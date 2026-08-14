import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/dns/dns_control_plane.dart';
import '../widgets/log_console.dart';

// LogConsole Global Key
final GlobalKey<LogConsoleState> logConsoleKey = GlobalKey<LogConsoleState>();

String _displayBranchLabel(String branch) {
  if (branch == 'main') {
    return 'latest';
  }
  if (branch.startsWith('release/')) {
    final releaseVersion = branch.replaceFirst('release/', '');
    if (releaseVersion.isNotEmpty) {
      return releaseVersion.replaceAll('/', '-');
    }
    return 'release';
  }
  return branch.replaceAll('/', '-');
}

String _firstNonEmpty(List<String> values) {
  for (final value in values) {
    if (value.isNotEmpty) {
      return value;
    }
  }
  return '';
}

/// 当前展示版本标签。
final String buildVersion = (() {
  const defineBranchName = String.fromEnvironment(
    'BRANCH_NAME',
    defaultValue: '',
  );
  const defineBranch = String.fromEnvironment('BRANCH', defaultValue: '');
  const defineBuildId = String.fromEnvironment('BUILD_ID', defaultValue: '');
  const defineBuildDate = String.fromEnvironment(
    'BUILD_DATE',
    defaultValue: '',
  );

  // Prioritize environment defines (passed via --dart-define) for ALL platforms
  // This ensures mobile builds (iOS/Android) get the same labels as Desktop when built via Makefile.
  final branch = _firstNonEmpty([defineBranchName, defineBranch, 'main']);
  const buildId = defineBuildId;
  const buildDate = defineBuildDate;

  final parts = <String>[
    _displayBranchLabel(branch),
    if (buildDate.isNotEmpty) buildDate,
    if (buildId.isNotEmpty) buildId,
  ];
  return parts.join('-');
})();

/// 基础系统信息，用于匿名统计等场景
Map<String, String> collectSystemInfo() => {
      'os': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'dartVersion': Platform.version,
    };

/// 全局应用状态管理（使用 ValueNotifier 实现响应式绑定）
class GlobalState {
  static const String tunnelConnectionMode = 'VPN';
  static const String proxyOnlyConnectionMode = '仅代理';

  /// 是否在顶部栏显示解锁按钮（默认隐藏，在设置中心开启）
  static final ValueNotifier<bool> showUnlockButton = ValueNotifier<bool>(
    false,
  );

  /// 调试模式开关，由 `--debug` 参数控制
  static final ValueNotifier<bool> debugMode = ValueNotifier<bool>(false);

  /// 遥测开关：true 表示发送匿名统计信息
  static final ValueNotifier<bool> telemetryEnabled = ValueNotifier<bool>(
    false,
  );

  /// 全局代理开关
  static final ValueNotifier<bool> globalProxy = ValueNotifier<bool>(false);

  /// 隧道模式开关
  static final ValueNotifier<bool> tunnelProxyEnabled = ValueNotifier<bool>(
    false,
  );

  /// TUN 设置开关
  static final ValueNotifier<bool> tunSettingsEnabled = ValueNotifier<bool>(
    false,
  );

  /// Xray Core 下载状态
  static final ValueNotifier<bool> xrayUpdating = ValueNotifier<bool>(false);

  /// 系统权限向导是否已完成
  static final ValueNotifier<bool> permissionGuideDone = ValueNotifier<bool>(
    false,
  );

  /// 当前连接模式，可在底部弹出栏中切换（如 VPN / 仅代理）
  static final ValueNotifier<String> connectionMode = ValueNotifier<String>(
    Platform.isLinux ? proxyOnlyConnectionMode : tunnelConnectionMode,
  );

  /// 当前活跃节点名称（桌面菜单栏/主界面共享）
  static final ValueNotifier<String> activeNodeName = ValueNotifier<String>('');

  /// 最近导入/新增的节点名称（用于主界面高亮）
  static final ValueNotifier<String> lastImportedNodeName =
      ValueNotifier<String>('');

  /// 节点列表修订号（导入/删除后递增，用于触发主界面刷新）
  static final ValueNotifier<int> nodeListRevision = ValueNotifier<int>(0);

  /// 当前语言环境，默认中文
  static final ValueNotifier<Locale> locale = ValueNotifier<Locale>(
    const Locale('zh'),
  );

  /// SOCKS 代理模式开关（默认开启）
  static final ValueNotifier<bool> socksProxyEnabled = ValueNotifier<bool>(
    true,
  );

