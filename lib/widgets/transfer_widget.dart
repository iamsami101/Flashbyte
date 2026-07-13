import 'package:flashbyte/classes/hero_page_route.dart';
import 'package:flashbyte/widgets/file_preview_widget.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:heroine/heroine.dart';
import 'package:motor/motor.dart';

enum TransferStatus { inProgress, paused, completed, cancelled }

class TransferWidget extends StatelessWidget {
  final String fileName;
  final String fileSize;
  final String filePath;

  final bool isReceived;

  final String uuid;

  final ValueListenable<double>? value;
  final TransferStatus status;
  final bool canResume;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onCancel;

  const TransferWidget({
    super.key,
    required this.fileName,
    required this.fileSize,
    this.isReceived = true,
    this.value,
    required this.uuid,
    required this.filePath,
    this.status = TransferStatus.inProgress,
    this.canResume = true,
    this.onPause,
    this.onResume,
    this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isFinished = status == TransferStatus.completed;
    final isCancelled = status == TransferStatus.cancelled;
    final isPaused = status == TransferStatus.paused;
    final isActive =
        status == TransferStatus.inProgress || status == TransferStatus.paused;
    final transferStateText = switch (status) {
      TransferStatus.cancelled => "cancelled",
      TransferStatus.paused => "paused",
      TransferStatus.completed => isReceived ? "received" : "sent",
      TransferStatus.inProgress => isReceived ? "receiving" : "sending",
    };
    final primaryTextStyle =
        Theme.of(
          context,
        ).textTheme.labelSmall!.copyWith(
          color: isCancelled
              ? colorScheme.error
              : isFinished
              ? colorScheme.primary
              : Colors.white.withAlpha(100),
        );
    final progressValue = isFinished ? 1.0 : null;

    return Heroine(
      motion: Motion.bouncySpring(),
      tag: uuid,
      child: Container(
        margin: EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 5,
        ),
        child: Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: SingleChildScrollView(
            physics: NeverScrollableScrollPhysics(),
            child: Column(
              children: [
                ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadiusGeometry.circular(13),
                  ),
                  onTap: () {
                    if (isCancelled) return;
                    openFilePreview(context);
                  },
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
                            isCancelled
                                ? Icons.block_rounded
                                : isReceived
                                ? Icons.arrow_downward_rounded
                                : Icons.arrow_upward_rounded,
                            fontWeight: FontWeight.w900,
                            size: 15,
                            color: isCancelled
                                ? colorScheme.error
                                : isFinished
                                ? colorScheme.primary
                                : Colors.white.withAlpha(100),
                          ),
                          Text(
                            transferStateText,
                            style: primaryTextStyle,
                          ),
                        ],
                      ),
                    ],
                  ),
                  subtitle:
                      // value == null
                      //     ? Column(
                      //         crossAxisAlignment: CrossAxisAlignment.start,
                      //         spacing: 10,
                      //         children: [
                      //           Text(
                      //             "$fileSize • ${fileName.split(".").last.toUpperCase()} • 100%",
                      //           ),
                      //           LinearProgressIndicator(
                      //             value: 1,
                      //             year2023: false,
                      //             stopIndicatorRadius: 1,
                      //             stopIndicatorColor: colorScheme.secondary,
                      //           ),
                      //         ],
                      //       )
                      //     :
                      ValueListenableBuilder(
                        valueListenable: progressValue != null
                            ? ValueNotifier<double>(progressValue)
                            : value!,
                        builder: (context, pvalue, child) => SingleMotionBuilder(
                          value: pvalue,
                          motion: Motion.smoothSpring(),
                          builder: (context, value, child) => Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            spacing: 10,
                            children: [
                              Text(
                                isCancelled
                                    ? "$fileSize • ${fileName.split(".").last.toUpperCase()} • Cancelled"
                                    : "$fileSize • ${fileName.split(".").last.toUpperCase()} • ${(value * 100).round()}%",
                              ),
                              LinearProgressIndicator(
                                value: value,
                                year2023: false,
                                stopIndicatorRadius: 1,
                                color: isCancelled
                                    ? colorScheme.error
                                    : colorScheme.primary,
                                stopIndicatorColor: isCancelled
                                    ? colorScheme.error
                                    : colorScheme.secondary,
                              ),
                              if (isActive)
                                _TransferControls(
                                  isPaused: isPaused,
                                  canResume: canResume,
                                  onPause: onPause,
                                  onResume: onResume,
                                  onCancel: onCancel,
                                ),
                            ],
                          ),
                        ),
                      ),
                  dense: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void openFilePreview(BuildContext context) {
    Navigator.push(
      context,
      HeroDialogRoute(
        heroTag: uuid,
        heroChild: FilePreviewWidget(
          uuid: uuid,
          filePath: filePath,
          fileName: fileName,
          fileSize: fileSize,
        ),
      ),
    );
  }
}

class _TransferControls extends StatelessWidget {
  const _TransferControls({
    required this.isPaused,
    required this.canResume,
    required this.onPause,
    required this.onResume,
    required this.onCancel,
  });

  final bool isPaused;
  final bool canResume;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Row(
      spacing: 8,
      children: [
        FilledButton.tonalIcon(
          onPressed: isPaused && !canResume
              ? null
              : isPaused
              ? onResume
              : onPause,
          icon: Icon(
            isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
          ),
          label: Text(
            isPaused && !canResume
                ? "Pause"
                : isPaused
                ? "Continue"
                : "Pause",
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.centerLeft,
          child: isPaused
              ? FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    backgroundColor: colorScheme.errorContainer,
                    foregroundColor: colorScheme.onErrorContainer,
                  ),
                  onPressed: onCancel,
                  icon: const Icon(Icons.close_rounded),
                  label: const Text("Cancel"),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}
