import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/services/sync/xray_config_writer.dart';
import 'package:xconnect/services/vpn_config_service.dart';

void main() {
  group('XrayConfigWriter.isReplaceableFallbackNode', () {
    test('does not prune region nodes created by sync', () {
      for (final name in ['jp', 'ph', 'sg', 'us']) {
        final node = VpnNode(
          name: name,
          countryCode: name.toUpperCase(),
          configPath: '/tmp/$name.json',
          serviceName: 'xconnect.desktop.sync',
        );
        expect(
          XrayConfigWriter.isReplaceableFallbackNode(node, 'US-Connect'),
          isFalse,
        );
      }
    });

    test('replaces only the generic fallback sync node', () {
      final fallback = VpnNode(
        name: 'Desktop Sync',
        countryCode: 'SYNC',
        configPath: '/tmp/fallback.json',
        serviceName: 'xconnect.desktop.sync',
      );
      expect(
        XrayConfigWriter.isReplaceableFallbackNode(fallback, 'US-Connect'),
        isTrue,
      );
      expect(
        XrayConfigWriter.isReplaceableFallbackNode(fallback, 'Desktop Sync'),
        isFalse,
      );
    });
  });

  group('XrayConfigWriter.extractOutboundIdentity', () {
    test('extracts stable identity from proxy outbound', () {
      const json = '''
{
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "57.183.19.25",
            "port": 443,
            "users": [
              { "id": "18d270a9-533d-4b13-b3f1-e7f55540a9b2" }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "jp-xhttp.svc.plus"
        }
      }
    }
  ]
}
''';

      final identity = XrayConfigWriter.extractOutboundIdentity(json);

      expect(
        identity,
        'vless|57.183.19.25|443|18d270a9-533d-4b13-b3f1-e7f55540a9b2|xhttp|tls|jp-xhttp.svc.plus',
      );
    });

    test('returns null when proxy outbound is missing', () {
      const json = '{"outbounds":[{"tag":"direct","protocol":"freedom"}]}';
      expect(XrayConfigWriter.extractOutboundIdentity(json), isNull);
    });
  });
}
