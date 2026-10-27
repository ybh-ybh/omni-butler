import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/core/audio/microphone_coordinator.dart';
import 'package:omni_butler/core/auth/auth_models.dart';

import 'assistant_repository.dart';
import 'assistant_voice_transport.dart';

/// 两端共用的语音输入阶段。
enum AssistantVoicePhase { idle, preparing, recording, finishing }

/// 插件工厂可替换，界面测试不申请真实麦克风。
final assistantVoiceRecorderFactoryProvider =
    Provider<AssistantVoiceRecorder Function()>(
      (ref) => AssistantRecordVoice.new,
    );

/// 网络工厂可替换，测试不访问收费转写。
final assistantSpeechConnectorProvider =
    Provider<
      Future<AssistantSpeechConnection> Function(AssistantRepository, String)
    >((ref) => AssistantWebSocketSpeech.connect);

/// 每次识别固定草稿与身份；中间结果不能成为自动发送信号。
class AssistantVoiceController extends ChangeNotifier {
  /// 应用级设备占用。
  final MicrophoneCoordinator microphone;

  /// 恢复原生笔记录音状态后再申请占用。
  final Future<void> Function() beforeAcquire;

  /// 独立采集实例工厂。
  final AssistantVoiceRecorder Function() createRecorder;

  /// 固定当前来源的连接工厂。
  final Future<AssistantSpeechConnection> Function() connect;

  /// 同步当前可见文本和原会话草稿。
  final void Function(TextEditingValue) onText;

  /// 单次录音上限，测试可缩短。
  final Duration limit;

  /// 协议等待期限，测试可缩短。
  final Duration timeout;

  /// 当前界面阶段。
  AssistantVoicePhase phase = AssistantVoicePhase.idle;

  /// 当前可见提示，不含原始网络诊断。
  String? message;

  /// 当前实际录音时长。
  Duration elapsed = Duration.zero;

  /// 当前识别实例。
  _VoiceSession? _session;

  /// 多个生命周期入口共享正在进行的取消过程。
  Future<void>? _cancelling;

  /// 销毁后不再通知界面。
  bool _disposed = false;

  /// 注入采集和网络边界。
  AssistantVoiceController({
    required this.microphone,
    required this.beforeAcquire,
    required this.createRecorder,
    required this.connect,
    required this.onText,
    this.limit = const Duration(minutes: 5),
    this.timeout = const Duration(seconds: 10),
  });

  /// 收尾期间保持输入冻结，防止最后一句覆盖键盘输入。
  bool get busy => phase != AssistantVoicePhase.idle;

  /// 清晰区分连接、采集和等待最终结果。
  String? get status => switch (phase) {
    AssistantVoicePhase.preparing => '正在连接语音服务…',
    AssistantVoicePhase.recording =>
      '正在录音 ${elapsed.inMinutes.toString().padLeft(2, '0')}:${(elapsed.inSeconds % 60).toString().padLeft(2, '0')}，点击麦克风结束',
    AssistantVoicePhase.finishing => '正在完成转写…',
    AssistantVoicePhase.idle => message,
  };

  /// 当前来源、会话和页面都仍有效。
  bool _live(_VoiceSession session) =>
      !_disposed &&
      identical(_session, session) &&
      !session.terminal &&
      session.isCurrent();

  /// 只在组件仍存活时重绘。
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// 固定选区，未选择时从光标插入；无有效光标时追加。
  Future<void> start({
    required TextEditingValue initial,
    required bool autoSend,
    required bool Function() isCurrent,
    required Future<void> Function() send,
  }) async {
    if (busy || _disposed) return;
    // 本次录音身份不与聊天ID复用。
    final _VoiceSession session = _VoiceSession(
      initial,
      autoSend,
      isCurrent,
      send,
      createRecorder(),
    );
    _session = session;
    message = null;
    elapsed = Duration.zero;
    phase = AssistantVoicePhase.preparing;
    _changed();
    session.startup = _prepare(session);
    try {
      await session.startup;
      if (identical(_session, session) && !session.isCurrent()) await cancel();
    } catch (error) {
      await _fail(
        session,
        error is ApiFailure ? error.message : '无法开始语音输入，请检查麦克风和网络',
      );
    }
  }

