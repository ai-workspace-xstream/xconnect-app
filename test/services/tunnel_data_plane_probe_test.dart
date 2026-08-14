import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/services/tunnel_data_plane_probe.dart';
import 'package:xconnect/utils/app_log_file.dart';

/// Drives the probe with a virtual clock so retry behaviour is tested without
/// real waiting.
class _FakeClock {
  DateTime _now = DateTime(2026, 1, 1);
  final List<Duration> slept = <Duration>[];

  DateTime now() => _now;

  Future<void> sleep(Duration duration) async {
    slept.add(duration);
    _now = _now.add(duration);
  }

  /// Advance without recording a sleep, to model time spent inside a call.
  void advance(Duration duration) => _now = _now.add(duration);
}

InternetAddress _address(String value) => InternetAddress(value);

void main() {
  setUpAll(() => AppLogFile.enabled = false);

  group('TunnelDataPlaneProbe', () {
    test('waits out the settle delay before the first attempt', () async {
      final clock = _FakeClock();
      var resolveCalls = 0;

      final probe = TunnelDataPlaneProbe(
        readTunnelState: () async => 'connected',
        settleDelay: const Duration(milliseconds: 400),
        resolveHost: (host, timeout) async {
          resolveCalls++;
          return <InternetAddress>[_address('104.16.0.1')];
        },
        probeTransport: (host, port, timeout) async {},
        sleep: clock.sleep,
        now: clock.now,
      );

      final report = await probe.run();

      expect(report.ok, isTrue);
      expect(resolveCalls, 1);
      expect(clock.slept.first, const Duration(milliseconds: 400));
    });

    test('recovers when DNS only settles after the first attempts', () async {
      final clock = _FakeClock();
      var resolveCalls = 0;

      final probe = TunnelDataPlaneProbe(
        readTunnelState: () async => 'connected',
        resolveHost: (host, timeout) async {
          resolveCalls++;
          if (resolveCalls < 3) {
            throw const SocketException(
              "Failed host lookup: 'www.cloudflare.com'",
            );
          }
          return <InternetAddress>[_address('104.16.0.1')];
        },
        probeTransport: (host, port, timeout) async {},
        sleep: clock.sleep,
        now: clock.now,
      );

      final report = await probe.run();

      expect(report.ok, isTrue);
      expect(report.outcome, TunnelDataPlaneOutcome.reachable);
      expect(report.attempts, 3);
    });

    test('reports dnsUnreachable when routing works but names never resolve',
        () async {
      final clock = _FakeClock();

      final probe = TunnelDataPlaneProbe(
        readTunnelState: () async => 'connected',
        budget: const Duration(seconds: 3),
        resolveHost: (host, timeout) async {
          throw const SocketException('Failed host lookup');
        },
        probeTransport: (host, port, timeout) async {
          // Raw IP fallback succeeds: packets route, the resolver is the fault.
        },
        sleep: clock.sleep,
        now: clock.now,
      );

      final report = await probe.run();

      expect(report.ok, isFalse);
      expect(report.outcome, TunnelDataPlaneOutcome.dnsUnreachable);
      expect(report.isConclusiveFailure, isTrue);
      expect(report.attempts, greaterThan(1));
    });

    test('reports transportUnreachable when nothing routes', () async {
      final clock = _FakeClock();

      final probe = TunnelDataPlaneProbe(
        readTunnelState: () async => 'connected',
        budget: const Duration(seconds: 3),
        resolveHost: (host, timeout) async {
          throw const SocketException('Failed host lookup');
        },
        probeTransport: (host, port, timeout) async {
          throw const SocketException('No route to host');
        },
        sleep: clock.sleep,
        now: clock.now,
      );

      final report = await probe.run();

      expect(report.outcome, TunnelDataPlaneOutcome.transportUnreachable);
      expect(report.isConclusiveFailure, isTrue);
      expect(report.transportError, isNotNull);
    });

    test('a tunnel that drops mid-probe is inconclusive, not a failure',
        () async {
      final clock = _FakeClock();
      var stateReads = 0;

      final probe = TunnelDataPlaneProbe(
        readTunnelState: () async {
          stateReads++;
          return stateReads > 1 ? 'disconnected' : 'connected';
        },
        resolveHost: (host, timeout) async {
          throw const SocketException('Failed host lookup');
        },
        probeTransport: (host, port, timeout) async {
          throw const SocketException('No route to host');
        },
        sleep: clock.sleep,
        now: clock.now,
      );

      final report = await probe.run();

      expect(report.outcome, TunnelDataPlaneOutcome.tunnelDropped);
      expect(report.isConclusiveFailure, isFalse);
      expect(report.tunnelState, 'disconnected');
    });

    test('a failing status read does not by itself fail the probe', () async {
      final clock = _FakeClock();

      final probe = TunnelDataPlaneProbe(
        readTunnelState: () async => throw StateError('channel unavailable'),
        resolveHost: (host, timeout) async =>
            <InternetAddress>[_address('104.16.0.1')],
        probeTransport: (host, port, timeout) async {},
        sleep: clock.sleep,
        now: clock.now,
      );

      final report = await probe.run();

      expect(report.ok, isTrue);
    });

    test('never overruns the budget, even when every call burns its timeout',
        () async {
      final clock = _FakeClock();

      final probe = TunnelDataPlaneProbe(
        readTunnelState: () async => 'connected',
        budget: const Duration(seconds: 12),
        // Model a weak link: each call consumes its full timeout before
        // failing. Before the deadline clamp this overran the budget by
        // seconds, matching the 17.2s/16.1s seen on device against a 12s
        // budget.
        resolveHost: (host, timeout) async {
          clock.advance(timeout);
          throw const SocketException('Failed host lookup');
        },
        probeTransport: (host, port, timeout) async {
          clock.advance(timeout);
          throw const SocketException(
            'Connection failed (OS Error: No route to host, errno = 65)',
          );
        },
        sleep: clock.sleep,
        now: clock.now,
      );

      final report = await probe.run();

      expect(report.outcome, TunnelDataPlaneOutcome.transportUnreachable);
      expect(report.elapsed, lessThanOrEqualTo(const Duration(seconds: 12)));
    });

    test('backs off so a long budget buys waiting, not more attempts',
        () async {
      final clock = _FakeClock();

      final probe = TunnelDataPlaneProbe(
        readTunnelState: () async => 'connected',
        budget: const Duration(seconds: 20),
        // An unreachable route fails instantly, which is what let the field
        // run burn 19 attempts in 16s.
        resolveHost: (host, timeout) async {
          throw const SocketException('Failed host lookup');
        },
        probeTransport: (host, port, timeout) async {
          throw const SocketException('No route to host');
        },
        sleep: clock.sleep,
        now: clock.now,
      );

      final report = await probe.run();

      expect(report.elapsed, lessThanOrEqualTo(const Duration(seconds: 20)));
      expect(report.attempts, lessThan(15));
      expect(clock.slept.last, greaterThan(clock.slept[1]));
    });

    test('an app suspended mid-probe is inconclusive, not a failure', () async {
      final clock = _FakeClock();
      var attempts = 0;

      final probe = TunnelDataPlaneProbe(
        readTunnelState: () async => 'connected',
        budget: const Duration(seconds: 12),
        resolveHost: (host, timeout) async {
          attempts++;
          // iOS suspends the app after a few quick attempts: wall-clock time
          // races ahead while the probe makes no progress. This is the
          // "221.9s, 3 attempts against a 12s budget" field report.
          if (attempts == 3) {
            clock.advance(const Duration(seconds: 218));
          }
          throw const SocketException('Failed host lookup');
        },
        probeTransport: (host, port, timeout) async {
          throw const SocketException(
            'Connection failed (OS Error: No route to host, errno = 65)',
          );
        },
        sleep: clock.sleep,
        now: clock.now,
      );

      final report = await probe.run();

      expect(report.outcome, TunnelDataPlaneOutcome.suspended);
      expect(report.isConclusiveFailure, isFalse);
      expect(report.attempts, 3);
    });

    test('a merely slow run is still judged, not written off as suspended',
        () async {
      final clock = _FakeClock();

      final probe = TunnelDataPlaneProbe(
        readTunnelState: () async => 'connected',
        budget: const Duration(seconds: 12),
        // Every call burns its full timeout: slow, but legitimately spent.
        resolveHost: (host, timeout) async {
          clock.advance(timeout);
          throw const SocketException('Failed host lookup');
        },
        probeTransport: (host, port, timeout) async {
          clock.advance(timeout);
          throw const SocketException('No route to host');
        },
        sleep: clock.sleep,
        now: clock.now,
      );

      final report = await probe.run();

      expect(report.outcome, TunnelDataPlaneOutcome.transportUnreachable);
      expect(report.isConclusiveFailure, isTrue);
    });

    test('stops retrying at the budget instead of running forever', () async {
      final clock = _FakeClock();
      var attempts = 0;

      final probe = TunnelDataPlaneProbe(
        readTunnelState: () async => 'connected',
        budget: const Duration(seconds: 6),
        retryInterval: const Duration(seconds: 1),
        resolveHost: (host, timeout) async {
          attempts++;
          throw const SocketException('Failed host lookup');
        },
        probeTransport: (host, port, timeout) async {
          throw const SocketException('No route to host');
        },
        sleep: clock.sleep,
        now: clock.now,
      );

      final report = await probe.run();

      expect(attempts, lessThanOrEqualTo(7));
      expect(report.elapsed.inSeconds, lessThanOrEqualTo(6));
    });

    test('rotates DNS hosts so one poisoned name cannot fail the probe',
        () async {
      final clock = _FakeClock();
      final probed = <String>[];

      final probe = TunnelDataPlaneProbe(
        readTunnelState: () async => 'connected',
        dnsHosts: const <String>['a.example', 'b.example'],
        resolveHost: (host, timeout) async {
          probed.add(host);
          if (host == 'a.example') {
            throw const SocketException('Failed host lookup');
          }
          return <InternetAddress>[_address('104.16.0.1')];
        },
        probeTransport: (host, port, timeout) async {},
        sleep: clock.sleep,
        now: clock.now,
      );

      final report = await probe.run();

      expect(report.ok, isTrue);
      expect(probed, <String>['a.example', 'b.example']);
    });
  });
}
