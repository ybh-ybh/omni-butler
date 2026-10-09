import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/features/home/data/home_card_preferences.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 安卓首页的固定名言、平铺分页和独立纵向阅读区域。
class HomeMobileDashboard extends StatefulWidget {
  /// 已启用且业务可用的模块顺序。
  final List<HomeCardId> visibleCards;

  /// 沿用业务状态与操作的模块内容。
  final Map<HomeCardId, Widget> cards;

  /// 打开首页设置。
  final VoidCallback onManageCards;

  /// 为悬浮操作预留的正文末尾空间。
  final double bottomPadding;

  /// 创建安卓首页分页布局。
  const HomeMobileDashboard({
    required this.visibleCards,
    required this.cards,
    required this.onManageCards,
    required this.bottomPadding,
    super.key,
  });

  /// 创建会话内分页与顶部测量状态。
  @override
  State<HomeMobileDashboard> createState() => _HomeMobileDashboardState();
}

/// 按稳定模块身份保留选择，并协调短视口的顶部收起。
class _HomeMobileDashboardState extends State<HomeMobileDashboard> {
  /// 首页自己的横向分页，不接力一级导航。
  final PageController _pageController = PageController();

  /// 短视口中只负责让顶部横幅滚出的外层控制器。
  final ScrollController _outerController = ScrollController();

  /// 上次排版是否允许收起顶部，用于恢复标准视口的位置。
  bool _collapsible = true;

  /// 保持顶部业务子树在固定与可收起模式之间的身份。
  final GlobalKey _headerKey = GlobalKey();

  /// 当前选择的稳定模块身份。
  HomeCardId? _selected;

  /// 顶部真实排版高度，包含名言与用户字体缩放。
  double? _headerHeight;

  /// 重排后的待对齐页码，防止旧滚动通知覆盖当前选择。
  int? _pendingPage;

  /// 排除顶部名言后的可分页模块。
  List<HomeCardId> get _pages => widget.visibleCards
      .where((HomeCardId card) => card != HomeCardId.quote)
      .toList(growable: false);

  /// 首次进入按用户保存的顺序选中第一页。
  @override
  void initState() {
    super.initState();
    _selected = _pages.firstOrNull;
  }

