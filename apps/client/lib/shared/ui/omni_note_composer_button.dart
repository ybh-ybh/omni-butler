import 'package:flutter/material.dart';

import 'omni_windows_semantics_boundary.dart';

import 'package:omni_butler/app/theme/app_tokens.dart';

/// 笔记输入卡片的图标按钮，显式样式不被普通图标的内缩轮廓覆盖。
class OmniNoteComposerButton extends StatelessWidget {
  /// 当前动作图标或提交加载指示。
  final Widget icon;

  /// 图标操作的无障碍名称与悬停提示。
  final String tooltip;

  /// 不可操作时为空，保留按钮占位和外观。
  final VoidCallback? onPressed;

  /// 标签与主操作各自的图标前景色。
  final Color foreground;

  /// 发布、麦克风或透明标签的底色。
  final Color background;

  /// 图标按钮的实际布局与绘制尺寸。
  final Size size;

  /// 标签保持透明，主操作保留轻微按下反馈。
  final Color overlay;

  /// 创建仅供笔记输入卡片使用的图标操作。
  const OmniNoteComposerButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    required this.foreground,
    this.background = Colors.transparent,
    this.size = const Size.square(OmniSize.iconButton),
    this.overlay = Colors.transparent,
  });

  /// 保留原生键盘和提示能力，并将背景完整绘制到参考尺寸。
  @override
  Widget build(BuildContext context) => OmniWindowsSemanticsBoundary(
    child: IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: icon,
      style: ButtonStyle(
        mouseCursor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? SystemMouseCursors.basic
              : SystemMouseCursors.click,
        ),
        foregroundColor: WidgetStatePropertyAll(foreground),
        iconColor: WidgetStatePropertyAll(foreground),
        backgroundColor: WidgetStatePropertyAll(background),
        overlayColor: WidgetStatePropertyAll(overlay),
        iconSize: const WidgetStatePropertyAll(OmniSpacing.xl),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        minimumSize: WidgetStatePropertyAll(size),
        maximumSize: WidgetStatePropertyAll(size),
        fixedSize: WidgetStatePropertyAll(size),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.standard,
        animationDuration: OmniMotion.duration(context, OmniMotion.fast),
        shape: const WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(OmniRadius.control)),
          ),
        ),
      ),
    ),
  );
}
