import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Missing/legacy fields are unknown, never a zero quota. Included allowance
/// exhaustion alone is not authority to disable PAYG or unlimited connections.
class QuotaSnapshot {
  const QuotaSnapshot(
      {this.remaining,
      this.total,
      this.unlimited = false,
      this.paused = false});
  final num? remaining;
  final num? total;
  final bool unlimited;
  final bool paused;

  factory QuotaSnapshot.fromJson(Map<String, dynamic> json) {
    final profile = json['billingProfile'];
    final rawTotal = json['includedQuotaBytes'] ??
        (profile is Map
            ? profile['includedQuotaBytes'] ?? profile['IncludedQuotaBytes']
            : null);
    final plan = json['currentPlan'];
    return QuotaSnapshot(
      remaining: json['remainingIncludedQuota'] is num
          ? json['remainingIncludedQuota'] as num
          : null,
      total: rawTotal is num ? rawTotal : null,
      unlimited: json['temporaryUnlimited'] == true ||
          (plan is Map && plan['unlimited'] == true),
      paused: json['networkAccessState'] == 'paused' &&
          json['networkAccessReason'] == 'quota_exhausted',
    );
  }

  String? get notice {
    if (unlimited) return null;
    if (paused) return 'quotaPaused';
    if (remaining == null ||
        total == null ||
        !remaining!.isFinite ||
        !total!.isFinite ||
        total! <= 0 ||
        remaining! < 0) {
      return null;
    }
    if (remaining == 0) return 'quotaEmpty';
    return remaining! / total! < .1 ? 'quotaLow' : null;
  }
}

class QuotaNotifications extends ChangeNotifier {
  QuotaNotifications();
  static final instance = QuotaNotifications();
  String _scope = '';
  int _selection = 0;
  String? notice;
  bool read = false;
  bool remindersEnabled = true;
  bool get hasUnread => notice != null && !read;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    remindersEnabled = prefs.getBool('notifications.quota.enabled') ?? true;
    notifyListeners();
  }

  /// Only an opaque digest of the account scope is persisted; no credentials.
  Future<void> selectAccount(String? owner) async {
    final selection = ++_selection;
    final scope = owner == null
        ? ''
        : (await Sha256().hash(
            utf8.encode(owner),
          ))
            .bytes
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
    if (selection != _selection || _scope == scope) return;
    _scope = scope;
    notice = null;
    read = false;
    if (scope.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      if (_scope != scope) return;
      final saved = prefs.getString('notifications.quota.$scope');
      if (saved == 'quotaPaused' ||
          (remindersEnabled &&
              const ['quotaLow', 'quotaEmpty'].contains(saved))) {
        notice = saved;
        read = prefs.getBool('notifications.quota.$scope.read') ?? false;
      }
    }
    notifyListeners();
  }

  Future<void> update(String? next) async {
    if (_scope.isEmpty || next == notice) return;
    notice = next;
    read = false;
    notifyListeners();
    final scope = _scope;
    final prefs = await SharedPreferences.getInstance();
    if (next == null) {
      await prefs.remove('notifications.quota.$scope');
    } else {
      await prefs.setString('notifications.quota.$scope', next);
    }
    await prefs.setBool('notifications.quota.$scope.read', false);
  }

  Future<void> markRead() async {
    read = true;
    notifyListeners();
    final scope = _scope;
    final prefs = await SharedPreferences.getInstance();
    if (scope.isNotEmpty) {
      await prefs.setBool('notifications.quota.$scope.read', true);
    }
  }

  Future<void> setReminders(bool enabled) async {
    remindersEnabled = enabled;
    if (!enabled && notice != 'quotaPaused') await update(null);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notifications.quota.enabled', enabled);
  }

  /// Match machine-readable reasons only, never arbitrary server text or 403.
  static bool isQuotaRejection(String body) {
    try {
      final json = jsonDecode(body);
      if (json is! Map) return false;
      return const [
        'quota_exhausted',
        'traffic_quota_exceeded',
        'quota_exceeded',
      ].contains(json['code'] ?? json['error']);
    } catch (_) {
      return false;
    }
  }
}
