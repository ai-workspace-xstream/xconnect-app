import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Mirrors app logs to a bounded file inside the app sandbox.
///
/// The in-app console keeps logs in memory only, which makes a field problem on
/// a physical device unreproducible after the fact: the evidence dies with the
/// process, and an attached debug session is not always available (LLDB cannot
/// attach on every iOS build). Persisting a bounded tail lets a log be pulled
/// off the device after the fact, and lets the in-memory buffers stay small.
///
/// Stored under the app's cache directory (`Library/Caches` on Apple
/// platforms), per Apple's iOS Data Storage Guidelines: logs are regenerable
/// diagnostic data, so they must not sit in a backed-up location such as
/// `Documents` or `Application Support`. `Library/Caches` is excluded from
/// backup and may be purged by the system under disk pressure, which is the
/// correct trade-off for this data.
///
/// Best-effort by construction: every failure is swallowed, and writes are
/// serialised through a single queue so logging can never reorder, block, or
/// break the caller.
class AppLogFile {
  AppLogFile._();

  static const fileName = 'app.log';
  static const previousFileName = 'app.log.1';
  static const maxBytes = 512 * 1024;

  static Future<void> _queue = Future<void>.value();
  static Directory? _cachedDirectory;

  /// Disabled in tests and on hosts without an app sandbox, so unit tests do
  /// not touch the filesystem.
  static bool enabled = true;

  static void append(String level, String message) {
    if (!enabled) return;
    final line = '${DateTime.now().toIso8601String()} [$level] $message\n';
    _queue = _queue.then((_) => _write(line)).catchError((_) {});
  }

  static Future<void> _write(String line) async {
    try {
      final directory = await _logsDirectory();
      if (directory == null) return;
      final file = File('${directory.path}/$fileName');
      if (await file.exists() && await file.length() >= maxBytes) {
        // Keep one generation so a rotation mid-incident does not discard the
        // lines that led up to it.
        try {
          await file.rename('${directory.path}/$previousFileName');
        } catch (_) {
          await file.writeAsString('');
        }
      }
      await file.writeAsString(line, mode: FileMode.append, flush: false);
    } catch (_) {
      // Logging must never affect app behaviour.
    }
  }

  static Future<Directory?> _logsDirectory() async {
    final cached = _cachedDirectory;
    if (cached != null) return cached;
    try {
      final base = await getApplicationCacheDirectory();
      final directory = Directory('${base.path}/logs');
      await directory.create(recursive: true);
      _cachedDirectory = directory;
      return directory;
    } catch (_) {
      return null;
    }
  }

  /// Flushes pending writes; used before reading the file back.
  static Future<void> flush() => _queue;
}