  /// HTTP 代理模式开关（默认开启）
  static final ValueNotifier<bool> httpProxyEnabled = ValueNotifier<bool>(true);

  /// HTTP/3 直连隧道开关（默认关闭）
  static final ValueNotifier<bool> http3Passthrough = ValueNotifier<bool>(
    false,
  );

  /// 嗅探开关（Sniffing）
  static final ValueNotifier<bool> sniffingEnabled = ValueNotifier<bool>(true);

  /// 回退到代理（Fallback to Proxy）
  static final ValueNotifier<bool> fallbackToProxy = ValueNotifier<bool>(false);

  /// 回退到域名（Fallback to Domain）
  static final ValueNotifier<bool> fallbackToDomain = ValueNotifier<bool>(
    false,
  );

  /// IPv6 to Domain
  static final ValueNotifier<bool> ipv6ToDomain = ValueNotifier<bool>(false);

  /// 系统代理 SOCKS 端口
  static final ValueNotifier<String> socksPort = ValueNotifier<String>('1080');

  /// 系统代理 HTTP 端口
  static final ValueNotifier<String> httpPort = ValueNotifier<String>('1081');

  static String normalizeConnectionMode(String? value) {
    if (Platform.isIOS) {
      return tunnelConnectionMode;
    }
    if (Platform.isLinux) {
      return value == tunnelConnectionMode
          ? tunnelConnectionMode
          : proxyOnlyConnectionMode;
    }
    return value == proxyOnlyConnectionMode
        ? proxyOnlyConnectionMode
        : tunnelConnectionMode;
  }

  static bool isTunnelModeValue(String? value) {
    return normalizeConnectionMode(value) == tunnelConnectionMode;
  }

  static bool get isTunnelMode {
    return isTunnelModeValue(connectionMode.value);
  }

  static void setConnectionMode(String? mode) {
    final normalized = normalizeConnectionMode(mode);
    final tunnelEnabled = normalized == tunnelConnectionMode;
    if (connectionMode.value != normalized) {
      connectionMode.value = normalized;
    }
    if (tunnelProxyEnabled.value != tunnelEnabled) {
      tunnelProxyEnabled.value = tunnelEnabled;
    }
  }

  static void setTunnelModeEnabled(bool enabled) {
    if (Platform.isIOS) {
      setConnectionMode(tunnelConnectionMode);
      return;
    }
    setConnectionMode(enabled ? tunnelConnectionMode : proxyOnlyConnectionMode);
  }
}

/// 管理 DNS 配置，支持保存到本地
enum DnsTransportMode {
  plain('plain'),
  doh('doh');

  const DnsTransportMode(this.storageValue);
  final String storageValue;

  static DnsTransportMode fromStorage(String? value) {
    return value == DnsTransportMode.plain.storageValue
        ? DnsTransportMode.plain
        : DnsTransportMode.doh;
  }
}

/// DNS preset for quick selection in settings UI
class DnsPreset {
  final String label;
  final String dohUrl;
  final String plainHost;

  const DnsPreset(this.label, this.dohUrl, this.plainHost);

  String get dohHost => Uri.parse(dohUrl).host.toLowerCase();
}

class DnsConfig {
  static const _legacyProxyDns1Key = 'dnsServer1';
  static const _legacyProxyDns2Key = 'dnsServer2';
  static const _directDns1Key = 'directDnsServer1';
  static const _directDns2Key = 'directDnsServer2';
  static const _transportModeKey = 'dnsTransportMode';
  static const _legacyDotEnabledKey = 'tunDnsOverTls';
  static const _tunnelDnsViaProxyKey = 'tunnelDnsViaProxy';
  static const _resolveProxyDomainDirectKey = 'resolveProxyDomainDirect';
  static const _http3PassthroughKey = 'http3Passthrough';
  static const _schemaVersionKey = 'dnsSchemaVersion';
  static const _currentSchemaVersion = 3;

  // Proxy resolvers are routed through the `proxy` outbound (see
  // RoutePolicy.buildSecureDnsRules), so they are queried from the exit node's
  // vantage point. They must be IP-literal — a domain address adds a bootstrap
  // dependency on the very tunnel being brought up — and must answer correctly
  // from anywhere. That leaves so little room for a meaningful user choice
  // that they are built in rather than configurable: every value a user could
  // pick here was either one of these two or a misconfiguration. CN-domestic
  // providers belong on the direct resolvers, which are configurable.
  static const _defaultDohDns1 = 'https://1.1.1.1/dns-query'; // Cloudflare
  static const _defaultDohDns2 = 'https://8.8.8.8/dns-query'; // Google
  static const _defaultPlainDns1 = '1.1.1.1';
  static const _defaultPlainDns2 = '8.8.8.8';

