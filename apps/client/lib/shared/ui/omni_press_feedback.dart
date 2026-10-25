import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

import 'omni_disclosure.dart';

/// 将原上下文手势的右键反馈交给行内容，避免缩放外层背景。
class OmniSecondaryPressScope extends InheritedWidget {
  /// 当前上下文手势控制器；空值表示反馈已由上层内容消费。
  final OmniPressController? controller;

  /// 不创建额外手势，仅传递现有右键状态。
  const OmniSecondaryPressScope({
    required this.controller,
    required super.child,
    super.key,
  });

  /// 查找最近且尚未被内容层消费的右键控制器。
  static OmniPressController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<OmniSecondaryPressScope>()
      ?.controller;

  /// 仅在交互宿主更换时更新内容订阅。
  @override
  bool updateShouldNotify(OmniSecondaryPressScope oldWidget) =>
      controller != oldWidget.controller;
}

/// 为未使用整行InkWell的内容标记右键缩放边界，背景由调用方保留在外层。
class OmniSecondaryPressContent extends StatelessWidget {
  /// 同一项内需要整体缩放的图文和控件。
  final Widget child;

  /// 创建不改变布局和命中的纯视觉边界。
  const OmniSecondaryPressContent({required this.child, super.key});

  /// 只消费一次上下文反馈，后代按钮不会重复叠加同一右键缩放。
  @override
  Widget build(BuildContext context) {
    // 原上下文手势持有的控制器。
    final OmniPressController? secondary = OmniSecondaryPressScope.maybeOf(
      context,
    );
    if (secondary == null ||
        Theme.of(context).platform != TargetPlatform.windows) {
      return child;
    }
    return OmniSecondaryPressScope(
      controller: null,
      child: OmniPressContent(controller: secondary, child: child),
    );
  }
}

/// 业务适配器使用的简短反馈类型名。
typedef OmniPressFeedback = OmniPressController;

/// 只控制内容的 Windows 按压动画，不保存或延迟业务回调。
class OmniPressController extends ChangeNotifier {
  /// 原生控件使用的唯一状态控制器。
  final WidgetStatesController statesController;

  /// 可被后续按压接管的视觉压缩进度。
  final AnimationController _animation;

  /// 是否由本控制器负责释放原生状态。
  final bool _ownsStates;

  /// 当前是否允许 Windows 动画。
  bool _enabled = false;

  /// 当前原生控件是否按住。
  bool _pressed = false;

  /// 本轮已完成压缩时松手只恢复，不补播第二次压下。
  bool _reachedCompression = false;

  /// 后续动作使旧动画完成回调失效。
  int _generation = 0;

  /// 控制器是否已经释放。
  bool _disposed = false;

  /// 创建共享状态与动画控制器。
  OmniPressController({
    required TickerProvider vsync,
    WidgetStatesController? statesController,
  }) : statesController = statesController ?? WidgetStatesController(),
       _ownsStates = statesController == null,
       _animation = AnimationController(vsync: vsync) {
    this.statesController.addListener(_readStates);
    _animation.addListener(_handleAnimation);
  }

  /// 当前内容比例，布局与命中区域始终保持原值。
  double get scale => 1 - (1 - OmniMotion.windowsPressScale) * _animation.value;

  /// 记录已经呈现的压缩终点，同时通知纯视觉内容。
  void _handleAnimation() {
    if (_animation.value == 1) _reachedCompression = true;
    if (_animation.value == 0 && !_pressed) _reachedCompression = false;
    notifyListeners();
  }

  /// 同步平台与系统减少动画偏好。
  void configure({required bool enabled}) {
    if (_enabled == enabled) return;
    _enabled = enabled;
    if (!enabled) {
      _generation++;
      _pressed = false;
      _animation.value = 0;
    }
  }

  /// 捕获包括语义激活在内的同步状态边沿。
  void _readStates() {
    if (statesController.value.contains(WidgetState.disabled)) {
      cancel(immediate: true);
      return;
    }
    setPressed(statesController.value.contains(WidgetState.pressed));
  }

  /// 使用原生手势状态启动按下或释放，不增加手势识别器。
  void setPressed(bool pressed) {
    if (!_enabled || _disposed || _pressed == pressed) return;
    _pressed = pressed;
    if (pressed) _reachedCompression = _animation.value == 1;
    _generation++;
    _animation.animateTo(
      pressed ? 1 : 0,
      duration: pressed
          ? OmniMotion.windowsPressDown
          : OmniMotion.windowsPressRelease,
      curve: OmniMotion.standardCurve,
    );
  }

