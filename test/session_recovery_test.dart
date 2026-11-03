import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xconnect/services/session/session_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final session = SessionManager.instance;
  final endpoint =
      Uri.parse('https://accounts.example/api/auth/network-access');

  Future<void> init({String? cookie, String? refresh}) async {
    SharedPreferences.setMockInitialValues({
      'session.baseUrl': 'https://accounts.example',
      'session.username': 'member@example',
      'session.token': 'expired-token',
      if (cookie != null) 'session.cookie': cookie,
      if (refresh != null) 'session.refreshToken': refresh,
    });
    session.onSessionReset = null;
    await session.init();
  }

  test('valid cookie recovers expired bearer and persists it without logout',
      () async {
    await init(cookie: 'xc_session=valid-cookie');
    final generation = session.generation;
    final headers = {
      'Authorization': 'Bearer expired-token',
      'Cookie': session.cookie!
    };
    final client = MockClient((request) async => http.Response(
        '{}', request.headers.containsKey('Authorization') ? 401 : 200));
    final result =
        await session.getWithSessionRecovery(client, endpoint, headers);
    expect(result.statusCode, 200);
    expect(session.sessionToken, 'valid-cookie');
    expect(headers['Authorization'], 'Bearer valid-cookie');
    expect(session.generation, generation);
    expect(session.isLoggedIn, isTrue);
    await session.init();
    expect(session.sessionToken, 'valid-cookie');
  });

  test('refresh token renews bearer then retries original request', () async {
    await init(refresh: 'saved-refresh');
    final requests = <String>[];
    final client = MockClient((request) async {
      requests.add(request.url.path);
      if (request.method == 'POST') {
        expect(jsonDecode(request.body), {'refresh_token': 'saved-refresh'});
        return http.Response('{"access_token":"renewed"}', 200);
      }
      return http.Response('{}',
          request.headers['Authorization'] == 'Bearer renewed' ? 200 : 401);
    });
    final result = await session.getWithSessionRecovery(
        client, endpoint, {'Authorization': 'Bearer expired-token'});
    expect(result.statusCode, 200);
    expect(requests, [endpoint.path, '/api/auth/token/refresh', endpoint.path]);
    expect(session.isLoggedIn, isTrue);
    expect(session.sessionToken, 'renewed');
  });

  test('transient 401 retries in place; persistent 401 stays bounded',
      () async {
    await init();
    var calls = 0;
    final result = await session.getWithSessionRecovery(
        MockClient((_) async => http.Response('{}', ++calls == 1 ? 401 : 200)),
        endpoint, {});
    expect(result.statusCode, 200);
    expect(calls, 2);
    calls = 0;
    final denied = await session.getWithSessionRecovery(MockClient((_) async {
      calls++;
      return http.Response('{}', 401);
    }), endpoint, {});
    expect(denied.statusCode, 401);
    expect(calls, 2);
    expect(session.isLoggedIn, isTrue);
  });

  test('old refresh cannot overwrite a logged out session', () async {
    await init(refresh: 'saved-refresh');
    final refreshing = Completer<void>();
    final response = Completer<http.Response>();
    final client = MockClient((request) async {
      if (request.method == 'POST') {
        refreshing.complete();
        return response.future;
      }
      return http.Response('{}', 401);
    });
    final result = session.getWithSessionRecovery(client, endpoint, {});
    await refreshing.future;
    await session.logout();
    response.complete(http.Response('{"access_token":"stale"}', 200));
    await result;
    expect(session.isLoggedIn, isFalse);
    expect(session.sessionToken, isNull);
    expect((await SharedPreferences.getInstance()).getString('session.token'),
        isNull);
    expect(
        (await SharedPreferences.getInstance())
            .getString('session.refreshToken'),
        isNull);
  });
}
