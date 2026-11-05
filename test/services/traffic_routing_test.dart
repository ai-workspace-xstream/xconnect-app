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
      'global TUN routing follows DNS and QUIC and precedes business direct rules',
      () {
    final config = standardConfig();
    VpnConfig.applySecureDnsConfig(config,
        enableTunnelMode: true, forceBlockQuic: true);
    final baseline = jsonEncode(config['routing']);
    final candidate = jsonDecode(jsonEncode(config)) as Map<String, dynamic>;
    VpnConfig.applySecureDnsConfig(candidate,
        enableTunnelMode: true,
        forceBlockQuic: true,
        routeAllTunnelTraffic: true);
    final rules = (candidate['routing']['rules'] as List).cast<Map>();
    final global = rules.indexWhere((rule) =>
        rule['outboundTag'] == 'proxy' &&
        rule['network'] == 'tcp,udp' &&
        rule['port'] == null);
    final dns = rules.indexWhere((rule) => rule['port'] == '53');
    final quic = rules.lastIndexWhere((rule) => rule['outboundTag'] == 'block');
    final direct = rules.indexWhere(
        (rule) => rule['outboundTag'] == 'direct' && rule.containsKey('ip'));
    expect(dns, greaterThanOrEqualTo(0));
    expect(quic, greaterThanOrEqualTo(0));
    expect(global, greaterThan(dns));
    expect(global, greaterThan(quic));
    expect(global, lessThan(direct));
    expect(rules[global]['inboundTag'], ['tun-in']);
    expect(
        rules.where((rule) =>
            rule['outboundTag'] == 'direct' && rule.containsKey('ip')),
        hasLength(1));
    expect(jsonEncode(config['routing']), baseline);

    final globalRouting = jsonEncode(candidate['routing']);
    VpnConfig.applySecureDnsConfig(candidate,
        enableTunnelMode: true,
        forceBlockQuic: true,
        routeAllTunnelTraffic: true);
    expect(jsonEncode(candidate['routing']), globalRouting);
    VpnConfig.applySecureDnsConfig(candidate,
        enableTunnelMode: true, forceBlockQuic: true);
    expect(jsonEncode(candidate['routing']), baseline);
  });
}
