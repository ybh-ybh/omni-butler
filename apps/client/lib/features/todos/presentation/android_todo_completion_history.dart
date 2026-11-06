import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/todos/data/todo_completion_entry.dart';
import 'package:omni_butler/features/todos/data/todo_completion_summary.dart';
import 'package:omni_butler/features/todos/presentation/android_todo_completion_filter.dart';
import 'package:omni_butler/features/todos/presentation/android_todo_completion_sidebar.dart';
import 'package:omni_butler/features/todos/presentation/todo_progress_panel.dart';
import 'package:omni_butler/shared/layout/android_sidebar_swipe_target.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

part 'android_todo_completion_results.dart';

/// Browses complete history while keeping search in its own route and state.
class AndroidTodoCompletionHistory extends ConsumerStatefulWidget {
  /// Returns to the still-mounted task dashboard.
  final VoidCallback onBack;

  /// Edits only the concrete completed task selected by the user.
  final ValueChanged<TodoRecord> onEdit;

  /// Reopens only the selected task, never its containing group.
  final ValueChanged<TodoRecord> onReopen;

  /// Distinguishes a temporary search session from the main history.
  final bool _searchMode;

  /// Copies the browsing scope when entering search.
  final AndroidTodoCompletionFilter _initialFilter;

  /// Creates an unfiltered, cross-date history workspace.
  const AndroidTodoCompletionHistory({
    required this.onBack,
    required this.onEdit,
    required this.onReopen,
    super.key,
  }) : _searchMode = false,
       _initialFilter = const AndroidTodoCompletionFilter();

  /// Creates an isolated query without modifying the browsing page.
  const AndroidTodoCompletionHistory._search({
    required this.onBack,
    required this.onEdit,
    required this.onReopen,
    required this._initialFilter,
  }) : _searchMode = true;

  /// Owns the local query, scrolling and expansion preferences.
  @override
  ConsumerState<AndroidTodoCompletionHistory> createState() =>
      _AndroidTodoCompletionHistoryState();
}

