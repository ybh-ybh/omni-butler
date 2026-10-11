import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import 'note_audio_models.dart';
import 'note_audio_player_service.dart';
import 'note_wav.dart';

export 'note_audio_models.dart';

/// 注入应用级容器的录音服务，不随路由销毁。原件落库后调用 acknowledge。
class NoteRecorderService {
  /// 可替换存储根目录和原生通道，测试不需要真实麦克风。
  NoteRecorderService({
    required this.player,
    Future<Directory> Function()? directoryResolver,
    AudioRecorder? recorder,
    MethodChannel? channel,
    EventChannel? events,
    bool? android,
  }) : _directoryResolver = directoryResolver ?? _defaultDirectory,
       // 保留公开参数recorder，不将私有字段暴露为参数名。
       // ignore: prefer_initializing_formals
       _recorder = recorder,
       _channel = channel ?? const MethodChannel('omni_butler/notes_recording'),
       _events =
           events ?? const EventChannel('omni_butler/notes_recording_events'),
       _android = android ?? Platform.isAndroid {
    player.recordingActive = () => state.isActive;
  }

  /// 两端单段上限。
  static const Duration segmentLimit = Duration(minutes: 30);

  /// 调用方计算笔记已保存片段后传入剩余额度。
  static const Duration noteLimit = Duration(minutes: 60);

  /// 共享的原音播放器。
  final NoteAudioPlayerService player;

  /// 私有目录解析器，允许与数据源目录隔离。
  final Future<Directory> Function() _directoryResolver;

  /// Windows 麦克风 PCM 采集插件。
  AudioRecorder? _recorder;

  /// Android 原生命令桥。
  final MethodChannel _channel;

  /// Android 服务状态桥。
  final EventChannel _events;

  /// 当前是否使用原生前台服务。
  final bool _android;

  /// 当前状态快照。
  NoteRecordingState state = const NoteRecordingState();

  /// 页面共享状态广播。
  final StreamController<NoteRecordingState> _states =
      StreamController.broadcast();

  /// 原生通知、达到限额、正常结束均走同一完成流。
  final StreamController<NoteRecordingResult> _completed =
      StreamController.broadcast();

  /// 通知返回笔记时提供原始笔记 ID。
  final StreamController<String> _returnRequests = StreamController.broadcast();

  /// 广播流订阅。
  StreamSubscription<dynamic>? _nativeSubscription;

  /// Windows 音频流订阅。
  StreamSubscription<Uint8List>? _audioSubscription;

  /// Windows 采集状态订阅，用于发现设备被中断。
  StreamSubscription<RecordState>? _recordSubscription;

  /// 当前活动文件句柄。
  RandomAccessFile? _file;

  /// 当前原音恢复记录。
  Map<String, dynamic>? _session;

  /// 串行采样写入，不能让异步写盘互相覆盖。
  Future<void> _writes = Future.value();

  /// 串行用户命令，快速连点不重复打开设备。
  Future<void> _commands = Future.value();

  /// 已接收 PCM 数据长度。
  int _audioBytes = 0;

  /// 当前允许 PCM 最大长度。
  int _maxBytes = 0;

  /// 最近一次同步刷新时间。
  DateTime _lastFlush = DateTime.fromMillisecondsSinceEpoch(0);

  /// 最近有效采集时刻，用于 Windows 设备休眠或采集卡死检测。
  DateTime _lastPacket = DateTime.now();

  /// 即使设备不再回调，也能发现采集停滞。
  Timer? _watchdog;

  /// 已成功交付的结果，避免 stop 与事件桥重复回调。
  final Map<String, NoteRecordingResult> _finished = {};

  /// 初始化复用的异步结果。
  Future<void>? _initialization;

  /// Windows 关闭流程标记，避免正常 stop 被当作系统中断。
  bool _stopping = false;

  /// 状态变化广播；首次绘制使用 state。
  Stream<NoteRecordingState> get states => _states.stream;

  /// 原音完成广播，消费者持久化后必须 acknowledge。
  Stream<NoteRecordingResult> get completed => _completed.stream;

