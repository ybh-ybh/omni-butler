import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

/// 悬停入口统一淡入淡出，保留布局和子树以支持中途反向。
class OmniHoverReveal extends StatelessWidget {
  /// 创建不改变布局占位的渐隐入口。
  const OmniHoverReveal({
    required this.visible,
    required this.child,
    super.key,
  });

  /// 入口当前是否应可见和可操作。
  final bool visible;

  /// 保留原有状态、焦点及菜单身份的控件。
  final Widget child;

  /// 淡出开始即禁止点击、键盘焦点及读屏，不等待动画结束。
  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !visible,
    child: ExcludeFocus(
      excluding: !visible,
      child: ExcludeSemantics(
        excluding: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: OmniMotion.duration(context, OmniMotion.fast),
          curve: OmniMotion.standardCurve,
          child: child,
        ),
      ),
    ),
  );
}
