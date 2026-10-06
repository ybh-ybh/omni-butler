import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme_palette.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证主题偏好的兼容默认值、持久化与相互独立的更新。
void main() {
  test('没有偏好时仍使用经典蓝和跟随系统', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 当前设备的测试存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 当前设备的依赖容器。
    final ProviderContainer container = _container(preferences);
    expect(container.read(themeControllerProvider).mode, ThemeMode.system);
    expect(
      container.read(themeControllerProvider).palette,
      AppThemePalette.classicBlue,
    );
  });

  test('未知主题标识回退经典蓝并保留原明暗偏好', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'appearance.theme_mode': 'dark',
      'appearance.theme_palette': 'removed_palette',
    });
    // 当前设备的测试存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 当前设备的依赖容器。
    final ProviderContainer container = _container(preferences);
    expect(container.read(themeControllerProvider).mode, ThemeMode.dark);
    expect(
      container.read(themeControllerProvider).palette,
      AppThemePalette.classicBlue,
    );
  });

  test('每款配色均可保存并在新容器中恢复，切换模式不覆盖配色', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 当前设备的测试存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 当前设备的依赖容器。
    final ProviderContainer container = _container(preferences);
    // 当前设备的主题控制器。
    final ThemeController controller = container.read(
      themeControllerProvider.notifier,
    );
    await controller.setThemeMode(ThemeMode.dark);
    // 逐个验证持久化标识，而非只覆盖默认主题。
    for (final AppThemePalette palette in AppThemePalette.values) {
      await controller.setThemePalette(palette);
      expect(preferences.getString('appearance.theme_palette'), palette.id);
      expect(container.read(themeControllerProvider).mode, ThemeMode.dark);
      // 模拟设备重新启动后恢复同一个本机存储。
      final ProviderContainer restored = _container(preferences);
      expect(restored.read(themeControllerProvider).palette, palette);
      expect(restored.read(themeControllerProvider).mode, ThemeMode.dark);
    }
    await controller.setThemeMode(ThemeMode.light);
    expect(
      container.read(themeControllerProvider).palette,
      AppThemePalette.slate,
    );
    expect(preferences.getString('appearance.theme_mode'), 'light');
  });

  test('连续快速切换后保存最后一款配色', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 当前设备的测试存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 当前设备的依赖容器。
    final ProviderContainer container = _container(preferences);
    // 当前设备的主题控制器。
    final ThemeController controller = container.read(
      themeControllerProvider.notifier,
    );
    await Future.wait(<Future<void>>[
      controller.setThemePalette(AppThemePalette.sky),
      controller.setThemePalette(AppThemePalette.seaSalt),
      controller.setThemePalette(AppThemePalette.slate),
    ]);
    expect(
      container.read(themeControllerProvider).palette,
      AppThemePalette.slate,
    );
    expect(preferences.getString('appearance.theme_palette'), 'slate');
  });
}

/// 创建自动清理的测试容器。
ProviderContainer _container(SharedPreferences preferences) {
  // 显式注入本机存储的 Riverpod 容器。
  final ProviderContainer container = ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
  );
  addTearDown(container.dispose);
  return container;
}
