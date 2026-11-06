import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xconnect/l10n/app_localizations.dart';
import 'package:xconnect/services/traffic_routing.dart';
import 'package:xconnect/utils/app_theme.dart';
import 'package:xconnect/widgets/traffic_mode_group.dart';

Widget _host(Widget child, {Locale locale = const Locale('zh')}) {
  return MaterialApp(
    theme: AppTheme.lightTheme,
    locale: locale,
    supportedLocales: const [Locale('en'), Locale('zh')],
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await TrafficRouting.init();
    TrafficRouting.markActiveMode(null);
  });

  testWidgets(
      'renders Smart routing and Global proxy options with CN rules hints',
      (tester) async {
    await tester.pumpWidget(_host(const TrafficModeGroup()));
    await tester.pumpAndSettle();

    expect(find.text('选择流量方式'), findsOneWidget);
    expect(find.text('智能路由'), findsOneWidget);
    expect(
      find.text('局域网和命中中国大陆域名规则的流量直连，其余公网流量经节点。'),
      findsOneWidget,
    );
    expect(find.text('全局代理'), findsOneWidget);
    expect(
      find.text('公网业务流量经节点，局域网仍可直连。'),
      findsOneWidget,
    );
    expect(find.text('下次从 XConnect 连接时生效'), findsOneWidget);
    expect(
      find.text('仅适用于系统 VPN 接管的流量。IPv6 覆盖取决于设备的 VPN 路由。'),
      findsOneWidget,
    );
  });

  testWidgets('tapping Global proxy selects allVpn and updates state',
      (tester) async {
    await tester.pumpWidget(_host(const TrafficModeGroup()));
    await tester.pumpAndSettle();

    expect(TrafficRouting.selected.value, TrafficMode.smart);

    await tester.tap(find.text('全局代理'));
    await tester.pumpAndSettle();

    expect(TrafficRouting.selected.value, TrafficMode.allVpn);
  });

  testWidgets(
      'shows pending restart when user switches mode while tunnel is active',
      (tester) async {
    TrafficRouting.markActiveMode(TrafficMode.smart);
    await TrafficRouting.select(TrafficMode.allVpn);

    await tester.pumpWidget(_host(const TrafficModeGroup()));
    await tester.pumpAndSettle();

    // Indicates pending state
    expect(find.text('已选择 全局代理（下次连接时生效）'), findsOneWidget);
    expect(find.text('当前连接生效：智能路由'), findsOneWidget);

    // After reconnecting with allVpn, pending message clears
    TrafficRouting.markActiveMode(TrafficMode.allVpn);
    await tester.pumpAndSettle();

    expect(find.text('已选择 全局代理（下次连接时生效）'), findsNothing);
    expect(find.text('当前连接生效：全局代理'), findsOneWidget);
  });

  testWidgets('renders correctly in English locale', (tester) async {
    await tester.pumpWidget(
        _host(const TrafficModeGroup(), locale: const Locale('en')));
    await tester.pumpAndSettle();

    expect(find.text('TRAFFIC MODE'), findsOneWidget);
    expect(find.text('Smart routing'), findsOneWidget);
    expect(
      find.text(
        'LAN and traffic matching Chinese mainland domain rules go directly; other public traffic uses the VPN node.',
      ),
      findsOneWidget,
    );
    expect(find.text('Global proxy'), findsOneWidget);
    expect(
      find.text(
          'Public traffic uses the node, while LAN traffic remains direct.'),
      findsOneWidget,
    );
  });
}
