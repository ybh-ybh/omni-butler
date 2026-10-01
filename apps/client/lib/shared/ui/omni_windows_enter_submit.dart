import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 在 Windows 上将无修饰键的 Enter 映射为提交操作。
class OmniWindowsEnterSubmit extends StatefulWidget {
  /// 被键盘提交作用域包裹的内容。
  final Widget child;

  /// Enter 提交回调；为空时不拦截按键。
  final VoidCallback? onSubmit;

  /// 创建 Windows Enter 提交作用域。
  const OmniWindowsEnterSubmit({
    required this.child,
    required this.onSubmit,
    super.key,
  });

  /// 创建 Windows Enter 提交作用域状态。
  @override
  State<OmniWindowsEnterSubmit> createState() => _OmniWindowsEnterSubmitState();
}

/// Windows Enter 提交作用域状态。
class _OmniWindowsEnterSubmitState extends State<OmniWindowsEnterSubmit> {
  /// 接收弹窗打开后尚未落到子控件上的键盘焦点。
  final FocusNode _focusNode = FocusNode(
    debugLabel: 'OmniWindowsEnterSubmit',
    skipTraversal: true,
  );

  /// 初始化焦点作用域并在首帧后补齐弹窗焦点。
  @override
  void initState() {
    super.initState();
    _scheduleFocusRequest();
  }

  /// 在提交回调从禁用恢复时重新检查弹窗焦点。
  @override
  void didUpdateWidget(covariant OmniWindowsEnterSubmit oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.onSubmit == null && widget.onSubmit != null) {
      _scheduleFocusRequest();
    }
  }

  /// 在当前帧结束后让无子级焦点的 Windows 弹窗接收键盘事件。
  void _scheduleFocusRequest() {
    WidgetsBinding.instance.addPostFrameCallback((Duration timeStamp) {
      if (mounted &&
          defaultTargetPlatform == TargetPlatform.windows &&
          widget.onSubmit != null &&
          !_focusNode.hasFocus) {
        _focusNode.requestFocus();
      }
    });
  }

  /// 处理从子级焦点冒泡的键盘事件。
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (defaultTargetPlatform != TargetPlatform.windows ||
        widget.onSubmit == null ||
        event is! KeyDownEvent ||
        (event.logicalKey != LogicalKeyboardKey.enter &&
            event.logicalKey != LogicalKeyboardKey.numpadEnter) ||
        HardwareKeyboard.instance.isShiftPressed ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    widget.onSubmit!();
    return KeyEventResult.handled;
  }

  /// 释放提交作用域焦点节点。
  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  /// 构建可接收子级冒泡键盘事件的焦点作用域。
  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _handleKeyEvent,
      child: widget.child,
    );
  }
}
