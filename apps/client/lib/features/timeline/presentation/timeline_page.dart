import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/features/timeline/data/time_entry_repository.dart';
import 'package:omni_butler/features/timeline/presentation/timeline_review.dart';
import 'package:omni_butler/shared/taxonomy/taxonomy_manager_dialog.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 在当前页面打开轻量开始记录弹窗。
Future<void> showStartTimeEntryDialog(
  BuildContext context, {
  required DateTime day,
}) async {
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
  await showOmniDialog<void>(
    context: context,
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

/// Android 时间页拆分按钮中的次要操作。
enum _TimelineMobileAction {
  /// 补记完整时间记录。
  backfill,

  /// 管理时间分类。
  categories,
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
  /// Android 悬浮拆分按钮需要避让的滚动内容高度。
  static const double _mobileActionClearance = 88;

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
    await showOmniDialog<void>(
      context: context,
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

  /// 执行 Android 拆分按钮中的次要操作。
  Future<void> _handleMobileAction(_TimelineMobileAction action) async {
    switch (action) {
      case _TimelineMobileAction.backfill:
        await _openEditor();
        return;
      case _TimelineMobileAction.categories:
        await _openTimelineCategories();
        return;
    }
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
    // 保持桌面结构不变的时间页主体。
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
          if (!androidCompact) ...<Widget>[
            OmniPageHeader(
              title: '时间管理',
              actions: <Widget>[
                OmniButton(
                  label: '分类',
                  icon: Icons.category_outlined,
                  variant: OmniButtonVariant.secondary,
                  onPressed: _openTimelineCategories,
                ),
                OmniButton(
                  label: '补记时间',
                  icon: Icons.edit_calendar_outlined,
                  variant: OmniButtonVariant.secondary,
                  onPressed: () => _openEditor(),
                ),
                OmniButton(
                  label: ongoingEntries.isEmpty ? '开始记录' : '结束记录',
                  icon: ongoingEntries.isEmpty
                      ? Icons.play_arrow_rounded
                      : Icons.stop_rounded,
                  variant: OmniButtonVariant.pagePrimary,
                  onPressed: ongoingEntries.isEmpty
                      ? _openStartEditor
                      : () => _openFinishEditor(ongoingEntries.first),
                ),
              ],
            ),
            const SizedBox(height: OmniSpacing.xs),
          ],
          _buildToolbar(context, androidCompact: androidCompact),
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
                              ? _mobileActionClearance
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
                              ? _mobileActionClearance
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
      floatingActionButton: OmniSplitActionButton<_TimelineMobileAction>(
        keyPrefix: 'timeline-mobile',
        label: ongoingEntries.isEmpty ? '开始记录' : '结束记录',
        primaryIcon: ongoingEntries.isEmpty
            ? Icons.play_arrow_rounded
            : Icons.stop_rounded,
        primarySemanticsLabel: ongoingEntries.isEmpty ? '开始记录' : '结束记录',
        menuTooltip: '更多时间操作',
        onPressed: ongoingEntries.isEmpty
            ? _openStartEditor
            : () => _openFinishEditor(ongoingEntries.first),
        actions: const <OmniSplitAction<_TimelineMobileAction>>[
          OmniSplitAction<_TimelineMobileAction>(
            value: _TimelineMobileAction.backfill,
            label: '补记时间',
            icon: Icons.edit_calendar_outlined,
          ),
          OmniSplitAction<_TimelineMobileAction>(
            value: _TimelineMobileAction.categories,
            label: '分类',
            icon: Icons.category_outlined,
          ),
        ],
        onSelected: _handleMobileAction,
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      body: pageContent,
    );
  }

  /// 构建可在紧凑宽度换行的日期与统计工具栏。
  Widget _buildToolbar(BuildContext context, {required bool androidCompact}) {
    // 桌面与其他平台使用的页面模式切换。
    final Widget legacyViewControl = SegmentedButton<TimelineViewMode>(
      key: const ValueKey<String>('timeline-view-mode'),
      showSelectedIcon: false,
      segments: const <ButtonSegment<TimelineViewMode>>[
        ButtonSegment<TimelineViewMode>(
          value: TimelineViewMode.review,
          icon: Icon(Icons.insights_outlined),
          label: Text('时间复盘'),
        ),
        ButtonSegment<TimelineViewMode>(
          value: TimelineViewMode.details,
          icon: Icon(Icons.view_timeline_outlined),
          label: Text('记录明细'),
        ),
      ],
      selected: <TimelineViewMode>{_viewMode},
      onSelectionChanged: (Set<TimelineViewMode> selection) {
        setState(() => _viewMode = selection.first);
      },
    );
    // 当前日期选择按钮。
    final Widget datePicker = OmniDatePickerButton(
      value: _selectedDay,
      initialDate: _selectedDay,
      firstDate: DateTime(1970),
      lastDate: DateTime(2100),
      label: _selectionLabel(),
      onChanged: (DateTime selected) {
        setState(() => _selectedDay = selected);
      },
    );
    // 回到当前周期按钮。
    final Widget currentShortcut = OmniButton(
      label: _currentShortcutLabel(),
      variant: OmniButtonVariant.text,
      onPressed: () => setState(
        () => _selectedDay = DateUtils.dateOnly(ref.read(nowProvider)),
      ),
    );
    // 桌面日期导航控件。
    final Widget dateControls = OmniToolbar(
      children: <Widget>[
        IconButton(
          tooltip: '上一周期',
          onPressed: () => _moveSelection(-1),
          icon: const Icon(Icons.chevron_left_rounded),
        ),
        datePicker,
        IconButton(
          tooltip: '下一周期',
          onPressed: () => _moveSelection(1),
          icon: const Icon(Icons.chevron_right_rounded),
        ),
        currentShortcut,
      ],
    );
    // 日周月统计切换。
    final Widget statsControl = SegmentedButton<TimelineStatsPeriod>(
      showSelectedIcon: false,
      segments: const <ButtonSegment<TimelineStatsPeriod>>[
        ButtonSegment<TimelineStatsPeriod>(
          value: TimelineStatsPeriod.day,
          label: Text('日'),
        ),
        ButtonSegment<TimelineStatsPeriod>(
          value: TimelineStatsPeriod.week,
          label: Text('周'),
        ),
        ButtonSegment<TimelineStatsPeriod>(
          value: TimelineStatsPeriod.month,
          label: Text('月'),
        ),
      ],
      selected: <TimelineStatsPeriod>{_statsPeriod},
      onSelectionChanged: (Set<TimelineStatsPeriod> selection) =>
          setState(() => _statsPeriod = selection.first),
    );

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 当前布局实际使用的页面模式切换。
        final Widget viewControl = androidCompact
            ? OmniSlidingSegmentedControl<TimelineViewMode>(
                key: const ValueKey<String>('timeline-view-mode'),
                options: TimelineViewMode.values,
                selected: _viewMode,
                width: constraints.maxWidth,
                height: OmniSize.touch,
                labelBuilder: (TimelineViewMode mode) => switch (mode) {
                  TimelineViewMode.review => '时间复盘',
                  TimelineViewMode.details => '记录明细',
                },
                itemKeyBuilder: (TimelineViewMode mode) =>
                    ValueKey<String>('timeline-view-mode-${mode.name}'),
                itemBuilder:
                    (
                      BuildContext itemContext,
                      TimelineViewMode mode,
                      bool selected,
                    ) {
                      // 当前分段选项使用的主题色。
                      final ColorScheme scheme = Theme.of(itemContext)
                          .colorScheme;
                      // 当前分段选项的图文颜色。
                      final Color foreground = selected
                          ? scheme.onPrimaryContainer
                          : scheme.onSurfaceVariant;
                      // 当前分段选项文案。
                      final String label = switch (mode) {
                        TimelineViewMode.review => '时间复盘',
                        TimelineViewMode.details => '记录明细',
                      };
                      // 当前分段选项图标。
                      final IconData icon = switch (mode) {
                        TimelineViewMode.review => Icons.insights_outlined,
                        TimelineViewMode.details =>
                          Icons.view_timeline_outlined,
                      };
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(icon, size: 18, color: foreground),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(itemContext).textTheme.labelMedium
                                  ?.copyWith(
                                    color: foreground,
                                    fontWeight: selected
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                  ),
                            ),
                          ),
                        ],
                      );
                    },
                onChanged: (TimelineViewMode mode) {
                  setState(() => _viewMode = mode);
                },
              )
            : legacyViewControl;
        // 当前是否运行在桌面端。
        final bool isDesktopPlatform = OmniBreakpoint.isDesktopPlatform(
          Theme.of(context).platform,
        );
        // 当前工具栏是否需要纵向排列。
        final bool compact =
            !isDesktopPlatform &&
            OmniBreakpoint.isCompact(constraints.maxWidth);
        if (compact) {
          // 移动端单行日期导航，避免 Wrap 将四个控件拆成多行。
          final Widget compactDateControls = Row(
            children: <Widget>[
              IconButton(
                tooltip: '上一周期',
                onPressed: () => _moveSelection(-1),
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              Expanded(child: datePicker),
              IconButton(
                tooltip: '下一周期',
                onPressed: () => _moveSelection(1),
                icon: const Icon(Icons.chevron_right_rounded),
              ),
              currentShortcut,
            ],
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              viewControl,
              const SizedBox(height: OmniSpacing.xs),
              compactDateControls,
              if (_viewMode == TimelineViewMode.review) ...<Widget>[
                const SizedBox(height: OmniSpacing.xs),
                statsControl,
              ],
            ],
          );
        }
        // 桌面窄窗口下是否保留周期切换。
        final bool showStatsControl =
            _viewMode == TimelineViewMode.review &&
            (!isDesktopPlatform ||
                constraints.maxWidth >= OmniBreakpoint.compact);
        return Row(
          children: <Widget>[
            viewControl,
            const SizedBox(width: OmniSpacing.sm),
            Expanded(child: dateControls),
            if (showStatsControl) ...<Widget>[
              const SizedBox(width: OmniSpacing.xs),
              statsControl,
            ],
          ],
        );
      },
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
              TextFormField(
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
              TextField(
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

  /// 创建可动态扩展的双手柄时间区间编辑器。
  const _TimeRangeEditor({
    required this.startMinute,
    required this.endMinute,
    required this.occupiedRecords,
    required this.conflict,
    required this.onChanged,
  });

  /// 创建动态时间窗口状态。
  @override
  State<_TimeRangeEditor> createState() => _TimeRangeEditorState();
}

/// 动态时间窗口状态。
class _TimeRangeEditorState extends State<_TimeRangeEditor> {
  /// 单次展示或扩展的时间长度。
  static const int _windowMinutes = 360;

  /// 补记滑动条允许覆盖的最大时长范围。
  static const int _maxMinutes = 2880;

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
    _setInitialWindow(widget.startMinute, widget.endMinute);
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
                  // 动画当前帧的可见时间长度。
                  final double animatedSpan =
                      animatedWindow.end - animatedWindow.start;
                  // 动画过程中近似五分钟的离散段数。
                  final int animatedDivisions = (animatedSpan / 5)
                      .round()
                      .clamp(1, 576);
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
                      showValueIndicator: ShowValueIndicator.onlyForDiscrete,
                      rangeTrackShape: _OccupiedRangeSliderTrackShape(
                        occupiedRecords: visibleOccupiedRecords,
                        visibleStartMinute: animatedWindow.start,
                        visibleEndMinute: animatedWindow.end,
                        occupiedColor: colors.muted.withValues(alpha: 0.42),
                        conflictColor: colors.danger,
                        tickColor: colors.paper.withValues(alpha: 0.62),
                      ),
                      rangeThumbShape: _OutlinedRangeSliderThumbShape(
                        fillColor: colors.paper,
                        startBorderColor: startColor,
                        endBorderColor: endColor,
                      ),
                    ),
                    child: RangeSlider(
                      key: const ValueKey<String>('time-range-slider'),
                      values: RangeValues(
                        widget.startMinute.toDouble(),
                        widget.endMinute.toDouble(),
                      ),
                      min: animatedWindow.start,
                      max: animatedWindow.end,
                      divisions: animatedDivisions,
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
        if (_visibleStartMinute > 0 ||
            _visibleEndMinute < _maxMinutes) ...<Widget>[
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
        if (hasConflict) ...<Widget>[
          const SizedBox(height: OmniSpacing.xs),
          _TimeConflictMessage(record: widget.conflict!),
        ] else if (visibleOccupiedRecords.isNotEmpty) ...<Widget>[
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
                '灰色区段表示当天已记录时间',
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
    // 以选中开始时间作为初始起点。
    int windowStart = startMinute;
    // 覆盖当前区间所需的六小时窗口数。
    final int windowCount =
        ((endMinute - windowStart + _windowMinutes - 1) ~/ _windowMinutes)
            .clamp(1, 8);
    // 当前初始窗口总时长。
    final int windowSpan = windowCount * _windowMinutes;
    // 不超过次日末尾的窗口结束。
    final int windowEnd = (windowStart + windowSpan).clamp(
      _windowMinutes,
      _maxMinutes,
    );
    if (windowEnd - windowStart < windowSpan) {
      windowStart = (windowEnd - windowSpan).clamp(
        0,
        _maxMinutes - _windowMinutes,
      );
    }
    _visibleStartMinute = windowStart;
    _visibleEndMinute = windowEnd;
  }

  /// 在手柄到达边缘时扩展六小时并同步选中值。
  void _handleChanged(RangeValues values) {
    // 滑动后的开始分钟数。
    final int nextStart = values.start.round();
    // 滑动后的结束分钟数。
    final int nextEnd = values.end.round();
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
        0,
        _maxMinutes,
      );
    }
    if (endChanged && nextEnd >= _visibleEndMinute) {
      nextVisibleEnd = (_visibleEndMinute + _windowMinutes).clamp(
        0,
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
    widget.onChanged(values);
  }

  /// 返回当前窗口内均匀分布的七个刻度。
  List<int> _scaleMinutes() {
    // 相邻两个文字刻度的分钟间隔。
    final int step = (_visibleEndMinute - _visibleStartMinute) ~/ 6;
    return List<int>.generate(
      7,
      (int index) => _visibleStartMinute + step * index,
      growable: false,
    );
  }

  /// 将分钟数格式化为时间。
  String _time(int minute) {
    if (minute == 1440) {
      return '24:00';
    }
    // 相对起始自然日的天数。
    final int dayOffset = minute ~/ 1440;
    // 当前自然日内的分钟数。
    final int minuteOfDay = minute % 1440;
    // 二十四小时制时间。
    final String clock =
        '${(minuteOfDay ~/ 60).toString().padLeft(2, '0')}:${(minuteOfDay % 60).toString().padLeft(2, '0')}';
    return dayOffset == 0 ? clock : '次日 $clock';
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

  /// 创建时间范围冲突提示。
  const _TimeConflictMessage({required this.record});

  /// 构建可定位到具体记录的错误文案。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
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
              '与 ${_time(record.startMinute)}–${_time(record.endMinute)}'
              '的“${record.activity}”重叠，请调整时间范围',
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
    final int firstHourMinute = (visibleStartMinute ~/ 60 + 1) * 60;
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

  /// 手柄视觉半径。
  static const double _radius = 10;

  /// 创建白底强调色描边手柄。
  const _OutlinedRangeSliderThumbShape({
    required this.fillColor,
    required this.startBorderColor,
    required this.endBorderColor,
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
    // 当前按压态下的手柄缩放半径。
    final double effectiveRadius = _radius + activationAnimation.value;
    // 当前绘制画布。
    final Canvas canvas = context.canvas;
    // 根据手柄侧别选择的边框色。
    final Color effectiveBorderColor = thumb == Thumb.start
        ? startBorderColor
        : endBorderColor;
    canvas.drawShadow(
      Path()..addOval(Rect.fromCircle(center: center, radius: effectiveRadius)),
      Colors.black.withValues(alpha: 0.18),
      2,
      true,
    );
    canvas.drawCircle(center, effectiveRadius, Paint()..color = fillColor);
    canvas.drawCircle(
      center,
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

  /// 是否正在保存。
  bool _saving = false;

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
    // 新增记录的默认开始时间。
    final DateTime defaultStart = widget.initialStartMinute == null
        ? roundedNow
        : DateUtils.dateOnly(widget.day)
              .add(Duration(minutes: widget.initialStartMinute!));
    // 待编辑记录。
    final TimeEntryRecord? record = widget.record;
    _startedAt = record?.startedAt ?? defaultStart;
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
        Navigator.of(context).pop();
      }
    } on ActiveTimeEntryConflict catch (error) {
      _showError(error.toString());
    } on TimeEntryConflict catch (error) {
      _showError(error.toString());
    } on FormatException catch (error) {
      _showError(error.message);
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
    showOmniMessage(context, message: message, tone: OmniMessageTone.error);
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
    final DateTime day = DateUtils.dateOnly(_startedAt);
    // 按五分钟步进换算的开始分钟数。
    final int startMinute = ((values.start / 5).round() * 5).clamp(0, 2875);
    // 按五分钟步进换算的结束分钟数。
    final int endMinute = ((values.end / 5).round() * 5).clamp(5, 2880);
    if (endMinute <= startMinute) {
      return;
    }
    setState(() {
      _startedAt = day.add(Duration(minutes: startMinute));
      _endedAt = day.add(Duration(minutes: endMinute));
    });
  }

  /// 切换补记日期并整体平移当前时间范围。
  void _shiftSliderDate(DateTime date) {
    // 当前滑动条基准自然日。
    final DateTime currentDay = DateUtils.dateOnly(_startedAt);
    // 新选择的基准自然日。
    final DateTime nextDay = DateUtils.dateOnly(date);
    // 两个自然日之间的位移。
    final Duration shift = nextDay.difference(currentDay);
    setState(() {
      _startedAt = _startedAt.add(shift);
      _endedAt = _endedAt.add(shift);
    });
  }

  /// 将绝对时间记录投影到补记滑动条的连续分钟轴。
  List<TimeEntryRecord> _relativeSliderRecords({
    required List<TimeEntryRecord> records,
    required DateTime day,
    required DateTime now,
  }) {
    // 投影后的占用区间。
    final List<TimeEntryRecord> relativeRecords = <TimeEntryRecord>[];
    for (final TimeEntryRecord record in records) {
      if (record.id == widget.record?.id) {
        continue;
      }
      // 进行中记录以当前时刻作为临时结束时间。
      final DateTime effectiveEnd = record.endedAt ?? now;
      // 相对基准日的裁切开始分钟。
      final int startMinute = record.startedAt
          .difference(day)
          .inMinutes
          .clamp(0, 2880);
      // 相对基准日的裁切结束分钟。
      final int endMinute = effectiveEnd
          .difference(day)
          .inMinutes
          .clamp(0, 2880);
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

  /// 查找补记滑动区间命中的第一条冲突记录。
  TimeEntryRecord? _findSliderConflict(
    List<TimeEntryRecord> occupiedRecords,
    int startMinute,
    int endMinute,
  ) {
    for (final TimeEntryRecord record in occupiedRecords) {
      // 当前选择是否与已有记录重叠。
      final bool overlaps =
          startMinute < record.endMinute && endMinute > record.startMinute;
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
    // 补记与编辑完成记录是否使用双手柄滑动条。
    final bool usesRangeSlider = widget.mode == _TimeEntryEditorMode.completed;
    // 补记滑动条的基准自然日。
    final DateTime sliderDay = DateUtils.dateOnly(_startedAt);
    // 补记滑动条的开始分钟数。
    final int sliderStartMinute = _startedAt.difference(sliderDay).inMinutes;
    // 补记滑动条的结束分钟数，跨天时允许超过 1440。
    final int sliderEndMinute = _endedAt
        .difference(sliderDay)
        .inMinutes
        .clamp(sliderStartMinute + 5, 2880);
    // 滑动条覆盖范围内的逻辑记录。
    final List<TimeEntryRecord> sliderRecords = usesRangeSlider
        ? ref
                  .watch(
                    timeEntriesForRangeProvider((
                      sliderDay,
                      sliderDay.add(const Duration(days: 2)),
                    )),
                  )
                  .asData
                  ?.value ??
              const <TimeEntryRecord>[]
        : const <TimeEntryRecord>[];
    // 投影到连续分钟轴的已占用区间。
    final List<TimeEntryRecord> occupiedSliderRecords = usesRangeSlider
        ? _relativeSliderRecords(
            records: sliderRecords,
            day: sliderDay,
            now: ref.watch(nowProvider),
          )
        : const <TimeEntryRecord>[];
    // 当前滑动选择命中的冲突记录。
    final TimeEntryRecord? sliderConflict = usesRangeSlider
        ? _findSliderConflict(
            occupiedSliderRecords,
            sliderStartMinute,
            sliderEndMinute,
          )
        : null;
    return OmniDialogScaffold(
      key: const ValueKey<String>('time-entry-editor'),
      title: _title,
      width: 620,
      actions: <Widget>[
        OmniButton(
          label: '取消',
          variant: OmniButtonVariant.secondary,
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
        ),
        OmniButton(
          label: _saving ? '保存中…' : _actionLabel,
          loading: _saving,
          onPressed: _saving || sliderConflict != null ? null : _save,
        ),
      ],
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              TextFormField(
                controller: _activityController,
                autofocus: widget.mode != _TimeEntryEditorMode.startOnly,
                decoration: InputDecoration(
                  labelText: hasEndTime ? '做了什么 *' : '正在做什么（可稍后填写）',
                  hintText: hasEndTime ? '例如：睡眠、学习 Text2SQL' : '留空也可以直接开始',
                ),
                validator: (String? value) {
                  if (hasEndTime && (value == null || value.trim().isEmpty)) {
                    return '请输入活动内容';
                  }
                  return null;
                },
              ),
              const SizedBox(height: OmniSpacing.lg),
              if (usesRangeSlider) ...<Widget>[
                Row(
                  children: <Widget>[
                    Text('开始日期', style: Theme.of(context).textTheme.labelLarge),
                    const SizedBox(width: OmniSpacing.xs),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: OmniDatePickerButton(
                          value: sliderDay,
                          initialDate: sliderDay,
                          firstDate: DateTime(1970),
                          lastDate: DateTime(2100),
                          label: DateFormat('yyyy 年 M 月 d 日').format(sliderDay),
                          onChanged: _shiftSliderDate,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: OmniSpacing.sm),
                _TimeRangeEditor(
                  startMinute: sliderStartMinute,
                  endMinute: sliderEndMinute,
                  occupiedRecords: occupiedSliderRecords,
                  conflict: sliderConflict,
                  onChanged: _updateSliderRange,
                ),
                if (sliderEndMinute > 1440) ...<Widget>[
                  const SizedBox(height: OmniSpacing.xs),
                  Text(
                    '跨天记录将保存为一条完整记录，并按自然日拆分统计。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ] else ...<Widget>[
                _AbsoluteDateTimeField(
                  label: '开始时间',
                  value: _startedAt,
                  onDateChanged: widget.mode == _TimeEntryEditorMode.finish
                      ? null
                      : (DateTime date) {
                          setState(
                            () => _startedAt = _withDate(_startedAt, date),
                          );
                        },
                  onTimeChanged: widget.mode == _TimeEntryEditorMode.finish
                      ? null
                      : (TimeOfDay time) {
                          setState(
                            () => _startedAt = _withTime(_startedAt, time),
                          );
                        },
                ),
                if (hasEndTime) ...<Widget>[
                  const SizedBox(height: OmniSpacing.md),
                  _AbsoluteDateTimeField(
                    label: '结束时间',
                    value: _endedAt,
                    onDateChanged: (DateTime date) {
                      setState(() => _endedAt = _withDate(_endedAt, date));
                    },
                    onTimeChanged: (TimeOfDay time) {
                      setState(() => _endedAt = _withTime(_endedAt, time));
                    },
                  ),
                  const SizedBox(height: OmniSpacing.sm),
                  _TimeSpanHint(startedAt: _startedAt, endedAt: _endedAt),
                ] else ...<Widget>[
                  const SizedBox(height: OmniSpacing.sm),
                  const Text('保存后计时会持续运行，关闭应用也不会丢失；结束时再补充活动内容。'),
                ],
              ],
              const SizedBox(height: OmniSpacing.lg),
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
              TextField(
                controller: _notesController,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '详细描述（可选）',
                  hintText: '补充地点、结果或其他上下文',
                ),
              ),
            ],
          ),
        ),
      ),
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
    // 当前是否跨越自然日。
    final bool crossesDay = !DateUtils.isSameDay(startedAt, endedAt);
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
            valid
                ? '共 $durationLabel${crossesDay ? ' · 跨天记录，将按自然日拆分统计' : ''}'
                : '结束时间必须晚于开始时间',
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
      child: Row(
        children: <Widget>[
          Icon(
            hasConflict
                ? Icons.warning_amber_rounded
                : Icons.radio_button_checked,
            size: 18,
            color: hasConflict ? colors.warning : colors.brand,
          ),
          const SizedBox(width: OmniSpacing.sm),
          Expanded(
            child: Text(
              hasConflict
                  ? '检测到 ${widget.records.length} 条进行中记录，请逐条结束以解决同步冲突'
                  : '${timeEntryDisplayActivity(record)} · 已进行 ${_formatElapsed(elapsedMinutes)} · ${DateFormat('M月d日 HH:mm').format(record.startedAt)} 开始',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          OmniButton(
            label: '编辑',
            variant: OmniButtonVariant.text,
            onPressed: () => widget.onEdit(record),
          ),
          const SizedBox(width: OmniSpacing.xs),
          OmniButton(
            label: '结束记录',
            variant: OmniButtonVariant.secondary,
            onPressed: () => widget.onFinish(record),
          ),
        ],
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
