import Darwin
import Foundation
import Network
import NetworkExtension
import os.log

let tunnelLog = OSLog(subsystem: "plus.svc.xconnect", category: "PacketTunnel")
#if os(iOS)
  // iPhoneOS SDK does not expose these kernel control macros to Swift, but the
  // Packet Tunnel getsockopt call still uses the standard XNU values.
  private let systemProtoControlLevel: Int32 = 2
  private let utunOptionInterfaceName: Int32 = 2
#else
  private let systemProtoControlLevel = SYSPROTO_CONTROL
  private let utunOptionInterfaceName = UTUN_OPT_IFNAME
#endif

public final class PacketTunnelProvider: NEPacketTunnelProvider {
  private var activeSettings: NEPacketTunnelNetworkSettings?
  private lazy var statusStore = PacketTunnelStatusStore()
  private lazy var metricsSampler = PacketTunnelMetricsSampler()
  private var monitor: NWPathMonitor?
  private lazy var engine: SecureTunnelEngine = XrayTunnelEngine()

  public override func startTunnel(
    options: [String: NSObject]?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    os_log("PacketTunnelProvider: starting tunnel", log: tunnelLog, type: .info)
    metricsSampler.stop()
    do {
      let map = try resolveOptions(options: options)
      let enableIPv6 = shouldEnableIPv6(options: map, launchOptions: options)
      let settings = try buildNetworkSettings(options: map, enableIPv6: enableIPv6)

      setTunnelNetworkSettings(settings) { [weak self] error in
        guard let self else {
          completionHandler(error)
          return
        }

        if let error {
          os_log(
            "PacketTunnelProvider: setTunnelNetworkSettings failed: %{public}@", log: tunnelLog,
            type: .error, error.localizedDescription)
          self.metricsSampler.stop()
          self.statusStore.markFailed(error.localizedDescription)
          completionHandler(error)
          return
        }

        self.activeSettings = settings
        self.ensurePathMonitor()
        self.startPathMonitor()

        let resolvedFd = self.resolvePacketFlowFileDescriptor()
        let resolvedTun = self.resolveDarwinTunnelHandle(preferredFd: resolvedFd)
        let fd = resolvedTun.fd
        let egressInterface =
          self.monitor?.currentPath.availableInterfaces.first(where: { !$0.name.contains("utun") })?
          .name ?? ""

        // Record what the egress link actually offers. An IPv6-only carrier
        // link is indistinguishable from a weak network at the socket layer --
        // both surface as an immediate EHOSTUNREACH on an IPv4 destination --
        // so the address families present on the egress interface are the only
        // way to tell them apart after the fact.
        self.statusStore.recordEgress(
          interfaceName: egressInterface,
          families: self.describeAddressFamilies(of: egressInterface)
        )

        do {
          let configData = self.attachEngineErrorLog(
            self.sanitizeConfigForDarwinTun(
              self.resolveConfigData(options: map),
              tunnelInterfaceName: resolvedTun.interfaceName
            )
          )
          try self.engine.start(
            config: configData,
            fd: fd,
            fdDetail: resolvedTun.detail,
            egressInterface: egressInterface
          )
          self.metricsSampler.start(interfaceName: resolvedTun.interfaceName)
          self.statusStore.markConnected()
          os_log("PacketTunnelProvider: Engine started successfully", log: tunnelLog, type: .info)
          completionHandler(nil)
        } catch {
          os_log(
            "PacketTunnelProvider: Engine failed to start: %{public}@", log: tunnelLog,
            type: .error, error.localizedDescription)
          self.rollbackStartFailure(error: error, completionHandler: completionHandler)
        }
      }
    } catch {
      os_log(
        "PacketTunnelProvider: startTunnel exception: %{public}@", log: tunnelLog, type: .error,
        error.localizedDescription)
      metricsSampler.stop()
      statusStore.markFailed(error.localizedDescription)
      completionHandler(error)
    }
  }

  public override func stopTunnel(
    with reason: NEProviderStopReason, completionHandler: @escaping () -> Void
  ) {
    os_log(
      "PacketTunnelProvider: stopping tunnel (reason=%{public}d)",
      log: tunnelLog,
      type: .info,
      reason.rawValue
    )
    metricsSampler.stop()
    monitor?.cancel()
    monitor = nil
    engine.stop()
    statusStore.markDisconnected(reason: reason)
    completionHandler()
  }

  private func resolveOptions(options: [String: NSObject]?) throws -> [String: NSObject] {
    if let options {
      return options
    }

    let proto = protocolConfiguration as? NETunnelProviderProtocol
    if let map = proto?.providerConfiguration?["options"] as? [String: NSObject] {
      return map
    }

    throw NSError(
      domain: "XConnect.PacketTunnel",
      code: -1,
      userInfo: [NSLocalizedDescriptionKey: "Missing Packet Tunnel options"]
    )
  }

