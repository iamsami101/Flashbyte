import 'dart:async';
import 'dart:io';

import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:fast_file_picker/fast_file_picker.dart';
import 'package:flashbyte/services/transfer/socket_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AndroidConnectionNotificationService {
  AndroidConnectionNotificationService._();

  static final AndroidConnectionNotificationService instance =
      AndroidConnectionNotificationService._();

  static const int _foregroundServiceId = 8050;
  static const int _progressNotificationId = 8051;
  static const int _offerNotificationId = 8052;

  static const String _connectionChannelKey = 'tcp_connection_service';
  static const String _progressChannelKey = 'file_transfer_progress';
  static const String _offerChannelKey = 'file_offers';
  static const Duration _progressUpdateInterval = Duration(milliseconds: 500);

  static const String _actionPause = 'progress_pause';
  static const String _actionResume = 'progress_resume';
  static const String _actionCancel = 'progress_cancel';
  static const String _actionSendFile = 'notif_send_file';
  static const String _actionSendClipboard = 'notif_send_clipboard';
  static const String _actionAcceptFile = 'offer_accept';
  static const String _actionDeclineFile = 'offer_decline';
  static const String _actionCancelOffer = 'offer_cancel';

  final Map<String, _TransferProgress> _activeTransfers = {};
  final Set<String> _pausedTransfers = {};
  final Set<String> _pendingOffers = {};

  StreamSubscription<bool>? _connectionSubscription;
  StreamSubscription<Map<String, dynamic>>? _messageSubscription;
  Timer? _progressNotificationTimer;
  DateTime? _lastProgressNotificationUpdate;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    if (!Platform.isAndroid) return;

    _connectionSubscription = SocketService.instance.connectionStatusStream
        .listen(_handleConnectionChanged);
    _messageSubscription = SocketService.instance.messageStream.listen(
      _handleSocketMessage,
    );

    if (SocketService.instance.hasEstablishedConnection) {
      unawaited(_handleConnectionChanged(true));
    }
  }

  void handleNotificationAction(ReceivedAction receivedAction) {
    final action = receivedAction.buttonKeyPressed;
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
      case _actionAcceptFile:
        _acceptPendingOffer();
        break;
      case _actionDeclineFile:
        _declinePendingOffer();
        break;
      case _actionCancelOffer:
        _cancelPendingOffer();
        break;
    }
  }

  String? _activeTransferFileId() {
    if (_activeTransfers.isNotEmpty) return _activeTransfers.keys.last;
    final activeTransfers = SocketService.instance.getActiveTransferIsReceived();
    return activeTransfers.keys.isEmpty ? null : activeTransfers.keys.last;
  }

  bool _activeTransferIsReceived(String fileId) {
    final transfer = _activeTransfers[fileId];
    if (transfer != null) return transfer.isReceived;
    final activeTransfers = SocketService.instance.getActiveTransferIsReceived();
    return activeTransfers[fileId] ?? true;
  }

  void _pauseActiveTransfer() {
    final fileId = _activeTransferFileId();
    if (fileId == null) return;
    SocketService.instance.pauseTransfer(
      fileId,
      isReceiver: _activeTransferIsReceived(fileId),
    );
  }

  void _resumeActiveTransfer() {
    final fileId = _activeTransferFileId();
    if (fileId == null) return;
    SocketService.instance.resumeTransfer(
      fileId,
      isReceiver: _activeTransferIsReceived(fileId),
    );
  }

  void _cancelActiveTransfer() {
    final fileId = _activeTransferFileId();
    if (fileId == null) return;
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
      SocketService.instance.sendClipboard(data.text!);
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
    _pendingOffers.clear();
    _progressNotificationTimer?.cancel();
    _progressNotificationTimer = null;
    unawaited(AwesomeNotifications().cancel(_progressNotificationId));
    unawaited(AwesomeNotifications().cancel(_offerNotificationId));
    unawaited(AwesomeNotifications().cancel(_foregroundServiceId));
  }

  Future<void> _showConnectionNotification() async {
    if (!Platform.isAndroid) return;

    final hasTransfers = _activeTransfers.isNotEmpty;
    final actions = hasTransfers
        ? <NotificationActionButton>[]
        : [
            NotificationActionButton(
              key: _actionSendFile,
              label: 'Send file',
              actionType: ActionType.Default,
            ),
            NotificationActionButton(
              key: _actionSendClipboard,
              label: 'Send clipboard',
              actionType: ActionType.SilentAction,
            ),
          ];

    try {
      await AwesomeNotifications().createNotification(
        content: NotificationContent(
          id: _foregroundServiceId,
          channelKey: _connectionChannelKey,
          title: 'Flashbyte',
          body: 'Connected to $_peerName',
          category: NotificationCategory.Service,
          locked: true,
          autoDismissible: false,
          showWhen: false,
          displayOnForeground: true,
          displayOnBackground: true,
          wakeUpScreen: false,
        ),
        actionButtons: actions.isEmpty ? null : actions,
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
        if (message['pendingAcceptance'] == true) {
          _startTransfer(message, isReceived: false);
          _showSenderPendingNotification(message);
        } else {
          _startTransfer(message, isReceived: false);
        }
        break;
      case 'start':
        if (message['pendingAcceptance'] == true) {
          _showReceiverOfferNotification(message);
        } else {
          _startTransfer(message, isReceived: true);
        }
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
      case 'transfer_accepted':
        _handleOfferResolved(message);
        break;
      case 'transfer_declined':
        _handleOfferResolved(message);
        break;
      case 'transfer_cancelled':
        _handleOfferResolved(message);
        _completeTransfer(message);
        break;
      case 'send_complete':
      case 'completed':
      case 'error':
      case 'disconnect':
        _completeTransfer(message);
        if (status == 'disconnect' || status == 'error') {
          unawaited(AwesomeNotifications().cancel(_foregroundServiceId));
        }
        break;
      case 'outgoing_offer_cancelled':
      case 'offer_cancelled_by_sender':
        _handleOfferCancelledBySender();
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
      unawaited(AwesomeNotifications().cancel(_progressNotificationId));
      return;
    }

    _scheduleProgressNotificationUpdate(force: true);
  }

  void _showSenderPendingNotification(Map<String, dynamic> message) {
    final fileId = message['fileId'] as String?;
    final fileName = message['fileName'] as String? ?? 'file';
    if (fileId == null) return;

    _pendingOffers.add(fileId);

    unawaited(AwesomeNotifications().createNotification(
      content: NotificationContent(
        id: _offerNotificationId,
        channelKey: _offerChannelKey,
        title: 'Waiting for receiver to accept',
        body: fileName,
        locked: true,
        autoDismissible: false,
        showWhen: false,
        displayOnForeground: true,
        displayOnBackground: true,
      ),
      actionButtons: [
        NotificationActionButton(
          key: _actionCancelOffer,
          label: 'Cancel',
          actionType: ActionType.SilentAction,
        ),
      ],
    ));
  }

  void _showReceiverOfferNotification(Map<String, dynamic> message) {
    final fileId = message['fileId'] as String?;
    final fileName = message['fileName'] as String? ?? 'file';
    if (fileId == null) return;

    _pendingOffers.add(fileId);

    unawaited(AwesomeNotifications().createNotification(
      content: NotificationContent(
        id: _offerNotificationId,
        channelKey: _offerChannelKey,
        title: 'Incoming file',
        body: fileName,
        locked: true,
        autoDismissible: false,
        showWhen: false,
        displayOnForeground: true,
        displayOnBackground: true,
      ),
      actionButtons: [
        NotificationActionButton(
          key: _actionAcceptFile,
          label: 'Accept',
          actionType: ActionType.SilentAction,
        ),
        NotificationActionButton(
          key: _actionDeclineFile,
          label: 'Decline',
          actionType: ActionType.SilentAction,
        ),
      ],
    ));
  }

  void _handleOfferResolved(Map<String, dynamic> message) {
    final fileId = message['fileId'] as String?;
    if (fileId != null) {
      _pendingOffers.remove(fileId);
    }
    if (_pendingOffers.isEmpty) {
      unawaited(AwesomeNotifications().cancel(_offerNotificationId));
    }
  }

  void _handleOfferCancelledBySender() {
    _pendingOffers.clear();
    unawaited(AwesomeNotifications().cancel(_offerNotificationId));
  }

  void _acceptPendingOffer() {
    if (_pendingOffers.isEmpty) return;
    final fileId = _pendingOffers.last;
    SocketService.instance.acceptTransfer(fileId);
  }

  void _declinePendingOffer() {
    if (_pendingOffers.isEmpty) return;
    final fileId = _pendingOffers.last;
    SocketService.instance.declineTransfer(fileId);
  }

  void _cancelPendingOffer() {
    if (_pendingOffers.isEmpty) return;
    SocketService.instance.cancelOutgoingOffer();
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
        NotificationActionButton(
          key: _actionResume,
          label: 'Resume',
          actionType: ActionType.SilentAction,
        )
      else
        NotificationActionButton(
          key: _actionPause,
          label: 'Pause',
          actionType: ActionType.SilentAction,
        ),
      NotificationActionButton(
        key: _actionCancel,
        label: 'Cancel',
        actionType: ActionType.SilentAction,
      ),
    ];

    try {
      await AwesomeNotifications().createNotification(
        content: NotificationContent(
          id: _progressNotificationId,
          channelKey: _progressChannelKey,
          title: '${transfer.direction} ${transfer.fileName}',
          body: '$percent% complete',
          notificationLayout: NotificationLayout.ProgressBar,
          locked: true,
          progress: transfer.progress.clamp(0.0, 1.0),
          autoDismissible: false,
          showWhen: false,
          displayOnForeground: true,
          displayOnBackground: true,
          category: NotificationCategory.Progress,
        ),
        actionButtons: actions,
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
    await AwesomeNotifications().cancel(_foregroundServiceId);
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
