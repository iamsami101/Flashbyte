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

/// Manages the file receiving process.
/// 
/// Optimized for minimal allocations and syscalls on the hot path.
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

  static const _progressUpdateIntervalMs = 500;
  static const _probeTimeout = Duration(seconds: 5);
  
  // Pre-built pong frame - constant, no encoding needed per ping
  static final _pongFrame = Uint8List.fromList([
    0, 0, 0, 18, // header length (18 bytes for {"type":"pong"})
    0, 0, 0, 0,  // payload length (0 for control frames)
    123, 34, 116, 121, 112, 101, 34, 58, 34, 112, 111, 110, 103, 34, 125, // {"type":"pong"}
  ]);

  final _buffer = _SocketReadBuffer();
  StreamSubscription<List<int>>? _subscription;
  
  // Hot path state - mutable primitives, no allocations
  Map<String, dynamic>? _activeHeader;
  _OutputTarget? _activeTarget;
  int _totalBytes = 0;
  int _bytesWritten = 0;
  int _lastProgressPercent = -1;
  int _lastProgressUpdateMs = 0;
  Stopwatch? _stopwatch;
  
  // Pending file transfer (parsed but not yet started)
  Map<String, dynamic>? _pendingHeader;
  int _pendingPayloadLength = 0;
  
  // Connection state
  var _probeHandled = false;
  var _errorSent = false;
  var _socketClosed = false;
  var _processing = false;

  void start() {
    if (!waitForProbe) {
      _probeHandled = true;
    } else {
      Future.delayed(_probeTimeout, _handleProbeTimeout);
    }
    _subscription = socket.listen(
      _onData, 
      onDone: _onDone, 
      onError: _onError,
    );
  }

  void _handleProbeTimeout() {
    if (!_probeHandled) {
      _sendError('Could not establish the connection. Check the TLS setting on both devices.');
      _closeSocket();
    }
  }

  void _onData(List<int> data) {
    _buffer.add(data);
    // Backpressure: if already processing, let it complete and return
    if (_processing) return;
    _processFramesSync();
  }

  /// Process frames synchronously until we hit an await or run out of data.
  void _processFramesSync() {
    _processing = true;
    
    while (!_socketClosed) {
      if (_activeTarget == null) {
        final action = _tryProcessHeaderFrameSync();
        if (action == null) {
          // Need async (file creation) - _pendingHeader/_pendingPayloadLength already set
          _subscription?.pause();
          _beginPendingFileTransfer().then((_) {
            _subscription?.resume();
            _processing = false;
            // Check if more data arrived while paused
            if (_buffer.availableBytes > 0 && !_socketClosed) {
              _processFramesSync();
            }
          });
          return;
        }
        if (action.shouldClose) _closeSocket();
        if (!action.shouldContinue || _socketClosed) break;
      } else {
        final action = _processFileData();
        if (action.shouldClose) _closeSocket();
        if (!action.shouldContinue || _socketClosed) break;
      }
    }
    
    _processing = false;
  }

  /// Synchronous header frame processing. Returns null if async needed.
  _FrameAction? _tryProcessHeaderFrameSync() {
    final frameHeader = _buffer.tryPeekFrameHeader();
    if (frameHeader == null || _buffer.availableBytes < 8 + frameHeader.headerLength) {
      return _FrameAction.wait;
    }

    _buffer.skipBytes(8);
    final headerBytes = _buffer.tryReadBytes(frameHeader.headerLength)!;
    final header = jsonDecode(utf8.decode(headerBytes)) as Map<String, dynamic>;

    final isControlFrame = header.containsKey('type') || header.containsKey('ok');
    
    // Control frames can be handled sync
    if (isControlFrame && frameHeader.payloadLength == 0) {
      return _handleControlFrameSync(header);
    }
    
    // File transfer needs async (file creation) - store for async path
    _pendingHeader = header;
    _pendingPayloadLength = frameHeader.payloadLength;
    return null;
  }

  Future<void> _beginPendingFileTransfer() async {
    final header = _pendingHeader;
    final payloadLength = _pendingPayloadLength;
    _pendingHeader = null;
    _pendingPayloadLength = 0;
    
    if (header == null) return;
    
    await _beginFileTransfer(header, payloadLength);
  }

  _FrameAction _handleControlFrameSync(Map<String, dynamic> header) {
    if (!_probeHandled) return _handleProbe(header);

    final type = header['type'];
    return switch (type) {
      'ping' => _respondToPing(),
      'pong' => _FrameAction.continueReading,
      'file_received_ack' => _handleFileAck(header),
      'file_receive_progress' => _handleProgressReport(header),
      'disconnect' => _handleDisconnectSync(),
      _ => _FrameAction.continueReading,
    };
  }

  _FrameAction _handleProbe(Map<String, dynamic> header) {
    _probeHandled = true;

    final ok = header['ok'];
    if (ok != null) {
      if (ok == true) {
        toUiSendPort.send(['connected_to_host']);
        return _FrameAction.continueReading;
      }
      _sendError(header['error'] as String? ?? 'Could not establish the connection.');
      return _FrameAction.close;
    }

    if (header['type'] == 'probe') {
      final clientWantsTls = header['tls'] == true;
      _writeFrameUtf8(clientWantsTls
          ? '{"ok":false,"error":"TLS mismatch: server does not use TLS, client has TLS enabled"}'
          : '{"ok":true,"tls":false}');

      if (clientWantsTls) {
        _sendError('TLS settings do not match on both devices.', fatal: false);
        return _FrameAction.close;
      }
      toUiSendPort.send(['client_connected']);
    }
    return _FrameAction.continueReading;
  }

  _FrameAction _respondToPing() {
    socket.add(_pongFrame);
    return _FrameAction.continueReading;
  }

  _FrameAction _handleFileAck(Map<String, dynamic> header) {
    final fileId = header['fileId'] as String?;
    if (fileId != null) {
      onTransferAcknowledged?.call(fileId);
      toUiSendPort.send([
        'send_complete',
        fileId,
        header['fileName'],
        header['timeTaken'],
      ]);
    }
    return _FrameAction.continueReading;
  }

  _FrameAction _handleProgressReport(Map<String, dynamic> header) {
    final fileId = header['fileId'] as String?;
    final progress = (header['progress'] as num?)?.toDouble();
    if (fileId != null && progress != null) {
      toUiSendPort.send(['send_progress', fileId, progress.clamp(0.0, 1.0)]);
    }
    return _FrameAction.continueReading;
  }

  _FrameAction _handleDisconnectSync() {
    _cleanupPartialTransferSync();
    toUiSendPort.send(['disconnect']);
    return _FrameAction.close;
  }

  Future<_FrameAction> _beginFileTransfer(Map<String, dynamic> header, int payloadLength) async {
    final target = await _createOutputTarget(
      configuredDownloadDirectory: configuredDownloadDirectory,
      originalFileName: header['name'] as String,
    );

    toUiSendPort.send([
      'start',
      header['uuid'],
      target.fileName,
      target.filePath,
      payloadLength,
    ]);

    _activeHeader = header;
    _activeTarget = target;
    _totalBytes = payloadLength;
    _bytesWritten = 0;
    _lastProgressPercent = -1;
    _stopwatch = Stopwatch()..start();

    return _FrameAction.continueReading;
  }

  _FrameAction _processFileData() {
    final remaining = _totalBytes - _bytesWritten;

    if (remaining <= 0) {
      _completeFileTransfer();
      return _FrameAction.continueReading;
    }

    final written = _buffer.drainToSink(_activeTarget!.sink, maxBytes: remaining);
    if (written == 0) return _FrameAction.wait;

    _bytesWritten += written;
    _reportProgress();

    if (_bytesWritten >= _totalBytes) {
      _completeFileTransfer();
    }

    return _FrameAction.continueReading;
  }

  void _reportProgress({bool force = false}) {
    // Integer math first - only compute double if we'll actually send
    final percent = _totalBytes == 0 ? 100 : (_bytesWritten * 100) ~/ _totalBytes;
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    final shouldThrottle = !force &&
        (percent == _lastProgressPercent ||
            nowMs - _lastProgressUpdateMs < _progressUpdateIntervalMs);

    if (shouldThrottle) return;

    _lastProgressPercent = percent;
    _lastProgressUpdateMs = nowMs;

    // Now compute double for the payload
    final progress = _totalBytes == 0 ? 1.0 : _bytesWritten / _totalBytes;
    final fileId = _activeHeader!['uuid'] as String;

    // List instead of Map for isolate message
    toUiSendPort.send(['progress', fileId, progress]);

    // Hand-built JSON for hot frame
    _sendProgressFrame(fileId, progress);
  }

  /// Send progress frame with hand-built JSON - no jsonEncode overhead.
  void _sendProgressFrame(String fileId, double progress) {
    final json = '{"type":"file_receive_progress","fileId":"$fileId","progress":$progress}';
    _writeFrameUtf8(json);
  }

  /// Write a UTF-8 encoded JSON frame with single socket.add call.
  void _writeFrameUtf8(String json) {
    final payloadBytes = utf8.encode(json);
    final frame = Uint8List(8 + payloadBytes.length)
      ..buffer.asByteData().setUint32(0, payloadBytes.length, Endian.big);
    frame.setRange(8, 8 + payloadBytes.length, payloadBytes);
    socket.add(frame);
  }

  void _completeFileTransfer() {
    final timeTaken = _stopwatch!.elapsed.inSeconds.toString();
    final fileId = _activeHeader!['uuid'] as String;
    final target = _activeTarget!;

    _reportProgress(force: true);

    // Hand-built JSON for ack frame
    final json = '{"type":"file_received_ack","fileId":"$fileId","fileName":"${target.fileName}","timeTaken":"$timeTaken"}';
    _writeFrameUtf8(json);

    toUiSendPort.send([
      target.finalizeToTreeUri == null ? 'completed' : 'android_saf_finalize',
      fileId,
      timeTaken,
      target.finalizeToTreeUri ?? '',
      target.filePath,
      target.fileName,
    ]);

    _stopwatch!.stop();
    target.sink.close();
    _activeHeader = null;
    _activeTarget = null;
    _stopwatch = null;
  }

  void _sendError(String message, {bool fatal = true}) {
    if (_errorSent) return;
    _errorSent = true;
    _probeHandled = true;
    toUiSendPort.send(['error', fatal, message]);
  }

  void _closeSocket() {
    if (_socketClosed) return;
    _socketClosed = true;
    socket.destroy();
  }

  void _cleanupPartialTransferSync() {
    final target = _activeTarget;
    if (target == null) return;

    target.sink.close();
    try {
      File(target.filePath).deleteSync();
    } catch (_) {}
    
    _activeHeader = null;
    _activeTarget = null;
  }

  void _onDone() => _handleConnectionEnd(
    'Connection closed before the link was established. Check the TLS setting on both devices.',
    'Connection lost. The other device disconnected unexpectedly.',
  );

  void _onError(dynamic e) => _handleConnectionEnd(
    'Could not establish the connection. Check the TLS setting on both devices.',
    e.toString(),
  );

  void _handleConnectionEnd(String probeErrorMsg, String postProbeErrorMsg) {
    _cleanupOnDisconnect();
    if (!_probeHandled && !_errorSent) {
      _sendError(probeErrorMsg);
    } else if (!_errorSent && _activeTarget != null) {
      _sendError(postProbeErrorMsg, fatal: true);
    }
    _closeSocket();
  }

  void _cleanupOnDisconnect() {
    if (_activeTarget != null) {
      _cleanupPartialTransferSync();
    }
  }
}

/// Result of processing a frame.
enum _FrameAction {
  continueReading,
  wait,
  close;

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
