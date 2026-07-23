package com.flashbyte

import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import java.net.NetworkInterface

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        FlutterEngineCache.getInstance().put("clipboard_engine", flutterEngine)

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
            "com.flashbyte/request_clipboard"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestClipboard" -> {
                    val intent = Intent(this, ClipboardSendActivity::class.java).apply {
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
                    }
                    startActivity(intent)
                    result.success(true)
                }
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
}
