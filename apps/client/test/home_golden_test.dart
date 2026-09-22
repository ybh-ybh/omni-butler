import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/omni_butler_app.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/events/data/event_repository.dart';
import 'package:omni_butler/features/memberships/data/membership_repository.dart';
import 'package:omni_butler/features/todos/data/todo_priority_quadrant.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 生成并校验首页关键视口的视觉基线。
void main() {
  testWidgets('统一品牌浅色桌面首页视觉基线', (WidgetTester tester) async {
    // 桌面视觉基线尺寸。
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
    // 桌面基线使用的当前时间。
    final DateTime now = DateTime(2026, 9, 4, 14, 20);
    // 用于展示今日脉络子项的临近周期事件。
    await EventRepository(database).save(
      EventDraft(
        name: '更换空气滤芯',
        intervalValue: 10,
        intervalUnit: EventIntervalUnit.day,
        lastCompletedAt: DateTime(2026, 8, 30, 9),
        reminderEnabled: true,
        reminderDaysBefore: 7,
      ),
    );
    // 用于展示今日脉络子项的到期会员。
    await MembershipRepository(database).save(
      MembershipDraft(
        name: '设计工具会员',
        priceCents: 9600,
        purchaseDate: DateTime(2026, 8, 4),
        expirationDate: DateTime(2026, 9, 8),
        isPermanent: false,
        autoRenew: false,
      ),
    );
    // 用于展示首页父子任务树的待办仓储。
    final TodoRepository todoRepository = TodoRepository(database);
    await todoRepository.save(
      TodoDraft(
        title: '完成首页改版',
        scheduledDate: DateUtils.dateOnly(now),
        priorityQuadrant: TodoPriorityQuadrant.urgentImportant,
        dueAt: DateTime(2026, 9, 4, 16),
      ),
    );
    // 用于承载首页子任务的父任务。
    final TodoRecord todoParent =
        (await database.select(database.todoItems).get()).single;
    await todoRepository.save(
      TodoDraft(
        title: '核对父子任务层级',
        parentId: todoParent.id,
        scheduledDate: DateUtils.dateOnly(now),
        dueAt: DateTime(2026, 9, 4, 17, 30),
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          appDatabaseProvider.overrideWithValue(database),
          nowProvider.overrideWithValue(now),
        ],
        child: const OmniButlerApp(),
      ),
    );
    await tester.pumpAndSettle();

    // 桌面名言卡尺寸。
    final Size quoteSize = tester.getSize(
      find.byKey(const ValueKey<String>('home-quote-card')),
    );
    // 桌面时间刻度卡尺寸。
    final Size rulerSize = tester.getSize(
      find.byKey(const ValueKey<String>('home-day-ruler')),
    );
    // 桌面待办卡尺寸。
    final Size todoSize = tester.getSize(
      find.byKey(const ValueKey<String>('home-todo-card')),
    );
    // 桌面今日脉络卡尺寸。
    final Size contextSize = tester.getSize(
      find.byKey(const ValueKey<String>('home-context-card')),
    );
    // 桌面时间状态卡尺寸。
    final Size timeStatusSize = tester.getSize(
      find.byKey(const ValueKey<String>('home-time-status-card')),
    );
    expect(contextSize.width, inInclusiveRange(380, 430));
    expect(quoteSize.width, closeTo(contextSize.width * 2 + 8, 0.1));
    expect(quoteSize.height, 156);
    expect(rulerSize.height, 156);
    expect(todoSize.width, closeTo(contextSize.width, 0.1));
    expect(timeStatusSize.width, closeTo(contextSize.width, 0.1));
    expect(todoSize.height, closeTo(contextSize.height, 0.1));
    expect(todoSize.height, closeTo(timeStatusSize.height, 0.1));
    // 最后一排卡片底边位置。
    final double lastRowBottom = tester
        .getBottomRight(
          find.byKey(const ValueKey<String>('home-time-status-card')),
        )
        .dy;
    expect(lastRowBottom, closeTo(viewport.height - OmniSpacing.xl, 0.1));

    await expectLater(
      find.byType(OmniButlerApp),
      matchesGoldenFile('goldens/home_feishu_light_1440x900.png'),
    );
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Windows 窄窗口首页两列重排视觉基线', (WidgetTester tester) async {
    // 桌面窄窗口视觉基线尺寸。
    const Size viewport = Size(1024, 768);
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
          nowProvider.overrideWithValue(DateTime(2026, 9, 4, 14, 20)),
        ],
        child: const OmniButlerApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('medium-navigation')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('compact-navigation')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('home-context-card')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('home-todo-card')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('home-time-status-card')),
      findsOneWidget,
    );

    await expectLater(
      find.byType(OmniButlerApp),
      matchesGoldenFile('goldens/home_feishu_windows_narrow_1024x768.png'),
    );
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('统一品牌深色紧凑首页视觉基线', (WidgetTester tester) async {
    // 紧凑视觉基线尺寸。
    const Size viewport = Size(390, 844);
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'appearance.theme_mode': 'dark',
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
          nowProvider.overrideWithValue(DateTime(2026, 9, 4, 14, 20)),
        ],
        child: const OmniButlerApp(),
      ),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(OmniButlerApp),
      matchesGoldenFile('goldens/home_feishu_dark_390x844.png'),
    );
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });
}
