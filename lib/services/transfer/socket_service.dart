import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:flashbyte/app/app_settings.dart';
import 'package:flashbyte/services/security/tls_identity_service.dart';
import 'package:flashbyte/services/transfer/file_transfer_isolate.dart';

typedef IsolateMessage = Map<String, dynamic>;

class SocketStartupCancelled implements Exception {
  const SocketStartupCancelled();

  @override
  String toString() => 'Socket startup was cancelled.';
}

class SocketService {
  SocketService._privateConstructor();
  static final SocketService instance = SocketService._privateConstructor();

  Isolate? _receiverIsolate;
  SendPort? _toIsolateSendPort;

  ReceivePort? _uiReceivePort = ReceivePort();
  StreamSubscription? _streamSubscription;
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
  bool get isRunning => _receiverIsolate != null;
  bool get isHosting => _hostIsListening;
  bool get isSecureHosting => _hostIsListening && _hostUsesTls;
  bool get hasEstablishedConnection => _hasEstablishedConnection;
  IsolateMessage? get connectedPeerInfo => _connectedPeerInfo == null
      ? null
      : Map<String, dynamic>.from(_connectedPeerInfo!);

  bool _hasEstablishedConnection = false;
  bool _hostIsListening = false;
  bool _hostUsesTls = false;

