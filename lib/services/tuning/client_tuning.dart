import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Transport knobs the control plane may tune for this client. Every value is
/// checked against a fixed range and everything else in the payload is
/// ignored, so a tuning response can never add outbounds or redirect traffic.
@immutable
class ClientTuningValues {
  const ClientTuningValues({
    this.xhttpMode,
    this.xmuxMaxConcurrency,
    this.xmuxHMaxRequestTimes,
    this.xmuxHMaxReusableSecs,
    this.scMaxEachPostBytes,
    this.scMinPostsIntervalMs,
    this.dohTimeoutMs,
    this.dnsParallelQuery,
    this.goMemoryLimitMB,
    this.goGCPercent,
  });

  static const allowedXhttpModes = <String>['auto', 'stream-up'];

  final String? xhttpMode;
  // Xray range values, normalized to "n" or "a-b".
  final String? xmuxMaxConcurrency;
  final String? xmuxHMaxRequestTimes;
  final String? xmuxHMaxReusableSecs;
  final String? scMaxEachPostBytes;
  final String? scMinPostsIntervalMs;
  final int? dohTimeoutMs;
  final bool? dnsParallelQuery;

  /// Go runtime soft memory limit for the Apple Packet Tunnel, in MiB; 0
  /// removes it. It caps only the Go heap, not the extension's footprint,
  /// which iOS limits far below the upper bound.
  final int? goMemoryLimitMB;

  /// Go GC target percentage for the Apple Packet Tunnel.
  final int? goGCPercent;

  factory ClientTuningValues.fromJson(Object? raw) {
    if (raw is! Map) return const ClientTuningValues();
    final xhttp = raw['xhttp'] is Map ? raw['xhttp'] as Map : const {};
    final dns = raw['dns'] is Map ? raw['dns'] as Map : const {};
    final tunnel = raw['tunnel'] is Map ? raw['tunnel'] as Map : const {};
    final memoryLimit = tunnel['goMemoryLimitMB'];
    final mode = xhttp['mode'];
    final normalizedMode = mode is String ? mode.trim().toLowerCase() : null;
    final parallel = dns['parallelQuery'];
    return ClientTuningValues(
      xhttpMode:
          allowedXhttpModes.contains(normalizedMode) ? normalizedMode : null,
      xmuxMaxConcurrency: _range(xhttp['xmuxMaxConcurrency'], 1, 128),
      xmuxHMaxRequestTimes: _range(xhttp['xmuxHMaxRequestTimes'], 1, 10000),
      xmuxHMaxReusableSecs: _range(xhttp['xmuxHMaxReusableSecs'], 1, 86400),
      scMaxEachPostBytes:
          _range(xhttp['scMaxEachPostBytes'], 64 * 1024, 4 * 1024 * 1024),
      scMinPostsIntervalMs: _range(xhttp['scMinPostsIntervalMs'], 1, 1000),
      dohTimeoutMs: _integer(dns['dohTimeoutMs'], 500, 8000),
      dnsParallelQuery: parallel is bool ? parallel : null,
      goMemoryLimitMB: memoryLimit == 0 ? 0 : _integer(memoryLimit, 32, 256),
      goGCPercent: _integer(tunnel['goGCPercent'], 20, 200),
    );
  }

