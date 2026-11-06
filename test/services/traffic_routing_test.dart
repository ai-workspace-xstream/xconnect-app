import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xconnect/services/dns/cn_domain_rules.dart';
import 'package:xconnect/services/traffic_routing.dart';
import 'package:xconnect/services/vpn_config_service.dart';

Map<String, dynamic> standardConfig() => {
      'outbounds': [
        {
          'tag': 'proxy',
          'protocol': 'vless',
          'streamSettings': {
            'security': 'tls',
            'tlsSettings': {'allowInsecure': false}
          },
        },
        {'tag': 'direct', 'protocol': 'freedom'},
        {'tag': 'block', 'protocol': 'blackhole'},
        {'tag': 'dns', 'protocol': 'dns'},
      ],
      'routing': {'rules': []},
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('old installations keep the original route until a choice is saved',
      () async {
    SharedPreferences.setMockInitialValues({});
    await TrafficRouting.init();
    expect(TrafficRouting.selected.value, TrafficMode.smart);
    expect(TrafficRouting.connectionMode, isNull);
    expect(await TrafficRouting.select(TrafficMode.allVpn), isTrue);
    await TrafficRouting.init();
    expect(TrafficRouting.connectionMode, TrafficMode.allVpn);
    expect(await TrafficRouting.select(TrafficMode.smart), isTrue);
    await TrafficRouting.init();
    expect(TrafficRouting.connectionMode, TrafficMode.smart);
  });

  test('accepts generated routes and rejects a user-defined routing graph', () {
    final config = standardConfig();
    expect(VpnConfig.supportsTrafficRouting(config), isTrue);
    VpnConfig.applySecureDnsConfig(config, enableTunnelMode: true);
    expect(VpnConfig.supportsTrafficRouting(config), isTrue);
    (config['routing']['rules'] as List).add({
      'type': 'field',
      'ip': ['203.0.113.1'],
      'outboundTag': 'direct',
    });
    expect(VpnConfig.supportsTrafficRouting(config), isFalse);
  });

  test('rejects plaintext and certificate verification bypass', () {
    final config = standardConfig();
    final stream = config['outbounds'][0]['streamSettings'] as Map;
    stream['security'] = 'none';
    expect(VpnConfig.supportsTrafficRouting(config), isFalse);
    stream['security'] = 'tls';
    stream['tlsSettings']['allowInsecure'] = true;
    expect(VpnConfig.supportsTrafficRouting(config), isFalse);
  });

  test(
      'Smart routing applies shared private CIDRs, system connectivity, and CN domain rules',
      () {
    final config = standardConfig();
    VpnConfig.applySecureDnsConfig(config,
        enableTunnelMode: true, forceBlockQuic: true);

    final rules = (config['routing']['rules'] as List).cast<Map>();

    // 1. Control rules: DNS port 53 & QUIC block
    final dns = rules.indexWhere((r) => r['port'] == '53');
    final quic = rules.indexWhere((r) => r['outboundTag'] == 'block');
    expect(dns, greaterThanOrEqualTo(0));
    expect(quic, greaterThanOrEqualTo(0));

    // 2. Direct resolvers inbound tag
    expect(
      rules.any((r) =>
          r['outboundTag'] == 'direct' &&
          (r['inboundTag'] as List?)?.contains('dns-direct-primary') == true),
      isTrue,
    );

    // 3. Shared LAN / Private IP CIDRs (direct)
    final privateIpRule = rules.firstWhere(
      (r) =>
          r['outboundTag'] == 'direct' &&
          r['ip'] != null &&
          (r['ip'] as List).contains('192.168.0.0/16'),
    );
    expect((privateIpRule['ip'] as List).contains('10.0.0.0/8'), isTrue);
    expect((privateIpRule['ip'] as List).contains('127.0.0.0/8'), isTrue);

    // 4. Shared minimal system connectivity (direct)
    final sysRule = rules.firstWhere(
      (r) =>
          r['outboundTag'] == 'direct' &&
          r['domain'] != null &&
          (r['domain'] as List).contains('full:localhost'),
    );
    expect(
        (sysRule['domain'] as List).contains('full:captive.apple.com'), isTrue);
    // apple.com and icloud.com must NOT be in system connectivity (they are CN/business rules)
    expect((sysRule['domain'] as List).contains('domain:apple.com'), isFalse);

    // 5. Chinese mainland domain rules (direct in Smart mode)
    final cnRule = rules.firstWhere(
      (r) =>
          r['outboundTag'] == 'direct' &&
          r['domain'] != null &&
          (r['domain'] as List).contains('domain:cn'),
    );
    expect((cnRule['domain'] as List).contains('domain:baidu.com'), isTrue);
    expect((cnRule['domain'] as List).contains('domain:qq.com'), isTrue);
    expect((cnRule['domain'] as List).contains('domain:apple.com'), isTrue);
  });

  test(
      'Global proxy preserves shared LAN/private CIDRs and system connectivity, but omits CN domain rules',
      () {
    final config = standardConfig();
    VpnConfig.applySecureDnsConfig(config,
        enableTunnelMode: true, forceBlockQuic: true);
    final baseline = jsonEncode(config['routing']);

    // Switch to Global mode (routeAllTunnelTraffic = true)
    final candidate = jsonDecode(jsonEncode(config)) as Map<String, dynamic>;
    VpnConfig.applySecureDnsConfig(candidate,
        enableTunnelMode: true,
        forceBlockQuic: true,
        routeAllTunnelTraffic: true);
    final rules = (candidate['routing']['rules'] as List).cast<Map>();

    // 1. System control rules preserved
    expect(rules.any((r) => r['port'] == '53'), isTrue);
    expect(rules.any((r) => r['outboundTag'] == 'block'), isTrue);

    // 2. Shared private LAN CIDRs STILL DIRECT in Global proxy mode!
    final privateIp = rules.indexWhere(
      (r) =>
          r['outboundTag'] == 'direct' &&
          r['ip'] != null &&
          (r['ip'] as List).contains('192.168.0.0/16'),
    );
    expect(privateIp, greaterThanOrEqualTo(0));

    // 3. Shared minimal system connectivity STILL DIRECT in Global proxy mode!
    final sysConn = rules.indexWhere(
      (r) =>
          r['outboundTag'] == 'direct' &&
          r['domain'] != null &&
          (r['domain'] as List).contains('full:localhost'),
    );
    expect(sysConn, greaterThanOrEqualTo(0));

    // 4. CN domain rules are OMITTED in Global proxy mode (traffic routes to proxy)
    expect(
      rules.any((r) =>
          r['outboundTag'] == 'direct' &&
          r['domain'] != null &&
          (r['domain'] as List).contains('domain:cn')),
      isFalse,
    );
    expect(
      rules.any((r) =>
          r['outboundTag'] == 'direct' &&
          r['domain'] != null &&
          (r['domain'] as List).contains('domain:baidu.com')),
      isFalse,
    );
    expect(
      rules.any((r) =>
          r['outboundTag'] == 'direct' &&
          r['domain'] != null &&
          (r['domain'] as List).contains('domain:apple.com')),
      isFalse,
    );

    // 5. NO rogue global interception rule preceding private CIDRs
    expect(
      rules.any((r) =>
          r['ruleTag'] == 'xconnect-global-tunnel-traffic' ||
          (r['outboundTag'] == 'proxy' &&
              r['network'] == 'tcp,udp' &&
              r['port'] == null)),
      isFalse,
    );

    // 6. Idempotence of Global mode compilation
    final globalRouting = jsonEncode(candidate['routing']);
    VpnConfig.applySecureDnsConfig(candidate,
        enableTunnelMode: true,
        forceBlockQuic: true,
        routeAllTunnelTraffic: true);
    expect(jsonEncode(candidate['routing']), globalRouting);

    // 7. Switching back to Smart mode restores exact baseline
    VpnConfig.applySecureDnsConfig(candidate,
        enableTunnelMode: true, forceBlockQuic: true);
    expect(jsonEncode(candidate['routing']), baseline);
  });

  test('offline CN domain ruleset metadata and matching verification', () {
    expect(CnDomainRules.version, isNotEmpty);
    expect(CnDomainRules.license, contains('CC-BY-SA'));
    expect(CnDomainRules.source, contains('domain-list-community'));
    expect(CnDomainRules.defaultRules.length, greaterThan(50));

    // Must match CN domains
    expect(CnDomainRules.matches('example.cn'), isTrue);
    expect(CnDomainRules.matches('sub.baidu.com'), isTrue);
    expect(CnDomainRules.matches('weixin.qq.com'), isTrue);
    expect(CnDomainRules.matches('taobao.com'), isTrue);
    expect(CnDomainRules.matches('bilibili.com'), isTrue);
    expect(CnDomainRules.matches('apple.com'), isTrue);

    // Must NOT match overseas non-CN public domains
    expect(CnDomainRules.matches('google.com'), isFalse);
    expect(CnDomainRules.matches('github.com'), isFalse);
    expect(CnDomainRules.matches('youtube.com'), isFalse);
    expect(CnDomainRules.matches('netflix.com'), isFalse);
  });

  test('active mode tracking and pending restart status', () async {
    SharedPreferences.setMockInitialValues({});
    await TrafficRouting.init();
    expect(TrafficRouting.activeMode.value, isNull);
    expect(TrafficRouting.isPendingRestart, isFalse);

    // Set active mode when tunnel starts
    TrafficRouting.markActiveMode(TrafficMode.smart);
    expect(TrafficRouting.activeMode.value, TrafficMode.smart);
    expect(TrafficRouting.isPendingRestart, isFalse);

    // User switches mode while tunnel is active -> pending restart is true
    await TrafficRouting.select(TrafficMode.allVpn);
    expect(TrafficRouting.selected.value, TrafficMode.allVpn);
    expect(TrafficRouting.activeMode.value, TrafficMode.smart);
    expect(TrafficRouting.isPendingRestart, isTrue);

    // Tunnel reconnects with the new mode -> pending restart clears
    TrafficRouting.markActiveMode(TrafficMode.allVpn);
    expect(TrafficRouting.isPendingRestart, isFalse);

    // Tunnel disconnects
    TrafficRouting.markActiveMode(null);
    expect(TrafficRouting.activeMode.value, isNull);
    expect(TrafficRouting.isPendingRestart, isFalse);
  });
}
