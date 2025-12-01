import 'package:flashbyte/classes/hero_page_route.dart';
import 'package:flashbyte/widgets/file_preview_widget.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:heroine/heroine.dart';
import 'package:motor/motor.dart';

class TransferWidget extends StatelessWidget {
  final String fileName;
  final String fileSize;
  final String filePath;

  final bool isReceived;

  final String uuid;

  final ValueListenable<double>? value;

  const TransferWidget({
    super.key,
    required this.fileName,
    required this.fileSize,
    this.isReceived = true,
    this.value,
    required this.uuid,
    required this.filePath,
  });

  @override
  Widget build(BuildContext context) {
    return Heroine(
      motion: Motion.bouncySpring(),
      tag: uuid,
      child: Card(
        margin: EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 5,
        ),
        child: SingleChildScrollView(
          physics: NeverScrollableScrollPhysics(),
          child: Column(
            children: [
              ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadiusGeometry.circular(13),
                ),
                onTap: () {
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
                          isReceived
                              ? Icons.arrow_downward_rounded
                              : Icons.arrow_upward_rounded,
                          fontWeight: FontWeight.w900,
                          size: 15,
                          color: Colors.white.withAlpha(100),
                        ),
                        Text(
                          isReceived ? "Received" : "Sent",
                          style: Theme.of(context).textTheme.labelSmall!
                              .copyWith(
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
                          motion:
                              MaterialSpringMotion.expressiveEffectsDefault(),
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
