import 'dart:async';
import 'dart:io';

import 'package:flashbyte/services/platform/android_saf_service.dart';
import 'package:flashbyte/app/app_settings.dart';
import 'package:flashbyte/services/transfer/socket_service.dart';
import 'package:flutter/material.dart';
import 'package:loading_indicator_m3e/loading_indicator_m3e.dart';
import 'package:mime/mime.dart';
import 'package:open_file/open_file.dart';
import 'package:process_run/process_run.dart';
import 'package:widget_zoom/widget_zoom.dart';

class FilePreviewWidget extends StatefulWidget {
  final String fileName;
  final String fileSize;
  final String uuid;

  final String filePath;
  final double initialTransferProgress;
  final bool isTransferComplete;
  final bool isTransferCancelled;

  const FilePreviewWidget({
    super.key,
    required this.fileName,
    required this.fileSize,
    required this.filePath,
    required this.uuid,
    this.initialTransferProgress = 1,
    this.isTransferComplete = true,
    this.isTransferCancelled = false,
  });

  @override
  State<FilePreviewWidget> createState() => _FilePreviewWidgetState();
}

class _FilePreviewWidgetState extends State<FilePreviewWidget> {
  late final String mimeType;

  File? previewFile;

  bool isLoading = false;
  bool _isOpeningFile = false;
  late double _transferProgress;
  late bool _transferComplete;
  late bool _transferCancelled;
  StreamSubscription? _transferSubscription;

  @override
  void initState() {
    super.initState();
    _transferProgress = widget.initialTransferProgress.clamp(0.0, 1.0);
    _transferComplete = widget.isTransferComplete;
    _transferCancelled = widget.isTransferCancelled;
    _listenForTransferUpdates();

    mimeType =
        lookupMimeType(widget.fileName) ??
        lookupMimeType(widget.filePath) ??
        "";

    if (!mimeType.startsWith("image") ||
        (Platform.isAndroid && widget.filePath.contains("://"))) {
      return;
    }
    _loadFile();
  }

  @override
  void dispose() {
    _transferSubscription?.cancel();
    super.dispose();
  }

  void _listenForTransferUpdates() {
    _transferSubscription = SocketService.instance.messageStream.listen((
      message,
    ) {
      if (message['fileId'] != widget.uuid || !mounted) {
        return;
      }

      final status = message['status'] ?? message['command'];
      switch (status) {
        case 'progress':
        case 'send_progress':
          final progress = (message['progress'] as num?)?.toDouble();
          if (progress == null) return;
          setState(() {
            _transferProgress = progress.clamp(0.0, 1.0);
          });
          break;
        case 'completed':
        case 'send_complete':
          setState(() {
            _transferProgress = 1;
            _transferComplete = true;
          });
          break;
        case 'transfer_cancelled':
          setState(() {
            _transferCancelled = true;
          });
          break;
      }
    });
  }

  Future<void> _openFileWithLoading() async {
    if (_isOpeningFile) {
      return;
    }

    setState(() => _isOpeningFile = true);
    try {
      await openFile(widget.filePath);
    } finally {
      if (mounted) {
        setState(() => _isOpeningFile = false);
      }
    }
  }

