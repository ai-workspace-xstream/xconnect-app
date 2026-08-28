import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/product/xconnect_one/mobile_enrollment.dart';
import 'package:xconnect/product/xconnect_one/mobile_host_services.dart';

import 'mobile_enrollment_fakes.dart';

void main() {
  test(
    'accepts a strict native deep link event and rejects extra fields',
    () async {
      final channel = FakePlatformChannel()
        ..responses['initialInvite'] = {
          'status': 'accepted',
          'payload': validInvite(),
        };
      final host = PlatformXConnectOneHostServices(
        channel: channel,
        targetPlatform: TargetPlatform.iOS,
      );
      final events = <XConnectOneInviteIngressEvent>[];
      final subscription = host.events.listen(events.add);

      await host.start();
      await Future<void>.delayed(Duration.zero);
      expect(events.single, isA<XConnectOneInviteAccepted>());

      await channel.emit('inviteReceived', {
        'status': 'accepted',
        'payload': validInvite(),
        'unexpected': 'field',
      });
      expect(events.last, isA<XConnectOneInviteRejected>());
      await subscription.cancel();
      await host.dispose();
    },
  );

  test('maps PlatformException details to a stable redacted code', () async {
    final secret = validInvite();
    final channel = FakePlatformChannel()
      ..errors['probeJoinBridge'] = PlatformException(
        code: 'native_error',
        message: secret,
        details: {'invite': secret},
      );
    final host = PlatformXConnectOneHostServices(
      channel: channel,
      targetPlatform: TargetPlatform.android,
    );

    final capability = await host.probeJoinBridge();

    expect(capability.code, 'mobile_join_bridge_unavailable');
    expect(capability.code, isNot(contains('xjt_')));
    await host.dispose();
  });

  test(
    'probes Keychain and Android Keystore with exact backend binding',
    () async {
      for (final testCase in [
        (TargetPlatform.iOS, 'keychain'),
        (TargetPlatform.macOS, 'keychain'),
        (TargetPlatform.android, 'android_keystore'),
      ]) {
        final channel = FakePlatformChannel()
          ..responses['probeSecureStorage'] = {
            'available': true,
            'backend': testCase.$2,
            'code': '${testCase.$2}_available',
          };
        final host = PlatformXConnectOneHostServices(
          channel: channel,
          targetPlatform: testCase.$1,
        );

        final capability = await host.probeSecureStorage();

        expect(capability.isAvailable, isTrue);
        await host.dispose();
      }
    },
  );

  test(
    'explicitly degrades missing Windows and Linux secure storage hosts',
    () async {
      for (final testCase in [
        (TargetPlatform.windows, 'credential_manager_not_integrated'),
        (TargetPlatform.linux, 'secret_service_not_integrated'),
      ]) {
        final host = PlatformXConnectOneHostServices(
          channel: FakePlatformChannel()
            ..errors['probeSecureStorage'] = MissingPluginException(),
          targetPlatform: testCase.$1,
        );

        final capability = await host.probeSecureStorage();

        expect(capability.isAvailable, isFalse);
        expect(capability.code, testCase.$2);
        await host.dispose();
      }
    },
  );

  test(
    'strict join response rejects unknown fields without exposing them',
    () async {
      final channel = FakePlatformChannel()
        ..responses['joinInvite'] = {
          'outcome': 'joined',
          'code': 'joined',
          'retryable': false,
          'enrollment_token': 'must-not-cross-the-boundary',
        };
      final host = PlatformXConnectOneHostServices(
        channel: channel,
        targetPlatform: TargetPlatform.iOS,
      );

      final result = await host.join(validInvite());

      expect(result.outcome, XConnectOneJoinOutcome.failed);
      expect(result.code, 'mobile_join_bridge_unavailable');
      await host.dispose();
    },
  );

  test('device session bridge is operation-level and fail-closed', () async {
    final channel = FakePlatformChannel()
      ..responses['syncDeviceSession'] = {
        'completed': true,
        'code': 'synchronized',
        'retryable': false,
      }
      ..responses['rotateDeviceCredential'] = {
        'completed': false,
        'code': 'credential_rotation_pending',
        'retryable': true,
        'device_credential': 'must-not-cross-dart-boundary',
      };
    final host = PlatformXConnectOneHostServices(
      channel: channel,
      targetPlatform: TargetPlatform.android,
    );

    final sync = await host.sync();
    final rotate = await host.rotateCredential();

    expect(sync.completed, isTrue);
    expect(sync.code, 'synchronized');
    expect(rotate.completed, isFalse);
    expect(rotate.code, 'protected_device_session_unavailable');
    expect(rotate.code, isNot(contains('xdc_')));
    await host.dispose();
  });
}

final class FakePlatformChannel implements XConnectOnePlatformChannel {
  final Map<String, Object?> responses = {};
  final Map<String, Object> errors = {};
  XConnectOnePlatformEventHandler? handler;

  @override
  Future<Object?> invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    final error = errors[method];
    if (error != null) throw error;
    return responses[method];
  }

  @override
  void setEventHandler(XConnectOnePlatformEventHandler? handler) {
    this.handler = handler;
  }

  Future<void> emit(String method, Object? arguments) async {
    await handler?.call(method, arguments);
    await Future<void>.delayed(Duration.zero);
  }
}
