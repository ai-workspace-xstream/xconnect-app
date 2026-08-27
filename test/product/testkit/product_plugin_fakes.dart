import 'package:xconnect/product/sdk/host_capability.dart';
import 'package:xconnect/product/sdk/host_services.dart';
import 'package:xconnect/product/sdk/product_manifest.dart';
import 'package:xconnect/product/sdk/product_plugin.dart';

final class FakeHostService {
  const FakeHostService(this.capability);

  final HostCapability capability;
}

CapabilityHostServices fakeHostServices({
  Set<HostCapability> capabilities = const {},
}) {
  return CapabilityHostServices({
    for (final capability in capabilities)
      capability: FakeHostService(capability),
  });
}

final class FakeProductPlugin implements ProductPlugin {
  FakeProductPlugin({
    required this.manifest,
    ProductRegistration? registration,
    ProductHealth? health,
    this.registerError,
    this.onRegister,
    this.onHealth,
  })  : _registration =
            registration ?? ProductRegistration(pluginId: manifest.pluginId),
        _health = health ??
            const ProductHealth(
              status: ProductHealthStatus.healthy,
              code: 'ready',
            );

  @override
  final ProductManifest manifest;
  final ProductRegistration _registration;
  final ProductHealth _health;
  final Object? registerError;
  final void Function(HostServices services)? onRegister;
  final void Function()? onHealth;

  @override
  Future<ProductRegistration> register(HostServices hostServices) async {
    onRegister?.call(hostServices);
    if (registerError != null) throw registerError!;
    return _registration;
  }

  @override
  Future<ProductHealth> health() async {
    onHealth?.call();
    return _health;
  }
}

ProductManifest fakeManifest({
  String pluginId = 'com.example.product',
  String version = '1.0.0',
  HostApiRange hostApi = const HostApiRange(
    minimum: ApiVersion(1, 0, 0),
    maximumExclusive: ApiVersion(2, 0, 0),
  ),
  Set<HostCapability> requiredCapabilities = const {},
  String runtimeCoreId = 'xray',
  PluginDelivery delivery = PluginDelivery.builtIn,
  ProductPluginSignature? signature,
}) {
  return ProductManifest(
    pluginId: pluginId,
    displayName: 'Example Product',
    version: version,
    hostApi: hostApi,
    configSchemaVersion: 1,
    requiredCapabilities: requiredCapabilities,
    runtimeCoreId: runtimeCoreId,
    delivery: delivery,
    signature: signature,
  );
}
