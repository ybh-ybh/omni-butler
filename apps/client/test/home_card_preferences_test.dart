import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/features/home/data/home_card_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证首页卡片偏好的默认值、增删、排序与本机持久化。
void main() {
  test('首页默认展示五张卡片并持久化增删排序', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 测试用设备偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 首次读取偏好的 Riverpod 容器。
    final ProviderContainer firstContainer = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
    );

    expect(
      firstContainer.read(homeCardPreferenceProvider).orderedCards,
      defaultHomeCardOrder,
    );

    await firstContainer
        .read(homeCardPreferenceProvider.notifier)
        .setVisible(HomeCardId.dayRuler, false);
    await firstContainer
        .read(homeCardPreferenceProvider.notifier)
        .reorder(3, 0);

    expect(
      firstContainer.read(homeCardPreferenceProvider).orderedCards,
      <HomeCardId>[
        HomeCardId.timeStatus,
        HomeCardId.quote,
        HomeCardId.todos,
        HomeCardId.todayContext,
      ],
    );
    firstContainer.dispose();

    // 模拟应用重启后的 Riverpod 容器。
    final ProviderContainer restoredContainer = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
    );
    expect(
      restoredContainer.read(homeCardPreferenceProvider).orderedCards,
      <HomeCardId>[
        HomeCardId.timeStatus,
        HomeCardId.quote,
        HomeCardId.todos,
        HomeCardId.todayContext,
      ],
    );
    restoredContainer.dispose();
  });

  test('空卡片列表可以持久化且不会恢复默认值', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'home.cards.order': <String>[],
    });
    // 测试用设备偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用 Riverpod 容器。
    final ProviderContainer container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
    );

    expect(container.read(homeCardPreferenceProvider).orderedCards, isEmpty);
    container.dispose();
  });
}
