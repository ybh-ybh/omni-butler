import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/features/todos/data/todo_priority_quadrant.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 安卓待办内部分类的稳定顺序。
const List<TodoPriorityQuadrant?> _quadrants = <TodoPriorityQuadrant?>[
  null,
  ...todoPriorityQuadrantActionOrder,
];

/// 安卓紧凑待办的分类导航、独立滚动与完成历史二级页。
class TodoMobileDashboard extends StatefulWidget {
  /// 当前会话选中的分类。
  final TodoPriorityQuadrant? selectedQuadrant;

  /// 各分类进行中的父任务数量，不包含子任务或完成历史。
  final Map<TodoPriorityQuadrant, int> quadrantCounts;

  /// 是否正在查看完成历史。
  final bool showingHistory;

  /// 当前完成历史日期。
  final DateTime selectedDay;

  /// 当前自然日。
  final DateTime today;

  /// 分类切换后更新会话状态。
  final ValueChanged<TodoPriorityQuadrant?> onQuadrantSelected;

  /// 打开或返回完成历史。
  final ValueChanged<bool> onHistoryChanged;

  /// 更新历史日期。
  final ValueChanged<DateTime> onDaySelected;

  /// 打开现有新增待办编辑器。
  final VoidCallback onCreate;

  /// 按分类构建进行中业务内容，不受历史视图开关影响。
  final Widget Function(BuildContext, TodoPriorityQuadrant?) activePageBuilder;

  /// 当前日期的完成历史业务内容。
  final Widget history;

  /// 创建安卓待办平铺页面。
  const TodoMobileDashboard({
    required this.selectedQuadrant,
    required this.quadrantCounts,
    required this.showingHistory,
    required this.selectedDay,
    required this.today,
    required this.onQuadrantSelected,
    required this.onHistoryChanged,
    required this.onDaySelected,
    required this.onCreate,
    required this.activePageBuilder,
    required this.history,
    super.key,
  });

  /// 创建可保留分页位置的页面状态。
  @override
  State<TodoMobileDashboard> createState() => _TodoMobileDashboardState();
}

/// 在会话分类与分页控制器之间同步状态。
class _TodoMobileDashboardState extends State<TodoMobileDashboard> {
  /// 独立于一级导航的分类分页控制器。
  late final PageController _pageController;

  /// 点按或路由切换期间尚未落位的目标页。
  int? _pendingPage;

  /// 正文已报告的页码，避免会话回传时中断当前拖动。
  int? _reportedPage;

  /// 防止已被新操作替代的动画回调修改当前状态。
  int _selectionRevision = 0;

  /// 根据已保留的会话分类初始化分页。
  @override
  void initState() {
    super.initState();
    _pageController = PageController(
      initialPage: _quadrants.indexOf(widget.selectedQuadrant),
    );
  }

