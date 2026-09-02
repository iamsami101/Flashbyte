import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flashbyte/services/security/tls_identity_service.dart';

void main() {
  group('TlsIdentityService', () {
    test('computes SHA-256 certificate fingerprint correctly', () {
      final dummyBody = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      final base64Body = base64Encode(dummyBody);
      final pem =
          '-----BEGIN CERTIFICATE-----\n$base64Body\n-----END CERTIFICATE-----';

      final expectedFingerprint = sha256.convert(dummyBody).toString();
      final actualFingerprint = TlsIdentityService.certificateFingerprint(pem);

      expect(actualFingerprint, equals(expectedFingerprint));
    });

    test('handles PEM strings with Windows CRLF newlines', () {
      final dummyBody = Uint8List.fromList([10, 20, 30, 40]);
      final base64Body = base64Encode(dummyBody);
      final pem =
          '-----BEGIN CERTIFICATE-----\r\n$base64Body\r\n-----END CERTIFICATE-----';

      final expectedFingerprint = sha256.convert(dummyBody).toString();
      final actualFingerprint = TlsIdentityService.certificateFingerprint(pem);

      expect(actualFingerprint, equals(expectedFingerprint));
    });
  });
}
