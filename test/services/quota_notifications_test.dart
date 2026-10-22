import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xconnect/services/notifications/quota_notifications.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('strict threshold, zero, unlimited and unknown are distinct', () {
    expect(const QuotaSnapshot(remaining: 9, total: 100).notice, 'quotaLow');
    expect(const QuotaSnapshot(remaining: 10, total: 100).notice, isNull);
    expect(const QuotaSnapshot(remaining: 0, total: 100).notice, 'quotaEmpty');
    expect(
        const QuotaSnapshot(remaining: 0, total: 100, unlimited: true).notice,
        isNull);
    expect(const QuotaSnapshot(remaining: 0).notice, isNull);
    expect(const QuotaSnapshot(remaining: -1, total: 100).notice, isNull);
    expect(const QuotaSnapshot(remaining: 0, total: 0).notice, isNull);
    expect(
        QuotaSnapshot.fromJson({'totalBytes': 100, 'currentBalance': 0}).notice,
        isNull);
    expect(
        QuotaSnapshot.fromJson({
          'remainingIncludedQuota': 9,
          'billingProfile': {'IncludedQuotaBytes': 100}
        }).notice,
        'quotaLow');
  });

  test('current server contract honors unlimited overrides and pause reasons',
      () {
    const payload = {'remainingIncludedQuota': 9, 'includedQuotaBytes': 100};
    expect(QuotaSnapshot.fromJson(payload).notice, 'quotaLow');
    expect(
        QuotaSnapshot.fromJson({
          'networkAccessState': 'paused',
          'networkAccessReason': 'quota_exhausted'
        }).notice,
        'quotaPaused');
    expect(
        QuotaSnapshot.fromJson({...payload, 'temporaryUnlimited': true}).notice,
        isNull);
    expect(
        QuotaSnapshot.fromJson({
          ...payload,
          'currentPlan': {'unlimited': true}
        }).notice,
        isNull);
    expect(
        QuotaSnapshot.fromJson({
          ...payload,
          'networkAccessState': 'paused',
          'networkAccessReason': 'quota_exhausted'
        }).notice,
        'quotaPaused');
    expect(
        QuotaSnapshot.fromJson({
          'networkAccessState': 'paused',
          'networkAccessReason': 'operator_paused'
        }).notice,
        isNull);
  });

  test('read state survives restart, repeats deduplicate, recovery rearms',
      () async {
    final store = QuotaNotifications();
    await store.selectAccount('server|account-a');
    await store.update('quotaLow');
    expect(store.hasUnread, isTrue);
    await store.markRead();
    await store.update('quotaLow');
    expect(store.hasUnread, isFalse);
    final restored = QuotaNotifications();
    await restored.selectAccount('server|account-a');
    expect(restored.notice, 'quotaLow');
    expect(restored.hasUnread, isFalse);
    await restored.update(null);
    await restored.update('quotaLow');
    expect(restored.hasUnread, isTrue);
    await restored.selectAccount('server|account-b');
    expect(restored.notice, isNull);
    await restored.selectAccount(null);
    expect(restored.hasUnread, isFalse);
  });

  test('preferences persist and never hide a quota suspension', () async {
    final store = QuotaNotifications();
    await store.selectAccount('a');
    await store.update('quotaLow');
    await store.setReminders(false);
    expect(store.notice, isNull);
    await store.update('quotaPaused');
    await store.setReminders(false);
    expect(store.notice, 'quotaPaused');
    final restored = QuotaNotifications();
    await restored.init();
    expect(restored.remindersEnabled, isFalse);
  });

  test('only structured quota errors classify as exhaustion', () {
    expect(QuotaNotifications.isQuotaRejection('{"error":"quota_exhausted"}'),
        isTrue);
    expect(
        QuotaNotifications.isQuotaRejection('{"error":"forbidden"}'), isFalse);
    expect(QuotaNotifications.isQuotaRejection('quota_exhausted'), isFalse);
  });
}
