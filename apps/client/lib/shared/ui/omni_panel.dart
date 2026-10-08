import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

/// 为指定面板提供内部滚动控制器。
class OmniPanelScrollScope extends InheritedWidget {
  /// 面板内容使用的滚动控制器。
  final ScrollController controller;

  /// 正文末尾额外保留的滚动空间，例如悬浮操作按钮的避让区。
  final double bottomPadding;

  /// 是否让当前面板接入祖先的主滚动控制器。
  final bool usePrimaryScrollController;

  /// 切换滚动控制器时是否保留正文状态及当前位置。
  final bool preserveScrollState;

  /// 创建面板内部滚动作用域。
  const OmniPanelScrollScope({
    required this.controller,
    required super.child,
    this.bottomPadding = 0,
    this.usePrimaryScrollController = false,
    this.preserveScrollState = false,
    super.key,
  }) : assert(bottomPadding >= 0);

  /// 从当前上下文读取可选的面板滚动作用域。
  static OmniPanelScrollScope? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<OmniPanelScrollScope>();
  }

  /// 滚动控制器、避让空间或协调模式变化时通知面板重建。
  @override
  bool updateShouldNotify(OmniPanelScrollScope oldWidget) {
    return controller != oldWidget.controller ||
        bottomPadding != oldWidget.bottomPadding ||
        usePrimaryScrollController != oldWidget.usePrimaryScrollController ||
        preserveScrollState != oldWidget.preserveScrollState;
  }
}

/// 统一的清晰实底内容面板。
class OmniPanel extends StatelessWidget {
  /// 可选固定头部；自身间距由调用方控制，不随面板内容滚动。
  final Widget? header;

  /// 面板内容。
  final Widget child;

  /// 面板内边距。
  final EdgeInsetsGeometry padding;

  /// 可选外边距。
  final EdgeInsetsGeometry? margin;

  /// 可选点击回调。
  final VoidCallback? onTap;

  /// 是否裁剪面板内容。
  final Clip clipBehavior;

  /// 是否使用没有边框、圆角及独立底色的平铺外观。
  final bool flat;

  /// 创建统一内容面板。
  const OmniPanel({
    required this.child,
    this.header,
    this.padding = const EdgeInsets.all(OmniSpacing.md),
    this.margin,
    this.onTap,
    this.clipBehavior = Clip.antiAlias,
    this.flat = false,
    super.key,
  });

  /// 构建带边框和悬浮反馈的面板。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前面板可选的滚动契约。
    final OmniPanelScrollScope? scrollScope = OmniPanelScrollScope.maybeOf(
      context,
    );
    // 当前面板独立使用的滚动控制器。
    final ScrollController? scrollController = scrollScope?.controller;
    // 真正随正文一起滚动的底部避让空间。
    final EdgeInsets bottomPadding = EdgeInsets.only(
      bottom: scrollScope?.bottomPadding ?? 0,
    );
    // 可选的保活滚动宿主仅供需要切换主滚动协调模式的面板使用。
    final Widget? coordinatedContent =
        scrollScope != null &&
            (scrollScope.preserveScrollState ||
                scrollScope.usePrimaryScrollController)
        ? _OmniPanelScrollBody(
            controller: scrollScope.usePrimaryScrollController
                ? PrimaryScrollController.of(context)
                : scrollScope.controller,
            usePrimaryScrollController: scrollScope.usePrimaryScrollController,
            padding: header == null
                ? bottomPadding
                : padding.add(bottomPadding),
            child: child,
          )
        : null;
    // 面板内保持边框固定的内容区域。
    final Widget panelContent = header != null
        ? Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              header!,
              Flexible(
                fit: FlexFit.loose,
                child:
                    coordinatedContent ??
                    (scrollController == null
                        ? Padding(padding: padding, child: child)
                        : ScrollbarTheme(
                            data: ScrollbarTheme.of(context).copyWith(
                              crossAxisMargin: 2,
                              mainAxisMargin: OmniSpacing.xs,
                            ),
                            child: ScrollConfiguration(
                              behavior: ScrollConfiguration.of(context)
                                  .copyWith(scrollbars: false),
                              child: Scrollbar(
                                controller: scrollController,
                                child: SingleChildScrollView(
                                  controller: scrollController,
                                  primary: false,
                                  padding: padding.add(bottomPadding),
                                  child: child,
                                ),
                              ),
                            ),
                          )),
              ),
            ],
          )
        : coordinatedContent ??
              (scrollController == null
                  ? child
                  : Scrollbar(
                      controller: scrollController,
                      child: SingleChildScrollView(
                        controller: scrollController,
                        primary: false,
                        padding: bottomPadding.bottom == 0
                            ? null
                            : bottomPadding,
                        child: child,
                      ),
                    ));
    // 面板主体。
    final Widget panel = Material(
      color: flat ? Colors.transparent : colors.paper,
      clipBehavior: clipBehavior,
      shape: flat
          ? null
          : RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(OmniRadius.panel),
              side: BorderSide(color: colors.line),
            ),
      child: InkWell(
        onTap: onTap,
        hoverColor: colors.ink.withValues(alpha: 0.04),
        highlightColor: colors.ink.withValues(alpha: 0.08),
        focusColor: colors.brand.withValues(alpha: 0.12),
        child: header == null
            ? Padding(padding: padding, child: panelContent)
            : panelContent,
      ),
    );

    if (margin == null) {
      return panel;
    }
    return Padding(padding: margin!, child: panel);
  }
}

