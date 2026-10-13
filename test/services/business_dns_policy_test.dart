import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xconnect/services/dns/dns_control_plane.dart';
import 'package:xconnect/services/vpn_config_service.dart';
import 'package:xconnect/utils/global_config.dart';

Map<String, dynamic> _config() => <String, dynamic>{
      'inbounds': <dynamic>[],
      'outbounds': <dynamic>[
        <String, dynamic>{
          'tag': 'proxy',
          'protocol': 'vless',
          'settings': <String, dynamic>{
            'vnext': <dynamic>[
              <String, dynamic>{
                'address': 'edge.google.com',
                'port': 443,
                'users': <dynamic>[
                  <String, dynamic>{
                    'id': '11111111-1111-1111-1111-111111111111',
                    'encryption': 'none',
                  },
                ],
              },
            ],
          },
          'streamSettings': <String, dynamic>{
            'network': 'tcp',
            'security': 'tls',
            'tlsSettings': <String, dynamic>{
              'serverName': 'edge.google.com',
              'allowInsecure': false,
            },
          },
        },
        <String, dynamic>{'tag': 'direct', 'protocol': 'freedom'},
        <String, dynamic>{'tag': 'block', 'protocol': 'blackhole'},
        <String, dynamic>{'tag': 'dns', 'protocol': 'dns'},
      ],
      'routing': <String, dynamic>{
        'rules': <dynamic>[
          <String, dynamic>{
            'type': 'field',
            'domain': <String>['domain:github.com', 'domain:corp.example'],
            'outboundTag': 'direct',
          },
        ],
      },
    };

List<dynamic> _outbounds(Map<String, dynamic> config) =>
    config['outbounds'] as List;

