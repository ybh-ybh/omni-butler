import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 明暗模式持久化键。
const String _themeModePreferenceKey = 'appearance.theme_mode';

/// 设备偏好存储提供者。
final Provider<SharedPreferences> sharedPreferencesProvider =
    Provider<SharedPreferences>((Ref ref) {
      throw StateError('SharedPreferences 尚未初始化');
    });

/// 当前主题偏好。
@immutable
class ThemePreference {
  /// 当前明暗模式。
  final ThemeMode mode;

  /// 创建主题偏好。
  const ThemePreference({required this.mode});

  /// 复制并替换指定偏好。
  ThemePreference copyWith({ThemeMode? mode}) {
    return ThemePreference(mode: mode ?? this.mode);
  }
}

/// 主题偏好控制器。
class ThemeController extends Notifier<ThemePreference> {
  /// 从设备存储恢复主题偏好。
  @override
  ThemePreference build() {
    // 设备偏好存储。
    final SharedPreferences preferences = ref.watch(sharedPreferencesProvider);
    // 已保存的明暗模式名称。
    final String? modeName = preferences.getString(_themeModePreferenceKey);

    return ThemePreference(
      mode: ThemeMode.values.firstWhere(
        (ThemeMode value) => value.name == modeName,
        orElse: () => ThemeMode.system,
      ),
    );
  }

  /// 切换明暗模式并保存到当前设备。
  Future<void> setThemeMode(ThemeMode mode) async {
    state = state.copyWith(mode: mode);
    // 设备偏好存储。
    final SharedPreferences preferences = ref.read(sharedPreferencesProvider);
    await preferences.setString(_themeModePreferenceKey, mode.name);
  }
}

/// 主题偏好状态提供者。
final NotifierProvider<ThemeController, ThemePreference>
themeControllerProvider = NotifierProvider<ThemeController, ThemePreference>(
  ThemeController.new,
);
