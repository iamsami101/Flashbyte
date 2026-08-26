import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flashbyte/models/discovered_device.dart';

class DeviceDiscoveryService {
  DeviceDiscoveryService._();

  static final DeviceDiscoveryService instance = DeviceDiscoveryService._();
  static const _protocol = 'flashbyte-discovery-v1';
  static const _broadcastInterval = Duration(seconds: 2);
  static const _advertiseBurstDelays = [
    Duration(milliseconds: 180),
    Duration(milliseconds: 650),
  ];
  static const _probeBurstDelays = [
    Duration(milliseconds: 220),
    Duration(milliseconds: 700),
  ];
  static const _goodbyeBurstDelays = [
    Duration(milliseconds: 80),
    Duration(milliseconds: 180),
  ];
  static const _refreshInterval = Duration(seconds: 4);
  static const _peerTimeout = Duration(seconds: 20);
  static const _fallbackBroadcastPrefixes = [24, 20, 16, 28, 29, 30];

  static final _limitedBroadcast = InternetAddress('255.255.255.255');

  final _devicesController =
      StreamController<List<DiscoveredDevice>>.broadcast();
  final Map<String, _SeenDevice> _devices = {};

  RawDatagramSocket? _receiveSocket;
  StreamSubscription<RawSocketEvent>? _receiveSubscription;
  final List<_DiscoverySocket> _sendSockets = [];
  Timer? _broadcastTimer;
  final List<Timer> _advertiseBurstTimers = [];
  final List<Timer> _probeBurstTimers = [];
  Timer? _cleanupTimer;
  Timer? _refreshTimer;
  String? _localDeviceId;
  int? _discoveryPort;
  Map<String, dynamic>? _advertisement;
  String? _advertisingInstanceId;

  Stream<List<DiscoveredDevice>> get devicesStream => _devicesController.stream;
  List<DiscoveredDevice> get devices =>
      List.unmodifiable(_devices.values.map((entry) => entry.device));

  Future<void> startDiscovery({
    required String localDeviceId,
    required int port,
  }) async {
    _localDeviceId = localDeviceId;
    if (_receiveSocket != null && _discoveryPort == port) {
      _emitDevices();
      requestRefresh();
      return;
    }

    await stopDiscovery();
    await _bindReceiveSocket(port);
    final sockets = await _createSendSockets(port);
    _sendSockets.addAll(sockets);
    _discoveryPort = port;
    _cleanupTimer = Timer.periodic(
      _broadcastInterval,
      (_) => _removeExpiredDevices(),
    );
    _refreshTimer = Timer.periodic(
      _refreshInterval,
      (_) => requestRefresh(),
    );
    _emitDevices();
    requestRefresh();
  }

  Future<void> startAdvertising({
    required String deviceId,
    required String name,
    required int port,
    required bool usesTls,
    String? certificateFingerprint,
    String? certificatePem,
  }) async {
    if (_advertisement != null &&
        _discoveryPort != null &&
        _discoveryPort != port) {
      await stopAdvertising();
    }

    await startDiscovery(localDeviceId: deviceId, port: port);
    _advertisingInstanceId = DateTime.now().microsecondsSinceEpoch.toString();
    // NOTE: The full certificate PEM is deliberately NOT embedded in the
    // periodic hello. A 2048-bit RSA cert pushes the datagram past the ~1500
    // byte MTU, and IP-fragmented UDP broadcasts are dropped by many Wi-Fi
    // stacks (notably Android). Peers instead verify the TLS handshake against
    // `certFingerprint` via onBadCertificate.
    _advertisement = {
      'protocol': _protocol,
      'action': 'hello',
      'instanceId': _advertisingInstanceId,
      'id': deviceId,
      'name': name,
      'port': port,
      'tls': usesTls,
      'certFingerprint': certificateFingerprint,
      'deviceType': Platform.isAndroid || Platform.isIOS
          ? DiscoveredDeviceType.phone.name
          : DiscoveredDeviceType.laptop.name,
    };
    if (kDebugMode) {
      debugPrint(
        '[DISCOVERY] advertising name="$name" tls=$usesTls '
        'fingerprint=${certificateFingerprint != null} '
        'bytes=${utf8.encode(jsonEncode(_advertisement!)).length}',
      );
    }
    _broadcastTimer?.cancel();
    _cancelAdvertiseBurst();
    _broadcastAdvertisement();
    for (final delay in _advertiseBurstDelays) {
      _advertiseBurstTimers.add(Timer(delay, _broadcastAdvertisement));
    }
    _broadcastTimer = Timer.periodic(
      _broadcastInterval,
      (_) => _broadcastAdvertisement(),
    );
  }

