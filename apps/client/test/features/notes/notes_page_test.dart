import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:drift/drift.dart' hide Column, isNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/omni_butler_app.dart';
import 'package:omni_butler/app/router/app_router.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/notes/audio/note_audio_player_service.dart';
import 'package:omni_butler/features/notes/audio/note_recorder_service.dart';
import 'package:omni_butler/features/notes/data/note_providers.dart';
import 'package:omni_butler/features/notes/data/note_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全应用路径回归：所有音频接口都由替身接管。
void main() {
  setUpAll(() async {
    if (Platform.environment['OMNI_NOTES_PREVIEW'] == null) return;
    // 预览使用本机字体，常规回归不依赖Windows资源。
    final ByteData font = ByteData.sublistView(
      await File(
        Platform.environment['OMNI_UI_FONT'] ?? 'C:/Windows/Fonts/msyh.ttc',
      ).readAsBytes(),
    );
    // 所有生产字体别名都提供真实中文字形。
    for (final String family in <String>[
      'Roboto',
      'Ahem',
      'Noto Sans CJK SC',
      'Microsoft YaHei UI',
      'Microsoft YaHei',
    ]) {
      // 当前别名的字体装载器。
      final FontLoader loader = FontLoader(family)
        ..addFont(Future<ByteData>.value(font));
      await loader.load();
    }
    // 图标来自Flutter SDK，路径允许测试环境替换。
    final FontLoader icons = FontLoader('MaterialIcons')
      ..addFont(
        File(
          Platform.environment['OMNI_UI_ICONS'] ?? 'D:/program/code/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
        ).readAsBytes().then(ByteData.sublistView),
      );
    await icons.load();
  });
  testWidgets('Android六分支预载不录音，保存与历史及重新进入相互独立', (tester) async {
    // 完整生产路由环境。
    final _App app = await _mount(tester);
    expect(app.routerPath, '/home');
    expect(
      await tester.runAsync(
        () => app.database.select(app.database.noteEntries).get(),
      ),
      isEmpty,
    );
    expect(app.recorder.starts, 0);
    // 首次真正进入后使用实际编辑器自动保存。
    await _navigate(tester, app, '/notes');
    final String originalId = app.container.read(noteEditorProvider).draft.id;
    await tester.enterText(_body(), '今天完成笔记功能，明天继续验证。');
    await _settle(tester, elapsed: const Duration(milliseconds: 700));
    expect(
      (await tester.runAsync(
        () => NoteRepository(app.database).find(originalId),
      ))?.body,
      '今天完成笔记功能，明天继续验证。',
    );
    expect(find.text('已保存到本机'), findsOneWidget);
    // 生命周期恢复不能生成另一篇笔记。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await _settle(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _settle(tester);
    expect(app.container.read(noteEditorProvider).draft.id, originalId);
    await tester.tap(find.byTooltip('查看历史'));
    await _settle(tester);
    expect(find.text('今天完成笔记功能，明天继续验证。'), findsOneWidget);
    await tester.tap(find.text('今天完成笔记功能，明天继续验证。'));
    await _settle(tester);
    expect(app.container.read(noteEditorProvider).draft.id, originalId);
    expect(
      (await tester.runAsync(
        () => app.database.select(app.database.noteEntries).get(),
      ))!.length,
      1,
    );
    // 一级导航离开后返回，旧正文仍在库中，新入口为空。
    await _navigate(tester, app, '/home');
    await _navigate(tester, app, '/notes');
    expect(app.container.read(noteEditorProvider).draft.id, isNot(originalId));
    expect(tester.widget<TextField>(_body()).controller!.text, isEmpty);
    expect(
      (await tester.runAsync(
        () => NoteRepository(app.database).find(originalId),
      ))?.body,
      '今天完成笔记功能，明天继续验证。',
    );
    expect(
      (await tester.runAsync(
        () => app.database.select(app.database.noteEntries).get(),
      ))!.length,
      1,
    );
    expect(app.recorder.starts, 0);
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('历史按时间类别多标签与原始转写交集筛选', (tester) async {
    // 已有多天、多类别和多标签的真实数据库。
    final _App app = await _mount(tester, seed: true);
    await _navigate(tester, app, '/notes');
    await tester.tap(find.byTooltip('查看历史'));
    await _settle(tester);
    expect(find.text('今日日报目标'), findsOneWidget);
    expect(find.text('昨日日报'), findsOneWidget);
    // 正文没有关键词，搜索应命中原始转写。
    await tester.enterText(
      find.widgetWithText(TextField, '搜索笔记、类别或标签'),
      '语音验收',
    );
    await _settle(tester);
    expect(find.text('今日日报目标'), findsOneWidget);
    expect(find.text('昨日日报'), findsNothing);
    await tester.tap(find.text('全部时间'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('今天').last);
    await _settle(tester);
    await tester.tap(find.text('全部类别').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('日报').last);
    await _settle(tester);
    await tester.tap(find.widgetWithText(FilterChip, '工作'));
    await tester.tap(find.widgetWithText(FilterChip, '复盘'));
    await _settle(tester);
    expect(find.text('今日日报目标'), findsOneWidget);
    expect(find.byType(ListTile), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, '搜索笔记、类别或标签'), '不存在');
    await _settle(tester);
    expect(find.text('没有符合条件的笔记'), findsOneWidget);
    await tester.tap(find.text('清除筛选'));
    await _settle(tester);
    expect(find.text('昨日日报'), findsOneWidget);
    expect(app.recorder.starts, 0);
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  // 两端主题截图均来自实际生产根组件。
  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.android,
    TargetPlatform.windows,
  ]) {
    for (final String theme in <String>['light', 'dark']) {
      testWidgets('${platform.name} $theme 生产笔记页截图', (tester) async {
        // 当前截图的主题和布局环境。
        final _App app = await _mount(
          tester,
          platform: platform,
          theme: theme,
          seed: true,
        );
        await _navigate(tester, app, '/notes');
        await tester.enterText(
          _body(),
          '记录此刻的想法\n\n今天完成了第一轮验证。把临时想法写下来，之后再整理成日报或周报。',
        );
        await _settle(tester, elapsed: const Duration(milliseconds: 700));
        await _capture(tester, app, '${platform.name}-$theme');
        expect(app.recorder.starts, 0);
        await _dispose(tester, app);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('320宽与1.6字号的编辑历史无溢出', (tester) async {
    // 保存框架处理器，打印完整溢出位置供修复定位。
    final FlutterExceptionHandler? previousErrorHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('RenderFlex overflowed')) {
        debugPrint(details.toString());
      }
      previousErrorHandler?.call(details);
    };
    addTearDown(() => FlutterError.onError = previousErrorHandler);
    // 最窄支持尺寸与放大字号。
    final _App app = await _mount(tester, seed: true);
    await _navigate(tester, app, '/notes');
    tester.view.physicalSize = const Size(320, 844);
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    await _settle(tester);
    await _capture(tester, app, 'android-320-large-editor');
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('查看历史'));
    await _settle(tester);
    await _capture(tester, app, 'android-320-large-history');
    FlutterError.onError = previousErrorHandler;
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });
}

/// 定位正文，避免误输入应用的搜索框。
Finder _body() => find.byWidgetPredicate(
  (widget) =>
      widget is TextField &&
      widget.decoration?.hintText?.startsWith('记下此刻') == true,
);

/// 将真实数据库异步事件与动画帧排空。
Future<void> _settle(
  WidgetTester tester, {
  Duration elapsed = Duration.zero,
}) async {
  await tester.pump(elapsed);
  // 每轮允许真实Drift异步工作完成，再刷新对应画面。
  for (int index = 0; index < 5; index++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

/// 通过生产一级导航进入目标分支。
Future<void> _navigate(WidgetTester tester, _App app, String path) async {
  await tester.tap(find.byKey(ValueKey<String>('navigation-$path')));
  await _settle(tester);
  expect(app.routerPath, path);
}

/// 测试持有的全部资源。
class _App {
  /// 当前数据库。
  final AppDatabase database;

  /// 当前生产依赖容器。
  final ProviderContainer container;

  /// 无原生设备的录音替身。
  final _Recorder recorder;

  /// 全页面截图边界。
  final GlobalKey boundary;

  /// 聚合测试资源。
  _App(this.database, this.container, this.recorder, this.boundary);

  /// 避免正常路径与失败兜底重复释放。
  bool disposed = false;

  /// 当前真实路由。
  String get routerPath =>
      container.read(appRouterProvider).routeInformationProvider.value.uri.path;
}

/// 构造两端生产应用，不替换数据库、编辑器或路由。
Future<_App> _mount(
  WidgetTester tester, {
  TargetPlatform platform = TargetPlatform.android,
  String theme = 'light',
  double width = 390,
  double scale = 1,
  bool seed = false,
}) async {
  debugDefaultTargetPlatformOverride = platform;
  tester.view.physicalSize = Size(
    platform == TargetPlatform.windows ? 1280 : width,
    platform == TargetPlatform.windows ? 900 : 844,
  );
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  SharedPreferences.setMockInitialValues(<String, Object>{
    'appearance.theme_mode': theme,
    'sync.enabled': false,
  });
  // 不访问真实偏好存储。
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  // 实际Drift schema和事务。
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  if (seed) await tester.runAsync(() => _seed(database));
  // 音频入口全部在无设备替身上执行。
  final _Recorder recorder = _Recorder();
  // 生产应用容器。
  final ProviderContainer container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      appDatabaseProvider.overrideWithValue(database),
      noteRecorderProvider.overrideWithValue(recorder),
      noteAudioPlayerProvider.overrideWithValue(_Player()),
    ],
  );
  // 用于保存完整应用截图。
  final GlobalKey boundary = GlobalKey();
  final _App app = _App(database, container, recorder, boundary);
  addTearDown(() => _dispose(tester, app));
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(key: boundary, child: const OmniButlerApp()),
    ),
  );
  await _settle(tester);
  return app;
}

/// 测试正常结束前释放全应用，失败时由tearDown补偿。
Future<void> _dispose(WidgetTester tester, _App app) async {
  if (app.disposed) return;
  app.disposed = true;
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  app.container.dispose();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.runAsync(app.database.close);
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
  tester.platformDispatcher.clearTextScaleFactorTestValue();
  debugDefaultTargetPlatformOverride = null;
}

/// 真实仓储插入有效分类与记录，覆盖筛选维度。
Future<void> _seed(AppDatabase database) async {
  // 日期使用页面相同的本机自然日规则。
  final DateTime now = DateTime.now();
  // 分类与标签的测试身份。
  for (final (String, String, String) item in <(String, String, String)>[
    ('daily', 'category', '日报'),
    ('weekly', 'category', '周报'),
    ('work', 'tag', '工作'),
    ('review', 'tag', '复盘'),
  ]) {
    await database
        .into(database.taxonomyEntries)
        .insert(
          TaxonomyEntriesCompanion.insert(
            id: item.$1,
            module: 'notes',
            kind: item.$2,
            name: item.$3,
            colorValue: 0xff6280ff,
            createdAt: now,
            updatedAt: now,
          ),
        );
  }
  // 每一篇记录都经过生产保存约束。
  for (final (String, String, DateTime, String, Set<String>) item
      in <(String, String, DateTime, String, Set<String>)>[
        ('target', '今日日报目标', now, 'daily', <String>{'work', 'review'}),
        (
          'yesterday',
          '昨日日报',
          now.subtract(const Duration(days: 1)),
          'daily',
          <String>{'work'},
        ),
        ('weekly-note', '今日周报', now, 'weekly', <String>{'review'}),
      ]) {
    await NoteRepository(database).save(
      NoteDraft(
        id: item.$1,
        body: item.$2,
        dayKey: businessDayKey(item.$3),
        baseRevision: '',
        categoryId: item.$4,
        categoryName: item.$4 == 'daily' ? '日报' : '周报',
        tags: item.$5,
      ),
    );
  }
  await database
      .into(database.noteAudioSegments)
      .insert(
        NoteAudioSegmentsCompanion.insert(
          id: 'audio-target',
          noteId: 'target',
          sortOrder: 0,
          durationMs: 18000,
          mime: 'audio/wav',
          sha256: '0' * 64,
          byteSize: 576044,
          transcript: const Value('语音验收通过'),
          createdAt: now,
          updatedAt: now,
        ),
      );
}

/// 开启环境变量才导出截图，普通回归不写产物。
Future<void> _capture(WidgetTester tester, _App app, String name) async {
  // 可复现截图输出开关。
  final String? output = Platform.environment['OMNI_NOTES_PREVIEW'];
  if (output == null) return;
  // 当前生产应用完整渲染边界。
  final RenderRepaintBoundary boundary =
      app.boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    // 无损当前页面像素。
    final ui.Image image = await boundary.toImage();
    try {
      // PNG像素内容。
      final ByteData? bytes = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      await Directory(output).create(recursive: true);
      await File('$output/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

/// 永不触碰系统麦克风的替身。
class _Recorder implements NoteRecorderService {
  /// 检测意外自动录音。
  int starts = 0;

  /// 永远空闲，页面不能自行开始采集。
  @override
  NoteRecordingState get state => const NoteRecordingState();

  /// 无采集状态事件。
  @override
  Stream<NoteRecordingState> get states => const Stream.empty();

  /// 无原音完成事件。
  @override
  Stream<NoteRecordingResult> get completed => const Stream.empty();

  /// 无通知导航事件。
  @override
  Stream<String> get returnRequests => const Stream.empty();

  /// 记录意外启动，明确让测试失败。
  @override
  Future<void> start(
    String noteId, {
    Duration remaining = const Duration(minutes: 60),
  }) async {
    starts++;
    throw StateError('页面测试不允许启动录音');
  }

  /// 初始化不需要平台通道。
  @override
  Future<void> initialize() async {}

  /// 没有未恢复原件。
  @override
  Future<List<NoteRecordingResult>> recoverPending() async =>
      <NoteRecordingResult>[];

  /// 页面测试没有永久删除恢复候选。
  @override
  Future<bool> isPermanentlyDiscarded(String noteId) async => false;

  /// 没有设备需要停止。
  @override
  Future<NoteRecordingResult?> stop({String? reason}) async => null;

  /// 捕获未预期接口调用。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 无音频设备的页面播放器。
class _Player implements NoteAudioPlayerService {
  /// 未选择音源。
  @override
  String? get currentPath => null;

  /// 无音源变化。
  @override
  Stream<String?> get currentPaths => const Stream.empty();

  /// 未播放。
  @override
  PlayerState get state => PlayerState.stopped;

  /// 无状态事件。
  @override
  Stream<PlayerState> get states => const Stream.empty();

  /// 无位置事件。
  @override
  Stream<Duration> get positions => const Stream.empty();

  /// 无时长事件。
  @override
  Stream<Duration> get durations => const Stream.empty();

  /// 无播放完成事件。
  @override
  Stream<void> get completions => const Stream.empty();

  /// 捕获未预期设备调用。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
