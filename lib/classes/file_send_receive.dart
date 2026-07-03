import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:async';
import 'package:flashbyte/classes/android_saf_service.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:external_path/external_path.dart';
import 'package:saf_util/saf_util.dart';
import 'package:uri_to_file/uri_to_file.dart';
import 'package:uuid/uuid.dart';

void fileReceiverIsolate(List<Object> args) {
  final toUiSendPort = args[0] as SendPort;
  final RootIsolateToken rootIsolateToken = args[1] as RootIsolateToken;

  BackgroundIsolateBinaryMessenger.ensureInitialized(rootIsolateToken);

  final fromUiReceivePort = ReceivePort();
  toUiSendPort.send(fromUiReceivePort.sendPort);

  dynamic clientSocket;
  dynamic serverSocket;

  final Queue<Map<String, dynamic>> commandQueue =
      Queue<Map<String, dynamic>>();
  bool isProcessing = false;
  String? sendingFileId;

  Future<void> processCommandQueue() async {
    if (isProcessing || commandQueue.isEmpty) return;
    isProcessing = true;

    while (commandQueue.isNotEmpty) {
      final command = commandQueue.removeFirst();

      try {
        if (command['command'] == 'connect') {
          final useTLS = command['useTLS'] ?? false;

          if (command['mode'] == 'host') {
            SecurityContext? securityContext;
            if (useTLS) {
              try {
                final certPath = command['certPath'] as String?;
                final keyPath = command['keyPath'] as String?;
                print('[SERVER_TLS] certPath=$certPath, keyPath=$keyPath');

                if (certPath != null && keyPath != null) {
                  final certFile = File(certPath);
                  final keyFile = File(keyPath);
                  print(
                    '[SERVER_TLS] cert exists=${certFile.existsSync()}, key exists=${keyFile.existsSync()}',
                  );
                  securityContext = SecurityContext(withTrustedRoots: false);
                  securityContext.useCertificateChain(certPath);
                  securityContext.usePrivateKey(keyPath);
                } else {
                  final certFile = File('certificates/server.crt');
                  final keyFile = File('certificates/server.key');
                  if (certFile.existsSync() && keyFile.existsSync()) {
                    securityContext = SecurityContext(withTrustedRoots: false);
                    securityContext.useCertificateChain(
                      'certificates/server.crt',
                    );
                    securityContext.usePrivateKey('certificates/server.key');
                  } else {
                    throw Exception('Certificate files not found.');
                  }
                }
                print('[SERVER_TLS] Certificate loaded successfully');
              } catch (e) {
                toUiSendPort.send({
                  'status': 'error',
                  'fatal': 'true',
                  'message': 'Failed to load certificate: ${e.toString()}',
                });
                return;
              }
            }

            if (useTLS) {
              serverSocket = await SecureServerSocket.bind(
                "0.0.0.0",
                command['port'],
                securityContext!,
                shared: true,
              );
              print('[SERVER_TLS] SecureServerSocket bound successfully');
            } else {
              serverSocket = await ServerSocket.bind(
                "0.0.0.0",
                command['port'],
                shared: true,
              );
            }

            toUiSendPort.send({
              'status': 'hosting',
              'address': serverSocket!.address.address,
            });

            dynamic savedClientSocket;

            serverSocket!.listen(
              (socket) {
                savedClientSocket = socket;
                _configureSocketForTransfer(savedClientSocket);
                clientSocket = socket;
                if (useTLS) {
                  // TLS handshake already verified the client — notify UI immediately
                  toUiSendPort.send({'status': 'client_connected'});
                } else {
                  // Non-TLS: notify UI that a client is connecting (probe in progress)
                  toUiSendPort.send({'status': 'client_connecting'});
                }
                // Non-TLS servers wait for probe before sending client_connected
                _handleSocketConnection(
                  savedClientSocket,
                  toUiSendPort,
                  waitForProbe: !useTLS,
                  configuredDownloadDirectory:
                      command['downloadDirectory'] as String?,
                );
              },
              onError: (error) {
                print('[SERVER_TLS] listen error: $error');
                toUiSendPort.send({
                  'status': 'error',
                  'fatal': 'false',
                  'message': 'TLS connection error: $error',
                });
              },
            );
          } else if (command['mode'] == 'client') {
            SecurityContext? securityContext;
            if (useTLS) {
              try {
                final certPath = command['certPath'] as String?;
                if (certPath != null && File(certPath).existsSync()) {
                  print('[CLIENT_TLS] cert path=$certPath, exists=true');
                  securityContext = SecurityContext(withTrustedRoots: false);
                  securityContext.setTrustedCertificates(certPath);
                } else {
                  final certFile = File('certificates/server.crt');
                  if (certFile.existsSync()) {
                    securityContext = SecurityContext(withTrustedRoots: false);
                    securityContext.setTrustedCertificates(
                      'certificates/server.crt',
                    );
                  }
                }
              } catch (e) {
                print('[CLIENT_TLS] cert load error: ${e.toString()}');
              }
            }

            try {
              dynamic finalSocket;

              if (useTLS) {
                final rawSocket = await Socket.connect(
                  command['host'],
                  command['port'],
                );
                finalSocket = await SecureSocket.secure(
                  rawSocket,
                  host: 'localhost',
                  context: securityContext,
                );
                _configureSocketForTransfer(finalSocket);
                print('[CLIENT_TLS] connected successfully');
                clientSocket = finalSocket;
                toUiSendPort.send({'status': 'connected_to_host'});
                _handleSocketConnection(
                  clientSocket!,
                  toUiSendPort,
                  configuredDownloadDirectory:
                      command['downloadDirectory'] as String?,
                  onTransferAcknowledged: (fileId) {
                    if (sendingFileId == fileId) {
                      sendingFileId = null;
                    }
                  },
                );
              } else {
                // Non-TLS: send probe, then hand off to _handleSocketConnection
                // which handles both the probe response and subsequent file transfers
                finalSocket = await Socket.connect(
                  command['host'],
                  command['port'],
                );
                _configureSocketForTransfer(finalSocket);
                final probeMsg = jsonEncode({'type': 'probe', 'tls': false});
                final probeBytes = utf8.encode(probeMsg);
                final header = ByteData(8);
                header.setUint32(0, probeBytes.length, Endian.big);
                header.setUint32(4, 0, Endian.big);
                finalSocket.add(header.buffer.asUint8List());
                finalSocket.add(probeBytes);

                clientSocket = finalSocket;
                // _handleSocketConnection will process the probe response as the
                // first incoming message and send 'connected_to_host' when verified
                _handleSocketConnection(
                  clientSocket!,
                  toUiSendPort,
                  waitForProbe: true,
                  configuredDownloadDirectory:
                      command['downloadDirectory'] as String?,
                  onTransferAcknowledged: (fileId) {
                    if (sendingFileId == fileId) {
                      sendingFileId = null;
                    }
                  },
                );
              }
            } catch (e) {
              print('[CLIENT_TLS] connect error: $e');
              toUiSendPort.send({
                'status': 'error',
                'fatal': 'true',
                'message': useTLS
                    ? 'TLS connection failed: ${e.toString()}'
                    : 'Could not connect. Try enabling TLS on both devices.',
              });
            }
          }
        } else if (command['command'] == 'send_file') {
          if (clientSocket == null) {
            toUiSendPort.send({
              'status': 'error',
              'fatal': 'true',
              'message': 'Socket not connected',
            });
            continue;
          }

          try {
            sendingFileId = await _sendFileCommand(
              command,
              clientSocket!,
              toUiSendPort,
            );
          } finally {}
        } else if (command['command'] == "disconnect") {
          final header = utf8.encode(
            jsonEncode({
              'type': 'disconnect',
            }),
          );
          final byteData = ByteData(8);
          byteData.setUint32(0, header.length);
          byteData.setUint32(4, 0);

          clientSocket!.add(byteData.buffer.asUint8List());
          clientSocket!.add(header);
        }
      } catch (e) {
        toUiSendPort.send({
          'status': 'error',
          'fatal': 'false',
          'message': 'Command processing error: ${e.toString()}',
        });
      }
    }

    isProcessing = false;
  }

  fromUiReceivePort.listen((message) {
    commandQueue.add(message as Map<String, dynamic>);
    processCommandQueue();
  });
}

