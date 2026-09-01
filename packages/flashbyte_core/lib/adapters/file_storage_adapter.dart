import 'dart:typed_data';

/// Adapter for platform-specific file system operations.
///
/// The app implements this with real path_provider / SAF / dart:io calls.
/// The core package uses it without depending on any Flutter plugin.
abstract class FileStorageAdapter {
  Future<String> resolveDownloadDirectory({String? configuredDirectory});

  Future<bool> directoryIsWritable(String directory);

  Future<void> createDirectory(String path);

  /// Returns the temporary directory path (e.g. path_provider getTemporaryDirectory).
  Future<String> getTemporaryDirectory();

  Future<bool> fileExists(String path);

  Future<void> deleteFile(String path);

  Future<void> writeFileBytes(String path, Uint8List bytes);

  Future<Uint8List> readFileBytes(String path);
}
