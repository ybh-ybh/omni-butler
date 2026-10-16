import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/features/notes/data/note_providers.dart';
import 'package:omni_butler/features/notes/data/note_statistics.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';
import 'package:omni_butler/shared/ui/omni_windows_semantics_boundary.dart';

/// 只在正式笔记流变化时重新聚合，切换视图不会重复扫描正文。
final noteStatisticsProvider = Provider<AsyncValue<NoteStatistics>>(
  (ref) => ref.watch(notesProvider).whenData(NoteStatistics.fromNotes),
);

/// 应用内统计返回选中的归档日期，取消返回空值。
Future<String?> showNoteStatisticsDialog(BuildContext context) =>
    showOmniDialog<String>(
      context: context,
      builder: (_) => BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 3, sigmaY: 3),
        child: const WindowsNoteStatisticsDialog(),
      ),
    );

/// 记录统计专用布局，复用应用路由、主题和操作控件。
class WindowsNoteStatisticsDialog extends ConsumerStatefulWidget {
  /// 创建月历与年度统计弹窗。
  const WindowsNoteStatisticsDialog({super.key});

  /// 创建只属于本次弹窗的选择状态。
  @override
  ConsumerState<WindowsNoteStatisticsDialog> createState() =>
      _WindowsNoteStatisticsDialogState();
}

