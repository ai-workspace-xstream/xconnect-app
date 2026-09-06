package plus.svc.xconnect

import android.content.Intent
import android.net.IpPrefix
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.InetAddress

class XConnectPacketTunnelService : VpnService() {
    private var tunInterface: ParcelFileDescriptor? = null
    private var tunnelHandle: Long = 0L

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> startTunnel(intent.getStringExtra(EXTRA_PROFILE_JSON))
            ACTION_STOP -> {
                stopTunnel()
                stopSelf()
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        stopTunnel()
        super.onDestroy()
    }

    private fun startTunnel(profileJson: String?) {
        if (profileJson.isNullOrBlank()) {
            PacketTunnelController.markFailed(this, "profile_missing")
            stopSelf()
            return
        }

        try {
            val profile = JSONObject(profileJson)
            val mtu = profile.optInt("mtu", 1500).coerceIn(1200, 9000)
            val configuredDns4 = jsonStringArray(profile.optJSONArray("dnsServers4"))
            val dns4 = if (configuredDns4.isEmpty()) {
                listOf("1.1.1.1", "8.8.8.8")
            } else {
                configuredDns4
            }
            val dns6 = jsonStringArray(profile.optJSONArray("dnsServers6"))
            val ipv4Addresses = jsonStringArray(profile.optJSONArray("ipv4Addresses"))
            val ipv4SubnetMasks = jsonStringArray(profile.optJSONArray("ipv4SubnetMasks"))
            val ipv4Routes = profile.optJSONArray("ipv4IncludedRoutes")
            val ipv4ExcludedRoutes = profile.optJSONArray("ipv4ExcludedRoutes")
            val ipv6Addresses = jsonStringArray(profile.optJSONArray("ipv6Addresses"))
            val ipv6Prefixes = jsonIntArray(profile.optJSONArray("ipv6NetworkPrefixLengths"))
            val ipv6Routes = profile.optJSONArray("ipv6IncludedRoutes")
            val ipv6ExcludedRoutes = profile.optJSONArray("ipv6ExcludedRoutes")

            android.util.Log.i(
                LOG_TAG,
                "profile dns4=${dns4.size} dns6=${dns6.size} " +
                    "ipv4Excluded=${ipv4ExcludedRoutes?.length() ?: 0} " +
                    "ipv6=${!ipv6Addresses.firstOrNull().isNullOrBlank()}"
            )

            val baseConfig = resolveConfigJson(profile)
            if (baseConfig.isNullOrBlank()) {
                PacketTunnelController.markFailed(this, "config_missing")
                stopSelf()
                return
            }
            stopTunnel()

            // Resolve node endpoints while the old VPN is down. If the
            // Flutter-side preflight could not pin a domain, doing it here
            // still prevents the Xray bootstrap lookup from entering its own
            // TUN. TLS SNI and transport host fields remain unchanged.
            val pinned = pinOutboundEndpoints(baseConfig)
            android.util.Log.i(LOG_TAG, "pinned endpoint count=${pinned.second.size}")
            val tunnelConfig = ensureTunInbound(pinned.first, mtu)

            val builder = Builder()
                .setSession("XConnect")
                .setMtu(mtu)

            // The Xray engine runs in this same UID. Keep its node and DNS
            // sockets on the underlying network, otherwise the node dial can
            // be routed back into the TUN that Xray is consuming. The VPN
            // still covers every other application on the device.
            try {
                builder.addDisallowedApplication(packageName)
            } catch (_: Throwable) {
                // A failed exclusion must not hide the real tunnel start
                // error; Xray will report it through its normal start path.
            }

            val ipv4Address = ipv4Addresses.firstOrNull() ?: "10.0.0.2"
            val ipv4Mask = ipv4SubnetMasks.firstOrNull() ?: "255.255.255.0"
            builder.addAddress(ipv4Address, maskToPrefixLength(ipv4Mask))

            val ipv6Address = ipv6Addresses.firstOrNull()
            val ipv6Prefix = ipv6Prefixes.firstOrNull() ?: 120
            if (!ipv6Address.isNullOrBlank()) {
                builder.addAddress(ipv6Address, ipv6Prefix.coerceIn(0, 128))
            }

            addIpv4Routes(builder, ipv4Routes)
            addExcludedRoutes(builder, ipv4ExcludedRoutes, ipv6ExcludedRoutes)
            addPinnedEndpointExclusions(builder, pinned.second)
            // Advertising an IPv6 default route without an IPv6 address makes
            // Android send IPv6-only app traffic into a stack that has no
            // usable IPv6 interface. Keep the physical IPv6 route untouched
            // until the profile supplies an address and prefix.
            if (!ipv6Address.isNullOrBlank()) {
                addIpv6Routes(builder, ipv6Routes)
            }

            dns4.forEach { dns ->
                if (dns.isNotBlank()) {
                    builder.addDnsServer(dns)
                }
            }
            dns6.forEach { dns ->
                if (dns.isNotBlank()) {
                    builder.addDnsServer(dns)
                }
            }

            tunInterface = builder.establish()
            val tunFd = tunInterface?.fd ?: -1
            if (tunFd <= 0) {
                PacketTunnelController.markFailed(this, "establish_failed")
                stopSelf()
                return
            }

            if (!NativePacketTunnelBridge.isAvailable()) {
                PacketTunnelController.markFailed(this, "native_bridge_unavailable")
                stopTunnel(markDisconnected = false)
                stopSelf()
                return
            }

            tunnelHandle = NativePacketTunnelBridge.startTunnel(tunnelConfig, tunFd)
            if (tunnelHandle <= 0L) {
                PacketTunnelController.markFailed(this, "xray_start_failed")
                stopTunnel(markDisconnected = false)
                stopSelf()
                return
            }

            android.util.Log.i(LOG_TAG, "packet tunnel engine started fd=$tunFd")
            PacketTunnelController.markConnected(this)
        } catch (t: Throwable) {
            android.util.Log.e(LOG_TAG, "packet tunnel start failed: ${t.message}")
            PacketTunnelController.markFailed(this, t.message ?: "start_failed")
            stopTunnel(markDisconnected = false)
            stopSelf()
        }
    }