  static const _defaultDirectDns6Servers = <String>[
    '2606:4700:4700::1111',
    '2001:4860:4860::8888',
  ];
  static const _packetTunnelLocalDns4Servers = <String>['10.0.0.53'];
  static const _packetTunnelLocalDns6Servers = <String>['fd00::53'];
  static const _darwinTunnelLocalDnsEnabled = false;
  static const _defaultDirectDomains = <String>[
    'full:localhost',
    r'regexp:^.*\.local$',
    'dotless:',
    'domain:apple.com',
    'domain:icloud.com',
    'domain:apple-dns.net',
    'full:captive.apple.com',
    'full:connectivitycheck.gstatic.com',
    'full:msftconnecttest.com',
    'full:msftncsi.com',
  ];

  /// Quick-select options for the direct resolvers. CN-domestic providers are
  /// first because those are the ones worth switching to — the direct slot is
  /// queried from the user's own vantage point, where they answer best.
  static const List<DnsPreset> dnsPresets = <DnsPreset>[
    DnsPreset('DNSPod (CN)', 'https://doh.pub/dns-query', '1.12.12.12'),
    DnsPreset('AliDNS (CN)', 'https://dns.alidns.com/dns-query', '223.6.6.6'),
    DnsPreset('Cloudflare', 'https://1.1.1.1/dns-query', '1.1.1.1'),
    DnsPreset('Google', 'https://8.8.8.8/dns-query', '8.8.8.8'),
  ];

  static const _defaultDirectIpCidrs = <String>[
    '10.0.0.0/8',
    '100.64.0.0/10',
    '127.0.0.0/8',
    '169.254.0.0/16',
    '172.16.0.0/12',
    '192.168.0.0/16',
    '::1/128',
    'fc00::/7',
    'fe80::/10',
    'ff00::/8',
  ];
  static final ValueNotifier<String> directDns1 = ValueNotifier<String>(
    _defaultPlainDns1,
  );
  static final ValueNotifier<String> directDns2 = ValueNotifier<String>(
    _defaultPlainDns2,
  );
  static final ValueNotifier<DnsTransportMode> transportMode =
      ValueNotifier<DnsTransportMode>(DnsTransportMode.doh);

  /// Routes tunnel DNS queries through the proxy resolver. On by default:
  /// this keeps resolution working when a local DoH endpoint is blocked,
  /// which is the common case this app is built for.
  static final ValueNotifier<bool> tunnelDnsViaProxy =
      ValueNotifier<bool>(true);

  /// Resolves the outbound server's own domain through the direct resolvers
  /// instead of through the proxy.
  ///
  /// Complements pinning the server to a literal IP before the tunnel starts,
  /// which is the primary defence against the resolution deadlock. This helps
  /// when the engine still resolves the name itself. Off by default: it takes
  /// the server domain outside the proxy path, which is a visibility trade-off
  /// the user should opt into.
  static final ValueNotifier<bool> resolveProxyDomainDirect =
      ValueNotifier<bool>(false);

  /// Outbound server domains for the config currently being built, supplied by
  /// the tunnel start path. Only consulted when [resolveProxyDomainDirect] is
  /// on.
  static List<String> proxyServerDomains = const <String>[];

  static bool get dohEnabled => transportMode.value == DnsTransportMode.doh;

  static String _bootstrapProxyDefault(
    DnsTransportMode mode, {
    required bool primary,
  }) {
    if (mode == DnsTransportMode.doh) {
      return primary ? _defaultDohDns1 : _defaultDohDns2;
    }
    return primary ? _defaultPlainDns1 : _defaultPlainDns2;
  }

  static String _bootstrapDirectDefault({required bool primary}) {
    return primary ? _defaultPlainDns1 : _defaultPlainDns2;
  }

  static String get proxyPrimaryDefault =>
      _bootstrapProxyDefault(transportMode.value, primary: true);

  static String get proxySecondaryDefault =>
      _bootstrapProxyDefault(transportMode.value, primary: false);

  static String get directPrimaryDefault =>
      _normalizeDirectEndpoint(directDns1.value, primary: true);

  static String get directSecondaryDefault =>
      _normalizeDirectEndpoint(directDns2.value, primary: false);

