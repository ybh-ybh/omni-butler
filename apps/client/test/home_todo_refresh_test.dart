import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/home/presentation/home_page.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:omni_butler/features/todos/presentation/todo_progress_widgets.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证删除后的后台重读不会卸载首页已有任务和进度订阅。
void main() {
  testWidgets('连续删除并刷新时保留其他任务行、进度条与子任务展开状态', (WidgetTester tester) async {
    // 仅使用隔离数据库，避免改变用户真实待办。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 使用生产仓储验证删除与最终列表内容。
    final TodoRepository repository = TodoRepository(database);
    // 固定任务日期，排除分钟变化带来的额外刷新。
    final DateTime now = DateTime(2026, 10, 25, 20);
    // 可控的重读响应，让测试确实覆盖加载中的中间帧。
    final StreamController<List<TodoTreeNode>> updates =
        StreamController<List<TodoTreeNode>>.broadcast();
    // 独立依赖用于覆盖刷新和依赖重载两种保留旧数据的状态。
    final Provider<Object> refreshDependency = Provider<Object>(
      (Ref ref) => Object(),
    );
    // 稍后挂载的依赖容器。
    ProviderContainer? container;
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await repository.save(TodoDraft(title: '保留的父任务', scheduledDate: now));
      // 需要在整个删除过程中保持展开的父任务。
      final TodoRecord parent =
          (await database.select(database.todoItems).get()).single;
      await repository.save(
        TodoDraft(title: '保持展开的子任务', scheduledDate: now, parentId: parent.id),
      );
      await repository.save(
        TodoDraft(
          title: '保留的进度任务',
          scheduledDate: now,
          taskType: TodoTaskType.progress,
          progressSteps: const <TodoProgressStepDraft>[
            TodoProgressStepDraft(name: '第一步'),
            TodoProgressStepDraft(name: '第二步'),
          ],
        ),
      );
      // 两个独立任务用于连续触发真实删除。
      for (final String title in <String>['第一次删除', '第二次删除']) {
        await repository.save(TodoDraft(title: title, scheduledDate: now));
      }
      // 通过真实记录身份执行连续删除。
      final List<TodoRecord> targets =
          (await database.select(database.todoItems).get())
              .where((TodoRecord row) => row.title.endsWith('次删除'))
              .toList();
      SharedPreferences.setMockInitialValues(<String, Object>{
        'home.cards.order': <String>['todos'],
      });
      // 首页生产组件所需的本机偏好。
      final SharedPreferences preferences =
          await SharedPreferences.getInstance();
      container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          appDatabaseProvider.overrideWithValue(database),
          nowProvider.overrideWithValue(now),
          activeTodoTreesProvider(DateUtils.dateOnly(now))
              .overrideWith((Ref ref) {
                ref.watch(refreshDependency);
                return updates.stream;
              }),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.build(brightness: Brightness.light),
            home: const Scaffold(body: HomePage()),
          ),
        ),
      );
      await tester.pump();
      // 首次尚无数据时仍然展示正常的加载指示。
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      updates.add(
        (await tester.runAsync(() => repository.watchActiveTrees(now).first))!,
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey<String>('home-todo-title-action-${parent.id}')),
      );
      await tester.pumpAndSettle();
      // 保留任务行与进度组件的元素身份，可检测卸载后重新创建。
      final Element parentElement = tester.element(
        find.byKey(ValueKey<String>('home-todo-row-${parent.id}')),
      );
      // 进度条被卸载会重新订阅步骤并短暂显示“正在读取进度”。
      final Element progressElement = tester.element(
        find.byType(TodoProgressBar),
      );
      // 行内提交状态同样需要跨刷新保留。
      final State progressState = tester.state(
        find.byType(TodoProgressTaskTile),
      );

      // 逐次删除并检查后台刷新各帧的组件身份。
      for (final TodoRecord target in targets) {
        await tester.tap(
          find.byKey(ValueKey<String>('home-todo-hover-${target.id}')),
          buttons: kSecondaryMouseButton,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('删除任务'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(OmniButton, '删除任务'));
        await tester.pumpAndSettle();
        // 等待真实删除事务结束，再模拟共享订阅的同步重读。
        expect(
          (await database.select(database.todoItems).get())
              .singleWhere((TodoRecord row) => row.id == target.id)
              .deletedAt,
          isNotNull,
        );
        if (target.id == targets.first.id) {
          container.invalidate(
            activeTodoTreesProvider(DateUtils.dateOnly(now)),
          );
        } else {
          container.invalidate(refreshDependency);
        }
        await tester.pump();
        expect(
          container
              .read(activeTodoTreesProvider(DateUtils.dateOnly(now)))
              .isLoading,
          isTrue,
        );
        // 重读尚未返回时逐帧检查，避免只验证刷新结束后的内容。
        for (int frame = 0; frame < 3; frame += 1) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(find.byType(CircularProgressIndicator), findsNothing);
          expect(find.text('正在读取进度…'), findsNothing);
          expect(find.text('保持展开的子任务'), findsOneWidget);
          expect(
            tester.element(
              find.byKey(ValueKey<String>('home-todo-row-${parent.id}')),
            ),
            same(parentElement),
          );
          expect(
            tester.element(find.byType(TodoProgressBar)),
            same(progressElement),
          );
          expect(
            tester.state(find.byType(TodoProgressTaskTile)),
            same(progressState),
          );
        }
        updates.add(
          (await tester.runAsync(
            () => repository.watchActiveTrees(now).first,
          ))!,
        );
        await tester.pumpAndSettle();
        expect(find.text(target.title), findsNothing);
        expect(find.text('保持展开的子任务'), findsOneWidget);
        expect(
          tester.element(find.byType(TodoProgressBar)),
          same(progressElement),
        );
        expect(tester.takeException(), isNull);
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      container?.dispose();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(updates.close);
      await tester.runAsync(database.close);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
