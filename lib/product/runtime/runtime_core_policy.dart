abstract final class RuntimeCorePolicy {
  static const String supportedCoreId = 'xray';
  static const String supportedAdapterId = 'libXray';

  static void requireSupported(String coreId) {
    if (coreId != supportedCoreId) {
      throw UnsupportedRuntimeCoreException(coreId);
    }
  }
}

final class UnsupportedRuntimeCoreException implements Exception {
  const UnsupportedRuntimeCoreException(this.coreId);

  final String coreId;
  String get code => 'unsupported_runtime_core';

  @override
  String toString() =>
      'UnsupportedRuntimeCoreException(coreId: $coreId, code: $code)';
}
