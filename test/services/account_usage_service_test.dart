import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:xconnect/services/account_usage_service.dart';

void main() {
  test('loads usage summary from accounts service', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/api/account/usage/summary');
      expect(request.headers['authorization'], 'Bearer session-token');
      return http.Response(
        jsonEncode({
          'accountUuid': 'acct-1',
          'totalBytes': 384,
          'currentBalance': 88.5,
          'syncDelaySeconds': 60,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final service = AccountUsageService(httpClient: client);
    final summary = await service.fetchUsageSummary(
      baseUrl: 'https://accounts.example.com',
      sessionToken: 'session-token',
    );

    expect(summary.accountUuid, 'acct-1');
    expect(summary.totalBytes, 384);
    expect(summary.currentBalance, 88.5);
    expect(summary.syncDelaySeconds, 60);
  });
  test('month usage queries local month start and sums server buckets',
      () async {
    final now = DateTime(2026, 11, 3, 17);
    final client = MockClient((request) async {
      expect(request.url.path, '/api/account/usage/buckets');
      expect(DateTime.parse(request.url.queryParameters['start']!),
          DateTime(2026, 11, 1).toUtc());
      expect(request.headers['authorization'], 'Bearer session-token');
      return http.Response(
          jsonEncode({
            'buckets': [
              {'TotalBytes': 1024},
              {'totalBytes': 256}
            ]
          }),
          200);
    });
    expect(
        await AccountUsageService(httpClient: client).fetchMonthUsage(
          baseUrl: 'https://accounts.example.com',
          sessionToken: 'session-token',
          now: now,
        ),
        1280);
  });

  test('malformed month bucket is reported as unavailable', () async {
    final client =
        MockClient((_) async => http.Response('{"buckets":[{}]}', 200));
    expect(
        AccountUsageService(httpClient: client).fetchMonthUsage(
          baseUrl: 'https://accounts.example.com',
          sessionToken: 'session-token',
        ),
        throwsFormatException);
  });

  test('fetchUsageOverview prefers summary.usedBytes without querying buckets',
      () async {
    final requestedPaths = <String>[];
    final client = MockClient((request) async {
      requestedPaths.add(request.url.path);
      return http.Response(
        jsonEncode({
          'accountUuid': 'acct-1',
          'totalBytes': 9000,
          'usedBytes': 4096,
          'includedQuotaBytes': 10240,
          'currentBalance': 12.5,
          'syncDelaySeconds': 30,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final (summary, used) =
        await AccountUsageService(httpClient: client).fetchUsageOverview(
      baseUrl: 'https://accounts.example.com',
      sessionToken: 'session-token',
    );
    expect(requestedPaths, ['/api/account/usage/summary']);
    expect(used, 4096);
    expect(summary.includedQuotaBytes, 10240);
  });

  test(
      'fetchUsageOverview falls back to summary.totalBytes when usage buckets fail',
      () async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/account/usage/summary') {
        return http.Response(
          jsonEncode({
            'accountUuid': 'acct-1',
            'totalBytes': 2048,
            'currentBalance': 0,
            'syncDelaySeconds': 60,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('gateway timeout', 504);
    });

    final (summary, used) =
        await AccountUsageService(httpClient: client).fetchUsageOverview(
      baseUrl: 'https://accounts.example.com',
      sessionToken: 'session-token',
    );
    expect(summary.totalBytes, 2048);
    expect(used, 2048);
  });
}
