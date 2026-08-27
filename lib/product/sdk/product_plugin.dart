import 'host_services.dart';
import 'product_manifest.dart';

enum ProductHealthStatus { healthy, degraded, unavailable }

final class ProductHealth {
  const ProductHealth({required this.status, required this.code});

  final ProductHealthStatus status;
  final String code;
}

final class ProductCommand {
  ProductCommand({required this.id, required Iterable<String> path})
      : path = List.unmodifiable(path);

  final String id;
  final List<String> path;
}

final class ProductUiRoute {
  const ProductUiRoute({required this.id, required this.path});

  final String id;
  final String path;
}

final class ProductProfileType {
  const ProductProfileType({
    required this.id,
    required this.runtimeCoreId,
    required this.runtimeAdapterId,
  });

  final String id;
  final String runtimeCoreId;
  final String runtimeAdapterId;
}

final class ProductRegistration {
  ProductRegistration({
    required this.pluginId,
    Iterable<ProductCommand> commands = const [],
    Iterable<ProductUiRoute> routes = const [],
    Iterable<ProductProfileType> profiles = const [],
  })  : commands = List.unmodifiable(commands),
        routes = List.unmodifiable(routes),
        profiles = List.unmodifiable(profiles);

  final String pluginId;
  final List<ProductCommand> commands;
  final List<ProductUiRoute> routes;
  final List<ProductProfileType> profiles;
}

abstract interface class ProductPlugin {
  ProductManifest get manifest;

  Future<ProductRegistration> register(HostServices hostServices);

  Future<ProductHealth> health();
}
