import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
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
class HomeTimeStatusCard extends ConsumerStatefulWidget {
  /// 当前时间。
  final DateTime now;

  /// 创建首页时间状态卡片。
  const HomeTimeStatusCard({required this.now, super.key});

  /// 创建仅用于当前卡片的类别筛选状态。
  @override
  ConsumerState<HomeTimeStatusCard> createState() => _HomeTimeStatusCardState();
}

/// 管理双圆环共用的类别可见性，不修改记录或持久化偏好。
class _HomeTimeStatusCardState extends ConsumerState<HomeTimeStatusCard> {
  /// 用户暂时隐藏的类别；未出现过的新类别默认显示。
  final Set<String> _hiddenCategories = <String>{};

  /// 单列与移动端没有网格滚动作用域时使用的记录滚动控制器。
  final ScrollController _entriesController = ScrollController();

  /// 释放卡片自有的滚动控制器。
  @override
  void dispose() {
    _entriesController.dispose();
    super.dispose();
  }

  /// 切换类别在两个圆环中的可见性。
  void _toggleCategory(String category) {
    setState(() {
      if (!_hiddenCategories.remove(category)) {
        _hiddenCategories.add(category);
      }
    });
  }

  /// 构建双圆环和今天的时间记录清单。
  @override
  Widget build(BuildContext context) {
    // 当前业务时刻。
    final DateTime now = widget.now;
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前是否使用由悬浮拆分按钮提供新增入口的 Android 紧凑布局。
    final bool androidCompact =
        Theme.of(context).platform == TargetPlatform.android &&
        OmniBreakpoint.isCompact(MediaQuery.sizeOf(context).width);
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
    // 两个圆环实际分类的并集，直接复用分段颜色并按名称去重。
    final Map<String, _TimeSlice> legendSlices = <String, _TimeSlice>{
      for (final _TimeSlice slice in <_TimeSlice>[
        ...todaySummary.slices,
        ...weekSummary.slices,
      ])
        slice.label: slice,
    };
    // 首页按进行中优先、开始时间倒序展示的今日记录。
    final List<TimeEntryRecord> sortedTodaySegments = List<TimeEntryRecord>.of(
      todaySegments,
    )..sort(_compareHomeEntries);
    // 优先复用桌面网格为当前卡片提供的滚动控制器。
    final ScrollController? gridController = OmniPanelScrollScope.maybeOf(
      context,
    )?.controller;

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: gridController == null
            ? math.max(420, MediaQuery.sizeOf(context).height - 160)
            : double.infinity,
      ),
      child: OmniPanelScrollScope(
        controller: gridController ?? _entriesController,
        child: OmniPanel(
          key: const ValueKey<String>('home-time-status-card'),
          padding: const EdgeInsets.fromLTRB(
            OmniSpacing.md,
            0,
            OmniSpacing.md,
            OmniSpacing.md,
          ),
          header: Padding(
            key: const ValueKey<String>('home-time-header'),
            padding: const EdgeInsets.fromLTRB(
              OmniSpacing.md,
              OmniSpacing.md,
              OmniSpacing.md,
              OmniSpacing.xs,
            ),
            child: _TimeStatusHeader(
              onStart: () => showStartTimeEntryDialog(context, day: now),
              onBackfill: () => showBackfillTimeEntryDialog(context, day: now),
              showActions: !androidCompact,
            ),
          ),
          child: Column(
            key: const ValueKey<String>('home-time-content'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const SizedBox(height: OmniSpacing.xs),
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
              else ...<Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: _TimeDonut(
                        label: '今日',
                        summary: _visibleSummary(
                          todaySummary,
                          _hiddenCategories,
                        ),
                        filtered: _hiddenCategories.isNotEmpty,
                        emptyColor: colors.mist,
                      ),
                    ),
                    const SizedBox(width: OmniSpacing.sm),
                    Expanded(
                      child: _TimeDonut(
                        label: '本周',
                        summary: _visibleSummary(
                          weekSummary,
                          _hiddenCategories,
                        ),
                        filtered: _hiddenCategories.isNotEmpty,
                        emptyColor: colors.mist,
                      ),
                    ),
                  ],
                ),
                if (legendSlices.isNotEmpty) ...<Widget>[
                  const SizedBox(height: OmniSpacing.md),
                  _TimeCategoryLegend(
                    slices: legendSlices.values.toList(),
                    hiddenCategories: _hiddenCategories,
                    onToggle: _toggleCategory,
                  ),
                ],
              ],
              Padding(
                padding: const EdgeInsets.symmetric(vertical: OmniSpacing.md),
                child: Divider(color: colors.line),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '今天做了什么',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              const SizedBox(height: OmniSpacing.xxs),
              if (todayRecordsAsync.hasError)
                Text('今日记录暂时无法读取', style: TextStyle(color: colors.danger))
              else if (sortedTodaySegments.isEmpty)
                _TimeEmptyState(
                  onCreate: androidCompact
                      ? null
                      : () => showStartTimeEntryDialog(context, day: now),
                )
              else
                for (
                  int index = 0;
                  index < sortedTodaySegments.length;
                  index += 1
                ) ...<Widget>[
                  if (index > 0) Divider(color: colors.line),
                  _TimeEntryRow(
                    key: ValueKey<String>(
                      'home-time-entry-${sortedTodaySegments[index].id}',
                    ),
                    record: sortedTodaySegments[index],
                    color:
                        categoryColors[sortedTodaySegments[index].category] ??
                        colors.time,
                    onTap: () => context.go('/timeline'),
                  ),
                ],
            ],
          ),
        ),
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

  /// 是否在卡片标题中显示时间操作。
  final bool showActions;

  /// 创建时间状态卡片标题。
  const _TimeStatusHeader({
    required this.onStart,
    required this.onBackfill,
    required this.showActions,
  });

  /// 构建标题和原地记录入口。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
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
          child: Text('时间状态', style: Theme.of(context).textTheme.titleMedium),
        ),
        if (showActions) ...<Widget>[
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
class _TimeDonut extends StatefulWidget {
  /// 当前是否应用了类别筛选。
  final bool filtered;

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
    required this.filtered,
  });

  /// 为每个周期维护独立的环节选中状态。
  @override
  State<_TimeDonut> createState() => _TimeDonutState();
}