Future<String> _sendFileCommand(
  Map<String, dynamic> command,
  dynamic clientSocket,
  SendPort toUiSendPort,
) async {
  final filePath = command['filePath'] as String;
  Stream<List<int>>? fileStream;
  Map<String, dynamic>? fileHeader;

  final stopwatch = Stopwatch()..start();

  File? cachedFile;
  int? androidFileDescriptor;

  try {
    if (Platform.isAndroid) {
      final fileStats = await SafUtil().stat(filePath, false);
      if (fileStats == null) {
        throw Exception('Could not read selected file metadata.');
      }

      try {
        androidFileDescriptor = await SafUtil().getFileDescriptor(filePath);
        final descriptorFile = File('/proc/self/fd/$androidFileDescriptor');
        fileStream = descriptorFile.openRead();
      } catch (_) {
        cachedFile = await toFile(filePath);
        fileStream = cachedFile.openRead();
      }

      fileHeader = {
        'uuid': Uuid().v4(),
        'name': fileStats.name,
        'size': fileStats.length,
      };
    } else {
      fileStream = File(filePath).openRead();
      final fileStats = await File(filePath).stat();

      fileHeader = {
        'uuid': Uuid().v4(),
        'name': filePath.split('/').last,
        'size': fileStats.size,
      };
    }

    final metadataBytes = utf8.encode(jsonEncode(fileHeader));
    final lengthHeaderBytes = ByteData(8);
    lengthHeaderBytes.setUint32(0, metadataBytes.length, Endian.big);
    lengthHeaderBytes.setUint32(4, fileHeader['size'] as int, Endian.big);

    clientSocket.add(lengthHeaderBytes.buffer.asUint8List());
    clientSocket.add(metadataBytes);

    toUiSendPort.send({
      'status': 'send_start',
      'fileId': fileHeader['uuid'],
      'fileName': fileHeader['name'],
      'fileSize': fileHeader['size'],
      'filePath': command['filePath'],
    });

    await for (final chunk in fileStream) {
      clientSocket.add(chunk);
    }
    await clientSocket.flush();

    stopwatch.stop();

    try {
      if (androidFileDescriptor != null) {
        await SafUtil().closeFileDescriptor(androidFileDescriptor);
      }
      cachedFile?.delete();
    } on Exception catch (_) {}
    return fileHeader['uuid'] as String;
  } catch (e) {
    stopwatch.stop();
    try {
      if (androidFileDescriptor != null) {
        await SafUtil().closeFileDescriptor(androidFileDescriptor);
      }
      cachedFile?.delete();
    } on Exception catch (_) {}
    toUiSendPort.send({
      'status': 'error',
      'fatal': 'false',
      'message': 'File send error: ${e.toString()}',
    });
    rethrow;
  }
}

