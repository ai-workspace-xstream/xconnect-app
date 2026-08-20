import 'package:flutter/material.dart';

import '../utils/app_theme.dart';

class SettingsTab {
  const SettingsTab({required this.icon, required this.label});

  final IconData icon;
  final String label;
}

/// Horizontal tab strip for the settings page.
///
/// The selected tab is marked with a check and carries no fill, so the strip
/// stays quiet next to the content it switches; unselected tabs pick up a fill
/// only on hover. Scrolls horizontally when the window is too narrow rather
/// than wrapping, so the content below never shifts vertically as tabs reflow.
class SettingsTabBar extends StatelessWidget {
  const SettingsTabBar({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<SettingsTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final xc = context.xColors;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < tabs.length; i++)
            Padding(
              padding: EdgeInsets.only(right: i == tabs.length - 1 ? 0 : 4),
              child: _Tab(
                tab: tabs[i],
                selected: i == selectedIndex,
                onTap: () => onSelected(i),
                accent: xc.brand,
                onSurface: cs.onSurface,
                muted: xc.mutedText,
              ),
            ),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.tab,
    required this.selected,
    required this.onTap,
    required this.accent,
    required this.onSurface,
    required this.muted,
  });

  final SettingsTab tab;
  final bool selected;
  final VoidCallback onTap;
  final Color accent;
  final Color onSurface;
  final Color muted;

  @override
  Widget build(BuildContext context) {
    final xc = context.xColors;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? xc.surfaceSunken : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          hoverColor: accent.withValues(alpha: 0.08),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  selected ? Icons.check : tab.icon,
                  size: 17,
                  color: selected ? accent : muted,
                ),
                const SizedBox(width: 8),
                Text(
                  tab.label,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w500,
                        color: selected ? onSurface : muted,
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
