import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

enum XConnectOneInviteSource { deepLink, paste, importedFile, qr }

final class XConnectOneInvite {
  XConnectOneInvite._({required this.payload, required this.controller});

  final String payload;
  final Uri controller;

  static XConnectOneInvite parse(String value) {
    if (value.trim() != value) {
      throw const XConnectOneInputException('join_invite_invalid');
    }
    final raw = value;
    final match = RegExp(
      r'^xconnect://join/(xjt_[A-Za-z0-9_-]{43})\?controller=([^&#]+)$',
    ).firstMatch(raw);
    if (match == null) {
      throw const XConnectOneInputException('join_invite_invalid');
    }

    final token = match.group(1)!;
    try {
      final tokenBytes = base64Url.decode(
        base64Url.normalize(token.substring('xjt_'.length)),
      );
      if (tokenBytes.length != 32) {
        throw const FormatException('unexpected token size');
      }
      final canonical = base64Url.encode(tokenBytes).replaceAll('=', '');
      if (canonical != token.substring('xjt_'.length)) {
        throw const FormatException('non-canonical token');
      }
    } on FormatException {
      throw const XConnectOneInputException('join_invite_invalid');
    }

    final String controllerValue;
    try {
      controllerValue = Uri.decodeQueryComponent(match.group(2)!);
    } on FormatException {
      throw const XConnectOneInputException('join_invite_invalid');
    }
    final controller = Uri.tryParse(controllerValue);
    if (controller == null ||
        controller.scheme != 'https' ||
        controller.host.isEmpty ||
        controller.userInfo.isNotEmpty ||
        controller.hasQuery ||
        controller.hasFragment ||
        (controller.path.isNotEmpty && controller.path != '/') ||
        controllerValue.trim() != controllerValue) {
      throw const XConnectOneInputException('join_invite_invalid');
    }

    return XConnectOneInvite._(
      payload: raw,
      controller: controller.replace(path: ''),
    );
  }

  @override
  String toString() =>
      'XConnectOneInvite(controller: ${controller.host}, payload: [redacted])';
}

final class XConnectOneInputException implements Exception {
  const XConnectOneInputException(this.code);

  final String code;

  @override
  String toString() => 'XConnectOneInputException(code: $code)';
}

enum SecureStorageBackend {
  keychain,
  androidKeystore,
  windowsCredentialManager,
  linuxSecretService,
  unsupported,
}

enum HostCapabilityAvailability { available, unavailable }

final class SecureStorageCapability {
  const SecureStorageCapability({
    required this.backend,
    required this.availability,
    required this.code,
  });

  final SecureStorageBackend backend;
  final HostCapabilityAvailability availability;
  final String code;

  bool get isAvailable => availability == HostCapabilityAvailability.available;
}

abstract interface class XConnectOneSecureStorageProbe {
  Future<SecureStorageCapability> probeSecureStorage();
}

abstract interface class XConnectOneProtectedTunnelHost {
  String get boundaryCode;
}

final class XConnectOneJoinBridgeCapability {
  const XConnectOneJoinBridgeCapability({
    required this.available,
    required this.code,
  });

  final bool available;
  final String code;
}

enum XConnectOneJoinOutcome { joined, recoveryRequired, failed }

final class XConnectOneJoinResult {
  const XConnectOneJoinResult({
    required this.outcome,
    required this.code,
    this.retryable = false,
  });

  final XConnectOneJoinOutcome outcome;
  final String code;
  final bool retryable;
}

/// The sole Flutter boundary for the Go overlay Join use case.
///
/// Implementations must delegate exchange, SignedConfig validation, runtime
/// apply and ACK ordering to Go's `overlay/usecase.Joiner`. Flutter must never
/// reproduce those control-plane steps or persist their credentials.
abstract interface class XConnectOneJoinService {
  Future<XConnectOneJoinBridgeCapability> probeJoinBridge();

  Future<XConnectOneJoinResult> join(String invitePayload);

  Future<XConnectOneJoinResult> resume();

