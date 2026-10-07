import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show OrderingTerm;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:omni_butler/features/todos/presentation/todo_progress_panel.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 验证进度面板顶部的紧凑操作布局及输入、预览和实际提交边界。
void main() {
  setUpAll(_loadTestFonts);

  _testPanel('桌面五百二十像素使用两行紧凑操作且加一只完成首个未完成步骤', (
    WidgetTester tester,
    AppDatabase database,
  ) async {
    // 简短名称对应常见的桌面操作场景。
    final TodoRecord record = await _createProgress(database, <String>[
      '读取材料',
      '检查条件',
      '记录结论',
      '归档笔记',
    ]);
    // 既有顺序和跳序完成项用于识别真正的下一个未完成目标。
    final List<TodoProgressStepRecord> original = await _readSteps(database);
    await TodoRepository(database)
        .setProgressStepsCompleted(record.id, <String>[original[1].id], true);
    // 完整面板的可选中文预览边界。
    final GlobalKey previewKey = await _openPanel(tester, database, record);
    // 下一项名称和实际加一按钮应位于同一行。
    final Rect nextLabel = tester.getRect(
      find.byKey(const ValueKey<String>('todo-progress-next-label')),
    );
    // 加一按钮保持原来的业务操作键。
    final Rect nextAction = tester.getRect(
      find.byKey(const ValueKey<String>('todo-progress-next')),
    );
    // 外置批量标签不再挤占输入框内部空间。
    final Rect batchLabel = tester.getRect(
      find.byKey(const ValueKey<String>('todo-progress-batch-label')),
    );
    // 批量数量只需要容纳短整数输入。
    final Rect batchInput = tester.getRect(
      find.byKey(const ValueKey<String>('todo-progress-batch-count')),
    );
    // 操作面板边界用于核对没有残留多余空行和大间隔。
    final Rect quickActions = tester.getRect(
      find.byKey(const ValueKey<String>('todo-progress-quick-actions')),
    );
    expect(
      nextLabel.center.dy,
      moreOrLessEquals(nextAction.center.dy, epsilon: 2),
    );
    expect(nextLabel.right, lessThanOrEqualTo(nextAction.left));
    expect(
      batchLabel.center.dy,
      moreOrLessEquals(batchInput.center.dy, epsilon: 2),
    );
    expect(batchLabel.right, lessThanOrEqualTo(batchInput.left));
    expect(batchInput.top, greaterThanOrEqualTo(nextAction.bottom));
    expect(batchInput.top - nextAction.bottom, lessThanOrEqualTo(20));
    expect(
      quickActions.height,
      lessThanOrEqualTo(nextAction.height + batchInput.height + 48),
    );
    expect(tester.takeException(), isNull);
    await _capturePreview(tester, previewKey, 'desktop-520-normal');
    await tester.tap(find.byKey(const ValueKey<String>('todo-progress-next')));
    await _settleDatabase(tester);
    // 加一只改变第一项，已经完成的第二项及后续两项不受影响。
    final List<TodoProgressStepRecord> saved = await _readSteps(database);
    expect(
      saved
          .where((TodoProgressStepRecord step) => step.isCompleted)
          .map((TodoProgressStepRecord step) => step.id),
      <String>[original[0].id, original[1].id],
    );
    expect(
      (await database.select(database.todoItems).get()).single.isCompleted,
      isFalse,
    );
    expect(
      find.byKey(const ValueKey<String>('todo-progress-confirm')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  _testPanel('安卓两倍字号长名称自动分行且无效批量数量不能提交', (
    WidgetTester tester,
    AppDatabase database,
  ) async {
    // 长名称覆盖下一项标题超出单行按钮组合宽度的场景。
    const String longName = '整理接口联调记录并核对所有异常处理分支和最终交付结果';
    // 四个未完成步骤让数量上下界与预览目标都可明确验证。
    final TodoRecord record = await _createProgress(database, <String>[
      longName,
      '检查规则',
      '整理结果',
      '完成复核',
    ]);
    // 大字号安卓面板的可选中文预览边界。
    final GlobalKey previewKey = await _openPanel(
      tester,
      database,
      record,
      viewport: const Size(360, 1100),
      textScale: 2,
      brightness: Brightness.light,
    );
    // 两倍字号下下一项名称在按钮上方，以保留可读文本宽度。
    final Rect nextLabel = tester.getRect(
      find.byKey(const ValueKey<String>('todo-progress-next-label')),
    );
    // 分行后的按钮仍保留独立点击区域。
    final Rect nextAction = tester.getRect(
      find.byKey(const ValueKey<String>('todo-progress-next')),
    );
    expect(nextAction.top, greaterThanOrEqualTo(nextLabel.bottom));
    // 重用公开输入键验证无效范围和非数字内容。
    final Finder batchInput = find.byKey(
      const ValueKey<String>('todo-progress-batch-count'),
    );
    await tester.ensureVisible(batchInput);
    // 三种非法输入都不能生成可提交的目标集合。
    for (final String invalid in <String>['0', '5', 'abc']) {
      await tester.enterText(batchInput, invalid);
      await tester.pumpAndSettle();
      expect(find.text('请输入 1 至 4 的整数'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('todo-progress-batch-submit')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    }
    // 错误信息位于整行下方，避免短输入框承担一整句错误文案。
    final Rect error = tester.getRect(find.text('请输入 1 至 4 的整数'));
    // 当前输入框的实际边界用于验证错误文案的可用宽度。
    final Rect input = tester.getRect(batchInput);
    expect(error.top, greaterThanOrEqualTo(input.bottom));
    expect(error.width, greaterThanOrEqualTo(input.width));
    await _capturePreview(
      tester,
      previewKey,
      'android-360-double-text-invalid',
    );
    await tester.enterText(batchInput, '2');
    await tester.pumpAndSettle();
    expect(find.text('请输入 1 至 4 的整数'), findsNothing);
    expect(find.text('将按顺序完成以下 2 个未完成步骤：'), findsOneWidget);
    expect(find.text('1. $longName\n2. 检查规则'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('todo-progress-batch-submit')),
      findsOneWidget,
    );
    // 预览本身不能修改步骤，提交边界仍由确认按钮控制。
    expect(
      (await _readSteps(database))
          .every((TodoProgressStepRecord step) => !step.isCompleted),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  }, platform: TargetPlatform.android);
}

/// 使用 SDK 自带字体稳定数字宽度，中文截图才依赖系统字体。
Future<void> _loadTestFonts() async {
  // 当前项目包配置记录实际 Flutter SDK 位置。
  final File packageConfigFile = File('.dart_tool/package_config.json')
      .absolute;
  // 相对包路径以配置文件 URI 为基准解析。
  final Map<String, dynamic> packageConfig = jsonDecode(
    await packageConfigFile.readAsString(),
  ) as Map<String, dynamic>;
  // 当前依赖包配置列表。
  final List<Map<String, dynamic>> packages =
      (packageConfig['packages'] as List<dynamic>).cast<Map<String, dynamic>>();
  // Flutter 包目录位于 SDK 的 packages 子目录。
  final Map<String, dynamic> flutterPackageConfig = packages.singleWhere(
    (Map<String, dynamic> package) => package['name'] == 'flutter',
  );
  // 目录 API 兼容配置路径是否包含末尾斜线。
  final Directory flutterPackage = Directory.fromUri(
    packageConfigFile.uri.resolve(flutterPackageConfig['rootUri'] as String),
  );
  // 运行时字体随 Flutter SDK 安装，无需新增资产。
  final Uri fontDirectory = flutterPackage.parent.parent.uri.resolve(
    'bin/cache/artifacts/material_fonts/',
  );
  // 普通回归可移植，显式预览使用雅黑显示中文。
  final File fontFile =
      Platform.environment['OMNI_PROGRESS_PANEL_PREVIEW'] == null
      ? File.fromUri(fontDirectory.resolve('roboto-regular.ttf'))
      : File('C:/Windows/Fonts/msyh.ttc');
  // 主题候选字体共享同一份字形数据。
  final ByteData font = ByteData.sublistView(await fontFile.readAsBytes());
  // Windows 与 Android 的候选字体家族。
  for (final String family in <String>[
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'Roboto',
    'Ahem',
  ]) {
    // 当前家族对应的字体加载器。
    final FontLoader loader = FontLoader(family);
    loader.addFont(Future<ByteData>.value(font));
    await loader.load();
  }
  // 图标使用 SDK 中的真实字体，避免预览中的占位方框。
  final FontLoader icons = FontLoader('MaterialIcons');
  icons.addFont(
    File.fromUri(fontDirectory.resolve('materialicons-regular.otf'))
        .readAsBytes()
        .then(ByteData.sublistView),
  );
  await icons.load();
}

/// 在框架检查之前卸载订阅、关闭数据库并恢复平台覆盖。
void _testPanel(
  String description,
  Future<void> Function(WidgetTester tester, AppDatabase database) callback, {
  TargetPlatform platform = TargetPlatform.windows,
}) {
  testWidgets(description, (WidgetTester tester) async {
    // 调用前的全局平台覆盖状态。
    final TargetPlatform? originalPlatform = debugDefaultTargetPlatformOverride;
    // 每个场景拥有独立数据库，并由同一层负责等待清理完成。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    debugDefaultTargetPlatformOverride = platform;
    try {
      await callback(tester, database);
    } finally {
      try {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      } finally {
        try {
          await tester.runAsync(database.close);
        } finally {
          debugDefaultTargetPlatformOverride = originalPlatform;
        }
      }
    }
  });
}

/// 经公开入口打开真实进度面板并注册视口复原。
Future<GlobalKey> _openPanel(
  WidgetTester tester,
  AppDatabase database,
  TodoRecord record, {
  Size viewport = const Size(520, 1000),
  double textScale = 1,
  Brightness brightness = Brightness.dark,
}) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // 完整导航树的边界包含侧滑面板与提示浮层。
  final GlobalKey previewKey = GlobalKey();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appDatabaseProvider.overrideWithValue(database)],
      child: RepaintBoundary(
        key: previewKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.build(brightness: brightness),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(
            body: Center(
              child: Builder(
                builder: (BuildContext context) => OmniButton(
                  label: '打开进度面板',
                  onPressed: () =>
                      TodoProgressPanel.show(context, record: record),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开进度面板'));
  await _settleDatabase(tester);
  return previewKey;
}

/// 创建具有明确名称顺序的真实进度任务。
Future<TodoRecord> _createProgress(
  AppDatabase database,
  List<String> names,
) async {
  await TodoRepository(database).save(
    TodoDraft(
      title: '阅读与整理计划',
      scheduledDate: DateTime(2026, 10, 7),
      taskType: TodoTaskType.progress,
      progressUnit: '章',
      progressSteps: names
          .map((String name) => TodoProgressStepDraft(name: name))
          .toList(),
    ),
  );
  return (await database.select(database.todoItems).get()).single;
}

/// 按真实顺序读取有效步骤以核对操作精确目标。
Future<List<TodoProgressStepRecord>> _readSteps(AppDatabase database) {
  // 已删除项不属于当前可操作集合。
  final query = database.select(database.todoProgressSteps)
    ..where((TodoProgressSteps table) => table.deletedAt.isNull())
    ..orderBy([(TodoProgressSteps table) => OrderingTerm.asc(table.sortOrder)]);
  return query.get();
}

/// 等待数据库流与界面动画更新。
Future<void> _settleDatabase(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 40)),
  );
  await tester.pumpAndSettle();
}

/// 仅在显式开启预览时输出中文截图。
Future<void> _capturePreview(
  WidgetTester tester,
  GlobalKey key,
  String name,
) async {
  if (Platform.environment['OMNI_PROGRESS_PANEL_PREVIEW'] == null) return;
  // 完整应用的绘制边界。
  final RenderRepaintBoundary boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    // 与其他功能预览保持相同输出层级。
    final Directory directory = Directory('output/todo-progress-panel-preview');
    await directory.create(recursive: true);
    // 逻辑像素截图便于比较真实控件间距。
    final ui.Image image = await boundary.toImage(pixelRatio: 1);
    try {
      // 使用引擎编码 PNG，不引入额外图片依赖。
      final ByteData bytes = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!;
      await File('${directory.path}/$name.png')
          .writeAsBytes(bytes.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}
