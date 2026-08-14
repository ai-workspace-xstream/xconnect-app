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
  /// A dropped tunnel is inconclusive: the probe never got a fair chance, so
  /// callers must not report it as a data-plane failure.
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
        return '隧道已连接但外网不可达 ($attempts次探测, ${seconds}s): '
            '${transportError ?? dnsError ?? "无详情"}';
      case TunnelDataPlaneOutcome.tunnelDropped:
        return '探测中断: 隧道状态变为 ${tunnelState ?? "unknown"} '
            '($attempts次探测, ${seconds}s)';
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
    this.budget = const Duration(seconds: 12),
    this.retryInterval = const Duration(milliseconds: 600),
    this.initialAttemptTimeout = const Duration(seconds: 2),
    this.maxAttemptTimeout = const Duration(seconds: 4),
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
  final Duration initialAttemptTimeout;
  final Duration maxAttemptTimeout;
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

    await _sleep(settleDelay);

    while (true) {
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

      attempts++;
      final attemptTimeout = _attemptTimeout(attempts);
      final host = dnsHosts[(attempts - 1) % dnsHosts.length];

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
        try {
          await probeTransport(address.address, 443, attemptTimeout);
          return TunnelDataPlaneReport(
            outcome: TunnelDataPlaneOutcome.reachable,
            attempts: attempts,
            elapsed: _now().difference(startedAt),
          );
        } catch (e) {
          transportError = '${address.address}:443 ($host): $e';
        }
      } else {
        // DNS is down. Prove whether anything routes at all, so the caller can
        // report a resolver problem instead of a dead tunnel.
        for (final endpoint in fallbackEndpoints) {
          try {
            await probeTransport(endpoint.host, endpoint.port, attemptTimeout);
            sawRoutableTransport = true;
            transportError = null;
            break;
          } catch (e) {
            transportError = '$endpoint: $e';
          }
        }
      }

      if (!_now().add(retryInterval).isBefore(deadline)) {
        break;
      }
      await _sleep(retryInterval);
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
