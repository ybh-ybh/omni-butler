import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/omni_butler_app.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/todos/data/todo_priority_quadrant.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证首页任务左键、右键菜单与真实仓储读写互不干扰。
void main() {
  testWidgets('左键行空白、标题和箭头只展开收起，箭头悬停沿用整行背景', (WidgetTester tester) async {
    await _withHome(tester, (
      AppDatabase database,
      TodoRecord parent,
      TodoRecord child,
      TodoRecord leaf,
    ) async {
      // 任务整行最右侧留白用于验证非文字区域也可切换子项。
      final Finder row = find.byKey(
        ValueKey<String>('home-todo-hover-${parent.id}'),
      );
      // 左键点击前的任务行实际边界。
      final Rect rowRect = tester.getRect(row);
      expect(find.text(child.title), findsNothing);
      await tester.tapAt(Offset(rowRect.right - 3, rowRect.center.dy));
      await tester.pumpAndSettle();
      expect(find.text(child.title), findsOneWidget);
      expect(find.text('编辑待办'), findsNothing);

      await tester.tap(
        find.byKey(ValueKey<String>('home-todo-title-action-${parent.id}')),
      );
      await tester.pumpAndSettle();
      expect(find.text(child.title), findsNothing);
      // 箭头保留独立点击命中区域，但不叠加自己的悬停底色。
      final Finder arrow = find.byKey(
        ValueKey<String>('home-todo-tree-toggle-${parent.id}'),
      );
      // 真实鼠标移入箭头以激活父行悬停。
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(arrow));
      await tester.pumpAndSettle();
      // 检查合并主题后的最终材质背景，避免透明 overlay 掩盖主题灰底。
      final Finder arrowMaterial = find.descendant(
        of: arrow,
        matching: find.byType(Material),
      );
      expect(arrowMaterial, findsOneWidget);
      expect(tester.widget<Material>(arrowMaterial).color, Colors.transparent);
      // 父行使用统一悬停背景，而非只有箭头区域变灰。
      final BoxDecoration rowDecoration =
          tester.widget<AnimatedContainer>(row).decoration! as BoxDecoration;
      expect(rowDecoration.color, isNot(Colors.transparent));
      await tester.tap(arrow);
      await tester.pumpAndSettle();
      expect(find.text(child.title), findsOneWidget);
      expect(find.text('编辑待办'), findsNothing);
      await mouse.removePointer();

      await tester.tap(
        find.byKey(ValueKey<String>('home-todo-title-action-${leaf.id}')),
      );
      await tester.pumpAndSettle();
      expect(find.text('编辑待办'), findsNothing);
      expect(find.text(child.title), findsOneWidget);
      expect(
        (await database.select(database.todoItems).get()).every(
          (TodoRecord row) => !row.isCompleted,
        ),
        isTrue,
      );
    });
  });

  testWidgets('右键菜单不切换展开或完成，复选框区域右键也仅打开菜单', (WidgetTester tester) async {
    await _withHome(tester, (
      AppDatabase database,
      TodoRecord parent,
      TodoRecord child,
      TodoRecord leaf,
    ) async {
      await _openMenu(tester, parent.id);
      expect(find.text('编辑任务'), findsOneWidget);
      expect(find.text('添加子任务'), findsOneWidget);
      expect(find.text('删除任务'), findsOneWidget);
      expect(find.text(child.title), findsNothing);
      expect((await _readTodo(database, parent.id)).isCompleted, isFalse);
      await _dismissMenu(tester);

      await tester.tap(
        find.byKey(ValueKey<String>('home-todo-title-action-${parent.id}')),
      );
      await tester.pumpAndSettle();
      expect(find.text(child.title), findsOneWidget);
      await _openMenu(
        tester,
        parent.id,
        keyPrefix: 'home-todo-checkbox-action',
      );
      expect(find.text(child.title), findsOneWidget);
      expect((await _readTodo(database, parent.id)).isCompleted, isFalse);
      expect((await _readTodo(database, child.id)).isCompleted, isFalse);
      await _dismissMenu(tester);
      expect(find.text(child.title), findsOneWidget);
      expect(find.text('编辑待办'), findsNothing);
    });
  });

  testWidgets('右键编辑使用现有编辑器并持久化到首页共享仓储', (WidgetTester tester) async {
    await _withHome(tester, (
      AppDatabase database,
      TodoRecord parent,
      TodoRecord child,
      TodoRecord leaf,
    ) async {
      await _openMenu(tester, parent.id);
      await tester.tap(find.text('编辑任务'));
      await tester.pumpAndSettle();
      expect(find.text('编辑待办'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField).first, '右键编辑后的父任务');
      await tester.tap(find.widgetWithText(OmniButton, '保存'));
      await tester.pumpAndSettle();

      // 编辑后身份与层级保留，只修改用户输入的标题。
      final TodoRecord updated = await _readTodo(database, parent.id);
      expect(updated.title, '右键编辑后的父任务');
      expect(updated.parentId, isNull);
      expect(updated.isCompleted, isFalse);
      expect(updated.deletedAt, isNull);
      expect(find.text(updated.title), findsOneWidget);
      expect(find.text(parent.title), findsNothing);
      expect(find.text(child.title), findsNothing);
      expect((await _readTodo(database, child.id)).parentId, parent.id);
    });
  });

  testWidgets('右键添加子任务继承父级日期象限并在保存后自动展开', (WidgetTester tester) async {
    await _withHome(tester, (
      AppDatabase database,
      TodoRecord parent,
      TodoRecord child,
      TodoRecord leaf,
    ) async {
      expect(find.text(child.title), findsNothing);
      await _openMenu(tester, parent.id);
      await tester.tap(find.text('添加子任务'));
      await tester.pumpAndSettle();
      expect(find.text('新增子任务'), findsOneWidget);
      expect(find.textContaining('所属主任务：${parent.title}'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField).first, '从首页菜单新增的子任务');
      await tester.tap(find.widgetWithText(OmniButton, '保存'));
      await tester.pumpAndSettle();

      // 读取真实数据库验证父子关系和继承字段。
      final TodoRecord added = (await database.select(database.todoItems).get())
          .singleWhere((TodoRecord row) => row.title == '从首页菜单新增的子任务');
      expect(added.parentId, parent.id);
      expect(added.scheduledDate, parent.scheduledDate);
      expect(added.priorityQuadrant, parent.priorityQuadrant);
      expect(added.isCompleted, isFalse);
      expect(find.text(added.title), findsOneWidget);
      expect(find.text(child.title), findsOneWidget);
      expect(
        find.byKey(ValueKey<String>('home-todo-tree-children-${parent.id}')),
        findsOneWidget,
      );
    });
  });

  testWidgets('子任务菜单禁用再加子项，左键不编辑且勾选仅完成当前独立任务', (WidgetTester tester) async {
    await _withHome(tester, (
      AppDatabase database,
      TodoRecord parent,
      TodoRecord child,
      TodoRecord leaf,
    ) async {
      await tester.tap(
        find.byKey(ValueKey<String>('home-todo-title-action-${parent.id}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey<String>('home-todo-title-action-${child.id}')),
      );
      await tester.pumpAndSettle();
      expect(find.text('编辑子任务'), findsNothing);
      await _openMenu(tester, child.id);
      // 菜单的禁用状态沿用统一菜单项，阻止创建第三层任务。
      final Finder addChildMenuItem = find.ancestor(
        of: find.text('添加子任务'),
        matching: find.byWidgetPredicate(
          (Widget widget) => widget is OmniPopupMenuItem<dynamic>,
        ),
      );
      expect(addChildMenuItem, findsOneWidget);
      expect(
        tester.widget<OmniPopupMenuItem<dynamic>>(addChildMenuItem).enabled,
        isFalse,
      );
      // 禁用项最终文字颜色应与仍可用的编辑项有明确视觉区分。
      final Color? disabledColor = tester
          .widget<Text>(find.text('添加子任务'))
          .style
          ?.color;
      // 普通可用菜单项的最终文字颜色。
      final Color? enabledColor = tester
          .widget<Text>(find.text('编辑任务'))
          .style
          ?.color;
      expect(disabledColor, isNotNull);
      expect(enabledColor, isNotNull);
      expect(disabledColor, isNot(enabledColor));
      expect(disabledColor!.a, lessThan(enabledColor!.a));
      await tester.tap(find.text('添加子任务'));
      await tester.pumpAndSettle();
      expect(find.text('新增子任务'), findsNothing);
      expect(find.text('编辑任务'), findsOneWidget);
      expect((await database.select(database.todoItems).get()).length, 3);
      await _dismissMenu(tester);

      await tester.tap(
        find.byKey(ValueKey<String>('home-todo-checkbox-action-${leaf.id}')),
      );
      await tester.pumpAndSettle();
      // 完成反馈包含延迟提交，显式推进时钟以覆盖最终持久化。
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect((await _readTodo(database, leaf.id)).isCompleted, isTrue);
      expect((await _readTodo(database, parent.id)).isCompleted, isFalse);
      expect((await _readTodo(database, child.id)).isCompleted, isFalse);
      expect(find.text(leaf.title), findsNothing);
      expect(find.text(child.title), findsOneWidget);
      expect(find.text('编辑待办'), findsNothing);
    });
  });

  testWidgets('取消右键删除保留任务，确认删除将整棵树移入回收站', (WidgetTester tester) async {
    await _withHome(tester, (
      AppDatabase database,
      TodoRecord parent,
      TodoRecord child,
      TodoRecord leaf,
    ) async {
      await _openMenu(tester, parent.id);
      await tester.tap(find.text('删除任务'));
      await tester.pumpAndSettle();
      expect(find.textContaining('回收站'), findsOneWidget);
      await tester.tap(find.widgetWithText(OmniButton, '取消'));
      await tester.pumpAndSettle();
      expect((await _readTodo(database, parent.id)).deletedAt, isNull);
      expect((await _readTodo(database, child.id)).deletedAt, isNull);
      expect(find.text(parent.title), findsOneWidget);
      expect(find.text(child.title), findsNothing);

      await _openMenu(tester, parent.id);
      await tester.tap(find.text('删除任务'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OmniButton, '删除任务'));
      await tester.pumpAndSettle();
      // 软删除父子记录采用同一删除时间，保留回收站恢复所需结构。
      final TodoRecord deletedParent = await _readTodo(database, parent.id);
      // 被同步移入回收站的直属子任务。
      final TodoRecord deletedChild = await _readTodo(database, child.id);
      expect(deletedParent.deletedAt, isNotNull);
      expect(deletedChild.deletedAt, deletedParent.deletedAt);
      expect(deletedChild.parentId, parent.id);
      expect(deletedParent.isCompleted, isFalse);
      expect(deletedChild.isCompleted, isFalse);
      expect((await _readTodo(database, leaf.id)).deletedAt, isNull);
      expect(find.text(parent.title), findsNothing);
      expect(find.text(child.title), findsNothing);
      expect(find.text(leaf.title), findsOneWidget);
      expect((await database.select(database.todoItems).get()).length, 3);
    });
  });
  testWidgets('右键删除失败回滚父子记录并可通过原菜单重试', (WidgetTester tester) async {
    await _withHome(tester, (
      AppDatabase database,
      TodoRecord parent,
      TodoRecord child,
      TodoRecord leaf,
    ) async {
      await tester.tap(
        find.byKey(ValueKey<String>('home-todo-title-action-${parent.id}')),
      );
      await tester.pumpAndSettle();
      // 在子任务写入时失败，验证整树事务不会留下已删除的父任务。
      await database.customStatement('''
        CREATE TEMP TRIGGER reject_home_todo_delete
        BEFORE UPDATE OF deleted_at ON todo_items
        WHEN NEW.deleted_at IS NOT NULL AND OLD.parent_id IS NOT NULL
        BEGIN
          SELECT RAISE(ABORT, '模拟首页任务删除失败');
        END;
      ''');
      await _openMenu(tester, parent.id);
      await tester.tap(find.text('删除任务'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OmniButton, '删除任务'));
      await tester.pump(const Duration(milliseconds: 100));
      // 等待数据库队列完成事务回滚，不能把没有待绘制帧当成业务结束。
      final TodoRecord failedParent = await _readTodo(database, parent.id);
      // 第二次查询同步确认子任务也没有留下部分删除状态。
      final TodoRecord failedChild = await _readTodo(database, child.id);
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('删除失败，请重试'), findsOneWidget);
      expect(failedParent.deletedAt, isNull);
      expect(failedChild.deletedAt, isNull);
      expect(failedParent.isCompleted, isFalse);
      expect(failedChild.isCompleted, isFalse);
      expect(find.text(parent.title), findsOneWidget);
      expect(find.text(child.title), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(OmniButton, '删除任务'), findsNothing);
      expect(tester.takeException(), isNull);

      await database.customStatement('DROP TRIGGER reject_home_todo_delete');
      await _openMenu(tester, parent.id);
      await tester.tap(find.text('删除任务'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OmniButton, '删除任务'));
      await tester.pump(const Duration(milliseconds: 100));

      // 重试成功后父子记录统一软删除，独立任务不受影响。
      final TodoRecord deletedParent = await _readTodo(database, parent.id);
      // 子任务保留与父任务相同的删除批次和层级。
      final TodoRecord deletedChild = await _readTodo(database, child.id);
      // 数据库查询结束后再推进绘制，让首页消费新的有效任务列表。
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(deletedParent.deletedAt, isNotNull);
      expect(deletedChild.deletedAt, deletedParent.deletedAt);
      expect(deletedChild.parentId, parent.id);
      expect((await _readTodo(database, leaf.id)).deletedAt, isNull);
      expect(find.text(parent.title), findsNothing);
      expect(find.text(child.title), findsNothing);
      expect(find.text(leaf.title), findsOneWidget);
      expect((await database.select(database.todoItems).get()).length, 3);
    });
  });
}

