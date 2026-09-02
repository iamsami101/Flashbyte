import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';

/// After the user taps Accept on the device, run this script
/// to send the actual file data and verify the transfer completes.
Future<void> main(List<String> args) async {
  final host = args.isNotEmpty ? args[0] : '127.0.0.1';
  final port = args.length > 1 ? int.parse(args[1]) : 18050;

  print('=== Transfer Send (run AFTER tapping Accept on device) ===');
  print('Connecting to $host:$port...');

  final socket = await SecureSocket.connect(
    host,
    port,
    timeout: const Duration(seconds: 10),
    onBadCertificate: (_) => true,
  );
  final reader = _ReadBuffer(socket);

  // TLS server sends peer_info first
  final serverPeer = await reader.readFrame(timeout: 5);
  print('Server: ${serverPeer.metadata}');

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

  final fileId = 'test-${DateTime.now().microsecondsSinceEpoch}';
  const fileSize = 64 * 1024; // 64 KB

  socket.add(
    encodeFrame(
      jsonEncode({
        'type': 'file_offer',
        'uuid': fileId,
        'name': 'smol_test.bin',
        'size': fileSize,
      }),
    ),
  );
  print('Sent file_offer, waiting for accept...');

  final offerResp = await reader.readFrame(timeout: 30);
  print('Got: ${offerResp.metadata}');

  final offerJson = jsonDecode(offerResp.metadata);
  if (offerJson['type'] != 'file_transfer_accept') {
    print('Expected file_transfer_accept, got: ${offerResp.metadata}');
    socket.close();
    exit(1);
  }
  print('ACCEPTED! Starting transfer...');

  // Send file_start (MUST include 'size' for the receiver to accept it)
  socket.add(
    encodeFrame(
      jsonEncode({
        'type': 'file_start',
        'uuid': fileId,
        'name': 'smol_test.bin',
        'size': fileSize,
      }),
    ),
  );

  // Send a single chunk (64KB)
  final payload = Uint8List(fileSize);
  for (var i = 0; i < fileSize; i++) {
    payload[i] = i & 0xFF;
  }

  socket.add(
    encodeFrame(
      jsonEncode({
        'type': 'file_chunk',
        'uuid': fileId,
      }),
      payload,
    ),
  );
  print('Sent chunk ($fileSize bytes)');

  // Send file_end
  socket.add(
    encodeFrame(
      jsonEncode({
        'type': 'file_end',
        'uuid': fileId,
      }),
    ),
  );
  print('Sent file_end, waiting for ack...');

  final ack = await reader.readFrame(timeout: 30);
  print('Got: ${ack.metadata}');

  final ackJson = jsonDecode(ack.metadata);
  if (ackJson['type'] == 'file_received_ack') {
    print('\n=== FULL TRANSFER PASSED! ===');
  } else {
    print('\n=== Unexpected response ===');
  }

  socket.close();
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

  Future<void> _wait(int needed, {int t = 10}) async {
    while (_buf.length < needed && !_done) {
      final c = Completer<void>();
      _dataCompleter = c;
      await c.future.timeout(Duration(seconds: t));
      _dataCompleter = null;
    }
  }

  Future<_Frame> readFrame({int timeout = 10}) async {
    await _wait(8, t: timeout);
    if (_buf.length < 8) throw Exception('Closed');
    final metaLen = _buf[0] << 24 | _buf[1] << 16 | _buf[2] << 8 | _buf[3];
    final payloadLen = _buf[4] << 24 | _buf[5] << 16 | _buf[6] << 8 | _buf[7];
    _buf.removeRange(0, 8);
    await _wait(metaLen + payloadLen, t: timeout);
    final meta = utf8.decode(_buf.sublist(0, metaLen));
    final pl = Uint8List.fromList(_buf.sublist(metaLen, metaLen + payloadLen));
    _buf.removeRange(0, metaLen + payloadLen);
    return _Frame(meta, pl);
  }
}

class _Frame {
  final String metadata;
  final Uint8List payload;
  _Frame(this.metadata, this.payload);
}

List<int> encodeFrame(String metadata, [List<int>? payload]) {
  final m = utf8.encode(metadata);
  final h = Uint8List(8);
  h.buffer.asByteData()
    ..setUint32(0, m.length)
    ..setUint32(4, payload?.length ?? 0);
  return [...h, ...m, ...(payload ?? [])];
}
