import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/utils/app_theme.dart';
import 'package:xconnect/widgets/settings_row.dart';

Widget _host(Widget child) {
  return MaterialApp(
    theme: AppTheme.lightTheme,
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

void main() {
  testWidgets('navigation row shows a chevron and fires onTap', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_host(SettingsGroup(
      title: 'DNS',
      children: [
        SettingsRow(
          icon: Icons.dns,
          title: '代理 DNS',
          value: '1.1.1.1',
          onTap: () => taps++,
        ),
      ],
    )));

    expect(find.text('代理 DNS'), findsOneWidget);
    expect(find.text('1.1.1.1'), findsOneWidget);
    // Group titles are upper-cased for the label style.
    expect(find.text('DNS'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);

    await tester.tap(find.text('代理 DNS'));
    expect(taps, 1);
  });

  testWidgets('action row has no chevron and swaps its icon for a spinner',
      (tester) async {
    await tester.pumpWidget(_host(SettingsGroup(
      children: [
        SettingsRow(
          icon: Icons.sync,
          kind: SettingsRowKind.action,
          title: '同步配置',
          busy: true,
          onTap: () {},
        ),
      ],
    )));

    expect(find.byIcon(Icons.chevron_right), findsNothing);
    expect(find.byIcon(Icons.sync), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('tapping anywhere on a toggle row flips the switch',
      (tester) async {
    bool? received;
    await tester.pumpWidget(_host(SettingsGroup(
      children: [
        SettingsRow(
          icon: Icons.vpn_lock,
          kind: SettingsRowKind.toggle,
          title: 'DNS over HTTPS',
          description: '加密 DNS 查询',
          switchValue: false,
          onSwitchChanged: (v) => received = v,
        ),
      ],
    )));

    // Tap the label, not the Switch itself.
    await tester.tap(find.text('DNS over HTTPS'));
    expect(received, isTrue);
  });

  testWidgets('a toggle row without a handler is inert', (tester) async {
    await tester.pumpWidget(_host(const SettingsGroup(
      children: [
        SettingsRow(
          icon: Icons.terminal,
          kind: SettingsRowKind.toggle,
          title: '运行态 MCP Server',
          switchValue: false,
        ),
      ],
    )));

    final dimmed = tester.widget<Opacity>(
      find.ancestor(
        of: find.text('运行态 MCP Server'),
        matching: find.byType(Opacity),
      ).first,
    );
    expect(dimmed.opacity, 0.4);

    // The row must not be wrapped in its own tap target. (The Material Switch
    // has an InkWell of its own, so scope the search to the row.)
    expect(
      find.ancestor(
        of: find.text('运行态 MCP Server'),
        matching: find.byType(InkWell),
      ),
      findsNothing,
    );
  });

  testWidgets('absent entries drop their divider too', (tester) async {
    await tester.pumpWidget(_host(SettingsGroup(
      children: [
        SettingsRow(icon: Icons.sync, title: 'A', onTap: () {}),
        SettingsRow.absent(),
        SettingsRow(icon: Icons.download, title: 'B', onTap: () {}),
      ],
    )));

    // Two visible rows means exactly one separator between them.
    expect(find.byType(Divider), findsOneWidget);
    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
  });

  testWidgets('a group whose children are all absent renders nothing',
      (tester) async {
    await tester.pumpWidget(_host(SettingsGroup(
      title: '开发者',
      children: [SettingsRow.absent(), SettingsRow.absent()],
    )));

    expect(find.text('开发者'), findsNothing);
    expect(find.byType(Divider), findsNothing);
  });

  testWidgets('destructive rows use the error token, not a hardcoded red',
      (tester) async {
    await tester.pumpWidget(_host(SettingsGroup(
      children: [
        SettingsRow(
          icon: Icons.delete_forever,
          title: '删除配置',
          destructive: true,
          onTap: () {},
        ),
      ],
    )));

    final label = tester.widget<Text>(find.text('删除配置'));
    expect(label.style?.color, XConnectColors.light.error);
  });
}
