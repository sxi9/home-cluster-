package io.homecluster.worker

import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import java.io.File

/**
 * Foreground service: runs rpc-server (shipped as librpc-server.so, executed from the native
 * library dir), restarts it if it dies, holds wake + Wi-Fi locks, runs the Agent, and applies
 * root tweaks when root exists. Non-root phones work; root makes them survive memory pressure.
 */
class WorkerService : Service() {
    private var proc: Process? = null
    private var wake: PowerManager.WakeLock? = null
    private var wifi: WifiManager.WifiLock? = null
    private var agent: Agent? = null
    @Volatile private var stopRequested = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) { stopSelf(); return START_NOT_STICKY }
        if (WorkerState.running) return START_STICKY
        val prefs = Prefs(this)
        startForeground(1, notification("starting"))
        WorkerState.running = true
        stopRequested = false
        WorkerState.llamaRef = try { assets.open("llama_ref.txt").bufferedReader().readText().trim() } catch (_: Exception) { "unknown" }

        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "home-cluster:rpc").also { it.acquire() }
        val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val mode = if (Build.VERSION.SDK_INT >= 29) WifiManager.WIFI_MODE_FULL_LOW_LATENCY else @Suppress("DEPRECATION") WifiManager.WIFI_MODE_FULL_HIGH_PERF
        wifi = wm.createWifiLock(mode, "home-cluster:rpc").also { it.acquire() }

        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val mi = ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }
        WorkerState.offeredMb = maxOf(512, mi.totalMem / 1048576 - prefs.reserveMb)

        agent = Agent(this, prefs, WorkerState).also { it.start() }
        Thread({ supervise(prefs) }, "hc-rpc").start()
        return START_STICKY
    }

    /** Snapdragon phones ship the real OpenCL driver as /vendor/lib64/libOpenCL.so. */
    private fun vendorOpenCL(): Boolean = listOf("/vendor/lib64/libOpenCL.so", "/system/vendor/lib64/libOpenCL.so").any { File(it).exists() }

    private fun socName(): String {
        val soc = if (Build.VERSION.SDK_INT >= 31) listOf(Build.SOC_MANUFACTURER, Build.SOC_MODEL).filter { it.isNotBlank() && it != Build.UNKNOWN }.joinToString(" ") else ""
        return if (soc.isNotBlank()) "Adreno ($soc)" else "Adreno (${Build.HARDWARE})"
    }

    private fun supervise(prefs: Prefs) {
        val cpuExe = File(applicationInfo.nativeLibraryDir, "librpc-server.so")
        val clExe = File(applicationInfo.nativeLibraryDir, "librpc-server-cl.so")
        if (!cpuExe.exists()) { WorkerState.log("rpc-server binary missing from the APK (${cpuExe.path})"); return }
        cpuExe.setExecutable(true); clExe.setExecutable(true)
        Root.check()
        var useGpu = prefs.useGpu && clExe.exists() && vendorOpenCL()
        if (prefs.useGpu && !clExe.exists()) WorkerState.log("this APK has no OpenCL build; CPU only")
        else if (prefs.useGpu && !vendorOpenCL()) WorkerState.log("no /vendor/lib64/libOpenCL.so on this phone; CPU only")
        var gpuFailures = 0
        while (!stopRequested) {
            val exe = if (useGpu) clExe else cpuExe
            WorkerState.gpuKind = if (useGpu) "opencl" else "cpu"
            WorkerState.gpuName = if (useGpu) socName() else null
            val lan = Net.lan()
            val ip = lan?.second ?: "0.0.0.0"
            WorkerState.lanIp = ip
            val threads = Runtime.getRuntime().availableProcessors().toString()
            try {
                // RPC_MEM_MB is a planner-side cap reported by the agent; rpc-server takes no --mem
                val pb = ProcessBuilder(exe.path, "--host", ip, "--port", prefs.rpcPort.toString(), "--threads", threads)
                    .redirectErrorStream(true)
                if (useGpu) {
                    // the vendor driver lives outside the app's linker namespace: point the loader at it,
                    // and keep compiled kernels in the app cache so the GPU is ready in seconds next time
                    pb.environment()["LD_LIBRARY_PATH"] = "/vendor/lib64:/system/vendor/lib64:/system/lib64"
                    pb.environment()["GGML_OPENCL_KERNEL_CACHE_DIR"] = File(cacheDir, "opencl").apply { mkdirs() }.path
                }
                val started = System.currentTimeMillis()
                val p = pb.start()
                proc = p
                WorkerState.rpcPid = pidOf(p)
                WorkerState.rpcAlive = true
                WorkerState.log("rpc-server (${if (useGpu) "Adreno OpenCL" else "CPU"}) started on $ip:${prefs.rpcPort} (${if (Root.available == true) "root" else "no root"})")
                updateNotification("serving $ip:${prefs.rpcPort}")
                Root.tweaks(packageName, WorkerState.rpcPid)
                p.inputStream.bufferedReader().forEachLine { WorkerState.log(it) }
                p.waitFor()
                WorkerState.rpcAlive = false
                WorkerState.log("rpc-server exited with ${p.exitValue()}")
                if (useGpu && System.currentTimeMillis() - started < 15_000 && ++gpuFailures >= 2) {
                    useGpu = false
                    WorkerState.gpuFallback = "OpenCL binary kept dying at start; using the CPU binary"
                    WorkerState.log(WorkerState.gpuFallback!!)
                }
            } catch (e: Exception) {
                WorkerState.rpcAlive = false
                WorkerState.log("rpc-server failed: $e")
                if (useGpu && ++gpuFailures >= 2) { useGpu = false; WorkerState.gpuFallback = "OpenCL binary would not start; using the CPU binary" }
            }
            if (stopRequested) break
            updateNotification("rpc-server restarting")
            try { Thread.sleep(3000) } catch (_: InterruptedException) { break }
        }
    }

    override fun onDestroy() {
        stopRequested = true
        WorkerState.running = false
        WorkerState.rpcAlive = false
        agent?.stop()
        proc?.destroy()
        try { wake?.release() } catch (_: Exception) {}
        try { wifi?.release() } catch (_: Exception) {}
        super.onDestroy()
    }

    /** Android's java.lang.Process has no pid(); the field exists on its UNIXProcess. */
    private fun pidOf(p: Process): Long? = try {
        val f = p.javaClass.getDeclaredField("pid"); f.isAccessible = true; (f.get(p) as Int).toLong()
    } catch (_: Exception) {
        p.toString().substringAfter("pid=", "").takeWhile { it.isDigit() }.toLongOrNull()
    }

    private fun notification(text: String): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "home-cluster worker", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 1, Intent(this, WorkerService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(this, CHANNEL).setSmallIcon(R.drawable.ic_launcher).setContentTitle("home-cluster worker")
            .setContentText(text).setOngoing(true).setContentIntent(open).addAction(0, "Stop", stop).build()
    }

    private fun updateNotification(text: String) {
        if (Build.VERSION.SDK_INT >= 34)
            ServiceCompat.startForeground(this, 1, notification(text), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        else startForeground(1, notification(text))
    }

    companion object {
        const val CHANNEL = "home-cluster"
        const val ACTION_STOP = "io.homecluster.worker.STOP"
        fun start(ctx: Context) { ContextCompat.startForegroundService(ctx, Intent(ctx, WorkerService::class.java)) }
        fun stop(ctx: Context) { ctx.startService(Intent(ctx, WorkerService::class.java).setAction(ACTION_STOP)) }
    }
}
