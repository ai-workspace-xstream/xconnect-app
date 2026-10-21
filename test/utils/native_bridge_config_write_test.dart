import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/utils/native_bridge.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('xconnect-write-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  Future<String> write(String nodes) => NativeBridge.writeConfigFiles(
        xrayConfigPath: '${directory.path}/configs/node.json',
        xrayConfigContent: '{}',
        servicePath: '${directory.path}/services/node',
        serviceContent: 'node marker',
        vpnNodesConfigPath: '${directory.path}/vpn_nodes.json',
        vpnNodesConfigContent: nodes,
        password: '',
      );

  test('saving replaces the complete node snapshot without native runtime',
      () async {
    expect(await write('[{"name":"first"}]'), 'success');
    const snapshot = '[{"name":"first"},{"name":"second"}]';
    expect(await write(snapshot), 'success');
    expect(await write(snapshot), 'success');
    expect(await File('${directory.path}/vpn_nodes.json').readAsString(),
        snapshot);
    expect(
        await File('${directory.path}/configs/node.json').readAsString(), '{}');
  });

  test('filesystem errors cannot report success', () async {
    await Directory('${directory.path}/configs/node.json')
        .create(recursive: true);
    expect(await write('[]'), startsWith('写入失败:'));
    expect(await File('${directory.path}/vpn_nodes.json').exists(), isFalse);
  });
}
