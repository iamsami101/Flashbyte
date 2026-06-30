package com.flashbyte

import android.os.ParcelFileDescriptor
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val outputFdMap = mutableMapOf<Int, ParcelFileDescriptor>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "flashbyte/android_saf"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "createOutputFile" -> {
                    try {
                        val treeUriString = call.argument<String>("treeUri")
                            ?: throw IllegalArgumentException("Missing treeUri")
                        val requestedName = call.argument<String>("fileName")
                            ?: throw IllegalArgumentException("Missing fileName")
                        val mimeType = call.argument<String>("mimeType")
                            ?: "application/octet-stream"

                        val parent = DocumentFile.fromTreeUri(this, android.net.Uri.parse(treeUriString))
                            ?: throw IllegalStateException("Could not access the selected folder.")

                        val uniqueName = buildUniqueFileName(parent, requestedName)
                        val createdFile = parent.createFile(mimeType, uniqueName)
                            ?: throw IllegalStateException("Could not create the destination file.")
                        val fileDescriptor =
                            contentResolver.openFileDescriptor(createdFile.uri, "w")
                                ?: throw IllegalStateException("Could not open the destination file.")

                        outputFdMap[fileDescriptor.fd] = fileDescriptor

                        result.success(
                            mapOf(
                                "fd" to fileDescriptor.fd,
                                "uri" to createdFile.uri.toString(),
                                "name" to (createdFile.name ?: uniqueName),
                            )
                        )
                    } catch (error: Exception) {
                        result.error("ANDROID_SAF_ERROR", error.message, null)
                    }
                }

                "closeOutputFile" -> {
                    try {
                        val fd = call.argument<Int>("fd")
                            ?: throw IllegalArgumentException("Missing fd")
                        outputFdMap.remove(fd)?.close()
                        result.success(null)
                    } catch (error: Exception) {
                        result.error("ANDROID_SAF_ERROR", error.message, null)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun buildUniqueFileName(parent: DocumentFile, requestedName: String): String {
        if (parent.findFile(requestedName) == null) {
            return requestedName
        }

        val dotIndex = requestedName.lastIndexOf('.')
        val baseName = if (dotIndex > 0) requestedName.substring(0, dotIndex) else requestedName
        val extension = if (dotIndex > 0) requestedName.substring(dotIndex) else ""

        var counter = 1
        while (true) {
            val candidate = "$baseName ($counter)$extension"
            if (parent.findFile(candidate) == null) {
                return candidate
            }
            counter++
        }
    }
}
