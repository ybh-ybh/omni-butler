import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/features/timeline/data/time_entry_repository.dart';
import 'package:omni_butler/features/timeline/presentation/timeline_page.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 首页今日与本周时间状态卡片。
class HomeTimeStatusCard extends ConsumerWidget {
  /// 当前时间。
  final DateTime now;

  /// 创建首页时间状态卡片。
  const HomeTimeStatusCard({required this.now, super.key});

  /// 构建双圆环和今天的时间记录清单。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 今日自然日起点。
    final DateTime today = DateUtils.dateOnly(now);
    // 明日自然日起点。
    final DateTime tomorrow = today.add(const Duration(days: 1));
    // 本周周一起点。
    final DateTime weekStart = today.subtract(
      Duration(days: today.weekday - DateTime.monday),
    );
    // 下周周一起点。
    final DateTime weekEnd = weekStart.add(const Duration(days: 7));
    // 今日逻辑时间记录。
    final AsyncValue<List<TimeEntryRecord>> todayRecordsAsync = ref.watch(
      timeEntriesForDayProvider(today),
    );
    // 本周逻辑时间记录。
    final AsyncValue<List<TimeEntryRecord>> weekRecordsAsync = ref.watch(
      timeEntriesForRangeProvider((weekStart, weekEnd)),
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
    // 裁切到今天的自然日分段。
    final List<TimeEntryRecord> todaySegments = splitTimeEntriesForRange(
      records: todayRecordsAsync.asData?.value ?? const <TimeEntryRecord>[],
      rangeStart: today,
      rangeEnd: tomorrow,
      now: now,
    );
    // 裁切到本周的自然日分段。
    final List<TimeEntryRecord> weekSegments = splitTimeEntriesForRange(
      records: weekRecordsAsync.asData?.value ?? const <TimeEntryRecord>[],
      rangeStart: weekStart,
      rangeEnd: weekEnd,
      now: now,
    );
    // 时间记录仓储。
    final TimeEntryRepository repository = ref.watch(
      timeEntryRepositoryProvider,
    );
    // 今日圆环摘要。
    final _TimeSummary todaySummary = _buildSummary(
      repository.summarizeByCategory(todaySegments),
      categoryColors,
      colors.time,
    );
    // 本周圆环摘要。
    final _TimeSummary weekSummary = _buildSummary(
      repository.summarizeByCategory(weekSegments),
      categoryColors,
      colors.time,
    );
    // 首页按进行中优先、开始时间倒序展示的今日记录。
    final List<TimeEntryRecord> sortedTodaySegments = List<TimeEntryRecord>.of(
      todaySegments,
    )..sort(_compareHomeEntries);
    // 首页最多展示的五条今日记录。
    final List<TimeEntryRecord> visibleEntries = sortedTodaySegments
        .take(5)
        .toList(growable: false);

    return OmniPanel(
      key: const ValueKey<String>('home-time-status-card'),
      padding: const EdgeInsets.all(OmniSpacing.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _TimeStatusHeader(
            onStart: () => showStartTimeEntryDialog(context, day: now),
            onBackfill: () => showBackfillTimeEntryDialog(context, day: now),
          ),
          const SizedBox(height: OmniSpacing.md),
          if (todayRecordsAsync.isLoading || weekRecordsAsync.isLoading)
            const SizedBox(
              height: 142,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (todayRecordsAsync.hasError || weekRecordsAsync.hasError)
            SizedBox(
              height: 142,
              child: Center(
                child: Text(
                  '时间状态暂时无法读取',
                  style: TextStyle(color: colors.danger),
                ),
              ),
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: _TimeDonut(
                    label: '今日',
                    summary: todaySummary,
                    emptyColor: colors.mist,
                  ),
                ),
                const SizedBox(width: OmniSpacing.sm),
                Expanded(
                  child: _TimeDonut(
                    label: '本周',
                    summary: weekSummary,
                    emptyColor: colors.mist,
                  ),
                ),
              ],
            ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: OmniSpacing.md),
            child: Divider(color: colors.line),
          ),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '今天做了什么',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              if (sortedTodaySegments.length > 5)
                TextButton(
                  onPressed: () => context.go('/timeline'),
                  child: Text('查看全部 ${sortedTodaySegments.length} 条'),
                ),
            ],
          ),
          const SizedBox(height: OmniSpacing.xxs),
          if (todayRecordsAsync.hasError)
            Text('今日记录暂时无法读取', style: TextStyle(color: colors.danger))
          else if (visibleEntries.isEmpty)
            _TimeEmptyState(
              onCreate: () => showStartTimeEntryDialog(context, day: now),
            )
          else
            for (
              int index = 0;
              index < visibleEntries.length;
              index += 1
            ) ...<Widget>[
              if (index > 0) Divider(color: colors.line),
              _TimeEntryRow(
                key: ValueKey<String>(
                  'home-time-entry-${visibleEntries[index].id}',
                ),
                record: visibleEntries[index],
                color:
                    categoryColors[visibleEntries[index].category] ??
                    colors.time,
                onTap: () => context.go('/timeline'),
              ),
            ],
        ],
      ),
    );
  }
}

