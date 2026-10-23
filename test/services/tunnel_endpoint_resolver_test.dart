import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/services/tunnel_endpoint_resolver.dart';

Map<String, dynamic> _config({
  String address = 'tky-proxy.svc.plus',
  Map<String, dynamic>? streamSettings,
  String protocol = 'vless',
}) {
  return jsonDecode(jsonEncode(<String, dynamic>{
    'outbounds': <dynamic>[
      <String, dynamic>{
        'tag': 'proxy',
        'protocol': protocol,
        'settings': <String, dynamic>{
          'vnext': <dynamic>[
            <String, dynamic>{'address': address, 'port': 443},
          ],
        },
        if (streamSettings != null) 'streamSettings': streamSettings,
      },
      <String, dynamic>{'tag': 'direct', 'protocol': 'freedom'},
      <String, dynamic>{'tag': 'block', 'protocol': 'blackhole'},
    ],
  })) as Map<String, dynamic>;
}

Map<String, dynamic> _proxyOutbound(Map<String, dynamic> config) =>
    (config['outbounds'] as List).first as Map<String, dynamic>;

String _pinnedAddress(Map<String, dynamic> config) =>
    ((_proxyOutbound(config)['settings'] as Map)['vnext'] as List)
        .first['address'] as String;

Uint8List _dnsAResponse(
  Uint8List query,
  List<int> address,
) {
  final response = BytesBuilder(copy: false)
    ..add(<int>[
      query[0],
      query[1],
      0x81,
      0x80,
      0x00,
      0x01,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x00,
    ])
    ..add(query.sublist(12))
    ..add(<int>[
      0xc0,
      0x0c,
      0x00,
      0x01,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x3c,
      0x00,
      0x04,
      ...address,
    ]);
  return response.takeBytes();
}

