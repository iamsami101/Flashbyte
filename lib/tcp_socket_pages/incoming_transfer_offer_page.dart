import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

class IncomingTransferOfferPage extends StatelessWidget {
  const IncomingTransferOfferPage({
    super.key,
    required this.fileId,
    required this.fileName,
    required this.fileSize,
    required this.sender,
    required this.onAccept,
    required this.onDecline,
  });

  final String fileId;
  final String fileName;
  final int fileSize;
  final Map<String, dynamic>? sender;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final senderName = sender?['name'] as String? ?? 'Unknown device';
    final senderAddress = sender?['address'] as String?;
    final senderType = sender?['deviceType'] == 'laptop'
        ? Icons.laptop_mac_rounded
        : Icons.phone_android_rounded;

    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: const Text('Incoming files'),
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                          Icons.file_download_rounded,
                          size: 48,
                          color: colorScheme.primary,
                        )
                        .animate()
                        .fadeIn(duration: 180.ms)
                        .scale(
                          begin: const Offset(0.8, 0.8),
                          end: const Offset(1, 1),
                          curve: Curves.easeOutCubic,
                        ),
                    const SizedBox(height: 16),
                    Text(
                      'Files ready to receive',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ).animate().fadeIn(delay: 70.ms, duration: 180.ms),
                    const SizedBox(height: 8),
                    Text(
                      'Review the incoming file before it is saved to this device.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ).animate().fadeIn(delay: 110.ms, duration: 180.ms),
                    const SizedBox(height: 28),
                    _OfferSurface(
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            leading: CircleAvatar(
                              backgroundColor: colorScheme.secondaryContainer,
                              foregroundColor: colorScheme.onSecondaryContainer,
                              child: Icon(senderType),
                            ),
                            title: Text(senderName),
                            subtitle: Text(
                              senderAddress ?? 'Sending from a nearby device',
                            ),
                          ),
                        )
                        .animate()
                        .fadeIn(delay: 160.ms, duration: 200.ms)
                        .slideY(
                          begin: 0.04,
                          end: 0,
                          curve: Curves.easeOutCubic,
                        ),
                    const SizedBox(height: 12),
                    _OfferSurface(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.insert_drive_file_outlined,
                                  color: colorScheme.primary,
                                  size: 30,
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        fileName,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleMedium,
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        _formatFileSize(fileSize),
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color:
                                                  colorScheme.onSurfaceVariant,
                                              fontFeatures: const [
                                                FontFeature.tabularFigures(),
                                              ],
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                        .animate()
                        .fadeIn(delay: 220.ms, duration: 200.ms)
                        .slideY(
                          begin: 0.04,
                          end: 0,
                          curve: Curves.easeOutCubic,
                        ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: onAccept,
                      icon: const Icon(Icons.download_rounded),
                      label: const Text('Accept and receive'),
                    ).animate().fadeIn(delay: 280.ms, duration: 180.ms),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: onDecline,
                      icon: const Icon(Icons.close_rounded),
                      label: const Text('Decline'),
                    ).animate().fadeIn(delay: 330.ms, duration: 180.ms),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _formatFileSize(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final precision = unit == 0
        ? 0
        : value < 10
        ? 2
        : 1;
    return '${value.toStringAsFixed(precision)} ${units[unit]}';
  }
}

class _OfferSurface extends StatelessWidget {
  const _OfferSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(20),
      child: child,
    );
  }
}
