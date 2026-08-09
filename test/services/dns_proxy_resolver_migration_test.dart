import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xconnect/utils/global_config.dart';

const _cloudflareDoh = 'https://1.1.1.1/dns-query';
const _googleDoh = 'https://8.8.8.8/dns-query';
const _dnspodDoh = 'https://doh.pub/dns-query';
const _alidnsDoh = 'https://dns.alidns.com/dns-query';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('proxy resolver schema migration', () {
    test('rewrites CN-only DoH endpoints persisted by older builds', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'dnsServer1': _dnspodDoh,
        'dnsServer2': _alidnsDoh,
      });

      await DnsConfig.init();

      expect(DnsConfig.proxyDns1.value, _cloudflareDoh);
      expect(DnsConfig.proxyDns2.value, _googleDoh);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('dnsServer1'), _cloudflareDoh);
      expect(prefs.getString('dnsServer2'), _googleDoh);
      expect(prefs.getInt('dnsSchemaVersion'), 2);
    });

    test('leaves a deliberate non-CN choice untouched', () async {
      const quad9 = 'https://9.9.9.9/dns-query';
      SharedPreferences.setMockInitialValues(<String, Object>{
        'dnsServer1': quad9,
        'dnsServer2': _googleDoh,
      });

      await DnsConfig.init();

      expect(DnsConfig.proxyDns1.value, quad9);
      expect(DnsConfig.proxyDns2.value, _googleDoh);
    });

    test('does not run twice once the schema version is recorded', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'dnsServer1': _dnspodDoh,
        'dnsSchemaVersion': 2,
      });

      await DnsConfig.init();

      // The user re-selected DNSPod after migrating; that choice must survive.
      expect(DnsConfig.proxyDns1.value, _dnspodDoh);
    });

    test('v2 repairs bare CN hosts that v1 matching missed', () async {
      // Toggling DoH off rewrites the stored endpoint to its bare host, which
      // v1 read as a non-CN value — and which is not dialable as a plain
      // resolver either. v2 must re-run and repair it.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'dnsServer1': 'dns.alidns.com',
        'dnsServer2': '1.12.12.12',
        'dnsTransportMode': 'plain',
        'dnsSchemaVersion': 1,
      });

      await DnsConfig.init();

      expect(DnsConfig.proxyDns1.value, '1.1.1.1');
      expect(DnsConfig.proxyDns2.value, '8.8.8.8');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('dnsServer1'), '1.1.1.1');
      expect(prefs.getString('dnsServer2'), '8.8.8.8');
      expect(prefs.getInt('dnsSchemaVersion'), 2);
    });

    test('rewrites the retired 360 provider', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'dnsServer1': 'https://doh.360.cn/dns-query',
        'dnsSchemaVersion': 1,
      });

      await DnsConfig.init();

      expect(DnsConfig.proxyDns1.value, _cloudflareDoh);
    });

    test('migrates to the mode-appropriate default in plain mode', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'dnsServer1': _dnspodDoh,
        'dnsTransportMode': 'plain',
      });

      await DnsConfig.init();

      expect(DnsConfig.proxyDns1.value, '1.1.1.1');
    });

    test('fresh installs default to IP-literal DoH', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});

      await DnsConfig.init();

      expect(DnsConfig.proxyDns1.value, _cloudflareDoh);
      expect(DnsConfig.proxyDns2.value, _googleDoh);
    });
  });

  group('plain resolver addresses', () {
    test('maps a known provider DoH host onto its own plain IP', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'directDnsServer1': _alidnsDoh,
        'directDnsServer2': 'doh.pub',
        'dnsSchemaVersion': 2,
      });

      await DnsConfig.init();

      expect(DnsConfig.directDns1.value, '223.6.6.6');
      expect(DnsConfig.directDns2.value, '1.12.12.12');
    });

    test('falls back rather than keeping an undialable hostname', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'directDnsServer1': 'resolver.example.com',
        'dnsSchemaVersion': 2,
      });

      await DnsConfig.init();

      expect(DnsConfig.directDns1.value, '1.1.1.1');
    });

    test('keeps an IP-literal endpoint the presets do not know', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'dnsServer1': 'https://9.9.9.9/dns-query',
        'dnsTransportMode': 'plain',
        'dnsSchemaVersion': 2,
      });

      await DnsConfig.init();

      expect(DnsConfig.proxyDns1.value, '9.9.9.9');
    });

    test('keeps an IPv6 literal intact', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'directDnsServer1': '2606:4700:4700::1111',
        'dnsSchemaVersion': 2,
      });

      await DnsConfig.init();

      expect(DnsConfig.directDns1.value, '2606:4700:4700::1111');
    });
  });

  group('dnsPresets', () {
    test('no longer offers the retired 360 provider', () {
      expect(
        DnsConfig.dnsPresets.map((preset) => preset.label),
        isNot(contains(contains('360'))),
      );
    });

    test('flags every CN-domestic preset on both transports', () {
      for (final preset in DnsConfig.dnsPresets.where((p) => p.cnOnly)) {
        expect(DnsConfig.isCnOnlyResolver(preset.dohUrl), isTrue);
        expect(DnsConfig.isCnOnlyResolver(preset.plainHost), isTrue);
      }
      expect(DnsConfig.isCnOnlyResolver(_cloudflareDoh), isFalse);
      expect(DnsConfig.isCnOnlyResolver('1.1.1.1'), isFalse);
    });
  });

  group('proxyResolversForXray', () {
    test('keeps both resolvers distinct when the secondary is unset', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'dnsServer1': _cloudflareDoh,
        'dnsServer2': '',
        'dnsSchemaVersion': 2,
      });

      await DnsConfig.init();

      // Before the primary/secondary fix, the empty secondary fell back to the
      // primary default and was then collapsed by toSet(), leaving one server.
      expect(
        DnsConfig.proxyResolversForXray(),
        <String>[_cloudflareDoh, _googleDoh],
      );
    });
  });
}
