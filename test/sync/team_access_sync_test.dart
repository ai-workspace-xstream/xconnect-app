import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xconnect/services/session/network_access_policy.dart';
import 'package:xconnect/services/session/session_manager.dart';
import 'package:xconnect/services/sync/desktop_sync_service.dart';
import 'package:xconnect/services/vpn_config_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final policy = NetworkAccessPolicy.instance;
  final session = SessionManager.instance;
  final sync = DesktopSyncService.instance;
  const owner = 'https://accounts.example|member@example';
  Map<String, dynamic> teamAccess() => {
        'mode': 'dedicated',
        'teamId': 'acme',
        'allowed': true,
        'team': {
          'name': 'ACME',
          'validUntil': DateTime.now()
              .add(const Duration(hours: 1))
              .toUtc()
              .toIso8601String()
        }
      };

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'session.baseUrl': 'https://accounts.example',
      'session.token': 'test-session',
      'session.username': 'member@example'
    });
    session.onSessionReset = null;
    await session.init();
  });

  test('dedicated policy rejects public, other-team and other-account configs',
      () async {
    await policy.apply(teamAccess(), owner);
    policy.pending = false;
    policy.authorizedNodeIds = {'node-a'};
    expect(
        policy.canUse(
            serviceName: 'xconnect.sync.a',
            nodeOwner: owner,
            nodeTeamId: 'acme',
            nodeId: 'node-a'),
        isTrue);
    expect(
        policy.canUse(
            serviceName: 'manual',
            nodeOwner: owner,
            nodeTeamId: 'acme',
            nodeId: 'node-a'),
        isFalse);
    expect(
        policy.canUse(
            serviceName: 'xconnect.sync.a',
            nodeOwner: 'other-account',
            nodeTeamId: 'acme',
            nodeId: 'node-a'),
        isFalse);
    expect(
        policy.canUse(
            serviceName: 'xconnect.sync.a',
            nodeOwner: owner,
            nodeTeamId: 'other',
            nodeId: 'node-a'),
        isFalse);
    policy.invalidate(signedIn: false);
    expect(policy.canUse(serviceName: 'manual'), isFalse);
  });

  test('same-team policy refresh keeps an authorized connection usable',
      () async {
    await policy.apply(teamAccess(), owner);
    policy.pending = false;
    policy.authorizedNodeIds = {'node-a'};
    await policy.apply(teamAccess(), owner);
    expect(policy.active, isTrue);
    expect(policy.authorizedNodeIds, contains('node-a'));
  });

  test('team expiry rejects cached connections without a server response',
      () async {
    final access = teamAccess();
    (access['team'] as Map)['validUntil'] =
        DateTime.now().subtract(const Duration(seconds: 1)).toIso8601String();
    await policy.apply(access, owner);
    policy.pending = false;
    policy.authorizedNodeIds = {'node-a'};
    expect(
        policy.canUse(
            serviceName: 'xconnect.sync.a',
            nodeOwner: owner,
            nodeTeamId: 'acme',
            nodeId: 'node-a'),
        isFalse);
  });

  test('empty authoritative snapshot invalidates cached team nodes', () async {
    sync.client = MockClient((request) async => http.Response(
        request.url.path.endsWith('/network-access')
            ? jsonEncode(teamAccess())
            : '[]',
        200));
    final result = await sync.syncNow();
    expect(result.success, isFalse);
    expect(policy.active, isFalse);
    expect(policy.authorizedNodeIds, isEmpty);
    expect(policy.dedicated, isTrue);
  });

  test('team node outage cannot retain usable cached nodes', () async {
    sync.client = MockClient((request) async =>
        request.url.path.endsWith('/network-access')
            ? http.Response(jsonEncode(teamAccess()), 200)
            : http.Response('{"error":"team_nodes_unavailable"}', 503));
    final result = await sync.syncNow();
    expect(result.success, isFalse);
    expect(policy.active, isFalse);
    expect(policy.dedicated, isTrue);
  });

  test('a response from the signed-out session cannot apply a new policy',
      () async {
    final pending = Completer<http.Response>();
    final requested = Completer<void>();
    sync.client = MockClient((_) {
      requested.complete();
      return pending.future;
    });
    final operation = sync.syncNow();
    await requested.future;
    await session.logout();
    pending.complete(http.Response(jsonEncode(teamAccess()), 200));
    final result = await operation;
    expect(result.success, isFalse);
    expect(session.isLoggedIn, isFalse);
    expect(policy.active, isFalse);
  });

  test('logout clears persisted credentials even if native cleanup fails',
      () async {
    session.onSessionReset = () async {
      throw StateError('native failure');
    };
    await expectLater(session.logout(), throwsStateError);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('session.token'), isNull);
    expect(policy.active, isFalse);
  });

  test('managed node ownership survives serialization', () {
    final node = VpnNode(
        name: 'team',
        countryCode: 'TEAM',
        configPath: '/tmp/team.json',
        serviceName: 'xconnect.sync.team',
        managedOwner: owner,
        managedTeamId: 'acme',
        managedNodeId: 'node-a');
    final restored = VpnNode.fromJson(node.toJson());
    expect(restored.managedOwner, owner);
    expect(restored.managedTeamId, 'acme');
    expect(restored.managedNodeId, 'node-a');
  });
}
