import 'dart:io';

/// Extracts a display-friendly file name from a path or URI.
String displayFileName(String value) {
  var name = value;
  try {
    name = Uri.decodeComponent(name);
  } on FormatException {
    // Use the original value when a provider returns malformed escaping.
  }
  if (name.startsWith('primary:')) {
    name = name.substring('primary:'.length);
  }
  final forwardSlash = name.lastIndexOf('/');
  final backSlash = name.lastIndexOf('\\');
  final separator = forwardSlash > backSlash ? forwardSlash : backSlash;
  return separator == -1 ? name : name.substring(separator + 1);
}

/// Generates a unique file name in [directory] to avoid collisions.
String generateUniqueFileName(String directory, String originalFileName) {
  final originalFile = File("$directory/$originalFileName");
  if (!originalFile.existsSync()) {
    return originalFileName;
  }

  final lastDotIndex = originalFileName.lastIndexOf('.');
  final name = lastDotIndex > 0
      ? originalFileName.substring(0, lastDotIndex)
      : originalFileName;
  final extension = lastDotIndex > 0
      ? originalFileName.substring(lastDotIndex)
      : '';

  int counter = 1;
  while (true) {
    final newFileName = '$name ($counter)$extension';
    final newFile = File("$directory/$newFileName");
    if (!newFile.existsSync()) {
      return newFileName;
    }
    counter++;
  }
}

/// Generates a user-facing error message for a client connection failure.
String clientConnectErrorMessage({
  required Object error,
  required String? host,
  required int? port,
  required bool useTLS,
}) {
  final details = error.toString();
  final endpoint = host == null || port == null
      ? 'the receiver'
      : '$host:$port';

  if (error is SocketException) {
    return 'Could not reach $endpoint. Check that the IP address and port are correct, both devices are on the same network, and the receiver server is running.\n\nDetails: $details';
  }

  if (details.toLowerCase().contains('hostname mismatch')) {
    return 'Could not verify the receiver TLS certificate name. Refresh discovery and try connecting to the receiver again.\n\nDetails: $details';
  }

  return useTLS
      ? 'This device has TLS enabled, but the other device appears to have TLS disabled or an incompatible certificate. Disable TLS on this device, or enable TLS on the other device, then try again.\n\nDetails: $details'
      : 'This device has TLS disabled, but the other device appears to require TLS. Enable TLS on this device, or disable TLS on the other device, then try again.\n\nDetails: $details';
}
