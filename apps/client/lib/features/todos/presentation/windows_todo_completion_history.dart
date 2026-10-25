import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:omni_butler/features/todos/data/todo_completion_summary.dart';
import 'package:omni_butler/features/todos/presentation/todo_completion_checkbox.dart';
import 'package:omni_butler/features/todos/presentation/todo_completion_heatmap.dart';
import 'package:omni_butler/features/todos/presentation/todo_completion_search_filter.dart';
import 'package:omni_butler/features/todos/presentation/todo_progress_panel.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';
import 'package:omni_butler/shared/ui/omni_windows_semantics_boundary.dart';

/// Windows 完成历史工作区，筛选状态与后台刷新相互独立。
class WindowsTodoCompletionHistory extends ConsumerStatefulWidget {
  /// 编辑具体普通任务或子任务。
  final ValueChanged<TodoRecord> onEdit;

  /// 重新打开具体普通任务或子任务，禁止组级级联操作。
  final ValueChanged<TodoRecord> onReopen;

  /// 创建 Windows 完成历史。
  const WindowsTodoCompletionHistory({
    required this.onEdit,
    required this.onReopen,
    super.key,
  });

  /// 创建独立筛选与展开状态。
  @override
  ConsumerState<WindowsTodoCompletionHistory> createState() =>
      _WindowsTodoCompletionHistoryState();
}

/// 完成结果滚动区域中可独立惰性构建的行类型。
enum _CompletionResultRowKind {
  /// 一个完成自然日的汇总标题。
  day,

  /// 可折叠任务的分组标题。
  group,

  /// 独立完成明细。
  entry,

  /// 保持惰性构建的完整子项分组。
  details,
}

/// 仅保存轻量描述，具体行组件进入视口时才创建。
class _CompletionResultRow {
  /// 当前行的展示类型。
  final _CompletionResultRowKind kind;

  /// 当前行所属的同日任务分组。
  final TodoCompletionGroup group;

  /// 明细行对应的实际完成单元。
  final TodoCompletionEntry? entry;

  /// 日期标题使用的筛选后当天完成数量。
  final int? dayCount;

  /// 日期层级和同日任务组之间的顶部留白。
  final double topSpacing;

  /// 创建不持有组件的结果行描述。
  const _CompletionResultRow({
    required this.kind,
    required this.group,
    this.entry,
    this.dayCount,
    this.topSpacing = 0,
  });

  /// 展开、筛选和数据重排后仍可追踪同一行身份。
  ValueKey<String> get key => ValueKey<String>(switch (kind) {
    _CompletionResultRowKind.day =>
      'todo-completion-row-day-${businessDayKey(group.day)}',
    _CompletionResultRowKind.group => 'todo-completion-row-group-${group.id}',
    _CompletionResultRowKind.entry => 'todo-completion-row-entry-${entry!.id}',
    _CompletionResultRowKind.details =>
      'todo-completion-row-details-${group.id}',
  });
}

