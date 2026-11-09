package io.homecluster.worker

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.widget.Button
import android.widget.EditText
import android.widget.Switch
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat

class MainActivity : AppCompatActivity() {
    private lateinit var prefs: Prefs
    private val handler = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        prefs = Prefs(this)
        val headUrl = findViewById<EditText>(R.id.headUrl)
        val nodeName = findViewById<EditText>(R.id.nodeName)
        val reserve = findViewById<EditText>(R.id.reserveMb)
        val auto = findViewById<Switch>(R.id.autostart)
        val toggle = findViewById<Button>(R.id.toggle)
        headUrl.setText(prefs.headUrl); nodeName.setText(prefs.nodeName); reserve.setText(prefs.reserveMb.toString()); auto.isChecked = prefs.autostart
        if (nodeName.text.isBlank()) nodeName.hint = prefs.effectiveName()

        if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)

        toggle.setOnClickListener {
            if (WorkerState.running) {
                prefs.enabled = false; WorkerService.stop(this)
            } else {
                prefs.headUrl = headUrl.text.toString(); prefs.nodeName = nodeName.text.toString()
                prefs.reserveMb = reserve.text.toString().toIntOrNull() ?: 2048; prefs.autostart = auto.isChecked
                if (prefs.headUrl.isBlank()) { headUrl.error = "needed"; return@setOnClickListener }
                prefs.enabled = true; WorkerService.start(this)
            }
        }
        findViewById<Button>(R.id.battery).setOnClickListener {
            val pm = getSystemService(PowerManager::class.java)
            if (!pm.isIgnoringBatteryOptimizations(packageName))
                startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")))
            else startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        }
        tick()
    }

    private fun tick() {
        val toggle = findViewById<Button>(R.id.toggle)
        val status = findViewById<TextView>(R.id.status)
        val pm = getSystemService(PowerManager::class.java)
        toggle.text = if (WorkerState.running) "Stop" else "Start"
        val hb = if (WorkerState.lastHeartbeat > 0) "${(System.currentTimeMillis() - WorkerState.lastHeartbeat) / 1000}s ago" else "never"
        status.text = buildString {
            appendLine(if (WorkerState.running) "RUNNING" else "stopped")
            appendLine("rpc-server : ${if (WorkerState.rpcAlive) "up on ${WorkerState.lanIp}:${prefs.rpcPort}" else "down"}")
            appendLine("offers     : ${WorkerState.offeredMb} MB RAM")
            appendLine("head       : ${WorkerState.headUrl ?: "not reachable"} (heartbeat $hb)")
            appendLine("llama.cpp  : ${WorkerState.llamaRef}")
            appendLine("root       : ${when (Root.available) { true -> "yes (memory-killer protection on)"; false -> "no (works, less resilient)"; null -> "?" }}")
            appendLine("battery opt: ${if (pm.isIgnoringBatteryOptimizations(packageName)) "exempt" else "NOT exempt — tap the button above"}")
            appendLine(); append(WorkerState.tail())
        }
        handler.postDelayed({ tick() }, 2000)
    }

    override fun onDestroy() { handler.removeCallbacksAndMessages(null); super.onDestroy() }
}
