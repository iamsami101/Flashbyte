import 'dart:async';
import 'dart:io';

import 'package:fast_file_picker/fast_file_picker.dart';
import 'package:flashbyte/services/transfer/socket_service.dart';
import 'package:flashbyte/models/user_facing_error.dart';
import 'package:flashbyte/features/transfers/widgets/transfer_widget.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

class TcpChatPage extends StatefulWidget {
  final List<FastFilePickerPath> initialFiles;

  const TcpChatPage({super.key, this.initialFiles = const []});

  @override
  State<TcpChatPage> createState() => _TcpChatPageState();
}

class _TcpChatPageState extends State<TcpChatPage> {
  static const double _wideLayoutBreakpoint = 1000;

  final ScrollController scrollController = ScrollController();
  final TextEditingController textFieldController = TextEditingController();

  ValueNotifier<bool> isDisconnected = ValueNotifier(false);

  final ValueNotifier<List<TransferWidget>> _fileTransferWidgets =
      ValueNotifier([]);
  final Map<String, ValueNotifier<double>> _transferProgress = {};
  final Map<String, TransferStatus> _pendingTransferStatuses = {};
  final Map<String, bool> _pendingTransferCanResume = {};
  final Map<String, String> _pendingTransferPausedBy = {};

  bool isSharingInProgress = false;
  bool _sentInitialFiles = false;
  bool _errorDialogVisible = false;
  bool _disconnectSignalSent = false;
  bool _leavingPage = false;
  bool _suppressNextConnectionIssueAfterCancellation = false;
  Map<String, dynamic>? _peerInfo;

  StreamSubscription? _streamSubscription;

