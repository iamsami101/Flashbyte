package com.flashbyte

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

class ClipboardSendActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        try {
            val clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            if (clipboardManager.hasPrimaryClip()) {
                val clipData = clipboardManager.primaryClip
                if (clipData != null && clipData.itemCount > 0) {
                    val text = clipData.getItemAt(0).coerceToText(this).toString()
                    if (text.isNotEmpty()) {
                        val flutterEngine = FlutterEngineCache.getInstance().get("clipboard_engine")
                        if (flutterEngine != null) {
                            MethodChannel(
                                flutterEngine.dartExecutor.binaryMessenger,
                                "com.flashbyte/clipboard_bridge"
                            ).invokeMethod("sendClipboardText", text)
                        }
                    }
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        } finally {
            finish()
        }
    }
}
