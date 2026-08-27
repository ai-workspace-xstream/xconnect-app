import '../runtime/runtime_core_policy.dart';
import 'host_capability.dart';
import 'host_services.dart';
import 'product_manifest.dart';
import 'product_plugin.dart';

final class ProductActivation {
  const ProductActivation({
    required this.manifest,
    required this.registration,
    required this.health,
  });

  final ProductManifest manifest;
  final ProductRegistration registration;
  final ProductHealth health;
}

final class ProductRegistry {
  ProductRegistry({
    required this.hostApiVersion,
    required HostServices hostServices,
  }) : _hostServices = hostServices;

  final ApiVersion hostApiVersion;
  final HostServices _hostServices;
  final Map<String, ProductActivation> _active = {};

  Iterable<ProductActivation> get activeProducts => _active.values;

  ProductActivation? find(String pluginId) => _active[pluginId];

  Future<ProductActivation> activate(
    ProductPlugin plugin, {
    bool replace = false,
  }) async {
    final manifest = plugin.manifest;
    final current = _active[manifest.pluginId];
    if (current != null && !replace) {
      throw ProductRegistryException(
        manifest.pluginId,
        'plugin_already_active',
      );
    }
    if (!manifest.hostApi.supports(hostApiVersion)) {
      throw ProductRegistryException(
        manifest.pluginId,
        'incompatible_host_api',
      );
    }
    RuntimeCorePolicy.requireSupported(manifest.runtimeCoreId);

    final missingCapabilities = manifest.requiredCapabilities.difference(
      _hostServices.grantedCapabilities,
    );
    if (missingCapabilities.isNotEmpty) {
      throw MissingHostCapabilitiesException(
        manifest.pluginId,
        missingCapabilities,
      );
    }

    try {
      final scopedServices = ScopedHostServices(
        _hostServices,
        manifest.requiredCapabilities,
      );
      final registration = await plugin.register(scopedServices);
      _validateRegistration(manifest, registration);
      final health = await plugin.health();
      if (health.status == ProductHealthStatus.unavailable) {
        throw StateError('plugin reported unavailable health');
      }
      final activation = ProductActivation(
        manifest: manifest,
        registration: registration,
        health: health,
      );
      _active[manifest.pluginId] = activation;
      return activation;
    } catch (error) {
      throw ProductActivationException(manifest.pluginId, error);
    }
  }

  void _validateRegistration(
    ProductManifest manifest,
    ProductRegistration registration,
  ) {
    if (registration.pluginId != manifest.pluginId) {
      throw StateError('registration plugin ID does not match manifest');
    }
    _requireUnique(registration.commands.map((item) => item.id), 'command');
    _requireUnique(registration.routes.map((item) => item.id), 'route');
    _requireUnique(registration.profiles.map((item) => item.id), 'profile');
    for (final profile in registration.profiles) {
      RuntimeCorePolicy.requireSupported(profile.runtimeCoreId);
      if (profile.runtimeAdapterId != RuntimeCorePolicy.supportedAdapterId) {
        throw StateError(
          'unsupported runtime adapter: ${profile.runtimeAdapterId}',
        );
      }
    }
  }

  void _requireUnique(Iterable<String> values, String kind) {
    final seen = <String>{};
    for (final value in values) {
      if (!seen.add(value)) {
        throw StateError('duplicate $kind ID: $value');
      }
    }
  }
}

class ProductRegistryException implements Exception {
  const ProductRegistryException(this.pluginId, this.code);

  final String pluginId;
  final String code;

  @override
  String toString() =>
      'ProductRegistryException(pluginId: $pluginId, code: $code)';
}

final class MissingHostCapabilitiesException extends ProductRegistryException {
  MissingHostCapabilitiesException(String pluginId, Set<HostCapability> missing)
      : missing = Set.unmodifiable(missing),
        super(pluginId, 'missing_host_capabilities');

  final Set<HostCapability> missing;
}

final class ProductActivationException implements Exception {
  const ProductActivationException(this.pluginId, this.cause);

  final String pluginId;
  final Object cause;

  @override
  String toString() =>
      'ProductActivationException(pluginId: $pluginId, cause: $cause)';
}
