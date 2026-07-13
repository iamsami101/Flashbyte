package com.flashbyte

import androidx.documentfile.provider.DocumentFile
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.NetworkInterface

class MainActivity : FlutterActivity() {
    private val transferBufferSize = 1024 * 1024

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
                                input.copyTo(output, transferBufferSize)
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

                "openDocumentUri" -> {
                    try {
                        val uriString = call.argument<String>("uri")
                            ?: throw IllegalArgumentException("Missing uri")
                        val mimeType = call.argument<String>("mimeType")
                            ?: "application/octet-stream"
                        val uri = Uri.parse(uriString)
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, mimeType)
                            clipData = ClipData.newUri(contentResolver, "Flashbyte file", uri)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }

                        try {
                            startActivity(intent)
                            result.success(null)
                        } catch (_: ActivityNotFoundException) {
                            result.error("NO_APP_TO_OPEN", "No app available to open this file.", null)
                        }
                    } catch (error: Exception) {
                        result.error("ANDROID_OPEN_URI_ERROR", error.message, null)
                    }
                }

                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "flashbyte/network_status"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isHotspotEnabled" -> result.success(isHotspotEnabled())
                else -> result.notImplemented()
            }
        }
    }

    private fun isHotspotEnabled(): Boolean {
        return try {
            val wifiManager = applicationContext.getSystemService(
                Context.WIFI_SERVICE
            ) as WifiManager
            val method = wifiManager.javaClass.getDeclaredMethod("isWifiApEnabled")
            method.isAccessible = true
            method.invoke(wifiManager) as? Boolean ?: false
        } catch (_: Exception) {
            NetworkInterface.getNetworkInterfaces()?.toList()?.any { network ->
                network.isUp && (
                    network.name.startsWith("ap") ||
                        network.name.startsWith("swlan")
                    )
            } ?: false
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
