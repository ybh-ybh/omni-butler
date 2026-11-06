part of 'android_todo_completion_history.dart';

/// Renders lazy date headings, card headers and individually lazy details.
class _AndroidCompletionResults extends StatefulWidget {
  /// Conditions and read errors scroll without displacing the fixed search bar.
  final Widget header;

  /// Filtered groups retain the shared business ordering.
  final List<TodoCompletionGroup> groups;

  /// The parent route owns its independent scroll position.
  final ScrollController controller;

  /// Nonempty searches expand matches unless manually collapsed.
  final String query;

  /// Distinguishes a fresh empty history from an empty result scope.
  final bool filtered;

  /// Removes applied conditions from an empty result view.
  final VoidCallback onClear;

  /// Dispatches editing for a concrete completed task.
  final ValueChanged<TodoRecord> onEdit;

  /// Dispatches reopening for a concrete completed task.
  final ValueChanged<TodoRecord> onReopen;

  /// Lets the owning route validate source identity before opening progress.
  final ValueChanged<TodoRecord> onProgress;

  /// Keeps visual concerns independent of provider and route ownership.
  const _AndroidCompletionResults({
    required this.header,
    required this.groups,
    required this.controller,
    required this.query,
    required this.filtered,
    required this.onClear,
    required this.onEdit,
    required this.onReopen,
    required this.onProgress,
  });

  /// Stores expansion preferences by stable day and root identity.
  @override
  State<_AndroidCompletionResults> createState() =>
      _AndroidCompletionResultsState();
}

/// Carries only lightweight row metadata until it enters the viewport.
class _AndroidCompletionRow {
  /// Identifies the task whose context belongs to the row.
  final TodoCompletionGroup group;

  /// A nonnull count makes this row a date heading.
  final int? dayCount;

  /// Creates a date heading or a card header descriptor.
  const _AndroidCompletionRow(this.group, {this.dayCount});

  /// Stable keys preserve row identity during background updates.
  Key get key => ValueKey<String>(
    dayCount == null
        ? 'android-completion-group-${group.id}'
        : 'android-completion-day-${businessDayKey(group.day)}',
  );
}

/// Reuses shared disclosure animation without eagerly laying out long groups.
class _AndroidCompletionResultsState extends State<_AndroidCompletionResults> {
  /// Normal browsing expansion preferences survive filters and overlays.
  final Set<String> _expanded = <String>{};

  /// Search expansion can be overridden for each matched group.
  final Set<String> _searchCollapsed = <String>{};

