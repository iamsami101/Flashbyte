import 'dart:io';
import 'dart:isolate';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:async';
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
                  print('[SERVER_TLS] cert exists=${certFile.existsSync()}, key exists=${keyFile.existsSync()}');
                  securityContext = SecurityContext(withTrustedRoots: false);
                  securityContext.useCertificateChain(certPath);
                  securityContext.usePrivateKey(keyPath);
                } else {
                  final certFile = File('certificates/server.crt');
                  final keyFile = File('certificates/server.key');
                  if (certFile.existsSync() && keyFile.existsSync()) {
                    securityContext = SecurityContext(withTrustedRoots: false);
                    securityContext.useCertificateChain('certificates/server.crt');
                    securityContext.usePrivateKey('certificates/server.key');
                  } else {
                    throw Exception('Certificate files not found.');
                  }
                }
                print('[SERVER_TLS] Certificate loaded successfully');
              } catch (e) {
                toUiSendPort.send({
                  'status': 'error', 'fatal': 'true',
                  'message': 'Failed to load certificate: ${e.toString()}',
                });
                return;
              }
            }

            if (useTLS) {
              serverSocket = await SecureServerSocket.bind(
                "0.0.0.0", command['port'], securityContext!, shared: true);
              print('[SERVER_TLS] SecureServerSocket bound successfully');
            } else {
              serverSocket = await ServerSocket.bind(
                "0.0.0.0", command['port'], shared: true);
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
                toUiSendPort.send({'status': 'client_connected'});
                _handleSocketConnection(savedClientSocket, toUiSendPort);
              },
              onError: (error) {
                print('[SERVER_TLS] listen error: $error');
                toUiSendPort.send({
                  'status': 'error', 'fatal': 'false',
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
                    securityContext.setTrustedCertificates('certificates/server.crt');
                  }
                }
              } catch (e) {
                print('[CLIENT_TLS] cert load error: ${e.toString()}');
              }
            }

            try {
              dynamic finalSocket;
              
              if (useTLS) {
                // TLS: connect via plain Socket then upgrade with SecureSocket.
                // The TLS handshake itself validates the server — no probe needed.
                final rawSocket = await Socket.connect(command['host'], command['port']);
                finalSocket = await SecureSocket.secure(
                  rawSocket,
                  host: 'localhost',
                  context: securityContext,
                );
                print('[CLIENT_TLS] connected successfully');
              } else {
                // Non-TLS: send a probe to verify the server also has TLS OFF.
                finalSocket = await Socket.connect(command['host'], command['port']);
                final probeMsg = jsonEncode({'type': 'probe', 'tls': false});
                final probeBytes = utf8.encode(probeMsg);
                final header = ByteData(8);
                header.setUint32(0, probeBytes.length, Endian.big);
                header.setUint32(4, 0, Endian.big);
                finalSocket.add(header.buffer.asUint8List());
                finalSocket.add(probeBytes);

                final resp = await _readProbeResponse(finalSocket);
                if (resp['ok'] != true) {
                  finalSocket.destroy();
                  toUiSendPort.send({
                    'status': 'error', 'fatal': 'true',
                    'message': resp['error'] ?? 'Connection rejected',
                  });
                  return;
                }
              }

              clientSocket = finalSocket;
              toUiSendPort.send({'status': 'connected_to_host'});
              _handleSocketConnection(clientSocket!, toUiSendPort);
            } catch (e) {
              print('[CLIENT_TLS] connect error: $e');
              toUiSendPort.send({
                'status': 'error', 'fatal': 'true',
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

          await _sendFileCommand(command, clientSocket!, toUiSendPort);
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



// ---------- TLS probe helpers ----------

Future<Map<String, dynamic>> _readProbeResponse(dynamic socket) async {
  final completer = Completer<Map<String, dynamic>>();
  final buffer = <int>[];
  StreamSubscription? sub;

  sub = socket.listen(
    (data) {
      buffer.addAll(data);
      if (buffer.length >= 8 && !completer.isCompleted) {
        final headerBytes = Uint8List.fromList(buffer.sublist(0, 8));
        final headerData = ByteData.sublistView(headerBytes);
        final jsonLen = headerData.getUint32(0, Endian.big);
        final total = 8 + jsonLen;
        if (buffer.length >= total) {
          sub?.cancel();
          final jsonStr = utf8.decode(buffer.sublist(8, total));
          try {
            completer.complete(jsonDecode(jsonStr) as Map<String, dynamic>);
          } catch (e) {
            completer.completeError(Exception('Invalid probe response: $e'));
          }
        }
      }
    },
    onError: (e) {
      sub?.cancel();
      if (!completer.isCompleted) completer.completeError(e);
    },
    onDone: () {
      sub?.cancel();
      if (!completer.isCompleted) {
        completer.completeError(Exception('Connection closed during probe'));
      }
    },
  );

  return completer.future;
}

void _handleSocketConnection(dynamic socket, SendPort toUiSendPort) {
  List<int> buffer = [];

  // List<int> cachedChunks = [];
  // const int chunkSize = 512 * 1024;

  int? headerLength;
  int? fileBytesLength;

  int bytesWritten = 0;

  IOSink? fileSink;

  final Stopwatch stopwatch = Stopwatch();

  Map<String, dynamic>? headerJson;

  socket.listen(
    (data) async {
      stopwatch.start();
      buffer.addAll(data);

      // Extracting the 8 Bytes Header

      if (headerLength == null || fileBytesLength == null) {
        final first8BytesInt = Uint8List.fromList(buffer.sublist(0, 8));
        final first8ByteData = ByteData.sublistView(first8BytesInt);

        headerLength = first8ByteData.getUint32(0, Endian.big);
        fileBytesLength = first8ByteData.getUint32(4, Endian.big);

        buffer.removeRange(0, 8);
      }

      // Extracting the header JSON

      if (headerJson == null && buffer.length >= headerLength!) {
        headerJson = jsonDecode(utf8.decode(buffer.sublist(0, headerLength)));

        // Handle probe / disconnect meta-messages
        try {
          final j = headerJson!;
          final type = j['type'] as String?;
          if (type == 'disconnect') {
            socket.destroy();
            toUiSendPort.send({'command': 'disconnect'});
            return;
          }
          if (type == 'probe') {
            final clientWantsTls = j['tls'] == true;
            Map<String, dynamic> resp;
            if (clientWantsTls) {
              // Client wants TLS but server is non-TLS
              resp = {'ok': false, 'error': 'TLS mismatch: server does not use TLS, client has TLS enabled'};
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
              socket.destroy();
              toUiSendPort.send({
                'status': 'error', 'fatal': 'false',
                'message': 'TLS mismatch: client has TLS enabled but server does not',
              });
              return;
            }
            // Match — reset state for real file transfer messages
            headerLength = null;
            fileBytesLength = null;
            headerJson = null;
            buffer.clear();
            return;
          }
        } catch (_) {}
        final String tempDirectory;
        if (Platform.isAndroid) {
          tempDirectory = await ExternalPath.getExternalStoragePublicDirectory(
            ExternalPath.DIRECTORY_DOWNLOAD,
          );
        } else {
          final dirObject = await getDownloadsDirectory();
          tempDirectory = dirObject!.path;
        }

        // Generate unique filename if file already exists
        final fileName = _generateUniqueFileName(
          tempDirectory,
          headerJson!['name'] as String,
        );
        final filePath = "$tempDirectory/$fileName";
        final file = File(filePath);
        fileSink = file.openWrite();

        toUiSendPort.send({
          'status': 'start',
          'fileId': headerJson!['uuid'],
          'fileName': fileName,
          'filePath': filePath,
          'fileSize': fileBytesLength!,
        });

        buffer.removeRange(0, headerLength!);

        bytesWritten = 0;
      }

      // Writing the file bytes

      if (fileSink != null) {
        final remainingBytes = fileBytesLength! - bytesWritten;

        final bytesToWrite = buffer.length > remainingBytes
            ? remainingBytes
            : buffer.length;

        fileSink!.add(buffer.sublist(0, bytesToWrite));

        toUiSendPort.send({
          'status': 'progress',
          'fileId': headerJson!['uuid'],
          'progress': bytesWritten / fileBytesLength!,
        });

        if (bytesToWrite > 0) {
          bytesWritten += bytesToWrite;
          buffer.removeRange(0, bytesToWrite);
        }

        // while (cachedChunks.length >= chunkSize) {
        //   fileSink!.add(cachedChunks.sublist(0, chunkSize));
        //   cachedChunks.removeRange(0, bytesToWrite);
        // }

        if (bytesWritten == fileBytesLength!) {
          // if (cachedChunks.isNotEmpty) {
          //   fileSink!.add(cachedChunks);
          //   cachedChunks.clear();
          // }

          toUiSendPort.send({
            'status': 'completed',
            'fileId': headerJson!['uuid'],
            'timeTaken': stopwatch.elapsed.inSeconds.toString(),
          });

          await fileSink!.close();

          stopwatch.stop();
          stopwatch.reset();
          headerLength = null;
          fileBytesLength = null;
          headerJson = null;
          fileSink = null;
          bytesWritten = 0;
        }
      }
    },
    onDone: () {
      socket.destroy();
    },
    onError: (e) {
      toUiSendPort.send({
        'status': 'error',
        'fatal': 'true',
        'message': e.toString(),
      });
      socket.destroy();
    },
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
