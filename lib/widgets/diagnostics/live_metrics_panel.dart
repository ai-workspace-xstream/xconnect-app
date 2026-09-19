import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/diagnostics/live_diagnosis_controller.dart';
import '../../services/diagnostics/live_metrics.dart';
import '../../utils/app_theme.dart';

enum _Level { none, good, warn, bad }

/// Settings → Diagnostics: owns a [LiveDiagnosisController] for as long as the
/// tab is on screen, so leaving the tab ends the session.
class LiveDiagnosisSection extends StatefulWidget {
  const LiveDiagnosisSection({super.key});

  @override
  State<LiveDiagnosisSection> createState() => _LiveDiagnosisSectionState();
}

class _LiveDiagnosisSectionState extends State<LiveDiagnosisSection> {
  final LiveDiagnosisController _controller = LiveDiagnosisController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => LiveMetricsPanel(
        snapshot: _controller.snapshot,
        onToggle: () {
          if (_controller.snapshot.running) {
            _controller.stop();
          } else {
            _controller.start();
          }
        },
      ),
    );
  }
}

/// Latency, loss and network type for the current node, with a one-line
/// verdict. Pure view of a [LiveDiagnosisSnapshot].
class LiveMetricsPanel extends StatelessWidget {
  const LiveMetricsPanel({
    super.key,
    required this.snapshot,
    required this.onToggle,
  });

  static const _empty = '— —';

  final LiveDiagnosisSnapshot snapshot;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final xc = context.xColors;
    final l10n = context.l10n;
    final stats = snapshot.stats;
    final hasData = stats.sampleCount > 0;

    final latency = hasData ? stats.latencyMs : null;
    final lossPercent = hasData ? (stats.lossRate * 100).round() : null;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: xc.cardBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: xc.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(snapshot: snapshot, onToggle: onToggle),
          if (snapshot.tunConflict) ...[
            const SizedBox(height: 12),
            _Banner(
              title: l10n.get('diagVerdictTunConflict'),
              body: l10n.get('diagTunConflictHint'),
            ),
          ],
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final tiles = [
                _MetricTile(
                  label: l10n.get('diagLatency'),
                  value: latency?.toString() ?? _empty,
                  unit: latency == null ? null : 'ms',
                  level: _latencyLevel(latency),
                ),
                _MetricTile(
                  label: l10n.get('diagLoss'),
                  value: lossPercent?.toString() ?? _empty,
                  unit: lossPercent == null ? null : '%',
                  level: _lossLevel(lossPercent),
                ),
                _MetricTile(
                  label: l10n.get('diagNetworkType'),
                  value: _networkLabel(context, snapshot.networkType),
                  icon: _networkIcon(snapshot.networkType),
                  level: _Level.none,
                  compactValue: true,
                ),
              ];
              if (constraints.maxWidth < 420) {
                return Column(
                  children: [
                    for (var i = 0; i < tiles.length; i++) ...[
                      if (i > 0) const SizedBox(height: 8),
                      tiles[i],
                    ],
                  ],
                );
              }
              return IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < tiles.length; i++) ...[
                      if (i > 0) const SizedBox(width: 12),
                      Expanded(child: tiles[i]),
                    ],
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          _VerdictLine(snapshot: snapshot),
          const SizedBox(height: 8),
          Text(
            l10n.get('diagFooter'),
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: xc.subtleText),
          ),
        ],
      ),
    );
  }

  static _Level _latencyLevel(int? ms) {
    if (ms == null) return _Level.none;
    if (ms >= 300) return _Level.bad;
    if (ms >= 150) return _Level.warn;
    return _Level.good;
  }

  static _Level _lossLevel(int? percent) {
    if (percent == null) return _Level.none;
    if (percent >= 5) return _Level.bad;
    if (percent >= 2) return _Level.warn;
    return _Level.good;
  }

  static String _networkLabel(BuildContext context, DiagNetworkType type) {
    return context.l10n.get(switch (type) {
      DiagNetworkType.wifi => 'diagNetWifi',
      DiagNetworkType.ethernet => 'diagNetEthernet',
      DiagNetworkType.cellular => 'diagNetCellular',
      DiagNetworkType.none => 'diagNetNone',
      DiagNetworkType.other => 'diagNetOther',
      DiagNetworkType.unknown => 'diagNetUnknown',
    });
  }

  static IconData _networkIcon(DiagNetworkType type) => switch (type) {
        DiagNetworkType.wifi => Icons.wifi,
        DiagNetworkType.ethernet => Icons.settings_ethernet,
        DiagNetworkType.cellular => Icons.signal_cellular_alt,
        DiagNetworkType.none => Icons.wifi_off,
        _ => Icons.device_unknown_outlined,
      };
}

