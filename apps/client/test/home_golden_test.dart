import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/omni_butler_app.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
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
    expect(contextSize.width, inInclusiveRange(320, 380));
    expect(quoteSize.width, greaterThan(contextSize.width * 2));
    expect(quoteSize.height, inInclusiveRange(144, 174));
    expect(rulerSize.height, 86);
    expect(
      contextSize.height,
      closeTo(quoteSize.height + rulerSize.height + todoSize.height + 16, 0.1),
    );

    await expectLater(
      find.byType(OmniButlerApp),
      matchesGoldenFile('goldens/home_feishu_light_1440x900.png'),
    );
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Windows 窄窗口首页渐进隐藏视觉基线', (WidgetTester tester) async {
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
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('home-todo-card')),
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
