import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

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
import 'package:omni_butler/features/todos/presentation/todo_editor_dialog.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 验证待办时间设置的可选状态、真实选择保存及宽窄屏布局。
void main() {
  setUpAll(() async {
    // 当前项目生成的包配置为 Flutter 测试运行时提供可移植的 SDK 位置。
    final File packageConfigFile = File('.dart_tool/package_config.json')
        .absolute;
    // 配置中的相对 URI 必须以配置文件的位置为基准解析。
    final Map<String, dynamic> packageConfig = jsonDecode(
      await packageConfigFile.readAsString(),
    ) as Map<String, dynamic>;
    // 当前项目实际使用的全部依赖包配置。
    final List<Map<String, dynamic>> packages =
        (packageConfig['packages'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
    // Flutter 包所在目录固定属于当前 SDK 的 packages 子目录。
    final Map<String, dynamic> flutterPackageConfig = packages.singleWhere(
      (Map<String, dynamic> package) => package['name'] == 'flutter',
    );
    // 用目录 API 保留目录语义，兼容 rootUri 有无结尾斜线。
    final Directory flutterPackage = Directory.fromUri(
      packageConfigFile.uri.resolve(flutterPackageConfig['rootUri'] as String),
    );
    // Flutter SDK 自带字体与测试运行时一起安装，常规回归无需新增资产。
    final Uri fontDirectory = flutterPackage.parent.parent.uri.resolve(
      'bin/cache/artifacts/material_fonts/',
    );
    // 数字使用真实 Roboto 字宽；只有显式中文预览依赖系统雅黑字体。
    final File fontFile =
        Platform.environment['OMNI_TIME_SETTINGS_PREVIEW'] == null
        ? File.fromUri(fontDirectory.resolve('roboto-regular.ttf'))
        : File('C:/Windows/Fonts/msyh.ttc');
    // 可重复加载的字节为主题所有候选字体提供一致的数字度量。
    final ByteData font = ByteData.sublistView(await fontFile.readAsBytes());
    // 主题可能采用的字体家族共享同一份测试字体。
    for (final String family in <String>[
      'Microsoft YaHei UI',
      'Microsoft YaHei',
      'Roboto',
      'Ahem',
    ]) {
      // 当前家族对应的测试字体加载器。
      final FontLoader loader = FontLoader(family);
      loader.addFont(Future<ByteData>.value(font));
      await loader.load();
    }
    // 图标字体保证预览中的加号、时钟及箭头可辨认。
    final FontLoader icons = FontLoader('MaterialIcons');
    icons.addFont(
      File.fromUri(fontDirectory.resolve('materialicons-regular.otf'))
          .readAsBytes()
          .then(ByteData.sublistView),
    );
    await icons.load();
  });

  _testEditor('新增待办未添加截止和提醒时不显示默认时间且保存为空', (WidgetTester tester) async {
    // 本次新增测试独立使用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 新增弹窗的完整渲染边界，供可选中文预览使用。
    final GlobalKey previewKey = await _openEditor(tester, database);
    expect(find.text('新增待办'), findsOneWidget);
    expect(find.text('先保存到本机，联网后再同步。'), findsNothing);
    await tester.enterText(find.byType(TextFormField).first, '整理本周发票');
    await _expandTimeSettings(tester);
    expect(find.text('添加截止'), findsOneWidget);
    expect(find.text('添加提醒'), findsOneWidget);
    expect(find.byType(OmniTimePickerButton), findsNothing);
    expect(find.byTooltip('清除截止时间'), findsNothing);
    expect(find.byTooltip('清除提醒时间'), findsNothing);
    expect(find.text('计划日期、截止与提醒'), findsNothing);
    await _capturePreview(tester, previewKey, 'create-empty-dark');
    await _saveEditor(tester);
    // 未选择的默认小时不能意外写成真实截止或提醒。
    final TodoRecord saved =
        (await database.select(database.todoItems).get()).single;
    expect(saved.scheduledDate, DateTime(2026, 10, 7));
    expect(saved.dueAt, isNull);
    expect(saved.reminderAt, isNull);
    expect(saved.repeatRule, isNull);
  });

  _testEditor('新增待办通过日期时间浮层设置并保存计划截止提醒和重复', (WidgetTester tester) async {
    // 本次完整设置流程使用的独立数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    await _openEditor(tester, database);
    await tester.enterText(find.byType(TextFormField).first, '提交季度报告');
    await _expandTimeSettings(tester);
    await _chooseDay(tester, find.byType(OmniDatePickerButton).first, '9');
    await _chooseDay(tester, find.text('添加截止'), '15');
    expect(find.byType(OmniTimePickerButton), findsOneWidget);
    expect(find.text('18:00'), findsOneWidget);
    await _chooseTime(tester, '18:00', '18:30');
    await _chooseDay(tester, find.text('添加提醒'), '14');
    expect(find.text('09:00'), findsOneWidget);
    await _chooseTime(tester, '09:00', '09:30');
    await tester.ensureVisible(find.text('不重复'));
    await tester.tap(find.text('不重复'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('每周'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('时间设置'));
    await tester.tap(find.text('时间设置'));
    await tester.pumpAndSettle();
    expect(find.text('添加截止'), findsNothing);
    // 摘要保留所有已生效字段；日期允许当年短格式或跨年完整格式。
    final String summary = tester
        .widget<Text>(find.textContaining('计划 '))
        .data!;
    expect(summary, matches(RegExp(r'计划 (10月9日|2026/10/9)')));
    expect(summary, matches(RegExp(r'截止 (10月15日|2026/10/15) 18:30')));
    expect(summary, matches(RegExp(r'提醒 (10月14日|2026/10/14) 09:30')));
    await _saveEditor(tester);
    // 数据库值验证选择器回调及保存路径都使用用户实际选择。
    final TodoRecord saved =
        (await database.select(database.todoItems).get()).single;
    expect(saved.scheduledDate, DateTime(2026, 10, 9));
    expect(saved.dueAt, DateTime(2026, 10, 15, 18, 30));
    expect(saved.reminderAt, DateTime(2026, 10, 14, 9, 30));
    expect(saved.repeatRule, TodoRepeatRule.weekly.name);
  });

  _testEditor('编辑待办清除截止不移动提醒时间列且可清空后保存', (WidgetTester tester) async {
    // 编辑场景的内存数据库及既有时间数据。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 通过真实仓储准备已有待办。
    final TodoRecord record = await _createScheduledTodo(database);
    // 编辑弹窗的完整渲染边界。
    final GlobalKey previewKey = await _openEditor(
      tester,
      database,
      record: record,
    );
    expect(find.text('编辑待办'), findsOneWidget);
    expect(find.text('先保存到本机，联网后再同步。'), findsNothing);
    await _expandTimeSettings(tester);
    _expectAlignedTimeColumns(tester);
    expect(
      tester.getRect(find.text('计划日期')).right,
      lessThan(tester.getRect(find.byType(OmniDatePickerButton).first).left),
    );
    expect(
      tester.getTopLeft(find.text('计划日期')).dx,
      moreOrLessEquals(tester.getTopLeft(find.text('重复')).dx),
    );
    // 清除前提醒时间的横坐标，确保另一行状态变化不影响本行。
    final double reminderLeft = tester
        .getTopLeft(find.byType(OmniTimePickerButton).last)
        .dx;
    await _capturePreview(tester, previewKey, 'edit-filled-dark');
    await tester.tap(find.byTooltip('清除截止时间'));
    await tester.pumpAndSettle();
    expect(find.text('添加截止'), findsOneWidget);
    expect(find.byType(OmniTimePickerButton), findsOneWidget);
    expect(
      tester.getTopLeft(find.byType(OmniTimePickerButton)).dx,
      moreOrLessEquals(reminderLeft),
    );
    await tester.tap(find.byTooltip('清除提醒时间'));
    await tester.pumpAndSettle();
    expect(find.text('添加提醒'), findsOneWidget);
    expect(find.byType(OmniTimePickerButton), findsNothing);
    await _saveEditor(tester);
    // 清除既有值必须持久化为空，且不改变计划日期。
    final TodoRecord saved =
        (await database.select(database.todoItems).get()).single;
    expect(saved.id, record.id);
    expect(saved.scheduledDate, record.scheduledDate);
    expect(saved.dueAt, isNull);
    expect(saved.reminderAt, isNull);
  });

  _testEditor('窄屏及放大字号下时间标签上置且日期时间仍同排可操作', (WidgetTester tester) async {
    // 窄屏编辑场景的数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 已设日期和分钟可揭露窄屏真实的横向空间需求。
    final TodoRecord record = await _createScheduledTodo(database);
    // 放大字号的窄屏预览边界。
    final GlobalKey previewKey = await _openEditor(
      tester,
      database,
      record: record,
      viewport: const Size(360, 1100),
      textScale: 1.4,
      brightness: Brightness.light,
    );
    await _expandTimeSettings(tester);
    await tester.ensureVisible(find.text('不重复'));
    await tester.pumpAndSettle();
    // 计划日期标签在控件上方，避免窄屏继续挤压日期列。
    final Rect scheduledLabel = tester.getRect(find.text('计划日期'));
    // 日期控件在显示树中的顺序为计划、截止、提醒。
    final Rect scheduledControl = tester.getRect(
      find.byType(OmniDatePickerButton).first,
    );
    expect(scheduledLabel.bottom, lessThanOrEqualTo(scheduledControl.top));
    _expectAlignedTimeColumns(tester);
    expect(tester.takeException(), isNull);
    await _capturePreview(tester, previewKey, 'edit-narrow-large-text-light');
    await tester.ensureVisible(find.byTooltip('清除提醒时间'));
    await tester.tap(find.byTooltip('清除提醒时间'));
    await tester.pumpAndSettle();
    expect(find.text('添加提醒'), findsOneWidget);
    await _saveEditor(tester);
    // 窄屏中清除功能仍正常提交，截止时间保留原始分钟。
    final TodoRecord saved =
        (await database.select(database.todoItems).get()).single;
    expect(saved.dueAt, record.dueAt);
    expect(saved.reminderAt, isNull);
  });

  _testEditor('安卓窄屏两倍字号完整显示跨年日期且清除可保存', (WidgetTester tester) async {
    // 移动端可访问性回归使用的独立数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 始终取下一年，保证测试不会因日历年份变化而失去跨年覆盖。
    final int followingYear = DateTime.now().year + 1;
    // 已有跨年计划、截止及提醒同时验证完整日期的可读性。
    final TodoRecord record = await _createScheduledTodo(
      database,
      year: followingYear,
    );
    // 安卓两倍字号的完整预览边界。
    final GlobalKey previewKey = await _openEditor(
      tester,
      database,
      record: record,
      viewport: const Size(360, 1100),
      textScale: 2,
      brightness: Brightness.light,
    );
    await _expandTimeSettings(tester);
    await tester.ensureVisible(find.text('不重复'));
    await tester.pumpAndSettle();
    // 三个日期都必须完整排版，不能只在语义文本中保留被省略的年份。
    for (final String date in <String>[
      '$followingYear/10/7',
      '$followingYear/10/15',
      '$followingYear/10/14',
    ]) {
      // 实际绘制的文字段落直接提供是否被省略的证据。
      final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
        find.text(date),
      );
      expect(paragraph.didExceedMaxLines, isFalse, reason: date);
    }
    // 极窄或大字号下截止日期独占上一行，时间仍有完整点击空间。
    final Rect dueDate = tester.getRect(
      find.byType(OmniDatePickerButton).at(1),
    );
    // 截止时间位于日期下方，避免横排挤压跨年内容。
    final Rect dueTime = tester.getRect(
      find.byType(OmniTimePickerButton).first,
    );
    expect(dueDate.bottom, lessThanOrEqualTo(dueTime.top));
    expect(tester.takeException(), isNull);
    await _capturePreview(
      tester,
      previewKey,
      'edit-android-double-text-next-year',
    );
    await tester.ensureVisible(find.byTooltip('清除截止时间'));
    await tester.tap(find.byTooltip('清除截止时间'));
    await tester.pumpAndSettle();
    expect(find.text('添加截止'), findsOneWidget);
    await _saveEditor(tester);
    // 清除实际写入空值，另一行跨年提醒保持原始日期和分钟。
    final TodoRecord saved =
        (await database.select(database.todoItems).get()).single;
    expect(saved.dueAt, isNull);
    expect(saved.reminderAt, record.reminderAt);
  }, platform: TargetPlatform.android);

  _testEditor('新增子任务隐藏计划和重复并继承父任务日期保存截止', (WidgetTester tester) async {
    // 子任务继承规则使用独立数据库验证持久化结果。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 真实存在的父任务提供子任务上下文。
    final TodoRecord parent = await _createScheduledTodo(database);
    await _openEditor(tester, database, parent: parent);
    expect(find.text('新增子任务'), findsOneWidget);
    expect(find.textContaining('所属主任务：'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).first, '核对发票明细');
    await _expandTimeSettings(tester);
    expect(find.text('计划日期'), findsNothing);
    expect(find.text('重复'), findsNothing);
    expect(find.text('不重复'), findsNothing);
    expect(find.text('截止时间'), findsOneWidget);
    expect(find.text('提醒时间'), findsOneWidget);
    await _chooseDay(tester, find.text('添加截止'), '15');
    await _saveEditor(tester);
    // 仅定位新建子任务，避免把父任务原有值误当作保存证据。
    final TodoRecord saved = (await database.select(database.todoItems).get())
        .singleWhere((TodoRecord todo) => todo.parentId == parent.id);
    expect(saved.scheduledDate, parent.scheduledDate);
    expect(saved.priorityQuadrant, parent.priorityQuadrant);
    expect(saved.repeatRule, isNull);
    expect(saved.dueAt, DateTime(2026, 10, 15, 18));
    expect(saved.reminderAt, isNull);
  });

  _testEditor('进度任务删除冗余提示并继续隐藏重复设置', (WidgetTester tester) async {
    // 进度任务编辑器使用的独立数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    await _openEditor(tester, database);
    await tester.tap(find.text('进度任务'));
    await tester.pumpAndSettle();
    expect(find.text('步骤可跳序完成，名称可留空。进度任务不支持子任务和重复。'), findsNothing);
    expect(find.text('1 至 1000'), findsNothing);
    expect(find.text('1至1000'), findsNothing);
    await _expandTimeSettings(tester);
    expect(find.text('计划日期'), findsOneWidget);
    expect(find.text('截止时间'), findsOneWidget);
    expect(find.text('提醒时间'), findsOneWidget);
    expect(find.text('重复'), findsNothing);
    expect(find.text('不重复'), findsNothing);
  });
}

/// 在框架检查全局状态前复原平台覆盖，即使业务断言失败也保证清理。
void _testEditor(
  String description,
  Future<void> Function(WidgetTester tester) callback, {
  TargetPlatform platform = TargetPlatform.windows,
}) {
  testWidgets(description, (WidgetTester tester) async {
    // 保存进入测试前的平台覆盖，避免污染后续测试的布局密度。
    final TargetPlatform? originalPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = platform;
    try {
      await callback(tester);
    } finally {
      debugDefaultTargetPlatformOverride = originalPlatform;
    }
  });
}

/// 通过公开入口打开真实侧滑弹窗并统一释放数据库及视口。
Future<GlobalKey> _openEditor(
  WidgetTester tester,
  AppDatabase database, {
  TodoRecord? record,
  TodoRecord? parent,
  Size viewport = const Size(1000, 1100),
  double textScale = 1,
  Brightness brightness = Brightness.dark,
}) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(database.close);
  });
  // 包含路由浮层的完整渲染边界。
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
                  label: '打开待办',
                  onPressed: () => TodoEditorDialog.show(
                    context,
                    record: record,
                    parent: parent,
                    initialDate: DateTime(2026, 10, 7),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开待办'));
  await tester.pumpAndSettle();
  return previewKey;
}

/// 创建可在编辑弹窗中修改的普通任务，避免重复系列确认干扰清除回归。
Future<TodoRecord> _createScheduledTodo(
  AppDatabase database, {
  int year = 2026,
}) async {
  await TodoRepository(database).save(
    TodoDraft(
      title: '整理本周发票',
      scheduledDate: DateTime(year, 10, 7),
      dueAt: DateTime(year, 10, 15, 18, 30),
      reminderAt: DateTime(year, 10, 14, 9, 30),
    ),
  );
  return (await database.select(database.todoItems).get()).single;
}

/// 展开时间设置前先滚动到实际标题位置。
Future<void> _expandTimeSettings(WidgetTester tester) async {
  // 安卓编辑既有时间时默认展开，不重复点击将其收起。
  final ExpansionTile settings = tester.widget<ExpansionTile>(
    find.byKey(const ValueKey<String>('todo-time-settings')),
  );
  if (settings.controller?.isExpanded == true) return;
  await tester.ensureVisible(find.text('时间设置'));
  await tester.tap(find.text('时间设置'));
  await tester.pumpAndSettle();
}

/// 真实点击日期浮层中的某日，避免绕过按钮回调直接修改状态。
Future<void> _chooseDay(WidgetTester tester, Finder trigger, String day) async {
  await tester.ensureVisible(trigger);
  await tester.tap(trigger);
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(of: find.byType(GridView), matching: find.text(day)),
  );
  await tester.pumpAndSettle();
}

