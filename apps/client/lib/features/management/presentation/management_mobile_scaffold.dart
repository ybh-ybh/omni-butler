import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/shared/ui/omni_modal_bottom_sheet.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 管理宿主向保活业务页传递可见状态和统计手势锁。
class ManagementMobileScope extends InheritedWidget {
  /// 当前分区是否实际可见。
  final bool active;

  /// 统计离开收起的代次。
  final int collapseEpoch;

  /// 通知宿主暂停或恢复横向分页。
  final ValueChanged<bool> onExpansionChanged;

  /// 创建管理分区交互作用域。
  const ManagementMobileScope({
    required this.active,
    required this.collapseEpoch,
    required this.onExpansionChanged,
    required super.child,
    super.key,
  });

  /// 查找当前分区的交互状态，独立业务页测试可以不提供宿主。
  static ManagementMobileScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ManagementMobileScope>();

  /// 分区可见性或关闭代次改变时同步子页面。
  @override
  bool updateShouldNotify(ManagementMobileScope oldWidget) =>
      active != oldWidget.active || collapseEpoch != oldWidget.collapseEpoch;
}

/// 保持正文几何和滚动位置的下拉统计页面。
class ManagementMobileScaffold extends StatefulWidget {
  /// 当前统计名称。
  final String title;

  /// 收起时的一行指标。
  final Widget summary;

  /// 展开后的完整自然高度统计内容。
  final Widget statistics;

  /// 包含搜索和独立滚动列表的正文。
  final Widget body;

  /// 保留现有新增及管理菜单。
  final Widget? floatingActionButton;

  /// 创建移动管理页面。
  const ManagementMobileScaffold({
    required this.title,
    required this.summary,
    required this.statistics,
    required this.body,
    this.floatingActionButton,
    super.key,
  });

  /// 创建独立展开动画和详情滚动状态。
  @override
  State<ManagementMobileScaffold> createState() =>
      _ManagementMobileScaffoldState();
}

