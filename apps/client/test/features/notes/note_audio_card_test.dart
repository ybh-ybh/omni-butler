import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/notes/audio/note_audio_player_service.dart';
import 'package:omni_butler/features/notes/presentation/note_audio_card.dart';
import 'package:omni_butler/shared/ui/omni_button.dart';

/// 真实异步状态流的共享播放器替身，不启动平台插件。
class _SharedPlayer implements NoteAudioPlayerService {
  /// 当前原音路径。
  @override
  String? currentPath;

  /// 当前播放状态。
  @override
  PlayerState state = PlayerState.stopped;

  /// 原音身份变化。
  final StreamController<String?> pathsController =
      StreamController.broadcast();

  /// 播放状态变化。
  final StreamController<PlayerState> statesController =
      StreamController.broadcast();

  /// 进度变化。
  final StreamController<Duration> positionsController =
      StreamController.broadcast();

  /// 文件总长变化。
  final StreamController<Duration> durationsController =
      StreamController.broadcast();

  /// 用于验证明确回听操作。
  final List<String> operations = [];

  /// 未使用的 API 不调用原生插件。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  /// 音源身份广播。
  @override
  Stream<String?> get currentPaths => pathsController.stream;

  /// 播放状态广播。
  @override
  Stream<PlayerState> get states => statesController.stream;

  /// 位置广播。
  @override
  Stream<Duration> get positions => positionsController.stream;

  /// 时长广播。
  @override
  Stream<Duration> get durations => durationsController.stream;

  /// 明确开始新的原音播放。
  @override
  Future<void> play(String path) async {
    operations.add('play:$path');
    currentPath = path;
    state = PlayerState.playing;
    pathsController.add(path);
    statesController.add(state);
  }

  /// 明确暂停当前原音。
  @override
  Future<void> pause() async {
    operations.add('pause');
    state = PlayerState.paused;
    statesController.add(state);
  }

  /// 明确继续当前原音。
  @override
  Future<void> resume() async {
    operations.add('resume');
    state = PlayerState.playing;
    statesController.add(state);
  }

  /// 拖动或键盘更改回听进度。
  @override
  Future<void> seek(Duration value, {String? expectedPath}) async {
    operations.add('seek:${value.inMilliseconds}');
    positionsController.add(value);
  }

  /// 停止后释放原音身份。
  @override
  Future<void> stop() async {
    operations.add('stop');
    currentPath = null;
    state = PlayerState.stopped;
    pathsController.add(null);
    statesController.add(state);
  }

  /// 销毁测试状态流。
  @override
  Future<void> dispose() async {
    await pathsController.close();
    await statesController.close();
    await positionsController.close();
    await durationsController.close();
  }
}

/// 可阻塞一次平台播放启动，验证多卡片并发切换的真实服务排序。
class _BackendPlayer implements AudioPlayer {
  /// 可控制平台完成事件。
  final StreamController<void> finished = StreamController.broadcast();

  /// 原生音源启动次序。
  final List<String> sources = [];

  /// 原生拖动操作证据。
  final List<Duration> seeks = [];

  /// 模拟首次原音解码尚未完成。
  Completer<void>? firstGate;

  /// 底层播放器状态。
  @override
  PlayerState state = PlayerState.stopped;

  /// 其他平台 API 不在测试中调用。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  /// 原生播放结束广播。
  @override
  Stream<void> get onPlayerComplete => finished.stream;

  /// 本测试只验证命令排序，无需状态事件。
  @override
  Stream<PlayerState> get onPlayerStateChanged => const Stream.empty();

  /// 本测试只验证拖动请求，不回送位置。
  @override
  Stream<Duration> get onPositionChanged => const Stream.empty();

  /// 无原生文件时长事件。
  @override
  Stream<Duration> get onDurationChanged => const Stream.empty();

  /// 模拟真实播放器异步解码。
  @override
  Future<void> play(
    Source source, {
    double? volume,
    double? balance,
    AudioContext? ctx,
    Duration? position,
    PlayerMode? mode,
  }) async {
    sources.add((source as DeviceFileSource).path);
    if (sources.length == 1 && firstGate != null) await firstGate!.future;
    state = PlayerState.playing;
  }

  /// 底层停止。
  @override
  Future<void> stop() async {
    state = PlayerState.stopped;
  }

