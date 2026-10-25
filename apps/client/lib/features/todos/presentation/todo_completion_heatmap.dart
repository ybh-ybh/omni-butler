import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/todos/data/todo_completion_summary.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';
import 'package:omni_butler/shared/ui/omni_windows_semantics_boundary.dart';

/// 以当前主题色显示最近三百六十五个自然日的完成数量。
class TodoCompletionHeatmap extends StatefulWidget {
  /// 未受列表筛选影响的完整统计。
  final TodoCompletionSummary summary;

  /// 当前单日筛选，空值表示范围或全部日期。
  final DateTime? selectedDay;

  /// 点击日期后筛选当天完成记录。
  final ValueChanged<DateTime> onDaySelected;

  /// 创建完成热力图。
  const TodoCompletionHeatmap({
    required this.summary,
    required this.onDaySelected,
    this.selectedDay,
    super.key,
  });

  /// 创建横向滚动状态。
  @override
  State<TodoCompletionHeatmap> createState() => _TodoCompletionHeatmapState();
}

/// 小窗口首次打开时将今天保持在可见范围内。
class _TodoCompletionHeatmapState extends State<TodoCompletionHeatmap> {
  /// 横向图表滚动控制器。
  final ScrollController _controller = ScrollController();

  /// 首次布局后只定位一次，后续刷新不打断浏览。
  bool _positioned = false;

