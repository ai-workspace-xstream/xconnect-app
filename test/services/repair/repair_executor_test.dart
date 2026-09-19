import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/services/repair/conflict_scan.dart';
import 'package:xconnect/services/repair/repair_executor.dart';

void main() {
  late List<String> calls;
  late ValueNotifier<String> active;

  OwnTunnelRepair repair() => OwnTunnelRepair(
        activeNode: active,
        stopTunnel: () async => calls.add('stopTunnel'),
        stopNodeService: (n) async => calls.add('stopNodeService:$n'),
        clearOwnProxy: () async => calls.add('clearOwnProxy'),
      );

  setUp(() {
    calls = [];
    active = ValueNotifier<String>('jp');
  });

  test('disconnects the way the home screen does', () async {
    await repair().run(const []);
    expect(calls, ['stopTunnel', 'stopNodeService:jp']);
    expect(active.value, '', reason: 'home screen follows this notifier');
  });

  test('clears the system proxy only when the scan found ours stale', () async {
    await repair().run(const [
      ConflictFinding(kind: FindingKind.staleProxy, subject: '127.0.0.1:1080'),
    ]);
    expect(calls, contains('clearOwnProxy'));

    calls.clear();
    await repair().run(const [
      ConflictFinding(kind: FindingKind.manualDns, subject: 'Wi-Fi'),
    ]);
    expect(calls, isNot(contains('clearOwnProxy')));
  });

  test('with nothing connected it only makes sure the tunnel is down',
      () async {
    active.value = '';
    await repair().run(const []);
    expect(calls, ['stopTunnel']);
  });
}
