import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/features/home/data/home_card_preferences.dart';
import 'package:omni_butler/features/home/presentation/home_card_manager.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证移动首页独立横幅开关、内容排序与桌面管理器兼容性。
void main() {
  testWidgets('安卓紧凑首页名言独立开关且不会恢复隐藏刻度', (WidgetTester tester) async {
    // 当前测试使用的本机偏好。
    final SharedPreferences preferences = await _pumpManager(tester);
    expect(find.text('首页设置'), findsOneWidget);
    expect(find.text('管理卡片'), findsNothing);
    expect(find.text('顶部横幅'), findsOneWidget);
    expect(find.text('已添加模块'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^\d+$')), findsNothing);
    expect(find.textContaining('修改会立即保存到当前设备'), findsNothing);
    expect(find.byType(ReorderableDragStartListener), findsNWidgets(3));
    expect(find.byTooltip('移除每日名言'), findsNothing);
    expect(find.byTooltip('添加每日名言'), findsNothing);

    // 名言开关与模块增删列表独立。
    final Finder quoteSwitch = find.byKey(
      const ValueKey<String>('home-settings-quote-switch'),
    );
    expect(tester.widget<OmniSwitch>(quoteSwitch).value, isTrue);
    await tester.tap(quoteSwitch);
    await tester.pumpAndSettle();
    expect(preferences.getStringList('home.cards.order'), <String>[
      'todos',
      'timeStatus',
      'todayContext',
    ]);
    expect(tester.widget<OmniSwitch>(quoteSwitch).value, isFalse);
    await tester.tap(quoteSwitch);
    await tester.pumpAndSettle();
    expect(preferences.getStringList('home.cards.order'), <String>[
      'todos',
      'timeStatus',
      'todayContext',
      'quote',
    ]);
    expect(find.byTooltip('添加今日刻度'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('内容排序跨过中间名言仍保留原始名言槽位并持久化增删', (WidgetTester tester) async {
    // 当前测试使用的本机偏好。
    final SharedPreferences preferences = await _pumpManager(tester);
    // 拖拽列表把已过滤名言后的最终索引交给排序入口。
    final SliverReorderableList reorderable = tester
        .widget<SliverReorderableList>(find.byType(SliverReorderableList));
    reorderable.onReorderItem!(0, 2);
    await tester.pumpAndSettle();
    expect(preferences.getStringList('home.cards.order'), <String>[
      'timeStatus',
      'quote',
      'todayContext',
      'todos',
    ]);

    await tester.tap(find.byTooltip('移除时间状态'));
    await tester.pumpAndSettle();
    expect(preferences.getStringList('home.cards.order'), <String>[
      'quote',
      'todayContext',
      'todos',
    ]);
    await tester.tap(find.byTooltip('添加今日刻度'));
    await tester.pumpAndSettle();
    expect(preferences.getStringList('home.cards.order'), <String>[
      'quote',
      'todayContext',
      'todos',
      'dayRuler',
    ]);

    // 新容器模拟再次打开应用，验证沿用原始存储键和值。
    final ProviderContainer restored = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
    );
    addTearDown(restored.dispose);
    expect(restored.read(homeCardPreferenceProvider).orderedCards, <HomeCardId>[
      HomeCardId.quote,
      HomeCardId.todayContext,
      HomeCardId.todos,
      HomeCardId.dayRuler,
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('移动分组列表可实际拖拽排序并持久化', (WidgetTester tester) async {
    // 当前测试使用的本机偏好。
    final SharedPreferences preferences = await _pumpManager(tester);
    // 第一项的实际拖拽手柄。
    final Finder handle = find.byKey(
      const ValueKey<String>('home-card-reorder-今日待办-0'),
    );
    // 第三项下沿的目标位置，确保越过最后一个插入阈值。
    final Offset target =
        tester.getBottomLeft(
          find.byKey(const ValueKey<String>('home-card-manager-todayContext')),
        ) +
        const Offset(280, -4);
    // 使用真实手势经过分组列表，避免仅调用排序回调。
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(handle),
    );
    await tester.pump();
    await gesture.moveBy(const Offset(0, 24));
    await tester.pump();
    // 连续位置模拟手指移动，等待排序空位动画响应。
    final Offset start = tester.getCenter(handle);
    for (final double progress in <double>[0.25, 0.5, 0.75, 1]) {
      await gesture.moveTo(Offset.lerp(start, target, progress)!);
      await tester.pump(const Duration(milliseconds: 100));
    }
    await gesture.moveBy(const Offset(0, 4));
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(preferences.getStringList('home.cards.order'), <String>[
      'timeStatus',
      'quote',
      'todayContext',
      'todos',
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('移动模块键盘排序使用内容索引并保留关闭功能', (WidgetTester tester) async {
    // 待办已关闭但仍应保留在管理器和持久化顺序里。
    final SharedPreferences preferences = await _pumpManager(
      tester,
      additionalPreferences: <String, Object>{'features.todos.enabled': false},
    );
    expect(find.text('每日待办功能已关闭'), findsOneWidget);
    // 第一项内容的可聚焦手柄。
    final Finder handle = find.byKey(
      const ValueKey<String>('home-card-reorder-今日待办-0'),
    );
    expect(tester.getSize(handle).width, greaterThanOrEqualTo(48));
    expect(tester.getSize(handle).height, greaterThanOrEqualTo(48));
    Focus.of(tester.element(handle)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(preferences.getStringList('home.cards.order'), <String>[
      'timeStatus',
      'quote',
      'todos',
      'todayContext',
    ]);
    expect(preferences.getBool('features.todos.enabled'), isFalse);
    expect(find.text('每日待办功能已关闭'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('全部模块隐藏时仍能单独管理名言和添加内容', (WidgetTester tester) async {
    // 空列表必须保留为空，不能恢复默认卡片。
    final SharedPreferences preferences = await _pumpManager(
      tester,
      order: const <String>[],
      additionalPreferences: <String, Object>{'features.todos.enabled': false},
    );
    expect(find.text('还没有添加内容模块，可以从下方选择。'), findsOneWidget);
    expect(find.byType(SliverReorderableList), findsNothing);
    expect(
      tester
          .widget<OmniSwitch>(
            find.byKey(const ValueKey<String>('home-settings-quote-switch')),
          )
          .value,
      isFalse,
    );
    expect(find.byTooltip('添加每日名言'), findsNothing);
    expect(find.byTooltip('需要先开启相关功能'), findsOneWidget);
    await tester.tap(find.byTooltip('添加时间状态'));
    await tester.pumpAndSettle();
    expect(preferences.getStringList('home.cards.order'), <String>[
      'timeStatus',
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows 管理器保持名言在卡片排序列表内', (WidgetTester tester) async {
    // 桌面继续使用原来的完整卡片顺序。
    final SharedPreferences preferences = await _pumpManager(
      tester,
      platform: TargetPlatform.windows,
      size: const Size(1000, 1000),
    );
    expect(find.text('管理卡片'), findsOneWidget);
    expect(find.text('首页设置'), findsNothing);
    expect(find.text('顶部横幅'), findsNothing);
    expect(find.textContaining(RegExp(r'^\d+$')), findsNothing);
    expect(find.byType(OmniSwitch), findsNothing);
    expect(find.byType(ReorderableDragStartListener), findsNWidgets(4));
    expect(find.byTooltip('移除每日名言'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey<String>('home-card-manager-quote')),
        matching: find.byType(OmniPanel),
      ),
      findsWidgets,
    );
    expect(
      find.byKey(const ValueKey<String>('home-settings-available-panel')),
      findsOneWidget,
    );
    // 桌面拖拽索引依然包含名言。
    final SliverReorderableList reorderable = tester
        .widget<SliverReorderableList>(find.byType(SliverReorderableList));
    reorderable.onReorderItem!(1, 0);
    await tester.pumpAndSettle();
    expect(preferences.getStringList('home.cards.order'), <String>[
      'quote',
      'todos',
      'timeStatus',
      'todayContext',
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('安卓宽屏继续使用原有卡片管理界面', (WidgetTester tester) async {
    await _pumpManager(tester, size: const Size(800, 1000));
    expect(find.text('管理卡片'), findsOneWidget);
    expect(find.text('首页设置'), findsNothing);
    expect(find.byType(OmniSwitch), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

/// 创建无需业务数据库的管理器测试环境并打开设置。
Future<SharedPreferences> _pumpManager(
  WidgetTester tester, {
  TargetPlatform platform = TargetPlatform.android,
  Size size = const Size(390, 1000),
  List<String> order = const <String>[
    'todos',
    'quote',
    'timeStatus',
    'todayContext',
  ],
  Map<String, Object> additionalPreferences = const <String, Object>{},
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues(<String, Object>{
    'home.cards.order': order,
    ...additionalPreferences,
  });
  // 当前测试使用的内存偏好存储。
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
      child: MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light)
            .copyWith(platform: platform),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showHomeCardManager(context),
              child: const Text('打开管理器'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开管理器'));
  await tester.pumpAndSettle();
  return preferences;
}
