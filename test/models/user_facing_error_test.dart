import 'package:flutter_test/flutter_test.dart';
import 'package:flashbyte/models/user_facing_error.dart';

void main() {
  group('UserFacingError', () {
    test('maps connection cancelled error to friendly message', () {
      final error = UserFacingError.from('Socket startup was cancelled');
      expect(error.message, contains('Connection setup was interrupted'));
    });

    test('maps disconnected error to friendly message', () {
      final error = UserFacingError.from('Connection reset by peer');
      expect(
        error.message,
        contains('disconnected before the transfer finished'),
      );
    });

    test('maps unreachable network host error to friendly message', () {
      final error = UserFacingError.from(
        'SocketException: No route to host (errno = 113)',
      );
      expect(error.message, contains('Could not reach the receiver'));
    });

    test('retains raw details for unknown exceptions', () {
      final rawErr = 'Custom test error payload';
      final error = UserFacingError.from(rawErr);
      expect(error.hasDetails, isTrue);
      expect(error.details, contains('Custom test error payload'));
    });
  });
}
