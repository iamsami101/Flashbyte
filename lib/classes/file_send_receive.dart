import 'dart:io';
import 'dart:isolate';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:external_path/external_path.dart';
import 'package:saf_util/saf_util.dart';
import 'package:uri_to_file/uri_to_file.dart';
import 'package:uuid/uuid.dart';

// iOS/macOS file coordinator for secure file access

void fileReceiverIsolate(List<Object> args) {
  final toUiSendPort = args[0] as SendPort;
  final RootIsolateToken rootIsolateToken = args[1] as RootIsolateToken;

  BackgroundIsolateBinaryMessenger.ensureInitialized(rootIsolateToken);

  final fromUiReceivePort = ReceivePort();
  toUiSendPort.send(fromUiReceivePort.sendPort);

  Socket? clientSocket;
  ServerSocket? serverSocket;

  // Queue for handling concurrent file sends properly
  final List<Map<String, dynamic>> commandQueue = [];
  bool isProcessing = false;

  Future<void> processCommandQueue() async {
    if (isProcessing || commandQueue.isEmpty) return;
    isProcessing = true;

    while (commandQueue.isNotEmpty) {
      final command = commandQueue.removeAt(0);

      try {
        if (command['command'] == 'connect') {
          if (command['mode'] == 'host') {
            serverSocket = await ServerSocket.bind(
              "0.0.0.0",
              command['port'],
              shared: true,
            );
            toUiSendPort.send({
              'status': 'hosting',
              'address': serverSocket!.address.address,
            });
            serverSocket!.listen((socket) {
              clientSocket = socket;
              toUiSendPort.send({'status': 'client_connected'});
              _handleSocketConnection(clientSocket!, toUiSendPort);
            });
          } else if (command['mode'] == 'client') {
            clientSocket = await Socket.connect(
              command['host'],
              command['port'],
            );
            toUiSendPort.send({'status': 'connected_to_host'});
            _handleSocketConnection(clientSocket!, toUiSendPort);
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
  Socket clientSocket,
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

    // Stream file with progress tracking
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

      // Send progress update
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

void _handleSocketConnection(Socket socket, SendPort toUiSendPort) {
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

        try {
          if (headerJson!['type'] == 'disconnect') {
            socket.destroy();
            toUiSendPort.send({'command': 'disconnect'});
            return;
          }
        } catch (_) {}
        final String tempDirectory;
        if (Platform.isAndroid || Platform.isIOS) {
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
