import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/product/runtime/runtime_core_policy.dart';
import 'package:xconnect/product/sdk/product_manifest.dart';
import 'package:xconnect/product/sdk/product_registry.dart';
import 'package:xconnect/product/xconnect_one/xconnect_one_plugin.dart';

import '../testkit/product_plugin_fakes.dart';

void main() {
  group('XConnectOnePlugin', () {
    test('declares the built-in product identity and v1 runtime', () {
      final manifest = XConnectOnePlugin().manifest;

      expect(manifest.pluginId, 'com.xconnect.one');
      expect(manifest.displayName, 'XConnect-One');
      expect(manifest.delivery, PluginDelivery.builtIn);
      expect(manifest.runtimeCoreId, RuntimeCorePolicy.supportedCoreId);
      expect(manifest.signature, isNull);
    });

    test('registers CLI, UI, and profile contributions', () async {
      final plugin = XConnectOnePlugin();
      final registry = ProductRegistry(
        hostApiVersion: const ApiVersion(1, 0, 0),
        hostServices: fakeHostServices(
          capabilities: plugin.manifest.requiredCapabilities,
        ),
      );

      final activation = await registry.activate(plugin);

      expect(
        activation.registration.commands.map((command) => command.id),
        containsAll(['join', 'up', 'down', 'status', 'config.sync']),
      );
      expect(
        activation.registration.routes.single.path,
        '/products/xconnect-one',
      );
      expect(activation.registration.profiles.single.runtimeCoreId, 'xray');
      expect(
        activation.registration.profiles.single.runtimeAdapterId,
        'libXray',
      );
    });
  });
}
