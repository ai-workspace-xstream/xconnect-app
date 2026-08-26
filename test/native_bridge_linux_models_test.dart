import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/utils/native_bridge.dart';

void main() {
  test('LinuxDesktopIntegrationStatus parses bridge payload', () {
    final status = LinuxDesktopIntegrationStatus.fromMap(<String, dynamic>{
      'desktopEnvironment': 'gnome',
      'autostartEnabled': true,
      'privilegeReady': true,
      'message': 'ok',
    });

    expect(status.desktopEnvironment, 'gnome');
    expect(status.autostartEnabled, isTrue);
    expect(status.privilegeReady, isTrue);
    expect(status.message, 'ok');
  });

  test('Linux tray bridge is limited to sessions it can restore', () {
    expect(NativeBridge.supportsLinuxTrayForSessionType('x11'), isTrue);
    expect(NativeBridge.supportsLinuxTrayForSessionType(' X11 '), isTrue);
    expect(NativeBridge.supportsLinuxTrayForSessionType('wayland'), isFalse);
    expect(NativeBridge.supportsLinuxTrayForSessionType(null), isFalse);
  });
}
