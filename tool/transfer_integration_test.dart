import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Transfer integration test — sends a sample file over TCP to verify the
/// Flashbyte protocol end-to-end.
///
/// Modes:
///   dart run tool/transfer_integration_test.dart            (self-test, loopback)
///   dart run tool/transfer_integration_test.dart --adb       (prioritize Android device)
///   dart run tool/transfer_integration_test.dart --host IP   (test against specific host)
const int _kTestSize = 64 * 1024; // 64 KB

Future<void> main(List<String> args) async {
  final useAdb = args.contains('--adb');
  final hostIdx = args.indexOf('--host');
  final explicitHost = hostIdx != -1 && hostIdx + 1 < args.length
      ? args[hostIdx + 1]
      : null;

  print('=== Flashbyte Transfer Integration Test ===\n');

  // Determine test target
  String targetHost;
  int targetPort;
  bool isRemoteAdb = false;

  if (explicitHost != null) {
    targetHost = explicitHost;
    targetPort = 18099;
    print('Target: explicit host $targetHost:$targetPort');
  } else if (useAdb) {
    final adbTarget = await _findAdbDevice();
    if (adbTarget != null) {
      targetHost = adbTarget;
      targetPort = 18099;
      isRemoteAdb = true;
      print('Target: Android device at $targetHost:$targetPort');
    } else {
      print('No ADB device found — falling back to self-test (loopback)');
      targetHost = '127.0.0.1';
      targetPort = 18099;
    }
  } else {
    targetHost = '127.0.0.1';
    targetPort = 18099;
    print('Target: self-test loopback');
  }

  // Generate test file content (deterministic pattern for verification)
  final originalBytes = Uint8List(_kTestSize);
  for (var i = 0; i < _kTestSize; i++) {
    originalBytes[i] = (i * 7 + 13) & 0xFF; // deterministic pattern
  }
  final checksum = _crc32(originalBytes);

  print('Test file: $_kTestSize bytes, CRC32: ${checksum.toRadixString(16)}\n');

  // --- Self-test mode (server + client in same process) ---
  if (!isRemoteAdb && explicitHost == null) {
    final passed = await _runSelfTest(targetPort, originalBytes, checksum);
    if (!passed) {
      exit(1);
    }
  } else {
    // --- Remote test mode (server on this machine, client = Android device) ---
    final passed = await _runRemoteTest(
      targetHost,
      targetPort,
      originalBytes,
      checksum,
    );
    if (!passed) {
      exit(1);
    }
  }

  print('\n=== ALL TRANSFER TESTS PASSED ===');
}

// ---------------------------------------------------------------------------
// Self-test: server + client in the same process over loopback
// ---------------------------------------------------------------------------

