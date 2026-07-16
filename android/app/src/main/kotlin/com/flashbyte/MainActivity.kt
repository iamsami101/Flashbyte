package com.flashbyte

import androidx.documentfile.provider.DocumentFile
import android.content.Context
import android.net.ConnectivityManager
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.Inet4Address
import java.net.NetworkInterface

class MainActivity : FlutterActivity() {
    private val transferBufferSize = 1024 * 1024
    private var multicastLock: WifiManager.MulticastLock? = null

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

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "flashbyte/udp_discovery"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "acquireMulticastLock" -> {
                    acquireMulticastLock()
                    result.success(null)
                }

                "releaseMulticastLock" -> {
                    releaseMulticastLock()
                    result.success(null)
                }

                "getNetworkTargets" -> {
                    result.success(getNetworkTargets())
                }

                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        releaseMulticastLock()
        super.onDestroy()
    }

    private fun acquireMulticastLock() {
        val existingLock = multicastLock
        if (existingLock?.isHeld == true) {
            return
        }

        val wifiManager = applicationContext.getSystemService(
            Context.WIFI_SERVICE
        ) as WifiManager
        multicastLock = wifiManager.createMulticastLock("flashbyte_udp_discovery").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseMulticastLock() {
        multicastLock?.let { lock ->
            if (lock.isHeld) {
                lock.release()
            }
        }
        multicastLock = null
    }

    private fun getNetworkTargets(): List<Map<String, Any>> {
        val connectivityManager = applicationContext.getSystemService(
            Context.CONNECTIVITY_SERVICE
        ) as ConnectivityManager
        val targets = mutableListOf<Map<String, Any>>()

        connectivityManager.allNetworks.forEach { network ->
            val linkProperties = connectivityManager.getLinkProperties(network) ?: return@forEach
            val gatewayAddresses = linkProperties.routes
                .mapNotNull { route -> route.gateway as? Inet4Address }
                .map { gateway -> gateway.hostAddress }
                .filterNotNull()
                .distinct()

            linkProperties.linkAddresses.forEach { linkAddress ->
                val address = linkAddress.address as? Inet4Address ?: return@forEach
                val hostAddress = address.hostAddress ?: return@forEach
                val prefixLength = linkAddress.prefixLength
                val broadcastAddress = ipv4BroadcastAddress(address, prefixLength)

                targets.add(
                    mapOf(
                        "address" to hostAddress,
                        "prefixLength" to prefixLength,
                        "broadcast" to broadcastAddress,
                        "gateways" to gatewayAddresses,
                    )
                )
            }
        }

        return targets
    }

    private fun ipv4BroadcastAddress(address: Inet4Address, prefixLength: Int): String {
        if (prefixLength < 0 || prefixLength > 32) {
            return ""
        }

        val addressInt = address.address.fold(0) { accumulator, byte ->
            (accumulator shl 8) or (byte.toInt() and 0xff)
        }
        val mask = if (prefixLength == 0) {
            0
        } else {
            (-0x1) shl (32 - prefixLength)
        }
        val broadcast = addressInt or mask.inv()

        return listOf(
            (broadcast ushr 24) and 0xff,
            (broadcast ushr 16) and 0xff,
            (broadcast ushr 8) and 0xff,
            broadcast and 0xff,
        ).joinToString(".")
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
