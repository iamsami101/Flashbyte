import 'dart:async';
import 'dart:io';

import 'package:flashbyte/app/app_settings.dart';
import 'package:flashbyte/src/rust/api/transfer.dart' as rust_transfer;

typedef IsolateMessage = Map<String, dynamic>;

class SocketStartupCancelled implements Exception {
  const SocketStartupCancelled();

  @override
  String toString() => 'Socket startup was cancelled.';
}

class SocketService {
  SocketService._privateConstructor();
  static final SocketService instance = SocketService._privateConstructor();

  StreamSubscription<rust_transfer.TransferMessage>? _rustSubscription;
  bool _disconnectRequested = false;
  int _connectionGeneration = 0;
  Completer<void>? _disconnectCompleter;
  Completer<void>? _outgoingOfferCancelCompleter;
  Future<void> _lifecycleOperation = Future.value();

  final _messageStreamController = StreamController<IsolateMessage>.broadcast();
  final _connectionStatusController = StreamController<bool>.broadcast();
  final Map<String, IsolateMessage> _transferStartMessages = {};
  final Map<String, IsolateMessage> _transferLatestMessages = {};
  IsolateMessage? _connectedPeerInfo;

  Stream<IsolateMessage> get messageStream => _messageStreamController.stream;
  Stream<bool> get connectionStatusStream => _connectionStatusController.stream;
  bool get isRunning => _rustSubscription != null || rust_transfer.isRunning();
  bool get isHosting =>
      _hostIsListening ||
      (_rustSubscription != null && rust_transfer.isHosting());
  bool get isSecureHosting => false; // TLS not yet supported in Rust backend
  bool get hasEstablishedConnection =>
      _hasEstablishedConnection || rust_transfer.hasEstablishedConnection();
  IsolateMessage? get connectedPeerInfo => _connectedPeerInfo == null
      ? null
      : Map<String, dynamic>.from(_connectedPeerInfo!);

  bool _hasEstablishedConnection = false;
  bool _hostIsListening = false;

  Future<void> startHost(
    String host, {
    int port = 8050,
    bool useTLS = false,
  }) async {
    await _runLifecycleOperation(
      () => _startRustTransfer(
        mode: 'host',
        host: host,
        port: port,
        useTLS: useTLS,
      ),
    );
  }

  Future<void> connectToHost(
    String host, {
    int port = 8050,
    bool useTLS = false,
    String? trustedCertificatePem,
    String? expectedCertificateFingerprint,
    String? trustedPeerId,
  }) async {
    await _runLifecycleOperation(
      () => _startRustTransfer(
        mode: 'client',
        host: host,
        port: port,
        useTLS: useTLS,
      ),
    );
  }

  Future<T> _runLifecycleOperation<T>(Future<T> Function() operation) async {
    final previousOperation = _lifecycleOperation;
    final operationCompleter = Completer<void>();
    _lifecycleOperation = operationCompleter.future;

    try {
      try {
        await previousOperation;
      } catch (_) {
        // A failed previous startup should not poison the next lifecycle action.
      }
      return await operation();
    } finally {
      if (!operationCompleter.isCompleted) {
        operationCompleter.complete();
      }
    }
  }

  Future<void> _startRustTransfer({
    required String mode,
    String? host,
    required int port,
    bool useTLS = false,
  }) async {
    await _stopConnectionGracefully();
    final generation = _connectionGeneration;
    _disconnectRequested = false;
    _hostIsListening = false;
    _transferStartMessages.clear();
    _transferLatestMessages.clear();
    _connectedPeerInfo = null;
    _setConnectionEstablished(false);

    if (useTLS) {
      _emitError(
        'TLS is not yet supported by the Rust transfer backend. Disable TLS on both devices and try again.',
      );
      return;
    }

    final downloadDirectory = await AppSettings.getDownloadDirectory();
    final deviceName = await AppSettings.getDeviceName();
    final deviceType = Platform.isAndroid || Platform.isIOS
        ? 'phone'
        : 'laptop';

    final hostingCompleter = Completer<void>();

    final rustStream = mode == 'host'
        ? rust_transfer.startHost(
            port: port,
            downloadDirectory: downloadDirectory,
            deviceName: deviceName,
            deviceType: deviceType,
          )
        : rust_transfer.connectToHost(
            host: host!,
            port: port,
            downloadDirectory: downloadDirectory,
            deviceName: deviceName,
            deviceType: deviceType,
          );

    _rustSubscription = rustStream.listen(
      (message) {
        if (generation != _connectionGeneration) {
          return;
        }
        _handleRustMessage(message, mode, hostingCompleter);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (generation != _connectionGeneration) {
          return;
        }
        _setConnectionEstablished(false);
        if (mode == 'host' && !hostingCompleter.isCompleted) {
          hostingCompleter.completeError(
            Exception(error.toString()),
          );
        }
        _messageStreamController.add({
          'status': 'error',
          'fatal': true,
          'message': error.toString(),
        });
      },
      onDone: () {
        if (generation != _connectionGeneration) {
          return;
        }
        _setConnectionEstablished(false);
        _rustSubscription = null;
        _hostIsListening = false;
      },
    );

    if (mode == 'host') {
      await hostingCompleter.future.timeout(const Duration(seconds: 10));
    }
  }

