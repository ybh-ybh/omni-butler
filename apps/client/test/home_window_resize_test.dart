import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/omni_butler_app.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/events/data/event_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证 Windows 窗口实时缩放时的卡片重排与完整保留规则。
void main() {
  testWidgets('Windows 首页缩放时从三列重排为两列且卡片不消失', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
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
    // 用足量临近事件制造超过单页高度的最下方卡片内容。
    final EventRepository eventRepository = EventRepository(database);
    for (int index = 0; index < 16; index += 1) {
      await eventRepository.save(
        EventDraft(
          name: '窗口高度回归事件 $index',
          intervalValue: 1,
          intervalUnit: EventIntervalUnit.day,
          lastCompletedAt: DateTime(2026, 9, 1),
          reminderEnabled: true,
          reminderDaysBefore: 1,
        ),
      );
    }
    // 显式管理的测试依赖容器。
    final ProviderContainer container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        appDatabaseProvider.overrideWithValue(database),
        nowProvider.overrideWithValue(DateTime(2026, 9, 5, 10, 30)),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const OmniButlerApp(),
      ),
    );
    await tester.pumpAndSettle();

    // 宽窗口下待办主区域宽度。
    final double wideTodoWidth = tester
        .getSize(find.byKey(const ValueKey<String>('home-todo-card')))
        .width;
    // 宽窗口下最后一排卡片的底部位置。
    final double wideContextCardBottom = tester
        .getBottomRight(
          find.byKey(
            const ValueKey<String>('home-dashboard-card-todayContext'),
          ),
        )
        .dy;
    expect(wideContextCardBottom, lessThanOrEqualTo(900));
    expect(
      find.byKey(const ValueKey<String>('home-context-card')),
      findsOneWidget,
    );

    tester.view.physicalSize = const Size(1728, 969);
    await tester.pumpAndSettle();

    // 用户截图尺寸下最后一排卡片的底部位置。
    final double screenshotContextCardBottom = tester
        .getBottomRight(
          find.byKey(
            const ValueKey<String>('home-dashboard-card-todayContext'),
          ),
        )
        .dy;
    // 用户截图尺寸下今日脉络卡片专属滚动视口。
    final Finder screenshotContextCardScroll = find.byKey(
      const ValueKey<String>('home-card-scroll-todayContext'),
    );
    // 用户截图尺寸下卡片内实际可滚动组件。
    final Finder screenshotContextScrollable = find.descendant(
      of: screenshotContextCardScroll,
      matching: find.byType(Scrollable),
    );
    // 用户截图尺寸下卡片内滚动位置。
    final ScrollPosition screenshotContextScrollPosition = tester
        .state<ScrollableState>(screenshotContextScrollable)
        .position;
    expect(screenshotContextCardBottom, lessThanOrEqualTo(969));
    expect(screenshotContextScrollPosition.maxScrollExtent, greaterThan(0));

    tester.view.physicalSize = const Size(1024, 768);
    await tester.pumpAndSettle();

    // 窄窗口下待办主区域宽度。
    final double narrowTodoWidth = tester
        .getSize(find.byKey(const ValueKey<String>('home-todo-card')))
        .width;
    expect(narrowTodoWidth, greaterThan(wideTodoWidth));
    expect(
      find.byKey(const ValueKey<String>('home-context-card')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('home-time-status-card')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('compact-navigation')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('medium-navigation')),
      findsOneWidget,
    );

    tester.view.physicalSize = const Size(1024, 500);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('home-quote-card')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('home-day-ruler')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('home-todo-card')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('home-context-card')),
      findsOneWidget,
    );
    // 今日脉络卡片专属滚动视口。
    final Finder contextCardScroll = find.byKey(
      const ValueKey<String>('home-card-scroll-todayContext'),
    );
    // 卡片内实际可滚动组件。
    final Finder contextScrollable = find.descendant(
      of: contextCardScroll,
      matching: find.byType(Scrollable),
    );
    // 卡片内滚动位置。
    final ScrollPosition contextScrollPosition = tester
        .state<ScrollableState>(contextScrollable)
        .position;
    expect(tester.getSize(contextCardScroll).height, lessThan(500));
    expect(contextScrollPosition.maxScrollExtent, greaterThan(0));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });
}
