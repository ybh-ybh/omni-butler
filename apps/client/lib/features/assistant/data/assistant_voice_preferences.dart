import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';

/// 本机语音发送偏好，不跟随服务器设置同步。
const String assistantVoiceAutoSendKey = 'assistant.voice.autoSend';

/// 仅在保存成功后更新开关，默认让用户检查转写。
class AssistantVoicePreference extends Notifier<bool> {
  /// 恢复当前设备保存值。
  @override
  bool build() =>
      ref.watch(sharedPreferencesProvider).getBool(assistantVoiceAutoSendKey) ??
      false;

  /// 持久保存失败时保留原状态。
  Future<void> setEnabled(bool enabled) async {
    if (!await ref
        .read(sharedPreferencesProvider)
        .setBool(assistantVoiceAutoSendKey, enabled)) {
      throw StateError('语音输入设置保存失败');
    }
    state = enabled;
  }
}

/// 各设备独立的自动发送开关。
final assistantVoicePreferenceProvider =
    NotifierProvider<AssistantVoicePreference, bool>(
      AssistantVoicePreference.new,
    );