  private func resolveConfigData(options: [String: NSObject]) -> Data {
    if let data = options["config"] as? Data {
      return data
    }
    if let data = options["config"] as? NSData {
      return data as Data
    }
    return Data()
  }

  private func sanitizeConfigForDarwinTun(
    _ data: Data,
    tunnelInterfaceName: String?
  ) -> Data {
    guard !data.isEmpty else {
      return data
    }
    guard
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      var inbounds = root["inbounds"] as? [[String: Any]]
    else {
      return data
    }

    let normalizedTunnelInterface = normalizeUtunInterfaceName(tunnelInterfaceName)
    var updated = false
    for index in inbounds.indices {
      guard
        let protocolName = inbounds[index]["protocol"] as? String,
        protocolName == "tun",
        var settings = inbounds[index]["settings"] as? [String: Any]
      else {
        continue
      }

      for key in ["interfaceName", "name", "interface"] {
        guard let raw = settings[key] as? String else {
          continue
        }
        let isValidUtun =
          raw.range(
            of: #"^utun[0-9]+$"#,
            options: .regularExpression
          ) != nil
        if !isValidUtun {
          settings.removeValue(forKey: key)
          updated = true
        }
      }

      if let normalizedTunnelInterface {
        for key in ["name", "interfaceName", "interface"] {
          if (settings[key] as? String) != normalizedTunnelInterface {
            settings[key] = normalizedTunnelInterface
            updated = true
          }
        }
      }
      inbounds[index]["settings"] = settings
    }

    guard updated else {
      return data
    }

    var patched = root
    patched["inbounds"] = inbounds
    return (try? JSONSerialization.data(withJSONObject: patched)) ?? data
  }

