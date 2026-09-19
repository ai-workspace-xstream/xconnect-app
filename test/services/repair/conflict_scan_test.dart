import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/services/diagnostics/live_metrics.dart';
import 'package:xconnect/services/repair/conflict_scan.dart';

// Captured on the incident Mac, 2026-09-19.
const ncList =
    'Available network connection services in the current set (*=enabled):\n'
    '* (Disconnected)   0B2B2695-E60B-43BC-9FDF-12063575ADE8 VPN (plus.svc.xconnect) "Xstream"                        [VPN:plus.svc.xconnect]\n'
    '* (Connected)      E53202A0-57F6-448F-9920-3C180D85509B VPN (net.yuandev.onexray) "OneXray"                        [VPN:net.yuandev.onexray]\n';

const services = 'An asterisk (*) denotes that a network service is disabled.\n'
    'Thunderbolt Bridge\n'
    'Wi-Fi\n'
    '*iPhone USB\n'
    'Xstream\n'
    'OneXray\n';

const proxyOff = '<dictionary> {\n'
    '  ExcludeSimpleHostnames : 0\n'
    '  HTTPEnable : 0\n'
    '  SOCKSEnable : 0\n'
    '}\n';

const proxyStale = '<dictionary> {\n'
    '  SOCKSEnable : 1\n'
    '  SOCKSPort : 1080\n'
    '  SOCKSProxy : 127.0.0.1\n'
    '}\n';

MacScanInputs inputs({
  String nc = ncList,
  Map<String, String> dns = const {
    'Wi-Fi': '1.1.1.1\n8.8.8.8\n',
    'Thunderbolt Bridge':
        "There aren't any DNS Servers set on Thunderbolt Bridge.\n",
  },
  String proxy = proxyOff,
  bool ourPortListening = false,
  List<String> launchDaemons = const [],
  List<String> applications = const [],
}) =>
    MacScanInputs(
      ncList: nc,
      networkServices: services,
      dnsByService: dns,
      proxy: proxy,
      ourSocksPort: 1080,
      ourSocksPortListening: ourPortListening,
      launchDaemons: launchDaemons,
      applications: applications,
      ownBundleId: 'plus.svc.xconnect',
    );

void main() {
  group('parsers', () {
    test('scutil --nc list yields name, bundle and state', () {
      final vpns = parseScutilNcList(ncList);
      expect(vpns, hasLength(2));
      expect(vpns[1].name, 'OneXray');
      expect(vpns[1].bundleId, 'net.yuandev.onexray');
      expect(vpns[1].connected, isTrue);
      expect(vpns[0].connected, isFalse);
    });

    test('network services skip the header and disabled entries', () {
      expect(
        parseNetworkServices(services),
        ['Thunderbolt Bridge', 'Wi-Fi', 'Xstream', 'OneXray'],
      );
    });

    test('DNS servers: IPs listed, the "aren\'t any" sentence is empty', () {
      expect(parseDnsServers('1.1.1.1\n8.8.8.8\n'), ['1.1.1.1', '8.8.8.8']);
      expect(
        parseDnsServers("There aren't any DNS Servers set on Wi-Fi.\n"),
        isEmpty,
      );
    });

    test('scutil --proxy SOCKS fields', () {
      final p = parseScutilProxy(proxyStale);
      expect(p.socksEnabled, isTrue);
      expect(p.socksHost, '127.0.0.1');
      expect(p.socksPort, 1080);
      expect(parseScutilProxy(proxyOff).socksEnabled, isFalse);
    });
  });

  group('scanMac', () {
    test('the incident Mac: another VPN connected and Wi-Fi manual DNS', () {
      final findings = scanMac(inputs());
      final kinds = findings.map((f) => f.kind).toList();
      expect(kinds, contains(FindingKind.otherVpnConnected));
      expect(kinds, contains(FindingKind.manualDns));

      final vpn =
          findings.singleWhere((f) => f.kind == FindingKind.otherVpnConnected);
      expect(vpn.subject, 'OneXray');
      expect(vpn.thirdParty, isTrue);
      expect(vpn.fix, isNull, reason: 'never offer to change another vendor');

      final dns = findings.singleWhere((f) => f.kind == FindingKind.manualDns);
      expect(dns.subject, 'Wi-Fi');
      expect(dns.detail, '1.1.1.1, 8.8.8.8');
      expect(dns.fix, RepairActionId.resetManualDns);
    });

    test('our own disconnected profile is not a conflict', () {
      final findings = scanMac(inputs(
          nc: ncList.replaceAll(
              '* (Connected)      E53202A0', '* (Disconnected)   E53202A0')));
      expect(findings.map((f) => f.kind),
          isNot(contains(FindingKind.otherVpnConnected)));
    });

    test('our SOCKS proxy with nothing listening is stale and ours to fix', () {
      final findings = scanMac(inputs(proxy: proxyStale));
      final stale =
          findings.singleWhere((f) => f.kind == FindingKind.staleProxy);
      expect(stale.thirdParty, isFalse);
      expect(stale.fix, RepairActionId.repairTunnel);
    });

    test('our proxy while the port is listening is fine', () {
      final findings =
          scanMac(inputs(proxy: proxyStale, ourPortListening: true));
      expect(
          findings.map((f) => f.kind), isNot(contains(FindingKind.staleProxy)));
    });

    test('UU helper without the UU app is an orphan for the user', () {
      final findings = scanMac(inputs(
        launchDaemons: ['com.netease.uumac.helper.plist', 'com.apple.x.plist'],
      ));
      final orphan =
          findings.singleWhere((f) => f.kind == FindingKind.orphanHelper);
      expect(orphan.subject, contains('UU'));
      expect(orphan.fix, isNull);
      expect(orphan.manual, isTrue);
    });

    test('UU helper with the app installed is not reported', () {
      final findings = scanMac(inputs(
        launchDaemons: ['com.netease.uumac.helper.plist'],
        applications: ['UU加速器.app'],
      ));
      expect(findings.map((f) => f.kind),
          isNot(contains(FindingKind.orphanHelper)));
    });
  });

  group('shellQuote', () {
    test('quotes service names safely', () {
      expect(shellQuote('Wi-Fi'), '"Wi-Fi"');
      expect(shellQuote(r'My "Office" $LAN`x`'), r'"My \"Office\" \$LAN\`x\`"');
    });
  });

  group('common findings', () {
    test('a TUN answering locally is a conflict everywhere', () {
      final f = commonFindings(
        canary: const ProbeSample.reached(Duration.zero),
        tunnelLastError: null,
      );
      expect(f.single.kind, FindingKind.tunnelInterception);
    });

    test('a denied profile save is reported for the user to handle', () {
      final f = commonFindings(
        canary: const ProbeSample.timedOut(),
        tunnelLastError:
            'profile-save-failed: domain=NEVPNErrorDomain, code=5, message=permission denied',
      );
      final denied = f.single;
      expect(denied.kind, FindingKind.profileSaveDenied);
      expect(denied.manual, isTrue);
    });
  });
}
