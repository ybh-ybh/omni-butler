import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 多端同步总开关持久化键。
const String _syncEnabledKey = 'sync.enabled';

/// 当前设备多端同步偏好控制器。
class SyncPreferenceController extends Notifier<bool> {
  /// 从本机存储恢复同步开关，首次安装默认关闭。
  @override
  bool build() {
    // 当前设备偏好存储。
    final SharedPreferences preferences = ref.watch(sharedPreferencesProvider);
    return preferences.getBool(_syncEnabledKey) ?? false;
  }

  /// 保存同步总开关。
  Future<void> setEnabled(bool value) async {
    state = value;
    // 当前设备偏好存储。
    final SharedPreferences preferences = ref.read(sharedPreferencesProvider);
    await preferences.setBool(_syncEnabledKey, value);
  }
}

/// 当前设备多端同步总开关提供者。
final NotifierProvider<SyncPreferenceController, bool> syncPreferenceProvider =
    NotifierProvider<SyncPreferenceController, bool>(
      SyncPreferenceController.new,
    );