void _configureSocketForTransfer(dynamic socket) {
  try {
    socket.setOption(SocketOption.tcpNoDelay, true);
  } catch (_) {}
}

// ============================================================================
// File Receiving Logic - State Machine Based Implementation
// ============================================================================

/// Represents the current state of the file receiver.
sealed class _ReceiverState {
  const _ReceiverState();
}

/// Initial state, waiting for a frame header.
class _WaitingForHeader extends _ReceiverState {
  const _WaitingForHeader();
}

/// Actively receiving file data.
class _ReceivingFile extends _ReceiverState {
  final Map<String, dynamic> header;
  final int totalBytes;
  final int bytesWritten;
  final _OutputTarget target;
  final Stopwatch stopwatch;
  final int lastProgressPercent;
  final DateTime lastProgressUpdate;

  const _ReceivingFile({
    required this.header,
    required this.totalBytes,
    required this.bytesWritten,
    required this.target,
    required this.stopwatch,
    required this.lastProgressPercent,
    required this.lastProgressUpdate,
  });

  _ReceivingFile copyWith({
    int? bytesWritten,
    int? lastProgressPercent,
    DateTime? lastProgressUpdate,
  }) =>
      _ReceivingFile(
        header: header,
        totalBytes: totalBytes,
        bytesWritten: bytesWritten ?? this.bytesWritten,
        target: target,
        stopwatch: stopwatch,
        lastProgressPercent: lastProgressPercent ?? this.lastProgressPercent,
        lastProgressUpdate: lastProgressUpdate ?? this.lastProgressUpdate,
      );
}

/// Connection was closed gracefully.
class _Disconnected extends _ReceiverState {
  const _Disconnected();
}

