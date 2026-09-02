import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flashbyte/app/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppSettings', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('returns default port 8050 if unconfigured', () async {
      final port = await AppSettings.getPort();
      expect(port, equals(AppSettings.defaultPort));
    });

    test('saves and reads custom port', () async {
      await AppSettings.setPort(9090);
      final port = await AppSettings.getPort();
      expect(port, equals(9090));
    });

    test('returns default TLS setting as true', () async {
      final useTls = await AppSettings.getUseTls();
      expect(useTls, isTrue);
    });
  });
}