  /// Android 录音通知的“返回笔记”入口。
  Stream<String> get returnRequests => _returnRequests.stream;

  /// 建立事件桥，不申请麦克风权限也不自动录音。
  Future<void> initialize() => _initialization ??= _initialize();

  /// 初始化平台事件和恢复目录。
  Future<void> _initialize() async {
    await (await _directoryResolver()).create(recursive: true);
    if (_android) {
      _nativeSubscription = _events.receiveBroadcastStream().listen(
        _nativeEvent,
        onError: (Object error) => _publish(
          NoteRecordingState(
            phase: NoteRecordingPhase.failed,
            error: '录音服务连接异常：$error',
          ),
        ),
      );
    }
  }

  /// 实际请求采集才创建Windows设备，恢复清单仅访问磁盘。
  AudioRecorder _ensureRecorder() {
    // 保持同一设备与注入替身，页面预载不会到达这里。
    final AudioRecorder recorder = _recorder ??= AudioRecorder();
    _recordSubscription ??= recorder.onStateChanged().listen(
      (value) {
        if (value == RecordState.stop && state.isActive && !_stopping) {
          unawaited(_serial(() => _stop('麦克风采集中断，已保存可用原音')));
        }
      },
      onError: (Object error) {
        if (state.isActive && !_stopping) {
          unawaited(_serial(() => _stop('麦克风状态异常，已保存可用原音：$error')));
        }
      },
    );
    return recorder;
  }

  /// 用户主动开始录音，remaining 由持久化笔记累计时长计算。
  Future<void> start(String noteId, {Duration remaining = noteLimit}) =>
      _serial(() async {
        await initialize();
        if (state.isActive) throw StateError('已有录音进行中，请先结束当前录音');
        if (noteId.trim().isEmpty) throw ArgumentError('笔记标识不能为空');
        // 取每段上限、每篇总额和剩余额度的最小值。
        final limit = Duration(
          microseconds: min(
            segmentLimit.inMicroseconds,
            min(noteLimit.inMicroseconds, remaining.inMicroseconds),
          ),
        );
        if (limit <= Duration.zero) throw StateError('这篇笔记录音已达到 60 分钟上限');
        _publish(
          NoteRecordingState(
            phase: NoteRecordingPhase.starting,
            noteId: noteId,
            limit: limit,
          ),
        );
        try {
          await player.stop();
          // 按开始时刻生成不可变的片段标识。
          final id = const Uuid().v4();
          // 稳定的私有文件目录。
          final directory = await _directoryResolver();
          // 同目录原件路径，不使用外部可写公共目录。
          final path = p.join(directory.path, '$id.wav');
          // 开始瞬间固定本机时区，恢复不能冒用恢复时的设备时区。
          final DateTime startedAt = DateTime.now();
          // 未确认清单在真正开始采集前写盘。
          final session = <String, dynamic>{
            'id': id,
            'noteId': noteId,
            'path': path,
            'startedAt': startedAt.toUtc().toIso8601String(),
            'creationTimezone': _creationTimezone(startedAt),
            'limitMs': limit.inMilliseconds,
          };
          await File(p.join(directory.path, '$id.pending.json'))
              .writeAsString(jsonEncode(session), flush: true);
          _session = session;
          _audioBytes = 0;
          _maxBytes =
              limit.inMicroseconds * NoteWav.bytesPerSecond ~/ 1000000 ~/ 2 * 2;
          _stopping = false;
          _lastPacket = DateTime.now();
          if (_android) {
            await _channel.invokeMethod<void>('start', session);
          } else {
            if (!await _ensureRecorder().hasPermission()) {
              throw StateError('麦克风权限未开启，请在系统设置允许录音');
            }
            _file = await File(path).open(mode: FileMode.write);
            await _file!.writeFrom(NoteWav.header(0));
            await _file!.flush();
            // Windows 流模式让文件逐步落盘，而不依赖结束时编码封装。
            final stream = await _ensureRecorder().startStream(
              const RecordConfig(
                encoder: AudioEncoder.pcm16bits,
                sampleRate: NoteWav.sampleRate,
                numChannels: 1,
              ),
            );
            _audioSubscription = stream.listen(
              _writeAudio,
              onError: (Object error) =>
                  unawaited(_serial(() => _stop('麦克风采集失败：$error'))),
              onDone: () {
                if (state.isActive && !_stopping) {
                  unawaited(_serial(() => _stop('麦克风采集已中断')));
                }
              },
            );
            _publish(
              NoteRecordingState(
                phase: NoteRecordingPhase.recording,
                noteId: noteId,
                recordingId: id,
                limit: limit,
              ),
            );
            _watchdog?.cancel();
            _watchdog = Timer.periodic(const Duration(seconds: 1), (_) {
              if (state.phase == NoteRecordingPhase.recording &&
                  !_stopping &&
                  DateTime.now().difference(_lastPacket) >
                      const Duration(seconds: 5)) {
                _stopping = true;
                unawaited(_serial(() => _stop('设备休眠或麦克风采集停滞，已保存可用原音')));
              }
            });
          }
        } catch (error) {
          // 启动失败也保留可能已有的原音供下次恢复。
          if (_file != null) {
            await _file!.close();
            _file = null;
          }
          _publish(
            NoteRecordingState(
              phase: NoteRecordingPhase.failed,
              error: '$error',
            ),
          );
          rethrow;
        }
      });

