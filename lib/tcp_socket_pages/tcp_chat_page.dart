// ignore_for_file: unnecessary_null_comparison

import 'dart:async';
import 'dart:io';

import 'package:fast_file_picker/fast_file_picker.dart';
import 'package:file_sharing/classes/socket_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:motor/motor.dart';

class TcpChatPage extends StatefulWidget {
  const TcpChatPage({super.key});

  @override
  State<TcpChatPage> createState() => _TcpChatPageState();
}

class _TcpChatPageState extends State<TcpChatPage> {
  final ScrollController scrollController = ScrollController();
  final TextEditingController textFieldController = TextEditingController();

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

            setState(() {
              isSharingInProgress = true;
            });
            addFileWidget(
              fileName: message['fileName'],
              fileSize: sizeConvert((message['fileSize'] as int).toDouble()),
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
            if (mounted) {
              showGeneralDialog(
                context: context,
                barrierDismissible: true,
                pageBuilder: (context, animation, secondaryAnimation) =>
                    AlertDialog(
                      title: Text('Error'),
                      content: Text(message['message']),
                    ),
              );
            }
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
                  child: ValueListenableBuilder(
                    valueListenable: _fileTransferWidgets,
                    builder: (context, widgets, child) => ListView(
                      reverse: true,
                      physics: const BouncingScrollPhysics(),
                      controller: scrollController,
                      children: widgets.reversed.toList(),
                    ),
                  ),
                ),
                const Divider(height: 0),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Card.outlined(
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: isSharingInProgress == true
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
                    ],
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
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  void _scrollToBottom() {
    if (scrollController.hasClients) {
      scrollController.animateTo(
        scrollController.position.minScrollExtent,
        duration: const Duration(milliseconds: 1000),
        curve: Curves.easeOutCirc,
      );
    }
  }

  String _formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond < 1024) {
      return '${bytesPerSecond.toStringAsFixed(0)} B';
    } else if (bytesPerSecond < 1024 * 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB';
    } else {
      return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
  }

  void replaceLastWidget() {
    final lastWidget = _fileTransferWidgets.value.last;

    final List<TransferWidget> tempList = List.from(_fileTransferWidgets.value);
    tempList.removeLast();

    _fileTransferWidgets.value = [
      ...tempList,
      TransferWidget(
        fileName: lastWidget.fileName,
        fileSize: lastWidget.fileSize,
        isReceived: lastWidget.isReceived,
        value: null,
      ),
    ];
  }

  void addFileWidget({
    required String fileName,
    required String fileSize,
    required bool isReceived,
  }) {
    _scrollToBottom();
    _fileTransferWidgets.value = [
      ..._fileTransferWidgets.value,
      TransferWidget(
        fileName: fileName,
        fileSize: fileSize,
        value: _fileProgress,
        isReceived: isReceived,
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

class TransferWidget extends StatelessWidget {
  final String fileName;
  final String fileSize;

  final bool isReceived;

  final ValueListenable<double>? value;

  const TransferWidget({
    super.key,
    required this.fileName,
    required this.fileSize,
    this.isReceived = true,
    this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.symmetric(
        horizontal: 20,
        vertical: 5,
      ),
      child: Column(
        children: [
          ListTile(
            contentPadding: EdgeInsets.symmetric(
              vertical: 10,
              horizontal: 20,
            ),
            leading: SizedBox(
              height: double.infinity,
              child: FittedBox(child: Icon(Icons.file_copy)),
            ),
            title: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    physics: BouncingScrollPhysics(),
                    scrollDirection: Axis.horizontal,
                    child: Text(
                      fileName,
                      softWrap: false,
                      overflow: TextOverflow.fade,
                    ),
                  ),
                ),
                SizedBox(width: 10),
                Row(
                  spacing: 5,
                  children: [
                    Icon(
                      isReceived
                          ? Icons.arrow_downward_rounded
                          : Icons.arrow_upward_rounded,
                      fontWeight: FontWeight.w900,
                      size: 15,
                      color: Colors.white.withAlpha(100),
                    ),
                    Text(
                      isReceived ? "Received" : "Sent",
                      style: Theme.of(context).textTheme.labelSmall!.copyWith(
                        color: Colors.white.withAlpha(100),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            subtitle: value == null
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 10,
                    children: [
                      Text(
                        "$fileSize • ${fileName.split(".").last.toUpperCase()} • 100%",
                      ),
                      LinearProgressIndicator(
                        value: 1,
                        year2023: false,
                        stopIndicatorRadius: 1,
                        stopIndicatorColor: Theme.of(
                          context,
                        ).colorScheme.secondary,
                      ),
                    ],
                  )
                : ValueListenableBuilder(
                    valueListenable: value!,
                    builder: (context, pvalue, child) => SingleMotionBuilder(
                      value: pvalue,
                      motion: MaterialSpringMotion.expressiveEffectsDefault(),
                      builder: (context, value, child) => Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 10,
                        children: [
                          Text(
                            "$fileSize • ${fileName.split(".").last.toUpperCase()} • ${(value * 100).round()}%",
                          ),
                          LinearProgressIndicator(
                            value: value,
                            year2023: false,
                            stopIndicatorRadius: 1,
                            stopIndicatorColor: Theme.of(
                              context,
                            ).colorScheme.secondary,
                          ),
                        ],
                      ),
                    ),
                  ),
            dense: true,
          ),
        ],
      ),
    );
  }
}