  Map<String, dynamic> toJson() {
    final xhttp = <String, dynamic>{
      if (xhttpMode != null) 'mode': xhttpMode,
      if (xmuxMaxConcurrency != null) 'xmuxMaxConcurrency': xmuxMaxConcurrency,
      if (xmuxHMaxRequestTimes != null)
        'xmuxHMaxRequestTimes': xmuxHMaxRequestTimes,
      if (xmuxHMaxReusableSecs != null)
        'xmuxHMaxReusableSecs': xmuxHMaxReusableSecs,
      if (scMaxEachPostBytes != null) 'scMaxEachPostBytes': scMaxEachPostBytes,
      if (scMinPostsIntervalMs != null)
        'scMinPostsIntervalMs': scMinPostsIntervalMs,
    };
    final dns = <String, dynamic>{
      if (dohTimeoutMs != null) 'dohTimeoutMs': dohTimeoutMs,
      if (dnsParallelQuery != null) 'parallelQuery': dnsParallelQuery,
    };
    final tunnel = <String, dynamic>{
      if (goMemoryLimitMB != null) 'goMemoryLimitMB': goMemoryLimitMB,
      if (goGCPercent != null) 'goGCPercent': goGCPercent,
    };
    return <String, dynamic>{
      if (xhttp.isNotEmpty) 'xhttp': xhttp,
      if (dns.isNotEmpty) 'dns': dns,
      if (tunnel.isNotEmpty) 'tunnel': tunnel,
    };
  }

  /// Fields set in [other] replace this profile's values.
  ClientTuningValues overlay(ClientTuningValues? other) {
    if (other == null) return this;
    return ClientTuningValues(
      xhttpMode: other.xhttpMode ?? xhttpMode,
      xmuxMaxConcurrency: other.xmuxMaxConcurrency ?? xmuxMaxConcurrency,
      xmuxHMaxRequestTimes: other.xmuxHMaxRequestTimes ?? xmuxHMaxRequestTimes,
      xmuxHMaxReusableSecs: other.xmuxHMaxReusableSecs ?? xmuxHMaxReusableSecs,
      scMaxEachPostBytes: other.scMaxEachPostBytes ?? scMaxEachPostBytes,
      scMinPostsIntervalMs: other.scMinPostsIntervalMs ?? scMinPostsIntervalMs,
      dohTimeoutMs: other.dohTimeoutMs ?? dohTimeoutMs,
      dnsParallelQuery: other.dnsParallelQuery ?? dnsParallelQuery,
      goMemoryLimitMB: other.goMemoryLimitMB ?? goMemoryLimitMB,
      goGCPercent: other.goGCPercent ?? goGCPercent,
    );
  }

  static int? _integer(Object? raw, int min, int max) {
    final value = raw is int ? raw : null;
    if (value == null || value < min || value > max) return null;
    return value;
  }

  static String? _range(Object? raw, int min, int max) {
    int? from;
    int? to;
    if (raw is int) {
      from = to = raw;
    } else if (raw is String) {
      final match = RegExp(r'^\s*(\d+)(?:-(\d+))?\s*$').firstMatch(raw);
      if (match == null) return null;
      from = int.tryParse(match.group(1)!);
      to = int.tryParse(match.group(2) ?? match.group(1)!);
    }
    if (from == null || to == null) return null;
    final lower = from < to ? from : to;
    final upper = from < to ? to : from;
    if (lower < min || upper > max) return null;
    return lower == upper ? '$lower' : '$lower-$upper';
  }
}

/// Version 1 of the tuning document served by the control plane. Values are
/// resolved as defaults, then the current platform, then the node.
@immutable
class ClientTuningProfile {
  const ClientTuningProfile({
    required this.revision,
    this.defaults = const ClientTuningValues(),
    this.platforms = const <String, ClientTuningValues>{},
    this.nodes = const <String, ClientTuningValues>{},
  });

  final String revision;
  final ClientTuningValues defaults;
  final Map<String, ClientTuningValues> platforms;
  final Map<String, ClientTuningValues> nodes;

