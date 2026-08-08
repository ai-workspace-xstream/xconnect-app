import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/utils/app_theme.dart';
import 'package:xconnect/widgets/settings_tab_bar.dart';

const _tabs = [
  SettingsTab(icon: Icons.vpn_key_outlined, label: '连接'),
  SettingsTab(icon: Icons.dns_outlined, label: 'DNS'),
  SettingsTab(icon: Icons.tune, label: '系统'),
];

Widget _host({required int selected, ValueChanged<int>? onSelected}) {
  return MaterialApp(
    theme: AppTheme.lightTheme,
    home: Scaffold(
      body: SettingsTabBar(
        tabs: _tabs,
        selectedIndex: selected,
        onSelected: onSelected ?? (_) {},
      ),
    ),
  );
}

void main() {
  testWidgets('renders every tab label', (tester) async {
    await tester.pumpWidget(_host(selected: 0));
    for (final tab in _tabs) {
      expect(find.text(tab.label), findsOneWidget);
    }
  });

  testWidgets('the selected tab swaps its icon for a check', (tester) async {
    await tester.pumpWidget(_host(selected: 1));

    // Selected tab: check instead of its own icon.
    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(find.byIcon(Icons.dns_outlined), findsNothing);

    // Unselected tabs keep theirs.
    expect(find.byIcon(Icons.vpn_key_outlined), findsOneWidget);
    expect(find.byIcon(Icons.tune), findsOneWidget);
  });

  testWidgets('tapping a tab reports its index', (tester) async {
    final taps = <int>[];
    await tester.pumpWidget(_host(selected: 0, onSelected: taps.add));

    await tester.tap(find.text('系统'));
    expect(taps, [2]);
  });

  testWidgets('the selected tab is announced as selected', (tester) async {
    await tester.pumpWidget(_host(selected: 2));

    final flags = tester
        .widgetList<Semantics>(find.byType(Semantics))
        .where((s) => s.properties.selected != null)
        .map((s) => s.properties.selected)
        .toList();

    // Exactly one tab claims selection, and it is the third.
    expect(flags, [false, false, true]);
  });

  testWidgets('scrolls horizontally rather than wrapping', (tester) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(selected: 0));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
  });
}
