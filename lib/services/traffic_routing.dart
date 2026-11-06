import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum TrafficMode { smart, allVpn }

class TrafficRouting {
  static const _key = 'trafficRoutingMode';
  static final _selected = ValueNotifier(TrafficMode.smart);
  static final _activeMode = ValueNotifier<TrafficMode?>(null);
  static bool _hasSelection = false;

  static TrafficMode? get connectionMode =>
      _hasSelection ? _selected.value : null;
  static ValueListenable<TrafficMode> get selected => _selected;
  static ValueListenable<TrafficMode?> get activeMode => _activeMode;

  static bool get isPendingRestart =>
      _activeMode.value != null && _activeMode.value != _selected.value;

  static void markActiveMode(TrafficMode? mode) {
    _activeMode.value = mode;
  }

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.get(_key);
    _hasSelection =
        stored == TrafficMode.smart.name || stored == TrafficMode.allVpn.name;
    _selected.value = stored == TrafficMode.allVpn.name
        ? TrafficMode.allVpn
        : TrafficMode.smart;
  }

  static Future<bool> select(TrafficMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(_key, mode.name)) return false;
    _hasSelection = true;
    _selected.value = mode;
    return true;
  }
}
