import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xconnect/l10n/app_localizations.dart';
import 'package:xconnect/screens/login_screen.dart';
import 'package:xconnect/services/session/session_manager.dart';

void main() {
  testWidgets('rejected persisted session offers login without signing out',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'session.baseUrl': 'https://accounts.example',
      'session.username': 'member@example',
      'session.token': 'rejected-session',
      'session.reauthenticationRequired': true,
    });
    final session = SessionManager.instance;
    session.onSessionReset = null;
    await session.init();
    await tester.pumpWidget(const MaterialApp(
      localizationsDelegates: [AppLocalizations.delegate],
      locale: Locale('en'),
      home: Scaffold(body: LoginScreen()),
    ));
    await tester.pumpAndSettle();
    final reauthenticate = find.text('Sign in again');
    expect(reauthenticate, findsOneWidget);
    await tester.ensureVisible(reauthenticate);
    await tester.tap(reauthenticate);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'https://accounts.example'),
        findsOneWidget);
    expect(find.widgetWithText(TextField, 'member@example'), findsOneWidget);
    expect(session.sessionToken, 'rejected-session');
    expect(session.isLoggedIn, isTrue);
    await tester.pumpWidget(const SizedBox());
  });
}
