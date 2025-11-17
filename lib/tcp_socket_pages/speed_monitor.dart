import 'dart:async';

class ByteSpeedMonitor {
  late int lastByteCount;
  late DateTime lastTime;
  Timer? timer;

  ByteSpeedMonitor() {
    lastByteCount = 0;
    lastTime = DateTime.now();
  }

  void startMonitoring({Duration interval = const Duration(seconds: 1)}) {
    timer = Timer.periodic(interval, (timer) {
      calculateAndPrintSpeed();
    });
  }

  void stopMonitoring() {
    timer?.cancel();
  }

  void calculateAndPrintSpeed() {
    int currentByteCount = 0;
    DateTime currentTime = DateTime.now();

    int bytesAdded = currentByteCount - lastByteCount;
    Duration timeElapsed = currentTime.difference(lastTime);

    if (timeElapsed.inSeconds > 0) {
      double speed = bytesAdded / timeElapsed.inSeconds; // bytes per second
      String speedString;

      if (speed >= 1024 * 1024) {
        speedString = '${(speed / (1024 * 1024)).toStringAsFixed(2)} MB/s';
      } else if (speed >= 1024) {
        speedString = '${(speed / 1024).toStringAsFixed(2)} kB/s';
      } else {
        speedString = '${speed.toStringAsFixed(2)} B/s';
      }

      print('Speed: $speedString');
    }

    lastByteCount = currentByteCount;
    lastTime = currentTime;
  }
}