Future<bool> _runSelfTest(
  int port,
  Uint8List originalBytes,
  int expectedChecksum,
) async {
  print('--- Self-Test: Loopback Transfer ---');

  final serverSocket = await ServerSocket.bind('127.0.0.1', port, shared: true);
  print('Server listening on 127.0.0.1:$port');

  final receivedChunks = <Uint8List>[];
  String? receivedFileName;
  int? receivedFileSize;
  final serverReady = Completer<void>();

  // Server-side: accept connection, exchange peer_info, receive file
  final serverFuture = serverSocket.listen((socket) async {
    final reader = _ReadBuffer(socket);

    // Send peer_info
    socket.add(
      _encodeFrame(
        jsonEncode({
          'type': 'peer_info',
          'name': 'Test Server',
          'deviceType': 'laptop',
          'port': port,
          'tls': false,
        }),
      ),
    );

    // Wait for client peer_info
    final peerFrame = await reader.readFrame(timeout: 5);
    final peerJson = jsonDecode(peerFrame.metadata);
    if (peerJson['type'] != 'peer_info') {
      print('FAIL: Expected peer_info, got ${peerJson['type']}');
      socket.destroy();
      return;
    }
    print('Server: received peer_info from "${peerJson['name']}"');

    // Wait for file_offer
    final offerFrame = await reader.readFrame(timeout: 5);
    final offerJson = jsonDecode(offerFrame.metadata);
    if (offerJson['type'] != 'file_offer') {
      print('FAIL: Expected file_offer, got ${offerJson['type']}');
      socket.destroy();
      return;
    }
    receivedFileName = offerJson['name'] as String;
    receivedFileSize = offerJson['size'] as int;
    print('Server: file_offer "$receivedFileName" ($receivedFileSize bytes)');

    // Auto-accept
    socket.add(
      _encodeFrame(
        jsonEncode({
          'type': 'file_transfer_accept',
          'fileId': offerJson['uuid'],
        }),
      ),
    );
    print('Server: accepted transfer');

    // Read file chunks
    var bytesReceived = 0;
    while (bytesReceived < receivedFileSize!) {
      final frame = await reader.readFrame(timeout: 10);
      final json = jsonDecode(frame.metadata);
      if (json['type'] == 'file_chunk') {
        receivedChunks.add(frame.payload);
        bytesReceived += frame.payload.length;
      } else if (json['type'] == 'file_end') {
        break;
      }
    }

    // Reassemble and count
    final receivedBytes = _concatenate(receivedChunks);

    print('Server: received ${receivedBytes.length} bytes');

    // Send ack
    socket.add(
      _encodeFrame(
        jsonEncode({
          'type': 'file_received_ack',
          'fileId': offerJson['uuid'],
          'fileName': receivedFileName,
        }),
      ),
    );

    socket.destroy();
  });

  // Give server a moment to bind
  await Future.delayed(const Duration(milliseconds: 200));
  serverReady.complete();

  // Client-side: connect, exchange peer_info, send file
  print('\nClient: connecting to 127.0.0.1:$port');
  final clientSocket = await Socket.connect('127.0.0.1', port);
  final clientReader = _ReadBuffer(clientSocket);

  // Read server peer_info
  final serverPeer = await clientReader.readFrame(timeout: 5);
  final serverPeerJson = jsonDecode(serverPeer.metadata);
  print('Client: server peer "${serverPeerJson['name']}"');

  // Send our peer_info
  clientSocket.add(
    _encodeFrame(
      jsonEncode({
        'type': 'peer_info',
        'name': 'Test Client',
        'deviceType': 'laptop',
        'port': port,
        'tls': false,
      }),
    ),
  );

  // Send file_offer
  final fileId = 'test-${DateTime.now().microsecondsSinceEpoch}';
  clientSocket.add(
    _encodeFrame(
      jsonEncode({
        'type': 'file_offer',
        'uuid': fileId,
        'name': 'sample_test.bin',
        'size': _kTestSize,
      }),
    ),
  );
  print('Client: sent file_offer for sample_test.bin ($_kTestSize bytes)');

  // Wait for accept
  final acceptFrame = await clientReader.readFrame(timeout: 5);
  final acceptJson = jsonDecode(acceptFrame.metadata);
  if (acceptJson['type'] != 'file_transfer_accept') {
    print('FAIL: Expected file_transfer_accept, got ${acceptJson['type']}');
    clientSocket.destroy();
    serverFuture;
    await serverSocket.close();
    return false;
  }
  print('Client: transfer accepted');

  // Send file_start
  clientSocket.add(
    _encodeFrame(
      jsonEncode({
        'type': 'file_start',
        'uuid': fileId,
        'name': 'sample_test.bin',
        'size': _kTestSize,
      }),
    ),
  );

  // Send file_chunk with full payload
  clientSocket.add(
    _encodeFrame(
      jsonEncode({'type': 'file_chunk', 'fileId': fileId}),
      originalBytes,
    ),
  );
  print('Client: sent chunk ($_kTestSize bytes)');

  // Send file_end
  clientSocket.add(
    _encodeFrame(
      jsonEncode({
        'type': 'file_end',
        'fileId': fileId,
      }),
    ),
  );
  print('Client: sent file_end');

  // Wait for ack
  final ackFrame = await clientReader.readFrame(timeout: 10);
  final ackJson = jsonDecode(ackFrame.metadata);
  if (ackJson['type'] != 'file_received_ack') {
    print('FAIL: Expected file_received_ack, got ${ackJson['type']}');
    clientSocket.destroy();
    serverFuture;
    await serverSocket.close();
    return false;
  }
  print('Client: received ack');

  clientSocket.destroy();
  serverFuture;
  await serverSocket.close();

  // Verify
  final receivedBytes = _concatenate(receivedChunks);
  final receivedChecksum = _crc32(receivedBytes);
  final sizeOk = receivedBytes.length == _kTestSize;
  final checksumOk = receivedChecksum == expectedChecksum;

  print('\n--- Verification ---');
  print(
    'Sent:     $_kTestSize bytes, CRC32: ${expectedChecksum.toRadixString(16)}',
  );
  print(
    'Received: ${receivedBytes.length} bytes, CRC32: ${receivedChecksum.toRadixString(16)}',
  );
  print('Size match:     ${sizeOk ? "PASS" : "FAIL"}');
  print('Checksum match: ${checksumOk ? "PASS" : "FAIL"}');

  if (!sizeOk || !checksumOk) {
    print('\nFAIL: Transfer data mismatch');
    return false;
  }

  print('PASS: Self-test loopback transfer verified');
  return true;
}