  Future<void> clearTransient();
}

sealed class XConnectOneInviteIngressEvent {
  const XConnectOneInviteIngressEvent();
}

final class XConnectOneInviteAccepted extends XConnectOneInviteIngressEvent {
  const XConnectOneInviteAccepted(this.payload);

  final String payload;
}

final class XConnectOneInviteRejected extends XConnectOneInviteIngressEvent {
  const XConnectOneInviteRejected(this.code);

  final String code;
}

abstract interface class XConnectOneInviteIngress {
  Stream<XConnectOneInviteIngressEvent> get events;

  Future<void> start();

  Future<void> dispose();
}

abstract interface class XConnectOneQrScanner {
  Future<String?> scanInvite();
}

final class UnavailableXConnectOneQrScanner implements XConnectOneQrScanner {
  const UnavailableXConnectOneQrScanner();

  @override
  Future<String?> scanInvite() =>
      throw const XConnectOneInputException('qr_scanner_unavailable');
}

enum XConnectOneEnrollmentPhase {
  idle,
  inviteReady,
  checkingHost,
  joining,
  recoveryRequired,
  joined,
  failed,
  clearing,
}

@immutable
final class XConnectOneEnrollmentState {
  const XConnectOneEnrollmentState({
    required this.phase,
    required this.code,
    this.source,
    this.retryable = false,
  });

  const XConnectOneEnrollmentState.idle()
      : phase = XConnectOneEnrollmentPhase.idle,
        code = 'idle',
        source = null,
        retryable = false;

  final XConnectOneEnrollmentPhase phase;
  final String code;
  final XConnectOneInviteSource? source;
  final bool retryable;

  Map<String, Object?> toSafeJson() => {
        'phase': phase.name,
        'code': code,
        if (source != null) 'source': source!.name,
        'retryable': retryable,
      };
}

final class XConnectOneEnrollmentController extends ChangeNotifier {
  XConnectOneEnrollmentController({
    required XConnectOneJoinService joinService,
    required XConnectOneInviteIngress inviteIngress,
    required XConnectOneQrScanner qrScanner,
    required XConnectOneSecureStorageProbe secureStorage,
  })  : _joinService = joinService,
        _inviteIngress = inviteIngress,
        _qrScanner = qrScanner,
        _secureStorage = secureStorage;

  final XConnectOneJoinService _joinService;
  final XConnectOneInviteIngress _inviteIngress;
  final XConnectOneQrScanner _qrScanner;
  final XConnectOneSecureStorageProbe _secureStorage;
  StreamSubscription<XConnectOneInviteIngressEvent>? _inviteSubscription;
  XConnectOneInvite? _pendingInvite;
  Future<void>? _activeOperation;
  int _epoch = 0;
  bool _disposed = false;
  XConnectOneEnrollmentState _state = const XConnectOneEnrollmentState.idle();

  XConnectOneEnrollmentState get state => _state;

  Future<void> initialize() async {
    if (_inviteSubscription != null) return;
    _inviteSubscription = _inviteIngress.events.listen(_handleIngress);
    try {
      await _inviteIngress.start();
    } on Object {
      _setState(
        const XConnectOneEnrollmentState(
          phase: XConnectOneEnrollmentPhase.failed,
          code: 'invite_ingress_unavailable',
        ),
      );
    }
  }

  Future<void> submitPayload(
    String payload, {
    required XConnectOneInviteSource source,
  }) async {
    if (_disposed || _activeOperation != null) {
      // One-time invites received during an operation are deliberately
      // dropped; they never replace the invite currently being consumed.
      return;
    }
    final XConnectOneInvite invite;
    try {
      invite = XConnectOneInvite.parse(payload);
    } on XConnectOneInputException catch (error) {
      _pendingInvite = null;
      _setState(
        XConnectOneEnrollmentState(
          phase: XConnectOneEnrollmentPhase.failed,
          code: error.code,
          source: source,
        ),
      );
      return;
    }
    _pendingInvite = invite;
    _setState(
      XConnectOneEnrollmentState(
        phase: XConnectOneEnrollmentPhase.inviteReady,
        code: 'invite_ready',
        source: source,
      ),
    );
  }

