import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xconnect/services/dns/dns_control_plane.dart';
import 'package:xconnect/services/tuning/client_tuning.dart';
import 'package:xconnect/services/vpn_config_service.dart';
import 'package:xconnect/utils/global_config.dart';

Map<String, dynamic> _xhttpProfile() => <String, dynamic>{
      'log': <String, dynamic>{'loglevel': 'info'},
      'outbounds': <dynamic>[
        <String, dynamic>{
          'tag': 'proxy',
          'protocol': 'vless',
          'streamSettings': <String, dynamic>{
            'network': 'xhttp',
            'security': 'tls',
            'xhttpSettings': <String, dynamic>{
              'path': '/split',
              'extra': <String, dynamic>{
                'xmux': <String, dynamic>{'maxConcurrency': '4-8'},
              },
            },
          },
        },
      ],
    };

Map<String, dynamic> _xhttpSettings(Map<String, dynamic> config) =>
    ((config['outbounds'] as List).first['streamSettings']
        as Map)['xhttpSettings'] as Map<String, dynamic>;

const _profileJson = <String, dynamic>{
  'version': 1,
  'revision': '2026-10-14.1',
  'defaults': <String, dynamic>{
    'xhttp': <String, dynamic>{
      'mode': 'stream-up',
      'xmuxMaxConcurrency': '8-2',
      'scMaxEachPostBytes': 500000,
    },
    'dns': <String, dynamic>{'dohTimeoutMs': 1200, 'parallelQuery': true},
  },
  'platforms': <String, dynamic>{
    'linux': <String, dynamic>{
      'xhttp': <String, dynamic>{'scMinPostsIntervalMs': 10},
    },
  },
  'nodes': <String, dynamic>{
    'jp-1': <String, dynamic>{
      'xhttp': <String, dynamic>{'scMaxEachPostBytes': '262144-524288'},
    },
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await XhttpAdvancedConfig.init();
    XhttpAdvancedConfig.modeCustomized = false;
    XhttpAdvancedConfig.xmuxMaxConcurrencyCustomized = false;
    ClientTuning.profileForTesting = null;
    GlobalState.debugMode.value = false;
  });

  test('values outside the allowlist or their ranges are dropped', () {
    final values = ClientTuningValues.fromJson(const <String, dynamic>{
      'xhttp': <String, dynamic>{
        'mode': 'stream-one',
        'xmuxMaxConcurrency': '0-4',
        'xmuxHMaxRequestTimes': '900-600',
        'scMaxEachPostBytes': 10 * 1024 * 1024,
        'address': 'attacker.example',
      },
      'dns': <String, dynamic>{'dohTimeoutMs': 100, 'parallelQuery': 'yes'},
      'outbounds': <dynamic>[],
    });
    expect(values.xhttpMode, isNull);
    expect(values.xmuxMaxConcurrency, isNull);
    expect(values.xmuxHMaxRequestTimes, '600-900');
    expect(values.scMaxEachPostBytes, isNull);
    expect(values.dohTimeoutMs, isNull);
    expect(values.dnsParallelQuery, isNull);
    expect(values.toJson(), <String, dynamic>{
      'xhttp': <String, dynamic>{'xmuxHMaxRequestTimes': '600-900'},
    });
  });

  test('defaults, platform and node layers resolve in order', () {
    final profile = ClientTuningProfile.fromJson(_profileJson)!;
    final linux = profile.resolve(platform: 'linux');
    expect(linux.xhttpMode, 'stream-up');
    expect(linux.xmuxMaxConcurrency, '2-8');
    expect(linux.scMaxEachPostBytes, '500000');
    expect(linux.scMinPostsIntervalMs, '10');

    final node = profile.resolve(platform: 'ios', nodeId: 'jp-1');
    expect(node.scMaxEachPostBytes, '262144-524288');
    expect(node.scMinPostsIntervalMs, isNull);

    expect(
        ClientTuningProfile.fromJson(<String, dynamic>{'version': 2}), isNull);
  });

  group('refresh', () {
    final endpoint =
        Uri.parse('https://accounts.example${ClientTuning.endpointPath}');

    test('stores a valid document and reloads it after restart', () async {
      final client = MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer t');
        return http.Response(jsonEncode(_profileJson), 200);
      });
      final revision = await ClientTuning.refresh(
          client, endpoint, <String, String>{'Authorization': 'Bearer t'});
      expect(revision, '2026-10-14.1');

      ClientTuning.profileForTesting = null;
      await ClientTuning.init();
      expect(ClientTuning.profile?.revision, '2026-10-14.1');
      expect(ClientTuning.effective().dohTimeoutMs, 1200);
    });

    test('404 returns to built-in defaults; other failures keep last good',
        () async {
      await ClientTuning.refresh(
          MockClient((_) async => http.Response(jsonEncode(_profileJson), 200)),
          endpoint, const <String, String>{});

      await expectLater(
          ClientTuning.refresh(
              MockClient((_) async => http.Response('oops', 503)),
              endpoint, const <String, String>{}),
          throwsA(isA<http.ClientException>()));
      await expectLater(
          ClientTuning.refresh(
              MockClient((_) async => http.Response('{"version":9}', 200)),
              endpoint, const <String, String>{}),
          throwsFormatException);
      expect(ClientTuning.profile?.revision, '2026-10-14.1');

      final revision = await ClientTuning.refresh(
          MockClient((_) async => http.Response('', 404)),
          endpoint, const <String, String>{});
      expect(revision, isNull);
      expect(ClientTuning.profile, isNull);
      await ClientTuning.init();
      expect(ClientTuning.profile, isNull);
    });
  });

  test('tuning fills XHTTP knobs inside extra for the matching node', () {
    ClientTuning.profileForTesting = ClientTuningProfile.fromJson(_profileJson);
    final config = _xhttpProfile();
    VpnConfig.applyXhttpAdvancedSettings(config, nodeId: 'jp-1');
    final settings = _xhttpSettings(config);
    final extra = settings['extra'] as Map;
    expect(settings['mode'], 'stream-up');
    expect((extra['xmux'] as Map)['maxConcurrency'], '2-8');
    expect(extra['scMaxEachPostBytes'], '262144-524288');
    expect(settings.containsKey('scMaxEachPostBytes'), isFalse);
    if (Platform.operatingSystem == 'linux') {
      expect(extra['scMinPostsIntervalMs'], '10');
    }
  });

  test('a value the user changed in settings wins over tuning', () {
    ClientTuning.profileForTesting = ClientTuningProfile.fromJson(_profileJson);
    XhttpAdvancedConfig.setMode(XhttpAdvancedConfig.modeStreamUp);
    XhttpAdvancedConfig.setMode(XhttpAdvancedConfig.modeAuto);
    expect(XhttpAdvancedConfig.modeCustomized, isTrue);
    expect(XhttpAdvancedConfig.xmuxMaxConcurrencyCustomized, isFalse);

    final config = _xhttpProfile();
    VpnConfig.applyXhttpAdvancedSettings(config);
    final settings = _xhttpSettings(config);
    expect(settings['mode'], XhttpAdvancedConfig.modeAuto);
    expect(
        ((settings['extra'] as Map)['xmux'] as Map)['maxConcurrency'], '2-8');
  });

  test('without tuning the XHTTP profile keeps current behaviour', () {
    final config = _xhttpProfile();
    VpnConfig.applyXhttpAdvancedSettings(config);
    final settings = _xhttpSettings(config);
    final extra = settings['extra'] as Map;
    expect(settings['mode'], XhttpAdvancedConfig.mode.value);
    expect((extra['xmux'] as Map)['maxConcurrency'],
        XhttpAdvancedConfig.xmuxMaxConcurrency.value);
    expect(extra.containsKey('scMaxEachPostBytes'), isFalse);
  });

  test('DNS tuning replaces only the DoH timeout and enables parallel queries',
      () {
    final untuned = VpnConfig.buildSecureDnsConfig();
    expect(untuned.containsKey('enableParallelQuery'), isFalse);

    ClientTuning.profileForTesting = ClientTuningProfile.fromJson(_profileJson);
    final tuned = VpnConfig.buildSecureDnsConfig();
    expect(tuned['enableParallelQuery'], isTrue);
    final before = untuned['servers'] as List;
    final after = tuned['servers'] as List;
    expect(after.map((s) => s['address']), before.map((s) => s['address']));
    for (var i = 0; i < after.length; i++) {
      final hadTimeout = (before[i] as Map).containsKey('timeoutMs');
      expect((after[i] as Map)['timeoutMs'], hadTimeout ? 1200 : isNull);
    }
    expect(
        before
            .where((s) => s['timeoutMs'] == ResolverServerPolicy.dohTimeoutMs),
        isNotEmpty);
  });

  test('production connects lower verbose Xray logging', () {
    final verbose = <String, dynamic>{
      'log': <String, dynamic>{'loglevel': 'info', 'access': 'none'},
    };
    VpnConfig.applyRuntimeLogLevel(verbose);
    expect(verbose['log'], <String, dynamic>{
      'loglevel': 'warning',
      'access': 'none',
    });

    final quiet = <String, dynamic>{
      'log': <String, dynamic>{'loglevel': 'error'},
    };
    VpnConfig.applyRuntimeLogLevel(quiet);
    expect((quiet['log'] as Map)['loglevel'], 'error');

    GlobalState.debugMode.value = true;
    final debug = <String, dynamic>{
      'log': <String, dynamic>{'loglevel': 'debug'},
    };
    VpnConfig.applyRuntimeLogLevel(debug);
    expect((debug['log'] as Map)['loglevel'], 'debug');
  });

  test('node tuning follows the node, not where its profile is stored',
      () async {
    ClientTuning.profileForTesting = ClientTuningProfile.fromJson(_profileJson);
    final dir = await Directory.systemTemp.createTemp('xconnect-node');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/any-name.json')
      ..writeAsStringSync(jsonEncode(_xhttpProfile()));
    final node = VpnNode(
      name: 'JP tuning test',
      countryCode: 'JP',
      configPath: file.path,
      serviceName: 'xconnect.sync.jp-tuning',
      managedNodeId: 'jp-1',
    );
    VpnConfig.addNode(node);
    addTearDown(() => VpnConfig.removeNode(node.name));

    await VpnConfig.applyXhttpAdvancedSettingsToNode(node.name);
    final saved = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    expect((_xhttpSettings(saved)['extra'] as Map)['scMaxEachPostBytes'],
        '262144-524288');
  });

  group('withdrawing tuning', () {
    final endpoint =
        Uri.parse('https://accounts.example${ClientTuning.endpointPath}');
    Future<void> serve(int status, [Object? body]) => ClientTuning.refresh(
          MockClient((_) async =>
              http.Response(body == null ? '' : jsonEncode(body), status)),
          endpoint,
          const <String, String>{},
        );
    const tunedDocument = <String, dynamic>{
      'version': 1,
      'revision': 'r1',
      'defaults': <String, dynamic>{
        'xhttp': <String, dynamic>{
          'mode': 'stream-up',
          'xmuxMaxConcurrency': '2-8',
          'xmuxHMaxRequestTimes': '50-60',
          'xmuxHMaxReusableSecs': '120',
          'scMaxEachPostBytes': 500000,
          'scMinPostsIntervalMs': 10,
        },
      },
    };

    late File profileFile;
    setUp(() async {
      final dir = await Directory.systemTemp.createTemp('xconnect-tuning');
      addTearDown(() => dir.delete(recursive: true));
      // An imported profile carrying its own legitimate XHTTP limits.
      final imported = _xhttpProfile();
      final extra = _xhttpSettings(imported)['extra'] as Map;
      extra['scMaxEachPostBytes'] = 300000;
      (extra['xmux'] as Map)['hMaxRequestTimes'] = '100-200';
      profileFile = File('${dir.path}/node-imported.json')
        ..writeAsStringSync(jsonEncode(imported));
    });

    Map<String, dynamic> saved() =>
        jsonDecode(profileFile.readAsStringSync()) as Map<String, dynamic>;

    test('a 404 restores the original profile and keeps user settings',
        () async {
      XhttpAdvancedConfig.setXmuxMaxConcurrency('3');
      await serve(200, tunedDocument);
      await VpnConfig.applyXhttpAdvancedSettingsToFile(profileFile.path);
      var settings = _xhttpSettings(saved());
      var extra = settings['extra'] as Map;
      expect(settings['mode'], 'stream-up');
      expect(extra['scMaxEachPostBytes'], '500000');
      expect(extra['scMinPostsIntervalMs'], '10');
      expect((extra['xmux'] as Map)['hMaxRequestTimes'], '50-60');
      expect((extra['xmux'] as Map)['maxConcurrency'], '3');
      expect(saved(), contains(VpnConfig.tuningOverridesKey));

      await serve(404);
      final result =
          await VpnConfig.applyXhttpAdvancedSettingsToFile(profileFile.path);
      expect(result.changed, isTrue);
      settings = _xhttpSettings(saved());
      extra = settings['extra'] as Map;
      final xmux = extra['xmux'] as Map;
      expect(settings['mode'], XhttpAdvancedConfig.modeAuto);
      expect(extra['scMaxEachPostBytes'], 300000);
      expect(extra.containsKey('scMinPostsIntervalMs'), isFalse);
      expect(xmux['hMaxRequestTimes'], '100-200');
      expect(xmux['hMaxReusableSecs'],
          XhttpAdvancedConfig.defaultXmuxHMaxReusableSecs);
      expect(xmux['maxConcurrency'], '3');
      expect(saved().containsKey(VpnConfig.tuningOverridesKey), isFalse);

      // Preparing the same profile again is a no-op.
      final again =
          await VpnConfig.applyXhttpAdvancedSettingsToFile(profileFile.path);
      expect(again.changed, isFalse);
    });

    test('a 200 document that omits a field restores that field only',
        () async {
      await serve(200, tunedDocument);
      await VpnConfig.applyXhttpAdvancedSettingsToFile(profileFile.path);
      await serve(200, <String, dynamic>{
        'version': 1,
        'revision': 'r2',
        'defaults': <String, dynamic>{
          'xhttp': <String, dynamic>{'scMinPostsIntervalMs': 20},
        },
      });
      await VpnConfig.applyXhttpAdvancedSettingsToFile(profileFile.path);
      final extra = _xhttpSettings(saved())['extra'] as Map;
      expect(extra['scMaxEachPostBytes'], 300000);
      expect(extra['scMinPostsIntervalMs'], '20');
      expect((extra['xmux'] as Map)['hMaxRequestTimes'], '100-200');
      final overrides =
          (saved()[VpnConfig.tuningOverridesKey] as Map)['xhttp'] as Map;
      expect(overrides.keys, <String>['scMinPostsIntervalMs']);
    });

    test('a value edited after tuning was applied survives its withdrawal',
        () async {
      await serve(200, tunedDocument);
      await VpnConfig.applyXhttpAdvancedSettingsToFile(profileFile.path);
      final edited = saved();
      (_xhttpSettings(edited)['extra'] as Map)['scMaxEachPostBytes'] = 123456;
      profileFile.writeAsStringSync(jsonEncode(edited));

      await serve(404);
      await VpnConfig.applyXhttpAdvancedSettingsToFile(profileFile.path);
      final extra = _xhttpSettings(saved())['extra'] as Map;
      expect(extra['scMaxEachPostBytes'], 123456);
      expect((extra['xmux'] as Map)['hMaxRequestTimes'], '100-200');
    });
  });

  group('explicit user choices', () {
    const nonDefaults = <String, dynamic>{
      'version': 1,
      'revision': 'r1',
      'defaults': <String, dynamic>{
        'xhttp': <String, dynamic>{
          'mode': 'stream-up',
          'xmuxMaxConcurrency': '1-2',
        },
      },
    };

    test('saving the default value keeps precedence after a restart', () async {
      ClientTuning.profileForTesting =
          ClientTuningProfile.fromJson(nonDefaults);
      expect(VpnConfig.effectiveXhttpMode(), 'stream-up');
      expect(VpnConfig.effectiveXmuxMaxConcurrency(), '1-2');

      // Both equal the local values, so no listener fires.
      XhttpAdvancedConfig.setMode(XhttpAdvancedConfig.modeAuto);
      XhttpAdvancedConfig.setXmuxMaxConcurrency(
          XhttpAdvancedConfig.defaultXmuxMaxConcurrency);

      // Restart: flags come back only from what was persisted.
      XhttpAdvancedConfig.modeCustomized = false;
      XhttpAdvancedConfig.xmuxMaxConcurrencyCustomized = false;
      await XhttpAdvancedConfig.init();
      expect(XhttpAdvancedConfig.modeCustomized, isTrue);
      expect(XhttpAdvancedConfig.xmuxMaxConcurrencyCustomized, isTrue);

      final config = _xhttpProfile();
      VpnConfig.applyXhttpAdvancedSettings(config);
      final settings = _xhttpSettings(config);
      expect(settings['mode'], XhttpAdvancedConfig.modeAuto);
      expect(((settings['extra'] as Map)['xmux'] as Map)['maxConcurrency'],
          XhttpAdvancedConfig.defaultXmuxMaxConcurrency);
    });

    test('saving only ALPN leaves mode and concurrency to tuning', () async {
      ClientTuning.profileForTesting =
          ClientTuningProfile.fromJson(nonDefaults);
      XhttpAdvancedConfig.setAlpn(<String>[XhttpAdvancedConfig.alpnH2]);
      await XhttpAdvancedConfig.init();
      expect(XhttpAdvancedConfig.modeCustomized, isFalse);
      expect(XhttpAdvancedConfig.xmuxMaxConcurrencyCustomized, isFalse);
      expect(VpnConfig.effectiveXhttpMode(), 'stream-up');
      expect(VpnConfig.effectiveXmuxMaxConcurrency(), '1-2');
    });
  });

  test('a response for a cleared or ended session is never stored', () async {
    final endpoint =
        Uri.parse('https://accounts.example${ClientTuning.endpointPath}');
    final pending = Completer<http.Response>();
    final requested = Completer<void>();
    final refresh = ClientTuning.refresh(
      MockClient((_) {
        requested.complete();
        return pending.future;
      }),
      endpoint,
      const <String, String>{},
    );
    await requested.future;
    await ClientTuning.clear();
    pending.complete(http.Response(jsonEncode(_profileJson), 200));
    await expectLater(refresh, throwsA(isA<ClientTuningStaleException>()));
    expect(ClientTuning.profile, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('clientTuning.v1'), isNull);

    var current = true;
    final ended = ClientTuning.refresh(
      MockClient((_) async {
        current = false; // The session ends while the request is in flight.
        return http.Response(jsonEncode(_profileJson), 200);
      }),
      endpoint,
      const <String, String>{},
      isCurrent: () => current,
    );
    await expectLater(ended, throwsA(isA<ClientTuningStaleException>()));
    expect(ClientTuning.profile, isNull);
    expect(prefs.getString('clientTuning.v1'), isNull);
  });
}
