package com.omnibutler.omni_butler

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.os.StatFs
import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.net.Uri
import android.provider.Settings
import io.flutter.plugin.common.EventChannel


class MainActivity : FlutterActivity() {
    // 等待用户授权后再启动的录音请求。
    private var recordingPermissionResult: MethodChannel.Result? = null
    // 授权前保存的采集参数。
    private var recordingArguments: Map<String, Any?>? = null
    // 注册只读磁盘空间查询，迁移前避免耗尽应用私有存储。
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 应用级前台录音服务与 Flutter 的命令桥。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "omni_butler/notes_recording")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        if (recordingPermissionResult != null || NoteRecordingService.active != null) {
                            result.error("RECORDING_BUSY", "已有录音进行中", null)
                        } else {
                            // 仅保留本次主动点击的录音参数。
                            val arguments = call.arguments as? Map<String, Any?>
                            if (arguments == null) result.error("INVALID_ARGUMENT", "缺少录音参数", null)
                            else requestRecordingPermissions(arguments, result)
                        }
                    }
                    "setMetering" -> {
                        NoteRecordingService.active?.meteringEnabled = call.arguments == true
                        result.success(null)
                    }
                    "pause" -> { NoteRecordingService.active?.pauseRecording(); result.success(null) }
                    "resume" -> {
                        try { NoteRecordingService.active?.resumeRecording(); result.success(null) }
                        catch (error: Exception) { result.error("MICROPHONE_UNAVAILABLE", "麦克风无法继续采集", null) }
                    }
                    "stop" -> {
                        // 原生服务结束后才把可播放文件返回 Flutter。
                        val service = NoteRecordingService.active
                        if (service == null) result.success(null)
                        else service.finishRecording(call.argument<String>("reason")) { value -> result.success(value) }
                    }
                    "openSettings" -> {
                        startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.parse("package:$packageName")))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        // 录音状态来自服务，页面重建不会重新创建录音。
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "omni_butler/notes_recording_events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                // 重连时重放真实活动状态和通知返回请求。
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    NoteRecordingService.sink = events
                    NoteRecordingService.active?.publishState()
                    NoteRecordingService.pendingReturn?.let { NoteRecordingService.emit(mapOf("type" to "return", "noteId" to it)) }
                    NoteRecordingService.pendingReturn = null
                }
                // 服务仍采集，不依赖 Flutter 页面事件订阅。
                override fun onCancel(arguments: Any?) { NoteRecordingService.sink = null }
            })
        handleRecordingReturn(intent)
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

    // 只有主动点击开始录音时才申请麦克风和通知权限。
    private fun requestRecordingPermissions(arguments: Map<String, Any?>, result: MethodChannel.Result) {
        // 当前尚未授权的权限，通知权限用于后台暂停和结束入口。
        val missing = mutableListOf<String>()
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) missing.add(Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) missing.add(Manifest.permission.POST_NOTIFICATIONS)
        if (missing.isEmpty()) launchRecording(arguments, result)
        else {
            recordingPermissionResult = result
            recordingArguments = arguments
            requestPermissions(missing.toTypedArray(), 8041)
        }
    }

    // 授权结果只处理最初用户发起的请求，不自动重试被中断的录音。
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != 8041) return
        // 本次待处理 Flutter 返回句柄。
        val result = recordingPermissionResult ?: return
        // 最初请求的原件位置和稳定标识。
        val arguments = recordingArguments
        recordingPermissionResult = null
        recordingArguments = null
        if (grantResults.isEmpty() || grantResults.any { it != PackageManager.PERMISSION_GRANTED } || arguments == null) {
            result.error("PERMISSION_DENIED", "请在系统设置允许麦克风和录音通知；文字输入仍可使用", null)
        } else launchRecording(arguments, result)
    }

    // 在可见 Activity 中启动 microphone 类型前台服务，符合 Android 后台启动限制。
    private fun launchRecording(arguments: Map<String, Any?>, result: MethodChannel.Result) {
        try {
            // 防止参数被用来写入应用目录外部。
            val path = arguments["path"] as? String ?: throw IllegalArgumentException()
            // 应用数据根目录，Flutter support 文件位于其内部。
            val root = java.io.File(applicationInfo.dataDir).canonicalPath + java.io.File.separator
            require(java.io.File(path).canonicalPath.startsWith(root))
            NoteRecordingService.startResult = result
            // 跨服务传递所有不可变录音元信息。
            val command = Intent(this, NoteRecordingService::class.java).setAction(NoteRecordingService.START)
                .putExtra("id", arguments["id"] as String)
                .putExtra("noteId", arguments["noteId"] as String)
                // 原生状态、通知和完成回调必须保留本机草稿代次。
                .putExtra("draftId", arguments["draftId"] as? String)
                .putExtra("path", path)
                .putExtra("startedAt", arguments["startedAt"] as String)
                .putExtra("creationTimezone", arguments["creationTimezone"] as? String ?: "legacy:unknown")
                .putExtra("limitMs", (arguments["limitMs"] as Number).toLong())
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(command) else startService(command)
        } catch (error: Exception) {
            NoteRecordingService.startResult = null
            result.error("RECORDING_START_FAILED", "无法启动录音，请检查麦克风权限与设备状态", null)
        }
    }

    // 通知返回原始笔记，单实例 Activity 不创建新空白笔记。
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleRecordingReturn(intent)
    }

    // 将通知中的稳定笔记标识交给应用路由。
    private fun handleRecordingReturn(intent: Intent?) {
        // 当前返回请求携带的原始笔记。
        val noteId = intent?.getStringExtra("recordingNoteId") ?: return
        if (NoteRecordingService.sink == null) NoteRecordingService.pendingReturn = noteId
        else NoteRecordingService.emit(mapOf("type" to "return", "noteId" to noteId))
        intent.removeExtra("recordingNoteId")
    }
}
