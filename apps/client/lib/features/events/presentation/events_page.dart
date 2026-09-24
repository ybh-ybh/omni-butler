import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/events/data/event_repository.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 周期事件页面。
class EventsPage extends ConsumerStatefulWidget {
  /// 是否嵌入 Android 管理聚合页。
  final bool embeddedInManagement;

  /// 创建周期事件页面。
  const EventsPage({this.embeddedInManagement = false, super.key});

  /// 创建页面状态。
  @override
  ConsumerState<EventsPage> createState() => _EventsPageState();
}

/// 周期事件页面状态。
class _EventsPageState extends ConsumerState<EventsPage> {
  /// 是否显示归档事件。
  bool _showArchived = false;

  /// 是否优先使用双列事件卡片布局。
  bool _useTwoColumns = true;

  /// 当前事件完成撤销浮动消息。
  OmniMessageHandle? _undoMessage;

  /// 打开事件编辑器。
  Future<void> _openEditor([EventRecord? event]) async {
    await showOmniSideSheet<void>(
      context,
      builder: (BuildContext context) => _EventEditorDialog(event: event),
    );
  }

  /// 打开事件完成历史。
  Future<void> _openHistory(EventRecord event) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => _EventHistoryDialog(event: event),
    );
  }

  /// 记录事件当前完成时间。
  Future<void> _recordNow(EventRecord event) async {
    // 事件仓储。
    final EventRepository repository = ref.read(eventRepositoryProvider);
    // 撤销凭据。
    final EventCompletionUndo undo = await repository.recordNow(event);
    if (!mounted) {
      return;
    }
    _undoMessage?.dismiss();
    _undoMessage = showOmniMessage(
      context,
      message: '已记录“${event.name}”为现在完成',
      tone: OmniMessageTone.success,
      duration: const Duration(seconds: 6),
      actionLabel: '撤销',
      onAction: () => unawaited(_undoLastCompletion(undo)),
      onDismissed: () => _undoMessage = null,
    );
  }

  /// 撤销最近一次事件完成操作。
  Future<void> _undoLastCompletion(EventCompletionUndo undo) async {
    await ref.read(eventRepositoryProvider).undoRecord(undo);
  }

  /// 归档或恢复事件。
  Future<void> _toggleArchived(EventRecord event) async {
    await ref
        .read(eventRepositoryProvider)
        .setArchived(event.id, !event.isArchived);
  }

  /// 删除事件。
  Future<void> _delete(EventRecord event) async {
    await ref.read(eventRepositoryProvider).delete(event.id);
    ref.invalidate(recycleBinItemsProvider);
    if (!mounted) {
      return;
    }
    showOmniMessage(
      context,
      message: '“${event.name}”已移入回收站',
      tone: OmniMessageTone.success,
    );
  }

  /// 释放撤销浮动消息。
  @override
  void dispose() {
    _undoMessage?.dismiss();
    super.dispose();
  }

  /// 构建周期事件页面。
  @override
  Widget build(BuildContext context) {
    // 当前事件流。
    final AsyncValue<List<EventRecord>> events = ref.watch(
      _showArchived ? archivedEventsProvider : activeEventsProvider,
    );
    // 用于顶部统计的全部有效进行中事件流。
    final AsyncValue<List<EventRecord>> activeEvents = ref.watch(
      activeEventsProvider,
    );
    // 用于顶部统计的全部有效完成历史流。
    final AsyncValue<List<EventCompletionRecord>> completions = ref.watch(
      activeEventCompletionsProvider,
    );
    // 当前统计时间。
    final DateTime now = ref.watch(nowProvider);
    // 当前是否为紧凑布局。
    final bool compact = OmniBreakpoint.isCompact(
      MediaQuery.sizeOf(context).width,
    );
    return Scaffold(
      floatingActionButton: widget.embeddedInManagement
          ? OmniButton(
              key: const ValueKey<String>('event-mobile-create'),
              label: '新增事件',
              icon: Icons.add_rounded,
              variant: OmniButtonVariant.pagePrimary,
              onPressed: _openEditor,
            )
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      body: Padding(
        padding: compact
            ? EdgeInsets.fromLTRB(
                OmniSpacing.xs,
                OmniSpacing.xs,
                OmniSpacing.xs,
                widget.embeddedInManagement ? 88 : OmniSpacing.md,
              )
            : const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: OmniSpacing.sm,
              ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (!widget.embeddedInManagement) ...<Widget>[
              OmniPageHeader(
                title: '事件记录',
                actions: <Widget>[
                  OmniButton(
                    label: '新增事件',
                    icon: Icons.add_rounded,
                    variant: OmniButtonVariant.pagePrimary,
                    onPressed: _openEditor,
                  ),
                ],
              ),
              const SizedBox(height: OmniSpacing.xs),
            ],
            _EventStatistics(
              events: activeEvents,
              completions: completions,
              now: now,
              useCarousel: widget.embeddedInManagement,
            ),
            const SizedBox(height: OmniSpacing.xs),
            _EventToolbar(
              showArchived: _showArchived,
              useTwoColumns: _useTwoColumns,
              onArchivedChanged: (bool value) {
                setState(() => _showArchived = value);
              },
              onToggleLayout: () {
                setState(() => _useTwoColumns = !_useTwoColumns);
              },
            ),
            const SizedBox(height: OmniSpacing.xs),
            Expanded(
              child: events.when(
                data: (List<EventRecord> records) {
                  if (records.isEmpty) {
                    return _EmptyEvents(archived: _showArchived);
                  }
                  return _EventCardGrid(
                    events: records,
                    archived: _showArchived,
                    useTwoColumns: _useTwoColumns,
                    onRecord: _recordNow,
                    onHistory: _openHistory,
                    onEdit: _openEditor,
                    onArchive: _toggleArchived,
                    onDelete: _delete,
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (Object error, StackTrace stackTrace) =>
                    Center(child: Text('事件读取失败：$error')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 事件管理页顶部统计模块。
class _EventStatistics extends ConsumerWidget {
  /// 全部有效进行中事件。
  final AsyncValue<List<EventRecord>> events;

  /// 全部未删除事件的有效完成历史。
  final AsyncValue<List<EventCompletionRecord>> completions;

  /// 当前统计时间。
  final DateTime now;

  /// 是否使用 Android 管理页统计轮播。
  final bool useCarousel;

  /// 创建事件顶部统计模块。
  const _EventStatistics({
    required this.events,
    required this.completions,
    required this.now,
    required this.useCarousel,
  });

  /// 按自然周汇总本月完成次数。
  List<int> _monthWeeklyCompletions(List<EventCompletionRecord> records) {
    // 本月最多五个自然周桶。
    final List<int> weeklyCounts = List<int>.filled(5, 0);
    for (final EventCompletionRecord completion in records) {
      if (completion.completedAt.year != now.year ||
          completion.completedAt.month != now.month) {
        continue;
      }
      // 当前完成记录所属的周序号。
      final int weekIndex = (completion.completedAt.day - 1) ~/ 7;
      // 月末不足一周的日期并入第五个周桶。
      final int safeIndex = weekIndex > 4 ? 4 : weekIndex;
      weeklyCounts[safeIndex] += 1;
    }
    return weeklyCounts;
  }

  /// 汇总超期、今天与后续六天的应做事件数量。
  List<int> _nearbyDueCounts(
    EventRepository repository,
    List<EventRecord> records,
  ) {
    // 第一个桶为超期，后续七个桶为今天到未来第六天。
    final List<int> dueCounts = List<int>.filled(8, 0);
    // 今天的日期部分。
    final DateTime today = DateUtils.dateOnly(now);
    for (final EventRecord event in records) {
      // 当前事件下一次应做时间。
      final DateTime? dueAt = repository.nextDueAt(event);
      if (dueAt == null) {
        continue;
      }
      // 应做日期距离今天的自然日数量。
      final int dayOffset = DateUtils.dateOnly(dueAt).difference(today).inDays;
      if (dayOffset < 0) {
        dueCounts[0] += 1;
      } else if (dayOffset < 7) {
        dueCounts[dayOffset + 1] += 1;
      }
    }
    return dueCounts;
  }

  /// 构建事件状态、完成趋势与近期压力摘要。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 事件仓储。
    final EventRepository repository = ref.watch(eventRepositoryProvider);
    // 当前全部进行中事件。
    final List<EventRecord> eventRecords =
        events.asData?.value ?? const <EventRecord>[];
    // 当前全部有效完成历史。
    final List<EventCompletionRecord> completionRecords =
        completions.asData?.value ?? const <EventCompletionRecord>[];
    // 四种事件状态数量。
    final Map<EventDueStatus, int> statusCounts = <EventDueStatus, int>{
      for (final EventDueStatus status in EventDueStatus.values) status: 0,
    };
    for (final EventRecord event in eventRecords) {
      // 当前事件状态。
      final EventDueStatus status = repository.statusFor(event, now);
      statusCounts[status] = (statusCounts[status] ?? 0) + 1;
    }
    // 待首次记录事件数量。
    final int unrecordedCount = statusCounts[EventDueStatus.unrecorded] ?? 0;
    // 节奏正常事件数量。
    final int normalCount = statusCounts[EventDueStatus.normal] ?? 0;
    // 本月开始时间。
    final DateTime currentMonthStart = DateTime(now.year, now.month);
    // 下月开始时间。
    final DateTime nextMonthStart = DateTime(now.year, now.month + 1);
    // 上月开始时间。
    final DateTime previousMonthStart = DateTime(now.year, now.month - 1);
    // 本月有效完成历史。
    final List<EventCompletionRecord> monthCompletions = completionRecords
        .where(
          (EventCompletionRecord completion) =>
              !completion.completedAt.isBefore(currentMonthStart) &&
              completion.completedAt.isBefore(nextMonthStart),
        )
        .toList(growable: false);
    // 上月有效完成次数。
    final int previousMonthCount = completionRecords.where((
      EventCompletionRecord completion,
    ) {
      return !completion.completedAt.isBefore(previousMonthStart) &&
          completion.completedAt.isBefore(currentMonthStart);
    }).length;
    // 本月与上月完成次数差值。
    final int monthDifference = monthCompletions.length - previousMonthCount;
    // 本月覆盖的事件数量。
    final int coveredEventCount = monthCompletions
        .map((EventCompletionRecord completion) => completion.eventId)
        .toSet()
        .length;
    // 本月环比文案。
    final String monthComparison = monthDifference == 0
        ? '与上月持平'
        : monthDifference > 0
        ? '比上月多 $monthDifference 次'
        : '比上月少 ${monthDifference.abs()} 次';
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 本月环比状态色。
    final Color monthComparisonColor = monthDifference == 0
        ? colors.muted
        : monthDifference > 0
        ? colors.success
        : colors.warning;
    // 超期、今天与未来六天的应做数量。
    final List<int> nearbyDueCounts = _nearbyDueCounts(
      repository,
      eventRecords,
    );
    // 已超期事件数量。
    final int overdueCount = nearbyDueCounts.first;
    // 今天至未来第六天应做的事件数量。
    final int nextSevenDaysCount = nearbyDueCounts
        .skip(1)
        .fold<int>(0, (int total, int count) => total + count);
    // 近期需要处理的事件总数。
    final int nearbyDueTotal = overdueCount + nextSevenDaysCount;
    // 近期事件状态文案。
    final String nearbyBadge = overdueCount > 0
        ? '优先处理超期'
        : nextSevenDaysCount > 0
        ? '近期留意'
        : '当前节奏良好';
    // 近期事件状态色。
    final Color nearbyAccent = overdueCount > 0
        ? colors.danger
        : nextSevenDaysCount > 0
        ? colors.warning
        : colors.success;
    // 三张事件统计卡片。
    final List<Widget> cards = <Widget>[
      _EventMetricCard(
        label: '进行中事件',
        value: '${eventRecords.length} 项',
        hint: unrecordedCount > 0 ? '$unrecordedCount 项待首次记录' : '全部已开始记录',
        badge: eventRecords.isEmpty ? '暂无进行中事件' : '节奏正常 $normalCount 项',
        icon: Icons.event_repeat_rounded,
        accent: colors.event,
        badgeAccent: eventRecords.isEmpty ? colors.muted : colors.success,
        chart: _EventStatusDistribution(
          slices: <_EventStatusSlice>[
            _EventStatusSlice(
              label: '节奏正常',
              count: normalCount,
              color: colors.success,
            ),
            _EventStatusSlice(
              label: '即将到期',
              count: statusCounts[EventDueStatus.upcoming] ?? 0,
              color: colors.warning,
            ),
            _EventStatusSlice(
              label: '已经超期',
              count: statusCounts[EventDueStatus.overdue] ?? 0,
              color: colors.danger,
            ),
            _EventStatusSlice(
              label: '待首次记录',
              count: unrecordedCount,
              color: colors.info,
            ),
          ],
        ),
      ),
      _EventMetricCard(
        label: '本月完成',
        value: '${monthCompletions.length} 次',
        hint: monthCompletions.isEmpty ? '本月暂无完成' : '覆盖 $coveredEventCount 个事件',
        badge: monthComparison,
        icon: Icons.task_alt_rounded,
        accent: colors.brand,
        badgeAccent: monthComparisonColor,
        chart: _EventMiniBarChart(
          values: _monthWeeklyCompletions(completionRecords),
          colors: List<Color>.filled(5, colors.brand),
        ),
      ),
      _EventMetricCard(
        label: '近期应做',
        value: '$nearbyDueTotal 项',
        hint: '超期 $overdueCount · 7 天内 $nextSevenDaysCount',
        badge: nearbyBadge,
        icon: Icons.schedule_rounded,
        accent: nearbyAccent,
        badgeAccent: nearbyAccent,
        chart: _EventMiniBarChart(
          values: nearbyDueCounts,
          colors: <Color>[
            colors.danger,
            colors.warning,
            ...List<Color>.filled(6, colors.event),
          ],
        ),
      ),
    ];
    if (useCarousel) {
      return OmniStatisticsCarousel(
        key: const ValueKey<String>('event-statistics-carousel'),
        cardHeight: 160,
        children: cards,
      );
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 摘要卡片是否横向完整展示。
        final bool showCompleteRow = constraints.maxWidth >= 720;
        if (!showCompleteRow) {
          return SingleChildScrollView(
            key: const ValueKey<String>('event-statistics-scroll'),
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                for (
                  int index = 0;
                  index < cards.length;
                  index += 1
                ) ...<Widget>[
                  if (index > 0) const SizedBox(width: OmniSpacing.xs),
                  SizedBox(width: 260, child: cards[index]),
                ],
              ],
            ),
          );
        }
        return Row(
          children: <Widget>[
            for (int index = 0; index < cards.length; index += 1) ...<Widget>[
              if (index > 0) const SizedBox(width: OmniSpacing.xs),
              Expanded(child: cards[index]),
            ],
          ],
        );
      },
    );
  }
}

/// 单张事件统计指标卡片。
class _EventMetricCard extends StatelessWidget {
  /// 指标名称。
  final String label;

  /// 指标值。
  final String value;

  /// 指标辅助说明。
  final String hint;

  /// 指标状态标签。
  final String badge;

  /// 指标图标。
  final IconData icon;

  /// 指标强调色。
  final Color accent;

  /// 状态标签语义色。
  final Color badgeAccent;

  /// 卡片底部图表。
  final Widget chart;

  /// 创建事件统计指标卡片。
  const _EventMetricCard({
    required this.label,
    required this.value,
    required this.hint,
    required this.badge,
    required this.icon,
    required this.accent,
    required this.badgeAccent,
    required this.chart,
  });

  /// 构建固定高度的统计指标卡片。
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: ValueKey<String>('event-metric-$label'),
      height: 160,
      child: OmniPanel(
        padding: const EdgeInsets.all(OmniSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: OmniSize.control,
                  height: OmniSize.control,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(OmniRadius.panel),
                  ),
                  alignment: Alignment.center,
                  child: Icon(icon, size: OmniSize.icon, color: accent),
                ),
                const SizedBox(width: OmniSpacing.xs),
                Text(label, style: Theme.of(context).textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: OmniSpacing.xs),
            Text(value, style: Theme.of(context).textTheme.displaySmall),
            const Spacer(),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const SizedBox(width: OmniSpacing.xs),
                Flexible(
                  flex: 2,
                  child: Tooltip(
                    message: badge,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: OmniSpacing.xs,
                        vertical: OmniSpacing.xxs,
                      ),
                      decoration: BoxDecoration(
                        color: badgeAccent.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(OmniRadius.pill),
                      ),
                      child: Text(
                        badge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: badgeAccent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: OmniSpacing.xs),
            chart,
          ],
        ),
      ),
    );
  }
}