  /// Host of an endpoint, whether it is written as a DoH URL or as a bare
  /// address. `Uri.host` alone is not enough: it returns empty for a bare
  /// hostname, which is the shape older builds persisted when DoH was
  /// switched off.
  static String _hostOf(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.hasScheme && uri.host.isNotEmpty) {
      return uri.host.toLowerCase();
    }
    return trimmed.toLowerCase();
  }

  static bool _isIpLiteral(String value) {
    final host = value.startsWith('[') && value.endsWith(']')
        ? value.substring(1, value.length - 1)
        : value;
    return host.isNotEmpty && InternetAddress.tryParse(host) != null;
  }

  /// Resolve [value] to an address that can actually be dialled without DNS.
  ///
  /// A direct resolver address is used before any name resolution exists, and
  /// is additionally handed to the OS as the tunnel's DNS server — both
  /// require an IP literal. A known provider's DoH host maps onto its own
  /// plain IP; anything else unresolvable falls back to the built-in default
  /// rather than being written out as an undialable name.
  static String _plainAddressFor(String value, String fallback) {
    final host = _hostOf(value);
    if (host.isEmpty) {
      return fallback;
    }
    if (_isIpLiteral(host)) {
      return host;
    }
    for (final preset in dnsPresets) {
      if (preset.dohHost == host) {
        return preset.plainHost;
      }
    }
    return fallback;
  }

  static DnsTransportMode _readTransportMode(SharedPreferences prefs) {
    final legacyDotEnabled = prefs.getBool(_legacyDotEnabledKey);
    return DnsTransportMode.fromStorage(
      prefs.getString(_transportModeKey) ??
          ((legacyDotEnabled ?? true)
              ? DnsTransportMode.doh.storageValue
              : DnsTransportMode.plain.storageValue),
    );
  }

  /// One-shot cleanup of proxy resolver state older builds persisted.
  ///
  /// Builds up to v1.1.0+5 let the proxy slot be edited, defaulted it to
  /// CN-domestic providers, and rewrote a stored DoH endpoint to its bare
  /// host whenever DoH was switched off. All three produced resolvers that
  /// are queried from the exit node's vantage point and, in the bare-host
  /// case, cannot be dialled at all. The slot is built-in now, so the values
  /// are simply dropped rather than repaired.
  static Future<void> _dropLegacyProxyResolvers(
    SharedPreferences prefs,
  ) async {
    if ((prefs.getInt(_schemaVersionKey) ?? 0) >= _currentSchemaVersion) {
      return;
    }
    await prefs.remove(_legacyProxyDns1Key);
    await prefs.remove(_legacyProxyDns2Key);
    await prefs.setInt(_schemaVersionKey, _currentSchemaVersion);
  }

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    await _dropLegacyProxyResolvers(prefs);
    transportMode.value = _readTransportMode(prefs);
    directDns1.value = _normalizeDirectEndpoint(
      prefs.getString(_directDns1Key),
      primary: true,
    );
    directDns2.value = _normalizeDirectEndpoint(
      prefs.getString(_directDns2Key),
      primary: false,
    );
    GlobalState.http3Passthrough.value =
        prefs.getBool(_http3PassthroughKey) ?? false;

    directDns1.addListener(
      () => prefs.setString(_directDns1Key, directDns1.value),
    );
    directDns2.addListener(
      () => prefs.setString(_directDns2Key, directDns2.value),
    );
    transportMode.addListener(() {
      prefs.setString(_transportModeKey, transportMode.value.storageValue);
    });
    GlobalState.http3Passthrough.addListener(() {
      prefs.setBool(
        _http3PassthroughKey,
        GlobalState.http3Passthrough.value,
      );
    });
    tunnelDnsViaProxy.value = prefs.getBool(_tunnelDnsViaProxyKey) ?? true;
    tunnelDnsViaProxy.addListener(() {
      prefs.setBool(_tunnelDnsViaProxyKey, tunnelDnsViaProxy.value);
    });
    resolveProxyDomainDirect.value =
        prefs.getBool(_resolveProxyDomainDirectKey) ?? false;
    resolveProxyDomainDirect.addListener(() {
      prefs.setBool(
        _resolveProxyDomainDirectKey,
        resolveProxyDomainDirect.value,
      );
    });
  }

  /// Transport for the proxy resolvers. The addresses themselves are built in,
  /// so this is the only thing the toggle changes.
  static void setDohEnabled(bool enabled) {
    transportMode.value =
        enabled ? DnsTransportMode.doh : DnsTransportMode.plain;
  }

  static void updateDirectServers({
    required String primary,
    required String secondary,
  }) {
    directDns1.value = _normalizeDirectEndpoint(primary, primary: true);
    directDns2.value = _normalizeDirectEndpoint(secondary, primary: false);
  }

  static List<String> proxyResolversForXray() =>
      <String>[proxyPrimaryDefault, proxySecondaryDefault];

  static List<String> directResolversForXray() {
    final servers = <String>[
      _normalizeDirectEndpoint(directDns1.value, primary: true),
      _normalizeDirectEndpoint(directDns2.value, primary: false),
    ].where((server) => server.isNotEmpty).toList();
    return servers.toSet().toList();
  }

  static List<String> effectiveTunnelDnsServers4() => directResolversForXray();

  static List<String> get effectiveTunnelDnsServers6 =>
      _defaultDirectDns6Servers;

  static List<String> systemTunnelDnsServers4() {
    if ((Platform.isMacOS || Platform.isIOS) && _darwinTunnelLocalDnsEnabled) {
      return darwinPacketTunnelDnsServers4;
    }
    return effectiveTunnelDnsServers4();
  }

  static List<String> systemTunnelDnsServers6() {
    if ((Platform.isMacOS || Platform.isIOS) && _darwinTunnelLocalDnsEnabled) {
      return darwinPacketTunnelDnsServers6;
    }
    return effectiveTunnelDnsServers6;
  }

  static bool get shouldCaptureSystemDnsToBuiltInDns =>
      Platform.isMacOS || Platform.isIOS ? _darwinTunnelLocalDnsEnabled : false;

  static String get darwinSystemDnsMode =>
      _darwinTunnelLocalDnsEnabled ? 'tunnel-local-endpoint' : 'resolver-ip';

  static List<String> get darwinPacketTunnelDnsServers4 =>
      List<String>.from(_packetTunnelLocalDns4Servers);

  static List<String> get darwinPacketTunnelDnsServers6 =>
      List<String>.from(_packetTunnelLocalDns6Servers);

  static List<String> get directDomainSet {
    final domains = List<String>.from(_defaultDirectDomains);
    if (!resolveProxyDomainDirect.value) {
      return domains;
    }
    for (final domain in proxyServerDomains) {
      final entry = 'full:$domain';
      if (!domains.contains(entry)) {
        domains.add(entry);
      }
    }
    return domains;
  }

  static List<String> get directIpCidrs =>
      List<String>.from(_defaultDirectIpCidrs);

  static DnsControlPlane controlPlane({
    required String dnsDirectPrimaryTag,
    required String dnsDirectSecondaryTag,
    required String dnsProxyPrimaryTag,
    required String dnsProxySecondaryTag,
  }) {
    final directResolvers = directResolversForXray();
    final effectiveDirectResolvers = directResolvers.isNotEmpty
        ? directResolvers
        : <String>[directPrimaryDefault, directSecondaryDefault];

    final directPolicies = <ResolverServerPolicy>[
      ResolverServerPolicy(
        address: effectiveDirectResolvers.first,
        tag: dnsDirectPrimaryTag,
        transport: ResolverTransport.plain,
        domains: directDomainSet,
        skipFallback: true,
      ),
      ResolverServerPolicy(
        address: effectiveDirectResolvers.length > 1
            ? effectiveDirectResolvers[1]
            : directSecondaryDefault,
        tag: dnsDirectSecondaryTag,
        transport: ResolverTransport.plain,
        domains: directDomainSet,
        skipFallback: true,
      ),
    ];

    final proxyTransport =
        dohEnabled ? ResolverTransport.doh : ResolverTransport.plain;
    final proxyPolicies = <ResolverServerPolicy>[
      ResolverServerPolicy(
        address: proxyPrimaryDefault,
        tag: dnsProxyPrimaryTag,
        transport: proxyTransport,
      ),
      ResolverServerPolicy(
        address: proxySecondaryDefault,
        tag: dnsProxySecondaryTag,
        transport: proxyTransport,
      ),
    ];

    return DnsControlPlane(
      dnsPolicy: DnsPolicy(
        directResolvers: directPolicies,
        proxyResolvers: proxyPolicies,
      ),
      routePolicy: RoutePolicy(
        domainSets: DomainSets(
          direct: directDomainSet,
          directIpCidrs: directIpCidrs,
        ),
        tunnelDnsServers4: systemTunnelDnsServers4(),
        tunnelDnsServers6: systemTunnelDnsServers6(),
        captureSystemDnsToBuiltInDns: shouldCaptureSystemDnsToBuiltInDns,
        forceTunnelDnsToProxy: tunnelDnsViaProxy.value,
      ),
    );
  }

  static String normalizeVisionFlow(String? rawFlow) {
    final trimmed = rawFlow?.trim() ?? '';
    if (trimmed.isEmpty) {
      return GlobalState.http3Passthrough.value
          ? 'xtls-rprx-vision-udp443'
          : 'xtls-rprx-vision';
    }

    final lowered = trimmed.toLowerCase();
    if (lowered == 'xtls-rprx-vision-udp443') {
      return GlobalState.http3Passthrough.value
          ? 'xtls-rprx-vision-udp443'
          : 'xtls-rprx-vision';
    }
    if (lowered == 'xtls-rprx-vision') {
      return GlobalState.http3Passthrough.value
          ? 'xtls-rprx-vision-udp443'
          : 'xtls-rprx-vision';
    }
    return trimmed;
  }

  static String _normalizeDirectEndpoint(
    String? endpoint, {
    required bool primary,
  }) {
    final fallback = _bootstrapDirectDefault(primary: primary);
    final trimmed = endpoint?.trim() ?? '';
    if (trimmed.isEmpty) {
      return fallback;
    }
    return _plainAddressFor(trimmed, fallback);
  }
}