/// 管理圆环悬停与触摸选择，不影响共用图例筛选。
class _TimeDonutState extends State<_TimeDonut> {
  /// 当前突出显示的类别名称，空值时显示总时长。
  String? _activeCategory;

  /// 更新选择，仅在命中类别变化时刷新界面。
  void _selectCategory(String? category) {
    // 退出动画尚在绘制的隐藏类别不能被再次选中。
    final String? visibleCategory =
        widget.summary.slices.any(
          (_TimeSlice slice) => slice.label == category && slice.minutes > 0,
        )
        ? category
        : null;
    if (_activeCategory == visibleCategory) return;
    setState(() => _activeCategory = visibleCategory);
  }

  /// 类别被隐藏或记录移除时清除过期选择。
  @override
  void didUpdateWidget(covariant _TimeDonut oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.summary.slices.any(
      (_TimeSlice slice) => slice.label == _activeCategory && slice.minutes > 0,
    )) {
      _activeCategory = null;
    }
  }

  /// 构建带中心时长和完整辅助功能摘要的圆环。
  @override
  Widget build(BuildContext context) {
    // 当前周期名称。
    final String label = widget.label;
    // 当前可见类别摘要。
    final _TimeSummary summary = widget.summary;
    // 当前选中类别的真实时长与颜色。
    final _TimeSlice? activeSlice = summary.slices
        .where(
          (_TimeSlice slice) =>
              slice.label == _activeCategory && slice.minutes > 0,
        )
        .firstOrNull;
    // 中心显示选中类别时长，未选中时显示当前总时长。
    final int minutes = activeSlice?.minutes ?? summary.totalMinutes;
    // 辅助功能可读的完整摘要。
    final String semanticsLabel = summary.totalMinutes == 0
        ? widget.filtered
              ? '$label所选类别暂无时间记录'
              : '$label还没有时间记录'
        : '$label记录${_formatDuration(summary.totalMinutes)}，${summary.detail}；${summary.breakdown}';
    // 保留零角度类别的位置，隐藏与恢复都沿原扇区边界过渡。
    final _TimeDonutFrame frame = _TimeDonutFrame.fromSummary(summary);
    return Semantics(
      label: activeSlice == null
          ? semanticsLabel
          : '$semanticsLabel；当前类别${activeSlice.label} ${_formatDuration(minutes)}',
      child: ExcludeSemantics(
        child: Column(
          children: <Widget>[
            Text(label, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: OmniSpacing.xs),
            SizedBox.square(
              dimension: 104,
              child: TweenAnimationBuilder<_TimeDonutFrame>(
                tween: _TimeDonutTween(begin: frame, end: frame),
                duration: OmniMotion.duration(
                  context,
                  const Duration(milliseconds: 400),
                ),
                curve: OmniMotion.standardCurve,
                builder:
                    (
                      BuildContext context,
                      _TimeDonutFrame value,
                      Widget? child,
                    ) {
                      // 交互与绘制共用当前动画帧，避免命中尚未移动到位的扇区。
                      final _TimeDonutPainter painter = _TimeDonutPainter(
                        frame: value,
                        emptyColor: widget.emptyColor,
                        activeCategory: activeSlice?.label,
                      );
                      return MouseRegion(
                        onHover: (event) => _selectCategory(
                          painter.categoryAt(
                            event.localPosition,
                            const Size.square(104),
                          ),
                        ),
                        onExit: (_) => _selectCategory(null),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapUp: (details) {
                            // 点击已选中环节或圆环空白区域时恢复总时长。
                            final String? category = painter.categoryAt(
                              details.localPosition,
                              const Size.square(104),
                            );
                            _selectCategory(
                              category == _activeCategory ? null : category,
                            );
                          },
                          child: Stack(
                            alignment: Alignment.center,
                            children: <Widget>[
                              CustomPaint(
                                key: ValueKey<String>('home-time-donut-$label'),
                                size: const Size.square(104),
                                painter: painter,
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    Text(
                                      '${minutes ~/ 60}h${minutes % 60}m',
                                      key: ValueKey<String>(
                                        'home-time-donut-duration-$label',
                                      ),
                                      textAlign: TextAlign.center,
                                      maxLines: 2,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleSmall
                                          ?.copyWith(
                                            fontFeatures: const <FontFeature>[
                                              FontFeature.tabularFigures(),
                                            ],
                                          ),
                                    ),
                                    if (activeSlice != null)
                                      Text(
                                        activeSlice.label,
                                        textAlign: TextAlign.center,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelSmall
                                            ?.copyWith(
                                              color: activeSlice.color,
                                            ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 今日与本周圆环共用的类别颜色图例。
class _TimeCategoryLegend extends StatelessWidget {
  /// 已按类别名称去重的圆环分段。
  final List<_TimeSlice> slices;

  /// 当前隐藏的类别，仍保留图例入口以便恢复。
  final Set<String> hiddenCategories;

  /// 点击或键盘激活类别时的回调。
  final ValueChanged<String> onToggle;

  /// 创建共用图例。
  const _TimeCategoryLegend({
    required this.slices,
    required this.hiddenCategories,
    required this.onToggle,
  });

  /// 构建可自动换行的小圆角色块与真实类别名称。
  @override
  Widget build(BuildContext context) {
    return Wrap(
      key: const ValueKey<String>('home-time-category-legend'),
      alignment: WrapAlignment.center,
      spacing: OmniSpacing.xxs,
      runSpacing: 0,
      children: <Widget>[
        for (final _TimeSlice slice in slices)
          Semantics(
            key: ValueKey<String>('home-time-legend-item-${slice.label}'),
            button: true,
            selected: !hiddenCategories.contains(slice.label),
            child: InkWell(
              onTap: () => onToggle(slice.label),
              borderRadius: BorderRadius.circular(OmniRadius.control),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: OmniSize.control),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: OmniSpacing.xs,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Container(
                        key: ValueKey<String>(
                          'home-time-legend-color-${slice.label}',
                        ),
                        width: 24,
                        height: 10,
                        decoration: BoxDecoration(
                          color: hiddenCategories.contains(slice.label)
                              ? OmniColors.of(context).line
                              : slice.color,
                          borderRadius: BorderRadius.circular(OmniRadius.tiny),
                        ),
                      ),
                      const SizedBox(width: OmniSpacing.xs),
                      Flexible(
                        child: Text(
                          slice.label,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: hiddenCategories.contains(slice.label)
                                    ? OmniColors.of(context).muted
                                    : OmniColors.of(context).ink,
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 用稳定类别标识描述圆环当前的角度与颜色。
class _TimeArc {
  /// 对应的时间类别。
  final String label;

  /// 当前类别颜色。
  final Color color;

  /// 当前圆弧起始角度。
  final double start;

  /// 当前圆弧覆盖角度，隐藏类别为零。
  final double sweep;

  /// 创建圆弧几何数据。
  const _TimeArc(this.label, this.color, this.start, this.sweep);

  /// 按几何值比较，避免无关刷新重新触发动画。
  @override
  bool operator ==(Object other) =>
      other is _TimeArc &&
      other.label == label &&
      other.color == color &&
      other.start == start &&
      other.sweep == sweep;

  /// 与值比较保持一致的哈希。
  @override
  int get hashCode => Object.hash(label, color, start, sweep);
}

/// 圆环的一帧几何数据。
class _TimeDonutFrame {
  /// 含零角度类别的稳定圆弧顺序。
  final List<_TimeArc> arcs;

  /// 创建一帧圆环数据。
  const _TimeDonutFrame(this.arcs);

  /// 将分类分钟比例转换为目标角度。
  factory _TimeDonutFrame.fromSummary(_TimeSummary summary) {
    // 从圆环顶部开始累积类别角度。
    double start = -math.pi / 2;
    // 所有类别的目标圆弧。
    final List<_TimeArc> arcs = <_TimeArc>[];
    for (final _TimeSlice slice in summary.slices) {
      // 隐藏类别保留原位置，但角度归零。
      final double sweep = summary.totalMinutes == 0
          ? 0
          : slice.minutes / summary.totalMinutes * math.pi * 2;
      arcs.add(_TimeArc(slice.label, slice.color, start, sweep));
      start += sweep;
    }
    return _TimeDonutFrame(arcs);
  }

  /// 相同摘要不应重新启动过渡。
  @override
  bool operator ==(Object other) =>
      other is _TimeDonutFrame && listEquals(other.arcs, arcs);

  /// 与帧值比较保持一致的哈希。
  @override
  int get hashCode => Object.hashAll(arcs);
}

/// 以类别名称配对角度，连续点击时从当前呈现帧接续动画。
class _TimeDonutTween extends Tween<_TimeDonutFrame> {
  /// 创建由 Flutter 管理当前帧的圆环过渡。
  _TimeDonutTween({
    required _TimeDonutFrame begin,
    required _TimeDonutFrame end,
  }) : super(begin: begin, end: end);

  /// 插值圆弧边界，同时处理记录刷新带来的类别增删。
  @override
  _TimeDonutFrame lerp(double t) {
    // 起始帧按类别建立索引。
    final Map<String, _TimeArc> previous = {
      for (final _TimeArc arc in begin!.arcs) arc.label: arc,
    };
    // 目标帧按类别建立索引。
    final Map<String, _TimeArc> target = {
      for (final _TimeArc arc in end!.arcs) arc.label: arc,
    };
    // 已删除类别在退出完成前仍参与过渡。
    final Set<String> labels = {...target.keys, ...previous.keys};
    return _TimeDonutFrame([
      for (final String label in labels)
        _TimeArc(
          label,
          Color.lerp(previous[label]?.color, target[label]?.color, t)!,
          lerpDouble(
            previous[label]?.start ?? target[label]!.start,
            target[label]?.start ?? previous[label]!.start,
            t,
          )!,
          lerpDouble(
            previous[label]?.sweep ?? 0,
            target[label]?.sweep ?? 0,
            t,
          )!,
        ),
    ]);
  }
}

/// 绘制按分类分段的时间圆环。
class _TimeDonutPainter extends CustomPainter {
  /// 动画当前帧的圆弧几何数据。
  final _TimeDonutFrame frame;

  /// 空圆环颜色。
  final Color emptyColor;

  /// 当前需要突出显示的类别。
  final String? activeCategory;

  /// 创建时间圆环绘制器。
  const _TimeDonutPainter({
    required this.frame,
    required this.emptyColor,
    this.activeCategory,
  });

  /// 计算与绘制一致的类别间隔，单一类别时保留完整圆环。
  double _gap(_TimeArc arc) =>
      math.min(0.035, arc.sweep * 0.18) *
      ((math.pi * 2 - arc.sweep) / 0.035).clamp(0, 1);

  /// 按实际圆弧范围命中类别，排除中心、外侧和分段间隙。
  String? categoryAt(Offset position, Size size) {
    // 鼠标或触点相对圆心的位置。
    final Offset offset = position - size.center(Offset.zero);
    // 与绘制边界一致的圆弧中心线半径。
    final double radius = size.shortestSide / 2 - 7;
    for (final _TimeArc arc in frame.arcs) {
      // 高亮描边加粗后的实际半宽。
      final double halfWidth = arc.label == activeCategory ? 7 : 5;
      if ((offset.distance - radius).abs() > halfWidth) continue;
      // 相对当前分段起点的顺时针角度。
      final double angle = (offset.direction - arc.start) % (math.pi * 2);
      // 保留分类之间的可见间隙作为非命中区域。
      final double gap = _gap(arc);
      if (arc.sweep > 0 && angle >= gap / 2 && angle < arc.sweep - gap / 2) {
        return arc.label;
      }
    }
    return null;
  }

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
    // 全部类别隐藏时逐渐露出空圆环，恢复时沿原方向展开。
    final double coverage =
        (frame.arcs.fold<double>(
                  0,
                  (double total, _TimeArc arc) => total + arc.sweep,
                ) /
                (math.pi * 2))
            .clamp(0, 1);
    if (coverage < 1) {
      paint.color = emptyColor.withValues(alpha: emptyColor.a * (1 - coverage));
      canvas.drawArc(bounds.deflate(7), 0, math.pi * 2, false, paint);
    }
    for (final _TimeArc arc in frame.arcs) {
      // 分类之间使用的细小间隔角度。
      final double gap = _gap(arc);
      paint
        ..strokeWidth = arc.label == activeCategory ? 14 : 10
        ..color = activeCategory == null || arc.label == activeCategory
            ? arc.color
            : arc.color.withValues(alpha: arc.color.a * 0.35);
      canvas.drawArc(
        bounds.deflate(7),
        arc.start + gap / 2,
        math.max(0, arc.sweep - gap),
        false,
        paint,
      );
    }
  }

  /// 仅在圆环数据或颜色变化时重绘。
  @override
  bool shouldRepaint(covariant _TimeDonutPainter oldDelegate) {
    return oldDelegate.frame != frame ||
        oldDelegate.emptyColor != emptyColor ||
        oldDelegate.activeCategory != activeCategory;
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
  final VoidCallback? onCreate;

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
          if (onCreate != null)
            TextButton(onPressed: onCreate, child: const Text('开始记录')),
        ],
      ),
    );
  }
}

/// 从原始摘要排除隐藏类别，重新计算总时长、占比及读屏摘要。
_TimeSummary _visibleSummary(
  _TimeSummary summary,
  Set<String> hiddenCategories,
) {
  // 可见类别仍按实际时长生成文字和读屏摘要。
  final _TimeSummary visible = _buildSummary(
    <String, int>{
      for (final _TimeSlice slice in summary.slices)
        if (!hiddenCategories.contains(slice.label)) slice.label: slice.minutes,
    },
    <String, Color>{
      for (final _TimeSlice slice in summary.slices) slice.label: slice.color,
    },
    Colors.transparent,
  );
  return _TimeSummary(
    slices: [
      for (final _TimeSlice slice in summary.slices)
        _TimeSlice(
          label: slice.label,
          minutes: hiddenCategories.contains(slice.label) ? 0 : slice.minutes,
          color: slice.color,
        ),
    ],
    totalMinutes: visible.totalMinutes,
    detail: visible.detail,
    breakdown: visible.breakdown,
  );
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