/// 统一管理日期、关键词、类型及稳定分组的展开偏好。
class _WindowsTodoCompletionHistoryState
    extends ConsumerState<WindowsTodoCompletionHistory> {
  /// 界面仅区分普通任务（含子任务）和进度任务。
  static const List<TodoCompletionKind> _taskKinds = <TodoCompletionKind>[
    TodoCompletionKind.normal,
    TodoCompletionKind.progress,
  ];

  /// 关键词输入内容。
  final TextEditingController _searchController = TextEditingController();

  /// 搜索框焦点仅控制本页输入表面的聚焦样式。
  final FocusNode _searchFocus = FocusNode();

  /// 搜索栏整体作为筛选面板定位锚点。
  final GlobalKey _searchAnchor = GlobalKey();

  /// 鼠标进入时显示与笔记搜索一致的细边框。
  bool _searchHovered = false;

  /// 面板打开期间保留筛选按钮和搜索表面的反馈。
  bool _searchFilterOpen = false;

  /// 普通高度下的独立结果滚动控制器。
  final ScrollController _listController = ScrollController();

  /// 月份归档独立滚动，不接入右侧嵌套列表。
  final ScrollController _archiveController = ScrollController();

  /// 用户主动展开的日期任务分组。
  final Set<String> _expandedGroupIds = <String>{};

  /// 搜索自动展开后仍允许用户主动收起。
  final Set<String> _searchCollapsedGroupIds = <String>{};

  /// 类型过滤；空值表示全部。
  TodoCompletionKind? _kind;

  /// 唯一日期条件的起点。
  DateTime? _startDate;

  /// 唯一日期条件的终点，包含当天。
  DateTime? _endDate;

  /// 最近一次输入快照，用于避免每分钟重复汇总全部历史。
  List<TodoCompletionEntry>? _summaryEntries;

  /// 最近一次汇总结果，日期变化时重新计算。
  TodoCompletionSummary? _summary;

  /// 页面只监听自己的搜索焦点，不修改其他模块的输入状态。
  @override
  void initState() {
    super.initState();
    _searchFocus.addListener(_refreshSearchSurface);
  }

  /// 聚焦和失焦同步搜索栏的局部外观。
  void _refreshSearchSurface() {
    if (mounted) setState(() {});
  }

  /// 释放页面独立控制器。
  @override
  void dispose() {
    _searchFocus.removeListener(_refreshSearchSurface);
    _searchFocus.dispose();
    _searchController.dispose();
    _listController.dispose();
    _archiveController.dispose();
    super.dispose();
  }

  /// 是否存在可清除的筛选条件。
  bool get _hasFilters =>
      _searchController.text.isNotEmpty ||
      _kind != null ||
      _startDate != null ||
      _endDate != null;

  /// 同时清除所有列表筛选，不改变上方完整统计。
  void _clearFilters() {
    setState(() {
      _searchController.clear();
      _kind = null;
      _startDate = null;
      _endDate = null;
      _searchCollapsedGroupIds.clear();
    });
  }

  /// 再次选择当前类型可取消类型筛选，恢复全部完成记录。
  void _selectKind(TodoCompletionKind kind) {
    setState(() => _kind = _kind == kind ? null : kind);
  }

  /// 月份、热力图和日期选择器共用一个范围。
  void _selectRange(DateTime? start, DateTime? end) {
    setState(() {
      _startDate = start;
      _endDate = end;
    });
  }

  /// 从未变化的快照复用统计，跨本地午夜重新生成窗口。
  TodoCompletionSummary _readSummary(
    List<TodoCompletionEntry> entries,
    DateTime now,
  ) {
    // 当前本地自然日。
    final DateTime day = DateUtils.dateOnly(now.toLocal());
    if (!identical(_summaryEntries, entries) || _summary?.today != day) {
      _summaryEntries = entries;
      _summary = TodoCompletionSummary(entries: entries, now: now);
    }
    return _summary!;
  }

  /// 一次订阅驱动统计、归档、热力图与所有搜索结果。
  @override
  Widget build(BuildContext context) {
    // 保留刷新中的已有数据，避免列表被加载圈卸载。
    final AsyncValue<List<TodoCompletionEntry>> history = ref.watch(
      todoCompletionEntriesProvider,
    );
    // 页面时间在分钟边界更新，跨午夜时自动换日。
    final DateTime now = ref.watch(nowProvider);
    // 当前流最近一次成功接收的记录。
    final List<TodoCompletionEntry>? entries = history.value;
    if (entries == null) {
      if (history.hasError) {
        return Center(child: _buildReadError());
      }
      return const Center(child: CircularProgressIndicator());
    }
    // 完整历史概览不接受任何列表筛选。
    final TodoCompletionSummary summary = _readSummary(entries, now);
    // 先过滤完成单元，之后才进行同日同任务聚合。
    final List<TodoCompletionGroup> groups = summary.groups(
      keyword: _searchController.text,
      kind: _kind,
      start: _startDate,
      end: _endDate,
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 窄窗口收起左栏，但保留全部筛选能力。
        final bool compact =
            constraints.maxWidth < OmniBreakpoint.compact ||
            MediaQuery.textScalerOf(context).scale(14) > 21;
        // 短窗口和大字号允许概览滚出，以保留正文阅读空间。
        final bool coordinated =
            constraints.maxHeight < 560 ||
            MediaQuery.textScalerOf(context).scale(14) > 21;
        // 顶部热力图独立显示，不使用卡片容器。
        final Widget overview = _buildOverview(summary);
        // 左右两个独立滚动区域。
        final Widget workspace = Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (!compact) ...<Widget>[
              SizedBox(width: 200, child: _buildArchive(summary)),
              const SizedBox(width: OmniSpacing.md),
            ],
            Expanded(
              child: _buildResults(
                summary,
                groups,
                compact: compact,
                coordinated: coordinated,
              ),
            ),
          ],
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (history.hasError) _buildReadError(),
            Expanded(
              child: coordinated
                  ? NestedScrollView(
                      key: const ValueKey<String>(
                        'todo-completion-short-scroll',
                      ),
                      headerSliverBuilder:
                          (BuildContext context, bool scrolled) => <Widget>[
                            SliverToBoxAdapter(child: overview),
                            const SliverToBoxAdapter(
                              child: SizedBox(height: OmniSpacing.md),
                            ),
                          ],
                      body: workspace,
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        overview,
                        const SizedBox(height: OmniSpacing.md),
                        Expanded(child: workspace),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }

  /// 首次失败与已有数据刷新失败都保留明确重试入口。
  Widget _buildReadError() => Padding(
    padding: const EdgeInsets.all(OmniSpacing.xs),
    child: Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: OmniSpacing.xs,
      children: <Widget>[
        const Text('完成历史读取失败'),
        OmniTextButton(
          onPressed: () => ref.invalidate(todoCompletionEntriesProvider),
          child: const Text('重试'),
        ),
      ],
    ),
  );

  /// 全年热力图直接放在页面背景上，保留上下呼吸空间。
  Widget _buildOverview(TodoCompletionSummary summary) => Padding(
    key: const ValueKey<String>('todo-completion-overview'),
    padding: const EdgeInsets.symmetric(vertical: OmniSpacing.xs),
    child: TodoCompletionHeatmap(
      summary: summary,
      selectedDay: _startDate == _endDate ? _startDate : null,
      onDaySelected: (DateTime day) {
        // 与笔记页一致，再次点击已选日期恢复全部时间。
        if (_startDate == day && _endDate == day) {
          _selectRange(null, null);
        } else {
          _selectRange(day, day);
        }
      },
    ),
  );

  /// 沿用笔记侧栏的数字在上、短标签在下及左中右三列对齐。
  Widget _buildStatistics(TodoCompletionSummary summary) => Padding(
    key: const ValueKey<String>('todo-completion-statistics'),
    padding: const EdgeInsets.fromLTRB(
      OmniSpacing.md,
      OmniSpacing.md,
      OmniSpacing.md,
      OmniSpacing.sm,
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final (String, String, int, CrossAxisAlignment) statistic
            in <(String, String, int, CrossAxisAlignment)>[
              ('周', '最近一周', 7, CrossAxisAlignment.start),
              ('月', '最近一个月', 30, CrossAxisAlignment.center),
              ('年', '最近一年', 365, CrossAxisAlignment.end),
            ])
          Expanded(
            // 每个提示保留独立的 Windows 语义锚点，防止三个浮层锚点合并。
            child: OmniWindowsSemanticsBoundary(
              child: Tooltip(
                key: ValueKey<String>(
                  'todo-completion-stat-tip-${statistic.$3}',
                ),
                message: statistic.$2,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: statistic.$4,
                  children: <Widget>[
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        '${summary.countLastDays(statistic.$3)}',
                        key: ValueKey<String>(
                          'todo-completion-stat-${statistic.$3}',
                        ),
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(color: OmniColors.of(context).muted),
                      ),
                    ),
                    const SizedBox(height: OmniSpacing.xxs),
                    Text(
                      statistic.$1,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: OmniColors.of(context).muted),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );

  /// 以独立滚动的窄栏展示类型及按年整理的月份。
  Widget _buildArchive(TodoCompletionSummary summary) => OmniPanel(
    key: const ValueKey<String>('todo-completion-archive'),
    padding: const EdgeInsets.all(OmniSpacing.xs),
    header: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[_buildStatistics(summary), const Divider(height: 1)],
    ),
    child: ListView(
      controller: _archiveController,
      primary: false,
      padding: EdgeInsets.zero,
      children: <Widget>[
        _sectionLabel('任务类型'),
        for (final TodoCompletionKind kind in _taskKinds)
          _archiveChoice(
            key: 'todo-completion-kind-${kind.name}',
            label: _kindLabel(kind),
            selected: _kind == kind,
            onTap: () => _selectKind(kind),
          ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: OmniSpacing.xs),
          child: Divider(height: 1),
        ),
        _sectionLabel('月份归档'),
        _archiveChoice(
          key: 'todo-completion-all-dates',
          label: '全部时间',
          count: summary.entries.length,
          selected: _startDate == null && _endDate == null,
          onTap: () => _selectRange(null, null),
        ),
        for (
          int index = 0;
          index < summary.months.length;
          index += 1
        ) ...<Widget>[
          if (index == 0 ||
              summary.months[index].year != summary.months[index - 1].year)
            _sectionLabel('${summary.months[index].year} 年'),
          _monthChoice(summary, summary.months[index]),
        ],
      ],
    ),
  );

  /// 窄栏标题只表达分区，不添加额外装饰。
  Widget _sectionLabel(String label) => Padding(
    padding: const EdgeInsets.fromLTRB(
      OmniSpacing.xs,
      OmniSpacing.sm,
      OmniSpacing.xs,
      OmniSpacing.xs,
    ),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelMedium
          ?.copyWith(color: OmniColors.of(context).muted),
    ),
  );

  /// 所有月份数量都来自未筛选的完整快照。
  Widget _monthChoice(TodoCompletionSummary summary, DateTime month) {
    // 当月最后一个自然日。
    final DateTime end = DateTime(month.year, month.month + 1, 0);
    return _archiveChoice(
      key: 'todo-completion-month-${DateFormat('yyyy-MM').format(month)}',
      label: '${month.month} 月',
      count: summary.monthCounts[month],
      selected: _startDate == month && _endDate == end,
      onTap: () => _selectRange(month, end),
    );
  }

  /// 统一的类型或归档选择项。
  Widget _archiveChoice({
    required String key,
    required String label,
    required bool selected,
    required VoidCallback onTap,
    int? count,
  }) => OmniListTile(
    key: ValueKey<String>(key),
    dense: true,
    // 与 AI 助手侧栏任务行同为 34dp，大字号允许按内容增高。
    minTileHeight: 34,
    minVerticalPadding: 6,
    contentPadding: const EdgeInsets.symmetric(horizontal: OmniSpacing.xs),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(OmniRadius.control),
    ),
    selected: selected,
    selectedTileColor: OmniColors.of(context).brandSoft,
    selectedColor: OmniColors.of(context).brandStrong,
    title: Text(label),
    trailing: count == null
        ? (selected ? const Icon(Icons.check_rounded, size: 15) : null)
        : Text('$count', style: Theme.of(context).textTheme.labelMedium),
    onTap: onTap,
  );

  /// 普通高度固定检索栏，短窗口将检索栏与惰性明细一同滚动。
  Widget _buildResults(
    TodoCompletionSummary summary,
    List<TodoCompletionGroup> groups, {
    required bool compact,
    required bool coordinated,
  }) {
    // 筛选后完成单元数量，不能使用折叠组数代替。
    final int count = groups.fold<int>(
      0,
      (int sum, TodoCompletionGroup group) => sum + group.entries.length,
    );
    // 当前结果按完成日汇总的数量。
    final Map<DateTime, int> dayCounts = <DateTime, int>{};
    for (final TodoCompletionGroup group in groups) {
      dayCounts.update(
        group.day,
        (int value) => value + group.entries.length,
        ifAbsent: () => group.entries.length,
      );
    }
    // 展开时只创建轻量行描述，避免同一组一次布局全部步骤。
    final List<_CompletionResultRow> rows = _resultRows(groups, dayCounts);
    // 两种高度布局共用相同的检索与计数内容。
    final Widget header = _buildResultsHeader(summary, count, compact: compact);
    // 明细两侧和底部沿用原有面板留白。
    const EdgeInsets listPadding = EdgeInsets.fromLTRB(
      OmniSpacing.sm,
      0,
      OmniSpacing.sm,
      OmniSpacing.sm,
    );
    return OmniPanel(
      padding: EdgeInsets.zero,
      child: coordinated
          ? CustomScrollView(
              key: const PageStorageKey<String>('todo-completion-results'),
              primary: true,
              slivers: <Widget>[
                SliverToBoxAdapter(child: header),
                if (rows.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _buildEmptyResults(),
                  )
                else
                  SliverPadding(
                    padding: listPadding,
                    sliver: SliverMainAxisGroup(
                      slivers: _buildResultSlivers(rows, summary),
                    ),
                  ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                header,
                Expanded(
                  child: rows.isEmpty
                      ? _buildEmptyResults()
                      : CustomScrollView(
                          key: const PageStorageKey<String>(
                            'todo-completion-results',
                          ),
                          controller: _listController,
                          primary: false,
                          slivers: <Widget>[
                            SliverPadding(
                              padding: listPadding,
                              sliver: SliverMainAxisGroup(
                                slivers: _buildResultSlivers(rows, summary),
                              ),
                            ),
                          ],
                        ),
                ),
              ],
            ),
    );
  }

  /// 两种窗口布局使用同一检索工具栏与结果数量。
  Widget _buildResultsHeader(
    TodoCompletionSummary summary,
    int count, {
    required bool compact,
  }) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      // 窄窗收起左栏后，统计移入下方结果卡片，仍可直接查看。
      if (compact) ...<Widget>[
        _buildStatistics(summary),
        const Divider(height: 1),
      ],
      Padding(
        padding: const EdgeInsets.all(OmniSpacing.sm),
        child: _buildSearch(summary, count, compact: compact),
      ),
      const Divider(height: 1),
    ],
  );

  /// 空结果仍区分没有历史和筛选后没有匹配。
  Widget _buildEmptyResults() => Center(
    child: Padding(
      padding: const EdgeInsets.all(OmniSpacing.md),
      child: Text(
        _hasFilters ? '没有匹配的完成记录' : '还没有完成记录',
        key: const ValueKey<String>('todo-completion-empty'),
        textAlign: TextAlign.center,
        style: TextStyle(color: OmniColors.of(context).muted),
      ),
    ),
  );

  /// 将日期、分组标题与可见明细展开为独立的轻量行描述。
  List<_CompletionResultRow> _resultRows(
    List<TodoCompletionGroup> groups,
    Map<DateTime, int> dayCounts,
  ) {
    // 只有展开分组才加入其明细描述，组件始终由列表按需创建。
    final List<_CompletionResultRow> rows = <_CompletionResultRow>[];
    // 上一个分组的完成日，用于每个日期只插入一次标题。
    DateTime? previousDay;
    for (final TodoCompletionGroup group in groups) {
      // 只在同日相邻任务之间增加紧凑间距，跨日交给日期标题区分。
      final bool sameDay = previousDay == group.day;
      if (!sameDay) {
        rows.add(
          _CompletionResultRow(
            kind: _CompletionResultRowKind.day,
            group: group,
            dayCount: dayCounts[group.day],
            topSpacing: previousDay == null ? OmniSpacing.sm : OmniSpacing.md,
          ),
        );
        previousDay = group.day;
      }
      if (group.expandable) {
        rows.add(
          _CompletionResultRow(
            kind: _CompletionResultRowKind.group,
            group: group,
            topSpacing: sameDay ? OmniSpacing.xxs : 0,
          ),
        );
      }
      if (group.expandable) {
        rows.add(
          _CompletionResultRow(
            kind: _CompletionResultRowKind.details,
            group: group,
          ),
        );
      } else {
        for (final TodoCompletionEntry entry in group.entries) {
          rows.add(
            _CompletionResultRow(
              kind: _CompletionResultRowKind.entry,
              group: group,
              entry: entry,
              topSpacing:
                  !group.expandable && sameDay && entry == group.entries.first
                  ? OmniSpacing.xxs
                  : 0,
            ),
          );
        }
      }
    }
    return rows;
  }

  /// 仅为视口附近的描述创建真实组件，并保留旧操作入口身份。
  Widget _buildResultRow(
    _CompletionResultRow row,
    TodoCompletionSummary summary,
  ) => KeyedSubtree(
    key: row.key,
    child: Padding(
      padding: EdgeInsets.only(top: row.topSpacing),
      child: switch (row.kind) {
        _CompletionResultRowKind.day => Padding(
          padding: const EdgeInsets.fromLTRB(
            OmniSpacing.xxs,
            0,
            OmniSpacing.xxs,
            OmniSpacing.xxs,
          ),
          child: Text(
            '${_dayLabel(row.group.day, summary.today)}'
            ' · 完成 ${row.dayCount} 项',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: OmniColors.of(context).muted,
              fontWeight: FontWeight.w400,
            ),
          ),
        ),
        _CompletionResultRowKind.group => _buildGroup(row.group),
        _CompletionResultRowKind.details => const SizedBox.shrink(),
        _CompletionResultRowKind.entry => Padding(
          key: row.group.expandable && row.entry == row.group.entries.first
              ? ValueKey<String>('todo-completion-details-${row.group.id}')
              : null,
          padding: EdgeInsets.only(
            left: row.group.expandable ? OmniSpacing.xl : 0,
          ),
          child: _buildEntry(row.entry!),
        ),
      },
    ),
  );

  /// 普通行连续惰性构建，子项以整组裁剪展开，避免首帧创建千行零高度内容。
  List<Widget> _buildResultSlivers(
    List<_CompletionResultRow> rows,
    TodoCompletionSummary summary,
  ) {
    // 所有 Sliver 只持有轻量描述，具体按钮仍进入视口时才创建。
    final List<Widget> slivers = <Widget>[];
    // 相邻的日期、分组标题和独立完成项共用一个惰性列表。
    List<_CompletionResultRow> chunk = <_CompletionResultRow>[];
    // 固定当前描述集合，避免闭包捕获后续修改后的列表。
    void flush() {
      if (chunk.isEmpty) return;
      // 本段固定的行集合。
      final List<_CompletionResultRow> items = chunk;
      // 稳定行键保证更新时不复用其他记录的状态。
      final Map<Key, int> indices = <Key, int>{
        for (int index = 0; index < items.length; index++)
          items[index].key: index,
      };
      slivers.add(
        SliverList.builder(
          key: ValueKey<String>('completion-chunk-${items.first.key.value}'),
          itemCount: items.length,
          findChildIndexCallback: (key) => indices[key],
          itemBuilder: (context, index) =>
              _buildResultRow(items[index], summary),
        ),
      );
      chunk = <_CompletionResultRow>[];
    }

    for (final _CompletionResultRow row in rows) {
      if (row.kind != _CompletionResultRowKind.details) {
        chunk.add(row);
        continue;
      }
      flush();
      // 分组内仍按真实完成单元跟踪身份，后台刷新不复用其他行的状态。
      final Map<Key, int> entryIndices = <Key, int>{
        for (int index = 0; index < row.group.entries.length; index++)
          ValueKey<String>(
            'todo-completion-row-entry-${row.group.entries[index].id}',
          ): index,
      };
      slivers.add(
        OmniDisclosure.sliver(
          key: row.key,
          expanded: _isGroupExpanded(row.group),
          child: SliverPadding(
            padding: const EdgeInsets.only(left: OmniSpacing.xl),
            sliver: SliverList.builder(
              itemCount: row.group.entries.length,
              findChildIndexCallback: (key) => entryIndices[key],
              itemBuilder: (context, index) => KeyedSubtree(
                key: ValueKey<String>(
                  'todo-completion-row-entry-${row.group.entries[index].id}',
                ),
                child: Padding(
                  key: index == 0
                      ? ValueKey<String>(
                          'todo-completion-details-${row.group.id}',
                        )
                      : null,
                  padding: EdgeInsets.zero,
                  child: _buildEntry(row.group.entries[index]),
                ),
              ),
            ),
          ),
        ),
      );
    }
    flush();
    return slivers;
  }

  /// 搜索右侧筛选图标沿用笔记页菜单，日期变化仍即时作用于历史。
  Future<void> _openSearchFilters(
    TodoCompletionSummary summary, {
    required bool compact,
  }) async {
    if (_searchFilterOpen) return;
    setState(() => _searchFilterOpen = true);
    _searchFocus.unfocus();
    try {
      await showTodoCompletionSearchFilter(
        context: context,
        anchorKey: _searchAnchor,
        today: summary.today,
        firstDate:
            summary.months.isNotEmpty &&
                summary.months.last.isBefore(DateTime(2000))
            ? summary.months.last
            : DateTime(2000),
        start: _startDate,
        end: _endDate,
        onRangeChanged: _selectRange,
        onClear: _clearFilters,
        compactFilters: compact ? _buildCompactFilters(summary) : null,
      );
    } finally {
      if (mounted) setState(() => _searchFilterOpen = false);
    }
  }

  /// 笔记同款灰底搜索表面内整合数量及筛选入口，避免窄窗工具换行。
  Widget _buildSearch(
    TodoCompletionSummary summary,
    int count, {
    required bool compact,
  }) {
    // 搜索表面和提示文字复用当前明暗主题的语义色。
    final OmniColors colors = OmniColors.of(context);
    // 输入聚焦或菜单打开期间显示中性细边框。
    final bool focused = _searchFocus.hasFocus;
    // 与笔记栏同为常规43.2dp，大字号增加必要高度。
    final double height =
        43.2 + (MediaQuery.textScalerOf(context).scale(14) - 14).clamp(0, 40);
    return KeyedSubtree(
      key: _searchAnchor,
      child: MouseRegion(
        onEnter: (_) => setState(() => _searchHovered = true),
        onExit: (_) => setState(() => _searchHovered = false),
        child: AnimatedContainer(
          key: const ValueKey<String>('todo-completion-search-surface'),
          height: height,
          duration: OmniMotion.duration(context, OmniMotion.fast),
          decoration: BoxDecoration(
            color: focused ? colors.paper : colors.mist,
            borderRadius: BorderRadius.circular(OmniRadius.panel),
            border: Border.all(
              color: focused || _searchHovered || _searchFilterOpen
                  ? colors.line
                  : colors.line.withValues(alpha: 0),
            ),
          ),
          child: TextFieldTapRegion(
            child: Row(
              children: <Widget>[
                const SizedBox(width: OmniSpacing.sm),
                Icon(Icons.search, size: OmniSize.icon, color: colors.muted),
                const SizedBox(width: OmniSpacing.xs),
                Expanded(
                  child: OmniTextField(
                    key: const ValueKey<String>('todo-completion-search'),
                    controller: _searchController,
                    focusNode: _searchFocus,
                    textAlignVertical: TextAlignVertical.center,
                    decoration: InputDecoration(
                      hintText: '搜索任务、子任务或章节',
                      filled: false,
                      isDense: true,
                      isCollapsed: true,
                      // 外层已控制高度，避免桌面紧凑密度再次下移文字基线。
                      visualDensity: VisualDensity.standard,
                      contentPadding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      hoverColor: Colors.transparent,
                      // 常驻尾部数量不因输入焦点和筛选面板的切换隐藏。
                      suffixIcon: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: OmniSpacing.xs,
                        ),
                        child: Center(
                          widthFactor: 1,
                          heightFactor: 1,
                          child: Text(
                            '$count 项',
                            key: const ValueKey<String>(
                              'todo-completion-results-count',
                            ),
                            semanticsLabel: '完成记录，共 $count 项',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: colors.muted),
                          ),
                        ),
                      ),
                      suffixIconConstraints: const BoxConstraints(),
                    ),
                    onTapOutside: (_) => _searchFocus.unfocus(),
                    onChanged: (String value) =>
                        setState(() => _searchCollapsedGroupIds.clear()),
                  ),
                ),
                OmniIconButton(
                  key: const ValueKey<String>('todo-completion-search-filter'),
                  tooltip: '筛选完成记录',
                  icon: const Icon(Icons.filter_list),
                  isSelected: _searchFilterOpen || _hasFilters,
                  color: _hasFilters ? colors.ink : null,
                  onPressed: () =>
                      _openSearchFilters(summary, compact: compact),
                ),
                const SizedBox(width: OmniSpacing.xxs),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 小窗口通过同一个菜单访问全部类型和月份。
  Widget _buildCompactFilters(TodoCompletionSummary summary) =>
      OmniPopupMenuButton<String>(
        key: const ValueKey<String>('todo-completion-compact-filters'),
        tooltip: '任务类型与月份',
        icon: const Icon(Icons.filter_alt_outlined, size: 18),
        onSelected: (String value) {
          if (value == 'dates-all') {
            _selectRange(null, null);
          } else if (value.startsWith('month-')) {
            // 从明确的年月选择构造完整月份范围。
            final DateTime month = DateTime.parse('${value.substring(6)}-01');
            _selectRange(month, DateTime(month.year, month.month + 1, 0));
          } else {
            _selectKind(TodoCompletionKind.values.byName(value));
          }
        },
        itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
          OmniPopupMenuItem<String>(
            value: 'type-label',
            label: '任务类型',
            icon: null,
            enabled: false,
          ),
          for (final TodoCompletionKind kind in _taskKinds)
            OmniPopupMenuItem<String>(
              value: kind.name,
              icon: _kind == kind ? Icons.check_rounded : null,
              label: _kindLabel(kind),
            ),
          const PopupMenuDivider(),
          OmniPopupMenuItem<String>(
            value: 'dates-all',
            label: '全部时间',
            icon: null,
          ),
          for (final DateTime month in summary.months)
            OmniPopupMenuItem<String>(
              value: 'month-${DateFormat('yyyy-MM').format(month)}',
              icon: null,
              label:
                  '${DateFormat('yyyy 年 M 月').format(month)}'
                  ' · ${summary.monthCounts[month]} 项',
            ),
        ],
      );

  /// 搜索自动展开匹配分组，同时尊重两种模式下的手动展开偏好。
  bool _isGroupExpanded(TodoCompletionGroup group) =>
      _searchController.text.trim().isNotEmpty
      ? !_searchCollapsedGroupIds.contains(group.id)
      : _expandedGroupIds.contains(group.id);

  /// 分组标题只切换展开，实际明细交给外层列表逐行创建。
  Widget _buildGroup(TodoCompletionGroup group) {
    // 标题图标与扁平明细行共享同一展开判断。
    final bool expanded = _isGroupExpanded(group);
    // 只切换明细，不执行父任务的完成或撤销。
    void toggle() {
      setState(() {
        if (_searchController.text.trim().isNotEmpty) {
          if (expanded) {
            _searchCollapsedGroupIds.add(group.id);
          } else {
            _searchCollapsedGroupIds.remove(group.id);
          }
        } else if (expanded) {
          _expandedGroupIds.remove(group.id);
        } else {
          _expandedGroupIds.add(group.id);
        }
      });
    }

    return KeyedSubtree(
      key: ValueKey<String>('todo-completion-group-${group.id}'),
      child: OmniDisclosureToggle(
        expanded: expanded,
        child: OmniListTile(
          key: ValueKey<String>('todo-completion-toggle-${group.id}'),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: OmniSpacing.xxs,
          ),
          leading: Icon(
            expanded ? Icons.expand_more_rounded : Icons.chevron_right_rounded,
            size: 20,
          ),
          horizontalTitleGap: OmniSpacing.xs,
          minLeadingWidth: 20,
          title: Text(group.root.title),
          subtitle: Text(
            '完成 ${group.entries.length} 项 · '
            '${DateFormat('HH:mm').format(group.latestCompletedAt.toLocal())}',
          ),
          trailing: group.root.taskType == 'progress'
              ? OmniIconButton(
                  tooltip: '查看进度',
                  icon: const Icon(Icons.segment_rounded, size: 18),
                  onPressed: () =>
                      TodoProgressPanel.show(context, record: group.root),
                )
              : null,
          onTap: toggle,
        ),
      ),
    );
  }

  /// 每条操作绑定实际完成单元，避免错误修改所属父任务。
  Widget _buildEntry(TodoCompletionEntry entry) => Padding(
    key: ValueKey<String>('todo-completion-entry-${entry.id}'),
    padding: const EdgeInsets.symmetric(vertical: OmniSpacing.xxs),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        if (entry.kind == TodoCompletionKind.progress)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.xs),
            child: Icon(
              Icons.check_rounded,
              size: 18,
              color: OmniColors.of(context).brand,
            ),
          )
        else
          TodoCompletionCheckbox(
            value: true,
            semanticLabel: '重新打开${entry.title}',
            onChanged: (bool value) {
              if (!value) widget.onReopen(entry.todo);
            },
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: OmniSpacing.xs),
            child: Text(entry.title),
          ),
        ),
        const SizedBox(width: OmniSpacing.xs),
        Tooltip(
          message: DateFormat('yyyy-MM-dd HH:mm:ss')
              .format(entry.completedAt.toLocal()),
          child: Text(
            DateFormat('HH:mm').format(entry.completedAt.toLocal()),
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: OmniColors.of(context).muted),
          ),
        ),
        OmniIconButton(
          tooltip: entry.kind == TodoCompletionKind.progress ? '查看进度' : '编辑',
          icon: Icon(
            entry.kind == TodoCompletionKind.progress
                ? Icons.segment_rounded
                : Icons.edit_outlined,
            size: 17,
          ),
          onPressed: () {
            if (entry.kind == TodoCompletionKind.progress) {
              TodoProgressPanel.show(context, record: entry.todo);
            } else {
              widget.onEdit(entry.todo);
            }
          },
        ),
      ],
    ),
  );

  /// 任务类型使用固定、可理解的业务名称。
  String _kindLabel(TodoCompletionKind kind) =>
      kind == TodoCompletionKind.progress ? '进度任务' : '普通任务';

  /// 完成日优先显示今天、昨天，其他日期保留年份。
  String _dayLabel(DateTime day, DateTime today) {
    if (day == today) return '今天';
    if (day == completionDayOffset(today, -1)) return '昨天';
    return DateFormat('yyyy 年 M 月 d 日').format(day);
  }
}
