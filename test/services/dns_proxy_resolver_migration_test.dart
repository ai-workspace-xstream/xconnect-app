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
      expect(prefs.getInt('dnsSchemaVersion'), 1);
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
        'dnsSchemaVersion': 1,
      });

      await DnsConfig.init();

      // The user re-selected DNSPod after migrating; that choice must survive.
      expect(DnsConfig.proxyDns1.value, _dnspodDoh);
    });

    test('fresh installs default to IP-literal DoH', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});

      await DnsConfig.init();

      expect(DnsConfig.proxyDns1.value, _cloudflareDoh);
      expect(DnsConfig.proxyDns2.value, _googleDoh);
    });
  });

  group('proxyResolversForXray', () {
    test('keeps both resolvers distinct when the secondary is unset', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'dnsServer1': _cloudflareDoh,
        'dnsServer2': '',
        'dnsSchemaVersion': 1,
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
