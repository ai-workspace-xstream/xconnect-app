import 'package:shared_preferences/shared_preferences.dart';

/// Server authority for managed connections. A cached dedicated mode never
/// becomes personal merely because login or policy refresh fails.
class NetworkAccessPolicy {
  NetworkAccessPolicy._();
  static final instance = NetworkAccessPolicy._();

  bool dedicated = false;
  bool authenticated = false;
  bool pending = false;
  bool allowed = false;
  String owner = '';
  String teamId = '';
  String teamName = '';
  DateTime? validUntil;
  Set<String> authorizedNodeIds = {};

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    dedicated = prefs.getBool('network.dedicated') ?? false;
    allowed = false;
    authorizedNodeIds = {};
  }

  void invalidate({required bool signedIn}) {
    authenticated = signedIn;
    pending = signedIn;
    allowed = false;
    authorizedNodeIds = {};
  }

  Future<void> apply(Map<String, dynamic> access, String accountOwner) async {
    if (access['mode'] != 'personal' && access['mode'] != 'dedicated') {
      throw const FormatException('Invalid network access mode');
    }
    final nextDedicated = access['mode'] == 'dedicated';
    final nextTeam = access['teamId'] as String? ?? '';
    final sameScope = owner == accountOwner &&
        dedicated == nextDedicated &&
        teamId == nextTeam &&
        active;
    dedicated = nextDedicated;
    owner = accountOwner;
    teamId = access['teamId'] as String? ?? '';
    final team = access['team'];
    teamName = team is Map ? team['name'] as String? ?? '' : '';
    validUntil = team is Map
        ? DateTime.tryParse(team['validUntil'] as String? ?? '')
        : null;
    allowed = access['allowed'] == true;
    pending = !sameScope; // publish a new scope only after its snapshot applies
    if (!sameScope) authorizedNodeIds = {};
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('network.dedicated', dedicated);
  }

  bool get active =>
      authenticated &&
      !pending &&
      allowed &&
      (validUntil == null || DateTime.now().isBefore(validUntil!));

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
