import 'dart:collection';
import 'dart:math';
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
import 'package:windowed_file_reader/windowed_file_reader.dart';

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
  bool isSendingFile = false;
  bool localDisconnectRequested = false;
  String? sendingFileId;
  final locallyPausedTransfers = <String, String>{};
  final remotelyPausedTransfers = <String, String>{};
  final locallyCancelledTransfers = <String>{};
  final remotelyCancelledTransfers = <String>{};

  bool isTransferPaused(String fileId) {
    return locallyPausedTransfers.containsKey(fileId) ||
        remotelyPausedTransfers.containsKey(fileId);
  }

  void sendTransferPausedState(String fileId, {String? pausedBy}) {
    final owner =
        pausedBy ??
        locallyPausedTransfers[fileId] ??
        remotelyPausedTransfers[fileId];
    toUiSendPort.send({
      'status': 'transfer_paused',
      'fileId': fileId,
      'pausedBy': ?owner,
      'canResume': locallyPausedTransfers.containsKey(fileId),
    });
  }

  void sendTransferResumeState(String fileId) {
    if (isTransferPaused(fileId)) {
      sendTransferPausedState(fileId);
      return;
    }

    toUiSendPort.send({'status': 'transfer_resumed', 'fileId': fileId});
  }

  void handleRemoteTransferPaused(String fileId, {String? pausedBy}) {
    remotelyPausedTransfers[fileId] = pausedBy ?? 'remote';
    sendTransferPausedState(fileId, pausedBy: pausedBy);
  }

  void handleRemoteTransferResumed(String fileId, {String? pausedBy}) {
    remotelyPausedTransfers.remove(fileId);
    sendTransferResumeState(fileId);
  }

  void handleRemoteTransferCancelled(String fileId) {
    remotelyCancelledTransfers.add(fileId);
    locallyPausedTransfers.remove(fileId);
    remotelyPausedTransfers.remove(fileId);
    toUiSendPort.send({'status': 'transfer_cancelled', 'fileId': fileId});
  }

  String transferControlType(String role, String action) {
    final normalizedRole = role == 'sender' ? 'sender' : 'receiver';
    return '${normalizedRole}_$action';
  }

  Future<void> processCommandQueue() async {
    if (isProcessing || commandQueue.isEmpty) return;
    isProcessing = true;

    while (commandQueue.isNotEmpty) {
      final command = commandQueue.removeFirst();

      try {
        if (command['command'] == 'connect') {
          final useTLS = command['useTLS'] ?? false;
          final localPeerInfo = <String, dynamic>{
            'type': 'peer_info',
            'name': command['deviceName'],
            'deviceType': command['deviceType'],
            'port': command['listeningPort'],
            'tls': useTLS,
          };

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
                  shouldSuppressConnectionErrors: () =>
                      localDisconnectRequested,
                  shouldCancelReceivingFile: (fileId) =>
                      locallyCancelledTransfers.contains(fileId),
                  localPeerInfo: localPeerInfo,
                  onRemoteTransferPaused: handleRemoteTransferPaused,
                  onRemoteTransferResumed: handleRemoteTransferResumed,
                  onRemoteTransferCancelled: handleRemoteTransferCancelled,
                );
              },
              onError: (error) {
                print('[SERVER_TLS] listen error: $error');
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
                  shouldSuppressConnectionErrors: () =>
                      localDisconnectRequested,
                  shouldCancelReceivingFile: (fileId) =>
                      locallyCancelledTransfers.contains(fileId),
                  localPeerInfo: localPeerInfo,
                  onRemoteTransferPaused: handleRemoteTransferPaused,
                  onRemoteTransferResumed: handleRemoteTransferResumed,
                  onRemoteTransferCancelled: handleRemoteTransferCancelled,
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
                  shouldSuppressConnectionErrors: () =>
                      localDisconnectRequested,
                  shouldCancelReceivingFile: (fileId) =>
                      locallyCancelledTransfers.contains(fileId),
                  localPeerInfo: localPeerInfo,
                  onRemoteTransferPaused: handleRemoteTransferPaused,
                  onRemoteTransferResumed: handleRemoteTransferResumed,
                  onRemoteTransferCancelled: handleRemoteTransferCancelled,
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
                'message': _clientConnectErrorMessage(
                  error: e,
                  host: command['host'] as String?,
                  port: command['port'] as int?,
                  useTLS: useTLS,
                ),
              });
            }
          }
        } else if (command['command'] == 'send_file') {
          if (localDisconnectRequested) {
            continue;
          }
          if (clientSocket == null) {
            toUiSendPort.send({
              'status': 'error',
              'fatal': 'true',
              'message': 'Socket not connected',
            });
            continue;
          }

          try {
            isSendingFile = true;
            sendingFileId = await _sendFileCommand(
              command,
              clientSocket!,
              toUiSendPort,
              shouldCancel: () => localDisconnectRequested,
              shouldPauseTransfer: isTransferPaused,
              shouldCancelTransfer: (fileId) =>
                  locallyCancelledTransfers.contains(fileId) ||
                  remotelyCancelledTransfers.contains(fileId),
            );
            if (sendingFileId != null) {
              locallyPausedTransfers.remove(sendingFileId);
              remotelyPausedTransfers.remove(sendingFileId);
              locallyCancelledTransfers.remove(sendingFileId);
              remotelyCancelledTransfers.remove(sendingFileId);
            }
          } on _TransferCancelled {
            sendingFileId = null;
          } finally {
            isSendingFile = false;
          }
        } else if (command['command'] == 'pause_transfer') {
          final fileId = command['fileId'] as String?;
          final role = command['role'] as String? ?? 'receiver';
          if (fileId != null) {
            locallyPausedTransfers[fileId] = role;
            await _sendTransferControlFrame(clientSocket, {
              'type': transferControlType(role, 'paused'),
              'fileId': fileId,
            });
            sendTransferPausedState(fileId);
          }
        } else if (command['command'] == 'resume_transfer') {
          final fileId = command['fileId'] as String?;
          final role = command['role'] as String? ?? 'receiver';
          if (fileId != null) {
            locallyPausedTransfers.remove(fileId);
            await _sendTransferControlFrame(clientSocket, {
              'type': transferControlType(role, 'resumed'),
              'fileId': fileId,
            });
            sendTransferResumeState(fileId);
          }
        } else if (command['command'] == 'cancel_transfer') {
          final fileId = command['fileId'] as String?;
          if (fileId != null) {
            locallyCancelledTransfers.add(fileId);
            locallyPausedTransfers.remove(fileId);
            remotelyPausedTransfers.remove(fileId);
            await _sendTransferControlFrame(clientSocket, {
              'type': 'file_transfer_cancel',
              'fileId': fileId,
            });
            toUiSendPort.send({
              'status': 'transfer_cancelled',
              'fileId': fileId,
            });
          }
        } else if (command['command'] == "disconnect") {
          localDisconnectRequested = true;
          final header = utf8.encode(
            jsonEncode({
              'type': 'disconnect',
            }),
          );
          final byteData = ByteData(8);
          byteData.setUint32(0, header.length);
          byteData.setUint32(4, 0);

          try {
            if (!isSendingFile && clientSocket != null) {
              clientSocket!.add(byteData.buffer.asUint8List());
              clientSocket!.add(header);
              await clientSocket!.flush();
            }
          } catch (_) {}
          try {
            clientSocket?.destroy();
            await serverSocket?.close();
          } catch (_) {}
          toUiSendPort.send({'command': 'disconnect'});
        }
      } catch (e) {
        if (localDisconnectRequested) {
          continue;
        }
        toUiSendPort.send({
          'status': 'error',
          'fatal': 'false',
          'message': 'Command processing error: ${e.toString()}',
        });
      }
    }

    isProcessing = false;
  }

  fromUiReceivePort.listen((message) async {
    final command = message as Map<String, dynamic>;
    if (command['command'] == 'disconnect') {
      localDisconnectRequested = true;
      if (isSendingFile) {
        try {
          clientSocket?.destroy();
          serverSocket?.close();
        } catch (_) {}
      }
    } else if (command['command'] == 'pause_transfer') {
      final fileId = command['fileId'] as String?;
      final role = command['role'] as String? ?? 'receiver';
      if (fileId != null) {
        locallyPausedTransfers[fileId] = role;
        await _sendTransferControlFrame(clientSocket, {
          'type': transferControlType(role, 'paused'),
          'fileId': fileId,
        });
        sendTransferPausedState(fileId);
        return;
      }
    } else if (command['command'] == 'resume_transfer') {
      final fileId = command['fileId'] as String?;
      final role = command['role'] as String? ?? 'receiver';
      if (fileId != null) {
        locallyPausedTransfers.remove(fileId);
        await _sendTransferControlFrame(clientSocket, {
          'type': transferControlType(role, 'resumed'),
          'fileId': fileId,
        });
        sendTransferResumeState(fileId);
        return;
      }
    } else if (command['command'] == 'cancel_transfer') {
      final fileId = command['fileId'] as String?;
      if (fileId != null) {
        locallyCancelledTransfers.add(fileId);
        locallyPausedTransfers.remove(fileId);
        remotelyPausedTransfers.remove(fileId);
        await _sendTransferControlFrame(clientSocket, {
          'type': 'file_transfer_cancel',
          'fileId': fileId,
        });
        toUiSendPort.send({'status': 'transfer_cancelled', 'fileId': fileId});
        return;
      }
    }
    commandQueue.add(command);
    processCommandQueue();
  });
}

