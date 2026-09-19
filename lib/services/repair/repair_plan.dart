import 'conflict_scan.dart';

/// How a repair is carried out (docs/design/network-self-repair.md §4.2).
///
/// `inApp` only touches XConnect's own state. Anything needing admin rights
/// is `guided` until the direct build's privileged helper exists (#89 M4);
/// the Mac App Store build stays guided for good.
enum RepairMode { inApp, guided }

class RepairPlan {
  const RepairPlan({
    required this.id,
    required this.mode,
    required this.stepKeys,
    this.command,
    this.settingsUrl,
    this.nothingToDo = false,
  });

  final RepairActionId id;
  final RepairMode mode;

  /// l10n keys, shown as numbered steps.
  final List<String> stepKeys;

  /// Shown for the user to copy; the app never executes it.
  final String? command;
  final Uri? settingsUrl;
  final bool nothingToDo;
}

RepairPlan planFor(
  RepairActionId id, {
  required String os,
  List<ConflictFinding> findings = const [],
}) {
  final desktop = os == 'macos' || os == 'windows' || os == 'linux';
  final terminalStep = switch (os) {
    'windows' => 'repairStepOpenAdminShell',
    _ => 'repairStepOpenTerminal',
  };

  switch (id) {
    case RepairActionId.flushDnsCache:
      return RepairPlan(
        id: id,
        mode: RepairMode.guided,
        stepKeys: desktop
            ? [terminalStep, 'repairStepPasteCommand', 'repairStepRecheck']
            : const ['repairStepAirplaneMode', 'repairStepRecheck'],
        command: switch (os) {
          'macos' =>
            'sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder',
          'windows' => 'ipconfig /flushdns',
          'linux' => 'sudo resolvectl flush-caches',
          _ => null,
        },
      );

    case RepairActionId.resetManualDns:
      final pinned = [
        for (final f in findings)
          if (f.kind == FindingKind.manualDns && f.subject != null) f.subject!,
      ];
      final String? command = switch (os) {
        'macos' when pinned.isNotEmpty => [
            for (final s in pinned)
              'sudo networksetup -setdnsservers ${shellQuote(s)} Empty',
          ].join('; '),
        _ => null,
      };
      return RepairPlan(
        id: id,
        mode: RepairMode.guided,
        nothingToDo: os == 'macos' && pinned.isEmpty,
        stepKeys: switch (os) {
          'macos' => const [
              'repairStepDnsMacSettings',
              'repairStepDnsMacAdvanced',
              'repairStepRecheck',
            ],
          'windows' => const ['repairStepDnsWindows', 'repairStepRecheck'],
          'linux' => const ['repairStepDnsLinux', 'repairStepRecheck'],
          'android' => const ['repairStepDnsAndroid', 'repairStepRecheck'],
          _ => const ['repairStepDnsIos', 'repairStepRecheck'],
        },
        command: command,
        settingsUrl: switch (os) {
          'macos' => Uri.parse(
              'x-apple.systempreferences:com.apple.Network-Settings.extension',
            ),
          'windows' => Uri.parse('ms-settings:network-status'),
          _ => null,
        },
      );

    case RepairActionId.repairTunnel:
      return RepairPlan(
        id: id,
        mode: RepairMode.inApp,
        stepKeys: [
          'repairStepTunnelStop',
          if (desktop) 'repairStepTunnelProxy',
          'repairStepTunnelReconnect',
        ],
      );
  }
}
