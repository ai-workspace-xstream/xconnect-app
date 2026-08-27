import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/product/sdk/host_capability.dart';
import 'package:xconnect/product/sdk/host_services.dart';

import '../testkit/product_plugin_fakes.dart';

void main() {
  group('HostServices', () {
    test('returns a typed service for a granted capability', () {
      final host = fakeHostServices(
        capabilities: const {HostCapability.accountSession},
      );

      final service = host.require<FakeHostService>(
        HostCapability.accountSession,
      );

      expect(service.capability, HostCapability.accountSession);
    });

    test('rejects unavailable capabilities', () {
      final host = fakeHostServices();

      expect(
        () => host.require<FakeHostService>(HostCapability.secretStore),
        throwsA(isA<HostCapabilityException>()),
      );
    });

    test('scope prevents access beyond manifest declarations', () {
      final host = fakeHostServices(
        capabilities: const {
          HostCapability.accountSession,
          HostCapability.secretStore,
        },
      );
      final scoped = ScopedHostServices(host, const {
        HostCapability.accountSession,
      });

      expect(scoped.grantedCapabilities, const {HostCapability.accountSession});
      expect(
        () => scoped.require<FakeHostService>(HostCapability.secretStore),
        throwsA(
          isA<HostCapabilityException>().having(
            (error) => error.reason,
            'reason',
            contains('manifest'),
          ),
        ),
      );
    });
  });
}
