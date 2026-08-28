import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'mobile_enrollment.dart';

typedef XConnectOnePlatformEventHandler = Future<void> Function(
    String method, Object? arguments);

abstract interface class XConnectOnePlatformChannel {
  Future<Object?> invoke(String method, [Map<String, Object?>? arguments]);

  void setEventHandler(XConnectOnePlatformEventHandler? handler);
}

final class MethodChannelXConnectOnePlatformChannel
    implements XConnectOnePlatformChannel {
  MethodChannelXConnectOnePlatformChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'plus.svc.xconnect/xconnect_one';
  final MethodChannel _channel;

  @override
  Future<Object?> invoke(String method, [Map<String, Object?>? arguments]) =>
      _channel.invokeMethod<Object?>(method, arguments);

  @override
  void setEventHandler(XConnectOnePlatformEventHandler? handler) {
    _channel.setMethodCallHandler(
      handler == null
          ? null
          : (call) async => handler(call.method, call.arguments),
    );
  }
}

final class PlatformXConnectOneHostServices
    implements
        XConnectOneJoinService,
        XConnectOneInviteIngress,
        XConnectOneSecureStorageProbe {
  PlatformXConnectOneHostServices({
    XConnectOnePlatformChannel? channel,
    TargetPlatform? targetPlatform,
  })  : _channel = channel ?? MethodChannelXConnectOnePlatformChannel(),
        _targetPlatform = targetPlatform ?? defaultTargetPlatform;

  final XConnectOnePlatformChannel _channel;
  final TargetPlatform _targetPlatform;
  final StreamController<XConnectOneInviteIngressEvent> _events =
      StreamController<XConnectOneInviteIngressEvent>.broadcast();
  bool _started = false;

  @override
  Stream<XConnectOneInviteIngressEvent> get events => _events.stream;

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _channel.setEventHandler(_handlePlatformEvent);
    try {
      final initial = await _channel.invoke('initialInvite');
      _emitIngress(initial);
    } on MissingPluginException {
      // A host without the product channel had no accepted deep link to emit.
    } on PlatformException {
      // Platform errors are reduced to absence; details may contain payloads.
    }
  }

  Future<void> _handlePlatformEvent(String method, Object? arguments) async {
    if (method == 'inviteReceived' || method == 'inviteRejected') {
      _emitIngress(arguments);
    }
  }

  void _emitIngress(Object? value) {
    if (value == null) return;
    if (value is! Map) {
      _events.add(const XConnectOneInviteRejected('join_invite_invalid'));
      return;
    }
    final map = Map<String, Object?>.from(value);
    if (map['status'] == 'accepted' &&
        map.keys.toSet().difference(const {'status', 'payload'}).isEmpty &&
        map.length == 2 &&
        map['payload'] is String) {
      final payload = map['payload']! as String;
      try {
        XConnectOneInvite.parse(payload);
        _events.add(XConnectOneInviteAccepted(payload));
      } on XConnectOneInputException {
        _events.add(const XConnectOneInviteRejected('join_invite_invalid'));
      }
      return;
    }
    if (map['status'] == 'rejected' &&
        map.keys.toSet().difference(const {'status', 'code'}).isEmpty &&
        map.length == 2) {
      _events.add(
        XConnectOneInviteRejected(
          map['code'] == 'join_invite_invalid'
              ? 'join_invite_invalid'
              : 'invite_ingress_unavailable',
        ),
      );
      return;
    }
    _events.add(const XConnectOneInviteRejected('join_invite_invalid'));
  }

  @override
  Future<XConnectOneJoinBridgeCapability> probeJoinBridge() async {
    try {
      final response = await _channel.invoke('probeJoinBridge');
      final map = _strictMap(response, const {'available', 'code'});
      final available = map['available'];
      final code = map['code'];
      if (available is! bool || code is! String || !_validCode(code)) {
        throw const FormatException('invalid join bridge response');
      }
      return XConnectOneJoinBridgeCapability(available: available, code: code);
    } on Object {
      return const XConnectOneJoinBridgeCapability(
        available: false,
        code: 'mobile_join_bridge_unavailable',
      );
    }
  }

  @override
  Future<XConnectOneJoinResult> join(String invitePayload) async {
    XConnectOneInvite.parse(invitePayload);
    return _invokeJoin('joinInvite', {'invite': invitePayload});
  }

  @override
  Future<XConnectOneJoinResult> resume() => _invokeJoin('resumeEnrollment');

  @override
  Future<void> clearTransient() async {
    try {
      final response = await _channel.invoke('clearEnrollmentTransient');
      final map = _strictMap(response, const {'cleared', 'code'});
      if (map['cleared'] != true ||
          map['code'] is! String ||
          !_validCode(map['code']! as String)) {
        throw const FormatException('invalid clear response');
      }
    } on MissingPluginException {
      // Nothing could have been persisted through an unavailable bridge.
    }
  }

  Future<XConnectOneJoinResult> _invokeJoin(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      final response = await _channel.invoke(method, arguments);
      final map = _strictMap(response, const {'outcome', 'code', 'retryable'});
      final outcomeName = map['outcome'];
      final code = map['code'];
      final retryable = map['retryable'];
      if (outcomeName is! String ||
          code is! String ||
          !_validCode(code) ||
          retryable is! bool) {
        throw const FormatException('invalid join response');
      }
      final outcome = switch (outcomeName) {
        'joined' => XConnectOneJoinOutcome.joined,
        'recovery_required' => XConnectOneJoinOutcome.recoveryRequired,
        'failed' => XConnectOneJoinOutcome.failed,
        _ => throw const FormatException('invalid join outcome'),
      };
      return XConnectOneJoinResult(
        outcome: outcome,
        code: code,
        retryable: retryable,
      );
    } on Object {
      return const XConnectOneJoinResult(
        outcome: XConnectOneJoinOutcome.failed,
        code: 'mobile_join_bridge_unavailable',
      );
    }
  }

  @override
  Future<SecureStorageCapability> probeSecureStorage() async {
    final expectedBackend = _expectedSecureStorageBackend(_targetPlatform);
    try {
      final response = await _channel.invoke('probeSecureStorage');
      final map = _strictMap(response, const {'available', 'backend', 'code'});
      final available = map['available'];
      final backendName = map['backend'];
      final code = map['code'];
      if (available is! bool ||
          backendName is! String ||
          code is! String ||
          !_validCode(code)) {
        throw const FormatException('invalid secure storage response');
      }
      final backend = _parseBackend(backendName);
      if (backend != expectedBackend) {
        throw const FormatException('unexpected secure storage backend');
      }
      return SecureStorageCapability(
        backend: backend,
        availability: available
            ? HostCapabilityAvailability.available
            : HostCapabilityAvailability.unavailable,
        code: code,
      );
    } on Object {
      return SecureStorageCapability(
        backend: expectedBackend,
        availability: HostCapabilityAvailability.unavailable,
        code: _unavailableStorageCode(expectedBackend),
      );
    }
  }

  Map<String, Object?> _strictMap(Object? value, Set<String> allowed) {
    if (value is! Map) throw const FormatException('expected map');
    final map = Map<String, Object?>.from(value);
    if (map.keys.any((key) => !allowed.contains(key)) ||
        !allowed.every(map.containsKey)) {
      throw const FormatException('unexpected response fields');
    }
    return map;
  }

  bool _validCode(String value) =>
      RegExp(r'^[a-z][a-z0-9_]{1,63}$').hasMatch(value);

  SecureStorageBackend _parseBackend(String value) => switch (value) {
        'keychain' => SecureStorageBackend.keychain,
        'android_keystore' => SecureStorageBackend.androidKeystore,
        'windows_credential_manager' =>
          SecureStorageBackend.windowsCredentialManager,
        'linux_secret_service' => SecureStorageBackend.linuxSecretService,
        _ => SecureStorageBackend.unsupported,
      };

  SecureStorageBackend _expectedSecureStorageBackend(TargetPlatform platform) =>
      switch (platform) {
        TargetPlatform.iOS ||
        TargetPlatform.macOS =>
          SecureStorageBackend.keychain,
        TargetPlatform.android => SecureStorageBackend.androidKeystore,
        TargetPlatform.windows => SecureStorageBackend.windowsCredentialManager,
        TargetPlatform.linux => SecureStorageBackend.linuxSecretService,
        _ => SecureStorageBackend.unsupported,
      };

  String _unavailableStorageCode(SecureStorageBackend backend) =>
      switch (backend) {
        SecureStorageBackend.keychain => 'keychain_unavailable',
        SecureStorageBackend.androidKeystore => 'android_keystore_unavailable',
        SecureStorageBackend.windowsCredentialManager =>
          'credential_manager_not_integrated',
        SecureStorageBackend.linuxSecretService =>
          'secret_service_not_integrated',
        SecureStorageBackend.unsupported => 'secure_storage_unsupported',
      };

  @override
  Future<void> dispose() async {
    _channel.setEventHandler(null);
    await _events.close();
  }
}
