import 'package:flutter/foundation.dart';

import '../../utils/global_config.dart' show GlobalState;
import '../../utils/native_bridge.dart';
import 'conflict_scan.dart';

/// "修复隧道配置": resets XConnect's own tunnel state and nothing else.
///
/// Disconnects the same way the home screen does, so the home screen follows
/// via [activeNode]. The system proxy is cleared only when the scan showed it
/// pointing at our port with nothing listening — clearing it otherwise could
/// switch off another app's proxy. Reconnecting from the home screen writes
/// the VPN profile afresh.
class OwnTunnelRepair {
  OwnTunnelRepair({
    ValueNotifier<String>? activeNode,
    Future<void> Function()? stopTunnel,
    Future<void> Function(String node)? stopNodeService,
    Future<void> Function()? clearOwnProxy,
  })  : _activeNode = activeNode ?? GlobalState.activeNodeName,
        _stopTunnel = stopTunnel ?? (() => NativeBridge.stopNodeForTunnel()),
        _stopNodeService =
            stopNodeService ?? ((n) => NativeBridge.stopNodeService(n)),
        _clearOwnProxy =
            clearOwnProxy ?? (() => NativeBridge.setSystemProxy(false, ''));

  final ValueNotifier<String> _activeNode;
  final Future<void> Function() _stopTunnel;
  final Future<void> Function(String node) _stopNodeService;
  final Future<void> Function() _clearOwnProxy;

  Future<void> run(List<ConflictFinding> findings) async {
    final node = _activeNode.value;
    await _stopTunnel();
    if (node.isNotEmpty) {
      await _stopNodeService(node);
      _activeNode.value = '';
    }
    if (findings.any((f) => f.kind == FindingKind.staleProxy)) {
      await _clearOwnProxy();
    }
  }
}
