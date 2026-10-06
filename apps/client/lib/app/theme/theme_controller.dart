import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/theme/app_theme_palette.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 明暗模式持久化键。
const String _themeModePreferenceKey = 'appearance.theme_mode';

/// 主题配色持久化键。
const String _themePalettePreferenceKey = 'appearance.theme_palette';

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

  /// 当前主题配色。
  final AppThemePalette palette;

  /// 创建主题偏好。
  const ThemePreference({
    required this.mode,
    this.palette = AppThemePalette.classicBlue,
  });

  /// 复制并替换指定偏好。
  ThemePreference copyWith({ThemeMode? mode, AppThemePalette? palette}) {
    return ThemePreference(
      mode: mode ?? this.mode,
      palette: palette ?? this.palette,
    );
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
      palette: AppThemePalette.fromId(
        preferences.getString(_themePalettePreferenceKey),
      ),
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

  /// 立即切换配色并保存到当前设备，不改变明暗模式。
  Future<void> setThemePalette(AppThemePalette palette) async {
    state = state.copyWith(palette: palette);
    // 设备偏好存储。
    final SharedPreferences preferences = ref.read(sharedPreferencesProvider);
    await preferences.setString(_themePalettePreferenceKey, palette.id);
  }
}

/// 主题偏好状态提供者。
final NotifierProvider<ThemeController, ThemePreference>
themeControllerProvider = NotifierProvider<ThemeController, ThemePreference>(
  ThemeController.new,
);