  /// 释放横向滚动控制器。
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 构建月份、固定星期标签与可横向滚动的全年网格。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 五档完成数量的固定颜色，随当前配色和明暗主题变化。
    final List<Color> levels = <Color>[
      colors.mist,
      Color.lerp(colors.paper, colors.brand, 0.22)!,
      Color.lerp(colors.paper, colors.brand, 0.46)!,
      Color.lerp(colors.paper, colors.brand, 0.72)!,
      colors.brand,
    ];
    // 完整窗口第一天。
    final DateTime first = widget.summary.firstHeatmapDay;
    // 以周一对齐后的第一列日期。
    final DateTime aligned = completionDayOffset(first, 1 - first.weekday);
    // 三百六十五天最多占五十三个星期列。
    final int columns = (364 + first.weekday - 1) ~/ 7 + 1;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 月份标签随系统字号扩展高度。
        final double labelHeight = MediaQuery.textScalerOf(context).scale(24);
        // 常规字号使用十六像素日期格，放大字号时同步增大。
        final double cell = MediaQuery.textScalerOf(context).scale(16);
        // 六像素间距使相邻日期的悬停范围更容易辨认。
        const double gap = 6;
        // 每列包含日期格与间距。
        final double pitch = cell + gap;
        // 星期标签固定在横向滚动区域之外，大字号保留足够宽度。
        final double weekdayWidth = MediaQuery.textScalerOf(context).scale(36);
        if (!_positioned) {
          _positioned = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !_controller.hasClients) return;
            _controller.jumpTo(_controller.position.maxScrollExtent);
          });
        }
        return Align(
          alignment: Alignment.center,
          child: SizedBox(
            key: const ValueKey<String>('todo-completion-heatmap-viewport'),
            width: math.min(
              constraints.maxWidth,
              weekdayWidth + OmniSpacing.xs + columns * pitch + OmniSpacing.xs,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(
                  key: const ValueKey<String>('todo-completion-weekdays'),
                  width: weekdayWidth,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: OmniSpacing.xxs,
                    ),
                    child: Column(
                      children: <Widget>[
                        SizedBox(height: labelHeight),
                        for (int row = 0; row < 7; row += 1)
                          Padding(
                            padding: const EdgeInsets.only(bottom: gap),
                            child: SizedBox(
                              key: ValueKey<String>(
                                'todo-completion-weekday-$row',
                              ),
                              height: cell,
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  _weekdayLabel(row),
                                  maxLines: 1,
                                  softWrap: false,
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(color: colors.muted),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: OmniSpacing.xs),
                Expanded(
                  child: SingleChildScrollView(
                    key: const ValueKey<String>(
                      'todo-completion-heatmap-scroll',
                    ),
                    controller: _controller,
                    scrollDirection: Axis.horizontal,
                    // 视口留出光晕边距并裁剪旧日期，防止覆盖固定星期标签。
                    padding: const EdgeInsets.all(OmniSpacing.xxs),
                    clipBehavior: Clip.hardEdge,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        for (int column = 0; column < columns; column += 1)
                          SizedBox(
                            width: pitch,
                            child: Column(
                              children: <Widget>[
                                SizedBox(
                                  height: labelHeight,
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      _monthLabel(aligned, column),
                                      softWrap: false,
                                      overflow: TextOverflow.visible,
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(color: colors.muted),
                                    ),
                                  ),
                                ),
                                for (int row = 0; row < 7; row += 1)
                                  Padding(
                                    padding: const EdgeInsets.only(
                                      right: gap,
                                      bottom: gap,
                                    ),
                                    child: _buildDay(
                                      completionDayOffset(
                                        aligned,
                                        column * 7 + row,
                                      ),
                                      cell,
                                      levels,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 星期列仅显示周一、周四和周日，对齐对应日期行。
  String _weekdayLabel(int row) => switch (row) {
    0 => '周一',
    3 => '周四',
    6 => '周日',
    _ => '',
  };

  /// 在跨入新月份的星期列上显示月份名称。
  String _monthLabel(DateTime aligned, int column) {
    // 当前星期第一天。
    final DateTime start = completionDayOffset(aligned, column * 7);
    // 当前星期最后一天。
    final DateTime end = completionDayOffset(start, 6);
    if (start.month != end.month) return '${end.month}月';
    if (start.day == 1) return '${start.month}月';
    return '';
  }

  /// 范围外只占位，零完成日期悬停反馈但不执行点击。
  Widget _buildDay(DateTime day, double cell, List<Color> levels) {
    if (day.isBefore(widget.summary.firstHeatmapDay) ||
        day.isAfter(widget.summary.today)) {
      return SizedBox.square(dimension: cell);
    }
    // 当天真实完成数量。
    final int count = widget.summary.dayCounts[day] ?? 0;
    // 固定分档保证不同日期和筛选状态可比较。
    final int level = count == 0
        ? 0
        : count <= 2
        ? 1
        : count <= 5
        ? 2
        : count <= 9
        ? 3
        : 4;
    return _CompletionHeatmapDay(
      key: ValueKey<String>('todo-completion-day-${businessDayKey(day)}'),
      day: day,
      count: count,
      color: levels[level],
      size: cell,
      selected: day == widget.selectedDay,
      outlined: day == widget.selectedDay || day == widget.summary.today,
      onTap: () => widget.onDaySelected(day),
    );
  }
}

/// 日期格同时支持鼠标和键盘说明，不只依赖颜色。
class _CompletionHeatmapDay extends StatefulWidget {
  /// 对应本地自然日。
  final DateTime day;

  /// 当日完成数。
  final int count;

  /// 当前分档颜色。
  final Color color;

  /// 日期格边长。
  final double size;

  /// 是否是当前单日筛选。
  final bool selected;

  /// 今天和选中日期沿用笔记页的常态边框。
  final bool outlined;

  /// 激活日期筛选。
  final VoidCallback onTap;

  /// 创建可聚焦的日期格。
  const _CompletionHeatmapDay({
    required this.day,
    required this.count,
    required this.color,
    required this.size,
    required this.selected,
    required this.outlined,
    required this.onTap,
    super.key,
  });

  /// 创建提示及焦点状态。
  @override
  State<_CompletionHeatmapDay> createState() => _CompletionHeatmapDayState();
}

/// 焦点进入时显示与悬停相同的完成数量。
class _CompletionHeatmapDayState extends State<_CompletionHeatmapDay> {
  /// 保留跨刷新稳定的提示身份。
  final GlobalKey<TooltipState> _tooltipKey = GlobalKey<TooltipState>();

  /// 每个格子独立维护悬停，避免重建全部日期。
  bool _hovered = false;

  /// 反向悬停从当前呈现值继续动画。
  void _hover(bool value) {
    if (mounted) setState(() => _hovered = value);
  }

  /// 构建真实可交互的日期格。
  @override
  Widget build(BuildContext context) {
    // 与笔记热力图共用主题色、动效时长和曲线。
    final OmniColors colors = OmniColors.of(context);
    // 空日期没有提示、光晕或筛选动作。
    final bool active = widget.count > 0;
    // 有记录的悬停格才显示光晕。
    final bool glowing = _hovered && active;
    // 减少动画时停止缩放，颜色仍提供即时反馈。
    final Duration motion = OmniMotion.duration(context, OmniMotion.fast);
    // 读屏和悬停共用完整日期及数量。
    final String label =
        '${DateFormat('yyyy年M月d日').format(widget.day)} · 完成 ${widget.count} 项';
    // 固定点击布局尺寸，放大不推动相邻日期。
    final Widget cell = SizedBox.square(
      dimension: widget.size,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => _hover(true),
        onExit: (_) => _hover(false),
        child: Semantics(
          label: label,
          button: active,
          selected: widget.selected,
          child: OmniInkWell(
            mouseCursor: SystemMouseCursors.click,
            borderRadius: BorderRadius.circular(OmniRadius.tiny),
            onTap: active ? widget.onTap : null,
            canRequestFocus: active,
            onFocusChange: (bool focused) {
              if (focused) {
                Scrollable.ensureVisible(context);
                _tooltipKey.currentState?.ensureTooltipVisible();
              } else {
                Tooltip.dismissAllToolTips();
              }
            },
            child: AnimatedScale(
              key: ValueKey<String>(
                'todo-completion-scale-${businessDayKey(widget.day)}',
              ),
              scale: _hovered && !OmniMotion.reduce(context) ? 1.2 : 1,
              duration: motion,
              curve: OmniMotion.standardCurve,
              child: AnimatedContainer(
                key: ValueKey<String>(
                  'todo-completion-fill-${businessDayKey(widget.day)}',
                ),
                duration: motion,
                curve: OmniMotion.standardCurve,
                decoration: BoxDecoration(
                  color: widget.color,
                  borderRadius: BorderRadius.circular(OmniRadius.tiny),
                  border: widget.outlined || glowing
                      ? Border.all(color: colors.brand)
                      : null,
                  boxShadow: glowing
                      ? <BoxShadow>[
                          BoxShadow(
                            color: colors.brand.withValues(alpha: 0.42),
                            blurRadius: OmniSpacing.xs,
                          ),
                        ]
                      : const <BoxShadow>[],
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      ),
    );
    return active
        ? OmniWindowsSemanticsBoundary(
            child: Tooltip(
              key: _tooltipKey,
              message: label,
              excludeFromSemantics: true,
              child: cell,
            ),
          )
        : cell;
  }
}
