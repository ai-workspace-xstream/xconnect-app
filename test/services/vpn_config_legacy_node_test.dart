import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/services/vpn_config_service.dart';

void main() {
  group('legacy compatibility node', () {
    test('matches the retired name without case or whitespace variance', () {
      expect(
        VpnConfig.isLegacyCompatibilityNodeName(' tky-proxy.svc.plus '),
        isTrue,
      );
      expect(
        VpnConfig.isLegacyCompatibilityNodeName('TKY-PROXY.SVC.PLUS'),
        isTrue,
      );
      expect(VpnConfig.isLegacyCompatibilityNodeName('jp'), isFalse);
    });
  });
}
