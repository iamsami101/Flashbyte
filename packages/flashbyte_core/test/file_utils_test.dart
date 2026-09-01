import 'dart:io';

import 'package:flashbyte_core/utils/file_utils.dart';
import 'package:test/test.dart';

void main() {
  group('displayFileName', () {
    test('extracts filename from Unix path', () {
      expect(displayFileName('/home/user/file.txt'), 'file.txt');
    });

    test('extracts filename from Windows path', () {
      expect(displayFileName('C:\\Users\\file.txt'), 'file.txt');
    });

    test('decodes URL-encoded names', () {
      expect(displayFileName('my%20file.txt'), 'my file.txt');
    });

    test('handles primary: prefix from SAF', () {
      expect(displayFileName('primary:DCIM/photo.jpg'), 'photo.jpg');
    });

    test('returns plain name when no separator', () {
      expect(displayFileName('file.txt'), 'file.txt');
    });
  });

  group('generateUniqueFileName', () {
    late Directory tmpDir;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('flashbyte_test_');
    });

    tearDown(() async {
      if (await tmpDir.exists()) {
        await tmpDir.delete(recursive: true);
      }
    });

    test('returns original when file does not exist', () {
      final result = generateUniqueFileName(tmpDir.path, 'new_file.txt');
      expect(result, 'new_file.txt');
    });

    test('appends counter when file exists', () async {
      final existing = File('${tmpDir.path}/photo.jpg');
      await existing.writeAsString('data');
      final result = generateUniqueFileName(tmpDir.path, 'photo.jpg');
      expect(result, 'photo (1).jpg');
    });

    test('increments counter for multiple collisions', () async {
      await File('${tmpDir.path}/doc.pdf').writeAsString('a');
      await File('${tmpDir.path}/doc (1).pdf').writeAsString('b');
      final result = generateUniqueFileName(tmpDir.path, 'doc.pdf');
      expect(result, 'doc (2).pdf');
    });
  });

  group('clientConnectErrorMessage', () {
    test('formats SocketException', () {
      final msg = clientConnectErrorMessage(
        error: SocketException('Connection refused'),
        host: '192.168.1.1',
        port: 8050,
        useTLS: false,
      );
      expect(msg, contains('192.168.1.1:8050'));
      expect(msg, contains('Connection refused'));
    });

    test('formats hostname mismatch', () {
      final msg = clientConnectErrorMessage(
        error: Exception('Hostname mismatch'),
        host: null,
        port: null,
        useTLS: true,
      );
      expect(msg, contains('TLS certificate name'));
    });

    test('formats TLS mismatch', () {
      final msg = clientConnectErrorMessage(
        error: Exception('Some TLS error'),
        host: '10.0.0.1',
        port: 8050,
        useTLS: true,
      );
      expect(msg, contains('TLS enabled'));
    });
  });
}
