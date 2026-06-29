import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flashbyte/classes/file_send_receive.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

typedef IsolateMessage = Map<String, dynamic>;

class SocketService {
  SocketService._privateConstructor();
  static final SocketService instance = SocketService._privateConstructor();

  Isolate? _receiverIsolate;
  SendPort? _toIsolateSendPort;

  ReceivePort? _uiReceivePort = ReceivePort();
  StreamSubscription? _streamSubscription;

  final _messageStreamController = StreamController<IsolateMessage>.broadcast();
  Stream<IsolateMessage> get messageStream => _messageStreamController.stream;

  Future<void> startHost(String host, {int port = 8050, bool useTLS = false}) async {
    await _startIsolate(
      mode: 'host',
      host: host,
      port: port,
      useTLS: useTLS,
    );
  }

  Future<void> connectToHost(String host, {int port = 8050, bool useTLS = false}) async {
    _startIsolate(
      mode: 'client',
      host: host,
      port: port,
      useTLS: useTLS,
    );
  }

  Future<String?> _copyCertToTemp(String fileName) async {
    final certAssetPath = 'assets/certificates/$fileName';
    final certFsPath = 'certificates/$fileName';
    try {
      // Try loading from assets first (works on Android/iOS)
      final data = await rootBundle.load(certAssetPath);
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/$fileName');
      await tempFile.writeAsBytes(data.buffer.asUint8List());
      return tempFile.path;
    } catch (_) {
      // Fallback: try direct filesystem path (works on Linux desktop)
      try {
        final fsFile = File(certFsPath);
        if (await fsFile.exists()) {
          return fsFile.path;
        }
        // Try with full path
        final fullPath = File(certFsPath).absolute.path;
        if (await File(fullPath).exists()) {
          return fullPath;
        }
      } catch (_) {}
      return null;
    }
  }

  Future<Map<String, String?>> _prepareCertFiles() async {
    final certPath = await _copyCertToTemp('server.crt');
    final keyPath = await _copyCertToTemp('server.key');
    return {'certPath': certPath, 'keyPath': keyPath};
  }

  Future<void> _startIsolate({
    required String mode,
    String? host,
    required int port,
    bool useTLS = false,
  }) async {
    stopConnection();

    String? certPath;
    String? keyPath;
    if (useTLS) {
      final paths = await _prepareCertFiles();
      certPath = paths['certPath'];
      keyPath = paths['keyPath'];
    }

    final completer = Completer<SendPort>();

    _uiReceivePort = ReceivePort();
    final RootIsolateToken? rootToken = RootIsolateToken.instance;

    if (rootToken == null) {
      throw Exception('Fatal: RootIsolateToken is null!');
    }

    _streamSubscription = _uiReceivePort!.listen(
      (message) {
        if (message is SendPort) {
          completer.complete(message);
        } else {
          _messageStreamController.add(message as IsolateMessage);
        }
      },
    );

    _receiverIsolate = await Isolate.spawn(
      fileReceiverIsolate,
      [
        _uiReceivePort!.sendPort,
        rootToken,
      ],
    );

    _toIsolateSendPort = await completer.future;

    _toIsolateSendPort!.send({
      'command': 'connect',
      'mode': mode,
      'host': host,
      'port': port,
      'useTLS': useTLS,
      'certPath': certPath,
      'keyPath': keyPath,
    });
  }

  void sendFile(String filePath) {
    if (_toIsolateSendPort == null) {
      print("Cannot send file, no active connection");
      return;
    }

    _toIsolateSendPort!.send({
      'command': 'send_file',
      'filePath': filePath,
    });
  }

  void disconnect() {
    if (_uiReceivePort == null) {
      stopConnection();
      return;
    }
    _toIsolateSendPort!.send({
      'command': 'disconnect',
    });
  }

  void stopConnection() {
    _streamSubscription?.cancel();
    _uiReceivePort?.close();
    _receiverIsolate?.kill(priority: Isolate.immediate);

    _receiverIsolate = null;
    _toIsolateSendPort = null;
    _streamSubscription = null;
    _uiReceivePort = null;
  }
}