    private fun stopTunnel(markDisconnected: Boolean = true) {
        if (tunnelHandle > 0L) {
            try {
                NativePacketTunnelBridge.stopTunnel(tunnelHandle)
            } catch (_: Throwable) {
            }
            try {
                NativePacketTunnelBridge.freeTunnel(tunnelHandle)
            } catch (_: Throwable) {
            }
            tunnelHandle = 0L
        }

        try {
            tunInterface?.close()
        } catch (_: Throwable) {
        } finally {
            tunInterface = null
        }

        if (markDisconnected) {
            PacketTunnelController.markDisconnected(this)
        }
    }

    private fun resolveConfigJson(profile: JSONObject): String? {
        val inlineConfig = profile.optString("configJson", "").trim()
        if (inlineConfig.isNotEmpty()) {
            return inlineConfig
        }

        val configPath = profile.optString("configPath", "").trim()
        if (configPath.isEmpty()) {
            return null
        }
        val file = File(configPath)
        if (!file.exists() || !file.isFile) {
            return null
        }
        return file.readText()
    }

    private fun ensureTunInbound(configJson: String, mtu: Int): String {
        val root = JSONObject(configJson)
        val inbounds = root.optJSONArray("inbounds") ?: JSONArray()

        var hasTunInbound = false
        for (i in 0 until inbounds.length()) {
            val inbound = inbounds.optJSONObject(i) ?: continue
            if (inbound.optString("protocol") == "tun") {
                val settings = inbound.optJSONObject("settings") ?: JSONObject()
                settings.put("name", settings.optString("name", "xray0"))
                settings.put("MTU", settings.optInt("MTU", mtu))
                inbound.put("settings", settings)
                hasTunInbound = true
                break
            }
        }

        if (!hasTunInbound) {
            val tunInbound = JSONObject()
                .put("port", 0)
                .put("protocol", "tun")
                .put("tag", "tun-in")
                .put(
                    "settings",
                    JSONObject()
                        .put("name", "xray0")
                        .put("MTU", mtu)
                        .put("userLevel", 0)
                )
            inbounds.put(tunInbound)
            root.put("inbounds", inbounds)
        }

        return root.toString()
    }

    private fun pinOutboundEndpoints(configJson: String): Pair<String, List<String>> {
        val root = try {
            JSONObject(configJson)
        } catch (_: Throwable) {
            return configJson to emptyList()
        }
        val outbounds = root.optJSONArray("outbounds") ?: return configJson to emptyList()
        val pinned = LinkedHashSet<String>()
        val protocols = setOf("vless", "vmess", "trojan", "shadowsocks", "socks", "http")

        for (i in 0 until outbounds.length()) {
            val outbound = outbounds.optJSONObject(i) ?: continue
            if (!protocols.contains(outbound.optString("protocol").lowercase())) continue
            val settings = outbound.optJSONObject("settings") ?: continue
            for (key in arrayOf("vnext", "servers")) {
                val entries = settings.optJSONArray(key) ?: continue
                for (j in 0 until entries.length()) {
                    val entry = entries.optJSONObject(j) ?: continue
                    val domain = entry.optString("address", "").trim()
                    if (domain.isEmpty() || parseNumericAddressOrNull(domain) != null) {
                        continue
                    }
                    val resolved = try {
                        InetAddress.getAllByName(domain).firstOrNull { it.address.size == 4 }
                    } catch (_: Throwable) {
                        null
                    } ?: continue
                    entry.put("address", resolved.hostAddress)
                    pinned.add(resolved.hostAddress)
                }
            }
        }
        return root.toString() to pinned.toList()
    }

