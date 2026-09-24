import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/features/floating/data/floating_window_preferences.dart';
import 'package:omni_butler/features/floating/platform/floating_window_placement.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证 Windows 悬浮窗本机偏好与窗口位置约束。
void main() {
  test('悬浮窗默认关闭并持久化开关与位置', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 测试用设备偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 首次读取悬浮窗偏好的容器。
    final ProviderContainer firstContainer = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
    );

    expect(
      firstContainer.read(floatingWindowPreferenceProvider).enabled,
      false,
    );
    await firstContainer
        .read(floatingWindowPreferenceProvider.notifier)
        .setEnabled(true);
    await firstContainer
        .read(floatingWindowPreferenceProvider.notifier)
        .savePlacement(displayId: 'display-2', positionX: 120, positionY: 64);
    firstContainer.dispose();

    // 模拟应用重启后的偏好容器。
    final ProviderContainer restoredContainer = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
    );
    // 应用重启后恢复的悬浮窗偏好。
    final FloatingWindowPreference restored = restoredContainer.read(
      floatingWindowPreferenceProvider,
    );
    expect(restored.enabled, true);
    expect(restored.displayId, 'display-2');
    expect(restored.positionX, 120);
    expect(restored.positionY, 64);
    restoredContainer.dispose();
  });

  test('窗口位置会被约束在带边距的工作区内', () {
    expect(
      clampFloatingPlacement(
        desiredPosition: const Offset(-50, 900),
        workAreaSize: const Size(1920, 1040),
        windowSize: const Size(420, 760),
        margin: 24,
      ),
      const Offset(24, 256),
    );
  });

  test('工作区小于悬浮窗时仍返回安全坐标', () {
    expect(
      clampFloatingPlacement(
        desiredPosition: const Offset(100, 100),
        workAreaSize: const Size(320, 600),
        windowSize: const Size(420, 760),
        margin: 24,
      ),
      const Offset(24, 24),
    );
  });

  test('靠近工作区边缘时吸附到对应边缘', () {
    expect(
      snapFloatingPlacement(
        desiredPosition: const Offset(18, 268),
        workAreaSize: const Size(1920, 1040),
        windowSize: const Size(420, 760),
        threshold: 24,
      ),
      const Offset(0, 280),
    );
    expect(
      snapFloatingPlacement(
        desiredPosition: const Offset(1482, 12),
        workAreaSize: const Size(1920, 1040),
        windowSize: const Size(420, 760),
        threshold: 24,
      ),
      const Offset(1500, 0),
    );
  });

  test('未进入吸附范围时只约束位置而不改变坐标', () {
    expect(
      snapFloatingPlacement(
        desiredPosition: const Offset(120, 96),
        workAreaSize: const Size(1920, 1040),
        windowSize: const Size(420, 760),
        threshold: 24,
      ),
      const Offset(120, 96),
    );
  });
}
