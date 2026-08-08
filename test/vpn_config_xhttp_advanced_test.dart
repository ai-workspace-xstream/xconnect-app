import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/services/vpn_config_service.dart';
import 'package:xconnect/utils/global_config.dart';

Map<String, dynamic> _proxyStreamSettingsFromConfig(String jsonText) {
  final obj = jsonDecode(jsonText) as Map<String, dynamic>;
  final outbounds = (obj['outbounds'] as List<dynamic>);
  final proxy = outbounds.cast<Map>().firstWhere(
        (item) => item['tag'] == 'proxy',
      );
  return Map<String, dynamic>.from(
    proxy['streamSettings'] as Map<dynamic, dynamic>,
  );
}

void main() {
  group('xhttp advanced config', () {
    test('defaults to auto and includes h3/h2/http1.1', () async {
      XhttpAdvancedConfig.setMode(XhttpAdvancedConfig.modeAuto);
      XhttpAdvancedConfig.setAlpn(<String>[
        XhttpAdvancedConfig.alpnH3,
        XhttpAdvancedConfig.alpnH2,
        XhttpAdvancedConfig.alpnHttp11,
      ]);
      XhttpAdvancedConfig.setXmuxMaxConcurrency('4-8');

      final jsonText = await VpnConfig.tryGenerateXrayJsonFromVlessUri(
        'vless://11111111-1111-1111-1111-111111111111@example.com:443'
        '?type=xhttp&security=tls&mode=stream-up&alpn=h2#example',
      );
      expect(jsonText, isNotNull);

      final streamSettings = _proxyStreamSettingsFromConfig(jsonText!);
      final xhttpSettings = Map<String, dynamic>.from(
        streamSettings['xhttpSettings'] as Map<dynamic, dynamic>,
      );
      final tlsSettings = Map<String, dynamic>.from(
        streamSettings['tlsSettings'] as Map<dynamic, dynamic>,
      );
      final alpn = List<String>.from(tlsSettings['alpn'] as List<dynamic>);

      expect(xhttpSettings['mode'], XhttpAdvancedConfig.modeAuto);
      expect(alpn, <String>['h3', 'h2', 'http/1.1']);
      expect(
        (xhttpSettings['extra'] as Map)['xmux']['maxConcurrency'],
        '4-8',
      );
      expect(
        (xhttpSettings['extra'] as Map)['xmux']['hMaxRequestTimes'],
        XhttpAdvancedConfig.defaultXmuxHMaxRequestTimes,
      );
      expect(
        (xhttpSettings['extra'] as Map)['xmux']['hMaxReusableSecs'],
        XhttpAdvancedConfig.defaultXmuxHMaxReusableSecs,
      );
    });

    test('allows stream-up and removing h3 from advanced config', () async {
      XhttpAdvancedConfig.setMode(XhttpAdvancedConfig.modeStreamUp);
      XhttpAdvancedConfig.setAlpn(<String>[
        XhttpAdvancedConfig.alpnH2,
        XhttpAdvancedConfig.alpnHttp11,
      ]);
      XhttpAdvancedConfig.setXmuxMaxConcurrency('6');

      final jsonText = await VpnConfig.tryGenerateXrayJsonFromVlessUri(
        'vless://22222222-2222-2222-2222-222222222222@example.com:443'
        '?type=xhttp&security=tls#example',
      );
      expect(jsonText, isNotNull);

      final streamSettings = _proxyStreamSettingsFromConfig(jsonText!);
      final xhttpSettings = Map<String, dynamic>.from(
        streamSettings['xhttpSettings'] as Map<dynamic, dynamic>,
      );
      final tlsSettings = Map<String, dynamic>.from(
        streamSettings['tlsSettings'] as Map<dynamic, dynamic>,
      );
      final alpn = List<String>.from(tlsSettings['alpn'] as List<dynamic>);

      expect(xhttpSettings['mode'], XhttpAdvancedConfig.modeStreamUp);
      expect(alpn, <String>['h2', 'http/1.1']);
      expect(
        (xhttpSettings['extra'] as Map)['xmux']['maxConcurrency'],
        '6',
      );
    });

    test('normalizes invalid or reversed xmux ranges', () {
      XhttpAdvancedConfig.setXmuxMaxConcurrency('8-4');
      expect(XhttpAdvancedConfig.xmuxMaxConcurrency.value, '4-8');

      XhttpAdvancedConfig.setXmuxMaxConcurrency('not-a-range');
      expect(
        XhttpAdvancedConfig.xmuxMaxConcurrency.value,
        XhttpAdvancedConfig.defaultXmuxMaxConcurrency,
      );
    });

    test('migrates a legacy xhttp node config before tunnel startup', () {
      XhttpAdvancedConfig.setMode(XhttpAdvancedConfig.modeAuto);
      XhttpAdvancedConfig.setAlpn(<String>[
        XhttpAdvancedConfig.alpnH3,
        XhttpAdvancedConfig.alpnH2,
        XhttpAdvancedConfig.alpnHttp11,
      ]);
      XhttpAdvancedConfig.setXmuxMaxConcurrency('4-8');
      final config = <String, dynamic>{
        'outbounds': <dynamic>[
          <String, dynamic>{
            'tag': 'proxy',
            'protocol': 'vless',
            'streamSettings': <String, dynamic>{
              'network': 'xhttp',
              'security': 'tls',
              'tlsSettings': <String, dynamic>{
                'serverName': 'example.com',
                'alpn': <String>['h2'],
              },
              'xhttpSettings': <String, dynamic>{
                'path': '/split',
                'host': 'example.com',
              },
            },
          },
        ],
      };

      final result = VpnConfig.applyXhttpAdvancedSettings(config);
      final streamSettings = _proxyStreamSettingsFromConfig(
        jsonEncode(config),
      );
      final xhttpSettings = Map<String, dynamic>.from(
        streamSettings['xhttpSettings'] as Map<dynamic, dynamic>,
      );

      expect(result.foundXhttp, isTrue);
      expect(result.changed, isTrue);
      expect(xhttpSettings['path'], '/split');
      expect(xhttpSettings['host'], 'example.com');
      expect(xhttpSettings['mode'], XhttpAdvancedConfig.modeAuto);
      expect(
        (xhttpSettings['extra'] as Map)['xmux']['maxConcurrency'],
        XhttpAdvancedConfig.defaultXmuxMaxConcurrency,
      );
      expect(
        (xhttpSettings['extra'] as Map)['xmux']['hMaxRequestTimes'],
        XhttpAdvancedConfig.defaultXmuxHMaxRequestTimes,
      );
      expect(
        (xhttpSettings['extra'] as Map)['xmux']['hMaxReusableSecs'],
        XhttpAdvancedConfig.defaultXmuxHMaxReusableSecs,
      );
      expect(
        (streamSettings['tlsSettings'] as Map)['alpn'],
        <String>['h3', 'h2', 'http/1.1'],
      );

      final secondResult = VpnConfig.applyXhttpAdvancedSettings(config);
      expect(secondResult.foundXhttp, isTrue);
      expect(secondResult.changed, isFalse);
    });

    test('rewrites a legacy xhttp node file', () async {
      XhttpAdvancedConfig.setXmuxMaxConcurrency('4-8');
      final tempDir = await Directory.systemTemp.createTemp(
        'xconnect-xhttp-migration-',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final configFile = File('${tempDir.path}/node-legacy-config.json');
      await configFile.writeAsString(
        jsonEncode(<String, dynamic>{
          'outbounds': <dynamic>[
            <String, dynamic>{
              'tag': 'proxy',
              'streamSettings': <String, dynamic>{
                'network': 'xhttp',
                'security': 'tls',
                'xhttpSettings': <String, dynamic>{'path': '/split'},
              },
            },
          ],
        }),
      );

      final result = await VpnConfig.applyXhttpAdvancedSettingsToFile(
        configFile.path,
      );
      final rewritten = jsonDecode(await configFile.readAsString())
          as Map<String, dynamic>;
      final streamSettings = _proxyStreamSettingsFromConfig(
        jsonEncode(rewritten),
      );

      expect(result.foundXhttp, isTrue);
      expect(result.changed, isTrue);
      expect(
        ((streamSettings['xhttpSettings'] as Map)['extra'] as Map)['xmux']
            ['maxConcurrency'],
        '4-8',
      );
      expect(
        ((streamSettings['xhttpSettings'] as Map)['extra']
            as Map)['xmux']['hMaxRequestTimes'],
        XhttpAdvancedConfig.defaultXmuxHMaxRequestTimes,
      );
      expect(
        ((streamSettings['xhttpSettings'] as Map)['extra']
            as Map)['xmux']['hMaxReusableSecs'],
        XhttpAdvancedConfig.defaultXmuxHMaxReusableSecs,
      );
    });

    test('preserves explicit xmux lifecycle limits during migration', () {
      XhttpAdvancedConfig.setXmuxMaxConcurrency('4-8');
      final config = <String, dynamic>{
        'outbounds': <dynamic>[
          <String, dynamic>{
            'tag': 'proxy',
            'streamSettings': <String, dynamic>{
              'network': 'xhttp',
              'xhttpSettings': <String, dynamic>{
                'extra': <String, dynamic>{
                  'xmux': <String, dynamic>{
                    'maxConcurrency': '16-32',
                    'hMaxRequestTimes': 1200,
                    'hMaxReusableSecs': '300-600',
                  },
                },
              },
            },
          },
        ],
      };

      final result = VpnConfig.applyXhttpAdvancedSettings(config);
      final streamSettings = _proxyStreamSettingsFromConfig(jsonEncode(config));
      final xmux =
          ((streamSettings['xhttpSettings'] as Map)['extra'] as Map)['xmux']
              as Map;

      expect(result.foundXhttp, isTrue);
      expect(result.changed, isTrue);
      expect(xmux['maxConcurrency'], '4-8');
      expect(xmux['hMaxRequestTimes'], 1200);
      expect(xmux['hMaxReusableSecs'], '300-600');
    });
  });
}
