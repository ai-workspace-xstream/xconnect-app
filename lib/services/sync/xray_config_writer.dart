import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import '../../services/vpn_config_service.dart';
import '../../utils/global_config.dart';
import '../../utils/tun_config_guard.dart';

class XrayConfigWriter {
  static const _defaultNodeName = 'Desktop Sync';
  static const _defaultServiceName = 'xconnect.desktop.sync';
  static const _syncServicePrefix = 'xconnect.sync.';
  static const _defaultCountryCode = 'SYNC';

  static Future<String> writeConfig(String json) async {
    final code = _normalizeNodeCode(_defaultCountryCode);
    final fileName = 'node-$code-config.json';
    final path = await GlobalApplicationConfig.getXrayConfigFilePath(fileName);
    final file = File(path);
    await file.create(recursive: true);
    final guarded = guardTunInterfaceFieldsForWrite(json);
    await file.writeAsString(guarded.json);
    return path;
  }

  static Future<String> writeConfigForNode({
    required String json,
    required String nodeName,
    String? countryCode,
    String? nodeId,
  }) async {
    final code = await _nodeCode(
      (countryCode ?? '').trim().isNotEmpty ? countryCode! : nodeName,
      nodeId: nodeId,
    );
    final fileName = 'node-$code-config.json';
    final path = await GlobalApplicationConfig.getXrayConfigFilePath(fileName);
    final file = File(path);
    await file.create(recursive: true);
    final guarded = guardTunInterfaceFieldsForWrite(json);
    await file.writeAsString(guarded.json);
    return path;
  }

  static Future<String> registerNode({
    required String configPath,
    String? nodeName,
    String? countryCode,
    String? protocol,
    String? transport,
    String? security,
    String? nodeId,
  }) async {
    final normalizedName = (nodeName ?? '').trim().isNotEmpty
        ? nodeName!.trim()
        : _defaultNodeName;
    final incomingIdentity = await _readOutboundIdentity(configPath);
    final existingByName = VpnConfig.getNodeByName(normalizedName);
    final serviceName =
        '$_syncServicePrefix${await _nodeCode('node', nodeId: nodeId ?? normalizedName)}';
    final identityMatches = incomingIdentity == null
        ? <VpnNode>[]
        : await _findNodesByIdentity(incomingIdentity);
    final activeNodeName = GlobalState.activeNodeName.value.trim();
    VpnNode? existing = identityMatches.cast<VpnNode?>().firstWhere(
      (node) => (node?.name ?? '') == activeNodeName,
      orElse: () => null,
    );
    existing ??= identityMatches.cast<VpnNode?>().firstWhere(
      (node) => (node?.serviceName ?? '') != _defaultServiceName,
      orElse: () => null,
    );
    existing ??= identityMatches.isNotEmpty ? identityMatches.first : null;
    existing ??= VpnConfig.nodes.cast<VpnNode?>().firstWhere(
      (node) => node?.serviceName == serviceName,
      orElse: () => null,
    );
    existing ??= existingByName;
    final targetNodeName = existing?.name ?? normalizedName;

    if (identityMatches.length > 1 && existing != null) {
      for (final duplicate in identityMatches) {
        if (duplicate.name != existing.name) {
          VpnConfig.removeNode(duplicate.name);
        }
      }
    }

    if (existing == null) {
      final stale = VpnConfig.nodes
          .where(
            (node) =>
                node.serviceName == _defaultServiceName &&
                node.name != targetNodeName,
          )
          .map((node) => node.name)
          .toList();
      for (final name in stale) {
        VpnConfig.removeNode(name);
      }
    }

    final node = VpnNode(
      name: targetNodeName,
      countryCode: _normalizeCountryCode(
        countryCode,
        existing?.countryCode ?? _defaultCountryCode,
      ),
      configPath: configPath,
      serviceName: existing?.serviceName ?? serviceName,
      protocol: _pickValue(protocol, existing?.protocol),
      transport: _pickValue(transport, existing?.transport),
      security: _pickValue(security, existing?.security),
      enabled: existing?.enabled ?? true,
    );
    if (existing == null) {
      VpnConfig.addNode(node);
    } else {
      VpnConfig.updateNode(node);
    }
    await VpnConfig.saveToFile();
    return node.name;
  }

