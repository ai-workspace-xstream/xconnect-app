import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/utils/global_config.dart';

void main() {
  test('about identifies a packaged revision instead of a moving branch', () {
    expect(
        formatBuildVersion(
            buildId: '9dde58405a2676ca099f1b9bc8e84426c2aaf927',
            buildDate: '2026-10-22'),
        '9dde584-2026-10-22');
    expect(formatBuildVersion(buildId: 'ABC1234'), 'abc1234');
  });

  test('missing or invalid provenance never claims a release revision', () {
    for (final value in ['', 'latest', 'main', '123', '0000000']) {
      expect(formatBuildVersion(buildId: value), 'dev');
    }
  });
}
