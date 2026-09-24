import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/floating/presentation/floating_window_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证悬浮窗的核心待办和时间操作入口。
void main() {
  test('待办象限默认一行且最多展示五行', () {
    expect(calculateFloatingTodoViewportHeight(0), 32);
    expect(calculateFloatingTodoViewportHeight(1), 32);
    expect(calculateFloatingTodoViewportHeight(3), 96);
    expect(calculateFloatingTodoViewportHeight(8), 160);
  });

  testWidgets('悬浮窗可直接新增待办、补记和开始时间记录', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(294, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 测试用设备偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    addTearDown(database.close);
    // 测试用 Riverpod 容器。
    final ProviderContainer container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        appDatabaseProvider.overrideWithValue(database),
        nowProvider.overrideWithValue(DateTime(2026, 9, 24, 9, 30)),
      ],
    );
    addTearDown(container.dispose);
    // 用户请求跳转到主窗口的目标路由。
    String? openedRoute;
    // 悬浮窗内容上报的自然高度。
    double? preferredHeight;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.build(brightness: Brightness.light),
          home: FloatingWindowPage(
            onClose: () async {},
            onOpenRoute: (String location) async => openedRoute = location,
            onDragStart: () {},
            onDragUpdate: () {},
            onDragEnd: () async {},
            onPreferredHeightChanged: (double value) {
              preferredHeight = value;
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('今日待办'), findsOneWidget);
    expect(find.text('重要·紧急'), findsOneWidget);
    expect(find.text('重要·不紧急'), findsOneWidget);
    expect(find.text('紧急·不重要'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('floating-todo-create')),
      findsOneWidget,
    );
    expect(find.text('新增'), findsNothing);
    expect(find.byIcon(Icons.add_rounded), findsOneWidget);
    // 新增入口中的加号旋转动画。
    final Finder createIconRotation = find.descendant(
      of: find.byKey(const ValueKey<String>('floating-todo-create')),
      matching: find.byType(AnimatedRotation),
    );
    expect(tester.widget<AnimatedRotation>(createIconRotation).turns, 0);
    expect(
      tester.getSize(
        find.byKey(const ValueKey<String>('floating-todo-create')),
      ),
      const Size.square(32),
    );
    expect(
      tester
          .getSize(
            find.byKey(const ValueKey<String>('floating-todo-viewport-3')),
          )
          .height,
      floatingTodoRowHeight,
    );

    await tester.ensureVisible(find.text('时间状态'));
    await tester.pumpAndSettle();
    expect(find.text('开始'), findsOneWidget);
    expect(find.text('补记'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('floating-time-start')),
        matching: find.byType(OutlinedButton),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('floating-time-backfill')),
        matching: find.byType(OutlinedButton),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey<String>('floating-time-start')))
          .height,
      30,
    );
    expect(preferredHeight, isNotNull);
    expect(preferredHeight!, lessThan(760));

    await tester.tap(
      find.byKey(const ValueKey<String>('floating-todo-create')),
    );
    await tester.pump();
    expect(tester.widget<AnimatedRotation>(createIconRotation).turns, 0.125);
    expect(find.text('新增今日待办'), findsNothing);
    expect(find.byTooltip('取消'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('floating-todo-title-field')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('floating-todo-inline-cancel')),
        matching: find.byType(OutlinedButton),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('floating-todo-inline-save')),
        matching: find.byType(OutlinedButton),
      ),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('floating-todo-create')),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedRotation>(createIconRotation).turns, 0);
    expect(
      find.byKey(const ValueKey<String>('floating-todo-title-field')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('floating-todo-create')),
    );
    await tester.pumpAndSettle();
    // 使用悬浮窗专属的紧凑半透明输入样式。
    final InputDecorator titleDecorator = tester.widget<InputDecorator>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('floating-todo-title-field')),
        matching: find.byType(InputDecorator),
      ),
    );
    expect(titleDecorator.decoration.labelText, isNull);
    expect(titleDecorator.decoration.filled, isTrue);
    expect(
      tester
          .getSize(
            find.byKey(const ValueKey<String>('floating-todo-title-field')),
          )
          .height,
      lessThan(44),
    );
    expect(
      tester
          .getSize(
            find.byKey(const ValueKey<String>('floating-todo-priority-field')),
          )
          .height,
      lessThan(44),
    );
    expect(
      find.byKey(const ValueKey<String>('time-entry-editor')),
      findsNothing,
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('floating-todo-title-field')),
      '悬浮窗新增待办',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('floating-todo-inline-save')),
    );
    await tester.pump(const Duration(milliseconds: 200));
    // 内联保存后的待办记录。
    final List<TodoRecord> todos = await database
        .select(database.todoItems)
        .get();
    expect(todos.map((TodoRecord todo) => todo.title), contains('悬浮窗新增待办'));

    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('floating-time-backfill')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('floating-time-backfill')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('floating-backfill-composer')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('time-entry-editor')),
      findsNothing,
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('floating-time-activity-field')),
      '整理资料',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('floating-time-inline-save')),
    );
    await tester.pump(const Duration(milliseconds: 200));
    // 内联补记后的已完成记录。
    final List<TimeEntryRecord> backfilledRecords = await database
        .select(database.timeEntries)
        .get();
    expect(backfilledRecords, hasLength(1));
    expect(backfilledRecords.single.endedAt, isNotNull);

    await tester.tap(find.byKey(const ValueKey<String>('floating-time-start')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('floating-start-composer')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('floating-time-inline-save')),
    );
    await tester.pump(const Duration(milliseconds: 200));
    // 开始记录后新增的进行中记录。
    final List<TimeEntryRecord> allTimeRecords = await database
        .select(database.timeEntries)
        .get();
    expect(allTimeRecords, hasLength(2));
    expect(
      allTimeRecords.where((TimeEntryRecord record) => record.endedAt == null),
      hasLength(1),
    );

    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('floating-todo-view-all')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('floating-todo-view-all')),
    );
    await tester.pump();
    expect(openedRoute, '/todos');
  });
}
