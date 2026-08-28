import 'host_capability.dart';

final class ApiVersion implements Comparable<ApiVersion> {
  const ApiVersion(this.major, this.minor, this.patch);

  factory ApiVersion.parse(String value) {
    final match = RegExp(
      r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$',
    ).firstMatch(value);
    if (match == null) {
      throw FormatException('Invalid API version: $value');
    }
    return ApiVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }

  final int major;
  final int minor;
  final int patch;

  @override
  int compareTo(ApiVersion other) {
    final majorComparison = major.compareTo(other.major);
    if (majorComparison != 0) return majorComparison;
    final minorComparison = minor.compareTo(other.minor);
    if (minorComparison != 0) return minorComparison;
    return patch.compareTo(other.patch);
  }

  @override
  bool operator ==(Object other) =>
      other is ApiVersion &&
      major == other.major &&
      minor == other.minor &&
      patch == other.patch;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}

final class HostApiRange {
  const HostApiRange({required this.minimum, required this.maximumExclusive});

  final ApiVersion minimum;
  final ApiVersion maximumExclusive;

  bool supports(ApiVersion version) =>
      version.compareTo(minimum) >= 0 &&
      version.compareTo(maximumExclusive) < 0;

  Map<String, Object> toJson() => {
        'minimum': minimum.toString(),
        'maximum_exclusive': maximumExclusive.toString(),
      };

  factory HostApiRange.fromJson(Map<String, Object?> json) {
    return HostApiRange(
      minimum: ApiVersion.parse(json['minimum'] as String),
      maximumExclusive: ApiVersion.parse(json['maximum_exclusive'] as String),
    );
  }
}

enum PluginDelivery {
  builtIn('built-in'),
  signedBundle('signed-bundle');

  const PluginDelivery(this.id);

  final String id;

  static PluginDelivery fromId(String id) {
    return values.firstWhere(
      (delivery) => delivery.id == id,
      orElse: () => throw FormatException('Unknown plugin delivery: $id'),
    );
  }
}

final class ProductPluginSignature {
  const ProductPluginSignature({
    required this.algorithm,
    required this.keyId,
    required this.value,
  });

  final String algorithm;
  final String keyId;
  final String value;

  Map<String, Object> toJson() => {
        'algorithm': algorithm,
        'key_id': keyId,
        'value': value,
      };

  factory ProductPluginSignature.fromJson(Map<String, Object?> json) {
    return ProductPluginSignature(
      algorithm: json['algorithm'] as String,
      keyId: json['key_id'] as String,
      value: json['value'] as String,
    );
  }
}

final class ProductManifest {
  ProductManifest({
    required this.pluginId,
    required this.displayName,
    required this.version,
    required this.hostApi,
    required this.configSchemaVersion,
    required Set<HostCapability> requiredCapabilities,
    Set<HostCapability> optionalCapabilities = const {},
    required this.runtimeCoreId,
    this.manifestSchemaVersion = 1,
    this.delivery = PluginDelivery.builtIn,
    this.signature,
  })  : requiredCapabilities = Set.unmodifiable(requiredCapabilities),
        optionalCapabilities = Set.unmodifiable(optionalCapabilities) {
    _validate();
  }

  final int manifestSchemaVersion;
  final String pluginId;
  final String displayName;
  final String version;
  final HostApiRange hostApi;
  final int configSchemaVersion;
  final Set<HostCapability> requiredCapabilities;
  final Set<HostCapability> optionalCapabilities;
  final String runtimeCoreId;
  final PluginDelivery delivery;
  final ProductPluginSignature? signature;

  void _validate() {
    if (!RegExp(r'^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)+$').hasMatch(pluginId)) {
      throw FormatException('Invalid plugin ID: $pluginId');
    }
    if (!RegExp(
      r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)'
      r'(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$',
    ).hasMatch(version)) {
      throw FormatException('Invalid plugin version: $version');
    }
    if (hostApi.minimum.compareTo(hostApi.maximumExclusive) >= 0) {
      throw const FormatException(
        'Host API maximum must be greater than minimum',
      );
    }
    if (manifestSchemaVersion < 1 || configSchemaVersion < 1) {
      throw const FormatException('Schema versions must be positive');
    }
    if (requiredCapabilities.intersection(optionalCapabilities).isNotEmpty) {
      throw const FormatException(
        'Required and optional capabilities must be disjoint',
      );
    }
    if (delivery == PluginDelivery.signedBundle && signature == null) {
      throw const FormatException('Signed bundles require a signature');
    }
    if (delivery == PluginDelivery.builtIn && signature != null) {
      throw const FormatException(
        'Built-in plugins must not embed a signature',
      );
    }
  }

  Map<String, Object> toJson() {
    final capabilities = requiredCapabilities.map((item) => item.id).toList()
      ..sort();
    final optional = optionalCapabilities.map((item) => item.id).toList()
      ..sort();
    return {
      'manifest_schema_version': manifestSchemaVersion,
      'plugin_id': pluginId,
      'display_name': displayName,
      'version': version,
      'host_api': hostApi.toJson(),
      'config_schema_version': configSchemaVersion,
      'required_capabilities': capabilities,
      if (optional.isNotEmpty) 'optional_capabilities': optional,
      'runtime_core_id': runtimeCoreId,
      'delivery': delivery.id,
      if (signature != null) 'signature': signature!.toJson(),
    };
  }

  factory ProductManifest.fromJson(Map<String, Object?> json) {
    final capabilities = (json['required_capabilities'] as List<Object?>)
        .map((item) => HostCapability.fromId(item as String))
        .toSet();
    final optionalCapabilities =
        (json['optional_capabilities'] as List<Object?>? ?? const [])
            .map((item) => HostCapability.fromId(item as String))
            .toSet();
    final signatureJson = json['signature'];
    return ProductManifest(
      manifestSchemaVersion: json['manifest_schema_version'] as int,
      pluginId: json['plugin_id'] as String,
      displayName: json['display_name'] as String,
      version: json['version'] as String,
      hostApi: HostApiRange.fromJson(
        Map<String, Object?>.from(json['host_api'] as Map),
      ),
      configSchemaVersion: json['config_schema_version'] as int,
      requiredCapabilities: capabilities,
      optionalCapabilities: optionalCapabilities,
      runtimeCoreId: json['runtime_core_id'] as String,
      delivery: PluginDelivery.fromId(json['delivery'] as String),
      signature: signatureJson == null
          ? null
          : ProductPluginSignature.fromJson(
              Map<String, Object?>.from(signatureJson as Map),
            ),
    );
  }
}
