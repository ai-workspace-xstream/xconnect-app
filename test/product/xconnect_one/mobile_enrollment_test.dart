import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/product/xconnect_one/mobile_enrollment.dart';

import 'mobile_enrollment_fakes.dart';

void main() {
  group('XConnectOneInvite ingress prefilter', () {
    test('matches the canonical Go mobile compatibility fixture', () async {
      final raw = await File(
        'go_core/overlay/invite/testdata/invite-url-cases.json',
      ).readAsString();
      final cases =
          (jsonDecode(raw) as List<Object?>).cast<Map<String, Object?>>();

      for (final item in cases) {
        final value = item['url']! as String;
        final expected = item['mobile_valid']! as bool;
        Object? error;
        try {
          XConnectOneInvite.parse(value);
        } on Object catch (caught) {
          error = caught;
        }
        expect(error == null, expected, reason: item['name']! as String);
      }
    });

    test('never exposes the opaque token from diagnostics', () {
      final invite = XConnectOneInvite.parse(validInvite());

      expect(invite.toString(), contains('[redacted]'));
      expect(invite.toString(), isNot(contains('xjt_')));
    });
  });

  group('XConnectOneEnrollmentController', () {
    test('delegates one payload to the single Join bridge', () async {
      final join = FakeJoinService();
      final ingress = FakeInviteIngress();
      final controller = XConnectOneEnrollmentController(
        joinService: join,
        inviteIngress: ingress,
        qrScanner: FakeQrScanner(null),
        secureStorage: FakeSecureStorage(),
      );
      await controller.initialize();
      final invite = validInvite();

      await controller.submitPayload(
        invite,
        source: XConnectOneInviteSource.paste,
      );
      await controller.join();

      expect(join.joinedPayloads, [invite]);
      expect(controller.state.phase, XConnectOneEnrollmentPhase.joined);
      expect(
        jsonEncode(controller.state.toSafeJson()),
        isNot(contains('xjt_')),
      );
      controller.dispose();
    });

    test('fails before handing a secret to an unavailable bridge', () async {
      final join = FakeJoinService()
        ..capability = const XConnectOneJoinBridgeCapability(
          available: false,
          code: 'mobile_join_bridge_unavailable',
        );
      final controller = XConnectOneEnrollmentController(
        joinService: join,
        inviteIngress: FakeInviteIngress(),
        qrScanner: FakeQrScanner(null),
        secureStorage: FakeSecureStorage(),
      );
      await controller.submitPayload(
        validInvite(),
        source: XConnectOneInviteSource.deepLink,
      );

      await controller.join();

      expect(join.joinedPayloads, isEmpty);
      expect(controller.state.code, 'mobile_join_bridge_unavailable');
      controller.dispose();
    });

    test('requires secure host storage before calling Join', () async {
      final join = FakeJoinService();
      final controller = XConnectOneEnrollmentController(
        joinService: join,
        inviteIngress: FakeInviteIngress(),
        qrScanner: FakeQrScanner(null),
        secureStorage: FakeSecureStorage(available: false),
      );
      await controller.submitPayload(
        validInvite(),
        source: XConnectOneInviteSource.paste,
      );

      await controller.join();

      expect(join.joinedPayloads, isEmpty);
      expect(controller.state.code, 'keychain_unavailable');
      controller.dispose();
    });

    test(
      'serializes duplicate join and drops a newer link during join',
      () async {
        final join = FakeJoinService()
          ..joinCompleter = Completer<XConnectOneJoinResult>();
        final ingress = FakeInviteIngress();
        final controller = XConnectOneEnrollmentController(
          joinService: join,
          inviteIngress: ingress,
          qrScanner: FakeQrScanner(null),
          secureStorage: FakeSecureStorage(),
        );
        await controller.initialize();
        final first = validInvite(1);
        final second = validInvite(2);
        await controller.submitPayload(
          first,
          source: XConnectOneInviteSource.deepLink,
        );

        final firstOperation = controller.join();
        final duplicateOperation = controller.join();
        ingress.controller.add(XConnectOneInviteAccepted(second));
        ingress.controller.add(
          const XConnectOneInviteRejected('join_invite_invalid'),
        );
        await Future<void>.delayed(Duration.zero);

        expect(identical(firstOperation, duplicateOperation), isTrue);
        expect(join.joinedPayloads, [first]);
        expect(controller.state.phase, XConnectOneEnrollmentPhase.joining);
        join.joinCompleter!.complete(
          const XConnectOneJoinResult(
            outcome: XConnectOneJoinOutcome.joined,
            code: 'joined',
          ),
        );
        await firstOperation;
        expect(controller.state.phase, XConnectOneEnrollmentPhase.joined);
        controller.dispose();
      },
    );

    test('clear invalidates a late join result and runs after it', () async {
      final join = FakeJoinService()
        ..joinCompleter = Completer<XConnectOneJoinResult>();
      final controller = XConnectOneEnrollmentController(
        joinService: join,
        inviteIngress: FakeInviteIngress(),
        qrScanner: FakeQrScanner(null),
        secureStorage: FakeSecureStorage(),
      );
      await controller.submitPayload(
        validInvite(),
        source: XConnectOneInviteSource.paste,
      );
      final joining = controller.join();
      final clearing = controller.clear();

      join.joinCompleter!.complete(
        const XConnectOneJoinResult(
          outcome: XConnectOneJoinOutcome.joined,
          code: 'joined',
        ),
      );
      await Future.wait([joining, clearing]);

      expect(join.clearCalls, 1);
      expect(controller.state.phase, XConnectOneEnrollmentPhase.idle);
      controller.dispose();
    });

    test('does not report cleared when host transient deletion fails',
        () async {
      final join = FakeJoinService()..clearError = StateError('secret details');
      final controller = XConnectOneEnrollmentController(
        joinService: join,
        inviteIngress: FakeInviteIngress(),
        qrScanner: FakeQrScanner(null),
        secureStorage: FakeSecureStorage(),
      );

      await controller.clear();

      expect(controller.state.phase, XConnectOneEnrollmentPhase.failed);
      expect(controller.state.code, 'clear_transient_failed');
      expect(controller.state.code, isNot(contains('secret')));
      controller.dispose();
    });

    test('recovery retry resumes without replaying the consumed invite',
        () async {
      final join = FakeJoinService()
        ..joinResult = const XConnectOneJoinResult(
          outcome: XConnectOneJoinOutcome.recoveryRequired,
          code: 'runtime_apply_failed',
          retryable: true,
        );
      final controller = XConnectOneEnrollmentController(
        joinService: join,
        inviteIngress: FakeInviteIngress(),
        qrScanner: FakeQrScanner(null),
        secureStorage: FakeSecureStorage(),
      );
      await controller.submitPayload(
        validInvite(),
        source: XConnectOneInviteSource.deepLink,
      );

      await controller.join();
      await controller.retry();

      expect(join.joinedPayloads, hasLength(1));
      expect(join.resumeCalls, 1);
      controller.dispose();
    });

    test(
      'dispose prevents a late result from notifying or changing state',
      () async {
        final join = FakeJoinService()
          ..joinCompleter = Completer<XConnectOneJoinResult>();
        final controller = XConnectOneEnrollmentController(
          joinService: join,
          inviteIngress: FakeInviteIngress(),
          qrScanner: FakeQrScanner(null),
          secureStorage: FakeSecureStorage(),
        );
        await controller.submitPayload(
          validInvite(),
          source: XConnectOneInviteSource.paste,
        );
        var notifications = 0;
        controller.addListener(() => notifications++);
        final operation = controller.join();
        final beforeDispose = notifications;
        controller.dispose();

        join.joinCompleter!.complete(
          const XConnectOneJoinResult(
            outcome: XConnectOneJoinOutcome.joined,
            code: 'joined',
          ),
        );
        await operation;

        expect(notifications, beforeDispose);
        expect(
          controller.state.phase,
          isNot(XConnectOneEnrollmentPhase.joined),
        );
      },
    );

    test(
      'QR scanner is an injected SPI and invalid payload fails closed',
      () async {
        final controller = XConnectOneEnrollmentController(
          joinService: FakeJoinService(),
          inviteIngress: FakeInviteIngress(),
          qrScanner: FakeQrScanner('not-an-invite'),
          secureStorage: FakeSecureStorage(),
        );

        await controller.scanQr();

        expect(controller.state.code, 'join_invite_invalid');
        controller.dispose();
      },
    );

    test('QR scanner exceptions are reduced to a stable code', () async {
      final controller = XConnectOneEnrollmentController(
        joinService: FakeJoinService(),
        inviteIngress: FakeInviteIngress(),
        qrScanner: FakeQrScanner(null, error: StateError(validInvite())),
        secureStorage: FakeSecureStorage(),
      );

      await controller.scanQr();

      expect(controller.state.code, 'qr_scanner_unavailable');
      expect(controller.state.code, isNot(contains('xjt_')));
      controller.dispose();
    });
  });
}
