import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

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
  static const _commonHotspotGateways = [
    '192.168.43.1',
    '192.168.49.1',
    '192.168.137.1',
    '172.20.10.1',
  ];
  static const _fallbackBroadcastPrefixes = [24, 20, 16, 28, 29, 30];

  final _devicesController =
      StreamController<List<DiscoveredDevice>>.broadcast();
  final Map<String, _SeenDevice> _devices = {};

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _socketSubscription;
  Timer? _broadcastTimer;
  final List<Timer> _advertiseBurstTimers = [];
  final List<Timer> _probeBurstTimers = [];
  Timer? _cleanupTimer;
  Timer? _refreshTimer;
  String? _localDeviceId;
  int? _discoveryPort;
  Map<String, dynamic>? _advertisement;
  String? _advertisingInstanceId;
  static const _androidDiscoveryChannel = MethodChannel(
    'flashbyte/udp_discovery',
  );

  Stream<List<DiscoveredDevice>> get devicesStream => _devicesController.stream;
  List<DiscoveredDevice> get devices =>
      List.unmodifiable(_devices.values.map((entry) => entry.device));

  Future<void> startDiscovery({
    required String localDeviceId,
    required int port,
  }) async {
    _localDeviceId = localDeviceId;
    if (_socket != null && _discoveryPort == port) {
      _emitDevices();
      requestRefresh();
      return;
    }

    await stopDiscovery();
    await _acquirePlatformDiscoveryLock();
    late final RawDatagramSocket socket;
    try {
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
        reuseAddress: true,
      );
    } catch (_) {
      await _releasePlatformDiscoveryLock();
      rethrow;
    }
    socket.broadcastEnabled = true;
    _socket = socket;
    _discoveryPort = port;
    _socketSubscription = socket.listen(_handleSocketEvent);
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
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    _socket?.close();
    _socket = null;
    _discoveryPort = null;
    await _releasePlatformDiscoveryLock();
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
    final socket = _socket;
    final port = _discoveryPort;
    if (socket == null || port == null) {
      return;
    }

    if (address == null) {
      unawaited(_sendBroadcastPacket(packet));
      return;
    }

    try {
      socket.send(
        utf8.encode(jsonEncode(packet)),
        address,
        port,
      );
    } on SocketException {
      // The next heartbeat retries after temporary network failures.
    }
  }

  Future<void> _sendBroadcastPacket(Map<String, dynamic> packet) async {
    final socket = _socket;
    final port = _discoveryPort;
    if (socket == null || port == null) {
      return;
    }

    final encodedPacket = utf8.encode(jsonEncode(packet));
    final targets = <String, InternetAddress>{
      '255.255.255.255': InternetAddress('255.255.255.255'),
    };
    for (final gateway in _commonHotspotGateways) {
      _addTarget(targets, gateway);
    }

    await _addPlatformNetworkTargets(targets);

    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          for (final broadcastAddress in _fallbackBroadcastsFor(address)) {
            targets[broadcastAddress.address] = broadcastAddress;
          }
          for (final gatewayAddress in _fallbackGatewayAddressesFor(address)) {
            targets[gatewayAddress.address] = gatewayAddress;
          }
        }
      }
    } on SocketException {
      // Fall back to the global broadcast address below.
    }

    for (final target in targets.values) {
      try {
        socket.send(encodedPacket, target, port);
      } on SocketException {
        // Try every discovered target; the next heartbeat retries failures.
      }
    }
  }

  Future<void> _addPlatformNetworkTargets(
    Map<String, InternetAddress> targets,
  ) async {
    if (!Platform.isAndroid) {
      return;
    }

    try {
      final networkTargets = await _androidDiscoveryChannel
          .invokeListMethod<dynamic>('getNetworkTargets');
      if (networkTargets == null) {
        return;
      }

      for (final target in networkTargets) {
        if (target is! Map) {
          continue;
        }
        _addTarget(targets, target['broadcast']);

        final address = target['address'];
        final prefixLength = target['prefixLength'];
        if (address is String && prefixLength is int) {
          final broadcast = _broadcastForPrefix(
            InternetAddress(address),
            prefixLength,
          );
          if (broadcast != null) {
            targets[broadcast.address] = broadcast;
          }
        }

        final gateways = target['gateways'];
        if (gateways is List) {
          for (final gateway in gateways) {
            _addTarget(targets, gateway);
          }
        }
      }
    } on PlatformException {
      // Fall back to global broadcast and locally derived candidates.
    } on MissingPluginException {
      // Non-Android builds and tests do not register this channel.
    } on ArgumentError {
      // Ignore malformed platform addresses and use fallback targets.
    }
  }

  void _addTarget(Map<String, InternetAddress> targets, Object? address) {
    if (address is! String || address.isEmpty) {
      return;
    }

    try {
      final internetAddress = InternetAddress(address);
      if (internetAddress.type == InternetAddressType.IPv4 &&
          !internetAddress.isLoopback) {
        targets[internetAddress.address] = internetAddress;
      }
    } on ArgumentError {
      // Ignore malformed platform addresses.
    }
  }

  List<InternetAddress> _fallbackBroadcastsFor(InternetAddress address) {
    if (address.type != InternetAddressType.IPv4 || address.isLoopback) {
      return const [];
    }

    return [
      for (final prefixLength in _fallbackBroadcastPrefixes)
        ?_broadcastForPrefix(address, prefixLength),
    ];
  }

  InternetAddress? _broadcastForPrefix(
    InternetAddress address,
    int prefixLength,
  ) {
    if (address.type != InternetAddressType.IPv4 ||
        address.isLoopback ||
        prefixLength < 0 ||
        prefixLength > 32) {
      return null;
    }

    final bytes = address.rawAddress;
    if (bytes.length != 4 || bytes[0] == 0 || bytes[0] == 127) {
      return null;
    }

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

  List<InternetAddress> _fallbackGatewayAddressesFor(InternetAddress address) {
    if (address.type != InternetAddressType.IPv4 || address.isLoopback) {
      return const [];
    }

    final bytes = address.rawAddress;
    if (bytes.length != 4 || bytes[0] == 0 || bytes[0] == 127) {
      return const [];
    }

    final gateways = <String, InternetAddress>{};
    for (final lastOctet in const [1, 254]) {
      if (bytes[3] == lastOctet) {
        continue;
      }
      final gateway = InternetAddress(
        '${bytes[0]}.${bytes[1]}.${bytes[2]}.$lastOctet',
      );
      gateways[gateway.address] = gateway;
    }

    return gateways.values.toList(growable: false);
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

  Future<void> _acquirePlatformDiscoveryLock() async {
    if (!Platform.isAndroid) {
      return;
    }

    try {
      await _androidDiscoveryChannel.invokeMethod<void>(
        'acquireMulticastLock',
      );
    } on PlatformException {
      // Discovery can still work on devices that do not expose the lock.
    } on MissingPluginException {
      // Non-Android builds and tests do not register this channel.
    }
  }

  Future<void> _releasePlatformDiscoveryLock() async {
    if (!Platform.isAndroid) {
      return;
    }

    try {
      await _androidDiscoveryChannel.invokeMethod<void>(
        'releaseMulticastLock',
      );
    } on PlatformException {
      // The OS may already have released it during activity teardown.
    } on MissingPluginException {
      // Non-Android builds and tests do not register this channel.
    }
  }
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