  /// 暂停采集，原生及插件均停止增加采样字节。
  Future<void> pause() => _serial(() async {
    if (state.phase != NoteRecordingPhase.recording) return;
    if (_android) {
      await _channel.invokeMethod<void>('pause');
    } else {
      await _recorder?.pause();
      _publish(_snapshot(NoteRecordingPhase.paused));
    }
  });

  /// 继续同一段录音，不增加暂停时间。
  Future<void> resume() => _serial(() async {
    if (state.phase != NoteRecordingPhase.paused) return;
    await player.stop();
    if (_android) {
      await _channel.invokeMethod<void>('resume');
    } else {
      await _recorder?.resume();
      _lastPacket = DateTime.now();
      _publish(_snapshot(NoteRecordingPhase.recording));
    }
  });

  /// 结束录音并返回真实文件；零字节录音返回空。
  Future<NoteRecordingResult?> stop({String? reason}) =>
      _serial(() => _stop(reason));

  /// 平台停止逻辑，接收自动结束与主动结束。
  Future<NoteRecordingResult?> _stop(String? reason) async {
    if (!state.isActive || _session == null) return null;
    _stopping = true;
    _watchdog?.cancel();
    _watchdog = null;
    _publish(_snapshot(NoteRecordingPhase.stopping));
    if (_android) {
      // 原生方法会等待采样线程结束及文件落盘。
      final value = await _channel.invokeMapMethod<String, dynamic>('stop', {
        'reason': reason,
      });
      if (value != null) return _acceptResult(value);
      _publish(const NoteRecordingState());
      return null;
    }
    // 尽可能停止设备；设备已被撤销时仍修复磁盘原音。
    try {
      await _recorder?.stop();
    } catch (_) {
      reason ??= '麦克风中断，已保存可用原音';
    }
    await _audioSubscription?.cancel();
    _audioSubscription = null;
    await _writes;
    await _file?.flush();
    await _file?.close();
    _file = null;
    // 原件以真实样本长度补齐头部。
    final duration = await NoteWav.repair(File(_session!['path'] as String));
    if (duration == null) {
      _publish(const NoteRecordingState());
      return null;
    }
    return _acceptResult({
      ..._session!,
      'durationMs': duration.inMilliseconds,
      'reason': reason,
    });
  }

