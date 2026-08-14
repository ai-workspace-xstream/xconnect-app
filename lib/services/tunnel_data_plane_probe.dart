import 'dart:async';
import 'dart:io';

/// Why a data-plane verification ended the way it did.
enum TunnelDataPlaneOutcome {
  /// DNS resolved and a TCP session was established through the tunnel.
  reachable,

  /// Routing works (a raw IP target accepted a TCP session) but name
  /// resolution never succeeded.
  dnsUnreachable,

  /// Neither name resolution nor a raw IP target could be reached.
  transportUnreachable,

  /// The tunnel left the connected state while the probe was running, so the
  /// probe result says nothing about data-plane health.
  tunnelDropped,

  /// The app was suspended mid-probe, so wall-clock time ran on while the
  /// probe made no progress. The budget was never actually spent testing, and
  /// whatever the network was doing on resume is minutes removed from the
  /// samples that were taken.
  suspended,
}

/// Outcome of a data-plane verification, including enough detail to tell a
/// broken tunnel apart from a tunnel that simply had not settled yet.
class TunnelDataPlaneReport {
  const TunnelDataPlaneReport({
    required this.outcome,
    required this.attempts,
    required this.elapsed,
    this.tunnelState,
    this.dnsError,
    this.transportError,
  });

  final TunnelDataPlaneOutcome outcome;
  final int attempts;
  final Duration elapsed;

  /// Tunnel state observed when the probe stopped early.
  final String? tunnelState;
  final String? dnsError;
  final String? transportError;

  bool get ok => outcome == TunnelDataPlaneOutcome.reachable;

  /// Whether the caller should treat this as evidence the tunnel is broken.
  ///
  /// A dropped tunnel or a suspended app is inconclusive: the probe never got
  /// a fair chance, so callers must not report either as a data-plane failure.
  bool get isConclusiveFailure =>
      outcome == TunnelDataPlaneOutcome.dnsUnreachable ||
      outcome == TunnelDataPlaneOutcome.transportUnreachable;

  String describe() {
    final seconds = (elapsed.inMilliseconds / 1000).toStringAsFixed(1);
    switch (outcome) {
      case TunnelDataPlaneOutcome.reachable:
        return '外网可达 ($attempts次探测, ${seconds}s)';
      case TunnelDataPlaneOutcome.dnsUnreachable:
        return '隧道已连接但 DNS 解析失败 ($attempts次探测, ${seconds}s): '
            '${dnsError ?? "无详情"}';
      case TunnelDataPlaneOutcome.transportUnreachable:
        // Nothing routed at all -- neither a resolved address nor a raw IP.
        // With DNS routed through the proxy outbound, both legs exercise the
        // same path, so this points at the outbound rather than the resolver.
        return '隧道已连接但出站不可用，${seconds}s 内 $attempts 次探测均无法建立连接'
            '（弱网或节点不可达）: ${transportError ?? dnsError ?? "无详情"}';
      case TunnelDataPlaneOutcome.tunnelDropped:
        return '探测中断: 隧道状态变为 ${tunnelState ?? "unknown"} '
            '($attempts次探测, ${seconds}s)';
      case TunnelDataPlaneOutcome.suspended:
        return '探测中断: App 在探测期间被系统挂起，结果不作数 '
            '($attempts次探测, 跨越 ${seconds}s)';
    }
  }

  @override
  String toString() => describe();
}

/// A raw-IP fallback target, used to separate "DNS is broken" from
/// "nothing routes at all".
class TunnelProbeEndpoint {
  const TunnelProbeEndpoint(this.host, this.port);

  final String host;
  final int port;

  @override
  String toString() => '$host:$port';
}

/// Resolves [host], returning the addresses. Injected so the retry logic can
/// be tested without a network.
typedef TunnelDnsResolver = Future<List<InternetAddress>> Function(
  String host,
  Duration timeout,
);

/// Opens and immediately closes a TCP session to prove routing works.
typedef TunnelTransportProbe = Future<void> Function(
  String host,
  int port,
  Duration timeout,
);

/// Reads the current Packet Tunnel state (`connected`, `disconnected`, ...).
typedef TunnelStateReader = Future<String> Function();

