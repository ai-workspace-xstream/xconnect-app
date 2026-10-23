import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xconnect/services/session/network_access_policy.dart';
import 'package:xconnect/services/session/session_manager.dart';
import 'package:xconnect/services/sync/desktop_sync_service.dart';
import 'package:xconnect/services/vpn_config_service.dart';
import 'package:xconnect/utils/global_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final session = SessionManager.instance;
  final sync = DesktopSyncService.instance;
  final policy = NetworkAccessPolicy.instance;
  late Directory support;

  final access = {
    'mode': 'dedicated',
    'allowed': true,
    'accountId': 'account-a',
    'teamId': 'team-a',
    'team': {
      'name': 'Team A',
      'validUntil':
          DateTime.now().add(const Duration(hours: 1)).toIso8601String(),
    },
  };
  const nodes = [
    {
      'id': 'node-a',
      'name': 'Cached connection',
      'region': 'test',
      'vless_uri':
          'vless://11111111-1111-4111-8111-111111111111@edge.example:443'
              '?type=xhttp&security=tls&path=%2Fsecure',
    },
  ];

  setUpAll(() async {
    support = await Directory.systemTemp.createTemp('xconnect-managed-cache-');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => support.path,
    );
    messenger.setMockMessageHandler('flutter/assets', (message) async {
      if (utf8.decode(message!.buffer.asUint8List()) !=
          'macos/Runner/Configs/AppInfo.xcconfig') {
        return null;
      }
      return ByteData.sublistView(Uint8List.fromList(
        utf8.encode('PRODUCT_BUNDLE_IDENTIFIER=plus.svc.xconnect'),
      ));
    });
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'session.baseUrl': 'https://accounts.example',
      'session.token': 'test-session',
      'session.username': 'member@example',
    });
    session.onSessionReset = null;
    await session.init();
    await DnsConfig.init();
    await XhttpAdvancedConfig.init();
    await VpnConfig.importFromJson('[]');
    sync.client = MockClient((request) async {
      if (request.url.path.endsWith('/network-access')) {
        return http.Response(jsonEncode(access), 200);
      }
      if (request.url.path.endsWith('/nodes')) {
        return http.Response(jsonEncode(nodes), 200);
      }
      return http.Response('', 404);
    });
    expect((await sync.syncNow()).success, isTrue);
  });

  tearDownAll(() async => support.delete(recursive: true));

  test('same-account restart restores cached nodes despite network timeout',
      () async {
    await session.init();
    await VpnConfig.load();
    sync.client = MockClient((_) async => throw TimeoutException('offline'));
    expect((await sync.syncNow()).success, isFalse);
    expect(policy.active, isTrue);
    expect(VpnConfig.nodes.single.managedNodeId, 'node-a');
  });

  test('temporary team-node 503 keeps the last successful snapshot', () async {
    sync.client = MockClient((request) async =>
        request.url.path.endsWith('/network-access')
            ? http.Response(jsonEncode(access), 200)
            : http.Response('', 503));
    expect((await sync.syncNow()).success, isFalse);
    expect(policy.active, isTrue);
    expect(VpnConfig.nodes.single.managedNodeId, 'node-a');
  });

  test('malformed nonempty snapshot cannot erase valid cached nodes', () async {
    sync.client = MockClient((request) async =>
        request.url.path.endsWith('/network-access')
            ? http.Response(jsonEncode(access), 200)
            : http.Response('[{"broken":true}]', 200));
    expect((await sync.syncNow()).success, isFalse);
    expect(VpnConfig.nodes.single.managedNodeId, 'node-a');
  });

  test('another account cannot restore the cached authorization', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('session.username', 'other@example');
    await session.init();
    expect(policy.active, isFalse);
    expect(VpnConfig.nodes, isEmpty);
  });

  test('explicit denial invalidates the cache across restart', () async {
    sync.client = MockClient((_) async => http.Response('', 403));
    expect((await sync.syncNow()).success, isFalse);
    expect(policy.active, isFalse);
    await session.init();
    expect(policy.active, isFalse);
    expect(VpnConfig.nodes, isEmpty);
  });

  test('logout clears cached authorization even without cleanup callback',
      () async {
    await session.logout();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('session.token', 'new-session');
    await prefs.setString('session.username', 'member@example');
    await session.init();
    expect(policy.active, isFalse);
    expect(VpnConfig.nodes, isEmpty);
  });

  test('an authoritative empty list withdraws the offline snapshot', () async {
    sync.client = MockClient((request) async =>
        request.url.path.endsWith('/network-access')
            ? http.Response(jsonEncode(access), 200)
            : http.Response('[]', 200));
    expect((await sync.syncNow()).success, isFalse);
    await session.init();
    expect(policy.active, isFalse);
    expect(VpnConfig.nodes, isEmpty);
  });

  test('a changed team cannot restore the previous snapshot after a 503',
      () async {
    sync.client = MockClient((request) async =>
        request.url.path.endsWith('/network-access')
            ? http.Response(jsonEncode({...access, 'teamId': 'team-b'}), 200)
            : http.Response('', 503));
    expect((await sync.syncNow()).success, isFalse);
    await session.init();
    expect(policy.active, isFalse);
    expect(VpnConfig.nodes, isEmpty);
  });

  test('cache lifetime is bounded even when the login token remains stored',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final cache = jsonDecode(prefs.getString('network.cachedAccess')!) as Map;
    cache['savedAt'] = DateTime.now()
        .subtract(const Duration(hours: 25))
        .millisecondsSinceEpoch;
    await prefs.setString('network.cachedAccess', jsonEncode(cache));
    await session.init();
    expect(session.isLoggedIn, isTrue);
    expect(policy.active, isFalse);
    expect(VpnConfig.nodes, isEmpty);
  });

  test('expired team validity rejects an otherwise fresh offline cache',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final cache = jsonDecode(prefs.getString('network.cachedAccess')!) as Map;
    cache['validUntil'] =
        DateTime.now().subtract(const Duration(seconds: 1)).toIso8601String();
    await prefs.setString('network.cachedAccess', jsonEncode(cache));
    await session.init();
    expect(policy.active, isFalse);
    expect(VpnConfig.nodes, isEmpty);
  });

  test('policy cache contains neither credentials nor connection URIs',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('network.cachedAccess')!;
    expect(raw, isNot(contains('test-session')));
    expect(raw, isNot(contains('vless://')));
    expect(raw, isNot(contains('11111111-1111-4111-8111-111111111111')));
  });
}
