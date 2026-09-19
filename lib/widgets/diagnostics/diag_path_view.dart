import 'dart:io';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/diagnostics/live_metrics.dart';
import '../../utils/app_theme.dart';

Color diagLevelColor(BuildContext context, DiagLevel level) {
  final xc = context.xColors;
  return switch (level) {
    DiagLevel.good => xc.success,
    DiagLevel.warn => xc.warning,
    DiagLevel.bad => xc.error,
    DiagLevel.none => Theme.of(context).colorScheme.onSurface,
  };
}

/// Device → router → node strip with per-hop latency and loss.
///
/// The router drops out when it is unknown, so the strip never invents a hop
/// it did not measure; an unmeasurable router stays but says so rather than
/// showing loss.
class DiagPathView extends StatelessWidget {
  const DiagPathView({super.key, required this.path});

  final PathAttribution path;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final isPhone = Platform.isIOS || Platform.isAndroid;
    final showRouter = path.local.state != SegmentState.unknown;

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 600;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Node(
              icon: isPhone
                  ? Icons.smartphone_outlined
                  : Icons.laptop_mac_outlined,
              label: l10n.get('diagNodeDevice'),
              compact: compact,
            ),
            if (showRouter) ...[
              Expanded(
                child: _Segment(
                  reading: path.local,
                  culprit: path.culprit == Culprit.local,
                  compact: compact,
                ),
              ),
              _Node(
                icon: Icons.router_outlined,
                label: l10n.get('diagNodeRouter'),
                compact: compact,
              ),
            ],
            Expanded(
              child: _Segment(
                reading: path.upstream,
                culprit: path.culprit == Culprit.upstream,
                compact: compact,
              ),
            ),
            _Node(
              icon: Icons.dns_outlined,
              label: l10n.get('diagNodeServer'),
              compact: compact,
            ),
          ],
        );
      },
    );
  }
}

class _Node extends StatelessWidget {
  const _Node({
    required this.icon,
    required this.label,
    required this.compact,
  });

  final IconData icon;
  final String label;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final xc = context.xColors;
    final box = compact ? 34.0 : 40.0;
    return SizedBox(
      width: compact ? 48 : 64,
      child: Column(
        children: [
          Container(
            width: box,
            height: box,
            decoration: BoxDecoration(
              color: xc.surfaceSunken,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Icon(icon, size: compact ? 18 : 22, color: xc.brand),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.reading,
    required this.culprit,
    required this.compact,
  });

  final SegmentReading reading;
  final bool culprit;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final xc = context.xColors;
    final measured = reading.state == SegmentState.measured;
    final color =
        measured ? diagLevelColor(context, reading.level) : xc.mutedText;
    final mark = culprit ? ' !' : '';

    final String top;
    final String? bottom;
    if (!measured) {
      top = l10n.get(switch (reading.state) {
        SegmentState.unmeasurable => 'diagSegUnmeasurable',
        _ => 'diagSegSampling',
      });
      bottom = null;
    } else {
      final latency =
          reading.latencyMs == null ? '— —' : '${reading.latencyMs} ms';
      final loss =
          '${l10n.get('diagLossShort')} ${((reading.lossRate ?? 0) * 100).round()}%$mark';
      if (compact) {
        top = latency;
        bottom = loss;
      } else {
        top = '$latency · $loss';
        bottom = null;
      }
    }

    final style = (compact
            ? Theme.of(context).textTheme.labelMedium
            : Theme.of(context).textTheme.labelLarge)
        ?.copyWith(
      color: color,
      fontWeight: culprit ? FontWeight.w700 : FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return Semantics(
      container: true,
      label: [top, if (bottom != null) bottom].join(' '),
      child: ExcludeSemantics(
        child: Padding(
          padding: EdgeInsets.only(top: compact ? 2 : 6),
          child: Column(
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(top, maxLines: 1, style: style),
              ),
              const SizedBox(height: 4),
              Container(
                height: culprit ? 3 : 1.5,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                color: measured ? color : xc.cardBorder,
              ),
              if (bottom != null) ...[
                const SizedBox(height: 4),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(bottom, maxLines: 1, style: style),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