  /// 底层暂停。
  @override
  Future<void> pause() async {
    state = PlayerState.paused;
  }

  /// 底层继续。
  @override
  Future<void> resume() async {
    state = PlayerState.playing;
  }

  /// 底层拖动记录。
  @override
  Future<void> seek(Duration value) async {
    seeks.add(value);
  }

  /// 释放完成事件流。
  @override
  Future<void> dispose() async {
    await finished.close();
  }
}

/// 建立一段不可变原音元数据。
NoteAudioSegmentRecord _segment(
  String id, {
  String? transcript,
  int order = 0,
}) => NoteAudioSegmentRecord(
  id: id,
  noteId: 'note',
  sortOrder: order,
  durationMs: 12000,
  mime: 'audio/wav',
  sha256: sha256.convert(List.filled(144, 0)).toString(),
  byteSize: 144,
  transcript: transcript,
  createdAt: DateTime(2026, 10, 11),
  updatedAt: DateTime(2026, 10, 11),
);

/// 当前本机原音、任务状态与授权。
NoteAudioLocalFileRecord _local(
  String id, {
  String? path,
  String status = 'idle',
  bool consent = false,
  String? inserted,
  String? error,
  String? candidate,
}) => NoteAudioLocalFileRecord(
  id: id,
  localPath: path,
  uploadState: 'pending',
  recognitionState: status,
  consent: consent,
  insertedRevision: inserted,
  lastError: error,
  candidateTranscript: candidate,
);

/// 测试使用产品主题，窄屏溢出由布局异常直接发现。
Widget _app(Widget child, {double scale = 1}) => MaterialApp(
  theme: AppTheme.build(brightness: Brightness.light),
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(scale)),
      child: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  ),
);

