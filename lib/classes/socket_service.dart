import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:flashbyte/classes/file_send_receive.dart';

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

  Future<void> startHost(String host, {int port = 8050}) async {
    await _startIsolate(
      mode: 'host',
      host: host,
      port: port,
    );
  }

  Future<void> connectToHost(String host, {int port = 8050}) async {
    _startIsolate(
      mode: 'client',
      host: host,
      port: port,
    );
  }

  Future<void> _startIsolate({
    required String mode,
    String? host,
    required int port,
  }) async {
    stopConnection();

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
