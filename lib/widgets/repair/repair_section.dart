import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../../services/diagnostics/live_diagnosis_controller.dart'
    show LiveDiagnosisController, tcpConnectProbe;
import '../../services/repair/conflict_scan.dart';
import '../../services/repair/repair_executor.dart';
import '../../services/repair/repair_plan.dart';
import '../../utils/app_theme.dart';
import '../../utils/global_config.dart' show GlobalState;
import '../../utils/native_bridge.dart';

typedef ConflictScanner = Future<List<ConflictFinding>> Function();

/// Read-only scan of this machine; nothing here changes system state.
Future<List<ConflictFinding>> scanThisDevice() async {
  final canary = await tcpConnectProbe(LiveDiagnosisController.canaryHost, 443);
  String? lastError;
  try {
    lastError = (await NativeBridge.getPacketTunnelStatus()).lastError;
  } catch (_) {}
  final findings = [
    ...commonFindings(canary: canary, tunnelLastError: lastError),
  ];
  if (Platform.isMacOS) {
    final inputs = await gatherMacInputs(
      ourSocksPort: int.tryParse(GlobalState.socksPort.value) ?? 1080,
      ownBundleId: 'plus.svc.xconnect',
    );
    final mac = scanMac(inputs);
    // A named VPN says more than the anonymous interception finding.
    if (mac.any((f) => f.kind == FindingKind.otherVpnConnected)) {
      findings.removeWhere((f) => f.kind == FindingKind.tunnelInterception);
    }
    findings.addAll(mac);
  }
  return findings;
}

/// Settings → 修复.
class RepairSection extends StatefulWidget {
  const RepairSection({
    super.key,
    this.scan = scanThisDevice,
    this.os,
    this.tunnelRepair,
  });

  final ConflictScanner scan;

  /// Defaults to the running platform; injectable for tests.
  final String? os;
  final OwnTunnelRepair? tunnelRepair;

  @override
  State<RepairSection> createState() => _RepairSectionState();
}

class _RepairSectionState extends State<RepairSection> {
  List<ConflictFinding> _findings = const [];
  bool _scanning = false;
  RepairActionId? _running;

  String get _os => widget.os ?? Platform.operatingSystem;

  @override
  void initState() {
    super.initState();
    _rescan();
  }

  Future<void> _rescan() async {
    setState(() => _scanning = true);
    final findings = await widget.scan();
    if (!mounted) return;
    setState(() {
      _findings = findings;
      _scanning = false;
    });
  }

  Future<void> _openPlan(RepairActionId id) async {
    final plan = planFor(id, os: _os, findings: _findings);
    final confirmed = await showRepairSheet(context, plan);
    if (confirmed != true || !mounted) return;
    if (plan.mode == RepairMode.inApp) {
      setState(() => _running = id);
      await (widget.tunnelRepair ?? OwnTunnelRepair()).run(_findings);
      if (!mounted) return;
      setState(() => _running = null);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(context.l10n.get('repairTunnelDone'))),
      );
    }
    await _rescan();
  }

  Future<void> _openFinding(ConflictFinding finding) async {
    if (finding.fix != null) return _openPlan(finding.fix!);
    await showFindingSheet(context, finding);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 600;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Card(
              children: [
                _Summary(
                  scanning: _scanning,
                  count: _findings.length,
                  compact: compact,
                  onRecheck: _scanning ? null : _rescan,
                ),
                for (final f in _findings)
                  _FindingRow(
                    finding: f,
                    compact: compact,
                    onTap: () => _openFinding(f),
                  ),
              ],
            ),
            const SizedBox(height: 24),
            _Card(
              title: context.l10n.get('repairSectionActions'),
              children: [
                for (final id in RepairActionId.values)
                  _ActionRow(
                    plan: planFor(id, os: _os, findings: _findings),
                    compact: compact,
                    busy: _running == id,
                    onTap: () => _openPlan(id),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.children, this.title});

  final List<Widget> children;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final xc = context.xColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 6),
            child: Text(
              title!,
              style: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(color: xc.subtleText),
            ),
          ),
        Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: xc.cardBackground,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: xc.cardBorder),
          ),
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) Divider(height: 1, color: xc.cardBorder),
                children[i],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({
    required this.scanning,
    required this.count,
    required this.compact,
    required this.onRecheck,
  });

  final bool scanning;
  final int count;
  final bool compact;
  final VoidCallback? onRecheck;

  @override
  Widget build(BuildContext context) {
    final xc = context.xColors;
    final l10n = context.l10n;
    final color = scanning
        ? xc.mutedText
        : count == 0
            ? xc.success
            : xc.warning;
    final text = scanning
        ? l10n.get('repairScanning')
        : count == 0
            ? l10n.get('repairSummaryClean')
            : l10n.get('repairSummaryConflicts').replaceAll('{n}', '$count');

    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            if (compact)
              IconButton(
                tooltip: l10n.get('repairRecheck'),
                onPressed: onRecheck,
                icon: Icon(Icons.refresh, color: xc.brand),
              )
            else
              TextButton.icon(
                onPressed: onRecheck,
                style: TextButton.styleFrom(foregroundColor: xc.brand),
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(l10n.get('repairRecheck')),
              ),
          ],
        ),
      ),
    );
  }
}

