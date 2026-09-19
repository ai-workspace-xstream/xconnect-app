import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/l10n/app_localizations.dart';
import 'package:xconnect/services/repair/conflict_scan.dart';
import 'package:xconnect/services/repair/repair_executor.dart';
import 'package:xconnect/utils/app_theme.dart';
import 'package:xconnect/widgets/repair/repair_section.dart';

const _incident = [
  ConflictFinding(
    kind: FindingKind.otherVpnConnected,
    subject: 'OneXray',
    detail: 'net.yuandev.onexray',
    thirdParty: true,
  ),
  ConflictFinding(
    kind: FindingKind.manualDns,
    subject: 'Wi-Fi',
    detail: '1.1.1.1, 8.8.8.8',
    fix: RepairActionId.resetManualDns,
  ),
];

Widget _host({
  List<ConflictFinding> findings = _incident,
  OwnTunnelRepair? tunnelRepair,
}) =>
    MaterialApp(
      theme: AppTheme.lightTheme,
      locale: const Locale('zh'),
      supportedLocales: const [Locale('en'), Locale('zh')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(
        body: SingleChildScrollView(
          child: RepairSection(
            scan: () async => findings,
            os: 'macos',
            tunnelRepair: tunnelRepair,
          ),
        ),
      ),
    );

void _size(WidgetTester tester, double width) {
  tester.view.physicalSize = Size(width, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('summarises the incident findings', (tester) async {
    _size(tester, 900);
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    expect(find.text('发现 2 个可能的冲突'), findsOneWidget);
    expect(find.text('另一个 VPN（OneXray）已连接'), findsOneWidget);
    expect(find.text('第三方组件，只提示，不修改'), findsOneWidget);
    expect(find.text('Wi-Fi 使用手动 DNS 1.1.1.1, 8.8.8.8'), findsOneWidget);
  });

  testWidgets('another vendor only ever gets 查看', (tester) async {
    _size(tester, 900);
    await tester.pumpWidget(_host(findings: [_incident.first]));
    await tester.pumpAndSettle();

    final row = find.ancestor(
      of: find.text('另一个 VPN（OneXray）已连接'),
      matching: find.byType(Row),
    );
    expect(find.descendant(of: row.first, matching: find.text('查看')),
        findsOneWidget);
    expect(find.descendant(of: row.first, matching: find.text('修复')),
        findsNothing);
  });

  testWidgets('repair rows carry the right execution badge', (tester) async {
    _size(tester, 900);
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    expect(find.text('引导操作'), findsNWidgets(2));
    expect(find.text('一键修复'), findsWidgets);
  });

  testWidgets('fixing manual DNS shows the copy-only command', (tester) async {
    _size(tester, 900);
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    final dnsRow = find.ancestor(
      of: find.text('Wi-Fi 使用手动 DNS 1.1.1.1, 8.8.8.8'),
      matching: find.byType(Row),
    );
    await tester
        .tap(find.descendant(of: dnsRow.first, matching: find.text('修复')));
    await tester.pumpAndSettle();

    expect(find.text('sudo networksetup -setdnsservers "Wi-Fi" Empty'),
        findsOneWidget);
    expect(find.text('我已完成，重新检查'), findsOneWidget);
  });

  testWidgets('confirming the tunnel repair runs it', (tester) async {
    _size(tester, 900);
    final calls = <String>[];
    await tester.pumpWidget(_host(
      tunnelRepair: OwnTunnelRepair(
        activeNode: ValueNotifier<String>(''),
        stopTunnel: () async => calls.add('stop'),
        stopNodeService: (_) async {},
        clearOwnProxy: () async => calls.add('proxy'),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('修复隧道配置'));
    await tester.pumpAndSettle();
    final tunnelRow = find.ancestor(
      of: find.text('修复隧道配置'),
      matching: find.byType(Row),
    );
    await tester
        .tap(find.descendant(of: tunnelRow.first, matching: find.text('修复')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '修复').last);
    await tester.pumpAndSettle();

    expect(calls, ['stop']);
    expect(find.text('已断开并重置，请在首页重新连接。'), findsOneWidget);
  });

  testWidgets('phone width uses chevrons and short badges', (tester) async {
    _size(tester, 360);
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.chevron_right), findsNWidgets(5));
    expect(find.text('引导'), findsNWidgets(2));
    expect(find.text('第三方组件，只提示，不修改'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