/// 事件状态分布切片。
class _EventStatusSlice {
  /// 状态名称。
  final String label;

  /// 状态事件数量。
  final int count;

  /// 状态颜色。
  final Color color;

  /// 创建事件状态分布切片。
  const _EventStatusSlice({
    required this.label,
    required this.count,
    required this.color,
  });
}

/// 事件统计卡底部的状态比例轨道。
class _EventStatusDistribution extends StatelessWidget {
  /// 全部状态切片。
  final List<_EventStatusSlice> slices;

  /// 创建事件状态比例轨道。
  const _EventStatusDistribution({required this.slices});

  /// 构建按事件数量分配宽度的状态比例轨道。
  @override
  Widget build(BuildContext context) {
    // 当前有数据的状态切片。
    final List<_EventStatusSlice> visibleSlices = slices
        .where((_EventStatusSlice slice) => slice.count > 0)
        .toList(growable: false);
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    if (visibleSlices.isEmpty) {
      return Container(
        key: const ValueKey<String>('event-status-distribution'),
        height: 18,
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: colors.mist)),
        ),
      );
    }
    return SizedBox(
      key: const ValueKey<String>('event-status-distribution'),
      height: 18,
      child: Row(
        children: <Widget>[
          for (
            int index = 0;
            index < visibleSlices.length;
            index += 1
          ) ...<Widget>[
            if (index > 0) const SizedBox(width: 2),
            Flexible(
              flex: visibleSlices[index].count,
              child: Tooltip(
                message:
                    '${visibleSlices[index].label} ${visibleSlices[index].count} 项',
                child: Container(
                  height: 6,
                  decoration: BoxDecoration(
                    color: visibleSlices[index].color.withValues(alpha: 0.76),
                    borderRadius: BorderRadius.circular(OmniRadius.pill),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 事件统计卡底部的迷你柱状图。
class _EventMiniBarChart extends StatelessWidget {
  /// 各时间段的统计值。
  final List<int> values;

  /// 各时间段的强调色。
  final List<Color> colors;

  /// 创建事件迷你柱状图。
  const _EventMiniBarChart({required this.values, required this.colors});

  /// 构建时间分布迷你柱状图。
  @override
  Widget build(BuildContext context) {
    // 所有时间段中的最大值。
    int maxValue = 0;
    for (final int value in values) {
      if (value > maxValue) {
        maxValue = value;
      }
    }
    // 当前主题语义色。
    final OmniColors themeColors = OmniColors.of(context);
    return Container(
      height: 18,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: themeColors.line)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          for (int index = 0; index < values.length; index += 1) ...<Widget>[
            if (index > 0) const SizedBox(width: OmniSpacing.xxs),
            Expanded(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  width: 6,
                  height: maxValue == 0
                      ? 2
                      : 2 + (values[index] / maxValue) * 14,
                  decoration: BoxDecoration(
                    color: colors[index].withValues(
                      alpha: values[index] == 0 ? 0.14 : 0.68,
                    ),
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(OmniRadius.tiny),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 事件状态筛选与布局操作栏。
class _EventToolbar extends StatelessWidget {
  /// 是否显示归档事件。
  final bool showArchived;

  /// 是否优先使用双列布局。
  final bool useTwoColumns;

  /// 归档筛选变更回调。
  final ValueChanged<bool> onArchivedChanged;

  /// 布局切换回调。
  final VoidCallback onToggleLayout;

  /// 创建事件工具栏。
  const _EventToolbar({
    required this.showArchived,
    required this.useTwoColumns,
    required this.onArchivedChanged,
    required this.onToggleLayout,
  });

  /// 构建状态筛选和单双列切换。
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 当前宽度是否允许双列事件卡片。
        final bool canUseTwoColumns = constraints.maxWidth >= 780;
        return OmniToolbar(
          alignment: WrapAlignment.spaceBetween,
          children: <Widget>[
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const <ButtonSegment<bool>>[
                ButtonSegment<bool>(value: false, label: Text('进行中')),
                ButtonSegment<bool>(value: true, label: Text('已归档')),
              ],
              selected: <bool>{showArchived},
              onSelectionChanged: (Set<bool> selection) {
                onArchivedChanged(selection.first);
              },
            ),
            OmniButton(
              key: const ValueKey<String>('event-layout-toggle'),
              label: canUseTwoColumns
                  ? useTwoColumns
                        ? '单列'
                        : '双列'
                  : '单列',
              icon: useTwoColumns && canUseTwoColumns
                  ? Icons.view_agenda_outlined
                  : Icons.grid_view_outlined,
              variant: OmniButtonVariant.secondary,
              onPressed: canUseTwoColumns ? onToggleLayout : null,
            ),
          ],
        );
      },
    );
  }
}

/// 自适应单双列事件卡片区域。
class _EventCardGrid extends StatelessWidget {
  /// 当前事件列表。
  final List<EventRecord> events;

  /// 当前是否来自归档列表。
  final bool archived;

  /// 是否优先使用双列布局。
  final bool useTwoColumns;

  /// 记录完成回调。
  final ValueChanged<EventRecord> onRecord;

  /// 查看完成历史回调。
  final ValueChanged<EventRecord> onHistory;

  /// 编辑事件回调。
  final ValueChanged<EventRecord> onEdit;

  /// 归档事件回调。
  final ValueChanged<EventRecord> onArchive;

  /// 删除事件回调。
  final ValueChanged<EventRecord> onDelete;

  /// 创建事件卡片区域。
  const _EventCardGrid({
    required this.events,
    required this.archived,
    required this.useTwoColumns,
    required this.onRecord,
    required this.onHistory,
    required this.onEdit,
    required this.onArchive,
    required this.onDelete,
  });

  /// 构建可滚动的事件卡片流。
  @override
  Widget build(BuildContext context) {
    return ListView(
      children: <Widget>[
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            // 当前宽度下是否实际使用双列布局。
            final bool showTwoColumns =
                useTwoColumns && constraints.maxWidth >= 780;
            // 单张事件卡片宽度。
            final double cardWidth = showTwoColumns
                ? (constraints.maxWidth - OmniSpacing.xs) / 2
                : constraints.maxWidth;
            return Wrap(
              spacing: OmniSpacing.xs,
              runSpacing: OmniSpacing.xs,
              children: events
                  .map((EventRecord event) {
                    return SizedBox(
                      width: cardWidth,
                      child: _EventCard(
                        key: ValueKey<String>('event-card-${event.id}'),
                        event: event,
                        archived: archived,
                        onRecord: () => onRecord(event),
                        onHistory: () => onHistory(event),
                        onEdit: () => onEdit(event),
                        onArchive: () => onArchive(event),
                        onDelete: () => onDelete(event),
                      ),
                    );
                  })
                  .toList(growable: false),
            );
          },
        ),
      ],
    );
  }
}

/// 周期事件卡片。
class _EventCard extends ConsumerWidget {
  /// 当前事件。
  final EventRecord event;

  /// 当前是否来自归档列表。
  final bool archived;

  /// 记录完成回调。
  final VoidCallback onRecord;

  /// 查看完成历史回调。
  final VoidCallback onHistory;

  /// 编辑回调。
  final VoidCallback onEdit;

  /// 归档回调。
  final VoidCallback onArchive;

  /// 删除回调。
  final VoidCallback onDelete;

  /// 创建周期事件卡片。
  const _EventCard({
    required this.event,
    required this.archived,
    required this.onRecord,
    required this.onHistory,
    required this.onEdit,
    required this.onArchive,
    required this.onDelete,
    super.key,
  });

  /// 构建周期事件卡片。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 事件仓储。
    final EventRepository repository = ref.watch(eventRepositoryProvider);
    // 当前时间。
    final DateTime now = ref.watch(nowProvider);
    // 当前状态。
    final EventDueStatus status = repository.statusFor(event, now);
    // 下一次应做时间。
    final DateTime? dueAt = repository.nextDueAt(event);
    // 主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 状态标签与语义色。
    final (String, Color) statusView = switch (status) {
      EventDueStatus.unrecorded => ('待首次记录', colors.info),
      EventDueStatus.normal => ('节奏正常', colors.success),
      EventDueStatus.upcoming => ('即将到期', colors.warning),
      EventDueStatus.overdue => ('已经超期', colors.danger),
    };
    // 归档事件统一使用弱化状态。
    final (String, Color) effectiveStatusView = archived
        ? ('已归档', colors.muted)
        : statusView;
    // 事件说明优先展示描述，其次展示备注。
    final String detail = (event.description ?? event.notes ?? '').trim();
    // 事件分类文案。
    final String categoryLabel = event.category?.trim().isNotEmpty == true
        ? event.category!.trim()
        : '未分类';
    // 分类、周期与说明组成的一行元信息。
    final String metadata = <String>[
      categoryLabel,
      _intervalLabel(event),
      if (detail.isNotEmpty) detail,
    ].join(' · ');
    // 当前事件最重要的时间状态文案。
    final String headline = _headlineFor(status, dueAt, now, archived);
    // 时间状态右侧的具体日期说明。
    final String scheduleLabel = archived
        ? event.archivedAt == null
              ? '已停止周期提醒'
              : '归档于 ${event.archivedAt!.month} 月 ${event.archivedAt!.day} 日'
        : dueAt == null
        ? '完成一次后开始推算'
        : '下次 ${dueAt.month} 月 ${dueAt.day} 日';
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 当前事件操作菜单。
        final Widget menu = OmniPopupMenuButton<String>(
          tooltip: '更多操作',
          onSelected: (String value) {
            switch (value) {
              case 'edit':
                onEdit();
              case 'archive':
                onArchive();
              case 'delete':
                onDelete();
            }
          },
          itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
            if (!archived)
              OmniPopupMenuItem<String>(
                value: 'edit',
                label: '编辑',
                icon: Icons.edit_outlined,
              ),
            if (!archived)
              OmniPopupMenuItem<String>(
                value: 'archive',
                label: '归档',
                icon: Icons.archive_outlined,
              ),
            OmniPopupMenuItem<String>(
              value: 'delete',
              label: '移入回收站',
              icon: Icons.delete_outline_rounded,
              danger: true,
            ),
          ],
        );
        return OmniPanel(
          padding: const EdgeInsets.all(OmniSpacing.md),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 184),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: colors.event.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(OmniRadius.panel),
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.event_repeat_rounded,
                        size: OmniSize.icon,
                        color: colors.event,
                      ),
                    ),
                    const SizedBox(width: OmniSpacing.xs),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            event.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 1),
                          Text(
                            metadata,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: OmniSpacing.xs),
                    OmniTag(
                      label: effectiveStatusView.$1,
                      color: effectiveStatusView.$2,
                    ),
                    const SizedBox(width: OmniSpacing.xxs),
                    menu,
                  ],
                ),
                const SizedBox(height: OmniSpacing.sm),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        headline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.headlineLarge
                            ?.copyWith(color: effectiveStatusView.$2),
                      ),
                    ),
                    const SizedBox(width: OmniSpacing.xs),
                    Flexible(
                      child: Text(
                        scheduleLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: OmniSpacing.sm),
                _EventCycleTimeline(
                  key: ValueKey<String>('event-timeline-${event.id}'),
                  event: event,
                  dueAt: dueAt,
                  now: now,
                  archived: archived,
                  progressColor: effectiveStatusView.$2,
                ),
                const SizedBox(height: OmniSpacing.xs),
                Divider(height: 1, color: colors.line),
                const SizedBox(height: OmniSpacing.xxs),
                Row(
                  children: <Widget>[
                    OmniButton(
                      key: ValueKey<String>('event-history-${event.id}'),
                      label: '历史',
                      icon: Icons.history_rounded,
                      variant: OmniButtonVariant.text,
                      onPressed: onHistory,
                    ),
                    const Spacer(),
                    OmniButton(
                      key: ValueKey<String>(
                        archived
                            ? 'event-restore-${event.id}'
                            : 'event-record-${event.id}',
                      ),
                      label: archived
                          ? '恢复'
                          : status == EventDueStatus.unrecorded
                          ? '首次记录'
                          : '记录',
                      icon: archived
                          ? Icons.unarchive_outlined
                          : Icons.done_rounded,
                      variant: archived
                          ? OmniButtonVariant.secondary
                          : OmniButtonVariant.primary,
                      onPressed: archived ? onArchive : onRecord,
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 返回事件周期文案。
  String _intervalLabel(EventRecord event) {
    // 周期单位文案。
    final String unit = switch (event.intervalUnit) {
      'day' => '天',
      'week' => '周',
      'year' => '年',
      _ => '个月',
    };
    return '每 ${event.intervalValue} $unit';
  }

  /// 返回事件卡片最醒目的时间状态文案。
  String _headlineFor(
    EventDueStatus status,
    DateTime? dueAt,
    DateTime now,
    bool archived,
  ) {
    if (archived) {
      return '已归档';
    }
    if (status == EventDueStatus.unrecorded || dueAt == null) {
      return '还未开始计时';
    }
    // 应做日期与今天的自然日差值。
    final int dayOffset = DateUtils.dateOnly(dueAt)
        .difference(DateUtils.dateOnly(now))
        .inDays;
    return switch (status) {
      EventDueStatus.unrecorded => '还未开始计时',
      EventDueStatus.normal => dayOffset == 0 ? '今天应做' : '还有 $dayOffset 天',
      EventDueStatus.upcoming => dayOffset == 0 ? '今天应做' : '$dayOffset 天后应做',
      EventDueStatus.overdue =>
        dayOffset == 0 ? '今天已超期' : '已超期 ${dayOffset.abs()} 天',
    };
  }
}

/// 事件最近完成时间到下一次应做时间的周期进度条。
class _EventCycleTimeline extends StatelessWidget {
  /// 当前事件。
  final EventRecord event;

  /// 可选下一次应做时间。
  final DateTime? dueAt;

  /// 当前时间。
  final DateTime now;

  /// 当前事件是否已归档。
  final bool archived;

  /// 时间条进度色。
  final Color progressColor;

  /// 创建事件周期时间条。
  const _EventCycleTimeline({
    required this.event,
    required this.dueAt,
    required this.now,
    required this.archived,
    required this.progressColor,
    super.key,
  });

  /// 构建贯穿卡片宽度的周期轨道与端点日期。
  @override
  Widget build(BuildContext context) {
    // 主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 可选周期起始时间。
    final DateTime? periodStart = event.lastCompletedAt;
    // 周期总毫秒数。
    final int totalMilliseconds = periodStart == null || dueAt == null
        ? 0
        : dueAt!.difference(periodStart).inMilliseconds;
    // 当前周期已经过的毫秒数。
    final int elapsedMilliseconds = periodStart == null
        ? 0
        : now.difference(periodStart).inMilliseconds;
    // 当前周期进度。
    final double progress = totalMilliseconds <= 0
        ? 0
        : (elapsedMilliseconds / totalMilliseconds).clamp(0.0, 1.0).toDouble();
    // 归档事件统一使用弱化后的轨道颜色。
    final Color effectiveProgressColor = archived
        ? colors.muted
        : progressColor;
    // 当前是否等待首次完成记录。
    final bool waitingForFirstRecord = periodStart == null || dueAt == null;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 窄卡片使用短日期格式。
        final bool compactLabels = constraints.maxWidth < 360;
        // 轨道起点文案。
        final String startLabel = periodStart == null
            ? '尚未完成'
            : '上次完成 ${_dateLabel(periodStart, compactLabels)}';
        // 轨道终点文案。
        final String dueLabel = dueAt == null
            ? '完成后开始周期'
            : '${archived ? '原定应做' : '下次应做'} ${_dateLabel(dueAt!, compactLabels)}';
        // 是否关闭轨道变化动画。
        final bool disableAnimations = MediaQuery.disableAnimationsOf(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              height: 12,
              child: waitingForFirstRecord
                  ? _buildWaitingTrack(colors)
                  : TweenAnimationBuilder<double>(
                      tween: Tween<double>(begin: 0, end: progress),
                      duration: disableAnimations
                          ? Duration.zero
                          : OmniMotion.panel,
                      builder:
                          (
                            BuildContext context,
                            double animatedProgress,
                            Widget? child,
                          ) {
                            return _buildActiveTrack(
                              constraints.maxWidth,
                              animatedProgress,
                              effectiveProgressColor,
                              colors,
                            );
                          },
                    ),
            ),
            const SizedBox(height: OmniSpacing.xxs),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    startLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
                const SizedBox(width: OmniSpacing.xs),
                Expanded(
                  child: Text(
                    dueLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  /// 构建等待首次记录时的蓝灰色虚线轨道。
  Widget _buildWaitingTrack(OmniColors colors) {
    return Row(
      children: <Widget>[
        for (int index = 0; index < 14; index += 1)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Container(
                height: 4,
                decoration: BoxDecoration(
                  color: colors.info.withValues(alpha: 0.24),
                  borderRadius: BorderRadius.circular(OmniRadius.pill),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 构建包含起点、当前位置和终点的实线周期轨道。
  Widget _buildActiveTrack(
    double width,
    double progress,
    Color color,
    OmniColors colors,
  ) {
    // 当前进度点的水平位置。
    final double progressLeft = (width - 12) * progress;
    return Stack(
      alignment: Alignment.centerLeft,
      children: <Widget>[
        Positioned.fill(
          top: 3,
          bottom: 3,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.mist,
              borderRadius: BorderRadius.circular(OmniRadius.pill),
            ),
          ),
        ),
        if (progress > 0)
          Positioned(
            left: 0,
            top: 3,
            bottom: 3,
            width: width * progress,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(OmniRadius.pill),
              ),
            ),
          ),
        Positioned(
          left: 1,
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        ),
        Positioned(
          left: progressLeft,
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: colors.paper, width: 2),
            ),
          ),
        ),
        Positioned(
          right: 1,
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: progress >= 1 ? color : colors.mist,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ],
    );
  }

  /// 根据卡片宽度返回完整或紧凑日期文案。
  String _dateLabel(DateTime date, bool compact) {
    if (compact) {
      return DateFormat('MM-dd').format(date);
    }
    return '${date.month} 月 ${date.day} 日';
  }
}

/// 事件空状态。
class _EmptyEvents extends StatelessWidget {
  /// 当前是否为归档列表。
  final bool archived;

  /// 创建事件空状态。
  const _EmptyEvents({required this.archived});

  /// 构建事件空状态。
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.event_repeat_rounded, size: 48),
          const SizedBox(height: 14),
          Text(archived ? '暂时没有归档事件' : '先建立一个需要反复完成的事件'),
          if (!archived) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              '例如：更换滤芯、整理账单或复查证件。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

/// 周期事件编辑弹窗。
class _EventEditorDialog extends ConsumerStatefulWidget {
  /// 可选待编辑事件。
  final EventRecord? event;

  /// 创建周期事件编辑弹窗。
  const _EventEditorDialog({this.event});

  /// 创建弹窗状态。
  @override
  ConsumerState<_EventEditorDialog> createState() => _EventEditorDialogState();
}

/// 周期事件编辑弹窗状态。
class _EventEditorDialogState extends ConsumerState<_EventEditorDialog> {
  /// 表单键。
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  /// 名称控制器。
  late final TextEditingController _nameController;

  /// 分类控制器。
  late final TextEditingController _categoryController;

  /// 说明控制器。
  late final TextEditingController _descriptionController;

  /// 间隔控制器。
  late final TextEditingController _intervalController;

  /// 提醒天数控制器。
  late final TextEditingController _reminderController;

  /// 备注控制器。
  late final TextEditingController _notesController;

  /// 当前周期单位。
  late EventIntervalUnit _unit;

  /// 是否开启提醒。
  late bool _reminderEnabled;

  /// 提醒时刻相对午夜的分钟数。
  late int _reminderTimeMinutes;

  /// 是否正在保存。
  bool _saving = false;

  /// 初始化编辑表单。
  @override
  void initState() {
    super.initState();
    // 待编辑事件。
    final EventRecord? event = widget.event;
    _nameController = TextEditingController(text: event?.name ?? '');
    _categoryController = TextEditingController(text: event?.category ?? '');
    _descriptionController = TextEditingController(
      text: event?.description ?? '',
    );
    _intervalController = TextEditingController(
      text: '${event?.intervalValue ?? 1}',
    );
    _reminderController = TextEditingController(
      text: '${event?.reminderDaysBefore ?? 1}',
    );
    _notesController = TextEditingController(text: event?.notes ?? '');
    _unit = EventIntervalUnit.values.firstWhere(
      (EventIntervalUnit value) => value.name == event?.intervalUnit,
      orElse: () => EventIntervalUnit.month,
    );
    _reminderEnabled = event?.reminderEnabled ?? true;
    _reminderTimeMinutes = event?.reminderTimeMinutes ?? 540;
  }

  /// 释放文本控制器。
  @override
  void dispose() {
    _nameController.dispose();
    _categoryController.dispose();
    _descriptionController.dispose();
    _intervalController.dispose();
    _reminderController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  /// 保存事件。
  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    setState(() => _saving = true);
    try {
      await ref
          .read(eventRepositoryProvider)
          .save(
            EventDraft(
              id: widget.event?.id,
              name: _nameController.text,
              description: _descriptionController.text,
              category: _categoryController.text,
              intervalValue: int.parse(_intervalController.text),
              intervalUnit: _unit,
              lastCompletedAt: widget.event?.lastCompletedAt,
              reminderEnabled: _reminderEnabled,
              reminderDaysBefore: _reminderEnabled
                  ? int.parse(_reminderController.text)
                  : 0,
              reminderTimeMinutes: _reminderTimeMinutes,
              notes: _notesController.text,
            ),
          );
      if (mounted) {
        Navigator.of(context).pop();
      }
    } on FormatException catch (error) {
      if (mounted) {
        showOmniMessage(
          context,
          message: error.message,
          tone: OmniMessageTone.error,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  /// 构建周期事件编辑表单。
  @override
  Widget build(BuildContext context) {
    return OmniSideSheetScaffold(
      title: widget.event == null ? '新建周期事件' : '编辑周期事件',
      canClose: !_saving,
      actions: <Widget>[
        OmniButton(
          label: '取消',
          variant: OmniButtonVariant.secondary,
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
        ),
        OmniButton(
          label: '保存',
          onPressed: _saving ? null : _save,
          loading: _saving,
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.all(OmniSpacing.lg),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextFormField(
                  controller: _nameController,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: '事件名称 *'),
                  validator: (String? value) =>
                      value == null || value.trim().isEmpty ? '请输入事件名称' : null,
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _categoryController,
                  decoration: const InputDecoration(labelText: '分类'),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _descriptionController,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: '事件说明'),
                ),
                const SizedBox(height: 14),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: TextFormField(
                        controller: _intervalController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: '每隔 *'),
                        validator: (String? value) {
                          // 解析后的间隔数值。
                          final int? parsed = int.tryParse(value ?? '');
                          return parsed == null || parsed <= 0
                              ? '请输入正整数'
                              : null;
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OmniDropdownButtonFormField<EventIntervalUnit>(
                        initialValue: _unit,
                        decoration: const InputDecoration(labelText: '周期单位'),
                        items: EventIntervalUnit.values
                            .map(
                              (EventIntervalUnit unit) =>
                                  DropdownMenuItem<EventIntervalUnit>(
                                    value: unit,
                                    child: Text(_unitLabel(unit)),
                                  ),
                            )
                            .toList(growable: false),
                        onChanged: (EventIntervalUnit? value) {
                          if (value != null) {
                            setState(() => _unit = value);
                          }
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                OmniSwitchListTile(
                  value: _reminderEnabled,
                  title: const Text('进入到期窗口时提醒'),
                  onChanged: (bool value) =>
                      setState(() => _reminderEnabled = value),
                ),
                if (_reminderEnabled)
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: TextFormField(
                          controller: _reminderController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: '提前天数'),
                          validator: (String? value) {
                            // 解析后的提醒天数。
                            final int? parsed = int.tryParse(value ?? '');
                            return parsed == null || parsed < 0
                                ? '请输入不小于 0 的整数'
                                : null;
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OmniDropdownButtonFormField<int>(
                          initialValue: _reminderTimeMinutes,
                          decoration: const InputDecoration(labelText: '提醒时刻'),
                          items:
                              List<int>.generate(48, (int index) => index * 30)
                                  .map(
                                    (int minute) => DropdownMenuItem<int>(
                                      value: minute,
                                      child: Text(_minuteLabel(minute)),
                                    ),
                                  )
                                  .toList(growable: false),
                          onChanged: (int? value) {
                            if (value != null) {
                              setState(() => _reminderTimeMinutes = value);
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 14),
                TextField(
                  controller: _notesController,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: '备注'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 返回周期单位名称。
  String _unitLabel(EventIntervalUnit unit) {
    return switch (unit) {
      EventIntervalUnit.day => '天',
      EventIntervalUnit.week => '周',
      EventIntervalUnit.month => '月',
      EventIntervalUnit.year => '年',
    };
  }

  /// 将午夜分钟数格式化为时间。
  String _minuteLabel(int minute) {
    return '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';
  }
}

/// 事件完成历史弹窗。
class _EventHistoryDialog extends ConsumerWidget {
  /// 当前事件。
  final EventRecord event;

  /// 创建事件完成历史弹窗。
  const _EventHistoryDialog({required this.event});

  /// 打开新增或编辑历史弹窗。
  Future<void> _edit(
    BuildContext context,
    WidgetRef ref, [
    EventCompletionRecord? completion,
  ]) async {
    // 用户提交的历史草稿。
    final (DateTime, String?)? result = await showDialog<(DateTime, String?)>(
      context: context,
      builder: (BuildContext context) =>
          _EventHistoryEditorDialog(completion: completion),
    );
    if (result == null) {
      return;
    }
    // 周期事件仓储。
    final EventRepository repository = ref.read(eventRepositoryProvider);
    if (completion == null) {
      await repository.addHistory(
        eventId: event.id,
        completedAt: result.$1,
        notes: result.$2,
      );
    } else {
      await repository.updateHistory(
        id: completion.id,
        eventId: event.id,
        completedAt: result.$1,
        notes: result.$2,
      );
    }
  }

  /// 二次确认并删除历史记录。
  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    EventCompletionRecord completion,
  ) async {
    // 用户是否确认删除。
    final bool confirmed = await showOmniConfirmDialog(
      context,
      title: '删除这条完成记录？',
      message: '删除后会根据剩余历史重新计算事件的上次完成时间。',
      confirmLabel: '删除',
      danger: true,
    );
    if (confirmed) {
      await ref.read(eventRepositoryProvider).deleteHistory(completion);
    }
  }

  /// 过滤掉已撤销的记录，只保留用户可管理的有效历史。
  List<EventCompletionRecord> _visibleHistory(
    List<EventCompletionRecord> records,
  ) {
    return records
        .where((EventCompletionRecord completion) => !completion.isRevoked)
        .toList(growable: false);
  }

  /// 构建事件完成历史弹窗。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 当前完成历史流。
    final AsyncValue<List<EventCompletionRecord>> history = ref.watch(
      eventHistoryProvider(event.id),
    );
    // 当前有效完成历史。
    final List<EventCompletionRecord> visibleRecords = _visibleHistory(
      history.asData?.value ?? const <EventCompletionRecord>[],
    );
    // 用于自适应弹窗高度的可见记录数量。
    final int measuredRecordCount = math.min(visibleRecords.length, 5);
    // 弹窗主体期望高度。
    final double desiredBodyHeight = visibleRecords.isEmpty
        ? 270
        : (218 + measuredRecordCount * 72).clamp(330, 510).toDouble();
    // 当前视口允许的弹窗最大高度。
    final double availableDialogHeight = MediaQuery.sizeOf(context).height - 48;
    // 加入统一标题区后最终使用的弹窗高度。
    final double dialogHeight = math.min(
      desiredBodyHeight + 94,
      availableDialogHeight,
    );
    // 周期事件仓储。
    final EventRepository repository = ref.watch(eventRepositoryProvider);

    return OmniDialogScaffold(
      title: event.name,
      width: 600,
      height: dialogHeight,
      child: SizedBox(
        width: double.infinity,
        height: desiredBodyHeight,
        child: history.when(
          data: (List<EventCompletionRecord> records) {
            // 当前有效完成历史。
            final List<EventCompletionRecord> effectiveRecords =
                _visibleHistory(records);
            return _EventHistoryContent(
              event: event,
              records: effectiveRecords,
              repository: repository,
              onAdd: () => _edit(context, ref),
              onEdit: (EventCompletionRecord completion) =>
                  _edit(context, ref, completion),
              onDelete: (EventCompletionRecord completion) =>
                  _delete(context, ref, completion),
            );
          },
          loading: () => const _EventHistoryLoading(),
          error: (Object error, StackTrace stackTrace) => _EventHistoryError(
            onRetry: () => ref.invalidate(eventHistoryProvider(event.id)),
          ),
        ),
      ),
    );
  }
}

/// 事件完成历史主体。
class _EventHistoryContent extends StatelessWidget {
  /// 当前事件。
  final EventRecord event;

  /// 当前有效完成记录。
  final List<EventCompletionRecord> records;

  /// 周期事件仓储。
  final EventRepository repository;

  /// 补记完成回调。
  final VoidCallback onAdd;

  /// 编辑完成记录回调。
  final ValueChanged<EventCompletionRecord> onEdit;

  /// 删除完成记录回调。
  final ValueChanged<EventCompletionRecord> onDelete;

  /// 创建事件完成历史主体。
  const _EventHistoryContent({
    required this.event,
    required this.records,
    required this.repository,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
  });

  /// 返回周期说明。
  String _periodLabel() {
    // 当前周期单位名称。
    final String unit = switch (event.intervalUnit) {
      'day' => '天',
      'week' => '周',
      'year' => '年',
      _ => '个月',
    };
    return '每 ${event.intervalValue} $unit';
  }

  /// 返回最近完成时间说明。
  String _latestLabel() {
    if (records.isEmpty) {
      return '尚未完成';
    }
    return DateFormat('M月d日 HH:mm').format(records.first.completedAt);
  }

  /// 返回下一次应做日期说明。
  String _nextDueLabel() {
    if (records.isEmpty) {
      return '完成后推算';
    }
    // 根据最新有效记录推算的下一次应做时间。
    final DateTime dueAt = repository.dueAtAfterCompletion(
      event,
      records.first.completedAt,
    );
    return DateFormat('M月d日').format(dueAt);
  }

  /// 构建按月份穿插的时间线内容。
  List<Widget> _timelineChildren() {
    // 每个月份的有效完成次数。
    final Map<String, int> monthCounts = <String, int>{};
    for (final EventCompletionRecord completion in records) {
      // 当前记录所属月份标识。
      final String monthKey = _monthKey(completion.completedAt);
      monthCounts[monthKey] = (monthCounts[monthKey] ?? 0) + 1;
    }

    // 最终时间线组件列表。
    final List<Widget> children = <Widget>[];
    for (int index = 0; index < records.length; index += 1) {
      // 当前完成记录。
      final EventCompletionRecord completion = records[index];
      // 当前记录所属月份标识。
      final String monthKey = _monthKey(completion.completedAt);
      // 上一条记录所属月份标识。
      final String? previousMonthKey = index == 0
          ? null
          : _monthKey(records[index - 1].completedAt);
      if (monthKey != previousMonthKey) {
        if (children.isNotEmpty) {
          children.add(const SizedBox(height: OmniSpacing.xs));
        }
        children.add(
          _EventHistoryMonthHeader(
            key: ValueKey<String>('event-history-month-$monthKey'),
            month: completion.completedAt,
            count: monthCounts[monthKey]!,
          ),
        );
        children.add(const SizedBox(height: OmniSpacing.xs));
      }
      children.add(
        _EventHistoryRecordTile(
          key: ValueKey<String>('event-history-record-${completion.id}'),
          completion: completion,
          onEdit: () => onEdit(completion),
          onDelete: () => onDelete(completion),
        ),
      );
      if (index < records.length - 1) {
        children.add(
          _EventHistoryGap(
            newer: completion,
            older: records[index + 1],
            event: event,
            repository: repository,
          ),
        );
      }
    }
    return children;
  }

  /// 返回年月分组标识。
  String _monthKey(DateTime value) {
    return '${value.year}-${value.month.toString().padLeft(2, '0')}';
  }

  /// 构建完成历史标题、摘要与时间线。
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '完成历史 · ${records.length} 条有效记录',
                key: const ValueKey<String>('event-history-count'),
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: OmniColors.of(context).muted),
              ),
            ),
            OmniButton(
              key: const ValueKey<String>('event-history-add'),
              label: '补记完成',
              icon: Icons.add_rounded,
              variant: OmniButtonVariant.secondary,
              onPressed: onAdd,
            ),
          ],
        ),
        const SizedBox(height: OmniSpacing.sm),
        _EventHistorySummary(
          latest: _latestLabel(),
          period: _periodLabel(),
          nextDue: _nextDueLabel(),
        ),
        const SizedBox(height: OmniSpacing.md),
        Expanded(
          child: records.isEmpty
              ? _EventHistoryEmpty(onAdd: onAdd)
              : ListView(
                  key: const ValueKey<String>('event-history-timeline'),
                  padding: EdgeInsets.zero,
                  children: _timelineChildren(),
                ),
        ),
      ],
    );
  }
}

/// 事件完成历史摘要栏。
class _EventHistorySummary extends StatelessWidget {
  /// 最近完成说明。
  final String latest;

  /// 计划周期说明。
  final String period;

  /// 下一次应做说明。
  final String nextDue;

  /// 创建事件完成历史摘要栏。
  const _EventHistorySummary({
    required this.latest,
    required this.period,
    required this.nextDue,
  });

  /// 构建可在窄屏换行的摘要信息。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Container(
      key: const ValueKey<String>('event-history-summary'),
      padding: const EdgeInsets.all(OmniSpacing.sm),
      decoration: BoxDecoration(
        color: colors.paperSubtle,
        borderRadius: BorderRadius.circular(OmniRadius.panel),
        border: Border.all(color: colors.line),
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // 当前摘要是否需要两列换行。
          final bool narrow = constraints.maxWidth < 420;
          // 每个摘要项的目标宽度。
          final double itemWidth = narrow
              ? (constraints.maxWidth - OmniSpacing.xs) / 2
              : (constraints.maxWidth - OmniSpacing.md * 2) / 3;
          return Wrap(
            spacing: narrow ? OmniSpacing.xs : OmniSpacing.md,
            runSpacing: OmniSpacing.sm,
            children: <Widget>[
              _EventHistorySummaryItem(
                width: itemWidth,
                label: '最近完成',
                value: latest,
              ),
              _EventHistorySummaryItem(
                width: itemWidth,
                label: '计划周期',
                value: period,
              ),
              _EventHistorySummaryItem(
                width: itemWidth,
                label: '下次应做',
                value: nextDue,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 事件完成历史单项摘要。
class _EventHistorySummaryItem extends StatelessWidget {
  /// 摘要项宽度。
  final double width;

  /// 摘要名称。
  final String label;

  /// 摘要值。
  final String value;

  /// 创建事件完成历史单项摘要。
  const _EventHistorySummaryItem({
    required this.width,
    required this.label,
    required this.value,
  });

  /// 构建摘要名称与值。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: colors.muted),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// 事件完成历史月份标题。
class _EventHistoryMonthHeader extends StatelessWidget {
  /// 当前月份。
  final DateTime month;

  /// 当前月份完成次数。
  final int count;

  /// 创建事件完成历史月份标题。
  const _EventHistoryMonthHeader({
    required this.month,
    required this.count,
    super.key,
  });

  /// 构建月份、次数与分隔线。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Row(
      children: <Widget>[
        Text(
          '${month.year} 年 ${month.month} 月 · $count 次',
          style: Theme.of(context).textTheme.labelMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(width: OmniSpacing.sm),
        Expanded(child: Divider(height: 1, color: colors.line)),
      ],
    );
  }
}

/// 事件完成历史记录行。
class _EventHistoryRecordTile extends StatelessWidget {
  /// 当前完成记录。
  final EventCompletionRecord completion;

  /// 编辑回调。
  final VoidCallback onEdit;

  /// 删除回调。
  final VoidCallback onDelete;

  /// 创建事件完成历史记录行。
  const _EventHistoryRecordTile({
    required this.completion,
    required this.onEdit,
    required this.onDelete,
    super.key,
  });

  /// 返回中文星期说明。
  String _weekdayLabel() {
    // 中文星期名称。
    const List<String> labels = <String>[
      '周一',
      '周二',
      '周三',
      '周四',
      '周五',
      '周六',
      '周日',
    ];
    return labels[completion.completedAt.weekday - 1];
  }

  /// 返回记录来源说明。
  String _sourceLabel() {
    return completion.source == 'recordNow' ? '自动记录' : '手动补记';
  }

  /// 处理记录操作菜单。
  void _handleAction(String value) {
    switch (value) {
      case 'edit':
        onEdit();
      case 'delete':
        onDelete();
    }
  }

  /// 构建日期、来源、备注与操作菜单。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前记录是否来自直接完成操作。
    final bool automatic = completion.source == 'recordNow';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 72,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                DateFormat('MM月dd日').format(completion.completedAt),
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(
                _weekdayLabel(),
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: colors.muted),
              ),
            ],
          ),
        ),
        const SizedBox(width: OmniSpacing.sm),
        SizedBox(
          width: 18,
          child: Align(
            alignment: Alignment.topCenter,
            child: Container(
              width: 12,
              height: 12,
              margin: const EdgeInsets.only(top: 4),
              decoration: BoxDecoration(
                color: colors.paper,
                shape: BoxShape.circle,
                border: Border.all(color: colors.success, width: 3),
              ),
            ),
          ),
        ),
        const SizedBox(width: OmniSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text(
                    DateFormat('HH:mm').format(completion.completedAt),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(width: OmniSpacing.xs),
                  OmniTag(
                    label: _sourceLabel(),
                    color: automatic ? colors.success : colors.info,
                  ),
                  const Spacer(),
                  OmniPopupMenuButton<String>(
                    key: ValueKey<String>(
                      'event-history-menu-${completion.id}',
                    ),
                    tooltip: '记录操作',
                    onSelected: _handleAction,
                    itemBuilder: (BuildContext context) =>
                        <PopupMenuEntry<String>>[
                          OmniPopupMenuItem<String>(
                            value: 'edit',
                            label: '编辑',
                            icon: Icons.edit_outlined,
                          ),
                          OmniPopupMenuItem<String>(
                            value: 'delete',
                            label: '删除记录',
                            icon: Icons.delete_outline_rounded,
                            danger: true,
                          ),
                        ],
                  ),
                ],
              ),
              if (completion.notes != null) ...<Widget>[
                const SizedBox(height: OmniSpacing.xxs),
                Text(
                  completion.notes!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colors.muted),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 两条完成历史之间的事件节奏间隔。
class _EventHistoryGap extends StatelessWidget {
  /// 较新的完成记录。
  final EventCompletionRecord newer;

  /// 较旧的完成记录。
  final EventCompletionRecord older;

  /// 当前事件。
  final EventRecord event;

  /// 周期事件仓储。
  final EventRepository repository;

  /// 创建完成历史间隔。
  const _EventHistoryGap({
    required this.newer,
    required this.older,
    required this.event,
    required this.repository,
  });

  /// 返回两次完成之间的实际间隔。
  String _intervalLabel() {
    // 两次完成之间的绝对时长。
    final Duration interval = newer.completedAt.difference(older.completedAt);
    if (interval.inDays >= 1) {
      return '相隔 ${interval.inDays} 天';
    }
    if (interval.inHours >= 1) {
      return '相隔 ${interval.inHours} 小时';
    }
    // 不足一小时的间隔分钟数。
    final int minutes = math.max(1, interval.inMinutes);
    return '相隔 $minutes 分钟';
  }

  /// 返回相对计划周期的偏差说明。
  String? _deviationLabel() {
    // 由较旧记录推算的计划完成时间。
    final DateTime plannedAt = repository.dueAtAfterCompletion(
      event,
      older.completedAt,
    );
    // 实际完成相对计划时间的整天偏差。
    final int days = newer.completedAt.difference(plannedAt).inDays;
    if (days > 0) {
      return '比计划晚 $days 天';
    }
    if (days < 0) {
      return '比计划早 ${days.abs()} 天';
    }
    return null;
  }

  /// 构建贯穿时间轴的间隔提示。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前计划偏差说明。
    final String? deviation = _deviationLabel();
    // 当前实际间隔说明。
    final String interval = _intervalLabel();
    // 当前完整间隔文案。
    final String label = deviation == null
        ? interval
        : '$interval · $deviation';
    return SizedBox(
      height: 34,
      child: Row(
        children: <Widget>[
          const SizedBox(width: 72 + OmniSpacing.sm),
          SizedBox(
            width: 18,
            child: Center(child: Container(width: 2, color: colors.line)),
          ),
          const SizedBox(width: OmniSpacing.sm),
          Expanded(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                // 窄屏下移除水平装饰线，为间隔文字保留完整空间。
                final bool narrow = constraints.maxWidth < 260;
                // 带稳定标识的间隔文字。
                final Widget intervalText = Text(
                  label,
                  key: ValueKey<String>(
                    'event-history-gap-${newer.id}-${older.id}',
                  ),
                  maxLines: narrow ? 2 : 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelSmall
                      ?.copyWith(color: colors.muted),
                );
                if (narrow) {
                  return Center(child: intervalText);
                }
                return Row(
                  children: <Widget>[
                    Expanded(child: Divider(height: 1, color: colors.line)),
                    const SizedBox(width: OmniSpacing.xs),
                    intervalText,
                    const SizedBox(width: OmniSpacing.xs),
                    Expanded(child: Divider(height: 1, color: colors.line)),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 事件完成历史空状态。
class _EventHistoryEmpty extends StatelessWidget {
  /// 补记第一次回调。
  final VoidCallback onAdd;

  /// 创建事件完成历史空状态。
  const _EventHistoryEmpty({required this.onAdd});

  /// 构建空状态引导。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.history_toggle_off_rounded, color: colors.muted, size: 32),
          const SizedBox(height: OmniSpacing.sm),
          Text('还没有完成记录', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: OmniSpacing.xxs),
          Text(
            '完成或补记一次后，这里会形成事件节奏。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.muted),
          ),
          const SizedBox(height: OmniSpacing.md),
          OmniButton(label: '补记第一次', icon: Icons.add_rounded, onPressed: onAdd),
        ],
      ),
    );
  }
}

/// 事件完成历史加载状态。
class _EventHistoryLoading extends StatelessWidget {
  /// 创建事件完成历史加载状态。
  const _EventHistoryLoading();

  /// 构建静态骨架块。
  Widget _bar(
    BuildContext context, {
    required double width,
    double height = 12,
  }) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: colors.mist,
        borderRadius: BorderRadius.circular(OmniRadius.control),
      ),
    );
  }

  /// 构建不产生持续动画的时间线骨架。
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _bar(context, width: 160),
        const SizedBox(height: OmniSpacing.sm),
        _bar(context, width: double.infinity, height: 56),
        const SizedBox(height: OmniSpacing.md),
        _bar(context, width: 120),
        const SizedBox(height: OmniSpacing.sm),
        for (int index = 0; index < 3; index += 1) ...<Widget>[
          _bar(context, width: double.infinity, height: 32),
          if (index < 2) const SizedBox(height: OmniSpacing.xs),
        ],
      ],
    );
  }
}

/// 事件完成历史错误状态。
class _EventHistoryError extends StatelessWidget {
  /// 重新加载回调。
  final VoidCallback onRetry;

  /// 创建事件完成历史错误状态。
  const _EventHistoryError({required this.onRetry});

  /// 构建错误说明与恢复入口。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.error_outline_rounded, color: colors.danger, size: 32),
          const SizedBox(height: OmniSpacing.sm),
          Text('完成历史读取失败', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: OmniSpacing.xxs),
          Text(
            '请重新加载；如果仍然失败，请检查本地数据状态。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.muted),
          ),
          const SizedBox(height: OmniSpacing.md),
          OmniButton(
            label: '重新加载',
            icon: Icons.refresh_rounded,
            variant: OmniButtonVariant.secondary,
            onPressed: onRetry,
          ),
        ],
      ),
    );
  }
}

/// 事件完成历史编辑弹窗。
class _EventHistoryEditorDialog extends StatefulWidget {
  /// 可选待编辑完成记录。
  final EventCompletionRecord? completion;

  /// 创建事件完成历史编辑弹窗。
  const _EventHistoryEditorDialog({this.completion});

  /// 创建弹窗状态。
  @override
  State<_EventHistoryEditorDialog> createState() =>
      _EventHistoryEditorDialogState();
}

/// 事件完成历史编辑弹窗状态。
class _EventHistoryEditorDialogState extends State<_EventHistoryEditorDialog> {
  /// 当前完成时间。
  late DateTime _completedAt;

  /// 备注控制器。
  late final TextEditingController _notesController;

  /// 初始化历史表单。
  @override
  void initState() {
    super.initState();
    _completedAt = widget.completion?.completedAt ?? DateTime.now();
    _notesController = TextEditingController(
      text: widget.completion?.notes ?? '',
    );
  }

  /// 释放备注控制器。
  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  /// 提交历史表单。
  void _submit() {
    // 清理后的备注。
    final String notes = _notesController.text.trim();
    Navigator.of(context).pop((_completedAt, notes.isEmpty ? null : notes));
  }

  /// 构建历史编辑表单。
  @override
  Widget build(BuildContext context) {
    return OmniDialogScaffold(
      title: widget.completion == null ? '补记完成历史' : '编辑完成历史',
      width: 420,
      actions: <Widget>[
        OmniButton(
          label: '取消',
          variant: OmniButtonVariant.secondary,
          onPressed: () => Navigator.of(context).pop(),
        ),
        OmniButton(label: '保存', onPressed: _submit),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: OmniDatePickerButton(
                  value: _completedAt,
                  initialDate: _completedAt,
                  firstDate: DateTime(1970),
                  lastDate: DateTime(2100),
                  label: DateFormat('yyyy-MM-dd').format(_completedAt),
                  onChanged: (DateTime selectedDate) {
                    setState(() {
                      _completedAt = DateTime(
                        selectedDate.year,
                        selectedDate.month,
                        selectedDate.day,
                        _completedAt.hour,
                        _completedAt.minute,
                      );
                    });
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OmniTimePickerButton(
                  value: TimeOfDay.fromDateTime(_completedAt),
                  label: DateFormat('HH:mm').format(_completedAt),
                  onChanged: (TimeOfDay selectedTime) {
                    setState(() {
                      _completedAt = DateTime(
                        _completedAt.year,
                        _completedAt.month,
                        _completedAt.day,
                        selectedTime.hour,
                        selectedTime.minute,
                      );
                    });
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _notesController,
            maxLines: 3,
            decoration: const InputDecoration(labelText: '备注'),
          ),
        ],
      ),
    );
  }
}
