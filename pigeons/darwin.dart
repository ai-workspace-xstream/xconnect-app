import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/app/darwin_host_api.g.dart',
    dartOptions: DartOptions(),
    swiftOut: 'darwin/Messages.g.swift',
    swiftOptions: SwiftOptions(),
  ),
)
class TunnelRouteV4 {
  TunnelRouteV4({
    required this.destinationAddress,
    required this.subnetMask,
  });

  String destinationAddress;
  String subnetMask;
}

class TunnelRouteV6 {
  TunnelRouteV6({
    required this.destinationAddress,
    required this.networkPrefixLength,
  });

  String destinationAddress;
  int networkPrefixLength;
}

class TunnelProfile {
  TunnelProfile({
    required this.mtu,
    required this.tun46Setting,
    required this.defaultNicSupport6,
    required this.dnsServers4,
    required this.dnsServers6,
    required this.ipv4Addresses,
    required this.ipv4SubnetMasks,
    required this.ipv4IncludedRoutes,
    required this.ipv4ExcludedRoutes,
    required this.ipv6Addresses,
    required this.ipv6NetworkPrefixLengths,
    required this.ipv6IncludedRoutes,
    required this.ipv6ExcludedRoutes,
    required this.configPath,
    this.nodeId,
    this.goMemoryLimitMB,
    this.goGCPercent,
  });

  int mtu;
  int tun46Setting;
  bool defaultNicSupport6;
  List<String> dnsServers4;
  List<String> dnsServers6;
  List<String> ipv4Addresses;
  List<String> ipv4SubnetMasks;
  List<TunnelRouteV4> ipv4IncludedRoutes;
  List<TunnelRouteV4> ipv4ExcludedRoutes;
  List<String> ipv6Addresses;
  List<int> ipv6NetworkPrefixLengths;
  List<TunnelRouteV6> ipv6IncludedRoutes;
  List<TunnelRouteV6> ipv6ExcludedRoutes;
  String configPath;

  /// Server node ID of the profile, so a later tuning change can refresh the
  /// persisted profile without guessing the node from a file path.
  String? nodeId;

  /// Go runtime tuning for the Packet Tunnel; null keeps the built-in default.
  /// A memory limit of 0 removes the Go soft limit.
  int? goMemoryLimitMB;
  int? goGCPercent;
}

/// The persisted Packet Tunnel profile, as the system will relaunch it.
class SavedTunnelProfile {
  SavedTunnelProfile({required this.configPath, this.nodeId});

  String configPath;
  String? nodeId;
}

/// Runtime tuning to write into the persisted Packet Tunnel profile.
class TunnelRuntimeTuning {
  TunnelRuntimeTuning({this.goMemoryLimitMB, this.goGCPercent});

  int? goMemoryLimitMB;
  int? goGCPercent;
}

class TunnelStatus {
  TunnelStatus({
    required this.state,
    required this.lastError,
    required this.utunInterfaces,
    required this.startedAt,
  });

  String state;
  String? lastError;
  List<String> utunInterfaces;
  int? startedAt;
}

class TunnelMetricsSnapshot {
  TunnelMetricsSnapshot({
    this.downloadBytesPerSecond,
    this.uploadBytesPerSecond,
    this.memoryBytes,
    this.cpuPercent,
    this.updatedAt,
    this.footprintBytes,
    this.peakFootprintBytes,
    this.goHeapInUseBytes,
    this.goHeapIdleBytes,
    this.goHeapReleasedBytes,
    this.goSysBytes,
    this.goNumGC,
    this.goGoroutines,
    this.goMemoryLimitBytes,
    this.goGCPercent,
  });

  int? downloadBytesPerSecond;
  int? uploadBytesPerSecond;
  int? memoryBytes;
  double? cpuPercent;
  int? updatedAt;

  /// Physical footprint and its peak, the figures jetsam enforces.
  int? footprintBytes;
  int? peakFootprintBytes;

  /// Go runtime share of the process and the pacing in effect.
  int? goHeapInUseBytes;
  int? goHeapIdleBytes;
  int? goHeapReleasedBytes;
  int? goSysBytes;
  int? goNumGC;
  int? goGoroutines;
  int? goMemoryLimitBytes;
  int? goGCPercent;
}

@HostApi()
abstract class DarwinHostApi {
  String appGroupPath();

  @async
  void startXApiServer(Uint8List config);

  @async
  void redirectStdErr(String path);

  Uint8List generateTls();

  void setupShutdownNotification();

  @async
  String savePacketTunnelProfile(TunnelProfile profile);

  @async
  void startPacketTunnel();

  @async
  void stopPacketTunnel();

  @async
  TunnelStatus getPacketTunnelStatus();

  @async
  TunnelMetricsSnapshot getPacketTunnelMetrics();

  /// The persisted profile, or null when none has been saved.
  @async
  SavedTunnelProfile? savedPacketTunnelProfile();

  /// Reloads the persisted profile's config file and writes [tuning] into it,
  /// so an automatic relaunch uses current values. Never creates a new VPN
  /// configuration.
  @async
  String refreshPacketTunnelProfile(TunnelRuntimeTuning tuning);
}

@FlutterApi()
abstract class DarwinFlutterApi {
  void onSystemWillShutdown();

  void onSystemWillRestart();

  void onSystemWillSleep();

  void onPacketTunnelStateChanged(TunnelStatus status);

  void onPacketTunnelError(String code, String message);
}
