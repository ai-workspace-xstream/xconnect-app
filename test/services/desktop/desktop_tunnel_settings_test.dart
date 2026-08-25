import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/services/vpn_config_service.dart';

void main() {
  group('desktop tunnel inbound settings', () {
    test('Windows uses a stable interface and automatic routing', () {
      expect(VpnConfig.tunnelInboundSettingsForOperatingSystem('windows'), {
        'mtu': 1500,
        'name': 'XConnect',
        'gateway': ['198.18.0.2/15', 'fc00::2/64'],
        'dns': ['8.8.8.8', '2001:4860:4860::8888'],
        'autoSystemRoutingTable': ['0.0.0.0/0', '::/0'],
        'autoOutboundsInterface': 'auto',
      });
    });

    test('Linux uses a stable interface and automatic routing', () {
      expect(VpnConfig.tunnelInboundSettingsForOperatingSystem('linux'), {
        'mtu': 1500,
        'name': 'xconnect-tun0',
        'gateway': ['198.18.0.2/15', 'fc00::2/64'],
        'dns': ['8.8.8.8', '2001:4860:4860::8888'],
        'autoSystemRoutingTable': ['0.0.0.0/0', '::/0'],
        'autoOutboundsInterface': 'auto',
      });
    });

    test('Apple settings retain the Packet Tunnel provider shape', () {
      expect(VpnConfig.tunnelInboundSettingsForOperatingSystem('macos'), {
        'mtu': 1500,
      });
    });
  });
}
