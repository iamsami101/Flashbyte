import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';

Uint8List buildFrame({
  required Map<String, dynamic> metadata,
  Uint8List? payload,
}) {
  final metadataBytes = utf8.encode(jsonEncode(metadata));
  final payloadBytes = payload ?? Uint8List(0);

  final metadataLength = metadataBytes.length;
  final payloadLength = payloadBytes.length;

  final totalLength = 8 + metadataLength + payloadLength;
  final buffer = Uint8List(totalLength);
  final byteData = ByteData.sublistView(buffer);

  byteData.setUint32(0, metadataLength, Endian.big);
  byteData.setUint32(4, payloadLength, Endian.big);
  buffer.setRange(8, 8 + metadataLength, metadataBytes);
  if (payloadBytes.isNotEmpty) {
    buffer.setRange(8 + metadataLength, totalLength, payloadBytes);
  }

  return buffer;
}

(Map<String, dynamic>, Uint8List) parseFrame(Uint8List frameData) {
  final byteData = ByteData.sublistView(frameData);
  final metadataLength = byteData.getUint32(0, Endian.big);
  final payloadLength = byteData.getUint32(4, Endian.big);

  final metadataBytes = frameData.sublist(8, 8 + metadataLength);
  final metadataJson =
      jsonDecode(utf8.decode(metadataBytes)) as Map<String, dynamic>;

  final payloadBytes = frameData.sublist(
    8 + metadataLength,
    8 + metadataLength + payloadLength,
  );
  return (metadataJson, payloadBytes);
}

void main() {
  group('Protocol Framing', () {
    test('encodes control frame with 0 payload length', () {
      final meta = {
        'type': 'file_offer',
        'fileId': 'file-100',
        'name': 'photo.png',
        'size': 2048,
      };
      final frame = buildFrame(metadata: meta);

      final byteData = ByteData.sublistView(frame);
      final metaLen = byteData.getUint32(0, Endian.big);
      final payloadLen = byteData.getUint32(4, Endian.big);

      expect(payloadLen, equals(0));
      expect(metaLen, equals(utf8.encode(jsonEncode(meta)).length));

      final (parsedMeta, parsedPayload) = parseFrame(frame);
      expect(parsedMeta['type'], equals('file_offer'));
      expect(parsedMeta['fileId'], equals('file-100'));
      expect(parsedPayload.isEmpty, isTrue);
    });

    test('encodes binary data chunk frame', () {
      final meta = {'type': 'file_chunk', 'fileId': 'file-100'};
      final dummyData = Uint8List.fromList(List.generate(1024, (i) => i % 256));

      final frame = buildFrame(metadata: meta, payload: dummyData);
      final (parsedMeta, parsedPayload) = parseFrame(frame);

      expect(parsedMeta['type'], equals('file_chunk'));
      expect(parsedPayload.length, equals(1024));
      expect(parsedPayload[0], equals(0));
      expect(parsedPayload[255], equals(255));
    });

    test('resume_request control frame encodes offset', () {
      final meta = {
        'type': 'resume_request',
        'transferId': 'file-100',
        'fileName': 'photo.png',
        'fileSize': 2048,
        'offset': 512,
      };
      final frame = buildFrame(metadata: meta);
      final byteData = ByteData.sublistView(frame);
      expect(byteData.getUint32(4, Endian.big), equals(0));

      final (parsedMeta, _) = parseFrame(frame);
      expect(parsedMeta['type'], equals('resume_request'));
      expect(parsedMeta['transferId'], equals('file-100'));
      expect(parsedMeta['offset'], equals(512));
    });

    test('resume_response control frame carries ok and offset', () {
      final meta = {
        'type': 'resume_response',
        'ok': true,
        'transferId': 'file-100',
        'offset': 1024,
      };
      final frame = buildFrame(metadata: meta);
      final (parsedMeta, _) = parseFrame(frame);
      expect(parsedMeta['ok'], isTrue);
      expect(parsedMeta['offset'], equals(1024));
    });

    test('file_start includes offset for resume append', () {
      final meta = {
        'type': 'file_start',
        'uuid': 'file-100',
        'name': 'photo.png',
        'size': 2048,
        'offset': 1024,
      };
      final frame = buildFrame(metadata: meta);
      final (parsedMeta, _) = parseFrame(frame);
      expect(parsedMeta['type'], equals('file_start'));
      expect(parsedMeta['offset'], equals(1024));
      expect(parsedMeta['size'], equals(2048));
    });

    test('peer_info now carries deviceId', () {
      final meta = {
        'type': 'peer_info',
        'name': 'device-a',
        'deviceType': 'phone',
        'deviceId': 'd-1234',
      };
      final frame = buildFrame(metadata: meta);
      final (parsedMeta, _) = parseFrame(frame);
      expect(parsedMeta['deviceId'], equals('d-1234'));
    });
  });
}