/// 两种视图共享年份，关闭后不持久化临时选择。
class _WindowsNoteStatisticsDialogState
    extends ConsumerState<WindowsNoteStatisticsDialog> {
  /// 当前是否显示年度柱状图。
  bool _annual = false;

  /// 当前选择的有效年份。
  int? _year;

  /// 年份菜单展开时反转箭头。
  bool _menuOpen = false;

  /// 切换年份或视图时回到内容起点。
  final ScrollController _scroll = ScrollController();

  /// 释放弹窗自己的滚动资源。
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 在选项变化时只更新呈现状态。
  void _change(VoidCallback change) {
    setState(change);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  /// 构建固定头部与独立滚动的统计主体。
  @override
  Widget build(BuildContext context) {
    // 与侧栏一致的正式数据，不受列表筛选影响。
    final AsyncValue<NoteStatistics> result = ref.watch(noteStatisticsProvider);
    // 只有成功集合才能初始化或纠正年份，加载和错误不重置选择。
    final NoteStatistics? statistics = result.value;
    if (!result.isLoading && !result.hasError && statistics != null) {
      if (_year == null) {
        _year = statistics.years.contains(DateTime.now().year)
            ? DateTime.now().year
            : statistics.years.firstOrNull;
      } else if (!statistics.years.contains(_year)) {
        _year = statistics.years.firstOrNull;
      }
    }
    // 弹窗大小受当前窗口约束，最小窗口仍保留可滚动内容。
    final Size viewport = MediaQuery.sizeOf(context);
    // 当前主题所有表面和文字颜色。
    final OmniColors colors = OmniColors.of(context);
    // 安卓使用完整可用宽度，七列日历在大字号下仍能容纳两位日期。
    final bool mobile = Theme.of(context).platform == TargetPlatform.android;
    return Dialog(
      key: const ValueKey('notes-statistics-dialog'),
      insetPadding: EdgeInsets.all(mobile ? 0 : 24),
      backgroundColor: colors.canvas,
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: mobile ? viewport.width : math.min(1120, viewport.width - 48),
        height: mobile ? viewport.height : math.min(780, viewport.height - 48),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: Text(
                      '记录统计',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: OmniIconButton(
                      key: const ValueKey('notes-statistics-close'),
                      tooltip: '关闭记录统计',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                ],
              ),
            ),
            Center(
              child: Theme(
                data: Theme.of(context).copyWith(
                  colorScheme: Theme.of(context).colorScheme.copyWith(
                    surface: colors.mist,
                    outline: Colors.transparent,
                    primaryContainer: colors.paper,
                    onPrimaryContainer: colors.ink,
                  ),
                ),
                child: OmniSlidingSegmentedControl<bool>(
                  options: const [false, true],
                  selected: _annual,
                  width: 244,
                  height: 38,
                  mouseCursor: SystemMouseCursors.click,
                  unselectedHoverColor: Color.alphaBlend(
                    colors.ink.withValues(alpha: 0.12),
                    colors.mist,
                  ),
                  labelBuilder: (value) => value ? '年' : '月',
                  itemKeyBuilder: (value) => ValueKey(
                    value
                        ? 'notes-statistics-year-view'
                        : 'notes-statistics-month-view',
                  ),
                  onChanged: (value) => _change(() => _annual = value),
                ),
              ),
            ),
            if (!result.isLoading &&
                !result.hasError &&
                statistics != null &&
                statistics.years.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _yearMenu(statistics),
                ),
              )
            else
              const SizedBox(height: 20),
            Expanded(child: _content(result)),
          ],
        ),
      ),
    );
  }

  /// 年份选择保留共享菜单的键盘导航、焦点恢复和窗口边缘避让。
  Widget _yearMenu(NoteStatistics statistics) => Theme(
    data: Theme.of(context).copyWith(
      hoverColor: Colors.transparent,
      focusColor: Colors.transparent,
      highlightColor: Colors.transparent,
      splashColor: Colors.transparent,
    ),
    child: OmniPopupMenuButton<int>(
      key: const ValueKey('notes-statistics-year-menu'),
      mouseCursor: SystemMouseCursors.click,
      initialValue: _year,
      onOpened: () => setState(() => _menuOpen = true),
      onCanceled: () => setState(() => _menuOpen = false),
      onSelected: (year) => _change(() {
        _year = year;
        _menuOpen = false;
      }),
      itemBuilder: (context) => [
        for (final int year in statistics.years)
          OmniPopupMenuItem<int>.custom(
            key: ValueKey('notes-statistics-option-$year'),
            value: year,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Expanded(child: Text('$year')),
                  if (year == _year)
                    Icon(
                      Icons.check_rounded,
                      size: 16,
                      color: OmniColors.of(context).brand,
                    ),
                ],
              ),
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$_year',
              key: const ValueKey('notes-statistics-selected-year'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(width: 4),
            Icon(
              _menuOpen ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
              size: 16,
              color: OmniColors.of(context).muted,
            ),
          ],
        ),
      ),
    ),
  );

  /// 加载、真实空集合与失败分开呈现。
  Widget _content(AsyncValue<NoteStatistics> result) {
    if (result.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (result.hasError) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('笔记统计加载失败'),
            OmniButton(
              label: '重试',
              variant: OmniButtonVariant.text,
              onPressed: () => ref.invalidate(notesProvider),
            ),
          ],
        ),
      );
    }
    // 成功后才使用当前有效年份。
    final NoteStatistics statistics = result.requireValue;
    if (statistics.years.isEmpty) return const Center(child: Text('暂无笔记记录'));
    // 固定本次渲染的年份，选择期间不会影响页面草稿。
    final int year = _year!;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 字号放大时卡片也增宽，从三列自然退为两列或一列。
        final double scale = math.max(
          1,
          MediaQuery.textScalerOf(context).scale(14) / 14,
        );
        // 扣除两边留白后的实际内容宽度。
        final double horizontalPadding =
            Theme.of(context).platform == TargetPlatform.android ? 8 : 24;
        // 扣除当前平台的内容安全留白。
        final double width = constraints.maxWidth - horizontalPadding * 2;
        // 卡片之间保持截图中的均匀留白。
        final int columns = ((width + 20) / (300 * scale + 20)).floor().clamp(
          1,
          3,
        );
        // 同一行卡片均分空间。
        final double cardWidth = (width - (columns - 1) * 20) / columns;
        // 当前年仅展示已经到来的月份；历史年展示完整十二月。
        final int lastMonth = year == DateTime.now().year
            ? DateTime.now().month
            : 12;
        return SingleChildScrollView(
          key: const ValueKey('notes-statistics-scroll'),
          controller: _scroll,
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            0,
            horizontalPadding,
            24,
          ),
          child: Wrap(
            spacing: 20,
            runSpacing: 20,
            children: _annual
                ? [
                    for (int metric = 0; metric < 3; metric++)
                      SizedBox(
                        width: cardWidth,
                        child: _AnnualCard(
                          statistics: statistics,
                          year: year,
                          metric: metric,
                        ),
                      ),
                  ]
                : [
                    for (int month = lastMonth; month >= 1; month--)
                      SizedBox(
                        width: cardWidth,
                        child: _MonthCard(
                          statistics: statistics,
                          year: year,
                          month: month,
                        ),
                      ),
                  ],
          ),
        );
      },
    );
  }
}

/// 单月日历保留日期数字与六周方块，不使用旧侧栏热图的缩放和光晕。
class _MonthCard extends StatelessWidget {
  /// 创建当前月份卡片。
  const _MonthCard({
    required this.statistics,
    required this.year,
    required this.month,
  });

  /// 全量统计快照。
  final NoteStatistics statistics;

  /// 归档年份。
  final int year;

  /// 归档月份。
  final int month;

