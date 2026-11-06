import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xconnect/services/dns/cn_domain_rules.dart';
import 'package:xconnect/services/dns/dns_control_plane.dart';
import 'package:xconnect/services/traffic_routing.dart';
import 'package:xconnect/services/vpn_config_service.dart';
import 'package:xconnect/utils/global_config.dart';
import 'package:xconnect/utils/native_bridge.dart';

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
    expect(CnDomainRules.license, equals('MIT'));
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

  test(
      'legacy config upgrade recognizes legacy generated rule shapes without unsupported error',
      () {
    // Legacy XConnect configuration where system connectivity and Apple domains
    // were bundled in a single direct rule before the split.
    final legacyConfig = standardConfig();
    final legacyRules = <Map<String, dynamic>>[
      {
        'type': 'field',
        'inboundTag': ['tun-in'],
        'network': 'tcp,udp',
        'port': '53',
        'outboundTag': 'proxy',
      },
      {
        'type': 'field',
        'inboundTag': ['tun-in'],
        'network': 'udp',
        'port': '443',
        'outboundTag': 'block',
      },
      {
        'type': 'field',
        'inboundTag': ['tun-in'],
        'protocol': ['quic'],
        'outboundTag': 'block',
      },
      {
        'type': 'field',
        'inboundTag': ['dns-proxy-primary', 'dns-proxy-secondary'],
        'outboundTag': 'proxy',
      },
      {
        'type': 'field',
        'inboundTag': ['dns-direct-primary', 'dns-direct-secondary'],
        'outboundTag': 'direct',
      },
      {
        'type': 'field',
        'domain': DnsConfig.legacyDirectDomains,
        'outboundTag': 'direct',
      },
      {
        'type': 'field',
        'ip': DnsConfig.directIpCidrs,
        'outboundTag': 'direct',
      },
    ];
    legacyConfig['routing']['rules'] = legacyRules;

    // Must be recognized as a valid generated configuration
    expect(VpnConfig.supportsTrafficRouting(legacyConfig), isTrue);

    // Compiling with Global Proxy must succeed and migrate the legacy rule
    VpnConfig.applySecureDnsConfig(
      legacyConfig,
      enableTunnelMode: true,
      forceBlockQuic: true,
      routeAllTunnelTraffic: true,
    );
    expect(VpnConfig.supportsTrafficRouting(legacyConfig), isTrue);

    final migratedRules =
        (legacyConfig['routing']['rules'] as List).cast<Map>();
    // Legacy combined rule is stripped
    expect(
      migratedRules.any((r) =>
          r['domain'] != null &&
          (r['domain'] as List).contains('domain:apple.com')),
      isFalse,
    );
    // Shared private CIDRs and system connectivity are present
    expect(
      migratedRules.any((r) =>
          r['ip'] != null && (r['ip'] as List).contains('192.168.0.0/16')),
      isTrue,
    );
    expect(
      migratedRules.any((r) =>
          r['domain'] != null &&
          (r['domain'] as List).contains('full:localhost')),
      isTrue,
    );

    // Custom user rules outside standard/legacy templates are still rejected
    final customConfig = standardConfig();
    customConfig['routing']['rules'] = [
      ...migratedRules,
      {
        'type': 'field',
        'domain': ['custom.corporate.network'],
        'outboundTag': 'direct',
      }
    ];
    expect(VpnConfig.supportsTrafficRouting(customConfig), isFalse);
  });

  test(
      'Apple system reconnect: tuning refresh preserves saved routing mode and DNS outbound',
      () async {
    SharedPreferences.setMockInitialValues({});
    await TrafficRouting.init();

    // 1. Prepare a persisted config saved in Smart mode
    final config = standardConfig();
    VpnConfig.applySecureDnsConfig(
      config,
      enableTunnelMode: true,
      routeAllTunnelTraffic: false,
    );
    final rawConfig = const JsonEncoder.withIndent('  ').convert(config);

    // 2. User changes preference to Global proxy in UI, but has NOT reconnected
    await TrafficRouting.select(TrafficMode.allVpn);
    expect(TrafficRouting.connectionMode, TrafficMode.allVpn);

    // 3. Background tuning refresh occurs
    final rewritten = NativeBridge.rewritePersistedTunnelConfig(rawConfig);
    // If routing mode was preserved as Smart mode, routing rules remain identical
    if (rewritten != null) {
      final rewrittenMap = jsonDecode(rewritten) as Map<String, dynamic>;
      final isAllVpn = VpnConfig.isRoutingAllTunnelTraffic(
          rewrittenMap['routing'] as Map<String, dynamic>);
      // MUST NOT be allVpn! Must preserve the saved Smart mode!
      expect(isAllVpn, isFalse);
    }

    // 4. Preserve Business DNS outbound tag if configured
    final bizConfig = standardConfig();
    bizConfig['routing']['rules'] = [
      {
        'type': 'field',
        'inboundTag': ['tun-in'],
        'network': 'tcp,udp',
        'port': '53',
        'outboundTag': BusinessDnsPolicy.outboundTag,
      },
      {
        'type': 'field',
        'domain': DnsConfig.legacyDirectDomains,
        'outboundTag': 'direct',
      },
      {
        'type': 'field',
        'ip': DnsConfig.directIpCidrs,
        'outboundTag': 'direct',
      },
    ];
    final rawBiz = const JsonEncoder.withIndent('  ').convert(bizConfig);
    final rewrittenBiz = NativeBridge.rewritePersistedTunnelConfig(rawBiz);
    final rewrittenBizMap =
        jsonDecode(rewrittenBiz ?? rawBiz) as Map<String, dynamic>;
    final dnsTag = VpnConfig.findTunnelDnsOutboundTag(
        rewrittenBizMap['routing'] as Map<String, dynamic>);
    expect(dnsTag, BusinessDnsPolicy.outboundTag);
  });

  test(
      'local HTTP/SOCKS proxy isolation: global VPN preference never strips proxy direct rules',
      () async {
    SharedPreferences.setMockInitialValues({});
    await TrafficRouting.init();
    await TrafficRouting.select(TrafficMode.allVpn);
    expect(TrafficRouting.connectionMode, TrafficMode.allVpn);

    // A node config with custom domain direct rule for local proxy
    final proxyConfig = standardConfig();
    (proxyConfig['routing']['rules'] as List).add({
      'type': 'field',
      'domain': ['internal.corp.com'],
      'outboundTag': 'direct',
    });

    // When preparing for local proxy mode (isTunMode: false)
    VpnConfig.applySecureDnsConfig(
      proxyConfig,
      enableTunnelMode: false,
      routeAllTunnelTraffic: false,
    );

    final rules = (proxyConfig['routing']['rules'] as List).cast<Map>();
    // The custom direct domain rule MUST NOT be deleted
    expect(
      rules.any((r) =>
          r['outboundTag'] == 'direct' &&
          r['domain'] is List &&
          (r['domain'] as List).contains('internal.corp.com')),
      isTrue,
    );
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