  static Future<void> pruneSyncedNodes(Set<String> retainedNames) async {
    final stale = VpnConfig.nodes
        .where(
          (node) =>
              (node.serviceName == _defaultServiceName ||
                  node.serviceName.startsWith(_syncServicePrefix)) &&
              !retainedNames.contains(node.name),
        )
        .map((node) => node.name)
        .toList();
    for (final name in stale) {
      VpnConfig.removeNode(name);
    }
    if (stale.isNotEmpty) await VpnConfig.saveToFile();
  }

  static Future<String> _nodeCode(String raw, {String? nodeId}) async {
    final prefix = _normalizeNodeCode(raw);
    final digest = await Sha256().hash(utf8.encode(nodeId ?? raw));
    final suffix = digest.bytes
        .take(6)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return '$prefix-$suffix';
  }

  static String _normalizeCountryCode(String? value, String fallback) {
    final raw = (value ?? '').trim();
    if (raw.isEmpty) return fallback;
    if (raw.length > 12) return raw.substring(0, 12).toUpperCase();
    return raw.toUpperCase();
  }

  static String _pickValue(String? preferred, String? fallback) {
    final primary = (preferred ?? '').trim();
    if (primary.isNotEmpty) return primary.toLowerCase();
    final secondary = (fallback ?? '').trim();
    if (secondary.isNotEmpty) return secondary.toLowerCase();
    return '';
  }

  static String _normalizeNodeCode(String raw) {
    final lower = raw.trim().toLowerCase();
    final normalized = lower.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    final compact = normalized.replaceAll(RegExp(r'-+'), '-');
    final trimmed = compact.replaceAll(RegExp(r'^-+|-+$'), '');
    if (trimmed.isEmpty) return 'node';
    if (trimmed.length > 24) return trimmed.substring(0, 24);
    return trimmed;
  }

  static Future<List<VpnNode>> _findNodesByIdentity(String identity) async {
    final matches = <VpnNode>[];
    for (final node in VpnConfig.nodes) {
      final nodeIdentity = await _readOutboundIdentity(node.configPath);
      if (nodeIdentity == identity) {
        matches.add(node);
      }
    }
    return matches;
  }

  static Future<String?> _readOutboundIdentity(String configPath) async {
    try {
      final raw = await File(configPath).readAsString();
      return extractOutboundIdentity(raw);
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static String? extractOutboundIdentity(String rawJson) {
    try {
      final obj = jsonDecode(rawJson);
      if (obj is! Map) return null;
      final outboundsRaw = obj['outbounds'];
      if (outboundsRaw is! List) return null;
      Map<dynamic, dynamic>? proxyOutbound;
      for (final outbound in outboundsRaw) {
        if (outbound is! Map) continue;
        if ((outbound['tag'] as String?) == 'proxy') {
          proxyOutbound = outbound;
          break;
        }
      }
      if (proxyOutbound == null) return null;

      final protocol = ((proxyOutbound['protocol'] as String?) ?? '')
          .trim()
          .toLowerCase();
      if (protocol.isEmpty) return null;

      final settings = proxyOutbound['settings'];
      if (settings is! Map) return null;
      final vnext = settings['vnext'];
      if (vnext is! List || vnext.isEmpty || vnext.first is! Map) return null;
      final first = vnext.first as Map;

      final address = ((first['address'] as String?) ?? '')
          .trim()
          .toLowerCase();
      final port = (first['port'] as num?)?.toInt();
      if (address.isEmpty || port == null) return null;

      String userId = '';
      final users = first['users'];
      if (users is List && users.isNotEmpty && users.first is Map) {
        userId = (((users.first as Map)['id'] as String?) ?? '')
            .trim()
            .toLowerCase();
      }

      String network = '';
      String security = '';
      String sni = '';
      final streamSettings = proxyOutbound['streamSettings'];
      if (streamSettings is Map) {
        network = ((streamSettings['network'] as String?) ?? '')
            .trim()
            .toLowerCase();
        security = ((streamSettings['security'] as String?) ?? '')
            .trim()
            .toLowerCase();

        final tlsSettings = streamSettings['tlsSettings'];
        if (tlsSettings is Map) {
          sni = ((tlsSettings['serverName'] as String?) ?? '')
              .trim()
              .toLowerCase();
        }
        if (sni.isEmpty) {
          final realitySettings = streamSettings['realitySettings'];
          if (realitySettings is Map) {
            sni = ((realitySettings['serverName'] as String?) ?? '')
                .trim()
                .toLowerCase();
          }
        }
      }

      return [
        protocol,
        address,
        '$port',
        userId,
        network,
        security,
        sni,
      ].join('|');
    } catch (_) {
      return null;
    }
  }
}
