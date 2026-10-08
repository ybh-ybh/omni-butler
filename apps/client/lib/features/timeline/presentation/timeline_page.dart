import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/features/timeline/data/time_entry_repository.dart';
import 'package:omni_butler/features/timeline/presentation/time_entry_time_picker.dart';
import 'package:omni_butler/features/timeline/presentation/timeline_review.dart';
import 'package:omni_butler/shared/taxonomy/taxonomy_manager_dialog.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 在当前页面打开轻量开始记录弹窗。
Future<void> showStartTimeEntryDialog(
  BuildContext context, {
  required DateTime day,
}) async {
  if (Theme.of(context).platform == TargetPlatform.android) {
    await showOmniExpandableBottomSheet<void>(
      context: context,
      builder: (BuildContext context) => _AbsoluteTimeEntryDialog(
        mode: _TimeEntryEditorMode.startOnly,
        day: DateUtils.dateOnly(day),
      ),
    );
    return;
  }
  await showOmniDialog<void>(
    context: context,
    builder: (BuildContext context) => _AbsoluteTimeEntryDialog(
      mode: _TimeEntryEditorMode.startOnly,
      day: DateUtils.dateOnly(day),
    ),
  );
}

/// 在当前页面打开完整时间补记弹窗。
Future<void> showBackfillTimeEntryDialog(
  BuildContext context, {
  required DateTime day,
}) async {
  // 安卓补记覆盖根导航，安全区由全屏内容统一处理。
  final bool fullscreen = Theme.of(context).platform == TargetPlatform.android;
  await showOmniDialog<void>(
    context: context,
    useSafeArea: !fullscreen,
    fullscreenDialog: fullscreen,
    barrierDismissible: !fullscreen,
    builder: (BuildContext context) => _AbsoluteTimeEntryDialog(
      mode: _TimeEntryEditorMode.completed,
      day: DateUtils.dateOnly(day),
    ),
  );
}

/// 在当前页面打开进行中记录的结束弹窗。
Future<void> showFinishTimeEntryDialog(
  BuildContext context, {
  required TimeEntryRecord record,
}) async {
  await showOmniDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext context) => _AbsoluteTimeEntryDialog(
      mode: _TimeEntryEditorMode.finish,
      day: DateUtils.dateOnly(record.startedAt),
      record: record,
    ),
  );
}

/// 24 小时时间记录页面。
class TimelinePage extends ConsumerStatefulWidget {
  /// 创建时间记录页面。
  const TimelinePage({super.key});

  /// 创建页面状态。
  @override
  ConsumerState<TimelinePage> createState() => _TimelinePageState();
}

/// 24 小时时间记录页面状态。
class _TimelinePageState extends ConsumerState<TimelinePage> {
  /// Android 悬浮操作组的实际布局高度。
  double _mobileActionHeight = OmniSize.touch;

  /// 当前查看日期。
  late DateTime _selectedDay;

  /// 当前页面工作模式。
  TimelineViewMode _viewMode = TimelineViewMode.review;

  /// 当前统计周期。
  TimelineStatsPeriod _statsPeriod = TimelineStatsPeriod.week;

  /// 初始化稳定且可测试的当前日期。
  @override
  void initState() {
    super.initState();
    _selectedDay = DateUtils.dateOnly(ref.read(nowProvider));
  }

  /// 切换到相邻日期或统计周期。
  void _moveSelection(int direction) {
    // 当前模式对应的日期位移。
    final DateTime nextDay = switch ((_viewMode, _statsPeriod)) {
      (TimelineViewMode.details, _) ||
      (
        TimelineViewMode.review,
        TimelineStatsPeriod.day,
      ) => _selectedDay.add(Duration(days: direction)),
      (TimelineViewMode.review, TimelineStatsPeriod.week) => _selectedDay.add(
        Duration(days: 7 * direction),
      ),
      (TimelineViewMode.review, TimelineStatsPeriod.month) => DateTime(
        _selectedDay.year,
        _selectedDay.month + direction,
        1,
      ),
    };
    setState(() => _selectedDay = DateUtils.dateOnly(nextDay));
  }

  /// 打开时间记录编辑器。
  Future<void> _openEditor({
    TimeEntryRecord? record,
    DateTime? day,
    int? initialStartMinute,
  }) async {
    // 编辑器实际使用的自然日。
    final DateTime editorDay = DateUtils.dateOnly(
      record?.startedAt ?? day ?? _selectedDay,
    );
    // 时间页菜单及空白时间轴补记也使用相同的安卓全屏路由。
    final bool fullscreen =
        record == null && Theme.of(context).platform == TargetPlatform.android;
    await showOmniDialog<void>(
      context: context,
      useSafeArea: !fullscreen,
      fullscreenDialog: fullscreen,
      barrierDismissible: !fullscreen,
      builder: (BuildContext context) => _AbsoluteTimeEntryDialog(
        mode: record?.endedAt == null && record != null
            ? _TimeEntryEditorMode.ongoing
            : _TimeEntryEditorMode.completed,
        day: editorDay,
        record: record,
        initialStartMinute: initialStartMinute,
      ),
    );
  }

  /// 打开轻量开始记录弹窗。
  Future<void> _openStartEditor() async {
    await showStartTimeEntryDialog(context, day: ref.read(nowProvider));
  }

  /// 打开进行中记录的结束弹窗。
  Future<void> _openFinishEditor(TimeEntryRecord record) async {
    await showFinishTimeEntryDialog(context, record: record);
  }

  /// 打开时间分类管理器。
  Future<void> _openTimelineCategories() async {
    await TaxonomyManagerDialog.show(
      context,
      module: TaxonomyModule.timeline,
      kind: TaxonomyKind.category,
    );
  }

  /// 打开指定日期的记录明细。
  void _openDayDetails(DateTime day) {
    setState(() {
      _selectedDay = DateUtils.dateOnly(day);
      _viewMode = TimelineViewMode.details;
    });
  }

  /// 删除时间记录。
  Future<void> _delete(TimeEntryRecord record) async {
    await ref.read(timeEntryRepositoryProvider).delete(record.id);
    ref.invalidate(recycleBinItemsProvider);
    if (!mounted) {
      return;
    }
    showOmniMessage(
      context,
      message: '“${timeEntryDisplayActivity(record)}”已移入回收站',
      tone: OmniMessageTone.success,
    );
  }