class XhttpAdvancedConfig {
  static const _modeKey = 'xhttpMode';
  static const _alpnKey = 'xhttpAlpn';
  static const _xmuxMaxConcurrencyKey = 'xhttpXmuxMaxConcurrency';

  static const String modeStreamUp = 'stream-up';
  static const String modeAuto = 'auto';
  static const List<String> allowedModes = <String>[modeStreamUp, modeAuto];

  static const String alpnH3 = 'h3';
  static const String alpnH2 = 'h2';
  static const String alpnHttp11 = 'http/1.1';
  static const List<String> allowedAlpn = <String>[alpnH3, alpnH2, alpnHttp11];
  static const List<String> defaultAlpn = <String>[alpnH3, alpnH2, alpnHttp11];
  static const String defaultXmuxMaxConcurrency = '4-8';
  static const String defaultXmuxHMaxRequestTimes = '600-900';
  static const String defaultXmuxHMaxReusableSecs = '1800-3000';

  static final ValueNotifier<String> mode = ValueNotifier<String>(modeAuto);
  static final ValueNotifier<List<String>> alpn = ValueNotifier<List<String>>(
    List<String>.from(defaultAlpn),
  );
  static final ValueNotifier<String> xmuxMaxConcurrency =
      ValueNotifier<String>(defaultXmuxMaxConcurrency);

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    mode.value = _normalizeMode(prefs.getString(_modeKey));
    alpn.value = _normalizeAlpn(prefs.getStringList(_alpnKey));
    xmuxMaxConcurrency.value = _normalizeXmuxMaxConcurrency(
      prefs.getString(_xmuxMaxConcurrencyKey),
    );

