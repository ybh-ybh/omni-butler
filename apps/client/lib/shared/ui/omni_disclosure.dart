import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

/// 标记展开入口：保留原生交互，只取消入口本身的按压缩放。
class OmniDisclosureToggle extends StatelessWidget {
  /// 当前展开状态；没有可展开内容时为空。
  final bool? expanded;

  /// 原按钮或点击行。
  final Widget child;

  /// 创建具有展开语义的原尺寸入口。
  const OmniDisclosureToggle({
    required this.expanded,
    required this.child,
    super.key,
  });

  /// 仅最近的交互宿主消费标记，行内其他按钮保留各自反馈。
  static bool suppressesPress(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_DisclosurePressScope>()
          ?.suppress ??
      false;

  /// 消费入口标记后恢复后代独立按钮的常规反馈。
  static Widget consume({required Widget child}) =>
      _DisclosurePressScope(suppress: false, child: child);

  /// 原生语义、焦点和点击回调仍由原控件负责。
  @override
  Widget build(BuildContext context) => Semantics(
    expanded: expanded,
    child: _DisclosurePressScope(suppress: expanded != null, child: child),
  );
}

/// 只向最近的交互宿主传递展开入口标记。
class _DisclosurePressScope extends InheritedWidget {
  /// 是否取消当前入口缩放。
  final bool suppress;

  /// 创建不改变几何的交互标记。
  const _DisclosurePressScope({required this.suppress, required super.child});

  /// 入口用途变化时立即同步动画开关。
  @override
  bool updateShouldNotify(_DisclosurePressScope oldWidget) =>
      suppress != oldWidget.suppress;
}

/// 从顶部向下展开、向上收起，快速反向点击从当前高度接续。
class OmniDisclosure extends StatefulWidget {
  /// 业务持有的展开状态。
  final bool expanded;

  /// 展开区域内容。
  final Widget child;

  /// 表单等区域收起后仍需保留输入和校验注册。
  final bool maintainState;

  /// 长列表采用 Sliver 裁剪，内部明细仍按视口惰性构建。
  final bool _sliver;

  /// 创建共享垂直展开区域。
  const OmniDisclosure({
    required this.expanded,
    required this.child,
    this.maintainState = false,
    super.key,
  }) : _sliver = false;

  /// 创建不将长列表整体转为普通盒子的展开区域。
  const OmniDisclosure.sliver({
    required this.expanded,
    required this.child,
    super.key,
  }) : maintainState = false,
       _sliver = true;

  /// 校验定位等待折叠区实际展开，避免按零高度计算错误滚动位置。
  static Future<void> ensureVisible(
    BuildContext context, {
    double alignment = .1,
  }) async {
    // 字段所在的最近展开区域；普通字段可直接定位。
    final _OmniDisclosureState? disclosure = context
        .findAncestorStateOfType<_OmniDisclosureState>();
    if (disclosure != null &&
        disclosure.widget.expanded &&
        !disclosure._controller.isCompleted) {
      try {
        await disclosure._controller.forward().orCancel;
      } on TickerCanceled {
        return;
      }
    }
    if (context.mounted) {
      await Scrollable.ensureVisible(context, alignment: alignment);
    }
  }

