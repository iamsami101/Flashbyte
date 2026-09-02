import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// CLI Tool to send a file (e.g. 1GB.zip) over Flashbyte TCP Protocol
/// Usage:
///   dart run tool/send_file.dart [filePath] [targetIp] [port] [useTls]
void main(List<String> args) async {
  final filePath = args.isNotEmpty ? args[0] : '/home/sami/Downloads/1GB.zip';
  final targetIp = args.length > 1 ? args[1] : '192.168.1.29';
  final port = args.length > 2 ? int.parse(args[2]) : 8050;
  final useTls = args.length > 3 ? args[3] == 'true' : false;

  final file = File(filePath);
  if (!await file.exists()) {
    print('❌ Error: File not found at path: $filePath');
    exit(1);
  }

  final fileSize = await file.length();
  final fileName = file.uri.pathSegments.last;

  print('====================================================');
  print('⚡ FLASHBYTE CLI FILE SENDER');
  print('====================================================');
  print('File Path : $filePath');
  print('File Name : $fileName');
  print(
    'File Size : ${(fileSize / (1024 * 1024)).toStringAsFixed(2)} MB ($fileSize bytes)',
  );
  print('Target IP : $targetIp:$port');
  print('TLS Mode  : ${useTls ? "Enabled" : "Disabled"}');
  print('----------------------------------------------------');

  try {
    print('Connecting to $targetIp:$port...');
    final socket = await Socket.connect(
      targetIp,
      port,
      timeout: const Duration(seconds: 10),
    );
    print('✔ Connected to receiver socket!');

    final readBuffer = _SocketBuffer();
    final socketSub = socket.listen(
      (data) => readBuffer.add(data),
      onError: (err) => print('Socket error: $err'),
      onDone: () => print('Socket connection closed.'),
    );

    if (!useTls) {
      print('Sending probe frame...');
      _sendFrame(socket, {'type': 'probe', 'tls': false});
      final probeResp = await _readNextFrame(readBuffer);
      print('Probe response: $probeResp');
    }

    print('Exchanging peer_info...');
    _sendFrame(socket, {
      'type': 'peer_info',
      'name': 'Linux-CLI-Harness',
      'deviceType': 'laptop',
    });

    final peerInfo = await _readNextFrame(readBuffer);
    print('Receiver Peer Info: $peerInfo');

    final fileId = 'cli-transfer-${DateTime.now().millisecondsSinceEpoch}';
    print('\nSending file offer ($fileName)...');
    _sendFrame(socket, {
      'type': 'file_offer',
      'fileId': fileId,
      'name': fileName,
      'size': fileSize,
    });

    print('Waiting for receiver approval on target device...');
    final acceptFrame = await _readNextFrame(readBuffer);
    print('Response: $acceptFrame');

    if (acceptFrame['type'] != 'file_transfer_accept') {
      print('❌ Receiver declined or sent unexpected frame: $acceptFrame');
      await socket.close();
      exit(1);
    }

    print('✔ Offer ACCEPTED! Starting stream...');
    _sendFrame(socket, {
      'type': 'file_start',
      'fileId': fileId,
    });

    final stopwatch = Stopwatch()..start();
    final randomAccess = await file.open(mode: FileMode.read);
    const chunkSize = 65536; // 64 KB window chunk
    int bytesSent = 0;
    int lastReportBytes = 0;
    DateTime lastReportTime = DateTime.now();

    while (bytesSent < fileSize) {
      final toRead = (fileSize - bytesSent) < chunkSize
          ? (fileSize - bytesSent)
          : chunkSize;
      final chunkData = await randomAccess.read(toRead);

      _sendFrame(
        socket,
        {'type': 'file_chunk', 'fileId': fileId},
        payload: chunkData,
      );

      bytesSent += chunkData.length;

      final now = DateTime.now();
      final diffMs = now.difference(lastReportTime).inMilliseconds;
      if (diffMs >= 500 || bytesSent == fileSize) {
        final speedMBps =
            ((bytesSent - lastReportBytes) / (1024 * 1024)) / (diffMs / 1000.0);
        final percent = (bytesSent / fileSize * 100).toStringAsFixed(1);
        final sentMB = (bytesSent / (1024 * 1024)).toStringAsFixed(1);
        final totalMB = (fileSize / (1024 * 1024)).toStringAsFixed(1);

        stdout.write(
          '\r🚀 Progress: $percent% ($sentMB / $totalMB MB) | Speed: ${speedMBps.toStringAsFixed(2)} MB/s',
        );
        lastReportBytes = bytesSent;
        lastReportTime = now;
      }
    }
    await randomAccess.close();
    stopwatch.stop();

    print('\nSending file_end frame...');
    _sendFrame(socket, {
      'type': 'file_end',
      'fileId': fileId,
    });

    print('Waiting for receiver ACK...');
    final ackFrame = await _readNextFrame(readBuffer);
    print('Receiver ACK: $ackFrame');

    print('\n🎉 TRANSFER COMPLETE!');
    print(
      'Total Time: ${(stopwatch.elapsedMilliseconds / 1000.0).toStringAsFixed(2)} seconds',
    );
    final avgSpeed =
        ((fileSize / (1024 * 1024)) / (stopwatch.elapsedMilliseconds / 1000.0))
            .toStringAsFixed(2);
    print('Average Speed: $avgSpeed MB/s');

    await socketSub.cancel();
    await socket.close();
  } catch (e) {
    print('\n❌ Transfer Error: $e');
  }
}

void _sendFrame(
  Socket socket,
  Map<String, dynamic> metadata, {
  Uint8List? payload,
}) {
  final metaBytes = utf8.encode(jsonEncode(metadata));
  final payloadBytes = payload ?? Uint8List(0);

  final metaLen = metaBytes.length;
  final payloadLen = payloadBytes.length;

  final header = Uint8List(8);
  final bd = ByteData.sublistView(header);
  bd.setUint32(0, metaLen, Endian.big);
  bd.setUint32(4, payloadLen, Endian.big);

  socket.add(header);
  socket.add(metaBytes);
  if (payloadBytes.isNotEmpty) {
    socket.add(payloadBytes);
  }
}

Future<Map<String, dynamic>> _readNextFrame(_SocketBuffer buffer) async {
  while (true) {
    final frame = buffer.tryReadFrame();
    if (frame != null) {
      return frame;
    }
    await Future.delayed(const Duration(milliseconds: 10));
  }
}

class _SocketBuffer {
  final List<int> _bytes = [];

  void add(List<int> chunk) {
    _bytes.addAll(chunk);
  }

  Map<String, dynamic>? tryReadFrame() {
    if (_bytes.length < 8) return null;

    final bd = ByteData.sublistView(Uint8List.fromList(_bytes.sublist(0, 8)));
    final metaLen = bd.getUint32(0, Endian.big);
    final payloadLen = bd.getUint32(4, Endian.big);

    final totalFrameLen = 8 + metaLen + payloadLen;
    if (_bytes.length < totalFrameLen) return null;

    final metaBytes = _bytes.sublist(8, 8 + metaLen);
    _bytes.removeRange(0, totalFrameLen);

    final jsonStr = utf8.decode(metaBytes);
    return jsonDecode(jsonStr) as Map<String, dynamic>;
  }
}