  /// 构建时间记录页面。
  @override
  Widget build(BuildContext context) {
    // 当日记录流。
    final AsyncValue<List<TimeEntryRecord>> dayEntries = ref.watch(
      timeEntriesForDayProvider(_selectedDay),
    );
    // 当前统计范围。
    final (DateTime, DateTime) statsRange = _rangeFor(
      _selectedDay,
      _statsPeriod,
    );
    // 上一统计范围。
    final (DateTime, DateTime) previousStatsRange = _previousRangeFor(
      statsRange,
      _statsPeriod,
    );
    // 当前统计范围内记录。
    final AsyncValue<List<TimeEntryRecord>> statsEntries = ref.watch(
      timeEntriesForRangeProvider(statsRange),
    );
    // 上一统计范围内记录。
    final AsyncValue<List<TimeEntryRecord>> previousStatsEntries = ref.watch(
      timeEntriesForRangeProvider(previousStatsRange),
    );
    // 当前全部进行中记录。
    final List<TimeEntryRecord> ongoingEntries =
        ref.watch(ongoingTimeEntriesProvider).asData?.value ??
        const <TimeEntryRecord>[];
    // 当前时刻用于进行中记录的临时统计终点。
    final DateTime now = ref.watch(nowProvider);
    // 当前是否为紧凑布局。
    final bool compact = OmniBreakpoint.isCompact(
      MediaQuery.sizeOf(context).width,
    );
    // 当前是否使用 Android 紧凑时间页布局。
    final bool androidCompact =
        compact && Theme.of(context).platform == TargetPlatform.android;
    // 为悬浮操作组保留完整高度、底部间距及安全区。
    final double mobileActionClearance =
        _mobileActionHeight +
        OmniSpacing.md +
        OmniSpacing.xs +
        MediaQuery.paddingOf(context).bottom;
    // 按导航、时间范围和内容组织的时间页主体。
    final Widget pageContent = Padding(
      padding: compact
          ? EdgeInsets.fromLTRB(
              OmniSpacing.xs,
              OmniSpacing.xs,
              OmniSpacing.xs,
              androidCompact ? 0 : OmniSpacing.md,
            )
          : const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: OmniSpacing.sm,
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _buildToolbar(
            context,
            androidCompact: androidCompact,
            ongoingEntries: ongoingEntries,
          ),
          if (ongoingEntries.isNotEmpty) ...<Widget>[
            const SizedBox(height: OmniSpacing.xs),
            _OngoingTimeEntryBanner(
              records: ongoingEntries,
              onFinish: _openFinishEditor,
              onEdit: (TimeEntryRecord record) => _openEditor(record: record),
            ),
          ],
          const SizedBox(height: OmniSpacing.xs),
          Expanded(
            child: _viewMode == TimelineViewMode.review
                ? statsEntries.when(
                    data: (List<TimeEntryRecord> records) =>
                        TimelineReviewContent(
                          records: splitTimeEntriesForRange(
                            records: records,
                            rangeStart: statsRange.$1,
                            rangeEnd: statsRange.$2,
                            now: now,
                          ),
                          previousRecords: splitTimeEntriesForRange(
                            records:
                                previousStatsEntries.asData?.value ??
                                const <TimeEntryRecord>[],
                            rangeStart: previousStatsRange.$1,
                            rangeEnd: previousStatsRange.$2,
                            now: now,
                          ),
                          rangeStart: statsRange.$1,
                          rangeEnd: statsRange.$2,
                          period: _statsPeriod,
                          safeBottomPadding: androidCompact
                              ? mobileActionClearance
                              : 0,
                          onOpenDay: _openDayDetails,
                          onEdit: (TimeEntryRecord record) =>
                              _openEditor(record: record),
                        ),
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (Object error, StackTrace stackTrace) =>
                        Center(child: Text('时间复盘读取失败：$error')),
                  )
                : dayEntries.when(
                    data: (List<TimeEntryRecord> records) =>
                        TimelineDetailsContent(
                          day: _selectedDay,
                          safeBottomPadding: androidCompact
                              ? mobileActionClearance
                              : 0,
                          records: splitTimeEntriesForRange(
                            records: records,
                            rangeStart: _selectedDay,
                            rangeEnd: _selectedDay.add(const Duration(days: 1)),
                            now: now,
                          ),
                          onAddAtMinute: (int minute) => _openEditor(
                            day: _selectedDay,
                            initialStartMinute: minute,
                          ),
                          onEdit: (TimeEntryRecord record) =>
                              _openEditor(record: record),
                          onDelete: _delete,
                        ),
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (Object error, StackTrace stackTrace) =>
                        Center(child: Text('时间明细读取失败：$error')),
                  ),
          ),
        ],
      ),
    );
    if (!androidCompact) {
      return pageContent;
    }
    return Scaffold(
      floatingActionButton: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: math.max(
            0,
            MediaQuery.sizeOf(context).width - OmniSpacing.md * 2,
          ),
        ),
        child: _TimelineActionMeasure(
          onSize: (Size size) {
            if (mounted && (_mobileActionHeight - size.height).abs() > 0.5) {
              setState(() => _mobileActionHeight = size.height);
            }
          },
          child: _buildRecordActions(context, ongoingEntries, mobile: true),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      body: pageContent,
    );
  }

  /// 测量当前字号下的控件文字宽度，避免窄屏仅依赖固定断点。
  double _textWidth(BuildContext context, String text, TextStyle? style) {
    // 采用真实字体和系统缩放的文字测量器。
    final TextPainter painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    // 释放测量器之前保存排版宽度。
    final double width = painter.width;
    painter.dispose();
    return width;
  }

  /// 构建开始／结束、补记及分类菜单组成的直接操作组。
  Widget _buildRecordActions(
    BuildContext context,
    List<TimeEntryRecord> ongoingEntries, {
    required bool mobile,
  }) {
    // 保留移动端已有主操作标识，方便焦点和交互回归。
    final String prefix = mobile ? 'timeline-mobile' : 'timeline-desktop';
    // 手机操作组使用统一实底承托，避免更多入口混入滚动内容。
    final Widget actions = Wrap(
      key: ValueKey<String>('$prefix-actions'),
      spacing: OmniSpacing.xs,
      runSpacing: OmniSpacing.xxs,
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        OmniButton(
          key: ValueKey<String>('$prefix-backfill'),
          label: '补记时间',
          icon: Icons.edit_calendar_outlined,
          variant: OmniButtonVariant.secondary,
          visualHeight: mobile ? OmniSize.control : null,
          onPressed: () => _openEditor(),
        ),
        OmniButton(
          key: ValueKey<String>('$prefix-create'),
          label: ongoingEntries.isEmpty ? '开始记录' : '结束记录',
          icon: ongoingEntries.isEmpty
              ? Icons.play_arrow_rounded
              : Icons.stop_rounded,
          variant: OmniButtonVariant.pagePrimary,
          visualHeight: mobile ? OmniSize.control : null,
          onPressed: ongoingEntries.isEmpty
              ? _openStartEditor
              : () => _openFinishEditor(ongoingEntries.first),
        ),
        OmniPopupMenuButton<String>(
          key: ValueKey<String>('$prefix-more-actions'),
          tooltip: '更多时间操作',
          onSelected: (String _) => _openTimelineCategories(),
          itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
            OmniPopupMenuItem<String>(
              key: ValueKey<String>('$prefix-categories'),
              value: 'categories',
              label: '分类',
              icon: Icons.category_outlined,
            ),
          ],
        ),
      ],
    );
    return mobile
        ? OmniPanel(
            padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.xxs),
            child: actions,
          )
        : actions;
  }

  /// 构建独立的页面模式导航，并按文字大小提高高度。
  Widget _buildViewControl(BuildContext context, double width) {
    // 模式控件的文字样式。
    final TextStyle? style = Theme.of(context).textTheme.labelMedium;
    // 系统文字缩放后的单行高度。
    final double textHeight =
        MediaQuery.textScalerOf(context).scale(style?.fontSize ?? 12) *
        (style?.height ?? 1.3);
    return OmniSlidingSegmentedControl<TimelineViewMode>(
      key: const ValueKey<String>('timeline-view-mode'),
      options: TimelineViewMode.values,
      selected: _viewMode,
      width: width,
      height: math.max(
        OmniDensity.controlHeight(context, large: true),
        textHeight + OmniSpacing.md,
      ),
      embedded: true,
      labelBuilder: (TimelineViewMode mode) =>
          mode == TimelineViewMode.review ? '时间复盘' : '记录明细',
      itemKeyBuilder: (TimelineViewMode mode) =>
          ValueKey<String>('timeline-view-mode-${mode.name}'),
      itemBuilder:
          (BuildContext context, TimelineViewMode mode, bool selected) {
            // 当前选项图文采用共享主题语义色。
            final ColorScheme scheme = Theme.of(context).colorScheme;
            // 当前选项的前景色。
            final Color foreground = selected
                ? scheme.onPrimaryContainer
                : scheme.onSurfaceVariant;
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  mode == TimelineViewMode.review
                      ? Icons.insights_outlined
                      : Icons.view_timeline_outlined,
                  size: OmniSize.icon,
                  color: foreground,
                ),
                const SizedBox(width: OmniSpacing.xxs),
                Flexible(
                  child: Text(
                    mode == TimelineViewMode.review ? '时间复盘' : '记录明细',
                    style: style?.copyWith(
                      color: foreground,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ],
            );
          },
      onChanged: (TimelineViewMode mode) => setState(() => _viewMode = mode),
    );
  }

  /// 按平台组织导航和记录操作，不因窄窗口隐藏入口。
  Widget _buildToolbar(
    BuildContext context, {
    required bool androidCompact,
    required List<TimeEntryRecord> ongoingEntries,
  }) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 当前可供工具栏使用的真实宽度。
        final double width = constraints.maxWidth;
        // 模式图标、文字及内部留白共同需要的宽度。
        final double modeWidth = math.min(
          width,
          math.max(
            248,
            (_textWidth(
                      context,
                      '时间复盘',
                      Theme.of(context).textTheme.labelMedium,
                    ) +
                    50) *
                2,
          ),
        );
        // 记录操作组的保守自然宽度，空间不足时让整个组换行。
        final double actionWidth =
            (_textWidth(
                      context,
                      '开始记录',
                      Theme.of(context).textTheme.labelLarge
                          ?.copyWith(fontSize: 14),
                    ) +
                    58) *
                2 +
            OmniDensity.controlHeight(context) +
            OmniSpacing.xs * 2;
        // Android 紧凑页将操作放在底部，其余平台与模式分列。
        final Widget header = androidCompact
            ? _buildViewControl(context, width)
            : width >= modeWidth + actionWidth + OmniSpacing.md
            ? Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  _buildViewControl(context, modeWidth),
                  _buildRecordActions(context, ongoingEntries, mobile: false),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _buildViewControl(context, modeWidth),
                  ),
                  const SizedBox(height: OmniSpacing.xs),
                  _buildRecordActions(context, ongoingEntries, mobile: false),
                ],
              );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            header,
            const SizedBox(height: OmniSpacing.xs),
            _buildRangeControls(
              context,
              width: width,
              androidCompact: androidCompact,
            ),
          ],
        );
      },
    );
  }

  /// 返回短日期；极窄或大字号时按自然边界分行并保留完整语义。
  String _shortSelectionLabel({bool multiline = false}) {
    // 明细与日复盘使用单日。
    final bool daily =
        _viewMode == TimelineViewMode.details ||
        _statsPeriod == TimelineStatsPeriod.day;
    // 跨年查询保留年份，避免短日期歧义。
    final bool showYear = _selectedDay.year != ref.read(nowProvider).year;
    // 大字号日期按年份与月日分行。
    final String separator = multiline ? '\n' : '/';
    if (daily) {
      return '${showYear ? '${_selectedDay.year}$separator' : ''}${DateFormat('M/d').format(_selectedDay)}';
    }
    if (_statsPeriod == TimelineStatsPeriod.month) {
      return '${_selectedDay.year}${multiline ? '\n' : '年'}${_selectedDay.month}月';
    }
    // 周范围的自然日起止。
    final (DateTime, DateTime) range = _rangeFor(_selectedDay, _statsPeriod);
    // 当前周的最后一天。
    final DateTime last = range.$2.subtract(const Duration(days: 1));
    // 是否需要明确表示跨年周的年份。
    final bool weekYear = showYear || range.$1.year != last.year;
    // 起点的完整短格式。
    final String start =
        '${weekYear ? '${range.$1.year}$separator' : ''}${DateFormat('M/d').format(range.$1)}';
    // 终点的完整短格式。
    final String end =
        '${weekYear ? '${last.year}$separator' : ''}${DateFormat('M/d').format(last)}';
    return '$start${multiline ? '\n–' : '–'}$end';
  }

  /// 构建箭头和日期组成的完整导航组。
  Widget _buildDateNavigation(
    BuildContext context, {
    required double width,
    required bool shortLabel,
  }) {
    // 平台箭头热区的标准尺寸。
    final double extent = OmniDensity.controlHeight(context);
    // 日期文字实际可用的宽度。
    final double labelWidth = math.max(
      0,
      width - extent * 2 - OmniSpacing.xs * 2,
    );
    // 首先尝试当前平台的日期格式。
    String label = shortLabel ? _shortSelectionLabel() : _selectionLabel();
    if (_textWidth(context, label, Theme.of(context).textTheme.labelLarge) >
        labelWidth) {
      label = _shortSelectionLabel(multiline: true);
    }
    return SizedBox(
      key: const ValueKey<String>('timeline-date-navigation'),
      width: width,
      child: Row(
        children: <Widget>[
          OmniIconButton(
            tooltip: '上一周期',
            onPressed: () => _moveSelection(-1),
            icon: const Icon(Icons.chevron_left_rounded),
          ),
          Expanded(
            child: Tooltip(
              message: _selectionLabel(),
              child: OmniDatePickerButton(
                key: const ValueKey<String>('timeline-date-picker'),
                value: _selectedDay,
                initialDate: _selectedDay,
                currentDate: ref.read(nowProvider),
                firstDate: DateTime(1970),
                lastDate: DateTime(2100),
                icon: null,
                label: label,
                style: ButtonStyle(
                  side: const WidgetStatePropertyAll<BorderSide>(
                    BorderSide.none,
                  ),
                  padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
                    EdgeInsets.symmetric(horizontal: OmniSpacing.xs),
                  ),
                  minimumSize: WidgetStatePropertyAll<Size>(Size(0, extent)),
                  backgroundColor: const WidgetStatePropertyAll<Color>(
                    Colors.transparent,
                  ),
                ),
                onChanged: (DateTime selected) =>
                    setState(() => _selectedDay = selected),
              ),
            ),
          ),
          OmniIconButton(
            tooltip: '下一周期',
            onPressed: () => _moveSelection(1),
            icon: const Icon(Icons.chevron_right_rounded),
          ),
        ],
      ),
    );
  }

  /// 将统计周期、日期巡航和回当前组合为独立的范围带。
  Widget _buildRangeControls(
    BuildContext context, {
    required double width,
    required bool androidCompact,
  }) {
    // 当前文字样式用于自然宽度测量。
    final TextStyle? style = Theme.of(context).textTheme.labelLarge;
    // 当前平台的完整点击高度。
    final double extent = OmniDensity.controlHeight(context);
    // 回当前周期的直接入口。
    final Widget shortcut = OmniButton(
      key: const ValueKey<String>('timeline-current-shortcut'),
      label: _currentShortcutLabel(),
      variant: OmniButtonVariant.text,
      visualHeight: OmniDensity.isTouch(context) ? OmniSize.control : null,
      onPressed: () => setState(
        () => _selectedDay = DateUtils.dateOnly(ref.read(nowProvider)),
      ),
    );
    // 桌面周期滑块随字体大小扩展，移动端使用单个周期菜单。
    final double periodWidth = androidCompact
        ? _textWidth(context, '周', style) + extent
        : math.max(
            132,
            (_textWidth(context, '周', Theme.of(context).textTheme.labelMedium) +
                    OmniSpacing.lg * 2) *
                3,
          );
    // 只有复盘模式提供统计周期切换。
    final Widget? period = _viewMode == TimelineViewMode.details
        ? null
        : androidCompact
        ? OmniPopupMenuButton<TimelineStatsPeriod>(
            key: const ValueKey<String>('timeline-period-menu'),
            tooltip: '选择统计周期',
            initialValue: _statsPeriod,
            onSelected: (TimelineStatsPeriod value) =>
                setState(() => _statsPeriod = value),
            itemBuilder: (BuildContext context) =>
                <PopupMenuEntry<TimelineStatsPeriod>>[
                  for (final TimelineStatsPeriod value
                      in TimelineStatsPeriod.values)
                    OmniPopupMenuItem<TimelineStatsPeriod>(
                      value: value,
                      label: switch (value) {
                        TimelineStatsPeriod.day => '日',
                        TimelineStatsPeriod.week => '周',
                        TimelineStatsPeriod.month => '月',
                      },
                      icon: _statsPeriod == value
                          ? Icons.check_rounded
                          : Icons.calendar_view_week_outlined,
                    ),
                ],
            child: Container(
              constraints: BoxConstraints(minHeight: extent),
              padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.xs),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(switch (_statsPeriod) {
                    TimelineStatsPeriod.day => '日',
                    TimelineStatsPeriod.week => '周',
                    TimelineStatsPeriod.month => '月',
                  }, style: style),
                  const SizedBox(width: OmniSpacing.xxs),
                  const Icon(Icons.expand_more_rounded, size: OmniSize.icon),
                ],
              ),
            ),
          )
        : OmniSlidingSegmentedControl<TimelineStatsPeriod>(
            key: const ValueKey<String>('timeline-period-control'),
            options: TimelineStatsPeriod.values,
            selected: _statsPeriod,
            width: periodWidth,
            height: math.max(
              extent,
              MediaQuery.textScalerOf(context).scale(14) * 1.3 + OmniSpacing.sm,
            ),
            embedded: true,
            labelBuilder: (TimelineStatsPeriod value) => switch (value) {
              TimelineStatsPeriod.day => '日',
              TimelineStatsPeriod.week => '周',
              TimelineStatsPeriod.month => '月',
            },
            onChanged: (TimelineStatsPeriod value) =>
                setState(() => _statsPeriod = value),
          );
    // 日期组保留箭头热区和测量后的文字宽度。
    final double dateWidth =
        _textWidth(
          context,
          androidCompact ? _shortSelectionLabel() : _selectionLabel(),
          style,
        ) +
        extent * 2 +
        OmniSpacing.md +
        OmniSpacing.xs;
    // 回当前按钮的自然占位。
    final double shortcutWidth =
        _textWidth(context, _currentShortcutLabel(), style) +
        OmniSpacing.lg * 2;
    // 组合在同一行需要的最小宽度。
    final double totalWidth =
        dateWidth +
        shortcutWidth +
        (period == null ? 0 : periodWidth) +
        OmniSpacing.xs * (period == null ? 1 : 2);
    if (androidCompact && totalWidth > width) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[?period, shortcut],
          ),
          _buildDateNavigation(context, width: width, shortLabel: true),
        ],
      );
    }
    return Wrap(
      key: const ValueKey<String>('timeline-range-controls'),
      spacing: OmniSpacing.xs,
      runSpacing: OmniSpacing.xxs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        ?period,
        _buildDateNavigation(
          context,
          width: math.min(width, dateWidth),
          shortLabel: androidCompact,
        ),
        shortcut,
      ],
    );
  }

  /// 计算统计周期的左闭右开日期范围。
  (DateTime, DateTime) _rangeFor(DateTime day, TimelineStatsPeriod period) {
    // 规范化自然日。
    final DateTime normalized = DateUtils.dateOnly(day);
    return switch (period) {
      TimelineStatsPeriod.day => (
        normalized,
        normalized.add(const Duration(days: 1)),
      ),
      TimelineStatsPeriod.week => (
        normalized.subtract(Duration(days: normalized.weekday - 1)),
        normalized
            .subtract(Duration(days: normalized.weekday - 1))
            .add(const Duration(days: 7)),
      ),
      TimelineStatsPeriod.month => (
        DateTime(normalized.year, normalized.month),
        DateTime(normalized.year, normalized.month + 1),
      ),
    };
  }

  /// 计算当前周期对应的上一完整周期。
  (DateTime, DateTime) _previousRangeFor(
    (DateTime, DateTime) currentRange,
    TimelineStatsPeriod period,
  ) {
    if (period == TimelineStatsPeriod.month) {
      // 上一个自然月的起点。
      final DateTime previousStart = DateTime(
        currentRange.$1.year,
        currentRange.$1.month - 1,
      );
      return (previousStart, currentRange.$1);
    }
    // 日或周周期的持续天数。
    final Duration duration = currentRange.$2.difference(currentRange.$1);
    return (currentRange.$1.subtract(duration), currentRange.$1);
  }

  /// 返回当前选择范围的按钮文案。
  String _selectionLabel() {
    if (_viewMode == TimelineViewMode.details ||
        _statsPeriod == TimelineStatsPeriod.day) {
      return DateFormat('yyyy 年 M 月 d 日').format(_selectedDay);
    }
    if (_statsPeriod == TimelineStatsPeriod.month) {
      return DateFormat('yyyy 年 M 月').format(_selectedDay);
    }
    // 当前周范围。
    final (DateTime, DateTime) range = _rangeFor(
      _selectedDay,
      TimelineStatsPeriod.week,
    );
    // 当前周最后一天。
    final DateTime lastDay = range.$2.subtract(const Duration(days: 1));
    return '${DateFormat('M 月 d 日').format(range.$1)}—${DateFormat('M 月 d 日').format(lastDay)}';
  }

  /// 返回回到当前周期的操作文案。
  String _currentShortcutLabel() {
    if (_viewMode == TimelineViewMode.details ||
        _statsPeriod == TimelineStatsPeriod.day) {
      return '今天';
    }
    return _statsPeriod == TimelineStatsPeriod.week ? '本周' : '本月';
  }
}

/// 在悬浮操作组完成布局后通知实际尺寸。
class _TimelineActionMeasure extends SingleChildRenderObjectWidget {
  /// 当前尺寸变化的通知回调。
  final ValueChanged<Size> onSize;

  /// 创建不改变子组件布局的测量节点。
  const _TimelineActionMeasure({required this.onSize, required super.child});

  /// 创建布局测量代理。
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _TimelineActionMeasureBox(onSize);

