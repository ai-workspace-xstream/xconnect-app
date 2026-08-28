import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:xconnect/product/xconnect_one/mobile_enrollment.dart';

final class FakeJoinService implements XConnectOneJoinService {
  XConnectOneJoinBridgeCapability capability =
      const XConnectOneJoinBridgeCapability(
    available: true,
    code: 'join_bridge_available',
  );
  XConnectOneJoinResult joinResult = const XConnectOneJoinResult(
    outcome: XConnectOneJoinOutcome.joined,
    code: 'joined',
  );
  XConnectOneJoinResult resumeResult = const XConnectOneJoinResult(
    outcome: XConnectOneJoinOutcome.recoveryRequired,
    code: 'enrollment_resume_required',
    retryable: true,
  );
  Completer<XConnectOneJoinResult>? joinCompleter;
  final List<String> joinedPayloads = [];
  int clearCalls = 0;
  int resumeCalls = 0;
  Object? clearError;

  @override
  Future<XConnectOneJoinBridgeCapability> probeJoinBridge() async => capability;

  @override
  Future<XConnectOneJoinResult> join(String invitePayload) {
    joinedPayloads.add(invitePayload);
    return joinCompleter?.future ?? Future.value(joinResult);
  }

  @override
  Future<XConnectOneJoinResult> resume() async {
    resumeCalls++;
    return resumeResult;
  }

  @override
  Future<void> clearTransient() async {
    clearCalls++;
    if (clearError != null) throw clearError!;
  }
}

final class FakeInviteIngress implements XConnectOneInviteIngress {
  final StreamController<XConnectOneInviteIngressEvent> controller =
      StreamController<XConnectOneInviteIngressEvent>.broadcast();
  bool started = false;

  @override
  Stream<XConnectOneInviteIngressEvent> get events => controller.stream;

  @override
  Future<void> start() async {
    started = true;
  }

  @override
  Future<void> dispose() => controller.close();
}

final class FakeQrScanner implements XConnectOneQrScanner {
  FakeQrScanner(this.payload, {this.error});

  final String? payload;
  final Object? error;

  @override
  Future<String?> scanInvite() async {
    if (error != null) throw error!;
    return payload;
  }
}

final class FakeSecureStorage implements XConnectOneSecureStorageProbe {
  FakeSecureStorage({this.available = true});

  final bool available;

  @override
  Future<SecureStorageCapability> probeSecureStorage() async =>
      SecureStorageCapability(
        backend: SecureStorageBackend.keychain,
        availability: available
            ? HostCapabilityAvailability.available
            : HostCapabilityAvailability.unavailable,
        code: available ? 'keychain_available' : 'keychain_unavailable',
      );
}

final class FakeProtectedTunnelHost implements XConnectOneProtectedTunnelHost {
  const FakeProtectedTunnelHost();

  @override
  String get boundaryCode => 'packet_tunnel_boundary';
}

String validInvite([int byte = 0]) {
  final token = base64Url.encode(Uint8List(32)..fillRange(0, 32, byte));
  return 'xconnect://join/xjt_${token.replaceAll('=', '')}'
      '?controller=https%3A%2F%2Faccounts.example';
}