void main() {
  group('TunnelEndpointResolver', () {
    test('replaces a server domain with the resolved IPv4 literal', () async {
      final resolver = TunnelEndpointResolver(
        resolve: (host, timeout) async => <InternetAddress>[
          InternetAddress('203.0.113.10'),
        ],
      );

      final result = await resolver.pinOutboundEndpoints(_config());

      expect(_pinnedAddress(result.config), '203.0.113.10');
      expect(result.pinned, {'tky-proxy.svc.plus': '203.0.113.10'});
      expect(result.pinnedIpv4, <String>['203.0.113.10']);
    });

    test('leaves an explicit serverName and host untouched', () async {
      final resolver = TunnelEndpointResolver(
        resolve: (host, timeout) async => <InternetAddress>[
          InternetAddress('203.0.113.10'),
        ],
      );

      final result = await resolver.pinOutboundEndpoints(
        _config(
          streamSettings: <String, dynamic>{
            'tlsSettings': <String, dynamic>{'serverName': 'front.example'},
            'xhttpSettings': <String, dynamic>{'host': 'front.example'},
          },
        ),
      );

      final stream = _proxyOutbound(result.config)['streamSettings']
          as Map<String, dynamic>;
      expect((stream['tlsSettings'] as Map)['serverName'], 'front.example');
      expect((stream['xhttpSettings'] as Map)['host'], 'front.example');
    });

    test('fills in SNI and host from the domain when they were implicit',
        () async {
      // Swapping in an IP would otherwise break TLS validation, because the
      // domain would no longer appear anywhere in the outbound.
      final resolver = TunnelEndpointResolver(
        resolve: (host, timeout) async => <InternetAddress>[
          InternetAddress('203.0.113.10'),
        ],
      );

      final result = await resolver.pinOutboundEndpoints(
        _config(
          streamSettings: <String, dynamic>{
            'tlsSettings': <String, dynamic>{},
            'xhttpSettings': <String, dynamic>{},
          },
        ),
      );

      final stream = _proxyOutbound(result.config)['streamSettings']
          as Map<String, dynamic>;
      expect(
        (stream['tlsSettings'] as Map)['serverName'],
        'tky-proxy.svc.plus',
      );
      expect((stream['xhttpSettings'] as Map)['host'], 'tky-proxy.svc.plus');
    });

    test('leaves an address that is already a literal alone', () async {
      var lookups = 0;
      final resolver = TunnelEndpointResolver(
        resolve: (host, timeout) async {
          lookups++;
          return <InternetAddress>[InternetAddress('203.0.113.10')];
        },
      );

      final result =
          await resolver.pinOutboundEndpoints(_config(address: '198.51.100.7'));

      expect(lookups, 0);
      expect(result.changedAnything, isFalse);
      expect(_pinnedAddress(result.config), '198.51.100.7');
    });

    test('keeps the domain when resolution fails, rather than breaking dial',
        () async {
      final resolver = TunnelEndpointResolver(
        resolve: (host, timeout) async =>
            throw const SocketException('Failed host lookup'),
      );

      final result = await resolver.pinOutboundEndpoints(_config());

      expect(_pinnedAddress(result.config), 'tky-proxy.svc.plus');
      expect(result.changedAnything, isFalse);
      expect(result.failures, <String>['tky-proxy.svc.plus']);
    });

    test('does not pin an IPv6-only result, which cannot be route-excluded',
        () async {
      // The tunnel profile carries IPv4 routes only, so an IPv6 literal would
      // loop straight back into the tunnel it is meant to bypass.
      final resolver = TunnelEndpointResolver(
        resolve: (host, timeout) async => <InternetAddress>[
          InternetAddress('2606:4700::1111'),
        ],
      );

      final result = await resolver.pinOutboundEndpoints(_config());

      expect(_pinnedAddress(result.config), 'tky-proxy.svc.plus');
      expect(result.pinnedIpv4, isEmpty);
      expect(result.failures, <String>['tky-proxy.svc.plus']);
    });

    test('prefers the IPv4 answer when both families resolve', () async {
      final resolver = TunnelEndpointResolver(
        resolve: (host, timeout) async => <InternetAddress>[
          InternetAddress('2606:4700::1111'),
          InternetAddress('203.0.113.10'),
        ],
      );

      final result = await resolver.pinOutboundEndpoints(_config());

      expect(_pinnedAddress(result.config), '203.0.113.10');
      expect(result.pinnedIpv4, <String>['203.0.113.10']);
    });

    test('ignores outbounds that dial nothing', () async {
      var lookups = 0;
      final resolver = TunnelEndpointResolver(
        resolve: (host, timeout) async {
          lookups++;
          return <InternetAddress>[InternetAddress('203.0.113.10')];
        },
      );

      await resolver.pinOutboundEndpoints(<String, dynamic>{
        'outbounds': <dynamic>[
          <String, dynamic>{'tag': 'direct', 'protocol': 'freedom'},
          <String, dynamic>{'tag': 'block', 'protocol': 'blackhole'},
          <String, dynamic>{'tag': 'dns', 'protocol': 'dns'},
        ],
      });

      expect(lookups, 0);
    });
  });

  group('DnsJsonEndpointResolver', () {
    test('returns only unique IPv4 A records', () async {
      final resolver = DnsJsonEndpointResolver(
        request: (uri, timeout) async => <String, dynamic>{
          'Status': 0,
          'Answer': <Map<String, dynamic>>[
            <String, dynamic>{'type': 5, 'data': 'alias.example'},
            <String, dynamic>{'type': 28, 'data': '2001:db8::1'},
            <String, dynamic>{'type': 1, 'data': '203.0.113.10'},
            <String, dynamic>{'type': 1, 'data': '203.0.113.10'},
          ],
        },
      );

      final result = await resolver.resolve(
        'tky-proxy.svc.plus',
        const Duration(seconds: 1),
      );

      expect(result.map((address) => address.address), <String>[
        '203.0.113.10',
      ]);
    });

    test('uses literal-IP resolver endpoints and falls back to the second',
        () async {
      final requested = <Uri>[];
      final resolver = DnsJsonEndpointResolver(
        request: (uri, timeout) async {
          requested.add(uri);
          if (requested.length == 1) {
            throw const SocketException('first provider unavailable');
          }
          return <String, dynamic>{
            'Status': 0,
            'Answer': <Map<String, dynamic>>[
              <String, dynamic>{'type': 1, 'data': '203.0.113.11'},
            ],
          };
        },
      );

      final result = await resolver.resolve(
        'tky-proxy.svc.plus',
        const Duration(seconds: 1),
      );

      expect(requested.map((uri) => uri.host), <String>['1.1.1.1', '8.8.8.8']);
      expect(result.single.address, '203.0.113.11');
    });

    test('rejects unsuccessful DNS responses', () async {
      final resolver = DnsJsonEndpointResolver(
        request: (uri, timeout) async => <String, dynamic>{
          'Status': 3,
          'Answer': <Map<String, dynamic>>[
            <String, dynamic>{'type': 1, 'data': '203.0.113.10'},
          ],
        },
      );

      final result = await resolver.resolve(
        'missing.example',
        const Duration(seconds: 1),
      );

      expect(result, isEmpty);
    });
  });

  group('DnsDatagramEndpointResolver', () {
    test('builds an A query and parses a compressed IPv4 answer', () {
      const transactionId = 0x1234;
      final query = DnsDatagramEndpointResolver.buildQuery(
        'tky-proxy.svc.plus',
        transactionId,
      );
      final response = _dnsAResponse(query, <int>[203, 0, 113, 12]);

      final result = DnsDatagramEndpointResolver.parseResponse(
        response,
        transactionId,
      );

      expect(result.single.address, '203.0.113.12');
    });

    test('falls back to the second literal DNS server', () async {
      final requested = <String>[];
      final resolver = DnsDatagramEndpointResolver(
        request: (query, server, timeout) async {
          requested.add(server.address);
          if (requested.length == 1) {
            throw const SocketException('first DNS server unavailable');
          }
          return _dnsAResponse(query, <int>[203, 0, 113, 13]);
        },
      );

      final result = await resolver.resolve(
        'tky-proxy.svc.plus',
        const Duration(seconds: 1),
      );

      expect(requested, <String>['1.1.1.1', '8.8.8.8']);
      expect(result.single.address, '203.0.113.13');
    });
  });
}