// ---------------------------------------------------------------------------
// Remote test: server here, Android device connects as client
// ---------------------------------------------------------------------------

Future<bool> _runRemoteTest(
  String targetHost,
  int port,
  Uint8List originalBytes,
  int expectedChecksum,
) async {
  print('--- Remote Test: ADB Device Transfer ---');
  print('Waiting for Android device to connect to $targetHost:$port ...');
  print(
    '(Run the app on the device and tap Receive, then Send to this device)',
  );

  final serverSocket = await ServerSocket.bind('0.0.0.0', port, shared: true);
  print('Server listening on 0.0.0.0:$port');

  final receivedChunks = <Uint8List>[];
  String? receivedFileName;
  int? receivedFileSize;

  final connectionCompleter = Completer<Socket>();

  serverSocket.listen((socket) {
    if (!connectionCompleter.isCompleted) {
      connectionCompleter.complete(socket);
    }
  });

  Socket deviceSocket;
  try {
    deviceSocket = await connectionCompleter.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        print('FAIL: No device connected within 30 seconds');
        serverSocket.close();
        throw TimeoutException('Device did not connect');
      },
    );
  } on TimeoutException {
    return false;
  }

  print('Device connected from ${deviceSocket.remoteAddress.address}');
  final reader = _ReadBuffer(deviceSocket);

  // Server sends peer_info
  deviceSocket.add(
    _encodeFrame(
      jsonEncode({
        'type': 'peer_info',
        'name': 'Test Server',
        'deviceType': 'laptop',
        'port': port,
        'tls': false,
      }),
    ),
  );

  // Wait for device peer_info
  final peerFrame = await reader.readFrame(timeout: 10);
  final peerJson = jsonDecode(peerFrame.metadata);
  print('Device peer: "${peerJson['name']}" (${peerJson['deviceType']})');

  // Wait for file_offer from device
  final offerFrame = await reader.readFrame(timeout: 10);
  final offerJson = jsonDecode(offerFrame.metadata);
  if (offerJson['type'] != 'file_offer') {
    print('FAIL: Expected file_offer from device, got ${offerJson['type']}');
    deviceSocket.destroy();
    await serverSocket.close();
    return false;
  }
  receivedFileName = offerJson['name'] as String;
  receivedFileSize = offerJson['size'] as int;
  print('Device offers: "$receivedFileName" ($receivedFileSize bytes)');

  // Auto-accept
  deviceSocket.add(
    _encodeFrame(
      jsonEncode({
        'type': 'file_transfer_accept',
        'fileId': offerJson['uuid'],
      }),
    ),
  );
  print('Accepted transfer from device');

  // Read chunks
  var bytesReceived = 0;
  while (bytesReceived < receivedFileSize) {
    final frame = await reader.readFrame(timeout: 30);
    final json = jsonDecode(frame.metadata);
    if (json['type'] == 'file_chunk') {
      receivedChunks.add(frame.payload);
      bytesReceived += frame.payload.length;
      if (bytesReceived % (1024 * 1024) == 0 ||
          bytesReceived >= receivedFileSize) {
        print(
          '  Received ${bytesReceived ~/ 1024}KB / ${receivedFileSize ~/ 1024}KB',
        );
      }
    } else if (json['type'] == 'file_end') {
      break;
    }
  }

  final receivedBytes = _concatenate(receivedChunks);
  final receivedChecksum = _crc32(receivedBytes);

  // Send ack
  deviceSocket.add(
    _encodeFrame(
      jsonEncode({
        'type': 'file_received_ack',
        'fileId': offerJson['uuid'],
        'fileName': receivedFileName,
      }),
    ),
  );

  deviceSocket.destroy();
  await serverSocket.close();

  // Verify
  final sizeOk = receivedBytes.length == receivedFileSize;
  final checksumOk = receivedChecksum == expectedChecksum;

  print('\n--- Verification ---');
  print(
    'Received: ${receivedBytes.length} bytes, CRC32: ${receivedChecksum.toRadixString(16)}',
  );
  print('Size match:     ${sizeOk ? "PASS" : "FAIL"}');
  print('Checksum match: ${checksumOk ? "PASS" : "FAIL"}');

  if (!sizeOk || !checksumOk) {
    print('\nFAIL: Transfer data mismatch');
    return false;
  }

  print('PASS: Remote device transfer verified');
  return true;
}

// ---------------------------------------------------------------------------
// ADB helpers
// ---------------------------------------------------------------------------

