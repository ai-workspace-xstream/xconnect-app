enum ResolverTransport {
  plain,
  doh,
}

class ResolverServerPolicy {
  final String address;
  final String tag;
  final ResolverTransport transport;
  final List<String> domains;
  final bool skipFallback;

  const ResolverServerPolicy({
    required this.address,
    required this.tag,
    required this.transport,
    this.domains = const <String>[],
    this.skipFallback = false,
  });

  Map<String, dynamic> toXrayDnsServer() {
    final server = <String, dynamic>{
      'address': address,
      'tag': tag,
      'queryStrategy': 'UseIPv4',
    };
    if (domains.isNotEmpty) {
      server['domains'] = domains;
    }
    if (skipFallback) {
      server['skipFallback'] = true;
    }
    return server;
  }
}

class DomainSets {
  final List<String> direct;
  final List<String> directIpCidrs;

  const DomainSets({
    required this.direct,
    required this.directIpCidrs,
  });
}

class DnsPolicy {
  final List<ResolverServerPolicy> directResolvers;
  final List<ResolverServerPolicy> proxyResolvers;

  const DnsPolicy({
    required this.directResolvers,
    required this.proxyResolvers,
  });

  List<Map<String, dynamic>> buildDnsServers() {
    final servers = <Map<String, dynamic>>[];
    servers
        .addAll(directResolvers.map((resolver) => resolver.toXrayDnsServer()));
    servers
        .addAll(proxyResolvers.map((resolver) => resolver.toXrayDnsServer()));
    return servers;
  }

  Map<String, dynamic> toXrayDnsConfig() {
    return <String, dynamic>{
      'servers': buildDnsServers(),
      'queryStrategy': 'UseIPv4',
      'disableFallbackIfMatch': true,
    };
  }
}

class RoutePolicy {
  final DomainSets domainSets;

  /// Desktop preference. iOS always supplies true because allowing DNS to
  /// bypass the proxy recreates the cellular bootstrap failure.
  final bool forceTunnelDnsToProxy;

  const RoutePolicy({
    required this.domainSets,
    required this.forceTunnelDnsToProxy,
  });

  List<Map<String, dynamic>> buildSecureDnsRules({
    required bool enableTunnelMode,
    required bool blockQuic,
    required String tunInboundTag,
    required List<String> directResolverInboundTags,
    required List<String> proxyResolverInboundTags,
  }) {
    return <Map<String, dynamic>>[
      if (enableTunnelMode && forceTunnelDnsToProxy)
        <String, dynamic>{
          'type': 'field',
          'inboundTag': <String>[tunInboundTag],
          'network': 'tcp,udp',
          'port': '53',
          'outboundTag': 'proxy',
        },
      if (enableTunnelMode && blockQuic) ...<Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'field',
          'inboundTag': <String>[tunInboundTag],
          'network': 'udp',
          'port': '443',
          'outboundTag': 'block',
        },
        <String, dynamic>{
          'type': 'field',
          'inboundTag': <String>[tunInboundTag],
          'protocol': <String>['quic'],
          'outboundTag': 'block',
        },
      ],
      if (domainSets.direct.isNotEmpty)
        <String, dynamic>{
          'type': 'field',
          'domain': domainSets.direct,
          'outboundTag': 'direct',
        },
      if (domainSets.directIpCidrs.isNotEmpty)
        <String, dynamic>{
          'type': 'field',
          'ip': domainSets.directIpCidrs,
          'outboundTag': 'direct',
        },
      <String, dynamic>{
        'type': 'field',
        'inboundTag': directResolverInboundTags,
        'outboundTag': 'direct',
      },
      <String, dynamic>{
        'type': 'field',
        'inboundTag': proxyResolverInboundTags,
        'outboundTag': 'proxy',
      },
    ];
  }
}

class DnsControlPlane {
  final DnsPolicy dnsPolicy;
  final RoutePolicy routePolicy;

  const DnsControlPlane({
    required this.dnsPolicy,
    required this.routePolicy,
  });
}
