import 'package:test/test.dart';

import '../lib/xconnect_one_bridge.dart';

void main() {
  test('requires absolute executable and state paths', () {
    expect(
      () => XConnectOneBridge(
        executablePath: 'xconnect',
        stateDirectory: '/tmp/xconnect-one',
      ),
      throwsA(isA<XConnectOneBridgeException>()),
    );
    expect(
      () => XConnectOneBridge(
        executablePath: '/usr/local/bin/xconnect',
        stateDirectory: 'relative-state',
      ),
      throwsA(isA<XConnectOneBridgeException>()),
    );
  });

  test('rejects an empty invite without starting a process', () {
    final bridge = XConnectOneBridge(
      executablePath: '/usr/local/bin/xconnect',
      stateDirectory: '/tmp/xconnect-one',
    );
    expect(
      () => bridge.join(invite: ' '),
      throwsA(isA<XConnectOneBridgeException>()),
    );
  });
}
