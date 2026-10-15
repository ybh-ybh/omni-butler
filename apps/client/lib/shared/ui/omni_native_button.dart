import 'package:flutter/material.dart';

import 'omni_press_feedback.dart';

/// 保留选择对话框原生留白与热区，只为Windows内容接入按压。
class OmniSimpleDialogOption extends SimpleDialogOption {
  /// 创建与原生选择项相同的业务和布局接口。
  const OmniSimpleDialogOption({
    super.key,
    super.onPressed,
    super.padding,
    super.child,
  });

  /// Android仍由原生选择项处理，Windows沿用同一个InkWell识别器。
  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).platform != TargetPlatform.windows) {
      return super.build(context);
    }
    return OmniInkWell(
      onTap: onPressed,
      child: Padding(
        padding:
            padding ?? const EdgeInsets.symmetric(vertical: 8, horizontal: 24),
        child: child,
      ),
    );
  }
}

/// 保留原生文字按钮外观，仅为Windows内容增加统一按压反馈。
class OmniTextButton extends _OmniNativeButton {
  /// 创建沿用原TextButton参数与主题的文字按钮。
  const OmniTextButton({
    required super.onPressed,
    required Widget super.child,
    super.onLongPress,
    super.onHover,
    super.onFocusChange,
    super.style,
    super.focusNode,
    super.autofocus,
    super.clipBehavior,
    super.key,
  }) : super(kind: _OmniNativeButtonKind.text);

  /// 保留原生图标文字按钮的间距与主题。
  const OmniTextButton.icon({
    required super.onPressed,
    required super.icon,
    required super.label,
    super.onLongPress,
    super.onHover,
    super.onFocusChange,
    super.style,
    super.focusNode,
    super.autofocus,
    super.clipBehavior,
    super.key,
  }) : super(kind: _OmniNativeButtonKind.text);
}

/// 保留原生描边按钮几何与主题，仅缩放其文字和图标。
class OmniOutlinedButton extends _OmniNativeButton {
  /// 创建保留原生描边样式的按钮。
  const OmniOutlinedButton({
    required super.onPressed,
    required Widget super.child,
    super.onLongPress,
    super.onHover,
    super.onFocusChange,
    super.style,
    super.focusNode,
    super.autofocus,
    super.clipBehavior,
    super.key,
  }) : super(kind: _OmniNativeButtonKind.outlined);

  /// 图标和标签作为同一内容层压缩，背景与边框固定。
  const OmniOutlinedButton.icon({
    required super.onPressed,
    required super.icon,
    required super.label,
    super.onLongPress,
    super.onHover,
    super.onFocusChange,
    super.style,
    super.focusNode,
    super.autofocus,
    super.clipBehavior,
    super.key,
  }) : super(kind: _OmniNativeButtonKind.outlined);
}

/// 沿用原生填色按钮的加载以外行为和视觉。
class OmniFilledButton extends _OmniNativeButton {
  /// 创建仅增加Windows内容反馈的填色按钮。
  const OmniFilledButton({
    required super.onPressed,
    required Widget super.child,
    super.onLongPress,
    super.onHover,
    super.onFocusChange,
    super.style,
    super.focusNode,
    super.autofocus,
    super.clipBehavior,
    super.key,
  }) : super(kind: _OmniNativeButtonKind.filled);
}

/// 原生按钮家族的选择，不另建颜色或尺寸规范。
enum _OmniNativeButtonKind {
  /// 文字次操作。
  text,

  /// 描边次操作。
  outlined,

  /// 实色主操作。
  filled,
}

/// 为已有受控原生按钮接入内容反馈，维持底层按钮类型。
abstract class _OmniNativeButton extends StatelessWidget {
  /// 原生按钮类型。
  final _OmniNativeButtonKind kind;

  /// 原业务回调，为空时禁用。
  final VoidCallback? onPressed;

  /// 原长按操作。
  final VoidCallback? onLongPress;

