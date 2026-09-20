import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/utils/native_bridge.dart';

void main() {
  group('NativeBridge.isTunnelStartAcceptedMessage', () {
    test('accepts Android pending and submitted messages', () {
      expect(
        NativeBridge.isTunnelStartAcceptedMessage('vpn_permission_requested'),
        isTrue,
      );
      expect(
        NativeBridge.isTunnelStartAcceptedMessage('start_submitted'),
        isTrue,
      );
    });

    test('rejects explicit failures', () {
      expect(
        NativeBridge.isTunnelStartAcceptedMessage(
          '启动失败: vpn_permission_denied',
        ),
        isFalse,
      );
      expect(
        NativeBridge.isTunnelStartAcceptedMessage('xray_start_failed'),
        isFalse,
      );
    });
  });

  group('NativeBridge.packetTunnelOccupiesVpnSlot', () {
    test('a connected tunnel owns the slot', () {
      expect(
        NativeBridge.packetTunnelOccupiesVpnSlot(status: 'connected'),
        isTrue,
      );
    });

    test('a tunnel genuinely coming up owns the slot', () {
      expect(
        NativeBridge.packetTunnelOccupiesVpnSlot(status: 'connecting'),
        isTrue,
      );
    });

    test('a start still awaiting VPN consent owns nothing', () {
      // Pixel 7a, 2026-09-20: the system consent dialog never delivered a
      // result, so the state stayed 'connecting' and proxy mode was blocked
      // behind "Packet Tunnel 已在运行" with no tunnel in sight.
      expect(
        NativeBridge.packetTunnelOccupiesVpnSlot(
          status: 'connecting',
          lastError: 'vpn_permission_required',
        ),
        isFalse,
      );
    });

    test('no idle or failed state ever blocks proxy mode', () {
      for (final status in [
        'disconnected',
        'disconnecting',
        'invalid',
        'not_configured',
        'unsupported',
        'unknown',
      ]) {
        expect(
          NativeBridge.packetTunnelOccupiesVpnSlot(status: status),
          isFalse,
          reason: '"$status" must not block the proxy',
        );
      }
    });
  });
}