  /// 构建月份摘要和从周一开始的完整网格。
  @override
  Widget build(BuildContext context) {
    // 当前月份的三项合计。
    final NoteStatisticsTotals totals = statistics.month(year, month);
    // 当前主题颜色。
    final OmniColors colors = OmniColors.of(context);
    // 月初前的空占位个数。
    final int offset = DateTime(year, month).weekday - 1;
    // 自然月天数，自动覆盖闰年。
    final int length = DateTime(year, month + 1, 0).day;
    // 用年度最高日篇数统一各月热力强度。
    final int maxCount = statistics.dates.entries
        .where((entry) => entry.key.startsWith('$year-'))
        .fold(1, (value, entry) => math.max(value, entry.value.count));
    // 放大字号时为日期数字保留额外垂直空间。
    final double rowHeight =
        60 + math.max(0, MediaQuery.textScalerOf(context).scale(12) - 12);
    return OmniPanel(
      key: ValueKey('notes-statistics-month-$year-$month'),
      showBorder: false,
      padding: EdgeInsets.all(
        Theme.of(context).platform == TargetPlatform.android ? 8 : 18,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${month.toString().padLeft(2, '0')} 月',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              for (final String label in [
                '${totals.count}笔记',
                '${totals.words}字数',
                '${totals.days}记录天数',
              ])
                Expanded(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(fontSize: 11, color: colors.muted),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (final String label in const [
                '一',
                '二',
                '三',
                '四',
                '五',
                '六',
                '日',
              ])
                Expanded(
                  child: Center(
                    child: Text(
                      label,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(fontSize: 11),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          for (int week = 0; week < 6; week++)
            SizedBox(
              height: rowHeight,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (int weekday = 0; weekday < 7; weekday++)
                    Expanded(
                      child: Builder(
                        builder: (context) {
                          // 网格位置转为当月自然日，范围外只保留布局。
                          final int day = week * 7 + weekday - offset + 1;
                          if (day < 1 || day > length) {
                            return const SizedBox.shrink();
                          }
                          // 归档日期保持稳定字符串，不经过时区转换。
                          final String dayKey =
                              '$year-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
                          return Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal:
                                  Theme.of(context).platform ==
                                      TargetPlatform.android
                                  ? 0
                                  : 4,
                            ),
                            child: _StatisticsDay(
                              dayKey: dayKey,
                              day: day,
                              totals:
                                  statistics.dates[dayKey] ??
                                  const NoteStatisticsTotals(),
                              maxCount: maxCount,
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 每个日期独立更新悬停，不重建全弹窗或其语义父节点。
class _StatisticsDay extends StatefulWidget {
  /// 创建绑定到业务自然日的方块。
  const _StatisticsDay({
    required this.dayKey,
    required this.day,
    required this.totals,
    required this.maxCount,
  });

  /// 点击后返回的归档日期。
  final String dayKey;

  /// 方块上方的日期数字。
  final int day;

  /// 当前自然日统计。
  final NoteStatisticsTotals totals;

  /// 年内最高日篇数。
  final int maxCount;

  /// 创建鼠标和键盘状态。
  @override
  State<_StatisticsDay> createState() => _StatisticsDayState();
}

/// 空日期只描边，有记录日期才提供动作和提示。
class _StatisticsDayState extends State<_StatisticsDay> {
  /// 鼠标当前是否位于方块上。
  bool _hovered = false;

  /// 键盘焦点使用同样的主题轮廓。
  bool _focused = false;

  /// 构建具有真实光标与可访问日期说明的日历格。
  @override
  Widget build(BuildContext context) {
    // 当前日期是否存在可筛选的正式笔记。
    final bool enabled = widget.totals.count > 0;
    // 当前配色下的边框和热力色。
    final OmniColors colors = OmniColors.of(context);
    // 只有有效日期向页面返回选择结果。
    void select() => Navigator.of(context).pop(widget.dayKey);
    // 日期方块，不让空日期具有可点击语义或键盘焦点。
    final Widget square = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        key: ValueKey('notes-statistics-day-${widget.dayKey}'),
        duration: OmniMotion.duration(context, OmniMotion.fast),
        curve: OmniMotion.standardCurve,
        height: 32,
        decoration: BoxDecoration(
          color: enabled
              ? colors.brand.withValues(
                  alpha: 0.1 + 0.18 * widget.totals.count / widget.maxCount,
                )
              : colors.line.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(OmniRadius.tiny),
          border: Border.all(
            color: _hovered || _focused ? colors.brand : Colors.transparent,
          ),
        ),
        child: enabled
            ? OmniInkWell(
                onTap: select,
                onFocusChange: (value) => setState(() => _focused = value),
                mouseCursor: SystemMouseCursors.click,
                borderRadius: BorderRadius.circular(OmniRadius.tiny),
                child: const SizedBox.expand(),
              )
            : null,
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExcludeSemantics(
          child: Text(
            '${widget.day}',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(fontSize: 12),
          ),
        ),
        const SizedBox(height: 2),
        Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: 32,
            child: AspectRatio(
              aspectRatio: 1,
              child: OmniWindowsSemanticsBoundary(
                child: Semantics(
                  container: true,
                  button: enabled,
                  label:
                      '${widget.dayKey}，${widget.totals.count}篇笔记，${widget.totals.words}字',
                  child: enabled
                      ? Tooltip(
                          message:
                              '${widget.totals.count}笔记·${widget.totals.words}字',
                          excludeFromSemantics: true,
                          preferBelow: false,
                          child: square,
                        )
                      : square,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 按月展示年度三项指标，保持零值为真正的零高度。
class _AnnualCard extends StatelessWidget {
  /// 创建某一项指标的年度图。
  const _AnnualCard({
    required this.statistics,
    required this.year,
    required this.metric,
  });

  /// 同一份日月年聚合快照。
  final NoteStatistics statistics;

  /// 当前归档年份。
  final int year;

  /// 篇数、字数、记录天数三个指标的索引。
  final int metric;

  /// 从统一汇总读取当前指标。
  int _value(NoteStatisticsTotals totals) => switch (metric) {
    0 => totals.count,
    1 => totals.words,
    _ => totals.days,
  };

  /// 使用易读的十进制刻度，小计数保持整数，不出现21、42等不规则间距。
  int _tickStep(int maximum) {
    // 七个区间近似参考图的纵轴密度。
    final double rough = maximum / 7;
    // 根据数据量级选取1、2、5系列刻度。
    final double magnitude = math
        .pow(10, (math.log(rough) / math.ln10).floor())
        .toDouble();
    // 小数刻度最终至少提升到一个完整单位。
    final num multiple = const [
      1,
      2,
      5,
      10,
    ].firstWhere((value) => value * magnitude >= rough);
    return math.max(1, (multiple * magnitude).round());
  }

  /// 构建右侧刻度与十二个月柱状分布。
  @override
  Widget build(BuildContext context) {
    // 当前主题图表的语义色。
    final OmniColors colors = OmniColors.of(context);
    // 三项指标对应截图中的蓝、绿、红。
    final Color color = [colors.info, colors.success, colors.danger][metric];
    // 指标使用各自单位。
    final String unit = ['条笔记', '字', '天'][metric];
    // 每个月都保留横轴位置。
    final List<int> values = [
      for (int month = 1; month <= 12; month++)
        _value(statistics.month(year, month)),
    ];
    // 刻度采用整数并避免全零除法。
    final int maximum = values.fold(1, math.max);
    // 刻度清晰易读，篇数和天数不会出现分数单位。
    final int step = _tickStep(maximum);
    // 顶部刻度向上取整以容纳最高柱。
    final int top = (maximum / step).ceil() * step;
    return OmniPanel(
      key: ValueKey('notes-statistics-annual-$metric'),
      showBorder: false,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '${_value(statistics.annual[year]!)}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                TextSpan(
                  text: ' $unit',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colors.muted),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  children: [
                    SizedBox(
                      height: 176,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          for (int index = 0; index < 12; index++)
                            Expanded(
                              child: Semantics(
                                label: '${index + 1}月，${values[index]}$unit',
                                child: Align(
                                  alignment: Alignment.bottomCenter,
                                  child: Container(
                                    key: ValueKey(
                                      'notes-statistics-bar-$metric-${index + 1}',
                                    ),
                                    width: 15,
                                    height: 176 * values[index] / top,
                                    decoration: BoxDecoration(
                                      color: color,
                                      borderRadius: BorderRadius.circular(
                                        OmniRadius.tiny,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        for (int month = 1; month <= 12; month++)
                          Expanded(
                            child: Text(
                              month.toString().padLeft(2, '0'),
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(fontSize: 10),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ExcludeSemantics(
                child: SizedBox(
                  width: 1,
                  height: 176,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (int dash = 0; dash < 32; dash++)
                        SizedBox(
                          height: 2,
                          child: ColoredBox(color: colors.line),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 184,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (int tick = top; tick >= 0; tick -= step)
                      Text(
                        '$tick',
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(fontSize: 10),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
