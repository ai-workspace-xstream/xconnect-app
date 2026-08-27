enum HostCapability {
  accountSession('account.session'),
  secretStore('secret.store'),
  tunnelRuntime('tunnel.runtime'),
  controlledNetwork('network.controlled'),
  eventBus('event.bus'),
  logging('observability.logging'),
  metrics('observability.metrics'),
  diagnostics('diagnostics'),
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