  /// 保持渲染节点身份并同步最新回调。
  @override
  void updateRenderObject(
    BuildContext context,
    _TimelineActionMeasureBox renderObject,
  ) {
    renderObject.onSize = onSize;
  }
}

/// 仅在真实布局尺寸变化后于帧末发布尺寸。
class _TimelineActionMeasureBox extends RenderProxyBox {
  /// 当前测量结果的接收回调。
  ValueChanged<Size> onSize;

  /// 上一帧已通知的尺寸。
  Size? _previousSize;

  /// 创建透明的测量渲染对象。
  _TimelineActionMeasureBox(this.onSize);

  /// 按自然尺寸布局并避免构建阶段更新页面状态。
  @override
  void performLayout() {
    super.performLayout();
    if (_previousSize == size) return;
    _previousSize = size;
    // 捕获本次结果，帧末不读取过期布局。
    final Size measured = size;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (attached) onSize(measured);
    });
  }
}

/// 时间记录编辑弹窗。
class _TimeEntryEditorDialog extends ConsumerStatefulWidget {
  /// 默认所属日期。
  final DateTime day;

  /// 可选待编辑记录。
  final TimeEntryRecord? record;

  /// 新增记录时可选的预填开始分钟数。
  final int? initialStartMinute;

  /// 创建时间记录编辑弹窗。
  const _TimeEntryEditorDialog({
    required this.day,
    // ignore: unused_element_parameter
    this.record,
    // ignore: unused_element_parameter
    this.initialStartMinute,
  });

  /// 创建弹窗状态。
  @override
  ConsumerState<_TimeEntryEditorDialog> createState() =>
      _TimeEntryEditorDialogState();
}

