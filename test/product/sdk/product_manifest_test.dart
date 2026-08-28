import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/product/sdk/host_capability.dart';
import 'package:xconnect/product/sdk/product_manifest.dart';

void main() {
  group('ProductManifest', () {
    test('serializes a stable manifest contract and round-trips', () {
      final manifest = ProductManifest(
        pluginId: 'com.xconnect.one',
        displayName: 'XConnect-One',
        version: '1.2.3-beta.1+45',
        hostApi: const HostApiRange(
          minimum: ApiVersion(1, 0, 0),
          maximumExclusive: ApiVersion(2, 0, 0),
        ),
        configSchemaVersion: 3,
        requiredCapabilities: const {
          HostCapability.tunnelRuntime,
          HostCapability.accountSession,
        },
        runtimeCoreId: 'xray',
      );

      final json = manifest.toJson();

      expect(json, {
        'manifest_schema_version': 1,
        'plugin_id': 'com.xconnect.one',
        'display_name': 'XConnect-One',
        'version': '1.2.3-beta.1+45',
        'host_api': {'minimum': '1.0.0', 'maximum_exclusive': '2.0.0'},
        'config_schema_version': 3,
        'required_capabilities': ['account.session', 'tunnel.runtime'],
        'runtime_core_id': 'xray',
        'delivery': 'built-in',
      });

      final decoded = ProductManifest.fromJson(json);
      expect(decoded.toJson(), json);
    });

    test('requires signatures for future external bundles', () {
      expect(
        () => ProductManifest(
          pluginId: 'com.example.bundle',
          displayName: 'Bundle',
          version: '1.0.0',
          hostApi: const HostApiRange(
            minimum: ApiVersion(1, 0, 0),
            maximumExclusive: ApiVersion(2, 0, 0),
          ),
          configSchemaVersion: 1,
          requiredCapabilities: const {},
          runtimeCoreId: 'xray',
          delivery: PluginDelivery.signedBundle,
        ),
        throwsFormatException,
      );
    });

    test('uses an exclusive upper host API bound', () {
      const range = HostApiRange(
        minimum: ApiVersion(1, 2, 0),
        maximumExclusive: ApiVersion(2, 0, 0),
      );

      expect(range.supports(const ApiVersion(1, 2, 0)), isTrue);
      expect(range.supports(const ApiVersion(1, 9, 9)), isTrue);
      expect(range.supports(const ApiVersion(2, 0, 0)), isFalse);
    });

    test('round-trips optional capabilities and rejects overlap', () {
      final manifest = ProductManifest(
        pluginId: 'com.xconnect.one',
        displayName: 'XConnect-One',
        version: '1.0.0',
        hostApi: const HostApiRange(
          minimum: ApiVersion(1, 0, 0),
          maximumExclusive: ApiVersion(2, 0, 0),
        ),
        configSchemaVersion: 1,
        requiredCapabilities: const {HostCapability.secretStore},
        optionalCapabilities: const {HostCapability.qrScanner},
        runtimeCoreId: 'xray',
      );

      expect(
        ProductManifest.fromJson(manifest.toJson()).optionalCapabilities,
        const {HostCapability.qrScanner},
      );
      expect(
        () => ProductManifest(
          pluginId: 'com.xconnect.one',
          displayName: 'XConnect-One',
          version: '1.0.0',
          hostApi: const HostApiRange(
            minimum: ApiVersion(1, 0, 0),
            maximumExclusive: ApiVersion(2, 0, 0),
          ),
          configSchemaVersion: 1,
          requiredCapabilities: const {HostCapability.qrScanner},
          optionalCapabilities: const {HostCapability.qrScanner},
          runtimeCoreId: 'xray',
        ),
        throwsFormatException,
      );
    });
  });
}
