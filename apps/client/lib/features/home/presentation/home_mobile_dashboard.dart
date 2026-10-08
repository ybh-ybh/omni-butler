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
    // 标签随字号增长，始终保留最小触控高度。
    final double tabHeight = pages.length > 1
        ? math.max(
            OmniSize.touch,
            MediaQuery.textScalerOf(context).scale(16) * 1.4 + OmniSpacing.md,
          )
        : 0;
    // 正文至少容纳模块标题及一行触控内容。
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

/// 使用文字与短下划线的平铺模块导航。
class _HomeModuleTabs extends StatelessWidget {
  /// 可见模块的顺序。
  final List<HomeCardId> pages;

  /// 当前选中模块。
  final HomeCardId selected;

  /// 横向滚动位置，用于同步指示线。
  final PageController pageController;

  /// 模块重排后尚未应用的目标页。
  final int? pendingPage;

  /// 包含字号缩放的导航高度。
  final double height;

  /// 点按标签后的选择回调。
  final ValueChanged<int> onSelected;

  /// 创建首页文本导航。
  const _HomeModuleTabs({
    required this.pages,
    required this.selected,
    required this.pageController,
    required this.pendingPage,
    required this.height,
    required this.onSelected,
  });

  /// 返回适合手机导航的简短标签。
  String _label(HomeCardId card) => switch (card) {
    HomeCardId.todos => '待办',
    HomeCardId.timeStatus => '时间',
    HomeCardId.todayContext => '脉络',
    HomeCardId.dayRuler => '刻度',
    HomeCardId.quote => '名言',
  };

  /// 构建可点按、可读屏且随分页连续移动的导航。
  @override
  Widget build(BuildContext context) {
    // 当前页面语义色。
    final OmniColors colors = OmniColors.of(context);
    return SizedBox(
      key: const ValueKey<String>('home-mobile-tabs'),
      height: height,
      child: Material(
        color: colors.paper,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            // 每个标签均分可用宽度。
            final double itemWidth = constraints.maxWidth / pages.length;
            return AnimatedBuilder(
              animation: pageController,
              builder: (BuildContext context, Widget? child) {
                // 更新与首帧期间采用稳定索引，正常拖动使用真实连续页码。
                final double index =
                    (pendingPage?.toDouble() ??
                            (pageController.hasClients &&
                                    pageController.position.hasContentDimensions
                                ? pageController.page
                                : null) ??
                            pages.indexOf(selected).toDouble())
                        .clamp(0, pages.length - 1)
                        .toDouble();
                return Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        for (
                          int position = 0;
                          position < pages.length;
                          position++
                        )
                          Expanded(
                            child: Semantics(
                              button: true,
                              selected: pages[position] == selected,
                              child: InkWell(
                                key: ValueKey<String>(
                                  'home-mobile-tab-${pages[position].name}',
                                ),
                                onTap: () => onSelected(position),
                                child: Center(
                                  child: Text(
                                    _label(pages[position]),
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall
                                        ?.copyWith(
                                          color: pages[position] == selected
                                              ? colors.brand
                                              : colors.muted,
                                          fontWeight:
                                              pages[position] == selected
                                              ? FontWeight.w600
                                              : FontWeight.w400,
                                        ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Divider(height: 1, color: colors.line),
                    ),
                    Positioned(
                      left: itemWidth * (index + 0.5) - OmniSpacing.xl / 2,
                      bottom: 0,
                      width: OmniSpacing.xl,
                      height: 2,
                      child: ColoredBox(color: colors.brand),
                    ),
                  ],
                );
              },
            );
          },
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