  @override
  void initState() {
    super.initState();
    _peerInfo = SocketService.instance.connectedPeerInfo;

    _streamSubscription = SocketService.instance.messageStream.listen(
      (message) {
        final status = message['status'] ?? message['command'];

        switch (status) {
          case 'peer_info':
            if (!mounted) return;
            setState(() {
              _peerInfo = Map<String, dynamic>.from(message);
            });
            break;
          case 'disconnect':
            if (!mounted) return;
            _disconnectSignalSent = true;
            _handleDisconnectAfterCancellationWindow();
            break;
          case 'start':
            if (isSharingInProgress &&
                message['pendingAcceptance'] != true &&
                !_hasTransferWidget(message['fileId'] as String?)) {
              break;
            }

            setState(() {
              isSharingInProgress = true;
            });
            addFileWidget(
              filePath: message['filePath'],
              fileName: message['fileName'],
              fileSize: sizeConvert((message['fileSize'] as int).toDouble()),
              uuid: message['fileId'],
              isReceived: true,
              status: message['pendingAcceptance'] == true
                  ? TransferStatus.pending
                  : TransferStatus.inProgress,
            );
            break;
          case 'progress':
            _setTransferProgress(
              message['fileId'] as String?,
              (message['progress'] as num?)?.toDouble(),
            );
            _updateTransferStatus(
              message['fileId'] as String?,
              TransferStatus.inProgress,
            );
            break;
          case 'completed':
            replaceTransferWidget(
              uuid: message['fileId'] as String?,
              filePath: message['filePath'] as String?,
              fileName: message['fileName'] as String?,
            );
            _disposeTransferProgress(message['fileId'] as String?);

            setState(() {
              isSharingInProgress = false;
            });
            break;
          case 'send_start':
            if (isSharingInProgress == true &&
                message['pendingAcceptance'] != true &&
                !_hasTransferWidget(message['fileId'] as String?)) {
              break;
            }

            setState(() {
              isSharingInProgress = true;
            });

            addFileWidget(
              filePath: message['filePath'],
              uuid: message['fileId'],
              fileName: message['fileName'],
              fileSize: sizeConvert((message['fileSize'] as int).toDouble()),
              isReceived: false,
              status: message['pendingAcceptance'] == true
                  ? TransferStatus.pending
                  : TransferStatus.inProgress,
            );
            break;
          case 'send_progress':
            _setTransferProgress(
              message['fileId'] as String?,
              (message['progress'] as num?)?.toDouble(),
            );
            _updateTransferStatus(
              message['fileId'] as String?,
              TransferStatus.inProgress,
            );
            break;
          case 'send_complete':
            replaceTransferWidget(uuid: message['fileId'] as String?);
            _disposeTransferProgress(message['fileId'] as String?);

            setState(() {
              isSharingInProgress = false;
            });
            break;
          case 'transfer_paused':
            _updateTransferStatus(
              message['fileId'] as String?,
              TransferStatus.paused,
              pausedBy: message['pausedBy'] as String?,
              canResume: message['canResume'] as bool? ?? false,
            );
            break;
          case 'transfer_resumed':
            _updateTransferStatus(
              message['fileId'] as String?,
              TransferStatus.inProgress,
            );
            break;
          case 'transfer_accepted':
            _updateTransferStatus(
              message['fileId'] as String?,
              TransferStatus.inProgress,
            );
            break;
          case 'transfer_cancelled':
            if (message['cancelledBy'] == 'remote') {
              _suppressNextConnectionIssueAfterCancellation = true;
            }
            _updateTransferStatus(
              message['fileId'] as String?,
              TransferStatus.cancelled,
            );
            break;
          case 'transfer_cancel_ready':
            setState(() {
              isSharingInProgress = false;
            });
            if (_suppressNextConnectionIssueAfterCancellation) {
              Future<void>.delayed(const Duration(seconds: 2), () {
                _suppressNextConnectionIssueAfterCancellation = false;
              });
            }
            break;

          case 'error':
            final isFatal = message['fatal'] == 'true';
            final errorText = message['message'] as String? ?? 'Unknown error';
            if (isFatal) {
              _showErrorAfterCancellationWindow(errorText);
            } else {
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(errorText)),
              );
            }
            break;
        }
      },
    );
    SocketService.instance.replayTransferState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sendInitialFiles();
    });
  }

  @override
  void dispose() {
    _streamSubscription?.cancel();
    for (final notifier in _transferProgress.values) {
      notifier.dispose();
    }
    _transferProgress.clear();
    if (!_disconnectSignalSent) {
      _leavingPage = true;
      SocketService.instance.disconnect();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop && !_disconnectSignalSent) {
          _leavingPage = true;
          _disconnectSignalSent = true;
          SocketService.instance.disconnect();
        }
      },
      child: GestureDetector(
        onTap: () {
          FocusManager.instance.primaryFocus!.unfocus();
        },
        child: Scaffold(
          appBar: AppBar(title: const Text("Share")),
          body: SafeArea(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Expanded(
                        child: ConstrainedBox(
                          constraints: (Platform.isAndroid || Platform.isIOS)
                              ? BoxConstraints()
                              : BoxConstraints(maxWidth: 500),
                          child: ValueListenableBuilder(
                            valueListenable: _fileTransferWidgets,
                            builder: (context, widgets, child) => ListView(
                              reverse: true,
                              physics: const BouncingScrollPhysics(),
                              controller: scrollController,
                              padding: EdgeInsets.only(bottom: 15),
                              children: [
                                AnimatedSwitcher(
                                  duration: 240.ms,
                                  switchInCurve: Curves.easeOutCubic,
                                  switchOutCurve: Curves.easeInCubic,
                                  transitionBuilder: (child, animation) {
                                    final offsetAnimation = Tween<Offset>(
                                      begin: const Offset(0, 0.02),
                                      end: Offset.zero,
                                    ).animate(animation);
                                    return FadeTransition(
                                      opacity: animation,
                                      child: SlideTransition(
                                        position: offsetAnimation,
                                        child: child,
                                      ),
                                    );
                                  },
                                  child: widgets.isEmpty
                                      ? Padding(
                                          key: const ValueKey('empty_state'),
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 20,
                                            horizontal: 20,
                                          ),
                                          child: Card(
                                            child: Padding(
                                              padding: const EdgeInsets.all(20),
                                              child: Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                spacing: 10,
                                                children: [
                                                  Icon(
                                                    Icons.error_outline_rounded,
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .inverseSurface,
                                                  ),
                                                  Text("No files sent yet."),
                                                ],
                                              ),
                                            ),
                                          ),
                                        )
                                      : Column(
                                          key: const ValueKey('file_list'),
                                          children: widgets,
                                        ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const Divider(height: 0),
                      ConstrainedBox(
                        constraints: (Platform.isAndroid || Platform.isIOS)
                            ? BoxConstraints()
                            : BoxConstraints(maxWidth: 500),
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child:
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Expanded(
                                    child: ValueListenableBuilder(
                                      valueListenable: isDisconnected,
                                      builder: (context, value, child) =>
                                          _buildPickFileButton(
                                            isConnectionLost: value,
                                          ),
                                    ),
                                  ),
                                ],
                              ).animate().fadeIn(
                                delay: 80.ms,
                                duration: 220.ms,
                                curve: Curves.easeOutCubic,
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (MediaQuery.sizeOf(context).width >= _wideLayoutBreakpoint)
                  Container(
                    width: 1,
                    color: Theme.of(
                      context,
                    ).colorScheme.outlineVariant.withValues(alpha: 0.55),
                  ),
                if (MediaQuery.sizeOf(context).width >= _wideLayoutBreakpoint)
                  SizedBox(
                    width: 340,
                    child: _buildPeerDetailsPanel(),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPeerDetailsPanel() {
    final colorScheme = Theme.of(context).colorScheme;
    final peer = _peerInfo;
    final disconnected = isDisconnected.value;
    final disconnectedColor = colorScheme.onSurfaceVariant;
    final disconnectedContainer = colorScheme.surfaceContainerHighest;

    return ColoredBox(
      color: colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: AnimatedSwitcher(
          duration: 220.ms,
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          child: peer == null
              ? Column(
                  key: const ValueKey('peer-loading'),
                  mainAxisAlignment: MainAxisAlignment.center,
                  spacing: 14,
                  children: [
                    const CircularProgressIndicator(),
                    Text(
                      "Identifying connected device...",
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                )
              : Column(
                  key: ValueKey(peer['address']),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    CircleAvatar(
                      radius: 34,
                      backgroundColor: colorScheme.primaryContainer,
                      foregroundColor: colorScheme.onPrimaryContainer,
                      child: Icon(
                        peer['deviceType'] == 'laptop'
                            ? Icons.laptop_rounded
                            : Icons.smartphone_rounded,
                        size: 30,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      peer['name'] as String? ?? "Connected device",
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      spacing: 7,
                      children: [
                        Icon(
                          Icons.circle,
                          size: 9,
                          color: disconnected
                              ? disconnectedColor
                              : colorScheme.primary,
                        ),
                        Text(
                          disconnected ? "Disconnected" : "Connected",
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: disconnected
                                    ? disconnectedColor
                                    : colorScheme.primary,
                              ),
                        ),
                      ],
                    ),
                    if (disconnected) ...[
                      const SizedBox(height: 16),
                      Card(
                        margin: EdgeInsets.zero,
                        color: disconnectedContainer,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(color: colorScheme.outlineVariant),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            spacing: 10,
                            children: [
                              Icon(
                                Icons.link_off_rounded,
                                color: disconnectedColor,
                              ),
                              Expanded(
                                child: Text(
                                  "This session ended. Go back to reconnect before sending more files.",
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(
                                        color: disconnectedColor,
                                      ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 28),
                    _buildPeerDetailRow(
                      icon: Icons.lan_rounded,
                      label: "IP address",
                      value: peer['address'] as String? ?? "Unknown",
                    ),
                    const Divider(height: 28),
                    _buildPeerDetailRow(
                      icon: Icons.numbers_rounded,
                      label: "Port",
                      value: (peer['port'] as int?)?.toString() ?? "Unknown",
                    ),
                    const Divider(height: 28),
                    _buildPeerDetailRow(
                      icon: Icons.devices_rounded,
                      label: "Device",
                      value: peer['deviceType'] == 'laptop'
                          ? "Desktop or laptop"
                          : "Phone or tablet",
                    ),
                    const Divider(height: 28),
                    _buildPeerDetailRow(
                      icon: peer['tls'] == true
                          ? Icons.lock_rounded
                          : Icons.lock_open_rounded,
                      label: "Security",
                      value: peer['tls'] == true
                          ? "TLS enabled"
                          : "Unencrypted",
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildPeerDetailRow({
    required IconData icon,
    required String label,
    required String value,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return Row(
      spacing: 12,
      children: [
        Icon(icon, size: 20, color: colorScheme.onSurfaceVariant),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 2,
            children: [
              Text(
                label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPickFileButton({required bool isConnectionLost}) {
    final colorScheme = Theme.of(context).colorScheme;
    final disabledColor = colorScheme.onSurfaceVariant;
    final disabled = isConnectionLost || isSharingInProgress;
    final title = isConnectionLost
        ? "Connection lost"
        : isSharingInProgress
        ? "Transfer in progress"
        : "Pick File";
    final subtitle = isConnectionLost
        ? "Reconnect to send more files"
        : isSharingInProgress
        ? "Wait for this transfer to finish"
        : "Choose another file to send";
    final icon = isConnectionLost
        ? Icons.link_off_rounded
        : isSharingInProgress
        ? Icons.hourglass_top_rounded
        : Icons.file_present_rounded;

    return Card(
      margin: EdgeInsets.zero,
      color: isConnectionLost
          ? colorScheme.surfaceContainerHighest
          : colorScheme.surfaceContainerHighest,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isConnectionLost
              ? colorScheme.outlineVariant
              : Colors.transparent,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: disabled
            ? null
            : () async {
                final pickedFile = await FastFilePicker.pickFile();
                if (pickedFile == null) {
                  return;
                }
                _sendPickedFile(pickedFile);
              },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
          child: Row(
            spacing: 12,
            children: [
              AnimatedSwitcher(
                duration: 180.ms,
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: Icon(
                  icon,
                  key: ValueKey(icon),
                  color: isConnectionLost ? disabledColor : colorScheme.primary,
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: isConnectionLost
                            ? disabledColor
                            : colorScheme.onSurface,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: isConnectionLost
                            ? disabledColor
                            : colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void showScaffoldSnackbar(String message) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        showCloseIcon: true,
        dismissDirection: DismissDirection.horizontal,
      ),
    );
  }

  void _sendInitialFiles() {
    if (_sentInitialFiles || widget.initialFiles.isEmpty) {
      return;
    }

    _sentInitialFiles = true;
    for (final file in widget.initialFiles) {
      _sendPickedFile(file);
    }
  }

  void _sendPickedFile(FastFilePickerPath pickedFile) {
    final fileLocation = Platform.isAndroid && pickedFile.uri != null
        ? pickedFile.uri
        : pickedFile.path;

    if (fileLocation == null) {
      showScaffoldSnackbar("Could not read selected file");
      return;
    }

    SocketService.instance.sendFile(fileLocation);
  }

  void _showConnectionIssueDialog({required String message}) {
    if (_errorDialogVisible || !mounted) {
      return;
    }
    final error = UserFacingError.from(message);
    final colorScheme = Theme.of(context).colorScheme;

    setState(() {
      isSharingInProgress = false;
    });
    isDisconnected.value = true;
    _errorDialogVisible = true;

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: "Close Dialog",
      pageBuilder: (context, animation, secondaryAnimation) => AlertDialog(
        title: Row(
          spacing: 10,
          children: [
            Icon(
              Icons.error_rounded,
              color: colorScheme.onErrorContainer,
            ),
            const Text('Connection Lost'),
          ],
        ),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          spacing: 10,
          children: [
            Text(error.message),
            if (error.hasDetails)
              Card(
                margin: EdgeInsets.zero,
                color: colorScheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 200),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        error.details!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    ).then((_) {
      _errorDialogVisible = false;
    });
  }

  void _scrollToBottom() {
    if (scrollController.hasClients) {
      Future.delayed(500.ms).then(
        (value) {
          scrollController.animateTo(
            scrollController.position.minScrollExtent,
            duration: const Duration(milliseconds: 1000),
            curve: Curves.easeOutCirc,
          );
        },
      );
    }
  }

  void replaceTransferWidget({
    required String? uuid,
    String? filePath,
    String? fileName,
  }) {
    if (uuid == null) {
      return;
    }
    _fileTransferWidgets.value = [
      for (final widget in _fileTransferWidgets.value)
        widget.uuid == uuid
            ? TransferWidget(
                key: ValueKey(widget.uuid),
                filePath: filePath ?? widget.filePath,
                fileName: fileName ?? widget.fileName,
                fileSize: widget.fileSize,
                isReceived: widget.isReceived,
                uuid: widget.uuid,
                value: null,
                status: TransferStatus.completed,
                canResume: true,
              )
            : widget,
    ];
  }

  void _updateTransferStatus(
    String? uuid,
    TransferStatus status, {
    String? pausedBy,
    bool canResume = true,
  }) {
    if (uuid == null) {
      return;
    }

    final widgets = _fileTransferWidgets.value;
    var didUpdate = false;
    _fileTransferWidgets.value = [
      for (final widget in widgets)
        if (widget.uuid == uuid) ...[
          _copyTransferWidget(
            widget,
            status: status,
            canResume: pausedBy == null
                ? canResume
                : _transferRole(widget.isReceived) == pausedBy,
            value: status == TransferStatus.completed ? null : widget.value,
          ),
        ] else
          widget,
    ];
    didUpdate = widgets.any((widget) => widget.uuid == uuid);
    if (didUpdate) {
      _pendingTransferStatuses.remove(uuid);
      _pendingTransferCanResume.remove(uuid);
      _pendingTransferPausedBy.remove(uuid);
      return;
    }

    _pendingTransferStatuses[uuid] = status;
    _pendingTransferCanResume[uuid] = canResume;
    if (pausedBy == null) {
      _pendingTransferPausedBy.remove(uuid);
    } else {
      _pendingTransferPausedBy[uuid] = pausedBy;
    }
  }

  void addFileWidget({
    required String uuid,
    required String fileName,
    required String fileSize,
    required String filePath,
    required bool isReceived,
    TransferStatus status = TransferStatus.inProgress,
  }) {
    _scrollToBottom();
    if (_fileTransferWidgets.value.any((widget) => widget.uuid == uuid)) {
      _fileTransferWidgets.value = [
        for (final widget in _fileTransferWidgets.value)
          widget.uuid == uuid
              ? _copyTransferWidget(
                  widget,
                  status: status,
                  filePath: filePath.isEmpty ? widget.filePath : filePath,
                  fileName: fileName,
                  value: widget.value,
                )
              : widget,
      ];
      return;
    }
    final progress = ValueNotifier<double>(0);
    _transferProgress[uuid] = progress;
    final hadPendingStatus = _pendingTransferStatuses.containsKey(uuid);
    final pendingStatus =
        _pendingTransferStatuses.remove(uuid) ?? TransferStatus.inProgress;
    final pendingPausedBy = _pendingTransferPausedBy.remove(uuid);
    final pendingCanResumeFallback = _pendingTransferCanResume.remove(uuid);
    final pendingCanResume = pendingPausedBy == null
        ? pendingCanResumeFallback ?? true
        : _transferRole(isReceived) == pendingPausedBy;
    _fileTransferWidgets.value = [
      ..._fileTransferWidgets.value,
      TransferWidget(
        key: ValueKey(uuid),
        filePath: filePath,
        fileName: fileName,
        fileSize: fileSize,
        value: progress,
        isReceived: isReceived,
        uuid: uuid,
        status: hadPendingStatus ? pendingStatus : status,
        canResume: pendingCanResume,
        onPause: () =>
            SocketService.instance.pauseTransfer(uuid, isReceiver: isReceived),
        onResume: () =>
            SocketService.instance.resumeTransfer(uuid, isReceiver: isReceived),
        onCancel: () => _cancelTransfer(uuid, isReceived: isReceived),
        onAccept: () => SocketService.instance.acceptTransfer(uuid),
        onDecline: () => SocketService.instance.declineTransfer(uuid),
      ),
    ];
  }

  bool _hasTransferWidget(String? uuid) {
    if (uuid == null) {
      return false;
    }
    return _fileTransferWidgets.value.any((widget) => widget.uuid == uuid);
  }

  void _setTransferProgress(String? uuid, double? progress) {
    if (uuid == null || progress == null) {
      return;
    }
    _transferProgress[uuid]?.value = progress.clamp(0.0, 1.0);
  }

  void _disposeTransferProgress(String? uuid) {
    if (uuid == null) {
      return;
    }
    final notifier = _transferProgress.remove(uuid);
    Future<void>.delayed(const Duration(milliseconds: 500), notifier?.dispose);
  }

  TransferWidget _copyTransferWidget(
    TransferWidget widget, {
    required TransferStatus status,
    bool canResume = true,
    String? filePath,
    String? fileName,
    ValueListenable<double>? value,
  }) {
    return TransferWidget(
      key: ValueKey(widget.uuid),
      filePath: filePath ?? widget.filePath,
      fileName: fileName ?? widget.fileName,
      fileSize: widget.fileSize,
      isReceived: widget.isReceived,
      uuid: widget.uuid,
      value: value,
      status: status,
      canResume: canResume,
      onPause: () => SocketService.instance.pauseTransfer(
        widget.uuid,
        isReceiver: widget.isReceived,
      ),
      onResume: () => SocketService.instance.resumeTransfer(
        widget.uuid,
        isReceiver: widget.isReceived,
      ),
      onCancel: () =>
          _cancelTransfer(widget.uuid, isReceived: widget.isReceived),
      onAccept: () => SocketService.instance.acceptTransfer(widget.uuid),
      onDecline: () => SocketService.instance.declineTransfer(widget.uuid),
    );
  }

  String _transferRole(bool isReceived) {
    return isReceived ? 'receiver' : 'sender';
  }

  void _cancelTransfer(String fileId, {required bool isReceived}) {
    if (!isReceived) {
      _suppressNextConnectionIssueAfterCancellation = true;
    }
    SocketService.instance.cancelTransfer(fileId);
  }

  Future<void> _handleDisconnectAfterCancellationWindow() async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (!mounted || _suppressNextConnectionIssueAfterCancellation) {
      if (mounted) {
        isDisconnected.value = true;
      }
      return;
    }
    if (!_leavingPage && isSharingInProgress) {
      _showConnectionIssueDialog(
        message:
            'Connection lost. The other device disconnected during the transfer.',
      );
    } else if (!_leavingPage) {
      Navigator.pop(context);
      showScaffoldSnackbar("Disconnected");
    }
  }

  Future<void> _showErrorAfterCancellationWindow(String message) async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (!mounted ||
        _disconnectSignalSent ||
        _suppressNextConnectionIssueAfterCancellation) {
      return;
    }
    _showConnectionIssueDialog(message: message);
  }

  String sizeConvert(double bytes) {
    if (bytes.isNaN || bytes.isInfinite || bytes <= 0) return '0 B';

    const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    int unitIndex = 0;
    double size = bytes;

    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex++;
    }

    String formatted;
    if (unitIndex == 0) {
      formatted = '${size.toInt()} ${units[unitIndex]}';
    } else if (size < 10) {
      formatted = '${size.toStringAsFixed(2)} ${units[unitIndex]}';
    } else if (size < 100) {
      formatted = '${size.toStringAsFixed(1)} ${units[unitIndex]}';
    } else {
      formatted = '${size.toStringAsFixed(0)} ${units[unitIndex]}';
    }

    return formatted;
  }
}
