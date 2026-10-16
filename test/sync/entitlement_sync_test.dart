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
  late Directory support;

  setUpAll(() async {
    support = await Directory.systemTemp.createTemp('entitlement-sync');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => support.path,
    );
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'session.baseUrl': 'https://accounts.example',
      'session.token': 'session-token',
      'session.username': 'user@example',
    });
    session.onSessionReset = null;
    await session.init();
    await DnsConfig.init();
    await XhttpAdvancedConfig.init();
    for (final node in VpnConfig.allNodes.toList()) {
      VpnConfig.removeNode(node.name);
    }
    GlobalState.activeNodeName.value = '';
  });

  tearDownAll(() async {
    sync.dispose();
    await support.delete(recursive: true);
  });

  for (final kind in ['free', 'plus', 'team']) {
    test('$kind sync preserves and prioritizes custom imports', () async {
      final customFile = File('${support.path}/custom.json');
      await customFile.writeAsString('{"custom":true}');
      final custom = VpnNode(
        name: 'Edge',
        countryCode: 'CUSTOM',
        configPath: customFile.path,
        serviceName: 'custom.import',
      );
      VpnConfig.addNode(custom);
      GlobalState.activeNodeName.value = custom.name;
      var unavailable = false;
      var nodeStatus = 200;
      sync.client = MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer session-token');
        if (request.url.path.endsWith('/network-access')) {
          return http.Response(
            jsonEncode({
              'accountId': 'account-a',
              'mode': kind == 'team' ? 'dedicated' : 'personal',
              'allowed': true,
              if (kind == 'team') 'teamId': 'team-a',
            }),
            200,
          );
        }
        if (!request.url.path.endsWith('/nodes')) {
          return http.Response('', 404);
        }
        return http.Response(
          jsonEncode(
            unavailable
                ? []
                : [
                    {
                      'id': 'edge-a',
                      'name': 'Edge',
                      'region': 'r1',
                      'resource_class': kind,
                      'uri_scheme_xhttp':
                          'vless://11111111-1111-1111-1111-111111111111@edge.example:443'
                              '?security=tls&type=xhttp&path=%2Fsplit#Edge',
                    },
                  ],
          ),
          nodeStatus,
        );
      });

      expect((await sync.syncNow()).success, isTrue);
      final managed = VpnConfig.nodes.where((node) => node.isManaged).single;
      expect(managed.managedNodeId, 'edge-a');
      expect(await File(managed.configPath).readAsString(),
          contains('edge.example'));
      expect(managed.managedTeamId, kind == 'team' ? 'team-a' : '');
      expect(VpnConfig.nodes.first, same(custom));
      expect(VpnConfig.canUseNode(custom), isTrue);
      expect(GlobalState.activeNodeName.value, custom.name);
      expect(await customFile.readAsString(), '{"custom":true}');
      // Repeated sync updates only the stable managed identity.
      expect((await sync.syncNow()).success, isTrue);
      expect(VpnConfig.allNodes.length, 2);

      unavailable = true;
      expect((await sync.syncNow()).success, isFalse);
      expect(VpnConfig.nodes, [custom]);
      expect(await customFile.readAsString(), '{"custom":true}');
      expect(NetworkAccessPolicy.instance.authorizedNodeIds, isEmpty);
      // A blocked account cannot retain managed nodes, but it cannot erase
      // a separately imported connection either.
      nodeStatus = 403;
      expect((await sync.syncNow()).success, isFalse);
      expect(VpnConfig.nodes, [custom]);
    });
  }
}
