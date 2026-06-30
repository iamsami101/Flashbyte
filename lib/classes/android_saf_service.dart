import 'package:flutter/services.dart';

class AndroidSafOutputFile {
  const AndroidSafOutputFile({
    required this.fileDescriptor,
    required this.uri,
    required this.name,
  });

  final int fileDescriptor;
  final String uri;
  final String name;
}

class AndroidSafService {
  AndroidSafService._();

  static const MethodChannel _channel = MethodChannel('flashbyte/android_saf');

  static bool isTreeUri(String value) => value.startsWith('content://');

  static String formatTreeUriForDisplay(String uri) {
    final treeMatch = RegExp(r'tree/([^/?]+)').firstMatch(uri);
    if (treeMatch == null) {
      return uri;
    }

    final decoded = Uri.decodeComponent(treeMatch.group(1)!);
    if (decoded == 'primary:') {
      return '/storage/emulated/0';
    }
    if (decoded.startsWith('primary:')) {
      return decoded.replaceFirst('primary:', '/storage/emulated/0/');
    }
    return decoded.replaceAll(':', ':/');
  }

  static Future<AndroidSafOutputFile> createOutputFile({
    required String treeUri,
    required String fileName,
    String mimeType = 'application/octet-stream',
  }) async {
    final response = await _channel.invokeMapMethod<String, dynamic>(
      'createOutputFile',
      {
        'treeUri': treeUri,
        'fileName': fileName,
        'mimeType': mimeType,
      },
    );

    if (response == null) {
      throw Exception('Could not create the destination file.');
    }

    final fileDescriptor = response['fd'];
    final uri = response['uri'];
    final name = response['name'];

    if (fileDescriptor is! int || uri is! String || name is! String) {
      throw Exception('Invalid Android SAF response.');
    }

    return AndroidSafOutputFile(
      fileDescriptor: fileDescriptor,
      uri: uri,
      name: name,
    );
  }

  static Future<void> closeOutputFile(int fileDescriptor) {
    return _channel.invokeMethod<void>(
      'closeOutputFile',
      {'fd': fileDescriptor},
    );
  }
}
