import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/omni_butler_app.dart';
import 'package:omni_butler/app/router/app_router.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/floating/presentation/floating_window_page.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:omni_butler/features/todos/presentation/todo_progress_panel.dart';
import 'package:omni_butler/features/todos/presentation/todo_progress_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证真实业务入口使用同一份进度及手动完成规则。
void main() {
  setUpAll(() async {
    if (Platform.environment['OMNI_PROGRESS_PREVIEW'] == null) return;
    // 预览才加载中文字体，常规测试不依赖开发机字体路径。
    final ByteData font = ByteData.sublistView(
      await File('C:/Windows/Fonts/msyh.ttc').readAsBytes(),
    );
    for (final String family in <String>[
      'Microsoft YaHei UI',
      'Microsoft YaHei',
      'Roboto',
      'Ahem',
    ]) {
      // 每种主题字体共享同一份中文字体内容。
      final FontLoader loader = FontLoader(family);
      loader.addFont(Future<ByteData>.value(font));
      await loader.load();
    }
    // 实际预览同时加载图标字体，避免测试环境的占位方框。
    final FontLoader icons = FontLoader('MaterialIcons');
    icons.addFont(
      File(
        'D:/program/code/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ).readAsBytes().then(ByteData.sublistView),
    );
    await icons.load();
  });

  testWidgets('首页与四象限共享跳序进度，满进度必须确认', (WidgetTester tester) async {
    await _withProgress(tester, (fixture) async {
      expect(find.textContaining('已完成 3/12'), findsOneWidget);
      expect(find.byType(TodoProgressTaskTile), findsOneWidget);
      await _capture(tester, fixture, 'home');
      fixture.container.read(appRouterProvider).go('/todos');
      await tester.pumpAndSettle();
      expect(find.textContaining('已完成 3/12'), findsOneWidget);
      await _capture(tester, fixture, 'todos');
      await tester.tap(
        find.byKey(ValueKey<String>('progress-update-${fixture.todo.id}')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TodoProgressPanel), findsOneWidget);
      await _capture(tester, fixture, 'panel');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await fixture.repository.setProgressStepsCompleted(
        fixture.todo.id,
        fixture.steps.map((step) => step.id).toList(),
        true,
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('待确认完成'), findsOneWidget);
      expect((await fixture.readTodo())!.isCompleted, isFalse);
      await tester.tap(
        find.byKey(ValueKey<String>('progress-confirm-${fixture.todo.id}')),
      );
      // 完成反馈先等待固定勾选时长，不能只依赖尚未排帧的动画判断。
      await tester.pump(const Duration(seconds: 1));
      // 撤销消息持续绘制倒计时；等待全部动画会直接耗尽六秒撤销窗口。
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect((await fixture.readTodo())!.isCompleted, isTrue);
      expect(find.byType(TodoProgressTaskTile), findsNothing);
      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      expect(find.textContaining('待确认完成'), findsOneWidget);
      expect(
        (await fixture.readSteps()).every((step) => step.isCompleted),
        isTrue,
      );
    });
  });

  testWidgets('Android窄屏进度可打开且不抢占横滑切页', (WidgetTester tester) async {
    await _withProgress(
      tester,
      (fixture) async {
        fixture.container.read(appRouterProvider).go('/todos');
        await tester.pumpAndSettle();
        expect(find.textContaining('已完成 3/12'), findsOneWidget);
        await _capture(tester, fixture, 'android-todos');
        await tester.tap(
          find.byKey(ValueKey<String>('progress-update-${fixture.todo.id}')),
        );
        await tester.pumpAndSettle();
        expect(find.byType(TodoProgressPanel), findsOneWidget);
        await _capture(tester, fixture, 'android-panel');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        await tester.fling(
          find.byKey(const ValueKey<String>('todo-mobile-swipe-surface')),
          const Offset(-180, 0),
          800,
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey<String>('todo-mobile-section-3-focused')),
          findsOneWidget,
        );
        expect(
          (await fixture.readSteps()).where((step) => step.isCompleted).length,
          3,
        );
      },
      platform: TargetPlatform.android,
      size: const Size(390, 844),
    );
  });

  testWidgets('最小悬浮窗只展示比例，点击打开当前窗口内进度面板', (WidgetTester tester) async {
    await _withProgress(
      tester,
      (fixture) async {
        // 悬浮窗与主窗口共用容器，不启动任何真实窗口服务。
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: fixture.container,
            child: RepaintBoundary(
              key: fixture.previewKey,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: AppTheme.build(brightness: Brightness.light),
                home: FloatingWindowPage(
                  onClose: () async {},
                  onOpenRoute: (String location) async {},
                  onDragStart: () {},
                  onDragUpdate: () {},
                  onDragEnd: () async {},
                  onResizeStart: () {},
                  onResizeUpdate: () {},
                  onResizeEnd: () async {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(
            ValueKey<String>('floating-todo-progress-${fixture.todo.id}'),
          ),
          findsOneWidget,
        );
        expect(find.text('3/12'), findsOneWidget);
        await _capture(tester, fixture, 'floating');
        await tester.tap(
          find.byKey(
            ValueKey<String>('floating-todo-complete-${fixture.todo.id}'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(TodoProgressPanel), findsOneWidget);
        expect((await fixture.readTodo())!.isCompleted, isFalse);
        await _capture(tester, fixture, 'floating-panel');
      },
      size: const Size(294, 500),
      mountApp: false,
    );
  });
}

/// 每个入口测试独占的业务数据与应用依赖。
class _ProgressFixture {
  /// 测试仓储。
  final TodoRepository repository;

  /// 共享依赖容器。
  final ProviderContainer container;

  /// 任务身份。
  final TodoRecord todo;

  /// 原始有序步骤。
  final List<TodoProgressStepRecord> steps;

  /// 可选截图的隔离渲染边界。
  final GlobalKey previewKey = GlobalKey();

  /// 创建测试上下文。
  _ProgressFixture(this.repository, this.container, this.todo, this.steps);

  /// 直接读取当前任务，避免组件测试假时钟等待流首次事件。
  Future<TodoRecord?> readTodo() async {
    // 本用例独占数据库只包含一个任务。
    final AppDatabase database = container.read(appDatabaseProvider);
    return database.select(database.todoItems).getSingleOrNull();
  }

  /// 直接读取当前步骤状态，不触发新的流订阅计时器。
  Future<List<TodoProgressStepRecord>> readSteps() async {
    // 从共享容器取出隔离的数据库。
    final AppDatabase database = container.read(appDatabaseProvider);
    return database.select(database.todoProgressSteps).get();
  }
}

/// 使用内存数据库建立12章且第1、3、8章已完成的任务。
Future<void> _withProgress(
  WidgetTester tester,
  Future<void> Function(_ProgressFixture fixture) verify, {
  TargetPlatform platform = TargetPlatform.windows,
  Size size = const Size(1440, 900),
  bool mountApp = true,
}) async {
  // 本轮内存数据库与仓储。
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  // 完全复用生产业务规则的数据入口。
  final TodoRepository repository = TodoRepository(database);
  // 使用当前自然日使手动完成时间与历史视图一致。
  final DateTime now = DateTime.now();
  // 安全释放可能尚未创建完成的容器。
  ProviderContainer? container;
  try {
    await repository.save(
      TodoDraft(
        title: '阅读《设计心理学》',
        scheduledDate: now,
        taskType: TodoTaskType.progress,
        progressUnit: '章',
        progressSteps: List<TodoProgressStepDraft>.generate(
          12,
          (int index) => TodoProgressStepDraft(
            name: index == 0
                ? '日常设计的心理学'
                : index == 2
                ? '头脑中的知识与外界知识'
                : null,
          ),
        ),
      ),
    );
    // 创建后的稳定任务标识。
    final TodoRecord todo = await database
        .select(database.todoItems)
        .getSingle();
    // 原始步骤顺序，用于验证跳序记录。
    final List<TodoProgressStepRecord> steps = await database
        .select(database.todoProgressSteps)
        .get();
    steps.sort((left, right) => left.sortOrder.compareTo(right.sortOrder));
    await repository.setProgressStepsCompleted(todo.id, <String>[
      steps[0].id,
      steps[2].id,
      steps[7].id,
    ], true);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'home.cards.order': <String>['todos', 'todayContext'],
    });
    // 独立偏好，不接触正式设备设置。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        appDatabaseProvider.overrideWithValue(database),
        nowProvider.overrideWithValue(now),
      ],
    );
    debugDefaultTargetPlatformOverride = platform;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    // 供各入口复用的上下文。
    final _ProgressFixture fixture = _ProgressFixture(
      repository,
      container,
      todo,
      steps,
    );
    if (mountApp) {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: RepaintBoundary(
            key: fixture.previewKey,
            child: const OmniButlerApp(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }
    await verify(fixture);
    expect(tester.takeException(), isNull);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container?.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    // Drift会等待已关闭流的缓存清理计时器，推进假时钟后再等待关闭。
    final Future<void> closing = database.close();
    await tester.pump(const Duration(seconds: 1));
    await closing;
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    debugDefaultTargetPlatformOverride = null;
  }
}

/// 按显式环境开关导出隔离业务界面，常规测试不写截图。
Future<void> _capture(
  WidgetTester tester,
  _ProgressFixture fixture,
  String name,
) async {
  // 可选预览输出目录。
  final String? output = Platform.environment['OMNI_PROGRESS_PREVIEW'];
  if (output == null) return;
  await tester.pumpAndSettle();
  // 当前页面的专属渲染边界。
  final RenderRepaintBoundary boundary =
      fixture.previewKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
  await tester.runAsync(() async {
    // 当前界面完整像素；编码和文件写入使用真实异步执行环境。
    final ui.Image image = await boundary.toImage();
    try {
      // 无损PNG编码。
      final ByteData png = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!;
      await Directory(output).create(recursive: true);
      await File('$output/$name.png').writeAsBytes(png.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}