/// Manages the file receiving process using a state machine.
class _FileReceiver {
  final dynamic socket;
  final SendPort toUiSendPort;
  final String? configuredDownloadDirectory;
  final void Function(String fileId)? onTransferAcknowledged;
  final bool waitForProbe;

  _FileReceiver({
    required this.socket,
    required this.toUiSendPort,
    this.configuredDownloadDirectory,
    this.onTransferAcknowledged,
    required this.waitForProbe,
  });

  static const _progressUpdateInterval = Duration(milliseconds: 500);
  static const _probeTimeout = Duration(seconds: 5);

  final _buffer = _SocketReadBuffer();
  _ReceiverState _state = const _WaitingForHeader();
  var _probeHandled = false;
  var _errorSent = false;
  var _socketClosed = false;

  void start() {
    _scheduleProbeTimeout();
    socket.listen(_onData, onDone: _onDone, onError: _onError);
  }

  void _scheduleProbeTimeout() {
    if (!waitForProbe) {
      _probeHandled = true;
      return;
    }
    Future.delayed(_probeTimeout, () {
      if (!_probeHandled) _handleProbeTimeout();
    });
  }

  void _handleProbeTimeout() {
    _sendError('Could not establish the connection. Check the TLS setting on both devices.');
    _closeSocket();
  }

  Future<void> _onData(List<int> data) async {
    _buffer.add(data);
    await _processFrames();
  }

  void _onDone() {
    _handleConnectionEnd(
      'Connection closed before the link was established. Check the TLS setting on both devices.',
      'Connection lost. The other device disconnected unexpectedly.',
    );
  }

  void _onError(dynamic e) {
    _handleConnectionEnd(
      'Could not establish the connection. Check the TLS setting on both devices.',
      e.toString(),
    );
  }

  void _handleConnectionEnd(String probeErrorMsg, String postProbeErrorMsg) {
    _cleanupOnDisconnect();
    if (!_probeHandled && !_errorSent) {
      _sendError(probeErrorMsg);
    } else if (!_errorSent && _state is! _Disconnected) {
      _sendError(postProbeErrorMsg, fatal: true);
    }
    _closeSocket();
  }

  Future<void> _processFrames() async {
    while (!_socketClosed) {
      final action = _state is _WaitingForHeader
          ? await _processHeaderFrame()
          : _state is _ReceivingFile
              ? _processFileData()
              : _FrameAction.none;

      if (action.shouldClose) _closeSocket();
      if (!action.shouldContinue || _socketClosed) return;
    }
  }

  Future<_FrameAction> _processHeaderFrame() async {
    final frameHeader = _buffer.tryPeekFrameHeader();
    if (frameHeader == null || _buffer.availableBytes < 8 + frameHeader.headerLength) {
      return _FrameAction.wait;
    }

    _buffer.skipBytes(8);
    final headerBytes = _buffer.tryReadBytes(frameHeader.headerLength)!;
    final header = jsonDecode(utf8.decode(headerBytes)) as Map<String, dynamic>;

    final isControlFrame = header.containsKey('type') || header.containsKey('ok');
    return isControlFrame && frameHeader.payloadLength == 0
        ? _handleControlFrame(header)
        : _beginFileTransfer(header, frameHeader.payloadLength);
  }

  Future<_FrameAction> _handleControlFrame(Map<String, dynamic> header) async {
    // Handle probe handshake first
    if (!_probeHandled) return _handleProbe(header);

    // Handle other control frames
    return switch (header['type']) {
      'ping' => _respondToPing(),
      'pong' => _FrameAction.continueReading,
      'file_received_ack' => _handleFileAck(header),
      'file_receive_progress' => _handleProgressReport(header),
      'disconnect' => _handleDisconnect(),
      _ => _FrameAction.continueReading,
    };
  }

  _FrameAction _handleProbe(Map<String, dynamic> header) {
    _probeHandled = true;

    // Client received probe response from server
    final ok = header['ok'];
    if (ok != null) {
      if (ok == true) {
        toUiSendPort.send({'status': 'connected_to_host'});
        return _FrameAction.continueReading;
      }
      _sendError(header['error'] as String? ?? 'Could not establish the connection.');
      return _FrameAction.close;
    }

    // Server received probe from client
    if (header['type'] == 'probe') {
      final clientWantsTls = header['tls'] == true;
      _sendControlFrame(clientWantsTls
          ? {'ok': false, 'error': 'TLS mismatch: server does not use TLS, client has TLS enabled'}
          : {'ok': true, 'tls': false});

      if (clientWantsTls) {
        _sendError('TLS settings do not match on both devices.', fatal: false);
        return _FrameAction.close;
      }
      toUiSendPort.send({'status': 'client_connected'});
    }
    return _FrameAction.continueReading;
  }