  void _handleRustMessage(
    rust_transfer.TransferMessage message,
    String mode,
    Completer<void> hostingCompleter,
  ) {
    final typedMessage = _rustMessageToMap(message);
    final status = typedMessage['status'] ?? typedMessage['command'];

    if (status == 'hosting') {
      _hostIsListening = true;
      if (!hostingCompleter.isCompleted) {
        hostingCompleter.complete();
      }
    } else if (mode == 'host' &&
        status == 'error' &&
        !hostingCompleter.isCompleted) {
      hostingCompleter.completeError(
        Exception(typedMessage['message'] ?? 'Failed to start server'),
      );
    }

    if (status == 'client_connected' || status == 'connected_to_host') {
      _disconnectRequested = false;
      _setConnectionEstablished(true);
    } else if (status == 'disconnect' || status == 'error') {
      _setConnectionEstablished(false);
      if (status == 'disconnect') {
        _completeDisconnectWaiter();
      }
    }

    if (status == 'outgoing_offer_cancelled') {
      final completer = _outgoingOfferCancelCompleter;
      if (completer != null && !completer.isCompleted) {
        completer.complete();
      }
      _outgoingOfferCancelCompleter = null;
    }

    if (status == 'error' && _disconnectRequested) {
      return;
    }

    _publishMessage(typedMessage);

    if (status == 'disconnect') {
      Future.microtask(() => _stopConnectionIfCurrent(_connectionGeneration));
    }
  }

  IsolateMessage _rustMessageToMap(rust_transfer.TransferMessage message) {
    final map = <String, dynamic>{};

    void put(String key, Object? value) {
      if (value != null) {
        map[key] = value;
      }
    }

    put('status', message.status.isEmpty ? null : message.status);
    put('command', message.command);
    put('fatal', message.fatal);
    put('message', message.message);
    put('address', message.address);
    put('fileId', message.fileId);
    put('fileName', message.fileName);
    put('filePath', message.filePath);
    put('fileSize', message.fileSize);
    put('progress', message.progress);
    put('timeTaken', message.timeTaken);
    put('treeUri', message.treeUri);
    put('sourceFilePath', message.sourceFilePath);
    put('name', message.peerName);
    put('deviceType', message.peerDeviceType);
    put('pausedBy', message.pausedBy);
    put('canResume', message.canResume);

    return map;
  }

  void sendFile(String filePath) {
    if (!isRunning) {
      return;
    }
    unawaited(
      rust_transfer.sendFile(filePath: filePath).catchError((Object error) {
        _emitError('File send error: ${error.toString()}', fatal: false);
      }),
    );
  }

  void sendFiles(List<String> filePaths) {
    if (!isRunning || filePaths.isEmpty) {
      return;
    }
    unawaited(
      rust_transfer.sendFiles(filePaths: filePaths).catchError((Object error) {
        _emitError('File send error: ${error.toString()}', fatal: false);
      }),
    );
  }

  void pauseTransfer(String fileId, {required bool isReceiver}) {
    final role = isReceiver ? 'receiver' : 'sender';
    unawaited(
      rust_transfer
          .pauseTransfer(fileId: fileId, role: role)
          .catchError((_) {}),
    );
  }

  void resumeTransfer(String fileId, {required bool isReceiver}) {
    final role = isReceiver ? 'receiver' : 'sender';
    unawaited(
      rust_transfer
          .resumeTransfer(fileId: fileId, role: role)
          .catchError((_) {}),
    );
  }

  void cancelTransfer(String fileId) {
    unawaited(
      rust_transfer.cancelTransfer(fileId: fileId).catchError((_) {}),
    );
  }

