import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/services/diagnostics/live_diagnosis_controller.dart';
import 'package:xconnect/services/diagnostics/live_metrics.dart';

class _Calls {
  final probes = <({String host, int port, String? source})>[];
}

LiveDiagnosisController _controller(
  _Calls calls, {
  ProbeSample Function(String host, String? source)? answer,
  String? physical = '192.168.0.107',
  ServerEndpoint? endpoint = (host: 'node.example', port: 443),
  DateTime Function()? now,
}) {
  return LiveDiagnosisController(
    endpoint: () async => (name: 'jp', endpoint: endpoint),
    physicalAddress: () async => physical,
    networkType: () async => DiagNetworkType.wifi,
    probe: (host, port, {sourceAddress}) async {
      calls.probes.add((host: host, port: port, source: sourceAddress));
      return (answer ??
          (_, __) => const ProbeSample.reached(Duration(milliseconds: 80)))(
        host,
        sourceAddress,
      );
    },
    now: now ?? DateTime.now,
    startTimer: false,
  );
}

void main() {
  test('the node probe is bound to the physical interface', () async {
    final calls = _Calls();
    final c = _controller(calls);
    await c.start();

    final nodeProbes = calls.probes.where((p) => p.host == 'node.example');
    expect(nodeProbes, isNotEmpty);
    expect(nodeProbes.every((p) => p.source == '192.168.0.107'), isTrue);
    c.dispose();
  });

  test('an unbound canary that connects flags a tunnel conflict', () async {
    final calls = _Calls();
    final c = _controller(
      calls,
      answer: (host, source) => const ProbeSample.reached(Duration.zero),
    );
    await c.start();

    final canary = calls.probes.singleWhere((p) => p.host == '192.0.2.1');
    expect(canary.source, isNull);
    expect(c.snapshot.tunConflict, isTrue);
    expect(c.snapshot.verdict, LiveVerdict.tunConflict);
    c.dispose();
  });

  test('a canary that times out means no conflict', () async {
    final calls = _Calls();
    final c = _controller(
      calls,
      answer: (host, source) => host == '192.0.2.1'
          ? const ProbeSample.timedOut()
          : const ProbeSample.reached(Duration(milliseconds: 80)),
    );
    await c.start();
    expect(c.snapshot.tunConflict, isFalse);
    c.dispose();
  });

  test('each tick feeds one sample into the window', () async {
    final calls = _Calls();
    final c = _controller(calls);
    await c.start();
    for (var i = 0; i < 5; i++) {
      await c.tick();
    }
    expect(c.snapshot.stats.sampleCount, 6);
    expect(c.snapshot.stats.latencyMs, 80);
    expect(c.snapshot.networkType, DiagNetworkType.wifi);
    c.dispose();
  });

  test('no node configured reports that instead of probing', () async {
    final calls = _Calls();
    final c = _controller(calls, endpoint: null);
    await c.start();
    expect(c.snapshot.noEndpoint, isTrue);
    expect(calls.probes.where((p) => p.host != '192.0.2.1'), isEmpty);
    c.dispose();
  });

  test('stops by itself after five minutes', () async {
    var clock = DateTime(2026, 9, 19, 12);
    final calls = _Calls();
    final c = _controller(calls, now: () => clock);
    await c.start();
    clock = clock.add(const Duration(minutes: 5, seconds: 1));
    await c.tick();
    expect(c.snapshot.running, isFalse);
    expect(c.snapshot.autoStopped, isTrue);
    c.dispose();
  });

  test('stop keeps the last results but ends the session', () async {
    final calls = _Calls();
    final c = _controller(calls);
    await c.start();
    c.stop();
    expect(c.snapshot.running, isFalse);
    expect(c.snapshot.stats.sampleCount, 1);
    c.dispose();
  });
}
