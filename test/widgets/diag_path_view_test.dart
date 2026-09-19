import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/l10n/app_localizations.dart';
import 'package:xconnect/services/diagnostics/live_metrics.dart';
import 'package:xconnect/utils/app_theme.dart';
import 'package:xconnect/widgets/diagnostics/diag_path_view.dart';

Widget _host(PathAttribution path, {double width = 800}) => MaterialApp(
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
        body: Center(
          child: SizedBox(width: width, child: DiagPathView(path: path)),
        ),
      ),
    );

const _localCulprit = PathAttribution(
  local: SegmentReading(
    state: SegmentState.measured,
    latencyMs: 3,
    lossRate: 0.10,
    level: DiagLevel.bad,
  ),
  upstream: SegmentReading(
    state: SegmentState.measured,
    latencyMs: 158,
    lossRate: 0,
    level: DiagLevel.warn,
  ),
  culprit: Culprit.local,
);

void main() {
  testWidgets('shows device, router and node with both hops', (tester) async {
    await tester.pumpWidget(_host(_localCulprit));
    await tester.pumpAndSettle();

    expect(find.text('本设备'), findsOneWidget);
    expect(find.text('路由器'), findsOneWidget);
    expect(find.text('节点'), findsOneWidget);
    expect(find.textContaining('3 ms'), findsOneWidget);
    expect(find.textContaining('158 ms'), findsOneWidget);
  });

  testWidgets('marks the culprit hop with an exclamation', (tester) async {
    await tester.pumpWidget(_host(_localCulprit));
    await tester.pumpAndSettle();

    expect(find.textContaining('10% !'), findsOneWidget);
    expect(find.textContaining('丢包 0% !'), findsNothing);
  });

  testWidgets('an unmeasurable router is labelled, never shown as loss',
      (tester) async {
    await tester.pumpWidget(_host(const PathAttribution(
      local: SegmentReading(state: SegmentState.unmeasurable),
      upstream: SegmentReading(
        state: SegmentState.measured,
        latencyMs: 90,
        lossRate: 0,
        level: DiagLevel.good,
      ),
      culprit: Culprit.none,
    )));
    await tester.pumpAndSettle();

    expect(find.text('无法测量'), findsOneWidget);
    expect(find.textContaining('100%'), findsNothing);
  });

  testWidgets('unknown router collapses to device and node only',
      (tester) async {
    await tester.pumpWidget(_host(const PathAttribution(
      local: SegmentReading(state: SegmentState.unknown),
      upstream: SegmentReading(
        state: SegmentState.measured,
        latencyMs: 90,
        lossRate: 0,
        level: DiagLevel.good,
      ),
      culprit: Culprit.none,
    )));
    await tester.pumpAndSettle();

    expect(find.text('路由器'), findsNothing);
    expect(find.text('本设备'), findsOneWidget);
    expect(find.text('节点'), findsOneWidget);
  });

  testWidgets('fits a 328px phone column without overflow', (tester) async {
    await tester.pumpWidget(_host(_localCulprit, width: 328));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
