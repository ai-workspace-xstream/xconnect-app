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

/// Severity shared by tiles, path segments and the verdict line.
enum DiagLevel { none, good, warn, bad }

DiagLevel _levelFor(
  int? latencyMs,
  double? lossRate, {
  required int latencyWarn,
  required int latencyBad,
}) {
  if (latencyMs == null && lossRate == null) return DiagLevel.none;
  final loss = lossRate ?? 0;
  final latency = latencyMs ?? 0;
  if (loss >= 0.05 || latency >= latencyBad) return DiagLevel.bad;
  if (loss >= 0.02 || latency >= latencyWarn) return DiagLevel.warn;
  return DiagLevel.good;
}

DiagLevel latencyLevel(int? ms) => ms == null
    ? DiagLevel.none
    : _levelFor(ms, null, latencyWarn: 150, latencyBad: 300);

DiagLevel lossLevel(double? rate) => rate == null
    ? DiagLevel.none
    : _levelFor(null, rate, latencyWarn: 150, latencyBad: 300);

enum SegmentState { measured, warmingUp, unmeasurable, unknown }

enum Culprit { none, local, upstream }

class SegmentReading {
  const SegmentReading({
    required this.state,
    this.latencyMs,
    this.lossRate,
    this.level = DiagLevel.none,
  });

  final SegmentState state;
  final int? latencyMs;
  final double? lossRate;
  final DiagLevel level;
}

class PathAttribution {
  const PathAttribution({
    required this.local,
    required this.upstream,
    required this.culprit,
  });

  /// Device → router.
  final SegmentReading local;

  /// Router → node, or device → node when the router hop is not measured.
  final SegmentReading upstream;
  final Culprit culprit;
}

/// Splits the end-to-end reading into the LAN hop and everything past it.
///
/// Loss and latency on the node probe include the LAN hop, so the upstream
/// share is the difference. The segment nearest the device that is bad (or
/// failing that, warn) is blamed, since trouble there shows up everywhere
/// downstream too.
PathAttribution attributePath({
  required SegmentStats? local,
  required SegmentStats node,
  bool localUnmeasurable = false,
}) {
  final warming = node.warmingUp || (local?.warmingUp ?? false);
  SegmentReading whole(SegmentState state) => SegmentReading(
        state: state,
        latencyMs: node.latencyMs,
        lossRate: node.lossRate,
        level: state == SegmentState.measured
            ? _levelFor(node.latencyMs, node.lossRate,
                latencyWarn: 150, latencyBad: 300)
            : DiagLevel.none,
      );

  if (local == null) {
    final upstream =
        whole(warming ? SegmentState.warmingUp : SegmentState.measured);
    return PathAttribution(
      local: SegmentReading(
        state: localUnmeasurable
            ? SegmentState.unmeasurable
            : SegmentState.unknown,
      ),
      upstream: upstream,
      culprit: !warming && upstream.level == DiagLevel.bad
          ? Culprit.upstream
          : Culprit.none,
    );
  }

  if (warming) {
    return const PathAttribution(
      local: SegmentReading(state: SegmentState.warmingUp),
      upstream: SegmentReading(state: SegmentState.warmingUp),
      culprit: Culprit.none,
    );
  }

  final localLevel = _levelFor(local.latencyMs, local.lossRate,
      latencyWarn: 20, latencyBad: 50);
  final upLatency = node.latencyMs == null
      ? null
      : (node.latencyMs! - (local.latencyMs ?? 0)).clamp(0, 1 << 30);
  final upLoss = (node.lossRate - local.lossRate).clamp(0.0, 1.0);
  final upLevel =
      _levelFor(upLatency, upLoss, latencyWarn: 150, latencyBad: 300);

  final Culprit culprit;
  if (localLevel == DiagLevel.bad) {
    culprit = Culprit.local;
  } else if (upLevel == DiagLevel.bad) {
    culprit = Culprit.upstream;
  } else if (localLevel == DiagLevel.warn) {
    culprit = Culprit.local;
  } else if (upLevel == DiagLevel.warn) {
    culprit = Culprit.upstream;
  } else {
    culprit = Culprit.none;
  }

  return PathAttribution(
    local: SegmentReading(
      state: SegmentState.measured,
      latencyMs: local.latencyMs,
      lossRate: local.lossRate,
      level: localLevel,
    ),
    upstream: SegmentReading(
      state: SegmentState.measured,
      latencyMs: upLatency,
      lossRate: upLoss,
      level: upLevel,
    ),
    culprit: culprit,
  );
}

/// Whether [gateway] is plausibly the router on the physical network.
///
/// With another tunnel up, "the default gateway" can come back as the
/// tunnel's peer; requiring the same /16 as the physical address keeps the
/// router hop honest.
bool acceptGateway(String? gateway, {required String? physical}) {
  if (gateway == null || physical == null || gateway == physical) {
    return false;
  }
  final g = gateway.split('.');
  final p = physical.split('.');
  if (g.length != 4 || p.length != 4) return false;
  return g[0] == p[0] && g[1] == p[1];
}
