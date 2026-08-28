import '../runtime/runtime_core_policy.dart';
import '../sdk/host_capability.dart';
import '../sdk/host_services.dart';
import '../sdk/product_manifest.dart';
import '../sdk/product_plugin.dart';
import 'mobile_enrollment.dart';

final class XConnectOnePlugin implements ProductPlugin {
  static const String pluginId = 'com.xconnect.one';

  XConnectOneEnrollmentController? _enrollmentController;
  ProductHealth _health = const ProductHealth(
    status: ProductHealthStatus.degraded,
    code: 'product_not_registered',
  );

  XConnectOneEnrollmentController get enrollmentController {
    final controller = _enrollmentController;
    if (controller == null) {
      throw StateError('XConnect-One plugin has not been registered');
    }
    return controller;
  }

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
          HostCapability.secretStoreProbe,
          HostCapability.tunnelRuntime,
          HostCapability.overlayEnrollment,
          HostCapability.inviteIngress,
        },
        optionalCapabilities: const {
          HostCapability.accountSession,
          HostCapability.secretStore,
          HostCapability.controlledNetwork,
          HostCapability.eventBus,
          HostCapability.logging,
          HostCapability.diagnostics,
          HostCapability.qrScanner,
          HostCapability.cliCommands,
          HostCapability.uiRoutes,
          HostCapability.tunnelProfiles,
        },
        runtimeCoreId: RuntimeCorePolicy.supportedCoreId,
      );

  @override
  Future<ProductRegistration> register(HostServices hostServices) async {
    final joinService = hostServices.require<XConnectOneJoinService>(
      HostCapability.overlayEnrollment,
    );
    final inviteIngress = hostServices.require<XConnectOneInviteIngress>(
      HostCapability.inviteIngress,
    );
    hostServices.require<XConnectOneProtectedTunnelHost>(
      HostCapability.tunnelRuntime,
    );
    final qrScanner = hostServices.grantedCapabilities
            .contains(HostCapability.qrScanner)
        ? hostServices.require<XConnectOneQrScanner>(HostCapability.qrScanner)
        : const UnavailableXConnectOneQrScanner();
    final secureStorage = hostServices.require<XConnectOneSecureStorageProbe>(
      HostCapability.secretStoreProbe,
    );
    final controller = XConnectOneEnrollmentController(
      joinService: joinService,
      inviteIngress: inviteIngress,
      qrScanner: qrScanner,
      secureStorage: secureStorage,
    );
    await controller.initialize();
    _enrollmentController = controller;

    final bridge = await joinService.probeJoinBridge();
    final storage = await secureStorage.probeSecureStorage();
    _health = bridge.available && storage.isAvailable
        ? const ProductHealth(
            status: ProductHealthStatus.healthy,
            code: 'mobile_enrollment_ready',
          )
        : ProductHealth(
            status: ProductHealthStatus.degraded,
            code: bridge.available ? storage.code : bridge.code,
          );

    final hasCli = hostServices.grantedCapabilities.contains(
      HostCapability.cliCommands,
    );
    final hasUi = hostServices.grantedCapabilities.contains(
      HostCapability.uiRoutes,
    );
    final hasProfiles = hostServices.grantedCapabilities.contains(
      HostCapability.tunnelProfiles,
    );
    return ProductRegistration(
      pluginId: pluginId,
      commands: hasCli
          ? [
              ProductCommand(id: 'join', path: ['join']),
              ProductCommand(id: 'up', path: ['up']),
              ProductCommand(id: 'down', path: ['down']),
              ProductCommand(id: 'status', path: ['status']),
              ProductCommand(id: 'config.sync', path: ['config', 'sync']),
              ProductCommand(id: 'diagnose', path: ['diagnose']),
              ProductCommand(id: 'leave', path: ['leave']),
            ]
          : const [],
      routes: hasUi
          ? const [
              ProductUiRoute(
                id: 'xconnect-one.home',
                path: '/products/xconnect-one',
              ),
            ]
          : const [],
      profiles: hasProfiles
          ? const [
              ProductProfileType(
                id: 'xconnect-one.overlay',
                runtimeCoreId: RuntimeCorePolicy.supportedCoreId,
                runtimeAdapterId: RuntimeCorePolicy.supportedAdapterId,
              ),
            ]
          : const [],
    );
  }

  @override
  Future<ProductHealth> health() async => _health;
}
