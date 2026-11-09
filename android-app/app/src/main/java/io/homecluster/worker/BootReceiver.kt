package io.homecluster.worker

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        val p = Prefs(ctx)
        if (p.autostart && p.enabled && p.headUrl.isNotBlank()) WorkerService.start(ctx)
    }
}
