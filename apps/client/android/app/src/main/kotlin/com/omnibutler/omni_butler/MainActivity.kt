package com.omnibutler.omni_butler

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.os.StatFs

class MainActivity : FlutterActivity() {
    // 注册只读磁盘空间查询，迁移前避免耗尽应用私有存储。
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "omni_butler/storage")
            .setMethodCallHandler { call, result ->
                if (call.method != "availableBytes") {
                    result.notImplemented()
                } else {
                    try {
                        // 仅允许查询应用自身能够访问的目录。
                        val path = call.argument<String>("path") ?: filesDir.absolutePath
                        result.success(StatFs(path).availableBytes)
                    } catch (error: Exception) {
                        result.error("STORAGE_UNAVAILABLE", "无法检查本机剩余空间", null)
                    }
                }
            }
    }
}
