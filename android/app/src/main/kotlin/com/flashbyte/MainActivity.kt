package com.flashbyte

import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "flashbyte/android_saf"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "importFileToTree" -> {
                    try {
                        val treeUriString = call.argument<String>("treeUri")
                            ?: throw IllegalArgumentException("Missing treeUri")
                        val sourceFilePath = call.argument<String>("sourceFilePath")
                            ?: throw IllegalArgumentException("Missing sourceFilePath")
                        val requestedName = call.argument<String>("fileName")
                            ?: throw IllegalArgumentException("Missing fileName")
                        val mimeType = call.argument<String>("mimeType")
                            ?: "application/octet-stream"

                        val parent = DocumentFile.fromTreeUri(this, android.net.Uri.parse(treeUriString))
                            ?: throw IllegalStateException("Could not access the selected folder.")

                        val uniqueName = buildUniqueFileName(parent, requestedName)
                        val createdFile = parent.createFile(mimeType, uniqueName)
                            ?: throw IllegalStateException("Could not create the destination file.")

                        val sourceFile = File(sourceFilePath)
                        if (!sourceFile.exists()) {
                            throw IllegalStateException("The staged file does not exist anymore.")
                        }

                        contentResolver.openOutputStream(createdFile.uri, "w")?.use { output ->
                            sourceFile.inputStream().use { input ->
                                input.copyTo(output)
                            }
                        } ?: throw IllegalStateException("Could not open the destination file.")

                        result.success(
                            mapOf(
                                "uri" to createdFile.uri.toString(),
                                "name" to (createdFile.name ?: uniqueName),
                            )
                        )
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