/// 时间记录编辑弹窗状态。
class _TimeEntryEditorDialogState
    extends ConsumerState<_TimeEntryEditorDialog> {
  /// 表单键。
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  /// 活动控制器。
  late final TextEditingController _activityController;

  /// 分类控制器。
  late final TextEditingController _categoryController;

  /// 详细描述控制器。
  late final TextEditingController _notesController;

  /// 开始分钟数。
  late int _startMinute;

  /// 结束分钟数。
  late int _endMinute;

  /// 是否正在保存。
  bool _saving = false;

  /// 初始化时间记录表单。
  @override
  void initState() {
    super.initState();
    // 待编辑记录。
    final TimeEntryRecord? record = widget.record;
    // 当前时间向下取整到 5 分钟。
    final DateTime now = ref.read(nowProvider);
    // 新增记录的默认开始分钟数。
    final int defaultStart = ((now.hour * 60 + now.minute) ~/ 5 * 5).clamp(
      0,
      1435,
    );
    _activityController = TextEditingController(text: record?.activity ?? '');
    _categoryController = TextEditingController(text: record?.category ?? '');
    _notesController = TextEditingController(text: record?.notes ?? '');
    _startMinute =
        record?.startMinute ?? widget.initialStartMinute ?? defaultStart;
    _endMinute = record?.endMinute ?? (_startMinute + 60).clamp(15, 1440);
  }

  /// 释放文本控制器。
  @override
  void dispose() {
    _activityController.dispose();
    _categoryController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  /// 保存时间记录。
  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    setState(() => _saving = true);
    try {
      await ref
          .read(timeEntryRepositoryProvider)
          .save(
            TimeEntryDraft(
              id: widget.record?.id,
              entryDate: widget.day,
              startMinute: _startMinute,
              endMinute: _endMinute,
              activity: _activityController.text,
              category: _categoryController.text,
              notes: _notesController.text,
            ),
          );
      if (mounted) {
        Navigator.of(context).pop();
      }
    } on TimeEntryConflict catch (error) {
      if (mounted) {
        showOmniMessage(
          context,
          message: error.toString(),
          tone: OmniMessageTone.error,
        );
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

  /// 构建时间记录编辑表单。
  @override
  Widget build(BuildContext context) {
    // 当前可用时间类别。
    final List<TaxonomyEntry> categories =
        ref
            .watch(
              taxonomyEntriesProvider((
                TaxonomyModule.timeline,
                TaxonomyKind.category,
              )),
            )
            .asData
            ?.value
            .toList(growable: false) ??
        const <TaxonomyEntry>[];
    // 当前类别文本。
    final String currentCategory = _categoryController.text;
    // 当日已有时间记录。
    final List<TimeEntryRecord> dayRecords =
        ref.watch(timeEntriesForDayProvider(widget.day)).asData?.value ??
        const <TimeEntryRecord>[];
    // 排除当前编辑记录后的已占用区间。
    final List<TimeEntryRecord> occupiedRecords = dayRecords
        .where((TimeEntryRecord item) => item.id != widget.record?.id)
        .toList(growable: false);
    // 当前选择范围命中的第一条冲突记录。
    final TimeEntryRecord? conflict = _findConflict(occupiedRecords);
    // 下拉选项名称。
    final List<String> categoryNames = <String>{
      if (currentCategory.isNotEmpty) currentCategory,
      ...categories.map((TaxonomyEntry item) => item.name),
    }.toList(growable: false);
    return OmniSideSheetScaffold(
      key: const ValueKey<String>('time-entry-editor'),
      title: widget.record == null ? '记录一段时间' : '编辑时间记录',
      canClose: !_saving,
      actions: <Widget>[
        OmniButton(
          label: '取消',
          variant: OmniButtonVariant.secondary,
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
        ),
        OmniButton(
          label: _saving ? '保存中…' : '保存',
          loading: _saving,
          onPressed: _saving || conflict != null ? null : _save,
        ),
      ],
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(OmniSpacing.xl),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              OmniTextFormField(
                controller: _activityController,
                autofocus: true,
                decoration: const InputDecoration(labelText: '做了什么 *'),
                validator: (String? value) =>
                    value == null || value.trim().isEmpty ? '请输入活动内容' : null,
              ),
              const SizedBox(height: OmniSpacing.md),
              _TimeRangeEditor(
                startMinute: _startMinute,
                endMinute: _endMinute,
                occupiedRecords: occupiedRecords,
                conflict: conflict,
                onChanged: _updateTimeRange,
              ),
              const SizedBox(height: OmniSpacing.md),
              OmniDropdownButtonFormField<String>(
                initialValue: currentCategory.isEmpty ? null : currentCategory,
                decoration: const InputDecoration(labelText: '类别'),
                items: categoryNames
                    .map(
                      (String value) => DropdownMenuItem<String>(
                        value: value,
                        child: Text(value),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (String? value) {
                  _categoryController.text = value ?? '';
                },
              ),
              const SizedBox(height: OmniSpacing.md),
              OmniTextField(
                controller: _notesController,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '详细描述（可选）',
                  hintText: '补充这段时间的具体内容、地点或结果',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 更新滑动条选中的时间区间。
  void _updateTimeRange(RangeValues values) {
    // 按五分钟步进换算的开始分钟数。
    final int nextStart = ((values.start / 5).round() * 5).clamp(0, 1435);
    // 按五分钟步进换算的结束分钟数。
    final int nextEnd = ((values.end / 5).round() * 5).clamp(5, 1440);
    if (nextEnd <= nextStart) {
      return;
    }
    setState(() {
      _startMinute = nextStart;
      _endMinute = nextEnd;
    });
  }

  /// 查找当前选中区间的第一条冲突记录。
  TimeEntryRecord? _findConflict(List<TimeEntryRecord> occupiedRecords) {
    for (final TimeEntryRecord item in occupiedRecords) {
      // 当前选择是否与已有记录重叠。
      final bool overlaps =
          _startMinute < item.endMinute && _endMinute > item.startMinute;
      if (overlaps) {
        return item;
      }
    }
    return null;
  }
}

/// 滑轨吸附与阻挡后的合法范围，以及需要反馈的端点。
class _TimeRangeAdjustment {
  /// 实际允许提交的分钟区间。
  final RangeValues values;

  /// 是否阻挡开始端向左越过已有记录。
  final bool blockedStart;

  /// 是否阻挡结束端向右越过已有记录。
  final bool blockedEnd;

  /// 创建吸附和占用校验结果。
  const _TimeRangeAdjustment(
    this.values, {
    this.blockedStart = false,
    this.blockedEnd = false,
  });
}

/// 可动态扩展时间维度的双手柄区间编辑器。
class _TimeRangeEditor extends StatefulWidget {
  /// 开始分钟数。
  final int startMinute;

  /// 结束分钟数。
  final int endMinute;

  /// 已占用的时间记录。
  final List<TimeEntryRecord> occupiedRecords;

  /// 当前冲突记录。
  final TimeEntryRecord? conflict;

  /// 时间范围变更回调。
  final ValueChanged<RangeValues> onChanged;

  /// 是否显示原有时间摘要，补记新布局在卡片中统一展示。
  final bool showSummary;

  /// 是否在滑轨内显示冲突提示，补记新布局统一放在时间区。
  final bool showConflict;

  /// 是否保留逐分钟值，由调用方仅吸附正在调整的一端。
  final bool preservesMinutes;

  /// 滑轨可覆盖的连续分钟上限，长记录按实际结束日期扩展。
  final int maxMinutes;

  /// 滑轨连续分钟下限，负值表示基准日之前的时间。
  final int minMinutes;

  /// 在扩展窗口之前吸附并限制本次拖动，防止跳过已有记录。
  final _TimeRangeAdjustment Function(RangeValues)? adjustRange;

  /// 创建可动态扩展的双手柄时间区间编辑器。
  const _TimeRangeEditor({
    required this.startMinute,
    required this.endMinute,
    required this.occupiedRecords,
    required this.conflict,
    required this.onChanged,
    this.showSummary = true,
    this.showConflict = true,
    this.preservesMinutes = false,
    this.maxMinutes = 2880,
    this.minMinutes = 0,
    this.adjustRange,
    super.key,
  });

  /// 创建动态时间窗口状态。
  @override
  State<_TimeRangeEditor> createState() => _TimeRangeEditorState();
}

/// 动态时间窗口状态。
class _TimeRangeEditorState extends State<_TimeRangeEditor>
    with SingleTickerProviderStateMixin {
  /// 手柄在空闲侧回弹的当前像素位移。
  late final AnimationController _blockController;

  /// 当前反馈的被阻挡端点。
  Thumb? _blockedThumb;

  /// 临界阻尼保证回弹始终位于空闲侧，不进入已占用区间。
  static final SpringDescription _blockSpring =
      SpringDescription.withDampingRatio(mass: 1, stiffness: 320, ratio: 1);

  /// 单次展示或扩展的时间长度。
  static const int _windowMinutes = 360;

  /// 允许覆盖的实际分钟范围。
  int get _maxMinutes => widget.maxMinutes;

  /// 允许向基准日之前扩展的分钟范围。
  int get _minMinutes => widget.minMinutes;

  /// 时间窗口扩展的过渡时长。
  static const Duration _expansionDuration = Duration(milliseconds: 600);

  /// 当前可见窗口开始分钟数。
  late int _visibleStartMinute;

  /// 当前可见窗口结束分钟数。
  late int _visibleEndMinute;

  /// 根据当前选中区间初始化六小时窗口。
  @override
  void initState() {
    super.initState();
    _blockController = AnimationController.unbounded(vsync: this);
    _setInitialWindow(widget.startMinute, widget.endMinute);
  }

  /// 释放回弹时钟，避免弹窗关闭后继续更新。
  @override
  void dispose() {
    _blockController.dispose();
    super.dispose();
  }

  /// 在边界空闲侧给出一次回弹，持续顶住时不反复重启动画。
  void _showBlock(Thumb thumb) {
    if (_blockedThumb == thumb && _blockController.isAnimating) return;
    _blockedThumb = thumb;
    if (OmniMotion.reduce(context)) {
      _blockController.stop();
      _blockController.value = 0;
      return;
    }
    _blockController.value = 4;
    _blockController.animateWith(
      SpringSimulation(_blockSpring, _blockController.value, 0, 0),
    );
  }

  /// 用户反向拖动时立即解除反馈，不等待动画结束。
  void _clearBlock() {
    _blockedThumb = null;
    _blockController.stop();
    _blockController.value = 0;
  }

  /// 在外部时间值超出窗口时重新覆盖它。
  @override
  void didUpdateWidget(covariant _TimeRangeEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 当前选中区间是否超出可见窗口。
    final bool outsideWindow =
        widget.startMinute < _visibleStartMinute ||
        widget.endMinute > _visibleEndMinute;
    if (outsideWindow) {
      _setInitialWindow(widget.startMinute, widget.endMinute);
    } else {
      // 到达旧边界后父级会放宽范围，保持同一手势并继续扩展窗口。
      if (widget.minMinutes < oldWidget.minMinutes &&
          widget.startMinute <= _visibleStartMinute) {
        _visibleStartMinute = (_visibleStartMinute - _windowMinutes).clamp(
          _minMinutes,
          _maxMinutes,
        );
      }
      if (widget.maxMinutes > oldWidget.maxMinutes &&
          widget.endMinute >= _visibleEndMinute) {
        _visibleEndMinute = (_visibleEndMinute + _windowMinutes).clamp(
          _minMinutes,
          _maxMinutes,
        );
      }
    }
  }

  /// 构建时间读数、滑动条与冲突提示。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前选中区间是否存在冲突。
    final bool hasConflict = widget.conflict != null;
    // 开始手柄是否落入已占用区间。
    final bool startTouchesConflict = widget.occupiedRecords.any(
      (TimeEntryRecord record) =>
          widget.startMinute >= record.startMinute &&
          widget.startMinute < record.endMinute,
    );
    // 结束手柄是否落入已占用区间。
    final bool endTouchesConflict = widget.occupiedRecords.any(
      (TimeEntryRecord record) =>
          widget.endMinute > record.startMinute &&
          widget.endMinute < record.endMinute,
    );
    // 已占用区间是否完全位于两个手柄之间。
    final bool conflictBetweenHandles =
        hasConflict && !startTouchesConflict && !endTouchesConflict;
    // 开始侧是否需要错误强调。
    final bool startHasConflict =
        startTouchesConflict || conflictBetweenHandles;
    // 结束侧是否需要错误强调。
    final bool endHasConflict = endTouchesConflict || conflictBetweenHandles;
    // 开始时间与手柄颜色。
    final Color startColor = startHasConflict ? colors.danger : colors.time;
    // 结束时间与手柄颜色。
    final Color endColor = endHasConflict ? colors.danger : colors.time;
    // 时长与有效滑轨的常规强调色。
    final Color rangeColor = colors.time;
    // 当前区间的总分钟数。
    final int durationMinutes = widget.endMinute - widget.startMinute;
    // 当前窗口内可见的已占用记录。
    final List<TimeEntryRecord> visibleOccupiedRecords = widget.occupiedRecords
        .where(
          (TimeEntryRecord record) =>
              record.startMinute < _visibleEndMinute &&
              record.endMinute > _visibleStartMinute,
        )
        .toList(growable: false);
    // 当前动态窗口的刻度文案。
    final List<int> scaleMinutes = _scaleMinutes();
    // 尊重系统减少动效设置后的实际过渡时长。
    final Duration motionDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : _expansionDuration;
    // 供辅助功能读取的完整时间描述。
    final String semanticLabel =
        '时间范围，从 ${_time(widget.startMinute)} '
        '到 ${_time(widget.endMinute)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (widget.showSummary) ...<Widget>[
          Row(
            children: <Widget>[
              Text('时间范围', style: Theme.of(context).textTheme.labelLarge),
              const Spacer(),
              Text(
                '共 ${_duration(durationMinutes)}',
                key: const ValueKey<String>('time-range-duration'),
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: rangeColor, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: OmniSpacing.xs),
          Row(
            children: <Widget>[
              Expanded(
                child: _TimeValueCard(
                  key: const ValueKey<String>('time-start-display'),
                  label: '开始',
                  value: _time(widget.startMinute),
                  accent: startColor,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.xs),
                child: Icon(
                  Icons.arrow_forward_rounded,
                  size: OmniSize.icon,
                  color: colors.muted,
                ),
              ),
              Expanded(
                child: _TimeValueCard(
                  key: const ValueKey<String>('time-end-display'),
                  label: '结束',
                  value: _time(widget.endMinute),
                  accent: endColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: OmniSpacing.xs),
        ],
        Semantics(
          label: semanticLabel,
          child: TweenAnimationBuilder<_TimeWindow>(
            tween: _TimeWindowTween(
              begin: _TimeWindow(
                start: _visibleStartMinute.toDouble(),
                end: _visibleEndMinute.toDouble(),
              ),
              end: _TimeWindow(
                start: _visibleStartMinute.toDouble(),
                end: _visibleEndMinute.toDouble(),
              ),
            ),
            duration: motionDuration,
            curve: Curves.easeInOutCubic,
            builder:
                (
                  BuildContext context,
                  _TimeWindow animatedWindow,
                  Widget? child,
                ) {
                  // 外部输入可以跨越旧窗口，动画每帧也必须包含真实选中区间。
                  final double visibleStart = animatedWindow.start.clamp(
                    _minMinutes.toDouble(),
                    widget.startMinute.toDouble(),
                  );
                  // 日期修改后的结束值不能在窗口动画期间被裁掉。
                  final double visibleEnd =
                      animatedWindow.end < widget.endMinute
                      ? widget.endMinute.toDouble()
                      : animatedWindow.end;
                  // 动画当前帧的可见时间长度。
                  final double animatedSpan = visibleEnd - visibleStart;
                  // 动画过程中近似五分钟的离散段数。
                  final int animatedDivisions = (animatedSpan / 5)
                      .round()
                      .clamp(1, 576);
                  return AnimatedBuilder(
                    key: const ValueKey<String>('time-range-block-animation'),
                    animation: _blockController,
                    builder: (BuildContext context, Widget? child) {
                      // 回弹只移动被阻挡手柄，合法区间与另一端保持不变。
                      final double rebound = _blockController.value.clamp(0, 4);
                      return SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 8,
                          activeTrackColor: rangeColor,
                          inactiveTrackColor: colors.mist,
                          disabledActiveTrackColor: colors.mist,
                          disabledInactiveTrackColor: colors.mist,
                          overlayColor: rangeColor.withValues(alpha: 0.12),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 14,
                          ),
                          valueIndicatorColor: rangeColor,
                          valueIndicatorTextStyle: TextStyle(
                            color: colors.accentInk,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                          showValueIndicator: ShowValueIndicator.onDrag,
                          rangeTrackShape: _OccupiedRangeSliderTrackShape(
                            occupiedRecords: visibleOccupiedRecords,
                            visibleStartMinute: visibleStart,
                            visibleEndMinute: visibleEnd,
                            occupiedColor: colors.muted.withValues(alpha: 0.42),
                            conflictColor: colors.danger,
                            tickColor: colors.paper.withValues(alpha: 0.62),
                          ),
                          rangeThumbShape: _OutlinedRangeSliderThumbShape(
                            fillColor: colors.paper,
                            startBorderColor: _blockedThumb == Thumb.start
                                ? Color.lerp(
                                    startColor,
                                    colors.warning,
                                    rebound / 4,
                                  )!
                                : startColor,
                            endBorderColor: _blockedThumb == Thumb.end
                                ? Color.lerp(
                                    endColor,
                                    colors.warning,
                                    rebound / 4,
                                  )!
                                : endColor,
                            startRebound: _blockedThumb == Thumb.start
                                ? rebound
                                : 0,
                            endRebound: _blockedThumb == Thumb.end
                                ? -rebound
                                : 0,
                          ),
                        ),
                        child: RangeSlider(
                          key: const ValueKey<String>('time-range-slider'),
                          values: RangeValues(
                            widget.startMinute.toDouble(),
                            widget.endMinute.toDouble(),
                          ),
                          min: visibleStart,
                          max: visibleEnd,
                          divisions: widget.preservesMinutes
                              ? null
                              : animatedDivisions,
                          labels: RangeLabels(
                            _time(widget.startMinute),
                            _time(widget.endMinute),
                          ),
                          semanticFormatterCallback: (double value) =>
                              _time(value.round()),
                          onChanged: _handleChanged,
                        ),
                      );
                    },
                  );
                },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.xs),
          child: AnimatedSwitcher(
            duration: motionDuration,
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            child: Row(
              key: ValueKey<String>(
                'time-scale-$_visibleStartMinute-$_visibleEndMinute',
              ),
              children: <Widget>[
                for (int index = 0; index < scaleMinutes.length; index += 1)
                  Expanded(
                    child: Text(
                      _time(scaleMinutes[index]),
                      key: ValueKey<String>(
                        'time-scale-${scaleMinutes[index]}',
                      ),
                      textAlign: index == 0
                          ? TextAlign.left
                          : index == scaleMinutes.length - 1
                          ? TextAlign.right
                          : TextAlign.center,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (widget.showSummary &&
            (_visibleStartMinute > _minMinutes ||
                _visibleEndMinute < _maxMinutes)) ...<Widget>[
          const SizedBox(height: OmniSpacing.xxs),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              Icon(Icons.open_in_full_rounded, size: 13, color: colors.muted),
              const SizedBox(width: OmniSpacing.xxs),
              Text(
                '拖到边缘可继续扩展时间范围',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
        ],
        if (hasConflict && widget.showConflict) ...<Widget>[
          const SizedBox(height: OmniSpacing.xs),
          _TimeConflictMessage(record: widget.conflict!),
        ] else if (!hasConflict &&
            visibleOccupiedRecords.isNotEmpty) ...<Widget>[
          const SizedBox(height: OmniSpacing.xs),
          Row(
            children: <Widget>[
              Container(
                width: 12,
                height: 6,
                decoration: BoxDecoration(
                  color: colors.muted.withValues(alpha: 0.42),
                  borderRadius: BorderRadius.circular(OmniRadius.pill),
                ),
              ),
              const SizedBox(width: OmniSpacing.xs),
              Text(
                widget.showSummary ? '灰色区段表示当天已记录时间' : '已记录',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// 根据选中区间创建从开始时间起算的六小时窗口。
  void _setInitialWindow(int startMinute, int endMinute) {
    // 补记开始端左侧留出一小时，首次拖动也能直接触发左扩展。
    int windowStart = widget.preservesMinutes
        ? (startMinute - 60).clamp(_minMinutes, _maxMinutes - _windowMinutes)
        : startMinute;
    // 覆盖当前区间所需的六小时窗口数。
    final int windowCount =
        ((endMinute - windowStart + _windowMinutes - 1) ~/ _windowMinutes)
            .clamp(1, ((_maxMinutes - _minMinutes) / _windowMinutes).ceil());
    // 当前初始窗口总时长。
    final int windowSpan = windowCount * _windowMinutes;
    // 窗口包含全部选择值并保留合法的左右边界。
    final int windowEnd = (windowStart + windowSpan).clamp(
      _minMinutes + _windowMinutes,
      _maxMinutes,
    );
    if (windowEnd - windowStart < windowSpan) {
      windowStart = (windowEnd - windowSpan).clamp(
        _minMinutes,
        _maxMinutes - _windowMinutes,
      );
    }
    _visibleStartMinute = windowStart;
    _visibleEndMinute = windowEnd;
  }

  /// 在手柄到达边缘时扩展六小时并同步选中值。
  void _handleChanged(RangeValues values) {
    // 吸附后再检查障碍，快速拖过整个占用区间也不能穿越。
    final _TimeRangeAdjustment adjustment =
        widget.adjustRange?.call(values) ?? _TimeRangeAdjustment(values);
    if (adjustment.blockedStart) {
      _showBlock(Thumb.start);
    } else if (adjustment.blockedEnd) {
      _showBlock(Thumb.end);
    } else {
      _clearBlock();
    }
    // 滑动后的开始分钟数。
    final int nextStart = adjustment.values.start.round();
    // 滑动后的结束分钟数。
    final int nextEnd = adjustment.values.end.round();
    // 本次是否调整了开始手柄。
    final bool startChanged = nextStart != widget.startMinute;
    // 本次是否调整了结束手柄。
    final bool endChanged = nextEnd != widget.endMinute;
    // 下一个可见窗口起点。
    int nextVisibleStart = _visibleStartMinute;
    // 下一个可见窗口终点。
    int nextVisibleEnd = _visibleEndMinute;
    if (startChanged && nextStart <= _visibleStartMinute) {
      nextVisibleStart = (_visibleStartMinute - _windowMinutes).clamp(
        _minMinutes,
        _maxMinutes,
      );
    }
    if (endChanged && nextEnd >= _visibleEndMinute) {
      nextVisibleEnd = (_visibleEndMinute + _windowMinutes).clamp(
        _minMinutes,
        _maxMinutes,
      );
    }
    if (nextVisibleStart != _visibleStartMinute ||
        nextVisibleEnd != _visibleEndMinute) {
      setState(() {
        _visibleStartMinute = nextVisibleStart;
        _visibleEndMinute = nextVisibleEnd;
      });
    }
    widget.onChanged(adjustment.values);
  }

  /// 新布局显示四个刻度，旧编辑器保留七个。
  List<int> _scaleMinutes() {
    // 当前布局所需的刻度间隔数。
    final int intervals = widget.showSummary ? 6 : 3;
    // 相邻两个文字刻度的分钟间隔。
    final int step = (_visibleEndMinute - _visibleStartMinute) ~/ intervals;
    return List<int>.generate(
      intervals + 1,
      (int index) => index == intervals
          ? _visibleEndMinute
          : _visibleStartMinute + step * index,
      growable: false,
    );
  }

  /// 将分钟数格式化为时间。
  String _time(int minute) {
    if (minute == 1440) {
      return '24:00';
    }
    // 相对起始自然日的天数。
    final int dayOffset = (minute / 1440).floor();
    // 当前自然日内的分钟数。
    final int minuteOfDay = minute % 1440;
    // 二十四小时制时间。
    final String clock =
        '${(minuteOfDay ~/ 60).toString().padLeft(2, '0')}:${(minuteOfDay % 60).toString().padLeft(2, '0')}';
    return dayOffset == 0
        ? clock
        : '${dayOffset == -1
              ? '昨日'
              : dayOffset == 1
              ? '次日'
              : '${dayOffset > 0 ? '+' : ''}$dayOffset 天'} $clock';
  }

  /// 将区间分钟数格式化为时长文案。
  String _duration(int minutes) {
    // 完整小时数。
    final int hours = minutes ~/ 60;
    // 扣除完整小时后的分钟数。
    final int remainder = minutes % 60;
    if (hours == 0) {
      return '$remainder 分钟';
    }
    if (remainder == 0) {
      return '$hours 小时';
    }
    return '$hours 小时 $remainder 分钟';
  }
}

/// 开始或结束时间只读卡片。
class _TimeValueCard extends StatelessWidget {
  /// 时间类型标签。
  final String label;

  /// 格式化后的时间值。
  final String value;

  /// 当前强调色。
  final Color accent;

  /// 创建时间只读卡片。
  const _TimeValueCard({
    required this.label,
    required this.value,
    required this.accent,
    super.key,
  });

  /// 构建标签与大字时间。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: OmniSpacing.sm,
        vertical: 10,
      ),
      decoration: BoxDecoration(
        color: colors.paperSubtle,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(OmniRadius.control),
      ),
      child: Row(
        children: <Widget>[
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const Spacer(),
          Text(
            value,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: accent,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// 时间范围冲突提示。
class _TimeConflictMessage extends StatelessWidget {
  /// 与当前范围冲突的记录。
  final TimeEntryRecord record;

  /// 是否显示真实起止日期，进行中记录不伪造结束时刻。
  final bool absolute;

  /// 创建时间范围冲突提示。
  const _TimeConflictMessage({required this.record, this.absolute = false});

  /// 构建可定位到具体记录的错误文案。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 补记使用完整时间，旧编辑器继续使用自然日分钟轴。
    final String rangeLabel = absolute
        ? '${DateFormat('MM/dd HH:mm').format(record.startedAt)}–'
              '${record.endedAt == null ? '进行中' : DateFormat('MM/dd HH:mm').format(record.endedAt!)}'
        : '${_time(record.startMinute)}–${_time(record.endMinute)}';
    return Container(
      key: const ValueKey<String>('time-conflict-message'),
      padding: const EdgeInsets.symmetric(
        horizontal: OmniSpacing.sm,
        vertical: OmniSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: colors.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(OmniRadius.control),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline_rounded, size: 16, color: colors.danger),
          const SizedBox(width: OmniSpacing.xs),
          Expanded(
            child: Text(
              '与 $rangeLabel 的“${record.activity ?? '进行中记录'}”重叠，请调整时间范围',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.danger),
            ),
          ),
        ],
      ),
    );
  }

  /// 将分钟数格式化为时间。
  String _time(int minute) {
    if (minute == 1440) {
      return '24:00';
    }
    return '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';
  }
}

/// 可见时间窗口的连续起止值。
class _TimeWindow {
  /// 窗口开始分钟数。
  final double start;

  /// 窗口结束分钟数。
  final double end;

  /// 创建可见时间窗口。
  const _TimeWindow({required this.start, required this.end});

  /// 按起止值判断两个时间窗口是否相同。
  @override
  bool operator ==(Object other) {
    return other is _TimeWindow && other.start == start && other.end == end;
  }

  /// 返回与起止值一致的哈希值。
  @override
  int get hashCode => Object.hash(start, end);
}

/// 在两个可见时间窗口之间插值的补间。
class _TimeWindowTween extends Tween<_TimeWindow> {
  /// 创建时间窗口补间。
  _TimeWindowTween({required super.begin, required super.end});

  /// 返回当前动画进度对应的时间窗口。
  @override
  _TimeWindow lerp(double t) {
    // 当前补间的起始窗口。
    final _TimeWindow from = begin!;
    // 当前补间的目标窗口。
    final _TimeWindow to = end!;
    return _TimeWindow(
      start: from.start + (to.start - from.start) * t,
      end: from.end + (to.end - from.end) * t,
    );
  }
}

/// 可绘制已占用区段与小时刻度的范围滑轨。
class _OccupiedRangeSliderTrackShape extends RangeSliderTrackShape
    with BaseRangeSliderTrackShape {
  /// 已占用的时间记录。
  final List<TimeEntryRecord> occupiedRecords;

  /// 当前可见窗口开始分钟数。
  final double visibleStartMinute;

  /// 当前可见窗口结束分钟数。
  final double visibleEndMinute;

  /// 已占用区段颜色。
  final Color occupiedColor;

  /// 冲突区间颜色。
  final Color conflictColor;

  /// 小时刻度颜色。
  final Color tickColor;

  /// 创建带已占用区段的范围滑轨。
  const _OccupiedRangeSliderTrackShape({
    required this.occupiedRecords,
    required this.visibleStartMinute,
    required this.visibleEndMinute,
    required this.occupiedColor,
    required this.conflictColor,
    required this.tickColor,
  });

  /// 绘制基础滑轨、已占用区段、选中区间与小时刻度。
  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset startThumbCenter,
    required Offset endThumbCenter,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    // 当前滑轨的实际绘制矩形。
    final Rect trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    if (trackRect.isEmpty) {
      return;
    }
    // 滑轨背景颜色。
    final Color backgroundColor =
        sliderTheme.inactiveTrackColor ?? Colors.transparent;
    // 滑轨选中区间颜色。
    final Color activeColor =
        sliderTheme.activeTrackColor ?? Colors.transparent;
    // 滑轨的胶囊圆角。
    final Radius radius = Radius.circular(trackRect.height / 2);
    // 当前绘制画布。
    final Canvas canvas = context.canvas;
    canvas.drawRRect(
      RRect.fromRectAndRadius(trackRect, radius),
      Paint()..color = backgroundColor,
    );
    // 当前可见窗口的总分钟数。
    final double visibleDuration = visibleEndMinute - visibleStartMinute;
    for (final TimeEntryRecord record in occupiedRecords) {
      // 裁剪到当前窗口后的区段开始分钟数。
      final double clippedStart = record.startMinute.toDouble().clamp(
        visibleStartMinute,
        visibleEndMinute,
      );
      // 裁剪到当前窗口后的区段结束分钟数。
      final double clippedEnd = record.endMinute.toDouble().clamp(
        visibleStartMinute,
        visibleEndMinute,
      );
      // 已占用区段的左侧比例。
      final double startRatio =
          (clippedStart - visibleStartMinute) / visibleDuration;
      // 已占用区段的右侧比例。
      final double endRatio =
          (clippedEnd - visibleStartMinute) / visibleDuration;
      // 已占用区段的绘制矩形。
      final Rect occupiedRect = Rect.fromLTRB(
        trackRect.left + trackRect.width * startRatio,
        trackRect.top,
        trackRect.left + trackRect.width * endRatio,
        trackRect.bottom,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(occupiedRect, radius),
        Paint()..color = occupiedColor,
      );
    }
    // 选中区间左边界。
    final double activeLeft = switch (textDirection) {
      TextDirection.ltr => startThumbCenter.dx,
      TextDirection.rtl => endThumbCenter.dx,
    };
    // 选中区间右边界。
    final double activeRight = switch (textDirection) {
      TextDirection.ltr => endThumbCenter.dx,
      TextDirection.rtl => startThumbCenter.dx,
    };
    // 当前选中区间的绘制矩形。
    final Rect activeRect = Rect.fromLTRB(
      activeLeft,
      trackRect.top,
      activeRight,
      trackRect.bottom,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(activeRect, radius),
      Paint()..color = activeColor,
    );
    for (final TimeEntryRecord record in occupiedRecords) {
      // 已占用区段在当前窗口内的左边界。
      final double occupiedLeft =
          trackRect.left +
          trackRect.width *
              (record.startMinute.toDouble().clamp(
                    visibleStartMinute,
                    visibleEndMinute,
                  ) -
                  visibleStartMinute) /
              visibleDuration;
      // 已占用区段在当前窗口内的右边界。
      final double occupiedRight =
          trackRect.left +
          trackRect.width *
              (record.endMinute.toDouble().clamp(
                    visibleStartMinute,
                    visibleEndMinute,
                  ) -
                  visibleStartMinute) /
              visibleDuration;
      // 选中区间与已占用区段的实际重叠矩形。
      final Rect overlapRect = Rect.fromLTRB(
        occupiedLeft > activeLeft ? occupiedLeft : activeLeft,
        trackRect.top,
        occupiedRight < activeRight ? occupiedRight : activeRight,
        trackRect.bottom,
      );
      if (overlapRect.left < overlapRect.right) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(overlapRect, radius),
          Paint()..color = conflictColor,
        );
      }
    }
    // 小时刻度画笔。
    final Paint tickPaint = Paint()
      ..color = tickColor
      ..strokeWidth = 1;
    // 窗口内第一个需要绘制的整点。
    final int firstHourMinute = ((visibleStartMinute / 60).floor() + 1) * 60;
    for (
      int minute = firstHourMinute;
      minute < visibleEndMinute;
      minute += 60
    ) {
      // 当前小时刻度的横向坐标。
      final double dx =
          trackRect.left +
          trackRect.width * (minute - visibleStartMinute) / visibleDuration;
      canvas.drawLine(
        Offset(dx, trackRect.top + 1),
        Offset(dx, trackRect.bottom - 1),
        tickPaint,
      );
    }
  }

  /// 当前滑轨外形使用圆角。
  @override
  bool get isRounded => true;
}

/// 白底强调色描边的范围滑动手柄。
class _OutlinedRangeSliderThumbShape extends RangeSliderThumbShape {
  /// 手柄内部填充色。
  final Color fillColor;

  /// 开始手柄边框色。
  final Color startBorderColor;

  /// 结束手柄边框色。
  final Color endBorderColor;

  /// 开始手柄向空闲侧的阻挡回弹位移。
  final double startRebound;

  /// 结束手柄向空闲侧的阻挡回弹位移。
  final double endRebound;

  /// 手柄视觉半径。
  static const double _radius = 10;

  /// 创建白底强调色描边手柄。
  const _OutlinedRangeSliderThumbShape({
    required this.fillColor,
    required this.startBorderColor,
    required this.endBorderColor,
    this.startRebound = 0,
    this.endRebound = 0,
  });

  /// 返回手柄所需的视觉尺寸。
  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) {
    return const Size.fromRadius(_radius);
  }

  /// 绘制带阴影的白底描边手柄。
  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    bool isDiscrete = false,
    bool isEnabled = false,
    bool isOnTop = false,
    TextDirection textDirection = TextDirection.ltr,
    required SliderThemeData sliderTheme,
    Thumb thumb = Thumb.start,
    bool isPressed = false,
  }) {
    // 回弹不改变逻辑选中值，且始终朝向可选的空闲区间。
    final Offset paintCenter = center.translate(
      thumb == Thumb.start ? startRebound : endRebound,
      0,
    );
    // 当前按压态下的手柄缩放半径。
    final double effectiveRadius = _radius + activationAnimation.value;
    // 当前绘制画布。
    final Canvas canvas = context.canvas;
    // 根据手柄侧别选择的边框色。
    final Color effectiveBorderColor = thumb == Thumb.start
        ? startBorderColor
        : endBorderColor;
    canvas.drawShadow(
      Path()..addOval(
        Rect.fromCircle(center: paintCenter, radius: effectiveRadius),
      ),
      Colors.black.withValues(alpha: 0.18),
      2,
      true,
    );
    canvas.drawCircle(paintCenter, effectiveRadius, Paint()..color = fillColor);
    canvas.drawCircle(
      paintCenter,
      effectiveRadius - 1,
      Paint()
        ..color = effectiveBorderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }
}

/// 时间记录弹窗的业务模式。
enum _TimeEntryEditorMode {
  /// 补录或编辑一条已经结束的记录。
  completed,

  /// 只保存开始时间，创建进行中记录。
  startOnly,

  /// 编辑一条仍在进行中的记录。
  ongoing,

  /// 为进行中记录补充结束时间与活动内容。
  finish,
}

/// 使用绝对时间的居中时间记录弹窗。
class _AbsoluteTimeEntryDialog extends ConsumerStatefulWidget {
  /// 当前弹窗模式。
  final _TimeEntryEditorMode mode;

  /// 新增记录的默认自然日。
  final DateTime day;

  /// 可选待编辑记录。
  final TimeEntryRecord? record;

  /// 新增记录时可选的预填开始分钟数。
  final int? initialStartMinute;

  /// 创建绝对时间记录弹窗。
  const _AbsoluteTimeEntryDialog({
    required this.mode,
    required this.day,
    this.record,
    this.initialStartMinute,
  });

  /// 创建弹窗状态。
  @override
  ConsumerState<_AbsoluteTimeEntryDialog> createState() =>
      _AbsoluteTimeEntryDialogState();
}

/// 使用绝对时间的居中时间记录弹窗状态。
class _AbsoluteTimeEntryDialogState
    extends ConsumerState<_AbsoluteTimeEntryDialog> {
  /// 仅安卓新增补记使用全屏分组表单。
  bool get _usesFullscreenBackfill =>
      widget.mode == _TimeEntryEditorMode.completed &&
      widget.record == null &&
      Theme.of(context).platform == TargetPlatform.android;

  /// 仅安卓开始记录使用可展开底部面板。
  bool get _usesExpandableSheet =>
      widget.mode == _TimeEntryEditorMode.startOnly &&
      Theme.of(context).platform == TargetPlatform.android;

  /// 日期控件支持范围内的固定查询，扩展窗口时不清空占用快照。
  static final (DateTime, DateTime) _recordRange = (
    DateTime(1970),
    DateTime(2101),
  );

  /// 表单键。
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  /// 活动内容控制器。
  late final TextEditingController _activityController;

  /// 分类控制器。
  late final TextEditingController _categoryController;

  /// 备注控制器。
  late final TextEditingController _notesController;

  /// 当前选择的开始时间。
  late DateTime _startedAt;

  /// 当前选择的结束时间。
  late DateTime _endedAt;

  /// 滑轨固定的基准自然日，拖动跨日时不重建控件或重算坐标。
  late DateTime _sliderDay;

  /// 是否正在保存。
  bool _saving = false;

  /// 安卓滚轮当前编辑开始时间还是结束时间。
  bool _editingStart = true;

  /// 备注是否展开，编辑已有备注时自动展开。
  late bool _notesExpanded;

  /// 桌面开始时刻输入是否完整有效。
  bool _startInputValid = true;

  /// 桌面结束时刻输入是否完整有效。
  bool _endInputValid = true;

  /// 保存失败后常驻显示的错误信息。
  String? _saveError;

  /// 默认补记区间必须读取已有记录后才能编辑或保存。
  bool _defaultRangeReady = true;

  /// 是否正在计算默认空闲区间。
  bool _loadingDefaultRange = false;

  /// 打开时的结束候选，重试时不随等待改变。
  late final DateTime _defaultEnd;

  /// 初始化绝对时间表单。
  @override
  void initState() {
    super.initState();
    // 当前时间。
    final DateTime now = ref.read(nowProvider);
    // 当前时间向下取整到五分钟。
    final DateTime roundedNow = DateTime(
      now.year,
      now.month,
      now.day,
      now.hour,
      now.minute ~/ 5 * 5,
    );
    _defaultEnd = roundedNow;
    // 新增补记默认回溯一小时，时间轴预填和开始记录沿用原有时间。
    final DateTime defaultStart = widget.initialStartMinute == null
        ? widget.mode == _TimeEntryEditorMode.completed
              ? roundedNow.subtract(const Duration(hours: 1))
              : roundedNow
        : DateUtils.dateOnly(widget.day)
              .add(Duration(minutes: widget.initialStartMinute!));
    // 待编辑记录。
    final TimeEntryRecord? record = widget.record;
    _startedAt = record?.startedAt ?? defaultStart;
    _sliderDay = DateUtils.dateOnly(_startedAt);
    _endedAt = switch (widget.mode) {
      _TimeEntryEditorMode.finish =>
        roundedNow.isAfter(_startedAt)
            ? roundedNow
            : _startedAt.add(const Duration(minutes: 5)),
      _ => record?.endedAt ?? _startedAt.add(const Duration(hours: 1)),
    };
    _activityController = TextEditingController(text: record?.activity ?? '');
    _categoryController = TextEditingController(text: record?.category ?? '');
    _notesController = TextEditingController(text: record?.notes ?? '');
    _notesExpanded = _notesController.text.isNotEmpty;
    if (widget.mode == _TimeEntryEditorMode.completed &&
        record == null &&
        widget.initialStartMinute == null) {
      _defaultRangeReady = false;
      _loadDefaultRange();
    }
  }

  /// 向下取整到一分钟，结束端不得延伸到占用区间里。
  DateTime _floorMinute(DateTime value) =>
      DateTime(value.year, value.month, value.day, value.hour, value.minute);

  /// 向上取整到一分钟，开始端不得覆盖记录末尾的秒数。
  DateTime _ceilMinute(DateTime value) {
    // 秒和微秒均为零时完整保留原有分钟。
    final DateTime floor = _floorMinute(value);
    return value.isAfter(floor) ? floor.add(const Duration(minutes: 1)) : floor;
  }

  /// 从当前时刻往前寻找最近空闲段，上限一小时，不跳过中间占用。
  (DateTime, DateTime) _defaultFreeRange(List<TimeEntryRecord> records) {
    // 按开始时间倒序遍历，合并相邻或重叠的占用边界。
    final List<TimeEntryRecord> ordered = records.toList()
      ..sort(
        (TimeEntryRecord a, TimeEntryRecord b) =>
            b.startedAt.compareTo(a.startedAt),
      );
    // 当前最近可用的结束边界。
    DateTime end = _defaultEnd;
    // 默认最多回溯一小时。
    DateTime start = end.subtract(const Duration(hours: 1));
    for (final TimeEntryRecord record in ordered) {
      if (!record.startedAt.isBefore(end)) continue;
      if (record.endedAt == null || !record.endedAt!.isBefore(end)) {
        end = _floorMinute(record.startedAt);
        start = end.subtract(const Duration(hours: 1));
      } else {
        // 对齐到完整分钟后的开始时间，保留非五分钟边界。
        final DateTime boundary = _ceilMinute(record.endedAt!);
        if (boundary.isAfter(start)) start = boundary;
        if (!start.isBefore(end)) {
          end = _floorMinute(record.startedAt);
          start = end.subtract(const Duration(hours: 1));
        }
      }
    }
    return (start, end);
  }

  /// 默认值只在打开时计算一次，失败可重试，不覆盖之后的用户输入。
  Future<void> _loadDefaultRange() async {
    if (_loadingDefaultRange) return;
    setState(() {
      _loadingDefaultRange = true;
      _saveError = null;
    });
    try {
      // 使用同一绝对时间口径，包含进行中、跨日及未来开始的记录。
      final List<TimeEntryRecord> records = await ref
          .read(timeEntryRepositoryProvider)
          .loadForRange(_recordRange.$1, _recordRange.$2);
      if (!mounted) return;
      // 得到最靠近打开时刻的一段空闲时间。
      final (DateTime start, DateTime end) = _defaultFreeRange(records);
      setState(() {
        _startedAt = start;
        _endedAt = end;
        _sliderDay = DateUtils.dateOnly(start);
        _defaultRangeReady = true;
      });
    } catch (_) {
      if (mounted) setState(() => _saveError = '读取已有记录失败，请重试');
    } finally {
      if (mounted) setState(() => _loadingDefaultRange = false);
    }
  }

  /// 释放文本控制器。
  @override
  void dispose() {
    _activityController.dispose();
    _categoryController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  /// 保存当前记录。
  Future<void> _save() async {
    if (_saving || !_defaultRangeReady) return;
    if (!_formKey.currentState!.validate()) {
      return;
    }
    setState(() {
      _saving = true;
      _saveError = null;
    });
    // 受关闭保护的安卓编辑器须在提交成功后先解除返回拦截。
    final bool guardedEditor = _usesExpandableSheet || _usesFullscreenBackfill;
    try {
      await ref
          .read(timeEntryRepositoryProvider)
          .save(
            TimeEntryDraft(
              id: widget.record?.id,
              startedAt: _startedAt,
              endedAt:
                  widget.mode == _TimeEntryEditorMode.startOnly ||
                      widget.mode == _TimeEntryEditorMode.ongoing
                  ? null
                  : _endedAt,
              activity: _activityController.text,
              category: _categoryController.text,
              notes: _notesController.text,
            ),
          );
      if (mounted) {
        if (guardedEditor) {
          setState(() => _saving = false);
          await WidgetsBinding.instance.endOfFrame;
          if (!mounted) return;
        }
        Navigator.of(context).pop();
      }
    } on ActiveTimeEntryConflict catch (error) {
      _showError(error.toString());
    } on TimeEntryConflict catch (error) {
      _showError(error.toString());
    } on FormatException catch (error) {
      _showError(error.message);
    } catch (error) {
      if (!guardedEditor) rethrow;
      _showError(_usesFullscreenBackfill ? '保存失败，请重试' : '开始记录失败，请重试');
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  /// 展示表单错误。
  void _showError(String message) {
    if (!mounted) {
      return;
    }
    if (widget.mode == _TimeEntryEditorMode.completed || _usesExpandableSheet) {
      setState(() => _saveError = message);
    } else {
      showOmniMessage(context, message: message, tone: OmniMessageTone.error);
    }
  }

  /// 更新日期并保留原时分。
  DateTime _withDate(DateTime source, DateTime date) {
    return DateTime(
      date.year,
      date.month,
      date.day,
      source.hour,
      source.minute,
    );
  }

  /// 更新时间并保留原日期。
  DateTime _withTime(DateTime source, TimeOfDay time) {
    return DateTime(
      source.year,
      source.month,
      source.day,
      time.hour,
      time.minute,
    );
  }

  /// 将补记滑动条结果换算为绝对开始与结束时间。
  void _updateSliderRange(RangeValues values) {
    // 当前滑动条基准自然日。
    final DateTime day = _sliderDay;
    // 当前开始分钟，用于判断正在移动的手柄。
    final int currentStart = _startedAt.difference(day).inMinutes;
    // 当前结束分钟，保留非整五分钟和较短记录。
    final int currentEnd = _endedAt.difference(day).inMinutes;
    // 应用吸附与阻挡后的开始分钟，未移动的一端保留绝对时间。
    final int startMinute = values.start.round();
    // 应用吸附与阻挡后的结束分钟。
    final int endMinute = values.end.round();
    if (endMinute <= startMinute) {
      return;
    }
    setState(() {
      if (startMinute != currentStart) {
        _startedAt = day.add(Duration(minutes: startMinute));
        _startInputValid = true;
      }
      if (endMinute != currentEnd) {
        _endedAt = day.add(Duration(minutes: endMinute));
        _endInputValid = true;
      }
      _saveError = null;
    });
  }

  /// 吸附被拖端点后限制在当前空闲段内，不允许越过整个占用区间。
  _TimeRangeAdjustment _adjustSliderRange(
    RangeValues values,
    List<TimeEntryRecord> occupied,
  ) {
    // 当前开始和结束分钟，未拖动的一端不重新取整。
    final int currentStart = _startedAt.difference(_sliderDay).inMinutes;
    // 当前结束端的精确分钟。
    final int currentEnd = _endedAt.difference(_sliderDay).inMinutes;
    // 仅对发生移动的端点应用五分钟吸附。
    int start = values.start.round() == currentStart
        ? currentStart
        : (values.start / 5).round() * 5;
    // 吸附后的结束候选。
    int end = values.end.round() == currentEnd
        ? currentEnd
        : (values.end / 5).round() * 5;
    // 本次实际触碰的左侧障碍。
    bool blockedStart = false;
    // 本次实际触碰的右侧障碍。
    bool blockedEnd = false;
    for (final TimeEntryRecord record in occupied) {
      if (start < currentStart &&
          record.endedAt != null &&
          !record.endedAt!.isAfter(_startedAt) &&
          record.endMinute > start) {
        // 已编辑记录带秒时，阻挡不能反向改变其合法开始时刻。
        start = record.endMinute > currentStart
            ? currentStart
            : record.endMinute;
        blockedStart = true;
      }
      if (end > currentEnd &&
          !record.startedAt.isBefore(_endedAt) &&
          record.startMinute < end) {
        end = record.startMinute < currentEnd ? currentEnd : record.startMinute;
        blockedEnd = true;
      }
    }
    return _TimeRangeAdjustment(
      start < end
          ? RangeValues(start.toDouble(), end.toDouble())
          : RangeValues(currentStart.toDouble(), currentEnd.toDouble()),
      blockedStart: blockedStart,
      blockedEnd: blockedEnd,
    );
  }

  /// 更新单个端点的时分，保留日期并反馈无效的部分输入。
  void _updateEndpointTime(bool start, TimeOfDay? time) {
    setState(() {
      if (start) {
        _startInputValid = time != null;
        if (time != null) _startedAt = _withTime(_startedAt, time);
      } else {
        _endInputValid = time != null;
        if (time != null) _endedAt = _withTime(_endedAt, time);
      }
      _saveError = null;
    });
  }

  /// 将绝对时间记录投影到补记滑动条的连续分钟轴。
  List<TimeEntryRecord> _relativeSliderRecords({
    required List<TimeEntryRecord> records,
    required DateTime day,
    required int minMinutes,
    required int maxMinutes,
  }) {
    // 投影后的占用区间。
    final List<TimeEntryRecord> relativeRecords = <TimeEntryRecord>[];
    for (final TimeEntryRecord record in records) {
      if (record.id == widget.record?.id) {
        continue;
      }
      // 进行中持续占用后续区间，与仓储保存语义保持一致。
      final DateTime effectiveEnd =
          record.endedAt ?? day.add(Duration(minutes: maxMinutes));
      // 相对基准日的裁切开始分钟。
      final int startMinute =
          (record.startedAt.difference(day).inMicroseconds /
                  Duration.microsecondsPerMinute)
              .floor()
              .clamp(minMinutes, maxMinutes);
      // 相对基准日的裁切结束分钟。
      final int endMinute =
          (effectiveEnd.difference(day).inMicroseconds /
                  Duration.microsecondsPerMinute)
              .ceil()
              .clamp(minMinutes, maxMinutes);
      if (endMinute <= startMinute) {
        continue;
      }
      relativeRecords.add(
        record.copyWith(
          entryDate: day,
          startMinute: startMinute,
          endMinute: endMinute,
        ),
      );
    }
    return relativeRecords;
  }

  /// 按完整绝对时间检查冲突，供安卓滚轮和桌面滑轨共同使用。
  TimeEntryRecord? _findTimeConflict(List<TimeEntryRecord> records) {
    for (final TimeEntryRecord record in records) {
      if (record.id == widget.record?.id) continue;
      // 当前选择是否与已有记录重叠。
      final bool overlaps =
          _startedAt.isBefore(record.endedAt ?? DateTime(9999, 12, 31)) &&
          _endedAt.isAfter(record.startedAt);
      if (overlaps) {
        return record;
      }
    }
    return null;
  }

  /// 返回弹窗标题。
  String get _title => switch (widget.mode) {
    _TimeEntryEditorMode.completed =>
      widget.record == null ? '补记一段时间' : '编辑时间记录',
    _TimeEntryEditorMode.startOnly => '开始记录',
    _TimeEntryEditorMode.ongoing => '编辑进行中记录',
    _TimeEntryEditorMode.finish => '结束记录',
  };

  /// 返回主要操作文案。
  String get _actionLabel => switch (widget.mode) {
    _TimeEntryEditorMode.completed => '保存记录',
    _TimeEntryEditorMode.startOnly => '开始记录',
    _TimeEntryEditorMode.ongoing => '保存修改',
    _TimeEntryEditorMode.finish => '结束并保存',
  };

  /// 构建绝对时间记录表单。
  @override
  Widget build(BuildContext context) {
    // 当前可用时间类别。
    final List<TaxonomyEntry> categories =
        ref
            .watch(
              taxonomyEntriesProvider((
                TaxonomyModule.timeline,
                TaxonomyKind.category,
              )),
            )
            .asData
            ?.value
            .toList(growable: false) ??
        const <TaxonomyEntry>[];
    // 类别名称对应的配置颜色，供下拉选项和选中值共同使用。
    final Map<String, Color> categoryColors = <String, Color>{
      for (final TaxonomyEntry category in categories)
        category.name: Color(category.colorValue),
    };
    // 已移除类别沿用时间模块的默认颜色。
    final Color fallbackCategoryColor = OmniColors.of(context).time;
    // 当前类别文本。
    final String currentCategory = _categoryController.text;
    // 下拉选项名称。
    final List<String> categoryNames = <String>{
      if (currentCategory.isNotEmpty) currentCategory,
      ...categories.map((TaxonomyEntry item) => item.name),
    }.toList(growable: false);
    // 是否需要填写结束时间。
    final bool hasEndTime =
        widget.mode != _TimeEntryEditorMode.startOnly &&
        widget.mode != _TimeEntryEditorMode.ongoing;
    // 已完成记录使用重构后的时间区间布局。
    final bool completed = widget.mode == _TimeEntryEditorMode.completed;
    // 按平台选择输入方式，平板和窄桌面窗口保持各自交互。
    final bool usesWheel = Theme.of(context).platform == TargetPlatform.android;
    // 补记滑动条的基准自然日。
    final DateTime sliderDay = _sliderDay;
    // 补记滑动条的开始分钟数。
    final int sliderStartMinute = _startedAt.difference(sliderDay).inMinutes;
    // 补记滑动条的结束分钟数，跨天时允许超过 1440。
    final int sliderEndMinute = _endedAt.difference(sliderDay).inMinutes;
    // 左侧至少可到昨日，继续向左拖动时按真实开始时间扩展。
    final int sliderMinMinute = sliderStartMinute - 360 < -1440
        ? sliderStartMinute - 360
        : -1440;
    // 滑轨覆盖较长跨日记录，并在右侧保留扩展空间。
    final int sliderMaxMinute = sliderEndMinute + 360 > 2880
        ? sliderEndMinute + 360
        : 2880;
    // 固定读取全部可选日期的记录，快速跨日扩展也不丢失阻挡边界。
    final AsyncValue<List<TimeEntryRecord>> recordsState = completed
        ? ref.watch(timeEntriesForRangeProvider(_recordRange))
        : const AsyncData<List<TimeEntryRecord>>(<TimeEntryRecord>[]);
    // 查询尚未准备好时不允许拖动或保存。
    final bool recordsReady = recordsState.asData != null;
    // 保留最新完整占用快照。
    final List<TimeEntryRecord> sliderRecords =
        recordsState.asData?.value ?? const <TimeEntryRecord>[];
    // 投影到连续分钟轴的已占用区间。
    final List<TimeEntryRecord> occupiedSliderRecords = completed
        ? _relativeSliderRecords(
            records: sliderRecords,
            day: sliderDay,
            minMinutes: sliderMinMinute,
            maxMinutes: sliderMaxMinute,
          )
        : const <TimeEntryRecord>[];
    // 当前滑动选择命中的冲突记录。
    final TimeEntryRecord? sliderConflict = completed
        ? _findTimeConflict(sliderRecords)
        : null;
    // 时间区间与手动输入均合法时才允许保存。
    final bool invalidTime =
        completed &&
        (!_endedAt.isAfter(_startedAt) || !_startInputValid || !_endInputValid);
    // 当前页面的活动内容输入，共用校验和原有输入提示。
    final Widget activityField = OmniTextFormField(
      key: const ValueKey<String>('time-entry-activity'),
      controller: _activityController,
      autofocus: !completed && widget.mode != _TimeEntryEditorMode.startOnly,
      decoration: _usesFullscreenBackfill
          ? _groupedInputDecoration.copyWith(hintText: '做了什么')
          : InputDecoration(
              labelText: completed
                  ? null
                  : hasEndTime
                  ? '做了什么 *'
                  : '正在做什么（可稍后填写）',
              hintText: hasEndTime ? '例如：睡眠、学习 Text2SQL' : '留空也可以直接开始',
            ),
      validator: (String? value) =>
          hasEndTime && (value == null || value.trim().isEmpty)
          ? '请输入活动内容'
          : null,
    );
    // 沿用原有分类色点，菜单项及选中值均保持左侧业务颜色。
    final Widget categoryField = OmniDropdownButtonFormField<String>(
      key: const ValueKey<String>('time-entry-category'),
      initialValue: currentCategory.isEmpty ? null : currentCategory,
      decoration: _usesFullscreenBackfill
          ? _groupedInputDecoration
          : InputDecoration(
              labelText: completed || _usesExpandableSheet ? null : '类别',
            ),
      hint: const Text('选择类别'),
      selectionIndicatorPosition:
          OmniDropdownSelectionIndicatorPosition.trailing,
      items: categoryNames
          .map(
            (String value) => DropdownMenuItem<String>(
              value: value,
              child: Row(
                children: <Widget>[
                  Container(
                    key: ValueKey<String>('time-category-color-$value'),
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: categoryColors[value] ?? fallbackCategoryColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: OmniSpacing.xs),
                  Expanded(child: Text(value)),
                ],
              ),
            ),
          )
          .toList(growable: false),
      onChanged: (String? value) => _categoryController.text = value ?? '',
    );
    if (_usesExpandableSheet) {
      return OmniExpandableBottomSheetScaffold(
        key: const ValueKey<String>('time-entry-editor'),
        semanticsLabel: '开始记录面板',
        canClose: !_saving,
        leading: OmniButton(
          label: '取消',
          variant: OmniButtonVariant.text,
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
        ),
        trailing: OmniButton(
          key: const ValueKey<String>('time-entry-start-submit'),
          label: '开始',
          visualHeight: OmniSize.control,
          loading: _saving,
          onPressed: _saving ? null : _save,
        ),
        bodyBuilder: (BuildContext context, bool expanded) => AbsorbPointer(
          absorbing: _saving,
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                activityField,
                const SizedBox(height: OmniSpacing.lg),
                categoryField,
                if (expanded) ...<Widget>[
                  const SizedBox(height: OmniSpacing.lg),
                  _AbsoluteDateTimeField(
                    key: const ValueKey<String>('time-entry-start-time'),
                    label: '开始时间',
                    value: _startedAt,
                    onDateChanged: (DateTime date) => setState(
                      () => _startedAt = _withDate(_startedAt, date),
                    ),
                    onTimeChanged: (TimeOfDay time) => setState(
                      () => _startedAt = _withTime(_startedAt, time),
                    ),
                  ),
                  const SizedBox(height: OmniSpacing.lg),
                  OmniTextField(
                    key: const ValueKey<String>('time-entry-notes'),
                    controller: _notesController,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: '详细描述（可选）',
                      hintText: '补充地点、结果或其他上下文',
                    ),
                  ),
                ],
                if (_saveError != null) ...<Widget>[
                  const SizedBox(height: OmniSpacing.sm),
                  Text(
                    _saveError!,
                    key: const ValueKey<String>('time-entry-save-error'),
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: OmniColors.of(context).danger),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }
    // 两种呈现共用时间状态、表单校验及加载失败重试。
    final Widget editorBody = !_defaultRangeReady
        ? Padding(
            padding: const EdgeInsets.all(OmniSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (_loadingDefaultRange) ...<Widget>[
                  const CircularProgressIndicator(),
                  const SizedBox(height: OmniSpacing.md),
                  const Text('正在计算空闲时间…'),
                ] else ...<Widget>[
                  Text(_saveError ?? '读取已有记录失败，请重试'),
                  const SizedBox(height: OmniSpacing.md),
                  OmniButton(label: '重试', onPressed: _loadDefaultRange),
                ],
              ],
            ),
          )
        : SingleChildScrollView(
            padding: _usesFullscreenBackfill
                ? const EdgeInsets.all(OmniSpacing.md)
                : EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (!recordsReady)
                  Padding(
                    padding: const EdgeInsets.only(bottom: OmniSpacing.md),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          recordsState.hasError
                              ? '读取已记录时间失败，请重试'
                              : '正在读取已记录时间…',
                        ),
                        if (recordsState.hasError)
                          OmniButton(
                            label: '重试',
                            onPressed: () => ref.invalidate(
                              timeEntriesForRangeProvider(_recordRange),
                            ),
                          ),
                      ],
                    ),
                  ),
                AbsorbPointer(
                  absorbing: _saving || !recordsReady,
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        if (_usesFullscreenBackfill) ...<Widget>[
                          _backfillGroup(
                            child: _buildCompletedTimeSection(
                              usesWheel: usesWheel,
                              sliderDay: sliderDay,
                              startMinute: sliderStartMinute,
                              endMinute: sliderEndMinute,
                              minMinute: sliderMinMinute,
                              maxMinute: sliderMaxMinute,
                              occupiedRecords: occupiedSliderRecords,
                              conflict: sliderConflict,
                              invalidTime: invalidTime,
                            ),
                          ),
                          const SizedBox(height: OmniSpacing.lg),
                          _buildBackfillDetails(activityField, categoryField),
                          if (_saveError != null) ...<Widget>[
                            const SizedBox(height: OmniSpacing.sm),
                            Text(
                              _saveError!,
                              key: const ValueKey<String>(
                                'time-entry-save-error',
                              ),
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: OmniColors.of(context).danger,
                                  ),
                            ),
                          ],
                        ] else if (completed) ...<Widget>[
                          _buildCompletedTimeSection(
                            usesWheel: usesWheel,
                            sliderDay: sliderDay,
                            startMinute: sliderStartMinute,
                            endMinute: sliderEndMinute,
                            minMinute: sliderMinMinute,
                            maxMinute: sliderMaxMinute,
                            occupiedRecords: occupiedSliderRecords,
                            conflict: sliderConflict,
                            invalidTime: invalidTime,
                          ),
                          const SizedBox(height: OmniSpacing.lg),
                          const Divider(),
                          const SizedBox(height: OmniSpacing.lg),
                          LayoutBuilder(
                            builder:
                                (
                                  BuildContext context,
                                  BoxConstraints constraints,
                                ) {
                                  // 桌面宽窗口让活动和类别同行，触控或大字号则自然分行。
                                  final bool horizontal =
                                      !usesWheel &&
                                      constraints.maxWidth >= 520 &&
                                      MediaQuery.textScalerOf(context)
                                              .scale(14) <=
                                          21;
                                  // 活动输入的外置标签。
                                  final Widget activity = _labelledField(
                                    '做了什么 *',
                                    activityField,
                                  );
                                  // 类别输入的外置标签，内部保留原有颜色圆点。
                                  final Widget category = _labelledField(
                                    '类别',
                                    categoryField,
                                  );
                                  return horizontal
                                      ? Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: <Widget>[
                                            Expanded(flex: 2, child: activity),
                                            const SizedBox(
                                              width: OmniSpacing.md,
                                            ),
                                            Expanded(child: category),
                                          ],
                                        )
                                      : Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: <Widget>[
                                            activity,
                                            const SizedBox(
                                              height: OmniSpacing.md,
                                            ),
                                            category,
                                          ],
                                        );
                                },
                          ),
                          const SizedBox(height: OmniSpacing.sm),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: OmniButton(
                              key: const ValueKey<String>(
                                'time-entry-notes-toggle',
                              ),
                              variant: OmniButtonVariant.text,
                              onPressed: _saving
                                  ? null
                                  : () => setState(
                                      () => _notesExpanded = !_notesExpanded,
                                    ),
                              icon: _notesExpanded
                                  ? Icons.expand_less_rounded
                                  : Icons.expand_more_rounded,
                              label: _notesExpanded ? '收起备注' : '添加备注（可选）',
                            ),
                          ),
                          if (_notesExpanded)
                            OmniTextField(
                              key: const ValueKey<String>('time-entry-notes'),
                              controller: _notesController,
                              maxLines: 3,
                              decoration: const InputDecoration(
                                hintText: '补充地点、结果或其他信息',
                              ),
                            ),
                          if (_saveError != null) ...<Widget>[
                            const SizedBox(height: OmniSpacing.sm),
                            Text(
                              _saveError!,
                              key: const ValueKey<String>(
                                'time-entry-save-error',
                              ),
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: OmniColors.of(context).danger,
                                  ),
                            ),
                          ],
                        ] else ...<Widget>[
                          activityField,
                          const SizedBox(height: OmniSpacing.lg),
                          _AbsoluteDateTimeField(
                            label: '开始时间',
                            value: _startedAt,
                            onDateChanged:
                                widget.mode == _TimeEntryEditorMode.finish
                                ? null
                                : (DateTime date) => setState(
                                    () => _startedAt = _withDate(
                                      _startedAt,
                                      date,
                                    ),
                                  ),
                            onTimeChanged:
                                widget.mode == _TimeEntryEditorMode.finish
                                ? null
                                : (TimeOfDay time) => setState(
                                    () => _startedAt = _withTime(
                                      _startedAt,
                                      time,
                                    ),
                                  ),
                          ),
                          if (hasEndTime) ...<Widget>[
                            const SizedBox(height: OmniSpacing.md),
                            _AbsoluteDateTimeField(
                              label: '结束时间',
                              value: _endedAt,
                              onDateChanged: (DateTime date) => setState(
                                () => _endedAt = _withDate(_endedAt, date),
                              ),
                              onTimeChanged: (TimeOfDay time) => setState(
                                () => _endedAt = _withTime(_endedAt, time),
                              ),
                            ),
                            const SizedBox(height: OmniSpacing.sm),
                            _TimeSpanHint(
                              startedAt: _startedAt,
                              endedAt: _endedAt,
                            ),
                          ],
                          const SizedBox(height: OmniSpacing.lg),
                          categoryField,
                          const SizedBox(height: OmniSpacing.md),
                          OmniTextField(
                            controller: _notesController,
                            maxLines: 3,
                            decoration: const InputDecoration(
                              labelText: '详细描述（可选）',
                              hintText: '补充地点、结果或其他上下文',
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
    // 所有入口使用相同的保存门禁，避免未加载或冲突区间提交。
    final VoidCallback? onSave =
        _saving ||
            !_defaultRangeReady ||
            !recordsReady ||
            sliderConflict != null ||
            invalidTime
        ? null
        : _save;
    if (_usesFullscreenBackfill) {
      return _buildFullscreenBackfill(
        child: editorBody,
        onSave: onSave,
        invalidTime: invalidTime,
      );
    }
    return OmniDialogScaffold(
      key: const ValueKey<String>('time-entry-editor'),
      title: _title,
      width: completed ? (usesWheel ? 440 : 680) : 620,
      onWindowsEnter: onSave,
      actions: <Widget>[
        OmniButton(
          label: '取消',
          variant: OmniButtonVariant.secondary,
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
        ),
        OmniButton(
          label: _saving ? '保存中…' : _actionLabel,
          loading: _saving,
          onPressed: onSave,
        ),
      ],
      child: editorBody,
    );
  }

  /// 分组行使用卡片自身的底色和分隔线，输入保持原生校验能力。
  static const InputDecoration _groupedInputDecoration = InputDecoration(
    filled: false,
    contentPadding: EdgeInsets.symmetric(vertical: OmniSpacing.sm),
    border: InputBorder.none,
    enabledBorder: InputBorder.none,
    focusedBorder: InputBorder.none,
    disabledBorder: InputBorder.none,
    errorBorder: InputBorder.none,
    focusedErrorBorder: InputBorder.none,
  );

  /// 构建实底圆角分组，不叠加外框或阴影。
  Widget _backfillGroup({required Widget child, Key? key}) {
    return Material(
      key: key,
      color: OmniColors.of(context).paper,
      borderRadius: BorderRadius.circular(OmniRadius.panel),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.md),
        child: child,
      ),
    );
  }

  /// 活动、类别和可折叠备注共用设置式分组卡片。
  Widget _buildBackfillDetails(Widget activityField, Widget categoryField) {
    return _backfillGroup(
      key: const ValueKey<String>('time-entry-details-group'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Semantics(label: '做了什么，必填', child: activityField),
          const Divider(height: 1),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              // 大字号或极窄窗口将类别标签置于控件上方，保留选项可读宽度。
              final bool stacked =
                  constraints.maxWidth < 280 ||
                  MediaQuery.textScalerOf(context).scale(14) > 21;
              return stacked
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        const Padding(
                          padding: EdgeInsets.only(top: OmniSpacing.sm),
                          child: Text('类别'),
                        ),
                        categoryField,
                      ],
                    )
                  : Row(
                      children: <Widget>[
                        const Text('类别'),
                        const SizedBox(width: OmniSpacing.xl),
                        Expanded(child: categoryField),
                      ],
                    );
            },
          ),
          const Divider(height: 1),
          Semantics(
            expanded: _notesExpanded,
            child: OmniButton(
              key: const ValueKey<String>('time-entry-notes-toggle'),
              variant: OmniButtonVariant.text,
              onPressed: _saving
                  ? null
                  : () => setState(() => _notesExpanded = !_notesExpanded),
              icon: _notesExpanded
                  ? Icons.expand_less_rounded
                  : Icons.expand_more_rounded,
              label: _notesExpanded ? '收起备注' : '添加备注（可选）',
            ),
          ),
          if (_notesExpanded)
            OmniTextField(
              key: const ValueKey<String>('time-entry-notes'),
              controller: _notesController,
              maxLines: 3,
              decoration: _groupedInputDecoration.copyWith(
                hintText: '补充地点、结果或其他信息',
              ),
            ),
        ],
      ),
    );
  }

  /// 固定全屏弹窗顶部操作和居中时长，正文随键盘避让并独立滚动。
  Widget _buildFullscreenBackfill({
    required Widget child,
    required VoidCallback? onSave,
    required bool invalidTime,
  }) {
    // 当前主题的背景及辅助文字颜色。
    final OmniColors colors = OmniColors.of(context);
    // 非整小时保留最多两位小数，整数不显示多余零。
    final String hours = NumberFormat('0.##')
        .format(_endedAt.difference(_startedAt).inMinutes / 60);
    return PopScope(
      canPop: !_saving,
      child: Dialog.fullscreen(
        key: const ValueKey<String>('time-entry-editor'),
        backgroundColor: colors.canvas,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.xs),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: OmniButton(
                          label: '取消',
                          variant: OmniButtonVariant.text,
                          onPressed: _saving
                              ? null
                              : () => Navigator.of(context).pop(),
                        ),
                      ),
                    ),
                    Semantics(
                      namesRoute: true,
                      header: true,
                      child: Text(
                        '补记',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Theme(
                          data: Theme.of(context).copyWith(
                            colorScheme: Theme.of(context).colorScheme
                                .copyWith(onPrimary: Colors.white),
                          ),
                          child: OmniButton(
                            key: const ValueKey<String>(
                              'time-entry-backfill-submit',
                            ),
                            label: '保存',
                            variant: OmniButtonVariant.primary,
                            visualHeight: OmniSize.control,
                            loading: _saving,
                            onPressed: onSave,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: OmniSpacing.xs),
                child: Text(
                  !_defaultRangeReady
                      ? (_loadingDefaultRange ? '正在计算时长…' : '时长待计算')
                      : invalidTime
                      ? '时间待调整'
                      : '共 $hours 小时',
                  key: const ValueKey<String>('time-range-duration'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colors.muted),
                ),
              ),
              Expanded(child: child),
            ],
          ),
        ),
      ),
    );
  }

  /// 用外置标签明确活动和类别所属字段。
  Widget _labelledField(String label, Widget field) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(label, style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: OmniSpacing.xs),
        field,
      ],
    );
  }

  /// 构建一侧起止卡片，日期与时刻均写入同一份绝对时间。
  Widget _buildEndpointCard({required bool start, required bool usesWheel}) {
    return TimeEntryEndpointCard(
      key: ValueKey<String>(start ? 'time-start-display' : 'time-end-display'),
      endpoint: start ? 'start' : 'end',
      value: start ? _startedAt : _endedAt,
      usesWheel: usesWheel,
      selected: _editingStart == start,
      nextDay:
          !start &&
          DateUtils.isSameDay(
            _endedAt,
            DateTime(_startedAt.year, _startedAt.month, _startedAt.day + 1),
          ),
      enabled: !_saving,
      onSelect: () {
        FocusManager.instance.primaryFocus?.unfocus();
        setState(() => _editingStart = start);
      },
      onDateChanged: (DateTime date) => setState(() {
        if (start) {
          _startedAt = _withDate(_startedAt, date);
          _sliderDay = DateUtils.dateOnly(_startedAt);
        } else {
          _endedAt = _withDate(_endedAt, date);
        }
        _saveError = null;
      }),
      onTimeChanged: (TimeOfDay? time) => _updateEndpointTime(start, time),
    );
  }

  /// 构建两端一致的时间摘要及平台专用输入。
  Widget _buildCompletedTimeSection({
    required bool usesWheel,
    required DateTime sliderDay,
    required int startMinute,
    required int endMinute,
    required int minMinute,
    required int maxMinute,
    required List<TimeEntryRecord> occupiedRecords,
    required TimeEntryRecord? conflict,
    required bool invalidTime,
  }) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 用实际时间差显示唯一一处时长。
    final int minutes = _endedAt.difference(_startedAt).inMinutes;
    // 精简时长文本，避免零小时或零分钟占据注意力。
    final String duration = minutes <= 0
        ? '不足 1 分钟'
        : '${minutes >= 60 ? '${minutes ~/ 60} 小时' : ''}'
                  '${minutes % 60 != 0 ? ' ${minutes % 60} 分钟' : ''}'
              .trim();
    // 滚轮上方在时间无效时显示错误，恢复有效后继续提示当前调整端点。
    final String? timeError = invalidTime
        ? (!_startInputValid || !_endInputValid
              ? '请输入有效时刻（HH:mm）'
              : '结束时间必须晚于开始时间')
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (!_usesFullscreenBackfill)
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: OmniSpacing.sm,
            runSpacing: OmniSpacing.xxs,
            children: <Widget>[
              Text('时间区间', style: Theme.of(context).textTheme.labelLarge),
              Text(
                invalidTime ? '待调整' : '共 $duration',
                key: const ValueKey<String>('time-range-duration'),
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: colors.muted),
              ),
            ],
          ),
        const SizedBox(height: OmniSpacing.sm),
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            // 窄屏和放大文字时分行，日期和精确时刻都完整可见。
            final bool stacked =
                constraints.maxWidth < 260 ||
                MediaQuery.textScalerOf(context).scale(14) > 21;
            return stacked
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _buildEndpointCard(start: true, usesWheel: usesWheel),
                      const SizedBox(height: OmniSpacing.sm),
                      _buildEndpointCard(start: false, usesWheel: usesWheel),
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(
                        child: _buildEndpointCard(
                          start: true,
                          usesWheel: usesWheel,
                        ),
                      ),
                      const SizedBox(width: OmniSpacing.sm),
                      Expanded(
                        child: _buildEndpointCard(
                          start: false,
                          usesWheel: usesWheel,
                        ),
                      ),
                    ],
                  );
          },
        ),
        if (usesWheel) ...<Widget>[
          const SizedBox(height: OmniSpacing.sm),
          Text(
            timeError ?? (_editingStart ? '调整开始时间' : '调整结束时间'),
            key: timeError == null
                ? null
                : const ValueKey<String>('time-entry-time-error'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: timeError == null ? colors.muted : colors.danger,
            ),
          ),
          TimeEntryWheelPicker(
            // 字号变化会改变刻度高度，重建滚轮以按真实时刻定位，避免像素偏移改写数据。
            key: ValueKey<(bool, double)>((
              _editingStart,
              MediaQuery.textScalerOf(context).scale(
                Theme.of(context).textTheme.headlineSmall?.fontSize ?? 24,
              ),
            )),
            value: TimeOfDay.fromDateTime(
              _editingStart ? _startedAt : _endedAt,
            ),
            label: _editingStart ? '开始' : '结束',
            enabled: !_saving,
            onChanged: (TimeOfDay time) =>
                _updateEndpointTime(_editingStart, time),
          ),
        ] else if (_endedAt.isAfter(_startedAt)) ...<Widget>[
          const SizedBox(height: OmniSpacing.sm),
          _TimeRangeEditor(
            // 开始日期变化时重新建立自然日对应的滑轨窗口。
            key: ValueKey<DateTime>(sliderDay),
            startMinute: startMinute,
            endMinute: endMinute,
            minMinutes: minMinute,
            maxMinutes: maxMinute,
            occupiedRecords: occupiedRecords,
            conflict: conflict,
            showSummary: false,
            showConflict: false,
            preservesMinutes: true,
            adjustRange: (RangeValues values) =>
                _adjustSliderRange(values, occupiedRecords),
            onChanged: _updateSliderRange,
          ),
        ],
        if (!usesWheel && invalidTime) ...<Widget>[
          const SizedBox(height: OmniSpacing.xs),
          Text(
            timeError!,
            key: const ValueKey<String>('time-entry-time-error'),
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.danger),
          ),
        ] else if (!invalidTime && conflict != null) ...<Widget>[
          const SizedBox(height: OmniSpacing.xs),
          _TimeConflictMessage(record: conflict, absolute: true),
        ],
      ],
    );
  }
}

