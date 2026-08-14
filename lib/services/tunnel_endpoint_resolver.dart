import 'dart:io';

/// Result of pinning outbound server domains to literal addresses.
class TunnelEndpointPinning {
  const TunnelEndpointPinning({
    required this.config,
    required this.pinnedIpv4,
    required this.pinned,
    required this.failures,
  });

  /// The config with dialable addresses replaced by literal IPs.
  final Map<String, dynamic> config;

  /// Literal IPv4 addresses now dialled directly, for tunnel route exclusion.
  final List<String> pinnedIpv4;

  /// `domain -> address` for each endpoint that was pinned.
  final Map<String, String> pinned;

  /// Domains that could not be resolved; these keep their original address.
  final List<String> failures;

  bool get changedAnything => pinned.isNotEmpty;
}

typedef EndpointResolver = Future<List<InternetAddress>> Function(
  String host,
  Duration timeout,
);

/// Replaces outbound server domains with literal IPs before the tunnel starts.
///
/// The Packet Tunnel captures every DNS query (`matchDomains = [""]`) and the
/// routing rules send port 53 through the proxy outbound. If that outbound is
/// addressed by domain, the engine has to resolve a name in order to build the
/// very tunnel that the resolution depends on — a deadlock that shows up as
/// `dial tcp: lookup <server>: no such host`, repeated forever, with no
/// traffic. It survives on Wi-Fi only when the name happens to be in the DNS
/// cache already, which is why it reads as an intermittent cellular fault.
///
/// Resolving in the app *before* the tunnel is raised breaks the cycle: the
/// system resolver is still un-captured at that point, and the engine is then
/// handed an address it can dial without asking anyone.
///
/// TLS is unaffected. `serverName` and the transport `host` are what identify
/// the server for SNI and virtual hosting, and this keeps them on the original
/// domain — filling them in from the domain when the config left them implicit,
/// which is exactly when swapping in an IP would otherwise break validation.
class TunnelEndpointResolver {
  TunnelEndpointResolver({
    EndpointResolver? resolve,
    this.timeout = const Duration(seconds: 5),
  }) : _resolve = resolve ?? _defaultResolve;

  final EndpointResolver _resolve;
  final Duration timeout;

  /// Outbound protocols that dial a remote server. `freedom`, `blackhole` and
  /// `dns` carry no server address of their own.
  static const dialingProtocols = <String>{
    'vless',
    'vmess',
    'trojan',
    'shadowsocks',
    'socks',
    'http',
  };

  /// The domains the dialing outbounds point at, ignoring literal addresses.
  static List<String> outboundServerDomains(Map<String, dynamic> config) {
    final domains = <String>[];
    final outbounds = config['outbounds'];
    if (outbounds is! List) return domains;
    for (final outbound in outbounds) {
      if (outbound is! Map<String, dynamic>) continue;
      final protocol = outbound['protocol'];
      if (protocol is! String || !dialingProtocols.contains(protocol)) continue;
      final settings = outbound['settings'];
      if (settings is! Map<String, dynamic>) continue;
      for (final key in const <String>['vnext', 'servers']) {
        final entries = settings[key];
        if (entries is! List) continue;
        for (final entry in entries) {
          if (entry is! Map<String, dynamic>) continue;
          final address = entry['address'];
          if (address is! String) continue;
          final domain = address.trim();
          if (domain.isEmpty || _isLiteralAddress(domain)) continue;
          if (!domains.contains(domain)) domains.add(domain);
        }
      }
    }
    return domains;
  }

