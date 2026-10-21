import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/services/vpn_config_service.dart';
import 'package:xconnect/utils/global_config.dart';

void main() {
  group('desktop tunnel inbound settings', () {
    test('Windows supplies interface addresses and selected tunnel DNS', () {
      expect(VpnConfig.tunnelInboundSettingsForOperatingSystem('windows'), {
        'mtu': 1500,
        'name': 'XConnect',
        'gateway': ['198.18.0.1/30', 'fdfe:dcba:9876::1/126'],
        'dns': DnsConfig.systemTunnelDnsServers4(),
        'autoSystemRoutingTable': ['0.0.0.0/0', '::/0'],
        'autoOutboundsInterface': 'auto',
      });
    });

    test('Windows DNS follows current resolver preferences', () {
      final primary = DnsConfig.directDns1.value;
      final secondary = DnsConfig.directDns2.value;
      try {
        DnsConfig.updateDirectServers(primary: '9.9.9.9', secondary: '1.1.1.1');
        final settings =
            VpnConfig.tunnelInboundSettingsForOperatingSystem('windows');
        expect(settings['dns'], ['9.9.9.9', '1.1.1.1']);
      } finally {
        DnsConfig.updateDirectServers(primary: primary, secondary: secondary);
      }
    });

    test('Linux lets the OS address the stable automatically-routed TUN', () {
      expect(VpnConfig.tunnelInboundSettingsForOperatingSystem('linux'), {
        'mtu': 1500,
        'name': 'xconnect-tun0',
        'autoSystemRoutingTable': ['0.0.0.0/0', '::/0'],
        'autoOutboundsInterface': 'auto',
      });
    });

    test('Apple settings retain the Packet Tunnel provider shape', () {
      expect(VpnConfig.tunnelInboundSettingsForOperatingSystem('macos'), {
        'mtu': 1500,
      });
    });

    test('desktop TUN replaces sniffed destinations for the data plane', () {
      expect(
        VpnConfig.tunnelSniffingRouteOnlyForOperatingSystem('windows'),
        isFalse,
      );
      expect(
        VpnConfig.tunnelSniffingRouteOnlyForOperatingSystem('linux'),
        isFalse,
      );
    });

    test('Apple Packet Tunnel keeps route-only sniffing', () {
      expect(
        VpnConfig.tunnelSniffingRouteOnlyForOperatingSystem('macos'),
        isTrue,
      );
      expect(
        VpnConfig.tunnelSniffingRouteOnlyForOperatingSystem('ios'),
        isTrue,
      );
    });
  });
}
