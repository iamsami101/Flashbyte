import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';

class DiscoveredDevice {
  const DiscoveredDevice({
    required this.id,
    required this.name,
    required this.address,
    required this.port,
    required this.usesTls,
  });

  final String id;
  final String name;
  final String address;
  final int port;
  final bool usesTls;
}

class DeviceDiscoveryService {
  DeviceDiscoveryService._();

  static final DeviceDiscoveryService instance = DeviceDiscoveryService._();
  static const serviceType = '_flashbyte._tcp';

  final _devicesController =
      StreamController<List<DiscoveredDevice>>.broadcast();
  final Map<String, DiscoveredDevice> _devices = {};

  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _discoverySubscription;
  String? _localDeviceId;

  Stream<List<DiscoveredDevice>> get devicesStream => _devicesController.stream;
  List<DiscoveredDevice> get devices => List.unmodifiable(_devices.values);

  Future<void> startDiscovery({required String localDeviceId}) async {
    _localDeviceId = localDeviceId;
    if (_discovery != null) {
      return;
    }

    final discovery = BonsoirDiscovery(type: serviceType);
    await discovery.initialize();
    _discoverySubscription = discovery.eventStream!.listen(
      (event) => _handleDiscoveryEvent(event, discovery),
    );
    _discovery = discovery;
    await discovery.start();
  }

  Future<void> startAdvertising({
    required String deviceId,
    required String name,
    required int port,
    required bool usesTls,
  }) async {
    await stopAdvertising();

    final broadcast = BonsoirBroadcast(
      service: BonsoirService(
        name: name,
        type: serviceType,
        port: port,
        attributes: {
          'id': deviceId,
          'tls': usesTls ? '1' : '0',
        },
      ),
    );
    await broadcast.initialize();
    _broadcast = broadcast;
    await broadcast.start();
  }

  Future<void> stopAdvertising() async {
    final broadcast = _broadcast;
    _broadcast = null;
    if (broadcast != null && !broadcast.isStopped) {
      await broadcast.stop();
    }
  }

  Future<void> stopDiscovery() async {
    final discovery = _discovery;
    _discovery = null;
    await _discoverySubscription?.cancel();
    _discoverySubscription = null;
    if (discovery != null && !discovery.isStopped) {
      await discovery.stop();
    }
    _devices.clear();
    _emitDevices();
  }

  Future<void> stop() async {
    await stopAdvertising();
    await stopDiscovery();
  }

  void _handleDiscoveryEvent(
    BonsoirDiscoveryEvent event,
    BonsoirDiscovery discovery,
  ) {
    switch (event) {
      case BonsoirDiscoveryServiceFoundEvent():
        event.service.resolve(discovery.serviceResolver);
      case BonsoirDiscoveryServiceResolvedEvent():
        _upsertService(event.service);
      case BonsoirDiscoveryServiceUpdatedEvent():
        _upsertService(event.service);
      case BonsoirDiscoveryServiceLostEvent():
        _devices.remove(_serviceKey(event.service));
        _emitDevices();
      default:
        break;
    }
  }

  void _upsertService(BonsoirService service) {
    final deviceId = service.attributes['id'] ?? _serviceKey(service);
    if (deviceId == _localDeviceId) {
      return;
    }

    final address = service.hostAddresses.cast<String?>().firstWhere(
      (value) =>
          value != null &&
          value.isNotEmpty &&
          !InternetAddress(value).isLoopback &&
          InternetAddress(value).type == InternetAddressType.IPv4,
      orElse: () => service.hostAddress,
    );
    if (address == null || address.isEmpty) {
      return;
    }

    _devices[_serviceKey(service)] = DiscoveredDevice(
      id: deviceId,
      name: service.name,
      address: address,
      port: service.port,
      usesTls: service.attributes['tls'] == '1',
    );
    _emitDevices();
  }

  String _serviceKey(BonsoirService service) =>
      service.attributes['id'] ?? '${service.name}:${service.port}';

  void _emitDevices() {
    final sortedDevices = _devices.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    _devicesController.add(List.unmodifiable(sortedDevices));
  }
}
