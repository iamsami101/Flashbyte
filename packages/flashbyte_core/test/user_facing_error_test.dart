import 'dart:io';

import 'package:flashbyte_core/models/user_facing_error.dart';
import 'package:test/test.dart';

void main() {
  group('UserFacingError', () {
    test('maps connection refused', () {
      final error = UserFacingError.from(SocketException('Connection refused'));
      expect(error.message, contains('Could not reach'));
    });

    test('maps TLS mismatch', () {
      final error = UserFacingError.from(
        Exception('tls enabled but peer has tls disabled'),
      );
      expect(error.message, contains('TLS settings do not match'));
    });

    test('maps permission denied', () {
      final error = UserFacingError.from(
        FileSystemException('Permission denied'),
      );
      expect(error.message, contains('Permission was denied'));
    });

    test('passes through unknown errors', () {
      final error = UserFacingError.from('some random error');
      expect(error.message, 'some random error');
      expect(error.hasDetails, isTrue);
    });

    test('splits details on double newline', () {
      final error = UserFacingError.from('Summary\n\nDetails: extra info');
      expect(error.message, 'Summary');
      expect(error.details, 'extra info');
      expect(error.hasDetails, isTrue);
    });

    test('null error returns generic message', () {
      final error = UserFacingError.from(null);
      expect(error.message, contains('Unknown error'));
    });
  });
}
