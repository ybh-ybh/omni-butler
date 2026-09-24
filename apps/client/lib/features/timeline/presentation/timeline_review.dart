import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 时间管理页面的工作模式。
enum TimelineViewMode {
  /// 以统计和规律发现为主的复盘模式。
  review,

  /// 以补录和编辑为主的明细模式。
  details,
}

/// 时间复盘的统计周期。
enum TimelineStatsPeriod {
  /// 单个自然日。
  day,

  /// 周一至周日。
  week,

  /// 单个自然月。
  month,
}

/// 时间复盘主体。
class TimelineReviewContent extends ConsumerWidget {
  /// 当前统计周期记录。
  final List<TimeEntryRecord> records;

  /// 上一统计周期记录。
  final List<TimeEntryRecord> previousRecords;

  /// 当前范围起点。
  final DateTime rangeStart;

  /// 当前范围终点。
  final DateTime rangeEnd;

  /// 当前统计周期。
  final TimelineStatsPeriod period;

  /// 滚动内容底部需要避让的安全距离。
  final double safeBottomPadding;

  /// 打开指定自然日的回调。
  final ValueChanged<DateTime> onOpenDay;

  /// 编辑时间记录的回调。
  final ValueChanged<TimeEntryRecord> onEdit;

  /// 创建时间复盘主体。
  const TimelineReviewContent({
    required this.records,
    required this.previousRecords,
    required this.rangeStart,
    required this.rangeEnd,
    required this.period,
    required this.onOpenDay,
    required this.onEdit,
    this.safeBottomPadding = 0,
    super.key,
  });

  /// 构建周期摘要、时间指纹与对比统计。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 时间记录仓储。
    final repository = ref.watch(timeEntryRepositoryProvider);
    // 当前周期分类汇总。
    final Map<String, int> summary = repository.summarizeByCategory(records);
    // 上一周期分类汇总。
    final Map<String, int> previousSummary = repository.summarizeByCategory(
      previousRecords,
    );
    // 当前时间类别。
    final List<TaxonomyEntry> categories =
        ref
            .watch(
              taxonomyEntriesProvider((
                TaxonomyModule.timeline,
                TaxonomyKind.category,
              )),
            )
            .asData
            ?.value ??
        const <TaxonomyEntry>[];
    // 时间类别颜色映射。
    final Map<String, Color> categoryColors = <String, Color>{
      for (final TaxonomyEntry category in categories)
        category.name: Color(category.colorValue),
    };
    // 当前周期记录分钟数。
    final int trackedMinutes = _sumMinutes(records);
    // 上一周期记录分钟数。
    final int previousTrackedMinutes = _sumMinutes(previousRecords);
    // 当前周期包含的自然日数量。
    final int dayCount = rangeEnd.difference(rangeStart).inDays;
    // 当前周期完整自然时间容量。
    final int capacityMinutes = dayCount * 1440;
    // 当前周期记录覆盖率。
    final int coveragePercent = capacityMinutes == 0
        ? 0
        : (trackedMinutes / capacityMinutes * 100).round().clamp(0, 100);
    // 当前周期耗时最多的类别。
    final MapEntry<String, int>? dominantCategory = _dominantEntry(summary);
    // 当前周期平均每段记录分钟数。
    final int averageMinutes = records.isEmpty
        ? 0
        : (trackedMinutes / records.length).round();
    // 当前周期相对上一周期的总时长变化。
    final int totalDelta = trackedMinutes - previousTrackedMinutes;
    // 指标条数据。
    final List<_TimelineMetricData> metrics = <_TimelineMetricData>[
      _TimelineMetricData(
        label: '已记录',
        value: _formatDuration(trackedMinutes),
        detail: previousRecords.isEmpty
            ? '上一周期暂无记录'
            : '${_comparisonLabel(period)} ${_formatSignedDuration(totalDelta)}',
        icon: Icons.schedule_rounded,
      ),
      _TimelineMetricData(
        label: '记录覆盖率',
        value: '$coveragePercent%',
        detail: '按完整自然时间计算',
        icon: Icons.donut_large_rounded,
      ),
      _TimelineMetricData(
        label: '主要投入',
        value: dominantCategory?.key ?? '暂无',
        detail: dominantCategory == null || trackedMinutes == 0
            ? '记录后显示类别分布'
            : '${_formatDuration(dominantCategory.value)} · ${(dominantCategory.value / trackedMinutes * 100).round()}%',
        icon: Icons.flag_outlined,
      ),
      _TimelineMetricData(
        label: '平均每段',
        value: records.isEmpty ? '暂无' : _formatDuration(averageMinutes),
        detail: '${records.length} 段记录',
        icon: Icons.segment_rounded,
      ),
    ];

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 当前内容区是否足以并排展示统计面板。
        final bool twoColumns = constraints.maxWidth >= 880;
        // 类别结构面板。
        final Widget categoryPanel = _CategoryStructurePanel(
          summary: summary,
          previousSummary: previousSummary,
          categoryColors: categoryColors,
          period: period,
        );
        // 每日或分时趋势面板。
        final Widget trendPanel = _TimeTrendPanel(
          records: records,
          rangeStart: rangeStart,
          rangeEnd: rangeEnd,
          period: period,
        );
        // 填满可用高度的时间复盘滚动视图。
        final Widget scrollView = CustomScrollView(
          key: const ValueKey<String>('timeline-review-content'),
          slivers: <Widget>[
            SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _TimelineInsightBanner(
                    text: _buildInsight(
                      records: records,
                      previousRecords: previousRecords,
                      summary: summary,
                      previousSummary: previousSummary,
                      period: period,
                    ),
                    hasRecords: records.isNotEmpty,
                  ),
                  const SizedBox(height: OmniSpacing.xs),
                  _TimelineMetricsPanel(metrics: metrics),
                  const SizedBox(height: OmniSpacing.xs),
                  _TimeFingerprintPanel(
                    records: records,
                    rangeStart: rangeStart,
                    rangeEnd: rangeEnd,
                    period: period,
                    categoryColors: categoryColors,
                    onOpenDay: onOpenDay,
                    onEdit: onEdit,
                  ),
                ],
              ),
            ),
            if (twoColumns)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: const EdgeInsets.only(top: OmniSpacing.xs),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Expanded(flex: 7, child: categoryPanel),
                      const SizedBox(width: OmniSpacing.xs),
                      Expanded(flex: 5, child: trendPanel),
                    ],
                  ),
                ),
              )
            else
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const SizedBox(height: OmniSpacing.xs),
                    categoryPanel,
                    const SizedBox(height: OmniSpacing.xs),
                    trendPanel,
                  ],
                ),
              ),
            if (safeBottomPadding > 0)
              SliverToBoxAdapter(child: SizedBox(height: safeBottomPadding)),
          ],
        );
        if (safeBottomPadding > 0) {
          return scrollView;
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: OmniSpacing.md),
          child: scrollView,
        );
      },
    );
  }
}

