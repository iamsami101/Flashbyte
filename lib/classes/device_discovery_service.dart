import 'dart:async';
import 'dart:convert';
import 'dart:io';

enum DiscoveredDeviceType { phone, laptop }

class DiscoveredDevice {
  const DiscoveredDevice({
    required this.id,
    required this.name,
    required this.address,
    required this.port,
    required this.usesTls,
    required this.type,
    this.certificateFingerprint,
    this.certificatePem,
  });

  final String id;
  final String name;
  final String address;
  final int port;
  final bool usesTls;
  final DiscoveredDeviceType type;
  final String? certificateFingerprint;
  final String? certificatePem;
}

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
  static const _refreshInterval = Duration(seconds: 4);
  static const _peerTimeout = Duration(seconds: 20);
  static final _multicastGroup = InternetAddress('224.0.0.167');

  final _devicesController =
      StreamController<List<DiscoveredDevice>>.broadcast();
  final Map<String, _SeenDevice> _devices = {};

  final List<_DiscoverySocket> _sockets = [];
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
    if (_sockets.isNotEmpty && _discoveryPort == port) {
      _emitDevices();
      requestRefresh();
      return;
    }

    await stopDiscovery();
    _sockets.addAll(await _createMulticastSockets(port));
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
    _advertisement = {
      'protocol': _protocol,
      'action': 'hello',
      'instanceId': _advertisingInstanceId,
      'id': deviceId,
      'name': name,
      'port': port,
      'tls': usesTls,
      'certFingerprint': certificateFingerprint,
      'cert': certificatePem,
      'deviceType': Platform.isAndroid || Platform.isIOS
          ? DiscoveredDeviceType.phone.name
          : DiscoveredDeviceType.laptop.name,
    };
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
      _sendPacket({...advertisement, 'action': 'goodbye'});
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
    for (final socket in _sockets) {
      await socket.subscription.cancel();
      socket.socket.close();
    }
    _sockets.clear();
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

  Future<List<_DiscoverySocket>> _createMulticastSockets(int port) async {
    final sockets = <_DiscoverySocket>[];
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );

    for (final interface in interfaces) {
      final socket = await _bindMulticastSocket(port, interface: interface);
      if (socket != null) {
        sockets.add(socket);
      }
    }

    if (sockets.isEmpty) {
      final socket = await _bindMulticastSocket(port);
      if (socket != null) {
        sockets.add(socket);
      }
    }

    if (sockets.isEmpty) {
      throw const SocketException('Could not bind multicast discovery socket.');
    }

    return sockets;
  }

  Future<_DiscoverySocket?> _bindMulticastSocket(
    int port, {
    NetworkInterface? interface,
  }) async {
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
        reuseAddress: true,
        reusePort: true,
      );
      socket.joinMulticast(_multicastGroup, interface);
      socket.multicastHops = 1;
      final subscription = socket.listen(_handleSocketEvent);
      return _DiscoverySocket(
        socket: socket,
        subscription: subscription,
        interface: interface,
      );
    } on SocketException {
      return null;
    } on OSError {
      return null;
    }
  }

  void _handleSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) {
      return;
    }

    for (final socket in _sockets) {
      Datagram? datagram;
      while ((datagram = socket.socket.receive()) != null) {
        _handleDatagram(datagram!);
      }
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
      if (message['protocol'] != _protocol) {
        return;
      }

      final id = message['id'] as String?;
      if (id == null || id == _localDeviceId) {
        return;
      }
      if (message['action'] == 'probe') {
        _sendAdvertisement(address: datagram.address);
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
      final certificatePem = message['cert'] as String?;
      final instanceId = message['instanceId'] as String?;
      if (name == null || port == null || usesTls == null) {
        return;
      }
      if (usesTls &&
          (certificateFingerprint == null || certificatePem == null)) {
        return;
      }
      final deviceType = DiscoveredDeviceType.values.firstWhere(
        (type) => type.name == message['deviceType'],
        orElse: () => DiscoveredDeviceType.phone,
      );

      final nextDevice = DiscoveredDevice(
        id: id,
        name: name,
        address: datagram.address.address,
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
    if (_sockets.isEmpty || port == null) {
      return;
    }

    if (address == null) {
      _sendMulticastPacket(packet);
      return;
    }

    final encodedPacket = utf8.encode(jsonEncode(packet));
    for (final socket in _sockets) {
      try {
        socket.socket.send(encodedPacket, address, port);
      } on SocketException {
        // Try every joined interface; the next heartbeat retries failures.
      }
    }
  }

  void _sendMulticastPacket(Map<String, dynamic> packet) {
    final port = _discoveryPort;
    if (_sockets.isEmpty || port == null) {
      return;
    }

    final encodedPacket = utf8.encode(jsonEncode(packet));
    for (final socket in _sockets) {
      try {
        socket.socket.multicastHops = 1;
        socket.socket.send(encodedPacket, _multicastGroup, port);
      } on SocketException {
        // Try every joined interface; the next heartbeat retries failures.
      } on UnimplementedError {
        // Some Dart socket backends do not expose multicast socket options.
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
    required this.subscription,
    required this.interface,
  });

  final RawDatagramSocket socket;
  final StreamSubscription<RawSocketEvent> subscription;
  final NetworkInterface? interface;
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