  Future<void> scanQr() async {
    if (_disposed || _activeOperation != null) return;
    try {
      final payload = await _qrScanner.scanInvite();
      if (payload != null) {
        await submitPayload(payload, source: XConnectOneInviteSource.qr);
      }
    } on XConnectOneInputException catch (error) {
      _setState(
        XConnectOneEnrollmentState(
          phase: XConnectOneEnrollmentPhase.failed,
          code: error.code,
          source: XConnectOneInviteSource.qr,
        ),
      );
    } on Object {
      _setState(
        const XConnectOneEnrollmentState(
          phase: XConnectOneEnrollmentPhase.failed,
          code: 'qr_scanner_unavailable',
          source: XConnectOneInviteSource.qr,
        ),
      );
    }
  }

  Future<void> join() {
    if (_disposed) return Future.value();
    final active = _activeOperation;
    if (active != null) return active;
    return _startOperation(_joinPending);
  }

  Future<void> _joinPending(int operationEpoch) async {
    final invite = _pendingInvite;
    if (invite == null) {
      _setStateIfCurrent(
        operationEpoch,
        const XConnectOneEnrollmentState(
          phase: XConnectOneEnrollmentPhase.failed,
          code: 'join_invite_required',
        ),
      );
      return;
    }

    _setStateIfCurrent(
      operationEpoch,
      XConnectOneEnrollmentState(
        phase: XConnectOneEnrollmentPhase.checkingHost,
        code: 'checking_host_capabilities',
        source: state.source,
      ),
    );
    final XConnectOneJoinBridgeCapability bridge;
    try {
      bridge = await _joinService.probeJoinBridge();
    } on Object {
      _setStableFailure(operationEpoch, 'mobile_join_bridge_unavailable');
      return;
    }
    if (!_isCurrent(operationEpoch)) return;
    if (!bridge.available) {
      _setStateIfCurrent(
        operationEpoch,
        XConnectOneEnrollmentState(
          phase: XConnectOneEnrollmentPhase.failed,
          code: bridge.code,
          source: state.source,
        ),
      );
      return;
    }
    final SecureStorageCapability storage;
    try {
      storage = await _secureStorage.probeSecureStorage();
    } on Object {
      _setStableFailure(operationEpoch, 'secure_storage_unavailable');
      return;
    }
    if (!_isCurrent(operationEpoch)) return;
    if (!storage.isAvailable) {
      _setStateIfCurrent(
        operationEpoch,
        XConnectOneEnrollmentState(
          phase: XConnectOneEnrollmentPhase.failed,
          code: storage.code,
          source: state.source,
        ),
      );
      return;
    }

    _setStateIfCurrent(
      operationEpoch,
      XConnectOneEnrollmentState(
        phase: XConnectOneEnrollmentPhase.joining,
        code: 'joining',
        source: state.source,
      ),
    );
    final XConnectOneJoinResult result;
    // Ownership transfers to the authoritative Go use case at this point.
    // Never replay the one-time invite from Flutter after the bridge call.
    _pendingInvite = null;
    try {
      result = await _joinService.join(invite.payload);
    } on Object {
      _setStableFailure(operationEpoch, 'mobile_join_bridge_unavailable');
      return;
    }
    if (!_isCurrent(operationEpoch)) return;
    _applyResult(result, operationEpoch);
  }

  Future<void> retry() {
    if (_disposed) return Future.value();
    final active = _activeOperation;
    if (active != null) return active;
    if (_pendingInvite != null) {
      return _startOperation(_joinPending);
    }
    return _startOperation(_resume);
  }