  /// Points the engine's error log at the shared App Group container.
  ///
  /// Without this the engine's own view of an outbound failure goes to stderr
  /// and is lost, leaving only the socket error the app sees -- which cannot
  /// distinguish a dial failure from a routing, TLS or transport problem.
  private func attachEngineErrorLog(_ data: Data) -> Data {
    guard
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: "group.plus.svc.xconnect"
      ),
      var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return data
    }

    let logsDirectory = container.appendingPathComponent("logs", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: logsDirectory, withIntermediateDirectories: true)
    let logURL = logsDirectory.appendingPathComponent("xray-tunnel.log")

    // Start each session from empty so a pulled log describes this run only.
    try? FileManager.default.removeItem(at: logURL)

    var logSettings = (root["log"] as? [String: Any]) ?? [:]
    logSettings["loglevel"] = "info"
    logSettings["error"] = logURL.path
    root["log"] = logSettings

    os_log(
      "PacketTunnelProvider: engine error log at %{public}@", log: tunnelLog, type: .info,
      logURL.path)
    return (try? JSONSerialization.data(withJSONObject: root)) ?? data
  }

  private func shouldEnableIPv6(options: [String: NSObject], launchOptions: [String: NSObject]?)
    -> Bool
  {
    let tun46Setting = (options["tun46Setting"] as? NSNumber)?.intValue ?? 2
    switch tun46Setting {
    case 0:
      return false
    case 1:
      return true
    default:
      if launchOptions != nil {
        return (options["defaultNicSupport6"] as? NSNumber)?.boolValue ?? true
      }
      return true
    }
  }

  private func buildNetworkSettings(
    options: [String: NSObject],
    enableIPv6: Bool
  ) throws -> NEPacketTunnelNetworkSettings {
    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
    settings.mtu = options["mtu"] as? NSNumber ?? NSNumber(value: 1500)

    var dnsServers = (options["dnsServers4"] as? [String]) ?? []
    if enableIPv6 {
      dnsServers.append(contentsOf: (options["dnsServers6"] as? [String]) ?? [])
    }
    if dnsServers.isEmpty {
      dnsServers = enableIPv6
        ? ["1.1.1.1", "8.8.8.8", "2606:4700:4700::1111", "2001:4860:4860::8888"]
        : ["1.1.1.1", "8.8.8.8"]
    }
    settings.dnsSettings = NEDNSSettings(servers: dnsServers)
    settings.dnsSettings?.matchDomains = [""]
    settings.dnsSettings?.matchDomainsNoSearch = true
    os_log(
      "PacketTunnelProvider: DNS capture servers=%{public}@ matchDomains=%{public}@",
      log: tunnelLog,
      type: .info,
      dnsServers.joined(separator: ","),
      (settings.dnsSettings?.matchDomains ?? []).joined(separator: ",")
    )

    let ipv4Addresses = (options["ipv4Addresses"] as? [String]) ?? ["10.0.0.2"]
    let ipv4Masks = (options["ipv4SubnetMasks"] as? [String]) ?? ["255.255.255.0"]
    guard ipv4Addresses.count == ipv4Masks.count else {
      throw NSError(
        domain: "XConnect.PacketTunnel",
        code: -2,
        userInfo: [NSLocalizedDescriptionKey: "Invalid IPv4 subnet mask mapping"]
      )
    }

    let ipv4 = NEIPv4Settings(addresses: ipv4Addresses, subnetMasks: ipv4Masks)
    let ipv4Included =
      (options["ipv4IncludedRoutes"] as? [[String: String]]) ?? [
        [
          "destinationAddress": "0.0.0.0",
          "subnetMask": "0.0.0.0",
        ]
      ]
    ipv4.includedRoutes = ipv4Included.compactMap { route in
      guard
        let destinationAddress = route["destinationAddress"],
        let subnetMask = route["subnetMask"]
      else {
        return nil
      }
      return NEIPv4Route(destinationAddress: destinationAddress, subnetMask: subnetMask)
    }

    let ipv4Excluded =
      (options["ipv4ExcludedRoutes"] as? [[String: String]])
      ?? (options["ipv4ExcludedRouteAddresses"] as? [[String: String]])
    if let ipv4Excluded {
      ipv4.excludedRoutes = ipv4Excluded.compactMap { route in
        guard
          let destinationAddress = route["destinationAddress"],
          let subnetMask = route["subnetMask"]
        else {
          return nil
        }
        return NEIPv4Route(destinationAddress: destinationAddress, subnetMask: subnetMask)
      }
    }
    settings.ipv4Settings = ipv4

    if enableIPv6 {
      let ipv6Addresses = (options["ipv6Addresses"] as? [String]) ?? ["fd00::2"]
      let ipv6Prefixes = (options["ipv6NetworkPrefixLengths"] as? [Int]) ?? [120]
      if ipv6Addresses.count == ipv6Prefixes.count {
        let ipv6 = NEIPv6Settings(
          addresses: ipv6Addresses,
          networkPrefixLengths: ipv6Prefixes.map { NSNumber(value: $0) }
        )

        let ipv6Included =
          (options["ipv6IncludedRoutes"] as? [[String: Any]]) ?? [
            [
              "destinationAddress": "::",
              "networkPrefixLength": NSNumber(value: 0),
            ]
          ]
        ipv6.includedRoutes = parseIPv6Routes(ipv6Included)

        if let ipv6Excluded = options["ipv6ExcludedRoutes"] as? [[String: Any]] {
          ipv6.excludedRoutes = parseIPv6Routes(ipv6Excluded)
        }

        settings.ipv6Settings = ipv6
      }
    }

    return settings
  }

  private func parseIPv6Routes(_ rawRoutes: [[String: Any]]) -> [NEIPv6Route] {
    rawRoutes.compactMap { route in
      guard let destinationAddress = route["destinationAddress"] as? String else {
        return nil
      }
      if let prefix = route["networkPrefixLength"] as? NSNumber {
        return NEIPv6Route(destinationAddress: destinationAddress, networkPrefixLength: prefix)
      }
      if let prefix = route["networkPrefixLength"] as? Int {
        return NEIPv6Route(
          destinationAddress: destinationAddress,
          networkPrefixLength: NSNumber(value: prefix)
        )
      }
      return nil
    }
  }

  private func startPathMonitor() {
    guard let monitor else {
      return
    }
    monitor.pathUpdateHandler = { path in
      guard path.status == .satisfied else {
        return
      }
      _ = path.availableInterfaces.first(where: { !$0.name.contains("utun") })
    }
    monitor.start(queue: DispatchQueue.global())
  }

  private func resolveDarwinTunnelHandle(
    preferredFd: (fd: Int32, detail: String)
  ) -> (fd: Int32, detail: String, interfaceName: String?) {
    if preferredFd.fd >= 0 {
      let interfaceName = resolveUtunInterfaceName(forFileDescriptor: preferredFd.fd)
      let detail = annotateFdDetail(preferredFd.detail, interfaceName: interfaceName)
      return (preferredFd.fd, detail, interfaceName)
    }

    if let scanned = scanOpenFileDescriptorsForUtun() {
      return scanned
    }

    return (preferredFd.fd, preferredFd.detail, nil)
  }

  private func resolvePacketFlowFileDescriptor() -> (fd: Int32, detail: String) {
    let flowObj = packetFlow as NSObject

    let selectorPaths = [
      ["socket", "fileDescriptor"],
      ["_socket", "fileDescriptor"],
      ["socket", "fd"],
      ["_socket", "fd"],
      ["packetSocket", "fileDescriptor"],
      ["packetSocket", "fd"],
      ["_packetSocket", "fileDescriptor"],
      ["_packetSocket", "fd"],
    ]
    for path in selectorPaths {
      if let fd = resolveIntSelectorPath(on: flowObj, path: path), fd >= 0 {
        return (fd, "packetFlow.\(path.joined(separator: "."))")
      }
    }

    if let fd = callIntSelector(on: flowObj, selectorName: "fileDescriptor"), fd >= 0 {
      return (fd, "packetFlow.fileDescriptor")
    }
    if let fd = callIntSelector(on: flowObj, selectorName: "fd"), fd >= 0 {
      return (fd, "packetFlow.fd")
    }

    let socketSelectors = ["socket", "_socket", "packetSocket", "_packetSocket", "fileHandle"]
    for selectorName in socketSelectors {
      guard let child = callObjectSelector(on: flowObj, selectorName: selectorName) else {
        continue
      }
      if let fd = callIntSelector(on: child, selectorName: "fileDescriptor"), fd >= 0 {
        return (fd, "packetFlow.\(selectorName).fileDescriptor")
      }
      if let fd = callIntSelector(on: child, selectorName: "fd"), fd >= 0 {
        return (fd, "packetFlow.\(selectorName).fd")
      }
    }

    if let fd = scanObjectIvarsForFileDescriptor(flowObj), fd >= 0 {
      return (fd, "packetFlow ivar scan")
    }

    return (-1, "no accessible fd selector on \(NSStringFromClass(type(of: flowObj)))")
  }

  private func scanOpenFileDescriptorsForUtun(
    maxFd: Int32 = 1024
  ) -> (fd: Int32, detail: String, interfaceName: String?)? {
    var matches: [(fd: Int32, interfaceName: String)] = []

    for candidate in 0...Int(maxFd) {
      let fd = Int32(candidate)
      guard fcntl(fd, F_GETFD) != -1 else {
        continue
      }
      guard let interfaceName = resolveUtunInterfaceName(forFileDescriptor: fd) else {
        continue
      }
      matches.append((fd, interfaceName))
    }

    guard !matches.isEmpty else {
      return nil
    }

    let resolved = matches.max { lhs, rhs in
      let lhsIndex = utunSortKey(lhs.interfaceName)
      let rhsIndex = utunSortKey(rhs.interfaceName)
      if lhsIndex == rhsIndex {
        return lhs.fd < rhs.fd
      }
      return lhsIndex < rhsIndex
    }!
    return (
      resolved.fd,
      "fd scan -> \(resolved.fd)",
      resolved.interfaceName
    )
  }

  private func resolveUtunInterfaceName(forFileDescriptor fd: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
    var length = socklen_t(buffer.count)
    let result = buffer.withUnsafeMutableBufferPointer { pointer in
      getsockopt(
        fd,
        systemProtoControlLevel,
        utunOptionInterfaceName,
        pointer.baseAddress,
        &length
      )
    }
    guard result == 0 else {
      return nil
    }
    return normalizeUtunInterfaceName(String(cString: buffer))
  }

  private func normalizeUtunInterfaceName(_ raw: String?) -> String? {
    guard let raw else {
      return nil
    }
    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.range(of: #"^utun[0-9]+$"#, options: .regularExpression) != nil else {
      return nil
    }
    return normalized
  }

  private func utunSortKey(_ name: String) -> Int {
    Int(name.dropFirst("utun".count)) ?? -1
  }

  private func annotateFdDetail(_ detail: String, interfaceName: String?) -> String {
    guard let interfaceName else {
      return detail
    }
    return "\(detail), tun=\(interfaceName)"
  }

  private func resolveIntSelectorPath(on object: NSObject, path: [String]) -> Int32? {
    guard !path.isEmpty else {
      return nil
    }
    if path.count == 1 {
      return callIntSelector(on: object, selectorName: path[0])
    }

    var current: NSObject? = object
    for segment in path.dropLast() {
      guard let unwrapped = current else {
        return nil
      }
      current = callObjectSelector(on: unwrapped, selectorName: segment)
    }

    guard let target = current, let leaf = path.last else {
      return nil
    }
    return callIntSelector(on: target, selectorName: leaf)
  }

  private func callIntSelector(on object: NSObject, selectorName: String) -> Int32? {
    let selector = NSSelectorFromString(selectorName)
    guard object.responds(to: selector),
      let method = class_getInstanceMethod(type(of: object), selector)
    else {
      return nil
    }
    typealias Getter = @convention(c) (AnyObject, Selector) -> Int
    let impl = method_getImplementation(method)
    let function = unsafeBitCast(impl, to: Getter.self)
    let value = function(object, selector)
    return Int32(value)
  }

  private func callObjectSelector(on object: NSObject, selectorName: String) -> NSObject? {
    let selector = NSSelectorFromString(selectorName)
    guard object.responds(to: selector),
      let method = class_getInstanceMethod(type(of: object), selector)
    else {
      return nil
    }
    typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
    let impl = method_getImplementation(method)
    let function = unsafeBitCast(impl, to: Getter.self)
    return function(object, selector)?.takeUnretainedValue() as? NSObject
  }

  private func scanObjectIvarsForFileDescriptor(_ object: NSObject) -> Int32? {
    var cls: AnyClass? = type(of: object)
    while let current = cls {
      var count: UInt32 = 0
      guard let ivars = class_copyIvarList(current, &count) else {
        cls = class_getSuperclass(current)
        continue
      }
      defer { free(ivars) }
      for i in 0..<Int(count) {
        let ivar = ivars[i]
        guard let name = ivar_getName(ivar) else { continue }
        let ivarName = String(cString: name)
        guard ivarName.contains("socket") || ivarName.contains("Socket") else { continue }
        if let value = object_getIvar(object, ivar) as? NSObject {
          if let fd = callIntSelector(on: value, selectorName: "fileDescriptor"), fd >= 0 {
            return fd
          }
          if let fd = callIntSelector(on: value, selectorName: "fd"), fd >= 0 {
            return fd
          }
        }
      }
      cls = class_getSuperclass(current)
    }
    return nil
  }

  private func rollbackStartFailure(
    error: Error,
    completionHandler: @escaping (Error?) -> Void
  ) {
    metricsSampler.stop()
    engine.stop()
    monitor?.cancel()
    monitor = nil
    activeSettings = nil
    statusStore.markFailed(error.localizedDescription)
    completionHandler(error)
  }

  /// Counts the IPv4 and IPv6 addresses bound to an interface.
  ///
  /// `v4=0` on the egress interface means the link carries no IPv4 route at
  /// all, so any IPv4 destination fails instantly with EHOSTUNREACH no matter
  /// how healthy the radio is.
  private func describeAddressFamilies(of interfaceName: String) -> String {
    guard !interfaceName.isEmpty else {
      return "interface=unavailable"
    }
    var addressPointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addressPointer) == 0, let first = addressPointer else {
      return "\(interfaceName): getifaddrs failed"
    }
    defer { freeifaddrs(addressPointer) }

    var v4 = 0
    var v6 = 0
    var pointer: UnsafeMutablePointer<ifaddrs>? = first
    while let current = pointer {
      let entry = current.pointee
      if String(cString: entry.ifa_name) == interfaceName,
        let address = entry.ifa_addr
      {
        switch Int32(address.pointee.sa_family) {
        case AF_INET: v4 += 1
        case AF_INET6: v6 += 1
        default: break
        }
      }
      pointer = entry.ifa_next
    }
    return "\(interfaceName): v4=\(v4) v6=\(v6)"
  }

  private func ensurePathMonitor() {
    if monitor != nil {
      return
    }
    monitor = NWPathMonitor(prohibitedInterfaceTypes: [NWInterface.InterfaceType.other])
  }
}