  void acceptTransfer(String fileId) {
    unawaited(
      rust_transfer.acceptTransfer(fileId: fileId).catchError((_) {}),
    );
  }

  void declineTransfer(String fileId) {
    unawaited(
      rust_transfer.declineTransfer(fileId: fileId).catchError((_) {}),
    );
  }

  void setDownloadDirectory(String? directory) {
    unawaited(
      rust_transfer
          .setDownloadDirectory(directory: directory)
          .catchError((_) {}),
    );
  }

  Future<void> cancelOutgoingOffer() async {
    if (!isRunning) return;
    final completer = _outgoingOfferCancelCompleter ??= Completer<void>();
    unawaited(
      rust_transfer.cancelOutgoingOffer().catchError((_) {
        // Silently ignore – the completer timeout handles cleanup.
      }),
    );
    try {
      await completer.future.timeout(const Duration(seconds: 1));
    } on TimeoutException {
      // The following graceful disconnect still cleans up a closed socket.
    } finally {
      if (identical(_outgoingOfferCancelCompleter, completer)) {
        _outgoingOfferCancelCompleter = null;
      }
    }
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

  Future<void> disconnect() {
    if (!isRunning) {
      stopConnection();
      return Future.value();
    }
    _disconnectRequested = true;
    _setConnectionEstablished(false);
    final completer = _disconnectCompleter ??= Completer<void>();
    unawaited(
      rust_transfer.disconnect().catchError((_) {
        stopConnection();
      }),
    );
    return completer.future;
  }

  Future<void> stopConnectionGracefully({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    await _runLifecycleOperation(
      () => _stopConnectionGracefully(timeout: timeout),
    );
  }

  Future<void> _stopConnectionGracefully({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    if (!isRunning) {
      stopConnection();
      return;
    }

    try {
      await disconnect().timeout(timeout);
      stopConnection();
    } on TimeoutException {
      stopConnection();
    }
  }

  void stopConnection() {
    _connectionGeneration++;
    _setConnectionEstablished(false);
    _completeDisconnectWaiter();
    _rustSubscription?.cancel();
    _rustSubscription = null;
    _hostIsListening = false;
    _disconnectRequested = false;
    unawaited(rust_transfer.disconnect().catchError((_) {}));
  }

  void _completeDisconnectWaiter() {
    final completer = _disconnectCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
    _disconnectCompleter = null;
    final offerCompleter = _outgoingOfferCancelCompleter;
    if (offerCompleter != null && !offerCompleter.isCompleted) {
      offerCompleter.complete();
    }
    _outgoingOfferCancelCompleter = null;
  }

  void _stopConnectionIfCurrent(int generation) {
    if (generation == _connectionGeneration) {
      stopConnection();
    }
  }

  void _setConnectionEstablished(bool value) {
    if (_hasEstablishedConnection == value) {
      return;
    }
    _hasEstablishedConnection = value;
    _connectionStatusController.add(value);
  }

  void _emitError(String message, {bool fatal = true}) {
    _messageStreamController.add({
      'status': 'error',
      'fatal': fatal,
      'message': message,
    });
  }

  Map<String, bool> getActiveTransferIsReceived() {
    final result = <String, bool>{};
    for (final entry in _transferStartMessages.entries) {
      final status = entry.value['status'] as String?;
      if (status == 'start') {
        result[entry.key] = true;
      } else if (status == 'send_start') {
        result[entry.key] = false;
      }
    }
    return result;
  }

  void _publishMessage(IsolateMessage message) {
    final status = message['status'] ?? message['command'];
    if (status == 'peer_info') {
      _connectedPeerInfo = Map<String, dynamic>.from(message);
    }
    final fileId = message['fileId'] as String?;
    if (fileId != null) {
      if (status == 'start' || status == 'send_start') {
        _transferStartMessages[fileId] = Map<String, dynamic>.from(message);
        _transferLatestMessages.remove(fileId);
      } else if (status == 'progress' ||
          status == 'send_progress' ||
          status == 'completed' ||
          status == 'send_complete' ||
          status == 'transfer_paused' ||
          status == 'transfer_resumed' ||
          status == 'transfer_pending' ||
          status == 'transfer_accepted' ||
          status == 'transfer_declined' ||
          status == 'transfer_cancelled') {
        _transferLatestMessages[fileId] = Map<String, dynamic>.from(message);
      }
    }

    _messageStreamController.add(message);
  }
}