  /// PCM 流串行写盘与限额；即使页面离开仍继续采集。
  void _writeAudio(Uint8List bytes) {
    if (state.phase == NoteRecordingPhase.paused) return;
    if (!_stopping &&
        state.phase == NoteRecordingPhase.recording &&
        DateTime.now().difference(_lastPacket) > const Duration(seconds: 5)) {
      _stopping = true;
      unawaited(_serial(() => _stop('设备休眠或麦克风采集停滞，已保存可用原音')));
      return;
    }
    _lastPacket = DateTime.now();
    _writes = _writes
        .then((_) async {
          if (_file == null || _audioBytes >= _maxBytes) return;
          // 本批只写限额内的完整采样。
          final count = min(bytes.length, _maxBytes - _audioBytes) ~/ 2 * 2;
          if (count == 0) return;
          await _file!.writeFrom(bytes, 0, count);
          _audioBytes += count;
          // 每秒刷新数据；恢复直接使用文件大小补全文件头。
          final now = DateTime.now();
          if (now.difference(_lastFlush) >= const Duration(seconds: 1)) {
            await _file!.flush();
            _lastFlush = now;
            _publish(_snapshot(state.phase));
          }
          if (_audioBytes >= _maxBytes && !_stopping) {
            _stopping = true;
            unawaited(_serial(() => _stop('已达到本段或本篇录音时长上限')));
          }
        })
        .catchError((Object error) {
          if (!_stopping) {
            _stopping = true;
            unawaited(_serial(() => _stop('录音写入失败：$error')));
          }
        });
  }

  /// 从原生采样线程接收状态，完成和返回请求。
  void _nativeEvent(dynamic raw) {
    if (raw is! Map) return;
    // 仅接收本机通道结构。
    final event = Map<String, dynamic>.from(raw);
    if (event['type'] == 'return') {
      if (event['noteId'] is String) {
        _returnRequests.add(event['noteId'] as String);
      }
      return;
    }
    if (event['type'] == 'completed') {
      _acceptResult(event);
      return;
    }
    if (event['type'] == 'failed') {
      _publish(
        NoteRecordingState(
          phase: NoteRecordingPhase.failed,
          error: event['reason'] as String?,
        ),
      );
      return;
    }
    if (event['type'] == 'state') {
      if (event['id'] is String && event['path'] is String) {
        _session = event;
      }
      // 原生服务状态是后台/锁屏采集的权威来源。
      final phase = switch (event['phase']) {
        'recording' => NoteRecordingPhase.recording,
        'paused' => NoteRecordingPhase.paused,
        'stopping' => NoteRecordingPhase.stopping,
        _ => NoteRecordingPhase.idle,
      };
      _publish(
        NoteRecordingState(
          phase: phase,
          noteId: event['noteId'] as String?,
          recordingId: event['id'] as String?,
          duration: Duration(
            milliseconds: (event['durationMs'] as num?)?.toInt() ?? 0,
          ),
          limit: Duration(
            milliseconds: (event['limitMs'] as num?)?.toInt() ?? 0,
          ),
        ),
      );
    }
  }

  /// 消费完成事件，并以稳定 ID 去重。
  NoteRecordingResult? _acceptResult(Map<String, dynamic> value) {
    // 迟到的上一段完成事件不能清空新一段的活动状态。
    final id = value['id'] as String;
    if (_finished.containsKey(id)) return _finished[id];
    // 非正常服务销毁时可能没有有效采样。
    final durationMs = (value['durationMs'] as num?)?.toInt() ?? 0;
    if (state.recordingId == id || state.recordingId == null) {
      _publish(const NoteRecordingState());
    }
    if (durationMs <= 0) return null;
    // 已交付片段返回同一个对象，不重复发转写任务。
    // 原始开始时间不因通知结束而变化。
    final result = NoteRecordingResult(
      id: id,
      noteId: value['noteId'] as String,
      path: value['path'] as String,
      duration: Duration(milliseconds: durationMs),
      startedAt: DateTime.parse(value['startedAt'] as String),
      creationTimezone:
          value['creationTimezone'] as String? ?? 'legacy:unknown',
      interruptionReason: value['reason'] as String?,
    );
    _finished[id] = result;
    _completed.add(result);
    return result;
  }