  static ClientTuningProfile? fromJson(Object? decoded) {
    if (decoded is! Map || decoded['version'] != 1) return null;
    Map<String, ClientTuningValues> section(Object? raw) => raw is Map
        ? <String, ClientTuningValues>{
            for (final entry in raw.entries)
              if (entry.key is String && entry.value is Map)
                entry.key as String: ClientTuningValues.fromJson(entry.value),
          }
        : const <String, ClientTuningValues>{};
    final revision = decoded['revision'];
    return ClientTuningProfile(
      revision: revision is String ? revision : '',
      defaults: ClientTuningValues.fromJson(decoded['defaults']),
      platforms: section(decoded['platforms']),
      nodes: section(decoded['nodes']),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': 1,
        'revision': revision,
        'defaults': defaults.toJson(),
        'platforms': {
          for (final entry in platforms.entries) entry.key: entry.value.toJson()
        },
        'nodes': {
          for (final entry in nodes.entries) entry.key: entry.value.toJson()
        },
      };

  ClientTuningValues resolve({required String platform, String? nodeId}) =>
      defaults
          .overlay(platforms[platform])
          .overlay(nodeId == null ? null : nodes[nodeId]);
}

/// The response belongs to a session that has since ended or been cleared.
class ClientTuningStaleException implements Exception {
  const ClientTuningStaleException();

  @override
  String toString() => 'Client tuning response belongs to a stale session';
}

/// Last known good tuning from the control plane. It is fetched after each
/// successful node sync and applied when a profile is prepared for connect.
class ClientTuning {
  ClientTuning._();

  static const endpointPath = '/api/agent-server/v1/client-tuning';
  static const _prefsKey = 'clientTuning.v1';

  static ClientTuningProfile? _profile;
  static ClientTuningProfile? get profile => _profile;

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return;
    try {
      _profile = ClientTuningProfile.fromJson(jsonDecode(raw));
    } on FormatException {
      _profile = null;
    }
  }

  static ClientTuningValues effective({String? nodeId}) =>
      _profile?.resolve(platform: Platform.operatingSystem, nodeId: nodeId) ??
      const ClientTuningValues();

  /// Bumped by [clear] so that a request started before it can never write.
  static int _generation = 0;

  /// Returns the applied revision, or null when the server has no tuning. A
  /// 404 drops the cached profile so the built-in defaults apply again; any
  /// other failure throws and keeps the last known good profile.
  ///
  /// [isCurrent] reports whether the session that started the request is
  /// still active. It is checked, together with [clear], before the memory
  /// cache and again before the persisted copy is written; a response from a
  /// stale session throws [ClientTuningStaleException] and changes nothing.
  static Future<String?> refresh(
    http.Client client,
    Uri endpoint,
    Map<String, String> headers, {
    bool Function()? isCurrent,
  }) async {
    final generation = _generation;
    bool stale() =>
        generation != _generation || (isCurrent != null && !isCurrent());

    final response = await client
        .get(endpoint, headers: headers)
        .timeout(const Duration(seconds: 15));
    if (stale()) throw const ClientTuningStaleException();
    if (response.statusCode == 404) {
      if (!await _store(null, stale)) {
        throw const ClientTuningStaleException();
      }
      return null;
    }
    if (response.statusCode != 200) {
      throw http.ClientException(
        'Client tuning returned ${response.statusCode}',
        endpoint,
      );
    }
    final profile = ClientTuningProfile.fromJson(jsonDecode(response.body));
    if (profile == null) {
      throw const FormatException('Unsupported client tuning document');
    }
    if (!await _store(profile, stale)) {
      throw const ClientTuningStaleException();
    }
    return profile.revision;
  }

  /// Drops the profile and invalidates every request still in flight.
  static Future<void> clear() async {
    final generation = ++_generation;
    await _store(null, () => generation != _generation);
  }

  /// Writes both copies unless [stale]. The last check and the memory write
  /// share one synchronous step, so a clear or sign-out can only land before
  /// it (nothing is written) or after it (the clear wins both copies).
  static Future<bool> _store(
    ClientTuningProfile? profile,
    bool Function() stale,
  ) async {
    if (stale()) return false;
    final prefs = await SharedPreferences.getInstance();
    if (stale()) return false;
    _profile = profile;
    if (profile == null) {
      await prefs.remove(_prefsKey);
    } else {
      await prefs.setString(_prefsKey, jsonEncode(profile.toJson()));
    }
    return true;
  }

  @visibleForTesting
  static set profileForTesting(ClientTuningProfile? profile) =>
      _profile = profile;
}
