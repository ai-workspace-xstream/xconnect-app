import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

typedef DnsJsonRequest = Future<Map<String, dynamic>> Function(
  Uri uri,
  Duration timeout,
);

typedef DnsDatagramRequest = Future<Uint8List> Function(
  Uint8List query,
  InternetAddress server,
  Duration timeout,
);

/// Minimal DNS-over-UDP A-record resolver using literal server addresses.
///
/// This is intentionally small and used only before the Packet Tunnel starts.
/// It avoids both the system resolver and HTTPS/TLS, which makes it suitable
/// for cellular networks where one of those paths is unavailable.
class DnsDatagramEndpointResolver {
  DnsDatagramEndpointResolver({DnsDatagramRequest? request})
      : _request = request ?? _defaultRequest;

  final DnsDatagramRequest _request;

  static final servers = <InternetAddress>[
    InternetAddress('1.1.1.1'),
    InternetAddress('8.8.8.8'),
  ];

  Future<List<InternetAddress>> resolve(
    String host,
    Duration timeout,
  ) async {
    final transactionId =
        DateTime.now().microsecondsSinceEpoch.remainder(0x10000);
    final query = buildQuery(host, transactionId);
    for (final server in servers) {
      try {
        final response = await _request(query, server, timeout);
        final addresses = parseResponse(response, transactionId);
        if (addresses.isNotEmpty) return addresses;
      } catch (_) {
        // Try the next literal-IP DNS server.
      }
    }
    return const <InternetAddress>[];
  }

  static Uint8List buildQuery(String host, int transactionId) {
    final builder = BytesBuilder(copy: false)
      ..add(<int>[
        transactionId >> 8,
        transactionId & 0xff,
        0x01,
        0x00,
        0x00,
        0x01,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
      ]);
    for (final label in host.split('.')) {
      final encoded = ascii.encode(label);
      if (encoded.isEmpty || encoded.length > 63) {
        throw const FormatException('invalid DNS label');
      }
      builder
        ..addByte(encoded.length)
        ..add(encoded);
    }
    builder
      ..addByte(0)
      ..add(<int>[0x00, 0x01, 0x00, 0x01]);
    return builder.takeBytes();
  }

  static List<InternetAddress> parseResponse(
    Uint8List response,
    int transactionId,
  ) {
    if (response.length < 12 ||
        _readUint16(response, 0) != transactionId ||
        (response[2] & 0x80) == 0 ||
        (response[3] & 0x0f) != 0) {
      return const <InternetAddress>[];
    }

    final questionCount = _readUint16(response, 4);
    final answerCount = _readUint16(response, 6);
    var offset = 12;
    for (var i = 0; i < questionCount; i++) {
      offset = _skipName(response, offset);
      if (offset < 0 || offset + 4 > response.length) {
        return const <InternetAddress>[];
      }
      offset += 4;
    }

    final addresses = <InternetAddress>[];
    for (var i = 0; i < answerCount; i++) {
      offset = _skipName(response, offset);
      if (offset < 0 || offset + 10 > response.length) break;
      final type = _readUint16(response, offset);
      final dnsClass = _readUint16(response, offset + 2);
      final dataLength = _readUint16(response, offset + 8);
      offset += 10;
      if (offset + dataLength > response.length) break;
      if (type == 1 && dnsClass == 1 && dataLength == 4) {
        final address = InternetAddress(
          '${response[offset]}.${response[offset + 1]}.'
          '${response[offset + 2]}.${response[offset + 3]}',
        );
        if (!addresses.any(
          (candidate) => candidate.address == address.address,
        )) {
          addresses.add(address);
        }
      }
      offset += dataLength;
    }
    return addresses;
  }

  static int _readUint16(Uint8List bytes, int offset) =>
      bytes[offset] << 8 | bytes[offset + 1];

  static int _skipName(Uint8List bytes, int offset) {
    while (offset < bytes.length) {
      final length = bytes[offset];
      if (length == 0) return offset + 1;
      if ((length & 0xc0) == 0xc0) {
        return offset + 2 <= bytes.length ? offset + 2 : -1;
      }
      if ((length & 0xc0) != 0 || offset + 1 + length > bytes.length) {
        return -1;
      }
      offset += 1 + length;
    }
    return -1;
  }

  static Future<Uint8List> _defaultRequest(
    Uint8List query,
    InternetAddress server,
    Duration timeout,
  ) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0)
        .timeout(timeout);
    socket.writeEventsEnabled = false;
    try {
      final responseReady = socket
          .where((event) => event == RawSocketEvent.read)
          .first
          .timeout(timeout);
      socket.send(query, server, 53);
      await responseReady;
      final datagram = socket.receive();
      if (datagram == null) {
        throw const SocketException('empty DNS response');
      }
      return Uint8List.fromList(datagram.data);
    } finally {
      socket.close();
    }
  }
}

/// Resolves A records through HTTPS endpoints addressed by literal IPs.
///
/// This deliberately avoids a hostname in the resolver URL. It is the fallback
/// for iOS cellular networks where the system resolver can fail before the
/// Packet Tunnel starts; using a named DoH endpoint in that situation would
/// depend on the same broken lookup.
class DnsJsonEndpointResolver {
  DnsJsonEndpointResolver({DnsJsonRequest? request})
      : _request = request ?? _defaultRequest;

  final DnsJsonRequest _request;

  static final endpoints = <Uri Function(String host)>[
    (host) => Uri.https(
          '1.1.1.1',
          '/dns-query',
          <String, String>{'name': host, 'type': 'A'},
        ),
    (host) => Uri.https(
          '8.8.8.8',
          '/resolve',
          <String, String>{'name': host, 'type': 'A'},
        ),
  ];

  Future<List<InternetAddress>> resolve(
    String host,
    Duration timeout,
  ) async {
    for (final endpoint in endpoints) {
      try {
        final response = await _request(endpoint(host), timeout);
        if (response['Status'] != 0) continue;
        final answers = response['Answer'];
        if (answers is! List) continue;

        final addresses = <InternetAddress>[];
        for (final answer in answers) {
          if (answer is! Map || answer['type'] != 1) continue;
          final raw = answer['data'];
          if (raw is! String) continue;
          final address = InternetAddress.tryParse(raw.trim());
          if (address == null ||
              address.type != InternetAddressType.IPv4 ||
              addresses
                  .any((candidate) => candidate.address == address.address)) {
            continue;
          }
          addresses.add(address);
        }
        if (addresses.isNotEmpty) return addresses;
      } catch (_) {
        // Try the next literal-IP provider.
      }
    }
    return const <InternetAddress>[];
  }

  static Future<Map<String, dynamic>> _defaultRequest(
    Uri uri,
    Duration timeout,
  ) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/dns-json');
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        return <String, dynamic>{};
      }
      final body = await utf8.decoder.bind(response).join().timeout(timeout);
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } finally {
      client.close(force: true);
    }
  }
}

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
  ) async {
    try {
      final system = await InternetAddress.lookup(host).timeout(timeout);
      if (system.any(
        (address) => address.type == InternetAddressType.IPv4,
      )) {
        return system;
      }
    } catch (_) {
      // Fall through to literal-IP resolvers. These bypass a broken or stale
      // system resolver without depending on another hostname lookup.
    }
    if (!Platform.isIOS) {
      return const <InternetAddress>[];
    }
    final datagram = await DnsDatagramEndpointResolver().resolve(host, timeout);
    if (datagram.isNotEmpty) return datagram;
    return DnsJsonEndpointResolver().resolve(host, timeout);
  }
}
