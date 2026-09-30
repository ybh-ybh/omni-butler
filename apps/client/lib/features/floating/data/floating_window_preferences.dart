import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 悬浮框启用状态的本机偏好键。
const String _enabledKey = 'floating_window.enabled';

/// 悬浮框最近所在显示器的本机偏好键。
const String _displayIdKey = 'floating_window.display_id';

/// 悬浮框最近水平位置的本机偏好键。
const String _positionXKey = 'floating_window.position_x';

/// 悬浮框最近垂直位置的本机偏好键。
const String _positionYKey = 'floating_window.position_y';

/// 悬浮框最近宽度的本机偏好键。
const String _widthKey = 'floating_window.width';

/// 悬浮框最近高度的本机偏好键。
const String _heightKey = 'floating_window.height';

/// 当前设备保存的悬浮框偏好。
@immutable
class FloatingWindowPreference {
  /// 用户是否开启 Windows 桌面悬浮框。
  final bool enabled;

  /// 最近一次有效位置所属的显示器标识。
  final String? displayId;

  /// 最近一次有效位置的逻辑横坐标。
  final double? positionX;

  /// 最近一次有效位置的逻辑纵坐标。
  final double? positionY;

  /// 最近一次用户调整后的逻辑宽度。
  final double? width;

  /// 最近一次用户调整后的逻辑高度。
  final double? height;

  /// 创建悬浮框本机偏好。
  const FloatingWindowPreference({
    required this.enabled,
    this.displayId,
    this.positionX,
    this.positionY,
    this.width,
    this.height,
  });

  /// 当前是否存在一组可以恢复的完整窗口位置。
  bool get hasPlacement =>
      displayId != null && positionX != null && positionY != null;

  /// 当前是否存在一组可以恢复的完整窗口尺寸。
  bool get hasSize =>
      width != null && height != null && width!.isFinite && height!.isFinite;

  /// 复制偏好并替换启用状态。
  FloatingWindowPreference copyWithEnabled(bool value) {
    return FloatingWindowPreference(
      enabled: value,
      displayId: displayId,
      positionX: positionX,
      positionY: positionY,
      width: width,
      height: height,
    );
  }

  /// 复制偏好并替换最近一次窗口位置。
  FloatingWindowPreference copyWithPlacement({
    required String displayId,
    required double positionX,
    required double positionY,
  }) {
    return FloatingWindowPreference(
      enabled: enabled,
      displayId: displayId,
      positionX: positionX,
      positionY: positionY,
      width: width,
      height: height,
    );
  }

  /// 复制偏好并替换最近一次窗口尺寸。
  FloatingWindowPreference copyWithSize({
    required double width,
    required double height,
  }) {
    return FloatingWindowPreference(
      enabled: enabled,
      displayId: displayId,
      positionX: positionX,
      positionY: positionY,
      width: width,
      height: height,
    );
  }

  /// 复制偏好并清除用户调整过的窗口尺寸。
  FloatingWindowPreference withoutSize() {
    return FloatingWindowPreference(
      enabled: enabled,
      displayId: displayId,
      positionX: positionX,
      positionY: positionY,
    );
  }
}

/// 当前设备悬浮框偏好控制器。
class FloatingWindowPreferenceController
    extends Notifier<FloatingWindowPreference> {
  /// 从本机偏好恢复开关与最近位置。
  @override
  FloatingWindowPreference build() {
    // 当前设备偏好存储。
    final SharedPreferences preferences = ref.watch(sharedPreferencesProvider);
    return FloatingWindowPreference(
      enabled: preferences.getBool(_enabledKey) ?? false,
      displayId: preferences.getString(_displayIdKey),
      positionX: preferences.getDouble(_positionXKey),
      positionY: preferences.getDouble(_positionYKey),
      width: preferences.getDouble(_widthKey),
      height: preferences.getDouble(_heightKey),
    );
  }

  /// 保存悬浮框启用状态。
  Future<void> setEnabled(bool enabled) async {
    if (state.enabled == enabled) {
      return;
    }
    state = state.copyWithEnabled(enabled);
    // 当前设备偏好存储。
    final SharedPreferences preferences = ref.read(sharedPreferencesProvider);
    await preferences.setBool(_enabledKey, enabled);
  }

  /// 从设置页切换悬浮框，并在关闭时恢复默认尺寸。
  Future<void> setEnabledFromSettings(bool enabled) async {
    // 当前设备偏好存储。
    final SharedPreferences preferences = ref.read(sharedPreferencesProvider);
    if (!enabled) {
      state = state.withoutSize().copyWithEnabled(false);
      await Future.wait(<Future<bool>>[
        preferences.setBool(_enabledKey, false),
        preferences.remove(_widthKey),
        preferences.remove(_heightKey),
      ]);
      return;
    }
    if (state.enabled == enabled) {
      return;
    }
    state = state.copyWithEnabled(enabled);
    await preferences.setBool(_enabledKey, enabled);
  }

  /// 保存悬浮框最后一次有效位置。
  Future<void> savePlacement({
    required String displayId,
    required double positionX,
    required double positionY,
  }) async {
    state = state.copyWithPlacement(
      displayId: displayId,
      positionX: positionX,
      positionY: positionY,
    );
    // 当前设备偏好存储。
    final SharedPreferences preferences = ref.read(sharedPreferencesProvider);
    await Future.wait(<Future<bool>>[
      preferences.setString(_displayIdKey, displayId),
      preferences.setDouble(_positionXKey, positionX),
      preferences.setDouble(_positionYKey, positionY),
    ]);
  }

  /// 保存用户最后一次调整后的悬浮框尺寸。
  Future<void> saveSize({required double width, required double height}) async {
    state = state.copyWithSize(width: width, height: height);
    // 当前设备偏好存储。
    final SharedPreferences preferences = ref.read(sharedPreferencesProvider);
    await Future.wait(<Future<bool>>[
      preferences.setDouble(_widthKey, width),
      preferences.setDouble(_heightKey, height),
    ]);
  }
}

/// 当前设备悬浮框偏好提供者。
final NotifierProvider<
  FloatingWindowPreferenceController,
  FloatingWindowPreference
>
floatingWindowPreferenceProvider =
    NotifierProvider<
      FloatingWindowPreferenceController,
      FloatingWindowPreference
    >(FloatingWindowPreferenceController.new);