  /// 上游应用握手就绪之后才打开采样设备。
  Future<void> _prepare(_VoiceSession session) async {
    await beforeAcquire();
    if (!_live(session)) return;
    if (!microphone.tryAcquire(session)) throw const ApiFailure('请先结束当前笔记录音');
    session.acquired = true;
    if (!await session.recorder.hasPermission()) {
      throw const ApiFailure('麦克风权限未开启，请在系统设置允许录音');
    }
    if (!_live(session)) return;
    session.connection = await connect();
    if (!_live(session)) return;
    session.events = session.connection!.events.listen(
      (Map<String, dynamic> event) => _event(session, event),
      onError: (Object _) => _networkFailed(session),
      onDone: () => _networkFailed(session),
    );
    await session.ready.future.timeout(timeout);
    if (!_live(session)) return;
    // 权限返回和网络就绪后再次核实页面，取消不能迟到开麦。
    final Stream<Uint8List> stream = await session.recorder.start();
    if (!_live(session)) return;
    session.clock.start();
    session.lastAudio = DateTime.now();
    phase = AssistantVoicePhase.recording;
    session.audio = stream.listen(
      (Uint8List bytes) => _audio(session, bytes),
      onError: (Object _) => unawaited(_fail(session, '麦克风采集已中断，已保留可用文字')),
      onDone: () {
        if (_live(session) && !session.ending) {
          unawaited(_fail(session, '麦克风采集已中断，已保留可用文字'));
        }
      },
    );
    session.pump = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!_live(session)) {
        unawaited(cancel());
        return;
      }
      elapsed = session.clock.elapsed;
      _changed();
      if (elapsed >= limit) {
        unawaited(finish(manual: false));
        return;
      }
      if (DateTime.now().difference(session.lastAudio) >
          const Duration(seconds: 5)) {
        unawaited(_fail(session, '麦克风采集超时，已保留可用文字'));
        return;
      }
      if (!session.sending && session.buffer.length >= 6400) {
        session.write = _sendPacket(session);
        unawaited(
          session.write!.catchError(
            (Object _) => _fail(session, '音频发送失败，已保留可用文字'),
          ),
        );
      }
    });
    _changed();
  }

  /// 音频仅保存在有界发送缓冲，不持久化原件。
  void _audio(_VoiceSession session, Uint8List bytes) {
    if (!_live(session)) return;
    session.lastAudio = DateTime.now();
    if (session.buffer.length + bytes.length > 65536) {
      unawaited(_fail(session, '语音网络发送过慢，请检查连接后重试'));
      return;
    }
    session.buffer.addAll(bytes);
  }

  /// 每包最多200ms音频，保留16-bit采样边界。
  Future<void> _sendPacket(_VoiceSession session) async {
    if (!_live(session) || session.sending || session.buffer.length < 2) return;
    session.sending = true;
    // 最后一包也必须包含完整采样。
    final int count = (session.buffer.length.clamp(0, 6400) ~/ 2) * 2;
    // 在等待网络前移出本包，后来的采样仍写到原缓冲。
    final Uint8List bytes = Uint8List.fromList(
      session.buffer.sublist(0, count),
    );
    session.buffer.removeRange(0, count);
    try {
      await session.connection!.sendAudio(bytes);
    } finally {
      session.sending = false;
    }
  }

  /// 手动结束只提交结束标记，最终事件才能解除输入锁。
  Future<void> finish({bool manual = true}) async {
    // 固定本次操作对象，后续取消不能误操作下一次录音。
    final _VoiceSession? session = _session;
    if (session == null ||
        !_live(session) ||
        session.ending ||
        phase != AssistantVoicePhase.recording) {
      return;
    }
    session.ending = true;
    session.manual = manual;
    session.pump?.cancel();
    session.clock.stop();
    phase = AssistantVoicePhase.finishing;
    _changed();
    try {
      await session.recorder.stop();
      session.deviceReleased = true;
      await session.audio?.cancel();
      session.audio = null;
      microphone.release(session);
      session.acquired = false;
      await session.write;
      while (_live(session) && session.buffer.length >= 2) {
        await _sendPacket(session);
        if (session.buffer.length >= 2) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
      if (!_live(session)) return;
      session.connection!.finish(manual: manual);
      session.finalWait = Timer(
        timeout,
        () => unawaited(_fail(session, '等待最终转写超时，已保留可用文字，请检查后发送')),
      );
    } catch (_) {
      await _fail(session, '语音输入未能完整结束，已保留可用文字');
    }
  }

  /// 中间结果按整段替换，避免相同句子重复追加。
  void _transcript(_VoiceSession session, String text) {
    if (!_live(session)) return;
    if (text.length > 20000) {
      unawaited(_fail(session, '语音文字超过长度限制，已保留可用文字'));
      return;
    }
    if (text.isEmpty) {
      session.text = text;
      onText(session.initial);
      return;
    }
    // 非法或未初始化选区按末尾插入处理。
    final TextSelection selection = session.initial.selection;
    // 起始偏移在录音开始时固定。
    final int start = selection.isValid
        ? selection.start.clamp(0, session.initial.text.length)
        : session.initial.text.length;
    // 结束偏移允许替换原选中文字。
    final int end = selection.isValid
        ? selection.end.clamp(start, session.initial.text.length)
        : start;
    // 每次从原草稿重建，只替换语音对应区段。
    final String merged = session.initial.text.replaceRange(start, end, text);
    if (merged.length > 20000) {
      unawaited(_fail(session, '合并后的文字超过20000字限制，已保留此前草稿，请缩短后重试'));
      return;
    }
    session.text = text;
    onText(
      TextEditingValue(
        text: merged,
        selection: TextSelection.collapsed(offset: start + text.length),
      ),
    );
  }

  /// 只识别协议内事件，不把socket关闭当作成功。
  void _event(_VoiceSession session, Map<String, dynamic> event) {
    if (!_live(session)) return;
    switch (event['type']) {
      case 'ready':
        if (!session.ready.isCompleted) session.ready.complete();
      case 'transcript':
        if (event['text'] is String) {
          _transcript(session, event['text'] as String);
        } else {
          unawaited(_fail(session, '语音服务返回无效转写'));
        }
      case 'completed':
        if (event['text'] is! String ||
            (!session.ending && event['reason'] != 'limit')) {
          unawaited(_fail(session, '语音服务提前结束，已保留可用文字'));
          return;
        }
        _transcript(session, event['text'] as String);
        if (_live(session)) {
          unawaited(_complete(session, event['reason'] == 'manual'));
        }
      case 'error':
        // 只将固定错误码映射为本机文案，不展示未经筛选的云端消息。
        final String description = switch (event['code']) {
          'ASR_NOT_CONFIGURED' => '语音服务尚未配置，请检查腾讯云 AppId 和密钥',
          'ASR_AUTH_FAILED' => '语音服务鉴权失败，请检查腾讯云配置',
          'ASR_CONCURRENCY_LIMIT' => '已有语音输入进行中，请稍后重试',
          'ASSISTANT_SPEECH_UNAUTHORIZED' => '设备连接已失效，请重新连接服务器',
          'ASSISTANT_SPEECH_FINAL_TIMEOUT' => '等待最终转写超时，已保留可用文字，请检查后发送',
          'ASSISTANT_SPEECH_TIMEOUT' => '连接语音服务超时，请检查网络和腾讯云配置',
          'ASSISTANT_SPEECH_AUDIO_TIMEOUT' => '音频采集或上传已中断，已保留可用文字',
          'ASSISTANT_SPEECH_BACKPRESSURE' => '语音网络发送过慢，请检查连接后重试',
          'ASSISTANT_SPEECH_PROVIDER_ERROR' => '腾讯云识别失败，请检查语音服务开通状态、密钥权限及余额',
          _ => '语音识别失败，已保留可用文字，请检查服务配置或网络',
        };
        if (!session.ready.isCompleted) {
          session.ready.completeError(ApiFailure(description));
        }
        unawaited(_fail(session, description));
      default:
        unawaited(_fail(session, '语音服务协议不兼容，请更新服务器'));
    }
  }

  /// 握手期间也使等待立即失败，避免无意义等待到超时。
  void _networkFailed(_VoiceSession session) {
    if (!_live(session)) return;
    if (!session.ready.isCompleted) {
      session.ready.completeError(const ApiFailure('语音连接已断开'));
    }
    unawaited(_fail(session, '语音连接已断开，已保留可用文字，请检查后发送'));
  }

  /// 完成后先停麦清理，再按原会话条件执行一次发送。
  Future<void> _complete(_VoiceSession session, bool serverManual) async {
    if (!_live(session)) return;
    session.terminal = true;
    session.finalWait?.cancel();
    await _cleanup(session);
    if (!identical(_session, session) || _disposed) return;
    _session = null;
    phase = AssistantVoicePhase.idle;
    message = session.text.trim().isEmpty
        ? '未识别到文字，请重试'
        : (!serverManual ? '已达到单次录音上限，请检查文字后发送' : null);
    if (!session.deviceReleased) message = '麦克风未能释放，请重启应用后再录音；文字已保留';
    _changed();
    if (session.manual &&
        serverManual &&
        session.autoSend &&
        session.deviceReleased &&
        session.text.trim().isNotEmpty &&
        session.isCurrent()) {
      try {
        await session.send();
      } catch (_) {
        message = '自动发送未完成，已保留草稿，请检查后发送';
        _changed();
      }
    }
  }

  /// 异常仅保留文字，永远不自动发送。
  Future<void> _fail(_VoiceSession session, String description) async {
    if (!identical(_session, session) || session.terminal) return;
    session.terminal = true;
    message = description;
    await _cleanup(session);
    if (!identical(_session, session)) return;
    _session = null;
    phase = AssistantVoicePhase.idle;
    if (!session.deviceReleased) message = '麦克风未能释放，请重启应用后再录音；文字已保留';
    _changed();
  }

  /// 导航取消同步使事件失效，收尾不再写任何草稿。
  Future<void> cancel() {
    if (_cancelling != null) return _cancelling!;
    // 同一对象即使已完成事件也需清理，禁止完成后的迟到发送。
    final _VoiceSession? session = _session;
    if (session == null) return Future<void>.value();
    _session = null;
    session.terminal = true;
    session.manual = false;
    if (!session.ready.isCompleted) session.ready.complete();
    phase = AssistantVoicePhase.finishing;
    _changed();
    _cancelling = _cleanup(session)
        .then((_) {
          if (_session != null) return;
          phase = AssistantVoicePhase.idle;
          message = session.text.isEmpty ? null : '语音输入已中止，已保留文字，请检查后发送';
          if (!session.deviceReleased) message = '麦克风未能释放，请重启应用后再录音；文字已保留';
          _changed();
        })
        .whenComplete(() => _cancelling = null);
    return _cancelling!;
  }

  /// 等待迟到启动收尾后才释放设备，清理操作可安全重复。
  Future<void> _cleanup(_VoiceSession session) => session.cleanup ??= () async {
    session.pump?.cancel();
    session.finalWait?.cancel();
    try {
      await session.startup;
    } catch (_) {}
    try {
      await session.recorder.stop();
      session.deviceReleased = true;
    } catch (_) {}
    try {
      await session.audio?.cancel();
    } catch (_) {}
    try {
      await session.write;
    } catch (_) {}
    try {
      session.connection?.cancel();
    } catch (_) {}
    try {
      await session.events?.cancel();
    } catch (_) {}
    try {
      await session.connection?.close();
    } catch (_) {}
    try {
      await session.recorder.dispose();
      session.deviceReleased = true;
    } catch (_) {}
    if (session.acquired && session.deviceReleased) {
      microphone.release(session);
      session.acquired = false;
    }
    session.buffer.clear();
  }();

  /// 页面销毁立即隔离回调，异步清理仍会完成。
  @override
  void dispose() {
    _disposed = true;
    unawaited(cancel());
    super.dispose();
  }
}