  Future<void> _resume(int operationEpoch) async {
    final XConnectOneJoinBridgeCapability bridge;
    final SecureStorageCapability storage;
    try {
      bridge = await _joinService.probeJoinBridge();
      if (!_isCurrent(operationEpoch)) return;
      if (!bridge.available) {
        _setStableFailure(operationEpoch, bridge.code);
        return;
      }
      storage = await _secureStorage.probeSecureStorage();
      if (!_isCurrent(operationEpoch)) return;
      if (!storage.isAvailable) {
        _setStableFailure(operationEpoch, storage.code);
        return;
      }
    } on Object {
      _setStableFailure(operationEpoch, 'mobile_join_bridge_unavailable');
      return;
    }
    final XConnectOneJoinResult result;
    try {
      result = await _joinService.resume();
    } on Object {
      _setStableFailure(operationEpoch, 'mobile_join_bridge_unavailable');
      return;
    }
    if (_isCurrent(operationEpoch)) {
      _applyResult(result, operationEpoch);
    }
  }

  Future<void> clear() {
    if (_disposed) return Future.value();
    final previous = _activeOperation;
    final clearEpoch = ++_epoch;
    _pendingInvite = null;
    _setState(
      const XConnectOneEnrollmentState(
        phase: XConnectOneEnrollmentPhase.clearing,
        code: 'clearing',
      ),
    );
    late Future<void> operation;
    operation = (previous ?? Future<void>.value())
        .catchError((Object _) {})
        .then((_) async {
      try {
        await _joinService.clearTransient();
        if (_isCurrent(clearEpoch)) {
          _setState(const XConnectOneEnrollmentState.idle());
        }
      } on Object {
        _setStableFailure(clearEpoch, 'clear_transient_failed');
      }
    }).whenComplete(() {
      if (identical(_activeOperation, operation)) {
        _activeOperation = null;
      }
    });
    _activeOperation = operation;
    return operation;
  }

  void _handleIngress(XConnectOneInviteIngressEvent event) {
    if (_disposed || _activeOperation != null) {
      return;
    }
    if (event is XConnectOneInviteAccepted) {
      unawaited(
        submitPayload(event.payload, source: XConnectOneInviteSource.deepLink),
      );
      return;
    }
    if (event is XConnectOneInviteRejected) {
      _pendingInvite = null;
      _setState(
        XConnectOneEnrollmentState(
          phase: XConnectOneEnrollmentPhase.failed,
          code: event.code,
          source: XConnectOneInviteSource.deepLink,
        ),
      );
    }
  }

  void _applyResult(XConnectOneJoinResult result, int operationEpoch) {
    final phase = switch (result.outcome) {
      XConnectOneJoinOutcome.joined => XConnectOneEnrollmentPhase.joined,
      XConnectOneJoinOutcome.recoveryRequired =>
        XConnectOneEnrollmentPhase.recoveryRequired,
      XConnectOneJoinOutcome.failed => XConnectOneEnrollmentPhase.failed,
    };
    _setStateIfCurrent(
      operationEpoch,
      XConnectOneEnrollmentState(
        phase: phase,
        code: result.code,
        source: state.source,
        retryable: result.retryable,
      ),
    );
  }

  void _setState(XConnectOneEnrollmentState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  Future<void> _startOperation(Future<void> Function(int epoch) body) {
    final operationEpoch = ++_epoch;
    late Future<void> operation;
    operation = body(operationEpoch).whenComplete(() {
      if (identical(_activeOperation, operation)) {
        _activeOperation = null;
      }
    });
    _activeOperation = operation;
    return operation;
  }

  bool _isCurrent(int operationEpoch) => !_disposed && operationEpoch == _epoch;

  void _setStateIfCurrent(int operationEpoch, XConnectOneEnrollmentState next) {
    if (_isCurrent(operationEpoch)) _setState(next);
  }

  void _setStableFailure(int operationEpoch, String code) {
    _setStateIfCurrent(
      operationEpoch,
      XConnectOneEnrollmentState(
        phase: XConnectOneEnrollmentPhase.failed,
        code: code,
        source: state.source,
      ),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _pendingInvite = null;
    unawaited(_inviteSubscription?.cancel());
    unawaited(_inviteIngress.dispose());
    super.dispose();
  }
}
