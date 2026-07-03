import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flashbyte/classes/android_saf_service.dart';
import 'package:flashbyte/classes/app_settings.dart';
import 'package:flashbyte/classes/file_send_receive.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

typedef IsolateMessage = Map<String, dynamic>;

class SocketService {
  SocketService._privateConstructor();
  static final SocketService instance = SocketService._privateConstructor();

  Isolate? _receiverIsolate;
  SendPort? _toIsolateSendPort;
  String? _currentMode;

  ReceivePort? _uiReceivePort = ReceivePort();
  StreamSubscription? _streamSubscription;

  final _messageStreamController = StreamController<IsolateMessage>.broadcast();
  final _connectionStatusController = StreamController<bool>.broadcast();
  Stream<IsolateMessage> get messageStream => _messageStreamController.stream;
  Stream<bool> get connectionStatusStream => _connectionStatusController.stream;
  bool get isRunning => _receiverIsolate != null;
  bool get isHosting => _receiverIsolate != null && _currentMode == 'host';
  bool get hasEstablishedConnection => _hasEstablishedConnection;

  bool _hasEstablishedConnection = false;

  Future<void> startHost(
    String host, {
    int port = 8050,
    bool useTLS = false,
  }) async {
    await _startIsolate(
      mode: 'host',
      host: host,
      port: port,
      useTLS: useTLS,
    );
  }

  Future<void> connectToHost(
    String host, {
    int port = 8050,
    bool useTLS = false,
  }) async {
    await _startIsolate(
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
    _currentMode = mode;
    _setConnectionEstablished(false);

    String? certPath;
    String? keyPath;
    final downloadDirectory = await AppSettings.getDownloadDirectory();
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
      (message) async {
        if (message is SendPort) {
          completer.complete(message);
          return;
        }

        // Convert List messages (from optimized isolate) to Map for UI compatibility
        final typedMessage = message is List 
            ? _listToMapMessage(message) 
            : message as IsolateMessage;
        final status = typedMessage['status'] ?? typedMessage['command'];
        if (status == 'client_connected' || status == 'connected_to_host') {
          _setConnectionEstablished(true);
        } else if (status == 'disconnect' || status == 'error') {
          _setConnectionEstablished(false);
        }
        if (typedMessage['status'] == 'android_saf_finalize') {
          await _finalizeAndroidSafTransfer(typedMessage);
          return;
        }

        _messageStreamController.add(typedMessage);
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
      'downloadDirectory': downloadDirectory,
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
    final sendPort = _toIsolateSendPort;
    if (_uiReceivePort == null || sendPort == null) {
      stopConnection();
      return;
    }
    _setConnectionEstablished(false);
    try {
      sendPort.send({
        'command': 'disconnect',
      });
    } catch (_) {
      stopConnection();
    }
  }

  void stopConnection() {
    _setConnectionEstablished(false);
    _streamSubscription?.cancel();
    _uiReceivePort?.close();
    _receiverIsolate?.kill(priority: Isolate.immediate);

    _receiverIsolate = null;
    _toIsolateSendPort = null;
    _streamSubscription = null;
    _uiReceivePort = null;
    _currentMode = null;
  }

  void _setConnectionEstablished(bool value) {
    if (_hasEstablishedConnection == value) {
      return;
    }

    _hasEstablishedConnection = value;
    _connectionStatusController.add(value);
  }

  /// Converts optimized List messages from isolate to Map for UI compatibility.
  /// Format: [status, ...args] where args depend on message type.
  IsolateMessage _listToMapMessage(List<dynamic> list) {
    final status = list[0] as String;
    return switch (status) {
      'connected_to_host' => {'status': 'connected_to_host'},
      'client_connected' => {'status': 'client_connected'},
      'disconnect' => {'command': 'disconnect'},
      'error' => {'status': 'error', 'fatal': list[1], 'message': list[2]},
      'progress' => {'status': 'progress', 'fileId': list[1], 'progress': list[2]},
      'start' => {'status': 'start', 'fileId': list[1], 'fileName': list[2], 'filePath': list[3], 'fileSize': list[4]},
      'completed' => {'status': 'completed', 'fileId': list[1], 'timeTaken': list[2], 'fileName': list[5]},
      'android_saf_finalize' => {'status': 'android_saf_finalize', 'fileId': list[1], 'timeTaken': list[2], 'treeUri': list[3], 'sourceFilePath': list[4], 'fileName': list[5]},
      'send_complete' => {'status': 'send_complete', 'fileId': list[1], 'fileName': list[2], 'timeTaken': list[3]},
      'send_progress' => {'status': 'send_progress', 'fileId': list[1], 'progress': list[2]},
      _ => {'status': status},
    };
  }

  Future<void> _finalizeAndroidSafTransfer(IsolateMessage message) async {
    final treeUri = message['treeUri'] as String?;
    final sourceFilePath = message['sourceFilePath'] as String?;
    final fileName = message['fileName'] as String?;

    if (treeUri == null || sourceFilePath == null || fileName == null) {
      _messageStreamController.add({
        'status': 'error',
        'fatal': false,
        'message': 'Could not finalize the received file on Android.',
      });
      return;
    }

    try {
      final savedFile = await AndroidSafService.importFileToTree(
        treeUri: treeUri,
        sourceFilePath: sourceFilePath,
        fileName: fileName,
      );
      await File(sourceFilePath).delete();

      _messageStreamController.add({
        'status': 'completed',
        'fileId': message['fileId'],
        'timeTaken': message['timeTaken'],
        'fileName': savedFile.name,
        'filePath': savedFile.uri,
      });
    } catch (e) {
      _messageStreamController.add({
        'status': 'error',
        'fatal': false,
        'message':
            'Could not save the received file to the selected folder.\n${e.toString()}',
      });
    }
  }
}