private protocol SecureTunnelEngine {
  func start(config: Data, fd: Int32, fdDetail: String, egressInterface: String) throws
  func stop()
}

private final class XrayTunnelEngine: SecureTunnelEngine {
  private let bridge = XrayTunnelBridge()
  private var tunnelHandle: Int64?

  func start(config: Data, fd: Int32, fdDetail: String, egressInterface: String) throws {
    stop()
    guard !config.isEmpty else {
      throw NSError(
        domain: "XConnect.PacketTunnel",
        code: -10,
        userInfo: [NSLocalizedDescriptionKey: "Missing Xray config for Packet Tunnel"]
      )
    }
    let handle = try bridge.start(
      configData: config, fd: fd, fdDetail: fdDetail, egressInterface: egressInterface)
    tunnelHandle = handle
  }

  func stop() {
    if let handle = tunnelHandle {
      bridge.stop(handle: handle)
      bridge.free(handle: handle)
      tunnelHandle = nil
    }
  }
}

private final class XrayTunnelBridge {
  func start(configData: Data, fd: Int32, fdDetail: String, egressInterface: String) throws -> Int64
  {
    guard fd >= 0 else {
      let summary = summarizeConfig(configData)
      throw NSError(
        domain: "XConnect.PacketTunnel",
        code: -12,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Packet Tunnel handoff failed: system tun fd unavailable (fdDetail=\(fdDetail), egress=\(egressInterface), \(summary))"
        ]
      )
    }
    let json = String(data: configData, encoding: .utf8) ?? "{}"
    return try json.withCString { cstr in
      return try egressInterface.withCString { ifaceCstr in
        let handle = StartXrayTunnelWithFd(cstr, fd, ifaceCstr)
        if handle <= 0 {
          let bridgeError = readBridgeError()
          let summary = summarizeConfig(configData)
          throw NSError(
            domain: "XConnect.PacketTunnel",
            code: -12,
            userInfo: [
              NSLocalizedDescriptionKey:
                "StartXrayTunnelWithFd failed invalid handle (fd=\(fd), fdDetail=\(fdDetail), egress=\(egressInterface), bridgeError=\(bridgeError), \(summary))"
            ]
          )
        }
        return handle
      }
    }
  }

  func stop(handle: Int64) {
    let message = StopXrayTunnel(handle)
    releaseCString(message)
  }

  func free(handle: Int64) {
    let message = FreeXrayTunnel(handle)
    releaseCString(message)
  }

  private func releaseCString(_ ptr: UnsafeMutablePointer<CChar>?) {
    guard let ptr else {
      return
    }
    FreeCString(ptr)
  }

  private func readBridgeError() -> String {
    let ptr = GetLastXrayTunnelError()
    defer { releaseCString(ptr) }
    guard let ptr else {
      return "empty"
    }
    let value = String(cString: ptr).trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? "empty" : value
  }

  private func summarizeConfig(_ data: Data) -> String {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return "configBytes=\(data.count), json=invalid"
    }
    guard let inbounds = root["inbounds"] as? [[String: Any]] else {
      return "configBytes=\(data.count), inbounds=0"
    }
    var tunSummaries: [String] = []
    for inbound in inbounds {
      guard let proto = inbound["protocol"] as? String, proto == "tun" else { continue }
      guard let settings = inbound["settings"] as? [String: Any] else {
        tunSummaries.append("tun(no-settings)")
        continue
      }
      let ifaceName = settings["interfaceName"] as? String ?? "nil"
      let name = settings["name"] as? String ?? "nil"
      let iface = settings["interface"] as? String ?? "nil"
      tunSummaries.append("tun(interfaceName=\(ifaceName),name=\(name),interface=\(iface))")
    }
    if tunSummaries.isEmpty {
      return "configBytes=\(data.count), tunInbounds=0"
    }
    return "configBytes=\(data.count), \(tunSummaries.joined(separator: ";"))"
  }
}

