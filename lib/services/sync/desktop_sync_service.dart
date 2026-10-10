import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../utils/app_logger.dart';
import '../../utils/global_config.dart' show GlobalState;
import '../session/session_manager.dart';
import '../vpn_config_service.dart';
import 'sync_state.dart';
import 'xray_config_writer.dart';

class DesktopSyncResult {
  final bool success;
  final String message;
  const DesktopSyncResult({required this.success, required this.message});
}

class SyncedNodeMetadata {
  final String id;
  final String name;
  final String? region;
  final String? protocol;
  final String? transport;
  final String? security;
  final String vlessUri;

  const SyncedNodeMetadata({
    required this.id,
    required this.name,
    required this.vlessUri,
    this.region,
    this.protocol,
    this.transport,
    this.security,
  });
}

/// Pulls the authoritative regional node list after login and periodically
/// while a session is active. The server owns availability and VLESS details;
/// this service only renders and persists the returned profiles.
class DesktopSyncService {
  DesktopSyncService._();
  static final instance = DesktopSyncService._();

  static const _nodesPath = '/api/agent-server/v1/nodes';
  static const _autoInterval = Duration(minutes: 10);
  final syncing = ValueNotifier<bool>(false);
  Timer? _timer;
  bool _initialized = false;
  bool _running = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await SessionManager.instance.init();
    await SyncStateStore.instance.init();
    SessionManager.instance.status.addListener(_onSessionChanged);
    _onSessionChanged();
  }

  void dispose() {
    _timer?.cancel();
    SessionManager.instance.status.removeListener(_onSessionChanged);
    _initialized = false;
  }

  Future<DesktopSyncResult> syncNow({bool manual = false}) async {
    if (!SessionManager.instance.isLoggedIn) {
      return const DesktopSyncResult(success: false, message: '请先登录');
    }
    if (_running) {
      return const DesktopSyncResult(success: false, message: '同步进行中');
    }
    _running = true;
    syncing.value = true;
    try {
      final session = SessionManager.instance;
      final headers = <String, String>{'Accept': 'application/json'};
      if ((session.sessionToken ?? '').trim().isNotEmpty) {
        headers['Authorization'] = 'Bearer ${session.sessionToken!.trim()}';
      }
      if ((session.cookie ?? '').trim().isNotEmpty) {
        headers['Cookie'] = session.cookie!.trim();
      }
      final response = await http
          .get(session.buildEndpoint(_nodesPath), headers: headers)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode == 401) {
        const message = '会话已过期，请重新登录';
        await SyncStateStore.instance.recordError(message);
        await session.logout();
        return const DesktopSyncResult(success: false, message: message);
      }
      if (response.statusCode == 403) {
        const message = '账号没有可用节点';
        await SyncStateStore.instance.recordError(message);
        return const DesktopSyncResult(success: false, message: message);
      }
      if (response.statusCode != 200) {
        final message = '节点同步接口返回 ${response.statusCode}';
        await SyncStateStore.instance.recordError(message);
        return DesktopSyncResult(success: false, message: message);
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! List) {
        throw const FormatException('节点同步响应必须是数组');
      }
      final nodes = decoded
          .whereType<Map>()
          .map((item) => _parseNode(item.cast<Object?, Object?>()))
          .whereType<SyncedNodeMetadata>()
          .toList();
      if (nodes.isEmpty) {
        const message = '服务端当前没有可用区域节点';
        await SyncStateStore.instance.recordError(message);
        return const DesktopSyncResult(success: false, message: message);
      }

      final retained = <String>{};
      for (final node in nodes) {
        final config = await VpnConfig.tryGenerateXrayJsonFromVlessUri(
          node.vlessUri,
        );
        if (!_isRenderable(config)) {
          throw FormatException('区域节点 ${node.name} 的 VLESS 配置不可用');
        }
        final path = await XrayConfigWriter.writeConfigForNode(
          json: config!,
          nodeName: node.name,
          countryCode: node.region,
          nodeId: node.id,
        );
        final name = await XrayConfigWriter.registerNode(
          configPath: path,
          nodeName: node.name,
          countryCode: node.region,
          protocol: node.protocol,
          transport: node.transport,
          security: node.security,
          nodeId: node.id,
        );
        retained.add(name);
      }
      await XrayConfigWriter.pruneSyncedNodes(retained);
      GlobalState.nodeListRevision.value++;
      await SyncStateStore.instance.recordSuccess(
        nodeCount: nodes.length,
        nodeIds: nodes.map((n) => n.id).join(','),
      );
      addAppLog('区域 VLESS 配置已同步 (${nodes.length} 个节点)');
      return DesktopSyncResult(
        success: true,
        message: '同步成功 (${nodes.length} 个区域)',
      );
    } catch (error) {
      final message = '同步失败: $error';
      await SyncStateStore.instance.recordError(message);
      return DesktopSyncResult(success: false, message: message);
    } finally {
      _running = false;
      syncing.value = false;
    }
  }

  void _onSessionChanged() {
    _timer?.cancel();
    if (!SessionManager.instance.isLoggedIn) return;
    unawaited(syncNow());
    _timer = Timer.periodic(_autoInterval, (_) => unawaited(syncNow()));
  }

  SyncedNodeMetadata? _parseNode(Map<Object?, Object?> node) {
    String value(List<String> keys) {
      for (final key in keys) {
        final raw = node[key];
        if (raw is String && raw.trim().isNotEmpty) return raw.trim();
      }
      return '';
    }

    final id = value(['id', 'address']);
    final name = value(['name', 'display_name', 'remark', 'region', 'id']);
    final uri = value([
      'uri_scheme_xhttp',
      'uri_scheme_tcp',
      'vless_uri',
      'uri',
    ]);
    if (id.isEmpty || name.isEmpty || !uri.startsWith('vless://')) return null;
    return SyncedNodeMetadata(
      id: id,
      name: name,
      vlessUri: uri,
      region: value(['region', 'country_code']).toLowerCase(),
      protocol: value(['protocol']),
      transport: value(['transport', 'network']),
      security: value(['security']),
    );
  }

  static bool _isRenderable(String? raw) {
    if (raw == null || raw.trim().isEmpty) return false;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['outbounds'] is! List) return false;
      return (decoded['outbounds'] as List).any(
        (item) =>
            item is Map && item['tag'] == 'proxy' && item['protocol'] is String,
      );
    } catch (_) {
      return false;
    }
  }
}
