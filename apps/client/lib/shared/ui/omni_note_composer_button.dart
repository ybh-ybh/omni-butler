import 'package:flutter/material.dart';

import 'omni_windows_semantics_boundary.dart';
import 'omni_press_feedback.dart';
import 'omni_menu_route.dart';

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

  /// 工具悬停与键盘聚焦时加深前景，主操作不传则沿用原样。
  final Color? hoverForeground;

  /// 工具底色独立绘制，避开 InkHighlight 固定透明度造成的黑底。
  final Color? hoverBackground;

  /// 当前格式或弹层处于启用状态。
  final bool selected;

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
    this.hoverForeground,
    this.hoverBackground,
    this.selected = false,
  });

  /// 保留原生键盘和提示能力，并将背景完整绘制到参考尺寸。
  @override
  Widget build(BuildContext context) => OmniWindowsSemanticsBoundary(
    child: OmniPressBinding(
      enabled: onPressed != null,
      builder: (context, feedback) {
        // 提前同步禁用状态，避免子按钮挂载时通知正在构建的外层监听器。
        feedback.statesController.update(
          WidgetState.disabled,
          onPressed == null,
        );
        return ListenableBuilder(
          listenable: feedback.statesController,
          builder: (context, _) {
            // 菜单沿用最近输入方式，鼠标打开时不把首项键盘焦点画成选中。
            final OmniMenuNavigation? menu = context
                .dependOnInheritedWidgetOfExactType<OmniMenuNavigation>();
            // 菜单内只突出当前导航来源，菜单外保留原有悬停与焦点反馈。
            final bool highlighted = menu == null
                ? feedback.statesController.value.contains(
                        WidgetState.hovered,
                      ) ||
                      feedback.statesController.value.contains(
                        WidgetState.focused,
                      )
                : feedback.statesController.value.contains(
                    menu.keyboard ? WidgetState.focused : WidgetState.hovered,
                  );
            // 仅可操作工具响应鼠标与键盘状态。
            final bool active = onPressed != null && (selected || highlighted);
            // 前景与独立背景共享同一状态，不修改主操作配色。
            final Color ink = active
                ? hoverForeground ?? foreground
                : foreground;
            // 透明时保留背景 RGB，避免退场动画混入透明黑。
            final Color? fill = hoverBackground;
            return Stack(
              alignment: Alignment.center,
              children: [
                if (fill != null)
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.all(OmniSpacing.xxs),
                      child: AnimatedContainer(
                        key: ValueKey('composer-hover-$tooltip'),
                        duration: OmniMotion.duration(context, OmniMotion.fast),
                        curve: OmniMotion.standardCurve,
                        decoration: BoxDecoration(
                          color: fill.withValues(alpha: active ? fill.a : 0),
                          borderRadius: BorderRadius.circular(
                            OmniRadius.control,
                          ),
                        ),
                      ),
                    ),
                  ),
                IconButton(
                  tooltip: tooltip,
                  onPressed: onPressed == null
                      ? null
                      : () {
                          feedback.activate();
                          onPressed!();
                        },
                  statesController: feedback.statesController,
                  icon: icon,
                  style: ButtonStyle(
                    foregroundBuilder: feedback.foregroundBuilder,
                    mouseCursor: WidgetStateProperty.resolveWith(
                      (states) => states.contains(WidgetState.disabled)
                          ? SystemMouseCursors.basic
                          : SystemMouseCursors.click,
                    ),
                    foregroundColor: WidgetStatePropertyAll(ink),
                    iconColor: WidgetStatePropertyAll(ink),
                    backgroundColor: WidgetStatePropertyAll(background),
                    overlayColor: WidgetStatePropertyAll(overlay),
                    iconSize: const WidgetStatePropertyAll(OmniSpacing.xl),
                    padding: const WidgetStatePropertyAll(EdgeInsets.zero),
                    minimumSize: WidgetStatePropertyAll(size),
                    maximumSize: WidgetStatePropertyAll(size),
                    fixedSize: WidgetStatePropertyAll(size),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.standard,
                    animationDuration: OmniMotion.duration(
                      context,
                      OmniMotion.fast,
                    ),
                    shape: const WidgetStatePropertyAll(
                      RoundedRectangleBorder(
                        borderRadius: BorderRadius.all(
                          Radius.circular(OmniRadius.control),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    ),
  );
}
