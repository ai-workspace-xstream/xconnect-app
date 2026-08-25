import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/services/vpn_config_service.dart';

void main() {
  group('desktop tunnel inbound settings', () {
    test('Windows uses a stable interface and automatic routing', () {
      expect(VpnConfig.tunnelInboundSettingsForOperatingSystem('windows'), {
        'mtu': 1500,
        'name': 'XConnect',
        'autoRoute': true,
      });
    });

    test('Linux uses a stable interface and automatic routing', () {
      expect(VpnConfig.tunnelInboundSettingsForOperatingSystem('linux'), {
        'mtu': 1500,
        'name': 'xconnect-tun0',
        'autoRoute': true,
      });
    });

    test('Apple settings retain the Packet Tunnel provider shape', () {
      expect(VpnConfig.tunnelInboundSettingsForOperatingSystem('macos'), {
        'mtu': 1500,
      });
    });
  });
}
