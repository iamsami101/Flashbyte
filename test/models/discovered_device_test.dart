import 'package:flutter_test/flutter_test.dart';
import 'package:flashbyte/models/discovered_device.dart';

void main() {
  group('DiscoveredDevice Model', () {
    test('creates DiscoveredDevice with valid attributes', () {
      const device = DiscoveredDevice(
        id: 'test-uuid-1234',
        name: 'Brave-Falcon',
        address: '192.168.1.50',
        port: 8050,
        usesTls: true,
        type: DiscoveredDeviceType.laptop,
        certificateFingerprint: 'a1b2c3d4e5f6',
        certificatePem:
            '-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----',
      );

      expect(device.id, equals('test-uuid-1234'));
      expect(device.name, equals('Brave-Falcon'));
      expect(device.address, equals('192.168.1.50'));
      expect(device.port, equals(8050));
      expect(device.usesTls, isTrue);
      expect(device.type, equals(DiscoveredDeviceType.laptop));
      expect(device.certificateFingerprint, equals('a1b2c3d4e5f6'));
      expect(device.certificatePem, contains('BEGIN CERTIFICATE'));
    });

    test('supports phone device type', () {
      const phoneDevice = DiscoveredDevice(
        id: 'phone-001',
        name: 'Swift-Phone',
        address: '192.168.1.100',
        port: 8050,
        usesTls: false,
        type: DiscoveredDeviceType.phone,
      );

      expect(phoneDevice.type, equals(DiscoveredDeviceType.phone));
      expect(phoneDevice.usesTls, isFalse);
      expect(phoneDevice.certificateFingerprint, isNull);
    });
  });
}
