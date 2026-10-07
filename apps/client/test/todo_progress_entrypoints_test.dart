import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
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
import 'package:omni_butler/features/todos/presentation/todo_editor_dialog.dart';
import 'package:omni_butler/shared/ui/omni_icon_button.dart';
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
        find.byKey(ValueKey<String>('progress-title-${fixture.todo.id}')),
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

  testWidgets('首页和每日待办的加一直接推进未完成步骤且最后一步仍需确认', (WidgetTester tester) async {
    await _withProgress(tester, (fixture) async {
      // 首页和每日待办沿用同一个公开操作键。
      final Finder advance = find.byKey(
        ValueKey<String>('progress-update-${fixture.todo.id}'),
      );
      // 首页明确使用加一图标和操作提示，避免被理解为打开编辑器。
      final OmniIconButton homeAction = tester.widget<OmniIconButton>(advance);
      expect(homeAction.tooltip, '完成下一个');
      expect((homeAction.icon as Icon).icon, Icons.plus_one_rounded);
      expect(find.textContaining('已完成 3/12'), findsOneWidget);
      await _capture(tester, fixture, 'home-complete-next');
      // 首次提交尚未重绘时重复点击也只能推进同一个未完成目标。
      await tester.tap(advance);
      await tester.tap(advance);
      await _settleProgressWrite(tester);
      expect(find.byType(TodoProgressPanel), findsNothing);
      expect(find.textContaining('已完成 4/12'), findsOneWidget);
      expect(
        (await fixture.readSteps())
            .where((TodoProgressStepRecord step) => step.isCompleted)
            .map((TodoProgressStepRecord step) => step.id),
        <String>[
          fixture.steps[0].id,
          fixture.steps[1].id,
          fixture.steps[2].id,
          fixture.steps[7].id,
        ],
      );
      fixture.container.read(appRouterProvider).go('/todos');
      await tester.pumpAndSettle();
      // 每日待办使用相同操作语义并读取首页刚保存的状态。
      final OmniIconButton todoAction = tester.widget<OmniIconButton>(advance);
      expect(todoAction.tooltip, '完成下一个');
      expect((todoAction.icon as Icon).icon, Icons.plus_one_rounded);
      await _capture(tester, fixture, 'todos-complete-next');
      await tester.tap(advance);
      await _settleProgressWrite(tester);
      expect(find.byType(TodoProgressPanel), findsNothing);
      expect(find.textContaining('已完成 5/12'), findsOneWidget);
      expect(
        (await fixture.readSteps())
            .where((TodoProgressStepRecord step) => step.isCompleted)
            .map((TodoProgressStepRecord step) => step.id),
        <String>[
          fixture.steps[0].id,
          fixture.steps[1].id,
          fixture.steps[2].id,
          fixture.steps[3].id,
          fixture.steps[7].id,
        ],
      );
      // 准备唯一剩余步骤，验证加一到满进度不会越过任务确认边界。
      await fixture.repository.setProgressStepsCompleted(
        fixture.todo.id,
        fixture.steps
            .take(11)
            .map((TodoProgressStepRecord step) => step.id)
            .toList(),
        true,
      );
      await _settleProgressWrite(tester);
      expect(find.textContaining('已完成 11/12'), findsOneWidget);
      await tester.tap(advance);
      await _settleProgressWrite(tester);
      expect(find.textContaining('已完成 12/12'), findsOneWidget);
      expect(find.textContaining('待确认完成'), findsOneWidget);
      expect(advance, findsNothing);
      expect(
        find.byKey(ValueKey<String>('progress-confirm-${fixture.todo.id}')),
        findsOneWidget,
      );
      expect((await fixture.readTodo())!.isCompleted, isFalse);
      expect(find.byType(TodoProgressPanel), findsNothing);
    });
  });

  testWidgets('每日待办图标对齐、行内进度与整行悬停保持紧凑', (WidgetTester tester) async {
    await _withProgress(tester, (fixture) async {
      await fixture.repository.save(
        TodoDraft(title: '普通任务对齐参照', scheduledDate: DateTime.now()),
      );
      // 与进度任务处于同一象限的普通任务。
      final AppDatabase database = fixture.container.read(appDatabaseProvider);
      // 新创建的普通任务身份。
      final TodoRecord normal =
          (await database.select(database.todoItems).get()).firstWhere(
            (todo) => todo.taskType == 'normal',
          );
      fixture.container.read(appRouterProvider).go('/todos');
      await tester.pumpAndSettle();
      // 两种任务的实际拖动图标位置。
      final Finder normalHandle = find.byKey(
        ValueKey<String>('todo-drag-handle-${normal.id}'),
      );
      // 进度任务拖动图标应在标题行，而非整块进度内容的中央。
      final Finder progressHandle = find.byKey(
        ValueKey<String>('todo-drag-handle-${fixture.todo.id}'),
      );
      // 替代文字操作的图标按钮。
      final Finder update = find.byKey(
        ValueKey<String>('progress-update-${fixture.todo.id}'),
      );
      // 进度图标与普通勾选框使用完全相同的中心列。
      final Finder status = find.byKey(
        ValueKey<String>('progress-status-${fixture.todo.id}'),
      );
      // 普通任务的完整复选框区域。
      final Finder checkbox = find.byKey(
        ValueKey<String>('todo-completion-checkbox-${normal.id}'),
      );
      // 任务名称与右侧摘要的实际布局。
      final Finder title = find.byKey(
        ValueKey<String>('progress-title-${fixture.todo.id}'),
      );
      // 摘要不能再独占第二行。
      final Finder label = find.byKey(
        ValueKey<String>('progress-label-${fixture.todo.id}'),
      );
      // 包含标题、进度条和内边距的完整任务。
      final Finder task = find.byKey(
        ValueKey<String>('progress-task-${fixture.todo.id}'),
      );
      expect(
        tester.getCenter(status).dx,
        closeTo(tester.getCenter(checkbox).dx, 0.1),
      );
      expect(
        tester.getCenter(label).dy,
        closeTo(tester.getCenter(title).dy, 0.1),
      );
      expect(
        tester.getTopLeft(label).dx,
        greaterThan(tester.getBottomRight(title).dx),
      );
      expect(
        tester.getSize(task).height,
        lessThanOrEqualTo(
          tester
                  .getSize(
                    find.byKey(ValueKey<String>('todo-row-${normal.id}')),
                  )
                  .height +
              8,
        ),
      );
      expect(
        tester.getCenter(progressHandle).dx,
        closeTo(tester.getCenter(normalHandle).dx, 0.1),
      );
      expect(
        tester.getCenter(progressHandle).dy,
        closeTo(tester.getCenter(update).dy, 0.1),
      );
      expect(find.text('更新进度'), findsNothing);
      // 图标按钮沿用统一热区、提示与无障碍说明。
      final OmniIconButton button = tester.widget<OmniIconButton>(update);
      expect(button.tooltip, '完成下一个');
      expect((button.icon as Icon).icon, Icons.plus_one_rounded);
      expect(button.onPressed, isNotNull);
      await _capture(tester, fixture, 'todos-aligned');
      await fixture.container
          .read(themeControllerProvider.notifier)
          .setThemeMode(ThemeMode.dark);
      await tester.pumpAndSettle();
      expect(
        tester.getCenter(progressHandle).dx,
        closeTo(tester.getCenter(normalHandle).dx, 0.1),
      );
      expect(
        tester.getCenter(progressHandle).dy,
        closeTo(tester.getCenter(update).dy, 0.1),
      );
      await _capture(tester, fixture, 'todos-aligned-dark');
      // 在上下留白取样，验证底色覆盖标题和进度条之外的整个任务。
      final Rect bounds = tester.getRect(task);
      // 标题上方的无文字像素。
      final Offset topSample = Offset(bounds.center.dx, bounds.top + 2);
      // 进度条下方的无文字像素。
      final Offset bottomSample = Offset(bounds.center.dx, bounds.bottom - 2);
      // 悬停前两处像素用于比较真实绘制结果。
      final List<int> idlePixels = await _samplePixels(
        tester,
        fixture,
        <Offset>[topSample, bottomSample],
      );
      // 使用真实鼠标事件触发整行悬停。
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(title));
      await tester.pumpAndSettle();
      // 悬停后上下两处都必须变化，避免只给标题局部上色。
      final List<int> hoveredPixels = await _samplePixels(
        tester,
        fixture,
        <Offset>[topSample, bottomSample],
      );
      expect(hoveredPixels[0], isNot(idlePixels[0]));
      expect(hoveredPixels[1], isNot(idlePixels[1]));
      expect(hoveredPixels[0], hoveredPixels[1]);
      await _capture(tester, fixture, 'todos-aligned-dark-hover');
      await mouse.moveTo(
        tester.getCenter(
          find.descendant(of: task, matching: find.byType(TodoProgressBar)),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        await _samplePixels(tester, fixture, <Offset>[topSample, bottomSample]),
        hoveredPixels,
      );
      // 在第一个已命名节点停留超过提示延时，也不应弹出步骤名称或状态。
      final Rect barBounds = tester.getRect(
        find.descendant(of: task, matching: find.byType(TodoProgressBar)),
      );
      await mouse.moveTo(
        Offset(barBounds.left + barBounds.width / 24, barBounds.center.dy),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.textContaining('日常设计的心理学'), findsNothing);
      expect(find.textContaining('· 已完成'), findsNothing);
      expect(find.textContaining('进度总览：'), findsNothing);
      await mouse.moveTo(tester.getCenter(update));
      await tester.pumpAndSettle();
      expect(
        await _samplePixels(tester, fixture, <Offset>[topSample, bottomSample]),
        hoveredPixels,
      );
      await mouse.moveTo(Offset.zero);
      await tester.pumpAndSettle();
      expect(
        await _samplePixels(tester, fixture, <Offset>[topSample, bottomSample]),
        idlePixels,
      );
      await mouse.removePointer();
      await tester.tap(title);
      await tester.pumpAndSettle();
      expect(find.byType(TodoProgressPanel), findsOneWidget);
      expect(find.textContaining('已完成 3/12'), findsWidgets);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    });
  });

  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.windows,
    TargetPlatform.android,
  ]) {
    testWidgets('${platform.name}普通任务单击只切换子项，任务菜单与操作尺寸一致', (
      WidgetTester tester,
    ) async {
      await _withProgress(
        tester,
        (fixture) async {
          await fixture.repository.save(
            TodoDraft(title: '菜单父任务', scheduledDate: DateTime.now()),
          );
          // 与进度任务共用象限的普通父任务。
          final AppDatabase database = fixture.container.read(
            appDatabaseProvider,
          );
          // 保存后的稳定父任务身份。
          final TodoRecord parent =
              (await database.select(database.todoItems).get()).singleWhere(
                (todo) => todo.title == '菜单父任务',
              );
          await fixture.repository.save(
            TodoDraft(
              title: '菜单子任务',
              parentId: parent.id,
              scheduledDate: DateTime.now(),
            ),
          );
          await fixture.repository.save(
            TodoDraft(title: '无子项任务', scheduledDate: DateTime.now()),
          );
          await tester.pumpAndSettle();
          expect(
            tester
                .getCenter(
                  find.byKey(
                    ValueKey<String>('progress-status-${fixture.todo.id}'),
                  ),
                )
                .dx,
            closeTo(
              tester
                  .getCenter(
                    find.byKey(
                      ValueKey<String>('home-todo-checkbox-${parent.id}'),
                    ),
                  )
                  .dx,
              0.1,
            ),
          );
          // 首页进度条的左边缘与实际蓝色图标对齐。
          final Finder homeProgressIcon = find.byKey(
            ValueKey<String>('progress-status-${fixture.todo.id}'),
          );
          // Icon本身占满三十二像素槽位，字形才是实际可见的蓝色图标。
          final Finder homeIconGlyph = find.descendant(
            of: homeProgressIcon,
            matching: find.byType(RichText),
          );
          // 只定位当前进度任务，避免首页其他卡片的图形干扰。
          final Finder homeProgressBar = find.descendant(
            of: find.byKey(
              ValueKey<String>('progress-task-${fixture.todo.id}'),
            ),
            matching: find.byType(TodoProgressBar),
          );
          expect(
            tester.getTopLeft(homeProgressBar).dx,
            closeTo(tester.getTopLeft(homeIconGlyph).dx, 0.1),
          );
          await _capture(tester, fixture, '${platform.name}-home-aligned');
          fixture.container.read(appRouterProvider).go('/todos');
          await tester.pumpAndSettle();
          // 普通父任务的文字及完整行。
          final Finder parentTitle = find.text('菜单父任务');
          // 普通子任务不承担父项展开动作。
          final Finder childTitle = find.text('菜单子任务');
          // 无子项的普通任务保持单击无操作。
          final Finder leafTitle = find.text('无子项任务');
          // 父任务快捷添加按钮。
          final Finder add = find.byKey(
            ValueKey<String>('todo-add-child-${parent.id}'),
          );
          // 进度任务快捷更新按钮。
          final Finder update = find.byKey(
            ValueKey<String>('progress-update-${fixture.todo.id}'),
          );
          expect(find.byTooltip('更多操作'), findsNothing);
          expect(tester.getSize(update), tester.getSize(add));
          expect(
            tester.getCenter(update).dx,
            closeTo(tester.getCenter(add).dx, 0.1),
          );
          if (platform == TargetPlatform.android) {
            expect(tester.getSize(update), const Size.square(48));
          }
          expect(childTitle, findsOneWidget);
          await tester.tap(parentTitle);
          await tester.pumpAndSettle();
          expect(childTitle, findsNothing);
          expect(find.byType(TodoEditorDialog), findsNothing);
          // 留白属于任务项，同样支持展开。
          final Rect parentBounds = tester.getRect(
            find.byKey(ValueKey<String>('todo-tree-root-${parent.id}')),
          );
          await tester.tapAt(
            Offset(parentBounds.right - 3, parentBounds.center.dy),
          );
          await tester.pumpAndSettle();
          expect(childTitle, findsOneWidget);
          await tester.tap(leafTitle);
          await tester.tap(childTitle);
          await tester.pumpAndSettle();
          expect(find.byType(TodoEditorDialog), findsNothing);
          expect(childTitle, findsOneWidget);
          await _openTaskMenu(tester, parentTitle, platform);
          expect(childTitle, findsOneWidget);
          expect(find.text('编辑'), findsOneWidget);
          expect(find.text('移动象限'), findsOneWidget);
          expect(find.text('移入回收站'), findsOneWidget);
          await tester.tap(find.text('编辑'));
          await tester.pumpAndSettle();
          expect(find.byType(TodoEditorDialog), findsOneWidget);
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          await _openTaskMenu(tester, childTitle, platform);
          expect(find.text('编辑'), findsOneWidget);
          expect(find.text('移动象限'), findsNothing);
          expect(find.text('移入回收站'), findsOneWidget);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          await _openTaskMenu(tester, find.text(fixture.todo.title), platform);
          expect(find.byType(TodoProgressPanel), findsNothing);
          expect(find.text('编辑'), findsOneWidget);
          expect(find.text('移动象限'), findsOneWidget);
          expect(find.text('移入回收站'), findsOneWidget);
          await _capture(tester, fixture, '${platform.name}-task-context-menu');
          await tester.tap(find.text('编辑'));
          await tester.pumpAndSettle();
          expect(find.byType(TodoEditorDialog), findsOneWidget);
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(ValueKey<String>('progress-title-${fixture.todo.id}')),
          );
          await tester.pumpAndSettle();
          expect(find.byType(TodoProgressPanel), findsOneWidget);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          if (platform == TargetPlatform.windows) {
            // 移除更多按钮后，聚焦任务操作仍可通过键盘打开菜单。
            final Finder focusChild = find
                .descendant(of: update, matching: find.byType(MouseRegion))
                .first;
            Focus.of(tester.element(focusChild)).requestFocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
            await tester.pumpAndSettle();
            expect(find.text('编辑'), findsOneWidget);
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await tester.pumpAndSettle();
            await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
            await tester.sendKeyEvent(LogicalKeyboardKey.f10);
            await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
            await tester.pumpAndSettle();
            expect(find.text('编辑'), findsOneWidget);
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await tester.pumpAndSettle();
          }
          await tester.tap(add);
          await tester.pumpAndSettle();
          expect(find.text('新增子任务'), findsOneWidget);
          expect(childTitle, findsOneWidget);
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          expect(
            (await fixture.readSteps())
                .where((step) => step.isCompleted)
                .length,
            3,
          );
          expect(
            (await database.select(database.todoItems).get()).every(
              (todo) => !todo.isCompleted,
            ),
            isTrue,
          );
        },
        platform: platform,
        size: platform == TargetPlatform.android
            ? const Size(390, 844)
            : const Size(1440, 900),
      );
    });
  }

  testWidgets('Android窄屏进度可打开且不抢占横滑切页', (WidgetTester tester) async {
    await _withProgress(
      tester,
      (fixture) async {
        fixture.container.read(appRouterProvider).go('/todos');
        await tester.pumpAndSettle();
        expect(find.textContaining('已完成 3/12'), findsOneWidget);
        await _capture(tester, fixture, 'android-todos');
        await tester.tap(
          find.byKey(ValueKey<String>('progress-title-${fixture.todo.id}')),
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

/// 等待即时写库和数据流刷新，保留当前消息窗口而不等其完整倒计时。
Future<void> _settleProgressWrite(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 40)),
  );
  await tester.pump(const Duration(milliseconds: 300));
}

/// 使用平台实际的菜单触发方式，验证手势不触发任务点击。
Future<void> _openTaskMenu(
  WidgetTester tester,
  Finder task,
  TargetPlatform platform,
) async {
  if (platform == TargetPlatform.android) {
    await tester.longPress(task);
  } else {
    await tester.tap(
      task,
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
  }
  await tester.pumpAndSettle();
}

/// 从完整页面的渲染结果取样，验证悬停背景实际覆盖范围。
Future<List<int>> _samplePixels(
  WidgetTester tester,
  _ProgressFixture fixture,
  List<Offset> positions,
) async {
  // 完整应用的隔离渲染边界。
  final RenderRepaintBoundary boundary =
      fixture.previewKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
  return (await tester.runAsync(() async {
    // 使用真实像素检测，避免只断言布局或颜色属性。
    final ui.Image image = await boundary.toImage();
    try {
      // 按RGBA排列的完整画面。
      final ByteData pixels = (await image.toByteData())!;
      return positions.map((position) {
        // 取样坐标相对页面原点，测试视口比例固定为一。
        final Offset local = boundary.globalToLocal(position);
        return pixels.getUint32(
          (local.dy.floor() * image.width + local.dx.floor()) * 4,
        );
      }).toList();
    } finally {
      image.dispose();
    }
  }))!;
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
