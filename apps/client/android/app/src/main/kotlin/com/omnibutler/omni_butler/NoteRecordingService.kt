package com.omnibutler.omni_butler

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioRecordingConfiguration
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** 真正持有麦克风的 Android 前台服务，采样和限额不依赖 Dart 计时器。 */
class NoteRecordingService : Service() {
    companion object {
        // 前台服务命令名，通知操作只能控制当前采集。
        const val START = "notes.recording.START"
        // 通知暂停/继续命令。
        const val TOGGLE = "notes.recording.TOGGLE"
        // 通知结束命令。
        const val STOP = "notes.recording.STOP"
        // 固定通知频道。
        private const val CHANNEL = "notes_microphone"
        // 固定活动录音通知 ID。
        private const val NOTIFICATION = 8042
        // PCM 格式采样率。
        private const val SAMPLE_RATE = 16000
        // PCM 每秒数据长度。
        private const val BYTES_PER_SECOND = SAMPLE_RATE * 2
        // 正在运行的服务，不按页面持有。
        @Volatile var active: NoteRecordingService? = null
        // 原生事件通道订阅。
        var sink: EventChannel.EventSink? = null
        // 延迟到设备实际启动后响应的 Flutter 调用。
        var startResult: MethodChannel.Result? = null
        // 引擎未订阅时暂存通知返回请求。
        var pendingReturn: String? = null
        // 主线程事件调度，EventSink 不能在采样线程调用。
        private val main = Handler(Looper.getMainLooper())

        // 在主线程发送原生权威状态。
        fun emit(value: Map<String, Any?>) { main.post { sink?.success(value) } }
    }