class _TransferCancelled implements Exception {
  const _TransferCancelled();
}

String _clientConnectErrorMessage({
  required Object error,
  required String? host,
  required int? port,
  required bool useTLS,
}) {
  final details = error.toString();
  final endpoint = host == null || port == null
      ? 'the receiver'
      : '$host:$port';

  if (error is SocketException) {
    return 'Could not reach $endpoint. Check that the IP address and port are correct, both devices are on the same network, and the receiver server is running.\n\nDetails: $details';
  }

  return useTLS
      ? 'This device has TLS enabled, but the other device appears to have TLS disabled or an incompatible certificate. Disable TLS on this device, or enable TLS on the other device, then try again.\n\nDetails: $details'
      : 'This device has TLS disabled, but the other device appears to require TLS. Enable TLS on this device, or disable TLS on the other device, then try again.\n\nDetails: $details';
}

Future<String?> _sendFileCommand(
  Map<String, dynamic> command,
  dynamic clientSocket,
  SendPort toUiSendPort, {
  required bool Function() shouldCancel,
  required bool Function(String fileId) shouldPauseTransfer,
  required bool Function(String fileId) shouldCancelTransfer,
}) async {
  final filePath = command['filePath'] as String;
  File? fileToSend;
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
        fileToSend = File('/proc/self/fd/$androidFileDescriptor');
      } catch (_) {
        cachedFile = await toFile(filePath);
        fileToSend = cachedFile;
      }

      fileHeader = {
        'uuid': Uuid().v4(),
        'name': fileStats.name,
        'size': fileStats.length,
      };
    } else {
      fileToSend = File(filePath);
      final fileStats = await fileToSend.stat();

      fileHeader = {
        'uuid': Uuid().v4(),
        'name': filePath.split('/').last,
        'size': fileStats.size,
      };
    }

    await _sendSocketFrame(clientSocket, {
      'type': 'file_start',
      'uuid': fileHeader['uuid'],
      'name': fileHeader['name'],
      'size': fileHeader['size'],
    });

    toUiSendPort.send({
      'status': 'send_start',
      'fileId': fileHeader['uuid'],
      'fileName': fileHeader['name'],
      'fileSize': fileHeader['size'],
      'filePath': command['filePath'],
    });

    await _sendFileWithWindowedReader(
      fileId: fileHeader['uuid'] as String,
      file: fileToSend,
      fileSize: fileHeader['size'] as int,
      clientSocket: clientSocket,
      shouldCancel: shouldCancel,
      shouldPauseTransfer: shouldPauseTransfer,
      shouldCancelTransfer: shouldCancelTransfer,
    );
    await _sendSocketFrame(clientSocket, {
      'type': 'file_end',
      'fileId': fileHeader['uuid'],
    });
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
    if (e is _TransferCancelled ||
        shouldCancel() ||
        (fileHeader != null &&
            shouldCancelTransfer(fileHeader['uuid'] as String))) {
      if (fileHeader != null) {
        await _sendSocketFrame(clientSocket, {
          'type': 'file_end',
          'fileId': fileHeader['uuid'],
          'cancelled': true,
        });
        toUiSendPort.send({
          'status': 'transfer_cancelled',
          'fileId': fileHeader['uuid'],
        });
        toUiSendPort.send({
          'status': 'transfer_cancel_ready',
          'fileId': fileHeader['uuid'],
        });
        return fileHeader['uuid'] as String;
      }
      return null;
    }
    toUiSendPort.send({
      'status': 'error',
      'fatal': 'false',
      'message': 'File send error: ${e.toString()}',
    });
    rethrow;
  }
}