private final class PacketTunnelMetricsSampler {
  private static let resourceSampleInterval: TimeInterval = 10
  private let queue = DispatchQueue(label: "plus.svc.xconnect.PacketTunnel.metrics")
  private let store = PacketTunnelMetricsSnapshotStore()
  private var timer: DispatchSourceTimer?
  private var lastSample: InterfaceCounters?
  private var lastResourceSampleAt: TimeInterval?
  private var cachedCpuPercent: Double?
  private var cachedMemoryBytes: Int64?
  private var cachedGoMemory: GoMemoryStats?

  func start(interfaceName: String?) {
    stop()
    guard let interfaceName = normalizeInterfaceName(interfaceName) else {
      refreshResourceMetricsIfNeeded(force: true, timestamp: Date().timeIntervalSince1970)
      store.write(
        downloadBytesPerSecond: nil,
        uploadBytesPerSecond: nil,
        memoryBytes: cachedMemoryBytes,
        cpuPercent: cachedCpuPercent,
        goMemory: cachedGoMemory
      )
      return
    }

    let initialTimestamp = Date().timeIntervalSince1970
    lastSample = readCounters(interfaceName: interfaceName, timestamp: initialTimestamp)
    refreshResourceMetricsIfNeeded(force: true, timestamp: initialTimestamp)
    store.write(
      downloadBytesPerSecond: 0,
      uploadBytesPerSecond: 0,
      memoryBytes: cachedMemoryBytes,
      cpuPercent: cachedCpuPercent,
      goMemory: cachedGoMemory
    )

    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
    timer.setEventHandler { [weak self] in
      self?.captureSnapshot(interfaceName: interfaceName)
    }
    self.timer = timer
    timer.resume()
  }