  _FrameAction _respondToPing() {
    _sendControlFrame({'type': 'pong'});
    return _FrameAction.continueReading;
  }

  _FrameAction _handleFileAck(Map<String, dynamic> header) {
    final fileId = header['fileId'] as String?;
    if (fileId != null) {
      onTransferAcknowledged?.call(fileId);
      toUiSendPort.send({
        'status': 'send_complete',
        'fileId': fileId,
        'fileName': header['fileName'],
        'timeTaken': header['timeTaken'],
      });
    }
    return _FrameAction.continueReading;
  }

  _FrameAction _handleProgressReport(Map<String, dynamic> header) {
    final fileId = header['fileId'] as String?;
    final progress = (header['progress'] as num?)?.toDouble();
    if (fileId != null && progress != null) {
      toUiSendPort.send({
        'status': 'send_progress',
        'fileId': fileId,
        'progress': progress.clamp(0.0, 1.0),
      });
    }
    return _FrameAction.continueReading;
  }

  Future<_FrameAction> _handleDisconnect() async {
    await _cleanupPartialTransfer();
    _state = const _Disconnected();
    toUiSendPort.send({'command': 'disconnect'});
    return _FrameAction.close;
  }

  Future<_FrameAction> _beginFileTransfer(Map<String, dynamic> header, int payloadLength) async {
    final target = await _createOutputTarget(
      configuredDownloadDirectory: configuredDownloadDirectory,
      originalFileName: header['name'] as String,
    );

    toUiSendPort.send({
      'status': 'start',
      'fileId': header['uuid'],
      'fileName': target.fileName,
      'filePath': target.filePath,
      'fileSize': payloadLength,
    });

    _state = _ReceivingFile(
      header: header,
      totalBytes: payloadLength,
      bytesWritten: 0,
      target: target,
      stopwatch: Stopwatch()..start(),
      lastProgressPercent: -1,
      lastProgressUpdate: DateTime.fromMillisecondsSinceEpoch(0),
    );

    return _FrameAction.continueReading;
  }

  _FrameAction _processFileData() {
    final state = _state as _ReceivingFile;
    final remaining = state.totalBytes - state.bytesWritten;

    if (remaining <= 0) {
      _completeFileTransfer(state);
      return _FrameAction.continueReading;
    }

    final written = _buffer.drainToSink(state.target.sink, maxBytes: remaining);
    if (written == 0) return _FrameAction.wait;

    final newBytesWritten = state.bytesWritten + written;
    _state = state.copyWith(
      bytesWritten: newBytesWritten,
      lastProgressPercent: state.lastProgressPercent,
      lastProgressUpdate: state.lastProgressUpdate,
    );

    _reportProgress(_state as _ReceivingFile);

    if (newBytesWritten >= state.totalBytes) {
      _completeFileTransfer(_state as _ReceivingFile);
    }

    return _FrameAction.continueReading;
  }

  void _reportProgress(_ReceivingFile state, {bool force = false}) {
    final progress = state.totalBytes == 0
        ? 1.0
        : (state.bytesWritten / state.totalBytes).clamp(0.0, 1.0);
    final percent = (progress * 100).floor();
    final now = DateTime.now();

    final shouldThrottle = !force &&
        (percent == state.lastProgressPercent ||
            now.difference(state.lastProgressUpdate) < _progressUpdateInterval);

    if (shouldThrottle) return;

    _state = state.copyWith(
      lastProgressPercent: percent,
      lastProgressUpdate: now,
    );

    toUiSendPort.send({
      'status': 'progress',
      'fileId': state.header['uuid'],
      'progress': progress,
    });

    _sendControlFrame({
      'type': 'file_receive_progress',
      'fileId': state.header['uuid'],
      'progress': progress,
    });
  }

