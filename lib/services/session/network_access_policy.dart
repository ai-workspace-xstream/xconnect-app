import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Server authority for managed connections. A cached dedicated mode never
/// becomes personal merely because login or policy refresh fails.
class NetworkAccessPolicy {
  NetworkAccessPolicy._();
  static final instance = NetworkAccessPolicy._();
  static const _cacheKey = 'network.cachedAccess';
  static const _snapshotOwnerKey = 'network.snapshotOwner';
  static const _cacheLifetime = Duration(hours: 24);

  bool dedicated = false;
  bool authenticated = false;
  bool pending = false;
  bool allowed = false;
  String owner = '';
  String teamId = '';
  String teamName = '';
  DateTime? validUntil;
  Set<String> authorizedNodeIds = {};
  DateTime? _cachedAt;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    dedicated = prefs.getBool('network.dedicated') ?? false;
    invalidate(signedIn: false);
    owner = '';
    teamId = '';
    teamName = '';
    validUntil = null;
  }

  void invalidate({required bool signedIn}) {
    authenticated = signedIn;
    pending = signedIn;
    allowed = false;
    authorizedNodeIds = {};
    _cachedAt = null;
  }

  /// Restore only a complete, unexpired snapshot for this authenticated login.
  Future<void> restoreCachedAccess(String sessionScope) async {
    if (!authenticated) return;
    final prefs = await SharedPreferences.getInstance();
    try {
      final raw = prefs.getString(_cacheKey);
      if (raw == null) return;
      final cache = jsonDecode(raw) as Map<String, dynamic>;
      final savedAt =
          DateTime.fromMillisecondsSinceEpoch(cache['savedAt'] as int);
      final age = DateTime.now().difference(savedAt);
      final expiry = cache['validUntil'] == null
          ? null
          : DateTime.parse(cache['validUntil'] as String);
      final ids = (cache['nodeIds'] as List).cast<String>().toSet();
      if (cache['sessionScope'] != sessionScope ||
          age.isNegative ||
          age >= _cacheLifetime ||
          cache['allowed'] != true ||
          (cache['owner'] as String).isEmpty ||
          ids.isEmpty ||
          (expiry != null && !DateTime.now().isBefore(expiry)) ||
          (cache['dedicated'] == true && (cache['teamId'] as String).isEmpty)) {
        await clearCachedAccess();
        return;
      }
      dedicated = cache['dedicated'] as bool;
      owner = cache['owner'] as String;
      teamId = cache['teamId'] as String;
      teamName = cache['teamName'] as String;
      validUntil = expiry;
      authorizedNodeIds = ids;
      _cachedAt = savedAt;
      allowed = true;
      pending = false;
    } catch (_) {
      await clearCachedAccess();
    }
  }

  /// Save policy metadata only after every node has been persisted successfully.
  Future<void> cacheAccess({
    required String sessionScope,
    required bool Function() isCurrent,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (!isCurrent() || !active || authorizedNodeIds.isEmpty) return;
    _cachedAt = DateTime.now();
    await prefs.setString(
        _cacheKey,
        jsonEncode({
          'sessionScope': sessionScope,
          'savedAt': _cachedAt!.millisecondsSinceEpoch,
          'allowed': allowed,
          'dedicated': dedicated,
          'owner': owner,
          'teamId': teamId,
          'teamName': teamName,
          'validUntil': validUntil?.toIso8601String(),
          'nodeIds': authorizedNodeIds.toList(),
        }));
    // Keep the ownership binding after suspension, without keeping permission.
    // A denial before a new account syncs must not purge the old account files.
    if (isCurrent()) {
      await prefs.setString(_snapshotOwnerKey,
          jsonEncode({'sessionScope': sessionScope, 'owner': owner}));
    }
    if (!isCurrent()) await clearCachedAccess();
  }

  Future<String?> snapshotOwner(String sessionScope) async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final raw = prefs.getString(_snapshotOwnerKey);
      if (raw == null) return null;
      final binding = jsonDecode(raw);
      if (binding is Map && binding['sessionScope'] == sessionScope) {
        final owner = binding['owner'];
        if (owner is String && owner.isNotEmpty) return owner;
      }
    } catch (_) {
      // Unknown ownership is not authority to delete another account's files.
    }
    return null;
  }

  Future<void> clearCachedAccess() async {
    _cachedAt = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cacheKey);
  }

  Future<void> apply(Map<String, dynamic> access, String accountOwner) async {
    if (access['mode'] != 'personal' && access['mode'] != 'dedicated') {
      throw const FormatException('Invalid network access mode');
    }
    final nextDedicated = access['mode'] == 'dedicated';
    final nextTeam = access['teamId'] as String? ?? '';
    final team = access['team'];
    final nextExpiry = team is Map
        ? DateTime.tryParse(team['validUntil'] as String? ?? '')
        : null;
    final authorizationChanged = owner != accountOwner ||
        dedicated != nextDedicated ||
        teamId != nextTeam ||
        validUntil != nextExpiry ||
        access['allowed'] != true;
    final sameScope = owner == accountOwner &&
        dedicated == nextDedicated &&
        teamId == nextTeam &&
        active;
    dedicated = nextDedicated;
    owner = accountOwner;
    teamId = access['teamId'] as String? ?? '';
    teamName = team is Map ? team['name'] as String? ?? '' : '';
    validUntil = nextExpiry;
    allowed = access['allowed'] == true;
    pending = !sameScope; // publish a new scope only after its snapshot applies
    if (!sameScope) authorizedNodeIds = {};
    if (authorizationChanged) await clearCachedAccess();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('network.dedicated', dedicated);
  }

  DateTime? get expiresAt {
    final cacheExpiry = _cachedAt?.add(_cacheLifetime);
    if (validUntil == null) return cacheExpiry;
    return cacheExpiry == null || validUntil!.isBefore(cacheExpiry)
        ? validUntil
        : cacheExpiry;
  }

  bool get active =>
      authenticated &&
      !pending &&
      allowed &&
      (_cachedAt == null ||
          (!DateTime.now().isBefore(_cachedAt!) &&
              DateTime.now().difference(_cachedAt!) < _cacheLifetime)) &&
      (expiresAt == null || DateTime.now().isBefore(expiresAt!));

  bool canUse({
    required String serviceName,
    String? nodeOwner,
    String? nodeTeamId,
    String? nodeId,
  }) {
    final managed = serviceName == 'xconnect.desktop.sync' ||
        serviceName.startsWith('xconnect.sync.');
    // Custom imports are independent user-owned connections in every account
    // mode. Managed metadata cannot be relabeled to escape account isolation.
    if (!managed) {
      return nodeOwner == null && nodeTeamId == null && nodeId == null;
    }
    if (dedicated) {
      return active &&
          teamId.isNotEmpty &&
          managed &&
          nodeOwner == owner &&
          nodeTeamId == teamId &&
          authorizedNodeIds.contains(nodeId);
    }
    if (pending) return false;
    return active && nodeOwner == owner && authorizedNodeIds.contains(nodeId);
  }
}
