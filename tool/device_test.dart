import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';

Future<void> main(List<String> args) async {
  final host = args.isNotEmpty ? args[0] : '127.0.0.1';
  final port = args.length > 1 ? int.parse(args[1]) : 8050;

  print('=== Device Transfer Test ===');
  print('Connecting to $host:$port TLS...');

  final socket = await SecureSocket.connect(
    host,
    port,
    timeout: const Duration(seconds: 10),
    onBadCertificate: (_) => true,
  );
  print('Connected.');

  final reader = _ReadBuffer(socket);

  // Server sends peer_info first (TLS mode)
  final peerInfo = await reader.readFrame(timeout: 5);
  print('Received: ${peerInfo.metadata}');

  // Send our peer_info
  socket.add(
    encodeFrame(
      jsonEncode({
        'type': 'peer_info',
        'name': 'Test CLI',
        'deviceType': 'laptop',
        'port': 8050,
        'tls': true,
      }),
    ),
  );
  print('Sent peer_info');

  // Wait a moment to ensure the connection is stable
  await Future.delayed(const Duration(seconds: 1));

  // Send file_offer
  final fileId = 'test-${DateTime.now().microsecondsSinceEpoch}';
  final testSize = 1024 * 1024; // 1 MB
  socket.add(
    encodeFrame(
      jsonEncode({
        'type': 'file_offer',
        'uuid': fileId,
        'name': 'test_1mb.bin',
        'size': testSize,
      }),
    ),
  );
  print('Sent file_offer for test_1mb.bin ($testSize bytes)');

  // Check for notification by dumping logcat
  await Future.delayed(const Duration(seconds: 3));
  print('\nChecking for notification icon errors in logcat...');
  final logs = Process.runSync('adb', ['logcat', '-d', '-s', 'flutter:V']);
  final stdout = logs.stdout as String;
  if (stdout.contains('no valid small icon')) {
    print('FAIL: "no valid small icon" error still present!');
  } else {
    print('PASS: No small icon error');
  }

  print('\nFile offer sent. Check the device — an Accept/Decline');
  print('notification should now be visible!');
  print('Tap ACCEPT to continue the test in the next step.');
  print('(In another terminal, run the accept script to verify full flow)');

  socket.close();
  print('\n=== Test script complete ===');
}

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

List<int> encodeFrame(String metadata, [List<int>? payload]) {
  final metaBytes = utf8.encode(metadata);
  final metaLen = metaBytes.length;
  final payloadLen = payload?.length ?? 0;
  final header = Uint8List(8);
  header.buffer.asByteData()
    ..setUint32(0, metaLen)
    ..setUint32(4, payloadLen);
  return [...header, ...metaBytes, ...(payload ?? [])];
}
