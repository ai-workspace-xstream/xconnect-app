import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/l10n/app_localizations.dart';
import 'package:xconnect/services/diagnostics/live_diagnosis_controller.dart';
import 'package:xconnect/services/diagnostics/live_metrics.dart';
import 'package:xconnect/utils/app_theme.dart';
import 'package:xconnect/widgets/diagnostics/live_metrics_panel.dart';

Widget _host(LiveDiagnosisSnapshot snapshot, {VoidCallback? onToggle}) {
  return MaterialApp(
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
        child:
            LiveMetricsPanel(snapshot: snapshot, onToggle: onToggle ?? () {}),
      ),
    ),
  );
}

const _unstable = LiveDiagnosisSnapshot(
  running: true,
  elapsed: Duration(minutes: 15, seconds: 22),
  nodeName: 'jp',
  endpoint: (host: 'jp-xhttp.svc.plus', port: 443),
  networkType: DiagNetworkType.wifi,
  stats: SegmentStats(
    sampleCount: 30,
    latencyMs: 162,
    lossRate: 0.10,
    retransmitRate: 0,
    jitterMs: 12,
    warmingUp: false,
  ),
);

void main() {
  testWidgets('shows latency, loss and network type like the reference',
      (tester) async {
    await tester.pumpWidget(_host(_unstable));
    await tester.pumpAndSettle();

    expect(find.text('162'), findsOneWidget);
    expect(find.text('10'), findsOneWidget);
    expect(find.text('Wi‑Fi'), findsOneWidget);
    expect(find.text('即时延迟'), findsOneWidget);
    expect(find.text('丢包率'), findsOneWidget);
    expect(find.text('网络类型'), findsOneWidget);
    expect(find.textContaining('00:15:22'), findsOneWidget);
    expect(find.text('您当前设备的网络环境不稳定'), findsOneWidget);
    expect(find.text('停止诊断'), findsOneWidget);
  });

  testWidgets('idle state shows placeholders and a start button',
      (tester) async {
    await tester.pumpWidget(_host(const LiveDiagnosisSnapshot()));
    await tester.pumpAndSettle();

    expect(find.text('— —'), findsNWidgets(2));
    expect(find.text('开始诊断'), findsOneWidget);
  });

  testWidgets('warns when another tunnel intercepts traffic', (tester) async {
    await tester.pumpWidget(_host(const LiveDiagnosisSnapshot(
      running: true,
      endpoint: (host: 'n', port: 443),
      tunConflict: true,
    )));
    await tester.pumpAndSettle();

    expect(find.text('检测到其他 VPN 或加速器正在接管网络'), findsOneWidget);
  });

  testWidgets('tapping the button calls onToggle', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(const LiveDiagnosisSnapshot(), onToggle: () => taps++),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始诊断'));
    expect(taps, 1);
  });

  testWidgets('phone width keeps the three tiles side by side', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_unstable));
    await tester.pumpAndSettle();

    final latency = tester.getCenter(find.text('即时延迟'));
    final loss = tester.getCenter(find.text('丢包率'));
    final network = tester.getCenter(find.text('网络类型'));
    expect(loss.dy, latency.dy);
    expect(network.dy, latency.dy);
    expect(latency.dx < loss.dx && loss.dx < network.dx, isTrue);
  });

  testWidgets('narrow width does not overflow', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_unstable));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
