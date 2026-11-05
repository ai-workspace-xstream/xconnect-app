import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
      'global TUN routing preserves system rules and omits business direct rules',
      () {
    final config = standardConfig();
    VpnConfig.applySecureDnsConfig(config,
        enableTunnelMode: true, forceBlockQuic: true);
    final baseline = jsonEncode(config['routing']);

    // Baseline (Smart mode): contains DNS, QUIC, and direct domain/IP rules
    final baseRules = (config['routing']['rules'] as List).cast<Map>();
    expect(baseRules.any((r) => r['port'] == '53'), isTrue);
    expect(baseRules.any((r) => r['outboundTag'] == 'block'), isTrue);
    expect(
      baseRules
          .any((r) => r['outboundTag'] == 'direct' && r.containsKey('domain')),
      isTrue,
    );
    expect(
      baseRules.any((r) => r['outboundTag'] == 'direct' && r.containsKey('ip')),
      isTrue,
    );

    // Candidate (Global mode, routeAllTunnelTraffic == true)
    final candidate = jsonDecode(jsonEncode(config)) as Map<String, dynamic>;
    VpnConfig.applySecureDnsConfig(candidate,
        enableTunnelMode: true,
        forceBlockQuic: true,
        routeAllTunnelTraffic: true);
    final rules = (candidate['routing']['rules'] as List).cast<Map>();

    // System rules must be preserved
    final dns = rules.indexWhere((rule) => rule['port'] == '53');
    final quic = rules.lastIndexWhere((rule) => rule['outboundTag'] == 'block');
    expect(dns, greaterThanOrEqualTo(0));
    expect(quic, greaterThanOrEqualTo(0));
    // Resolver system direct rules (tagged by inbound) must be preserved
    expect(
      rules.any((r) =>
          r['outboundTag'] == 'direct' &&
          (r['inboundTag'] as List?)?.contains('dns-direct-primary') == true),
      isTrue,
    );

    // Business direct domain/IP rules must be completely omitted in Global mode
    expect(
      rules.any((r) => r['outboundTag'] == 'direct' && r.containsKey('domain')),
      isFalse,
    );
    expect(
      rules.any((r) => r['outboundTag'] == 'direct' && r.containsKey('ip')),
      isFalse,
    );

    // Global routing configuration is idempotent
    final globalRouting = jsonEncode(candidate['routing']);
    VpnConfig.applySecureDnsConfig(candidate,
        enableTunnelMode: true,
        forceBlockQuic: true,
        routeAllTunnelTraffic: true);
    expect(jsonEncode(candidate['routing']), globalRouting);

    // Reverting to Smart mode restores the exact baseline
    VpnConfig.applySecureDnsConfig(candidate,
        enableTunnelMode: true, forceBlockQuic: true);
    expect(jsonEncode(candidate['routing']), baseline);
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
