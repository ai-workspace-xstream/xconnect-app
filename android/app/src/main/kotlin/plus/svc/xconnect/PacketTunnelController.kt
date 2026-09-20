package plus.svc.xconnect

import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.provider.Settings
import org.json.JSONObject

internal object PacketTunnelController {
    private const val LOG_TAG = "XConnectPacketTunnel"
    private const val PREFS = "xconnect_packet_tunnel"
    private const val KEY_PROFILE = "profile_json"
    private const val KEY_STATE = "state"
    private const val KEY_ERROR = "last_error"
    private const val KEY_STARTED_AT = "started_at"
    private const val KEY_PERMISSION_PENDING = "permission_pending"

    private const val STATE_NOT_CONFIGURED = "not_configured"
    private const val STATE_DISCONNECTED = "disconnected"
    private const val STATE_CONNECTING = "connecting"
    private const val STATE_CONNECTED = "connected"
    private const val STATE_INVALID = "invalid"

    fun saveProfile(context: Context, profileMap: Map<*, *>): String {
        val json = JSONObject()
        profileMap.forEach { (key, value) ->
            if (key is String) {
                json.put(key, value)
            }
        }
        prefs(context).edit().putString(KEY_PROFILE, json.toString()).apply()
        clearError(context)
        clearPendingPermission(context)
        if (readState(context) == STATE_NOT_CONFIGURED) {
            writeState(context, STATE_DISCONNECTED)
        }
        return "profile_saved"
    }

    fun start(
        context: Context,
        profileMap: Map<*, *>?,
        requestPermission: ((Intent) -> Unit)? = null,
    ): String {
        if (profileMap != null) {
            saveProfile(context, profileMap)
        }
        val stored = prefs(context).getString(KEY_PROFILE, null)
            ?: return "profile_missing"

        val prepareIntent = VpnService.prepare(context)
        android.util.Log.i(
            LOG_TAG,
            "start: prepare=${if (prepareIntent == null) "granted" else "needs-consent"}"
        )
        if (prepareIntent != null) {
            // Consent is not granted, so nothing is running. Writing
            // CONNECTING here strands the state whenever the system consent
            // dialog never delivers a result — which also made proxy mode
            // refuse to start with "Packet Tunnel 已在运行，请先停止", because
            // that guard treats CONNECTING as a live tunnel. `permissionPending`
            // carries the real story for the UI.
            writeState(context, STATE_DISCONNECTED)
            writeError(context, "vpn_permission_required")
            clearStartedAt(context)
            markPendingPermission(context)
            if (requestPermission != null) {
                requestPermission(prepareIntent)
                return "vpn_permission_requested"
            }
            writeState(context, STATE_INVALID)
            return "vpn_permission_required"
        }

        writeState(context, STATE_CONNECTING)
        clearError(context)
        clearPendingPermission(context)
        return startService(context, stored)
    }

    fun onVpnPermissionResult(context: Context, granted: Boolean): String {
        android.util.Log.i(LOG_TAG, "onVpnPermissionResult: granted=$granted")
        if (!granted) {
            writeState(context, STATE_INVALID)
            writeError(context, "vpn_permission_denied")
            clearStartedAt(context)
            clearPendingPermission(context)
            return "vpn_permission_denied"
        }

        val stored = prefs(context).getString(KEY_PROFILE, null)
            ?: return "profile_missing"
        writeState(context, STATE_CONNECTING)
        clearError(context)
        clearPendingPermission(context)
        return startService(context, stored)
    }

    private fun startService(context: Context, stored: String): String {
        val intent = Intent(context, XConnectPacketTunnelService::class.java).apply {
            action = XConnectPacketTunnelService.ACTION_START
            putExtra(XConnectPacketTunnelService.EXTRA_PROFILE_JSON, stored)
        }
        return try {
            context.startService(intent)
            android.util.Log.i(LOG_TAG, "startService: submitted")
            "start_submitted"
        } catch (t: Throwable) {
            // A background start throws on API 26+; swallowing it left the UI
            // waiting on a service that was never going to run.
            android.util.Log.e(LOG_TAG, "startService failed: ${t.javaClass.simpleName}: ${t.message}")
            markFailed(context, "service_start_failed:${t.javaClass.simpleName}")
            "启动失败: ${t.javaClass.simpleName}"
        }
    }

    fun stop(context: Context): String {
        val intent = Intent(context, XConnectPacketTunnelService::class.java).apply {
            action = XConnectPacketTunnelService.ACTION_STOP
        }
        context.startService(intent)
        writeState(context, STATE_DISCONNECTED)
        clearError(context)
        clearStartedAt(context)
        clearPendingPermission(context)
        return "stop_submitted"
    }

    fun status(context: Context): Map<String, Any?> {
        return mapOf(
            "status" to readState(context),
            "utun" to emptyList<String>(),
            "lastError" to prefs(context).getString(KEY_ERROR, null),
            "startedAt" to prefs(context).getLong(KEY_STARTED_AT, 0L).takeIf { it > 0L },
            "permissionPending" to prefs(context).getBoolean(KEY_PERMISSION_PENDING, false),
        )
    }

    // Read-only VPN authorisation state, for Settings → 诊断/修复.
    //
    // `VpnService.prepare` returning null is the only reliable statement that
    // the OS has granted consent; the app cannot read the ACTIVATE_VPN appop.
    // `always_on_vpn_app` lives in Settings.Secure, is @hide and system-write
    // only, so an uninstall leaves it behind and a read may be refused — a
    // null therefore means "unknown", never "nothing is set".
    fun vpnConsentState(context: Context): Map<String, Any?> {
        val granted = try {
            VpnService.prepare(context) == null
        } catch (_: Throwable) {
            false
        }
        val alwaysOn = try {
            Settings.Secure.getString(context.contentResolver, "always_on_vpn_app")
        } catch (_: Throwable) {
            null
        }
        return mapOf(
            "granted" to granted,
            "alwaysOnVpnPackage" to alwaysOn?.takeIf { it.isNotBlank() },
            "ownPackage" to context.packageName,
        )
    }

    fun markConnected(context: Context) {
        writeState(context, STATE_CONNECTED)
        clearError(context)
        prefs(context).edit().putLong(KEY_STARTED_AT, System.currentTimeMillis() / 1000L).apply()
    }

    fun markDisconnected(context: Context) {
        writeState(context, STATE_DISCONNECTED)
        clearError(context)
        clearStartedAt(context)
        clearPendingPermission(context)
    }

    fun markFailed(context: Context, message: String) {
        writeState(context, STATE_INVALID)
        writeError(context, message)
        clearStartedAt(context)
        clearPendingPermission(context)
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun writeState(context: Context, state: String) {
        prefs(context).edit().putString(KEY_STATE, state).apply()
    }

    private fun readState(context: Context): String {
        return prefs(context).getString(KEY_STATE, STATE_NOT_CONFIGURED) ?: STATE_NOT_CONFIGURED
    }

    private fun writeError(context: Context, message: String) {
        prefs(context).edit().putString(KEY_ERROR, message).apply()
    }

    private fun clearError(context: Context) {
        prefs(context).edit().remove(KEY_ERROR).apply()
    }

    private fun clearStartedAt(context: Context) {
        prefs(context).edit().remove(KEY_STARTED_AT).apply()
    }

    private fun markPendingPermission(context: Context) {
        prefs(context).edit().putBoolean(KEY_PERMISSION_PENDING, true).apply()
    }

    private fun clearPendingPermission(context: Context) {
        prefs(context).edit().remove(KEY_PERMISSION_PENDING).apply()
    }
}
