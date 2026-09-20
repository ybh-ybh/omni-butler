import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 可以由用户控制显示状态的业务功能。
enum AppFeature {
  /// 每日待办功能。
  todos,

  /// 时间管理功能。
  timeline,

  /// 事件管理功能。
  events,

  /// 物品管理功能。
  inventory,

  /// 会员管理功能。
  memberships,
}

/// 单个功能的本机持久化键。
String _featurePreferenceKey(AppFeature feature) {
  return 'features.${feature.name}.enabled';
}

/// 当前设备的功能启用偏好。
@immutable
class FeaturePreference {
  /// 各业务功能的启用状态。
  final Map<AppFeature, bool> enabledFeatures;

  /// 创建功能启用偏好。
  FeaturePreference({required Map<AppFeature, bool> enabledFeatures})
    : enabledFeatures = Map<AppFeature, bool>.unmodifiable(enabledFeatures);

  /// 判断指定业务功能是否启用。
  bool isEnabled(AppFeature feature) => enabledFeatures[feature] ?? true;

  /// 复制偏好并替换一个业务功能的状态。
  FeaturePreference copyWithFeature(AppFeature feature, bool enabled) {
    // 更新后的全部功能状态。
    final Map<AppFeature, bool> updatedFeatures = <AppFeature, bool>{
      ...enabledFeatures,
      feature: enabled,
    };
    return FeaturePreference(enabledFeatures: updatedFeatures);
  }
}

/// 当前设备功能偏好控制器。
class FeaturePreferenceController extends Notifier<FeaturePreference> {
  /// 从本机存储恢复全部功能状态。
  @override
  FeaturePreference build() {
    // 当前设备偏好存储。
    final SharedPreferences preferences = ref.watch(sharedPreferencesProvider);
    // 已恢复的全部功能状态。
    final Map<AppFeature, bool> enabledFeatures = <AppFeature, bool>{
      for (final AppFeature feature in AppFeature.values)
        feature: preferences.getBool(_featurePreferenceKey(feature)) ?? true,
    };
    return FeaturePreference(enabledFeatures: enabledFeatures);
  }

  /// 保存指定业务功能的启用状态。
  Future<void> setFeatureEnabled(AppFeature feature, bool enabled) async {
    state = state.copyWithFeature(feature, enabled);
    // 当前设备偏好存储。
    final SharedPreferences preferences = ref.read(sharedPreferencesProvider);
    await preferences.setBool(_featurePreferenceKey(feature), enabled);
  }
}

/// 当前设备功能偏好提供者。
final NotifierProvider<FeaturePreferenceController, FeaturePreference>
featurePreferenceProvider =
    NotifierProvider<FeaturePreferenceController, FeaturePreference>(
      FeaturePreferenceController.new,
    );
