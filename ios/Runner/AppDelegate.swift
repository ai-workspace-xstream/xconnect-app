import Flutter
import Security
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var productChannel: FlutterMethodChannel?
  private var pendingInvite: [String: Any]?

  private var isRunningUnitTests: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if isRunningUnitTests {
      return true
    }
    if let inviteURL = launchOptions?[.url] as? URL {
      captureInvite(inviteURL, emit: false)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let messenger = engineBridge.applicationRegistrar.messenger()
    let api = DarwinHostApiImpl(binaryMessenger: messenger)
    DarwinHostApiSetup.setUp(binaryMessenger: messenger, api: api)

    let channel = FlutterMethodChannel(name: "plus.svc.xconnect/native", binaryMessenger: messenger)
    let bundleId = Bundle.main.bundleIdentifier ?? "com.xconnect"
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      switch call.method {
      case "writeConfigFiles":
        self.writeConfigFiles(call: call, result: result)
      case "startNodeService", "stopNodeService", "checkNodeStatus":
        self.handleServiceControl(call: call, result: result)
      case "performAction":
        self.handlePerformAction(call: call, bundleId: bundleId, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let product = FlutterMethodChannel(
      name: "plus.svc.xconnect/xconnect_one",
      binaryMessenger: messenger
    )
    productChannel = product
    product.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      switch call.method {
      case "initialInvite":
        result(self.pendingInvite)
        self.pendingInvite = nil
      case "probeJoinBridge":
        result([
          "available": false,
          "code": "mobile_join_bridge_unavailable",
        ])
      case "probeSecureStorage":
        result(self.probeKeychain())
      case "clearEnrollmentTransient":
        result(["cleared": true, "code": "nothing_to_clear"])
      case "joinInvite", "resumeEnrollment":
        result([
          "outcome": "failed",
          "code": "mobile_join_bridge_unavailable",
          "retryable": false,
        ])
      case "syncDeviceSession", "rotateDeviceCredential", "leaveDevice":
        result([
          "completed": false,
          "code": "protected_device_session_unavailable",
          "retryable": false,
        ])
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    captureInvite(url, emit: true)
    return true
  }

  func captureInvite(_ url: URL, emit: Bool) {
    let accepted = validateInvite(url)
    let event: [String: Any]
    if let accepted {
      event = ["status": "accepted", "payload": accepted]
    } else {
      event = ["status": "rejected", "code": "join_invite_invalid"]
    }
    if emit, let productChannel {
      productChannel.invokeMethod(
        accepted == nil ? "inviteRejected" : "inviteReceived",
        arguments: event
      )
    } else {
      pendingInvite = event
    }
  }

  private func validateInvite(_ url: URL) -> String? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme == "xconnect", components.host == "join",
      components.user == nil, components.password == nil, components.port == nil,
      components.fragment == nil,
      let queryItems = components.queryItems, queryItems.count == 1,
      queryItems[0].name == "controller", let controllerValue = queryItems[0].value
    else { return nil }

    let token = String(components.path.dropFirst())
    guard components.path == "/\(token)", components.percentEncodedPath == "/\(token)",
      validJoinToken(token),
      let controller = URLComponents(string: controllerValue),
      controller.scheme == "https", controller.host?.isEmpty == false,
      controller.user == nil, controller.password == nil, controller.query == nil,
      controller.fragment == nil, controller.path.isEmpty || controller.path == "/"
    else { return nil }
    return url.absoluteString
  }

  private func validJoinToken(_ value: String) -> Bool {
    guard value.range(of: #"^xjt_[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil
    else { return false }
    var raw = String(value.dropFirst(4)).replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    raw += String(repeating: "=", count: (4 - raw.count % 4) % 4)
    guard let data = Data(base64Encoded: raw), data.count == 32 else { return false }
    let canonical = data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return canonical == String(value.dropFirst(4))
  }

  private func probeKeychain() -> [String: Any] {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "plus.svc.xconnect.capability-probe",
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecReturnData as String: false,
    ]
    let status = SecItemCopyMatching(query as CFDictionary, nil)
    let available = status == errSecSuccess || status == errSecItemNotFound
    return [
      "available": available,
      "backend": "keychain",
      "code": available ? "keychain_available" : "keychain_unavailable",
    ]
  }
}
