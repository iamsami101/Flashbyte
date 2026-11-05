import 'dart:async';
import 'dart:io';

import 'package:fast_file_picker/fast_file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

/// Receives files and text shared to Flashbyte from other apps (share menu)
/// and exposes them as batches of ready-to-send [FastFilePickerPath]s.
class IncomingShareService {
  IncomingShareService._();

  static final IncomingShareService instance = IncomingShareService._();

  final _controller = StreamController<List<FastFilePickerPath>>.broadcast();
  bool _initialized = false;

  /// Emits one event per share action with only the files from that action.
  Stream<List<FastFilePickerPath>> get sharedFilesStream => _controller.stream;

  bool get _supported => Platform.isAndroid || Platform.isIOS;

  Future<void> init() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    if (!_supported) {
      return;
    }
    try {
      // Subscribe before reading the initial intent so warm shares are never
      // missed. The initial share is only delivered via getInitialMedia.
      ReceiveSharingIntent.instance.getMediaStream().listen(
        (files) => unawaited(_emit(files)),
        onError: (Object _) {},
      );
      final initial = await ReceiveSharingIntent.instance.getInitialMedia();
      await _emit(initial);
      // Consume the initial intent so it is not delivered again.
      await ReceiveSharingIntent.instance.reset();
    } catch (_) {
      // Plugin unavailable; sharing stays disabled on this platform.
    }
  }

  Future<void> _emit(List<SharedMediaFile> files) async {
    final converted = <FastFilePickerPath>[];
    for (final file in files) {
      final path = await _convert(file);
      if (path != null) {
        converted.add(path);
      }
    }
    if (converted.isNotEmpty && !_controller.isClosed) {
      _controller.add(converted);
    }
  }

  Future<FastFilePickerPath?> _convert(SharedMediaFile file) async {
    try {
      switch (file.type) {
        case SharedMediaType.text:
        case SharedMediaType.url:
          return await _textToFile(file.path);
        case SharedMediaType.image:
        case SharedMediaType.video:
        case SharedMediaType.file:
          final path = file.path;
          if (path.isEmpty) return null;
          final io = File(path);
          if (!await io.exists()) return null;
          // Probe readability: some shared content URIs resolve to paths
          // that are inaccessible due to scoped storage.
          final handle = await io.open();
          await handle.close();
          final name = path.split('/').last;
          if (name.isEmpty) return null;
          return FastFilePickerPath.fromPath(name, path);
      }
    } catch (_) {
      return null;
    }
  }

  Future<FastFilePickerPath> _textToFile(String text) async {
    final dir = await getTemporaryDirectory();
    final name = 'Shared text ${DateTime.now().millisecondsSinceEpoch}.txt';
    final file = File('${dir.path}/$name');
    await file.writeAsString(text);
    return FastFilePickerPath.fromPath(name, file.path);
  }
}
