import Foundation
import Flutter

extension AppDelegate {
  func logToFlutter(_ level: String, _ message: String) {
    let log = "[\(level.uppercased())] \(Date()): \(message)"
    if let controller = window?.rootViewController as? FlutterViewController {
      let messenger = controller.binaryMessenger
      let loggerChannel = FlutterMethodChannel(name: "plus.svc.xconnect/logger", binaryMessenger: messenger)
      loggerChannel.invokeMethod("log", arguments: log)
    }
  }
}
