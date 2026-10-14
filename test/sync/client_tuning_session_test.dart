import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xconnect/services/session/session_manager.dart';
import 'package:xconnect/services/sync/desktop_sync_service.dart';
import 'package:xconnect/services/tuning/client_tuning.dart';
import 'package:xconnect/utils/global_config.dart';

const _tuning = <String, dynamic>{
  'version': 1,
  'revision': 'old-session',
  'defaults': <String, dynamic>{
    'xhttp': <String, dynamic>{'scMaxEachPostBytes': 500000},
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final session = SessionManager.instance;
  final sync = DesktopSyncService.instance;
  late Directory support;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('xconnect-sync');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => support.path,
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      'session.baseUrl': 'https://accounts.example',
      'session.token': 'test-session',
      'session.username': 'member@example',
    });
    await DnsConfig.init();
    await XhttpAdvancedConfig.init();
    ClientTuning.profileForTesting = null;
    await session.init();
    session.onSessionReset = sync.clearManagedConnections;
  });

  tearDown(() async {
    session.onSessionReset = null;
    await support.delete(recursive: true);
  });

  test('signing out during the tuning request discards the old response',
      () async {
    final tuningResponse = Completer<http.Response>();
    final tuningRequested = Completer<void>();
    sync.client = MockClient((request) {
      final path = request.url.path;
      if (path.endsWith('/network-access')) {
        return Future.value(http.Response('', 404));
      }
      if (path.endsWith(ClientTuning.endpointPath)) {
        tuningRequested.complete();
        return tuningResponse.future;
      }
      return Future.value(http.Response(
          jsonEncode(<Map<String, String>>[
            <String, String>{
              'id': 'jp-1',
              'name': 'JP',
              'region': 'jp',
              'vless_uri':
                  'vless://11111111-1111-1111-1111-111111111111@edge.example:443'
                      '?security=tls&type=xhttp&path=%2Fsplit#JP',
            },
          ]),
          200));
    });

    final result = sync.syncNow();
    await tuningRequested.future;
    await session.logout();
    tuningResponse.complete(http.Response(jsonEncode(_tuning), 200));

    final outcome = await result;
    expect(outcome.success, isFalse);
    expect(ClientTuning.profile, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('clientTuning.v1'), isNull);
    expect(prefs.getInt('sync.lastSuccessAt'), isNull);
  });
}