  /// 原悬停通知。
  final ValueChanged<bool>? onHover;

  /// 原焦点通知。
  final ValueChanged<bool>? onFocusChange;

  /// 业务提供的原生样式。
  final ButtonStyle? style;

  /// 原焦点节点。
  final FocusNode? focusNode;

  /// 是否自动聚焦。
  final bool autofocus;

  /// 原内容裁剪方式。
  final Clip? clipBehavior;

  /// 原普通内容。
  final Widget? child;

  /// 图标构造的图标。
  final Widget? icon;

  /// 图标构造的文字。
  final Widget? label;

  /// 保存原生按钮所需的最小接口。
  const _OmniNativeButton({
    required this.kind,
    required this.onPressed,
    this.child,
    this.icon,
    this.label,
    this.onLongPress,
    this.onHover,
    this.onFocusChange,
    this.style,
    this.focusNode,
    this.autofocus = false,
    this.clipBehavior,
    super.key,
  });

  /// 用原生状态控制器驱动内容动画，业务同步执行。
  @override
  Widget build(BuildContext context) => OmniPressBinding(
    enabled: onPressed != null || onLongPress != null,
    builder: (BuildContext context, OmniPressFeedback feedback) {
      // 只替换内容构建器，其他样式完全继承业务及主题。
      final ButtonStyle effectiveStyle = (style ?? const ButtonStyle())
          .copyWith(foregroundBuilder: feedback.foregroundBuilder);
      // 成功激活补足快速点击与语义激活反馈，不等待动画。
      final VoidCallback? activate = onPressed == null
          ? null
          : () {
              feedback.activate();
              onPressed!();
            };
      // 图标构造继续交给原生工厂计算图文间距。
      if (kind == _OmniNativeButtonKind.text && label != null) {
        return TextButton.icon(
          onPressed: activate,
          onLongPress: onLongPress,
          onHover: onHover,
          onFocusChange: onFocusChange,
          style: effectiveStyle,
          statesController: feedback.statesController,
          focusNode: focusNode,
          autofocus: autofocus,
          clipBehavior: clipBehavior ?? Clip.none,
          icon: icon,
          label: label!,
        );
      }
      if (kind == _OmniNativeButtonKind.outlined && label != null) {
        return OutlinedButton.icon(
          onPressed: activate,
          onLongPress: onLongPress,
          onHover: onHover,
          onFocusChange: onFocusChange,
          style: effectiveStyle,
          statesController: feedback.statesController,
          focusNode: focusNode,
          autofocus: autofocus,
          clipBehavior: clipBehavior ?? Clip.none,
          icon: icon,
          label: label!,
        );
      }
      return switch (kind) {
        _OmniNativeButtonKind.text => TextButton(
          onPressed: activate,
          onLongPress: onLongPress,
          onHover: onHover,
          onFocusChange: onFocusChange,
          style: effectiveStyle,
          statesController: feedback.statesController,
          focusNode: focusNode,
          autofocus: autofocus,
          clipBehavior: clipBehavior ?? Clip.none,
          child: child!,
        ),
        _OmniNativeButtonKind.outlined => OutlinedButton(
          onPressed: activate,
          onLongPress: onLongPress,
          onHover: onHover,
          onFocusChange: onFocusChange,
          style: effectiveStyle,
          statesController: feedback.statesController,
          focusNode: focusNode,
          autofocus: autofocus,
          clipBehavior: clipBehavior ?? Clip.none,
          child: child!,
        ),
        _OmniNativeButtonKind.filled => FilledButton(
          onPressed: activate,
          onLongPress: onLongPress,
          onHover: onHover,
          onFocusChange: onFocusChange,
          style: effectiveStyle,
          statesController: feedback.statesController,
          focusNode: focusNode,
          autofocus: autofocus,
          clipBehavior: clipBehavior ?? Clip.none,
          child: child!,
        ),
      };
    },
  );
}
