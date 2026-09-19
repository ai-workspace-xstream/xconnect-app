import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:network_info_plus/network_info_plus.dart';

import '../../utils/global_config.dart' show GlobalState;
import '../vpn_config_service.dart';
import 'live_metrics.dart';

enum DiagNetworkType { wifi, ethernet, cellular, none, other, unknown }

typedef TcpProbe = Future<ProbeSample> Function(
  String host,
  int port, {
  String? sourceAddress,
});

typedef NodeEndpointReader = Future<({String? name, ServerEndpoint? endpoint})>
    Function();

class LiveDiagnosisSnapshot {
  const LiveDiagnosisSnapshot({
    this.running = false,
    this.startedAt,
    this.elapsed = Duration.zero,
    this.nodeName,
    this.endpoint,
    this.stats = SegmentStats.empty,
    this.networkType = DiagNetworkType.unknown,
    this.tunConflict = false,
    this.noEndpoint = false,
    this.noPhysicalInterface = false,
    this.autoStopped = false,
    this.gateway,
    this.localStats,
    this.localUnmeasurable = false,
  });

  final bool running;
  final DateTime? startedAt;
  final Duration elapsed;
  final String? nodeName;
  final ServerEndpoint? endpoint;
  final SegmentStats stats;
  final DiagNetworkType networkType;
  final bool tunConflict;
  final bool noEndpoint;
  final bool noPhysicalInterface;
  final bool autoStopped;

  /// Router on the physical network, when one was found and accepted.
  final String? gateway;

  /// Device → router samples; null when the router hop is not measured.
  final SegmentStats? localStats;

  /// A router was found but answered on none of the probe ports.
  final bool localUnmeasurable;

  LiveVerdict get verdict => liveVerdict(stats, tunConflict: tunConflict);

  PathAttribution get path => attributePath(
        local: localStats,
        node: stats,
        localUnmeasurable: localUnmeasurable,
      );
}

/// Runs the live latency / loss measurement behind Settings → Diagnostics.
///
/// Store-compliant by construction: plain TCP connects only (no ICMP, no
/// subprocesses), one probe per second, results kept in memory, and the
/// session stops after [maxDuration] or when the owner disposes it.
class LiveDiagnosisController extends ChangeNotifier {
  LiveDiagnosisController({
    NodeEndpointReader? endpoint,
    Future<String?> Function()? gateway,
    Future<String?> Function()? physicalAddress,
    Future<DiagNetworkType> Function()? networkType,
    TcpProbe? probe,
    DateTime Function()? now,
    this.interval = const Duration(seconds: 1),
    this.maxDuration = const Duration(minutes: 5),
    bool startTimer = true,
  })  : _endpoint = endpoint ?? readActiveNodeEndpoint,
        _gateway = gateway ?? readGateway,
        _physicalAddress = physicalAddress ?? readPhysicalIPv4,
        _networkType = networkType ?? readNetworkType,
        _probe = probe ?? tcpConnectProbe,
        _now = now ?? DateTime.now,
        _startTimer = startTimer;

  /// RFC 5737 TEST-NET-1: nothing on the internet answers here, so a connect
  /// that succeeds was answered by a local TUN stack.
  static const canaryHost = '192.0.2.1';

  /// Ports tried on the router, in order. RST counts as an answer, so any
  /// router that rejects rather than drops SYNs is measurable.
  static const routerPorts = <int>[53, 80, 443];

  final NodeEndpointReader _endpoint;
  final Future<String?> Function() _gateway;
  final Future<String?> Function() _physicalAddress;
  final Future<DiagNetworkType> Function() _networkType;
  final TcpProbe _probe;
  final DateTime Function() _now;
  final bool _startTimer;
  final Duration interval;
  final Duration maxDuration;

  final SegmentWindow _window = SegmentWindow();
  final SegmentWindow _localWindow = SegmentWindow();
  int? _routerPort;
  LiveDiagnosisSnapshot _snapshot = const LiveDiagnosisSnapshot();
  String? _source;
  Timer? _timer;
  bool _inFlight = false;
  bool _disposed = false;

