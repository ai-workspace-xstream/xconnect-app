import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/product/runtime/runtime_core_policy.dart';

void main() {
  group('RuntimeCorePolicy', () {
    test('accepts the v1 xray core and libXray adapter', () {
      expect(RuntimeCorePolicy.supportedCoreId, 'xray');
      expect(RuntimeCorePolicy.supportedAdapterId, 'libXray');
      expect(() => RuntimeCorePolicy.requireSupported('xray'), returnsNormally);
    });

    for (final coreId in ['sing-box', 'unknown', 'Xray', '']) {
      test('rejects unsupported core "$coreId" without fallback', () {
        expect(
          () => RuntimeCorePolicy.requireSupported(coreId),
          throwsA(
            isA<UnsupportedRuntimeCoreException>()
                .having((error) => error.coreId, 'coreId', coreId)
                .having(
                  (error) => error.code,
                  'code',
                  'unsupported_runtime_core',
                ),
          ),
        );
      });
    }
  });
}
