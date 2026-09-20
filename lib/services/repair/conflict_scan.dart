import 'dart:io';

import '../diagnostics/live_diagnosis_controller.dart' show tcpConnectProbe;
import '../diagnostics/live_metrics.dart';

/// What the scanner can find (see docs/design/network-self-repair.md §1).
enum FindingKind {
  /// C1: a TUN is answering TCP handshakes locally.
  tunnelInterception,

  /// C1/C4: another app's VPN profile is connected (macOS).
  otherVpnConnected,

  /// D2: a network service has DNS servers pinned by hand.
  manualDns,

  /// T1: the system SOCKS proxy points at our port but nothing listens.
  staleProxy,

  /// C3: a known accelerator left a root helper behind after uninstall.
  orphanHelper,

  /// T4: the OS refused to save our VPN profile (signing / consent).
  profileSaveDenied,

  /// A1: Android has not granted VpnService consent, so no tunnel can start.
  vpnConsentMissing,

  /// A2: `always_on_vpn_app` still names a package that cannot use it.
  ///
  /// The key lives in Settings.Secure and only the system may write it, so an
  /// uninstall leaves it behind and no app can clear it. Detect and guide.
  alwaysOnVpnResidual,

  /// A3: we report a live tunnel while the OS carries no VPN transport.
  tunnelStateMismatch,
}

enum RepairActionId {
  flushDnsCache,
  resetManualDns,
  repairTunnel,
  grantVpnConsent,
  clearAlwaysOnVpn,
}

class ConflictFinding {
  const ConflictFinding({
    required this.kind,
    this.subject,
    this.detail,
    this.thirdParty = false,
    this.manual = false,
    this.fix,
  });

  final FindingKind kind;

  /// The thing concerned: a VPN name, a network service, a helper.
  final String? subject;
  final String? detail;

  /// Belongs to another vendor: shown, never modified.
  final bool thirdParty;

  /// Only the user can resolve it (uninstaller, signing, system settings).
  final bool manual;
  final RepairActionId? fix;
}

typedef ScutilVpn = ({String name, String bundleId, bool connected});

final _ncLine = RegExp(
  r'\((\w+)\)\s+\S+\s+\S+\s+\(([^)]+)\)\s+"([^"]*)"',
);

List<ScutilVpn> parseScutilNcList(String output) => [
      for (final m in _ncLine.allMatches(output))
        (
          name: m.group(3)!,
          bundleId: m.group(2)!,
          connected: m.group(1) == 'Connected',
        ),
    ];

List<String> parseNetworkServices(String output) => [
      for (final line in output.split('\n').skip(1))
        if (line.trim().isNotEmpty && !line.startsWith('*')) line.trim(),
    ];

final _ipv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');

List<String> parseDnsServers(String output) => [
      for (final line in output.split('\n'))
        if (_ipv4.hasMatch(line.trim()) || line.trim().contains(':'))
          if (!line.contains(' ')) line.trim(),
    ];

({bool socksEnabled, String? socksHost, int? socksPort}) parseScutilProxy(
  String output,
) {
  String? field(String key) {
    final m = RegExp('^\\s*$key : (.+)\$', multiLine: true).firstMatch(output);
    return m?.group(1)?.trim();
  }

  return (
    socksEnabled: field('SOCKSEnable') == '1',
    socksHost: field('SOCKSProxy'),
    socksPort: int.tryParse(field('SOCKSPort') ?? ''),
  );
}

/// Root helpers that known accelerators install and do not always remove.
/// Each maps a LaunchDaemon plist to the product name and a substring of its
/// app bundle name, so an installed app suppresses the finding.
const _knownHelpers = <String, ({String product, String appHint})>{
  'com.netease.uumac.helper.plist': (product: '网易 UU 加速器', appHint: 'UU'),
};

class MacScanInputs {
  const MacScanInputs({
    required this.ncList,
    required this.networkServices,
    required this.dnsByService,
    required this.proxy,
    required this.ourSocksPort,
    required this.ourSocksPortListening,
    required this.launchDaemons,
    required this.applications,
    required this.ownBundleId,
  });

