package io.homecluster.worker

import java.net.Inet4Address
import java.net.NetworkInterface

object Net {
    /** (interface name, IPv4) of the LAN link: USB/ethernet first, then Wi-Fi. */
    fun lan(): Pair<String, String>? {
        val all = try { NetworkInterface.getNetworkInterfaces()?.toList() ?: emptyList() } catch (e: Exception) { emptyList() }
        val cands = all.filter { it.isUp && !it.isLoopback }
            .mapNotNull { nif ->
                nif.inetAddresses.toList().firstOrNull { it is Inet4Address && !it.isLoopbackAddress }
                    ?.let { nif.name to it.hostAddress!! }
            }
        val rank = { name: String -> when { name.startsWith("eth") || name.startsWith("usb") || name.startsWith("rndis") -> 0; name.startsWith("wlan") -> 1; else -> 2 } }
        return cands.filter { rank(it.first) < 2 }.minByOrNull { rank(it.first) } ?: cands.firstOrNull()
    }

    fun linkType(iface: String?) = when {
        iface == null -> "unknown"
        iface.startsWith("wlan") -> "wifi"
        else -> "wired"
    }
}