  void _completeFileTransfer(_ReceivingFile state) {
    final timeTaken = state.stopwatch.elapsed.inSeconds.toString();

    _reportProgress(state, force: true);

    _sendControlFrame({
      'type': 'file_received_ack',
      'fileId': state.header['uuid'],
      'fileName': state.target.fileName,
      'timeTaken': timeTaken,
    });

    toUiSendPort.send({
      'status': state.target.finalizeToTreeUri == null
          ? 'completed'
          : 'android_saf_finalize',
      'fileId': state.header['uuid'],
      'timeTaken': timeTaken,
      'treeUri': state.target.finalizeToTreeUri,
      'sourceFilePath': state.target.filePath,
      'fileName': state.target.fileName,
    });

    state.stopwatch.stop();
    state.target.sink.close();
    _state = const _WaitingForHeader();
  }

  void _sendControlFrame(Map<String, dynamic> payload) {
    final payloadBytes = utf8.encode(jsonEncode(payload));
    final header = ByteData(8)
      ..setUint32(0, payloadBytes.length, Endian.big)
      ..setUint32(4, 0, Endian.big);
    socket.add(header.buffer.asUint8List());
    socket.add(payloadBytes);
  }

  void _sendError(String message, {bool fatal = true}) {
    if (_errorSent) return;
    _errorSent = true;
    _probeHandled = true;
    toUiSendPort.send({'status': 'error', 'fatal': fatal, 'message': message});
  }

  void _closeSocket() {
    if (_socketClosed) return;
    _socketClosed = true;
    socket.destroy();
  }