  /// A changed query exposes its new matches again.
  @override
  void didUpdateWidget(_AndroidCompletionResults oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query) _searchCollapsed.clear();
  }

  /// Uses separate manual preferences for browsing and searching.
  bool _isExpanded(TodoCompletionGroup group) => widget.query.isNotEmpty
      ? !_searchCollapsed.contains(group.id)
      : _expanded.contains(group.id);

  /// Changes disclosure state without mutating the underlying task.
  void _toggle(TodoCompletionGroup group) => setState(() {
    if (widget.query.isNotEmpty) {
      if (!_searchCollapsed.add(group.id)) _searchCollapsed.remove(group.id);
    } else if (!_expanded.add(group.id)) {
      _expanded.remove(group.id);
    }
  });

  /// Builds rows lazily, including very large expanded progress tasks.
  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      key: const ValueKey<String>('android-completion-list'),
      controller: widget.controller,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: <Widget>[
        SliverToBoxAdapter(child: widget.header),
        if (widget.groups.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(widget.filtered ? '没有符合条件的记录' : '还没有完成记录'),
                    if (widget.filtered)
                      OmniButton(
                        key: const ValueKey<String>(
                          'android-completion-clear-filters',
                        ),
                        label: '清除条件',
                        variant: OmniButtonVariant.text,
                        onPressed: widget.onClear,
                      ),
                  ],
                ),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            sliver: SliverMainAxisGroup(slivers: _buildSlivers()),
          ),
      ],
    );
  }

  /// Batches adjacent headers while giving each disclosure a lazy sliver.
  List<Widget> _buildSlivers() {
    // Day totals use only filtered completed units.
    final Map<DateTime, int> counts = <DateTime, int>{};
    for (final TodoCompletionGroup group in widget.groups) {
      counts.update(
        group.day,
        (int value) => value + group.entries.length,
        ifAbsent: () => group.entries.length,
      );
    }
    // Lightweight sliver descriptors do not create offscreen row widgets.
    final List<Widget> slivers = <Widget>[];
    // Consecutive date headings and card headers share a single lazy list.
    List<_AndroidCompletionRow> chunk = <_AndroidCompletionRow>[];
    // Tracks the date heading already emitted.
    DateTime? previousDay;

    /// Captures an immutable batch before starting another disclosure.
    void flush() {
      if (chunk.isEmpty) return;
      // Capture this batch rather than the reassigned outer collection.
      final List<_AndroidCompletionRow> rows = chunk;
      // Stable child indices preserve state when records move or disappear.
      final Map<Key, int> indices = <Key, int>{
        for (int index = 0; index < rows.length; index++)
          rows[index].key: index,
      };
      slivers.add(
        SliverList.builder(
          key: ValueKey<String>('android-completion-chunk-${rows.first.key}'),
          itemCount: rows.length,
          findChildIndexCallback: (Key key) => indices[key],
          itemBuilder: (BuildContext context, int index) => KeyedSubtree(
            key: rows[index].key,
            child: rows[index].dayCount != null
                ? _dayHeading(context, rows[index])
                : _cardHeader(context, rows[index].group),
          ),
        ),
      );
      chunk = <_AndroidCompletionRow>[];
    }

    for (final TodoCompletionGroup group in widget.groups) {
      if (group.day != previousDay) {
        chunk.add(_AndroidCompletionRow(group, dayCount: counts[group.day]));
        previousDay = group.day;
      }
      chunk.add(_AndroidCompletionRow(group));
      if (!group.expandable) continue;
      flush();
      // Concrete entry keys keep menu actions attached to the correct task.
      final Map<Key, int> indices = <Key, int>{
        for (int index = 0; index < group.entries.length; index++)
          ValueKey<String>(
            'android-completion-entry-${group.entries[index].id}',
          ): index,
      };
      slivers.add(
        OmniDisclosure.sliver(
          key: ValueKey<String>('android-completion-details-${group.id}'),
          expanded: _isExpanded(group),
          child: SliverList.builder(
            itemCount: group.entries.length,
            findChildIndexCallback: (Key key) => indices[key],
            itemBuilder: (BuildContext context, int index) => _detail(
              context,
              group.entries[index],
              last: index == group.entries.length - 1,
            ),
          ),
        ),
      );
    }
    flush();
    return slivers;
  }

  /// Places a quiet date heading outside the paper card surfaces.
  Widget _dayHeading(
    BuildContext context,
    _AndroidCompletionRow row,
  ) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 0),
    child: Text(
      '${DateFormat('yyyy年M月d日').format(row.group.day)} · 完成${row.dayCount}项',
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: OmniColors.of(context).muted),
    ),
  );

  /// Draws either a standalone task or an expandable parent card header.
  Widget _cardHeader(BuildContext context, TodoCompletionGroup group) {
    // Group headers gain square lower corners while details are visible.
    final bool expanded = group.expandable && _isExpanded(group);
    // Summary time is the most recent matching completion in this group.
    final String time = DateFormat('HH:mm')
        .format(group.latestCompletedAt.toLocal());
    // Expanded headers wrap completely instead of hiding long parent names.
    final Widget title = Text(
      group.root.title,
      maxLines: expanded ? null : 2,
      overflow: expanded ? TextOverflow.visible : TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 16),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Material(
        color: OmniColors.of(context).paper,
        borderRadius: BorderRadius.vertical(
          top: const Radius.circular(OmniRadius.panel),
          bottom: Radius.circular(expanded ? 0 : OmniRadius.panel),
        ),
        clipBehavior: Clip.antiAlias,
        child: OmniDisclosureToggle(
          expanded: group.expandable ? expanded : null,
          child: OmniInkWell(
            onTap: group.expandable
                ? () => _toggle(group)
                : () => widget.onEdit(group.entries.first.todo),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        title,
                        const SizedBox(height: 4),
                        Text(
                          group.expandable
                              ? '完成${group.entries.length}项 · $time'
                              : time,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: OmniColors.of(context).muted),
                        ),
                      ],
                    ),
                  ),
                  if (group.root.taskType == 'progress')
                    OmniIconButton(
                      tooltip: '查看进度',
                      icon: const Icon(Icons.segment_rounded, size: 20),
                      onPressed: () => widget.onProgress(group.root),
                    ),
                  if (group.expandable)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Icon(
                        expanded
                            ? Icons.expand_more_rounded
                            : Icons.chevron_right_rounded,
                        color: OmniColors.of(context).muted,
                        size: 24,
                      ),
                    )
                  else
                    _more(group.entries.first),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Extends the same card surface through independently built detail rows.
  Widget _detail(
    BuildContext context,
    TodoCompletionEntry entry, {
    required bool last,
  }) => Material(
    key: ValueKey<String>('android-completion-entry-${entry.id}'),
    color: OmniColors.of(context).paper,
    borderRadius: BorderRadius.vertical(
      bottom: Radius.circular(last ? OmniRadius.panel : 0),
    ),
    clipBehavior: Clip.antiAlias,
    child: Padding(
      padding: EdgeInsets.fromLTRB(28, 4, 4, last ? 12 : 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  entry.title,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  DateFormat('HH:mm').format(entry.completedAt.toLocal()),
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: OmniColors.of(context).muted),
                ),
              ],
            ),
          ),
          if (entry.kind == TodoCompletionKind.progress)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Icon(
                Icons.check_rounded,
                color: OmniColors.of(context).brand,
                size: 16,
              ),
            )
          else
            _more(entry),
        ],
      ),
    ),
  );

  /// Exposes explicit task-level actions without a destructive group shortcut.
  Widget _more(TodoCompletionEntry entry) => OmniPopupMenuButton<String>(
    key: ValueKey<String>('android-completion-more-${entry.id}'),
    tooltip: '${entry.title}，更多操作',
    icon: const Icon(Icons.more_horiz_rounded),
    onSelected: (String action) {
      if (action == 'edit') widget.onEdit(entry.todo);
      if (action == 'reopen') widget.onReopen(entry.todo);
    },
    itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
      OmniPopupMenuItem<String>(
        value: 'edit',
        label: '编辑',
        icon: Icons.edit_outlined,
      ),
      OmniPopupMenuItem<String>(
        value: 'reopen',
        label: '重新打开',
        icon: Icons.undo_rounded,
      ),
    ],
  );
}
