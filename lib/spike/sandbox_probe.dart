// R0 spike only (issue #89 M0 / #88 R0). Not for merge into main.
//
// Built with --dart-define=XCONNECT_SANDBOX_PROBE=true, the app runs every
// check below once after the first frame, writes the results as JSON to its
// Application Support directory (inside the container when sandboxed), and
// exits. Every check is read-only or confined to a throwaway file it deletes.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

const bool kSandboxProbe = bool.fromEnvironment('XCONNECT_SANDBOX_PROBE');

const _native = MethodChannel('plus.svc.xconnect/native');

Future<Map<String, Object?>> _run(Future<Object?> Function() body) async {
  try {
    final value = await body().timeout(const Duration(seconds: 8));
    return {'ok': true, 'detail': value};
  } catch (e) {
    return {'ok': false, 'error': e.toString()};
  }
}

String _clip(Object? v, [int max = 300]) {
  final s = v?.toString() ?? '';
  return s.length <= max ? s : '${s.substring(0, max)}…';
}

Future<Object?> _proc(String exe, List<String> args) async {
  final r = await Process.run(exe, args);
  if (r.exitCode != 0) {
    throw 'exit=${r.exitCode} stderr=${_clip(r.stderr, 200)}';
  }
  return _clip(r.stdout);
}

Future<void> runSandboxProbe() async {
  final env = Platform.environment;
  final user = env['USER'] ?? '';
  final realHome = '/Users/$user';
  final results = <String, Object?>{
    'timestamp': DateTime.now().toIso8601String(),
    'sandboxContainerId': env['APP_SANDBOX_CONTAINER_ID'],
    'homeEnv': env['HOME'],
  };

  final checks = <String, Future<Object?> Function()>{
    // Process spawning — used by the permission guide and system proxy.
    'P1 scutil --dns': () => _proc('/usr/sbin/scutil', ['--dns']),
    'P2 scutil --nc list': () => _proc('/usr/sbin/scutil', ['--nc', 'list']),
    'P3 scutil --proxy': () => _proc('/usr/sbin/scutil', ['--proxy']),
    'P4 networksetup -listallnetworkservices': () =>
        _proc('/usr/sbin/networksetup', ['-listallnetworkservices']),
    'P5 networksetup -getdnsservers Wi-Fi': () =>
        _proc('/usr/sbin/networksetup', ['-getdnsservers', 'Wi-Fi']),
    'P6 id -u': () => _proc('/usr/bin/id', ['-u']),
    'P7 launchctl print gui/<uid>': () async {
      final uid = (await Process.run('/usr/bin/id', ['-u'])).stdout.toString();
      return _proc('/bin/launchctl', ['print', 'gui/${uid.trim()}']);
    },
    'P8 bash -c echo': () => _proc('/bin/bash', ['-c', 'echo ok']),
    // File access outside the container.
    'F1 read /etc/hosts': () async =>
        _clip(await File('/etc/hosts').readAsString()),
    'F2 list /Library/LaunchDaemons': () async =>
        (await Directory('/Library/LaunchDaemons').list().length).toString(),
    'F3 write ~/Library/LaunchAgents': () async {
      final f = File('$realHome/Library/LaunchAgents/.xconnect-sandbox-probe');
      await f.writeAsString('probe');
      await f.delete();
      return 'wrote+deleted ${f.path}';
    },
    'F4 read legacy log ~/Library/Caches/plus.svc.xconnect': () async =>
        (await File('$realHome/Library/Caches/plus.svc.xconnect/logs/app.log')
                .length())
            .toString(),
    'F5 write Application Support (container)': () async {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}/.probe-write');
      await f.writeAsString('probe');
      await f.delete();
      return dir.path;
    },
    // Network — diagnosis probes, local proxy listener, core download host.
    'N1 TCP connect 1.1.1.1:443': () async {
      final sw = Stopwatch()..start();
      final s = await Socket.connect('1.1.1.1', 443,
          timeout: const Duration(seconds: 3));
      s.destroy();
      return '${sw.elapsedMilliseconds}ms';
    },
    'N2 listen 127.0.0.1:0': () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();
      return 'port=$port';
    },
    'N3 HTTPS HEAD github.com': () async {
      final client = HttpClient();
      final req = await client.headUrl(Uri.parse('https://github.com/'));
      final res = await req.close();
      await res.drain<void>();
      client.close();
      return 'status=${res.statusCode}';
    },
    'N4 DNS lookup jp-xconnect.svc.plus': () async =>
        (await InternetAddress.lookup('jp-xconnect.svc.plus'))
            .map((a) => a.address)
            .join(','),
    // Native SystemConfiguration / sysctl reads (S2).
    'S2 native SystemConfiguration': () =>
        _native.invokeMethod<Object?>('sandboxProbe'),
  };

  for (final entry in checks.entries) {
    results[entry.key] = await _run(entry.value);
  }

  // Also printed: a sandboxed app's container is unreadable from outside
  // (App Data protection), so stdout is how the runner collects results.
  final json = const JsonEncoder.withIndent('  ').convert(results);
  final dir = await getApplicationSupportDirectory();
  await File('${dir.path}/sandbox_probe.json').writeAsString(json);
  stdout.writeln('SANDBOX_PROBE_BEGIN');
  stdout.writeln(json);
  stdout.writeln('SANDBOX_PROBE_END');
  await stdout.flush();
  exit(0);
}