  LiveDiagnosisSnapshot get snapshot => _snapshot;

  Future<void> start() async {
    stop();
    _window.clear();
    _localWindow.clear();
    _routerPort = null;
    final startedAt = _now();
    final node = await _endpoint();
    _source = await _physicalAddress();
    final networkType = await _networkType();
    final canary = await _probe(canaryHost, 443);
    final rawGateway = await _gateway();
    final gateway =
        acceptGateway(rawGateway, physical: _source) ? rawGateway : null;
    var localUnmeasurable = false;
    if (gateway != null && node.endpoint != null) {
      for (final port in routerPorts) {
        final sample = await _probe(gateway, port, sourceAddress: _source);
        if (sample.answered) {
          _routerPort = port;
          _localWindow.add(sample);
          break;
        }
      }
      localUnmeasurable = _routerPort == null;
    }

    _snapshot = LiveDiagnosisSnapshot(
      running: node.endpoint != null,
      startedAt: startedAt,
      nodeName: node.name,
      endpoint: node.endpoint,
      networkType: networkType,
      tunConflict: canary.answered,
      noEndpoint: node.endpoint == null,
      noPhysicalInterface: _source == null,
      gateway: gateway,
      localStats: _routerPort == null ? null : _localWindow.stats,
      localUnmeasurable: localUnmeasurable,
    );
    _notify();
    if (node.endpoint == null) return;

    await tick();
    if (_startTimer && _snapshot.running) {
      _timer = Timer.periodic(interval, (_) => tick());
    }
  }

  /// One sampling round. Public so tests can drive it without timers.
  Future<void> tick() async {
    final endpoint = _snapshot.endpoint;
    if (!_snapshot.running || endpoint == null || _inFlight) return;
    final elapsed = _now().difference(_snapshot.startedAt!);
    if (elapsed > maxDuration) {
      _finish(autoStopped: true);
      return;
    }
    _inFlight = true;
    try {
      final gateway = _snapshot.gateway;
      final routerPort = _routerPort;
      if (gateway != null && routerPort != null) {
        _localWindow.add(
          await _probe(gateway, routerPort, sourceAddress: _source),
        );
      }
      _window.add(
        await _probe(endpoint.host, endpoint.port, sourceAddress: _source),
      );
    } finally {
      _inFlight = false;
    }
    if (!_snapshot.running) return;
    _snapshot = _copy(
      elapsed: elapsed,
      stats: _window.stats,
      localStats: _routerPort == null ? null : _localWindow.stats,
    );
    _notify();
  }

  void stop() {
    if (!_snapshot.running) return;
    _finish(autoStopped: false);
  }

  void _finish({required bool autoStopped}) {
    _timer?.cancel();
    _timer = null;
    _snapshot = _copy(running: false, autoStopped: autoStopped);
    _notify();
  }

