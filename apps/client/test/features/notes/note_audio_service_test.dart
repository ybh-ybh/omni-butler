import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:omni_butler/features/notes/audio/note_audio_player_service.dart';
import 'package:omni_butler/features/notes/audio/note_recorder_service.dart';
import 'package:omni_butler/features/notes/audio/note_wav.dart';
import 'package:record/record.dart';

/// 可确定注入 PCM 和暂停事件的设备替身。
class _Recorder implements AudioRecorder {
  /// 单次采集原始流。
  final StreamController<Uint8List> samples = StreamController.broadcast();

  /// 平台状态广播。
  final StreamController<RecordState> statuses = StreamController.broadcast();

  /// 验证每次采集的实际格式。
  RecordConfig? config;

  /// 权限拒绝路径。
  bool permission = true;

  /// 设备启动次数。
  int starts = 0;

  /// 测试使用的方法以外不走原生插件。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  /// 当前权限结果。
  @override
  Future<bool> hasPermission({bool request = true}) async => permission;

  /// 开始采样只计数，不伪造数据。
  @override
  Future<Stream<Uint8List>> startStream(RecordConfig value) async {
    starts++;
    config = value;
    return samples.stream;
  }

  /// 提供系统状态事件。
  @override
  Stream<RecordState> onStateChanged() => statuses.stream;

  /// 暂停底层采集。
  @override
  Future<void> pause() async {}

  /// 继续底层采集。
  @override
  Future<void> resume() async {}

  /// 停止真实设备替身。
  @override
  Future<String?> stop() async => null;

  /// 释放测试流。
  @override
  Future<void> dispose() async {
    await samples.close();
    await statuses.close();
  }
}

/// 记录回听互斥行为，不初始化原生播放器。
class _Player implements NoteAudioPlayerService {
  /// 录音服务注入的互斥状态查询。
  @override
  bool Function()? recordingActive;

  /// 每次采集前停止回听的调用次数。
  int stops = 0;

  /// 未使用的方法禁止意外调用。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  /// 停止回听只计数。
  @override
  Future<void> stop() async {
    stops++;
  }
}

