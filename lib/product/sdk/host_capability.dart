enum HostCapability {
  accountSession('account.session'),
  secretStore('secret.store'),
  secretStoreProbe('secret-store.probe'),
  tunnelRuntime('tunnel.runtime'),
  controlledNetwork('network.controlled'),
  eventBus('event.bus'),
  logging('observability.logging'),
  metrics('observability.metrics'),
  diagnostics('diagnostics'),
  overlayEnrollment('overlay.enrollment'),
  inviteIngress('input.invite'),
  qrScanner('input.qr-scanner'),
  cliCommands('registration.cli-commands'),
  uiRoutes('registration.ui-routes'),
  tunnelProfiles('registration.tunnel-profiles');

  const HostCapability(this.id);

  final String id;

  static HostCapability fromId(String id) {
    return values.firstWhere(
      (capability) => capability.id == id,
      orElse: () => throw FormatException('Unknown host capability: $id'),
    );
  }
}
