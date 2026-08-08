import 'package:flutter/material.dart';

import '../utils/app_theme.dart';

/// A titled card holding a run of [SettingsRow]s.
///
/// Replaces the ad-hoc `Container(decoration: …) + Column + Divider` blocks that
/// were duplicated across the mobile and desktop settings views.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    this.title,
    required this.children,
  });

  final String? title;
  final List<Widget> children;

  static const double _radius = 12;

  @override
  Widget build(BuildContext context) {
    final xc = context.xColors;
    final visible = children.where((child) => child is! _Absent).toList();
    if (visible.isEmpty) {
      return const SizedBox.shrink();
    }

    final rows = <Widget>[];
    for (var i = 0; i < visible.length; i++) {
      if (i > 0) {
        rows.add(Divider(
          height: 1,
          thickness: 1,
          // Start the rule at the label, not the card edge, so the icon column
          // reads as one continuous strip.
          indent: SettingsRow.contentInset,
          color: xc.cardBorder,
        ));
      }
      rows.add(visible[i]);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null) ...[
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 6),
            child: Text(
              title!.toUpperCase(),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.1,
                color: xc.subtleText,
              ),
            ),
          ),
        ],
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: xc.cardBackground,
            borderRadius: BorderRadius.circular(_radius),
            border: Border.all(color: xc.cardBorder),
          ),
          child: Column(children: rows),
        ),
      ],
    );
  }
}

/// Marker returned by [SettingsRow.absent] so a caller can keep a declarative
/// list and let [SettingsGroup] drop the entry along with its divider.
class _Absent extends StatelessWidget {
  const _Absent();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

enum SettingsRowKind {
  /// Opens a dialog or another page. Shows a chevron.
  navigation,

  /// Runs in place. No chevron; shows a spinner while [SettingsRow.busy].
  action,

  /// Carries a [Switch]. Tapping the row toggles it.
  toggle,
}

/// One line in a [SettingsGroup].
///
/// The whole row is the hit target, so a trailing control never needs its own
/// enlarged tap area.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.icon,
    required this.title,
    this.description,
    this.value,
    this.onTap,
    this.kind = SettingsRowKind.navigation,
    this.destructive = false,
    this.busy = false,
    this.switchValue,
    this.onSwitchChanged,
    this.trailing,
  });

  /// An entry that renders nothing and takes no divider.
  static Widget absent() => const _Absent();

  final IconData icon;
  final String title;
  final String? description;

  /// Current value, shown right-aligned before the chevron.
  final String? value;

  final VoidCallback? onTap;
  final SettingsRowKind kind;
  final bool destructive;
  final bool busy;

  final bool? switchValue;
  final ValueChanged<bool>? onSwitchChanged;

  /// Escape hatch for a control that is none of the above.
  final Widget? trailing;

  static const double _iconSize = 28;
  static const double _gap = 12;
  static const double _padH = 13;

  /// Left inset of the text column, used to indent dividers.
  static const double contentInset = _padH + _iconSize + _gap;

  bool get _enabled {
    if (kind == SettingsRowKind.toggle) {
      return onSwitchChanged != null;
    }
    return onTap != null;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final xc = context.xColors;
    final accent = destructive ? xc.error : xc.brand;
    final minHeight =
        MediaQuery.of(context).size.width < 768 ? 48.0 : 44.0;

    Widget? tail = trailing;
    if (tail == null) {
      switch (kind) {
        case SettingsRowKind.toggle:
          tail = Switch(
            value: switchValue ?? false,
            onChanged: onSwitchChanged,
          );
          break;
        case SettingsRowKind.navigation:
          tail = Icon(Icons.chevron_right, size: 20, color: xc.subtleText);
          break;
        case SettingsRowKind.action:
          break;
      }
    }

    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: _padH, vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: _iconSize,
            height: _iconSize,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(8),
              ),
              child: busy
                  ? Padding(
                      padding: const EdgeInsets.all(6),
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: accent,
                      ),
                    )
                  : Icon(icon, size: 16, color: accent),
            ),
          ),
          const SizedBox(width: _gap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: destructive ? xc.error : cs.onSurface,
                  ),
                ),
                if (description != null && description!.isNotEmpty)
                  Text(
                    description!,
                    style: TextStyle(fontSize: 11.5, color: xc.mutedText),
                  ),
              ],
            ),
          ),
          if (value != null && value!.isNotEmpty) ...[
            const SizedBox(width: _gap),
            Text(
              value!,
              style: TextStyle(
                fontSize: 12,
                color: xc.subtleText,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
          if (tail != null) ...[
            const SizedBox(width: 4),
            tail,
          ],
        ],
      ),
    );

    final body = ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: row,
    );

    if (!_enabled) {
      return Opacity(opacity: 0.4, child: body);
    }

    return InkWell(
      onTap: kind == SettingsRowKind.toggle
          ? () => onSwitchChanged?.call(!(switchValue ?? false))
          : (busy ? null : onTap),
      hoverColor: accent.withValues(alpha: 0.06),
      child: body,
    );
  }
}
