/// Adapter for querying device information without platform dependencies.
abstract class DeviceInfoAdapter {
  bool get isMobile;
  String get deviceType;
}
