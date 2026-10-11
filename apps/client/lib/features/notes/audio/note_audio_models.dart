/// 当前采集状态；完成事件独立于页面生命周期。
enum NoteRecordingPhase { idle, starting, recording, paused, stopping, failed }

/// 录音原件及中断说明，落库成功后须确认恢复清单。
class NoteRecordingResult {
  /// 初始化不可变的原音元信息。
  const NoteRecordingResult({
    required this.id,
    required this.noteId,
    required this.path,
    required this.duration,
    required this.startedAt,
    this.interruptionReason,
    this.creationTimezone,
    this.mimeType = 'audio/wav',
  });

  /// 稳定的录音片段标识。
  final String id;

  /// 录音开始时绑定的笔记，浏览其他页不会更换。
  final String noteId;

  /// 私有目录中可播放的绝对路径。
  final String path;

  /// 实际采集时长，不包含暂停。
  final Duration duration;

  /// 录音开始的真实时刻。
  final DateTime startedAt;

  /// 采集开始时的设备时区与偏移，旧清单使用 legacy:unknown。
  final String? creationTimezone;

  /// 文件格式，当前统一为单声道 16 kHz PCM WAV。
  final String mimeType;

  /// 限额或系统中断原因；正常结束时为空。
  final String? interruptionReason;
}

/// 供页面和通知共享的录音快照。
class NoteRecordingState {
  /// 构造当前状态。
  const NoteRecordingState({
    this.phase = NoteRecordingPhase.idle,
    this.noteId,
    this.recordingId,
    this.duration = Duration.zero,
    this.limit = Duration.zero,
    this.error,
  });

  /// 当前状态机节点。
  final NoteRecordingPhase phase;

  /// 当前绑定的笔记。
  final String? noteId;

  /// 当前绑定的片段。
  final String? recordingId;

  /// 当前有效采集时长。
  final Duration duration;

  /// 本段实际限额，取单段和单篇剩余额度的较小者。
  final Duration limit;

  /// 可向用户展示的错误说明。
  final String? error;

  /// 正在采集、暂停及启停过渡期均占用设备。
  bool get isActive =>
      phase != NoteRecordingPhase.idle && phase != NoteRecordingPhase.failed;

  /// 上限前 30 秒由页面显示提示。
  bool get approachingLimit =>
      isActive &&
      limit > Duration.zero &&
      limit - duration <= const Duration(seconds: 30);
}
