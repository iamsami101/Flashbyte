import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// A writable target for an incoming file transfer.
class OutputTarget {
  OutputTarget._({
    required this.fileName,
    required this.filePath,
    required this.writeChunk,
    required this.closeWriter,
    required this.deleteFile,
  });

  /// Creates an [OutputTarget] with custom handlers (e.g. for SAF streaming).
  factory OutputTarget.custom({
    required String fileName,
    required String filePath,
    required void Function(Uint8List) writeChunk,
    required Future<void> Function() closeWriter,
    required Future<void> Function() deleteFile,
  }) {
    return OutputTarget._(
      fileName: fileName,
      filePath: filePath,
      writeChunk: writeChunk,
      closeWriter: closeWriter,
      deleteFile: deleteFile,
    );
  }

  factory OutputTarget.regular({
    required String fileName,
    required String filePath,
    void Function(Object error)? onWriteError,
  }) {
    final file = File(filePath);
    final sink = file.openWrite();
    if (onWriteError != null) {
      sink.done.then((_) {}, onError: onWriteError);
    }
    return OutputTarget._(
      fileName: fileName,
      filePath: filePath,
      writeChunk: (data) => sink.add(data),
      closeWriter: () => sink.close(),
      deleteFile: () async {
        await sink.close();
        try {
          if (await file.exists()) {
            await file.delete();
          }
        } catch (_) {}
      },
    );
  }

  final String fileName;
  final String filePath;
  final void Function(Uint8List) writeChunk;
  final Future<void> Function() closeWriter;
  final Future<void> Function() deleteFile;
}

/// Adapter for creating output targets (platform-specific, e.g. SAF streaming).
abstract class OutputTargetAdapter {
  Future<OutputTarget> createOutputTarget({
    required String? configuredDownloadDirectory,
    required String originalFileName,
    void Function(Object error)? onWriteError,
  });
}
