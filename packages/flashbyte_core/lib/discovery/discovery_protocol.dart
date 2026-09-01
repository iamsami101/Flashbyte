import 'dart:io';

/// Protocol constants for UDP device discovery.
const kDiscoveryProtocol = 'flashbyte-discovery-v1';
const kDiscoveryBroadcastInterval = Duration(seconds: 2);
const kDiscoveryPeerTimeout = Duration(seconds: 20);
const kDiscoveryRefreshInterval = Duration(seconds: 4);

const kAdvertiseBurstDelays = [
  Duration(milliseconds: 180),
  Duration(milliseconds: 650),
];

const kProbeBurstDelays = [
  Duration(milliseconds: 220),
  Duration(milliseconds: 700),
];

const kGoodbyeBurstDelays = [
  Duration(milliseconds: 80),
  Duration(milliseconds: 180),
];

const kFallbackBroadcastPrefixes = [24, 20, 16, 28, 29, 30];

/// Builds a hello advertisement packet.
Map<String, dynamic> buildHelloPacket({
  required String instanceId,
  required String deviceId,
  required String name,
  required int port,
  required bool usesTls,
  String? certificateFingerprint,
  required String deviceType,
}) {
  return {
    'protocol': kDiscoveryProtocol,
    'action': 'hello',
    'instanceId': instanceId,
    'id': deviceId,
    'name': name,
    'port': port,
    'tls': usesTls,
    'certFingerprint': certificateFingerprint,
    'deviceType': deviceType,
  };
}

/// Builds a probe packet.
Map<String, dynamic> buildProbePacket({required String deviceId}) {
  return {'protocol': kDiscoveryProtocol, 'action': 'probe', 'id': deviceId};
}

/// Builds a goodbye packet from an existing advertisement.
Map<String, dynamic> buildGoodbyePacket(Map<String, dynamic> advertisement) {
  return {...advertisement, 'action': 'goodbye'};
}

/// Validates a received discovery message.
bool isValidDiscoveryMessage(Map<String, dynamic> message) {
  return message['protocol'] == kDiscoveryProtocol;
}

/// Computes broadcast target addresses for a given interface address.
List<InternetAddress> broadcastTargetsForAddress(InternetAddress address) {
  final targets = <String, InternetAddress>{};
  for (final prefixLength in kFallbackBroadcastPrefixes) {
    final broadcast = _broadcastForPrefix(address, prefixLength);
    if (broadcast != null) {
      targets[broadcast.address] = broadcast;
    }
  }
  targets[_limitedBroadcast.address] = _limitedBroadcast;
  return targets.values.toList(growable: false);
}

final _limitedBroadcast = InternetAddress('255.255.255.255');

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

/// Checks if a network interface is usable for discovery broadcasts.
bool isUsableInterface(NetworkInterface interface) {
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

/// Checks if an IPv4 address is usable for discovery.
bool isUsableAddress(InternetAddress address) => _isUsableAddress(address);

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
