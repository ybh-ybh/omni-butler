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
import 'package:omni_butler/features/todos/presentation/todo_editor_dialog.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 验证进度编辑器的紧凑布局及真实编辑、保存和焦点行为。
void main() {
  setUpAll(_loadTestFonts);

  _testEditor('新增进度任务的数量更新和单位同排且四个步骤无需内部滚动', (WidgetTester tester) async {
    // 新建流程使用独立数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 完整弹窗的预览边界。
    final GlobalKey previewKey = await _openEditor(tester, database);
    // 步骤总数和更新操作的公开控件。
    final Finder total = find.byKey(
      const ValueKey<String>('todo-progress-total'),
    );
    // 保留的操作键让测试验证实际点击后的结构变化。
    final Finder update = find.byKey(
      const ValueKey<String>('todo-progress-apply-total'),
    );
    // 单位输入框与步骤数量共享一行。
    final Finder unit = find.byKey(
      const ValueKey<String>('todo-progress-unit'),
    );
    expect(tester.widget<OmniButton>(update).onPressed, isNull);
    expect(
      tester.getRect(total).center.dy,
      moreOrLessEquals(tester.getRect(update).center.dy, epsilon: 3),
    );
    expect(
      tester.getRect(total).center.dy,
      moreOrLessEquals(tester.getRect(unit).center.dy, epsilon: 3),
    );
    await tester.enterText(total, '4');
    await tester.pump();
    expect(tester.widget<OmniButton>(update).onPressed, isNotNull);
    await tester.tap(update);
    await tester.pumpAndSettle();
    expect(tester.widget<OmniButton>(update).onPressed, isNull);
    await _expandSteps(tester);
    expect(find.text('步骤列表 · 4 项'), findsOneWidget);
    expect(_stepFields(), findsNWidgets(4));
    _expectNoInnerVerticalScroll(tester);
    _expectFullyVisible(tester, _stepFields().first);
    _expectFullyVisible(tester, _stepFields().last);
    expect(
      find.descendant(of: unit, matching: find.text('0/10')),
      findsNothing,
    );
    expect(
      find.descendant(of: _stepFields(), matching: find.text('0/200')),
      findsNothing,
    );
    await _capturePreview(tester, previewKey, 'create-four-steps-dark');
  });

  _testEditor('编辑五个步骤自然展示且行内名称与操作对齐', (WidgetTester tester) async {
    // 五步边界用于验证短列表完整显示。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 五个步骤都通过仓储创建，避免跳过加载流程。
    final TodoRecord record = await _createProgress(database, count: 5);
    // 编辑状态的预览边界。
    final GlobalKey previewKey = await _openEditor(
      tester,
      database,
      record: record,
    );
    expect(find.text('共 5 步'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('todo-progress-total')),
      findsNothing,
    );
    expect(find.text('步骤列表 · 5 项'), findsOneWidget);
    expect(_stepFields(), findsNWidgets(5));
    _expectNoInnerVerticalScroll(tester);
    _expectFullyVisible(tester, _stepFields().first);
    _expectFullyVisible(tester, _stepFields().last);
    expect(
      tester.getRect(_stepFields().first).center.dy,
      moreOrLessEquals(tester.getRect(find.byTooltip('下移步骤 1')).center.dy),
    );
    expect(
      tester
          .widget<OmniTextFormField>(
            find.byKey(const ValueKey<String>('todo-progress-unit')),
          )
          .enabled,
      isTrue,
    );
    await _capturePreview(tester, previewKey, 'edit-five-steps-dark');
  });

  _testEditor('安卓窄屏通过步骤菜单移动和删除且保存稳定标识与完成状态', (WidgetTester tester) async {
    // 窄屏菜单使用的独立数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 三个命名步骤让删除触发真实确认流程。
    final TodoRecord record = await _createProgress(
      database,
      count: 3,
      named: true,
    );
    // 初始稳定标识用于核对移动后没有创建替代步骤。
    final List<TodoProgressStepRecord> original = await _readSteps(database);
    await TodoRepository(
      database,
    ).setProgressStepsCompleted(record.id, <String>[original.first.id], true);
    // 原有完成时刻必须随步骤移动而保留。
    final DateTime? completedAt = (await _readSteps(database))
        .first
        .completedAt;
    // 安卓菜单布局的预览边界。
    final GlobalKey previewKey = await _openEditor(
      tester,
      database,
      record: record,
      viewport: const Size(360, 1100),
      brightness: Brightness.light,
    );
    expect(find.byTooltip('步骤 1 操作'), findsOneWidget);
    expect(find.byTooltip('下移步骤 1'), findsNothing);
    await _capturePreview(tester, previewKey, 'edit-android-step-menu');
    await _chooseStepAction(tester, 1, '下移');
    await _chooseStepAction(tester, 3, '上移');
    await _chooseStepAction(tester, 2, '删除');
    expect(find.text('删除这些步骤？'), findsOneWidget);
    await tester.tap(find.widgetWithText(OmniButton, '删除步骤'));
    await tester.pumpAndSettle();
    expect(find.text('步骤列表 · 2 项'), findsOneWidget);
    await _saveEditor(tester);
    // 下移第一项、上移第三项并删除第三项后，前两项顺序交换。
    final List<TodoProgressStepRecord> saved = await _readSteps(database);
    expect(saved.map((TodoProgressStepRecord step) => step.id), <String>[
      original[1].id,
      original[0].id,
    ]);
    expect(saved.first.isCompleted, isFalse);
    expect(saved.last.isCompleted, isTrue);
    expect(saved.last.completedAt, completedAt);
    expect(saved.last.name, original.first.name);
  }, platform: TargetPlatform.android);

  _testEditor('从折叠长列表添加步骤后自动展开并将新名称定位聚焦', (WidgetTester tester) async {
    // 长列表添加流程使用的独立数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 十二项确保列表确实需要内部滚动。
    final TodoRecord record = await _createProgress(database, count: 12);
    // 添加后最后一项的预览边界。
    final GlobalKey previewKey = await _openEditor(
      tester,
      database,
      record: record,
    );
    await tester.ensureVisible(find.text('步骤列表 · 12 项'));
    await tester.tap(find.text('步骤列表 · 12 项'));
    await tester.pumpAndSettle();
    expect(_stepFields(), findsNothing);
    await tester.ensureVisible(find.text('添加步骤'));
    await tester.tap(find.text('添加步骤'));
    await tester.pumpAndSettle();
    expect(find.text('步骤列表 · 13 项'), findsOneWidget);
    // 新增行必须实际获得键盘焦点，不能只改变滚动位置。
    final Finder focused = find.descendant(
      of: find.byKey(const ValueKey<String>('todo-progress-step-names')),
      matching: find.byWidgetPredicate(
        (Widget widget) =>
            widget is OmniTextFormField && widget.focusNode?.hasFocus == true,
      ),
    );
    expect(focused, findsOneWidget);
    _expectFullyVisible(tester, focused);
    expect(tester.widget<OmniTextFormField>(focused).controller!.text, isEmpty);
    await tester.enterText(focused, '追加收尾章节');
    await _capturePreview(tester, previewKey, 'edit-long-list-added-step');
    await _saveEditor(tester);
    // 可见且聚焦的行必须对应持久化结构的最后一项。
    final List<TodoProgressStepRecord> saved = await _readSteps(database);
    expect(saved, hasLength(13));
    expect(saved.last.name, '追加收尾章节');
    expect(saved.last.isCompleted, isFalse);
  });

  _testEditor('单位和名称仅在接近上限时显示内部计数且仍限制输入长度', (WidgetTester tester) async {
    // 输入限制测试使用独立数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    await _openEditor(tester, database);
    await _expandSteps(tester);
    // 单位控件的边界用于验证计数留在输入框内部。
    final Finder unit = find.byKey(
      const ValueKey<String>('todo-progress-unit'),
    );
    // 短列表首项即当前名称输入。
    final Finder name = _stepFields().first;
    expect(
      find.descendant(of: unit, matching: find.text('0/10')),
      findsNothing,
    );
    expect(
      find.descendant(of: name, matching: find.text('0/200')),
      findsNothing,
    );
    await tester.enterText(unit, 'abcdefgh');
    await tester.pump();
    expect(
      find.descendant(of: unit, matching: find.text('8/10')),
      findsOneWidget,
    );
    expect(
      tester.getRect(find.text('8/10')).bottom,
      lessThanOrEqualTo(tester.getRect(unit).bottom),
    );
    await tester.enterText(name, List<String>.filled(180, '章').join());
    await tester.pump();
    expect(
      find.descendant(of: name, matching: find.text('180/200')),
      findsOneWidget,
    );
    expect(
      tester.getRect(find.text('180/200')).bottom,
      lessThanOrEqualTo(tester.getRect(name).bottom),
    );
    await tester.enterText(unit, 'abcdefghijk');
    await tester.enterText(name, List<String>.filled(201, '章').join());
    await tester.pump();
    expect(tester.widget<OmniTextFormField>(unit).controller!.text.length, 10);
    expect(tester.widget<OmniTextFormField>(name).controller!.text.length, 200);
    await _saveEditor(tester);
    // 保存数据仍受原有业务长度限制，计数外观不会放宽输入规则。
    final TodoRecord saved =
        (await database.select(database.todoItems).get()).single;
    expect(saved.progressUnit!.length, 10);
    expect((await _readSteps(database)).single.name!.length, 200);
  });

  _testEditor('五步扩为六步再回五步时新增名称焦点节点和既有标识保持稳定', (WidgetTester tester) async {
    // 列表在自然高度与内部滚动之间切换时使用独立数据库核对结构。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 初始五项恰好处于自然展示上限。
    final TodoRecord record = await _createProgress(database, count: 5);
    // 既有稳定标识用于核对删除和排序没有重建剩余步骤。
    final List<TodoProgressStepRecord> original = await _readSteps(database);
    await _openEditor(tester, database, record: record);
    await tester.ensureVisible(find.text('添加步骤'));
    await tester.tap(find.text('添加步骤'));
    await tester.pumpAndSettle();
    expect(find.text('步骤列表 · 6 项'), findsOneWidget);
    // 新增名称应当是当前唯一聚焦的步骤输入。
    final Finder focused = find.descendant(
      of: find.byKey(const ValueKey<String>('todo-progress-step-names')),
      matching: find.byWidgetPredicate(
        (Widget widget) =>
            widget is OmniTextFormField && widget.focusNode?.hasFocus == true,
      ),
    );
    expect(focused, findsOneWidget);
    _expectFullyVisible(tester, focused);
    // 记录新行真实输入组件所持有的身份资源，跨布局切换不得换成另一项。
    final OmniTextFormField addedInput = tester.widget<OmniTextFormField>(
      focused,
    );
    // 稳定键在移动及列表类型切换后继续定位同一新增项。
    final Finder added = find.byKey(addedInput.key!);
    // 焦点对象需跟随步骤，而不是跟随当前行序号。
    final FocusNode addedFocus = addedInput.focusNode!;
    // 控制器保留用户尚未保存的名称。
    final TextEditingController addedController = addedInput.controller!;
    await tester.enterText(added, '新增附录');
    await tester.ensureVisible(find.byTooltip('上移步骤 6'));
    await tester.tap(find.byTooltip('上移步骤 6'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<OmniTextFormField>(added).controller,
      same(addedController),
    );
    expect(tester.widget<OmniTextFormField>(added).focusNode, same(addedFocus));
    expect(addedController.text, '新增附录');
    await tester.ensureVisible(find.byTooltip('删除步骤 1'));
    await tester.tap(find.byTooltip('删除步骤 1'));
    await tester.pumpAndSettle();
    expect(find.text('步骤列表 · 5 项'), findsOneWidget);
    _expectNoInnerVerticalScroll(tester);
    expect(
      tester.widget<OmniTextFormField>(added).controller,
      same(addedController),
    );
    expect(tester.widget<OmniTextFormField>(added).focusNode, same(addedFocus));
    expect(addedController.text, '新增附录');
    await tester.ensureVisible(added);
    await tester.tap(added);
    await tester.pump();
    expect(addedFocus.hasFocus, isTrue);
    await tester.enterText(added, '新增附录（调整后）');
    await _saveEditor(tester);
    // 删除首项并上移新增项后，新项位于倒数第二项，其他标识原样保留。
    final List<TodoProgressStepRecord> saved = await _readSteps(database);
    expect(saved, hasLength(5));
    expect(
      saved.take(3).map((TodoProgressStepRecord step) => step.id),
      original.skip(1).take(3).map((TodoProgressStepRecord step) => step.id),
    );
    expect(saved[3].name, '新增附录（调整后）');
    expect(
      original.map((TodoProgressStepRecord step) => step.id),
      isNot(contains(saved[3].id)),
    );
    expect(saved.last.id, original.last.id);
  });

  _testEditor('安卓两倍字号的长名称内部计数不溢出且步骤菜单仍可操作', (WidgetTester tester) async {
    // 大字号窄屏场景使用独立数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 两项允许真实执行移动操作，同时避免删除确认遮挡目标布局。
    final TodoRecord record = await _createProgress(database, count: 2);
    // 180 字触发内部计数，内容仍处于合法输入范围。
    final String longName = List<String>.filled(180, '章').join();
    // 大字号安卓布局的中文预览边界。
    final GlobalKey previewKey = await _openEditor(
      tester,
      database,
      record: record,
      viewport: const Size(360, 1100),
      textScale: 2,
      brightness: Brightness.light,
    );
    await tester.ensureVisible(_stepFields().first);
    await tester.enterText(_stepFields().first, longName);
    await tester.pumpAndSettle();
    // 长名称只水平滚动，计数应完整保留在同一输入框内部。
    final Rect nameRect = tester.getRect(_stepFields().first);
    // 计数必须有实际排版空间，不能依靠裁切掩盖溢出。
    final Rect counterRect = tester.getRect(find.text('180/200'));
    expect(counterRect.left, greaterThanOrEqualTo(nameRect.left));
    expect(counterRect.right, lessThanOrEqualTo(nameRect.right));
    expect(
      tester
          .renderObject<RenderParagraph>(find.text('180/200'))
          .didExceedMaxLines,
      isFalse,
    );
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byTooltip('步骤 1 操作'));
    await tester.tap(find.byTooltip('步骤 1 操作'));
    await tester.pumpAndSettle();
    expect(find.text('下移'), findsOneWidget);
    await _capturePreview(
      tester,
      previewKey,
      'edit-android-double-text-counter-menu',
    );
    await tester.tap(find.text('下移'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<OmniTextFormField>(_stepFields().last).controller!.text,
      longName,
    );
    expect(tester.takeException(), isNull);
    await _saveEditor(tester);
    expect((await _readSteps(database)).last.name, longName);
  }, platform: TargetPlatform.android);

  _testEditor('已完成任务保留步骤只读限制且允许修改标题', (WidgetTester tester) async {
    // 已完成任务使用独立数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 全部两步经业务入口完成，保持真实的只读来源。
    final TodoRecord record = await _createProgress(
      database,
      count: 2,
      named: true,
    );
    // 原始步骤标识用于批量完成。
    final List<TodoProgressStepRecord> original = await _readSteps(database);
    // 仓储提供完成步骤及最终确认任务的方法。
    final TodoRepository repository = TodoRepository(database);
    await repository.setProgressStepsCompleted(
      record.id,
      original.map((TodoProgressStepRecord step) => step.id).toList(),
      true,
    );
    await repository.confirmProgressTask(record.id);
    // 重新读取已完成记录，避免用旧快照误测为可编辑状态。
    final TodoRecord completed =
        (await database.select(database.todoItems).get()).single;
    await _openEditor(tester, database, record: completed);
    expect(find.text('任务已完成，重新打开后才能修改步骤。'), findsOneWidget);
    expect(
      tester
          .widget<OmniTextFormField>(
            find.byKey(const ValueKey<String>('todo-progress-unit')),
          )
          .enabled,
      isFalse,
    );
    // 所有步骤名称和增删移动操作都必须禁用。
    for (final OmniTextFormField field in tester.widgetList<OmniTextFormField>(
      _stepFields(),
    )) {
      expect(field.enabled, isFalse);
    }
    expect(
      tester
          .widget<OmniButton>(find.widgetWithText(OmniButton, '添加步骤'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OmniIconButton>(
            find.ancestor(
              of: find.byTooltip('删除步骤 1'),
              matching: find.byType(OmniIconButton),
            ),
          )
          .onPressed,
      isNull,
    );
    await tester.enterText(find.byType(TextFormField).first, '已完成阅读计划');
    await _saveEditor(tester);
    // 标题修改不会重新打开任务，也不会更换或清空完成步骤。
    final TodoRecord saved =
        (await database.select(database.todoItems).get()).single;
    expect(saved.title, '已完成阅读计划');
    expect(saved.isCompleted, isTrue);
    expect(
      (await _readSteps(database))
          .every((TodoProgressStepRecord step) => step.isCompleted),
      isTrue,
    );
  });
}

/// 使用 SDK 自带数字字体保持普通测试可移植，预览模式单独加载中文字体。
Future<void> _loadTestFonts() async {
  // 包配置提供当前项目实际使用的 Flutter SDK 路径。
  final File packageConfigFile = File('.dart_tool/package_config.json')
      .absolute;
  // 配置中的相对 URI 以配置文件的位置为基准解析。
  final Map<String, dynamic> packageConfig = jsonDecode(
    await packageConfigFile.readAsString(),
  ) as Map<String, dynamic>;
  // 当前项目的全部依赖配置。
  final List<Map<String, dynamic>> packages =
      (packageConfig['packages'] as List<dynamic>).cast<Map<String, dynamic>>();
  // Flutter 包位于 SDK 的 packages 目录。
  final Map<String, dynamic> flutterPackageConfig = packages.singleWhere(
    (Map<String, dynamic> package) => package['name'] == 'flutter',
  );
  // 目录 API 兼容 rootUri 带或不带末尾斜线。
  final Directory flutterPackage = Directory.fromUri(
    packageConfigFile.uri.resolve(flutterPackageConfig['rootUri'] as String),
  );
  // 字体随 SDK 安装，不新增测试资产。
  final Uri fontDirectory = flutterPackage.parent.parent.uri.resolve(
    'bin/cache/artifacts/material_fonts/',
  );
  // 可选中文预览才使用开发机系统字体。
  final File fontFile =
      Platform.environment['OMNI_PROGRESS_EDITOR_PREVIEW'] == null
      ? File.fromUri(fontDirectory.resolve('roboto-regular.ttf'))
      : File('C:/Windows/Fonts/msyh.ttc');
  // 所有主题候选字体使用一致度量。
  final ByteData font = ByteData.sublistView(await fontFile.readAsBytes());
  // 桌面与安卓主题的候选字体家族。
  for (final String family in <String>[
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'Roboto',
    'Ahem',
  ]) {
    // 当前家族的字体加载器。
    final FontLoader loader = FontLoader(family);
    loader.addFont(Future<ByteData>.value(font));
    await loader.load();
  }
  // 加载实际图标避免截图出现占位方框。
  final FontLoader icons = FontLoader('MaterialIcons');
  icons.addFont(
    File.fromUri(fontDirectory.resolve('materialicons-regular.otf'))
        .readAsBytes()
        .then(ByteData.sublistView),
  );
  await icons.load();
}

/// 在测试回调返回前恢复平台覆盖，防止框架全局状态检查失败。
void _testEditor(
  String description,
  Future<void> Function(WidgetTester tester) callback, {
  TargetPlatform platform = TargetPlatform.windows,
}) {
  testWidgets(description, (WidgetTester tester) async {
    // 保存调用前的平台覆盖以免污染同组测试。
    final TargetPlatform? originalPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = platform;
    try {
      await callback(tester);
    } finally {
      debugDefaultTargetPlatformOverride = originalPlatform;
    }
  });
}

/// 经公开入口打开进度编辑器并注册数据库和视口清理。
Future<GlobalKey> _openEditor(
  WidgetTester tester,
  AppDatabase database, {
  TodoRecord? record,
  Size viewport = const Size(1000, 1200),
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
  // 完整导航树的绘制边界包含侧滑弹窗。
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
                  label: '打开进度编辑器',
                  onPressed: () => TodoEditorDialog.show(
                    context,
                    record: record,
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
  await tester.tap(find.text('打开进度编辑器'));
  await _settleDatabase(tester);
  if (record == null) {
    await tester.tap(find.text('进度任务'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '阅读计划');
  }
  return previewKey;
}

/// 通过仓储创建可编辑的有序进度任务。
Future<TodoRecord> _createProgress(
  AppDatabase database, {
  required int count,
  bool named = false,
}) async {
  await TodoRepository(database).save(
    TodoDraft(
      title: '阅读计划',
      scheduledDate: DateTime(2026, 10, 7),
      taskType: TodoTaskType.progress,
      progressUnit: '章',
      progressSteps: List<TodoProgressStepDraft>.generate(
        count,
        (int index) =>
            TodoProgressStepDraft(name: named ? '章节 ${index + 1}' : null),
      ),
    ),
  );
  return (await database.select(database.todoItems).get()).single;
}

/// 读取有效步骤并按数据库真实顺序核对稳定标识和状态。
Future<List<TodoProgressStepRecord>> _readSteps(AppDatabase database) {
  // 排除软删除项，避免把菜单删除后的历史记录算进当前列表。
  final query = database.select(database.todoProgressSteps)
    ..where((TodoProgressSteps table) => table.deletedAt.isNull())
    ..orderBy([(TodoProgressSteps table) => OrderingTerm.asc(table.sortOrder)]);
  return query.get();
}

/// 仅定位折叠列表里的步骤名称，排除标题和单位输入。
Finder _stepFields() => find.descendant(
  of: find.byKey(const ValueKey<String>('todo-progress-step-names')),
  matching: find.byType(OmniTextFormField),
);

/// 新建默认折叠时展开列表，已展开场景保持原状态。
Future<void> _expandSteps(WidgetTester tester) async {
  if (_stepFields().evaluate().isNotEmpty) return;
  // 实际折叠标题位于扩展组件的直接标题位置。
  final Finder heading = find.textContaining('步骤列表 · ');
  await tester.ensureVisible(heading);
  await tester.tap(heading);
  await tester.pumpAndSettle();
}

/// 短列表不应产生第二个有滚动范围的纵向滚动区。
void _expectNoInnerVerticalScroll(WidgetTester tester) {
  // 名称输入自带横向滚动，因此这里只检查纵向列表。
  final Finder scrollables = find.descendant(
    of: find.byKey(const ValueKey<String>('todo-progress-step-names')),
    matching: find.byWidgetPredicate(
      (Widget widget) =>
          widget is Scrollable &&
          (widget.axisDirection == AxisDirection.down ||
              widget.axisDirection == AxisDirection.up),
    ),
  );
  // 允许实现保留零滚动范围的容器，但不允许隐藏短列表末项。
  for (final Element element in scrollables.evaluate()) {
    // 当前纵向滚动区域的真实位置状态。
    final ScrollableState state = tester.state<ScrollableState>(
      find.byWidget(element.widget),
    );
    expect(state.position.maxScrollExtent, moreOrLessEquals(0));
  }
}

/// 输入框必须完整落在屏幕及每一层纵向滚动视口内。
void _expectFullyVisible(WidgetTester tester, Finder field) {
  // 目标名称输入框的全局实际边界。
  final Rect fieldRect = tester.getRect(field);
  expect(fieldRect.top, greaterThanOrEqualTo(0));
  expect(fieldRect.bottom, lessThanOrEqualTo(tester.view.physicalSize.height));
  // 检查嵌套滚动造成的裁切，而不仅是全屏坐标范围。
  final Finder ancestors = find.ancestor(
    of: field,
    matching: find.byWidgetPredicate(
      (Widget widget) =>
          widget is Scrollable &&
          (widget.axisDirection == AxisDirection.down ||
              widget.axisDirection == AxisDirection.up),
    ),
  );
  // 所有外层与内层列表都必须真正显示整项。
  for (final Element element in ancestors.evaluate()) {
    // 当前祖先滚动区域的可见边界。
    final Rect viewport = tester.getRect(find.byWidget(element.widget));
    expect(fieldRect.top, greaterThanOrEqualTo(viewport.top - 1));
    expect(fieldRect.bottom, lessThanOrEqualTo(viewport.bottom + 1));
  }
}

/// 使用真实弹出菜单触发窄屏步骤操作。
Future<void> _chooseStepAction(
  WidgetTester tester,
  int number,
  String label,
) async {
  await tester.ensureVisible(find.byTooltip('步骤 $number 操作'));
  await tester.tap(find.byTooltip('步骤 $number 操作'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

/// 等待仓储异步写入与弹窗布局动画共同完成。
Future<void> _settleDatabase(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 40)),
  );
  await tester.pumpAndSettle();
}

/// 点击实际保存按钮并确认编辑器正常关闭。
Future<void> _saveEditor(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(OmniButton, '保存'));
  await _settleDatabase(tester);
  expect(find.byType(TodoEditorDialog), findsNothing);
  expect(tester.takeException(), isNull);
}

/// 可选导出中文预览，常规回归不产生图片文件。
Future<void> _capturePreview(
  WidgetTester tester,
  GlobalKey key,
  String name,
) async {
  if (Platform.environment['OMNI_PROGRESS_EDITOR_PREVIEW'] == null) return;
  // 完整应用的隔离渲染边界。
  final RenderRepaintBoundary boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    // 与现有功能预览保持同一输出目录层级。
    final Directory directory = Directory(
      'output/todo-progress-editor-preview',
    );
    await directory.create(recursive: true);
    // 使用逻辑像素便于比对桌面和窄屏控件布局。
    final ui.Image image = await boundary.toImage(pixelRatio: 1);
    try {
      // 由 Flutter 引擎编码 PNG，无需额外图像处理依赖。
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