/// Verifies that a freshly established tunnel actually carries traffic.
///
/// The naive version of this check — one DNS lookup fired the instant
/// `NEVPNStatus` flips to `connected` — reports failure on a perfectly healthy
/// tunnel, because the utun interface's DNS and routes are not usable in the
/// app process for the first few hundred milliseconds. This probe is built
/// around that fact:
///
/// * it waits out a settle delay before the first attempt;
/// * it retries until a deadline instead of trusting a single sample;
/// * it grows the per-attempt timeout so a slow first handshake is not fatal;
/// * it follows real traffic (resolve a name, then connect to the address it
///   returned) and only falls back to raw IPs to classify the failure;
/// * it aborts early — and inconclusively — if the tunnel drops underneath it.
class TunnelDataPlaneProbe {
  TunnelDataPlaneProbe({
    required this.readTunnelState,
    this.dnsHosts = defaultDnsHosts,
    this.fallbackEndpoints = defaultFallbackEndpoints,
    this.settleDelay = const Duration(milliseconds: 400),
    this.budget = const Duration(seconds: 20),
    this.retryInterval = const Duration(milliseconds: 600),
    this.maxRetryInterval = const Duration(milliseconds: 2500),
    this.initialAttemptTimeout = const Duration(seconds: 2),
    this.maxAttemptTimeout = const Duration(seconds: 4),
    this.suspensionTolerance = const Duration(seconds: 10),
    TunnelDnsResolver? resolveHost,
    TunnelTransportProbe? probeTransport,
    Future<void> Function(Duration)? sleep,
    DateTime Function()? now,
  })  : resolveHost = resolveHost ?? _defaultResolveHost,
        probeTransport = probeTransport ?? _defaultProbeTransport,
        _sleep = sleep ?? _defaultSleep,
        _now = now ?? DateTime.now;

  static const List<String> defaultDnsHosts = <String>[
    'www.cloudflare.com',
    'www.apple.com',
    'www.microsoft.com',
  ];

  /// Reached only when DNS is dead, so these must be raw addresses.
  static const List<TunnelProbeEndpoint> defaultFallbackEndpoints =
      <TunnelProbeEndpoint>[
    TunnelProbeEndpoint('1.1.1.1', 443),
    TunnelProbeEndpoint('8.8.8.8', 443),
  ];

  final TunnelStateReader readTunnelState;
  final List<String> dnsHosts;
  final List<TunnelProbeEndpoint> fallbackEndpoints;
  final Duration settleDelay;
  final Duration budget;
  final Duration retryInterval;
  final Duration maxRetryInterval;
  final Duration initialAttemptTimeout;
  final Duration maxAttemptTimeout;

  /// How much longer than intended a step may take before the run is treated
  /// as suspended rather than merely slow.
  final Duration suspensionTolerance;
  final TunnelDnsResolver resolveHost;
  final TunnelTransportProbe probeTransport;
  final Future<void> Function(Duration) _sleep;
  final DateTime Function() _now;

