import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xconnect/utils/global_config.dart';

const _cloudflareDoh = 'https://1.1.1.1/dns-query';
const _googleDoh = 'https://8.8.8.8/dns-query';
const _dnspodDoh = 'https://doh.pub/dns-query';
const _alidnsDoh = 'https://dns.alidns.com/dns-query';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('proxy resolvers', () {
    test('are built in, not read from storage', () async {
      // Older builds let this slot be edited and could leave a CN-only or
      // bare-host value in it. Whatever is stored, it no longer has a say.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'dnsServer1': _dnspodDoh,
        'dnsServer2': 'dns.alidns.com',
      });

      await DnsConfig.init();

      expect(
        DnsConfig.proxyResolversForXray(),
        <String>[_cloudflareDoh, _googleDoh],
      );
    });

    test('drop the legacy stored values so nothing can resurrect them',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'dnsServer1': _dnspodDoh,
        'dnsServer2': _alidnsDoh,
        'dnsSchemaVersion': 2,
      });

      await DnsConfig.init();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('dnsServer1'), isNull);
      expect(prefs.getString('dnsServer2'), isNull);
      expect(prefs.getBool('resolveProxyDomainDirect'), isNull);
      expect(prefs.getInt('dnsSchemaVersion'), 4);
    });

    test(
        'desktop keeps its tunnel DNS choice while dropping server-domain mode',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'tunnelDnsViaProxy': false,
        'resolveProxyDomainDirect': true,
        'dnsSchemaVersion': 3,
      });

      await DnsConfig.init();

      final prefs = await SharedPreferences.getInstance();
      expect(DnsConfig.tunnelDnsViaProxy.value, isFalse);
      expect(prefs.getBool('tunnelDnsViaProxy'), isFalse);
      expect(prefs.getBool('resolveProxyDomainDirect'), isNull);

      final controlPlane = DnsConfig.controlPlane(
        dnsDirectPrimaryTag: 'dns-direct-primary',
        dnsDirectSecondaryTag: 'dns-direct-secondary',
        dnsProxyPrimaryTag: 'dns-proxy-primary',
        dnsProxySecondaryTag: 'dns-proxy-secondary',
      );
      final rules = controlPlane.routePolicy.buildSecureDnsRules(
        enableTunnelMode: true,
        blockQuic: false,
        tunInboundTag: 'tun-in',
        directResolverInboundTags: const <String>['dns-direct'],
        proxyResolverInboundTags: const <String>['dns-proxy'],
      );
      expect(
        rules.where((rule) => rule['port'] == '53'),
        isEmpty,
      );
    });

    test('follow the transport toggle and stay IP-literal', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'dnsTransportMode': 'plain',
        'dnsSchemaVersion': 3,
      });

      await DnsConfig.init();

      expect(DnsConfig.proxyResolversForXray(), <String>['1.1.1.1', '8.8.8.8']);

      DnsConfig.setDohEnabled(true);
      expect(
        DnsConfig.proxyResolversForXray(),
        <String>[_cloudflareDoh, _googleDoh],
      );

      DnsConfig.setDohEnabled(false);
      expect(DnsConfig.proxyResolversForXray(), <String>['1.1.1.1', '8.8.8.8']);
    });
  });

  group('direct resolvers', () {
    test('map a known provider DoH host onto its own plain IP', () async {
      // Turning DoH off in an older build left bare hostnames behind, which
      // cannot be dialled as a plain resolver and cannot be handed to the OS
      // as the tunnel's DNS server either.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'directDnsServer1': _alidnsDoh,
        'directDnsServer2': 'doh.pub',
        'dnsSchemaVersion': 3,
      });

      await DnsConfig.init();

      expect(DnsConfig.directDns1.value, '223.6.6.6');
      expect(DnsConfig.directDns2.value, '1.12.12.12');
    });

    test('fall back rather than keeping an undialable hostname', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'directDnsServer1': 'resolver.example.com',
        'dnsSchemaVersion': 3,
      });

      await DnsConfig.init();

      expect(DnsConfig.directDns1.value, '1.1.1.1');
    });

    test('keep an IP literal the presets do not know', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'directDnsServer1': 'https://9.9.9.9/dns-query',
        'directDnsServer2': '2606:4700:4700::1111',
        'dnsSchemaVersion': 3,
      });

      await DnsConfig.init();

      expect(DnsConfig.directDns1.value, '9.9.9.9');
      expect(DnsConfig.directDns2.value, '2606:4700:4700::1111');
    });

    test('drop the retired 360 provider', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'directDnsServer1': 'doh.360.cn',
        'dnsSchemaVersion': 3,
      });

      await DnsConfig.init();

      expect(DnsConfig.directDns1.value, '1.1.1.1');
    });

    test('keep both resolvers distinct when the secondary is unset', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'directDnsServer1': '223.6.6.6',
        'directDnsServer2': '',
        'dnsSchemaVersion': 3,
      });

      await DnsConfig.init();

      // Before the primary/secondary fix, the empty secondary fell back to the
      // primary default and was then collapsed by toSet(), leaving one server.
      expect(
        DnsConfig.directResolversForXray(),
        <String>['223.6.6.6', '8.8.8.8'],
      );
    });

    test('fresh installs default to IP literals', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});

      await DnsConfig.init();

      expect(
          DnsConfig.directResolversForXray(), <String>['1.1.1.1', '8.8.8.8']);
    });
  });

  group('dnsPresets', () {
    test('no longer offer the retired 360 provider', () {
      expect(
        DnsConfig.dnsPresets.map((preset) => preset.label),
        isNot(contains(contains('360'))),
      );
    });

    test('every preset offers a dialable plain address', () {
      for (final preset in DnsConfig.dnsPresets) {
        expect(
          Uri.tryParse(preset.plainHost)?.hasScheme,
          isFalse,
          reason: '${preset.label} must be a bare address',
        );
        expect(preset.dohHost, isNotEmpty);
      }
    });
  });
}
