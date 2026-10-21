import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/utils/global_config.dart';

void main() {
  test('Windows config stays user writable with an installed app', () {
    expect(
      GlobalApplicationConfig.windowsDataPathForEnvironment({
        'ProgramFiles': r'C:\Program Files',
        'LOCALAPPDATA': r'C:\Users\Test User\AppData\Local',
      }),
      r'C:\Users\Test User\AppData\Local\XConnect',
    );
  });

  test('Windows config resolves a user profile fallback', () {
    expect(
      GlobalApplicationConfig.windowsDataPathForEnvironment({
        'LOCALAPPDATA': '',
        'USERPROFILE': r'C:\Users\Test User',
      }),
      r'C:\Users\Test User\AppData\Local\XConnect',
    );
    expect(
      () => GlobalApplicationConfig.windowsDataPathForEnvironment({
        'ProgramFiles': r'C:\Program Files',
      }),
      throwsStateError,
    );
  });
}
