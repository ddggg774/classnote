package com.example.classnote

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 除了正常启动，还充当「从其他 App 分享文本给课堂笔记」的接收方。
 *
 * 冷启动：文本随 Intent 进来，Flutter 侧拉取后清空，避免重复导入。
 * 热启动：onNewIntent 收到，主动推给 Flutter。
 */
class MainActivity : FlutterActivity() {

    private var pendingText: String? = null
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "classnote/share_in")
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getPendingText" -> {
                    result.success(pendingText)
                    pendingText = null
                }
                else -> result.notImplemented()
            }
        }
        pendingText = extractSharedText(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val text = extractSharedText(intent) ?: return
        pendingText = text
        // 页面已在前台时直接推过去；没有监听者也没关系，getPendingText 会兜底
        channel?.invokeMethod("onSharedText", text)
    }

    private fun extractSharedText(intent: Intent?): String? {
        if (intent == null || intent.action != Intent.ACTION_SEND) return null
        val type = intent.type ?: return null
        if (!type.startsWith("text/")) return null
        val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: return null
        return text.takeIf { it.isNotBlank() }
    }
}