  /// 成功的快速点击补足短压缩；调用方随即执行原业务，无需等待。
  void activate() {
    if (!_enabled ||
        _disposed ||
        _pressed ||
        _reachedCompression ||
        statesController.value.contains(WidgetState.disabled)) {
      return;
    }
    // 只有本次点击可以在压缩完成后恢复。
    final int generation = ++_generation;
    _animation
        .animateTo(
          1,
          duration: Duration(
            microseconds:
                (OmniMotion.windowsPressDown.inMicroseconds *
                        (1 - _animation.value))
                    .round(),
          ),
          curve: OmniMotion.standardCurve,
        )
        .whenCompleteOrCancel(() {
          if (_disposed || generation != _generation || _pressed) return;
          _animation.animateTo(
            0,
            duration: OmniMotion.windowsPressRelease,
            curve: OmniMotion.standardCurve,
          );
        });
  }

  /// 取消直接从当前值恢复，禁用时立即清除反馈。
  void cancel({bool immediate = false}) {
    if (_disposed) return;
    _generation++;
    _pressed = false;
    if (immediate || !_enabled) {
      _animation.value = 0;
    } else {
      _animation.animateTo(
        0,
        duration: OmniMotion.windowsPressRelease,
        curve: OmniMotion.standardCurve,
      );
    }
  }

  /// 原生按钮的前景构建入口，只包装文字与图标。
  Widget foregroundBuilder(
    BuildContext context,
    Set<WidgetState> states,
    Widget? child,
  ) => OmniPressContent(
    controller: this,
    child: child ?? const SizedBox.shrink(),
  );

  /// 释放动画和自身创建的原生状态控制器。
  @override
  void dispose() {
    _disposed = true;
    _generation++;
    statesController.removeListener(_readStates);
    _animation.dispose();
    if (_ownsStates) statesController.dispose();
    super.dispose();
  }
}

/// 缩放内部内容，原尺寸和命中位置不随绘制变化。
class OmniPressContent extends StatelessWidget {
  /// 所属交互的动画控制器。
  final OmniPressController controller;

  /// 保持身份的业务内容。
  final Widget child;

  /// 创建纯视觉按压内容。
  const OmniPressContent({
    super.key,
    required this.controller,
    required this.child,
  });

  /// 只改变绘制变换，不创建手势或语义操作。
  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).platform != TargetPlatform.windows) return child;
    // 上层上下文手势控制右键，本控件的原生状态继续控制左键。
    final OmniPressController? secondary = OmniSecondaryPressScope.maybeOf(
      context,
    );
    return AnimatedBuilder(
      animation: secondary == null
          ? controller
          : Listenable.merge(<Listenable>[controller, secondary]),
      child: secondary == null
          ? child
          : OmniSecondaryPressScope(controller: null, child: child),
      builder: (context, child) => Transform.scale(
        scale: secondary != null && secondary.scale < controller.scale
            ? secondary.scale
            : controller.scale,
        transformHitTests: false,
        child: child,
      ),
    );
  }
}

/// 为原生按钮和自定义控件管理同一套按压状态。
class OmniPressBinding extends StatefulWidget {
  /// 构建原交互，并将控制器传入内容层。
  final Widget Function(BuildContext context, OmniPressController feedback)
  builder;

  /// 调用方已有的原生状态控制器。
  final WidgetStatesController? statesController;

  /// 是否允许反馈，禁用不改变原业务控件的状态。
  final bool enabled;

  /// 创建可供各种原生控件使用的状态桥接。
  const OmniPressBinding({
    super.key,
    required this.builder,
    this.statesController,
    this.enabled = true,
  });

  /// 创建独立动画生命周期。
  @override
  State<OmniPressBinding> createState() => _OmniPressBindingState();
}

