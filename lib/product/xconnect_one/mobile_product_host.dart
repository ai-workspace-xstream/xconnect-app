import '../sdk/host_capability.dart';
import '../sdk/host_services.dart';
import '../sdk/product_manifest.dart';
import '../sdk/product_registry.dart';
import 'mobile_enrollment.dart';
import 'mobile_host_services.dart';
import 'xconnect_one_plugin.dart';

final class ProtectedTunnelHostBoundary
    implements XConnectOneProtectedTunnelHost {
  const ProtectedTunnelHostBoundary();

  @override
  String get boundaryCode => 'protected_tunnel_host_required';
}

final class ProductRegistrationBoundary {
  const ProductRegistrationBoundary();
}

final class XConnectOneProductHost {
  XConnectOneProductHost._({required this.plugin, required this.activation});

  final XConnectOnePlugin plugin;
  final ProductActivation activation;

  XConnectOneEnrollmentController get enrollmentController =>
      plugin.enrollmentController;

  static Future<XConnectOneProductHost> create({
    PlatformXConnectOneHostServices? platformServices,
    XConnectOneQrScanner qrScanner = const UnavailableXConnectOneQrScanner(),
  }) async {
    final platform = platformServices ?? PlatformXConnectOneHostServices();
    final plugin = XConnectOnePlugin();
    final registry = ProductRegistry(
      hostApiVersion: const ApiVersion(1, 0, 0),
      hostServices: CapabilityHostServices({
        HostCapability.secretStoreProbe: platform,
        HostCapability.tunnelRuntime: const ProtectedTunnelHostBoundary(),
        HostCapability.overlayEnrollment: platform,
        HostCapability.inviteIngress: platform,
        if (qrScanner is! UnavailableXConnectOneQrScanner)
          HostCapability.qrScanner: qrScanner,
        HostCapability.uiRoutes: const ProductRegistrationBoundary(),
        HostCapability.tunnelProfiles: const ProductRegistrationBoundary(),
      }),
    );
    final activation = await registry.activate(plugin);
    return XConnectOneProductHost._(plugin: plugin, activation: activation);
  }
}
