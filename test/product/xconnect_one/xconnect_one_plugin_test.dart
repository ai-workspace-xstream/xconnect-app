import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/product/runtime/runtime_core_policy.dart';
import 'package:xconnect/product/sdk/product_manifest.dart';
import 'package:xconnect/product/sdk/product_registry.dart';
import 'package:xconnect/product/sdk/host_capability.dart';
import 'package:xconnect/product/sdk/host_services.dart';
import 'package:xconnect/product/xconnect_one/mobile_enrollment.dart';
import 'package:xconnect/product/xconnect_one/xconnect_one_plugin.dart';

import 'mobile_enrollment_fakes.dart';

void main() {
  group('XConnectOnePlugin', () {
    test('declares the built-in product identity and v1 runtime', () {
      final manifest = XConnectOnePlugin().manifest;

      expect(manifest.pluginId, 'com.xconnect.one');
      expect(manifest.displayName, 'XConnect-One');
      expect(manifest.delivery, PluginDelivery.builtIn);
      expect(manifest.runtimeCoreId, RuntimeCorePolicy.supportedCoreId);
      expect(manifest.signature, isNull);
    });

    test(
      'registers mobile UI without granting a shell CLI or QR scanner',
      () async {
        final plugin = XConnectOnePlugin();
        final registry = ProductRegistry(
          hostApiVersion: const ApiVersion(1, 0, 0),
          hostServices: _pluginHostServices(),
        );

        final activation = await registry.activate(plugin);

        expect(activation.registration.commands, isEmpty);
        expect(
          activation.registration.routes.single.path,
          '/products/xconnect-one',
        );
        expect(activation.registration.profiles.single.runtimeCoreId, 'xray');
        expect(
          activation.registration.profiles.single.runtimeAdapterId,
          'libXray',
        );
        expect(
          plugin.enrollmentController.state.phase,
          XConnectOneEnrollmentPhase.idle,
        );
        plugin.enrollmentController.dispose();
      },
    );

    test(
      'uses a granted QR SPI and exposes CLI metadata only when granted',
      () async {
        final plugin = XConnectOnePlugin();
        final registry = ProductRegistry(
          hostApiVersion: const ApiVersion(1, 0, 0),
          hostServices: _pluginHostServices(
            qrScanner: FakeQrScanner(validInvite()),
            grantCli: true,
          ),
        );

        final activation = await registry.activate(plugin);
        await plugin.enrollmentController.scanQr();

        expect(
          activation.registration.commands.map((command) => command.id),
          containsAll(['join', 'up', 'down', 'status', 'config.sync']),
        );
        expect(
          plugin.enrollmentController.state.phase,
          XConnectOneEnrollmentPhase.inviteReady,
        );
        plugin.enrollmentController.dispose();
      },
    );
  });
}

CapabilityHostServices _pluginHostServices({
  XConnectOneQrScanner? qrScanner,
  bool grantCli = false,
}) {
  final platform = _CombinedFakePlatformHost();
  return CapabilityHostServices({
    HostCapability.secretStoreProbe: platform,
    HostCapability.tunnelRuntime: const FakeProtectedTunnelHost(),
    HostCapability.overlayEnrollment: platform,
    HostCapability.inviteIngress: platform,
    if (qrScanner != null) HostCapability.qrScanner: qrScanner,
    HostCapability.uiRoutes: const Object(),
    HostCapability.tunnelProfiles: const Object(),
    if (grantCli) HostCapability.cliCommands: const Object(),
  });
}

final class _CombinedFakePlatformHost
    implements
        XConnectOneJoinService,
        XConnectOneInviteIngress,
        XConnectOneSecureStorageProbe {
  final FakeJoinService _join = FakeJoinService();
  final FakeInviteIngress _ingress = FakeInviteIngress();
  final FakeSecureStorage _storage = FakeSecureStorage();

  @override
  Future<void> clearTransient() => _join.clearTransient();

  @override
  Future<void> dispose() => _ingress.dispose();

  @override
  Stream<XConnectOneInviteIngressEvent> get events => _ingress.events;

  @override
  Future<XConnectOneJoinResult> join(String invitePayload) =>
      _join.join(invitePayload);

  @override
  Future<XConnectOneJoinBridgeCapability> probeJoinBridge() =>
      _join.probeJoinBridge();

  @override
  Future<SecureStorageCapability> probeSecureStorage() =>
      _storage.probeSecureStorage();

  @override
  Future<XConnectOneJoinResult> resume() => _join.resume();

  @override
  Future<void> start() => _ingress.start();
}
