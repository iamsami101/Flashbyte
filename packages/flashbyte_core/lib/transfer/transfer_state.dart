/// Transfer exception thrown when a transfer is cancelled by the user.
class TransferCancelled implements Exception {
  const TransferCancelled();
}

/// State machine for tracking the progress of a single file transfer.
class TransferState {
  TransferState({
    required this.fileId,
    required this.fileName,
    required this.fileSize,
    required this.filePath,
    this.isIncoming = false,
  });

  final String fileId;
  final String fileName;
  final int fileSize;
  final String filePath;
  final bool isIncoming;

  int bytesTransferred = 0;
  bool isPaused = false;
  bool isCancelled = false;

  double get progress =>
      fileSize <= 0 ? 1.0 : (bytesTransferred / fileSize).clamp(0.0, 1.0);

  bool get isComplete => bytesTransferred >= fileSize;
}