/// 绝对日期与时间组合字段。
class _AbsoluteDateTimeField extends StatelessWidget {
  /// 字段标签。
  final String label;

  /// 当前时间值。
  final DateTime value;

  /// 日期变化回调。
  final ValueChanged<DateTime>? onDateChanged;

  /// 时刻变化回调。
  final ValueChanged<TimeOfDay>? onTimeChanged;

  /// 创建绝对日期与时间组合字段。
  const _AbsoluteDateTimeField({
    required this.label,
    required this.value,
    required this.onDateChanged,
    required this.onTimeChanged,
    super.key,
  });

  /// 构建字段标签及日期、时刻选择器。
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: OmniSpacing.xs),
        Row(
          children: <Widget>[
            Expanded(
              child: OmniDatePickerButton(
                value: value,
                initialDate: value,
                firstDate: DateTime(1970),
                lastDate: DateTime(2100),
                label: DateFormat('yyyy 年 M 月 d 日').format(value),
                onChanged: onDateChanged,
              ),
            ),
            const SizedBox(width: OmniSpacing.sm),
            Expanded(
              child: OmniTimePickerButton(
                value: TimeOfDay.fromDateTime(value),
                label: DateFormat('HH:mm').format(value),
                minuteStep: 5,
                onChanged: onTimeChanged,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 时间跨度与跨天提示。
class _TimeSpanHint extends StatelessWidget {
  /// 开始时间。
  final DateTime startedAt;

  /// 结束时间。
  final DateTime endedAt;

  /// 创建时间跨度提示。
  const _TimeSpanHint({required this.startedAt, required this.endedAt});

  /// 构建时长或校验提示。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 结束时间是否合法。
    final bool valid = endedAt.isAfter(startedAt);
    // 当前时长。
    final Duration duration = endedAt.difference(startedAt);
    // 分钟总数。
    final int totalMinutes = duration.inMinutes;
    // 格式化时长。
    final String durationLabel =
        '${totalMinutes ~/ 60} 小时 ${totalMinutes % 60} 分钟';
    return Row(
      children: <Widget>[
        Icon(
          valid ? Icons.check_circle_outline_rounded : Icons.error_outline,
          size: 16,
          color: valid ? colors.success : colors.danger,
        ),
        const SizedBox(width: OmniSpacing.xs),
        Expanded(
          child: Text(
            valid ? '共 $durationLabel' : '结束时间必须晚于开始时间',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: valid ? colors.muted : colors.danger),
          ),
        ),
      ],
    );
  }
}

/// 页面顶部的进行中记录提示条。
class _OngoingTimeEntryBanner extends StatefulWidget {
  /// 当前全部进行中记录。
  final List<TimeEntryRecord> records;

  /// 结束记录回调。
  final ValueChanged<TimeEntryRecord> onFinish;

  /// 编辑记录回调。
  final ValueChanged<TimeEntryRecord> onEdit;

  /// 创建进行中记录提示条。
  const _OngoingTimeEntryBanner({
    required this.records,
    required this.onFinish,
    required this.onEdit,
  });

  /// 创建提示条状态。
  @override
  State<_OngoingTimeEntryBanner> createState() =>
      _OngoingTimeEntryBannerState();
}

/// 页面顶部的进行中记录提示条状态。
class _OngoingTimeEntryBannerState extends State<_OngoingTimeEntryBanner> {
  /// 每分钟刷新一次时长的计时器。
  Timer? _timer;

  /// 初始化分钟刷新计时器。
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(minutes: 1), (Timer _) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  /// 释放分钟刷新计时器。
  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// 构建进行中状态与结束入口。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 优先处理最早开始的进行中记录。
    final TimeEntryRecord record = widget.records.first;
    // 已持续分钟数。
    final int elapsedMinutes = DateTime.now()
        .difference(record.startedAt)
        .inMinutes;
    // 当前是否存在同步产生的多条进行中记录。
    final bool hasConflict = widget.records.length > 1;
    return Container(
      key: const ValueKey<String>('ongoing-time-entry-banner'),
      padding: const EdgeInsets.symmetric(
        horizontal: OmniSpacing.md,
        vertical: OmniSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: hasConflict
            ? colors.warning.withValues(alpha: 0.08)
            : colors.brandSoft,
        border: Border.all(
          color: hasConflict
              ? colors.warning.withValues(alpha: 0.35)
              : colors.brand.withValues(alpha: 0.22),
        ),
        borderRadius: BorderRadius.circular(OmniRadius.panel),
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // 冲突说明完整换行，普通记录保留可读的活动和持续时间。
          final String description = hasConflict
              ? '检测到 ${widget.records.length} 条进行中记录，请逐条结束以解决同步冲突'
              : '${timeEntryDisplayActivity(record)} · 已进行 ${_formatElapsed(elapsedMinutes)} · ${DateFormat('M月d日 HH:mm').format(record.startedAt)} 开始';
          // 状态图标与文字作为同一信息组。
          final Widget status = Row(
            children: <Widget>[
              Icon(
                hasConflict
                    ? Icons.warning_amber_rounded
                    : Icons.radio_button_checked,
                size: OmniSize.icon,
                color: hasConflict ? colors.warning : colors.brand,
              ),
              const SizedBox(width: OmniSpacing.xs),
              Expanded(
                child: Tooltip(
                  message: description,
                  child: Text(
                    description,
                    maxLines: hasConflict ? null : 2,
                    overflow: hasConflict ? null : TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          );
          // 普通记录统一使用主结束入口，冲突记录保留逐条处理能力。
          final Widget actions = Wrap(
            alignment: WrapAlignment.end,
            spacing: OmniSpacing.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              OmniButton(
                label: '编辑',
                variant: OmniButtonVariant.text,
                onPressed: () => widget.onEdit(record),
              ),
              if (hasConflict)
                OmniButton(
                  label: '结束记录',
                  variant: OmniButtonVariant.secondary,
                  onPressed: () => widget.onFinish(record),
                ),
            ],
          );
          if ((hasConflict && constraints.maxWidth < 600) ||
              MediaQuery.textScalerOf(context).scale(14) > 20) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[status, actions],
            );
          }
          return Row(
            children: <Widget>[
              Expanded(child: status),
              const SizedBox(width: OmniSpacing.xs),
              actions,
            ],
          );
        },
      ),
    );
  }

  /// 格式化进行中时长。
  String _formatElapsed(int minutes) {
    // 避免设备时间回拨导致负数。
    final int safeMinutes = minutes.clamp(0, 999999);
    // 完整小时数。
    final int hours = safeMinutes ~/ 60;
    // 剩余分钟数。
    final int remainingMinutes = safeMinutes % 60;
    return hours == 0
        ? '$remainingMinutes 分钟'
        : '$hours 小时 $remainingMinutes 分钟';
  }
}
