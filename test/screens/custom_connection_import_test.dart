import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xconnect/l10n/app_localizations.dart';
import 'package:xconnect/screens/subscription_screen.dart';
import 'package:xconnect/services/session/network_access_policy.dart';
import 'package:xconnect/services/vpn_config_service.dart';
import 'package:xconnect/services/sync/xray_config_writer.dart';
import 'package:xconnect/utils/global_config.dart';

const link = 'vless://11111111-1111-4111-8111-111111111111@edge.example:443'
    '?type=xhttp&security=tls&path=%2Fsecure#custom-connection';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final policy = NetworkAccessPolicy.instance;
  late Directory support;

  setUpAll(() async {
    support = await Directory.systemTemp.createTemp('xconnect-import-test-');
    GlobalApplicationConfig.localConfigPathOverride =
        '${support.path}/vpn_nodes.json';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => support.path,
    );
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (message) async {
      final key = utf8.decode(message!.buffer.asUint8List());
      if (key == 'macos/Runner/Configs/AppInfo.xcconfig') {
        return ByteData.sublistView(Uint8List.fromList(
          utf8.encode('PRODUCT_BUNDLE_IDENTIFIER=plus.svc.xconnect'),
        ));
      }
      return null;
    });
    await DnsConfig.init();
    await XhttpAdvancedConfig.init();
  });

  setUp(() async {
    policy.dedicated = false;
    policy.invalidate(signedIn: true);
    await VpnConfig.importFromJson('[]');
  });

  tearDownAll(() async {
    GlobalApplicationConfig.localConfigPathOverride = null;
    await support.delete(recursive: true);
  });

  test('personal import persists and remains usable during account sync',
      () async {
    final saved = await VpnConfig.generateFromVlessUri(
      vlessUri: link,
      password: '',
      bundleId: 'plus.svc.xconnect',
      setMessage: (_) {},
      logMessage: (_) {},
    );
    expect(saved, isTrue);
    await VpnConfig.load();
    final node = VpnConfig.nodes.single;
    expect(node.name, 'custom-connection');
    expect(await File(node.configPath).readAsString(), contains('/secure'));
    expect(policy.canUse(serviceName: 'xconnect.sync.managed'), isFalse);
    policy.dedicated = true;
    expect(VpnConfig.nodes.single.name, 'custom-connection');
  });

  test('same-prefix and same-name imports own independent durable files',
      () async {
    for (final uri in [
      link,
      link.replaceAll('custom-connection', 'custom-second'),
      link
    ]) {
      expect(
          await VpnConfig.generateFromVlessUri(
            vlessUri: uri,
            password: '',
            bundleId: 'plus.svc.xconnect',
            setMessage: (_) {},
            logMessage: (_) {},
          ),
          isTrue);
    }
    final original = VpnConfig.allNodes.toList();
    expect(original.map((n) => n.configPath).toSet(), hasLength(3));
    expect(original.map((n) => n.serviceName).toSet(), hasLength(3));
    expect(original.map((n) => n.name).toSet(), hasLength(3));
    final contents = {
      for (final n in original)
        n.configPath: await File(n.configPath).readAsString()
    };
    final managedPath = await XrayConfigWriter.writeConfigForNode(
        json: contents.values.first,
        nodeName: original.first.name,
        nodeId: 'node-a');
    await XrayConfigWriter.registerNode(
        configPath: managedPath,
        nodeName: original.first.name,
        nodeId: 'node-a');
    expect(VpnConfig.allNodes, hasLength(4));
    await XrayConfigWriter.pruneSyncedNodes({});
    policy.invalidate(signedIn: false);
    await VpnConfig.load();
    expect(VpnConfig.allNodes, hasLength(3));
    for (final n in original) {
      expect(await File(n.configPath).readAsString(), contents[n.configPath]);
      expect(VpnConfig.getNodeByName(n.name)?.isManaged, isFalse);
    }
  });

  testWidgets('successful save returns home and publishes the imported node',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [AppLocalizations.delegate],
      home: Builder(builder: (context) {
        return Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => const SubscriptionScreen(initialVlessUri: link),
            )),
            child: const Text('Import'),
          ),
        );
      }),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    final revision = GlobalState.nodeListRevision.value;
    await tester.runAsync(() async {
      await tester.tap(find.byType(FilledButton));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(find.byType(SubscriptionScreen), findsNothing);
    expect(find.text('Connection saved'), findsOneWidget);
    expect(GlobalState.nodeListRevision.value, revision + 1);
    expect(GlobalState.lastImportedNodeName.value, 'custom-connection');
    expect(VpnConfig.nodes.single.name, 'custom-connection');
  });

  testWidgets('failed save stays retryable and does not publish a node',
      (tester) async {
    // A directory at the destination causes an actual filesystem write error.
    final configPath = await tester.runAsync(() async {
      final path = await GlobalApplicationConfig.getLocalConfigPath();
      final blocked = Directory(path);
      if (await File(blocked.path).exists()) {
        await File(blocked.path).delete();
      }
      await blocked.create(recursive: true);
      return blocked;
    });
    await tester.pumpWidget(const MaterialApp(
      localizationsDelegates: [AppLocalizations.delegate],
      home: SubscriptionScreen(initialVlessUri: link),
    ));
    await tester.pumpAndSettle();
    final revision = GlobalState.nodeListRevision.value;
    await tester.runAsync(() async {
      await tester.tap(find.byType(FilledButton));
      // Allow real disk I/O, which does not complete under the fake clock.
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull);
    expect(find.byType(SubscriptionScreen), findsOneWidget);
    expect(GlobalState.nodeListRevision.value, revision);
    expect(VpnConfig.allNodes, isEmpty);
    await tester.runAsync(() => configPath!.delete());
  });
}