/// 让磁盘原音可用性检查先完成，再推进 Flutter 帧。
Future<void> _settle(WidgetTester tester) async {
  // exists 和 length 依次读取，逐轮交替真实 I/O 与测试微任务。
  for (var turn = 0; turn < 6; turn++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

/// 覆盖原音真实缺失、共享回听与明确插入/授权语义。
void main() {
  // 每例隔离的原音目录。
  late Directory directory;
  // 应用共享播放器替身。
  late _SharedPlayer player;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('notes-card-');
    player = _SharedPlayer();
  });
  tearDown(() async {
    await player.dispose();
    await directory.delete(recursive: true);
  });

  test('共享回听服务串行切换音源，迟到的旧段拖动不作用于新段', () async {
    // 平台首次播放启动门闩。
    final backend = _BackendPlayer()..firstGate = Completer<void>();
    // 使用真实业务服务而非卡片播放器替身。
    final actual = NoteAudioPlayerService(player: backend);
    // 模拟两张卡片同时请求不同的原音。
    final first = actual.play('first.wav');
    final second = actual.play('second.wav');
    await Future<void>.delayed(Duration.zero);
    expect(backend.sources, ['first.wav']);
    expect(actual.currentPath, 'first.wav');
    backend.firstGate!.complete();
    await Future.wait([first, second]);
    expect(backend.sources, ['first.wav', 'second.wav']);
    expect(actual.currentPath, 'second.wav');
    await actual.seek(const Duration(seconds: 3), expectedPath: 'first.wav');
    expect(backend.seeks, isEmpty);
    await actual.seek(const Duration(seconds: 4), expectedPath: 'second.wav');
    expect(backend.seeks, [const Duration(seconds: 4)]);
    backend.finished.add(null);
    await Future<void>.delayed(Duration.zero);
    expect(actual.currentPath, isNull);
    await actual.dispose();
  });

  test('真实服务在录音期间拒绝启动或继续回听，停止仍可执行', () async {
    // 注入原生替身避免任何麦克风或设备副作用。
    final backend = _BackendPlayer();
    final actual = NoteAudioPlayerService(player: backend)
      ..recordingActive = () => true;
    await expectLater(actual.play('recording.wav'), throwsStateError);
    await expectLater(actual.resume(), throwsStateError);
    expect(backend.sources, isEmpty);
    await actual.stop();
    expect(actual.currentPath, isNull);
    await actual.dispose();
  });

  testWidgets('缺失原音明确显示且不能回听，录音元信息不代表已下载', (tester) async {
    await tester.pumpWidget(
      _app(
        NoteAudioCard(
          segment: _segment('missing'),
          local: _local('missing', path: '${directory.path}/missing.wav'),
          player: player,
          onRecognize: () {},
          onCancel: () {},
          onInsert: (_) {},
          recordingActive: false,
        ),
      ),
    );
    await _settle(tester);
    expect(find.textContaining('本机原音缺失'), findsOneWidget);
    // 缺失状态仍可处理原始转写授权，不伪造播放成功。
    final playback = tester.widget<OmniButton>(
      find.widgetWithText(OmniButton, '回听原音'),
    );
    expect(playback.onPressed, isNull);
    expect(player.operations, isEmpty);
  });

  testWidgets('两段共用播放器，仅当前段显示暂停并支持继续和拖动', (tester) async {
    // 两个实际存在的原音文件用于可用性检查。
    final first = '${directory.path}/first.wav';
    final second = '${directory.path}/second.wav';
    await tester.runAsync(() async {
      await File(first).writeAsBytes(List.filled(144, 0));
      await File(second).writeAsBytes(List.filled(144, 0));
    });
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            NoteAudioCard(
              segment: _segment('first'),
              local: _local('first', path: first),
              player: player,
              onRecognize: () {},
              onCancel: () {},
              onInsert: (_) {},
              recordingActive: false,
            ),
            NoteAudioCard(
              segment: _segment('second', order: 1),
              local: _local('second', path: second),
              player: player,
              onRecognize: () {},
              onCancel: () {},
              onInsert: (_) {},
              recordingActive: false,
            ),
          ],
        ),
      ),
    );
    await _settle(tester);
    await tester.tap(find.text('回听原音').first);
    await _settle(tester);
    expect(player.currentPath, first);
    expect(find.text('暂停回听'), findsOneWidget);
    await tester.tap(find.text('暂停回听'));
    await _settle(tester);
    expect(find.text('继续回听'), findsOneWidget);
    await tester.tap(find.text('继续回听'));
    await _settle(tester);
    // 测试键盘/拖动最终回调，非活动段滑块必须禁用。
    final sliders = tester.widgetList<Slider>(find.byType(Slider)).toList();
    expect(sliders[1].onChanged, isNull);
    sliders[0].onChangeEnd!(6000);
    await _settle(tester);
    expect(player.operations, contains('seek:6000'));
    await tester.ensureVisible(find.text('回听原音'));
    await tester.tap(find.text('回听原音'));
    await _settle(tester);
    expect(player.currentPath, second);
    expect(find.text('暂停回听'), findsOneWidget);
    expect(find.text('回听原音'), findsOneWidget);
  });

  testWidgets('识别文本只在明确操作时插入，原始转写可查看复制', (tester) async {
    // 外层正文插入的唯一触发证据。
    final inserted = <String>[];
    // 记录系统剪贴板写入。
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.pumpWidget(
      _app(
        NoteAudioCard(
          segment: _segment('text', transcript: '今天完成了项目日报。'),
          local: _local('text', status: 'succeeded', consent: true),
          player: player,
          onRecognize: () {},
          onCancel: () {},
          onInsert: inserted.add,
          recordingActive: false,
        ),
      ),
    );
    await _settle(tester);
    expect(inserted, isEmpty);
    expect(find.text('转写已完成，待插入正文'), findsOneWidget);
    await tester.tap(find.text('插入正文'));
    await tester.pump();
    expect(inserted, ['今天完成了项目日报。']);
    await tester.tap(find.text('查看原始转写'));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsOneWidget);
    await tester.tap(find.text('复制原文'));
    await tester.pump();
    expect(copied, '今天完成了项目日报。');
    expect(inserted.length, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('320宽与放大字号不溢出，失败和撤回入口明确且触控48高', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // 明确重试和撤回点击证据。
    var retries = 0;
    var cancellations = 0;
    await tester.pumpWidget(
      _app(
        NoteAudioCard(
          segment: _segment('failure'),
          local: _local(
            'failure',
            status: 'failed',
            consent: true,
            error: '服务额度不足，请检查配置',
          ),
          player: player,
          onRecognize: () => retries++,
          onCancel: () => cancellations++,
          onInsert: (_) {},
          recordingActive: true,
        ),
        scale: 1.6,
      ),
    );
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('额度不足'), findsOneWidget);
    await tester.ensureVisible(find.text('重试转写'));
    await tester.tap(find.text('重试转写'));
    await tester.ensureVisible(find.text('撤回本段转写授权'));
    await tester.tap(find.text('撤回本段转写授权'));
    expect(retries, 1);
    expect(cancellations, 1);
    // 统一按钮保留最少 48px 点击高度。
    for (final element in find.byType(OmniButton).evaluate()) {
      expect(
        tester.getSize(find.byWidget(element.widget)).height,
        greaterThanOrEqualTo(48),
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('未知提交回执不提供新任务重试，已插入结果不重复提示插入', (tester) async {
    await tester.pumpWidget(
      _app(
        NoteAudioCard(
          segment: _segment('unknown', transcript: '保留的原始文字'),
          local: _local(
            'unknown',
            status: 'submissionUnknown',
            consent: true,
            inserted: 'revision',
          ),
          player: player,
          onRecognize: () {},
          onCancel: () {},
          onInsert: (_) {},
          recordingActive: false,
        ),
      ),
    );
    await _settle(tester);
    expect(find.textContaining('请查询原任务'), findsOneWidget);
    expect(find.text('重试转写'), findsNothing);
    expect(find.text('重新转写'), findsNothing);
    expect(find.text('插入正文'), findsNothing);
    expect(find.text('查看原始转写'), findsOneWidget);
  });

  testWidgets('重新转写候选优先插入，查看首次原文不会被本次结果替换', (tester) async {
    // 明确插入文本的用户动作证据。
    final inserted = <String>[];
    await tester.pumpWidget(
      _app(
        NoteAudioCard(
          segment: _segment('candidate', transcript: '首次原始转写'),
          local: _local(
            'candidate',
            status: 'succeeded',
            inserted: 'old-revision',
            candidate: '本次重试转写结果',
          ),
          player: player,
          onRecognize: () {},
          onCancel: () {},
          onInsert: inserted.add,
          recordingActive: false,
        ),
      ),
    );
    await _settle(tester);
    expect(find.text('转写已完成，待插入正文'), findsOneWidget);
    await tester.tap(find.text('插入正文'));
    await tester.pump();
    expect(inserted, ['本次重试转写结果']);
    await tester.tap(find.text('查看原始转写'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SelectableText>(find.byType(SelectableText)).data,
      '首次原始转写',
    );
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看本次转写'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SelectableText>(find.byType(SelectableText)).data,
      '本次重试转写结果',
    );
    expect(inserted.length, 1);
  });

  testWidgets('首次转写waiting锚点仍是待插入，不能声称已经插入', (tester) async {
    await tester.pumpWidget(
      _app(
        NoteAudioCard(
          segment: _segment('waiting', transcript: '迟到的首次识别文字'),
          local: _local(
            'waiting',
            status: 'succeeded',
            inserted: 'waiting:original-revision',
          ),
          player: player,
          onRecognize: () {},
          onCancel: () {},
          onInsert: (_) {},
          recordingActive: false,
        ),
      ),
    );
    await _settle(tester);
    expect(find.text('插入正文'), findsOneWidget);
    expect(find.textContaining('转写已插入正文'), findsNothing);
  });

  testWidgets('播放前重新核验真实SHA，同长度篡改文件不能回听', (tester) async {
    // 先提供与元信息 SHA 一致的原件。
    final path = '${directory.path}/integrity.wav';
    await tester.runAsync(() => File(path).writeAsBytes(List.filled(144, 0)));
    await tester.pumpWidget(
      _app(
        NoteAudioCard(
          segment: _segment('integrity'),
          local: _local('integrity', path: path),
          player: player,
          onRecognize: () {},
          onCancel: () {},
          onInsert: (_) {},
          recordingActive: false,
        ),
      ),
    );
    await _settle(tester);
    expect(find.text('原音已保存在本机'), findsOneWidget);
    // 本机路径和字节数均相同，但文件体已经被替换。
    await tester.runAsync(() => File(path).writeAsBytes(List.filled(144, 1)));
    await tester.tap(find.text('回听原音'));
    await _settle(tester);
    expect(find.textContaining('原音校验失败'), findsOneWidget);
    expect(player.operations, isEmpty);
    expect(
      tester
          .widget<OmniButton>(find.widgetWithText(OmniButton, '回听原音'))
          .onPressed,
      isNull,
    );
  });
}
