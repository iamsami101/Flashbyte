import 'package:flashbyte_core/identity/device_identity.dart';
import 'package:test/test.dart';

void main() {
  group('generateDeviceName', () {
    test('returns two capitalized words', () {
      final name = generateDeviceName();
      expect(name, matches(RegExp(r'^[A-Z][a-z]+ [A-Z][a-z]+$')));
    });

    test('generates unique names', () {
      final names = List.generate(10, (_) => generateDeviceName());
      // With 200 adjectives and 1000 nouns, the chance of collision in 10 is ~0.05%
      final uniqueNames = names.toSet();
      expect(uniqueNames.length, greaterThan(1));
    });
  });

  group('generateDeviceId', () {
    test('returns UUID v4 format', () {
      final id = generateDeviceId();
      expect(
        id,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
    });

    test('generates unique IDs', () {
      final ids = List.generate(100, (_) => generateDeviceId());
      expect(ids.toSet().length, 100);
    });
  });
}
