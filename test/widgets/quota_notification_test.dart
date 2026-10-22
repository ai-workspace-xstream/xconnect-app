import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xconnect/l10n/app_localizations.dart';
import 'package:xconnect/services/notifications/quota_notifications.dart';
import 'package:xconnect/widgets/quota_notification_button.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('bell opens readable notice, clears badge and fits phone width',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = QuotaNotifications.instance;
    await store.selectAccount('widget-account');
    await store.setReminders(true);
    await store.update('quotaLow');
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [AppLocalizations.delegate],
      home: Scaffold(
          appBar: AppBar(actions: const [QuotaNotificationButton()]),
          body: const QuotaStatusBanner()),
    ));
    await tester.pumpAndSettle();
    expect(store.hasUnread, isTrue);
    await tester.tap(find.byIcon(Icons.notifications_outlined));
    await tester.pumpAndSettle();
    expect(store.hasUnread, isFalse);
    expect(find.byType(SwitchListTile), findsOneWidget);
    expect(find.textContaining('Less than 10%'), findsNWidgets(2));
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(store.remindersEnabled, isFalse);
    expect(store.notice, isNull);
    expect(tester.takeException(), isNull);
  });
}