  func stop() {
    timer?.setEventHandler {}
    timer?.cancel()
    timer = nil
    lastSample = nil
    lastResourceSampleAt = nil
    cachedCpuPercent = nil
    cachedMemoryBytes = nil
    cachedGoMemory = nil
    store.clear()
  }

  private func captureSnapshot(interfaceName: String) {
    let timestamp = Date().timeIntervalSince1970
    refreshResourceMetricsIfNeeded(timestamp: timestamp)
    guard let current = readCounters(interfaceName: interfaceName, timestamp: timestamp) else {
      store.write(
        downloadBytesPerSecond: nil,
        uploadBytesPerSecond: nil,
        memoryBytes: cachedMemoryBytes,
        cpuPercent: cachedCpuPercent,
        goMemory: cachedGoMemory
      )
      lastSample = nil
      return
    }

    let elapsed = max(timestamp - (lastSample?.timestamp ?? timestamp), 1.0)
    let downloadBytesPerSecond: Int64?
    let uploadBytesPerSecond: Int64?
    if let previous = lastSample {
      let downDelta =
        current.receivedBytes >= previous.receivedBytes
        ? current.receivedBytes - previous.receivedBytes : 0
      let upDelta =
        current.sentBytes >= previous.sentBytes
        ? current.sentBytes - previous.sentBytes : 0
      downloadBytesPerSecond = Int64(Double(downDelta) / elapsed)
      uploadBytesPerSecond = Int64(Double(upDelta) / elapsed)
    } else {
      downloadBytesPerSecond = nil
      uploadBytesPerSecond = nil
    }

    lastSample = current
    store.write(
      downloadBytesPerSecond: downloadBytesPerSecond,
      uploadBytesPerSecond: uploadBytesPerSecond,
      memoryBytes: cachedMemoryBytes,
      cpuPercent: cachedCpuPercent,
      goMemory: cachedGoMemory
    )
  }