Future<void> _sendFileWithWindowedReader({
  required String fileId,
  required File file,
  required int fileSize,
  required dynamic clientSocket,
  required bool Function() shouldCancel,
  required bool Function(String fileId) shouldPauseTransfer,
  required bool Function(String fileId) shouldCancelTransfer,
}) async {
  const int windowSize = 65536;
  if (fileSize <= 0) {
    return;
  }

  final effectiveWindowSize = min(windowSize, fileSize);
  final reader = DefaultWindowedFileReader(
    file,
    windowSize: effectiveWindowSize,
  );

  await reader.initialize();
  try {
    var currentPosition = 0;
    final lastWindowStart = max(0, fileSize - effectiveWindowSize);

    while (currentPosition < fileSize) {
      while (!shouldCancel() &&
          !shouldCancelTransfer(fileId) &&
          shouldPauseTransfer(fileId)) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      if (shouldCancel() || shouldCancelTransfer(fileId)) {
        throw const _TransferCancelled();
      }
      final windowStart = min(currentPosition, lastWindowStart);
      final offset = currentPosition - windowStart;

      await reader.jumpTo(windowStart);
      final Uint8List windowBuffer = reader.view();

      final bytesToSend = min(
        effectiveWindowSize - offset,
        fileSize - currentPosition,
      );
      final actualChunk = windowBuffer.sublist(offset, offset + bytesToSend);

      await _sendSocketFrame(
        clientSocket,
        {
          'type': 'file_chunk',
          'fileId': fileId,
        },
        payloadBytes: actualChunk,
      );
      if (shouldCancel() || shouldCancelTransfer(fileId)) {
        throw const _TransferCancelled();
      }
      currentPosition += bytesToSend;
    }
  } finally {
    await reader.dispose();
  }
}