String findingTitle(BuildContext context, ConflictFinding f) {
  final l10n = context.l10n;
  String fill(String key) => l10n
      .get(key)
      .replaceAll('{subject}', f.subject ?? '')
      .replaceAll('{detail}', f.detail ?? '');
  return switch (f.kind) {
    FindingKind.tunnelInterception => fill('findTunnelInterception'),
    FindingKind.otherVpnConnected => fill('findOtherVpn'),
    FindingKind.manualDns => fill('findManualDns'),
    FindingKind.staleProxy => fill('findStaleProxy'),
    FindingKind.orphanHelper => fill('findOrphanHelper'),
    FindingKind.profileSaveDenied => fill('findProfileDenied'),
  };
}

class _FindingRow extends StatelessWidget {
  const _FindingRow({
    required this.finding,
    required this.compact,
    required this.onTap,
  });

  final ConflictFinding finding;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final subtitle = finding.thirdParty
        ? l10n.get('findThirdPartyNote')
        : finding.kind == FindingKind.profileSaveDenied
            ? l10n.get('findProfileDeniedNote')
            : null;
    // Third-party and user-only findings get "查看", never "修复".
    final verb = finding.fix != null ? 'repairFix' : 'repairView';
    return _Row(
      icon: Icons.warning_amber_rounded,
      iconColor: context.xColors.warning,
      title: findingTitle(context, finding),
      subtitle: compact ? null : subtitle,
      compact: compact,
      trailingLabel: l10n.get(verb),
      filled: finding.fix != null,
      onTap: onTap,
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.plan,
    required this.compact,
    required this.busy,
    required this.onTap,
  });

  final RepairPlan plan;
  final bool compact;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (icon, title, desc, verb) = switch (plan.id) {
      RepairActionId.flushDnsCache => (
          Icons.cleaning_services_outlined,
          'actFlushDns',
          'actFlushDnsDesc',
          plan.mode == RepairMode.inApp ? 'repairClean' : 'repairSteps',
        ),
      RepairActionId.resetManualDns => (
          Icons.language,
          'actResetDns',
          'actResetDnsDesc',
          'repairSteps',
        ),
      RepairActionId.repairTunnel => (
          Icons.link,
          'actRepairTunnel',
          'actRepairTunnelDesc',
          'repairFix',
        ),
    };
    return _Row(
      icon: icon,
      iconColor: context.xColors.brand,
      title: l10n.get(title),
      subtitle: compact ? null : l10n.get(desc),
      badge: _ModeBadge(mode: plan.mode, compact: compact),
      compact: compact,
      trailingLabel: l10n.get(verb),
      filled: true,
      busy: busy,
      onTap: onTap,
    );
  }
}

class _ModeBadge extends StatelessWidget {
  const _ModeBadge({required this.mode, required this.compact});

  final RepairMode mode;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final xc = context.xColors;
    final inApp = mode == RepairMode.inApp;
    final key = switch ((inApp, compact)) {
      (true, false) => 'modeInApp',
      (true, true) => 'modeInAppShort',
      (false, false) => 'modeGuided',
      (false, true) => 'modeGuidedShort',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: inApp ? xc.brandMuted : xc.surfaceSunken,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        context.l10n.get(key),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: inApp ? xc.brand : xc.mutedText,
            ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.compact,
    required this.trailingLabel,
    required this.filled,
    required this.onTap,
    this.subtitle,
    this.badge,
    this.busy = false,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String? subtitle;
  final Widget? badge;
  final bool compact;
  final String trailingLabel;
  final bool filled;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final xc = context.xColors;
    final textTheme = Theme.of(context).textTheme;

    final Widget trailing;
    if (busy) {
      trailing = const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (compact) {
      trailing = Icon(Icons.chevron_right, color: xc.mutedText);
    } else if (filled) {
      trailing = FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor: xc.ink,
          foregroundColor: xc.onInk,
          shape: const StadiumBorder(),
          visualDensity: VisualDensity.compact,
        ),
        child: Text(trailingLabel),
      );
    } else {
      trailing = TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(foregroundColor: xc.brand),
        child: Text(trailingLabel),
      );
    }

    return InkWell(
      onTap: busy || !compact ? null : onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 12 : 16,
            vertical: compact ? 8 : 10,
          ),
          child: Row(
            children: [
              compact
                  ? Icon(icon, size: 20, color: iconColor)
                  : Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: xc.surfaceSunken,
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                      child: Icon(icon, size: 20, color: iconColor),
                    ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(title, style: textTheme.bodyMedium),
                        if (badge != null) badge!,
                      ],
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style:
                            textTheme.bodySmall?.copyWith(color: xc.mutedText),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              trailing,
            ],
          ),
        ),
      ),
    );
  }
}