List<dynamic> _rules(Map<String, dynamic> config) =>
    (config['routing'] as Map)['rules'] as List;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    DnsConfig.setDohEnabled(true);
    DnsConfig.tunnelDnsViaProxy.value = true;
    DnsConfig.updateDirectServers(primary: '1.1.1.1', secondary: '8.8.8.8');
  });

  test('fresh defaults generate application DoH without extra settings',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await DnsConfig.init();
    expect(DnsConfig.dohEnabled, isTrue);
    expect(DnsConfig.tunnelDnsViaProxy.value, isTrue);
    final generated = await VpnConfig.tryGenerateXrayJsonFromVlessUri(
      'vless://11111111-1111-1111-1111-111111111111@edge.example:443'
      '?security=tls&type=tcp#test',
    );
    expect(generated, isNotNull);
    final config = jsonDecode(generated!) as Map<String, dynamic>;
    expect(
      _rules(config).singleWhere((rule) => rule['port'] == '53')['outboundTag'],
      BusinessDnsPolicy.outboundTag,
    );
    expect(
      _outbounds(config).where(
        (outbound) => outbound['tag'] == BusinessDnsPolicy.outboundTag,
      ),
      hasLength(1),
    );
  });

  test('all business A queries use DoH; nodes and direct exceptions win', () {
    final config = _config();
    final proxyBefore = jsonEncode(_outbounds(config).first);
    final systemDnsBefore = DnsConfig.systemTunnelDnsServers4();

    VpnConfig.applySecureDnsConfig(config, enableTunnelMode: true);

    final outbound = _outbounds(config).singleWhere(
      (value) => value['tag'] == BusinessDnsPolicy.outboundTag,
    ) as Map;
    expect(outbound['proxySettings'], {'tag': 'proxy'});
    final rules = (outbound['settings'] as Map)['rules'] as List;
    expect(rules.first['action'], 'direct');
    expect(
        rules.first['domain'],
        containsAll(<String>[
          'full:edge.google.com',
          'domain:github.com',
          'domain:corp.example',
          'domain:home.arpa',
          'full:connectivitycheck.gstatic.com',
        ]));
    expect(rules[1], {'action': 'hijack', 'qType': 1});
    expect(rules.last, {'action': 'direct'});
    final capture = _rules(config).singleWhere((rule) => rule['port'] == '53');
    expect(capture['outboundTag'], BusinessDnsPolicy.outboundTag);
    expect(capture['network'], 'tcp,udp');
    expect(capture['inboundTag'], ['tun-in']);
    expect(jsonEncode(_outbounds(config).first), proxyBefore);
    expect(DnsConfig.systemTunnelDnsServers4(), systemDnsBefore);
    final servers = (config['dns'] as Map)['servers'] as List;
    expect(
        servers.map((server) => server['address']),
        containsAll([
          'https://1.1.1.1/dns-query',
          'https://8.8.8.8/dns-query',
        ]));
    expect(
      servers
          .where((server) => server['tag'] == 'dns-proxy-primary')
          .single['timeoutMs'],
      ResolverServerPolicy.dohTimeoutMs,
    );
    expect(
      servers
          .where((server) => server['tag'] == 'dns-proxy-secondary')
          .single['timeoutMs'],
      ResolverServerPolicy.dohTimeoutMs,
    );
    expect(servers.last['address'], '1.1.1.1');
    expect(servers.last['tag'], ResolverServerPolicy.proxyFallbackTag);
    for (final tag in [
      'dns-proxy-primary',
      'dns-proxy-secondary',
      ResolverServerPolicy.proxyFallbackTag,
    ]) {
      expect(
          _rules(config).singleWhere(
            (rule) =>
                rule['inboundTag'] is List &&
                (rule['inboundTag'] as List).contains(tag),
          )['outboundTag'],
          'proxy');
    }

    // Optional fixture for the pinned-core runtime test. Contains test-only
    // identities and is never populated from a user's saved configuration.
    final fixture = Platform.environment['XCONNECT_BUSINESS_DNS_FIXTURE'];
    if (fixture != null) {
      File(fixture).writeAsStringSync(jsonEncode(config));
    }
  });

  test('configured fallback stays on proxy ahead of direct IP exceptions', () {
    DnsConfig.updateDirectServers(
        primary: '192.168.1.53', secondary: '9.9.9.9');
    final config = _config();
    VpnConfig.applySecureDnsConfig(config, enableTunnelMode: true);
    final servers = (config['dns'] as Map)['servers'] as List;
    expect(servers.last['address'], '192.168.1.53');
    final rules = _rules(config);
    final fallbackIndex = rules.indexWhere((rule) =>
        rule['inboundTag'] is List &&
        (rule['inboundTag'] as List)
            .contains(ResolverServerPolicy.proxyFallbackTag));
    expect(rules[fallbackIndex]['outboundTag'], 'proxy');
    expect(
        fallbackIndex,
        lessThan(rules.indexWhere(
            (rule) => rule['outboundTag'] == 'direct' && rule['ip'] != null)));

    DnsConfig.setDohEnabled(false);
    VpnConfig.applySecureDnsConfig(config, enableTunnelMode: true);
    expect(
      (config['dns'] as Map)['servers'].where(
          (server) => server['tag'] == ResolverServerPolicy.proxyFallbackTag),
      isEmpty,
    );
    expect(
      _rules(config).where((rule) =>
          rule['inboundTag'] is List &&
          (rule['inboundTag'] as List)
              .contains(ResolverServerPolicy.proxyFallbackTag)),
      isEmpty,
    );
  });

  test('reconnect is idempotent and DoH off restores the original DNS route',
      () {
    final config = _config();
    VpnConfig.applySecureDnsConfig(config, enableTunnelMode: true);
    final once = jsonEncode(config);
    VpnConfig.applySecureDnsConfig(config, enableTunnelMode: true);
    expect(jsonEncode(config), once);

    DnsConfig.setDohEnabled(false);
    VpnConfig.applySecureDnsConfig(config, enableTunnelMode: true);
    final fixture = Platform.environment['XCONNECT_BUSINESS_DNS_FIXTURE'];
    if (fixture != null) {
      File('$fixture.off').writeAsStringSync(jsonEncode(config));
    }
    expect(
        _outbounds(config).where(
          (outbound) => outbound['tag'] == BusinessDnsPolicy.outboundTag,
        ),
        isEmpty);
    expect(
        _rules(config)
            .singleWhere((rule) => rule['port'] == '53')['outboundTag'],
        'proxy');
    expect(
        _rules(config).where(
          (rule) =>
              rule['domain'] is List &&
              (rule['domain'] as List).contains('domain:corp.example'),
        ),
        hasLength(1));

    DnsConfig.setDohEnabled(true);
    VpnConfig.applySecureDnsConfig(config, enableTunnelMode: true);
    expect(jsonEncode(config), once);
  });

  test('local proxy mode and the existing tunnel DNS choice are preserved', () {
    final config = _config();
    VpnConfig.applySecureDnsConfig(config, enableTunnelMode: true);
    VpnConfig.applySecureDnsConfig(config, enableTunnelMode: false);
    expect(_rules(config).where((rule) => rule['port'] == '53'), isEmpty);
    expect(
        _outbounds(config).where(
          (outbound) => outbound['tag'] == BusinessDnsPolicy.outboundTag,
        ),
        isEmpty);

    if (!Platform.isIOS) {
      DnsConfig.tunnelDnsViaProxy.value = false;
      VpnConfig.applySecureDnsConfig(config, enableTunnelMode: true);
      expect(_rules(config).where((rule) => rule['port'] == '53'), isEmpty);
      expect(
          _outbounds(config).where(
            (outbound) => outbound['tag'] == BusinessDnsPolicy.outboundTag,
          ),
          isEmpty);
    }
  });

  test('all dialing outbounds contribute exact node-domain exceptions', () {
    final config = _config();
    _outbounds(config).add(<String, dynamic>{
      'tag': 'secondary',
      'protocol': 'socks',
      'settings': <String, dynamic>{
        'servers': <dynamic>[
          {'address': 'Relay.Example.', 'port': 1080},
          {'address': '203.0.113.10', 'port': 1080},
        ],
      },
    });
    VpnConfig.applySecureDnsConfig(config, enableTunnelMode: true);
    final outbound = _outbounds(config).singleWhere(
      (value) => value['tag'] == BusinessDnsPolicy.outboundTag,
    );
    final exceptions = outbound['settings']['rules'][0]['domain'] as List;
    expect(exceptions, contains('full:relay.example'));
    expect(exceptions, isNot(contains('full:203.0.113.10')));
  });

  test('an existing custom outbound with the reserved tag is retained', () {
    final config = _config();
    final custom = <String, dynamic>{
      'tag': BusinessDnsPolicy.outboundTag,
      'protocol': 'dns',
      'proxySettings': {'tag': 'proxy'},
      'settings': {
        'rules': [
          {'action': 'return', 'rCode': 5}
        ]
      },
    };
    _outbounds(config).add(custom);
    VpnConfig.applySecureDnsConfig(config, enableTunnelMode: true);
    expect(_outbounds(config).last, custom);
    expect(
        _rules(config)
            .singleWhere((rule) => rule['port'] == '53')['outboundTag'],
        'proxy');
  });
}