  /// 构造 Windows 状态，时长来自采样数量。
  NoteRecordingState _snapshot(NoteRecordingPhase phase) => NoteRecordingState(
    phase: phase,
    noteId: _session?['noteId'] as String?,
    recordingId: _session?['id'] as String?,
    duration: Duration(
      microseconds: _audioBytes * 1000000 ~/ NoteWav.bytesPerSecond,
    ),
    limit: Duration(milliseconds: (_session?['limitMs'] as int?) ?? 0),
  );

  /// 发布快照。
  void _publish(NoteRecordingState next) {
    state = next;
    _states.add(next);
  }

  /// 串行运行用户命令，不让一次失败阻塞后续重试。
  Future<T> _serial<T>(Future<T> Function() action) {
    // 向调用方保留真实成功或失败结果。
    final result = _commands.then((_) => action());
    _commands = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// 应用启动后扫描未落库原音，不自动重新开启麦克风。
  Future<List<NoteRecordingResult>> recoverPending() => _serial(() async {
    await initialize();
    // 当前目录的未确认清单。
    final directory = await _directoryResolver();
    // 返回顺序按开始时间排列，调用方决定恢复到原笔记或另存。
    final results = <NoteRecordingResult>[];
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! File || !entry.path.endsWith('.pending.json')) continue;
      try {
        // 清单只可指向录音私有目录。
        final session =
            jsonDecode(await entry.readAsString()) as Map<String, dynamic>;
        if (session['id'] == state.recordingId) continue;
        // 永久删除标记先于原件清理落盘，失败原件不能通过恢复复活。
        final String noteId = session['noteId'] as String;
        final File marker = _deletionMarker(directory, noteId);
        if (await marker.exists()) {
          // 标记损坏时保守保留文件，但仍禁止恢复该笔记。
          final Set<String>? protected = await _readProtectedPaths(
            marker,
            noteId,
          );
          if (protected != null) {
            await _discardManifest(entry, session, directory, protected);
          }
          continue;
        }
        // 校验原件路径防止损坏清单写入其他文件。
        final path = session['path'] as String;
        if (p.dirname(p.normalize(path)) != p.normalize(directory.path)) {
          continue;
        }
        // 修复中断时尚未更新的 WAV 长度字段。
        final duration = await NoteWav.repair(File(path));
        if (duration == null) continue;
        results.add(
          NoteRecordingResult(
            id: session['id'] as String,
            noteId: session['noteId'] as String,
            path: path,
            duration: duration,
            startedAt: DateTime.parse(session['startedAt'] as String),
            creationTimezone:
                session['creationTimezone'] as String? ?? 'legacy:unknown',
            interruptionReason: '恢复上次未确认保存的录音，请检查原音',
          ),
        );
      } on FileSystemException {
        continue;
      } on FormatException {
        continue;
      } on TypeError {
        continue;
      }
    }
    await _retryDeletionMarkers(directory);
    results.sort((a, b) => a.startedAt.compareTo(b.startedAt));
    return results;
  });

  /// 仓储明确永久删除后写标记并清候选，不根据数据库缺行推断删除。
  Future<void> discardPendingForNote(
    String noteId, {
    Set<String> protectedPaths = const {},
  }) => _serial(() async {
    if (noteId.trim().isEmpty) throw ArgumentError('笔记标识不能为空');
    // 当前数据源私有目录，不初始化任何音频设备或事件通道。
    final Directory directory = await _directoryResolver();
    await directory.create(recursive: true);
    // UUID派生名称不使用用户文本作为文件路径。
    final File marker = _deletionMarker(directory, noteId);
    // 保留此前明确保护的另存引用，重启清理不能丢掉保护关系。
    final Set<String> protected = {
      ...?await _readProtectedPaths(marker, noteId),
      ...protectedPaths.map(p.normalize),
    };
    // 删除清单前保存原件路径，原件删除失败后重启仍能继续清理。
    final Set<String> pendingPaths = {
      ...?await _readDeletionPaths(marker, noteId, 'pendingPaths'),
    };
    // 先只读收集安全清单，不在删除事实落盘前做任何删除。
    final List<(File, Map<String, dynamic>)> candidates = [];
    await for (final FileSystemEntity entry in directory.list(
      followLinks: false,
    )) {
      if (entry is! File || !entry.path.endsWith('.pending.json')) continue;
      try {
        // 清单内容损坏或跨目录时不记录可删原件。
        final Map<String, dynamic> session =
            jsonDecode(await entry.readAsString()) as Map<String, dynamic>;
        if (session['noteId'] != noteId) continue;
        // 只有当前source同目录的绝对路径才进入删除标记。
        final String? path = _ownedAudioPath(directory, session['path']);
        if (path == null) continue;
        pendingPaths.add(path);
        candidates.add((entry, session));
      } on FileSystemException {
        continue;
      } on FormatException {
        continue;
      } on TypeError {
        continue;
      }
    }
    // 完整标记先flush再rename，清理失败仍有持久删除事实。
    final File temporary = File('${marker.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'noteId': noteId,
        'protectedPaths': protected.toList()..sort(),
        'pendingPaths': pendingPaths.toList()..sort(),
      }),
      flush: true,
    );
    await temporary.rename(marker.path);
    // 尽量清理全部匹配片段，首个错误最后反馈，标记始终保留。
    FileSystemException? failure;
    for (final (File, Map<String, dynamic>) candidate in candidates) {
      try {
        await _discardManifest(
          candidate.$1,
          candidate.$2,
          directory,
          protected,
        );
      } on FileSystemException catch (error) {
        failure ??= error;
      }
    }
    if (failure != null) throw failure;
  });

  /// 完成流与恢复流共用永久删除门禁，只访问当前数据源磁盘标记。
  Future<bool> isPermanentlyDiscarded(String noteId) async {
    if (noteId.trim().isEmpty) return false;
    return _deletionMarker(await _directoryResolver(), noteId).exists();
  }

  /// 生成稳定安全的删除标记名称，不包含笔记ID原文。
  File _deletionMarker(Directory directory, String noteId) => File(
    p.join(
      directory.path,
      '${const Uuid().v5(Namespace.url.value, 'notes-deleted:$noteId')}.deleted.json',
    ),
  );

  /// 读取持久保护关系，坏标记不自动推断可删原件。
  Future<Set<String>?> _readProtectedPaths(File marker, String noteId) =>
      _readDeletionPaths(marker, noteId, 'protectedPaths');

  /// 删除标记中保留保护引用与尚待清理的原件，不相信损坏字段。
  Future<Set<String>?> _readDeletionPaths(
    File marker,
    String noteId,
    String field,
  ) async {
    try {
      if (!await marker.exists()) return null;
      // 标记身份必须与派生路径对应。
      final Map<String, dynamic> value =
          jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
      if (value['noteId'] != noteId) return null;
      if (value['protectedPaths'] is! List) return null;
      return (value[field] as List? ?? const [])
          .cast<String>()
          .map(p.normalize)
          .toSet();
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  /// 清单已删除但原件清理失败时，重启按持久标记再次尝试。
  Future<void> _retryDeletionMarkers(Directory directory) async {
    await for (final FileSystemEntity entry in directory.list(
      followLinks: false,
    )) {
      if (entry is! File || !entry.path.endsWith('.deleted.json')) continue;
      try {
        // 只处理本服务派生的文件名及完整标记。
        final Map<String, dynamic> marker =
            jsonDecode(await entry.readAsString()) as Map<String, dynamic>;
        final String noteId = marker['noteId'] as String;
        if (!p.equals(entry.path, _deletionMarker(directory, noteId).path)) {
          continue;
        }
        // 持久保护关系与残余原件路径。
        final Set<String>? protected = await _readProtectedPaths(entry, noteId);
        final Set<String>? pending = await _readDeletionPaths(
          entry,
          noteId,
          'pendingPaths',
        );
        if (protected == null || pending == null) continue;
        for (final String rawPath in pending) {
          // 逐项验证最终删除路径仍直接处于当前source目录。
          final String? path = _ownedAudioPath(directory, rawPath);
          if (path == null || protected.any((saved) => p.equals(saved, path))) {
            continue;
          }
          if (state.isActive &&
              _session?['path'] is String &&
              p.equals(_session!['path'] as String, path)) {
            continue;
          }
          // 未能删除的清单先保留，避免违反先清单后原件规则。
          if (await File(p.setExtension(path, '.pending.json')).exists()) {
            continue;
          }
          final File audio = File(path);
          if (await audio.exists()) await audio.delete();
        }
      } on FileSystemException {
        continue;
      } on FormatException {
        continue;
      } on TypeError {
        continue;
      }
    }
  }

  /// 限定原件绝对路径为当前source直接子文件。
  String? _ownedAudioPath(Directory directory, dynamic rawPath) {
    if (rawPath is! String || !p.isAbsolute(rawPath)) return null;
    // 删除操作使用此处核查后的规范绝对路径。
    final String path = p.normalize(rawPath);
    return p.equals(p.dirname(path), p.normalize(directory.path)) ? path : null;
  }

  /// 先删除清单再删同目录原件，另存引用和活动录音保留。
  Future<void> _discardManifest(
    File manifest,
    Map<String, dynamic> session,
    Directory directory,
    Set<String> protectedPaths,
  ) async {
    if (state.isActive && session['id'] == state.recordingId) return;
    // 必须是绝对路径且直接位于当前私有目录，禁止相邻目录与路径穿越。
    final String? path = _ownedAudioPath(directory, session['path']);
    if (path == null) return;
    // 删除操作仅对已核查的原件绝对路径执行。
    await manifest.delete();
    if (protectedPaths.any(
      (protected) => p.equals(p.normalize(protected), path),
    )) {
      return;
    }
    // 原件可能已经由仓储删除，清理保持幂等。
    final File audio = File(path);
    if (await audio.exists()) await audio.delete();
  }

  /// 仅在数据库确认原件保存成功后移除恢复标记；不删除原音。
  Future<void> acknowledge(String id) async {
    if (!RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(id)) {
      throw ArgumentError('无效的录音标识');
    }
    // 恢复标记位于同一个私有目录。
    final file = File(
      p.join(
        _finished[id] != null
            ? p.dirname(_finished[id]!.path)
            : (await _directoryResolver()).path,
        '$id.pending.json',
      ),
    );
    if (await file.exists()) await file.delete();
  }

  /// 从失败提示打开系统应用设置，不重试录音。
  Future<void> openSettings() async {
    if (_android) {
      await _channel.invokeMethod<void>('openSettings');
    } else if (Platform.isWindows) {
      await Process.run('explorer.exe', ['ms-settings:privacy-microphone']);
    }
  }

  /// 正常关闭应用时结束并落盘；容器保持到应用退出。
  Future<void> dispose() async {
    await stop(reason: '应用退出，已保存可用原音');
    await _nativeSubscription?.cancel();
    await _recordSubscription?.cancel();
    await _audioSubscription?.cancel();
    await _recorder?.dispose();
    await _states.close();
    await _completed.close();
    await _returnRequests.close();
  }

  /// 固定采集开始时的设备时区名和偏移。
  static String _creationTimezone(DateTime startedAt) {
    // 当前系统时区偏移的绝对分钟，保留半小时等非整小时区。
    final int minutes = startedAt.timeZoneOffset.inMinutes.abs();
    // 设备时区名与开始瞬间的有符号偏移。
    final String offset =
        '${startedAt.timeZoneOffset.isNegative ? '-' : '+'}'
        '${(minutes ~/ 60).toString().padLeft(2, '0')}:'
        '${(minutes % 60).toString().padLeft(2, '0')}';
    return '${startedAt.timeZoneName}|$offset';
  }

  /// 应用支持目录保存原件和恢复记录。
  static Future<Directory> _defaultDirectory() async => Directory(
    p.join((await getApplicationSupportDirectory()).path, 'notes', 'audio'),
  );
}
