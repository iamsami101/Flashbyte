/// Adapter for logging without depending on flutter/foundation.dart.
abstract class LoggerAdapter {
  void log(String message);
}