  private func normalizeInterfaceName(_ raw: String?) -> String? {
    guard let raw else {
      return nil
    }
    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.range(of: #"^utun[0-9]+$"#, options: .regularExpression) != nil else {
      return nil
    }
    return normalized
  }

  private func readCounters(interfaceName: String, timestamp: TimeInterval) -> InterfaceCounters? {
    var addressPointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addressPointer) == 0, let firstAddress = addressPointer else {
      return nil
    }
    defer { freeifaddrs(addressPointer) }

    var pointer = firstAddress
    while true {
      let address = pointer.pointee
      let name = String(cString: address.ifa_name)
      if name == interfaceName,
        let rawData = address.ifa_data,
        let rawAddress = address.ifa_addr,
        rawAddress.pointee.sa_family == UInt8(AF_LINK)
      {
        let data = rawData.assumingMemoryBound(to: if_data.self).pointee
        return InterfaceCounters(
          receivedBytes: UInt64(data.ifi_ibytes),
          sentBytes: UInt64(data.ifi_obytes),
          timestamp: timestamp
        )
      }

      guard let next = address.ifa_next else {
        break
      }
      pointer = next
    }
    return nil
  }

  private func currentMemoryBytes() -> Int64? {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info_data_t>.size
        / MemoryLayout<
          integer_t
        >.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
      }
    }
    guard result == KERN_SUCCESS else {
      return nil
    }
    return Int64(info.resident_size)
  }

  private func currentCpuPercent() -> Double? {
    var threadList: thread_act_array_t?
    var threadCount: mach_msg_type_number_t = 0
    let result = task_threads(mach_task_self_, &threadList, &threadCount)
    guard result == KERN_SUCCESS, let threadList else {
      return nil
    }
    defer {
      let size = vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
      vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threadList), size)
    }

    var totalUsage = 0.0
    for index in 0..<Int(threadCount) {
      var info = thread_basic_info()
      var count = mach_msg_type_number_t(
        MemoryLayout<thread_basic_info_data_t>.size
          / MemoryLayout<
            integer_t
          >.size)
      let infoResult = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
          thread_info(threadList[index], thread_flavor_t(THREAD_BASIC_INFO), rebound, &count)
        }
      }
      guard infoResult == KERN_SUCCESS else {
        continue
      }
      if (info.flags & TH_FLAGS_IDLE) == 0 {
        totalUsage += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
      }
    }

    return min(totalUsage, 100.0)
  }

  private func refreshResourceMetricsIfNeeded(force: Bool = false, timestamp: TimeInterval) {
    let shouldRefresh: Bool
    if force {
      shouldRefresh = true
    } else if let lastResourceSampleAt {
      shouldRefresh = (timestamp - lastResourceSampleAt) >= Self.resourceSampleInterval
    } else {
      shouldRefresh = true
    }
    guard shouldRefresh else {
      return
    }
    cachedCpuPercent = currentCpuPercent()
    cachedMemoryBytes = currentMemoryBytes()
    cachedGoMemory = readGoMemoryStats()
    lastResourceSampleAt = timestamp
  }

  /// Splits the process footprint into the Go runtime's share and everything
  /// else, so footprint work can target whichever actually dominates instead
  /// of guessing from resident size alone.
  private func readGoMemoryStats() -> GoMemoryStats? {
    guard let raw = XrayTunnelMemoryStats() else {
      return nil
    }
    defer { FreeCString(raw) }
    let json = String(cString: raw)
    guard
      let data = json.data(using: .utf8),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }
    func number(_ key: String) -> Int64? {
      (root[key] as? NSNumber)?.int64Value
    }
    guard let heapInUse = number("heapInUse"), let sys = number("sys") else {
      return nil
    }
    return GoMemoryStats(
      heapInUseBytes: heapInUse,
      heapIdleBytes: number("heapIdle") ?? 0,
      heapReleasedBytes: number("heapReleased") ?? 0,
      sysBytes: sys,
      numGC: number("numGC") ?? 0,
      goroutines: number("goroutines") ?? 0
    )
  }

  private struct InterfaceCounters {
    let receivedBytes: UInt64
    let sentBytes: UInt64
    let timestamp: TimeInterval
  }

}

private struct GoMemoryStats {
  let heapInUseBytes: Int64
  let heapIdleBytes: Int64
  let heapReleasedBytes: Int64
  let sysBytes: Int64
  let numGC: Int64
  let goroutines: Int64
}