  final String? ncList;
  final String? networkServices;
  final Map<String, String> dnsByService;
  final String? proxy;
  final int ourSocksPort;
  final bool ourSocksPortListening;
  final List<String> launchDaemons;
  final List<String> applications;
  final String ownBundleId;
}

List<ConflictFinding> scanMac(MacScanInputs input) {
  final findings = <ConflictFinding>[];

  for (final vpn in parseScutilNcList(input.ncList ?? '')) {
    if (vpn.connected && vpn.bundleId != input.ownBundleId) {
      findings.add(ConflictFinding(
        kind: FindingKind.otherVpnConnected,
        subject: vpn.name,
        detail: vpn.bundleId,
        thirdParty: true,
      ));
    }
  }

  for (final entry in input.dnsByService.entries) {
    final servers = parseDnsServers(entry.value);
    if (servers.isEmpty) continue;
    findings.add(ConflictFinding(
      kind: FindingKind.manualDns,
      subject: entry.key,
      detail: servers.join(', '),
      fix: RepairActionId.resetManualDns,
    ));
  }

  final proxy = parseScutilProxy(input.proxy ?? '');
  final pointsAtUs = proxy.socksEnabled &&
      (proxy.socksHost == '127.0.0.1' || proxy.socksHost == 'localhost') &&
      proxy.socksPort == input.ourSocksPort;
  if (pointsAtUs && !input.ourSocksPortListening) {
    findings.add(ConflictFinding(
      kind: FindingKind.staleProxy,
      subject: '${proxy.socksHost}:${proxy.socksPort}',
      fix: RepairActionId.repairTunnel,
    ));
  }

  for (final plist in input.launchDaemons) {
    final known = _knownHelpers[plist];
    if (known == null) continue;
    final appPresent =
        input.applications.any((app) => app.contains(known.appHint));
    if (appPresent) continue;
    findings.add(ConflictFinding(
      kind: FindingKind.orphanHelper,
      subject: known.product,
      detail: '/Library/LaunchDaemons/$plist',
      thirdParty: true,
      manual: true,
    ));
  }

  return findings;
}

/// The read-only Android state [scanAndroid] needs.
///
/// Every field comes from a public API: [vpnConsentGranted] from
/// `VpnService.prepare(context) == null`, [vpnTransportActive] from a network
/// with `TRANSPORT_VPN`. [alwaysOnVpnPackage] reads an `@hide` Settings.Secure
/// key, so it is nullable and a null means "could not read", never "unset".
class AndroidScanInputs {
  const AndroidScanInputs({
    required this.vpnConsentGranted,
    required this.vpnTransportActive,
    required this.reportedStatus,
    required this.ownPackage,
    this.alwaysOnVpnPackage,
  });

  final bool vpnConsentGranted;
  final bool vpnTransportActive;

  /// PacketTunnelController's own state string.
  final String reportedStatus;
  final String ownPackage;
  final String? alwaysOnVpnPackage;
}

/// Interface names a VpnService tunnel takes on Android.
///
/// Android names a VpnService device `tun<N>`; the legacy and IPsec stacks use
/// `ppp<N>` and `ipsec<N>`. Matching the name is enough to tell a live tunnel
/// from the app merely claiming one — on the Pixel 7a the card read 已连接
/// while `ip link` listed none of these.
final _vpnInterfaceName = RegExp(r'^(tun|ppp|ipsec)\d*$');

bool isVpnInterfaceName(String name) => _vpnInterfaceName.hasMatch(name);

/// Whether the OS currently carries a VPN interface.
///
/// Returns false when the list cannot be read: a scan must not invent a
/// tunnel it could not see.
Future<bool> hasVpnInterface({
  Future<List<NetworkInterface>> Function()? list,
}) async {
  try {
    final interfaces = await (list ?? () => NetworkInterface.list())();
    return interfaces.any((i) => isVpnInterfaceName(i.name));
  } catch (_) {
    return false;
  }
}