/// 覆盖采样格式、限额、暂停及真实磁盘恢复，而非复写状态实现。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 每个用例隔离的私有原件目录。
  late Directory directory;
  // 可控设备替身。
  late _Recorder device;
  // 可控回听替身。
  late _Player player;
  // 长生命周期应用服务。
  late NoteRecorderService service;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('notes-audio-test-');
    device = _Recorder();
    player = _Player();
    service = NoteRecorderService(
      player: player,
      recorder: device,
      android: false,
      directoryResolver: () async => directory,
    );
  });
  tearDown(() async {
    await service.dispose();
    await directory.delete(recursive: true);
  });

  test('预载构造、状态订阅与闲置销毁不调用任何音频平台通道', () async {
    // 实际插件的命令及全局事件频道，不替换服务构造路径。
    const List<MethodChannel> channels = [
      MethodChannel('com.llfbandit.record/messages'),
      MethodChannel('xyz.luan/audioplayers'),
      MethodChannel('xyz.luan/audioplayers.global'),
      MethodChannel('xyz.luan/audioplayers.global/events'),
      MethodChannel('omni_butler/notes_recording'),
      MethodChannel('omni_butler/notes_recording_events'),
    ];
    // 收集意外create、init、listen或dispose请求。
    final List<String> calls = [];
    for (final MethodChannel channel in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add('${channel.name}:${call.method}');
            return null;
          });
    }
    addTearDown(() {
      for (final MethodChannel channel in channels) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      }
    });
    // 与生产provider相同，完全不注入底层原生替身。
    final NoteAudioPlayerService lazyPlayer = NoteAudioPlayerService();
    // UI可提前监听，但真正回听前不会创建平台实例。
    final List<StreamSubscription<dynamic>> subscriptions = [
      lazyPlayer.states.listen((_) {}),
      lazyPlayer.positions.listen((_) {}),
      lazyPlayer.durations.listen((_) {}),
      lazyPlayer.completions.listen((_) {}),
      lazyPlayer.currentPaths.listen((_) {}),
    ];
    expect(lazyPlayer.currentPath, isNull);
    await lazyPlayer.pause();
    await lazyPlayer.resume();
    await lazyPlayer.seek(Duration.zero);
    await lazyPlayer.stop();
    // Windows恢复只访问本地清单；Android构造不建立事件桥。
    for (final bool android in <bool>[false, true]) {
      // 本次未使用的真实服务构造。
      final NoteRecorderService lazyRecorder = NoteRecorderService(
        player: lazyPlayer,
        android: android,
        directoryResolver: () async => directory,
      );
      if (!android) {
        expect(await lazyRecorder.recoverPending(), isEmpty);
      }
      await lazyRecorder.dispose();
    }
    for (final StreamSubscription<dynamic> subscription in subscriptions) {
      await subscription.cancel();
    }
    await lazyPlayer.dispose();
    // 等待插件构造可能排入的异步任务，不能只断言同步调用为零。
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls, isEmpty);
  });

  test('PCM 原件逐步写盘，暂停不计时，落库确认后才去掉恢复标记', () async {
    await service.start('note-a');
    expect(service.state.limit, const Duration(minutes: 30));
    expect(device.config?.encoder, AudioEncoder.pcm16bits);
    expect(device.config?.sampleRate, 16000);
    expect(device.config?.numChannels, 1);
    expect(player.stops, 1);
    // 第一秒有效采样，检查服务时长来自真实 PCM 数量。
    device.samples.add(Uint8List(NoteWav.bytesPerSecond));
    await service.states.firstWhere(
      (state) => state.duration == const Duration(seconds: 1),
    );
    await service.pause();
    device.samples.add(Uint8List(NoteWav.bytesPerSecond));
    await Future<void>.delayed(Duration.zero);
    await service.resume();
    device.samples.add(Uint8List(NoteWav.bytesPerSecond));
    // 停止会等待串行写盘，不能按墙上时间计算暂停。
    await Future<void>.delayed(Duration.zero);
    final result = await service.stop();
    expect(result?.noteId, 'note-a');
    expect(result?.duration, const Duration(seconds: 2));
    expect(result?.creationTimezone, matches(RegExp(r'^.+\|[+-]\d{2}:\d{2}$')));
    expect(await File(result!.path).length(), 44 + NoteWav.bytesPerSecond * 2);
    // 验证头部长度与原音实际大小一致，原音可被 WAV 播放器读取。
    final header = ByteData.sublistView(await File(result.path).readAsBytes());
    expect(header.getUint32(40, Endian.little), NoteWav.bytesPerSecond * 2);
    expect(
      await File('${directory.path}/${result.id}.pending.json').exists(),
      isTrue,
    );
    await service.acknowledge(result.id);
    expect(
      await File('${directory.path}/${result.id}.pending.json').exists(),
      isFalse,
    );
    expect(await File(result.path).exists(), isTrue);
  });

  test('剩余额度优先，达到限制截断完整采样并只发一次完成', () async {
    // 收集自动结束结果，不依赖页面调用 stop。
    final delivered = <NoteRecordingResult>[];
    final subscription = service.completed.listen(delivered.add);
    final completion = service.completed.first;
    await service.start(
      'note-limit',
      remaining: const Duration(milliseconds: 50),
    );
    device.samples.add(Uint8List(NoteWav.bytesPerSecond));
    final result = await completion;
    expect(result.duration, const Duration(milliseconds: 50));
    expect(await File(result.path).length(), 44 + 1600);
    expect(result.interruptionReason, contains('上限'));
    expect(service.state.phase, NoteRecordingPhase.idle);
    expect(await service.stop(), isNull);
    expect(delivered.length, 1);
    await subscription.cancel();
  });

  test('没有剩余额度不启动麦克风，不生成清单', () async {
    await expectLater(
      service.start('full', remaining: Duration.zero),
      throwsStateError,
    );
    expect(device.starts, 0);
    expect(await directory.list().isEmpty, isTrue);
  });

  test('Windows草稿代次写入真实清单并随完成恢复保留，取消不删除整篇身份', () async {
    await service.start('same-note', draftId: 'draft-one');
    expect(service.state.draftId, 'draft-one');
    device.samples.add(Uint8List(NoteWav.bytesPerSecond));
    await service.states.firstWhere(
      (state) => state.duration == const Duration(seconds: 1),
    );
    // 完成结果和恢复清单都必须携带同一代次。
    final NoteRecordingResult result = (await service.stop())!;
    expect(result.draftId, 'draft-one');
    expect((await service.recoverPending()).single.draftId, 'draft-one');
    await service.discardPendingForDraft('draft-one');
    expect(await File(result.path).exists(), isFalse);
    expect(await service.isPermanentlyDiscarded('same-note'), isFalse);
    expect(await service.recoverPending(), isEmpty);
    await service.start('same-note', draftId: 'draft-two');
    expect(service.state.draftId, 'draft-two');
    expect(service.state.noteId, 'same-note');
  });

  test('同一设备的活动录音不能改挂另一篇笔记', () async {
    await service.start('original');
    await expectLater(service.start('different'), throwsStateError);
    expect(device.starts, 1);
    expect(service.state.noteId, 'original');
    expect(player.recordingActive!(), isTrue);
  });

  test('系统麦克风中断保存已写原音，不自动重新启动', () async {
    final completion = service.completed.first;
    await service.start('interrupted');
    device.samples.add(Uint8List(NoteWav.bytesPerSecond));
    await service.states.firstWhere(
      (state) => state.duration == const Duration(seconds: 1),
    );
    device.statuses.add(RecordState.stop);
    final result = await completion;
    expect(result.duration, const Duration(seconds: 1));
    expect(result.interruptionReason, contains('中断'));
    expect(device.starts, 1);
    expect(service.state.isActive, isFalse);
  });

  test('异常终止 WAV 由真实字节长度恢复，坏清单不污染其他文件', () async {
    // 仿真进程被杀：头部仍为零而 PCM 已写到磁盘。
    final audio = File('${directory.path}/recovery.wav');
    await audio.writeAsBytes([
      ...NoteWav.header(0),
      ...Uint8List(32000),
      7,
    ], flush: true);
    // 正确的恢复清单与一个损坏清单并存。
    await File('${directory.path}/recovery.pending.json').writeAsString(
      jsonEncode({
        'id': 'recovery',
        'noteId': 'recover-note',
        'path': audio.path,
        'startedAt': '2026-10-11T10:00:00Z',
      }),
    );
    await File('${directory.path}/broken.pending.json')
        .writeAsString('{broken');
    final recovered = await service.recoverPending();
    expect(recovered.length, 1);
    expect(recovered.single.noteId, 'recover-note');
    expect(recovered.single.duration, const Duration(seconds: 1));
    expect(recovered.single.creationTimezone, 'legacy:unknown');
    expect(await audio.length(), 32044);
    final header = ByteData.sublistView(await audio.readAsBytes());
    expect(header.getUint32(4, Endian.little), 32036);
    expect(header.getUint32(40, Endian.little), 32000);
    expect(device.starts, 0);
  });

  test('跨时区恢复保留采集时区，不使用当前设备时区', () async {
    // 带历史半小时时区偏移的实际原件。
    final File audio = File('${directory.path}/timezone.wav');
    await audio.writeAsBytes([
      ...NoteWav.header(32000),
      ...Uint8List(32000),
    ], flush: true);
    await File('${directory.path}/timezone.pending.json').writeAsString(
      jsonEncode({
        'id': 'timezone',
        'noteId': 'timezone-note',
        'path': audio.path,
        'startedAt': '2026-10-11T10:00:00Z',
        'creationTimezone': 'Historical Zone|+05:30',
      }),
    );
    // 扫描不会打开麦克风，只读取已经固定的清单。
    final List<NoteRecordingResult> recovered = await service.recoverPending();
    expect(recovered.single.creationTimezone, 'Historical Zone|+05:30');
    expect(recovered.single.startedAt, DateTime.utc(2026, 10, 11, 10));
    expect(device.starts, 0);
  });

  test('永久删除清候选，另存保护路径重启后仍保留且不能恢复旧笔记', () async {
    // 原始候选与另存共享原件。
    final File removed = await _pendingFile(
      directory,
      'removed',
      'deleted-note',
    );
    final File shared = await _pendingFile(directory, 'shared', 'deleted-note');
    final File unrelated = await _pendingFile(directory, 'other', 'other-note');
    await service.discardPendingForNote(
      'deleted-note',
      protectedPaths: {shared.path},
    );
    expect(await removed.exists(), isFalse);
    expect(await shared.exists(), isTrue);
    expect(await unrelated.exists(), isTrue);
    expect(
      await File('${directory.path}/shared.pending.json').exists(),
      isFalse,
    );
    expect(await service.isPermanentlyDiscarded('deleted-note'), isTrue);
    // 模拟原件清理失败遗留文件与未删掉的清单，重启继续清理。
    await _pendingFile(directory, 'removed', 'deleted-note');
    await _pendingFile(directory, 'shared', 'deleted-note');
    // 新实例只根据磁盘marker读取保护关系。
    final NoteRecorderService restarted = NoteRecorderService(
      player: player,
      android: false,
      directoryResolver: () async => directory,
    );
    try {
      final List<NoteRecordingResult> recovered = await restarted
          .recoverPending();
      expect(recovered.map((item) => item.noteId), ['other-note']);
      expect(await removed.exists(), isFalse);
      expect(await shared.exists(), isTrue);
      expect(
        await File('${directory.path}/shared.pending.json').exists(),
        isFalse,
      );
      expect(await restarted.isPermanentlyDiscarded('deleted-note'), isTrue);
      // 模拟先删清单成功、原件删除失败；marker仍记得待清理路径。
      await removed.writeAsBytes([
        ...NoteWav.header(32000),
        ...Uint8List(32000),
      ]);
      expect(
        await File('${directory.path}/removed.pending.json').exists(),
        isFalse,
      );
      expect((await restarted.recoverPending()).map((item) => item.noteId), [
        'other-note',
      ]);
      expect(await removed.exists(), isFalse);
      expect(await shared.exists(), isTrue);
    } finally {
      await restarted.dispose();
    }
    expect(device.starts, 0);
  });

  test('永久删除坏清单与目录外路径不触碰外部文件', () async {
    // 与source隔离的外部目录，只用来验证最终路径门禁。
    final Directory outsideDirectory = await Directory.systemTemp.createTemp(
      'notes-outside-guard-',
    );
    final File outside = File('${outsideDirectory.path}/outside.wav');
    await outside.writeAsBytes(NoteWav.header(32000));
    addTearDown(() async {
      if (await outside.exists()) await outside.delete();
      await outsideDirectory.delete();
    });
    // 清单匹配笔记，但指向source以外的文件。
    final File manifest = File('${directory.path}/outside.pending.json');
    await manifest.writeAsString(
      jsonEncode({
        'id': 'outside',
        'noteId': 'guard-note',
        'path': outside.path,
        'startedAt': '2026-10-11T10:00:00Z',
      }),
    );
    await File('${directory.path}/bad.pending.json').writeAsString('{bad');
    await service.discardPendingForNote('guard-note');
    expect(await outside.exists(), isTrue);
    expect(await manifest.exists(), isTrue);
    expect(await File('${directory.path}/bad.pending.json').exists(), isTrue);
    expect(await service.recoverPending(), isEmpty);
    expect(await outside.exists(), isTrue);
    expect(await service.isPermanentlyDiscarded('guard-note'), isTrue);
    expect(device.starts, 0);
  });

  test('活动录音永久删除先留marker，结束后恢复不复活并清理原件', () async {
    await service.start('active-deleted');
    device.samples.add(Uint8List(NoteWav.bytesPerSecond));
    await service.states.firstWhere(
      (state) => state.duration == const Duration(seconds: 1),
    );
    // 活动原件与清单都必须保留，不能在采样时删文件。
    final String recordingId = service.state.recordingId!;
    final File audio = File('${directory.path}/$recordingId.wav');
    await service.discardPendingForNote('active-deleted');
    expect(await service.isPermanentlyDiscarded('active-deleted'), isTrue);
    expect(await audio.exists(), isTrue);
    expect(
      await File('${directory.path}/$recordingId.pending.json').exists(),
      isTrue,
    );
    expect(service.state.isActive, isTrue);
    await service.stop();
    expect(await service.recoverPending(), isEmpty);
    expect(await audio.exists(), isFalse);
    expect(
      await File('${directory.path}/$recordingId.pending.json').exists(),
      isFalse,
    );
    expect(device.starts, 1);
  });

  test('按片段取消只删除命中原件，重启清单不能复活且保留同篇其他片段', () async {
    // 同一篇笔记的两个片段不可按笔记整体清除。
    final File cancelled = await _pendingFile(
      directory,
      'cancelled',
      'same-note',
    );
    // 未取消原件继续等待正常恢复。
    final File retained = await _pendingFile(
      directory,
      'retained',
      'same-note',
    );
    await service.discardPendingForRecording('cancelled');
    expect(await cancelled.exists(), isFalse);
    expect(await retained.exists(), isTrue);
    expect(await service.isPermanentlyDiscarded('recording:cancelled'), isTrue);
    expect(await service.isPermanentlyDiscarded('same-note'), isFalse);
    await _pendingFile(directory, 'cancelled', 'same-note');
    expect((await service.recoverPending()).map((item) => item.id), [
      'retained',
    ]);
    expect(await cancelled.exists(), isFalse);
  });

  test('Android 通知完成与 stop 返回去重，迟到事件不能清空新录音', () async {
    await service.dispose();
    device = _Recorder();
    // 隔离原生测试桥，实际 Android 服务另由 Gradle 编译验证。
    const commands = MethodChannel('notes-test-commands');
    const events = EventChannel('notes-test-events');
    // 编码与真实 EventChannel 一致的服务消息。
    const codec = StandardMethodCodec();
    // 系统采集元信息，来自每次 start 参数。
    Map<String, dynamic>? current;
    // 将原生服务状态交给长生命周期 Dart 消费者。
    Future<void> send(Map<String, dynamic> value) async {
      // 等待通道完成本次消息交付。
      final completion = Completer<void>();
      ServicesBinding.instance.channelBuffers.push(
        'notes-test-events',
        codec.encodeSuccessEnvelope(value),
        (_) => completion.complete(),
      );
      await completion.future;
      await Future<void>.delayed(Duration.zero);
    }

    // 测试用方法桥替身，不调用真实麦克风。
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('notes-test-events'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(commands, (call) async {
      if (call.method == 'start') {
        current = Map<String, dynamic>.from(call.arguments as Map);
        // 首次响应故意先于事件，重现真实Android桥的启动交付顺序。
        if (current!['noteId'] == 'native-second') {
          await send({
            ...current!,
            'type': 'state',
            'phase': 'recording',
            'durationMs': 0,
          });
        }
      }
      if (call.method == 'stop') {
        return {...current!, 'durationMs': 1000, 'type': 'completed'};
      }
      return null;
    });
    service = NoteRecorderService(
      player: player,
      recorder: device,
      android: true,
      channel: commands,
      events: events,
      directoryResolver: () async => directory,
    );
    // 真实 UI 只订阅完成流，不能因 method response 和 EventChannel 双通道重复落库。
    final delivered = <NoteRecordingResult>[];
    final subscription = service.completed.listen(delivered.add);
    // 音量事件独立于正文状态，隐藏、暂停、旧身份和非法值均不交付。
    final List<NoteRecordingLevel> levels = [];
    // 独立广播订阅不增加主状态通知。
    final levelSubscription = service.levels.listen(levels.add);
    await service.start('native-first', draftId: 'native-draft');
    expect(service.state.recordingId, current!['id']);
    expect(service.state.draftId, 'native-draft');
    // 旧版原生缺失代次仍只能回填当前同一片段的身份。
    final Map<String, dynamic> legacy = {
      ...current!,
      'type': 'state',
      'phase': 'recording',
    }..remove('draftId');
    await send(legacy);
    expect(service.state.draftId, 'native-draft');
    await send({...current!, 'type': 'meter', 'level': .2, 'durationMs': 50});
    expect(levels, isEmpty);
    await service.setMeteringActive(true);
    await send({...current!, 'type': 'meter', 'level': .4, 'durationMs': 100});
    expect(levels.single.level, .4);
    expect(levels.single.duration, const Duration(milliseconds: 100));
    await send({...current!, 'type': 'meter', 'level': double.nan});
    await send({...current!, 'type': 'meter', 'id': 'old-id', 'level': .9});
    await send({...current!, 'type': 'state', 'phase': 'paused'});
    await send({...current!, 'type': 'meter', 'level': .7});
    expect(levels, hasLength(1));
    await send({...current!, 'type': 'state', 'phase': 'recording'});
    await service.setMeteringActive(false);
    await send({...current!, 'type': 'meter', 'level': .8});
    expect(levels, hasLength(1));
    expect(service.state.phase, NoteRecordingPhase.recording);
    // 原生通知完成和显式 stop 可能以任意顺序到达。
    final oldResult = {...current!, 'durationMs': 1000, 'type': 'completed'};
    final stopped = await service.stop();
    await service.acknowledge(stopped!.id);
    await send(oldResult);
    expect(delivered.length, 1);
    await service.start('native-second');
    await send(oldResult);
    expect(service.state.phase, NoteRecordingPhase.recording);
    expect(service.state.noteId, 'native-second');
    expect(delivered.length, 1);
    await service.stop();
    await subscription.cancel();
    await levelSubscription.cancel();
    messenger.setMockMethodCallHandler(commands, null);
    // 保留 listen/cancel mock 到 teardown 完成，避免取消订阅的 MissingPlugin。
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        const MethodChannel('notes-test-events'),
        null,
      ),
    );
  });
}

/// 写入真实WAV与同目录清单，不依赖录音设备。
Future<File> _pendingFile(Directory directory, String id, String noteId) async {
  // 恢复时应可播放的一秒原件。
  final File audio = File('${directory.path}/$id.wav');
  await audio.writeAsBytes([
    ...NoteWav.header(32000),
    ...Uint8List(32000),
  ], flush: true);
  await File('${directory.path}/$id.pending.json').writeAsString(
    jsonEncode({
      'id': id,
      'noteId': noteId,
      'path': audio.path,
      'startedAt': '2026-10-11T10:00:00Z',
    }),
    flush: true,
  );
  return audio;
}