  LiveDiagnosisSnapshot _copy({
    bool? running,
    Duration? elapsed,
    SegmentStats? stats,
    SegmentStats? localStats,
    bool? autoStopped,
  }) {
    final s = _snapshot;
    return LiveDiagnosisSnapshot(
      running: running ?? s.running,
      startedAt: s.startedAt,
      elapsed: elapsed ?? s.elapsed,
      nodeName: s.nodeName,
      endpoint: s.endpoint,
      stats: stats ?? s.stats,
      networkType: s.networkType,
      tunConflict: s.tunConflict,
      noEndpoint: s.noEndpoint,
      noPhysicalInterface: s.noPhysicalInterface,
      autoStopped: autoStopped ?? s.autoStopped,
      gateway: s.gateway,
      localStats: localStats ?? s.localStats,
      localUnmeasurable: s.localUnmeasurable,
    );
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

const _refusedErrnos = <int>{61, 111, 10061};
const _probeTimeout = Duration(seconds: 3);

/// TCP connect used as a store-safe stand-in for ping: the time to SYN-ACK
/// (or RST) is the RTT, and a timeout is a lost probe.
Future<ProbeSample> tcpConnectProbe(
  String host,
  int port, {
  String? sourceAddress,
}) async {
  final watch = Stopwatch()..start();
  try {
    final socket = await Socket.connect(
      host,
      port,
      sourceAddress: sourceAddress,
      timeout: _probeTimeout,
    );
    watch.stop();
    socket.destroy();
    return ProbeSample.reached(watch.elapsed);
  } on SocketException catch (e) {
    watch.stop();
    final errno = e.osError?.errorCode;
    if (errno != null && _refusedErrnos.contains(errno)) {
      return ProbeSample.refused(watch.elapsed);
    }
    if (e.message.contains('timed out') || watch.elapsed >= _probeTimeout) {
      return const ProbeSample.timedOut();
    }
    return const ProbeSample.unavailable();
  } on TimeoutException {
    return const ProbeSample.timedOut();
  }
}

Future<String?> readPhysicalIPv4() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  );
  return pickPhysicalIPv4([
    for (final iface in interfaces)
      for (final addr in iface.addresses)
        (name: iface.name, address: addr.address),
  ]);
}

Future<DiagNetworkType> readNetworkType() async {
  try {
    final results = await Connectivity().checkConnectivity();
    if (results.contains(ConnectivityResult.wifi)) return DiagNetworkType.wifi;
    if (results.contains(ConnectivityResult.ethernet)) {
      return DiagNetworkType.ethernet;
    }
    if (results.contains(ConnectivityResult.mobile)) {
      return DiagNetworkType.cellular;
    }
    if (results.contains(ConnectivityResult.none)) return DiagNetworkType.none;
    return DiagNetworkType.other;
  } catch (_) {
    return DiagNetworkType.unknown;
  }
}

/// The server of the active node, falling back to the first saved node.
Future<({String? name, ServerEndpoint? endpoint})>
    readActiveNodeEndpoint() async {
  final active = GlobalState.activeNodeName.value;
  final node = (active.isNotEmpty ? VpnConfig.getNodeByName(active) : null) ??
      (VpnConfig.nodes.isNotEmpty ? VpnConfig.nodes.first : null);
  if (node == null) return (name: null, endpoint: null);
  try {
    final json = jsonDecode(await File(node.configPath).readAsString());
    if (json is! Map<String, dynamic>) return (name: node.name, endpoint: null);
    return (name: node.name, endpoint: outboundServerEndpoint(json));
  } catch (_) {
    return (name: node.name, endpoint: null);
  }
}

/// The router's IPv4 address, from the OS where the plugin supports it and
/// from the kernel routing table on Linux.
Future<String?> readGateway() async {
  try {
    final gateway = await NetworkInfo().getWifiGatewayIP();
    if (gateway != null && gateway.isNotEmpty && gateway != '0.0.0.0') {
      return gateway;
    }
  } catch (_) {}
  if (Platform.isLinux) {
    try {
      return parseLinuxDefaultGateway(
        await File('/proc/net/route').readAsString(),
      );
    } catch (_) {}
  }
  return null;
}

/// Default route gateway from `/proc/net/route` (little-endian hex).
String? parseLinuxDefaultGateway(String table) {
  for (final line in table.split('\n').skip(1)) {
    final cols = line.trim().split(RegExp(r'\s+'));
    if (cols.length < 3 || cols[1] != '00000000') continue;
    final iface = cols[0];
    if (_isTunnelName(iface)) continue;
    final hex = cols[2];
    if (hex.length != 8 || hex == '00000000') continue;
    final bytes = [
      for (var i = 6; i >= 0; i -= 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];
    return bytes.join('.');
  }
  return null;
}

bool _isTunnelName(String name) =>
    pickPhysicalIPv4([(name: name, address: '10.0.0.1')]) == null;
