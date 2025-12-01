import 'dart:async';
import 'dart:io';

import 'package:fast_file_picker/fast_file_picker.dart';
import 'package:flashbyte/classes/socket_service.dart';
import 'package:flashbyte/widgets/transfer_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

class TcpChatPage extends StatefulWidget {
  const TcpChatPage({super.key});

  @override
  State<TcpChatPage> createState() => _TcpChatPageState();
}

class _TcpChatPageState extends State<TcpChatPage> {
  final ScrollController scrollController = ScrollController();
  final TextEditingController textFieldController = TextEditingController();

  ValueNotifier<bool> isDisconnected = ValueNotifier(false);

  final ValueNotifier<List<TransferWidget>> _fileTransferWidgets =
      ValueNotifier([]);
  final ValueNotifier<double> _fileProgress = ValueNotifier(0);

  bool isSharingInProgress = false;

  StreamSubscription? _streamSubscription;

  @override
  void initState() {
    super.initState();

    _streamSubscription = SocketService.instance.messageStream.listen(
      (message) {
        final status = message['status'] ?? message['command'];

        print(status);

        switch (status) {
          case 'disconnect':
            if (!mounted) return;
            Navigator.pop(context);
            showScaffoldSnackbar("Disconnected");
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
            replaceLastWidget();
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
            isDisconnected.value = true;
            showGeneralDialog(
              context: context,
              barrierDismissible: true,
              barrierLabel: "Close Dialog",
              pageBuilder:
                  (
                    context,
                    animation,
                    secondaryAnimation,
                  ) => AlertDialog(
                    title: Row(
                      spacing: 10,
                      children: [
                        Icon(
                          Icons.error_rounded,
                          color: Theme.of(
                            context,
                          ).colorScheme.onErrorContainer,
                        ),
                        Text('Error'),
                      ],
                    ),
                    content: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      spacing: 10,
                      children: [
                        Text(
                          "Connection may have been disrupted\n\nError log:",
                        ),
                        Card(
                          margin: EdgeInsets.all(0),
                          child: Padding(
                            padding: const EdgeInsets.all(
                              10,
                            ),
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxHeight: 200,
                              ),
                              child: SingleChildScrollView(
                                child: Text(
                                  message['message'],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
            );
            break;
        }
      },
    );
  }

  @override
  void dispose() {
    _streamSubscription?.cancel();
    SocketService.instance.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
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
                        children: widgets.isEmpty
                            ? [
                                Padding(
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
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.inverseSurface,
                                          ),
                                          Text("No files sent yet."),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ]
                            : widgets.reversed.toList(),
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
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Card.outlined(
                            child: ValueListenableBuilder(
                              valueListenable: isDisconnected,
                              builder: (context, value, child) => InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: value == true
                                    ? null
                                    : isSharingInProgress == true
                                    ? null
                                    : () async {
                                        final pickedFile =
                                            await FastFilePicker.pickFile();
                                        print(pickedFile?.path ?? "null");
                                        if (pickedFile == null) {
                                          return;
                                        }
                                        if (Platform.isAndroid &&
                                            pickedFile.uri != null) {
                                          SocketService.instance.sendFile(
                                            pickedFile.uri!,
                                          );
                                        } else {
                                          SocketService.instance.sendFile(
                                            pickedFile.path!,
                                          );
                                        }
                                      },
                                child: Padding(
                                  padding: EdgeInsets.all(17),
                                  child: IntrinsicHeight(
                                    child: Row(
                                      spacing: 10,
                                      children: [
                                        Icon(Icons.file_present_rounded),
                                        Text("Pick File"),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
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

  void replaceLastWidget() {
    final lastWidget = _fileTransferWidgets.value.last;

    final List<TransferWidget> tempList = List.from(_fileTransferWidgets.value);
    tempList.removeLast();

    _fileTransferWidgets.value = [
      ...tempList,
      TransferWidget(
        filePath: lastWidget.filePath,
        fileName: lastWidget.fileName,
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
