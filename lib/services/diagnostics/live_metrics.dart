import 'dart:collection';

/// How one TCP-connect probe ended.
enum ProbeOutcome { reached, refused, timedOut, unavailable }

class ProbeSample {
  const ProbeSample.reached(Duration this.rtt) : outcome = ProbeOutcome.reached;

  /// RST / ECONNREFUSED: the host answered, so the path works.
  const ProbeSample.refused(Duration this.rtt) : outcome = ProbeOutcome.refused;

  const ProbeSample.timedOut()
      : outcome = ProbeOutcome.timedOut,
        rtt = null;

  /// Network unreachable and similar: the segment is down, which is not loss.
  const ProbeSample.unavailable()
      : outcome = ProbeOutcome.unavailable,
        rtt = null;

  final ProbeOutcome outcome;
  final Duration? rtt;

  bool get answered =>
      outcome == ProbeOutcome.reached || outcome == ProbeOutcome.refused;
}

class SegmentStats {
  const SegmentStats({
    required this.sampleCount,
    required this.latencyMs,
    required this.lossRate,
    required this.retransmitRate,
    required this.jitterMs,
    required this.warmingUp,
  });

  static const empty = SegmentStats(
    sampleCount: 0,
    latencyMs: null,
    lossRate: 0,
    retransmitRate: 0,
    jitterMs: 0,
    warmingUp: true,
  );

  final int sampleCount;
  final int? latencyMs;
  final double lossRate;

  /// Share of successful connects that took long enough to imply a SYN
  /// retransmission — an estimate, not a kernel counter.
  final double retransmitRate;
  final int jitterMs;
  final bool warmingUp;
}

/// Sliding window of the most recent probe samples for one segment.
class SegmentWindow {
  SegmentWindow({this.capacity = 30});

  static const _warmUpSamples = 5;
  static const _latencySamples = 5;

  /// SYN retransmission adds at least ~1s (initial RTO); 800ms of slack keeps
  /// ordinary jitter from being counted.
  static const _retransmitSlackMs = 800;

  final int capacity;
  final Queue<ProbeSample> _samples = Queue<ProbeSample>();

  void add(ProbeSample sample) {
    if (sample.outcome == ProbeOutcome.unavailable) return;
    _samples.addLast(sample);
    while (_samples.length > capacity) {
      _samples.removeFirst();
    }
  }

  void clear() => _samples.clear();

  SegmentStats get stats {
    if (_samples.isEmpty) return SegmentStats.empty;
    final rtts = [
      for (final s in _samples)
        if (s.answered) s.rtt!.inMilliseconds,
    ];
    final lost = _samples.where((s) => s.outcome == ProbeOutcome.timedOut);

    int? latency;
    var retransmits = 0;
    var jitter = 0;
    if (rtts.isNotEmpty) {
      latency = _median(rtts.sublist(
        rtts.length > _latencySamples ? rtts.length - _latencySamples : 0,
      ));
      final baseline = _median(rtts);
      retransmits =
          rtts.where((ms) => ms >= baseline + _retransmitSlackMs).length;
      if (rtts.length > 1) {
        var total = 0;
        for (var i = 1; i < rtts.length; i++) {
          total += (rtts[i] - rtts[i - 1]).abs();
        }
        jitter = (total / (rtts.length - 1)).round();
      }
    }

    return SegmentStats(
      sampleCount: _samples.length,
      latencyMs: latency,
      lossRate: lost.length / _samples.length,
      retransmitRate: rtts.isEmpty ? 0 : retransmits / rtts.length,
      jitterMs: jitter,
      warmingUp: _samples.length < _warmUpSamples,
    );
  }

  static int _median(List<int> values) {
    final sorted = [...values]..sort();
    return sorted[sorted.length ~/ 2];
  }
}

typedef InterfaceAddress = ({String name, String address});

const _tunnelInterfacePrefixes = <String>[
  'utun',
  'tun',
  'tap',
  'wg',
  'ipsec',
  'ppp',
  'gif',
  'stf',
  'llw',
  'awdl',
  'bridge',
];

/// Picks the IPv4 address of a physical interface to bind probes to.
///
/// Any running TUN — ours or another accelerator's — completes TCP handshakes
/// locally, so an unbound probe reports ~0ms for every host. Binding to the
/// physical interface's address makes the probe take the real path.
String? pickPhysicalIPv4(List<InterfaceAddress> interfaces) {
  for (final iface in interfaces) {
    final name = iface.name.toLowerCase();
    if (name.startsWith('lo')) continue;
    if (_tunnelInterfacePrefixes.any(name.startsWith)) continue;
    if (iface.address.startsWith('169.254.')) continue;
    return iface.address;
  }
  return null;
}

const _dialingProtocols = <String>{
  'vless',
  'vmess',
  'trojan',
  'shadowsocks',
  'socks',
  'http',
};

typedef ServerEndpoint = ({String host, int port});

/// The first server a dialing outbound connects to, from an Xray config.
ServerEndpoint? outboundServerEndpoint(Map<String, dynamic> config) {
  final outbounds = config['outbounds'];
  if (outbounds is! List) return null;
  for (final outbound in outbounds) {
    if (outbound is! Map) continue;
    if (!_dialingProtocols.contains(outbound['protocol'])) continue;
    final settings = outbound['settings'];
    if (settings is! Map) continue;
    for (final key in const ['vnext', 'servers']) {
      final entries = settings[key];
      if (entries is! List) continue;
      for (final entry in entries) {
        if (entry is! Map) continue;
        final host = entry['address'];
        final port = entry['port'];
        if (host is String && host.trim().isNotEmpty && port is int) {
          return (host: host.trim(), port: port);
        }
      }
    }
  }
  return null;
}

enum LiveVerdict { sampling, good, slow, unstable, unreachable, tunConflict }

LiveVerdict liveVerdict(SegmentStats stats, {required bool tunConflict}) {
  if (tunConflict) return LiveVerdict.tunConflict;
  if (stats.warmingUp) return LiveVerdict.sampling;
  if (stats.lossRate >= 1) return LiveVerdict.unreachable;
  if (stats.lossRate >= 0.05) return LiveVerdict.unstable;
  final latency = stats.latencyMs;
  if (latency != null && latency >= 300) return LiveVerdict.slow;
  return LiveVerdict.good;
}
