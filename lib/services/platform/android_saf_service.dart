import 'package:flutter/services.dart';

class AndroidSafOutputFile {
  const AndroidSafOutputFile({
    required this.uri,
    required this.name,
  });

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
      return 'Internal storage';
    }
    if (decoded.startsWith('primary:')) {
      return decoded.replaceFirst('primary:', '');
    }
    return decoded.replaceAll(':', ':/');
  }

  static String trimPathForDisplay(String path) {
    if (isTreeUri(path)) {
      return formatTreeUriForDisplay(path);
    }

    if (path.startsWith('/storage/emulated/0/')) {
      return path.substring('/storage/emulated/0/'.length);
    }

    final homeMatch = RegExp(r'^/home/[^/]+/').firstMatch(path);
    if (homeMatch != null) {
      return path.substring(homeMatch.end);
    }

    return path;
  }

  static Future<AndroidSafOutputFile> importFileToTree({
    required String treeUri,
    required String sourceFilePath,
    required String fileName,
    String mimeType = 'application/octet-stream',
  }) async {
    final response = await _channel.invokeMapMethod<String, dynamic>(
      'importFileToTree',
      {
        'treeUri': treeUri,
        'sourceFilePath': sourceFilePath,
        'fileName': fileName,
        'mimeType': mimeType,
      },
    );

    if (response == null) {
      throw Exception('Could not save the destination file.');
    }

    final uri = response['uri'];
    final name = response['name'];

    if (uri is! String || name is! String) {
      throw Exception('Invalid Android SAF response.');
    }

    return AndroidSafOutputFile(
      uri: uri,
      name: name,
    );
  }
}
