import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class FrameHeader {
  const FrameHeader({required this.headerLength, required this.payloadLength});

  final int headerLength;
  final int payloadLength;
}

/// Queue-based byte buffer for reading length-prefixed frames from a socket.
class SocketReadBuffer {
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

  FrameHeader? tryPeekFrameHeader() {
    final bytes = tryPeekBytes(8);
    if (bytes == null) {
      return null;
    }

    final header = ByteData.sublistView(bytes);
    return FrameHeader(
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
      final take = (readable < remaining ? readable : remaining).toInt();
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
      final take = (readable < remaining ? readable : remaining).toInt();
      out.setRange(outOffset, outOffset + take, head, _headOffset);
      _consume(take);
      outOffset += take;
      remaining -= take;
    }

    return out;
  }

  void _consume(int byteCount) {
    _availableBytes -= byteCount;
    _headOffset += byteCount;

    while (_chunks.isNotEmpty && _headOffset >= _chunks.first.length) {
      _headOffset -= _chunks.removeFirst().length.toInt();
    }

    if (_chunks.isEmpty) {
      _headOffset = 0;
    }
  }
}

/// Encodes and sends a length-prefixed frame over a socket.
///
/// Frame format: [4 bytes metadata length][4 bytes payload length][metadata][payload]
Future<void> sendSocketFrame(
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

/// Sends a control frame (zero-payload frame carrying only metadata).
void sendControlFrame(dynamic socket, Map<String, dynamic> payload) {
  final payloadBytes = utf8.encode(jsonEncode(payload));
  final header = ByteData(8);
  header.setUint32(0, payloadBytes.length, Endian.big);
  header.setUint32(4, 0, Endian.big);
  socket.add(header.buffer.asUint8List());
  socket.add(payloadBytes);
}

/// Configures a socket for low-latency file transfer.
void configureSocketForTransfer(dynamic socket) {
  try {
    socket.setOption(SocketOption.tcpNoDelay, true);
  } catch (_) {}
}