  Future<void> _loadFile() async {
    setState(() => isLoading = true);

    final file = File(widget.filePath);

    if (!file.existsSync()) {
      if (mounted) {
        setState(() => isLoading = false);
      }
      return;
    }

    if (!mounted) return;

    setState(() {
      previewFile = file;
      isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);

    return Card(
      margin: EdgeInsets.symmetric(horizontal: 20),
      child: SingleChildScrollView(
        child: SizedBox(
          height: 550,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                contentPadding: EdgeInsets.symmetric(
                  vertical: 10,
                  horizontal: 20,
                ),
                leading: SizedBox(
                  height: double.infinity,
                  child: FittedBox(
                    child: Icon(Icons.file_copy),
                  ),
                ),
                title: SingleChildScrollView(
                  physics: BouncingScrollPhysics(),
                  scrollDirection: Axis.horizontal,
                  child: Text(
                    widget.fileName,
                    softWrap: false,
                    overflow: TextOverflow.fade,
                  ),
                ),
                subtitle: Text(
                  "${widget.fileSize} • ${widget.fileName.split(".").last.toUpperCase()}",
                ),
                dense: true,
              ),
              Expanded(
                child: SizedBox(
                  width: double.infinity,
                  child:
                      mimeType.startsWith("image") &&
                          (isLoading || previewFile != null)
                      ? isLoading
                            ? Center(
                                child: LoadingIndicatorM3E(
                                  variant: LoadingIndicatorM3EVariant.contained,
                                ),
                              )
                            : Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadiusGeometry.circular(
                                    10,
                                  ),
                                  child: FittedBox(
                                    fit: BoxFit.fitWidth,
                                    child: WidgetZoom(
                                      heroAnimationTag: widget.uuid,
                                      zoomWidget: Image.file(previewFile!),
                                    ),
                                  ),
                                ),
                              )
                      : Card.outlined(
                          margin: EdgeInsets.symmetric(horizontal: 22),
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              spacing: 20,
                              children: [
                                Icon(
                                  Icons.file_copy,
                                  size: 50,
                                ),
                                SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: Text(widget.fileName),
                                ),
                              ],
                            ),
                          ),
                        ),
                ),
              ),
              SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: Card.filled(
                  margin: const EdgeInsets.symmetric(horizontal: 20),
                  color: Theme.of(
                    context,
                  ).colorScheme.onInverseSurface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadiusGeometry.vertical(
                      top: Radius.circular(15),
                      bottom: Radius.circular(5),
                    ),
                  ),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        spacing: 10,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children:
                            {
                              Icons.create_rounded: Text(widget.fileName),
                              Icons.open_in_full_rounded: Text(
                                widget.fileSize,
                              ),
                              Icons.location_pin: Text(
                                AndroidSafService.trimPathForDisplay(
                                  widget.filePath,
                                ),
                              ),
                            }.entries.map(
                              (e) {
                                return Row(
                                  spacing: 10,
                                  children: [
                                    Icon(
                                      e.key,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSecondaryContainer,
                                    ),
                                    e.value,
                                  ],
                                );
                              },
                            ).toList(),
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(height: 5),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: AnimatedSwitcher(
                  duration: reducedMotion
                      ? Duration.zero
                      : const Duration(milliseconds: 220),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  child: _transferComplete
                      ? _OpenFileButton(
                          key: const ValueKey('open-file-button'),
                          isOpeningFile: _isOpeningFile,
                          onPressed: _openFileWithLoading,
                        )
                      : _TransferProgressFooter(
                          key: const ValueKey('transfer-progress-footer'),
                          progress: _transferProgress,
                          isCancelled: _transferCancelled,
                        ),
                ),
              ),
              SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> openFolder(String filePath) async {
    List<String> pathList = filePath.split("/");
    pathList.removeLast();

    final folderPath = "${pathList.join("/")}/";

    if (!Platform.isAndroid &&
        !Platform.isIOS &&
        !Directory(folderPath).existsSync()) {
      return;
    }

    if (Platform.isWindows) {
      await run('explorer "$folderPath"', runInShell: true);
    } else if (Platform.isMacOS) {
      await run('open "$folderPath"', runInShell: true);
    } else if (Platform.isLinux) {
      await run('xdg-open "$folderPath"', runInShell: true);
    } else if (Platform.isAndroid || Platform.isIOS) {
      final downloadsPath = await AppSettings.getDownloadDirectory();
      final result = await OpenFile.open("$downloadsPath/");
      if (result.type == ResultType.fileNotFound) {
        showScaffoldSnackbar("Couldn't open that folder");
      }
    }
  }

  Future<void> openFile(String filePath) async {
    String pathToOpen = filePath;

    final result = await OpenFile.open(
      pathToOpen,
      type: Platform.isAndroid ? _androidOpenMimeType(widget.fileName) : null,
    );

    switch (result.type) {
      case ResultType.error:
      case ResultType.fileNotFound:
        showScaffoldSnackbar("File may have been moved or deleted.");
        break;
      case ResultType.permissionDenied:
        showScaffoldSnackbar("Permission denied.");
        break;
      case ResultType.noAppToOpen:
        showScaffoldSnackbar("No app available to open this file");
        break;
      default:
    }
  }

  String _androidOpenMimeType(String fileName) {
    final extension = fileName.split('.').last.toLowerCase();

    return switch (extension) {
      'apk' => 'application/vnd.android.package-archive',
      'zip' => 'application/zip',
      'rar' => 'application/vnd.rar',
      '7z' => 'application/x-7z-compressed',
      'tar' => 'application/x-tar',
      'gz' => 'application/gzip',
      'bz2' => 'application/x-bzip2',
      'xz' => 'application/x-xz',
      _ => lookupMimeType(fileName) ?? 'application/octet-stream',
    };
  }

  void showScaffoldSnackbar(String message) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        dismissDirection: DismissDirection.horizontal,
      ),
    );
  }
}

class _TransferProgressFooter extends StatelessWidget {
  const _TransferProgressFooter({
    super.key,
    required this.progress,
    required this.isCancelled,
  });

  final double progress;
  final bool isCancelled;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final clampedProgress = progress.clamp(0.0, 1.0);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.onInverseSurface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(5),
          bottom: Radius.circular(15),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Row(
            children: [
              Icon(
                isCancelled ? Icons.block_rounded : Icons.downloading_rounded,
                size: 18,
                color: isCancelled ? colorScheme.error : colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isCancelled ? 'Transfer cancelled' : 'Transfer in progress',
                ),
              ),
              Text(
                '${(clampedProgress * 100).round()}%',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          LinearProgressIndicator(
            value: isCancelled ? null : clampedProgress,
            year2023: false,
            color: isCancelled ? colorScheme.error : colorScheme.primary,
            stopIndicatorColor: isCancelled
                ? colorScheme.error
                : colorScheme.secondary,
          ),
        ],
      ),
    );
  }
}

class _OpenFileButton extends StatelessWidget {
  const _OpenFileButton({
    super.key,
    required this.isOpeningFile,
    required this.onPressed,
  });

  final bool isOpeningFile;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isOpeningFile ? null : onPressed,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.onInverseSurface,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(5),
            bottom: Radius.circular(15),
          ),
        ),
        child: Center(
          child: AnimatedSwitcher(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 180),
            child: isOpeningFile
                ? const SizedBox(
                    key: ValueKey('opening-file'),
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.4),
                  )
                : const Text(
                    "Open file",
                    key: ValueKey('open-file-label'),
                  ),
          ),
        ),
      ),
    );
  }
}
