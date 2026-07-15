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
  static const _peerTimeout = Duration(seconds: 6);

  final _devicesController =
      StreamController<List<DiscoveredDevice>>.broadcast();
  final Map<String, _SeenDevice> _devices = {};

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _socketSubscription;
  Timer? _broadcastTimer;
  Timer? _cleanupTimer;
  String? _localDeviceId;
  int? _discoveryPort;
  Map<String, dynamic>? _advertisement;

  Stream<List<DiscoveredDevice>> get devicesStream => _devicesController.stream;
  List<DiscoveredDevice> get devices =>
      List.unmodifiable(_devices.values.map((entry) => entry.device));

  Future<void> startDiscovery({
    required String localDeviceId,
    required int port,
  }) async {
    _localDeviceId = localDeviceId;
    if (_socket != null && _discoveryPort == port) {
      return;
    }

    await stopDiscovery();
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      port,
      reuseAddress: true,
    );
    socket.broadcastEnabled = true;
    _socket = socket;
    _discoveryPort = port;
    _socketSubscription = socket.listen(_handleSocketEvent);
    _cleanupTimer = Timer.periodic(
      _broadcastInterval,
      (_) => _removeExpiredDevices(),
    );
  }

  Future<void> startAdvertising({
    required String deviceId,
    required String name,
    required int port,
    required bool usesTls,
    String? certificateFingerprint,
    String? certificatePem,
  }) async {
    await startDiscovery(localDeviceId: deviceId, port: port);
    _advertisement = {
      'protocol': _protocol,
      'action': 'hello',
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
    _broadcastAdvertisement();
    _broadcastTimer = Timer.periodic(
      _broadcastInterval,
      (_) => _broadcastAdvertisement(),
    );
  }

  Future<void> stopAdvertising() async {
    _broadcastTimer?.cancel();
    _broadcastTimer = null;
    final advertisement = _advertisement;
    if (advertisement != null) {
      _sendPacket({...advertisement, 'action': 'goodbye'});
    }
    _advertisement = null;
  }

  Future<void> stopDiscovery() async {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    _socket?.close();
    _socket = null;
    _discoveryPort = null;
    _devices.clear();
    _emitDevices();
  }

  Future<void> stop() async {
    await stopAdvertising();
    await stopDiscovery();
  }

  void _handleSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) {
      return;
    }

    Datagram? datagram;
    while ((datagram = _socket?.receive()) != null) {
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
      if (message['protocol'] != _protocol) {
        return;
      }

      final id = message['id'] as String?;
      if (id == null || id == _localDeviceId) {
        return;
      }
      if (message['action'] == 'goodbye') {
        _devices.remove(id);
        _emitDevices();
        return;
      }

      final name = message['name'] as String?;
      final port = message['port'] as int?;
      final usesTls = message['tls'] as bool?;
      final certificateFingerprint = message['certFingerprint'] as String?;
      final certificatePem = message['cert'] as String?;
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

      _devices[id] = _SeenDevice(
        device: DiscoveredDevice(
          id: id,
          name: name,
          address: datagram.address.address,
          port: port,
          usesTls: usesTls,
          type: deviceType,
          certificateFingerprint: certificateFingerprint,
          certificatePem: certificatePem,
        ),
        lastSeen: DateTime.now(),
      );
      _emitDevices();
    } on FormatException {
      // Ignore unrelated UDP traffic received on the configured port.
    } on TypeError {
      // Ignore malformed discovery packets.
    }
  }

  void _broadcastAdvertisement() {
    final advertisement = _advertisement;
    if (advertisement != null) {
      _sendPacket(advertisement);
    }
  }

  void _sendPacket(Map<String, dynamic> packet) {
    final socket = _socket;
    final port = _discoveryPort;
    if (socket == null || port == null) {
      return;
    }

    try {
      socket.send(
        utf8.encode(jsonEncode(packet)),
        InternetAddress('255.255.255.255'),
        port,
      );
    } on SocketException {
      // The next heartbeat retries after temporary network failures.
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

  void _emitDevices() {
    final sortedDevices = _devices.values.map((entry) => entry.device).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    _devicesController.add(List.unmodifiable(sortedDevices));
  }
}

class _SeenDevice {
  const _SeenDevice({
    required this.device,
    required this.lastSeen,
  });

  final DiscoveredDevice device;
  final DateTime lastSeen;
}