/// 时间状态卡片标题。
class _TimeStatusHeader extends StatelessWidget {
  /// 开始记录回调。
  final VoidCallback onStart;

  /// 补记时间回调。
  final VoidCallback onBackfill;

  /// 创建时间状态卡片标题。
  const _TimeStatusHeader({required this.onStart, required this.onBackfill});

  /// 构建标题、说明和原地记录入口。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: colors.time.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(OmniRadius.control),
          ),
          child: Icon(
            Icons.donut_large_rounded,
            color: colors.time,
            size: OmniSize.navigationIcon,
          ),
        ),
        const SizedBox(width: OmniSpacing.xs),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('时间状态', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 2),
              Text(
                '按已记录时间查看类别分布',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        OmniButton(
          key: const ValueKey<String>('home-time-start-button'),
          label: '开始',
          onPressed: onStart,
        ),
        const SizedBox(width: OmniSpacing.xxs),
        OmniButton(
          key: const ValueKey<String>('home-time-backfill-button'),
          label: '补记',
          variant: OmniButtonVariant.secondary,
          onPressed: onBackfill,
        ),
      ],
    );
  }
}

/// 一段周期内的分类时间摘要。
class _TimeSummary {
  /// 按分类统计的圆环分段。
  final List<_TimeSlice> slices;

  /// 已记录总分钟数。
  final int totalMinutes;

  /// 主导分类的等价文字摘要。
  final String detail;

  /// 所有分类名称与时长的等价文字明细。
  final String breakdown;

  /// 创建分类时间摘要。
  const _TimeSummary({
    required this.slices,
    required this.totalMinutes,
    required this.detail,
    required this.breakdown,
  });
}

/// 时间圆环中的单个分类分段。
class _TimeSlice {
  /// 分类名称。
  final String label;

  /// 分类分钟数。
  final int minutes;

  /// 分类颜色。
  final Color color;

  /// 创建时间分类分段。
  const _TimeSlice({
    required this.label,
    required this.minutes,
    required this.color,
  });
}

/// 单个周期时间圆环。
class _TimeDonut extends StatelessWidget {
  /// 周期名称。
  final String label;

  /// 当前周期摘要。
  final _TimeSummary summary;

  /// 空圆环颜色。
  final Color emptyColor;

  /// 创建单个周期时间圆环。
  const _TimeDonut({
    required this.label,
    required this.summary,
    required this.emptyColor,
  });

