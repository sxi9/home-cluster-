package io.homecluster.worker

import java.util.concurrent.TimeUnit

/** Optional root features. Everything else works without them. */
object Root {
    @Volatile var available: Boolean? = null

    fun check(): Boolean {
        available?.let { return it }
        val ok = try {
            val p = ProcessBuilder("su", "-c", "id").redirectErrorStream(true).start()
            val out = p.inputStream.bufferedReader().readText()
            p.waitFor(5, TimeUnit.SECONDS) && p.exitValue() == 0 && out.contains("uid=0")
        } catch (e: Exception) { false }
        available = ok
        return ok
    }

    private fun su(cmd: String) {
        try {
            val p = ProcessBuilder("su", "-c", cmd).redirectErrorStream(true).start()
            p.waitFor(10, TimeUnit.SECONDS)
        } catch (_: Exception) {}
    }

    /** Keep the app alive and the model process away from the low-memory killer. */
    fun tweaks(pkg: String, rpcPid: Long?) {
        if (!check()) return
        su("dumpsys deviceidle whitelist +$pkg >/dev/null 2>&1; cmd appops set $pkg RUN_IN_BACKGROUND allow; settings put global wifi_sleep_policy 2")
        if (rpcPid != null) su("echo -1000 > /proc/$rpcPid/oom_score_adj")
    }
}
