import 'package:saf/saf.dart';

class AndroidSafService {
  AndroidSafService._();

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

  static Future<SafDocumentFile?> pickDirectory({String? initialUri}) {
    final saf = Saf();
    return saf.pickDirectory(
      initialUri: initialUri,
      writePermission: true,
      persistablePermission: true,
    );
  }
}