/// Preserves readable cached data through refreshes and transient errors.
class _AndroidTodoCompletionHistoryState
    extends ConsumerState<AndroidTodoCompletionHistory> {
  /// Applied scope is replaced only after an explicit selection or apply.
  late AndroidTodoCompletionFilter _filter;

  /// Text input belongs exclusively to this route.
  final TextEditingController _query = TextEditingController();

  /// Search is not focused automatically on entry.
  final FocusNode _searchFocus = FocusNode();

  /// Scroll position remains stable while dialogs or search cover the page.
  final ScrollController _scroll = ScrollController();

  /// Overlay guards prevent repeated pushes and stale swipe callbacks.
  bool _surfaceOpen = false;

  /// A successful snapshot remains readable during provider errors.
  List<TodoCompletionEntry>? _cachedEntries;

  /// Summary recomputation is limited to new data and local date changes.
  TodoCompletionSummary? _summary;

  /// Prevents cached records and actions from crossing database identities.
  late final AppDatabase _source;

  /// Schedules source invalidation only once while routes are closing.
  bool _leaving = false;

  /// Initializes the route's independent applied scope.
  @override
  void initState() {
    super.initState();
    _filter = widget._initialFilter;
    _source = ref.read(appDatabaseProvider);
  }

  /// Guards delayed callbacks even before a source-change rebuild occurs.
  bool get _sameSource =>
      mounted && identical(ref.read(appDatabaseProvider), _source);

  /// Edits only records belonging to the still-active source.
  void _editRecord(TodoRecord record) {
    if (_sameSource) widget.onEdit(record);
  }

  /// Reopens only records belonging to the still-active source.
  void _reopenRecord(TodoRecord record) {
    if (_sameSource) widget.onReopen(record);
  }

  /// Opens progress only while the selected record still belongs to this source.
  void _viewProgress(TodoRecord record) {
    if (_sameSource) TodoProgressPanel.show(context, record: record);
  }

  /// Releases only resources owned by this route.
  @override
  void dispose() {
    _query.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Reuses the complete-data summary without mixing in result filters.
  TodoCompletionSummary? _readSummary(
    AsyncValue<List<TodoCompletionEntry>> history,
    DateTime now,
  ) {
    // Provider refreshes may temporarily omit their previous value.
    final List<TodoCompletionEntry>? entries = history.value ?? _cachedEntries;
    if (entries == null) return null;
    if (!identical(entries, _cachedEntries) ||
        _summary?.today != DateUtils.dateOnly(now.toLocal())) {
      _cachedEntries = entries;
      _summary = TodoCompletionSummary(entries: entries, now: now);
    }
    return _summary;
  }

  /// New scopes start at the first result without resetting unrelated state.
  void _applyFilter(AndroidTodoCompletionFilter filter) {
    setState(() => _filter = filter);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  /// Clears all query conditions from an empty-result action.
  void _clearFilters() {
    _query.clear();
    _applyFilter(const AndroidTodoCompletionFilter());
  }

  /// Opens either the browsing archive or the search draft filter sheet.
  Future<void> _openFilters({bool sidebar = false}) async {
    if (_surfaceOpen || !_sameSource) return;
    _searchFocus.unfocus();
    setState(() => _surfaceOpen = true);
    try {
      // Dismissal returns null and leaves the applied scope unchanged.
      final AndroidTodoCompletionFilter? result = sidebar
          ? await showAndroidTodoCompletionSidebar(context, initial: _filter)
          : await showAndroidTodoCompletionFilter(context, initial: _filter);
      if (_sameSource && result != null) _applyFilter(result);
    } finally {
      if (mounted) setState(() => _surfaceOpen = false);
    }
  }

  /// Pushes a full-screen query while preserving the complete browsing tree.
  Future<void> _openSearch() async {
    if (_surfaceOpen || !_sameSource) return;
    setState(() => _surfaceOpen = true);
    try {
      await Navigator.of(context, rootNavigator: true).push<void>(
        MaterialPageRoute<void>(
          builder: (BuildContext routeContext) => Scaffold(
            backgroundColor: OmniColors.of(routeContext).canvas,
            body: SafeArea(
              child: AndroidTodoCompletionHistory._search(
                initialFilter: _filter,
                onBack: () => Navigator.of(routeContext).pop(),
                onEdit: _editRecord,
                onReopen: _reopenRecord,
              ),
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _surfaceOpen = false);
    }
  }

  /// Closes input before leaving the current route.
  void _back() {
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      _searchFocus.unfocus();
      return;
    }
    widget.onBack();
  }

  /// Provides the same width and typography on phones and larger screens.
  @override
  Widget build(BuildContext context) {
    // A closed or replaced database invalidates every nested history surface.
    final bool sameSource = identical(ref.watch(appDatabaseProvider), _source);
    if (!sameSource) {
      _cachedEntries = null;
      _summary = null;
      if (!_leaving) {
        _leaving = true;
        WidgetsBinding.instance.addPostFrameCallback((Duration timestamp) {
          if (!mounted) return;
          // Another owning route may already have removed this route.
          final ModalRoute<Object?>? own = ModalRoute.of(context);
          if (own == null || !own.isActive) return;
          Navigator.of(context)
              .popUntil((Route<dynamic> route) => identical(route, own));
          if (own.isFirst) return;
          Navigator.of(context).pop();
        });
      }
      return const SizedBox.expand();
    }
    // Full history drives all scopes and statistics.
    final AsyncValue<List<TodoCompletionEntry>> history = ref.watch(
      todoCompletionEntriesProvider,
    );
    // Local midnight updates rolling totals even without record mutations.
    final DateTime now = ref.watch(nowProvider);
    // The last successful snapshot is kept during background reloads.
    final TodoCompletionSummary? summary = _readSummary(history, now);
    // Filtering before grouping keeps counts and matching details consistent.
    final List<TodoCompletionGroup> groups =
        summary?.groups(
          keyword: _query.text,
          kind: _filter.kind,
          start: _filter.startDate,
          end: _filter.endDate,
        ) ??
        <TodoCompletionGroup>[];
    // Counts represent completed units, not parent cards.
    final int resultCount = groups.fold<int>(
      0,
      (int total, TodoCompletionGroup group) => total + group.entries.length,
    );
    // Theme tokens preserve every existing palette and dark mode.
    final OmniColors colors = OmniColors.of(context);
    return PopScope<void>(
      canPop: MediaQuery.viewInsetsOf(context).bottom == 0,
      onPopInvokedWithResult: (bool didPop, void result) {
        if (!didPop) _searchFocus.unfocus();
      },
      child: Material(
        key: ValueKey<String>(
          widget._searchMode
              ? 'android-completion-search'
              : 'android-completion-history',
        ),
        color: colors.canvas,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _buildHeader(context),
                Expanded(
                  child: AndroidSidebarSwipeTarget(
                    sidebarWidth: math.min(
                      MediaQuery.sizeOf(context).width * .82,
                      360,
                    ),
                    enabled: !widget._searchMode && !_surfaceOpen,
                    onOpen: () => _openFilters(sidebar: true),
                    child: summary == null
                        ? history.hasError
                              ? SingleChildScrollView(
                                  child: _buildReadError(context),
                                )
                              : _buildSkeleton(context)
                        : _AndroidCompletionResults(
                            header: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                if (_filter.hasFilters) _buildScope(context),
                                if (widget._searchMode)
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      16,
                                      0,
                                      16,
                                      8,
                                    ),
                                    child: Text(
                                      '$resultCount 项',
                                      key: const ValueKey<String>(
                                        'android-completion-count',
                                      ),
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(color: colors.muted),
                                    ),
                                  ),
                                if (history.hasError) _buildReadError(context),
                              ],
                            ),
                            groups: groups,
                            controller: _scroll,
                            query: _query.text.trim(),
                            filtered:
                                _filter.hasFilters ||
                                _query.text.trim().isNotEmpty,
                            onClear: _clearFilters,
                            onEdit: _editRecord,
                            onReopen: _reopenRecord,
                            onProgress: _viewProgress,
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Leaves the browsing title uncluttered and gives search its own input.
  Widget _buildHeader(BuildContext context) {
    if (widget._searchMode) {
      return Padding(
        padding: const EdgeInsets.all(OmniSpacing.md),
        child: Row(
          children: <Widget>[
            Expanded(
              child: OmniTextField(
                key: const ValueKey<String>('android-completion-query'),
                controller: _query,
                focusNode: _searchFocus,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: '搜索完成记录',
                  suffixIcon: OmniIconButton(
                    key: const ValueKey<String>(
                      'android-completion-filter-open',
                    ),
                    tooltip: '筛选完成记录',
                    icon: const Icon(Icons.filter_list_rounded),
                    color: _filter.hasFilters
                        ? OmniColors.of(context).brand
                        : null,
                    onPressed: () => _openFilters(),
                  ),
                ),
                onChanged: (String value) {
                  setState(() {});
                  if (_scroll.hasClients) _scroll.jumpTo(0);
                },
                onSubmitted: (String value) => _searchFocus.unfocus(),
              ),
            ),
            OmniButton(
              key: const ValueKey<String>('android-completion-search-cancel'),
              label: '取消',
              variant: OmniButtonVariant.text,
              onPressed: widget.onBack,
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Row(
        children: <Widget>[
          KeyedSubtree(
            key: const ValueKey<String>('todo-mobile-history-back'),
            child: OmniIconButton(
              key: const ValueKey<String>('android-completion-back'),
              tooltip: '返回进行中待办',
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: _back,
            ),
          ),
          Expanded(
            child: Text('完成历史', style: Theme.of(context).textTheme.titleLarge),
          ),
          OmniIconButton(
            key: const ValueKey<String>('android-completion-sidebar-open'),
            tooltip: '完成概览与归档',
            icon: const Icon(Icons.menu_rounded),
            onPressed: () => _openFilters(sidebar: true),
          ),
          OmniIconButton(
            key: const ValueKey<String>('android-completion-search-open'),
            tooltip: '搜索完成记录',
            icon: const Icon(Icons.search_rounded),
            onPressed: _openSearch,
          ),
        ],
      ),
    );
  }

  /// Shows only active conditions, with separate accessible clear actions.
  Widget _buildScope(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: Wrap(
      spacing: OmniSpacing.xs,
      runSpacing: OmniSpacing.xxs,
      children: <Widget>[
        if (_filter.kind != null)
          OmniButton(
            key: const ValueKey<String>('android-completion-clear-kind'),
            label:
                '${_filter.kind == TodoCompletionKind.progress ? '进度任务' : '普通任务'} ×',
            variant: OmniButtonVariant.secondary,
            onPressed: () => _applyFilter(
              AndroidTodoCompletionFilter(
                startDate: _filter.startDate,
                endDate: _filter.endDate,
              ),
            ),
          ),
        if (_filter.dateLabel != null)
          OmniButton(
            key: const ValueKey<String>('android-completion-clear-date'),
            label: '${_filter.dateLabel} ×',
            variant: OmniButtonVariant.secondary,
            onPressed: () =>
                _applyFilter(AndroidTodoCompletionFilter(kind: _filter.kind)),
          ),
      ],
    ),
  );

  /// Reports read errors without discarding the last successful results.
  Widget _buildReadError(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Wrap(
      spacing: OmniSpacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        const Text('完成历史读取失败'),
        OmniButton(
          label: '重试',
          variant: OmniButtonVariant.text,
          onPressed: () => ref.invalidate(todoCompletionEntriesProvider),
        ),
      ],
    ),
  );

  /// Static skeletons respect reduced motion and work in short viewports.
  Widget _buildSkeleton(BuildContext context) => Semantics(
    label: '正在读取完成历史',
    child: ListView.builder(
      key: const ValueKey<String>('android-completion-loading'),
      padding: const EdgeInsets.all(16),
      itemCount: 5,
      itemBuilder: (BuildContext context, int index) => Container(
        height: 80,
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: OmniColors.of(context).paper,
          borderRadius: BorderRadius.circular(OmniRadius.panel),
        ),
        padding: const EdgeInsets.all(16),
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: .6,
          child: ColoredBox(
            color: OmniColors.of(context).mist,
            child: const SizedBox(height: 12),
          ),
        ),
      ),
    ),
  );
}