    private fun addPinnedEndpointExclusions(builder: Builder, addresses: List<String>) {
        if (Build.VERSION.SDK_INT < 33) return
        for (address in addresses) {
            try {
                builder.excludeRoute(IpPrefix(InetAddress.getByName(address), 32))
            } catch (_: Throwable) {
                // Keep the tunnel available if a resolver returned an invalid address.
            }
        }
    }

    private fun addIpv4Routes(builder: Builder, routes: JSONArray?) {
        var added = false
        if (routes != null) {
            for (i in 0 until routes.length()) {
                val route = routes.optJSONObject(i) ?: continue
                val destination = route.optString("destinationAddress", "")
                val subnetMask = route.optString("subnetMask", "")
                if (destination.isBlank() || subnetMask.isBlank()) {
                    continue
                }
                try {
                    builder.addRoute(destination, maskToPrefixLength(subnetMask))
                    added = true
                } catch (_: Throwable) {
                }
            }
        }
        if (!added) {
            builder.addRoute("0.0.0.0", 0)
        }
    }

    private fun addIpv6Routes(builder: Builder, routes: JSONArray?) {
        var added = false
        if (routes != null) {
            for (i in 0 until routes.length()) {
                val route = routes.optJSONObject(i) ?: continue
                val destination = route.optString("destinationAddress", "")
                val prefixLength = route.optInt("networkPrefixLength", 0)
                if (destination.isBlank()) {
                    continue
                }
                try {
                    builder.addRoute(destination, prefixLength.coerceIn(0, 128))
                    added = true
                } catch (_: Throwable) {
                }
            }
        }
        if (!added) {
            try {
                builder.addRoute("::", 0)
            } catch (_: Throwable) {
            }
        }
    }

    private fun addExcludedRoutes(
        builder: Builder,
        ipv4Routes: JSONArray?,
        ipv6Routes: JSONArray?
    ) {
        // Builder.excludeRoute was added in API 33. Older Android releases
        // still rely on the owner UID exclusion above for the engine bootstrap.
        if (Build.VERSION.SDK_INT < 33) return

        addExcludedRouteEntries(builder, ipv4Routes, isIpv4 = true)
        addExcludedRouteEntries(builder, ipv6Routes, isIpv4 = false)
    }

    private fun addExcludedRouteEntries(builder: Builder, routes: JSONArray?, isIpv4: Boolean) {
        if (routes == null) return
        for (i in 0 until routes.length()) {
            val route = routes.optJSONObject(i) ?: continue
            val destination = route.optString("destinationAddress", "").trim()
            if (destination.isEmpty()) continue
            val prefixLength = if (isIpv4) {
                maskToPrefixLength(route.optString("subnetMask", ""))
            } else {
                route.optInt("networkPrefixLength", 0).coerceIn(0, 128)
            }
            try {
                val address = InetAddress.getByName(destination)
                if ((isIpv4 && address.address.size != 4) ||
                    (!isIpv4 && address.address.size != 16)) {
                    continue
                }
                builder.excludeRoute(IpPrefix(address, prefixLength))
            } catch (_: Throwable) {
                // Ignore malformed optional exclusions and keep the tunnel up.
            }
        }
    }

    private fun maskToPrefixLength(mask: String): Int {
        return try {
            val bytes = InetAddress.getByName(mask).address
            bytes.sumOf { byte ->
                Integer.bitCount(byte.toInt() and 0xFF)
            }
        } catch (_: Throwable) {
            24
        }
    }

    private fun parseNumericAddressOrNull(value: String): InetAddress? {
        return try {
            if (value.any { it.isLetter() }) null else InetAddress.getByName(value)
        } catch (_: Throwable) {
            null
        }
    }

    private fun jsonStringArray(array: JSONArray?): List<String> {
        if (array == null) return emptyList()
        val out = ArrayList<String>(array.length())
        for (i in 0 until array.length()) {
            out.add(array.optString(i, ""))
        }
        return out
    }

    private fun jsonIntArray(array: JSONArray?): List<Int> {
        if (array == null) return emptyList()
        val out = ArrayList<Int>(array.length())
        for (i in 0 until array.length()) {
            out.add(array.optInt(i, 0))
        }
        return out
    }

    companion object {
        private const val LOG_TAG = "XConnectPacketTunnel"
        const val ACTION_START = "plus.svc.xconnect.securetunnel.START"
        const val ACTION_STOP = "plus.svc.xconnect.securetunnel.STOP"
        const val EXTRA_PROFILE_JSON = "profile_json"
    }
}