/// 真实点击时间菜单中的半小时时刻。
Future<void> _chooseTime(
  WidgetTester tester,
  String current,
  String selected,
) async {
  await tester.ensureVisible(find.text(current));
  await tester.tap(find.text(current));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(MenuItemButton, selected));
  await tester.pumpAndSettle();
}

/// 检查日期、时间及清除三个操作列对齐并且互不覆盖。
void _expectAlignedTimeColumns(WidgetTester tester) {
  // 截止行的日期控件边界。
  final Rect dueDate = tester.getRect(find.byType(OmniDatePickerButton).at(1));
  // 提醒行的日期控件边界。
  final Rect reminderDate = tester.getRect(
    find.byType(OmniDatePickerButton).at(2),
  );
  // 截止行的时间控件边界。
  final Rect dueTime = tester.getRect(find.byType(OmniTimePickerButton).first);
  // 提醒行的时间控件边界。
  final Rect reminderTime = tester.getRect(
    find.byType(OmniTimePickerButton).last,
  );
  // 截止行的清除热区。
  final Rect dueClear = tester.getRect(find.byTooltip('清除截止时间'));
  // 提醒行的清除热区。
  final Rect reminderClear = tester.getRect(find.byTooltip('清除提醒时间'));
  expect(dueDate.left, moreOrLessEquals(reminderDate.left));
  expect(dueDate.width, moreOrLessEquals(reminderDate.width));
  expect(dueTime.left, moreOrLessEquals(reminderTime.left));
  expect(dueClear.left, moreOrLessEquals(reminderClear.left));
  expect(dueDate.center.dy, moreOrLessEquals(dueTime.center.dy));
  expect(reminderDate.center.dy, moreOrLessEquals(reminderTime.center.dy));
  expect(dueDate.right, lessThanOrEqualTo(dueTime.left));
  expect(dueTime.right, lessThanOrEqualTo(dueClear.left));
  expect(reminderDate.right, lessThanOrEqualTo(reminderTime.left));
  expect(reminderTime.right, lessThanOrEqualTo(reminderClear.left));
}

/// 点击真实保存按钮并等待数据库异步写入及关闭动画。
Future<void> _saveEditor(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(OmniButton, '保存'));
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 40)),
  );
  await tester.pumpAndSettle();
  expect(find.byType(TodoEditorDialog), findsNothing);
  expect(tester.takeException(), isNull);
}

/// 仅显式启用环境变量时导出人工审查用截图，不写入测试基线。
Future<void> _capturePreview(
  WidgetTester tester,
  GlobalKey key,
  String name,
) async {
  if (Platform.environment['OMNI_TIME_SETTINGS_PREVIEW'] == null) return;
  // 当前应用的完整渲染边界。
  final RenderRepaintBoundary boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    // 截图目录与现有功能预览保持同一层级。
    final Directory directory = Directory('output/todo-time-settings-preview');
    await directory.create(recursive: true);
    // 按逻辑像素导出 PNG，便于比较窄屏文字与控件间距。
    final ui.Image image = await boundary.toImage(pixelRatio: 1);
    try {
      // 完整 PNG 字节由引擎编码，避免额外图像依赖。
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