  Future<void> _cleanupPartialTransfer() async {
    final state = _state;
    if (state is! _ReceivingFile) return;

    await state.target.sink.close();
    try {
      final file = File(state.target.filePath);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  void _cleanupOnDisconnect() {
    final state = _state;
    if (state is _ReceivingFile) {
      unawaited(_cleanupPartialTransfer());
    }
  }
}

/// Result of processing a frame.
enum _FrameAction {
  continueReading,
  wait,
  close,
  none;

  bool get shouldContinue => this == continueReading;
  bool get shouldClose => this == close;
}

void _handleSocketConnection(
  dynamic socket,
  SendPort toUiSendPort, {
  bool waitForProbe = false,
  String? configuredDownloadDirectory,
  void Function(String fileId)? onTransferAcknowledged,
}) {
  final receiver = _FileReceiver(
    socket: socket,
    toUiSendPort: toUiSendPort,
    configuredDownloadDirectory: configuredDownloadDirectory,
    onTransferAcknowledged: onTransferAcknowledged,
    waitForProbe: waitForProbe,
  );
  receiver.start();
}

Future<String> _resolveDownloadDirectory({String? commandDirectory}) async {
  if (commandDirectory != null && commandDirectory.isNotEmpty) {
    if (Platform.isAndroid && AndroidSafService.isTreeUri(commandDirectory)) {
      return commandDirectory;
    }
    final directory = Directory(commandDirectory);
    if (await directory.exists()) {
      return commandDirectory;
    }
  }

  if (Platform.isAndroid) {
    return ExternalPath.getExternalStoragePublicDirectory(
      ExternalPath.DIRECTORY_DOWNLOAD,
    );
  }

  final dirObject = await getDownloadsDirectory();
  if (dirObject != null) {
    return dirObject.path;
  }

  final fallback = await getApplicationDocumentsDirectory();
  return fallback.path;
}

class _FrameHeader {
  const _FrameHeader({
    required this.headerLength,
    required this.payloadLength,
  });

  final int headerLength;
  final int payloadLength;
}

class _SocketReadBuffer {
  final Queue<Uint8List> _chunks = Queue<Uint8List>();
  int _headOffset = 0;
  int _availableBytes = 0;

  int get availableBytes => _availableBytes;

  void add(List<int> bytes) {
    if (bytes.isEmpty) {
      return;
    }

    _chunks.add(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
    _availableBytes += bytes.length;
  }

  _FrameHeader? tryPeekFrameHeader() {
    final bytes = tryPeekBytes(8);
    if (bytes == null) {
      return null;
    }

    final header = ByteData.sublistView(bytes);
    return _FrameHeader(
      headerLength: header.getUint32(0, Endian.big),
      payloadLength: header.getUint32(4, Endian.big),
    );
  }

  Uint8List? tryPeekBytes(int byteCount) {
    if (_availableBytes < byteCount) {
      return null;
    }

    final out = Uint8List(byteCount);
    var outOffset = 0;
    var remaining = byteCount;
    var chunkOffset = _headOffset;

    for (final chunk in _chunks) {
      final readable = chunk.length - chunkOffset;
      final take = readable < remaining ? readable : remaining;
      out.setRange(outOffset, outOffset + take, chunk, chunkOffset);
      outOffset += take;
      remaining -= take;
      if (remaining == 0) {
        break;
      }
      chunkOffset = 0;
    }

    return out;
  }

  void skipBytes(int byteCount) {
    if (_availableBytes < byteCount) {
      throw RangeError.range(byteCount, 0, _availableBytes, 'byteCount');
    }
    _consume(byteCount);
  }

  Uint8List? tryReadBytes(int byteCount) {
    if (_availableBytes < byteCount) {
      return null;
    }

    final out = Uint8List(byteCount);
    var outOffset = 0;
    var remaining = byteCount;

    while (remaining > 0) {
      final head = _chunks.first;
      final readable = head.length - _headOffset;
      final take = readable < remaining ? readable : remaining;
      out.setRange(outOffset, outOffset + take, head, _headOffset);
      _consume(take);
      outOffset += take;
      remaining -= take;
    }

    return out;
  }

  int drainToSink(IOSink sink, {required int maxBytes}) {
    var remaining = maxBytes < _availableBytes ? maxBytes : _availableBytes;
    final total = remaining;

    while (remaining > 0) {
      final head = _chunks.first;
      final readable = head.length - _headOffset;
      final take = readable < remaining ? readable : remaining;
      final start = _headOffset;
      final end = start + take;

      sink.add(Uint8List.sublistView(head, start, end));
      _consume(take);
      remaining -= take;
    }

    return total;
  }

  void _consume(int byteCount) {
    _availableBytes -= byteCount;
    _headOffset += byteCount;

    while (_chunks.isNotEmpty && _headOffset >= _chunks.first.length) {
      _headOffset -= _chunks.removeFirst().length;
    }

    if (_chunks.isEmpty) {
      _headOffset = 0;
    }
  }
}

class _OutputTarget {
  const _OutputTarget({
    required this.fileName,
    required this.filePath,
    required this.sink,
    this.finalizeToTreeUri,
  });

  final String fileName;
  final String filePath;
  final IOSink sink;
  final String? finalizeToTreeUri;
}

Future<_OutputTarget> _createOutputTarget({
  required String? configuredDownloadDirectory,
  required String originalFileName,
}) async {
  final resolvedDirectory = await _resolveDownloadDirectory(
    commandDirectory: configuredDownloadDirectory,
  );

  if (Platform.isAndroid && AndroidSafService.isTreeUri(resolvedDirectory)) {
    final stagingDirectory = await getTemporaryDirectory();
    final fileName = _generateUniqueFileName(
      stagingDirectory.path,
      originalFileName,
    );
    final filePath = '${stagingDirectory.path}/$fileName';
    final file = File(filePath);
    return _OutputTarget(
      fileName: fileName,
      filePath: filePath,
      sink: file.openWrite(),
      finalizeToTreeUri: resolvedDirectory,
    );
  }

  final fileName = _generateUniqueFileName(
    resolvedDirectory,
    originalFileName,
  );
  final filePath = "$resolvedDirectory/$fileName";
  final file = File(filePath);
  return _OutputTarget(
    fileName: fileName,
    filePath: filePath,
    sink: file.openWrite(),
  );
}

String _generateUniqueFileName(String directory, String originalFileName) {
  final originalFile = File("$directory/$originalFileName");
  if (!originalFile.existsSync()) {
    return originalFileName;
  }

  final lastDotIndex = originalFileName.lastIndexOf('.');
  final name = lastDotIndex > 0
      ? originalFileName.substring(0, lastDotIndex)
      : originalFileName;
  final extension = lastDotIndex > 0
      ? originalFileName.substring(lastDotIndex)
      : '';

  int counter = 1;
  while (true) {
    final newFileName = '$name ($counter)$extension';
    final newFile = File("$directory/$newFileName");
    if (!newFile.existsSync()) {
      return newFileName;
    }
    counter++;
  }
}