/// 在指定任务区域发送真实鼠标右键并等待统一菜单打开。
Future<void> _openMenu(
  WidgetTester tester,
  String todoId, {
  String keyPrefix = 'home-todo-hover',
}) async {
  // 需要触发菜单的真实任务区域。
  final Finder target = find.byKey(ValueKey<String>('$keyPrefix-$todoId'));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(
    target,
    buttons: kSecondaryMouseButton,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pumpAndSettle();
}

/// 通过键盘关闭上下文菜单，避免额外触发行点击。
Future<void> _dismissMenu(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pumpAndSettle();
  expect(find.text('编辑任务'), findsNothing);
}

/// 读取包括软删除记录在内的真实任务状态。
Future<TodoRecord> _readTodo(AppDatabase database, String id) async {
  return (await database.select(database.todoItems).get()).singleWhere(
    (TodoRecord row) => row.id == id,
  );
}

/// 以完整应用和真实数据流运行断言，并确保失败时同样释放资源。
Future<void> _withHome(
  WidgetTester tester,
  Future<void> Function(
    AppDatabase database,
    TodoRecord parent,
    TodoRecord child,
    TodoRecord leaf,
  )
  verify,
) async {
  // 不接触实际用户数据库的独立测试实例。
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  // 通过生产仓储建立真实任务树。
  final TodoRepository repository = TodoRepository(database);
  // 固定时钟与任务日期。
  final DateTime now = DateTime(2026, 10, 6, 14);
  // 挂载后的依赖容器，允许初始化中途失败时安全清理。
  ProviderContainer? container;
  try {
    await repository.save(
      TodoDraft(
        title: '右键菜单父任务',
        scheduledDate: now,
        priorityQuadrant: TodoPriorityQuadrant.urgentImportant,
      ),
    );
    // 刚保存的根任务身份。
    final TodoRecord parent =
        (await database.select(database.todoItems).get()).single;
    await repository.save(
      TodoDraft(title: '菜单直属子任务', parentId: parent.id, scheduledDate: now),
    );
    await repository.save(
      TodoDraft(
        title: '没有子项的独立任务',
        scheduledDate: now,
        priorityQuadrant: TodoPriorityQuadrant.urgentImportant,
      ),
    );
    // 共用同一个仓储建立的直属子任务。
    final TodoRecord child = (await database.select(database.todoItems).get())
        .singleWhere((TodoRecord row) => row.parentId == parent.id);
    // 用于验证左键与复选框职责隔离的无子项任务。
    final TodoRecord leaf = (await database.select(database.todoItems).get())
        .singleWhere((TodoRecord row) => row.title == '没有子项的独立任务');
    SharedPreferences.setMockInitialValues(<String, Object>{
      'home.cards.order': <String>['todos', 'todayContext'],
    });
    // 独立的设备偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        appDatabaseProvider.overrideWithValue(database),
        nowProvider.overrideWithValue(now),
      ],
    );
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const OmniButlerApp(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    await verify(database, parent, child, leaf);
    expect(tester.takeException(), isNull);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container?.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    debugDefaultTargetPlatformOverride = null;
  }
}
