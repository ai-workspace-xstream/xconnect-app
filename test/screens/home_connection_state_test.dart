import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/screens/home_screen.dart';

/// Pixel 7a (lynx, Android 17 / SDK 37), 2026-09-20 — the 假绿 incident.
///
/// `startPacketTunnel` answers `vpn_permission_requested` the moment it
/// launches the system consent dialog. That message is a legitimately
/// *accepted* start, so the node was marked active and the card went green
/// while `appops ACTIVATE_VPN` stayed `ignore`, no tunnel service ran and
/// `ip link` showed no tun device. The tunnel's own state is the authority.
void main() {
  group('hasLiveTunnel', () {
    test('no node selected is never live', () {
      expect(
        hasLiveTunnel(
          activeNode: '',
          requiresPacketTunnelStatus: true,
          packetTunnelStatus: 'connected',
        ),
        isFalse,
      );
      expect(
        hasLiveTunnel(
          activeNode: '   ',
          requiresPacketTunnelStatus: true,
          packetTunnelStatus: 'connected',
        ),
        isFalse,
      );
    });

    test('a node awaiting VPN consent is not live', () {
      expect(
        hasLiveTunnel(
          activeNode: 'tky-proxy.svc.plus',
          requiresPacketTunnelStatus: true,
          packetTunnelStatus: 'connecting',
        ),
        isFalse,
      );
    });

    test('a node the OS denied is not live', () {
      expect(
        hasLiveTunnel(
          activeNode: 'tky-proxy.svc.plus',
          requiresPacketTunnelStatus: true,
          packetTunnelStatus: 'invalid',
        ),
        isFalse,
      );
    });

    test('a node with a connected tunnel is live', () {
      expect(
        hasLiveTunnel(
          activeNode: 'tky-proxy.svc.plus',
          requiresPacketTunnelStatus: true,
          packetTunnelStatus: 'connected',
        ),
        isTrue,
      );
    });

    test('platforms without packet-tunnel status keep trusting the node', () {
      // Desktop proxy mode has no tunnel state to consult.
      for (final status in ['', 'not_configured', 'invalid', 'connected']) {
        expect(
          hasLiveTunnel(
            activeNode: 'tky-proxy.svc.plus',
            requiresPacketTunnelStatus: false,
            packetTunnelStatus: status,
          ),
          isTrue,
          reason: 'status "$status" must not gate a non-tunnel platform',
        );
      }
    });

    test('no packet-tunnel state ever reads as live by accident', () {
      const notConnected = [
        'connecting',
        'disconnected',
        'disconnecting',
        'invalid',
        'not_configured',
        'reasserting',
        'unsupported',
        '',
      ];
      for (final status in notConnected) {
        expect(
          hasLiveTunnel(
            activeNode: 'tky-proxy.svc.plus',
            requiresPacketTunnelStatus: true,
            packetTunnelStatus: status,
          ),
          isFalse,
          reason: '"$status" must not paint the card green',
        );
      }
    });
  });

  group('shouldStopInsteadOfStart', () {
    test('a live tunnel on the tapped node stops', () {
      expect(
        shouldStopInsteadOfStart(
          activeNode: 'tky-proxy.svc.plus',
          tappedNode: 'tky-proxy.svc.plus',
          hasLiveTunnel: true,
          tunnelPending: false,
        ),
        isTrue,
      );
    });

    test('a tunnel still coming up stops, so the user can cancel', () {
      expect(
        shouldStopInsteadOfStart(
          activeNode: 'tky-proxy.svc.plus',
          tappedNode: 'tky-proxy.svc.plus',
          hasLiveTunnel: false,
          tunnelPending: true,
        ),
        isTrue,
      );
    });

    test('a failed tunnel on the same node starts again, never stops', () {
      // The card and the button both read 已断开/开始连接 here. Branching on
      // the selected node alone ran a disconnect behind a button that said
      // connect, so the tunnel could never be retried after a failure
      // (Pixel 7a, 2026-09-20).
      expect(
        shouldStopInsteadOfStart(
          activeNode: 'tky-proxy.svc.plus',
          tappedNode: 'tky-proxy.svc.plus',
          hasLiveTunnel: false,
          tunnelPending: false,
        ),
        isFalse,
      );
    });

    test('a different node is always a start', () {
      for (final live in [true, false]) {
        expect(
          shouldStopInsteadOfStart(
            activeNode: 'tky-proxy.svc.plus',
            tappedNode: 'sin-proxy.svc.plus',
            hasLiveTunnel: live,
            tunnelPending: live,
          ),
          isFalse,
        );
      }
    });

    test('the action always agrees with what the button shows', () {
      // The button says stop exactly when hasLiveTunnel || tunnelPending.
      for (final live in [true, false]) {
        for (final pending in [true, false]) {
          expect(
            shouldStopInsteadOfStart(
              activeNode: 'n',
              tappedNode: 'n',
              hasLiveTunnel: live,
              tunnelPending: pending,
            ),
            live || pending,
          );
        }
      }
    });
  });
}