/// Android conflicts, from the Pixel 7a incident (2026-09-20).
///
/// The three findings are ordered by what blocks the user first: without
/// consent nothing can start, so it is reported before the state mismatch it
/// causes.
List<ConflictFinding> scanAndroid(AndroidScanInputs input) {
  final findings = <ConflictFinding>[];

  if (!input.vpnConsentGranted) {
    findings.add(const ConflictFinding(
      kind: FindingKind.vpnConsentMissing,
      manual: true,
      fix: RepairActionId.grantVpnConsent,
    ));
  }

  // 假绿: the home screen is green while no VPN transport carries traffic.
  // Only `connected` counts; `connecting` legitimately has no transport yet.
  if (input.reportedStatus == 'connected' && !input.vpnTransportActive) {
    findings.add(const ConflictFinding(
      kind: FindingKind.tunnelStateMismatch,
      fix: RepairActionId.repairTunnel,
    ));
  }

  // Residue is only meaningful when the always-on package cannot actually be
  // serving: with consent and a live transport this is the normal setup.
  final alwaysOn = input.alwaysOnVpnPackage;
  if (alwaysOn != null &&
      alwaysOn.isNotEmpty &&
      !input.vpnConsentGranted &&
      !input.vpnTransportActive) {
    findings.add(ConflictFinding(
      kind: FindingKind.alwaysOnVpnResidual,
      subject: alwaysOn,
      thirdParty: alwaysOn != input.ownPackage,
      manual: true,
      fix: RepairActionId.clearAlwaysOnVpn,
    ));
  }

  return findings;
}

/// Findings every platform can produce.
List<ConflictFinding> commonFindings({
  required ProbeSample canary,
  required String? tunnelLastError,
}) {
  final error = tunnelLastError?.toLowerCase() ?? '';
  return [
    if (canary.answered)
      const ConflictFinding(
        kind: FindingKind.tunnelInterception,
        thirdParty: true,
      ),
    if (error.contains('profile-save-failed') ||
        error.contains('permission denied'))
      const ConflictFinding(kind: FindingKind.profileSaveDenied, manual: true),
  ];
}

/// Double-quotes [value] for a POSIX shell, escaping what stays live inside
/// double quotes. Used only for commands the user copies, never executed.
String shellQuote(String value) {
  final escaped = value.replaceAllMapped(
    RegExp(r'[\\"$`]'),
    (m) => '\\${m.group(0)}',
  );
  return '"$escaped"';
}

typedef CommandRunner = Future<String?> Function(String exe, List<String> args);

Future<String?> runReadOnly(String exe, List<String> args) async {
  try {
    final r = await Process.run(exe, args);
    return r.exitCode == 0 ? r.stdout.toString() : null;
  } catch (_) {
    return null;
  }
}

/// Collects the read-only system state [scanMac] needs.
Future<MacScanInputs> gatherMacInputs({
  required int ourSocksPort,
  required String ownBundleId,
  CommandRunner run = runReadOnly,
}) async {
  final servicesOut =
      await run('/usr/sbin/networksetup', ['-listallnetworkservices']);
  final dns = <String, String>{};
  for (final service in parseNetworkServices(servicesOut ?? '')) {
    final out =
        await run('/usr/sbin/networksetup', ['-getdnsservers', service]);
    if (out != null) dns[service] = out;
  }
  final listening = (await tcpConnectProbe('127.0.0.1', ourSocksPort)).answered;

  List<String> list(String dir) {
    try {
      return [
        for (final e in Directory(dir).listSync())
          e.uri.pathSegments.where((s) => s.isNotEmpty).last,
      ];
    } catch (_) {
      return const [];
    }
  }

  return MacScanInputs(
    ncList: await run('/usr/sbin/scutil', ['--nc', 'list']),
    networkServices: servicesOut,
    dnsByService: dns,
    proxy: await run('/usr/sbin/scutil', ['--proxy']),
    ourSocksPort: ourSocksPort,
    ourSocksPortListening: listening,
    launchDaemons: list('/Library/LaunchDaemons'),
    applications: list('/Applications'),
    ownBundleId: ownBundleId,
  );
}