  /// 创建保留退出内容与动画进度的状态。
  @override
  State<OmniDisclosure> createState() => _OmniDisclosureState();
}

/// 收起完成前保留子树，避免内容先消失再收缩空白。
class _OmniDisclosureState extends State<OmniDisclosure>
    with SingleTickerProviderStateMixin {
  /// 可随时反向的高度进度。
  late final AnimationController _controller;

  /// 应用统一缓动后的展开比例。
  late final Animation<double> _height;

  /// 创建真实高度控制器，不缩放文字或图标。
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      value: widget.expanded ? 1 : 0,
    )..addStatusListener(_handleStatus);
    _height = _controller.drive(CurveTween(curve: OmniMotion.standardCurve));
  }

  /// 系统减少动画偏好改变时立即应用目标高度。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _animate();
  }

  /// 展开状态变化后从当前可见高度继续。
  @override
  void didUpdateWidget(OmniDisclosure oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded != oldWidget.expanded) _animate();
  }

  /// 减少动画使用即时状态，其他情况沿原进度切换方向。
  void _animate() {
    _controller.duration = OmniMotion.duration(context, OmniMotion.panel);
    if (OmniMotion.reduce(context)) {
      _controller.value = widget.expanded ? 1 : 0;
    } else if (widget.expanded) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  /// 收起终点卸载或隐藏正文，逐帧更新只改变裁剪高度。
  void _handleStatus(AnimationStatus status) {
    if (mounted && status == AnimationStatus.dismissed) setState(() {});
  }

  /// 隐藏区域立即退出命中、聚焦和语义，表单可单独保留状态。
  @override
  Widget build(BuildContext context) {
    if (widget._sliver) {
      return AnimatedBuilder(
        animation: _height,
        child: ExcludeFocus(excluding: !widget.expanded, child: widget.child),
        builder: (context, child) => !widget.expanded && _controller.isDismissed
            ? const SliverToBoxAdapter(child: SizedBox.shrink())
            : _DisclosureSliver(
                progress: _height.value,
                expanded: widget.expanded,
                sliver: child!,
              ),
      );
    }
    return AnimatedBuilder(
      animation: _height,
      builder: (context, child) => ClipRect(
        child: Align(
          alignment: Alignment.topCenter,
          heightFactor: _height.value,
          child: child,
        ),
      ),
      child: Visibility(
        visible: widget.expanded || !_controller.isDismissed,
        maintainState: widget.maintainState,
        child: IgnorePointer(
          ignoring: !widget.expanded,
          child: ExcludeFocus(
            excluding: !widget.expanded,
            child: ExcludeSemantics(
              excluding: !widget.expanded,
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }

  /// 释放动画监听与控制器。
  @override
  void dispose() {
    _controller.removeStatusListener(_handleStatus);
    _controller.dispose();
    super.dispose();
  }
}

/// 只裁剪 Sliver 的总高度，不缩小内部各行的布局高度。
class _DisclosureSliver extends SingleChildRenderObjectWidget {
  /// 已缓动的展开进度。
  final double progress;

  /// 收起开始即停用隐藏内容的命中和语义。
  final bool expanded;

  /// 使用原 SliverList 执行视口附近的布局。
  const _DisclosureSliver({
    required this.progress,
    required this.expanded,
    required Widget sliver,
  }) : super(child: sliver);

  /// 创建仅改变组高度和裁剪范围的渲染宿主。
  @override
  _RenderDisclosureSliver createRenderObject(BuildContext context) =>
      _RenderDisclosureSliver(progress, expanded);

  /// 每帧仅使 Sliver 几何与裁剪失效。
  @override
  void updateRenderObject(
    BuildContext context,
    _RenderDisclosureSliver renderObject,
  ) {
    renderObject
      ..progress = progress
      ..expanded = expanded
      ..markNeedsLayout()
      ..markNeedsSemanticsUpdate();
  }
}

/// 组高度随进度变化，列表继续使用未经压缩的视口约束。
class _RenderDisclosureSliver extends RenderProxySliver {
  /// 当前可见高度比例。
  double progress;

  /// 是否允许子项交互。
  bool expanded;

  /// 初始化可反向的组裁剪。
  _RenderDisclosureSliver(this.progress, this.expanded);

  /// 使用列表原始布局估算总高度，并将可见部分限制在展开边界内。
  @override
  void performLayout() {
    child!.layout(constraints, parentUsesSize: true);
    // 原生列表提供的惰性布局几何。
    final SliverGeometry original = child!.geometry!;
    if (original.scrollOffsetCorrection != null) {
      geometry = original;
      return;
    }
    // 展开区域整体占用高度，内部各行仍保持原字号与高度。
    final double extent = original.scrollExtent * progress;
    // 当前滚动位置实际可绘制的组内容范围。
    final double paintExtent = calculatePaintOffset(
      constraints,
      from: 0,
      to: extent,
    ).clamp(0, original.paintExtent);
    geometry = original.copyWith(
      scrollExtent: extent,
      paintExtent: paintExtent,
      layoutExtent: original.layoutExtent.clamp(0, paintExtent),
      maxPaintExtent: original.maxPaintExtent * progress,
      cacheExtent: calculateCacheOffset(
        constraints,
        from: 0,
        to: extent,
      ).clamp(0, original.cacheExtent),
      hitTestExtent: expanded ? paintExtent : 0,
      hasVisualOverflow: true,
    );
  }

  /// 子项按原尺寸绘制，末端随展开高度向下或向上移动。
  @override
  void paint(PaintingContext context, Offset offset) {
    if (geometry!.paintExtent == 0) return;
    context.pushClipRect(
      needsCompositing,
      offset,
      Rect.fromLTWH(0, 0, constraints.crossAxisExtent, geometry!.paintExtent),
      (context, offset) => context.paintChild(child!, offset),
    );
  }

  /// 收起期间不允许仍在退出画面中的按钮响应。
  @override
  bool hitTestChildren(
    SliverHitTestResult result, {
    required double mainAxisPosition,
    required double crossAxisPosition,
  }) =>
      expanded &&
      super.hitTestChildren(
        result,
        mainAxisPosition: mainAxisPosition,
        crossAxisPosition: crossAxisPosition,
      );

  /// 收起立即从辅助功能树中移除明细。
  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (expanded) super.visitChildrenForSemantics(visitor);
  }
}
