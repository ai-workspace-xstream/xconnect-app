import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../utils/app_logger.dart';
import '../../utils/global_config.dart' show GlobalState;
import '../session/session_manager.dart';
import '../notifications/quota_notifications.dart';
import '../session/network_access_policy.dart';
import '../../utils/native_bridge.dart';
import '../../widgets/log_console.dart' show LogLevel;
import '../tuning/client_tuning.dart';
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
  @visibleForTesting
  late http.Client client = http.Client();
  final syncing = ValueNotifier<bool>(false);
  Timer? _timer;
  Timer? _expiryTimer;
  bool _initialized = false;
  bool _running = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    // Session is initialized before node restoration in main().
    SessionManager.instance.onSessionReset = clearManagedConnections;
    await SyncStateStore.instance.init();
    SessionManager.instance.status.addListener(_onSessionChanged);
    _onSessionChanged();
  }

  void dispose() {
    _timer?.cancel();
    _expiryTimer?.cancel();
    SessionManager.instance.onSessionReset = null;
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
    final generation = SessionManager.instance.generation;
    final policy = NetworkAccessPolicy.instance;
    try {
      final session = SessionManager.instance;
      final headers = <String, String>{'Accept': 'application/json'};
      if ((session.sessionToken ?? '').trim().isNotEmpty) {
        headers['Authorization'] = 'Bearer ${session.sessionToken!.trim()}';
      }
      if ((session.cookie ?? '').trim().isNotEmpty) {
        headers['Cookie'] = session.cookie!.trim();
      }
      var owner = '${session.baseUrl.value}|${session.currentUser.value}';
      await QuotaNotifications.instance.selectAccount(owner);
      if (generation != session.generation) {
        return const DesktopSyncResult(
          success: false,
          message: 'Session changed',
        );
      }
      final accessResponse = await client
          .get(
            session.buildEndpoint('/api/auth/network-access'),
            headers: headers,
          )
          .timeout(const Duration(seconds: 20));
      if (generation != session.generation) {
        return const DesktopSyncResult(
          success: false,
          message: 'Session changed',
        );
      }
      if (accessResponse.statusCode == 401) {
        await session.logout();
        return const DesktopSyncResult(
          success: false,
          message: 'Session expired',
        );
      }
      if ((accessResponse.statusCode == 403 ||
              accessResponse.statusCode == 429) &&
          QuotaNotifications.isQuotaRejection(accessResponse.body)) {
        policy.invalidate(signedIn: true);
        await clearManagedConnections();
        if (generation != session.generation) {
          return const DesktopSyncResult(
              success: false, message: 'Session changed');
        }
        await QuotaNotifications.instance.update('quotaPaused');
        await SyncStateStore.instance.recordError('quotaPaused');
        return const DesktopSyncResult(success: false, message: 'quotaPaused');
      }
      if (accessResponse.statusCode == 404 && !policy.dedicated) {
        await policy.apply({'mode': 'personal', 'allowed': true}, owner);
      } else if (accessResponse.statusCode == 200) {
        final access = jsonDecode(accessResponse.body);
        if (access is! Map<String, dynamic>) {
          throw const FormatException('Invalid network access');
        }
        owner =
            '${session.baseUrl.value}|${access["accountId"] ?? session.currentUser.value}';
        await policy.apply(access, owner);
      } else {
        // A transient service/network failure must not erase the last local
        // managed snapshot. Only explicit authorization/quota responses above
        // are allowed to withdraw managed nodes.
        throw FormatException(
          'Network access returned ${accessResponse.statusCode}',
        );
      }
      if (accessResponse.statusCode == 200) {
        await _refreshQuota(session, headers, generation);
      }
      if (generation != session.generation) {
        return const DesktopSyncResult(
            success: false, message: 'Session changed');
      }
      if (!policy.allowed) {
        await clearManagedConnections();
        throw const FormatException('Team access is inactive');
      }
      if (generation != session.generation) {
        return const DesktopSyncResult(
          success: false,
          message: 'Session changed',
        );
      }
      final response = await client
          .get(session.buildEndpoint(_nodesPath), headers: headers)
          .timeout(const Duration(seconds: 20));
      if (generation != session.generation) {
        return const DesktopSyncResult(
          success: false,
          message: 'Session changed',
        );
      }
      if (response.statusCode == 401) {
        const message = '会话已过期，请重新登录';
        await SyncStateStore.instance.recordError(message);
        await session.logout();
        return const DesktopSyncResult(success: false, message: message);
      }
      if ((response.statusCode == 403 || response.statusCode == 429) &&
          QuotaNotifications.isQuotaRejection(response.body)) {
        policy.invalidate(signedIn: true);
        await clearManagedConnections();
        if (generation != session.generation) {
          return const DesktopSyncResult(
              success: false, message: 'Session changed');
        }
        await QuotaNotifications.instance.update('quotaPaused');
        await SyncStateStore.instance.recordError('quotaPaused');
        return const DesktopSyncResult(success: false, message: 'quotaPaused');
      }
      if (response.statusCode == 403 ||
          (response.statusCode == 503 && policy.dedicated)) {
        policy.invalidate(signedIn: true);
        await clearManagedConnections();
        const message = '账号没有可用节点';
        await SyncStateStore.instance.recordError(message);
        return const DesktopSyncResult(success: false, message: message);
      }
      if (response.statusCode != 200) {
        // Keep the last successful managed snapshot for offline use. The
        // server can replace it on the next successful manual/automatic sync.
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
        policy.invalidate(signedIn: true);
        await clearManagedConnections();
        const message = '服务端当前没有可用节点';
        await SyncStateStore.instance.recordError(message);
        return const DesktopSyncResult(success: false, message: message);
      }

      // Prevent a current manual/public tunnel surviving entry into team mode.
      policy.authorizedNodeIds = nodes.map((n) => n.id).toSet();
      if (policy.dedicated) await _stopUnauthorizedActiveNode();
      final retained = <String>{};
      for (final node in nodes) {
        if (generation != session.generation) {
          await clearManagedConnections();
          return const DesktopSyncResult(
            success: false,
            message: 'Session changed',
          );
        }
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
          owner: owner,
          teamId: policy.teamId,
        );
        final name = await XrayConfigWriter.registerNode(
          configPath: path,
          nodeName: node.name,
          countryCode: node.region,
          protocol: node.protocol,
          transport: node.transport,
          security: node.security,
          nodeId: node.id,
          owner: owner,
          teamId: policy.teamId,
        );
        retained.add(name);
      }
      if (generation != session.generation) {
        await clearManagedConnections();
        return const DesktopSyncResult(
          success: false,
          message: 'Session changed',
        );
      }
      await XrayConfigWriter.pruneSyncedNodes(retained);
      policy.authorizedNodeIds = nodes.map((n) => n.id).toSet();
      policy.pending = false;
      _expiryTimer?.cancel();
      if (policy.dedicated && policy.validUntil != null) {
        _expiryTimer = Timer(policy.validUntil!.difference(DateTime.now()), () {
          policy.invalidate(signedIn: SessionManager.instance.isLoggedIn);
          unawaited(clearManagedConnections());
        });
      }
      await _refreshClientTuning(
        session,
        headers,
        isCurrent: () => generation == session.generation && session.isLoggedIn,
      );
      // Signing out or switching accounts during the tuning request must not
      // let this older sync report success.
      if (generation != session.generation) {
        return const DesktopSyncResult(
          success: false,
          message: 'Session changed',
        );
      }
      GlobalState.nodeListRevision.value++;
      if (QuotaNotifications.instance.notice == 'quotaPaused') {
        await QuotaNotifications.instance.update(null);
      }
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
      if (generation != SessionManager.instance.generation &&
          SessionManager.instance.isLoggedIn) {
        unawaited(syncNow());
      }
    }
  }

  // Quota status is advisory. Older servers and transient failures must not
  // block node sync or turn an unknown allowance into an exhaustion warning.
  Future<void> _refreshQuota(
    SessionManager session,
    Map<String, String> headers,
    int generation,
  ) async {
    try {
      final response = await client
          .get(
            session.buildEndpoint('/api/account/usage/summary'),
            headers: headers,
          )
          .timeout(const Duration(seconds: 10));
      if (generation != session.generation || response.statusCode != 200) {
        return;
      }
      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) return;
      final quota = QuotaSnapshot.fromJson(body);
      final store = QuotaNotifications.instance;
      // No quota fields is a legacy response, not proof of recovery.
      if (!quota.unlimited &&
          !quota.paused &&
          (quota.remaining == null || quota.total == null)) {
        return;
      }
      if (store.notice != 'quotaPaused' || quota.notice != 'quotaEmpty') {
        await store.update(
            quota.paused || store.remindersEnabled ? quota.notice : null);
      }
    } catch (_) {
      // Keep the last known status when the optional endpoint is unavailable.
    }
  }

  Future<void> _stopUnauthorizedActiveNode() async {
    final active = GlobalState.activeNodeName.value;
    if (active.trim().isEmpty) return;
    final node = VpnConfig.getNodeByName(active);
    if (node == null || VpnConfig.canUseNode(node)) return;
    await NativeBridge.stopNodeForTunnel();
    await NativeBridge.stopNodeService(active);
    GlobalState.activeNodeName.value = '';
  }

  Future<void> clearManagedConnections() async {
    _expiryTimer?.cancel();
    // Invalidate in-flight tuning requests before any await below.
    final tuningCleared = ClientTuning.clear();
    await _stopUnauthorizedActiveNode();
    await XrayConfigWriter.pruneSyncedNodes({});
    await SyncStateStore.instance.clearNodes();
    await tuningCleared;
    // Withdraw server overrides from the persisted Packet Tunnel profile too.
    unawaited(NativeBridge.refreshPersistedTunnelProfileTuning());
    GlobalState.nodeListRevision.value++;
  }

  /// Best effort: tuning never fails a node sync, and a failed fetch keeps
  /// the last known good tuning. It applies on the next connect, and a change
  /// is written into the persisted Packet Tunnel profile for system relaunch.
  Future<void> _refreshClientTuning(
    SessionManager session,
    Map<String, String> headers, {
    required bool Function() isCurrent,
  }) async {
    final before = jsonEncode(ClientTuning.profile?.toJson());
    try {
      final revision = await ClientTuning.refresh(
        client,
        session.buildEndpoint(ClientTuning.endpointPath),
        headers,
        isCurrent: isCurrent,
      );
      addAppLog(revision == null
          ? '服务端未下发连接调优参数，使用内置默认值'
          : '连接调优参数已更新 (revision $revision)，下次连接生效');
      if (jsonEncode(ClientTuning.profile?.toJson()) != before) {
        unawaited(NativeBridge.refreshPersistedTunnelProfileTuning());
      }
    } on ClientTuningStaleException {
      addAppLog('会话已变化，丢弃旧会话的连接调优参数');
    } catch (error) {
      addAppLog(
        '连接调优参数获取失败，继续使用上次的参数: $error',
        level: LogLevel.warning,
      );
    }
  }

  void _onSessionChanged() {
    _timer?.cancel();
    if (!SessionManager.instance.isLoggedIn) {
      unawaited(QuotaNotifications.instance.selectAccount(null));
      return;
    }
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
