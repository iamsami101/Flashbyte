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

  final List<Map<String, dynamic>> commandQueue = [];
  bool isProcessing = false;
  bool isSendingFile = false;

  Future<void> processCommandQueue() async {
    if (isProcessing || commandQueue.isEmpty) return;
    isProcessing = true;

    while (commandQueue.isNotEmpty) {
      final command = commandQueue.removeAt(0);

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
                  canSendHeartbeat: () => !isSendingFile,
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
                print('[CLIENT_TLS] connected successfully');
                clientSocket = finalSocket;
                toUiSendPort.send({'status': 'connected_to_host'});
                _handleSocketConnection(
                  clientSocket!,
                  toUiSendPort,
                  configuredDownloadDirectory:
                      command['downloadDirectory'] as String?,
                );
              } else {
                // Non-TLS: send probe, then hand off to _handleSocketConnection
                // which handles both the probe response and subsequent file transfers
                finalSocket = await Socket.connect(
                  command['host'],
                  command['port'],
                );
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
                  canSendHeartbeat: () => !isSendingFile,
                  configuredDownloadDirectory:
                      command['downloadDirectory'] as String?,
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

          isSendingFile = true;
          try {
            await _sendFileCommand(command, clientSocket!, toUiSendPort);
          } finally {
            isSendingFile = false;
          }
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

Future<void> _sendFileCommand(
  Map<String, dynamic> command,
  dynamic clientSocket,
  SendPort toUiSendPort,
) async {
  final filePath = command['filePath'] as String;
  Stream<List<int>>? fileStream;
  Map<String, dynamic>? fileHeader;

  final stopwatch = Stopwatch()..start();

  File? cachedFile;

  try {
    if (Platform.isAndroid) {
      cachedFile = await toFile(filePath);
      fileStream = cachedFile.openRead();
      final fileStats = await SafUtil().stat(filePath, false);

      fileHeader = {
        'uuid': Uuid().v4(),
        'name': fileStats!.name,
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

    int bytesSent = 0;
    final totalBytes = fileHeader['size'] as int;

    toUiSendPort.send({
      'status': 'send_start',
      'fileId': fileHeader['uuid'],
      'fileName': fileHeader['name'],
      'fileSize': fileHeader['size'],
      'filePath': command['filePath'],
    });

    await for (final chunk in fileStream) {
      clientSocket.add(chunk);
      bytesSent += chunk.length;

      final progress = (bytesSent / totalBytes).clamp(0.0, 1.0);

      toUiSendPort.send({
        'status': 'send_progress',
        'progress': progress,
      });
    }

    stopwatch.stop();

    toUiSendPort.send({
      'status': 'send_complete',
      'fileId': fileHeader['uuid'],
      'fileName': fileHeader['name'],
      'timeTaken': stopwatch.elapsed.inSeconds.toString(),
    });

    try {
      cachedFile?.delete();
    } on Exception catch (_) {}
  } catch (e) {
    stopwatch.stop();
    toUiSendPort.send({
      'status': 'error',
      'fatal': 'false',
      'message': 'File send error: ${e.toString()}',
    });
  }
}

void _handleSocketConnection(
  dynamic socket,
  SendPort toUiSendPort, {
  bool waitForProbe = false,
  bool Function()? canSendHeartbeat,
  String? configuredDownloadDirectory,
}) {
  List<int> buffer = [];

  int? headerLength;
  int? fileBytesLength;

  int bytesWritten = 0;

  IOSink? fileSink;
  _OutputTarget? activeOutputTarget;

  final Stopwatch stopwatch = Stopwatch();

  Map<String, dynamic>? headerJson;
  bool probeHandled = !waitForProbe;
  bool connectionErrorSent = false;
  bool gracefulDisconnect = false;
  bool heartbeatEnabled = !waitForProbe;
  bool awaitingHeartbeatResponse = false;
  Timer? heartbeatTimer;

  Future<void> cleanupOpenFile() async {
    if (fileSink != null) {
      await fileSink!.close();
      fileSink = null;
    }
  }

  void sendControlFrame(Map<String, dynamic> payload) {
    final payloadBytes = utf8.encode(jsonEncode(payload));
    final header = ByteData(8);
    header.setUint32(0, payloadBytes.length, Endian.big);
    header.setUint32(4, 0, Endian.big);
    socket.add(header.buffer.asUint8List());
    socket.add(payloadBytes);
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
    heartbeatTimer?.cancel();
    toUiSendPort.send({
      'status': 'error',
      'fatal': fatal,
      'message': message,
    });
  }

  heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (_) {
    if (!heartbeatEnabled || gracefulDisconnect || connectionErrorSent) {
      return;
    }
    if (canSendHeartbeat != null && !canSendHeartbeat()) {
      return;
    }
    if (fileSink != null) {
      return;
    }
    if (awaitingHeartbeatResponse) {
      sendConnectionError(
        'Connection lost. The other device is no longer responding.',
        markProbeHandled: false,
      );
      socket.destroy();
      return;
    }
    awaitingHeartbeatResponse = true;
    sendControlFrame({'type': 'ping'});
  });

  if (waitForProbe) {
    Future.delayed(const Duration(seconds: 5), () {
      if (!probeHandled) {
        sendConnectionError(
          'Could not establish the connection. Check the TLS setting on both devices.',
        );
        socket.destroy();
      }
    });
  }

  socket.listen(
    (data) async {
      stopwatch.start();
      buffer.addAll(data);

      while (true) {
        var madeProgress = false;

        // Extracting the 8 Bytes Header
        if (headerLength == null || fileBytesLength == null) {
          if (buffer.length < 8) break;
          final first8BytesInt = Uint8List.fromList(buffer.sublist(0, 8));
          final first8ByteData = ByteData.sublistView(first8BytesInt);

          headerLength = first8ByteData.getUint32(0, Endian.big);
          fileBytesLength = first8ByteData.getUint32(4, Endian.big);

          buffer.removeRange(0, 8);
          madeProgress = true;
        }

        // Extracting the header JSON
        if (headerJson == null) {
          if (buffer.length < headerLength!) break;

          final jsonStr = utf8.decode(buffer.sublist(0, headerLength!));
          buffer.removeRange(0, headerLength!);
          headerJson = jsonDecode(jsonStr) as Map<String, dynamic>;
          madeProgress = true;

          // Probe handling (first message when waitForProbe is true)
          if (!probeHandled) {
            probeHandled = true;
            final ok = headerJson!['ok'];
            if (ok != null) {
              if (ok == true) {
                heartbeatEnabled = true;
                awaitingHeartbeatResponse = false;
                toUiSendPort.send({'status': 'connected_to_host'});
                headerLength = null;
                fileBytesLength = null;
                headerJson = null;
                continue;
              }
              sendConnectionError(
                headerJson!['error'] as String? ??
                    'Could not establish the connection. Check the TLS setting on both devices.',
              );
              socket.destroy();
              return;
            }
            if (headerJson!['type'] == 'probe') {
              final clientWantsTls = headerJson!['tls'] == true;
              Map<String, dynamic> resp;
              if (clientWantsTls) {
                resp = {
                  'ok': false,
                  'error':
                      'TLS mismatch: server does not use TLS, client has TLS enabled',
                };
              } else {
                resp = {'ok': true, 'tls': false};
              }
              final respBytes = utf8.encode(jsonEncode(resp));
              final respHeader = ByteData(8);
              respHeader.setUint32(0, respBytes.length, Endian.big);
              respHeader.setUint32(4, 0, Endian.big);
              socket.add(respHeader.buffer.asUint8List());
              socket.add(respBytes);

              if (clientWantsTls) {
                sendConnectionError(
                  'TLS settings do not match on both devices.',
                  fatal: false,
                );
                socket.destroy();
                return;
              }
              heartbeatEnabled = true;
              awaitingHeartbeatResponse = false;
              toUiSendPort.send({'status': 'client_connected'});
              headerLength = null;
              fileBytesLength = null;
              headerJson = null;
              buffer.clear();
              continue;
            }
          }

          if (headerJson!['type'] == 'ping') {
            awaitingHeartbeatResponse = false;
            sendControlFrame({'type': 'pong'});
            headerLength = null;
            fileBytesLength = null;
            headerJson = null;
            continue;
          }

          if (headerJson!['type'] == 'pong') {
            awaitingHeartbeatResponse = false;
            headerLength = null;
            fileBytesLength = null;
            headerJson = null;
            continue;
          }

          if (headerJson!['type'] == 'disconnect') {
            gracefulDisconnect = true;
            heartbeatTimer?.cancel();
            socket.destroy();
            toUiSendPort.send({'command': 'disconnect'});
            return;
          }

          // ——— file transfer metadata ———
          final fileTarget = await _createOutputTarget(
            configuredDownloadDirectory: configuredDownloadDirectory,
            originalFileName: headerJson!['name'] as String,
          );
          activeOutputTarget = fileTarget;
          fileSink = fileTarget.sink;

          toUiSendPort.send({
            'status': 'start',
            'fileId': headerJson!['uuid'],
            'fileName': fileTarget.fileName,
            'filePath': fileTarget.filePath,
            'fileSize': fileBytesLength!,
          });

          bytesWritten = 0;
        }

        // Writing the file bytes
        if (fileSink != null) {
          final remainingBytes = fileBytesLength! - bytesWritten;
          final bytesToWrite = buffer.length > remainingBytes
              ? remainingBytes
              : buffer.length;

          if (bytesToWrite == 0) break;

          fileSink!.add(buffer.sublist(0, bytesToWrite));
          bytesWritten += bytesToWrite;
          buffer.removeRange(0, bytesToWrite);
          madeProgress = true;

          toUiSendPort.send({
            'status': 'progress',
            'fileId': headerJson!['uuid'],
            'progress': bytesWritten / fileBytesLength!,
          });

          if (bytesWritten == fileBytesLength!) {
            toUiSendPort.send({
              'status': activeOutputTarget!.finalizeToTreeUri == null
                  ? 'completed'
                  : 'android_saf_finalize',
              'fileId': headerJson!['uuid'],
              'timeTaken': stopwatch.elapsed.inSeconds.toString(),
              'treeUri': activeOutputTarget!.finalizeToTreeUri,
              'sourceFilePath': activeOutputTarget!.filePath,
              'fileName': activeOutputTarget!.fileName,
            });

            await cleanupOpenFile();

            stopwatch.stop();
            stopwatch.reset();
            headerLength = null;
            fileBytesLength = null;
            headerJson = null;
            activeOutputTarget = null;
            bytesWritten = 0;
            continue;
          }
        }

        if (!madeProgress) break;
      }
    },
    onDone: () {
      heartbeatTimer?.cancel();
      unawaited(cleanupOpenFile());
      if (!probeHandled && !connectionErrorSent) {
        sendConnectionError(
          'Connection closed before the link was established. Check the TLS setting on both devices.',
        );
      }
      socket.destroy();
    },
    onError: (e) {
      heartbeatTimer?.cancel();
      unawaited(cleanupOpenFile());
      if (!probeHandled) {
        sendConnectionError(
          'Could not establish the connection. Check the TLS setting on both devices.',
        );
      } else if (!connectionErrorSent && !gracefulDisconnect) {
        toUiSendPort.send({
          'status': 'error',
          'fatal': 'true',
          'message': e.toString(),
        });
      }
      socket.destroy();
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
