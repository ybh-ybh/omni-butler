import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/omni_butler_app.dart';
import 'package:omni_butler/app/router/app_router.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证 Windows 端主要新增弹窗可通过 Enter 保存。
void main() {
  testWidgets('待办、会员、物品、补录和开始记录均支持 Enter 保存', (WidgetTester tester) async {
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
    // 稳定的业务当前时间。
    final DateTime now = DateTime(2026, 9, 10, 10, 20);
    // 显式管理的测试依赖容器。
    final ProviderContainer container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        appDatabaseProvider.overrideWithValue(database),
        nowProvider.overrideWithValue(now),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const OmniButlerApp(),
      ),
    );
    await tester.pumpAndSettle();

    container.read(appRouterProvider).go('/todos');
    await tester.pumpAndSettle();
    await tester.tap(find.text('新增待办').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, '例如：整理本周发票'),
      'Enter 新增待办',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      (await database.select(database.todoItems).getSingle()).title,
      'Enter 新增待办',
    );

    container.read(appRouterProvider).go('/memberships');
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('新增会员'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, '会员名称 *'),
      'Enter 新增会员',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '本次价格（元）*'),
      '12.00',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      (await database.select(database.memberships).getSingle()).name,
      'Enter 新增会员',
    );

    container.read(appRouterProvider).go('/inventory');
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('新增物品'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, '物品名称 *'),
      'Enter 新增物品',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      (await database.select(database.inventoryItems).getSingle()).name,
      'Enter 新增物品',
    );

    container.read(appRouterProvider).go('/timeline');
    await tester.pumpAndSettle();
    await tester.tap(find.text('补记时间'));
    await tester.pumpAndSettle();
    // 先移动再触及左边缘以扩展窗口，并将补录区间调整到当前时间之前。
    RangeSlider rangeSlider = tester.widget<RangeSlider>(
      find.byKey(const ValueKey<String>('time-range-slider')),
    );
    rangeSlider.onChanged!(const RangeValues(565, 680));
    await tester.pumpAndSettle();
    rangeSlider = tester.widget<RangeSlider>(
      find.byKey(const ValueKey<String>('time-range-slider')),
    );
    rangeSlider.onChanged!(const RangeValues(560, 680));
    await tester.pumpAndSettle();
    rangeSlider = tester.widget<RangeSlider>(
      find.byKey(const ValueKey<String>('time-range-slider')),
    );
    rangeSlider.onChanged!(const RangeValues(480, 540));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, '例如：睡眠、学习 Text2SQL'),
      'Enter 补录',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    await tester.tap(find.text('开始记录').last);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('time-entry-editor')),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    // Enter 保存后的两条时间记录。
    final List<TimeEntryRecord> timeEntries = await database
        .select(database.timeEntries)
        .get();
    expect(timeEntries, hasLength(2));
    expect(
      timeEntries.any(
        (TimeEntryRecord record) => record.activity == 'Enter 补录',
      ),
      isTrue,
    );
    expect(
      timeEntries.any((TimeEntryRecord record) => record.endedAt == null),
      isTrue,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });
}
