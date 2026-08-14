import 'package:flutter/foundation.dart';

import '../widgets/log_console.dart';
import 'app_log_file.dart';
import 'log_store.dart';
import 'global_config.dart';

/// Helper for logging messages from anywhere in the app.
void addAppLog(String message, {LogLevel level = LogLevel.info}) {
  // Persist before dispatching: the console keeps logs in memory only, so
  // without this a problem reported from a physical device leaves no evidence
  // once the app is closed.
  AppLogFile.append(level.name, message);

  // App logs otherwise live only inside the in-app console, which makes an
  // attached debug session blind to them -- on a physical device that is the
  // only way to watch the connection flow as it happens. The assert body is
  // stripped from release builds, so this costs shipped users nothing.
  assert(() {
    debugPrint('[applog:${level.name}] $message');
    return true;
  }());

  final console = logConsoleKey.currentState;
  if (console != null) {
    console.addLog(message, level: level);
  } else {
    LogStore.addLog(level, message);
  }
}
