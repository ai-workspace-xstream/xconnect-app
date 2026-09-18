import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/utils/settings_tab_navigation.dart';

void main() {
  group('resolveSettingsTabIndex', () {
    test('finds the requested tab by id', () {
      final index = resolveSettingsTabIndex(
        const [
          SettingsTabId.connection,
          SettingsTabId.dns,
          SettingsTabId.diagnostics,
        ],
        SettingsTabId.diagnostics,
      );

      expect(index, 2);
    });

    test('returns null when the platform filtered the tab out', () {
      // iOS drops the DNS tab; a deep link aimed at it must not silently
      // fall back to index 0 (the Connection tab) and pretend it worked.
      final index = resolveSettingsTabIndex(
        const [SettingsTabId.connection, SettingsTabId.diagnostics],
        SettingsTabId.dns,
      );

      expect(index, isNull);
    });

    test('index tracks position, not enum declaration order', () {
      // Diagnostics is declared last in the enum but can render first once
      // every other tab is filtered out on this platform.
      final index = resolveSettingsTabIndex(
        const [SettingsTabId.diagnostics],
        SettingsTabId.diagnostics,
      );

      expect(index, 0);
    });
  });

  group('SettingsTabRequest', () {
    test('defaults autoStart to false', () {
      const request = SettingsTabRequest(id: SettingsTabId.diagnostics);

      expect(request.autoStart, isFalse);
    });

    test('carries an explicit autoStart flag', () {
      const request = SettingsTabRequest(
        id: SettingsTabId.diagnostics,
        autoStart: true,
      );

      expect(request.autoStart, isTrue);
    });
  });
}
