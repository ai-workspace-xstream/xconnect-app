package plus.svc.xconnect

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.util.Base64
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore

class MainActivity : FlutterFragmentActivity() {
    private var productChannel: MethodChannel? = null
    private var pendingInvite: Map<String, Any?>? = null

    private val vpnPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            val granted = result.resultCode == Activity.RESULT_OK
            PacketTunnelController.onVpnPermissionResult(this, granted)
        }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "plus.svc.xconnect/native"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "savePacketTunnelProfile" -> {
                    val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
                    result.success(PacketTunnelController.saveProfile(this, args))
                }
                "startPacketTunnel" -> {
                    val args = call.arguments as? Map<*, *>
                    result.success(
                        PacketTunnelController.start(this, args) { intent ->
                            vpnPermissionLauncher.launch(intent)
                        }
                    )
                }
                "stopPacketTunnel" -> result.success(PacketTunnelController.stop(this))
                "getPacketTunnelStatus" -> result.success(PacketTunnelController.status(this))
                "openVpnSettings" -> result.success(openVpnSettings())
                "startNodeService", "stopNodeService", "performAction" -> result.success("Android not supported")
                "checkNodeStatus" -> result.success(false)
                else -> result.notImplemented()
            }
        }

        productChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "plus.svc.xconnect/xconnect_one"
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialInvite" -> {
                        result.success(pendingInvite)
                        pendingInvite = null
                    }
                    "probeJoinBridge" -> result.success(
                        mapOf(
                            "available" to false,
                            "code" to "mobile_join_bridge_unavailable"
                        )
                    )
                    "probeSecureStorage" -> result.success(probeAndroidKeystore())
                    "clearEnrollmentTransient" -> result.success(
                        mapOf("cleared" to true, "code" to "nothing_to_clear")
                    )
                    "joinInvite", "resumeEnrollment" -> result.success(
                        mapOf(
                            "outcome" to "failed",
                            "code" to "mobile_join_bridge_unavailable",
                            "retryable" to false
                        )
                    )
                    "syncDeviceSession", "rotateDeviceCredential", "leaveDevice" -> result.success(
                        mapOf(
                            "completed" to false,
                            "code" to "protected_device_session_unavailable",
                            "retryable" to false
                        )
                    )
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        captureInvite(intent, emit = false)
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureInvite(intent, emit = true)
    }

    private fun captureInvite(intent: Intent?, emit: Boolean) {
        if (intent?.action != Intent.ACTION_VIEW || intent.data == null) return
        val accepted = validateInvite(intent.data!!)
        val event = accepted?.let {
            mapOf<String, Any?>("status" to "accepted", "payload" to it)
        } ?: mapOf<String, Any?>(
            "status" to "rejected",
            "code" to "join_invite_invalid"
        )
        if (emit && productChannel != null) {
            val method = if (accepted == null) "inviteRejected" else "inviteReceived"
            productChannel?.invokeMethod(method, event)
        } else {
            pendingInvite = event
        }
    }

    private fun validateInvite(uri: Uri): String? {
        if (uri.scheme != "xconnect" || uri.host != "join" || uri.userInfo != null ||
            uri.fragment != null || uri.port != -1 || uri.pathSegments.size != 1) return null
        val token = uri.pathSegments.single()
        if (uri.encodedPath != "/$token" || !validJoinToken(token)) return null
        if (uri.queryParameterNames != setOf("controller") ||
            uri.getQueryParameters("controller").size != 1) return null
        val controllerValue = uri.getQueryParameter("controller") ?: return null
        val controller = Uri.parse(controllerValue)
        if (controller.scheme != "https" || controller.host.isNullOrBlank() ||
            controller.userInfo != null || controller.query != null || controller.fragment != null ||
            (controller.path?.isNotEmpty() == true && controller.path != "/")) return null
        return uri.toString()
    }

    private fun validJoinToken(value: String): Boolean {
        if (!value.matches(Regex("^xjt_[A-Za-z0-9_-]{43}$"))) return false
        return try {
            val raw = Base64.decode(
                value.removePrefix("xjt_"),
                Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP
            )
            raw.size == 32 && Base64.encodeToString(
                raw,
                Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP
            ) == value.removePrefix("xjt_")
        } catch (_: IllegalArgumentException) {
            false
        }
    }

    private fun probeAndroidKeystore(): Map<String, Any?> {
        return try {
            KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            mapOf(
                "available" to true,
                "backend" to "android_keystore",
                "code" to "android_keystore_available"
            )
        } catch (_: Throwable) {
            mapOf(
                "available" to false,
                "backend" to "android_keystore",
                "code" to "android_keystore_unavailable"
            )
        }
    }

    private fun openVpnSettings(): String {
        return try {
            startActivity(
                Intent(Settings.ACTION_VPN_SETTINGS).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            )
            "opened"
        } catch (t: Throwable) {
            "failed: ${t.message ?: "unknown_error"}"
        }
    }
}
