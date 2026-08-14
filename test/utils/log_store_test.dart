import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/utils/log_store.dart';
import 'package:xconnect/widgets/log_console.dart';

void main() {
  setUp(LogStore.clear);

  group('LogStore', () {
    test('keeps a bounded tail instead of growing for the whole session', () {
      for (var i = 0; i < LogStore.maxEntries * 3; i++) {
        LogStore.addLog(LogLevel.info, 'line $i');
      }

      final logs = LogStore.getAll();
      expect(logs.length, LogStore.maxEntries);
    });

    test('drops the oldest lines first, so the newest are the ones kept', () {
      for (var i = 0; i < LogStore.maxEntries + 5; i++) {
        LogStore.addLog(LogLevel.info, 'line $i');
      }

      final logs = LogStore.getAll();
      expect(logs.first.message, 'line 5');
      expect(logs.last.message, 'line ${LogStore.maxEntries + 4}');
    });

    test('bounds entries added through add() as well', () {
      for (var i = 0; i < LogStore.maxEntries + 10; i++) {
        LogStore.add(LogEntry(LogLevel.error, 'entry $i'));
      }

      expect(LogStore.getAll().length, LogStore.maxEntries);
    });
  });
}
