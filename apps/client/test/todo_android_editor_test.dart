import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_theme_palette.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/todos/data/todo_priority_quadrant.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:omni_butler/features/todos/presentation/todo_editor_dialog.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 日期保持在未来，避免提醒校验受到测试执行年份影响。
final DateTime _plannedDate = DateTime(DateTime.now().year + 1, 4, 6);

/// 验证全屏路由、真实持久化、异步提交和可访问性。
void main() {
  setUpAll(_loadFonts);

  testWidgets('安卓全屏覆盖嵌套导航且取消和系统返回不保存', (WidgetTester tester) async {
    // 嵌套导航和系统安全区可以暴露只覆盖局部页面的问题。
    final _EditorFixture fixture = await _openEditor(tester);
    fixture.media.value = fixture.media.value.copyWith(
      padding: const EdgeInsets.only(top: 24, bottom: 24),
      viewPadding: const EdgeInsets.only(top: 24, bottom: 24),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byType(Dialog)),
      const Rect.fromLTWH(0, 0, 390, 844),
    );
    expect(tester.getCenter(find.text('新增待办')).dx, closeTo(195, 0.1));
    expect(tester.getTopLeft(find.text('取消')).dy, greaterThanOrEqualTo(24));
    expect(tester.testTextInput.isVisible, isFalse);
    expect(find.byTooltip('关闭'), findsNothing);
    expect(find.text('计划日期'), findsOneWidget);
    expect(find.text('优先象限'), findsOneWidget);
    expect(find.text('截止时间'), findsNothing);
    await _capture(tester, 'android-create');
    await _enterTitle(tester, '取消的草稿');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(fixture.results, <bool?>[false]);
    expect(
      await fixture.database.select(fixture.database.todoItems).get(),
      isEmpty,
    );
    await tester.tap(find.text('打开待办'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(TodoEditorDialog), findsNothing);
    expect(fixture.results, <bool?>[false, null]);
  });

  testWidgets('标题校验与失败重试保留折叠描述且仅保存一次', (WidgetTester tester) async {
    // 仓储首轮失败后重试调用生产持久化逻辑。
    final _EditorFixture fixture = await _openEditor(tester, failFirst: true);
    await tester.tap(_submit());
    await tester.pumpAndSettle();
    expect(find.text('请输入待办标题'), findsOneWidget);
    await _enterTitle(tester, '保留输入');
    await tester.tap(
      find.byKey(const ValueKey<String>('todo-description-toggle')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('todo-description-input')),
      '保留描述草稿',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('todo-description-toggle')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('todo-description-input')),
      findsNothing,
    );
    await tester.tap(_submit());
    await tester.pumpAndSettle();
    expect(find.text('保存失败，请重试。输入内容已保留。'), findsOneWidget);
    expect(find.text('保留输入'), findsOneWidget);
    await tester.tap(_submit());
    await tester.pumpAndSettle();
    // 真实数据库证明重试没有重复创建，并保留折叠内容及可选时间空值。
    final TodoRecord saved = await fixture.database
        .select(fixture.database.todoItems)
        .getSingle();
    expect(saved.description, '保留描述草稿');
    expect(saved.scheduledDate, _plannedDate);
    expect(saved.dueAt, isNull);
    expect(saved.reminderAt, isNull);
    expect(fixture.results, <bool?>[true]);
    expect(fixture.repository.calls, 2);
  });

  testWidgets('提交锁防重复保存和系统返回并允许成功退出', (WidgetTester tester) async {
    // 延迟写入覆盖提交尚未完成时的真实交互。
    final Completer<void> gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    // 保存期间仍保留父路由和当前草稿。
    final _EditorFixture fixture = await _openEditor(tester, gate: gate);
    await _enterTitle(tester, '异步待办');
    // 捕获同一回调连调两次，验证业务锁而非仅按钮禁用。
    final VoidCallback save = tester.widget<OmniButton>(_submit()).onPressed!;
    save();
    save();
    await tester.pump();
    expect(fixture.repository.calls, 1);
    expect(tester.widget<OmniButton>(_submit()).onPressed, isNull);
    expect(
      tester
          .widget<OmniButton>(find.widgetWithText(OmniButton, '取消'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<AbsorbPointer>(
            find
                .descendant(
                  of: find.byType(TodoEditorDialog),
                  matching: find.byType(AbsorbPointer),
                )
                .first,
          )
          .absorbing,
      isTrue,
    );
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(TodoEditorDialog), findsOneWidget);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(TodoEditorDialog), findsNothing);
    expect(
      await fixture.database.select(fixture.database.todoItems).get(),
      hasLength(1),
    );
    expect(fixture.results, <bool?>[true]);
  });

  testWidgets('象限菜单保存实际选择并保留入口日期', (WidgetTester tester) async {
    // 初始象限由入口预填，切换后应真实写入而非仅更新界面。
    final _EditorFixture fixture = await _openEditor(
      tester,
      quadrant: TodoPriorityQuadrant.urgentNotImportant,
    );
    await _enterTitle(tester, '象限切换');
    await tester.tap(
      find.byKey(const ValueKey<String>('todo-priority-dropdown')),
    );
    await tester.pumpAndSettle();
    expect(find.text('重要·紧急'), findsOneWidget);
    expect(find.text('不紧急·不重要'), findsOneWidget);
    await _capture(tester, 'android-priority-menu');
    await tester.tap(find.text('重要·紧急'));
    await tester.pumpAndSettle();
    await tester.tap(_submit());
    await tester.pumpAndSettle();
    // 保存的整数值遵循现有象限数据协议。
    final TodoRecord saved = await fixture.database
        .select(fixture.database.todoItems)
        .getSingle();
    expect(saved.priorityQuadrant, TodoPriorityQuadrant.urgentImportant.value);
    expect(saved.scheduledDate, _plannedDate);
  });

  testWidgets('编辑已有描述和时间默认展开且可清除后保存', (WidgetTester tester) async {
    // 编辑路径复用原记录标识和已设置的分钟值。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    await TodoRepository(database).save(
      TodoDraft(
        title: '已有待办',
        description: '已有描述',
        scheduledDate: _plannedDate,
        dueAt: _plannedDate.add(const Duration(hours: 18, minutes: 30)),
        reminderAt: _plannedDate.add(const Duration(hours: 9, minutes: 30)),
      ),
    );
    // 仓储生成的真实记录作为编辑参数。
    final TodoRecord record = await database
        .select(database.todoItems)
        .getSingle();
    // 新界面不改变待办的身份和任务类型。
    final _EditorFixture fixture = await _openEditor(
      tester,
      database: database,
      record: record,
    );
    expect(find.text('编辑待办'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('todo-task-type')), findsNothing);
    expect(find.text('任务类型'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('todo-description-input')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<ExpansionTile>(
            find.byKey(const ValueKey<String>('todo-time-settings')),
          )
          .controller!
          .isExpanded,
      isTrue,
    );
    await _capture(tester, 'android-edit');
    await tester.ensureVisible(find.byTooltip('清除截止时间'));
    await tester.tap(find.byTooltip('清除截止时间'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('清除提醒时间'));
    await tester.tap(find.byTooltip('清除提醒时间'));
    await tester.pumpAndSettle();
    await tester.tap(_submit());
    await tester.pumpAndSettle();
    // 清除可选时间不改变描述或计划日期。
    final TodoRecord saved = await fixture.database
        .select(fixture.database.todoItems)
        .getSingle();
    expect(saved.id, record.id);
    expect(saved.description, record.description);
    expect(saved.dueAt, isNull);
    expect(saved.reminderAt, isNull);
  });

  testWidgets('提醒校验失败自动展开时间设置且修正后可保存', (WidgetTester tester) async {
    // 已保存的提醒随时间流逝可能过期，直接模拟该历史数据。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    await TodoRepository(database)
        .save(TodoDraft(title: '过期提醒待办', scheduledDate: _plannedDate));
    await database
        .update(database.todoItems)
        .write(
          TodoItemsCompanion(
            reminderAt: Value<DateTime?>(
              DateTime.now().subtract(const Duration(days: 1)),
            ),
          ),
        );
    // 使用真实已过期记录验证仓储校验与表单恢复。
    final TodoRecord record = await database
        .select(database.todoItems)
        .getSingle();
    // 保存失败仍保持同一条记录和当前草稿。
    final _EditorFixture fixture = await _openEditor(
      tester,
      database: database,
      record: record,
    );
    await tester.ensureVisible(find.text('时间设置'));
    await tester.tap(find.text('时间设置'));
    await tester.pumpAndSettle();
    await tester.tap(_submit());
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ExpansionTile>(
            find.byKey(const ValueKey<String>('todo-time-settings')),
          )
          .controller!
          .isExpanded,
      isTrue,
    );
    expect(
      find
          .descendant(
            of: find.byType(TodoEditorDialog),
            matching: find.text('提醒时间不能早于当前时间'),
          )
          .hitTestable(),
      findsOneWidget,
    );
    await _capture(tester, 'android-time-validation');
    await tester.ensureVisible(find.byTooltip('清除提醒时间'));
    await tester.tap(find.byTooltip('清除提醒时间'));
    await tester.pumpAndSettle();
    await tester.tap(_submit());
    await tester.pumpAndSettle();
    expect(fixture.results, <bool?>[true]);
    expect(
      (await database.select(database.todoItems).getSingle()).reminderAt,
      isNull,
    );
    expect(fixture.repository.calls, 2);
  });

  for (final bool editing in <bool>[false, true]) {
    testWidgets('子任务${editing ? '编辑' : '新增'}隐藏继承字段且独立截止可保存', (
      WidgetTester tester,
    ) async {
      // 父子任务通过真实仓储创建，编辑时刻意不传 parent。
      final AppDatabase database = AppDatabase.forTesting(
        NativeDatabase.memory(),
      );
      await TodoRepository(database).save(
        TodoDraft(
          title: '主任务',
          scheduledDate: _plannedDate,
          priorityQuadrant: TodoPriorityQuadrant.urgentImportant,
        ),
      );
      // 新建和编辑均必须继承父任务的日期及象限。
      final TodoRecord parent = await database
          .select(database.todoItems)
          .getSingle();
      if (editing) {
        await TodoRepository(database).save(
          TodoDraft(
            title: '旧子任务',
            parentId: parent.id,
            scheduledDate: _plannedDate,
          ),
        );
      }
      // 编辑子任务的入口只提供 record，验证 parentId 判断。
      final TodoRecord? child = editing
          ? (await database.select(database.todoItems).get()).singleWhere(
              (TodoRecord item) => item.parentId != null,
            )
          : null;
      // 按真实入口参数打开编辑器。
      final _EditorFixture fixture = await _openEditor(
        tester,
        database: database,
        record: child,
        parent: editing ? null : parent,
      );
      expect(find.text('计划日期'), findsNothing);
      expect(find.text('优先象限'), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('todo-task-type')),
        findsNothing,
      );
      await _enterTitle(tester, '保存子任务');
      await _expandTime(tester);
      expect(find.text('重复'), findsNothing);
      // 添加日期继续使用原有选择器和默认截止小时。
      await tester.ensureVisible(find.text('添加截止'));
      await tester.tap(find.text('添加截止'));
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .descendant(of: find.byType(GridView), matching: find.text('6'))
            .first,
      );
      await tester.pumpAndSettle();
      await _capture(tester, 'android-child-${editing ? 'edit' : 'create'}');
      await tester.tap(_submit());
      await tester.pumpAndSettle();
      // 子任务的继承由仓储保证，独立时间由本次表单写入。
      final TodoRecord saved =
          (await fixture.database.select(fixture.database.todoItems).get())
              .singleWhere((TodoRecord item) => item.parentId == parent.id);
      expect(saved.scheduledDate, parent.scheduledDate);
      expect(saved.priorityQuadrant, parent.priorityQuadrant);
      expect(saved.repeatRule, isNull);
      expect(saved.dueAt, _plannedDate.add(const Duration(hours: 18)));
      if (editing) expect(saved.id, child!.id);
    });
  }

  for (final TodoSeriesScope scope in TodoSeriesScope.values) {
    testWidgets('重复待办确认可取消且${scope.name}范围只提交一次', (WidgetTester tester) async {
      // 重复系列由生产仓储生成。
      final AppDatabase database = AppDatabase.forTesting(
        NativeDatabase.memory(),
      );
      await TodoRepository(database).save(
        TodoDraft(
          title: '重复待办',
          scheduledDate: _plannedDate,
          repeatRule: TodoRepeatRule.daily,
        ),
      );
      // 首个系列实例需要选择修改范围。
      final TodoRecord record =
          (await database.select(database.todoItems).get()).first;
      // 测试仓储记录影响范围并继续真实落库。
      final _EditorFixture fixture = await _openEditor(
        tester,
        database: database,
        record: record,
      );
      await _enterTitle(tester, '修改后的重复待办');
      // 连续触发保存只能打开一个系列确认。
      final VoidCallback save = tester.widget<OmniButton>(_submit()).onPressed!;
      save();
      save();
      await _pumpConfirmation(tester);
      expect(find.text('修改重复待办'), findsOneWidget);
      expect(tester.widget<OmniButton>(_submit()).onPressed, isNull);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('修改重复待办'), findsNothing);
      expect(find.byType(TodoEditorDialog), findsOneWidget);
      expect(find.text('修改后的重复待办'), findsOneWidget);
      expect(fixture.repository.calls, 0);
      await tester.tap(_submit());
      await _pumpConfirmation(tester);
      await tester.tap(
        find.text(scope == TodoSeriesScope.single ? '仅本次' : '本次及以后'),
      );
      await tester.pumpAndSettle();
      expect(fixture.repository.calls, 1);
      expect(fixture.repository.lastScope, scope);
      expect(find.byType(TodoEditorDialog), findsNothing);
      expect(
        (await database.select(database.todoItems).get()).any(
          (TodoRecord item) => item.title == '修改后的重复待办',
        ),
        isTrue,
      );
    });
  }

  testWidgets('新增进度任务减少具名步骤确认可取消且草稿不丢失', (WidgetTester tester) async {
    // 保存时减少数量会打开步骤删除确认，父编辑器不能抢走返回。
    final _EditorFixture fixture = await _openEditor(tester);
    await tester.tap(find.text('进度任务'));
    await tester.pumpAndSettle();
    await _enterTitle(tester, '阅读计划');
    await tester.ensureVisible(find.text('添加步骤'));
    await tester.tap(find.text('添加步骤'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).last, '保留第二章');
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('todo-progress-total')),
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('todo-progress-total')),
      '1',
    );
    await tester.tap(_submit());
    await _pumpConfirmation(tester);
    expect(find.text('删除这些步骤？'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('删除这些步骤？'), findsNothing);
    expect(find.text('保留第二章'), findsOneWidget);
    expect(fixture.repository.calls, 0);
    await _capture(tester, 'android-progress');
    await tester.tap(_submit());
    await tester.pumpAndSettle();
    // 取消删除恢复步骤数，重新保存保留两步及名称。
    final TodoRecord saved = await fixture.database
        .select(fixture.database.todoItems)
        .getSingle();
    expect(saved.taskType, TodoTaskType.progress.name);
    expect(
      await fixture.database.select(fixture.database.todoProgressSteps).get(),
      hasLength(2),
    );
  });

  for (final Size size in <Size>[Size(360, 800), Size(1000, 900)]) {
    testWidgets('安卓${size.width.toInt()}宽两倍字号与键盘仍可编辑保存', (
      WidgetTester tester,
    ) async {
      // 两倍字号和键盘同时压缩正文可用空间。
      final _EditorFixture fixture = await _openEditor(
        tester,
        size: size,
        textScale: 2,
      );
      expect(
        find.byKey(const ValueKey<String>('todo-android-editor')),
        findsOneWidget,
      );
      await _enterTitle(tester, '大字号待办');
      fixture.media.value = fixture.media.value.copyWith(
        viewInsets: const EdgeInsets.only(bottom: 260),
      );
      await tester.pumpAndSettle();
      await _expandTime(tester);
      await tester.ensureVisible(find.text('不重复'));
      await tester.tap(find.text('不重复'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('每周'));
      await tester.pumpAndSettle();
      await _capture(
        tester,
        'android-${size.width.toInt()}-large-text-keyboard',
      );
      expect(tester.getBottomLeft(_submit()).dy, lessThan(size.height - 260));
      expect(tester.takeException(), isNull);
      await tester.tap(_submit());
      await tester.pumpAndSettle();
      expect(find.byType(TodoEditorDialog), findsNothing);
      expect(
        (await fixture.database.select(fixture.database.todoItems).getSingle())
            .repeatRule,
        TodoRepeatRule.weekly.name,
      );
    });
  }

  for (final AppThemePalette palette in AppThemePalette.values) {
    for (final Brightness brightness in Brightness.values) {
      testWidgets('${palette.id} ${brightness.name} 安卓主题分组正常显示保存', (
        WidgetTester tester,
      ) async {
        // 每种配色与明暗组合使用独立的真实主题和数据库。
        final _EditorFixture fixture = await _openEditor(
          tester,
          palette: palette,
          brightness: brightness,
        );
        // 页面表面必须取自当前主题语义背景。
        final Dialog dialog = tester.widget<Dialog>(find.byType(Dialog));
        expect(
          dialog.backgroundColor,
          OmniColors.of(tester.element(find.byType(TodoEditorDialog))).canvas,
        );
        await _enterTitle(tester, '主题待办');
        await _capture(tester, 'android-${palette.id}-${brightness.name}');
        await tester.tap(_submit());
        await tester.pumpAndSettle();
        expect(
          await fixture.database.select(fixture.database.todoItems).get(),
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('Windows 窄窗继续使用侧栏和四象限', (WidgetTester tester) async {
    // 平台判断不受窗口宽度影响。
    await _openEditor(
      tester,
      platform: TargetPlatform.windows,
      size: const Size(390, 844),
    );
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(OmniSideSheetScaffold), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('todo-priority-dropdown')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('todo-priority-option-3')),
      findsOneWidget,
    );
    await _capture(tester, 'windows-narrow-editor');
  });
}

/// 经公开入口从嵌套导航打开表单，避免依赖生产服务或用户数据。
Future<_EditorFixture> _openEditor(
  WidgetTester tester, {
  AppDatabase? database,
  TodoRecord? record,
  TodoRecord? parent,
  TargetPlatform platform = TargetPlatform.android,
  Size size = const Size(390, 844),
  double textScale = 1,
  AppThemePalette palette = AppThemePalette.classicBlue,
  Brightness brightness = Brightness.light,
  TodoPriorityQuadrant quadrant = TodoPriorityQuadrant.importantNotUrgent,
  Completer<void>? gate,
  bool failFirst = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // 所有写入均使用当前测试的隔离内存数据库。
  final AppDatabase effectiveDatabase =
      database ?? AppDatabase.forTesting(NativeDatabase.memory());
  // 保存代理只注入失败或延迟，最终仍调用真实仓储。
  final _SaveRepository repository = _SaveRepository(
    effectiveDatabase,
    gate: gate,
    failFirst: failFirst,
  );
  // 可变媒体数据模拟安全区和软键盘。
  final ValueNotifier<MediaQueryData> media = ValueNotifier<MediaQueryData>(
    MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
  );
  // 保留每次打开编辑器的公开返回结果。
  final List<bool?> results = <bool?>[];
  // 业务 provider 仅覆盖本次测试所需依赖。
  final ProviderContainer container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(effectiveDatabase),
      todoRepositoryProvider.overrideWithValue(repository),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
    media.dispose();
    await tester.runAsync(effectiveDatabase.close);
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: const ValueKey<String>('todo-editor-preview'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.build(
            brightness: brightness,
            palette: palette,
          ).copyWith(platform: platform),
          builder: (BuildContext context, Widget? child) =>
              ValueListenableBuilder<MediaQueryData>(
                valueListenable: media,
                builder: (
                  BuildContext context,
                  MediaQueryData data,
                  Widget? _,
                ) => MediaQuery(data: data, child: child!),
              ),
          home: Scaffold(
            bottomNavigationBar: const SizedBox(
              height: 56,
              child: Center(child: Text('底部导航')),
            ),
            body: Navigator(
              onGenerateRoute: (RouteSettings settings) =>
                  MaterialPageRoute<void>(
                    builder: (BuildContext context) => Center(
                      child: OmniButton(
                        label: '打开待办',
                        onPressed: () async {
                          // 调用位置属于子导航，编辑器仍应覆盖整个应用窗口。
                          final bool? result = await TodoEditorDialog.show(
                            context,
                            record: record,
                            parent: parent,
                            initialDate: _plannedDate,
                            initialPriorityQuadrant: quadrant,
                          );
                          results.add(result);
                        },
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
  return _EditorFixture(
    database: effectiveDatabase,
    repository: repository,
    media: media,
    results: results,
  );
}

/// 定位固定顶栏的保存操作，排除嵌套确认动作。
Finder _submit() => find.byKey(const ValueKey<String>('todo-android-submit'));

/// 父表单保存指示器持续动画，确认阶段只推进路由所需帧数。
Future<void> _pumpConfirmation(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// 标题输入始终是正文的第一个表单字段。
Future<void> _enterTitle(WidgetTester tester, String title) async {
  await tester.enterText(find.byType(TextFormField).first, title);
  await tester.pump();
}

/// 已展开的高级时间不再次收起。
Future<void> _expandTime(WidgetTester tester) async {
  // 编辑已有值时默认展开，新建则需要用户主动展开。
  final ExpansionTile tile = tester.widget<ExpansionTile>(
    find.byKey(const ValueKey<String>('todo-time-settings')),
  );
  if (tile.controller!.isExpanded) return;
  await tester.ensureVisible(find.text('时间设置'));
  await tester.tap(find.text('时间设置'));
  await tester.pumpAndSettle();
}

/// 字体从本机 SDK 读取，中文预览显式使用系统字体。
Future<void> _loadFonts() async {
  // 包配置给出当前实际 SDK，避免写死 Flutter 安装位置。
  final File configFile = File('.dart_tool/package_config.json').absolute;
  // 已安装的包配置包含 Flutter 的根 URI。
  final Map<String, dynamic> config =
      jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
  // Flutter 框架包对应当前测试运行时的 SDK。
  final Map<String, dynamic> flutter = (config['packages'] as List<dynamic>)
      .cast<Map<String, dynamic>>()
      .singleWhere((Map<String, dynamic> item) => item['name'] == 'flutter');
  // SDK 自带的真实字体保证正常测试也使用正确字宽。
  final Directory package = Directory.fromUri(
    configFile.uri.resolve(flutter['rootUri'] as String),
  );
  // 框架包位于 SDK 的 packages 下，字体位于缓存目录。
  final Uri fontDirectory = package.parent.parent.uri.resolve(
    'bin/cache/artifacts/material_fonts/',
  );
  // 只有显式生成中文预览时才依赖 Windows 字体。
  final ByteData bytes = ByteData.sublistView(
    await (Platform.environment['OMNI_TODO_EDITOR_PREVIEW_DIR'] == null
            ? File.fromUri(fontDirectory.resolve('roboto-regular.ttf'))
            : File('C:/Windows/Fonts/msyh.ttc'))
        .readAsBytes(),
  );
  // 生产主题和测试默认字体使用一致的真实字形度量。
  for (final String family in <String>[
    'Ahem',
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'Roboto',
    'Noto Sans CJK SC',
  ]) {
    // 每个家族分别注册，避免默认 Ahem 掩盖文字截断。
    final FontLoader loader = FontLoader(family);
    loader.addFont(Future<ByteData>.value(bytes));
    await loader.load();
  }
  // 图标字体保持实际产品符号。
  final FontLoader icons = FontLoader('MaterialIcons');
  icons.addFont(
    File.fromUri(fontDirectory.resolve('materialicons-regular.otf'))
        .readAsBytes()
        .then(ByteData.sublistView),
  );
  await icons.load();
}

/// 仅在显式指定目录时输出实际 Flutter 中文预览。
Future<void> _capture(WidgetTester tester, String name) async {
  // 普通回归不会写入截图。
  final String? directory =
      Platform.environment['OMNI_TODO_EDITOR_PREVIEW_DIR'];
  if (directory == null) return;
  // 整个应用的绘制边界包含全屏路由及菜单。
  final RenderRepaintBoundary boundary = tester
      .renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey<String>('todo-editor-preview')),
      );
  await tester.runAsync(() async {
    // 截图来自真实 widget 绘制。
    final ui.Image image = await boundary.toImage();
    // 无损保存便于逐图审查文字、对齐和触控布局。
    final ByteData bytes = (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!;
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png').writeAsBytes(bytes.buffer.asUint8List());
    image.dispose();
  });
}

/// 当前测试的业务与媒体状态。
class _EditorFixture {
  /// 隔离的真实数据库。
  final AppDatabase database;

  /// 记录调用次数并实际写入的仓储。
  final _SaveRepository repository;

  /// 供安全区和键盘适配测试调整的媒体数据。
  final ValueNotifier<MediaQueryData> media;

  /// 编辑器公开返回结果。
  final List<bool?> results;

  /// 创建测试状态集合。
  const _EditorFixture({
    required this.database,
    required this.repository,
    required this.media,
    required this.results,
  });
}

/// 延迟或失败注入后仍使用生产仓储，验证完整落库路径。
class _SaveRepository extends TodoRepository {
  /// 可选提交闸门。
  final Completer<void>? gate;

  /// 首轮提交是否失败。
  final bool failFirst;

  /// 保存调用次数。
  int calls = 0;

  /// 最新提交的重复系列范围。
  TodoSeriesScope? lastScope;

  /// 创建受控的真实仓储。
  _SaveRepository(super.database, {this.gate, this.failFirst = false});

  /// 只在写入前注入测试条件。
  @override
  Future<void> save(
    TodoDraft draft, {
    TodoSeriesScope scope = TodoSeriesScope.single,
  }) async {
    calls += 1;
    lastScope = scope;
    if (gate != null) await gate!.future;
    if (failFirst && calls == 1) throw StateError('测试保存失败');
    await super.save(draft, scope: scope);
  }
}
