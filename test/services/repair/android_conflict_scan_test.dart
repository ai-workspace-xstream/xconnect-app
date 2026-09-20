import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/services/repair/conflict_scan.dart';

/// Captured on the Pixel 7a (lynx, Android 17 / SDK 37), 2026-09-20.
///
/// The device reached a state the app reported as 已连接 while the OS had
/// never granted VPN consent: `appops get plus.svc.xconnect ACTIVATE_VPN`
/// stayed `ignore`, `dumpsys activity services` listed no tunnel service and
/// `ip link` showed no tun device. `always_on_vpn_app` still named the package
/// after an uninstall, and the package was absent from the system VPN page,
/// so the residue could not be cleared from the phone UI.
AndroidScanInputs inputs({
  bool consentGranted = true,
  bool vpnTransportActive = true,
  String reportedStatus = 'connected',
  String? alwaysOnVpnPackage,
  String ownPackage = 'plus.svc.xconnect',
}) =>
    AndroidScanInputs(
      vpnConsentGranted: consentGranted,
      vpnTransportActive: vpnTransportActive,
      reportedStatus: reportedStatus,
      alwaysOnVpnPackage: alwaysOnVpnPackage,
      ownPackage: ownPackage,
    );

void main() {
  group('scanAndroid — VPN consent', () {
    test('no consent while the app is trying to connect is the blocker', () {
      final findings = scanAndroid(
        inputs(
          consentGranted: false,
          vpnTransportActive: false,
          reportedStatus: 'connecting',
        ),
      );
      final f = findings.singleWhere(
        (f) => f.kind == FindingKind.vpnConsentMissing,
      );
      expect(f.manual, isTrue, reason: 'only the user can accept the dialog');
      expect(f.fix, RepairActionId.grantVpnConsent);
    });

    test('granted consent is not reported', () {
      expect(
        scanAndroid(inputs()).where(
          (f) => f.kind == FindingKind.vpnConsentMissing,
        ),
        isEmpty,
      );
    });
  });

  group('scanAndroid — 假绿', () {
    test('connected without a VPN transport is a state mismatch', () {
      final findings = scanAndroid(
        inputs(consentGranted: false, vpnTransportActive: false),
      );
      final f = findings.singleWhere(
        (f) => f.kind == FindingKind.tunnelStateMismatch,
      );
      expect(f.fix, RepairActionId.repairTunnel);
    });

    test('connected with a live VPN transport is fine', () {
      expect(
        scanAndroid(inputs()).where(
          (f) => f.kind == FindingKind.tunnelStateMismatch,
        ),
        isEmpty,
      );
    });

    test('disconnected without a transport is not a mismatch', () {
      expect(
        scanAndroid(
          inputs(vpnTransportActive: false, reportedStatus: 'disconnected'),
        ).where((f) => f.kind == FindingKind.tunnelStateMismatch),
        isEmpty,
      );
    });
  });

  group('scanAndroid — always-on residue', () {
    test('our package left as always-on while consent is gone is residue', () {
      final findings = scanAndroid(
        inputs(
          consentGranted: false,
          vpnTransportActive: false,
          reportedStatus: 'invalid',
          alwaysOnVpnPackage: 'plus.svc.xconnect',
        ),
      );
      final f = findings.singleWhere(
        (f) => f.kind == FindingKind.alwaysOnVpnResidual,
      );
      expect(f.subject, 'plus.svc.xconnect');
      expect(f.manual, isTrue, reason: 'Settings.Secure is system-owned');
      expect(f.fix, RepairActionId.clearAlwaysOnVpn);
      expect(f.thirdParty, isFalse);
    });

    test('our package as always-on with consent intact is normal', () {
      expect(
        scanAndroid(
          inputs(alwaysOnVpnPackage: 'plus.svc.xconnect'),
        ).where((f) => f.kind == FindingKind.alwaysOnVpnResidual),
        isEmpty,
      );
    });

    test('another vendor holding always-on is reported, never modified', () {
      final findings = scanAndroid(
        inputs(
          consentGranted: false,
          vpnTransportActive: false,
          reportedStatus: 'invalid',
          alwaysOnVpnPackage: 'net.yuandev.onexray',
        ),
      );
      final f = findings.singleWhere(
        (f) => f.kind == FindingKind.alwaysOnVpnResidual,
      );
      expect(f.subject, 'net.yuandev.onexray');
      expect(f.thirdParty, isTrue);
      expect(f.manual, isTrue);
    });

    test('no always-on package set reports nothing', () {
      expect(
        scanAndroid(
          inputs(consentGranted: false, vpnTransportActive: false),
        ).where((f) => f.kind == FindingKind.alwaysOnVpnResidual),
        isEmpty,
      );
    });

    test('an unreadable setting degrades to no finding, not a false alarm', () {
      // Settings.Secure.always_on_vpn_app is @hide; a read can return null on
      // OEM builds. Null must never be reported as "nothing is set".
      expect(
        scanAndroid(
          inputs(
            consentGranted: false,
            vpnTransportActive: false,
            alwaysOnVpnPackage: null,
          ),
        ).where((f) => f.kind == FindingKind.alwaysOnVpnResidual),
        isEmpty,
      );
    });
  });

  group('isVpnInterfaceName', () {
    test('accepts the names Android gives a tunnel', () {
      for (final name in ['tun0', 'tun1', 'tun', 'ppp0', 'ipsec0']) {
        expect(isVpnInterfaceName(name), isTrue, reason: name);
      }
    });

    test('rejects ordinary interfaces', () {
      for (final name in ['wlan0', 'rmnet1', 'lo', 'dummy0', 'tunnel0',
          'rmnet_data0', 'tunl0']) {
        expect(isVpnInterfaceName(name), isFalse, reason: name);
      }
    });
  });
}
