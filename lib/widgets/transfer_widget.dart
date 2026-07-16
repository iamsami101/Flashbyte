import 'package:flashbyte/classes/hero_page_route.dart';
import 'package:flashbyte/widgets/file_preview_widget.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:heroine/heroine.dart';
import 'package:motor/motor.dart';

enum TransferStatus { pending, inProgress, paused, completed, cancelled }

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
  final VoidCallback? onAccept;
  final VoidCallback? onDecline;

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
    this.onAccept,
    this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final isFinished = status == TransferStatus.completed;
    final isCancelled = status == TransferStatus.cancelled;
    final isPaused = status == TransferStatus.paused;
    final isPending = status == TransferStatus.pending;
    final isActive =
        status == TransferStatus.inProgress || status == TransferStatus.paused;
    final transferStateText = switch (status) {
      TransferStatus.pending => isReceived ? "request" : "waiting",
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

    final card = Container(
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
                  if (isCancelled || isPending) return;
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
                      builder: (context, pvalue, child) {
                        Widget buildProgress(double value) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            spacing: 10,
                            children: [
                              Text(
                                isCancelled
                                    ? "$fileSize • ${fileName.split(".").last.toUpperCase()} • Cancelled"
                                    : isPending
                                    ? "$fileSize • ${fileName.split(".").last.toUpperCase()} • Waiting"
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
                                  reducedMotion: reducedMotion,
                                ),
                              if (isPending)
                                _TransferAcceptanceControls(
                                  isReceived: isReceived,
                                  onAccept: onAccept,
                                  onDecline: onDecline,
                                ),
                            ],
                          );
                        }

                        if (reducedMotion) {
                          return buildProgress(pvalue);
                        }

                        return SingleMotionBuilder(
                          value: pvalue,
                          motion: Motion.smoothSpring(),
                          builder: (context, value, child) =>
                              buildProgress(value),
                        );
                      },
                    ),
                dense: true,
              ),
            ],
          ),
        ),
      ),
    );

    if (reducedMotion) {
      return card;
    }

    return Heroine(
      motion: Motion.bouncySpring(),
      tag: uuid,
      child: card,
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
          initialTransferProgress: status == TransferStatus.completed
              ? 1
              : value?.value ?? 0,
          isTransferComplete: status == TransferStatus.completed,
          isTransferCancelled: status == TransferStatus.cancelled,
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
    required this.reducedMotion,
  });

  final bool isPaused;
  final bool canResume;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onCancel;
  final bool reducedMotion;

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
        FilledButton(
          style: FilledButton.styleFrom(
            padding: EdgeInsets.zero,
            backgroundColor: colorScheme.errorContainer,
            foregroundColor: colorScheme.onErrorContainer,
            disabledBackgroundColor: Colors.transparent,
            disabledForegroundColor: Colors.transparent,
          ),
          onPressed: isPaused ? onCancel : null,
          child: reducedMotion
              ? AnimatedSwitcher(
                  duration: const Duration(milliseconds: 160),
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeIn,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: child,
                  ),
                  child: isPaused
                      ? const Padding(
                          key: ValueKey('cancel-visible'),
                          padding: EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            spacing: 8,
                            children: [
                              Icon(Icons.close_rounded),
                              Text("Cancel"),
                            ],
                          ),
                        )
                      : const SizedBox(
                          key: ValueKey('cancel-hidden'),
                          width: 0,
                          height: 24,
                        ),
                )
              : AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.centerLeft,
                  child: isPaused
                      ? const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            spacing: 8,
                            children: [
                              Icon(Icons.close_rounded),
                              Text("Cancel"),
                            ],
                          ),
                        )
                      : const SizedBox(width: 0, height: 24),
                ),
        ),
      ],
    );
  }
}

class _TransferAcceptanceControls extends StatelessWidget {
  const _TransferAcceptanceControls({
    required this.isReceived,
    required this.onAccept,
    required this.onDecline,
  });

  final bool isReceived;
  final VoidCallback? onAccept;
  final VoidCallback? onDecline;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (!isReceived) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          spacing: 10,
          children: [
            SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            Expanded(
              child: Text(
                "Waiting for receiver to accept",
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      );
    }

    return Row(
      spacing: 8,
      children: [
        FilledButton.icon(
          onPressed: onAccept,
          icon: const Icon(Icons.check_rounded),
          label: const Text("Accept"),
        ),
        FilledButton.tonalIcon(
          style: FilledButton.styleFrom(
            backgroundColor: colorScheme.errorContainer,
            foregroundColor: colorScheme.onErrorContainer,
          ),
          onPressed: onDecline,
          icon: const Icon(Icons.close_rounded),
          label: const Text("Decline"),
        ),
      ],
    );
  }
}
