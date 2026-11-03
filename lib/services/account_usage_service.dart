import 'dart:convert';

import 'package:http/http.dart' as http;

class AccountUsageSummary {
  const AccountUsageSummary({
    required this.accountUuid,
    required this.totalBytes,
    required this.currentBalance,
    required this.syncDelaySeconds,
    this.usedBytes,
    this.includedQuotaBytes,
  });

  final String accountUuid;
  final int totalBytes;
  final double currentBalance;
  final int syncDelaySeconds;
  final int? usedBytes;
  final int? includedQuotaBytes;

  factory AccountUsageSummary.fromJson(Map<String, dynamic> json) {
    return AccountUsageSummary(
      accountUuid: json['accountUuid'] as String? ?? '',
      totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
      currentBalance: (json['currentBalance'] as num?)?.toDouble() ?? 0,
      syncDelaySeconds: (json['syncDelaySeconds'] as num?)?.toInt() ?? 0,
      usedBytes: (json['usedBytes'] as num?)?.toInt(),
      includedQuotaBytes: (json['includedQuotaBytes'] as num?)?.toInt() ??
          ((json['billingProfile'] is Map
                  ? (json['billingProfile']['includedQuotaBytes'] ??
                      json['billingProfile']['IncludedQuotaBytes'])
                  : null) as num?)
              ?.toInt(),
    );
  }
}

class AccountUsageService {
  AccountUsageService({http.Client? httpClient})
      : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;

  Future<int> fetchMonthUsage({
    required String baseUrl,
    required String sessionToken,
    String? cookie,
    DateTime? now,
  }) async {
    final localNow = (now ?? DateTime.now()).toLocal();
    final monthStart = DateTime(localNow.year, localNow.month).toUtc();
    final uri = Uri.parse(
      '${baseUrl.replaceAll(RegExp(r'/$'), '')}/api/account/usage/buckets',
    ).replace(queryParameters: {'start': monthStart.toIso8601String()});
    final response = await _httpClient.get(uri, headers: {
      'Accept': 'application/json',
      if (sessionToken.isNotEmpty) 'Authorization': 'Bearer $sessionToken',
      if (cookie != null && cookie.isNotEmpty) 'Cookie': cookie,
    }).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw StateError('usage buckets request failed (${response.statusCode})');
    }
    final payload = jsonDecode(response.body);
    if (payload is! Map ||
        (payload['buckets'] != null && payload['buckets'] is! List)) {
      throw const FormatException('Invalid usage buckets');
    }
    final buckets = payload['buckets'] as List? ?? const [];
    var total = 0;
    for (final bucket in buckets) {
      if (bucket is! Map) throw const FormatException('Invalid usage bucket');
      final bytes = bucket['totalBytes'] ?? bucket['TotalBytes'];
      if (bytes is! num || bytes < 0) {
        throw const FormatException('Invalid usage bucket total');
      }
      total += bytes.toInt();
    }
    return total;
  }

  Future<AccountUsageSummary> fetchUsageSummary({
    required String baseUrl,
    required String sessionToken,
    String? cookie,
  }) async {
    final response = await _httpClient.get(
      Uri.parse(
          '${baseUrl.replaceAll(RegExp(r'/$'), '')}/api/account/usage/summary'),
      headers: {
        'Accept': 'application/json',
        if (sessionToken.isNotEmpty) 'Authorization': 'Bearer $sessionToken',
        if (cookie != null && cookie.isNotEmpty) 'Cookie': cookie,
      },
    ).timeout(const Duration(seconds: 20));

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      throw StateError(payload['message'] as String? ??
          payload['error'] as String? ??
          'usage summary request failed');
    }

    return AccountUsageSummary.fromJson(payload);
  }
}