  /// 模块变化时保留身份，删除当前项则选原位置上的相邻项。
  @override
  void didUpdateWidget(covariant HomeMobileDashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 更新前的内容页顺序。
    final List<HomeCardId> oldPages = oldWidget.visibleCards
        .where((HomeCardId card) => card != HomeCardId.quote)
        .toList(growable: false);
    // 更新后的内容页顺序。
    final List<HomeCardId> pages = _pages;
    if (listEquals(oldPages, pages)) return;
    if (!pages.contains(_selected)) {
      // 删除后优先选择同一索引，末项删除时退到前一项。
      final int adjacent = oldPages
          .indexOf(_selected ?? HomeCardId.quote)
          .clamp(0, math.max(0, pages.length - 1));
      _selected = pages.isEmpty ? null : pages[adjacent];
    }
    _pendingPage = pages.isEmpty ? null : pages.indexOf(_selected!);
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted || _pendingPage == null) return;
      if (_pageController.hasClients) {
        _pageController.jumpToPage(_pendingPage!);
      }
      setState(() => _pendingPage = null);
    });
  }

  /// 释放分页控制器。
  @override
  void dispose() {
    _pageController.dispose();
    _outerController.dispose();
    super.dispose();
  }

  /// 接收布局完成后的真实顶部高度。
  void _onHeaderSize(Size size) {
    if (!mounted || _headerHeight == size.height) return;
    setState(() => _headerHeight = size.height);
  }

  /// 标签选择与正文横滑使用同一个分页控制器。
  void _selectPage(int index) {
    if (!_pageController.hasClients || _pendingPage != null) return;
    if (OmniMotion.reduce(context)) {
      _pageController.jumpToPage(index);
    } else {
      unawaited(
        _pageController.animateToPage(
          index,
          duration: OmniMotion.panel,
          curve: OmniMotion.standardCurve,
        ),
      );
    }
  }

  /// 消费首页非分页区域的水平手势，防止触发外层一级横滑。
  void _consumeHorizontalDrag(DragStartDetails details) {}

  /// 构建连续实底首页及必要时可向上收起的顶部。
  @override
  Widget build(BuildContext context) {
    // 当前实际可用的模块。
    final List<HomeCardId> pages = _pages;
    // 统一页面底色。
    final OmniColors colors = OmniColors.of(context);
    // 与待办导航使用相同字体、视觉高度与系统字号测量。
    final double pillHeight = math.max(
      OmniSize.control,
      MediaQuery.textScalerOf(context)
                  .scale(Theme.of(context).textTheme.titleSmall!.fontSize!) *
              1.4 +
          OmniSpacing.xs,
    );
    // 标签随字号增长，始终保留最小触控高度。
    final double tabHeight = pages.length > 1
        ? math.max(OmniSize.touch, pillHeight + OmniSpacing.xs) +
              OmniSpacing.xxs * 2
        : 0;
    // 正文至少容纳分组标题及一行触控内容。
    final double minimumBodyHeight =
        math.max(34, MediaQuery.textScalerOf(context).scale(20) * 1.4) +
        OmniSpacing.md +
        OmniSpacing.xs +
        OmniSize.touch;
    return GestureDetector(
      key: const ValueKey<String>('home-mobile-gesture-boundary'),
      behavior: HitTestBehavior.opaque,
      // 此边界没有可执行的读屏动作，业务语义由内部控件独立提供。
      excludeFromSemantics: true,
      onHorizontalDragStart: _consumeHorizontalDrag,
      child: ColoredBox(
        color: colors.paper,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            // 首帧先使用可收起布局，避免测量完成前在极短视口溢出。
            final bool collapsible =
                _headerHeight == null ||
                constraints.maxHeight - _headerHeight! - tabHeight <
                    minimumBodyHeight;
            if (_collapsible != collapsible) {
              _collapsible = collapsible;
              if (!collapsible) {
                WidgetsBinding.instance.addPostFrameCallback((Duration _) {
                  if (mounted && !_collapsible && _outerController.hasClients) {
                    // 正文已换回独立控制器，复位顶部不会重置各模块位置。
                    _outerController.jumpTo(0);
                  }
                });
              }
            }
            // 名言沿用原有水平边距与自然尺寸。
            final Widget header = _HomeHeaderMeasure(
              key: _headerKey,
              onSize: _onHeaderSize,
              child: ColoredBox(
                color: colors.paper,
                child: Padding(
                  key: const ValueKey<String>('home-mobile-header'),
                  padding: const EdgeInsets.fromLTRB(
                    14,
                    OmniSpacing.xs,
                    14,
                    OmniSpacing.xs,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      if (widget.visibleCards.contains(HomeCardId.quote))
                        widget.cards[HomeCardId.quote]!,
                    ],
                  ),
                ),
              ),
            );
            return NestedScrollView(
              key: const ValueKey<String>('home-mobile-vertical-layout'),
              controller: _outerController,
              physics: collapsible
                  ? const ClampingScrollPhysics()
                  : const NeverScrollableScrollPhysics(),
              scrollBehavior: ScrollConfiguration.of(context).copyWith(
                scrollbars: false,
                // 嵌套协调器可能保留旧拖拽状态，标准视口显式关闭外层输入。
                dragDevices: collapsible ? null : const <PointerDeviceKind>{},
              ),
              headerSliverBuilder: (BuildContext context, bool innerScrolled) =>
                  <Widget>[SliverToBoxAdapter(child: header)],
              body: LayoutBuilder(
                builder:
                    (BuildContext context, BoxConstraints bodyConstraints) {
                      // 横幅很长时正文可暂在视口下方，但仍以可读高度正常布局。
                      final double bodyHeight = math.max(
                        bodyConstraints.maxHeight,
                        minimumBodyHeight + tabHeight,
                      );
                      return OverflowBox(
                        alignment: Alignment.topCenter,
                        minHeight: bodyHeight,
                        maxHeight: bodyHeight,
                        child: Column(
                          children: <Widget>[
                            if (pages.length > 1)
                              _HomeModuleTabs(
                                pages: pages,
                                selected: _selected!,
                                pageController: _pageController,
                                pendingPage: _pendingPage,
                                height: tabHeight,
                                onSelected: _selectPage,
                              ),
                            Expanded(
                              child: pages.isEmpty
                                  ? _HomeModuleViewport(
                                      key: const ValueKey<String>(
                                        'home-mobile-page-empty',
                                      ),
                                      bottomPadding: widget.bottomPadding,
                                      coordinated: collapsible,
                                      child: OmniPanel(
                                        key: const ValueKey<String>(
                                          'home-dashboard-empty',
                                        ),
                                        flat: true,
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: <Widget>[
                                            const SizedBox(
                                              height: OmniSpacing.xl,
                                            ),
                                            Text(
                                              '还没有显示的内容',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium,
                                            ),
                                            const SizedBox(
                                              height: OmniSpacing.sm,
                                            ),
                                            OmniButton(
                                              label: '首页设置',
                                              icon: Icons.tune_rounded,
                                              onPressed: widget.onManageCards,
                                            ),
                                          ],
                                        ),
                                      ),
                                    )
                                  : PageView(
                                      key: const ValueKey<String>(
                                        'home-mobile-pager',
                                      ),
                                      controller: _pageController,
                                      // 模块最多四项；完整预布局保证增删后页边界立即更新。
                                      allowImplicitScrolling: true,
                                      scrollCacheExtent:
                                          ScrollCacheExtent.viewport(
                                            pages.length.toDouble(),
                                          ),
                                      physics:
                                          const AlwaysScrollableScrollPhysics(
                                            parent: ClampingScrollPhysics(),
                                          ),
                                      onPageChanged: (int index) {
                                        if (_pendingPage == null &&
                                            index < pages.length) {
                                          setState(
                                            () => _selected = pages[index],
                                          );
                                        }
                                      },
                                      children: <Widget>[
                                        for (final HomeCardId card in pages)
                                          _HomeModuleViewport(
                                            key: ValueKey<String>(
                                              'home-mobile-page-${card.name}',
                                            ),
                                            bottomPadding: widget.bottomPadding,
                                            coordinated:
                                                collapsible &&
                                                _selected == card,
                                            child: widget.cards[card]!,
                                          ),
                                      ],
                                    ),
                            ),
                          ],
                        ),
                      );
                    },
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 与待办分类一致的胶囊模块导航。
class _HomeModuleTabs extends StatefulWidget {
  /// 可见模块的顺序。
  final List<HomeCardId> pages;

  /// 当前选中模块。
  final HomeCardId selected;

  /// 横向滚动位置，用于同步胶囊与标签展开。
  final PageController pageController;

  /// 模块重排后尚未应用的目标页。
  final int? pendingPage;

  /// 包含字号缩放的导航高度。
  final double height;

  /// 点按标签后的选择回调。
  final ValueChanged<int> onSelected;

  /// 创建首页胶囊导航。
  const _HomeModuleTabs({
    required this.pages,
    required this.selected,
    required this.pageController,
    required this.pendingPage,
    required this.height,
    required this.onSelected,
  });

  /// 创建标签独立滚动状态。
  @override
  State<_HomeModuleTabs> createState() => _HomeModuleTabsState();
}

/// 仅滚动导航自身，避免大字号标签定位改变正文。
class _HomeModuleTabsState extends State<_HomeModuleTabs> {
  /// 标签行专用的水平控制器。
  final ScrollController _scrollController = ScrollController();

  /// 防止过期布局回调覆盖当前模块的可见范围。
  String? _revealSignature;

  /// 返回适合手机导航的简短标签。
  String _label(HomeCardId card) => switch (card) {
    HomeCardId.todos => '待办',
    HomeCardId.timeStatus => '时间',
    HomeCardId.todayContext => '脉络',
    HomeCardId.dayRuler => '刻度',
    HomeCardId.quote => '名言',
  };

  /// 返回模块图标，收起项仍可识别用途。
  IconData _icon(HomeCardId card) => switch (card) {
    HomeCardId.todos => Icons.check_circle_outline_rounded,
    HomeCardId.timeStatus => Icons.schedule_rounded,
    HomeCardId.todayContext => Icons.hub_outlined,
    HomeCardId.dayRuler => Icons.straighten_rounded,
    HomeCardId.quote => Icons.format_quote_rounded,
  };

  /// 按实际字体和系统字号测量完整标签。
  double _labelWidth(HomeCardId card, TextStyle style, TextScaler scaler) {
    // 测量与绘制采用同一文字样式。
    final TextPainter painter = TextPainter(
      text: TextSpan(text: _label(card), style: style),
      textDirection: Directionality.of(context),
      textScaler: scaler,
    )..layout();
    // 保存结果后释放字体测量资源。
    final double width = painter.width;
    painter.dispose();
    return width;
  }

  /// 在布局后保证选中项的完整文字位于导航视口内。
  void _revealSelected(List<double> widths, double viewport, int selected) {
    if (viewport <= 0) return;
    // 模块顺序、字号和连续项宽共同决定本次滚动目标。
    final String signature =
        '${widget.pages}/$selected/$viewport/${widths.join(',')}';
    if (_revealSignature == signature) return;
    _revealSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted ||
          !_scrollController.hasClients ||
          _revealSignature != signature) {
        return;
      }
      // 当前项在整行内容中的起点。
      final double start = widths.take(selected).fold(0.0, (a, b) => a + b);
      // 包含展开标签的完整右边界。
      final double end = start + widths[selected];
      // 已保留的导航滚动位置。
      final double current = _scrollController.offset;
      // 只调整标签行，不触发祖先分页或纵向滚动。
      final double target =
          (start < current
                  ? start
                  : end > current + viewport
                  ? end - viewport
                  : current)
              .clamp(0, _scrollController.position.maxScrollExtent)
              .toDouble();
      _scrollController.jumpTo(target);
    });
  }

  /// 释放标签行控制器。
  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 构建常驻图标及随正文进度展开的标签。
  Widget _buildLabel(
    HomeCardId card,
    TextStyle style,
    TextScaler scaler,
    double labelWidth,
    double expansion,
    OmniColors colors,
  ) {
    // 前景色与背景移动共享连续分页进度。
    final Color color = Color.lerp(
      colors.muted,
      colors.brandStrong,
      expansion,
    )!;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(_icon(card), size: OmniSize.navigationIcon, color: color),
        if (expansion > 0)
          ClipRect(
            child: SizedBox(
              width: (labelWidth + OmniSpacing.xs) * expansion,
              child: OverflowBox(
                alignment: AlignmentDirectional.centerStart,
                minWidth: labelWidth + OmniSpacing.xs,
                maxWidth: labelWidth + OmniSpacing.xs,
                child: Opacity(
                  opacity: expansion,
                  child: Padding(
                    padding: const EdgeInsetsDirectional.only(
                      start: OmniSpacing.xs,
                    ),
                    child: Text(
                      _label(card),
                      key: ValueKey<String>('home-mobile-label-${card.name}'),
                      maxLines: 1,
                      softWrap: false,
                      textScaler: scaler,
                      style: style.copyWith(color: color),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 构建可点按、可读屏且随分页连续移动的导航。
  @override
  Widget build(BuildContext context) {
    // 当前页面语义色。
    final OmniColors colors = OmniColors.of(context);
    // 所有标签测量和绘制均使用主题字体。
    final TextStyle style = Theme.of(context).textTheme.titleSmall!
        .copyWith(fontWeight: FontWeight.w600);
    // 保留系统字号，不缩小文字来强行适配。
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    // 导航外边距内的完整触控高度。
    final double height = widget.height - OmniSpacing.xxs * 2;
    // 胶囊视觉高度与触控高度分开计算。
    final double pillHeight = math.max(
      OmniSize.control,
      scaler.scale(style.fontSize!) * 1.4 + OmniSpacing.xs,
    );
    // 每个模块完整展开时的文字宽度。
    final List<double> labelWidths = <double>[
      for (final HomeCardId card in widget.pages)
        _labelWidth(card, style, scaler),
    ];
    return SizedBox(
      key: const ValueKey<String>('home-mobile-tabs'),
      height: widget.height,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: OmniSpacing.xs,
          vertical: OmniSpacing.xxs,
        ),
        child: Material(
          key: const ValueKey<String>('home-mobile-tabs-track'),
          color: colors.mist,
          borderRadius: BorderRadius.circular(OmniRadius.pill),
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              return AnimatedBuilder(
                animation: widget.pageController,
                builder: (BuildContext context, Widget? child) {
                  // 更新与首帧期间采用稳定索引，正常拖动使用真实连续页码。
                  final double index =
                      (widget.pendingPage?.toDouble() ??
                              (widget.pageController.hasClients &&
                                      widget
                                          .pageController
                                          .position
                                          .hasContentDimensions
                                  ? widget.pageController.page
                                  : null) ??
                              widget.pages.indexOf(widget.selected).toDouble())
                          .clamp(0, widget.pages.length - 1)
                          .toDouble();
                  // 相邻两项收起和展开，最终只显示选中项文字。
                  final List<double> expansions = <double>[
                    for (
                      int position = 0;
                      position < widget.pages.length;
                      position++
                    )
                      (1 - (index - position).abs()).clamp(0, 1),
                  ];
                  // 保留最小触控宽度，并按展开进度增加文字宽度。
                  final List<double> widths = <double>[
                    for (
                      int position = 0;
                      position < widget.pages.length;
                      position++
                    )
                      OmniSize.touch +
                          (labelWidths[position] + OmniSpacing.xs) *
                              expansions[position],
                  ];
                  // 空间充足时均匀分配剩余宽度。
                  final double extra =
                      math.max(
                        0,
                        constraints.maxWidth -
                            widths.fold<double>(0, (a, b) => a + b),
                      ) /
                      widths.length;
                  // 将余量应用到各项的真实点击范围。
                  for (int position = 0; position < widths.length; position++) {
                    widths[position] += extra;
                  }
                  _revealSelected(widths, constraints.maxWidth, index.round());
                  // 当前页左侧相邻索引。
                  final int lower = index.floor();
                  // 当前页右侧相邻索引。
                  final int upper = index.ceil();
                  // 两个分页位置之间的插值比例。
                  final double fraction = index - lower;
                  // 胶囊起点按实际项宽连续移动。
                  final double start =
                      widths.take(lower).fold<double>(0, (a, b) => a + b) +
                      widths[lower] * fraction +
                      OmniSpacing.xxs;
                  // 胶囊宽度与文字展开同步。
                  final double width =
                      widths[lower] +
                      (widths[upper] - widths[lower]) * fraction -
                      OmniSpacing.xxs * 2;
                  return SingleChildScrollView(
                    key: const ValueKey<String>('home-mobile-tabs-scroll'),
                    controller: _scrollController,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: widths.fold<double>(0, (a, b) => a + b),
                      height: height,
                      child: Stack(
                        children: <Widget>[
                          PositionedDirectional(
                            start: start,
                            top: (height - pillHeight) / 2,
                            width: width,
                            height: pillHeight,
                            child: DecoratedBox(
                              key: const ValueKey<String>(
                                'home-mobile-tabs-indicator',
                              ),
                              decoration: BoxDecoration(
                                color: colors.paper,
                                borderRadius: BorderRadius.circular(
                                  OmniRadius.pill,
                                ),
                              ),
                            ),
                          ),
                          Row(
                            children: <Widget>[
                              for (
                                int position = 0;
                                position < widget.pages.length;
                                position++
                              )
                                Semantics(
                                  button: true,
                                  label: _label(widget.pages[position]),
                                  excludeSemantics: true,
                                  onTap: () => widget.onSelected(position),
                                  selected:
                                      widget.pages[position] == widget.selected,
                                  child: Tooltip(
                                    message: _label(widget.pages[position]),
                                    excludeFromSemantics: true,
                                    child: InkWell(
                                      key: ValueKey<String>(
                                        'home-mobile-tab-${widget.pages[position].name}',
                                      ),
                                      borderRadius: BorderRadius.circular(
                                        OmniRadius.pill,
                                      ),
                                      onTap: () => widget.onSelected(position),
                                      child: SizedBox(
                                        width: widths[position],
                                        height: height,
                                        child: Center(
                                          child: _buildLabel(
                                            widget.pages[position],
                                            style,
                                            scaler,
                                            labelWidths[position],
                                            expansions[position],
                                            colors,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 保活一个模块并提供独立纵向滚动位置。
class _HomeModuleViewport extends StatefulWidget {
  /// 当前模块的业务内容。
  final Widget child;

  /// 滚动尾部的悬浮操作避让。
  final double bottomPadding;

  /// 仅短视口的当前模块参与顶部收起。
  final bool coordinated;

  /// 创建稳定模块容器。
  const _HomeModuleViewport({
    required this.child,
    required this.bottomPadding,
    required this.coordinated,
    super.key,
  });

  /// 创建独立滚动及保活状态。
  @override
  State<_HomeModuleViewport> createState() => _HomeModuleViewportState();
}

/// 模块切出可视区后继续保存内部交互状态。
class _HomeModuleViewportState extends State<_HomeModuleViewport>
    with AutomaticKeepAliveClientMixin {
  /// 模块专用正文滚动控制器。
  final ScrollController _scrollController = ScrollController();

  /// 已访问模块保活到被移除或首页销毁。
  @override
  bool get wantKeepAlive => true;

  /// 释放模块滚动控制器。
  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 提供平铺内容的滚动契约，不改变业务子树身份。
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return OmniPanelScrollScope(
      controller: _scrollController,
      bottomPadding: widget.bottomPadding,
      usePrimaryScrollController: widget.coordinated,
      preserveScrollState: true,
      child: SizedBox.expand(child: widget.child),
    );
  }
}

/// 在真实排版后通知顶部大小，避免为名言或中文字号猜测高度。
class _HomeHeaderMeasure extends SingleChildRenderObjectWidget {
  /// 顶部大小变化后的回调。
  final ValueChanged<Size> onSize;

  /// 创建无额外布局约束的测量节点。
  const _HomeHeaderMeasure({
    required this.onSize,
    required super.child,
    super.key,
  });

  /// 创建透明代理测量对象。
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _HomeHeaderMeasureBox(onSize);

  /// 更新回调但不重建布局子树。
  @override
  void updateRenderObject(
    BuildContext context,
    _HomeHeaderMeasureBox renderObject,
  ) {
    renderObject.onSize = onSize;
  }
}

/// 仅在顶部大小变化时于帧末发布测量值。
class _HomeHeaderMeasureBox extends RenderProxyBox {
  /// 当前布局通知回调。
  ValueChanged<Size> onSize;

  /// 上次通知的布局尺寸。
  Size? _previousSize;

  /// 创建顶部测量渲染对象。
  _HomeHeaderMeasureBox(this.onSize);

  /// 按子组件自然尺寸排版并延后通知上层。
  @override
  void performLayout() {
    super.performLayout();
    if (_previousSize == size) return;
    _previousSize = size;
    // 捕获本帧测量值，避免帧末读取已失效布局。
    final Size measured = size;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (attached) onSize(measured);
    });
  }
}