/// Steps for a repair. Returns true when the user asks to run an in-app
/// repair, or says a guided one is done (the caller then re-scans).
Future<bool?> showRepairSheet(BuildContext context, RepairPlan plan) {
  final wide = MediaQuery.of(context).size.width >= 600;
  final body = _PlanBody(plan: plan);
  if (wide) {
    return showDialog<bool>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: body,
        ),
      ),
    );
  }
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => SafeArea(child: body),
  );
}

Future<void> showFindingSheet(BuildContext context, ConflictFinding finding) {
  final l10n = context.l10n;
  final help = switch (finding.kind) {
    FindingKind.otherVpnConnected => l10n.get('findOtherVpnHelp'),
    FindingKind.tunnelInterception => l10n.get('findTunnelHelp'),
    FindingKind.orphanHelper =>
      l10n.get('findOrphanHelp').replaceAll('{detail}', finding.detail ?? ''),
    FindingKind.profileSaveDenied => l10n.get('findProfileDeniedHelp'),
    _ => '',
  };
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(findingTitle(context, finding)),
      content: Text(help),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.get('confirm')),
        ),
      ],
    ),
  );
}

class _PlanBody extends StatelessWidget {
  const _PlanBody({required this.plan});

  final RepairPlan plan;

  @override
  Widget build(BuildContext context) {
    final xc = context.xColors;
    final l10n = context.l10n;
    final textTheme = Theme.of(context).textTheme;
    final title = l10n.get(switch (plan.id) {
      RepairActionId.flushDnsCache => 'actFlushDns',
      RepairActionId.resetManualDns => 'actResetDns',
      RepairActionId.repairTunnel => 'actRepairTunnel',
    });
    final inApp = plan.mode == RepairMode.inApp;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: textTheme.titleLarge),
          const SizedBox(height: 12),
          if (plan.nothingToDo)
            Text(l10n.get('repairNothingToDo'), style: textTheme.bodyMedium)
          else
            for (var i = 0; i < plan.stepKeys.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${i + 1}.',
                        style: textTheme.bodyMedium
                            ?.copyWith(color: xc.mutedText)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(l10n.get(plan.stepKeys[i]),
                          style: textTheme.bodyMedium),
                    ),
                  ],
                ),
              ),
          if (plan.command != null && !plan.nothingToDo) ...[
            const SizedBox(height: 4),
            Text(l10n.get('repairCommandLabel'),
                style: textTheme.labelLarge?.copyWith(color: xc.subtleText)),
            const SizedBox(height: 6),
            _CommandBlock(command: plan.command!),
          ],
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              if (plan.settingsUrl != null)
                OutlinedButton(
                  onPressed: () => launchUrl(plan.settingsUrl!),
                  child: Text(l10n.get('repairOpenSettings')),
                ),
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.get('cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                style: FilledButton.styleFrom(
                  backgroundColor: xc.ink,
                  foregroundColor: xc.onInk,
                  shape: const StadiumBorder(),
                ),
                child:
                    Text(l10n.get(inApp ? 'repairRun' : 'repairDoneRecheck')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CommandBlock extends StatelessWidget {
  const _CommandBlock({required this.command});

  final String command;

  @override
  Widget build(BuildContext context) {
    final xc = context.xColors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: xc.surfaceSunken,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              command,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
            ),
          ),
          IconButton(
            tooltip: context.l10n.get('repairCopy'),
            icon: Icon(Icons.copy_rounded, size: 18, color: xc.brand),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: command));
              if (!context.mounted) return;
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                SnackBar(content: Text(context.l10n.get('repairCopied'))),
              );
            },
          ),
        ],
      ),
    );
  }
}
