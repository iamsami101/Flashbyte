import 'dart:io';

import 'package:external_path/external_path.dart';
import 'package:flutter/material.dart';
import 'package:loading_indicator_m3e/loading_indicator_m3e.dart';
import 'package:mime/mime.dart';
import 'package:open_filex/open_filex.dart';
import 'package:process_run/process_run.dart';
import 'package:uri_to_file/uri_to_file.dart';
import 'package:widget_zoom/widget_zoom.dart';

class FilePreviewWidget extends StatefulWidget {
  final String fileName;
  final String fileSize;
  final String uuid;

  final String filePath;
  const FilePreviewWidget({
    super.key,
    required this.fileName,
    required this.fileSize,
    required this.filePath,
    required this.uuid,
  });

  @override
  State<FilePreviewWidget> createState() => _FilePreviewWidgetState();
}

class _FilePreviewWidgetState extends State<FilePreviewWidget> {
  late final String mimeType;

  File? previewFile;
  bool previewFileIsTemp = false;

  bool isLoading = false;

  @override
  void initState() {
    super.initState();

    if (Platform.isAndroid) {
      mimeType = widget.filePath.split("/").last;
    } else {
      mimeType = lookupMimeType(widget.filePath) ?? "";
    }

    if (!mimeType.startsWith("image")) return;
    _loadFile();
  }

  @override
  void dispose() {
    // delete only if it's a temporary file created by toFile()
    if (previewFileIsTemp && previewFile?.existsSync() == true) {
      previewFile!.delete();
    }

    super.dispose();
  }

  Future<void> _loadFile() async {
    setState(() => isLoading = true);

    File file;

    if (widget.filePath.contains("://") && Platform.isAndroid) {
      file = await toFile(widget.filePath);
      previewFileIsTemp = true; // mark as temp
    } else {
      file = File(widget.filePath);
      previewFileIsTemp = false; // don't delete real files
    }

    if (!file.existsSync()) return;

    if (!mounted) return;

    setState(() {
      previewFile = file;
      isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
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
                  child: mimeType.startsWith("image")
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
                              Icons.location_pin: Text(widget.filePath),
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
                child: GestureDetector(
                  onTap: () async {
                    openFile(widget.filePath);
                  },
                  child: Container(
                    padding: EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.onInverseSurface,
                      borderRadius: BorderRadius.vertical(
                        top: Radius.circular(5),
                        bottom: Radius.circular(15),
                      ),
                    ),
                    child: Center(child: Text("Open file")),
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
      print('Folder does not exist: $folderPath');
      return;
    }

    if (Platform.isWindows) {
      await run('explorer "$folderPath"', runInShell: true);
    } else if (Platform.isMacOS) {
      await run('open "$folderPath"', runInShell: true);
    } else if (Platform.isLinux) {
      await run('xdg-open "$folderPath"', runInShell: true);
    } else if (Platform.isAndroid || Platform.isIOS) {
      final downloadsPath =
          await ExternalPath.getExternalStoragePublicDirectory(
            ExternalPath.DIRECTORY_DOWNLOAD,
          );
      final result = await OpenFilex.open("$downloadsPath/");
      if (result.type == ResultType.fileNotFound) {
        showScaffoldSnackbar("Couldn't open that folder");
      }
    }
  }

  Future<void> openFile(String filePath) async {
    print(filePath);
    final result = await OpenFilex.open(filePath);
    print(result.message);

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
