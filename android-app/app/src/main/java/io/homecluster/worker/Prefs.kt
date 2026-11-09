package io.homecluster.worker

import android.content.Context
import android.os.Build

/** Settings the user enters once. Mirrors the keys worker.env uses on other devices. */
class Prefs(ctx: Context) {
    private val p = ctx.getSharedPreferences("home-cluster", Context.MODE_PRIVATE)

    var headUrl: String
        get() = p.getString("headUrl", "") ?: ""
        set(v) = p.edit().putString("headUrl", v.trim().trimEnd('/')).apply()

    var nodeName: String
        get() = p.getString("nodeName", "") ?: ""
        set(v) = p.edit().putString("nodeName", v.trim()).apply()

    var reserveMb: Int
        get() = p.getInt("reserveMb", 2048)
        set(v) = p.edit().putInt("reserveMb", v).apply()

    var autostart: Boolean
        get() = p.getBoolean("autostart", true)
        set(v) = p.edit().putBoolean("autostart", v).apply()

    var enabled: Boolean
        get() = p.getBoolean("enabled", false)
        set(v) = p.edit().putBoolean("enabled", v).apply()

    var fallbacks: List<String>
        get() = (p.getString("fallbacks", "") ?: "").split('\n').filter { it.isNotBlank() }
        set(v) = p.edit().putString("fallbacks", v.joinToString("\n")).apply()

    val rpcPort = 50052
    val agentPort = 8788

    fun effectiveName(): String {
        if (nodeName.isNotBlank()) return nodeName
        val model = Build.MODEL.lowercase().replace(Regex("[^a-z0-9]+"), "-").trim('-')
        val tail = Build.ID.lowercase().replace(Regex("[^a-z0-9]"), "").takeLast(4)
        return "${model.ifEmpty { "phone" }}-$tail"
    }
}
