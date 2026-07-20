import 'dart:async';
import 'dart:io';

import 'package:flashbyte/services/transfer/socket_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class AndroidConnectionNotificationService {
  AndroidConnectionNotificationService._();

  static final AndroidConnectionNotificationService instance =
      AndroidConnectionNotificationService._();

  static const int _foregroundServiceId = 8050;
  static const int _progressNotificationId = 8051;
  static const String _progressChannelId = 'file_transfer_progress';
  static const String _progressChannelName = 'File transfer progress';
  static const Duration _progressUpdateInterval = Duration(milliseconds: 500);
  static const String _foregroundNotificationTitle = 'Flashbyte';
  static const String _foregroundNotificationText = 'Connection established';
  static const String _notificationIcon = 'ic_notification';

  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  final Map<String, _TransferProgress> _activeTransfers = {};
  AndroidFlutterLocalNotificationsPlugin? _androidNotifications;

  StreamSubscription<bool>? _connectionSubscription;
  StreamSubscription<Map<String, dynamic>>? _messageSubscription;
  Timer? _progressNotificationTimer;
  DateTime? _lastProgressNotificationUpdate;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;

    if (!Platform.isAndroid) {
      return;
    }

    await _localNotifications.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings(_notificationIcon),
        iOS: DarwinInitializationSettings(),
        macOS: DarwinInitializationSettings(),
      ),
    );

    _androidNotifications = _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await _androidNotifications?.requestNotificationsPermission();

    _connectionSubscription = SocketService.instance.connectionStatusStream
        .listen(_handleConnectionChanged);
    _messageSubscription = SocketService.instance.messageStream.listen(
      _handleSocketMessage,
    );

    if (SocketService.instance.hasEstablishedConnection) {
      unawaited(_handleConnectionChanged(true));
    }
  }

  Future<void> _handleConnectionChanged(bool isConnected) async {
    if (isConnected) {
      await _showConnectionNotification();
      return;
    }

    _activeTransfers.clear();
    _progressNotificationTimer?.cancel();
    _progressNotificationTimer = null;
    await _localNotifications.cancel(id: _progressNotificationId);
    await _localNotifications.cancel(id: _foregroundServiceId);
  }

  Future<void> _showConnectionNotification() async {
    if (!Platform.isAndroid) {
      return;
    }

    try {
      await _localNotifications.show(
        id: _foregroundServiceId,
        title: _foregroundNotificationTitle,
        body: _foregroundNotificationText,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'tcp_connection_service',
            'TCP connection service',
            channelDescription:
                'Shows when Flashbyte has an active TCP connection.',
            category: AndroidNotificationCategory.service,
            icon: _notificationIcon,
            importance: Importance.low,
            priority: Priority.low,
            ongoing: true,
            autoCancel: false,
            onlyAlertOnce: true,
            playSound: false,
            enableVibration: false,
            showWhen: false,
          ),
        ),
      );
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'flashbyte notifications',
          context: ErrorDescription('show connection notification'),
        ),
      );
    }
  }

  void _handleSocketMessage(Map<String, dynamic> message) {
    final status = message['status'] ?? message['command'];

    switch (status) {
      case 'send_start':
        _startTransfer(message, direction: 'Sending');
        break;
      case 'start':
        _startTransfer(message, direction: 'Receiving');
        break;
      case 'send_progress':
      case 'progress':
        _updateTransfer(message);
        break;
      case 'send_complete':
      case 'completed':
      case 'transfer_cancelled':
      case 'error':
      case 'disconnect':
        _completeTransfer(message);
        break;
    }
  }

  void _startTransfer(
    Map<String, dynamic> message, {
    required String direction,
  }) {
    final fileId = message['fileId'] as String?;
    if (fileId == null) {
      return;
    }

    _activeTransfers[fileId] = _TransferProgress(
      direction: direction,
      fileName: message['fileName'] as String? ?? 'file',
      progress: 0,
    );
    _scheduleProgressNotificationUpdate(force: true);
  }

  void _updateTransfer(Map<String, dynamic> message) {
    final fileId = message['fileId'] as String?;
    final progress = (message['progress'] as num?)?.toDouble();
    if (fileId == null || progress == null) {
      return;
    }

    final transfer = _activeTransfers[fileId];
    if (transfer == null) {
      return;
    }

    final nextPercent = (progress.clamp(0.0, 1.0) * 100).floor();
    if (nextPercent == transfer.lastShownPercent) {
      return;
    }

    transfer
      ..progress = progress.clamp(0.0, 1.0)
      ..lastShownPercent = nextPercent;

    if (nextPercent >= 100) {
      return;
    }

    _scheduleProgressNotificationUpdate();
  }

  void _completeTransfer(Map<String, dynamic> message) {
    final fileId = message['fileId'] as String?;
    if (fileId == null) {
      _activeTransfers.clear();
    } else {
      _activeTransfers.remove(fileId);
    }

    if (_activeTransfers.isEmpty) {
      _progressNotificationTimer?.cancel();
      _progressNotificationTimer = null;
      unawaited(_localNotifications.cancel(id: _progressNotificationId));
      return;
    }

    _scheduleProgressNotificationUpdate(force: true);
  }

  void _scheduleProgressNotificationUpdate({bool force = false}) {
    if (_activeTransfers.isEmpty) {
      return;
    }

    final transfer = _activeTransfers.values.last;
    final percent = (transfer.progress.clamp(0.0, 1.0) * 100).floor();
    if (percent >= 100) {
      return;
    }

    if (force || _lastProgressNotificationUpdate == null) {
      _progressNotificationTimer?.cancel();
      _progressNotificationTimer = null;
      unawaited(_showProgressNotification());
      return;
    }

    final elapsed = DateTime.now().difference(_lastProgressNotificationUpdate!);
    if (elapsed >= _progressUpdateInterval) {
      _progressNotificationTimer?.cancel();
      _progressNotificationTimer = null;
      unawaited(_showProgressNotification());
      return;
    }

    _progressNotificationTimer ??= Timer(
      _progressUpdateInterval - elapsed,
      () {
        _progressNotificationTimer = null;
        unawaited(_showProgressNotification());
      },
    );
  }

  Future<void> _showProgressNotification() async {
    if (_activeTransfers.isEmpty) {
      return;
    }

    final transfer = _activeTransfers.values.last;
    final percent = (transfer.progress.clamp(0.0, 1.0) * 100).floor();
    if (percent >= 100) {
      return;
    }

    _lastProgressNotificationUpdate = DateTime.now();

    try {
      await _localNotifications.show(
        id: _progressNotificationId,
        title: '${transfer.direction} ${transfer.fileName}',
        body: '$percent% complete',
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _progressChannelId,
            _progressChannelName,
            channelDescription:
                'Shows active Flashbyte file transfer progress.',
            icon: _notificationIcon,
            importance: Importance.low,
            priority: Priority.low,
            onlyAlertOnce: true,
            showProgress: true,
            maxProgress: 100,
            progress: percent,
            ongoing: true,
            autoCancel: false,
            playSound: false,
            enableVibration: false,
          ),
        ),
      );
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'flashbyte notifications',
          context: ErrorDescription('show progress notification'),
        ),
      );
    }
  }

  Future<void> dispose() async {
    _progressNotificationTimer?.cancel();
    await _connectionSubscription?.cancel();
    await _messageSubscription?.cancel();
    await _localNotifications.cancel(id: _foregroundServiceId);
  }
}

class _TransferProgress {
  _TransferProgress({
    required this.direction,
    required this.fileName,
    required this.progress,
  });

  final String direction;
  final String fileName;
  double progress;
  int lastShownPercent = -1;
}
