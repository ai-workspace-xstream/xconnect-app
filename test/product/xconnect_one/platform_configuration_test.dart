import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Apple and Android register strict xconnect join lifecycle ingress',
    () async {
      final androidManifest = await File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsString();
      final androidActivity = await File(
        'android/app/src/main/kotlin/plus/svc/xconnect/MainActivity.kt',
      ).readAsString();
      final iosInfo = await File('ios/Runner/Info.plist').readAsString();
      final iosDelegate = await File(
        'ios/Runner/AppDelegate.swift',
      ).readAsString();
      final iosScene = await File(
        'ios/Runner/SceneDelegate.swift',
      ).readAsString();
      final macInfo = await File('macos/Runner/Info.plist').readAsString();
      final macDelegate = await File(
        'macos/Runner/AppDelegate.swift',
      ).readAsString();

      expect(androidManifest, contains('android.intent.action.VIEW'));
      expect(androidManifest, contains('android:scheme="xconnect"'));
      expect(androidManifest, contains('android:host="join"'));
      expect(androidActivity, contains('override fun onNewIntent'));
      expect(androidActivity, contains('validateInvite'));
      expect(androidActivity, contains('AndroidKeyStore'));
      expect(androidActivity, isNot(contains('"parser"')));

      for (final info in [iosInfo, macInfo]) {
        expect(info, contains('<key>CFBundleURLSchemes</key>'));
        expect(info, contains('<string>xconnect</string>'));
      }
      expect(iosDelegate, contains('validateInvite'));
      expect(iosDelegate, contains('probeKeychain'));
      expect(iosDelegate, isNot(contains('"parser"')));
      expect(iosScene, contains('openURLContexts'));
      expect(macDelegate, contains('open urls: [URL]'));
      expect(macDelegate, contains('probeKeychain'));
      expect(macDelegate, isNot(contains('"parser"')));
    },
  );

  test(
      'Flutter product boundary contains no control-plane implementation or '
      'plaintext preference storage', () async {
    final files = Directory(
      'lib/product/xconnect_one',
    ).listSync().whereType<File>().where((file) => file.path.endsWith('.dart'));
    final combined = (await Future.wait(
      files.map((file) => file.readAsString()),
    ))
        .join('\n');

    expect(combined, isNot(contains('/api/overlay/v1')));
    expect(combined, isNot(contains('SharedPreferences')));
    expect(combined, isNot(contains('enrollment_token')));
    expect(combined, isNot(contains('wireguard_private_key')));
  });
}
