import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

import 'omni_press_feedback.dart';

/// 音频条的紧凑文字操作，悬停浅灰底并显示手形光标。
class OmniNoteAudioLink extends StatelessWidget {
  /// 操作名称同时供键盘及读屏使用。
  final String label;

  /// 更多／收起使用尾部箭头，其余操作只有文字。
  final IconData? trailingIcon;

  /// 删除录音等操作在文字前显示小图标。
  final IconData? leadingIcon;

  /// 显式灰色用于更多入口，默认使用主题色。
  final Color? color;

  /// 正文展开和取消在悬停或键盘聚焦时切换文字色。
  final Color? hoverForeground;

  /// 纯文字展开入口不绘制额外悬停背景。
  final bool showHoverBackground;

  /// 为空时禁用操作，保留文字与布局。
  final VoidCallback? onPressed;

  /// 创建与音频截图一致的小号文字入口。
  const OmniNoteAudioLink({
    super.key,
    required this.label,
    required this.onPressed,
    this.trailingIcon,
    this.leadingIcon,
    this.color,
    this.hoverForeground,
    this.showHoverBackground = true,
  });

  /// 显式样式保持字号、留白和悬停背景一致。
  @override
  Widget build(BuildContext context) {
    // 表面与主题操作色跟随当前明暗配色。
    final OmniColors colors = OmniColors.of(context);
    return OmniPressBinding(
      enabled: onPressed != null,
      builder: (context, feedback) => TextButton(
        clipBehavior: Clip.none,
        onPressed: onPressed == null
            ? null
            : () {
                feedback.activate();
                onPressed!();
              },
        statesController: feedback.statesController,
        style: ButtonStyle(
          foregroundBuilder: feedback.foregroundBuilder,
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled)
                ? colors.muted.withValues(alpha: 0.45)
                : hoverForeground != null &&
                      (states.contains(WidgetState.hovered) ||
                          states.contains(WidgetState.focused))
                ? hoverForeground!
                : color ?? colors.brand,
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) =>
                showHoverBackground &&
                    (states.contains(WidgetState.hovered) ||
                        states.contains(WidgetState.pressed) ||
                        states.contains(WidgetState.focused))
                ? colors.mist
                : Colors.transparent,
          ),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          minimumSize: const WidgetStatePropertyAll(Size(0, OmniSpacing.xl)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(
              horizontal: OmniSpacing.xs,
              vertical: OmniSpacing.xxs,
            ),
          ),
          textStyle: WidgetStatePropertyAll(
            Theme.of(context).textTheme.bodySmall?.copyWith(
              fontSize: 12,
              height: 4 / 3,
              fontWeight: FontWeight.normal,
            ),
          ),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.standard,
          mouseCursor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled)
                ? SystemMouseCursors.basic
                : SystemMouseCursors.click,
          ),
          shape: const WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(OmniRadius.tiny)),
            ),
          ),
          animationDuration: OmniMotion.duration(context, OmniMotion.fast),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (leadingIcon != null) ...[
              Icon(leadingIcon, size: 12),
              const SizedBox(width: OmniSpacing.xxs),
            ],
            Text(label),
            if (trailingIcon != null) ...[
              const SizedBox(width: OmniSpacing.xxs),
              Icon(trailingIcon, size: 12),
            ],
          ],
        ),
      ),
    );
  }
}

/// 细灰色音频进度条，保留滑块键盘操作和播放位置语义。
class OmniNoteAudioSeekBar extends StatelessWidget {
  /// 当前播放或拖动预览位置，以毫秒计。
  final double value;

  /// 音频总时长，以毫秒计。
  final double total;

  /// 所属片段的读屏名称。
  final String label;

  /// 拖动预览回调，为空时显示不可操作的零进度。
  final ValueChanged<double>? onChanged;

  /// 松开滑块后的真实跳转回调。
  final ValueChanged<double>? onChangeEnd;

  /// 创建24dp热区内的两像素进度线。
  const OmniNoteAudioSeekBar({
    super.key,
    required this.value,
    required this.total,
    required this.label,
    required this.onChanged,
    required this.onChangeEnd,
  });

  /// 用独立 SliderTheme 复现细线和圆点，不改变其他页面滑块。
  @override
  Widget build(BuildContext context) {
    // 轨道使用中性灰色，播放进度和圆点保持可见。
    final OmniColors colors = OmniColors.of(context);
    return Semantics(
      label: label,
      child: SizedBox(
        height: OmniSpacing.xl,
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 2,
            activeTrackColor: colors.muted,
            inactiveTrackColor: colors.line,
            disabledActiveTrackColor: colors.line,
            disabledInactiveTrackColor: colors.line,
            thumbColor: colors.muted,
            disabledThumbColor: colors.muted,
            thumbShape: const RoundSliderThumbShape(
              enabledThumbRadius: 3,
              disabledThumbRadius: 3,
            ),
            overlayShape: SliderComponentShape.noOverlay,
            trackShape: const RectangularSliderTrackShape(),
          ),
          child: Slider(
            value: value,
            max: total,
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
            padding: EdgeInsets.zero,
            mouseCursor: onChanged == null
                ? SystemMouseCursors.basic
                : SystemMouseCursors.click,
            semanticFormatterCallback: (position) =>
                '${(position / 1000).round()}秒',
          ),
        ),
      ),
    );
  }
}