  Future<void> startHost(
    String host, {
    int port = 8050,
    bool useTLS = false,
  }) async {
    await _runLifecycleOperation(
      () => _startIsolate(
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
      () => _startIsolate(
        mode: 'client',
        host: host,
        port: port,
        useTLS: useTLS,
        trustedCertificatePem: trustedCertificatePem,
        expectedCertificateFingerprint: expectedCertificateFingerprint,
        trustedPeerId: trustedPeerId,
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

  Future<void> _startIsolate({
    required String mode,
    String? host,
    required int port,
    bool useTLS = false,
    String? trustedCertificatePem,
    String? expectedCertificateFingerprint,
    String? trustedPeerId,
  }) async {
    await _stopConnectionGracefully();
    final generation = _connectionGeneration;
    _hostUsesTls = mode == 'host' && useTLS;
    _disconnectRequested = false;
    _transferStartMessages.clear();
    _transferLatestMessages.clear();
    _connectedPeerInfo = null;
    _setConnectionEstablished(false);

    String? certPath;
    String? keyPath;
    String? certificateFingerprint;
    String? trustedCertPath;
    final downloadDirectory = await AppSettings.getDownloadDirectory();
    final deviceName = await AppSettings.getDeviceName();
    if (useTLS) {
      final identity = await TlsIdentityService.getOrCreateIdentity();
      certPath = identity.certificatePath;
      keyPath = identity.privateKeyPath;
      certificateFingerprint = identity.fingerprint;

      if (mode == 'client') {
        if (trustedCertificatePem == null ||
            trustedCertificatePem.trim().isEmpty ||
            expectedCertificateFingerprint == null ||
            expectedCertificateFingerprint.trim().isEmpty) {
          throw Exception(
            'TLS requires a discovered receiver certificate. Select the receiver from discovery and try again.',
          );
        }

        trustedCertPath = await TlsIdentityService.writeTrustedPeerCertificate(
          peerId: trustedPeerId ?? host ?? 'peer',
          certificatePem: trustedCertificatePem,
        );
      }
    }

    final completer = Completer<SendPort>();
    final hostingCompleter = Completer<void>();

    final uiReceivePort = ReceivePort();
    _uiReceivePort = uiReceivePort;
    final RootIsolateToken? rootToken = RootIsolateToken.instance;

    if (rootToken == null) {
      throw Exception('Fatal: RootIsolateToken is null!');
    }

    _streamSubscription = uiReceivePort.listen(
      (message) async {
        if (message is SendPort) {
          if (!completer.isCompleted) {
            completer.complete(message);
          }
          return;
        }
        if (generation != _connectionGeneration) {
          return;
        }

        final typedMessage = message as IsolateMessage;
        final status = typedMessage['status'] ?? typedMessage['command'];
        if (status == 'hosting' && !hostingCompleter.isCompleted) {
          _hostIsListening = true;
          hostingCompleter.complete();
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
          Future.microtask(() => _stopConnectionIfCurrent(generation));
        }
      },
    );

    final receiverIsolate = await Isolate.spawn(
      fileReceiverIsolate,
      [
        uiReceivePort.sendPort,
        rootToken,
      ],
    );
    if (generation != _connectionGeneration) {
      receiverIsolate.kill(priority: Isolate.immediate);
      throw const SocketStartupCancelled();
    }
    _receiverIsolate = receiverIsolate;

    _toIsolateSendPort = await completer.future;
    if (generation != _connectionGeneration) {
      throw const SocketStartupCancelled();
    }

    _toIsolateSendPort!.send({
      'command': 'connect',
      'mode': mode,
      'host': host,
      'port': port,
      'useTLS': useTLS,
      'certPath': certPath,
      'keyPath': keyPath,
      'certificateFingerprint': certificateFingerprint,
      'trustedCertPath': trustedCertPath,
      'expectedCertificateFingerprint': expectedCertificateFingerprint,
      'downloadDirectory': downloadDirectory,
      'deviceName': deviceName,
      'deviceType': Platform.isAndroid || Platform.isIOS ? 'phone' : 'laptop',
      'listeningPort': port,
    });

    if (mode == 'host') {
      await hostingCompleter.future.timeout(const Duration(seconds: 10));
    }
  }

  void sendFile(String filePath) {
    if (_toIsolateSendPort == null) {
      return;
    }

    _toIsolateSendPort!.send({
      'command': 'send_file',
      'filePath': filePath,
    });
  }

  void pauseTransfer(String fileId, {required bool isReceiver}) {
    _sendTransferControl(
      'pause_transfer',
      fileId,
      role: isReceiver ? 'receiver' : 'sender',
    );
  }

  void resumeTransfer(String fileId, {required bool isReceiver}) {
    _sendTransferControl(
      'resume_transfer',
      fileId,
      role: isReceiver ? 'receiver' : 'sender',
    );
  }

  void cancelTransfer(String fileId) {
    _sendTransferControl('cancel_transfer', fileId);
  }

  void acceptTransfer(String fileId) {
    _sendTransferControl('accept_transfer', fileId);
  }

  void declineTransfer(String fileId) {
    _sendTransferControl('decline_transfer', fileId);
  }

  Future<void> cancelOutgoingOffer() async {
    final sendPort = _toIsolateSendPort;
    if (sendPort == null) return;
    final completer = _outgoingOfferCancelCompleter ??= Completer<void>();
    sendPort.send({'command': 'cancel_outgoing_offer'});
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

  void _sendTransferControl(String command, String fileId, {String? role}) {
    _toIsolateSendPort?.send({
      'command': command,
      'fileId': fileId,
      'role': ?role,
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

  Future<void> disconnect() {
    final sendPort = _toIsolateSendPort;
    if (_uiReceivePort == null || sendPort == null) {
      stopConnection();
      return Future.value();
    }
    _disconnectRequested = true;
    _setConnectionEstablished(false);
    final completer = _disconnectCompleter ??= Completer<void>();
    try {
      sendPort.send({
        'command': 'disconnect',
      });
    } catch (_) {
      stopConnection();
    }
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
    if (_receiverIsolate == null && _toIsolateSendPort == null) {
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
    _streamSubscription?.cancel();
    _uiReceivePort?.close();
    _receiverIsolate?.kill(priority: Isolate.immediate);

    _receiverIsolate = null;
    _toIsolateSendPort = null;
    _streamSubscription = null;
    _uiReceivePort = null;
    _hostIsListening = false;
    _hostUsesTls = false;
    _disconnectRequested = false;
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
