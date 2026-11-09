package io.homecluster.worker

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.os.SystemClock
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.ServerSocket
import java.net.Socket
import java.net.URL

/**
 * Same job as agent/cluster-agent.py on the other devices: answer /metrics on :8788 and
 * heartbeat to the head every 10 s (falling back to standby heads it was told about).
 */
class Agent(private val ctx: Context, private val prefs: Prefs, private val state: WorkerState) {
    @Volatile private var running = false
    private var server: ServerSocket? = null

    fun start() {
        running = true
        Thread({ heartbeatLoop() }, "hc-heartbeat").apply { isDaemon = true }.start()
        Thread({ serve() }, "hc-metrics").apply { isDaemon = true }.start()
    }

    fun stop() {
        running = false
        try { server?.close() } catch (_: Exception) {}
    }

    // ------------------------------------------------------------------ snapshot
    private fun readInt(path: String): Long? = try { File(path).readText().trim().toLong() } catch (_: Exception) { null }

    private fun cpuInfo(): JSONObject {
        val soc = if (Build.VERSION.SDK_INT >= 31) listOf(Build.SOC_MANUFACTURER, Build.SOC_MODEL).filter { it.isNotBlank() && it != Build.UNKNOWN }.joinToString(" ") else ""
        var mhz: Long? = null
        for (i in 0 until Runtime.getRuntime().availableProcessors()) {
            val m = readInt("/sys/devices/system/cpu/cpu$i/cpufreq/cpuinfo_max_freq") ?: continue
            if (mhz == null || m > mhz) mhz = m
        }
        return JSONObject().put("model", soc.ifBlank { Build.HARDWARE }).put("cores", Runtime.getRuntime().availableProcessors())
            .put("max_mhz", mhz?.div(1000) ?: JSONObject.NULL).put("arch", Build.SUPPORTED_ABIS.firstOrNull() ?: "arm64")
    }