  Future<void> stopAdvertising() async {
    _broadcastTimer?.cancel();
    _broadcastTimer = null;
    _cancelAdvertiseBurst();
    final advertisement = _advertisement;
    if (advertisement != null) {
      final goodbye = {...advertisement, 'action': 'goodbye'};
      _sendPacket(goodbye);
      for (final delay in _goodbyeBurstDelays) {
        await Future<void>.delayed(delay);
        _sendPacket(goodbye);
      }
    }
    _advertisement = null;
    _advertisingInstanceId = null;
  }

  Future<void> stopDiscovery() async {
    _cancelAdvertiseBurst();
    _cancelProbeBurst();
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    await _receiveSubscription?.cancel();
    _receiveSubscription = null;
    _receiveSocket?.close();
    _receiveSocket = null;
    for (final socket in _sendSockets) {
      socket.socket.close();
    }
    _sendSockets.clear();
    _discoveryPort = null;
    _devices.clear();
    _emitDevices();
  }

  Future<void> stop() async {
    await stopAdvertising();
    await stopDiscovery();
  }

  void requestRefresh() {
    _sendProbe();
    _broadcastAdvertisement();
    _scheduleProbeBurst();
  }

  void _processInboundMessage(
    Map<String, dynamic> message, {
    required InternetAddress sourceAddress,
  }) {
    if (message['protocol'] != _protocol) {
      return;
    }

    final id = message['id'] as String?;
    if (id == null || id == _localDeviceId) {
      return;
    }

    if (message['action'] == 'probe') {
      _sendAdvertisement(address: sourceAddress);
      return;
    }

    if (message['action'] == 'goodbye') {
      final seenDevice = _devices[id];
      final instanceId = message['instanceId'] as String?;
      if (seenDevice != null &&
          (seenDevice.instanceId == null ||
              seenDevice.instanceId == instanceId)) {
        _devices.remove(id);
        _emitDevices();
      }
      return;
    }

    final name = message['name'] as String?;
    final port = message['port'] as int?;
    final usesTls = message['tls'] as bool?;
    final certificateFingerprint = message['certFingerprint'] as String?;
    // `cert` is optional for compatibility with older peers that still embed
    // the PEM; fingerprint-based verification is the supported path.
    final certificatePem = message['cert'] as String?;
    final instanceId = message['instanceId'] as String?;
    if (name == null || port == null || usesTls == null) {
      if (kDebugMode) {
        debugPrint(
          '[DISCOVERY] dropping hello id=$id (missing name/port/tls)',
        );
      }
      return;
    }
    if (usesTls && certificateFingerprint == null) {
      if (kDebugMode) {
        debugPrint('[DISCOVERY] dropping hello id=$id (tls w/o fingerprint)');
      }
      return;
    }
    final deviceType = DiscoveredDeviceType.values.firstWhere(
      (type) => type.name == message['deviceType'],
      orElse: () => DiscoveredDeviceType.phone,
    );

    final nextDevice = DiscoveredDevice(
      id: id,
      name: name,
      address: sourceAddress.address,
      port: port,
      usesTls: usesTls,
      type: deviceType,
      certificateFingerprint: certificateFingerprint,
      certificatePem: certificatePem,
    );
    final previousDevice = _devices[id]?.device;
    _devices[id] = _SeenDevice(
      device: nextDevice,
      instanceId: instanceId,
      lastSeen: DateTime.now(),
    );
    if (!_sameDevice(previousDevice, nextDevice)) {
      _emitDevices();
    }
  }

