import 'dart:async';
import 'dart:io';

import 'package:fast_file_picker/fast_file_picker.dart';
import 'package:flashbyte/classes/socket_service.dart';
import 'package:flashbyte/widgets/transfer_widget.dart';
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
  final ValueNotifier<double> _fileProgress = ValueNotifier(0);

  bool isSharingInProgress = false;
  bool _sentInitialFiles = false;
  bool _errorDialogVisible = false;
  bool _disconnectSignalSent = false;
  bool _leavingPage = false;
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
            if (!_leavingPage && isSharingInProgress) {
              _showConnectionIssueDialog(
                message:
                    'Connection lost. The other device disconnected during the transfer.',
              );
            } else if (!_leavingPage) {
              Navigator.pop(context);
              showScaffoldSnackbar("Disconnected");
            }
            break;
          case 'start':
            if (isSharingInProgress) break;

            print("FILE UID = ${message['fileId']}");

            setState(() {
              isSharingInProgress = true;
            });
            addFileWidget(
              filePath: message['filePath'],
              fileName: message['fileName'],
              fileSize: sizeConvert((message['fileSize'] as int).toDouble()),
              uuid: message['fileId'],
              isReceived: true,
            );
            break;
          case 'progress':
            _fileProgress.value = message['progress'];
            break;
          case 'completed':
            replaceLastWidget(
              filePath: message['filePath'] as String?,
              fileName: message['fileName'] as String?,
            );
            _fileProgress.value = 0;

            setState(() {
              isSharingInProgress = false;
            });
            break;
          case 'send_start':
            if (isSharingInProgress == true) break;

            setState(() {
              isSharingInProgress = true;
            });

            addFileWidget(
              filePath: message['filePath'],
              uuid: message['fileId'],
              fileName: message['fileName'],
              fileSize: sizeConvert((message['fileSize'] as int).toDouble()),
              isReceived: false,
            );
            break;
          case 'send_progress':
            _fileProgress.value = message['progress'];
            break;
          case 'send_complete':
            replaceLastWidget();
            _fileProgress.value = 0;

            setState(() {
              isSharingInProgress = false;
            });
            break;

          case 'error':
            if (_disconnectSignalSent || !mounted) {
              break;
            }
            _showConnectionIssueDialog(
              message: message['message'] as String? ?? 'Unknown error',
            );
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
                              ? colorScheme.error
                              : colorScheme.primary,
                        ),
                        Text(
                          disconnected ? "Disconnected" : "Connected",
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: disconnected
                                    ? colorScheme.error
                                    : colorScheme.primary,
                              ),
                        ),
                      ],
                    ),
                    if (disconnected) ...[
                      const SizedBox(height: 16),
                      Card(
                        margin: EdgeInsets.zero,
                        color: colorScheme.errorContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            spacing: 10,
                            children: [
                              Icon(
                                Icons.link_off_rounded,
                                color: colorScheme.onErrorContainer,
                              ),
                              Expanded(
                                child: Text(
                                  "This session ended. Go back to reconnect before sending more files.",
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(
                                        color: colorScheme.onErrorContainer,
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
          ? colorScheme.errorContainer
          : colorScheme.surfaceContainerHighest,
      elevation: isConnectionLost ? 2 : 0,
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
                  color: isConnectionLost
                      ? colorScheme.onErrorContainer
                      : colorScheme.primary,
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
                            ? colorScheme.onErrorContainer
                            : colorScheme.onSurface,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: isConnectionLost
                            ? colorScheme.onErrorContainer.withValues(
                                alpha: 0.78,
                              )
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
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
            const Text('Connection Lost'),
          ],
        ),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          spacing: 10,
          children: [
            const Text("Connection may have been disrupted\n\nError log:"),
            Card(
              margin: EdgeInsets.zero,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: SingleChildScrollView(
                    child: SelectableText(message),
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

  void replaceLastWidget({
    String? filePath,
    String? fileName,
  }) {
    final lastWidget = _fileTransferWidgets.value.last;

    final List<TransferWidget> tempList = List.from(_fileTransferWidgets.value);
    tempList.removeLast();

    _fileTransferWidgets.value = [
      ...tempList,
      TransferWidget(
        filePath: filePath ?? lastWidget.filePath,
        fileName: fileName ?? lastWidget.fileName,
        fileSize: lastWidget.fileSize,
        isReceived: lastWidget.isReceived,
        uuid: lastWidget.uuid,
        value: null,
      ),
    ];
  }

  void addFileWidget({
    required String uuid,
    required String fileName,
    required String fileSize,
    required String filePath,
    required bool isReceived,
  }) {
    _scrollToBottom();
    _fileTransferWidgets.value = [
      ..._fileTransferWidgets.value,
      TransferWidget(
        filePath: filePath,
        fileName: fileName,
        fileSize: fileSize,
        value: _fileProgress,
        isReceived: isReceived,
        uuid: uuid,
      ),
    ];
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
