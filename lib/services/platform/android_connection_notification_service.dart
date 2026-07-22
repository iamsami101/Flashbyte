import 'dart:async';
import 'dart:io';

import 'package:fast_file_picker/fast_file_picker.dart';
import 'package:flashbyte/services/transfer/socket_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class AndroidConnectionNotificationService {
  AndroidConnectionNotificationService._();

  static final AndroidConnectionNotificationService instance =
      AndroidConnectionNotificationService._();

  static const int _foregroundServiceId = 8050;
  static const int _progressNotificationId = 8051;
  static const String _connectionChannelId = 'tcp_connection_service';
  static const String _connectionChannelName = 'TCP connection service';
  static const String _progressChannelId = 'file_transfer_progress';
  static const String _progressChannelName = 'File transfer progress';
  static const Duration _progressUpdateInterval = Duration(milliseconds: 500);
  static const String _notificationIcon = 'ic_notification';

  static const String _actionPause = 'progress_pause';
  static const String _actionResume = 'progress_resume';
  static const String _actionCancel = 'progress_cancel';
  static const String _actionSendFile = 'notif_send_file';
  static const String _actionSendClipboard = 'notif_send_clipboard';

  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  final Map<String, _TransferProgress> _activeTransfers = {};
  final Set<String> _pausedTransfers = {};
  AndroidFlutterLocalNotificationsPlugin? _androidNotifications;

  StreamSubscription<bool>? _connectionSubscription;
  StreamSubscription<Map<String, dynamic>>? _messageSubscription;
  Timer? _progressNotificationTimer;
  DateTime? _lastProgressNotificationUpdate;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    if (!Platform.isAndroid) return;

    await _localNotifications.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings(_notificationIcon),
        iOS: DarwinInitializationSettings(),
        macOS: DarwinInitializationSettings(),
      ),
      onDidReceiveNotificationResponse: _handleNotificationAction,
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

  void _handleNotificationAction(NotificationResponse response) {
    final action = response.actionId;
    if (action == null) return;

    switch (action) {
      case _actionPause:
        _pauseActiveTransfer();
        break;
      case _actionResume:
        _resumeActiveTransfer();
        break;
      case _actionCancel:
        _cancelActiveTransfer();
        break;
      case _actionSendFile:
        unawaited(_pickAndSendFile());
        break;
      case _actionSendClipboard:
        unawaited(_sendClipboard());
        break;
    }
  }

  void _pauseActiveTransfer() {
    if (_activeTransfers.isEmpty) return;
    final fileId = _activeTransfers.keys.last;
    final transfer = _activeTransfers[fileId]!;
    SocketService.instance.pauseTransfer(fileId, isReceiver: transfer.isReceived);
  }

  void _resumeActiveTransfer() {
    if (_activeTransfers.isEmpty) return;
    final fileId = _activeTransfers.keys.last;
    final transfer = _activeTransfers[fileId]!;
    SocketService.instance.resumeTransfer(
      fileId,
      isReceiver: transfer.isReceived,
    );
  }

  void _cancelActiveTransfer() {
    if (_activeTransfers.isEmpty) return;
    final fileId = _activeTransfers.keys.last;
    SocketService.instance.cancelTransfer(fileId);
  }

  Future<void> _pickAndSendFile() async {
    try {
      final pickedFile = await FastFilePicker.pickFile();
      if (pickedFile == null) return;
      final fileLocation = Platform.isAndroid && pickedFile.uri != null
          ? pickedFile.uri
          : pickedFile.path;
      if (fileLocation == null) return;
      SocketService.instance.sendFile(fileLocation);
    } catch (_) {}
  }

  Future<void> _sendClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (data?.text == null || data!.text!.isEmpty) return;
      final tempDir = Directory.systemTemp;
      final file = File('${tempDir.path}/clipboard.txt');
      await file.writeAsString(data.text!);
      SocketService.instance.sendFile(file.path);
    } catch (_) {}
  }

  String get _peerName {
    final info = SocketService.instance.connectedPeerInfo;
    if (info == null) return 'Unknown';
    final name = info['name'];
    return name is String ? name : 'Unknown';
  }

  Future<void> _handleConnectionChanged(bool isConnected) async {
    if (isConnected) {
      await _showConnectionNotification();
      return;
    }

    _activeTransfers.clear();
    _pausedTransfers.clear();
    _progressNotificationTimer?.cancel();
    _progressNotificationTimer = null;
    await _localNotifications.cancel(id: _progressNotificationId);
    await _localNotifications.cancel(id: _foregroundServiceId);
  }

  Future<void> _showConnectionNotification() async {
    if (!Platform.isAndroid) return;

    final hasTransfers = _activeTransfers.isNotEmpty;
    final actions = hasTransfers
        ? <AndroidNotificationAction>[]
        : [
            AndroidNotificationAction(
              _actionSendFile,
              'Send file',
              showsUserInterface: true,
              cancelNotification: false,
            ),
            AndroidNotificationAction(
              _actionSendClipboard,
              'Send clipboard',
              showsUserInterface: true,
              cancelNotification: false,
            ),
          ];

    try {
      await _localNotifications.show(
        id: _foregroundServiceId,
        title: 'Flashbyte',
        body: 'Connected to $_peerName',
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _connectionChannelId,
            _connectionChannelName,
            channelDescription:
                'Shows when Flashbyte has an active TCP connection.',
            category: AndroidNotificationCategory.service,
            icon: _notificationIcon,
            importance: Importance.min,
            priority: Priority.min,
            ongoing: true,
            autoCancel: false,
            onlyAlertOnce: true,
            playSound: false,
            enableVibration: false,
            showWhen: false,
            actions: actions,
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
      case 'peer_info':
        unawaited(_showConnectionNotification());
        break;
      case 'send_start':
        _startTransfer(message, isReceived: false);
        break;
      case 'start':
        _startTransfer(message, isReceived: true);
        break;
      case 'send_progress':
      case 'progress':
        _updateTransfer(message);
        break;
      case 'transfer_paused':
        _markTransferPaused(message);
        break;
      case 'transfer_resumed':
        _markTransferResumed(message);
        break;
      case 'send_complete':
      case 'completed':
      case 'transfer_cancelled':
      case 'error':
      case 'disconnect':
        _completeTransfer(message);
        if (status == 'disconnect' || status == 'error') {
          unawaited(_localNotifications.cancel(id: _foregroundServiceId));
        }
        break;
    }
  }

  void _startTransfer(
    Map<String, dynamic> message, {
    required bool isReceived,
  }) {
    final fileId = message['fileId'] as String?;
    if (fileId == null) return;

    _activeTransfers[fileId] = _TransferProgress(
      fileId: fileId,
      isReceived: isReceived,
      direction: isReceived ? 'Receiving' : 'Sending',
      fileName: message['fileName'] as String? ?? 'file',
      progress: 0,
    );

    unawaited(_showConnectionNotification());
    _scheduleProgressNotificationUpdate(force: true);
  }

  void _updateTransfer(Map<String, dynamic> message) {
    final fileId = message['fileId'] as String?;
    final progress = (message['progress'] as num?)?.toDouble();
    if (fileId == null || progress == null) return;

    final transfer = _activeTransfers[fileId];
    if (transfer == null) return;

    final nextPercent = (progress.clamp(0.0, 1.0) * 100).floor();
    if (nextPercent == transfer.lastShownPercent) return;

    transfer
      ..progress = progress.clamp(0.0, 1.0)
      ..lastShownPercent = nextPercent;

    if (nextPercent >= 100) return;

    _scheduleProgressNotificationUpdate();
  }

  void _markTransferPaused(Map<String, dynamic> message) {
    final fileId = message['fileId'] as String?;
    if (fileId == null) return;
    _pausedTransfers.add(fileId);
    _scheduleProgressNotificationUpdate(force: true);
  }

  void _markTransferResumed(Map<String, dynamic> message) {
    final fileId = message['fileId'] as String?;
    if (fileId == null) return;
    _pausedTransfers.remove(fileId);
    _scheduleProgressNotificationUpdate(force: true);
  }

  void _completeTransfer(Map<String, dynamic> message) {
    final fileId = message['fileId'] as String?;
    if (fileId == null) {
      _activeTransfers.clear();
      _pausedTransfers.clear();
    } else {
      _activeTransfers.remove(fileId);
      _pausedTransfers.remove(fileId);
    }

    unawaited(_showConnectionNotification());

    if (_activeTransfers.isEmpty) {
      _progressNotificationTimer?.cancel();
      _progressNotificationTimer = null;
      unawaited(_localNotifications.cancel(id: _progressNotificationId));
      return;
    }

    _scheduleProgressNotificationUpdate(force: true);
  }

  void _scheduleProgressNotificationUpdate({bool force = false}) {
    if (_activeTransfers.isEmpty) return;

    final transfer = _activeTransfers.values.last;
    final percent = (transfer.progress.clamp(0.0, 1.0) * 100).floor();
    if (percent >= 100) return;

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
    if (_activeTransfers.isEmpty) return;

    final transfer = _activeTransfers.values.last;
    final percent = (transfer.progress.clamp(0.0, 1.0) * 100).floor();
    if (percent >= 100) return;

    _lastProgressNotificationUpdate = DateTime.now();

    final isPaused = _pausedTransfers.contains(transfer.fileId);
    final actions = [
      if (isPaused)
        AndroidNotificationAction(
          _actionResume,
          'Resume',
          showsUserInterface: false,
          cancelNotification: false,
        )
      else
        AndroidNotificationAction(
          _actionPause,
          'Pause',
          showsUserInterface: false,
          cancelNotification: false,
        ),
      AndroidNotificationAction(
        _actionCancel,
        'Cancel',
        showsUserInterface: false,
        cancelNotification: false,
      ),
    ];

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
            importance: Importance.high,
            priority: Priority.high,
            onlyAlertOnce: true,
            showProgress: true,
            maxProgress: 100,
            progress: percent,
            ongoing: true,
            autoCancel: false,
            playSound: false,
            enableVibration: false,
            actions: actions,
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
    required this.fileId,
    required this.isReceived,
    required this.direction,
    required this.fileName,
    required this.progress,
  });

  final String fileId;
  final bool isReceived;
  final String direction;
  final String fileName;
  double progress;
  int lastShownPercent = -1;
}