Future<String?> _findAdbDevice() async {
  try {
    final result = await Process.run('adb', ['devices']);
    final output = result.stdout.toString();
    final lines = output
        .split('\n')
        .where(
          (l) =>
              l.trim().isNotEmpty &&
              !l.startsWith('List of devices') &&
              l.contains('device'),
        )
        .toList();

    if (lines.isEmpty) return null;

    final deviceId = lines.first.split(RegExp(r'\s+')).first;
    print('ADB device found: $deviceId');

    // Get device IP address
    final ipResult = await Process.run('adb', [
      '-s',
      deviceId,
      'shell',
      'ip',
      'route',
      'show',
      'dev',
      'wlan0',
    ]);
    final ipOutput = ipResult.stdout.toString();
    final ipMatch = RegExp(r'src\s+(\d+\.\d+\.\d+\.\d+)').firstMatch(ipOutput);
    if (ipMatch != null) {
      return ipMatch.group(1);
    }

    // Fallback: try ip addr
    final addrResult = await Process.run('adb', [
      '-s',
      deviceId,
      'shell',
      'ip',
      '-f',
      'inet',
      'addr',
      'show',
      'wlan0',
    ]);
    final addrOutput = addrResult.stdout.toString();
    final addrMatch = RegExp(
      r'inet\s+(\d+\.\d+\.\d+\.\d+)',
    ).firstMatch(addrOutput);
    if (addrMatch != null) {
      return addrMatch.group(1);
    }

    print('WARNING: Could not determine device IP');
    return null;
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Protocol helpers
// ---------------------------------------------------------------------------

List<int> _encodeFrame(String metadata, [List<int>? payload]) {
  final metaBytes = utf8.encode(metadata);
  final header = Uint8List(8);
  header.buffer.asByteData()
    ..setUint32(0, metaBytes.length, Endian.big)
    ..setUint32(4, payload?.length ?? 0, Endian.big);
  return [...header, ...metaBytes, ...(payload ?? [])];
}

Uint8List _concatenate(List<Uint8List> chunks) {
  if (chunks.isEmpty) return Uint8List(0);
  var totalLength = 0;
  for (final chunk in chunks) {
    totalLength += chunk.length;
  }
  final result = Uint8List(totalLength);
  var offset = 0;
  for (final chunk in chunks) {
    result.setRange(offset, offset + chunk.length, chunk);
    offset += chunk.length;
  }
  return result;
}

int _crc32(Uint8List data) {
  var crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc >>> 1) ^ (crc & 1 == 1 ? 0xEDB88320 : 0);
    }
  }
  return crc ^ 0xFFFFFFFF;
}

// ---------------------------------------------------------------------------
// Read buffer (reused from existing tool scripts)
// ---------------------------------------------------------------------------

class _ReadBuffer {
  final Socket _socket;
  final _buf = <int>[];
  Completer<void>? _dataCompleter;
  bool _done = false;
  StreamSubscription<List<int>>? _sub; // ignore: unused_field

  _ReadBuffer(this._socket) {
    _sub = _socket.listen(
      (data) {
        _buf.addAll(data);
        _dataCompleter?.complete();
      },
      onDone: () {
        _done = true;
        _dataCompleter?.complete();
      },
    );
  }

  Future<void> _wait(int needed, {int timeoutSec = 10}) async {
    while (_buf.length < needed && !_done) {
      final c = Completer<void>();
      _dataCompleter = c;
      await c.future.timeout(Duration(seconds: timeoutSec));
      _dataCompleter = null;
    }
  }

  Future<_Frame> readFrame({int timeout = 10}) async {
    await _wait(8, timeoutSec: timeout);
    if (_buf.length < 8) throw Exception('Closed before frame header');
    final metaLen = _buf[0] << 24 | _buf[1] << 16 | _buf[2] << 8 | _buf[3];
    final payloadLen = _buf[4] << 24 | _buf[5] << 16 | _buf[6] << 8 | _buf[7];
    _buf.removeRange(0, 8);
    await _wait(metaLen + payloadLen, timeoutSec: timeout);
    if (_buf.length < metaLen + payloadLen) {
      throw Exception('Closed before frame body');
    }
    final metaBytes = _buf.sublist(0, metaLen);
    final payload = _buf.sublist(metaLen, metaLen + payloadLen);
    _buf.removeRange(0, metaLen + payloadLen);
    return _Frame(utf8.decode(metaBytes), Uint8List.fromList(payload));
  }
}

class _Frame {
  final String metadata;
  final Uint8List payload;
  _Frame(this.metadata, this.payload);
}
