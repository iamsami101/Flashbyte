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
