import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/services/vpn_config_service.dart';

void main() {
  group('desktop tunnel inbound settings', () {
    test('Windows lets the OS address the stable automatically-routed TUN', () {
      expect(VpnConfig.tunnelInboundSettingsForOperatingSystem('windows'), {
        'mtu': 1500,
        'name': 'XConnect',
        'autoSystemRoutingTable': ['0.0.0.0/0', '::/0'],
        'autoOutboundsInterface': 'auto',
      });
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
