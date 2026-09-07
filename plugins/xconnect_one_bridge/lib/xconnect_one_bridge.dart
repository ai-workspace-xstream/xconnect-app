import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// A safe, user-facing error from the optional One bridge.
///
/// Only the protocol error code is retained. The invite, process arguments,
/// stderr and controller response are deliberately never included.
class XConnectOneBridgeException implements Exception {
  final String code;

  const XConnectOneBridgeException(this.code);

  @override
  String toString() => 'XConnectOneBridgeException($code)';
}

/// Optional composition client for the independent `xconnect app-bridge`
/// command.
///
/// The APP core does not instantiate this class automatically. An explicit
/// plugin integration must provide the path to a released One binary and a
/// dedicated APP-owned state directory. Every request uses a short-lived
/// child process and a local stdin/stdout channel; no TCP listener is opened.
class XConnectOneBridge {
  XConnectOneBridge({
    required this.executablePath,
    required this.stateDirectory,
    this.timeout = const Duration(seconds: 30),
  }) {
    _validateAbsolutePath(executablePath, 'executable_path');
    _validateAbsolutePath(stateDirectory, 'state_dir');
    if (timeout <= Duration.zero) {
      throw const XConnectOneBridgeException('bridge_invalid_params');
    }
  }

  final String executablePath;
  final String stateDirectory;
  final Duration timeout;

  Future<Map<String, dynamic>> negotiate() => _call('negotiate', {
        'protocol_versions': ['1'],
      });

  Future<Map<String, dynamic>> join({
    required String invite,
    String? deviceId,
    String? name,
    String? networkId,
    String? nodeId,
  }) {
    if (invite.trim().isEmpty) {
      throw const XConnectOneBridgeException('bridge_invalid_params');
    }
    return _call('join', {
      'invite': invite,
      if (deviceId != null && deviceId.trim().isNotEmpty) 'device_id': deviceId,
      if (name != null && name.trim().isNotEmpty) 'name': name,
      if (networkId != null && networkId.trim().isNotEmpty)
        'network_id': networkId,
      if (nodeId != null && nodeId.trim().isNotEmpty) 'node_id': nodeId,
    });
  }

  Future<Map<String, dynamic>> sync({bool signedConfigV2 = false}) =>
      _call('sync', {'signed_config_v2': signedConfigV2});

  Future<Map<String, dynamic>> status() => _call('status', const {});

  Future<Map<String, dynamic>> diagnose() => _call('diagnose', const {});

  /// The host UI must confirm this action before calling it.
  Future<Map<String, dynamic>> leave({bool localOnly = false}) =>
      _call('leave', {'local_only': localOnly});

  Future<Map<String, dynamic>> _call(
    String method,
    Map<String, dynamic> methodParams,
  ) async {
    final params = <String, dynamic>{
      'state_dir': stateDirectory,
      ...methodParams,
    };
    final request = <String, dynamic>{
      'protocol_version': '1',
      'request_id': _requestId(),
      'method': method,
      'params': params,
    };

    Process? process;
    try {
      process = await Process.start(
          executablePath,
          const [
            'app-bridge',
          ],
          runInShell: false);
      // Drain stderr without retaining it. One's diagnostics can contain
      // paths or controller details and are outside the plugin contract.
      unawaited(process.stderr.drain<void>());
      process.stdin
        ..write(jsonEncode(request))
        ..write('\n')
        ..close();

      final line = await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(timeout);
      if (line.length > 64 * 1024) {
        throw const XConnectOneBridgeException('bridge_invalid_result');
      }
      final decoded = jsonDecode(line);
      if (decoded is! Map) {
        throw const XConnectOneBridgeException('bridge_invalid_result');
      }
      final response = Map<String, dynamic>.from(decoded);
      final error = response['error'];
      if (error is Map && error['code'] is String) {
        throw XConnectOneBridgeException(error['code'] as String);
      }
      final result = response['result'];
      if (result is! Map) {
        throw const XConnectOneBridgeException('bridge_invalid_result');
      }
      return Map<String, dynamic>.from(result);
    } on TimeoutException {
      throw const XConnectOneBridgeException('bridge_timeout');
    } on XConnectOneBridgeException {
      rethrow;
    } on FormatException {
      throw const XConnectOneBridgeException('bridge_invalid_result');
    } on IOException {
      throw const XConnectOneBridgeException('bridge_unavailable');
    } finally {
      process?.kill();
    }
  }

  static void _validateAbsolutePath(String value, String field) {
    if (value.trim().isEmpty || !Uri.file(value).isAbsolute) {
      throw XConnectOneBridgeException('bridge_invalid_$field');
    }
  }

  static String _requestId() {
    final random = Random.secure();
    final suffix = List<int>.generate(12, (_) => random.nextInt(256));
    return 'app-${DateTime.now().microsecondsSinceEpoch}-${base64UrlEncode(suffix)}';
  }
}