  /// 同步标签点按和首页路由指定的分类。
  @override
  void didUpdateWidget(covariant TodoMobileDashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedQuadrant != widget.selectedQuadrant) {
      if (_reportedPage != _quadrants.indexOf(widget.selectedQuadrant)) {
        _moveToSelectedPage();
      }
      _reportedPage = null;
    }
  }

  /// 将分页移动到当前会话分类，动画经过的中间页不覆盖目标。
  void _moveToSelectedPage() {
    // 当前会话指定的目标索引。
    final int target = _quadrants.indexOf(widget.selectedQuadrant);
    if (!_pageController.hasClients) return;
    if ((_pageController.page! - target).abs() < 0.001) return;
    _pendingPage = target;
    // 此次选择用于废弃旧动画的完成通知。
    final int revision = ++_selectionRevision;
    if (OmniMotion.reduce(context)) {
      _pageController.jumpToPage(target);
      _pendingPage = null;
      return;
    }
    _pageController
        .animateToPage(
          target,
          duration: OmniMotion.panel,
          curve: OmniMotion.standardCurve,
        )
        .whenComplete(() {
          if (mounted && revision == _selectionRevision) {
            setState(() => _pendingPage = null);
          }
        });
  }

  /// 用户拖动接管并落位后，以正文真实页码同步标签。
  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0 ||
        notification.metrics.axis != Axis.horizontal) {
      return false;
    }
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      ++_selectionRevision;
      _pendingPage = null;
    }
    if (notification is ScrollEndNotification && _pendingPage == null) {
      // 中断后回到原页可能不会再触发 onPageChanged，落位时补齐会话状态。
      final int index = _pageController.page!.round().clamp(
        0,
        _quadrants.length - 1,
      );
      _reportedPage = index;
      widget.onQuadrantSelected(_quadrants[index]);
    }
    return false;
  }

  /// 认领非分页区域的水平手势，避免进入一级导航。
  void _consumeHorizontalDrag(DragStartDetails details) {}

  /// 释放独立分页控制器。
  @override
  void dispose() {
    ++_selectionRevision;
    _pageController.dispose();
    super.dispose();
  }

  /// 构建连续实底、保活分类和历史返回行为。
  @override
  Widget build(BuildContext context) {
    // 与首页一致的连续内容背景。
    final OmniColors colors = OmniColors.of(context);
    // 新增按钮的避让随文字缩放增长，只加入列表末尾。
    final double actionClearance =
        math.max(
          OmniSize.touch,
          MediaQuery.textScalerOf(context).scale(16) * 1.4,
        ) +
        OmniSpacing.md * 2 +
        OmniSpacing.xs;
    return PopScope<Object?>(
      canPop: !widget.showingHistory,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop && widget.showingHistory) {
          widget.onHistoryChanged(false);
        }
      },
      child: GestureDetector(
        key: const ValueKey<String>('todo-mobile-page-gesture-boundary'),
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onHorizontalDragStart: _consumeHorizontalDrag,
        child: Material(
          color: colors.paper,
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: IndexedStack(
                  index: widget.showingHistory ? 1 : 0,
                  children: <Widget>[
                    TickerMode(
                      enabled: !widget.showingHistory,
                      child: Column(
                        children: <Widget>[
                          _TodoMobileTabs(
                            selected: widget.selectedQuadrant,
                            quadrantCounts: widget.quadrantCounts,
                            pageController: _pageController,
                            onSelected: widget.onQuadrantSelected,
                            onHistory: () => widget.onHistoryChanged(true),
                          ),
                          Expanded(
                            child: NotificationListener<ScrollNotification>(
                              onNotification: _handleScrollNotification,
                              child: PageView.builder(
                                key: const ValueKey<String>(
                                  'todo-mobile-pager',
                                ),
                                controller: _pageController,
                                physics: const AlwaysScrollableScrollPhysics(
                                  parent: ClampingScrollPhysics(),
                                ),
                                itemCount: _quadrants.length,
                                onPageChanged: (int index) {
                                  if (_pendingPage == null) {
                                    _reportedPage = index;
                                    widget.onQuadrantSelected(
                                      _quadrants[index],
                                    );
                                  }
                                },
                                itemBuilder:
                                    (
                                      BuildContext context,
                                      int index,
                                    ) => _TodoMobileViewport(
                                      key: ValueKey<String>(
                                        'todo-mobile-page-${_quadrants[index]?.value ?? 'all'}',
                                      ),
                                      bottomPadding: actionClearance,
                                      child: widget.activePageBuilder(
                                        context,
                                        _quadrants[index],
                                      ),
                                    ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    TickerMode(
                      enabled: widget.showingHistory,
                      child: Column(
                        children: <Widget>[
                          _TodoMobileHistoryHeader(
                            selectedDay: widget.selectedDay,
                            today: widget.today,
                            onBack: () => widget.onHistoryChanged(false),
                            onDaySelected: widget.onDaySelected,
                          ),
                          Expanded(
                            child: _TodoMobileViewport(
                              key: const ValueKey<String>(
                                'todo-mobile-history-viewport',
                              ),
                              bottomPadding: OmniSpacing.xl,
                              child: widget.history,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (!widget.showingHistory)
                Positioned(
                  right: OmniSpacing.md,
                  bottom: OmniSpacing.md,
                  child: OmniButton(
                    key: const ValueKey<String>('todo-mobile-create'),
                    label: '新增待办',
                    icon: Icons.add_rounded,
                    variant: OmniButtonVariant.pagePrimary,
                    onPressed: widget.onCreate,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 保留单个分类的滚动位置和业务子树。
class _TodoMobileViewport extends StatefulWidget {
  /// 随页面滚动的业务内容。
  final Widget child;

  /// 随列表滚动的底部避让空间。
  final double bottomPadding;

  /// 创建独立滚动页。
  const _TodoMobileViewport({
    required this.child,
    required this.bottomPadding,
    super.key,
  });

  /// 创建保活滚动状态。
  @override
  State<_TodoMobileViewport> createState() => _TodoMobileViewportState();
}

/// 分页离屏时仍保留纵向滚动位置。
class _TodoMobileViewportState extends State<_TodoMobileViewport>
    with AutomaticKeepAliveClientMixin<_TodoMobileViewport> {
  /// 本页专用纵向控制器。
  final ScrollController _scrollController = ScrollController();

  /// 已访问页在相邻分页之外继续保活。
  @override
  bool get wantKeepAlive => true;

  /// 释放本页独立控制器。
  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 构建填满正文高度的独立滚动视口。
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SingleChildScrollView(
      controller: _scrollController,
      primary: false,
      padding: EdgeInsets.only(bottom: widget.bottomPadding),
      child: widget.child,
    );
  }
}

/// 不压缩文字的横向分类标签和固定历史入口。
class _TodoMobileTabs extends StatefulWidget {
  /// 当前会话分类。
  final TodoPriorityQuadrant? selected;

  /// 分类右上角展示的父任务数量。
  final Map<TodoPriorityQuadrant, int> quadrantCounts;

  /// 正文分页位置，用于连续移动下划线。
  final PageController pageController;

  /// 点按分类。
  final ValueChanged<TodoPriorityQuadrant?> onSelected;

  /// 打开完成历史。
  final VoidCallback onHistory;

  /// 创建文字分类导航。
  const _TodoMobileTabs({
    required this.selected,
    required this.quadrantCounts,
    required this.pageController,
    required this.onSelected,
    required this.onHistory,
  });

  /// 创建标签滚动状态。
  @override
  State<_TodoMobileTabs> createState() => _TodoMobileTabsState();
}

/// 仅滚动标签自身，避免确保可见操作影响正文分页。
class _TodoMobileTabsState extends State<_TodoMobileTabs> {
  /// 标签行专用水平控制器。
  final ScrollController _scrollController = ScrollController();

  /// 上次完成可见性同步的标签和尺寸签名。
  String? _revealSignature;

  /// 在布局后将当前标签完整移入导航视口。
  void _revealSelected(List<double> widths, double viewportWidth) {
    // 引擎尚未提供真实尺寸时不启动隐藏页动画，避免切入后错误恢复。
    if (viewportWidth <= 0) return;
    // 选中标签在固定顺序中的位置。
    final int selectedIndex = _quadrants.indexOf(widget.selected);
    // 分类和字体变化都需要重新计算标签位置。
    final String signature =
        '$selectedIndex/$viewportWidth/${widths.join(',')}';
    if (_revealSignature == signature) return;
    _revealSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((Duration timestamp) {
      if (!mounted ||
          !_scrollController.hasClients ||
          _revealSignature != signature) {
        return;
      }
      // 当前标签在整行内容中的左右边界。
      final double start = widths.take(selectedIndex).fold(0, (a, b) => a + b);
      // 标签右边界需要连同完整文字一起进入视口。
      final double end = start + widths[selectedIndex];
      // 尽量只滚动到刚好能容纳当前标签的位置。
      final double current = _scrollController.offset;
      // 目标滚动量始终限制在标签列表自身的范围内。
      final double target =
          (start < current
                  ? start
                  : end > current + viewportWidth
                  ? end - viewportWidth
                  : current)
              .clamp(0, _scrollController.position.maxScrollExtent)
              .toDouble();
      if ((target - current).abs() < 0.5) {
        // 新目标已可见时仍需取消被隐藏Ticker冻结的旧滚动动画。
        _scrollController.jumpTo(target);
        return;
      }
      if (OmniMotion.reduce(context)) {
        _scrollController.jumpTo(target);
      } else {
        _scrollController.animateTo(
          target,
          duration: OmniMotion.panel,
          curve: OmniMotion.standardCurve,
        );
      }
    });
  }

  /// 释放标签滚动控制器。
  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 测量完整标签宽度后立即释放文字布局资源。
  double _labelWidth(
    TodoPriorityQuadrant? quadrant,
    TextStyle style,
    TextScaler scaler,
  ) {
    // 标签按选中时的较粗字重测量，避免选中后被裁切。
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: quadrant?.actionLabel ?? '全部',
        style: style.copyWith(fontWeight: FontWeight.w600),
      ),
      textDirection: Directionality.of(context),
      textScaler: scaler,
    )..layout();
    // 数量角标与完整文字一起分配宽度，避免覆盖标签。
    double contentWidth = painter.width;
    // 空分类不显示角标，也不预留角标宽度。
    final int count = widget.quadrantCounts[quadrant] ?? 0;
    if (count > 0) {
      painter.text = TextSpan(text: '$count', style: _countStyle(style));
      painter.layout();
      contentWidth += math.max(scaler.scale(12), painter.width + 6) + 2;
    }
    // 加入文字两侧的标准内边距和最小触控宽度。
    final double width = math.max(
      OmniSize.touch,
      contentWidth + OmniSpacing.sm * 2,
    );
    painter.dispose();
    return width;
  }

  /// 小号角标保留系统文字缩放和清晰字重。
  TextStyle _countStyle(TextStyle style) =>
      style.copyWith(fontSize: 10, height: 1, fontWeight: FontWeight.w600);

  /// 将父任务数量放在分类文字右上方，不挤压完整名称。
  Widget _buildLabel(
    TodoPriorityQuadrant? quadrant,
    TextStyle style,
    TextScaler scaler,
  ) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前分类的选中状态。
    final bool selected = quadrant == widget.selected;
    // 文字与角标同步强调当前分类。
    final Color color = selected ? colors.brand : colors.muted;
    // 只有非空分类才展示父任务数量。
    final int count = widget.quadrantCounts[quadrant] ?? 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          quadrant?.actionLabel ?? '全部',
          style: style.copyWith(
            color: color,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
        if (quadrant != null && count > 0) ...<Widget>[
          const SizedBox(width: 2),
          Transform.translate(
            offset: Offset(0, -scaler.scale(5)),
            child: Container(
              key: ValueKey<String>('todo-mobile-count-${quadrant.value}'),
              constraints: BoxConstraints(minWidth: scaler.scale(12)),
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(OmniRadius.pill),
              ),
              child: Text(
                '$count',
                textAlign: TextAlign.center,
                style: _countStyle(style).copyWith(color: color),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// 构建与首页一致的文字和短下划线。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 首页同款导航文字样式。
    final TextStyle style = Theme.of(context).textTheme.titleSmall!;
    // 保留系统字号缩放，不将标签压小。
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    // 导航高度随大字号增长，但不低于触控热区。
    final double height = math.max(
      OmniSize.touch,
      scaler.scale(style.fontSize!) * 1.4 + OmniSpacing.md,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          height: height,
          child: Row(
            children: <Widget>[
              Expanded(
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    // 每个完整标签按实际文字宽度分配空间。
                    final List<double> widths = <double>[
                      for (final TodoPriorityQuadrant? quadrant in _quadrants)
                        _labelWidth(quadrant, style, scaler),
                    ];
                    // 宽屏时均匀填满导航，窄屏时保留自然文字宽度。
                    final double naturalWidth = widths.fold(0, (a, b) => a + b);
                    if (naturalWidth < constraints.maxWidth) {
                      for (int index = 0; index < widths.length; index++) {
                        widths[index] +=
                            (constraints.maxWidth - naturalWidth) /
                            widths.length;
                      }
                    }
                    _revealSelected(widths, constraints.maxWidth);
                    return SingleChildScrollView(
                      key: const ValueKey<String>('todo-mobile-tabs-scroll'),
                      controller: _scrollController,
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: widths.fold<double>(0, (a, b) => a + b),
                        height: height,
                        child: AnimatedBuilder(
                          animation: widget.pageController,
                          builder: (BuildContext context, Widget? child) {
                            // 拖动时使用连续页码，首帧使用会话索引。
                            final double page =
                                (widget.pageController.hasClients &&
                                        widget
                                            .pageController
                                            .position
                                            .hasContentDimensions
                                    ? widget.pageController.page
                                    : null) ??
                                _quadrants.indexOf(widget.selected).toDouble();
                            // 指示线在实际标签中心之间连续插值。
                            final double clamped = page.clamp(
                              0,
                              widths.length - 1,
                            );
                            // 连续页码左侧对应的标签索引。
                            final int lower = clamped.floor();
                            // 连续页码右侧对应的标签索引。
                            final int upper = clamped.ceil();
                            // 左侧标签在自然宽度导航中的中心。
                            final double lowerCenter =
                                widths.take(lower).fold(0.0, (a, b) => a + b) +
                                widths[lower] / 2;
                            // 右侧标签在自然宽度导航中的中心。
                            final double upperCenter =
                                widths.take(upper).fold(0.0, (a, b) => a + b) +
                                widths[upper] / 2;
                            // 随正文拖动连续移动的指示线中心。
                            final double center =
                                lowerCenter +
                                (upperCenter - lowerCenter) * (clamped - lower);
                            return Stack(
                              children: <Widget>[
                                Row(
                                  children: <Widget>[
                                    for (
                                      int index = 0;
                                      index < _quadrants.length;
                                      index++
                                    )
                                      Semantics(
                                        button: true,
                                        label: _quadrants[index] == null
                                            ? '全部'
                                            : '${_quadrants[index]!.actionLabel}，${widget.quadrantCounts[_quadrants[index]] ?? 0} 个父任务',
                                        excludeSemantics: true,
                                        onTap: () => widget.onSelected(
                                          _quadrants[index],
                                        ),
                                        selected:
                                            _quadrants[index] ==
                                            widget.selected,
                                        child: InkWell(
                                          key: ValueKey<String>(
                                            'todo-mobile-quadrant-${_quadrants[index]?.value ?? 'all'}',
                                          ),
                                          onTap: () => widget.onSelected(
                                            _quadrants[index],
                                          ),
                                          child: SizedBox(
                                            width: widths[index],
                                            height: height,
                                            child: Center(
                                              child: _buildLabel(
                                                _quadrants[index],
                                                style,
                                                scaler,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                Positioned(
                                  left: center - OmniSpacing.xl / 2,
                                  bottom: 0,
                                  width: OmniSpacing.xl,
                                  height: 2,
                                  child: ColoredBox(color: colors.brand),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    );
                  },
                ),
              ),
              OmniIconButton(
                key: const ValueKey<String>('todo-mobile-history-open'),
                tooltip: '完成历史',
                onPressed: widget.onHistory,
                icon: const Icon(Icons.history_rounded),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: colors.line),
      ],
    );
  }
}

/// 完成历史二级页的返回和日期选择。
class _TodoMobileHistoryHeader extends StatelessWidget {
  /// 当前历史日期。
  final DateTime selectedDay;

  /// 当前自然日。
  final DateTime today;

  /// 返回原分类。
  final VoidCallback onBack;

  /// 修改历史日期。
  final ValueChanged<DateTime> onDaySelected;

  /// 创建平铺历史导航。
  const _TodoMobileHistoryHeader({
    required this.selectedDay,
    required this.today,
    required this.onBack,
    required this.onDaySelected,
  });

  /// 优先使用中文日期，窄屏大字号时完整显示短日期或分两行。
  String _dateLabel(BuildContext context, double width) {
    // 与日期按钮的实际主题字号一致，保留系统缩放。
    final TextStyle style =
        Theme.of(context).outlinedButtonTheme.style?.textStyle
            ?.resolve(const <WidgetState>{}) ??
        Theme.of(context).textTheme.labelLarge!;
    // 日期按钮两侧预留主题内边距。
    final double available = math.max(0, width - OmniSpacing.md * 2);
    // 首选自然中文日期。
    final String full = DateFormat('yyyy 年 M 月 d 日').format(selectedDay);
    // 空间不足时改用年月日均完整的紧凑格式。
    final String short = DateFormat('yyyy/M/d').format(selectedDay);
    // 按实际字体测量，避免只检查控件位置却漏掉省略号。
    final TextPainter painter = TextPainter(
      text: TextSpan(text: full, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    if (painter.width <= available) {
      painter.dispose();
      return full;
    }
    painter.text = TextSpan(text: short, style: style);
    painter.layout();
    // 仍无法单行容纳时让日期按钮自然增高，不缩小文字。
    final bool shortFits = painter.width <= available;
    painter.dispose();
    return shortFits
        ? short
        : '${DateFormat('yyyy').format(selectedDay)}\n${DateFormat('M/d').format(selectedDay)}';
  }

  /// 构建二级标题和可放大文字的日期行。
  @override
  Widget build(BuildContext context) {
    // 与正文一致的主题色。
    final OmniColors colors = OmniColors.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            OmniIconButton(
              key: const ValueKey<String>('todo-mobile-history-back'),
              tooltip: '返回进行中待办',
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            Expanded(
              child: Text(
                '完成历史',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const SizedBox(width: OmniSize.touch),
          ],
        ),
        Row(
          key: const ValueKey<String>('todo-mobile-history-date-row'),
          children: <Widget>[
            OmniIconButton(
              key: const ValueKey<String>('todo-mobile-history-previous-day'),
              tooltip: '前一天',
              onPressed: () =>
                  onDaySelected(selectedDay.subtract(const Duration(days: 1))),
              icon: const Icon(Icons.chevron_left_rounded),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) =>
                    OmniDatePickerButton(
                      key: const ValueKey<String>(
                        'todo-mobile-history-date-picker',
                      ),
                      value: selectedDay,
                      initialDate: selectedDay,
                      currentDate: today,
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                      label: _dateLabel(context, constraints.maxWidth),
                      icon: null,
                      onChanged: onDaySelected,
                    ),
              ),
            ),
            OmniIconButton(
              key: const ValueKey<String>('todo-mobile-history-next-day'),
              tooltip: '后一天',
              onPressed: () =>
                  onDaySelected(selectedDay.add(const Duration(days: 1))),
              icon: const Icon(Icons.chevron_right_rounded),
            ),
          ],
        ),
        Divider(height: 1, color: colors.line),
      ],
    );
  }
}
