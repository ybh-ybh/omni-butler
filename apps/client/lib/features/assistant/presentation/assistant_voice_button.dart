import 'package:flutter/material.dart';
import 'package:omni_butler/features/assistant/data/assistant_voice_controller.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 发送按钮左侧的轻量麦克风，保留触控和读屏热区。
class AssistantVoiceButton extends StatelessWidget {
  /// 当前语音阶段。
  final AssistantVoicePhase phase;

  /// 是否允许开始新录音。
  final bool enabled;

  /// 开始或手动结束。
  final VoidCallback onPressed;

  /// 两端使用同一录音按钮语义。
  const AssistantVoiceButton({
    required this.phase,
    required this.enabled,
    required this.onPressed,
    super.key,
  });

  /// 等待期间禁用重复启动，录音期间始终允许结束。
  @override
  Widget build(BuildContext context) {
    // 准备和收尾均显示进行中状态。
    final bool waiting =
        phase == AssistantVoicePhase.preparing ||
        phase == AssistantVoicePhase.finishing;
    // 是否正在真实采集。
    final bool recording = phase == AssistantVoicePhase.recording;
    return OmniIconButton(
      key: const ValueKey<String>('assistant-voice-button'),
      tooltip: recording
          ? '结束语音输入'
          : waiting
          ? '正在处理语音输入'
          : '语音输入',
      icon: waiting
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              recording ? Icons.stop_circle_outlined : Icons.mic_none_rounded,
            ),
      onPressed: !waiting && (recording || enabled) ? onPressed : null,
    );
  }
}