/// 摘要高度与正文位移由同一个连续进度驱动。
class _ManagementMobileScaffoldState extends State<ManagementMobileScaffold>
    with SingleTickerProviderStateMixin {
  /// 沿用应用分页的原生弹簧。
  static const PageScrollPhysics _physics = PageScrollPhysics();

  /// 从零到一的可打断展开进度。
  late final AnimationController _progress;

  /// 统计详情独立滚动，不控制展开手势。
  final ScrollController _detailsScroll = ScrollController();

  /// 自然内容尺寸，不使用固定图表总高度。
  double _detailsHeight = 320;

  /// 当前两端点的像素距离。
  double _travel = 1;

  /// 吸附回调代次，取消旧动画完成回调。
  int _generation = 0;

  /// 最近处理的宿主收起代次。
  int? _collapseEpoch;

  /// 当前分区可见性。
  bool _active = true;

  /// 当前手势是否被摘要接管。
  bool _dragging = false;

  /// 是否已经通知宿主锁定横滑。
  bool _locked = false;

  /// 当前吸附目标，供连续点击反转。
  bool _targetExpanded = false;

  /// 最近可用的宿主通知入口。
  ValueChanged<bool>? _onExpansionChanged;

  /// 创建可被拖动即时接手的控制器。
  @override
  void initState() {
    super.initState();
    _progress = AnimationController.unbounded(vsync: this)
      ..addListener(_changed);
  }

  /// 保活页失活时停止动画并清除遮罩。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 当前宿主状态。
    final ManagementMobileScope? scope = ManagementMobileScope.maybeOf(context);
    _onExpansionChanged = scope?.onExpansionChanged;
    // 本次宿主是否要求归零。
    final bool reset =
        scope != null &&
        (!scope.active ||
            (_collapseEpoch != null && _collapseEpoch != scope.collapseEpoch));
    _active = scope?.active ?? true;
    _collapseEpoch = scope?.collapseEpoch;
    if (reset) _reset();
  }

  /// 释放统计滚动和动画资源。
  @override
  void dispose() {
    _generation++;
    _progress.dispose();
    _detailsScroll.dispose();
    super.dispose();
  }

  /// 用帧后通知避免子组件更新期间同步重建宿主。
  void _notifyLock(bool value) {
    if (_locked == value) return;
    _locked = value;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted) _onExpansionChanged?.call(_locked);
    });
  }

  /// 进度改变只更新展示和输入隔离，不重建业务数据。
  void _changed() {
    _notifyLock(_progress.value > 0 || _dragging);
    if (mounted) setState(() {});
  }

  /// 离开分区后即时恢复收起端点。
  void _reset() {
    _generation++;
    _dragging = false;
    _targetExpanded = false;
    _progress.stop();
    _progress.value = 0;
    _notifyLock(false);
    if (_detailsScroll.hasClients) _detailsScroll.jumpTo(0);
  }

  /// 开始拖动时收起输入法，并接管当前展示位置。
  void _start(DragStartDetails details) {
    if (!_active) return;
    FocusManager.instance.primaryFocus?.unfocus();
    _generation++;
    _progress.stop();
    _dragging = true;
    _notifyLock(true);
  }

  /// 一比一跟随纵向手指位移。
  void _update(DragUpdateDetails details) {
    if (!_dragging || !_active) return;
    _progress.value =
        (_progress.value + details.delta.dy / math.max(1, _travel)).clamp(0, 1);
  }

  /// 慢拖按距离吸附，快速滑动按明确的离手方向吸附。
  void _end(DragEndDetails details) {
    if (!_dragging || !_active) return;
    _dragging = false;
    // 手指向下为展开方向的像素速度。
    final double velocity = details.primaryVelocity ?? 0;
    unawaited(
      _settle(
        velocity.abs() >= 300 ? velocity > 0 : _progress.value >= 0.5,
        velocity,
      ),
    );
  }

  /// 手势取消时落到最近端点。
  void _cancel() {
    if (!_dragging || !_active) return;
    _dragging = false;
    unawaited(_settle(_progress.value >= 0.5));
  }

  /// 点击和无障碍动作也能控制统计。
  void _toggle() => unawaited(_settle(!_targetExpanded));

  /// 从当前位置和离手速度连续吸附，可被下一次输入取消。
  Future<void> _settle(bool expanded, [double velocity = 0]) async {
    if (!_active) return;
    FocusManager.instance.primaryFocus?.unfocus();
    _progress.stop();
    _targetExpanded = expanded;
    // 当前吸附的唯一有效代次。
    final int generation = ++_generation;
    // 两个稳定端点。
    final double target = expanded ? 1 : 0;
    if (!OmniMotion.reduce(context) && _progress.value != target) {
      // 使用真实设备像素容差换算为进度。
      final Tolerance tolerance = _physics.toleranceFor(
        FixedScrollMetrics(
          minScrollExtent: 0,
          maxScrollExtent: _travel,
          pixels: _progress.value * _travel,
          viewportDimension: _travel,
          axisDirection: AxisDirection.down,
          devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
        ),
      );
      try {
        await _progress
            .animateWith(
              ScrollSpringSimulation(
                _physics.spring,
                _progress.value,
                target,
                velocity / math.max(1, _travel),
                tolerance: Tolerance(
                  distance: tolerance.distance / math.max(1, _travel),
                  velocity: tolerance.velocity / math.max(1, _travel),
                ),
              ),
            )
            .orCancel;
      } on TickerCanceled {
        return;
      }
    }
    if (!mounted || generation != _generation) return;
    _progress.value = target;
    _notifyLock(expanded);
    if (!expanded && _detailsScroll.hasClients) _detailsScroll.jumpTo(0);
  }

  /// 保存真实统计内容高度，数据更新不会重置业务子树。
  void _measureDetails(Size size) {
    if (!mounted || (_detailsHeight - size.height).abs() < 0.5) return;
    setState(() => _detailsHeight = size.height);
  }

  /// 消费非分页区域横滑，不让外层一级导航接管。
  void _consumeHorizontal(DragStartDetails details) {}

  /// 创建可点击及纵拖的固定触区。
  Widget _dragSurface({
    required Widget child,
    required String label,
    Key? key,
  }) => Semantics(
    button: true,
    label: label,
    onTap: _toggle,
    child: GestureDetector(
      key: key,
      behavior: HitTestBehavior.opaque,
      onTap: _toggle,
      onVerticalDragStart: _start,
      onVerticalDragUpdate: _update,
      onVerticalDragEnd: _end,
      onVerticalDragCancel: _cancel,
      child: child,
    ),
  );

  /// 绘制固定正文视口、展开面板及同步遮罩。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 连续进度只限制显示端点，不截断弹簧内部速度。
    final double progress = _progress.value.clamp(0, 1);
    // 背景在拖动或展开过程中不可操作。
    final bool blocked = progress > 0 || _dragging;
    // 搜索输入时让出键盘上方的有限空间，避免遮住空结果清除入口。
    final bool hideFloating =
        blocked ||
        MediaQuery.viewInsetsOf(Scaffold.maybeOf(context)?.context ?? context)
                .bottom >
            0;
    return PopScope<Object?>(
      canPop: !_active || !blocked,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop && _active && blocked) unawaited(_settle(false));
      },
      child: ColoredBox(
        color: colors.paper,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            // 胶囊高度跟随系统字号，避免缩小文字。
            final double capsule = math.max(
              OmniSize.touch,
              MediaQuery.textScalerOf(context).scale(14) * 1.5 + OmniSpacing.md,
            );
            // 标题与底部把手在极短视口中共享唯一可见标题触区。
            final double header = math.min(capsule, constraints.maxHeight);
            // 面板在上下各留八像素，正文起点固定。
            final double collapsedHeight = math.min(
              constraints.maxHeight,
              header + OmniSpacing.md,
            );
            // 展开时为背景保留空间，短屏详情始终可以滚动。
            final double limit = math.max(
              collapsedHeight,
              constraints.maxHeight * 0.7,
            );
            // 正常屏保留独立把手，极短屏通过标题收起。
            final double handle = limit - collapsedHeight > OmniSize.touch * 2
                ? OmniSize.touch
                : 0;
            // 实际展开高度受自然内容和可用空间双重约束。
            final double expandedHeight = math.min(
              limit,
              collapsedHeight + _detailsHeight + handle,
            );
            _travel = math.max(1, expandedHeight - collapsedHeight);
            // 当前统计面板占用高度，和正文平移严格相同。
            final double height =
                collapsedHeight + (expandedHeight - collapsedHeight) * progress;
            // 背景保持收起时的固定布局高度。
            final double bodyHeight = math.max(
              0,
              constraints.maxHeight - collapsedHeight,
            );
            return ClipRect(
              child: Stack(
                children: <Widget>[
                  Positioned(
                    key: const ValueKey<String>('management-body-layer'),
                    left: 0,
                    right: 0,
                    top: collapsedHeight,
                    height: bodyHeight,
                    child: Transform.translate(
                      key: const ValueKey<String>(
                        'management-body-translation',
                      ),
                      offset: Offset(0, height - collapsedHeight),
                      child: ExcludeFocus(
                        excluding: blocked,
                        child: ExcludeSemantics(
                          excluding: blocked,
                          child: IgnorePointer(
                            ignoring: blocked,
                            child: widget.body,
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (widget.floatingActionButton != null)
                    Positioned(
                      key: const ValueKey<String>('management-floating-layer'),
                      right: OmniSpacing.md,
                      bottom: OmniSpacing.md,
                      child: IgnorePointer(
                        ignoring: hideFloating,
                        child: ExcludeSemantics(
                          excluding: hideFloating,
                          child: Opacity(
                            opacity: hideFloating ? 0 : 1,
                            child: ExcludeFocus(
                              excluding: hideFloating,
                              child: widget.floatingActionButton!,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (blocked)
                    Positioned(
                      key: const ValueKey<String>('management-scrim-layer'),
                      left: 0,
                      right: 0,
                      top: height,
                      bottom: 0,
                      child: Semantics(
                        button: true,
                        label: '收起${widget.title}',
                        onTap: () => unawaited(_settle(false)),
                        child: GestureDetector(
                          key: const ValueKey<String>(
                            'management-summary-scrim',
                          ),
                          behavior: HitTestBehavior.opaque,
                          // 读屏只暴露外层收起动作，不生成无效横滚操作。
                          excludeFromSemantics: true,
                          onTap: () => unawaited(_settle(false)),
                          onHorizontalDragStart: _consumeHorizontal,
                          child: ColoredBox(
                            color: Colors.black.withValues(
                              alpha: progress * 0.32,
                            ),
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    key: const ValueKey<String>('management-summary-layer'),
                    left: OmniSpacing.md,
                    right: OmniSpacing.md,
                    top: OmniSpacing.xs,
                    height: math.max(0, height - OmniSpacing.md),
                    child: GestureDetector(
                      // 消费横滑不构成读屏操作，内部入口保留各自语义。
                      excludeFromSemantics: true,
                      onHorizontalDragStart: _consumeHorizontal,
                      child: Material(
                        key: const ValueKey<String>(
                          'management-summary-surface',
                        ),
                        color: Color.lerp(
                          colors.canvas,
                          colors.brandSoft,
                          progress * 0.55,
                        ),
                        borderRadius: BorderRadius.circular(
                          capsule / 2 +
                              (OmniRadius.dialog - capsule / 2) * progress,
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Stack(
                          children: <Widget>[
                            Positioned(
                              left: 0,
                              right: 0,
                              top: header,
                              height: math.max(
                                0,
                                expandedHeight - collapsedHeight - handle,
                              ),
                              child: IgnorePointer(
                                ignoring: progress < 0.99,
                                child: ExcludeSemantics(
                                  excluding: progress < 0.99,
                                  child: Opacity(
                                    opacity: progress,
                                    child: ScrollConfiguration(
                                      behavior: ScrollConfiguration.of(context)
                                          .copyWith(scrollbars: false),
                                      child: Scrollbar(
                                        controller: _detailsScroll,
                                        thumbVisibility: true,
                                        child: SingleChildScrollView(
                                          key: const ValueKey<String>(
                                            'management-summary-details',
                                          ),
                                          controller: _detailsScroll,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: OmniSpacing.md,
                                          ),
                                          child: _ManagementMeasure(
                                            onSize: _measureDetails,
                                            child: ExcludeFocus(
                                              excluding: progress < 0.99,
                                              child: widget.statistics,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            if (handle > 0)
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                height: handle,
                                child: IgnorePointer(
                                  ignoring: progress < 0.99,
                                  child: ExcludeSemantics(
                                    excluding: progress < 0.99,
                                    child: Opacity(
                                      opacity: progress,
                                      child: _dragSurface(
                                        key: const ValueKey<String>(
                                          'management-summary-handle',
                                        ),
                                        label: '收起${widget.title}',
                                        child: Center(
                                          child: Container(
                                            width: OmniSize.controlLarge,
                                            height: OmniSpacing.xxs,
                                            decoration: BoxDecoration(
                                              color: colors.muted,
                                              borderRadius:
                                                  BorderRadius.circular(
                                                    OmniRadius.pill,
                                                  ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            Positioned(
                              left: 0,
                              right: 0,
                              top: 0,
                              height: header,
                              child: _dragSurface(
                                key: const ValueKey<String>(
                                  'management-summary-toggle',
                                ),
                                label:
                                    '${blocked ? '收起' : '展开'}${widget.title}',
                                child: Padding(
                                  padding: const EdgeInsets.only(
                                    left: OmniSpacing.md,
                                  ),
                                  child: Row(
                                    children: <Widget>[
                                      Expanded(
                                        child: Stack(
                                          alignment: Alignment.centerLeft,
                                          children: <Widget>[
                                            ExcludeSemantics(
                                              excluding: blocked,
                                              child: Opacity(
                                                opacity: 1 - progress,
                                                child: IgnorePointer(
                                                  ignoring: blocked,
                                                  child: ExcludeFocus(
                                                    excluding: blocked,
                                                    child: widget.summary,
                                                  ),
                                                ),
                                              ),
                                            ),
                                            if (blocked)
                                              Opacity(
                                                opacity: progress,
                                                child: Text(
                                                  widget.title,
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .titleMedium,
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                      ExcludeSemantics(
                                        child: SizedBox(
                                          width: OmniSize.touch,
                                          child: Icon(
                                            blocked
                                                ? Icons
                                                      .keyboard_arrow_up_rounded
                                                : Icons
                                                      .keyboard_arrow_down_rounded,
                                            color: colors.muted,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 单项摘要数据，不改变原统计口径。
class ManagementSummaryMetric {
  /// 简短指标名。
  final String label;

  /// 已由业务格式化的完整数值。
  final String value;

  /// 指标语义色。
  final Color? color;

  /// 创建一项摘要。
  const ManagementSummaryMetric({
    required this.label,
    required this.value,
    this.color,
  });
}

/// 一行摘要在大字号或长金额时允许横向查看。
class ManagementSummaryLine extends StatelessWidget {
  /// 摘要指标。
  final List<ManagementSummaryMetric> metrics;

  /// 首次统计尚未返回。
  final bool loading;

  /// 真实读取错误，与零数据区分。
  final String? error;

  /// 重新加载失败的统计。
  final VoidCallback? onRetry;

  /// 创建一行摘要。
  const ManagementSummaryLine({
    required this.metrics,
    this.loading = false,
    this.error,
    this.onRetry,
    super.key,
  });

  /// 保留完整数值和辅助阅读语义。
  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: <Widget>[
            Text('统计读取失败', style: Theme.of(context).textTheme.bodySmall),
            if (onRetry != null)
              OmniButton(
                label: '重试',
                onPressed: onRetry,
                variant: OmniButtonVariant.text,
              ),
          ],
        ),
      );
    }
    if (loading) return const Text('正在读取统计');
    // 当前主题文字色。
    final OmniColors colors = OmniColors.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int index = 0; index < metrics.length; index++) ...<Widget>[
            if (index > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.sm),
                child: Text('·', style: TextStyle(color: colors.muted)),
              ),
            Text.rich(
              TextSpan(
                children: <InlineSpan>[
                  TextSpan(
                    text: '${metrics[index].label} ',
                    style: TextStyle(color: colors.muted),
                  ),
                  TextSpan(
                    text: metrics[index].value,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: metrics[index].color ?? colors.ink,
                    ),
                  ),
                ],
              ),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ],
      ),
    );
  }
}

/// 一项已应用且可以独立移除的筛选。
class ManagementFilterSelection {
  /// 显示给用户的条件。
  final String label;

  /// 移除此条件。
  final VoidCallback onDeleted;

  /// 创建条件标签描述。
  const ManagementFilterSelection({
    required this.label,
    required this.onDeleted,
  });
}

/// 三个管理分区共用的搜索与筛选工具栏。
class ManagementSearchToolbar extends StatelessWidget {
  /// 业务持有的输入控制器。
  final TextEditingController controller;

  /// 当前分区的搜索提示。
  final String hintText;

  /// 更新搜索词。
  final ValueChanged<String> onChanged;

  /// 清空搜索词。
  final VoidCallback onClear;

  /// 打开筛选草稿面板。
  final VoidCallback onFilter;

  /// 非默认筛选条件数量。
  final int filterCount;

  /// 可单独移除的已应用条件。
  final List<ManagementFilterSelection> filters;

  /// 创建常驻搜索行。
  const ManagementSearchToolbar({
    required this.controller,
    required this.hintText,
    required this.onChanged,
    required this.onClear,
    required this.onFilter,
    this.filterCount = 0,
    this.filters = const <ManagementFilterSelection>[],
    super.key,
  });

  /// 让搜索拥有剩余宽度，已选条件只在存在时占据第二行。
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      OmniSpacing.md,
      0,
      OmniSpacing.md,
      OmniSpacing.xs,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: OmniTextField(
                key: const ValueKey<String>('management-search'),
                controller: controller,
                onChanged: onChanged,
                textInputAction: TextInputAction.search,
                onSubmitted: (String _) =>
                    FocusManager.instance.primaryFocus?.unfocus(),
                decoration: InputDecoration(
                  hintText: hintText,
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: controller.text.isEmpty
                      ? null
                      : OmniIconButton(
                          tooltip: '清空搜索',
                          onPressed: onClear,
                          icon: const Icon(Icons.close_rounded),
                        ),
                ),
              ),
            ),
            const SizedBox(width: OmniSpacing.xs),
            Semantics(
              label: '筛选，已选 $filterCount 项',
              child: OmniButton(
                key: const ValueKey<String>('management-filter-button'),
                label: filterCount == 0 ? '筛选' : '筛选 $filterCount',
                variant: OmniButtonVariant.text,
                onPressed: () {
                  FocusManager.instance.primaryFocus?.unfocus();
                  onFilter();
                },
              ),
            ),
          ],
        ),
        if (filters.isNotEmpty)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                for (final ManagementFilterSelection filter in filters)
                  OmniButton(
                    label: filter.label,
                    icon: Icons.close_rounded,
                    variant: OmniButtonVariant.text,
                    onPressed: filter.onDeleted,
                  ),
              ],
            ),
          ),
      ],
    ),
  );
}

/// 打开局部草稿筛选，关闭不改变已应用的条件。
Future<T?> showManagementFilterSheet<T>({
  required BuildContext context,
  required T initialValue,
  required T resetValue,
  required Widget Function(BuildContext, T, ValueChanged<T>) builder,
}) => showOmniModalBottomSheet<T>(
  context: context,
  builder: (BuildContext context) => _ManagementFilterSheet<T>(
    initialValue: initialValue,
    resetValue: resetValue,
    builder: builder,
  ),
);

/// 筛选面板维护唯一草稿，不触碰业务状态。
class _ManagementFilterSheet<T> extends StatefulWidget {
  /// 打开时的条件。
  final T initialValue;

  /// 重置后的默认条件。
  final T resetValue;

  /// 按业务维度绘制选项。
  final Widget Function(BuildContext, T, ValueChanged<T>) builder;

  /// 创建独立草稿面板。
  const _ManagementFilterSheet({
    required this.initialValue,
    required this.resetValue,
    required this.builder,
  });

  /// 创建草稿状态。
  @override
  State<_ManagementFilterSheet<T>> createState() =>
      _ManagementFilterSheetState<T>();
}

/// 应用时一次提交所有条件，其他关闭方式返回空值。
class _ManagementFilterSheetState<T> extends State<_ManagementFilterSheet<T>> {
  /// 当前未应用的筛选草稿。
  late T _draft;

  /// 复制打开时的值。
  @override
  void initState() {
    super.initState();
    _draft = widget.initialValue;
  }

  /// 固定操作栏，长选项内容独立滚动。
  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.7,
      child: Column(
        key: const ValueKey<String>('management-filter-sheet'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.md),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '筛选',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                OmniIconButton(
                  tooltip: '取消筛选',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(OmniSpacing.md),
              child: widget.builder(
                context,
                _draft,
                (T value) => setState(() => _draft = value),
              ),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(OmniSpacing.md),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: OmniButton(
                    label: '重置',
                    variant: OmniButtonVariant.secondary,
                    onPressed: () => setState(() => _draft = widget.resetValue),
                  ),
                ),
                const SizedBox(width: OmniSpacing.sm),
                Expanded(
                  child: OmniButton(
                    label: '应用',
                    onPressed: () => Navigator.of(context).pop(_draft),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// 筛选选项沿用主题且保持四十八像素点击区域。
class ManagementFilterOption extends StatelessWidget {
  /// 选项文字。
  final String label;

  /// 当前草稿是否选择本项。
  final bool selected;

  /// 更新当前草稿。
  final VoidCallback onSelected;

  /// 创建可读屏的筛选选项。
  const ManagementFilterOption({
    required this.label,
    required this.selected,
    required this.onSelected,
    super.key,
  });

  /// 展示选中样式与语义。
  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    child: OmniButton(
      label: label,
      onPressed: onSelected,
      variant: selected
          ? OmniButtonVariant.primary
          : OmniButtonVariant.secondary,
    ),
  );
}

/// 不改变布局地测量统计自然高度。
class _ManagementMeasure extends SingleChildRenderObjectWidget {
  /// 帧后报告真实尺寸。
  final ValueChanged<Size> onSize;

  /// 创建测量节点。
  const _ManagementMeasure({required this.onSize, required super.child});

  /// 创建代理渲染节点。
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _ManagementMeasureRender(onSize);

  /// 更新尺寸回调。
  @override
  void updateRenderObject(
    BuildContext context,
    _ManagementMeasureRender renderObject,
  ) => renderObject.onSize = onSize;
}

/// 报告尺寸但不触发布局期间的同步重建。
class _ManagementMeasureRender extends RenderProxyBox {
  /// 当前测量回调。
  ValueChanged<Size> onSize;

  /// 最近一次已报告尺寸。
  Size? _lastSize;

  /// 创建测量代理。
  _ManagementMeasureRender(this.onSize);

  /// 完成正常布局后报告变化。
  @override
  void performLayout() {
    super.performLayout();
    if (size == _lastSize) return;
    _lastSize = size;
    // 当前布局的稳定尺寸。
    final Size measured = size;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (attached) onSize(measured);
    });
  }
}
