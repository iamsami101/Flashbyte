import 'dart:io';
import 'dart:typed_data';

import 'package:flashbyte_core/adapters/output_target_adapter.dart';
import 'package:flashbyte_core/adapters/file_source_adapter.dart';
import 'package:test/test.dart';

void main() {
  group('OutputTarget.regular', () {
    test('creates file and writes chunks', () async {
      final dir = await Directory.systemTemp.createTemp('ot_test_');
      final filePath = '${dir.path}/output.bin';

      final target = OutputTarget.regular(
        fileName: 'output.bin',
        filePath: filePath,
      );

      expect(target.fileName, 'output.bin');
      expect(target.filePath, filePath);

      target.writeChunk(Uint8List.fromList([1, 2, 3]));
      target.writeChunk(Uint8List.fromList([4, 5]));
      await target.closeWriter();

      final file = await File(filePath).readAsBytes();
      expect(file, [1, 2, 3, 4, 5]);

      await dir.delete(recursive: true);
    });

    test('deleteFile removes the file', () async {
      final dir = await Directory.systemTemp.createTemp('ot_test_');
      final filePath = '${dir.path}/to_delete.bin';

      final target = OutputTarget.regular(
        fileName: 'to_delete.bin',
        filePath: filePath,
      );
      target.writeChunk(Uint8List.fromList([1]));
      await target.closeWriter();
      expect(await File(filePath).exists(), isTrue);

      await target.deleteFile();
      expect(await File(filePath).exists(), isFalse);

      await dir.delete(recursive: true);
    });

    test('onWriteError is called on write failure', () async {
      final errors = <Object>[];
      final target = OutputTarget.regular(
        fileName: 'bad.bin',
        filePath: '/nonexistent/path/bad.bin',
        onWriteError: (e) => errors.add(e),
      );

      target.writeChunk(Uint8List.fromList([1, 2, 3]));
      // Close the sink; the write to a nonexistent path will fail asynchronously.
      try {
        await target.closeWriter();
      } catch (_) {}

      // Give async error time to propagate
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(errors, isNotEmpty);
    });
  });

  group('SendSource', () {
    test('disposes temp copy file', () async {
      final dir = await Directory.systemTemp.createTemp('ss_test_');
      final tempFile = File('${dir.path}/temp.tmp');
      await tempFile.writeAsString('temp data');

      final source = SendSource(
        file: tempFile,
        fileName: 'temp.tmp',
        fileSize: 9,
        tempCopyPath: tempFile.path,
      );

      expect(await tempFile.exists(), isTrue);
      await source.dispose();
      expect(await tempFile.exists(), isFalse);

      await dir.delete(recursive: true);
    });

    test('dispose is safe when no fd or temp copy', () async {
      final dir = await Directory.systemTemp.createTemp('ss_test_');
      final file = File('${dir.path}/file.txt');
      await file.writeAsString('data');

      final source = SendSource(file: file, fileName: 'file.txt', fileSize: 4);

      // Should not throw
      await source.dispose();
      expect(await file.exists(), isTrue);

      await dir.delete(recursive: true);
    });
  });
}
