import '../runtime/runtime_core_policy.dart';
import '../sdk/host_capability.dart';
import '../sdk/host_services.dart';
import '../sdk/product_manifest.dart';
import '../sdk/product_plugin.dart';

final class XConnectOnePlugin implements ProductPlugin {
  static const String pluginId = 'com.xconnect.one';

  @override
  ProductManifest get manifest => ProductManifest(
        pluginId: pluginId,
        displayName: 'XConnect-One',
        version: '0.1.0',
        hostApi: const HostApiRange(
          minimum: ApiVersion(1, 0, 0),
          maximumExclusive: ApiVersion(2, 0, 0),
        ),
        configSchemaVersion: 1,
        requiredCapabilities: const {
          HostCapability.accountSession,
          HostCapability.secretStore,
          HostCapability.tunnelRuntime,
          HostCapability.controlledNetwork,
          HostCapability.eventBus,
          HostCapability.logging,
          HostCapability.diagnostics,
          HostCapability.cliCommands,
          HostCapability.uiRoutes,
          HostCapability.tunnelProfiles,
        },
        runtimeCoreId: RuntimeCorePolicy.supportedCoreId,
      );

  @override
  Future<ProductRegistration> register(HostServices hostServices) async {
    return ProductRegistration(
      pluginId: pluginId,
      commands: [
        ProductCommand(id: 'join', path: ['join']),
        ProductCommand(id: 'up', path: ['up']),
        ProductCommand(id: 'down', path: ['down']),
        ProductCommand(id: 'status', path: ['status']),
        ProductCommand(id: 'config.sync', path: ['config', 'sync']),
        ProductCommand(id: 'diagnose', path: ['diagnose']),
        ProductCommand(id: 'leave', path: ['leave']),
      ],
      routes: const [
        ProductUiRoute(id: 'xconnect-one.home', path: '/products/xconnect-one'),
      ],
      profiles: const [
        ProductProfileType(
          id: 'xconnect-one.overlay',
          runtimeCoreId: RuntimeCorePolicy.supportedCoreId,
          runtimeAdapterId: RuntimeCorePolicy.supportedAdapterId,
        ),
      ],
    );
  }

  @override
  Future<ProductHealth> health() async => const ProductHealth(
        status: ProductHealthStatus.healthy,
        code: 'built_in_plugin_ready',
      );
}