  Future<TunnelEndpointPinning> pinOutboundEndpoints(
    Map<String, dynamic> config,
  ) async {
    final outbounds = config['outbounds'];
    if (outbounds is! List) {
      return TunnelEndpointPinning(
        config: config,
        pinnedIpv4: const <String>[],
        pinned: const <String, String>{},
        failures: const <String>[],
      );
    }

    final pinned = <String, String>{};
    final failures = <String>[];
    final ipv4 = <String>[];
    final cache = <String, InternetAddress?>{};

    for (final outbound in outbounds) {
      if (outbound is! Map<String, dynamic>) continue;
      final protocol = outbound['protocol'];
      if (protocol is! String || !dialingProtocols.contains(protocol)) {
        continue;
      }
      final settings = outbound['settings'];
      if (settings is! Map<String, dynamic>) continue;

      for (final key in const <String>['vnext', 'servers']) {
        final entries = settings[key];
        if (entries is! List) continue;
        for (final entry in entries) {
          if (entry is! Map<String, dynamic>) continue;
          final address = entry['address'];
          if (address is! String) continue;
          final domain = address.trim();
          if (domain.isEmpty || _isLiteralAddress(domain)) continue;

          if (!cache.containsKey(domain)) {
            cache[domain] = await _resolvePreferringIpv4(domain);
          }
          final resolved = cache[domain];
          if (resolved == null) {
            if (!failures.contains(domain)) failures.add(domain);
            continue;
          }

          // Keep the domain visible to TLS and the transport before the
          // address underneath it changes.
          _preserveServerIdentity(outbound, domain);
          entry['address'] = resolved.address;
          pinned[domain] = resolved.address;
          if (resolved.type == InternetAddressType.IPv4 &&
              !ipv4.contains(resolved.address)) {
            ipv4.add(resolved.address);
          }
        }
      }
    }

    return TunnelEndpointPinning(
      config: config,
      pinnedIpv4: ipv4,
      pinned: pinned,
      failures: failures,
    );
  }

  Future<InternetAddress?> _resolvePreferringIpv4(String domain) async {
    try {
      final addresses = await _resolve(domain, timeout);
      if (addresses.isEmpty) return null;
      for (final address in addresses) {
        if (address.type == InternetAddressType.IPv4) return address;
      }
      // The tunnel profile carries IPv4 routes only, so an IPv6-only result
      // cannot be excluded from the tunnel and would loop back into it.
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Pins SNI and the transport host to [domain] wherever they were implicit.
  ///
  /// Never overwrites an explicit value: a config may deliberately front a
  /// different name.
  static void _preserveServerIdentity(
    Map<String, dynamic> outbound,
    String domain,
  ) {
    final stream = outbound['streamSettings'];
    if (stream is! Map<String, dynamic>) return;

    for (final key in const <String>['tlsSettings', 'realitySettings']) {
      final security = stream[key];
      if (security is Map<String, dynamic>) {
        final serverName = security['serverName'];
        if (serverName is! String || serverName.trim().isEmpty) {
          security['serverName'] = domain;
        }
      }
    }

    for (final key in const <String>[
      'xhttpSettings',
      'httpSettings',
      'httpupgradeSettings',
      'splithttpSettings',
    ]) {
      final transport = stream[key];
      if (transport is Map<String, dynamic>) {
        final host = transport['host'];
        if (host is! String || host.trim().isEmpty) {
          transport['host'] = domain;
        }
      }
    }

    final ws = stream['wsSettings'];
    if (ws is Map<String, dynamic>) {
      final host = ws['host'];
      if (host is! String || host.trim().isEmpty) {
        final headers = ws['headers'];
        if (headers is Map<String, dynamic>) {
          final headerHost = headers['Host'];
          if (headerHost is! String || headerHost.trim().isEmpty) {
            headers['Host'] = domain;
          }
        } else {
          ws['headers'] = <String, dynamic>{'Host': domain};
        }
      }
    }
  }

  static bool _isLiteralAddress(String value) {
    return InternetAddress.tryParse(value) != null;
  }

  static Future<List<InternetAddress>> _defaultResolve(
    String host,
    Duration timeout,
  ) {
    return InternetAddress.lookup(host).timeout(timeout);
  }
}