  /// 构建带中心时长和文字摘要的圆环。
  @override
  Widget build(BuildContext context) {
    // 辅助功能可读的完整摘要。
    final String semanticsLabel = summary.totalMinutes == 0
        ? '$label还没有时间记录'
        : '$label记录${_formatDuration(summary.totalMinutes)}，${summary.detail}；${summary.breakdown}';
    return Semantics(
      label: semanticsLabel,
      child: ExcludeSemantics(
        child: Column(
          children: <Widget>[
            Text(label, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: OmniSpacing.xs),
            SizedBox.square(
              dimension: 104,
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  CustomPaint(
                    size: const Size.square(104),
                    painter: _TimeDonutPainter(
                      slices: summary.slices,
                      totalMinutes: summary.totalMinutes,
                      emptyColor: emptyColor,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Text(
                      _formatDuration(summary.totalMinutes),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: OmniSpacing.xs),
            Text(
              summary.totalMinutes == 0 ? '还没有时间记录' : summary.detail,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (summary.totalMinutes > 0) ...<Widget>[
              const SizedBox(height: 2),
              Text(
                summary.breakdown,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: OmniColors.of(context).muted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 绘制按分类分段的时间圆环。
class _TimeDonutPainter extends CustomPainter {
  /// 按分类统计的圆环分段。
  final List<_TimeSlice> slices;

  /// 已记录总分钟数。
  final int totalMinutes;

  /// 空圆环颜色。
  final Color emptyColor;

  /// 创建时间圆环绘制器。
  const _TimeDonutPainter({
    required this.slices,
    required this.totalMinutes,
    required this.emptyColor,
  });

  /// 绘制空圆环或按分钟比例绘制分类圆弧。
  @override
  void paint(Canvas canvas, Size size) {
    // 圆环边界。
    final Rect bounds = Offset.zero & size;
    // 圆环绘制画笔。
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.butt;
    if (totalMinutes <= 0 || slices.isEmpty) {
      paint.color = emptyColor;
      canvas.drawArc(bounds.deflate(7), 0, math.pi * 2, false, paint);
      return;
    }
    // 当前分类圆弧的起始角度。
    double startAngle = -math.pi / 2;
    for (final _TimeSlice slice in slices) {
      // 当前分类占据的完整角度。
      final double sweep = slice.minutes / totalMinutes * math.pi * 2;
      // 分类之间使用的细小间隔角度。
      final double gap = slices.length > 1 ? math.min(0.035, sweep * 0.18) : 0;
      paint.color = slice.color;
      canvas.drawArc(
        bounds.deflate(7),
        startAngle + gap / 2,
        math.max(0, sweep - gap),
        false,
        paint,
      );
      startAngle += sweep;
    }
  }

  /// 仅在圆环数据或颜色变化时重绘。
  @override
  bool shouldRepaint(covariant _TimeDonutPainter oldDelegate) {
    return oldDelegate.slices != slices ||
        oldDelegate.totalMinutes != totalMinutes ||
        oldDelegate.emptyColor != emptyColor;
  }
}

/// 首页时间状态卡中的单条今日记录。
class _TimeEntryRow extends StatelessWidget {
  /// 当前自然日分段记录。
  final TimeEntryRecord record;

  /// 当前分类颜色。
  final Color color;

  /// 打开时间管理回调。
  final VoidCallback onTap;

  /// 创建今日时间记录行。
  const _TimeEntryRow({
    required this.record,
    required this.color,
    required this.onTap,
    super.key,
  });

  /// 构建时间段、活动名称、类别和时长。
  @override
  Widget build(BuildContext context) {
    // 当前分段持续分钟数。
    final int minutes = record.endMinute - record.startMinute;
    // 当前记录时间范围。
    final String range = record.endedAt == null
        ? '${_formatMinute(record.startMinute)}–进行中'
        : '${_formatMinute(record.startMinute)}–${_formatMinute(record.endMinute)}';
    return OmniListRow(
      onTap: onTap,
      borderRadius: BorderRadius.circular(OmniRadius.control),
      padding: const EdgeInsets.symmetric(
        horizontal: OmniSpacing.sm,
        vertical: OmniSpacing.xs,
      ),
      leading: Container(
        key: ValueKey<String>('home-time-entry-leading-${record.id}'),
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      title: Text(
        timeEntryDisplayActivity(record),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '$range · ${record.category ?? '未分类'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        _formatDuration(minutes),
        key: ValueKey<String>('home-time-entry-trailing-${record.id}'),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// 时间状态卡片的紧凑空状态。
class _TimeEmptyState extends StatelessWidget {
  /// 打开时间管理回调。
  final VoidCallback onCreate;

  /// 创建时间记录空状态。
  const _TimeEmptyState({required this.onCreate});

  /// 构建说明和开始记录入口。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Container(
      padding: const EdgeInsets.all(OmniSpacing.sm),
      decoration: BoxDecoration(
        color: colors.paperSubtle,
        borderRadius: BorderRadius.circular(OmniRadius.control),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.schedule_outlined, color: colors.muted),
          const SizedBox(width: OmniSpacing.xs),
          const Expanded(child: Text('今天还没有时间记录')),
          TextButton(onPressed: onCreate, child: const Text('开始记录')),
        ],
      ),
    );
  }
}

/// 将分类分钟数转换为圆环摘要。
_TimeSummary _buildSummary(
  Map<String, int> summary,
  Map<String, Color> categoryColors,
  Color fallbackColor,
) {
  // 按耗时降序排列的有效分类。
  final List<MapEntry<String, int>> entries =
      summary.entries
          .where((MapEntry<String, int> entry) => entry.value > 0)
          .toList()
        ..sort(
          (MapEntry<String, int> left, MapEntry<String, int> right) =>
              right.value.compareTo(left.value),
        );
  // 已记录总分钟数。
  final int totalMinutes = entries.fold<int>(
    0,
    (int total, MapEntry<String, int> entry) => total + entry.value,
  );
  // 主导分类。
  final MapEntry<String, int>? dominant = entries.isEmpty
      ? null
      : entries.first;
  // 主导分类占比。
  final int dominantPercent = dominant == null || totalMinutes == 0
      ? 0
      : (dominant.value / totalMinutes * 100).round();
  // 所有分类名称和时长组成的等价文字明细。
  final String breakdown = entries
      .map(
        (MapEntry<String, int> entry) =>
            '${entry.key} ${_formatDuration(entry.value)}',
      )
      .join(' · ');
  return _TimeSummary(
    slices: entries
        .map(
          (MapEntry<String, int> entry) => _TimeSlice(
            label: entry.key,
            minutes: entry.value,
            color: categoryColors[entry.key] ?? fallbackColor,
          ),
        )
        .toList(growable: false),
    totalMinutes: totalMinutes,
    detail: dominant == null
        ? '还没有时间记录'
        : '主要用于${dominant.key} $dominantPercent%',
    breakdown: breakdown,
  );
}

/// 比较首页今日时间记录顺序，进行中优先，其余按开始时间倒序。
int _compareHomeEntries(TimeEntryRecord left, TimeEntryRecord right) {
  // 左侧记录是否仍在进行。
  final bool leftOngoing = left.endedAt == null;
  // 右侧记录是否仍在进行。
  final bool rightOngoing = right.endedAt == null;
  if (leftOngoing != rightOngoing) {
    return leftOngoing ? -1 : 1;
  }
  return right.startedAt.compareTo(left.startedAt);
}

/// 格式化自然日内分钟数。
String _formatMinute(int minute) {
  // 规范化到当天范围的分钟数。
  final int normalized = minute.clamp(0, 1440);
  if (normalized == 1440) {
    return '24:00';
  }
  // 当前分钟对应的时刻。
  final DateTime time = DateTime(2000, 1, 1).add(Duration(minutes: normalized));
  return DateFormat('HH:mm').format(time);
}

/// 格式化紧凑时长。
String _formatDuration(int minutes) {
  if (minutes <= 0) {
    return '0分钟';
  }
  // 完整小时数。
  final int hours = minutes ~/ 60;
  // 不足一小时的分钟数。
  final int remainingMinutes = minutes % 60;
  if (hours == 0) {
    return '$remainingMinutes分钟';
  }
  if (remainingMinutes == 0) {
    return '$hours小时';
  }
  return '$hours小时$remainingMinutes分';
}
