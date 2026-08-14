import '../widgets/log_console.dart';

/// In-memory tail of the app log.
///
/// Deliberately bounded: this buffer exists so the log console has something to
/// render on open, not to be the record of the session. The durable record is
/// the on-disk log (`AppLogFile`), so holding more than a screenful here only
/// costs memory — and on iOS the Packet Tunnel makes the app long-lived, so an
/// unbounded list grows for as long as the user stays connected.
class LogStore {
  /// Roughly a few screens of scrollback.
  static const maxEntries = 300;

  static final List<LogEntry> _logs = [];

  /// 原始添加方式（内部用）
  static void add(LogEntry entry) {
    _logs.add(entry);
    _trim();
  }

  /// ✅ 新增封装方法：统一外部调用日志
  static void addLog(LogLevel level, String message) {
    _logs.add(LogEntry(level, message));
    _trim();
  }

  static void clear() {
    _logs.clear();
  }

  static List<LogEntry> getAll() => List.unmodifiable(_logs);

  static void _trim() {
    final overflow = _logs.length - maxEntries;
    if (overflow > 0) {
      _logs.removeRange(0, overflow);
    }
  }
}
