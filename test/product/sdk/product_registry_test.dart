import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/product/runtime/runtime_core_policy.dart';
import 'package:xconnect/product/sdk/host_capability.dart';
import 'package:xconnect/product/sdk/product_manifest.dart';
import 'package:xconnect/product/sdk/product_plugin.dart';
import 'package:xconnect/product/sdk/product_registry.dart';

import '../testkit/product_plugin_fakes.dart';

void main() {
  group('ProductRegistry', () {
    test('activates a compatible product atomically', () async {
      final registry = ProductRegistry(
        hostApiVersion: const ApiVersion(1, 0, 0),
        hostServices: fakeHostServices(
          capabilities: const {HostCapability.accountSession},
        ),
      );
      final plugin = FakeProductPlugin(
        manifest: fakeManifest(
          requiredCapabilities: const {HostCapability.accountSession},
        ),
      );

      final activation = await registry.activate(plugin);

      expect(activation.manifest.pluginId, 'com.example.product');
      expect(registry.find('com.example.product'), same(activation));
    });

    test('rejects a plugin when a required capability is missing', () async {
      final registry = ProductRegistry(
        hostApiVersion: const ApiVersion(1, 0, 0),
        hostServices: fakeHostServices(),
      );
      final plugin = FakeProductPlugin(
        manifest: fakeManifest(
          requiredCapabilities: const {HostCapability.secretStore},
        ),
      );

      await expectLater(
        registry.activate(plugin),
        throwsA(
          isA<MissingHostCapabilitiesException>().having(
            (error) => error.missing,
            'missing',
            const {HostCapability.secretStore},
          ),
        ),
      );
      expect(registry.activeProducts, isEmpty);
    });

    test('rejects an incompatible Host API before registration', () async {
      var registered = false;
      final registry = ProductRegistry(
        hostApiVersion: const ApiVersion(2, 0, 0),
        hostServices: fakeHostServices(),
      );
      final plugin = FakeProductPlugin(
        manifest: fakeManifest(),
        onRegister: (_) => registered = true,
      );

      await expectLater(
        registry.activate(plugin),
        throwsA(
          isA<ProductRegistryException>().having(
            (error) => error.code,
            'code',
            'incompatible_host_api',
          ),
        ),
      );
      expect(registered, isFalse);
    });

    test('rejects unsupported core before registration', () async {
      var registered = false;
      final registry = ProductRegistry(
        hostApiVersion: const ApiVersion(1, 0, 0),
        hostServices: fakeHostServices(),
      );
      final plugin = FakeProductPlugin(
        manifest: fakeManifest(runtimeCoreId: 'sing-box'),
        onRegister: (_) => registered = true,
      );

      await expectLater(
        registry.activate(plugin),
        throwsA(isA<UnsupportedRuntimeCoreException>()),
      );
      expect(registered, isFalse);
    });

    test('failed upgrade retains the previous active plugin', () async {
      final registry = ProductRegistry(
        hostApiVersion: const ApiVersion(1, 0, 0),
        hostServices: fakeHostServices(),
      );
      final first = await registry.activate(
        FakeProductPlugin(manifest: fakeManifest(version: '1.0.0')),
      );
      final brokenUpgrade = FakeProductPlugin(
        manifest: fakeManifest(version: '1.1.0'),
        registerError: StateError('initialization failed'),
      );

      await expectLater(
        registry.activate(brokenUpgrade, replace: true),
        throwsA(isA<ProductActivationException>()),
      );

      expect(registry.find('com.example.product'), same(first));
      expect(registry.find('com.example.product')!.manifest.version, '1.0.0');
    });

    test(
      'rejects an invalid profile adapter without replacing old state',
      () async {
        final registry = ProductRegistry(
          hostApiVersion: const ApiVersion(1, 0, 0),
          hostServices: fakeHostServices(),
        );
        final first = await registry.activate(
          FakeProductPlugin(manifest: fakeManifest(version: '1.0.0')),
        );
        final invalid = FakeProductPlugin(
          manifest: fakeManifest(version: '1.1.0'),
          registration: ProductRegistration(
            pluginId: 'com.example.product',
            profiles: const [
              ProductProfileType(
                id: 'overlay',
                runtimeCoreId: 'xray',
                runtimeAdapterId: 'other-adapter',
              ),
            ],
          ),
        );

        await expectLater(
          registry.activate(invalid, replace: true),
          throwsA(isA<ProductActivationException>()),
        );
        expect(registry.find('com.example.product'), same(first));
      },
    );
  });
}