/// 在主题、禁用状态和外部状态控制器变化时同步动画。
class _OmniPressBindingState extends State<OmniPressBinding>
    with TickerProviderStateMixin {
  /// 当前交互的反馈控制器。
  late OmniPressController _feedback;

  /// 初始化唯一的反馈控制器。
  @override
  void initState() {
    super.initState();
    _feedback = OmniPressController(
      vsync: this,
      statesController: widget.statesController,
    );
  }

  /// 平台和辅助功能变化时立即更新动画开关。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _configure();
  }

  /// 外部控制器替换时安全迁移所有权。
  @override
  void didUpdateWidget(OmniPressBinding oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.statesController != widget.statesController) {
      _feedback.dispose();
      _feedback = OmniPressController(
        vsync: this,
        statesController: widget.statesController,
      );
    }
    _configure();
  }

  /// 只在 Windows 且系统允许动画时启用。
  void _configure() => _feedback.configure(
    enabled:
        widget.enabled &&
        !OmniDisclosureToggle.suppressesPress(context) &&
        Theme.of(context).platform == TargetPlatform.windows &&
        !OmniMotion.reduce(context),
  );

  /// 构建原生交互树。
  @override
  Widget build(BuildContext context) =>
      OmniDisclosureToggle.consume(child: widget.builder(context, _feedback));

  /// 移除所有在途动画，不留下延迟业务回调。
  @override
  void dispose() {
    _feedback.dispose();
    super.dispose();
  }
}

/// 保留 InkWell 的唯一识别器与嵌套排他行为，只缩放内部内容。
class OmniInkWell extends InkWell {
  /// 创建与原生 InkWell 属性兼容的按压入口。
  const OmniInkWell({
    super.key,
    super.child,
    super.onTap,
    super.onDoubleTap,
    super.onLongPress,
    super.onLongPressUp,
    super.onTapDown,
    super.onTapUp,
    super.onTapCancel,
    super.onSecondaryTap,
    super.onSecondaryTapUp,
    super.onSecondaryTapDown,
    super.onSecondaryTapCancel,
    super.onHighlightChanged,
    super.onHover,
    super.mouseCursor,
    super.focusColor,
    super.hoverColor,
    super.highlightColor,
    super.overlayColor,
    super.splashColor,
    super.splashFactory,
    super.radius,
    super.borderRadius,
    super.customBorder,
    super.enableFeedback,
    super.excludeFromSemantics,
    super.focusNode,
    super.canRequestFocus,
    super.onFocusChange,
    super.autofocus,
    super.statesController,
    super.hoverDuration,
  });

  /// 原生状态负责按下，业务激活只补足快速点击的可见帧。
  @override
  Widget build(BuildContext context) => OmniPressBinding(
    statesController: statesController,
    enabled:
        onTap != null ||
        onDoubleTap != null ||
        onLongPress != null ||
        onSecondaryTap != null ||
        onSecondaryTapUp != null ||
        onSecondaryTapDown != null,
    builder: (context, feedback) => InkWell(
      onTap: onTap == null
          ? null
          : () {
              feedback.activate();
              onTap!();
            },
      onDoubleTap: onDoubleTap == null
          ? null
          : () {
              feedback.activate();
              onDoubleTap!();
            },
      onLongPress: onLongPress,
      onLongPressUp: onLongPressUp,
      onTapDown: onTapDown,
      onTapUp: onTapUp,
      onTapCancel: () {
        feedback.cancel();
        onTapCancel?.call();
      },
      onSecondaryTap:
          onSecondaryTap == null &&
              onSecondaryTapUp == null &&
              onSecondaryTapDown == null
          ? null
          : () {
              feedback.activate();
              onSecondaryTap?.call();
            },
      onSecondaryTapUp: onSecondaryTapUp,
      onSecondaryTapDown: onSecondaryTapDown,
      onSecondaryTapCancel: () {
        feedback.cancel();
        onSecondaryTapCancel?.call();
      },
      onHighlightChanged: onHighlightChanged,
      onHover: onHover,
      mouseCursor: mouseCursor,
      focusColor: focusColor,
      hoverColor: hoverColor,
      highlightColor: highlightColor,
      overlayColor: overlayColor,
      splashColor: splashColor,
      splashFactory: splashFactory,
      radius: radius,
      borderRadius: borderRadius,
      customBorder: customBorder,
      enableFeedback: enableFeedback,
      excludeFromSemantics: excludeFromSemantics,
      focusNode: focusNode,
      canRequestFocus: canRequestFocus,
      onFocusChange: onFocusChange,
      autofocus: autofocus,
      statesController: feedback.statesController,
      hoverDuration: hoverDuration,
      child: OmniPressContent(
        controller: feedback,
        child: child ?? const SizedBox.shrink(),
      ),
    ),
  );
}
