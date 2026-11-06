import 'dart:async';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../services/traffic_routing.dart';
import '../utils/app_logger.dart';
import 'log_console.dart' show LogLevel;
import 'settings_row.dart';

class TrafficModeGroup extends StatefulWidget {
  const TrafficModeGroup({super.key});

  @override
  State<TrafficModeGroup> createState() => _TrafficModeGroupState();
}

class _TrafficModeGroupState extends State<TrafficModeGroup> {
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    final strings = context.l10n;
    return ValueListenableBuilder<TrafficMode>(
      valueListenable: TrafficRouting.selected,
      builder: (context, selected, _) {
        return ValueListenableBuilder<TrafficMode?>(
          valueListenable: TrafficRouting.activeMode,
          builder: (context, active, _) {
            final isPending = active != null && active != selected;
            final selectedLabel = selected == TrafficMode.allVpn
                ? strings.get('trafficModeGlobal')
                : strings.get('trafficModeSmart');
            final activeLabel = active == TrafficMode.allVpn
                ? strings.get('trafficModeGlobal')
                : strings.get('trafficModeSmart');

            SettingsRow choice(TrafficMode mode, IconData icon, String key) {
              return SettingsRow(
                icon: icon,
                kind: SettingsRowKind.action,
                title: strings.get(key),
                description: strings.get('${key}Hint'),
                trailing: selected == mode
                    ? Semantics(
                        selected: true,
                        child: const Icon(Icons.check_circle_outline),
                      )
                    : null,
                onTap: _saving || selected == mode
                    ? null
                    : () => unawaited(_selectTrafficMode(mode)),
              );
            }

            final String statusTitle;
            final String statusDesc;
            final IconData statusIcon;
            if (isPending) {
              statusIcon = Icons.sync_problem_outlined;
              statusTitle = strings
                  .get('trafficModePendingRestart')
                  .replaceAll('{0}', selectedLabel);
              statusDesc = strings
                  .get('trafficModeActive')
                  .replaceAll('{0}', activeLabel);
            } else if (active != null) {
              statusIcon = Icons.verified_user_outlined;
              statusTitle = strings
                  .get('trafficModeActive')
                  .replaceAll('{0}', activeLabel);
              statusDesc = strings.get('trafficModeScope');
            } else {
              statusIcon = Icons.info_outline;
              statusTitle = strings.get('trafficModeNextConnection');
              statusDesc = strings.get('trafficModeScope');
            }

            return SettingsGroup(
              title: strings.get('trafficModeTitle'),
              children: [
                choice(TrafficMode.smart, Icons.alt_route, 'trafficModeSmart'),
                choice(TrafficMode.allVpn, Icons.vpn_lock_outlined,
                    'trafficModeGlobal'),
                SettingsRow(
                  icon: statusIcon,
                  kind: SettingsRowKind.action,
                  title: statusTitle,
                  description: statusDesc,
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _selectTrafficMode(TrafficMode mode) async {
    setState(() => _saving = true);
    var saved = false;
    try {
      saved = await TrafficRouting.select(mode);
    } catch (_) {
      addAppLog('Traffic routing preference save failed',
          level: LogLevel.warning);
    }
    if (!mounted) return;
    setState(() => _saving = false);
    if (!saved) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.get('trafficModeSaveFailed'))),
      );
    }
  }
}