    mode.addListener(() {
      prefs.setString(_modeKey, _normalizeMode(mode.value));
    });
    alpn.addListener(() {
      prefs.setStringList(_alpnKey, _normalizeAlpn(alpn.value));
    });
    xmuxMaxConcurrency.addListener(() {
      prefs.setString(
        _xmuxMaxConcurrencyKey,
        _normalizeXmuxMaxConcurrency(xmuxMaxConcurrency.value),
      );
    });
  }

  static void setMode(String value) {
    mode.value = _normalizeMode(value);
  }

  static void setAlpn(List<String> values) {
    alpn.value = _normalizeAlpn(values);
  }

  static void setXmuxMaxConcurrency(String value) {
    xmuxMaxConcurrency.value = _normalizeXmuxMaxConcurrency(value);
  }

  static void toggleAlpn(String value, bool enabled) {
    final current = List<String>.from(alpn.value);
    if (!allowedAlpn.contains(value)) return;
    if (enabled) {
      if (!current.contains(value)) {
        current.add(value);
      }
    } else {
      current.remove(value);
    }
    alpn.value = _normalizeAlpn(current);
  }

  static String _normalizeMode(String? raw) {
    final value = (raw ?? '').trim().toLowerCase();
    if (allowedModes.contains(value)) {
      return value;
    }
    return modeAuto;
  }

  static List<String> _normalizeAlpn(List<String>? raw) {
    final source = raw ?? defaultAlpn;
    final normalized = <String>{};
    for (final value in source) {
      final lowered = value.trim().toLowerCase();
      if (allowedAlpn.contains(lowered)) {
        normalized.add(lowered);
      }
    }
    if (normalized.isEmpty) {
      return <String>[];
    }
    final ordered = <String>[];
    for (final candidate in allowedAlpn) {
      if (normalized.contains(candidate)) {
        ordered.add(candidate);
      }
    }
    return ordered;
  }

  static String _normalizeXmuxMaxConcurrency(String? raw) {
    final value = (raw ?? '').trim();
    final match = RegExp(r'^(\d+)(?:-(\d+))?$').firstMatch(value);
    if (match == null) return defaultXmuxMaxConcurrency;

    final from = int.tryParse(match.group(1)!);
    final to = int.tryParse(match.group(2) ?? match.group(1)!);
    if (from == null || to == null || from < 1 || to < 1) {
      return defaultXmuxMaxConcurrency;
    }
    // Keep this app-level knob bounded so a typo cannot create unbounded
    // physical connections on a lossy network.
    if (from > 128 || to > 128) return defaultXmuxMaxConcurrency;
    final lower = from < to ? from : to;
    final upper = from < to ? to : from;
    return lower == upper ? '$lower' : '$lower-$upper';
  }
}

