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
  bool _disconnectRequested = false;

  final _messageStreamController = StreamController<IsolateMessage>.broadcast();
  final _connectionStatusController = StreamController<bool>.broadcast();
  final Map<String, IsolateMessage> _transferStartMessages = {};
  final Map<String, IsolateMessage> _transferLatestMessages = {};
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
    _disconnectRequested = false;
    _transferStartMessages.clear();
    _transferLatestMessages.clear();
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

        final typedMessage = message as IsolateMessage;
        final status = typedMessage['status'] ?? typedMessage['command'];
        if (status == 'client_connected' || status == 'connected_to_host') {
          _disconnectRequested = false;
          _setConnectionEstablished(true);
        } else if (status == 'disconnect' || status == 'error') {
          _setConnectionEstablished(false);
        }
        if (status == 'error' && _disconnectRequested) {
          return;
        }
        if (typedMessage['status'] == 'android_saf_finalize') {
          await _finalizeAndroidSafTransfer(typedMessage);
          return;
        }

        _publishMessage(typedMessage);
        if (status == 'disconnect') {
          Future.microtask(stopConnection);
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

  void replayTransferState() {
    for (final entry in _transferStartMessages.entries) {
      _messageStreamController.add(Map<String, dynamic>.from(entry.value));
      final latestMessage = _transferLatestMessages[entry.key];
      if (latestMessage != null) {
        _messageStreamController.add(
          Map<String, dynamic>.from(latestMessage),
        );
      }
    }
  }

  void disconnect() {
    final sendPort = _toIsolateSendPort;
    if (_uiReceivePort == null || sendPort == null) {
      stopConnection();
      return;
    }
    _disconnectRequested = true;
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
    _disconnectRequested = false;
  }

  void _setConnectionEstablished(bool value) {
    if (_hasEstablishedConnection == value) {
      return;
    }

    _hasEstablishedConnection = value;
    _connectionStatusController.add(value);
  }

  void _publishMessage(IsolateMessage message) {
    final status = message['status'] ?? message['command'];
    final fileId = message['fileId'] as String?;
    if (fileId != null) {
      if (status == 'start' || status == 'send_start') {
        _transferStartMessages[fileId] = Map<String, dynamic>.from(message);
        _transferLatestMessages.remove(fileId);
      } else if (status == 'progress' ||
          status == 'send_progress' ||
          status == 'completed' ||
          status == 'send_complete') {
        _transferLatestMessages[fileId] = Map<String, dynamic>.from(message);
      }
    }

    _messageStreamController.add(message);
  }

  Future<void> _finalizeAndroidSafTransfer(IsolateMessage message) async {
    final treeUri = message['treeUri'] as String?;
    final sourceFilePath = message['sourceFilePath'] as String?;
    final fileName = message['fileName'] as String?;

    if (treeUri == null || sourceFilePath == null || fileName == null) {
      _publishMessage({
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

      _publishMessage({
        'status': 'completed',
        'fileId': message['fileId'],
        'timeTaken': message['timeTaken'],
        'fileName': savedFile.name,
        'filePath': savedFile.uri,
      });
    } catch (e) {
      _publishMessage({
        'status': 'error',
        'fatal': false,
        'message':
            'Could not save the received file to the selected folder.\n${e.toString()}',
      });
    }
  }
}