/// 单个摘要指标的数据。
class _TimelineMetricData {
  /// 指标名称。
  final String label;

  /// 指标值。
  final String value;

  /// 指标补充说明。
  final String detail;

  /// 指标图标。
  final IconData icon;

  /// 创建摘要指标数据。
  const _TimelineMetricData({
    required this.label,
    required this.value,
    required this.detail,
    required this.icon,
  });
}

/// 周期洞察提示条。
class _TimelineInsightBanner extends StatelessWidget {
  /// 洞察文案。
  final String text;

  /// 当前周期是否存在记录。
  final bool hasRecords;

  /// 创建周期洞察提示条。
  const _TimelineInsightBanner({required this.text, required this.hasRecords});

  /// 构建一条克制的确定性洞察。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Semantics(
      key: const ValueKey<String>('timeline-insight'),
      label: text,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: hasRecords ? colors.brandSoft : colors.paper,
          borderRadius: BorderRadius.circular(OmniRadius.panel),
          border: Border.all(
            color: hasRecords
                ? colors.brand.withValues(alpha: 0.22)
                : colors.line,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: OmniSpacing.md,
            vertical: OmniSpacing.sm,
          ),
          child: Row(
            children: <Widget>[
              Icon(
                hasRecords ? Icons.auto_graph_rounded : Icons.timeline_rounded,
                size: OmniSize.icon,
                color: hasRecords ? colors.brand : colors.muted,
              ),
              const SizedBox(width: OmniSpacing.sm),
              Expanded(
                child: Text(
                  text,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: hasRecords ? colors.brandStrong : colors.muted,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 周期摘要指标条。
class _TimelineMetricsPanel extends StatelessWidget {
  /// 待展示指标。
  final List<_TimelineMetricData> metrics;

  /// 创建周期摘要指标条。
  const _TimelineMetricsPanel({required this.metrics});

  /// 构建两列或四列摘要指标。
  @override
  Widget build(BuildContext context) {
    return OmniPanel(
      key: const ValueKey<String>('timeline-metrics'),
      padding: const EdgeInsets.symmetric(
        horizontal: OmniSpacing.xs,
        vertical: OmniSpacing.sm,
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // 当前行展示的指标列数。
          final int columnCount = constraints.maxWidth >= 720 ? 4 : 2;
          // 单个指标可用宽度。
          final double itemWidth = constraints.maxWidth / columnCount;
          return Wrap(
            children: <Widget>[
              for (int index = 0; index < metrics.length; index += 1)
                SizedBox(
                  width: itemWidth,
                  child: _TimelineMetricCell(
                    metric: metrics[index],
                    showLeftBorder: index % columnCount != 0,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// 单个周期摘要指标。
class _TimelineMetricCell extends StatelessWidget {
  /// 当前指标数据。
  final _TimelineMetricData metric;

  /// 是否展示左侧分隔线。
  final bool showLeftBorder;

  /// 创建单个周期摘要指标。
  const _TimelineMetricCell({
    required this.metric,
    required this.showLeftBorder,
  });

  /// 构建紧凑指标内容。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 76),
      padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.sm),
      decoration: BoxDecoration(
        border: showLeftBorder
            ? Border(left: BorderSide(color: colors.line))
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(metric.icon, size: 14, color: colors.muted),
              const SizedBox(width: OmniSpacing.xxs),
              Expanded(
                child: Text(
                  metric.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: OmniSpacing.xxs),
          Text(
            metric.value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
          Text(
            metric.detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}

/// 时间指纹面板。
class _TimeFingerprintPanel extends StatelessWidget {
  /// 当前统计周期记录。
  final List<TimeEntryRecord> records;

  /// 当前范围起点。
  final DateTime rangeStart;

  /// 当前范围终点。
  final DateTime rangeEnd;

  /// 当前统计周期。
  final TimelineStatsPeriod period;

  /// 时间类别颜色映射。
  final Map<String, Color> categoryColors;

  /// 打开指定自然日的回调。
  final ValueChanged<DateTime> onOpenDay;

  /// 编辑时间记录的回调。
  final ValueChanged<TimeEntryRecord> onEdit;

  /// 创建时间指纹面板。
  const _TimeFingerprintPanel({
    required this.records,
    required this.rangeStart,
    required this.rangeEnd,
    required this.period,
    required this.categoryColors,
    required this.onOpenDay,
    required this.onEdit,
  });

  /// 构建随周期改变形态的时间指纹。
  @override
  Widget build(BuildContext context) {
    // 当前指纹说明。
    final String description = switch (period) {
      TimelineStatsPeriod.day => '颜色表示类别，灰色表示尚未记录的时间',
      TimelineStatsPeriod.week => '对齐七天的 24 小时，查看重复出现的时间节律',
      TimelineStatsPeriod.month => '每格代表一天，底部微缩条保留当天的时间分布',
    };
    return OmniPanel(
      key: const ValueKey<String>('timeline-fingerprint'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _PanelHeading(title: '时间指纹', description: description),
          const SizedBox(height: OmniSpacing.md),
          if (period == TimelineStatsPeriod.month)
            _MonthFingerprint(
              records: records,
              rangeStart: rangeStart,
              rangeEnd: rangeEnd,
              categoryColors: categoryColors,
              onOpenDay: onOpenDay,
            )
          else
            _TimelineFingerprintRows(
              records: records,
              rangeStart: rangeStart,
              rangeEnd: rangeEnd,
              period: period,
              categoryColors: categoryColors,
              onOpenDay: onOpenDay,
              onEdit: onEdit,
            ),
        ],
      ),
    );
  }
}

/// 日或周时间指纹行组。
class _TimelineFingerprintRows extends StatelessWidget {
  /// 当前统计周期记录。
  final List<TimeEntryRecord> records;

  /// 当前范围起点。
  final DateTime rangeStart;

  /// 当前范围终点。
  final DateTime rangeEnd;

  /// 当前统计周期。
  final TimelineStatsPeriod period;

  /// 时间类别颜色映射。
  final Map<String, Color> categoryColors;

  /// 打开指定自然日的回调。
  final ValueChanged<DateTime> onOpenDay;

  /// 编辑时间记录的回调。
  final ValueChanged<TimeEntryRecord> onEdit;

  /// 创建日或周时间指纹行组。
  const _TimelineFingerprintRows({
    required this.records,
    required this.rangeStart,
    required this.rangeEnd,
    required this.period,
    required this.categoryColors,
    required this.onOpenDay,
    required this.onEdit,
  });

  /// 构建带统一时间刻度的多日轨道。
  @override
  Widget build(BuildContext context) {
    // 当前范围内的自然日。
    final List<DateTime> days = _daysInRange(rangeStart, rangeEnd);
    return Column(
      key: ValueKey<String>('timeline-${period.name}-fingerprint'),
      children: <Widget>[
        const _FingerprintScale(),
        const SizedBox(height: OmniSpacing.xxs),
        for (final DateTime day in days) ...<Widget>[
          _FingerprintDayRow(
            day: day,
            records: records
                .where(
                  (TimeEntryRecord record) =>
                      DateUtils.isSameDay(record.entryDate, day),
                )
                .toList(growable: false),
            tall: period == TimelineStatsPeriod.day,
            categoryColors: categoryColors,
            onOpenDay: () => onOpenDay(day),
            onEdit: onEdit,
          ),
          if (day != days.last) const SizedBox(height: OmniSpacing.xs),
        ],
      ],
    );
  }
}

/// 时间指纹共用刻度。
class _FingerprintScale extends StatelessWidget {
  /// 创建时间指纹共用刻度。
  const _FingerprintScale();

  /// 构建 00 至 24 点刻度。
  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        const SizedBox(width: 72),
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              for (final String label in const <String>[
                '00',
                '06',
                '12',
                '18',
                '24',
              ])
                Text(label, style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
        ),
      ],
    );
  }
}

/// 单日时间指纹轨道。
class _FingerprintDayRow extends StatelessWidget {
  /// 当前自然日。
  final DateTime day;

  /// 当天记录。
  final List<TimeEntryRecord> records;

  /// 是否使用加高轨道。
  final bool tall;

  /// 时间类别颜色映射。
  final Map<String, Color> categoryColors;

  /// 打开当天明细的回调。
  final VoidCallback onOpenDay;

  /// 编辑时间记录的回调。
  final ValueChanged<TimeEntryRecord> onEdit;

  /// 创建单日时间指纹轨道。
  const _FingerprintDayRow({
    required this.day,
    required this.records,
    required this.tall,
    required this.categoryColors,
    required this.onOpenDay,
    required this.onEdit,
  });

  /// 构建日期标签与真实比例时间段。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前轨道高度。
    final double trackHeight = tall ? 38 : 24;
    return Row(
      children: <Widget>[
        SizedBox(
          width: 72,
          child: InkWell(
            borderRadius: BorderRadius.circular(OmniRadius.control),
            onTap: onOpenDay,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: OmniSpacing.xxs),
              child: Text(
                _dayLabel(day),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              // 当前轨道可用宽度。
              final double width = constraints.maxWidth;
              return SizedBox(
                height: trackHeight,
                child: Material(
                  color: colors.mist,
                  borderRadius: BorderRadius.circular(OmniRadius.control),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: onOpenDay,
                    child: Stack(
                      children: <Widget>[
                        for (final double ratio in const <double>[
                          0.25,
                          0.5,
                          0.75,
                        ])
                          Positioned(
                            left: width * ratio,
                            top: 0,
                            bottom: 0,
                            child: ColoredBox(
                              color: colors.line.withValues(alpha: 0.65),
                              child: const SizedBox(width: 1),
                            ),
                          ),
                        for (final TimeEntryRecord record in records)
                          Positioned(
                            left: record.startMinute / 1440 * width,
                            width: math.max(
                              2,
                              (record.endMinute - record.startMinute) /
                                  1440 *
                                  width,
                            ),
                            top: 0,
                            bottom: 0,
                            child: Tooltip(
                              message:
                                  '${_formatClock(record.startMinute)}–${_formatClock(record.endMinute)}\n${record.activity}${record.category == null ? '' : ' · ${record.category}'}',
                              child: Material(
                                color:
                                    categoryColors[record.category] ??
                                    colors.time,
                                child: InkWell(
                                  onTap: () => onEdit(record),
                                  child:
                                      tall &&
                                          record.endMinute -
                                                  record.startMinute >=
                                              90
                                      ? Align(
                                          alignment: Alignment.centerLeft,
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: OmniSpacing.xs,
                                            ),
                                            child: Text(
                                              record.activity ?? '未命名记录',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .labelSmall
                                                  ?.copyWith(
                                                    color: Colors.white,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                            ),
                                          ),
                                        )
                                      : const SizedBox.shrink(),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 月度时间指纹日历。
class _MonthFingerprint extends StatelessWidget {
  /// 当前月记录。
  final List<TimeEntryRecord> records;

  /// 当前月起点。
  final DateTime rangeStart;

  /// 下一月起点。
  final DateTime rangeEnd;

  /// 时间类别颜色映射。
  final Map<String, Color> categoryColors;

  /// 打开指定自然日的回调。
  final ValueChanged<DateTime> onOpenDay;

  /// 创建月度时间指纹日历。
  const _MonthFingerprint({
    required this.records,
    required this.rangeStart,
    required this.rangeEnd,
    required this.categoryColors,
    required this.onOpenDay,
  });

  /// 构建带日内微缩条的月历。
  @override
  Widget build(BuildContext context) {
    // 当前月第一天前的空白格数量。
    final int leadingCount = rangeStart.weekday - 1;
    // 当前月自然日数量。
    final int dayCount = rangeEnd.difference(rangeStart).inDays;
    // 补齐整周后的总格数。
    final int itemCount = ((leadingCount + dayCount + 6) ~/ 7) * 7;
    return Column(
      key: const ValueKey<String>('timeline-month-fingerprint'),
      children: <Widget>[
        Row(
          children: <Widget>[
            for (final String weekday in const <String>[
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
                    weekday,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: OmniSpacing.xs),
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            // 窄屏月历使用的单元格间距。
            final double spacing = constraints.maxWidth < 560 ? 3 : 6;
            // 单个月历格宽度。
            final double cellWidth = (constraints.maxWidth - spacing * 6) / 7;
            // 是否显示完整时长文字。
            final bool showDuration = cellWidth >= 58;
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: itemCount,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 7,
                crossAxisSpacing: spacing,
                mainAxisSpacing: spacing,
                childAspectRatio: showDuration ? 1.2 : 0.78,
              ),
              itemBuilder: (BuildContext context, int index) {
                // 当前格对应的月内下标。
                final int dayIndex = index - leadingCount;
                if (dayIndex < 0 || dayIndex >= dayCount) {
                  return const SizedBox.shrink();
                }
                // 当前格对应的自然日。
                final DateTime day = rangeStart.add(Duration(days: dayIndex));
                // 当前自然日记录。
                final List<TimeEntryRecord> dayRecords = records
                    .where(
                      (TimeEntryRecord record) =>
                          DateUtils.isSameDay(record.entryDate, day),
                    )
                    .toList(growable: false);
                return _MonthFingerprintCell(
                  day: day,
                  records: dayRecords,
                  categoryColors: categoryColors,
                  showDuration: showDuration,
                  onTap: () => onOpenDay(day),
                );
              },
            );
          },
        ),
      ],
    );
  }
}

/// 月度时间指纹中的单日格。
class _MonthFingerprintCell extends StatelessWidget {
  /// 当前自然日。
  final DateTime day;

  /// 当天时间记录。
  final List<TimeEntryRecord> records;

  /// 时间类别颜色映射。
  final Map<String, Color> categoryColors;

  /// 是否显示完整时长。
  final bool showDuration;

  /// 点击回调。
  final VoidCallback onTap;

  /// 创建月度时间指纹中的单日格。
  const _MonthFingerprintCell({
    required this.day,
    required this.records,
    required this.categoryColors,
    required this.showDuration,
    required this.onTap,
  });

  /// 构建日期、记录时长与微缩时间条。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当天记录分钟数。
    final int trackedMinutes = _sumMinutes(records);
    // 当天记录覆盖率。
    final double coverage = (trackedMinutes / 1440).clamp(0, 1);
    return Material(
      color: records.isEmpty
          ? colors.paperSubtle
          : colors.brand.withValues(alpha: 0.04 + coverage * 0.1),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(OmniRadius.control),
        side: BorderSide(
          color: DateUtils.isSameDay(day, DateTime.now())
              ? colors.brand
              : colors.line,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.all(showDuration ? OmniSpacing.xs : 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '${day.day}',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: DateUtils.isSameDay(day, DateTime.now())
                      ? colors.brand
                      : colors.ink,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (showDuration) ...<Widget>[
                const Spacer(),
                Text(
                  records.isEmpty ? '无记录' : _formatDuration(trackedMinutes),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                const SizedBox(height: OmniSpacing.xxs),
              ] else
                const Spacer(),
              SizedBox(
                height: 5,
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    // 当前微缩时间条可用宽度。
                    final double width = constraints.maxWidth;
                    return Stack(
                      children: <Widget>[
                        Positioned.fill(child: ColoredBox(color: colors.mist)),
                        for (final TimeEntryRecord record in records)
                          Positioned(
                            left: record.startMinute / 1440 * width,
                            width: math.max(
                              1,
                              (record.endMinute - record.startMinute) /
                                  1440 *
                                  width,
                            ),
                            top: 0,
                            bottom: 0,
                            child: ColoredBox(
                              color:
                                  categoryColors[record.category] ??
                                  colors.time,
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 类别结构对比面板。
class _CategoryStructurePanel extends StatelessWidget {
  /// 当前周期分类汇总。
  final Map<String, int> summary;

  /// 上一周期分类汇总。
  final Map<String, int> previousSummary;

  /// 时间类别颜色映射。
  final Map<String, Color> categoryColors;

  /// 当前统计周期。
  final TimelineStatsPeriod period;

  /// 创建类别结构对比面板。
  const _CategoryStructurePanel({
    required this.summary,
    required this.previousSummary,
    required this.categoryColors,
    required this.period,
  });

  /// 构建按耗时降序排列的类别条形图。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 按耗时降序排列的类别。
    final List<MapEntry<String, int>> entries = summary.entries.toList()
      ..sort(
        (MapEntry<String, int> first, MapEntry<String, int> second) =>
            second.value.compareTo(first.value),
      );
    // 最长类别时长，用于计算视觉比例。
    final int maxMinutes = entries.isEmpty ? 1 : entries.first.value;
    return OmniPanel(
      key: const ValueKey<String>('timeline-category-structure'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _PanelHeading(title: '类别结构', description: '按耗时排序，并与上一周期比较'),
          const SizedBox(height: OmniSpacing.md),
          if (entries.isEmpty)
            const _InlineEmpty(
              icon: Icons.category_outlined,
              text: '当前周期还没有可统计的类别',
            )
          else
            for (final MapEntry<String, int> entry in entries.take(
              8,
            )) ...<Widget>[
              _CategoryBarRow(
                category: entry.key,
                minutes: entry.value,
                previousMinutes: previousSummary[entry.key] ?? 0,
                maxMinutes: maxMinutes,
                color: categoryColors[entry.key] ?? colors.time,
                comparisonLabel: _comparisonLabel(period),
              ),
              if (entry != entries.take(8).last)
                const SizedBox(height: OmniSpacing.sm),
            ],
        ],
      ),
    );
  }
}

/// 单个类别的耗时对比行。
class _CategoryBarRow extends StatelessWidget {
  /// 类别名称。
  final String category;

  /// 当前周期分钟数。
  final int minutes;

  /// 上一周期分钟数。
  final int previousMinutes;

  /// 当前列表最大分钟数。
  final int maxMinutes;

  /// 当前类别颜色。
  final Color color;

  /// 上一周期比较标签。
  final String comparisonLabel;

  /// 创建单个类别的耗时对比行。
  const _CategoryBarRow({
    required this.category,
    required this.minutes,
    required this.previousMinutes,
    required this.maxMinutes,
    required this.color,
    required this.comparisonLabel,
  });

  /// 构建类别名称、时长、变化与比例条。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前类别相对上一周期的分钟变化。
    final int delta = minutes - previousMinutes;
    return Semantics(
      label:
          '$category，${_formatDuration(minutes)}，$comparisonLabel ${_formatSignedDuration(delta)}',
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: OmniSpacing.xs),
              Expanded(
                child: Text(
                  category,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              Text(
                _formatDuration(minutes),
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
              const SizedBox(width: OmniSpacing.sm),
              SizedBox(
                width: 68,
                child: Text(
                  _formatSignedDuration(delta),
                  textAlign: TextAlign.end,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: delta > 0
                        ? colors.success
                        : delta < 0
                        ? colors.warning
                        : colors.muted,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: OmniSpacing.xxs),
          ClipRRect(
            borderRadius: BorderRadius.circular(OmniRadius.pill),
            child: LinearProgressIndicator(
              minHeight: 7,
              value: maxMinutes == 0 ? 0 : minutes / maxMinutes,
              backgroundColor: colors.mist,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ],
      ),
    );
  }
}

/// 趋势图中的单个数据点。
class _TimeTrendDatum {
  /// 数据点标签。
  final String label;

  /// 数据点分钟数。
  final int minutes;

  /// 创建趋势图数据点。
  const _TimeTrendDatum({required this.label, required this.minutes});
}

/// 日内或跨日趋势面板。
class _TimeTrendPanel extends StatelessWidget {
  /// 当前统计周期记录。
  final List<TimeEntryRecord> records;

  /// 当前范围起点。
  final DateTime rangeStart;

  /// 当前范围终点。
  final DateTime rangeEnd;

  /// 当前统计周期。
  final TimelineStatsPeriod period;

  /// 创建日内或跨日趋势面板。
  const _TimeTrendPanel({
    required this.records,
    required this.rangeStart,
    required this.rangeEnd,
    required this.period,
  });

  /// 构建日内时段、每日或每周趋势。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前周期对应的趋势数据点。
    final List<_TimeTrendDatum> data = _buildTrendData(
      records: records,
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
      period: period,
    );
    // 当前趋势中的最大分钟数。
    final int maxMinutes = data.fold<int>(
      1,
      (int value, _TimeTrendDatum item) => math.max(value, item.minutes),
    );
    // 当前趋势标题。
    final String title = period == TimelineStatsPeriod.day ? '时段节律' : '记录趋势';
    // 当前趋势说明。
    final String description = switch (period) {
      TimelineStatsPeriod.day => '观察时间主要落在哪个时段',
      TimelineStatsPeriod.week => '比较一周内每天的记录总量',
      TimelineStatsPeriod.month => '按自然周观察整月变化',
    };
    return OmniPanel(
      key: const ValueKey<String>('timeline-daily-trend'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _PanelHeading(title: title, description: description),
          const SizedBox(height: OmniSpacing.md),
          for (final _TimeTrendDatum item in data) ...<Widget>[
            Row(
              children: <Widget>[
                SizedBox(
                  width: 56,
                  child: Text(
                    item.label,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(OmniRadius.pill),
                    child: LinearProgressIndicator(
                      minHeight: 8,
                      value: item.minutes / maxMinutes,
                      backgroundColor: colors.mist,
                      valueColor: AlwaysStoppedAnimation<Color>(colors.time),
                    ),
                  ),
                ),
                const SizedBox(width: OmniSpacing.sm),
                SizedBox(
                  width: 58,
                  child: Text(
                    _formatDuration(item.minutes),
                    textAlign: TextAlign.end,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            if (item != data.last) const SizedBox(height: OmniSpacing.sm),
          ],
        ],
      ),
    );
  }
}

/// 单日记录明细主体。
class TimelineDetailsContent extends ConsumerWidget {
  /// 当前自然日。
  final DateTime day;

  /// 当天时间记录。
  final List<TimeEntryRecord> records;

  /// 滚动内容底部需要避让的安全距离。
  final double safeBottomPadding;

  /// 在指定分钟新增记录的回调。
  final ValueChanged<int> onAddAtMinute;

  /// 编辑时间记录的回调。
  final ValueChanged<TimeEntryRecord> onEdit;

  /// 删除时间记录的回调。
  final ValueChanged<TimeEntryRecord> onDelete;

  /// 创建单日记录明细主体。
  const TimelineDetailsContent({
    required this.day,
    required this.records,
    required this.onAddAtMinute,
    required this.onEdit,
    required this.onDelete,
    this.safeBottomPadding = 0,
    super.key,
  });

  /// 构建真实比例时间轴与紧凑记录清单。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 当前时间类别。
    final List<TaxonomyEntry> categories =
        ref
            .watch(
              taxonomyEntriesProvider((
                TaxonomyModule.timeline,
                TaxonomyKind.category,
              )),
            )
            .asData
            ?.value ??
        const <TaxonomyEntry>[];
    // 时间类别颜色映射。
    final Map<String, Color> categoryColors = <String, Color>{
      for (final TaxonomyEntry category in categories)
        category.name: Color(category.colorValue),
    };
    return LayoutBuilder(
      key: const ValueKey<String>('timeline-details-content'),
      builder: (BuildContext context, BoxConstraints constraints) {
        // 当前内容区是否适合时间轴与清单并排。
        final bool sideBySide = constraints.maxWidth >= 880;
        if (sideBySide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                child: _DayTimelineBoard(
                  day: day,
                  records: records,
                  categoryColors: categoryColors,
                  onAddAtMinute: onAddAtMinute,
                  onEdit: onEdit,
                ),
              ),
              const SizedBox(width: OmniSpacing.xs),
              SizedBox(
                width: math.min(360, constraints.maxWidth * 0.34),
                child: Column(
                  children: <Widget>[
                    _DayDetailSummary(day: day, records: records),
                    const SizedBox(height: OmniSpacing.xs),
                    Expanded(
                      child: _TimeEntryList(
                        records: records,
                        categoryColors: categoryColors,
                        onEdit: onEdit,
                        onDelete: onDelete,
                        scrollable: true,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        }
        return ListView(
          padding: EdgeInsets.only(
            bottom: safeBottomPadding > 0 ? safeBottomPadding : OmniSpacing.md,
          ),
          children: <Widget>[
            _DayDetailSummary(day: day, records: records),
            const SizedBox(height: OmniSpacing.xs),
            SizedBox(
              height: 560,
              child: _DayTimelineBoard(
                day: day,
                records: records,
                categoryColors: categoryColors,
                onAddAtMinute: onAddAtMinute,
                onEdit: onEdit,
              ),
            ),
            const SizedBox(height: OmniSpacing.xs),
            _TimeEntryList(
              records: records,
              categoryColors: categoryColors,
              onEdit: onEdit,
              onDelete: onDelete,
              scrollable: false,
            ),
          ],
        );
      },
    );
  }
}

/// 单日记录摘要。
class _DayDetailSummary extends StatelessWidget {
  /// 当前自然日。
  final DateTime day;

  /// 当天时间记录。
  final List<TimeEntryRecord> records;

  /// 创建单日记录摘要。
  const _DayDetailSummary({required this.day, required this.records});

  /// 构建已记录、空白和记录段数摘要。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当天已记录分钟数。
    final int trackedMinutes = _sumMinutes(records);
    // 当天空白分钟数。
    final int blankMinutes = math.max(0, 1440 - trackedMinutes);
    return OmniPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '${DateFormat('M 月 d 日').format(day)} · ${_weekdayLabel(day)}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Text(
                '${records.length} 段',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
          const SizedBox(height: OmniSpacing.sm),
          Row(
            children: <Widget>[
              Expanded(
                child: _DetailSummaryValue(
                  label: '已记录',
                  value: _formatDuration(trackedMinutes),
                  color: colors.time,
                ),
              ),
              Container(width: 1, height: 36, color: colors.line),
              Expanded(
                child: _DetailSummaryValue(
                  label: '空白时间',
                  value: _formatDuration(blankMinutes),
                  color: colors.muted,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 单日摘要中的数值。
class _DetailSummaryValue extends StatelessWidget {
  /// 数值名称。
  final String label;

  /// 数值内容。
  final String value;

  /// 数值强调色。
  final Color color;

  /// 创建单日摘要数值。
  const _DetailSummaryValue({
    required this.label,
    required this.value,
    required this.color,
  });

  /// 构建单个摘要数值。
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(height: OmniSpacing.xxs),
        Text(
          value,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: color,
            fontWeight: FontWeight.w700,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

/// 单日真实比例时间轴。
class _DayTimelineBoard extends StatelessWidget {
  /// 当前自然日。
  final DateTime day;

  /// 当天时间记录。
  final List<TimeEntryRecord> records;

  /// 时间类别颜色映射。
  final Map<String, Color> categoryColors;

  /// 在指定分钟新增记录的回调。
  final ValueChanged<int> onAddAtMinute;

  /// 编辑时间记录的回调。
  final ValueChanged<TimeEntryRecord> onEdit;

  /// 创建单日真实比例时间轴。
  const _DayTimelineBoard({
    required this.day,
    required this.records,
    required this.categoryColors,
    required this.onAddAtMinute,
    required this.onEdit,
  });

  /// 构建 00:00 至 24:00 的完整时间轨道。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return OmniPanel(
      key: const ValueKey<String>('timeline-day-board'),
      padding: const EdgeInsets.fromLTRB(
        OmniSpacing.sm,
        OmniSpacing.md,
        OmniSpacing.md,
        OmniSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const _PanelHeading(
            title: '24 小时时间轴',
            description: '点击空白位置补记，点击时间块编辑',
          ),
          const SizedBox(height: OmniSpacing.sm),
          Expanded(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                // 时间轴实际绘制高度。
                final double trackHeight = constraints.maxHeight;
                return Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    Positioned(
                      left: 48,
                      right: 0,
                      top: 0,
                      bottom: 0,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (TapDownDetails details) {
                          // 点击位置换算出的分钟数。
                          final int minute =
                              ((details.localPosition.dy / trackHeight * 1440) /
                                      5)
                                  .round() *
                              5;
                          onAddAtMinute(minute.clamp(0, 1435));
                        },
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: colors.paperSubtle,
                            borderRadius: BorderRadius.circular(
                              OmniRadius.control,
                            ),
                          ),
                        ),
                      ),
                    ),
                    for (int hour = 0; hour <= 24; hour += 1) ...<Widget>[
                      Positioned(
                        left: 0,
                        top: _hourTop(hour, trackHeight),
                        width: 40,
                        child: Text(
                          hour == 24 ? '24' : hour.toString().padLeft(2, '0'),
                          textAlign: TextAlign.right,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ),
                      Positioned(
                        left: 48,
                        right: 0,
                        top: hour / 24 * trackHeight,
                        child: ColoredBox(
                          color: colors.line.withValues(
                            alpha: hour % 6 == 0 ? 0.9 : 0.48,
                          ),
                          child: const SizedBox(height: 1),
                        ),
                      ),
                    ],
                    for (final TimeEntryRecord record in records)
                      Positioned(
                        left: 56,
                        right: 8,
                        top: record.startMinute / 1440 * trackHeight,
                        height: math.max(
                          8,
                          (record.endMinute - record.startMinute) /
                              1440 *
                              trackHeight,
                        ),
                        child: _DayTimelineBlock(
                          record: record,
                          color: categoryColors[record.category] ?? colors.time,
                          onTap: () => onEdit(record),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 返回整点标签在轨道内的安全位置。
  double _hourTop(int hour, double trackHeight) {
    // 未修正的整点标签位置。
    final double rawTop = hour / 24 * trackHeight - 7;
    return rawTop.clamp(0, math.max(0, trackHeight - 14));
  }
}

/// 单日时间轴中的记录块。
class _DayTimelineBlock extends StatelessWidget {
  /// 当前时间记录。
  final TimeEntryRecord record;

  /// 当前类别颜色。
  final Color color;

  /// 点击回调。
  final VoidCallback onTap;

  /// 创建单日时间轴中的记录块。
  const _DayTimelineBlock({
    required this.record,
    required this.color,
    required this.onTap,
  });

  /// 构建可点击的记录块。
  @override
  Widget build(BuildContext context) {
    // 当前记录分钟数。
    final int duration = record.endMinute - record.startMinute;
    return Tooltip(
      message:
          '${_formatClock(record.startMinute)}–${_formatClock(record.endMinute)}\n${record.activity}',
      child: Material(
        color: color,
        borderRadius: BorderRadius.circular(OmniRadius.tiny),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: duration >= 40
              ? Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: OmniSpacing.xs,
                    vertical: 2,
                  ),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          record.activity ?? '未命名记录',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ),
                      if (duration >= 90) ...<Widget>[
                        const SizedBox(width: OmniSpacing.xs),
                        Text(
                          '${_formatClock(record.startMinute)}–${_formatClock(record.endMinute)}',
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: Colors.white),
                        ),
                      ],
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ),
    );
  }
}

/// 单日时间记录清单。
class _TimeEntryList extends StatelessWidget {
  /// 当天时间记录。
  final List<TimeEntryRecord> records;

  /// 时间类别颜色映射。
  final Map<String, Color> categoryColors;

  /// 编辑时间记录的回调。
  final ValueChanged<TimeEntryRecord> onEdit;

  /// 删除时间记录的回调。
  final ValueChanged<TimeEntryRecord> onDelete;

  /// 是否允许内部滚动。
  final bool scrollable;

  /// 创建单日时间记录清单。
  const _TimeEntryList({
    required this.records,
    required this.categoryColors,
    required this.onEdit,
    required this.onDelete,
    required this.scrollable,
  });

  /// 构建紧凑连续记录清单。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    if (records.isEmpty) {
      return const OmniPanel(
        child: _InlineEmpty(
          icon: Icons.add_circle_outline_rounded,
          text: '点击时间轴空白位置，补记这段时间',
        ),
      );
    }
    // 单条时间记录构建器。
    Widget buildItem(BuildContext context, int index) {
      // 当前时间记录。
      final TimeEntryRecord record = records[index];
      return _TimeEntryListRow(
        record: record,
        color: categoryColors[record.category] ?? colors.time,
        onEdit: () => onEdit(record),
        onDelete: () => onDelete(record),
      );
    }

    return OmniPanel(
      key: const ValueKey<String>('timeline-entry-list'),
      padding: EdgeInsets.zero,
      child: ListView.separated(
        shrinkWrap: !scrollable,
        physics: scrollable ? null : const NeverScrollableScrollPhysics(),
        itemCount: records.length,
        separatorBuilder: (BuildContext context, int index) =>
            Divider(color: colors.line),
        itemBuilder: buildItem,
      ),
    );
  }
}

/// 单条紧凑时间记录。
class _TimeEntryListRow extends StatelessWidget {
  /// 当前时间记录。
  final TimeEntryRecord record;

  /// 当前类别颜色。
  final Color color;

  /// 编辑回调。
  final VoidCallback onEdit;

  /// 删除回调。
  final VoidCallback onDelete;

  /// 创建单条紧凑时间记录。
  const _TimeEntryListRow({
    required this.record,
    required this.color,
    required this.onEdit,
    required this.onDelete,
  });

  /// 构建仅保留一个行尾菜单的记录行。
  @override
  Widget build(BuildContext context) {
    return OmniListRow(
      onTap: onEdit,
      padding: const EdgeInsets.symmetric(
        horizontal: OmniSpacing.sm,
        vertical: OmniSpacing.xs,
      ),
      leading: Container(
        width: 3,
        height: 38,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(OmniRadius.pill),
        ),
      ),
      title: Text(record.activity ?? '未命名记录'),
      subtitle: Text(
        '${_formatLogicalRange(record)} · ${_formatLogicalDuration(record)}${record.category == null ? '' : ' · ${record.category}'}',
      ),
      trailing: OmniPopupMenuButton<String>(
        tooltip: '更多操作',
        onSelected: (String value) {
          if (value == 'edit') {
            onEdit();
          } else if (value == 'delete') {
            onDelete();
          }
        },
        itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
          OmniPopupMenuItem<String>(
            value: 'edit',
            label: '编辑',
            icon: Icons.edit_outlined,
          ),
          OmniPopupMenuItem<String>(
            value: 'delete',
            label: '移入回收站',
            icon: Icons.delete_outline_rounded,
            danger: true,
          ),
        ],
      ),
    );
  }
}

/// 统计面板通用标题。
class _PanelHeading extends StatelessWidget {
  /// 面板标题。
  final String title;

  /// 面板说明。
  final String description;

  /// 创建统计面板通用标题。
  const _PanelHeading({required this.title, required this.description});

  /// 构建标题和说明。
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 2),
        Text(description, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

/// 面板内的紧凑空状态。
class _InlineEmpty extends StatelessWidget {
  /// 空状态图标。
  final IconData icon;

  /// 空状态文案。
  final String text;

  /// 创建面板内的紧凑空状态。
  const _InlineEmpty({required this.icon, required this.text});

  /// 构建不抢占页面的大面积空状态。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: OmniSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 28, color: colors.muted),
          const SizedBox(height: OmniSpacing.xs),
          Text(
            text,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// 构建当前周期最值得注意的一条确定性洞察。
String _buildInsight({
  required List<TimeEntryRecord> records,
  required List<TimeEntryRecord> previousRecords,
  required Map<String, int> summary,
  required Map<String, int> previousSummary,
  required TimelineStatsPeriod period,
}) {
  if (records.isEmpty) {
    return '${_periodLabel(period)}还没有记录，新增一条后这里会形成你的时间指纹。';
  }
  // 当前周期耗时最多的类别。
  final MapEntry<String, int>? dominant = _dominantEntry(summary);
  if (dominant == null) {
    return '${_periodLabel(period)}已有 ${records.length} 段记录，可以继续补齐空白时间。';
  }
  if (previousRecords.isEmpty) {
    return '${_periodLabel(period)}投入最多的是“${dominant.key}”，共 ${_formatDuration(dominant.value)}；上一周期暂无记录。';
  }
  // 主要类别相对上一周期的分钟变化。
  final int delta = dominant.value - (previousSummary[dominant.key] ?? 0);
  // 主要类别的趋势文案。
  final String trend = delta == 0
      ? '与上一周期持平'
      : '比上一周期${delta > 0 ? '增加' : '减少'} ${_formatDuration(delta.abs())}';
  return '${_periodLabel(period)}投入最多的是“${dominant.key}”，共 ${_formatDuration(dominant.value)}，$trend。';
}

/// 构建与当前周期匹配的趋势数据。
List<_TimeTrendDatum> _buildTrendData({
  required List<TimeEntryRecord> records,
  required DateTime rangeStart,
  required DateTime rangeEnd,
  required TimelineStatsPeriod period,
}) {
  if (period == TimelineStatsPeriod.day) {
    // 单日固定六小时区间。
    const List<(String, int, int)> windows = <(String, int, int)>[
      ('00—06', 0, 360),
      ('06—12', 360, 720),
      ('12—18', 720, 1080),
      ('18—24', 1080, 1440),
    ];
    return <_TimeTrendDatum>[
      for (final (String, int, int) window in windows)
        _TimeTrendDatum(
          label: window.$1,
          minutes: records.fold<int>(
            0,
            (int total, TimeEntryRecord record) =>
                total + _minutesInWindow(record, window.$2, window.$3),
          ),
        ),
    ];
  }
  if (period == TimelineStatsPeriod.week) {
    // 当前周全部自然日。
    final List<DateTime> days = _daysInRange(rangeStart, rangeEnd);
    return <_TimeTrendDatum>[
      for (final DateTime day in days)
        _TimeTrendDatum(
          label: _weekdayLabel(day).replaceFirst('周', ''),
          minutes: _sumMinutes(
            records
                .where(
                  (TimeEntryRecord record) =>
                      DateUtils.isSameDay(record.entryDate, day),
                )
                .toList(growable: false),
          ),
        ),
    ];
  }
  // 包含月初的第一个自然周起点。
  final DateTime firstWeekStart = rangeStart.subtract(
    Duration(days: rangeStart.weekday - 1),
  );
  // 当前月跨越的自然周数量。
  final int weekCount = (rangeEnd.difference(firstWeekStart).inDays / 7).ceil();
  return <_TimeTrendDatum>[
    for (int weekIndex = 0; weekIndex < weekCount; weekIndex += 1)
      _TimeTrendDatum(
        label: DateFormat('M/d')
            .format(firstWeekStart.add(Duration(days: weekIndex * 7))),
        minutes: _sumMinutes(
          records
              .where((TimeEntryRecord record) {
                // 当前周起点。
                final DateTime weekStart = firstWeekStart.add(
                  Duration(days: weekIndex * 7),
                );
                // 下一自然周起点。
                final DateTime weekEnd = weekStart.add(const Duration(days: 7));
                // 当前记录自然日。
                final DateTime recordDay = DateUtils.dateOnly(record.entryDate);
                return !recordDay.isBefore(weekStart) &&
                    recordDay.isBefore(weekEnd);
              })
              .toList(growable: false),
        ),
      ),
  ];
}

/// 计算记录与指定分钟窗口相交的时长。
int _minutesInWindow(TimeEntryRecord record, int startMinute, int endMinute) {
  // 当前记录与窗口相交的起点。
  final int overlapStart = math.max(record.startMinute, startMinute);
  // 当前记录与窗口相交的终点。
  final int overlapEnd = math.min(record.endMinute, endMinute);
  return math.max(0, overlapEnd - overlapStart);
}

/// 返回左闭右开范围内的全部自然日。
List<DateTime> _daysInRange(DateTime start, DateTime end) {
  // 当前范围自然日数量。
  final int dayCount = end.difference(start).inDays;
  return <DateTime>[
    for (int index = 0; index < dayCount; index += 1)
      start.add(Duration(days: index)),
  ];
}

/// 汇总时间记录分钟数。
int _sumMinutes(List<TimeEntryRecord> records) {
  return records.fold<int>(
    0,
    (int total, TimeEntryRecord record) =>
        total + record.endMinute - record.startMinute,
  );
}

/// 返回耗时最多的类别。
MapEntry<String, int>? _dominantEntry(Map<String, int> summary) {
  if (summary.isEmpty) {
    return null;
  }
  // 按耗时降序排列的类别。
  final List<MapEntry<String, int>> entries = summary.entries.toList()
    ..sort(
      (MapEntry<String, int> first, MapEntry<String, int> second) =>
          second.value.compareTo(first.value),
    );
  return entries.first;
}

/// 将分钟数格式化为紧凑时长。
String _formatDuration(int minutes) {
  // 完整小时数。
  final int hours = minutes ~/ 60;
  // 扣除完整小时后的分钟数。
  final int remainder = minutes % 60;
  if (hours == 0) {
    return '${remainder}m';
  }
  if (remainder == 0) {
    return '${hours}h';
  }
  return '${hours}h${remainder}m';
}

/// 将分钟变化格式化为带符号时长。
String _formatSignedDuration(int minutes) {
  if (minutes == 0) {
    return '持平';
  }
  return '${minutes > 0 ? '+' : '−'}${_formatDuration(minutes.abs())}';
}

/// 将分钟数格式化为时钟时间。
String _formatClock(int minute) {
  if (minute == 1440) {
    return '24:00';
  }
  return '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';
}

/// 将一条逻辑记录格式化为时间范围，跨天时同时展示日期。
String _formatLogicalRange(TimeEntryRecord record) {
  // 可选结束时间。
  final DateTime? endedAt = record.endedAt;
  if (endedAt == null) {
    return '${DateFormat('M月d日 HH:mm').format(record.startedAt)}–进行中';
  }
  if (DateUtils.isSameDay(record.startedAt, endedAt)) {
    return '${DateFormat('HH:mm').format(record.startedAt)}–${DateFormat('HH:mm').format(endedAt)}';
  }
  return '${DateFormat('M月d日 HH:mm').format(record.startedAt)}–${DateFormat('M月d日 HH:mm').format(endedAt)} · 跨天';
}

/// 将一条逻辑记录格式化为完整持续时长。
String _formatLogicalDuration(TimeEntryRecord record) {
  // 进行中记录以当前时刻作为临时结束时间。
  final DateTime effectiveEnd = record.endedAt ?? DateTime.now();
  // 避免设备时间回拨产生负时长。
  final int minutes = math.max(
    0,
    effectiveEnd.difference(record.startedAt).inMinutes,
  );
  return _formatDuration(minutes);
}

/// 返回周期范围文案。
String _periodLabel(TimelineStatsPeriod period) {
  return switch (period) {
    TimelineStatsPeriod.day => '今天',
    TimelineStatsPeriod.week => '本周',
    TimelineStatsPeriod.month => '本月',
  };
}

/// 返回上一周期比较文案。
String _comparisonLabel(TimelineStatsPeriod period) {
  return switch (period) {
    TimelineStatsPeriod.day => '较昨日',
    TimelineStatsPeriod.week => '较上周',
    TimelineStatsPeriod.month => '较上月',
  };
}

/// 返回星期文案。
String _weekdayLabel(DateTime day) {
  return const <String>['周一', '周二', '周三', '周四', '周五', '周六', '周日'][day.weekday -
      1];
}

/// 返回时间指纹行的日期文案。
String _dayLabel(DateTime day) {
  return '${_weekdayLabel(day)} ${day.month}/${day.day}';
}