  Future<void> _bindReceiveSocket(int port) async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      port,
      reuseAddress: true,
    );
    socket.broadcastEnabled = true;
    _receiveSocket = socket;
    _receiveSubscription = socket.listen(_handleSocketEvent);
  }

  Future<List<_DiscoverySocket>> _createSendSockets(int port) async {
    final sockets = <_DiscoverySocket>[];
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    ).then((interfaces) => interfaces.where(_isUsableInterface).toList());

    for (final interface in interfaces) {
      for (final address in interface.addresses.where(_isUsableAddress)) {
        final socket = await _bindDiscoverySocket(
          port,
          interface: interface,
          address: address,
        );
        if (socket != null) {
          sockets.add(socket);
        }
      }
    }

    if (sockets.isEmpty) {
      final receiveSocket = _receiveSocket;
      if (receiveSocket != null) {
        sockets.add(
          _DiscoverySocket(
            socket: receiveSocket,
            interface: null,
            address: null,
            broadcastTargets: [_limitedBroadcast],
          ),
        );
      }
    }

    if (sockets.isEmpty) {
      throw const SocketException('Could not bind broadcast sender socket.');
    }

    return sockets;
  }

  bool _isUsableInterface(NetworkInterface interface) {
    final name = interface.name.toLowerCase();
    if (name.startsWith('docker') ||
        name.startsWith('veth') ||
        name.startsWith('br-') ||
        name.startsWith('virbr') ||
        name.startsWith('lo') ||
        name.startsWith('rmnet') ||
        name.startsWith('ccmni') ||
        name.startsWith('wwan')) {
      return false;
    }

    return interface.addresses.any(_isUsableAddress);
  }

  bool _isUsableAddress(InternetAddress address) {
    if (address.type != InternetAddressType.IPv4 || address.isLoopback) {
      return false;
    }
    final bytes = address.rawAddress;
    if (bytes.length != 4 || bytes[0] == 0 || bytes[0] == 127) {
      return false;
    }

    // Link-local addresses are not useful for this app's TCP follow-up.
    if (bytes[0] == 169 && bytes[1] == 254) {
      return false;
    }

    return true;
  }

  Future<_DiscoverySocket?> _bindDiscoverySocket(
    int port, {
    NetworkInterface? interface,
    InternetAddress? address,
  }) async {
    try {
      final socket = await RawDatagramSocket.bind(
        address ?? InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
      );
      socket.broadcastEnabled = true;
      return _DiscoverySocket(
        socket: socket,
        interface: interface,
        address: address,
        broadcastTargets: address == null
            ? [_limitedBroadcast]
            : _broadcastTargetsFor(address),
      );
    } on SocketException {
      return null;
    } on OSError {
      return null;
    }
  }

  List<InternetAddress> _broadcastTargetsFor(InternetAddress address) {
    final targets = <String, InternetAddress>{};
    for (final prefixLength in _fallbackBroadcastPrefixes) {
      final broadcast = _broadcastForPrefix(address, prefixLength);
      if (broadcast != null) {
        targets[broadcast.address] = broadcast;
      }
    }
    targets[_limitedBroadcast.address] = _limitedBroadcast;
    return targets.values.toList(growable: false);
  }

  InternetAddress? _broadcastForPrefix(
    InternetAddress address,
    int prefixLength,
  ) {
    if (!_isUsableAddress(address) || prefixLength < 0 || prefixLength > 32) {
      return null;
    }

    final bytes = address.rawAddress;
    final addressInt =
        (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
    final mask = prefixLength == 0 ? 0 : 0xffffffff << (32 - prefixLength);
    final broadcast = (addressInt | (~mask)) & 0xffffffff;

    return InternetAddress(
      '${(broadcast >> 24) & 0xff}.'
      '${(broadcast >> 16) & 0xff}.'
      '${(broadcast >> 8) & 0xff}.'
      '${broadcast & 0xff}',
    );
  }

  void _handleSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) {
      return;
    }

    Datagram? datagram;
    while ((datagram = _receiveSocket?.receive()) != null) {
      _handleDatagram(datagram!);
    }
  }

  void _handleDatagram(Datagram datagram) {
    if (datagram.address.type != InternetAddressType.IPv4 ||
        datagram.address.isLoopback) {
      return;
    }

    try {
      final message =
          jsonDecode(utf8.decode(datagram.data)) as Map<String, dynamic>;
      _processInboundMessage(message, sourceAddress: datagram.address);
    } on FormatException {
      // Ignore unrelated UDP traffic received on the configured port.
    } on TypeError {
      // Ignore malformed discovery packets.
    }
  }

  void _broadcastAdvertisement() {
    _sendAdvertisement();
  }

  void _sendAdvertisement({InternetAddress? address}) {
    final advertisement = _advertisement;
    if (advertisement != null) {
      _sendPacket(advertisement, address: address);
    }
  }

  void _sendProbe() {
    final localDeviceId = _localDeviceId;
    if (localDeviceId == null) {
      return;
    }

    _sendPacket({
      'protocol': _protocol,
      'action': 'probe',
      'id': localDeviceId,
    });
  }

  void _cancelAdvertiseBurst() {
    for (final timer in _advertiseBurstTimers) {
      timer.cancel();
    }
    _advertiseBurstTimers.clear();
  }

  void _scheduleProbeBurst() {
    _cancelProbeBurst();
    for (final delay in _probeBurstDelays) {
      _probeBurstTimers.add(Timer(delay, _sendProbe));
    }
  }

  void _cancelProbeBurst() {
    for (final timer in _probeBurstTimers) {
      timer.cancel();
    }
    _probeBurstTimers.clear();
  }

  void _sendPacket(Map<String, dynamic> packet, {InternetAddress? address}) {
    final port = _discoveryPort;
    if (_receiveSocket == null || port == null) {
      return;
    }

    if (address == null) {
      _sendBroadcastPacket(packet);
      return;
    }

    final encodedPacket = utf8.encode(jsonEncode(packet));
    for (final socket in _sendSockets) {
      try {
        socket.socket.send(encodedPacket, address, port);
      } on SocketException {
        // Try every sender socket; the next heartbeat retries failures.
      }
    }
  }

  void _sendBroadcastPacket(Map<String, dynamic> packet) {
    final port = _discoveryPort;
    if (_sendSockets.isEmpty || port == null) {
      if (kDebugMode) {
        debugPrint('[DISCOVERY] cannot broadcast: no send sockets bound');
      }
      return;
    }

    final encodedPacket = utf8.encode(jsonEncode(packet));
    for (final socket in _sendSockets) {
      for (final target in socket.broadcastTargets) {
        try {
          final bytesSent = socket.socket.send(encodedPacket, target, port);
          if (bytesSent > 0) {
            break;
          }
        } on SocketException catch (e) {
          // Try every broadcast target; the next heartbeat retries failures.
          if (kDebugMode) {
            debugPrint(
              '[DISCOVERY] broadcast to ${target.address}:$port failed: ${e.message}',
            );
          }
        }
      }
    }
  }

  void _removeExpiredDevices() {
    final cutoff = DateTime.now().subtract(_peerTimeout);
    final previousLength = _devices.length;
    _devices.removeWhere((_, entry) => entry.lastSeen.isBefore(cutoff));
    if (_devices.length != previousLength) {
      _emitDevices();
    }
  }

  bool _sameDevice(DiscoveredDevice? previous, DiscoveredDevice next) {
    return previous != null &&
        previous.id == next.id &&
        previous.name == next.name &&
        previous.address == next.address &&
        previous.port == next.port &&
        previous.usesTls == next.usesTls &&
        previous.type == next.type &&
        previous.certificateFingerprint == next.certificateFingerprint &&
        previous.certificatePem == next.certificatePem;
  }

  void _emitDevices() {
    final sortedDevices = _devices.values.map((entry) => entry.device).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    _devicesController.add(List.unmodifiable(sortedDevices));
  }
}

class _DiscoverySocket {
  const _DiscoverySocket({
    required this.socket,
    required this.interface,
    required this.address,
    required this.broadcastTargets,
  });

  final RawDatagramSocket socket;
  final NetworkInterface? interface;
  final InternetAddress? address;
  final List<InternetAddress> broadcastTargets;
}

class _SeenDevice {
  const _SeenDevice({
    required this.device,
    required this.instanceId,
    required this.lastSeen,
  });

  final DiscoveredDevice device;
  final String? instanceId;
  final DateTime lastSeen;
}
