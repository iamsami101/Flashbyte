package com.flashbyte

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

class ClipboardSendActivity : Activity() {
    companion object {
        private const val TAG = "Flashbyte/Clipboard"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        try {
            val clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            if (!clipboardManager.hasPrimaryClip()) {
                Log.w(TAG, "no primary clip available")
                return
            }

            val clipData = clipboardManager.primaryClip
            if (clipData == null || clipData.itemCount == 0) {
                Log.w(TAG, "clipData is null or empty")
                return
            }

            val text = clipData.getItemAt(0).coerceToText(this).toString()
            Log.d(TAG, "clipboard text length: ${text.length}")
            if (text.isEmpty()) {
                Log.w(TAG, "clipboard text is empty")
                return
            }

            val flutterEngine = FlutterEngineCache.getInstance().get("clipboard_engine")
            if (flutterEngine == null) {
                Log.e(TAG, "FlutterEngine not found in cache")
                return
            }

            Log.d(TAG, "invoking clipboard_bridge with text (len=${text.length})")
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                "com.flashbyte/clipboard_bridge"
            ).invokeMethod("sendClipboardText", text)
            Log.d(TAG, "clipboard_bridge invoke succeeded")
        } catch (e: Exception) {
            Log.e(TAG, "error reading/sending clipboard", e)
        } finally {
            finish()
        }
    }
}
