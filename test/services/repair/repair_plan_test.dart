import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/services/repair/conflict_scan.dart';
import 'package:xconnect/services/repair/repair_plan.dart';

void main() {
  const wifiDns = ConflictFinding(
    kind: FindingKind.manualDns,
    subject: 'Wi-Fi',
    detail: '1.1.1.1, 8.8.8.8',
    fix: RepairActionId.resetManualDns,
  );

  test('macOS reset-DNS command covers only services with manual DNS', () {
    final plan = planFor(RepairActionId.resetManualDns,
        os: 'macos', findings: const [wifiDns]);
    expect(plan.mode, RepairMode.guided);
    expect(plan.command, 'sudo networksetup -setdnsservers "Wi-Fi" Empty');
    expect(
        plan.settingsUrl.toString(), startsWith('x-apple.systempreferences:'));
  });

  test('reset-DNS with nothing pinned has nothing to run', () {
    final plan =
        planFor(RepairActionId.resetManualDns, os: 'macos', findings: const []);
    expect(plan.command, isNull);
    expect(plan.nothingToDo, isTrue);
  });

  test('flush-DNS command matches the scripts in scripts/', () {
    expect(planFor(RepairActionId.flushDnsCache, os: 'macos').command,
        'sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder');
    expect(planFor(RepairActionId.flushDnsCache, os: 'windows').command,
        'ipconfig /flushdns');
    expect(planFor(RepairActionId.flushDnsCache, os: 'linux').command,
        'sudo resolvectl flush-caches');
  });

  test('phones get steps, never a shell command', () {
    for (final os in ['ios', 'android']) {
      for (final id in RepairActionId.values) {
        expect(planFor(id, os: os).command, isNull, reason: '$os $id');
      }
    }
  });

  test('repairing our own tunnel runs in the app on every platform', () {
    for (final os in ['macos', 'windows', 'linux', 'ios', 'android']) {
      expect(
          planFor(RepairActionId.repairTunnel, os: os).mode, RepairMode.inApp);
    }
  });

  test('no plan ever deep-links iOS private settings schemes', () {
    for (final id in RepairActionId.values) {
      final url = planFor(id, os: 'ios').settingsUrl?.toString() ?? '';
      expect(url.toLowerCase(), isNot(startsWith('app-prefs')));
      expect(url.toLowerCase(), isNot(startsWith('prefs:')));
    }
  });

  group('android VPN plans', () {
    test('granting consent is guided and never a shell command', () {
      final plan = planFor(RepairActionId.grantVpnConsent, os: 'android');
      expect(plan.mode, RepairMode.guided);
      expect(plan.command, isNull);
    });

    test('clearing always-on is guided with no unlaunchable URL', () {
      final plan = planFor(RepairActionId.clearAlwaysOnVpn, os: 'android');
      expect(plan.mode, RepairMode.guided);
      expect(plan.command, isNull);
      // RepairSection passes settingsUrl to launchUrl; Android has no
      // resolvable VPN-settings URL, so it must stay null.
      expect(plan.settingsUrl, isNull);
    });

    test('every plan on every OS has a launchable scheme or none', () {
      const oses = ['macos', 'windows', 'linux', 'android', 'ios'];
      const launchable = {'x-apple.systempreferences', 'ms-settings', 'http', 'https'};
      for (final os in oses) {
        for (final id in RepairActionId.values) {
          final url = planFor(id, os: os).settingsUrl;
          if (url == null) continue;
          expect(
            launchable,
            contains(url.scheme),
            reason: '$id on $os uses unresolvable scheme "${url.scheme}"',
          );
        }
      }
    });
  });

  group('actionsFor', () {
    test('Android gets the consent and always-on actions', () {
      expect(
        actionsFor('android'),
        containsAll([
          RepairActionId.grantVpnConsent,
          RepairActionId.clearAlwaysOnVpn,
        ]),
      );
    });

    test('other platforms never offer the Android-only actions', () {
      for (final os in ['macos', 'windows', 'linux', 'ios']) {
        expect(
          actionsFor(os),
          isNot(contains(RepairActionId.grantVpnConsent)),
          reason: '$os has no VpnService consent step',
        );
        expect(
          actionsFor(os),
          isNot(contains(RepairActionId.clearAlwaysOnVpn)),
          reason: '$os has no always_on_vpn_app setting',
        );
      }
    });

    test('the shared actions are offered everywhere', () {
      for (final os in ['macos', 'windows', 'linux', 'ios', 'android']) {
        expect(
          actionsFor(os),
          containsAll([
            RepairActionId.flushDnsCache,
            RepairActionId.resetManualDns,
            RepairActionId.repairTunnel,
          ]),
        );
      }
    });
  });
}