private final class PacketTunnelMetricsSnapshotStore {
  private let defaults = UserDefaults(suiteName: "group.plus.svc.xconnect") ?? .standard
  private let snapshotKey = "packet_tunnel_metrics_snapshot"

  func write(
    downloadBytesPerSecond: Int64?,
    uploadBytesPerSecond: Int64?,
    memoryBytes: Int64?,
    cpuPercent: Double?,
    goMemory: GoMemoryStats? = nil
  ) {
    var snapshot: [String: Any] = [
      "updatedAt": Int64(Date().timeIntervalSince1970 * 1000)
    ]
    if let goMemory {
      snapshot["goHeapInUseBytes"] = NSNumber(value: goMemory.heapInUseBytes)
      snapshot["goHeapIdleBytes"] = NSNumber(value: goMemory.heapIdleBytes)
      snapshot["goHeapReleasedBytes"] = NSNumber(value: goMemory.heapReleasedBytes)
      snapshot["goSysBytes"] = NSNumber(value: goMemory.sysBytes)
      snapshot["goNumGC"] = NSNumber(value: goMemory.numGC)
      snapshot["goGoroutines"] = NSNumber(value: goMemory.goroutines)
    }
    if let downloadBytesPerSecond {
      snapshot["downloadBytesPerSecond"] = NSNumber(value: downloadBytesPerSecond)
    }
    if let uploadBytesPerSecond {
      snapshot["uploadBytesPerSecond"] = NSNumber(value: uploadBytesPerSecond)
    }
    if let memoryBytes {
      snapshot["memoryBytes"] = NSNumber(value: memoryBytes)
    }
    if let cpuPercent {
      snapshot["cpuPercent"] = NSNumber(value: cpuPercent)
    }
    defaults.set(snapshot, forKey: snapshotKey)
  }

  func clear() {
    defaults.removeObject(forKey: snapshotKey)
  }
}

private final class PacketTunnelStatusStore {
  private let defaults = UserDefaults(suiteName: "group.plus.svc.xconnect") ?? .standard
  private let errorKey = "packet_tunnel_last_error"
  private let startedAtKey = "packet_tunnel_started_at"
  private let egressKey = "packet_tunnel_egress_info"

  func recordEgress(interfaceName: String, families: String) {
    defaults.set(
      [
        "interface": interfaceName,
        "families": families,
        "at": Int64(Date().timeIntervalSince1970),
      ],
      forKey: egressKey
    )
  }

  func markConnected() {
    defaults.removeObject(forKey: errorKey)
    defaults.set(Int64(Date().timeIntervalSince1970), forKey: startedAtKey)
  }

  func markFailed(_ error: String) {
    defaults.set(error, forKey: errorKey)
  }

  func markDisconnected(reason: NEProviderStopReason) {
    let hadConnectedSession = defaults.object(forKey: startedAtKey) != nil
    defaults.removeObject(forKey: startedAtKey)
    let reasonText = describe(reason)
    let shouldKeepAsFailure = isFailureReason(reason)
    if shouldKeepAsFailure {
      defaults.set(
        "Packet Tunnel stopped (reason=\(reasonText), hadConnectedSession=\(hadConnectedSession))",
        forKey: errorKey
      )
      return
    }
    if hadConnectedSession {
      defaults.removeObject(forKey: errorKey)
      return
    }
    if defaults.string(forKey: errorKey)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ?? true
    {
      defaults.set(
        "Packet Tunnel stopped before connected (reason=\(reasonText))", forKey: errorKey)
    }
  }

  private func describe(_ reason: NEProviderStopReason) -> String {
    switch reason {
    case .none:
      return "none"
    case .userInitiated:
      return "userInitiated"
    case .providerFailed:
      return "providerFailed"
    case .noNetworkAvailable:
      return "noNetworkAvailable"
    case .unrecoverableNetworkChange:
      return "unrecoverableNetworkChange"
    case .providerDisabled:
      return "providerDisabled"
    case .authenticationCanceled:
      return "authenticationCanceled"
    case .configurationFailed:
      return "configurationFailed"
    case .idleTimeout:
      return "idleTimeout"
    case .configurationDisabled:
      return "configurationDisabled"
    case .configurationRemoved:
      return "configurationRemoved"
    case .superceded:
      return "superceded"
    case .userLogout:
      return "userLogout"
    case .userSwitch:
      return "userSwitch"
    case .connectionFailed:
      return "connectionFailed"
    case .sleep:
      return "sleep"
    case .appUpdate:
      return "appUpdate"
    @unknown default:
      return "unknown-\(reason.rawValue)"
    }
  }

  private func isFailureReason(_ reason: NEProviderStopReason) -> Bool {
    switch reason {
    case .providerFailed, .noNetworkAvailable, .unrecoverableNetworkChange, .configurationFailed,
      .connectionFailed:
      return true
    default:
      return false
    }
  }
}