/// 在独立滚动和嵌套主滚动间切换时保留业务正文与滚动位置。
class _OmniPanelScrollBody extends StatefulWidget {
  /// 本次滚动实际接入的独立或嵌套主控制器。
  final ScrollController controller;

  /// 当前是否由外层嵌套滚动协调器管理手势。
  final bool usePrimaryScrollController;

  /// 随正文滚动的完整内边距。
  final EdgeInsetsGeometry padding;

  /// 不应因滚动模式切换而重新创建的业务正文。
  final Widget child;

  /// 创建可切换滚动模式的正文宿主。
  const _OmniPanelScrollBody({
    required this.controller,
    required this.usePrimaryScrollController,
    required this.padding,
    required this.child,
  });

  /// 创建正文身份与滚动控制器桥接状态。
  @override
  State<_OmniPanelScrollBody> createState() => _OmniPanelScrollBodyState();
}

/// 让滚动视口重建，而业务正文可以在同一帧迁移到新视口。
class _OmniPanelScrollBodyState extends State<_OmniPanelScrollBody> {
  /// 保持卡片正文中展开、筛选等局部状态的稳定身份。
  final GlobalKey _contentKey = GlobalKey();

  /// 当前视口独享的桥接控制器，始终只关联一个滚动位置。
  late _OmniPanelScrollController _controller;

  /// 等待旧滚动视口解除关联后才能释放的控制器。
  final List<_OmniPanelScrollController> _retiredControllers =
      <_OmniPanelScrollController>[];

  /// 初始化当前控制器，沿用调用方的初始滚动位置。
  @override
  void initState() {
    super.initState();
    _controller = _OmniPanelScrollController(
      delegate: widget.controller,
      restoredOffset: widget.controller.initialScrollOffset,
    );
  }

  /// 控制器变化时重建视口，避免把普通位置交给嵌套控制器。
  @override
  void didUpdateWidget(covariant _OmniPanelScrollBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) {
      return;
    }
    // 换绑前的真实位置，同时覆盖尚未结束的滚动动画。
    final double offset = _controller.hasClients
        ? _controller.position.pixels
        : _controller.restoredOffset;
    // 旧视口会在本帧重建时解绑，延后释放其控制器。
    final _OmniPanelScrollController retiredController = _controller;
    _retiredControllers.add(retiredController);
    _controller = _OmniPanelScrollController(
      delegate: widget.controller,
      restoredOffset: offset,
    );
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (_retiredControllers.remove(retiredController)) {
        retiredController.dispose();
      }
    });
  }

  /// 释放宿主持有的桥接控制器，不释放调用方的控制器。
  @override
  void dispose() {
    _controller.dispose();
    // 同帧离开页面时一起清理尚未释放的旧控制器。
    for (final _OmniPanelScrollController controller in _retiredControllers) {
      controller.dispose();
    }
    _retiredControllers.clear();
    super.dispose();
  }

  /// 构建可安全切换控制器、正文保持身份的滚动视口。
  @override
  Widget build(BuildContext context) {
    // 控制器身份变化时替换视口，正文通过全局键迁移并保留状态。
    final Widget scrollView = SingleChildScrollView(
      key: ObjectKey(_controller),
      controller: _controller,
      primary: false,
      physics: widget.usePrimaryScrollController
          ? const AlwaysScrollableScrollPhysics()
          : null,
      padding: widget.padding,
      child: PrimaryScrollController.none(
        child: KeyedSubtree(key: _contentKey, child: widget.child),
      ),
    );
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: widget.usePrimaryScrollController
          ? scrollView
          : Scrollbar(controller: _controller, child: scrollView),
    );
  }
}

