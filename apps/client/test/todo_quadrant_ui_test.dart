import 'dart:ui';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/shared/ui/omni_button.dart';
import 'package:omni_butler/app/omni_butler_app.dart';
import 'package:omni_butler/app/router/app_router.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/todos/data/todo_priority_quadrant.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:omni_butler/features/todos/presentation/todo_editor_dialog.dart';
import 'package:omni_butler/shared/ui/omni_icon_button.dart';
import 'package:omni_butler/shared/ui/omni_panel.dart';
import 'package:omni_butler/shared/ui/omni_sliding_segmented_control.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证待办四象限在首页、完整页面与编辑器中保持一致。
void main() {
  testWidgets('首页三个重点区间展示全部任务，不保留隐藏数量入口', (WidgetTester tester) async {
    // 桌面测试视口。
    const Size viewport = Size(1440, 900);
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'appearance.theme_mode': 'light',
    });
    // 测试用主题偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 测试用待办仓储。
    final TodoRepository repository = TodoRepository(database);
    // 首页固定自然日。
    final DateTime today = DateTime(2026, 9, 6);

    for (final TodoPriorityQuadrant quadrant
        in todoPriorityQuadrantMatrixOrder) {
      for (int index = 1; index <= 4; index += 1) {
        await repository.save(
          TodoDraft(
            title: '${quadrant.label}任务$index',
            scheduledDate: today,
            priorityQuadrant: quadrant,
          ),
        );
      }
    }

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          appDatabaseProvider.overrideWithValue(database),
          nowProvider.overrideWithValue(DateTime(2026, 9, 6, 10)),
        ],
        child: const OmniButlerApp(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    // 首页展示的三个重点区间。
    const List<TodoPriorityQuadrant> focusQuadrants = <TodoPriorityQuadrant>[
      TodoPriorityQuadrant.urgentImportant,
      TodoPriorityQuadrant.importantNotUrgent,
      TodoPriorityQuadrant.urgentNotImportant,
    ];
    for (final TodoPriorityQuadrant quadrant in focusQuadrants) {
      expect(find.text('${quadrant.label}任务1'), findsOneWidget);
      expect(find.text('${quadrant.label}任务2'), findsOneWidget);
      expect(find.text('${quadrant.label}任务3'), findsOneWidget);
      expect(find.text('${quadrant.label}任务4'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('${quadrant.label}任务3')).dy,
        lessThan(tester.getTopLeft(find.text('${quadrant.label}任务4')).dy),
      );
    }
    for (int index = 1; index <= 4; index += 1) {
      expect(find.text('不紧急·不重要任务$index'), findsNothing);
    }
    expect(find.textContaining('还有'), findsNothing);
    // 浅色主题下承载重点区间的首页面板。
    final Finder lightPanel = find.ancestor(
      of: find.byKey(const ValueKey<String>('home-todo-quadrant-3')),
      matching: find.byWidgetPredicate(
        (Widget widget) =>
            widget is Material && widget.color == const Color(0xFFFFFFFF),
      ),
    );
    expect(lightPanel, findsOneWidget);

    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('首页完成任务播放反馈动画并提供顶部浮动撤销', (WidgetTester tester) async {
    // 桌面测试视口。
    const Size viewport = Size(1440, 900);
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'appearance.theme_mode': 'light',
    });
    // 测试用主题偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 测试用待办仓储。
    final TodoRepository repository = TodoRepository(database);
    // 首页固定自然日。
    final DateTime today = DateTime(2026, 9, 6);
    await repository.save(
      TodoDraft(
        title: '动画任务',
        scheduledDate: today,
        priorityQuadrant: TodoPriorityQuadrant.urgentImportant,
      ),
    );
    // 首页交互测试使用的待办记录。
    final TodoRecord task =
        (await database.select(database.todoItems).get()).single;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          appDatabaseProvider.overrideWithValue(database),
          nowProvider.overrideWithValue(DateTime(2026, 9, 6, 10)),
        ],
        child: const OmniButlerApp(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    // 当前任务文本。
    final Finder taskText = find.text('动画任务');
    // 当前任务行。
    final Finder taskRow = find.byKey(
      ValueKey<String>('home-todo-row-${task.id}'),
    );
    // 当前任务整行的悬停背景。
    final Finder hoverSurface = find.byKey(
      ValueKey<String>('home-todo-hover-${task.id}'),
    );
    // 模拟桌面鼠标悬停任务行。
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer();
    await mouse.moveTo(tester.getCenter(taskRow));
    await tester.pump(OmniMotion.fast);
    // 悬停后的圆角灰色背景装饰。
    final BoxDecoration hoverDecoration =
        tester.widget<AnimatedContainer>(hoverSurface).decoration!
            as BoxDecoration;
    expect(hoverDecoration.color, isNot(Colors.transparent));
    expect(
      hoverDecoration.borderRadius,
      BorderRadius.circular(OmniRadius.control),
    );
    // 当前任务的勾选框点击热区。
    final Finder checkboxAction = find.byKey(
      ValueKey<String>('home-todo-checkbox-action-${task.id}'),
    );
    await mouse.moveTo(tester.getCenter(checkboxAction));
    await tester.pump(OmniMotion.fast);
    // 勾选框热区本身不再绘制向外溢出的悬停底色。
    final InkWell checkboxInkWell = tester.widget<InkWell>(checkboxAction);
    expect(checkboxInkWell.hoverColor, Colors.transparent);
    // 统一表面与悬停边框仅由实际 18px 勾选框绘制。
    final Finder checkboxIndicatorFinder = find.descendant(
      of: checkboxAction,
      matching: find.byType(AnimatedContainer),
    );
    final AnimatedContainer checkboxIndicator = tester
        .widget<AnimatedContainer>(checkboxIndicatorFinder);
    expect(tester.getSize(checkboxIndicatorFinder), const Size.square(18));
    expect(
      (checkboxIndicator.decoration! as BoxDecoration).color,
      isNot(Colors.transparent),
    );
    await mouse.removePointer();

    // 名称点击保留子任务展开语义，编辑操作使用右键菜单。
    await tester.tap(
      find.byKey(ValueKey<String>('home-todo-title-action-${task.id}')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TodoEditorDialog), findsNothing);
    await tester.tap(
      taskRow,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑任务'));
    await tester.pumpAndSettle();
    expect(find.text('编辑待办'), findsOneWidget);
    expect(
      (await (database.select(
            database.todoItems,
          )..where((TodoItems table) => table.id.equals(task.id))).getSingle())
          .isCompleted,
      isFalse,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    // 只有点击勾选框才触发完成反馈。
    await tester.tap(checkboxAction);
    await tester.pump();

    expect(taskText, findsOneWidget);
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.descendant(
              of: taskRow,
              matching: find.byKey(
                const ValueKey<String>('home-todo-check-mark'),
              ),
            ),
          )
          .opacity,
      1,
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(taskText, findsOneWidget);

    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 190));
    await tester.pump(const Duration(milliseconds: 230));
    await tester.pump();

    // 窗口顶部的统一撤销浮动消息。
    final Finder undoPopup = find.byKey(
      const ValueKey<String>('omni-message-popup'),
    );
    expect(taskText, findsNothing);
    expect(undoPopup, findsOneWidget);
    expect(
      find.descendant(of: undoPopup, matching: find.text('已完成“动画任务”')),
      findsOneWidget,
    );
    expect(find.byType(SnackBar), findsNothing);

    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.descendant(of: undoPopup, matching: find.text('撤销')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(taskText, findsOneWidget);
    expect(undoPopup, findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('每日待办展示四象限且编辑器使用相同分类', (WidgetTester tester) async {
    // 桌面测试视口。
    const Size viewport = Size(1440, 900);
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'appearance.theme_mode': 'light',
    });
    // 测试用主题偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          appDatabaseProvider.overrideWithValue(database),
          nowProvider.overrideWithValue(DateTime(2026, 9, 6, 10)),
        ],
        child: const OmniButlerApp(),
      ),
    );
    // 根组件下的 Provider 容器。
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(OmniButlerApp)),
    );
    container.read(appRouterProvider).go('/todos');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    for (final TodoPriorityQuadrant quadrant
        in todoPriorityQuadrantMatrixOrder) {
      expect(find.text(quadrant.label), findsOneWidget);
      expect(find.text(quadrant.actionLabel), findsOneWidget);
    }
    expect(
      find.byKey(const ValueKey<String>('todo-quadrant-grid')),
      findsOneWidget,
    );
    for (final TodoPriorityQuadrant quadrant
        in todoPriorityQuadrantMatrixOrder) {
      expect(
        find.byKey(ValueKey<String>('todo-quadrant-card-${quadrant.value}')),
        findsOneWidget,
      );
    }
    expect(find.text('重要'), findsNothing);
    expect(find.text('不重要'), findsNothing);
    expect(find.text('紧\n急'), findsNothing);
    expect(find.text('不\n紧\n急'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey<String>('todo-quadrant-heading-3')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('todo-quadrant-grid')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('todo-quadrant-focus-3')),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('todo-quadrant-grid')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('todo-quadrant-focus-3')),
      findsOneWidget,
    );
    // 左侧聚焦的主象限位置。
    final Offset leftFocusedPosition = tester.getTopLeft(
      find.byKey(const ValueKey<String>('todo-quadrant-card-3')),
    );
    // 右侧第一个次要象限位置。
    final Offset firstRightPosition = tester.getTopLeft(
      find.byKey(const ValueKey<String>('todo-quadrant-card-1')),
    );
    // 右侧第二个次要象限位置。
    final Offset secondRightPosition = tester.getTopLeft(
      find.byKey(const ValueKey<String>('todo-quadrant-card-2')),
    );
    // 右侧第三个次要象限位置。
    final Offset thirdRightPosition = tester.getTopLeft(
      find.byKey(const ValueKey<String>('todo-quadrant-card-0')),
    );
    expect(firstRightPosition.dx, greaterThan(leftFocusedPosition.dx));
    expect(secondRightPosition.dx, moreOrLessEquals(firstRightPosition.dx));
    expect(thirdRightPosition.dx, moreOrLessEquals(firstRightPosition.dx));
    expect(secondRightPosition.dy, greaterThan(firstRightPosition.dy));
    expect(thirdRightPosition.dy, greaterThan(secondRightPosition.dy));

    await tester.tap(
      find.byKey(const ValueKey<String>('todo-quadrant-heading-1')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('todo-quadrant-focus-1')),
      findsOneWidget,
    );
    // 右侧聚焦的主象限位置。
    final Offset rightFocusedPosition = tester.getTopLeft(
      find.byKey(const ValueKey<String>('todo-quadrant-card-1')),
    );
    // 左侧纵向列的三个象限位置。
    final List<Offset> leftColumnPositions = <Offset>[
      tester.getTopLeft(
        find.byKey(const ValueKey<String>('todo-quadrant-card-3')),
      ),
      tester.getTopLeft(
        find.byKey(const ValueKey<String>('todo-quadrant-card-2')),
      ),
      tester.getTopLeft(
        find.byKey(const ValueKey<String>('todo-quadrant-card-0')),
      ),
    ];
    expect(leftColumnPositions.first.dx, lessThan(rightFocusedPosition.dx));
    expect(
      leftColumnPositions[1].dx,
      moreOrLessEquals(leftColumnPositions.first.dx),
    );
    expect(
      leftColumnPositions[2].dx,
      moreOrLessEquals(leftColumnPositions.first.dx),
    );
    expect(
      leftColumnPositions[1].dy,
      greaterThan(leftColumnPositions.first.dy),
    );
    expect(leftColumnPositions[2].dy, greaterThan(leftColumnPositions[1].dy));

    container.read(appRouterProvider).go('/home');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('todo-quadrant-focus-1')),
      findsNothing,
    );
    container.read(appRouterProvider).go('/todos');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('todo-quadrant-focus-1')),
      findsOneWidget,
    );
    expect(find.text('返回四象限'), findsNothing);
    expect(find.text('返回'), findsOneWidget);
    // 完成历史分段标签的位置。
    final Rect historyLabelRect = tester.getRect(find.text('完成历史'));
    // 返回按钮的位置。
    final Rect returnButtonRect = tester.getRect(
      find.byKey(const ValueKey<String>('todo-return-quadrants')),
    );
    expect(returnButtonRect.left, greaterThan(historyLabelRect.right));
    await tester.tap(
      find.byKey(const ValueKey<String>('todo-return-quadrants')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('todo-quadrant-focus-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('todo-quadrant-grid')),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('todo-quadrant-grid')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey<String>('todo-primary-create')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // 描述标签。
    final Finder descriptionLabel = find.text('描述（可选）');
    // 优先象限标题。
    final Finder priorityLabel = find.text('优先象限');
    // 默认收起的时间设置。
    final Finder timeSettings = find.byKey(
      const ValueKey<String>('todo-time-settings'),
    );
    expect(find.text('优先象限'), findsOneWidget);
    expect(find.text('备注（可选）'), findsNothing);
    expect(
      tester.getTopLeft(descriptionLabel).dy,
      lessThan(tester.getTopLeft(priorityLabel).dy),
    );
    expect(timeSettings, findsOneWidget);
    expect(find.text('计划日期'), findsNothing);
    expect(find.text('设置截止日期'), findsNothing);
    expect(find.text('设置提醒日期'), findsNothing);
    expect(find.text('重复'), findsNothing);
    for (final TodoPriorityQuadrant quadrant
        in todoPriorityQuadrantMatrixOrder) {
      expect(find.text(quadrant.label), findsNWidgets(2));
      expect(find.text(quadrant.description), findsNothing);
      // 新增弹窗中的紧凑象限选择卡。
      final Finder priorityOption = find.byKey(
        ValueKey<String>('todo-priority-option-${quadrant.value}'),
      );
      expect(priorityOption, findsOneWidget);
      expect(tester.getSize(priorityOption).height, lessThan(94));
    }

    await tester.ensureVisible(timeSettings);
    await tester.tap(timeSettings);
    await tester.pumpAndSettle();
    expect(find.text('计划日期'), findsOneWidget);
    expect(find.text('设置截止日期'), findsOneWidget);
    expect(find.text('设置提醒日期'), findsOneWidget);
    expect(find.text('重复'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('每日待办每个象限限制高度并在卡片内独立滚动', (WidgetTester tester) async {
    // 桌面测试视口。
    const Size viewport = Size(1440, 900);
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'appearance.theme_mode': 'light',
    });
    // 测试用主题偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 测试用待办仓储。
    final TodoRepository repository = TodoRepository(database);
    // 测试使用的固定自然日。
    final DateTime today = DateTime(2026, 9, 6);
    for (final TodoPriorityQuadrant quadrant
        in todoPriorityQuadrantMatrixOrder) {
      for (int index = 1; index <= 18; index += 1) {
        await repository.save(
          TodoDraft(
            title: '${quadrant.label}长列表任务$index',
            scheduledDate: today,
            priorityQuadrant: quadrant,
          ),
        );
      }
    }

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          appDatabaseProvider.overrideWithValue(database),
          nowProvider.overrideWithValue(today.add(const Duration(hours: 10))),
        ],
        child: const OmniButlerApp(),
      ),
    );
    // 根组件下的 Provider 容器。
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(OmniButlerApp)),
    );
    container.read(appRouterProvider).go('/todos');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    // 普通四象限布局区域。
    final Finder gridLayout = find.byKey(
      const ValueKey<String>('todo-quadrant-grid-layout'),
    );
    // 普通四象限布局的窗口内边界。
    final Rect gridBounds = tester.getRect(gridLayout);
    // 普通四象限布局的可用高度。
    final double gridAvailableHeight = gridBounds.height;
    for (final TodoPriorityQuadrant quadrant
        in todoPriorityQuadrantMatrixOrder) {
      // 当前象限卡片。
      final Finder quadrantCard = find.byKey(
        ValueKey<String>('todo-quadrant-card-${quadrant.value}'),
      );
      // 当前象限的多位数任务计数徽标。
      final Finder quadrantCount = find.byKey(
        ValueKey<String>('todo-quadrant-count-${quadrant.value}'),
      );
      // 当前象限的独立滚动视口。
      final Finder quadrantScroll = find.byKey(
        ValueKey<String>('todo-quadrant-scroll-${quadrant.value}'),
      );
      // 当前象限的独立滚动控制器。
      final ScrollController scrollController = tester
          .widget<SingleChildScrollView>(quadrantScroll)
          .controller!;
      // 当前象限在普通四象限布局中的边界。
      final Rect quadrantBounds = tester.getRect(quadrantCard);
      // 多位数计数徽标的实际尺寸。
      final Size quadrantCountSize = tester.getSize(quadrantCount);
      expect(quadrantBounds.height, lessThanOrEqualTo(gridAvailableHeight));
      expect(
        quadrantBounds.bottom,
        lessThanOrEqualTo(gridBounds.bottom + precisionErrorTolerance),
      );
      expect(quadrantCountSize.height, 18);
      expect(quadrantCountSize.width, greaterThan(18));
      expect(scrollController.position.maxScrollExtent, greaterThan(0));
    }

    await tester.tap(
      find.byKey(
        ValueKey<String>(
          'todo-quadrant-heading-${TodoPriorityQuadrant.urgentImportant.value}',
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 聚焦布局区域。
    final Finder focusedLayout = find.byKey(
      ValueKey<String>(
        'todo-quadrant-focus-layout-${TodoPriorityQuadrant.urgentImportant.value}',
      ),
    );
    // 聚焦布局的窗口内边界。
    final Rect focusedBounds = tester.getRect(focusedLayout);
    // 聚焦布局的可用高度。
    final double focusedAvailableHeight = focusedBounds.height;
    for (final TodoPriorityQuadrant quadrant
        in todoPriorityQuadrantMatrixOrder) {
      // 聚焦布局中的当前象限卡片。
      final Finder focusedQuadrantCard = find.byKey(
        ValueKey<String>('todo-quadrant-card-${quadrant.value}'),
      );
      // 聚焦布局中的当前象限滚动视口。
      final Finder focusedQuadrantScroll = find.byKey(
        ValueKey<String>('todo-quadrant-scroll-${quadrant.value}'),
      );
      // 聚焦布局中的当前象限滚动控制器。
      final ScrollController focusedScrollController = tester
          .widget<SingleChildScrollView>(focusedQuadrantScroll)
          .controller!;
      // 聚焦布局中的当前象限边界。
      final Rect focusedQuadrantBounds = tester.getRect(focusedQuadrantCard);
      expect(
        focusedQuadrantBounds.height,
        lessThanOrEqualTo(focusedAvailableHeight),
      );
      expect(
        focusedQuadrantBounds.bottom,
        lessThanOrEqualTo(focusedBounds.bottom + precisionErrorTolerance),
      );
      expect(focusedScrollController.position.maxScrollExtent, greaterThan(0));
    }

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('每日待办完成任务后右滑并提供浮动撤销消息', (WidgetTester tester) async {
    // 桌面测试视口。
    const Size viewport = Size(1440, 900);
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'appearance.theme_mode': 'light',
    });
    // 测试用主题偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 测试用待办仓储。
    final TodoRepository repository = TodoRepository(database);
    // 测试使用的固定自然日。
    final DateTime today = DateTime(2026, 9, 6);
    await repository.save(
      TodoDraft(
        title: '完成反馈任务',
        scheduledDate: today,
        priorityQuadrant: TodoPriorityQuadrant.urgentImportant,
      ),
    );
    // 刚创建的目标任务。
    final TodoRecord completionTodo = await database
        .select(database.todoItems)
        .getSingle();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          appDatabaseProvider.overrideWithValue(database),
          nowProvider.overrideWithValue(DateTime(2026, 9, 6, 10)),
        ],
        child: const OmniButlerApp(),
      ),
    );
    // 根组件下的 Provider 容器。
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(OmniButlerApp)),
    );
    container.read(appRouterProvider).go('/todos');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('完成反馈任务'), findsOneWidget);
    expect(find.text('已保存到本机'), findsNothing);
    // 当前任务的自定义完成复选框。
    final Finder completionCheckbox = find.byKey(
      ValueKey<String>('todo-completion-checkbox-${completionTodo.id}'),
    );
    // 当前复选框视觉方框。
    final Finder completionBox = find.descendant(
      of: completionCheckbox,
      matching: find.byKey(const ValueKey<String>('todo-completion-box')),
    );
    expect(completionCheckbox, findsOneWidget);
    expect(tester.getSize(completionCheckbox), const Size.square(32));
    expect(tester.getSize(completionBox), const Size.square(18));
    await tester.tap(completionCheckbox);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 399));
    expect(find.text('完成反馈任务'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 111));
    // 正在向右滑出的任务行。
    final FractionalTranslation slidingTask = tester.widget(
      find.byKey(
        ValueKey<String>('todo-completion-slide-${completionTodo.id}'),
      ),
    );
    expect(slidingTask.translation.dx, greaterThan(0));
    await tester.pump(const Duration(milliseconds: 111));
    await tester.pump();
    expect(find.text('完成反馈任务'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('omni-message-popup')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('omni-message-positioned')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('todo-quadrant-grid')),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('撤销'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('完成反馈任务'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('omni-message-popup')),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('每日待办按剩余子任务决定单行或整树右滑', (WidgetTester tester) async {
    // 桌面测试视口。
    const Size viewport = Size(1440, 900);
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'appearance.theme_mode': 'light',
    });
    // 测试用主题偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 测试用待办仓储。
    final TodoRepository repository = TodoRepository(database);
    // 测试使用的固定自然日。
    final DateTime today = DateTime(2026, 9, 6);
    await repository.save(
      TodoDraft(
        title: '发布版本',
        scheduledDate: today,
        priorityQuadrant: TodoPriorityQuadrant.urgentImportant,
      ),
    );
    // 新增后的父任务。
    final TodoRecord root = await database
        .select(database.todoItems)
        .getSingle();
    await repository.save(
      TodoDraft(title: '整理说明', parentId: root.id, scheduledDate: today),
    );
    await repository.save(
      TodoDraft(title: '检查构建', parentId: root.id, scheduledDate: today),
    );
    // 按创建顺序排列的两个子任务。
    final List<TodoRecord> children = await (database.select(
      database.todoItems,
    )..where((TodoItems table) => table.parentId.equals(root.id))).get();
    children.sort(
      (TodoRecord left, TodoRecord right) =>
          left.sortOrder.compareTo(right.sortOrder),
    );
    // 第一个完成的子任务。
    final TodoRecord firstChild = children.first;
    // 最后完成的子任务。
    final TodoRecord lastChild = children.last;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          appDatabaseProvider.overrideWithValue(database),
          nowProvider.overrideWithValue(DateTime(2026, 9, 6, 10)),
        ],
        child: const OmniButlerApp(),
      ),
    );
    // 根组件下的 Provider 容器。
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(OmniButlerApp)),
    );
    container.read(appRouterProvider).go('/todos');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    await tester.tap(
      find.byKey(ValueKey<String>('todo-completion-checkbox-${firstChild.id}')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 510));
    // 第一个子任务的右滑动画。
    final FractionalTranslation firstChildSlide = tester.widget(
      find.byKey(ValueKey<String>('todo-completion-slide-${firstChild.id}')),
    );
    // 父任务保持原位。
    final FractionalTranslation stationaryRoot = tester.widget(
      find.byKey(ValueKey<String>('todo-completion-slide-${root.id}')),
    );
    expect(firstChildSlide.translation.dx, greaterThan(0));
    expect(stationaryRoot.translation.dx, 0);
    await tester.pump(const Duration(milliseconds: 111));
    await tester.pump();
    expect(find.text(firstChild.title), findsNothing);
    expect(find.text(lastChild.title), findsOneWidget);
    expect(find.text(root.title), findsOneWidget);
    // 完成一个子任务后显示剩余数量与子任务总数。
    final Finder remainingChildCountTag = find.byKey(
      ValueKey<String>('todo-tree-progress-${root.id}'),
    );
    expect(remainingChildCountTag, findsOneWidget);
    expect(
      find.descendant(of: remainingChildCountTag, matching: find.text('1/2')),
      findsOneWidget,
    );
    // 完成一个子任务后父任务仍保持未完成。
    final TodoRecord pendingRoot = await (database.select(
      database.todoItems,
    )..where((TodoItems table) => table.id.equals(root.id))).getSingle();
    expect(pendingRoot.isCompleted, isFalse);

    await tester.tap(
      find.byKey(ValueKey<String>('todo-completion-checkbox-${lastChild.id}')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 510));
    // 最后一个子任务的右滑动画。
    final FractionalTranslation lastChildSlide = tester.widget(
      find.byKey(ValueKey<String>('todo-completion-slide-${lastChild.id}')),
    );
    // 与最后一个子任务同步右滑的父任务动画。
    final FractionalTranslation rootSlide = tester.widget(
      find.byKey(ValueKey<String>('todo-completion-slide-${root.id}')),
    );
    expect(lastChildSlide.translation.dx, greaterThan(0));
    expect(rootSlide.translation.dx, greaterThan(0));
    await tester.pump(const Duration(milliseconds: 111));
    await tester.pump();
    expect(find.text(lastChild.title), findsNothing);
    expect(find.text(root.title), findsNothing);
    // 最后一个子任务完成后自动完成的父任务。
    final TodoRecord completedRoot = await (database.select(
      database.todoItems,
    )..where((TodoItems table) => table.id.equals(root.id))).getSingle();
    expect(completedRoot.isCompleted, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('每日待办勾选父任务时无需确认并直接完成整树', (WidgetTester tester) async {
    // 桌面测试视口。
    const Size viewport = Size(1440, 900);
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'appearance.theme_mode': 'light',
    });
    // 测试用主题偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 测试用待办仓储。
    final TodoRepository repository = TodoRepository(database);
    // 测试使用的固定自然日。
    final DateTime today = DateTime(2026, 9, 6);
    await repository.save(
      TodoDraft(
        title: '直接完成父任务',
        scheduledDate: today,
        priorityQuadrant: TodoPriorityQuadrant.urgentImportant,
      ),
    );
    // 新增后的父任务。
    final TodoRecord root = await database
        .select(database.todoItems)
        .getSingle();
    await repository.save(
      TodoDraft(title: '随父任务完成', parentId: root.id, scheduledDate: today),
    );
    // 新增后的子任务。
    final TodoRecord child = await (database.select(
      database.todoItems,
    )..where((TodoItems table) => table.parentId.equals(root.id))).getSingle();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          appDatabaseProvider.overrideWithValue(database),
          nowProvider.overrideWithValue(DateTime(2026, 9, 6, 10)),
        ],
        child: const OmniButlerApp(),
      ),
    );
    // 根组件下的 Provider 容器。
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(OmniButlerApp)),
    );
    container.read(appRouterProvider).go('/todos');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    await tester.tap(
      find.byKey(ValueKey<String>('todo-completion-checkbox-${root.id}')),
    );
    await tester.pump();
    expect(find.text('完成整个任务？'), findsNothing);
    expect(find.text('全部完成'), findsNothing);
    await tester.pump(const Duration(milliseconds: 510));
    // 正在一起向右滑出的父任务。
    final FractionalTranslation rootSlide = tester.widget(
      find.byKey(ValueKey<String>('todo-completion-slide-${root.id}')),
    );
    // 正在一起向右滑出的子任务。
    final FractionalTranslation childSlide = tester.widget(
      find.byKey(ValueKey<String>('todo-completion-slide-${child.id}')),
    );
    expect(rootSlide.translation.dx, greaterThan(0));
    expect(childSlide.translation.dx, greaterThan(0));
    await tester.pump(const Duration(milliseconds: 111));
    await tester.pump();
    // 完成后的整棵任务树数据库记录。
    final List<TodoRecord> completedTree = await database
        .select(database.todoItems)
        .get();
    expect(completedTree, hasLength(2));
    expect(
      completedTree.every((TodoRecord record) => record.isCompleted),
      isTrue,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('每日待办移动端可从纵向四象限聚焦单个象限', (WidgetTester tester) async {
    // 移动端测试视口。
    const Size viewport = Size(390, 844);
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'appearance.theme_mode': 'light',
    });
    // 测试用主题偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 移动端导航数量角标使用的测试仓储。
    final TodoRepository repository = TodoRepository(database);
    await repository.save(
      TodoDraft(
        title: '移动端角标任务',
        scheduledDate: DateTime(2026, 9, 6),
        priorityQuadrant: TodoPriorityQuadrant.urgentImportant,
      ),
    );
    // 移动端交互测试使用的主任务记录。
    final TodoRecord mobileRoot = await database
        .select(database.todoItems)
        .getSingle();
    await repository.save(
      TodoDraft(
        title: '移动端展开子任务',
        parentId: mobileRoot.id,
        scheduledDate: DateTime(2026, 9, 6),
      ),
    );
    // 用于验证移动端子任务行高度的记录。
    final TodoRecord mobileChild =
        await (database.select(
              database.todoItems,
            )..where((TodoItems table) => table.parentId.equals(mobileRoot.id)))
            .getSingle();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          appDatabaseProvider.overrideWithValue(database),
          nowProvider.overrideWithValue(DateTime(2026, 9, 6, 10)),
        ],
        child: const OmniButlerApp(),
      ),
    );
    // 根组件下的 Provider 容器。
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(OmniButlerApp)),
    );
    container.read(appRouterProvider).go('/todos');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(
      find.byKey(const ValueKey<String>('todo-mobile-filter-all')),
      findsOneWidget,
    );
    expect(find.text('每日待办'), findsNothing);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(
      find.byType(OmniSlidingSegmentedControl<TodoPriorityQuadrant?>),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('todo-mobile-view-navigation')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('todo-mobile-count-3')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('todo-mobile-count-2')),
      findsNothing,
    );
    for (final double width in <double>[320, 360, 390]) {
      tester.view.physicalSize = Size(width, viewport.height);
      await tester.pumpAndSettle();
      // 当前宽度下的移动端父任务行。
      final Finder mobileRootRow = find.byKey(
        ValueKey<String>('todo-tree-root-${mobileRoot.id}'),
      );
      // 当前宽度下的移动端子任务行。
      final Finder mobileChildRow = find.byKey(
        ValueKey<String>('todo-child-${mobileChild.id}'),
      );
      // 48 像素触控热区加上下各 2 像素留白，父子任务保持同一行高。
      expect(tester.getSize(mobileRootRow).height, OmniSize.touch + 4);
      expect(tester.getSize(mobileChildRow).height, OmniSize.touch + 4);
      expect(tester.takeException(), isNull);
    }
    // 移动端父任务行中的新增子任务操作。
    final Finder mobileAddChild = find.byKey(
      ValueKey<String>('todo-add-child-${mobileRoot.id}'),
    );
    // 移动端父任务行中的更多操作菜单。
    final Finder mobileMoreAction = find.descendant(
      of: find.byKey(ValueKey<String>('todo-tree-root-${mobileRoot.id}')),
      matching: find.byTooltip('更多操作'),
    );
    expect(tester.getSize(mobileAddChild), const Size.square(OmniSize.touch));
    expect(tester.getSize(mobileMoreAction), const Size.square(OmniSize.touch));
    await tester.tap(mobileAddChild);
    await tester.pumpAndSettle();
    expect(find.text('新增子任务'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(mobileMoreAction);
    await tester.pumpAndSettle();
    expect(find.text('编辑'), findsOneWidget);
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(find.byType(TodoEditorDialog), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    // 待办象限轨道中的滑块动画。
    final AnimatedAlign quadrantIndicator = tester.widget<AnimatedAlign>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('todo-mobile-quadrant-filters')),
        matching: find.byType(AnimatedAlign),
      ),
    );
    expect(quadrantIndicator.duration, OmniMotion.normal);
    expect(quadrantIndicator.curve, OmniMotion.standardCurve);
    // 一级视图轨道中的滑块动画。
    final AnimatedAlign viewIndicator = tester.widget<AnimatedAlign>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('todo-mobile-view-filters')),
        matching: find.byType(AnimatedAlign),
      ),
    );
    expect(viewIndicator.duration, OmniMotion.normal);
    expect(viewIndicator.curve, OmniMotion.standardCurve);
    expect(
      find.byKey(const ValueKey<String>('todo-mobile-create')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('todo-primary-create')),
      findsNothing,
    );
    for (final TodoPriorityQuadrant quadrant
        in todoPriorityQuadrantMatrixOrder) {
      expect(
        find.byKey(
          ValueKey<String>('todo-mobile-section-${quadrant.value}-all'),
        ),
        findsOneWidget,
      );
      // 当前移动端象限标题行。
      final Finder mobileHeading = find.byKey(
        ValueKey<String>('todo-quadrant-heading-${quadrant.value}'),
      );
      // 当前移动端象限批量折叠按钮。
      final Finder mobileToggleAll = find.byKey(
        ValueKey<String>('todo-quadrant-toggle-all-${quadrant.value}'),
      );
      // 当前移动端象限新增按钮。
      final Finder mobileCreate = find.byKey(
        ValueKey<String>('todo-quadrant-create-${quadrant.value}'),
      );
      expect(tester.getSize(mobileHeading).height, OmniSize.touch);
      expect(
        tester.getSize(mobileToggleAll),
        const Size.square(OmniSize.touch),
      );
      expect(tester.getSize(mobileCreate), const Size.square(OmniSize.touch));
      expect(
        find.descendant(
          of: mobileHeading,
          matching: find.text(quadrant.actionLabel),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: mobileHeading, matching: find.text(quadrant.label)),
        findsNothing,
      );
    }
    // 有子任务象限的移动端批量折叠按钮。
    final Finder mobileToggleAll = find.byKey(
      ValueKey<String>(
        'todo-quadrant-toggle-all-${TodoPriorityQuadrant.urgentImportant.value}',
      ),
    );
    await tester.tap(mobileToggleAll);
    await tester.pump();
    expect(find.text('移动端展开子任务'), findsNothing);
    await tester.tap(mobileToggleAll);
    await tester.pump();
    expect(find.text('移动端展开子任务'), findsOneWidget);
    // 有子任务象限的移动端新增按钮。
    final Finder mobileCreate = find.byKey(
      ValueKey<String>(
        'todo-quadrant-create-${TodoPriorityQuadrant.urgentImportant.value}',
      ),
    );
    await tester.tap(mobileCreate);
    await tester.pumpAndSettle();
    expect(find.byType(TodoEditorDialog), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(TodoEditorDialog), findsNothing);
    expect(
      find.byKey(ValueKey<String>('todo-tree-toggle-${mobileRoot.id}')),
      findsNothing,
    );
    expect(find.text('移动端展开子任务'), findsOneWidget);
    // 点击移动端父任务名称只收起子任务，不打开编辑器。
    final Finder mobileRootTitle = find.byKey(
      ValueKey<String>('todo-title-${mobileRoot.id}'),
    );
    await tester.tap(mobileRootTitle);
    await tester.pump();
    expect(find.text('移动端展开子任务'), findsNothing);
    expect(find.text('编辑待办'), findsNothing);
    await tester.tap(mobileRootTitle);
    await tester.pump();
    expect(find.text('移动端展开子任务'), findsOneWidget);

    // 移动端整页横滑区域。
    final Finder swipeSurface = find.byKey(
      const ValueKey<String>('todo-mobile-swipe-surface'),
    );
    // 横滑前固定待办导航的边界。
    final Rect todoNavigationRect = tester.getRect(
      find.byKey(const ValueKey<String>('todo-mobile-view-navigation')),
    );
    // 横滑前象限导航滑块的水平位置。
    final double todoIndicatorStart = quadrantIndicator.alignment
        .resolve(TextDirection.ltr)
        .x;
    // 用于检查待办象限跟手中间态的真实触摸手势。
    final TestGesture todoGesture = await tester.startGesture(
      tester.getTopLeft(swipeSurface) + const Offset(330, 240),
    );
    await todoGesture.moveBy(const Offset(-24, 0));
    await tester.pump();
    await todoGesture.moveBy(const Offset(-72, 0));
    await tester.pump();
    // 正在离开的全部象限卡片缩放变换。
    final Transform todoCurrentScale = tester.widget<Transform>(
      find.byKey(const ValueKey<String>('nested-page-swipe-0-scale')),
    );
    // 正在进入的单象限卡片缩放变换。
    final Transform todoTargetScale = tester.widget<Transform>(
      find.byKey(const ValueKey<String>('nested-page-swipe-1-scale')),
    );
    // 正在离开的全部象限卡片外观。
    final PhysicalModel todoCurrentCard = tester.widget<PhysicalModel>(
      find.byKey(const ValueKey<String>('nested-page-swipe-0-card')),
    );
    // 跟手中的象限导航滑块水平位置。
    final double todoIndicatorDragged = tester
        .widget<AnimatedAlign>(
          find.descendant(
            of: find.byKey(
              const ValueKey<String>('todo-mobile-quadrant-filters'),
            ),
            matching: find.byType(AnimatedAlign),
          ),
        )
        .alignment
        .resolve(TextDirection.ltr)
        .x;
    expect(todoCurrentScale.transform.storage[0], lessThan(1));
    expect(todoTargetScale.transform.storage[0], greaterThan(0.985));
    expect(todoCurrentCard.elevation, greaterThan(0));
    expect(
      tester.getRect(
        find.byKey(const ValueKey<String>('todo-mobile-view-navigation')),
      ),
      todoNavigationRect,
    );
    expect(todoIndicatorDragged, greaterThan(todoIndicatorStart));
    await todoGesture.moveBy(const Offset(72, 0));
    await todoGesture.up();
    await tester.pumpAndSettle();
    // 向左依次切换立即处理、安排时间、快速处理和有空再做。
    for (final TodoPriorityQuadrant quadrant
        in todoPriorityQuadrantActionOrder) {
      await tester.fling(swipeSurface, const Offset(-160, 0), 800);
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          ValueKey<String>('todo-mobile-section-${quadrant.value}-focused'),
        ),
        findsOneWidget,
      );
    }
    // 最末分类继续左滑时向一级导航接力进入时间页。
    await tester.fling(swipeSurface, const Offset(-160, 0), 800);
    await tester.pumpAndSettle();
    expect(
      container.read(appRouterProvider).routeInformationProvider.value.uri.path,
      '/timeline',
    );
    // 返回待办后保留末项选择，继续验证内部反向相邻切换。
    container.read(appRouterProvider).go('/todos');
    await tester.pumpAndSettle();
    // 向右回到快速处理，验证反向相邻切换。
    await tester.fling(
      find.byKey(const ValueKey<String>('todo-mobile-swipe-surface')),
      const Offset(160, 0),
      800,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('todo-mobile-section-1-focused')),
      findsOneWidget,
    );

    for (final double width in <double>[320, 360, 390]) {
      tester.view.physicalSize = Size(width, viewport.height);
      await tester.pumpAndSettle();
      // 当前宽度下的一体化导航边界。
      final Rect navigationRect = tester.getRect(
        find.byKey(const ValueKey<String>('todo-mobile-view-navigation')),
      );
      for (final TodoPriorityQuadrant? quadrant in <TodoPriorityQuadrant?>[
        null,
        ...todoPriorityQuadrantActionOrder,
      ]) {
        // 当前象限点击区域边界。
        final Rect filterRect = tester.getRect(
          find.byKey(
            ValueKey<String>(
              quadrant == null
                  ? 'todo-mobile-filter-all'
                  : 'todo-mobile-filter-${quadrant.value}',
            ),
          ),
        );
        expect(filterRect.left, greaterThanOrEqualTo(navigationRect.left));
        expect(filterRect.right, lessThanOrEqualTo(navigationRect.right));
      }
      // 当前窄屏聚焦象限的标题行。
      final Finder focusedMobileHeading = find.byKey(
        const ValueKey<String>('todo-quadrant-heading-1'),
      );
      // 聚焦视图与总览视图共用 Android 的完整触控标题操作区。
      expect(tester.getSize(focusedMobileHeading).height, OmniSize.touch);
      expect(tester.takeException(), isNull);
    }

    await tester.tap(
      find.byKey(const ValueKey<String>('todo-mobile-filter-2')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('todo-mobile-section-2-focused')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('todo-mobile-section-3-all')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('todo-mobile-view-history')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('todo-mobile-history-date-row')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('todo-mobile-quadrant-filters')),
      findsNothing,
    );
    for (final double width in <double>[320, 360, 390]) {
      tester.view.physicalSize = Size(width, viewport.height);
      await tester.pumpAndSettle();
      // 当前宽度下的历史日期行边界。
      final Rect dateRowRect = tester.getRect(
        find.byKey(const ValueKey<String>('todo-mobile-history-date-row')),
      );
      // 当前宽度下的一体化导航边界。
      final Rect navigationRect = tester.getRect(
        find.byKey(const ValueKey<String>('todo-mobile-view-navigation')),
      );
      expect(dateRowRect.left, greaterThanOrEqualTo(navigationRect.left));
      expect(dateRowRect.right, lessThanOrEqualTo(navigationRect.right));
      expect(tester.takeException(), isNull);
    }
    await tester.tap(
      find.byKey(const ValueKey<String>('todo-mobile-view-active')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('todo-mobile-section-2-focused')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('每日待办进行中跨计划日期常驻且完成历史按完成日展示', (WidgetTester tester) async {
    // 桌面测试视口。
    const Size viewport = Size(1440, 900);
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'appearance.theme_mode': 'light',
    });
    // 测试用主题偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 测试用待办仓储。
    final TodoRepository repository = TodoRepository(database);
    // 与仓储完成时间一致的当前自然日。
    final DateTime today = DateUtils.dateOnly(DateTime.now());
    await repository.save(
      TodoDraft(
        title: '历史遗留任务',
        scheduledDate: today.subtract(const Duration(days: 5)),
      ),
    );
    await repository.save(
      TodoDraft(
        title: '未来计划任务',
        scheduledDate: today.add(const Duration(days: 5)),
      ),
    );
    await repository.save(
      TodoDraft(
        title: '今天完成任务',
        scheduledDate: today.subtract(const Duration(days: 2)),
      ),
    );
    // 待完成记录。
    final TodoRecord completed = await (database.select(
      database.todoItems,
    )..where((TodoItems table) => table.title.equals('今天完成任务'))).getSingle();
    await repository.setCompleted(completed.id, true);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          appDatabaseProvider.overrideWithValue(database),
          nowProvider.overrideWithValue(today.add(const Duration(hours: 10))),
        ],
        child: const OmniButlerApp(),
      ),
    );
    // 根组件下的 Provider 容器。
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(OmniButlerApp)),
    );
    container.read(appRouterProvider).go('/todos');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('历史遗留任务'), findsOneWidget);
    expect(find.text('未来计划任务'), findsOneWidget);
    expect(find.text('今天完成任务'), findsNothing);
    await tester.tap(find.text('完成历史'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('今天完成任务'), findsOneWidget);
    expect(find.text('历史遗留任务'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('每日待办完成历史按父任务聚类并默认展开', (WidgetTester tester) async {
    // 桌面测试视口。
    const Size viewport = Size(1440, 900);
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'appearance.theme_mode': 'light',
    });
    // 测试用主题偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 测试用待办仓储。
    final TodoRepository repository = TodoRepository(database);
    // 与仓储完成时间一致的当前自然日。
    final DateTime today = DateUtils.dateOnly(DateTime.now());
    await repository.save(
      TodoDraft(
        title: '发布父任务',
        scheduledDate: today,
        priorityQuadrant: TodoPriorityQuadrant.urgentImportant,
      ),
    );
    // 新增后的父任务。
    final TodoRecord root = await database
        .select(database.todoItems)
        .getSingle();
    await repository.save(
      TodoDraft(title: '准备说明', parentId: root.id, scheduledDate: today),
    );
    await repository.save(
      TodoDraft(title: '检查构建', parentId: root.id, scheduledDate: today),
    );
    await repository.setCompleted(root.id, true);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          appDatabaseProvider.overrideWithValue(database),
          nowProvider.overrideWithValue(today.add(const Duration(hours: 10))),
        ],
        child: const OmniButlerApp(),
      ),
    );
    // 根组件下的 Provider 容器。
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(OmniButlerApp)),
    );
    container.read(appRouterProvider).go('/todos');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.text('完成历史'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      find.byKey(ValueKey<String>('todo-history-group-${root.id}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey<String>('todo-history-children-${root.id}')),
      findsOneWidget,
    );
    expect(find.text('发布父任务'), findsOneWidget);
    expect(find.text('准备说明'), findsOneWidget);
    expect(find.text('检查构建'), findsOneWidget);

    await tester.tap(
      find.byKey(ValueKey<String>('todo-history-toggle-${root.id}')),
    );
    await tester.pump();
    expect(
      find.byKey(ValueKey<String>('todo-history-children-${root.id}')),
      findsNothing,
    );
    expect(find.text('发布父任务'), findsOneWidget);
    expect(find.text('准备说明'), findsNothing);
    expect(find.text('检查构建'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('每日待办展示子任务进度并可拖动整树跨象限', (WidgetTester tester) async {
    // 桌面测试视口。
    const Size viewport = Size(1440, 900);
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'appearance.theme_mode': 'light',
    });
    // 测试用主题偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 测试用待办仓储。
    final TodoRepository repository = TodoRepository(database);
    // 当前测试自然日。
    final DateTime today = DateTime(2026, 9, 21);
    await repository.save(
      TodoDraft(
        title: '发布主任务',
        description: '核对发布清单',
        scheduledDate: today,
        dueAt: DateTime(2026, 9, 21, 18),
        priorityQuadrant: TodoPriorityQuadrant.urgentImportant,
      ),
    );
    // 主任务记录。
    final TodoRecord root = await database
        .select(database.todoItems)
        .getSingle();
    await repository.save(
      TodoDraft(title: '发布子任务', parentId: root.id, scheduledDate: today),
    );
    await repository.save(
      TodoDraft(title: '已完成子任务', parentId: root.id, scheduledDate: today),
    );
    // 主任务下的全部子任务记录。
    final List<TodoRecord> children = await (database.select(
      database.todoItems,
    )..where((TodoItems table) => table.parentId.equals(root.id))).get();
    // 仍未完成的子任务记录。
    final TodoRecord pendingChild = children.singleWhere(
      (TodoRecord child) => child.title == '发布子任务',
    );
    // 准备用于验证总数的已完成子任务记录。
    final TodoRecord completedChild = children.singleWhere(
      (TodoRecord child) => child.title == '已完成子任务',
    );
    await repository.setCompleted(completedChild.id, true);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          appDatabaseProvider.overrideWithValue(database),
          nowProvider.overrideWithValue(today.add(const Duration(hours: 10))),
        ],
        child: const OmniButlerApp(),
      ),
    );
    // 根组件下的 Provider 容器。
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(OmniButlerApp)),
    );
    container.read(appRouterProvider).go('/todos');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('发布主任务'), findsOneWidget);
    expect(find.text('核对发布清单'), findsOneWidget);
    expect(find.text('发布子任务'), findsOneWidget);
    // 显示未完成子任务数量与子任务总数的进度标签。
    final Finder childCountTag = find.byKey(
      ValueKey<String>('todo-tree-progress-${root.id}'),
    );
    expect(childCountTag, findsOneWidget);
    expect(
      find.descendant(of: childCountTag, matching: find.text('1/2')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey<String>('todo-tree-branch-${pendingChild.id}')),
      findsOneWidget,
    );
    // 父任务的统一列表行。
    final OmniListRow rootListRow = tester.widget<OmniListRow>(
      find.descendant(
        of: find.byKey(ValueKey<String>('todo-tree-root-${root.id}')),
        matching: find.byType(OmniListRow),
      ),
    );
    // 子任务的统一列表行。
    final OmniListRow childListRow = tester.widget<OmniListRow>(
      find.descendant(
        of: find.byKey(ValueKey<String>('todo-child-${pendingChild.id}')),
        matching: find.byType(OmniListRow),
      ),
    );
    expect(rootListRow.borderRadius, BorderRadius.circular(OmniRadius.control));
    expect(
      childListRow.borderRadius,
      BorderRadius.circular(OmniRadius.control),
    );
    expect(find.text('截止 9月21日 18:00'), findsOneWidget);
    expect(find.text('计划 9月21日'), findsNothing);
    for (final TodoPriorityQuadrant quadrant
        in todoPriorityQuadrantMatrixOrder) {
      expect(
        find.byKey(
          ValueKey<String>('todo-quadrant-toggle-all-${quadrant.value}'),
        ),
        findsOneWidget,
      );
    }
    // 当前象限标题栏中的批量折叠按钮。
    final Finder quadrantToggleAll = find.byKey(
      ValueKey<String>(
        'todo-quadrant-toggle-all-${TodoPriorityQuadrant.urgentImportant.value}',
      ),
    );
    // 当前象限标题文字。
    final Finder quadrantTitle = find.byKey(
      ValueKey<String>(
        'todo-quadrant-title-${TodoPriorityQuadrant.urgentImportant.value}',
      ),
    );
    // 当前象限标题右侧的任务计数。
    final Finder quadrantCount = find.byKey(
      ValueKey<String>(
        'todo-quadrant-count-${TodoPriorityQuadrant.urgentImportant.value}',
      ),
    );
    // 当前象限标题栏中的新增按钮。
    final Finder quadrantCreate = find.byKey(
      ValueKey<String>(
        'todo-quadrant-create-${TodoPriorityQuadrant.urgentImportant.value}',
      ),
    );
    // 当前象限批量按钮的初始配置。
    final OmniIconButton initialToggleAllButton = tester.widget<OmniIconButton>(
      quadrantToggleAll,
    );
    expect(initialToggleAllButton.tooltip, '收起全部子任务');
    expect(initialToggleAllButton.onPressed, isNotNull);
    expect(tester.getSize(quadrantCount), const Size.square(18));
    expect(
      tester.getCenter(quadrantCount).dy,
      moreOrLessEquals(tester.getCenter(quadrantTitle).dy),
    );
    expect(
      tester.getTopLeft(quadrantCount).dx,
      greaterThanOrEqualTo(tester.getTopRight(quadrantTitle).dx),
    );
    expect(
      tester.getTopRight(quadrantCount).dx,
      lessThan(tester.getTopLeft(quadrantToggleAll).dx),
    );
    expect(
      tester.getTopLeft(quadrantToggleAll).dx,
      lessThan(tester.getTopLeft(quadrantCreate).dx),
    );
    await tester.tap(quadrantToggleAll);
    await tester.pump();
    expect(find.text('发布子任务'), findsNothing);
    expect(tester.widget<OmniIconButton>(quadrantToggleAll).tooltip, '展开全部子任务');
    await tester.tap(quadrantToggleAll);
    await tester.pump();
    expect(find.text('发布子任务'), findsOneWidget);
    expect(tester.widget<OmniIconButton>(quadrantToggleAll).tooltip, '收起全部子任务');
    // 同行展示的任务名称与描述。
    final Finder rootTitle = find.byKey(
      ValueKey<String>('todo-title-${root.id}'),
    );
    final Finder rootDescription = find.byKey(
      ValueKey<String>('todo-description-${root.id}'),
    );
    // 名称与描述文字组件。
    final Text rootTitleText = tester.widget(rootTitle);
    final Text rootDescriptionText = tester.widget(rootDescription);
    expect(
      tester.getTopLeft(rootDescription).dx,
      greaterThan(tester.getTopRight(rootTitle).dx),
    );
    expect(
      rootDescriptionText.style!.fontSize,
      lessThan(rootTitleText.style!.fontSize!),
    );
    // 父任务左侧同时支持单击折叠与拖拽。
    final Finder treeToggle = find.byKey(
      ValueKey<String>('todo-tree-toggle-${root.id}'),
    );
    expect(treeToggle, findsOneWidget);
    expect(find.byTooltip('收起子任务'), findsOneWidget);
    await tester.tap(treeToggle);
    await tester.pump();
    expect(find.text('发布子任务'), findsNothing);
    expect(
      find.byKey(ValueKey<String>('todo-tree-branch-${pendingChild.id}')),
      findsNothing,
    );
    expect(find.byTooltip('展开子任务'), findsOneWidget);
    expect(tester.widget<OmniIconButton>(quadrantToggleAll).tooltip, '展开全部子任务');
    await tester.tap(treeToggle);
    await tester.pump();
    expect(find.text('发布子任务'), findsOneWidget);
    expect(
      find.byKey(ValueKey<String>('todo-tree-branch-${pendingChild.id}')),
      findsOneWidget,
    );
    expect(tester.widget<OmniIconButton>(quadrantToggleAll).tooltip, '收起全部子任务');
    // 父任务行上直接展示的添加子任务按钮。
    final Finder addChildButton = find.byKey(
      ValueKey<String>('todo-add-child-${root.id}'),
    );
    expect(addChildButton, findsOneWidget);
    expect(find.byTooltip('添加子任务'), findsOneWidget);
    await tester.tap(addChildButton);
    await tester.pumpAndSettle();
    expect(find.text('新增子任务'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    // 父任务行的更多菜单不再包含添加子任务入口。
    final Finder rootRow = find.byKey(
      ValueKey<String>('todo-tree-root-${root.id}'),
    );
    final Finder rootMoreButton = find.descendant(
      of: rootRow,
      matching: find.byTooltip('更多操作'),
    );
    await tester.tap(rootMoreButton);
    await tester.pumpAndSettle();
    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('添加子任务'), findsNothing);
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    // 第一行左侧有子任务的象限卡片。
    final Finder tallerQuadrant = find.byKey(
      ValueKey<String>(
        'todo-quadrant-card-${TodoPriorityQuadrant.urgentImportant.value}',
      ),
    );
    // 第一行右侧空状态象限卡片。
    final Finder filledQuadrant = find.byKey(
      ValueKey<String>(
        'todo-quadrant-card-${TodoPriorityQuadrant.urgentNotImportant.value}',
      ),
    );
    expect(
      tester.getSize(filledQuadrant).height,
      tester.getSize(tallerQuadrant).height,
    );
    // 主任务拖动手柄。
    final Finder handle = find.byKey(
      ValueKey<String>('todo-drag-handle-${root.id}'),
    );
    // 快速处理象限放置区。
    final Finder target = find.byKey(
      const ValueKey<String>('todo-drop-quadrant-1'),
    );
    // 模拟桌面拖动到目标象限。
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(handle),
    );
    await gesture.moveTo(tester.getCenter(target));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // 拖动后的主任务。
    final TodoRecord movedRoot = await (database.select(
      database.todoItems,
    )..where((TodoItems table) => table.id.equals(root.id))).getSingle();
    // 拖动后的全部子任务。
    final List<TodoRecord> movedChildren = await (database.select(
      database.todoItems,
    )..where((TodoItems table) => table.parentId.equals(root.id))).get();
    expect(
      movedRoot.priorityQuadrant,
      TodoPriorityQuadrant.urgentNotImportant.value,
    );
    expect(
      movedChildren.every(
        (TodoRecord child) =>
            child.priorityQuadrant ==
            TodoPriorityQuadrant.urgentNotImportant.value,
      ),
      isTrue,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('每日待办回收站使用统一语义按钮并保留取消和删除结果', (WidgetTester tester) async {
    // 桌面测试视口。
    const Size viewport = Size(1440, 900);
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'appearance.theme_mode': 'light',
    });
    // 测试用主题偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 测试用待办仓储。
    final TodoRepository repository = TodoRepository(database);
    // 当前测试自然日。
    final DateTime today = DateTime(2026, 9, 21);
    await repository.save(
      TodoDraft(
        title: '待回收任务',
        scheduledDate: today,
        priorityQuadrant: TodoPriorityQuadrant.urgentImportant,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          appDatabaseProvider.overrideWithValue(database),
          nowProvider.overrideWithValue(today.add(const Duration(hours: 10))),
        ],
        child: const OmniButlerApp(),
      ),
    );
    // 根组件下的 Provider 容器。
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(OmniButlerApp)),
    );
    container.read(appRouterProvider).go('/todos');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移入回收站'));
    await tester.pumpAndSettle();

    // 取消按钮。
    final Finder cancelButton = find.byKey(
      const ValueKey<String>('todo-recycle-cancel-button'),
    );
    // 危险确认按钮。
    final Finder confirmButton = find.byKey(
      const ValueKey<String>('todo-recycle-confirm-button'),
    );
    expect(find.text('移入回收站？'), findsOneWidget);
    expect(cancelButton, findsOneWidget);
    expect(confirmButton, findsOneWidget);
    // 弹窗应保留在主窗口中央，不能退化为铺满桌面的原生 Dialog 窗口。
    final Finder recycleDialog = find
        .descendant(of: find.byType(Dialog), matching: find.byType(Material))
        .first;
    // 当前应用内弹窗的实际尺寸。
    final Size recycleDialogSize = tester.getSize(recycleDialog);
    // 当前应用内弹窗的中心位置。
    final Offset recycleDialogCenter = tester.getCenter(recycleDialog);
    expect(recycleDialogSize.width, lessThan(600));
    expect(recycleDialogSize.height, lessThan(300));
    expect(recycleDialogCenter.dx, closeTo(viewport.width / 2, 1));
    expect(recycleDialogCenter.dy, closeTo(viewport.height / 2, 1));
    expect(find.byType(ModalBarrier), findsWidgets);
    expect(
      tester.widget<OmniButton>(cancelButton).variant,
      OmniButtonVariant.secondary,
    );
    expect(
      tester.widget<OmniButton>(confirmButton).variant,
      OmniButtonVariant.danger,
    );
    await tester.tap(cancelButton);
    await tester.pumpAndSettle();
    expect(find.text('移入回收站？'), findsNothing);
    expect(find.text('待回收任务'), findsOneWidget);
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移入回收站'));
    await tester.pumpAndSettle();
    await tester.tap(confirmButton);
    await tester.pumpAndSettle();
    expect(find.text('移入回收站？'), findsNothing);
    expect(find.text('待回收任务'), findsNothing);
    // 确认操作仍按原业务规则软删除，避免视觉迁移改变数据语义。
    final TodoRecord recycled = await database
        .select(database.todoItems)
        .getSingle();
    expect(recycled.deletedAt, isNotNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });
}