void _configureSocketForTransfer(dynamic socket) {
  try {
    socket.setOption(SocketOption.tcpNoDelay, true);
  } catch (_) {}
}

Future<void> _sendTransferControlFrame(
  dynamic socket,
  Map<String, dynamic> payload,
) async {
  await _sendSocketFrame(socket, payload);
}

Future<void> _sendSocketFrame(
  dynamic socket,
  Map<String, dynamic> payload, {
  Uint8List? payloadBytes,
}) async {
  if (socket == null) {
    return;
  }
  try {
    final header = ByteData(8);
    final bodyBytes = payloadBytes;
    final metadataBytes = utf8.encode(jsonEncode(payload));
    header.setUint32(0, metadataBytes.length, Endian.big);
    header.setUint32(4, bodyBytes?.length ?? 0, Endian.big);
    socket.add(header.buffer.asUint8List());
    socket.add(metadataBytes);
    if (bodyBytes != null && bodyBytes.isNotEmpty) {
      socket.add(bodyBytes);
    }
    await socket.flush();
  } catch (_) {}
}

void _handleSocketConnection(
  dynamic socket,
  SendPort toUiSendPort, {
  bool waitForProbe = false,
  String? configuredDownloadDirectory,
  bool Function()? shouldSuppressConnectionErrors,
  bool Function(String fileId)? shouldCancelReceivingFile,
  void Function(String fileId)? onTransferAcknowledged,
  void Function(String fileId, {String? pausedBy})? onRemoteTransferPaused,
  void Function(String fileId, {String? pausedBy})? onRemoteTransferResumed,
  void Function(String fileId)? onRemoteTransferCancelled,
  required Map<String, dynamic> localPeerInfo,
}) {
  final readBuffer = _SocketReadBuffer();
  const progressUpdateInterval = Duration(milliseconds: 500);

  int? fileBytesLength;
  int bytesWritten = 0;
  int lastProgressPercent = -1;
  int? chunkBytesRemaining;
  bool isChunkedFileFrame = false;
  bool isDiscardingCancelledFile = false;
  DateTime lastProgressUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  IOSink? fileSink;
  _OutputTarget? activeOutputTarget;
  Map<String, dynamic>? activeFileHeader;

  final Stopwatch stopwatch = Stopwatch();

  bool probeHandled = !waitForProbe;
  bool connectionErrorSent = false;
  bool gracefulDisconnect = false;
  bool socketClosed = false;
  final localUsesTls = localPeerInfo['tls'] == true;

  Future<void> cleanupOpenFile() async {
    if (fileSink != null) {
      await fileSink!.close();
      fileSink = null;
    }
  }

  void resetFrameState() {
    fileBytesLength = null;
    activeFileHeader = null;
    bytesWritten = 0;
    lastProgressPercent = -1;
    chunkBytesRemaining = null;
    isChunkedFileFrame = false;
    isDiscardingCancelledFile = false;
  }

  Future<void> discardPartialOutput() async {
    final target = activeOutputTarget;
    if (target == null) {
      return;
    }

    await cleanupOpenFile();

    try {
      final file = File(target.filePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}

    activeOutputTarget = null;
    resetFrameState();
  }

  Future<void> discardActiveOutputForCancel() async {
    final target = activeOutputTarget;
    await cleanupOpenFile();

    if (target != null) {
      try {
        final file = File(target.filePath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    }

    activeOutputTarget = null;
  }

  void sendControlFrame(Map<String, dynamic> payload) {
    final payloadBytes = utf8.encode(jsonEncode(payload));
    final header = ByteData(8);
    header.setUint32(0, payloadBytes.length, Endian.big);
    header.setUint32(4, 0, Endian.big);
    socket.add(header.buffer.asUint8List());
    socket.add(payloadBytes);
  }

  void sendLocalPeerInfo() {
    sendControlFrame(localPeerInfo);
  }

  void closeSocket() {
    if (socketClosed) {
      return;
    }
    socketClosed = true;
    socket.destroy();
  }

  void sendConnectionError(
    String message, {
    bool fatal = true,
    bool markProbeHandled = true,
  }) {
    if (connectionErrorSent) {
      return;
    }
    connectionErrorSent = true;
    if (markProbeHandled) {
      probeHandled = true;
    }
    toUiSendPort.send({
      'status': 'error',
      'fatal': fatal,
      'message': message,
    });
  }

  String tlsHandshakeFailureMessage() {
    if (localUsesTls) {
      return 'This device has TLS enabled, but the other device appears to have TLS disabled. Disable TLS on this device, or enable TLS on the other device, then try again.';
    }

    return 'This device has TLS disabled, but the other device appears to require TLS. Enable TLS on this device, or disable TLS on the other device, then try again.';
  }

  void sendProgress({bool force = false}) {
    final totalBytes = fileBytesLength;
    final header = activeFileHeader;
    if (totalBytes == null || header == null) {
      return;
    }

    final progress = totalBytes == 0
        ? 1.0
        : (bytesWritten / totalBytes).clamp(0.0, 1.0);
    final percent = (progress * 100).floor();
    final now = DateTime.now();
    if (!force &&
        percent == lastProgressPercent &&
        now.difference(lastProgressUpdate) < progressUpdateInterval) {
      return;
    }
    if (!force &&
        percent < 100 &&
        now.difference(lastProgressUpdate) < progressUpdateInterval) {
      return;
    }

    lastProgressPercent = percent;
    lastProgressUpdate = now;
    toUiSendPort.send({
      'status': 'progress',
      'fileId': header['uuid'],
      'progress': progress,
    });
    sendControlFrame({
      'type': 'file_receive_progress',
      'fileId': header['uuid'],
      'progress': progress,
    });
  }

  Future<bool> handleControlFrame(Map<String, dynamic> headerJson) async {
    if (!probeHandled) {
      probeHandled = true;
      final ok = headerJson['ok'];
      if (ok != null) {
        if (ok == true) {
          sendLocalPeerInfo();
          toUiSendPort.send({'status': 'connected_to_host'});
          return true;
        }
        sendConnectionError(
          headerJson['error'] as String? ??
              'Could not establish the connection. Check the TLS setting on both devices.',
        );
        closeSocket();
        return false;
      }

      if (headerJson['type'] == 'probe') {
        final clientWantsTls = headerJson['tls'] == true;
        final response = clientWantsTls
            ? {
                'ok': false,
                'error':
                    'This device has TLS disabled, but the connecting device has TLS enabled. Enable TLS on this device, or ask the other device to disable TLS, then try again.',
              }
            : {'ok': true, 'tls': false};
        sendControlFrame(response);

        if (clientWantsTls) {
          sendConnectionError(
            'This device has TLS disabled, but the connecting device has TLS enabled. Enable TLS on this device, or ask the other device to disable TLS, then try again.',
            fatal: false,
          );
          closeSocket();
          return false;
        }

        sendLocalPeerInfo();
        toUiSendPort.send({'status': 'client_connected'});
        return true;
      }
    }

    switch (headerJson['type']) {
      case 'ping':
        sendControlFrame({'type': 'pong'});
        return true;
      case 'pong':
        return true;
      case 'peer_info':
        toUiSendPort.send({
          'status': 'peer_info',
          'name': headerJson['name'] is String
              ? headerJson['name']
              : 'Connected device',
          'deviceType': headerJson['deviceType'] == 'laptop'
              ? 'laptop'
              : 'phone',
          'port': headerJson['port'] is int ? headerJson['port'] : null,
          'tls': headerJson['tls'] == true,
          'address': socket.remoteAddress.address,
        });
        return true;
      case 'file_received_ack':
        final fileId = headerJson['fileId'] as String?;
        if (fileId != null) {
          onTransferAcknowledged?.call(fileId);
          toUiSendPort.send({
            'status': 'send_complete',
            'fileId': fileId,
            'fileName': headerJson['fileName'],
            'timeTaken': headerJson['timeTaken'],
          });
        }
        return true;
      case 'file_receive_progress':
        final fileId = headerJson['fileId'] as String?;
        final progress = (headerJson['progress'] as num?)?.toDouble();
        if (fileId != null && progress != null) {
          toUiSendPort.send({
            'status': 'send_progress',
            'fileId': fileId,
            'progress': progress.clamp(0.0, 1.0),
          });
        }
        return true;
      case 'sender_paused':
      case 'receiver_paused':
      case 'file_transfer_pause':
        final fileId = headerJson['fileId'] as String?;
        if (fileId != null) {
          final frameType = headerJson['type'] as String?;
          final pausedBy = switch (frameType) {
            'sender_paused' => 'sender',
            'receiver_paused' => 'receiver',
            _ => null,
          };
          onRemoteTransferPaused?.call(fileId, pausedBy: pausedBy);
        }
        return true;
      case 'sender_resumed':
      case 'receiver_resumed':
      case 'file_transfer_resume':
        final fileId = headerJson['fileId'] as String?;
        if (fileId != null) {
          final frameType = headerJson['type'] as String?;
          final pausedBy = switch (frameType) {
            'sender_resumed' => 'sender',
            'receiver_resumed' => 'receiver',
            _ => null,
          };
          onRemoteTransferResumed?.call(fileId, pausedBy: pausedBy);
        }
        return true;
      case 'file_transfer_cancel':
        final fileId = headerJson['fileId'] as String?;
        if (fileId != null) {
          onRemoteTransferCancelled?.call(fileId);
          if (activeFileHeader?['uuid'] == fileId) {
            isDiscardingCancelledFile = true;
            await discardActiveOutputForCancel();
          }
        }
        return true;
      case 'disconnect':
        gracefulDisconnect = true;
        await discardPartialOutput();
        closeSocket();
        toUiSendPort.send({'command': 'disconnect'});
        return false;
    }

    return false;
  }

  Future<void> beginFileFrame(
    Map<String, dynamic> headerJson,
    int fileSize, {
    required bool chunked,
  }) async {
    final fileTarget = await _createOutputTarget(
      configuredDownloadDirectory: configuredDownloadDirectory,
      originalFileName: headerJson['name'] as String,
    );
    activeOutputTarget = fileTarget;
    activeFileHeader = headerJson;
    fileBytesLength = fileSize;
    fileSink = fileTarget.sink;
    isChunkedFileFrame = chunked;
    bytesWritten = 0;
    lastProgressPercent = -1;
    stopwatch
      ..reset()
      ..start();

    toUiSendPort.send({
      'status': 'start',
      'fileId': headerJson['uuid'],
      'fileName': fileTarget.fileName,
      'filePath': fileTarget.filePath,
      'fileSize': fileSize,
    });
  }

  Future<void> completeFileFrame() async {
    final target = activeOutputTarget!;
    final header = activeFileHeader!;
    final timeTaken = stopwatch.elapsed.inSeconds.toString();

    sendProgress(force: true);
    sendControlFrame({
      'type': 'file_received_ack',
      'fileId': header['uuid'],
      'fileName': target.fileName,
      'timeTaken': timeTaken,
    });

    toUiSendPort.send({
      'status': target.finalizeToTreeUri == null
          ? 'completed'
          : 'android_saf_finalize',
      'fileId': header['uuid'],
      'timeTaken': timeTaken,
      'treeUri': target.finalizeToTreeUri,
      'sourceFilePath': target.filePath,
      'fileName': target.fileName,
    });

    await cleanupOpenFile();
    stopwatch.stop();
    activeOutputTarget = null;
    resetFrameState();
  }

  Future<void> processBufferedFrames() async {
    while (!socketClosed) {
      final drainingCancelledFile =
          isDiscardingCancelledFile && activeFileHeader != null;
      if (fileSink == null && !drainingCancelledFile) {
        final frameHeader = readBuffer.tryPeekFrameHeader();
        if (frameHeader == null ||
            readBuffer.availableBytes < 8 + frameHeader.headerLength) {
          return;
        }

        readBuffer.skipBytes(8);
        final headerBytes = readBuffer.tryReadBytes(frameHeader.headerLength)!;
        final headerJson =
            jsonDecode(utf8.decode(headerBytes)) as Map<String, dynamic>;

        final frameType = headerJson['type'] as String?;
        final isControlFrame =
            headerJson.containsKey('type') || headerJson.containsKey('ok');
        if (frameHeader.payloadLength == 0 && isControlFrame) {
          if (frameType == 'file_start') {
            final fileSize = headerJson['size'] as int?;
            if (fileSize == null) {
              continue;
            }
            await beginFileFrame(headerJson, fileSize, chunked: true);
            continue;
          }
          final keepReading = await handleControlFrame(headerJson);
          if (!keepReading) {
            return;
          }
          continue;
        }

        if (frameType == 'file_chunk') {
          if (readBuffer.availableBytes < frameHeader.payloadLength) {
            return;
          }
          readBuffer.skipBytes(frameHeader.payloadLength);
          continue;
        }

        await beginFileFrame(
          headerJson,
          frameHeader.payloadLength,
          chunked: false,
        );
      }

      final sink = fileSink;
      final totalBytes = fileBytesLength;
      if ((!isDiscardingCancelledFile && sink == null) || totalBytes == null) {
        continue;
      }

      final activeFileId = activeFileHeader?['uuid'] as String?;
      if (activeFileId != null &&
          (shouldCancelReceivingFile?.call(activeFileId) ?? false) &&
          !isDiscardingCancelledFile) {
        isDiscardingCancelledFile = true;
        await discardActiveOutputForCancel();
      }

      if (isChunkedFileFrame) {
        if (chunkBytesRemaining == null) {
          final frameHeader = readBuffer.tryPeekFrameHeader();
          if (frameHeader == null ||
              readBuffer.availableBytes < 8 + frameHeader.headerLength) {
            return;
          }

          readBuffer.skipBytes(8);
          final headerBytes = readBuffer.tryReadBytes(
            frameHeader.headerLength,
          )!;
          final headerJson =
              jsonDecode(utf8.decode(headerBytes)) as Map<String, dynamic>;
          final frameType = headerJson['type'] as String?;

          if (frameHeader.payloadLength == 0) {
            if (frameType == 'file_start' && isDiscardingCancelledFile) {
              final fileSize = headerJson['size'] as int?;
              resetFrameState();
              if (fileSize != null) {
                await beginFileFrame(headerJson, fileSize, chunked: true);
              }
              continue;
            }
            if (frameType == 'file_end') {
              final wasCancelled = headerJson['cancelled'] == true;
              if (!isDiscardingCancelledFile && !wasCancelled) {
                await completeFileFrame();
              } else {
                final cancelledFileId =
                    (activeFileHeader?['uuid'] ?? headerJson['fileId'])
                        as String?;
                final shouldReportCancellation =
                    wasCancelled && !isDiscardingCancelledFile;
                if (wasCancelled && !isDiscardingCancelledFile) {
                  isDiscardingCancelledFile = true;
                  await discardActiveOutputForCancel();
                }
                if (cancelledFileId != null) {
                  if (shouldReportCancellation) {
                    toUiSendPort.send({
                      'status': 'transfer_cancelled',
                      'fileId': cancelledFileId,
                    });
                  }
                  toUiSendPort.send({
                    'status': 'transfer_cancel_ready',
                    'fileId': cancelledFileId,
                  });
                }
                resetFrameState();
              }
              continue;
            }

            final keepReading = await handleControlFrame(headerJson);
            if (!keepReading) {
              return;
            }
            continue;
          }

          if (frameType != 'file_chunk') {
            if (readBuffer.availableBytes < frameHeader.payloadLength) {
              return;
            }
            readBuffer.skipBytes(frameHeader.payloadLength);
            continue;
          }

          final chunkFileId = headerJson['fileId'] as String?;
          if (chunkFileId != activeFileId) {
            if (readBuffer.availableBytes < frameHeader.payloadLength) {
              return;
            }
            readBuffer.skipBytes(frameHeader.payloadLength);
            continue;
          }

          chunkBytesRemaining = frameHeader.payloadLength;
        }

        final remainingChunkBytes = chunkBytesRemaining!;
        if (remainingChunkBytes <= 0) {
          chunkBytesRemaining = null;
          continue;
        }

        final availableToDrain = min(
          remainingChunkBytes,
          readBuffer.availableBytes,
        );
        if (availableToDrain == 0) {
          return;
        }

        if (isDiscardingCancelledFile || fileSink == null) {
          readBuffer.skipBytes(availableToDrain);
        } else {
          final writtenNow = readBuffer.drainToSink(
            sink!,
            maxBytes: availableToDrain,
          );
          bytesWritten += writtenNow;
          sendProgress();
        }
        chunkBytesRemaining = remainingChunkBytes - availableToDrain;
        if (chunkBytesRemaining == 0) {
          chunkBytesRemaining = null;
        }
        continue;
      }

      final remainingBytes = totalBytes - bytesWritten;
      if (remainingBytes <= 0) {
        await completeFileFrame();
        continue;
      }

      final writtenNow = isDiscardingCancelledFile || fileSink == null
          ? min(remainingBytes, readBuffer.availableBytes)
          : readBuffer.drainToSink(
              sink!,
              maxBytes: remainingBytes,
            );
      if (writtenNow == 0) {
        return;
      }
      if (isDiscardingCancelledFile || fileSink == null) {
        readBuffer.skipBytes(writtenNow);
      }

      bytesWritten += writtenNow;
      if (!isDiscardingCancelledFile) {
        sendProgress();
      }

      if (bytesWritten == totalBytes) {
        if (isDiscardingCancelledFile) {
          resetFrameState();
        } else {
          await completeFileFrame();
        }
      }
    }
  }

  if (waitForProbe) {
    Future.delayed(const Duration(seconds: 5), () {
      if (!probeHandled && !(shouldSuppressConnectionErrors?.call() ?? false)) {
        sendConnectionError(tlsHandshakeFailureMessage());
        closeSocket();
      }
    });
  }

  if (!waitForProbe) {
    sendLocalPeerInfo();
  }

  late StreamSubscription<List<int>> subscription;
  subscription = socket.listen(
    (data) async {
      subscription.pause();
      try {
        readBuffer.add(data);
        await processBufferedFrames();
      } finally {
        if (!socketClosed) {
          subscription.resume();
        }
      }
    },
    onDone: () {
      unawaited(
        activeOutputTarget == null ? cleanupOpenFile() : discardPartialOutput(),
      );
      final suppressErrors = shouldSuppressConnectionErrors?.call() ?? false;
      if (suppressErrors) {
        gracefulDisconnect = true;
      }

      if (!probeHandled && !connectionErrorSent && !suppressErrors) {
        sendConnectionError(tlsHandshakeFailureMessage());
      } else if (!connectionErrorSent &&
          !gracefulDisconnect &&
          !suppressErrors) {
        toUiSendPort.send({
          'status': 'error',
          'fatal': 'true',
          'message':
              'Connection lost. The other device disconnected unexpectedly.',
        });
      }
      closeSocket();
    },
    onError: (e) {
      unawaited(
        activeOutputTarget == null ? cleanupOpenFile() : discardPartialOutput(),
      );
      final suppressErrors = shouldSuppressConnectionErrors?.call() ?? false;
      if (suppressErrors) {
        gracefulDisconnect = true;
      }

      if (!probeHandled && !suppressErrors) {
        sendConnectionError(tlsHandshakeFailureMessage());
      } else if (!connectionErrorSent &&
          !gracefulDisconnect &&
          !suppressErrors) {
        toUiSendPort.send({
          'status': 'error',
          'fatal': 'true',
          'message': e.toString(),
        });
      }
      closeSocket();
    },
  );
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