/// 私有录音资源按实例隔离，旧清理不能释放新麦克风。
class _VoiceSession {
  /// 原输入快照。
  final TextEditingValue initial;

  /// 本次开始时固定的本机偏好。
  final bool autoSend;

  /// 页面和来源有效性检查。
  final bool Function() isCurrent;

  /// 原有消息发送入口。
  final Future<void> Function() send;

  /// 独立采集资源。
  final AssistantVoiceRecorder recorder;

  /// 当前上游连接。
  AssistantSpeechConnection? connection;

  /// 应用握手完成信号。
  final Completer<void> ready = Completer<void>();

  /// 设备启动完成后才允许释放占用。
  Future<void>? startup;

  /// 幂等资源清理。
  Future<void>? cleanup;

  /// 当前在途网络发送。
  Future<void>? write;

  /// 已取得设备占用。
  bool acquired = false;

  /// 原生停止或销毁成功后才允许释放应用级占用。
  bool deviceReleased = false;

  /// 已进入终态，不再接受事件。
  bool terminal = false;

  /// 正在排空并结束。
  bool ending = false;

  /// 仅用户主动结束允许自动发送。
  bool manual = false;

  /// 避免并行向socket写入流。
  bool sending = false;

  /// 完整当前识别文本。
  String text = '';

  /// 最多64KiB暂存音频。
  final List<int> buffer = <int>[];

  /// 单调录音时钟。
  final Stopwatch clock = Stopwatch();

  /// 最近采样时刻，用于设备断流检测。
  DateTime lastAudio = DateTime.now();

  /// 音频订阅。
  StreamSubscription<Uint8List>? audio;

  /// 转写订阅。
  StreamSubscription<Map<String, dynamic>>? events;

  /// 实时分包及计时。
  Timer? pump;

  /// 结束后的最终结果等待。
  Timer? finalWait;

  /// 建立单次资源归属。
  _VoiceSession(
    this.initial,
    this.autoSend,
    this.isCurrent,
    this.send,
    this.recorder,
  );
}