/// 使用目标控制器创建兼容位置，并在首次布局前恢复原有偏移。
class _OmniPanelScrollController extends ScrollController {
  /// 真正接收滚动位置的独立或嵌套主控制器。
  final ScrollController delegate;

  /// 新视口首次布局前应恢复的滚动位置。
  final double restoredOffset;

  /// 创建不拥有外部控制器生命周期的桥接控制器。
  _OmniPanelScrollController({
    required this.delegate,
    required this.restoredOffset,
  }) : super(keepScrollOffset: false);

  /// 由目标控制器创建正确类型的位置，恢复时不触发外层头部跳动。
  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    // 使用目标工厂，确保嵌套控制器始终收到兼容的位置类型。
    final ScrollPosition position = delegate.createScrollPosition(
      physics,
      context,
      oldPosition,
    );
    if (oldPosition == null) {
      position.correctPixels(restoredOffset);
    }
    return position;
  }

  /// 同时登记到宿主和目标控制器，维持嵌套滚动协调关系。
  @override
  void attach(ScrollPosition position) {
    super.attach(position);
    delegate.attach(position);
  }

  /// 同时解除两端的位置关联，不接管外部控制器的生命周期。
  @override
  void detach(ScrollPosition position) {
    delegate.detach(position);
    super.detach(position);
  }
}

/// 统一的连续列表面板。
class OmniListPanel extends StatelessWidget {
  /// 列表行。
  final List<Widget> children;

  /// 创建连续列表面板。
  const OmniListPanel({required this.children, super.key});

  /// 构建自动插入分隔线的连续列表。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 含分隔线的列表内容。
    final List<Widget> separated = <Widget>[];
    for (int index = 0; index < children.length; index += 1) {
      if (index > 0) {
        separated.add(Divider(color: colors.line));
      }
      separated.add(children[index]);
    }
    return OmniPanel(
      padding: EdgeInsets.zero,
      child: Column(mainAxisSize: MainAxisSize.min, children: separated),
    );
  }
}

/// 统一的紧凑列表行。
class OmniListRow extends StatelessWidget {
  /// 可选前置区域。
  final Widget? leading;

  /// 主标题。
  final Widget title;

  /// 可选辅助内容。
  final Widget? subtitle;

  /// 可选尾部操作。
  final Widget? trailing;

  /// 点击回调。
  final VoidCallback? onTap;

  /// 行内边距。
  final EdgeInsetsGeometry padding;

  /// 前置区域与主内容之间的间距。
  final double leadingGap;

  /// 可选的行背景与水波纹圆角。
  final BorderRadius? borderRadius;

  /// 创建紧凑列表行。
  const OmniListRow({
    required this.title,
    this.leading,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(
      horizontal: OmniSpacing.md,
      vertical: OmniSpacing.sm,
    ),
    this.leadingGap = OmniSpacing.sm,
    this.borderRadius,
    super.key,
  });

  /// 构建支持悬浮和键盘焦点的列表行。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 行内容。
    final Widget content = Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          if (leading != null) ...<Widget>[
            leading!,
            SizedBox(width: leadingGap),
          ],
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                DefaultTextStyle.merge(
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w400),
                  child: title,
                ),
                if (subtitle != null) ...<Widget>[
                  const SizedBox(height: OmniSpacing.xxs),
                  DefaultTextStyle.merge(
                    style: Theme.of(context).textTheme.bodySmall,
                    child: subtitle!,
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...<Widget>[
            const SizedBox(width: OmniSpacing.sm),
            trailing!,
          ],
        ],
      ),
    );

    return Material(
      color: Colors.transparent,
      borderRadius: borderRadius,
      clipBehavior: borderRadius == null ? Clip.none : Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: borderRadius,
        hoverColor: colors.ink.withValues(alpha: 0.04),
        highlightColor: colors.ink.withValues(alpha: 0.08),
        focusColor: colors.brand.withValues(alpha: 0.12),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: OmniDensity.controlHeight(context, large: true),
          ),
          child: content,
        ),
      ),
    );
  }
}
