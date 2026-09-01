import 'dart:io';

/// A readable source file for an outgoing transfer plus any resources that
/// must be released once the transfer finishes.
class SendSource {
  const SendSource({
    required this.file,
    required this.fileName,
    required this.fileSize,
    this.fd,
    this.tempCopyPath,
  });

  final File file;
  final String fileName;
  final int fileSize;
  final int? fd;
  final String? tempCopyPath;

  Future<void> dispose() async {
    final fd = this.fd;
    if (fd != null) {
      try {
        await closeFileDescriptor(fd);
      } on Exception catch (_) {}
    }
    final tempCopyPath = this.tempCopyPath;
    if (tempCopyPath != null) {
      try {
        final copy = File(tempCopyPath);
        if (await copy.exists()) {
          await copy.delete();
        }
      } on Exception catch (_) {}
    }
  }

  /// Platform adapter hook: close a file descriptor (Android SAF).
  /// Overridden by the app's platform-specific implementation.
  Future<void> closeFileDescriptor(int fd) async {}
}

/// Adapter for opening file sources (platform-specific, e.g. Android SAF).
abstract class FileSourceAdapter {
  Future<SendSource?> openSendSource(String filePath);
}
