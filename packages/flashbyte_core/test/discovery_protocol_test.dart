import 'dart:io';

import 'package:flashbyte_core/discovery/discovery_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('Discovery protocol constants', () {
    test('protocol identifier', () {
      expect(kDiscoveryProtocol, 'flashbyte-discovery-v1');
    });

    test('broadcast interval is 2 seconds', () {
      expect(kDiscoveryBroadcastInterval, const Duration(seconds: 2));
    });

    test('peer timeout is 20 seconds', () {
      expect(kDiscoveryPeerTimeout, const Duration(seconds: 20));
    });
  });

  group('buildHelloPacket', () {
    test('builds valid hello packet', () {
      final packet = buildHelloPacket(
        instanceId: '12345',
        deviceId: 'abc-123',
        name: 'Test Device',
        port: 8050,
        usesTls: true,
        certificateFingerprint: 'aabb',
        deviceType: 'laptop',
      );
      expect(packet['protocol'], kDiscoveryProtocol);
      expect(packet['action'], 'hello');
      expect(packet['id'], 'abc-123');
      expect(packet['name'], 'Test Device');
      expect(packet['port'], 8050);
      expect(packet['tls'], true);
      expect(packet['certFingerprint'], 'aabb');
      expect(packet['deviceType'], 'laptop');
    });
  });

  group('buildProbePacket', () {
    test('builds valid probe packet', () {
      final packet = buildProbePacket(deviceId: 'test-id');
      expect(packet['protocol'], kDiscoveryProtocol);
      expect(packet['action'], 'probe');
      expect(packet['id'], 'test-id');
    });
  });

  group('buildGoodbyePacket', () {
    test('adds goodbye action to advertisement', () {
      final advertisement = {
        'protocol': kDiscoveryProtocol,
        'action': 'hello',
        'id': 'device-1',
      };
      final goodbye = buildGoodbyePacket(advertisement);
      expect(goodbye['action'], 'goodbye');
      expect(goodbye['id'], 'device-1');
    });
  });

  group('isValidDiscoveryMessage', () {
    test('accepts valid protocol', () {
      expect(isValidDiscoveryMessage({'protocol': kDiscoveryProtocol}), isTrue);
    });

    test('rejects wrong protocol', () {
      expect(isValidDiscoveryMessage({'protocol': 'other'}), isFalse);
    });

    test('rejects missing protocol', () {
      expect(isValidDiscoveryMessage({'action': 'hello'}), isFalse);
    });
  });

  group('isUsableInterface', () {
    test('rejects docker interfaces', () async {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        if (iface.name.toLowerCase().startsWith('docker')) {
          expect(isUsableInterface(iface), isFalse);
        }
      }
    });
  });

  group('broadcastTargetsForAddress', () {
    test('includes limited broadcast', () {
      final address = InternetAddress('192.168.1.100');
      final targets = broadcastTargetsForAddress(address);
      expect(targets.any((t) => t.address == '255.255.255.255'), isTrue);
    });

    test('computes subnet broadcast', () {
      final address = InternetAddress('192.168.1.100');
      final targets = broadcastTargetsForAddress(address);
      expect(targets, isNotEmpty);
    });
  });
}