/// 用于获取应用相关的配置信息
class GlobalApplicationConfig {
  /// 沙盒化应用目录结构管理
  static Future<String> getSandboxBasePath() async {
    final baseDir = await getApplicationSupportDirectory();
    return baseDir.path;
  }

  /// 获取二进制文件目录路径
  static Future<String> getBinariesPath() async {
    final basePath = await getSandboxBasePath();
    final binDir = Directory('$basePath/bin');
    await binDir.create(recursive: true);
    return binDir.path;
  }

  /// 获取配置文件目录路径
  static Future<String> getConfigsPath() async {
    final basePath = await getSandboxBasePath();
    final configDir = Directory('$basePath/configs');
    await configDir.create(recursive: true);
    return configDir.path;
  }

  /// 获取服务文件目录路径
  static Future<String> getServicesPath() async {
    final basePath = await getSandboxBasePath();
    final servicesDir = Directory('$basePath/services');
    await servicesDir.create(recursive: true);
    return servicesDir.path;
  }

  /// 获取临时文件目录路径
  static Future<String> getTempPath() async {
    final basePath = await getSandboxBasePath();
    final tempDir = Directory('$basePath/temp');
    await tempDir.create(recursive: true);
    return tempDir.path;
  }

  /// 获取日志文件目录路径
  static Future<String> getLogsPath() async {
    final basePath = await getSandboxBasePath();
    final logsDir = Directory('$basePath/logs');
    await logsDir.create(recursive: true);
    return logsDir.path;
  }

  /// 获取设备指纹文件路径（用于桌面同步设备标识）
  static Future<String> getDeviceFingerprintFilePath() async {
    final basePath = await getSandboxBasePath();
    final deviceDir = Directory('$basePath/device');
    await deviceDir.create(recursive: true);
    return '${deviceDir.path}/fingerprint.bin';
  }

  /// 获取特定类型文件的完整路径
  static Future<String> getVpnNodesConfigPath() async {
    final basePath = await getSandboxBasePath();
    return '$basePath/vpn_nodes.json';
  }

  /// 获取Xray配置文件的完整路径
  static Future<String> getXrayConfigFilePath(String filename) async {
    final configsPath = await getConfigsPath();
    return '$configsPath/$filename';
  }

  /// 获取plist文件的完整路径
  static Future<String> getPlistFilePath(String plistName) async {
    final servicesPath = await getServicesPath();
    return '$servicesPath/$plistName';
  }

  /// 获取二进制文件的完整路径
  static Future<String> getBinaryFilePath(String binaryName) async {
    final binariesPath = await getBinariesPath();
    return '$binariesPath/$binaryName';
  }

  /// 获取日志文件的完整路径
  static Future<String> getLogFilePath(String logName) async {
    final logsPath = await getLogsPath();
    return '$logsPath/$logName';
  }