    // 当前原件固定元信息。
    private var metadata: Map<String, Any?> = emptyMap()
    // PCM 采集器。
    private var recorder: AudioRecord? = null
    // 私有原件文件句柄。
    private var output: RandomAccessFile? = null
    // 逐批写入的有效样本长度。
    @Volatile private var audioBytes = 0L
    // 本段剩余额度对应的采样上限。
    private var maxBytes = 0L
    // 采样线程生命标记。
    @Volatile private var running = false
    // 暂停时不写任何采样，也不增加时长。
    @Volatile private var paused = false
    // 停止过程只执行一次。
    @Volatile private var ending = false
    // 等待最终文件的命令回调。
    private val finishCallbacks = mutableListOf<(Map<String, Any?>?) -> Unit>()
    // 后台采样线程。
    private var worker: Thread? = null
    // 防止同步暂停、检查点与写盘交叉。
    private val ioLock = Any()
    // 锁屏期间保持 CPU 采样，不唤醒屏幕。
    private var wakeLock: PowerManager.WakeLock? = null
    // 音频焦点和麦克风状态管理器。
    private lateinit var audioManager: AudioManager
    // Android 26 及以上音频焦点句柄。
    private var focusRequest: AudioFocusRequest? = null
    // 暂时丢失焦点也停止录音，系统恢复时不自动重开。
    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        if (change == AudioManager.AUDIOFOCUS_LOSS || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) {
            finishRecording("来电或其他音频应用中断录音，已保存可用原音")
        }
    }
    // 系统静音麦克风（权限撤回或被抢占）时不能显示正常采集。
    private var recordingCallback: AudioManager.AudioRecordingCallback? = null

    // 可视音量仅在录音卡片可见时计算，不影响后台录音。
    @Volatile var meteringEnabled = false

    // 服务不提供 Binder；所有操作通过明确命令。
    override fun onBind(intent: Intent?): IBinder? = null

    // 初始化通知频道和音频系统。
    override fun onCreate() {
        super.onCreate()
        audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
        if (Build.VERSION.SDK_INT >= 26) {
            // 使用低优先级持续通知，正常显示用户正在录音。
            val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "笔记录音", NotificationManager.IMPORTANCE_LOW))
        }
    }

    // 前台开始、通知暂停和结束均由本服务完成。
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            START -> beginRecording(intent)
            TOGGLE -> if (!ending && active === this) {
                if (paused) {
                    try { resumeRecording() } catch (_: Exception) { finishRecording("麦克风无法继续采集") }
                } else pauseRecording()
            }
            STOP -> finishRecording(null)
        }
        // 系统杀进程后只恢复原音，绝不自动重新开启麦克风。
        return START_NOT_STICKY
    }

    // 启动采样前先展示 microphone 前台通知，再申请音频焦点。
    private fun beginRecording(intent: Intent) {
        try {
            require(active == null)
            // 稳定开始时间和文件位置来自已经落盘的 Dart 恢复清单。
            val limitMs = intent.getLongExtra("limitMs", 0).coerceAtMost(30L * 60 * 1000)
            require(limitMs > 0)
            metadata = mapOf("id" to intent.getStringExtra("id"), "noteId" to intent.getStringExtra("noteId"),
                // 草稿身份与采集身份同时固定，不依赖页面当前选择。
                "draftId" to intent.getStringExtra("draftId"),
                "path" to intent.getStringExtra("path"), "startedAt" to intent.getStringExtra("startedAt"),
                "creationTimezone" to (intent.getStringExtra("creationTimezone") ?: "legacy:unknown"), "limitMs" to limitMs)
            if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            else startForeground(NOTIFICATION, notification())
            if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) throw SecurityException()
            // 阻止关闭通知后无法从锁屏暂停/结束的隐形采集。
            if (!(getSystemService(NOTIFICATION_SERVICE) as NotificationManager).areNotificationsEnabled()) {
                throw IllegalStateException("请在系统设置开启笔记录音通知")
            }
            maxBytes = limitMs * BYTES_PER_SECOND / 1000 / 2 * 2
            // 系统建议采样缓冲，最少每批 100 ms。
            val size = maxOf(AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT), BYTES_PER_SECOND / 10)
            recorder = AudioRecord(MediaRecorder.AudioSource.MIC, SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, size * 2)
            if (recorder?.state != AudioRecord.STATE_INITIALIZED) throw IllegalStateException("麦克风不可用或被占用")
            output = RandomAccessFile(metadata["path"] as String, "rw")
            output!!.setLength(0)
            output!!.write(wavHeader(0))
            output!!.fd.sync()
            requestFocus()
            recorder!!.startRecording()
            if (recorder!!.recordingState != AudioRecord.RECORDSTATE_RECORDING) throw IllegalStateException("无法开始麦克风采集")
            running = true
            active = this
            acquireWakeLock()
            registerInterruptionMonitor()
            worker = Thread({ capture(size) }, "notes-pcm-recorder").apply { start() }
            publishState()
            startResult?.success(null)
            startResult = null
        } catch (error: Exception) {
            // 失败说明不包含内部绝对目录或敏感配置。
            val reason = if (error is SecurityException) "请允许麦克风权限后重试" else (error.message ?: "麦克风不可用或被占用")
            startResult?.error("RECORDING_START_FAILED", reason, null)
            startResult = null
            cleanup()
            emit(metadata + mapOf("type" to "failed", "reason" to reason))
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    // 采样线程只写固定 PCM 格式，暂停时间自然不计入字节数。
    private fun capture(bufferSize: Int) {
        // 本批采样缓冲。
        val buffer = ByteArray(bufferSize)
        // 最近的磁盘同步检查点。
        var checkpoint = android.os.SystemClock.elapsedRealtime()
        // 波形事件最多20Hz，不与磁盘同步和通知刷新耦合。
        var lastMeter = 0L
        try {
            while (running) {
                if (paused) { Thread.sleep(50); continue }
                // read 阻塞直到有采样或设备被停止。
                val read = recorder?.read(buffer, 0, buffer.size) ?: break
                if (!running) break
                if (paused) continue
                if (read <= 0) throw IllegalStateException("麦克风被中断或权限被撤回")
                synchronized(ioLock) {
                    if (!running || paused) return@synchronized
                    // 限额只截在完整 16 bit 采样边界。
                    val count = minOf(read.toLong(), maxBytes - audioBytes).toInt() / 2 * 2
                    if (count > 0) { output!!.write(buffer, 0, count); audioBytes += count }
                    // 每秒补写 WAV 长度并同步，强退后仍可直接播放有效部分。
                    val now = android.os.SystemClock.elapsedRealtime()
                    if (meteringEnabled && count > 0 && now - lastMeter >= 50) {
                        // 16位小端PCM的均方根转为有限可视幅度。
                        var squares = 0.0
                        for (index in 0 until count step 2) {
                            // 保留有符号16位采样，避免负值被当作大正数。
                            val sample = ((buffer[index].toInt() and 255) or (buffer[index + 1].toInt() shl 8)).toShort().toDouble() / 32768.0
                            squares += sample * sample
                        }
                        // 提升语音的低电平可见度，静音仍为零。
                        val level = kotlin.math.sqrt(kotlin.math.sqrt(squares / (count / 2))).coerceIn(0.0, 1.0)
                        emit(mapOf("type" to "meter", "id" to metadata["id"], "level" to level, "durationMs" to audioBytes * 1000 / BYTES_PER_SECOND))
                        lastMeter = now
                    }
                    if (now - checkpoint >= 1000) {
                        updateHeader()
                        output!!.fd.sync()
                        checkpoint = now
                        publishState()
                        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIFICATION, notification())
                    }
                }
                if (audioBytes >= maxBytes) {
                    Handler(Looper.getMainLooper()).post { finishRecording("已达到本段或本篇录音时长上限") }
                    break
                }
            }
        } catch (error: Exception) {
            if (running) Handler(Looper.getMainLooper()).post { finishRecording("录音中断，已保存可用原音：${error.message ?: "设备或存储异常"}") }
        }
    }

    // 暂停停止设备采样但保留同一原件和前台通知。
    fun pauseRecording() {
        if (!running || paused || ending) return
        paused = true
        try { recorder?.stop() } catch (_: Exception) { }
        try { synchronized(ioLock) { updateHeader(); output?.fd?.sync() } }
        catch (_: Exception) {
            finishRecording("录音写入失败，已保留可恢复的原音")
            return
        }
        wakeLock?.let { if (it.isHeld) it.release() }
        publishState()
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIFICATION, notification())
    }

    // 用户明确点击继续才重新采集，失败则保留已经采集的原音。
    fun resumeRecording() {
        if (!running || !paused || ending) return
        try {
            requestFocus()
            recorder?.startRecording()
            if (recorder?.recordingState != AudioRecord.RECORDSTATE_RECORDING) throw IllegalStateException()
            acquireWakeLock()
            paused = false
            publishState()
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIFICATION, notification())
        } catch (error: Exception) {
            finishRecording("麦克风无法继续采集，已保存可用原音")
            throw error
        }
    }

    // 等采样线程结束并同步原件，再交付完成事件和调用结果。
    fun finishRecording(reason: String?, callback: ((Map<String, Any?>?) -> Unit)? = null) {
        if (callback != null) finishCallbacks.add(callback)
        if (ending) return
        ending = true
        running = false
        publishState()
        try { recorder?.stop() } catch (_: Exception) { }
        Thread({
            worker?.join(3000)
            // 完成结果必须来自实际持久化的字节数。
            var savedReason = reason
            try { synchronized(ioLock) { updateHeader(); output?.fd?.sync(); output?.close(); output = null } }
            catch (_: Exception) { savedReason = "录音保存发生异常，请检查恢复原音" }
            // 小于一个采样不产生正式笔记。
            val result = if (audioBytes > 0) metadata + mapOf("type" to "completed", "durationMs" to audioBytes * 1000 / BYTES_PER_SECOND, "reason" to savedReason) else null
            Handler(Looper.getMainLooper()).post {
                cleanup()
                stopForeground(STOP_FOREGROUND_REMOVE)
                if (result != null) emit(result)
                else emit(metadata + mapOf("type" to "state", "phase" to "idle"))
                finishCallbacks.toList().forEach { it(result) }
                finishCallbacks.clear()
                stopSelf()
            }
        }, "notes-finalize-recorder").start()
    }

    // 与 Dart UI 和录音通知共享的采样字节状态。
    fun publishState() {
        emit(stateSnapshot())
    }

    // 同步返回采集真实状态，供 Dart 初始化互斥锁时读取。
    fun stateSnapshot(): Map<String, Any?> = metadata + mapOf("type" to "state",
        "phase" to when { ending -> "stopping"; paused -> "paused"; running -> "recording"; else -> "idle" },
        "durationMs" to audioBytes * 1000 / BYTES_PER_SECOND)

    // 保持屏幕关闭时采样，暂停时释放，恢复时重新获取。
    private fun acquireWakeLock() {
        if (wakeLock == null) wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "omni_butler:notes_recording")
        wakeLock!!.setReferenceCounted(false)
        if (!wakeLock!!.isHeld) wakeLock!!.acquire()
    }

    // 请求排他性临时音频焦点，来电和其他持有者会触发停止。
    private fun requestFocus() {
        // 系统焦点请求结果。
        val result = if (Build.VERSION.SDK_INT >= 26) {
            focusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                .setOnAudioFocusChangeListener(focusListener).build()
            audioManager.requestAudioFocus(focusRequest!!)
        } else {
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(focusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
        }
        if (result != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) throw IllegalStateException("其他音频应用正在占用麦克风")
    }

    // Android 10 以上可检测系统对本采集客户端静音。
    private fun registerInterruptionMonitor() {
        if (Build.VERSION.SDK_INT < 29) return
        recordingCallback = object : AudioManager.AudioRecordingCallback() {
            // 仅关注本次采集，其他应用的空状态不误报。
            override fun onRecordingConfigChanged(configs: MutableList<AudioRecordingConfiguration>?) {
                if (!running || paused || ending) return
                // 当前采集会话被系统禁音时不能继续虚假增长时长。
                val current = configs?.firstOrNull { it.clientAudioSessionId == recorder?.audioSessionId }
                if (current?.isClientSilenced == true) finishRecording("麦克风被其他应用占用或系统关闭，已保存可用原音")
            }
        }
        audioManager.registerAudioRecordingCallback(recordingCallback!!, Handler(Looper.getMainLooper()))
    }

    // 持续通知携带原笔记入口和原生暂停/继续、结束操作。
    private fun notification(): Notification {
        // 原笔记返回 Intent，页面导航由 Flutter 收到稳定 ID 后完成。
        val returnIntent = Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra("recordingNoteId", metadata["noteId"] as? String)
        // 防止通知参数被其他应用更改。
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        // 返回同一笔记的通知点击句柄。
        val content = PendingIntent.getActivity(this, 8043, returnIntent, flags)
        // 本服务操作通知句柄。
        fun action(command: String, id: Int): PendingIntent = PendingIntent.getService(this, id,
            Intent(this, NoteRecordingService::class.java).setAction(command), flags)
        // 通知构建器兼容 API 23。
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else Notification.Builder(this)
        // 实际录音时长的可读秒数。
        val seconds = audioBytes / BYTES_PER_SECOND
        // 临近上限的通知提示不依赖 Flutter 后台调度。
        val remainingSeconds = (maxBytes - audioBytes) / BYTES_PER_SECOND
        return builder.setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle(if (paused) "笔记录音已暂停" else "笔记正在录音")
            .setContentText("${seconds / 60}:${(seconds % 60).toString().padStart(2, '0')} · 点击返回原笔记" +
                if (running && remainingSeconds <= 30) " · 即将达到时长上限" else "")
            .setContentIntent(content).setOngoing(true).setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .addAction(Notification.Action.Builder(null, if (paused) "继续" else "暂停", action(TOGGLE, 8044)).build())
            .addAction(Notification.Action.Builder(null, "结束并保存", action(STOP, 8045)).build())
            .build()
    }

    // 更新 WAV 容器长度，然后继续在数据尾部追加。
    private fun updateHeader() {
        output?.seek(0)
        output?.write(wavHeader(audioBytes.toInt()))
        output?.seek(44 + audioBytes)
    }

    // 固定格式 PCM WAV 头，强退后 Dart 也能重建相同结构。
    private fun wavHeader(bytes: Int): ByteArray {
        // 小端 WAV 字节容器。
        val buffer = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        buffer.put("RIFF".toByteArray()).putInt(bytes + 36).put("WAVEfmt ".toByteArray())
        buffer.putInt(16).putShort(1.toShort()).putShort(1.toShort()).putInt(SAMPLE_RATE)
        buffer.putInt(BYTES_PER_SECOND).putShort(2.toShort()).putShort(16.toShort())
        buffer.put("data".toByteArray()).putInt(bytes)
        return buffer.array()
    }

    // 释放所有设备资源；不删除原音或未确认恢复标记。
    private fun cleanup() {
        running = false
        try { recorder?.release() } catch (_: Exception) { }
        recorder = null
        try { output?.close() } catch (_: Exception) { }
        output = null
        wakeLock?.let { if (it.isHeld) it.release() }
        if (::audioManager.isInitialized) {
            recordingCallback?.let { audioManager.unregisterAudioRecordingCallback(it) }
            if (Build.VERSION.SDK_INT >= 26) focusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
            else { @Suppress("DEPRECATION") audioManager.abandonAudioFocus(focusListener) }
        }
        if (active === this) active = null
    }

    // 用户真正从最近任务退出时结束；锁屏和普通切应用不会触发该回调。
    override fun onTaskRemoved(rootIntent: Intent?) {
        finishRecording("应用退出，已保存可用原音")
        super.onTaskRemoved(rootIntent)
    }

    // 系统销毁服务的最后机会同步当前采样，重启仅发现恢复清单。
    override fun onDestroy() {
        // 系统主动销毁服务时仍向存活的 Flutter 引擎交付可恢复原音。
        val unexpected = !ending && active === this
        running = false
        try { recorder?.stop() } catch (_: Exception) { }
        try { synchronized(ioLock) { updateHeader(); output?.fd?.sync() } } catch (_: Exception) { }
        cleanup()
        if (unexpected) {
            if (audioBytes > 0) emit(metadata + mapOf("type" to "completed",
                "durationMs" to audioBytes * 1000 / BYTES_PER_SECOND, "reason" to "系统停止了录音服务，已保存可用原音"))
            else emit(metadata + mapOf("type" to "failed", "reason" to "系统停止了录音服务，请检查麦克风权限"))
        }
        super.onDestroy()
    }
}
