import 'dart:collection';

import 'host_capability.dart';

abstract interface class HostServices {
  Set<HostCapability> get grantedCapabilities;

  T require<T extends Object>(HostCapability capability);
}

class HostCapabilityException implements Exception {
  const HostCapabilityException(this.capability, this.reason);

  final HostCapability capability;
  final String reason;

  @override
  String toString() =>
      'HostCapabilityException(${capability.id}, reason: $reason)';
}

class CapabilityHostServices implements HostServices {
  CapabilityHostServices(Map<HostCapability, Object> services)
      : _services = Map<HostCapability, Object>.unmodifiable(services);

  final Map<HostCapability, Object> _services;

  @override
  Set<HostCapability> get grantedCapabilities =>
      UnmodifiableSetView(_services.keys.toSet());

  @override
  T require<T extends Object>(HostCapability capability) {
    final service = _services[capability];
    if (service == null) {
      throw HostCapabilityException(capability, 'not granted by host');
    }
    if (service is! T) {
      throw HostCapabilityException(
        capability,
        'registered service does not implement the requested type $T',
      );
    }
    return service;
  }
}

class ScopedHostServices implements HostServices {
  ScopedHostServices(HostServices delegate, Set<HostCapability> allowed)
      : _delegate = delegate,
        _allowed = Set<HostCapability>.unmodifiable(allowed);

  final HostServices _delegate;
  final Set<HostCapability> _allowed;

  @override
  Set<HostCapability> get grantedCapabilities =>
      UnmodifiableSetView(_delegate.grantedCapabilities.intersection(_allowed));

  @override
  T require<T extends Object>(HostCapability capability) {
    if (!_allowed.contains(capability)) {
      throw HostCapabilityException(
        capability,
        'not declared in the plugin manifest',
      );
    }
    return _delegate.require<T>(capability);
  }
}