  /// Windows 平台默认安装目录
  static String get windowsBasePath {
    final program = Platform.environment['ProgramFiles'];
    if (program != null) {
      final path = '$program\\XConnect';
      try {
        Directory(path).createSync(recursive: true);
        return path;
      } catch (_) {
        // ignore and fall back
      }
    }
    final local = Platform.environment['LOCALAPPDATA'] ?? '.';
    final alt = '$local\\XConnect';
    Directory(alt).createSync(recursive: true);
    return alt;
  }

  /// Xray 可执行文件路径 - 使用沙盒安全路径
  static Future<String> getXrayExePath() async {
    switch (Platform.operatingSystem) {
      case 'macos':
        // Use sandboxed Application Support directory for App Store compliance
        final baseDir = await getApplicationSupportDirectory();
        final binDir = Directory('${baseDir.path}/bin');
        await binDir.create(recursive: true);
        return '${binDir.path}/xray';
      case 'windows':
        return '$windowsBasePath\\xray.exe';
      case 'linux':
        final home = Platform.environment['HOME'] ?? '~';
        return '$home/.local/bin/xray';
      default:
        final baseDir = await getApplicationSupportDirectory();
        final binDir = Directory('${baseDir.path}/bin');
        await binDir.create(recursive: true);
        return '${binDir.path}/xray';
    }
  }

  /// 从配置文件或默认值中获取 PRODUCT_BUNDLE_IDENTIFIER
  static Future<String> getBundleId() async {
    if (Platform.isMacOS) {
      try {
        // 读取 macOS 配置文件，获取 PRODUCT_BUNDLE_IDENTIFIER
        final config = await rootBundle.loadString(
          'macos/Runner/Configs/AppInfo.xcconfig',
        );
        final line = config
            .split('\n')
            .firstWhere((l) => l.startsWith('PRODUCT_BUNDLE_IDENTIFIER='));
        return line.split('=').last.trim();
      } catch (_) {
        // macOS 下若读取失败返回默认值
        return 'plus.svc.xconnect';
      }
    }

    // 其他平台直接返回默认值
    return 'plus.svc.xconnect';
  }

  /// 返回各平台下存放 Xray 配置文件的目录，末尾已包含分隔符
  static Future<String> getXrayConfigPath() async {
    switch (Platform.operatingSystem) {
      case 'macos':
        // Use sandboxed configs directory for App Store compliance
        final configsPath = await getConfigsPath();
        return '$configsPath/';
      case 'windows':
        final base =
            Platform.environment['ProgramFiles'] ?? 'C:\\Program Files';
        return '$base\\XConnect\\';
      case 'linux':
        return '/opt/etc/';
      default:
        final configsPath = await getConfigsPath();
        return '$configsPath/';
    }
  }

  /// 根据平台返回本地配置文件路径
  static Future<String> getLocalConfigPath() async {
    switch (Platform.operatingSystem) {
      case 'macos':
        // Use getVpnNodesConfigPath for consistent sandbox compliance
        return await getVpnNodesConfigPath();

      case 'windows':
        final xconnectDir = Directory(windowsBasePath);
        await xconnectDir.create(recursive: true);
        return '${xconnectDir.path}\\vpn_nodes.json';

      case 'linux':
        final home = Platform.environment['HOME'] ??
            (await getApplicationSupportDirectory()).path;
        final xconnectDir = Directory('$home/.config/xconnect');
        await xconnectDir.create(recursive: true);
        return '${xconnectDir.path}/vpn_nodes.json';

      default:
        return await getVpnNodesConfigPath();
    }
  }

  /// 根据 region 生成各平台的启动控制文件或任务名称
  static Future<String> serviceNameForRegion(String region) async {
    final code = region.toLowerCase();
    switch (Platform.operatingSystem) {
      case 'macos':
        final bundleId = await getBundleId();
        return '$bundleId.xray-node-$code.plist';
      case 'linux':
        return 'xray-node-$code.service';
      case 'windows':
        return 'ray-node-$code.schtasks';
      default:
        return 'xray-node-$code';
    }
  }

  /// 根据平台和服务名称返回服务配置文件路径
  static Future<String> getServicePath(String serviceName) async {
    switch (Platform.operatingSystem) {
      case 'macos':
        // Use sandboxed services directory for App Store compliance
        final servicesPath = await getServicesPath();
        return '$servicesPath/$serviceName';
      case 'linux':
        return '/etc/systemd/system/$serviceName';
      case 'windows':
        return '$windowsBasePath\\$serviceName';
      default:
        final servicesPath = await getServicesPath();
        return '$servicesPath/$serviceName';
    }
  }
}