  Future<TunnelDataPlaneReport> run() async {
    final startedAt = _now();
    final deadline = startedAt.add(budget);
    var attempts = 0;
    String? dnsError;
    String? transportError;
    var sawRoutableTransport = false;

    // Wall-clock deadlines are not trustworthy on their own here: iOS suspends
    // the containing app freely, and the user backgrounding the app right
    // after tapping connect is the normal case. Time then runs on while the
    // probe makes no progress, and the budget expires without a single extra
    // sample -- observed in the field as "221.9s, 3 attempts" against a 12s
    // budget. Track how long each step was *meant* to take, so a run that lost
    // time to suspension is reported as inconclusive instead of as failure.
    var intended = Duration.zero;

    await _sleep(settleDelay);
    intended += settleDelay;

    while (true) {
      if (_lostTime(startedAt, intended)) {
        return _suspendedReport(startedAt, attempts, dnsError, transportError);
      }

      final state = await _readStateSafely();
      if (state != 'connected') {
        return TunnelDataPlaneReport(
          outcome: TunnelDataPlaneOutcome.tunnelDropped,
          attempts: attempts,
          elapsed: _now().difference(startedAt),
          tunnelState: state,
          dnsError: dnsError,
          transportError: transportError,
        );
      }

      // Clamp to what is left of the budget. Without this the budget is not a
      // bound at all: on a weak link a stacked DNS timeout plus two fallback
      // connect timeouts can overrun it by seconds, which is exactly what the
      // 17.2s and 16.1s field reports against a 12s budget showed.
      var remaining = deadline.difference(_now());
      if (remaining <= Duration.zero) {
        break;
      }

      attempts++;
      final attemptTimeout = _clamp(_attemptTimeout(attempts), remaining);
      final host = dnsHosts[(attempts - 1) % dnsHosts.length];

      intended += attemptTimeout;
      List<InternetAddress>? addresses;
      try {
        addresses = await resolveHost(host, attemptTimeout);
        if (addresses.isEmpty) {
          dnsError = '$host resolved to no addresses';
          addresses = null;
        } else {
          dnsError = null;
        }
      } catch (e) {
        dnsError = '$host: $e';
        addresses = null;
      }

      if (addresses != null) {
        final address = addresses.first;
        remaining = deadline.difference(_now());
        if (remaining > Duration.zero) {
          final transportTimeout = _clamp(attemptTimeout, remaining);
          intended += transportTimeout;
          try {
            await probeTransport(address.address, 443, transportTimeout);
            return TunnelDataPlaneReport(
              outcome: TunnelDataPlaneOutcome.reachable,
              attempts: attempts,
              elapsed: _now().difference(startedAt),
            );
          } catch (e) {
            transportError = '${address.address}:443 ($host): $e';
          }
        }
      } else {
        // DNS is down. Prove whether anything routes at all, so the caller can
        // report a resolver problem instead of a dead tunnel.
        for (final endpoint in fallbackEndpoints) {
          remaining = deadline.difference(_now());
          if (remaining <= Duration.zero) {
            break;
          }
          final fallbackTimeout = _clamp(attemptTimeout, remaining);
          intended += fallbackTimeout;
          try {
            await probeTransport(endpoint.host, endpoint.port, fallbackTimeout);
            sawRoutableTransport = true;
            transportError = null;
            break;
          } catch (e) {
            transportError = '$endpoint: $e';
          }
        }
      }

      // Back off between attempts. A refused route fails instantly, so a fixed
      // short interval just burns the budget on retries that cannot succeed --
      // 19 attempts in 16s bought nothing in the field. Spacing them out gives
      // a recovering link real time to come back within the same budget.
      final backoff = _retryDelay(attempts);
      if (!_now().add(backoff).isBefore(deadline)) {
        break;
      }
      await _sleep(backoff);
      intended += backoff;
    }

    if (_lostTime(startedAt, intended)) {
      return _suspendedReport(startedAt, attempts, dnsError, transportError);
    }

    return TunnelDataPlaneReport(
      outcome: sawRoutableTransport
          ? TunnelDataPlaneOutcome.dnsUnreachable
          : TunnelDataPlaneOutcome.transportUnreachable,
      attempts: attempts,
      elapsed: _now().difference(startedAt),
      dnsError: dnsError,
      transportError: transportError,
    );
  }

  Duration _attemptTimeout(int attempt) {
    final scaled = initialAttemptTimeout * attempt;
    return scaled > maxAttemptTimeout ? maxAttemptTimeout : scaled;
  }

  /// Exponential backoff, capped, so a long budget means longer waits rather
  /// than more attempts.
  Duration _retryDelay(int attempt) {
    final scaled = retryInterval * (1 << (attempt - 1).clamp(0, 4));
    return scaled > maxRetryInterval ? maxRetryInterval : scaled;
  }

  static Duration _clamp(Duration value, Duration limit) =>
      value > limit ? limit : value;

  /// True when far more wall-clock time has passed than the run could
  /// legitimately have spent, which on iOS means the app was suspended.
  bool _lostTime(DateTime startedAt, Duration intended) =>
      _now().difference(startedAt) > intended + suspensionTolerance;

  TunnelDataPlaneReport _suspendedReport(
    DateTime startedAt,
    int attempts,
    String? dnsError,
    String? transportError,
  ) {
    return TunnelDataPlaneReport(
      outcome: TunnelDataPlaneOutcome.suspended,
      attempts: attempts,
      elapsed: _now().difference(startedAt),
      dnsError: dnsError,
      transportError: transportError,
    );
  }

  Future<String> _readStateSafely() async {
    try {
      return await readTunnelState();
    } catch (_) {
      // A status read that fails must not be mistaken for a dead data plane;
      // keep probing and let the network calls decide.
      return 'connected';
    }
  }

  static Future<List<InternetAddress>> _defaultResolveHost(
    String host,
    Duration timeout,
  ) {
    return InternetAddress.lookup(host).timeout(timeout);
  }

  static Future<void> _defaultProbeTransport(
    String host,
    int port,
    Duration timeout,
  ) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.destroy();
  }

  static Future<void> _defaultSleep(Duration duration) {
    if (duration <= Duration.zero) return Future<void>.value();
    return Future<void>.delayed(duration);
  }
}