Color _levelColor(BuildContext context, _Level level) {
  final xc = context.xColors;
  return switch (level) {
    _Level.good => xc.success,
    _Level.warn => xc.warning,
    _Level.bad => xc.error,
    _Level.none => Theme.of(context).colorScheme.onSurface,
  };
}

class _Header extends StatelessWidget {
  const _Header({required this.snapshot, required this.onToggle});

  final LiveDiagnosisSnapshot snapshot;
  final VoidCallback onToggle;

  static String _clock(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
  }

  @override
  Widget build(BuildContext context) {
    final xc = context.xColors;
    final l10n = context.l10n;
    final textTheme = Theme.of(context).textTheme;
    final endpoint = snapshot.endpoint;

    final title = snapshot.running || snapshot.stats.sampleCount > 0
        ? '${l10n.get('diagElapsed')}  ${_clock(snapshot.elapsed)}'
        : l10n.get('diagTitle');
    final subtitle = switch (snapshot) {
      LiveDiagnosisSnapshot(noEndpoint: true) => l10n.get('diagNoNode'),
      LiveDiagnosisSnapshot(autoStopped: true) => l10n.get('diagAutoStopped'),
      _ when endpoint != null =>
        '${snapshot.nodeName ?? ''}  ${endpoint.host}:${endpoint.port}'.trim(),
      _ => l10n.get('diagIdleHint'),
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: textTheme.titleMedium?.copyWith(
                  color: snapshot.running ? xc.brand : null,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodySmall?.copyWith(color: xc.mutedText),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        FilledButton(
          onPressed: onToggle,
          style: FilledButton.styleFrom(
            backgroundColor: xc.ink,
            foregroundColor: xc.onInk,
            shape: const StadiumBorder(),
          ),
          child: Text(
            l10n.get(snapshot.running ? 'diagStop' : 'diagStart'),
          ),
        ),
      ],
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.label,
    required this.value,
    required this.level,
    this.unit,
    this.icon,
    this.compactValue = false,
  });

  final String label;
  final String value;
  final String? unit;
  final IconData? icon;
  final _Level level;
  final bool compactValue;

  @override
  Widget build(BuildContext context) {
    final xc = context.xColors;
    final textTheme = Theme.of(context).textTheme;
    final color = _levelColor(context, level);
    final valueStyle =
        (compactValue ? textTheme.headlineSmall : textTheme.displaySmall)
            ?.copyWith(color: color, fontWeight: FontWeight.w700);

    return Semantics(
      container: true,
      label:
          '$label ${value == LiveMetricsPanel._empty ? '' : value}${unit ?? ''}',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
          decoration: BoxDecoration(
            color: xc.surfaceSunken,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 22, color: xc.brand),
                const SizedBox(height: 4),
              ],
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(value, style: valueStyle),
                    if (unit != null) ...[
                      const SizedBox(width: 3),
                      Text(
                        unit!,
                        style: textTheme.labelLarge?.copyWith(color: color),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                style: textTheme.labelLarge?.copyWith(color: xc.subtleText),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VerdictLine extends StatelessWidget {
  const _VerdictLine({required this.snapshot});

  final LiveDiagnosisSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final xc = context.xColors;
    final started = snapshot.running || snapshot.stats.sampleCount > 0;
    if (!started) return const SizedBox.shrink();

    // With a physical interface the probes bypass the other tunnel, so the
    // numbers are real: the banner reports the conflict, this line the result.
    final verdict = snapshot.tunConflict && !snapshot.noPhysicalInterface
        ? liveVerdict(snapshot.stats, tunConflict: false)
        : snapshot.verdict;
    final (key, level) = switch (verdict) {
      LiveVerdict.sampling => ('diagVerdictSampling', _Level.none),
      LiveVerdict.good => ('diagVerdictGood', _Level.good),
      LiveVerdict.slow => ('diagVerdictSlow', _Level.warn),
      LiveVerdict.unstable => ('diagVerdictUnstable', _Level.bad),
      LiveVerdict.unreachable => ('diagVerdictUnreachable', _Level.bad),
      LiveVerdict.tunConflict => ('diagVerdictTunConflict', _Level.warn),
    };
    final color =
        level == _Level.none ? xc.mutedText : _levelColor(context, level);

    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: xc.surfaceSunken,
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
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
                context.l10n.get(key),
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: color, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final xc = context.xColors;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: xc.warningBannerBackground,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: xc.warningBannerBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded,
              size: 18, color: xc.warningBannerText),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: textTheme.bodyMedium?.copyWith(
                    color: xc.warningBannerText,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: textTheme.bodySmall
                      ?.copyWith(color: xc.warningBannerText),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