    private fun mem(): JSONObject {
        val am = ctx.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val mi = ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }
        return JSONObject().put("total_mb", mi.totalMem / 1048576).put("free_mb", mi.availMem / 1048576)
            .put("swap_total_mb", 0).put("swap_free_mb", 0)
    }

    private fun battery(): Any {
        val i = ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)) ?: return JSONObject.NULL
        val level = i.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = i.getIntExtra(BatteryManager.EXTRA_SCALE, 100)
        val st = i.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        if (level < 0) return JSONObject.NULL
        return JSONObject().put("percent", level * 100 / scale)
            .put("charging", st == BatteryManager.BATTERY_STATUS_CHARGING || st == BatteryManager.BATTERY_STATUS_FULL)
            .put("status", st.toString())
    }

    private fun temperature(): Any {
        var best: Double? = null
        try {
            File("/sys/class/thermal").listFiles()?.filter { it.name.startsWith("thermal_zone") }?.forEach {
                val t = readInt("${it.path}/temp") ?: return@forEach
                val c = if (t > 1000) t / 1000.0 else t.toDouble()
                if (c > 0 && c < 150 && (best == null || c > best!!)) best = c
            }
        } catch (_: Exception) {}
        if (best == null) {
            val i = ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            val t = i?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, -1) ?: -1
            if (t > 0) best = t / 10.0
        }
        return best ?: JSONObject.NULL
    }

    private fun storage(): JSONArray {
        val arr = JSONArray()
        fun add(kind: String, path: File, mount: String) {
            try {
                val s = StatFs(path.path)
                arr.put(JSONObject().put("dev", mount).put("kind", kind).put("vendor", "").put("model", "")
                    .put("size_gb", Math.round(s.totalBytes / 1073741824.0 * 10) / 10.0)
                    .put("free_gb", Math.round(s.availableBytes / 1073741824.0 * 10) / 10.0).put("mount", mount))
            } catch (_: Exception) {}
        }
        add("internal (UFS/eMMC)", ctx.filesDir, "/data")
        ctx.getExternalFilesDirs(null).filterNotNull().forEach { d ->
            if (try { Environment.isExternalStorageRemovable(d) } catch (_: Exception) { false }) add("SD card", d, d.path.substringBefore("/Android"))
        }
        return arr
    }

    fun snapshot(): JSONObject {
        val lan = Net.lan()
        val m = mem()
        val alerts = JSONArray()
        if (m.getLong("free_mb") < m.getLong("total_mb") * 0.08) alerts.put("low memory: ${m.getLong("free_mb")} MB free")
        return JSONObject()
            .put("name", prefs.effectiveName()).put("role", "worker").put("os", "android")
            .put("model", "${Build.MANUFACTURER} ${Build.MODEL}").put("arch", Build.SUPPORTED_ABIS.firstOrNull() ?: "arm64")
            .put("link", Net.linkType(lan?.first)).put("lan_ip", lan?.second ?: "0.0.0.0").put("agent_port", prefs.agentPort)
            .put("cpus", Runtime.getRuntime().availableProcessors()).put("cpu", cpuInfo()).put("storage", storage())
            .put("processes", JSONArray()).put("alerts", alerts).put("ssh", JSONObject.NULL).put("load1", JSONObject.NULL)
            .put("mem", m)
            .put("gpu", JSONObject().put("kind", "cpu").put("name", JSONObject.NULL).put("unified", true))
            .put("temp_c", temperature()).put("battery", battery())
            .put("rpc", JSONObject().put("port", prefs.rpcPort).put("listening", state.rpcAlive).put("mem_mb", state.offeredMb))
            .put("llama_ref", state.llamaRef).put("standby", false).put("root", Root.available ?: false)
            .put("app", "android-apk ${BuildConfig.VERSION_NAME}")
            .put("uptime_s", SystemClock.elapsedRealtime() / 1000).put("ts", System.currentTimeMillis() / 1000.0)
    }

    // ------------------------------------------------------------------ heartbeat
    private fun post(url: String, body: ByteArray): JSONObject? {
        val c = (URL("$url/api/heartbeat").openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"; connectTimeout = 3000; readTimeout = 3000; doOutput = true
            setRequestProperty("Content-Type", "application/json")
        }
        return try {
            c.outputStream.use { it.write(body) }
            if (c.responseCode != 200) null else JSONObject(c.inputStream.bufferedReader().readText())
        } catch (e: Exception) { null } finally { c.disconnect() }
    }

    private fun heartbeatLoop() {
        var fallbacks = prefs.fallbacks
        while (running) {
            val primary = prefs.headUrl
            if (primary.isNotBlank()) {
                val body = snapshot().toString().toByteArray()
                var answered: String? = null
                for (url in listOf(primary) + fallbacks.filter { it != primary }) {
                    val r = post(url, body) ?: continue
                    answered = url
                    if (url == primary) {
                        val fb = r.optJSONArray("fallbacks")?.let { a -> (0 until a.length()).map { a.getString(it) } } ?: emptyList()
                        if (fb != fallbacks) { fallbacks = fb; prefs.fallbacks = fb }
                    }
                    break
                }
                state.headUrl = answered
                state.lastHeartbeat = if (answered != null) System.currentTimeMillis() else state.lastHeartbeat
            }
            try { Thread.sleep(10_000) } catch (_: InterruptedException) { break }
        }
    }

    // ------------------------------------------------------------------ /metrics
    private fun serve() {
        try {
            server = ServerSocket(prefs.agentPort)
        } catch (e: Exception) { state.log("agent port ${prefs.agentPort} busy: $e"); return }
        while (running) {
            val s = try { server!!.accept() } catch (_: Exception) { break }
            Thread { handle(s) }.start()
        }
    }

    private fun handle(s: Socket) {
        s.use {
            try {
                val inp = it.getInputStream().bufferedReader()
                val req = inp.readLine() ?: return
                var len = 0
                while (true) { val l = inp.readLine() ?: break; if (l.isEmpty()) break
                    if (l.lowercase().startsWith("content-length:")) len = l.substringAfter(':').trim().toInt() }
                val parts = req.split(' ')
                val method = parts.getOrNull(0) ?: ""; val path = parts.getOrNull(1)?.substringBefore('?') ?: "/"
                val (code, body) = when {
                    method == "GET" && path in listOf("/", "/metrics", "/health") -> 200 to snapshot().toString()
                    method == "GET" && path == "/processes" -> 200 to "[]"
                    method == "POST" && path == "/sink" -> { var left = len; val buf = CharArray(65536)
                        while (left > 0) { val n = inp.read(buf, 0, minOf(left, buf.size)); if (n <= 0) break; left -= n }
                        200 to """{"bytes": ${len - left}}""" }
                    else -> 404 to """{"error":"not found"}"""
                }
                val bytes = body.toByteArray()
                it.getOutputStream().apply {
                    write("HTTP/1.1 $code OK\r\nContent-Type: application/json\r\nContent-Length: ${bytes.size}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n".toByteArray())
                    write(bytes); flush()
                }
            } catch (_: Exception) {}
        }
    }
}
