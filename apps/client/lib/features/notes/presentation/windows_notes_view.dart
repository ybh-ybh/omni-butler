part of 'notes_page.dart';

/// 日期按指定周数排列，每列从周一到周日，跨年仍遵守自然日。
List<DateTime> noteHeatmapDates(DateTime today, {int weeks = 12}) {
  // 第一列周一，保留今天所在周并向前取其余周。
  final DateTime start = DateTime(
    today.year,
    today.month,
    today.day - today.weekday + 1 - (weeks - 1) * 7,
  );
  return List<DateTime>.generate(
    weeks * 7,
    (index) => DateTime(start.year, start.month, start.day + index),
  );
}

/// Windows 笔记内搜索只占用 Ctrl+F，全局搜索继续保留独立入口。
class _FindNoteIntent extends Intent {
  /// 创建笔记查找意图。
  const _FindNoteIntent();
}

/// 单个热图日期独立维护悬停，避免鼠标移动重建整个笔记工作区。
class _NoteHeatmapCell extends StatefulWidget {
  /// 创建与自然日身份绑定的热图方块。
  const _NoteHeatmapCell({
    super.key,
    required this.dayKey,
    required this.count,
    required this.future,
    required this.outlined,
    required this.selected,
    required this.onTap,
  });

  /// 用于提示、筛选及测试的业务自然日。
  final String dayKey;

  /// 当前日期的正式笔记篇数。
  final int count;

  /// 未来日期不参与筛选。
  final bool future;

  /// 今日或选中日期保留常态边框。
  final bool outlined;

  /// 当前筛选日期的读屏状态。
  final bool selected;

  /// 有笔记时才允许切换日期筛选。
  final VoidCallback onTap;

  /// 悬停动画状态仅属于当前格。
  @override
  State<_NoteHeatmapCell> createState() => _NoteHeatmapCellState();
}

/// 缩放和主题光晕均由项目动效与配色控制。
class _NoteHeatmapCellState extends State<_NoteHeatmapCell> {
  /// 鼠标是否进入当前日期方块。
  bool _hovered = false;

  /// 鼠标进出即时改变动画目标，反向从当前呈现值继续。
  void _hover(bool value) {
    if (mounted) setState(() => _hovered = value);
  }

  /// 空日期保留手形和放大反馈，但没有提示、筛选或光晕。
  @override
  Widget build(BuildContext context) {
    // 使用当前主题热力强度及边框颜色。
    final OmniColors colors = OmniColors.of(context);
    // 有正式笔记且非未来日期才有点击及提示。
    final bool active = widget.count > 0 && !widget.future;
    // 光晕只强调当前悬停的有效日期。
    final bool glowing = _hovered && active;
    // 减少动画时停止缩放，颜色反馈保持即时。
    final Duration motion = OmniMotion.duration(context, OmniMotion.fast);
    // 方块始终保留原始布局尺寸，缩放不挤动相邻日期。
    final Widget cell = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => _hover(true),
      onExit: (_) => _hover(false),
      child: Semantics(
        button: active,
        selected: widget.selected,
        label: '${widget.dayKey}，${widget.count} 篇笔记',
        child: OmniInkWell(
          key: ValueKey('note-heatmap-${widget.dayKey}'),
          mouseCursor: SystemMouseCursors.click,
          borderRadius: BorderRadius.circular(OmniRadius.tiny),
          onTap: active ? widget.onTap : null,
          child: AnimatedScale(
            key: ValueKey('note-day-scale-${widget.dayKey}'),
            scale: _hovered && !OmniMotion.reduce(context) ? 1.2 : 1,
            duration: motion,
            curve: OmniMotion.standardCurve,
            child: AnimatedContainer(
              key: ValueKey('note-day-fill-${widget.dayKey}'),
              duration: motion,
              curve: OmniMotion.standardCurve,
              decoration: BoxDecoration(
                color: widget.future
                    ? colors.canvas
                    : widget.count == 0
                    ? colors.mist
                    : Color.lerp(
                        colors.brandSoft,
                        colors.brand,
                        widget.count.clamp(1, 5) / 5,
                      ),
                borderRadius: BorderRadius.circular(OmniRadius.tiny),
                border: widget.outlined || glowing
                    ? Border.all(color: colors.brand)
                    : null,
                boxShadow: glowing
                    ? [
                        BoxShadow(
                          color: colors.brand.withValues(alpha: 0.42),
                          blurRadius: OmniSpacing.xs,
                        ),
                      ]
                    : const [],
              ),
            ),
          ),
        ),
      ),
    );
    return active
        ? OmniWindowsSemanticsBoundary(
            child: Tooltip(
              message: '${widget.dayKey} · ${widget.count} 篇笔记',
              child: cell,
            ),
          )
        : cell;
  }
}

/// 笔记桌面工作区只负责呈现，所有正文和原音归属由应用级控制器处理。
extension _WindowsNotesView on _NotesPageState {
  /// 渲染左侧统计导航与右侧连续笔记列表。
  Widget _windowsView(
    NoteEditorController editor,
    List<TaxonomyEntry> taxonomy,
    AsyncValue<List<NoteEntryRecord>> notes,
    List<NoteAudioSegmentRecord> segments,
    List<NoteAudioLocalFileRecord> local,
    NoteRecordingState recording,
  ) {
    // 搜索包含转写，统计始终只来自正式笔记。
    final List<NoteAudioSegmentRecord> audio =
        ref.watch(_allNoteAudioProvider).value ?? [];
    // 所有活动正式笔记。
    final List<NoteEntryRecord> all = notes.value ?? [];
    // 正式图片流参与筛选，草稿图片不会提前命中。
    final Set<String> imageNoteIds =
        (ref.watch(_allNoteImagesProvider).value ?? [])
            .where((image) => image.deletedAt == null)
            .map((image) => image.noteId)
            .toSet();
    // 当前视图的交集结果。
    final List<NoteEntryRecord> filtered = all
        .where(
          (note) => _matches(note, taxonomy, audio, imageNoteIds: imageNoteIds),
        )
        .toList();
    // 当前数据源实际可用的平铺标签。
    final List<TaxonomyEntry> tags = taxonomy
        .where((item) => item.kind == 'tag' && item.deletedAt == null)
        .toList();
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _FindNoteIntent(),
      },
      child: Actions(
        actions: {
          _FindNoteIntent: CallbackAction<_FindNoteIntent>(
            onInvoke: (_) {
              _searchFocus.requestFocus();
              return null;
            },
          ),
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 窄桌面保持键鼠控件密度，将笔记侧栏放入抽屉。
            final bool drawer = constraints.maxWidth < 900;
            // 侧栏内容独立滚动，短窗口不会挤压主区。
            final Widget sidebar = _noteSidebar(all, tags);
            return Scaffold(
              key: _notesScaffold,
              backgroundColor: OmniColors.of(context).canvas,
              drawer: drawer
                  ? Drawer(
                      width: _noteSidebarWidth,
                      child: SafeArea(child: sidebar),
                    )
                  : null,
              body: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!drawer) _noteSidebarTransition(sidebar),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _noteHeader(drawer, tags),
                        if (_actionError != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: OmniSpacing.xl,
                            ),
                            child: Text(
                              _actionError!,
                              style: TextStyle(
                                color: OmniColors.of(context).danger,
                              ),
                            ),
                          ),
                        Expanded(
                          child: _recycle
                              ? _noteRecycleView()
                              : SingleChildScrollView(
                                  key: const ValueKey('notes-main-scroll'),
                                  controller: _notesScroll,
                                  padding: const EdgeInsets.fromLTRB(
                                    OmniSpacing.xl,
                                    OmniSpacing.xs,
                                    OmniSpacing.xl,
                                    OmniSpacing.xxl,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      if (_expandedNoteId == null)
                                        _noteEditorSurface(
                                          editor,
                                          taxonomy,
                                          segments,
                                          local,
                                          recording,
                                        )
                                      else
                                        OmniPanel(
                                          key: const ValueKey(
                                            'notes-composer-entry',
                                          ),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                '记下此刻的想法…',
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodyLarge
                                                    ?.copyWith(
                                                      color: OmniColors.of(
                                                        context,
                                                      ).muted,
                                                    ),
                                              ),
                                              const SizedBox(
                                                height: OmniSpacing.lg,
                                              ),
                                              OmniButton(
                                                label: '写新笔记',
                                                icon: Icons.edit_note,
                                                variant: OmniButtonVariant.text,
                                                onPressed: () =>
                                                    _activateComposer(editor),
                                              ),
                                            ],
                                          ),
                                        ),
                                      const SizedBox(height: OmniSpacing.sm),
                                      if (_expandedNoteId != null &&
                                          !notes.isLoading &&
                                          !all.any(
                                            (note) =>
                                                note.id == _expandedNoteId,
                                          ))
                                        _noteEditorSurface(
                                          editor,
                                          taxonomy,
                                          segments,
                                          local,
                                          recording,
                                        ),
                                      if (notes.isLoading)
                                        const LinearProgressIndicator(),
                                      if (notes.hasError)
                                        Text('笔记加载失败：${notes.error}'),
                                      if (!notes.isLoading && filtered.isEmpty)
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                            vertical: OmniSpacing.xxl,
                                          ),
                                          child: Column(
                                            children: [
                                              Text(
                                                all.isEmpty
                                                    ? '从第一条笔记开始'
                                                    : '没有符合条件的笔记',
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .titleMedium,
                                              ),
                                              const SizedBox(
                                                height: OmniSpacing.xs,
                                              ),
                                              Text(
                                                all.isEmpty
                                                    ? '文字、图片和录音会先保存在本机草稿，发布后出现在这里。'
                                                    : '调整日期、标签或搜索词，再试一次。',
                                                textAlign: TextAlign.center,
                                              ),
                                              if (all.isNotEmpty)
                                                OmniButton(
                                                  label: '清除筛选',
                                                  variant:
                                                      OmniButtonVariant.text,
                                                  onPressed: _allNotes,
                                                ),
                                            ],
                                          ),
                                        ),
                                      for (final NoteEntryRecord note
                                          in filtered)
                                        Padding(
                                          key: _noteKeys.putIfAbsent(
                                            note.id,
                                            () => GlobalKey(),
                                          ),
                                          padding: const EdgeInsets.only(
                                            bottom: OmniSpacing.sm,
                                          ),
                                          child: _historyCard(
                                            note,
                                            editor,
                                            taxonomy,
                                            segments,
                                            local,
                                            recording,
                                          ),
                                        ),
                                      if (filtered.isNotEmpty)
                                        Padding(
                                          padding: const EdgeInsets.all(
                                            OmniSpacing.lg,
                                          ),
                                          child: Text(
                                            '已显示 ${filtered.length} 篇笔记',
                                            textAlign: TextAlign.center,
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// 固定头部只保留视图标题和带过滤菜单的笔记搜索。
  Widget _noteHeader(bool drawer, List<TaxonomyEntry> tags) {
    // 当前视图的短标题。
    final String label = _recycle
        ? '笔记回收站'
        : _tagFilter.isNotEmpty && !_excludeSearchTags
        ? '# ${tags.where((tag) => _tagFilter.contains(tag.id)).firstOrNull?.name ?? '标签'}'
        : _selectedDay ?? '全部笔记';
    // 聚焦向左展开，窄窗中由父级宽度限制。
    final Widget search = WindowsNoteSearchBar(
      controller: _search,
      focusNode: _searchFocus,
      tags: tags,
      filter: WindowsNoteSearchFilter(
        range: _selectedDay == null ? _range : 'custom',
        customRange: _selectedDay == null
            ? _customRange
            : DateTimeRange(
                start: DateTime.parse(_selectedDay!),
                end: DateTime.parse(_selectedDay!),
              ),
        tagMode: _untagged
            ? 'none'
            : _excludeSearchTags
            ? 'exclude'
            : 'include',
        tagIds: _tagFilter,
        contents: _searchContents,
      ),
      onChanged: (_) => _updateWindows(() => _recycle = false),
      onFilterChanged: (filter) => _updateWindows(() {
        _recycle = false;
        _selectedDay = null;
        _range = filter.range;
        _customRange = filter.customRange;
        _untagged = filter.tagMode == 'none';
        _excludeSearchTags = filter.tagMode == 'exclude';
        _tagFilter
          ..clear()
          ..addAll(filter.tagIds);
        _searchContents
          ..clear()
          ..addAll(filter.contents);
      }),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        OmniSpacing.xl,
        OmniSpacing.sm,
        OmniSpacing.md,
        OmniSpacing.xs,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 放大字号或窄窗时将搜索框完整换至下一行。
          final bool stacked =
              constraints.maxWidth < 580 ||
              MediaQuery.textScalerOf(context).scale(14) > 20;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  if (drawer || _noteSidebarHidden)
                    Builder(
                      builder: (context) => OmniIconButton(
                        tooltip: drawer ? '笔记导航' : '显示侧边栏',
                        icon: const Icon(Icons.menu),
                        onPressed: () {
                          if (drawer) {
                            Scaffold.of(context).openDrawer();
                          } else {
                            _updateWindows(() => _noteSidebarHidden = false);
                          }
                        },
                      ),
                    ),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (!stacked) SizedBox(width: 400, child: search),
                ],
              ),
              if (stacked)
                Padding(
                  padding: const EdgeInsets.only(top: OmniSpacing.xs),
                  child: search,
                ),
            ],
          );
        },
      ),
    );
  }

  /// 固定内部宽度，向左滑出并淡出，主区随占位宽度连续扩展。
  Widget _noteSidebarTransition(Widget sidebar) {
    // 侧栏和透明拖动热区一同退出。
    final double width = _noteSidebarWidth + OmniSpacing.xs;
    return TweenAnimationBuilder<double>(
      key: const ValueKey('notes-sidebar-transition'),
      tween: Tween<double>(
        begin: _noteSidebarHidden ? 0 : 1,
        end: _noteSidebarHidden ? 0 : 1,
      ),
      duration: OmniMotion.duration(context, OmniMotion.panel),
      curve: OmniMotion.standardCurve,
      child: SizedBox(
        width: width,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              key: const ValueKey('notes-sidebar-width'),
              width: _noteSidebarWidth,
              child: sidebar,
            ),
            _noteSidebarDivider(),
          ],
        ),
      ),
      builder: (context, progress, child) => Visibility(
        visible: progress > 0,
        maintainState: true,
        child: ExcludeFocus(
          excluding: _noteSidebarHidden,
          child: ExcludeSemantics(
            excluding: _noteSidebarHidden,
            child: IgnorePointer(
              ignoring: _noteSidebarHidden,
              child: ClipRect(
                child: Align(
                  alignment: Alignment.centerLeft,
                  widthFactor: progress,
                  child: Transform.translate(
                    offset: Offset(-width * (1 - progress), 0),
                    child: Opacity(opacity: progress, child: child),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 悬停灰线、按下主题线；上下留白避免贯穿整个窗口。
  Widget _noteSidebarDivider() => MouseRegion(
    cursor: SystemMouseCursors.resizeColumn,
    onEnter: (_) => _updateWindows(() => _noteSidebarDividerHovered = true),
    onExit: (_) => _updateWindows(() => _noteSidebarDividerHovered = false),
    child: Listener(
      onPointerDown: (event) {
        if (event.buttons == 1) {
          _updateWindows(() => _noteSidebarResizing = true);
        }
      },
      onPointerUp: (_) => _updateWindows(() => _noteSidebarResizing = false),
      onPointerCancel: (_) =>
          _updateWindows(() => _noteSidebarResizing = false),
      child: GestureDetector(
        key: const ValueKey('notes-sidebar-divider'),
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) => _updateWindows(() {
          _noteSidebarWidth = (_noteSidebarWidth + details.delta.dx).clamp(
            220,
            340,
          );
        }),
        onHorizontalDragEnd: (_) =>
            _updateWindows(() => _noteSidebarResizing = false),
        onHorizontalDragCancel: () =>
            _updateWindows(() => _noteSidebarResizing = false),
        child: SizedBox(
          width: OmniSpacing.xs,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: OmniSpacing.xl),
            child: Center(
              child: SizedBox(
                width: 1,
                height: double.infinity,
                child: _noteSidebarResizing || _noteSidebarDividerHovered
                    ? ColoredBox(
                        key: ValueKey(
                          _noteSidebarResizing
                              ? 'notes-sidebar-drag-line'
                              : 'notes-sidebar-hover-line',
                        ),
                        color: _noteSidebarResizing
                            ? OmniColors.of(context).brand
                            : OmniColors.of(context).line,
                      )
                    : null,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  /// 隐藏整个笔记侧栏，同时关闭窄窗抽屉并清理临时悬停状态。
  void _hideNoteSidebar() {
    _closeNoteDrawer();
    _updateWindows(() {
      _noteSidebarHidden = true;
      _noteSidebarHovered = false;
      _noteSidebarResizing = false;
      _noteSidebarDividerHovered = false;
    });
  }

  /// 统计、自适应热力图、全部笔记、标签和回收站依次排列。
  Widget _noteSidebar(List<NoteEntryRecord> notes, List<TaxonomyEntry> tags) {
    // 不同业务自然日数量不受页面筛选影响。
    final int days = notes.map((note) => note.dayKey).toSet().length;
    return MouseRegion(
      key: const ValueKey('notes-sidebar-region'),
      onEnter: (_) => _updateWindows(() => _noteSidebarHovered = true),
      onExit: (_) => _updateWindows(() => _noteSidebarHovered = false),
      child: SingleChildScrollView(
        key: const ValueKey('notes-sidebar'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MouseRegion(
              key: const ValueKey('notes-sidebar-overview'),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  OmniSpacing.lg,
                  OmniSpacing.xl,
                  OmniSpacing.lg,
                  0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '我的笔记',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        OmniHoverReveal(
                          visible: _noteSidebarHovered,
                          child: OmniIconButton(
                            tooltip: '隐藏侧边栏',
                            icon: const Icon(Icons.menu_open),
                            onPressed: _hideNoteSidebar,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: OmniSpacing.lg),
                    Row(
                      children: [
                        _noteStatistic(
                          '${notes.length}',
                          '笔记',
                          'note-count',
                          CrossAxisAlignment.start,
                        ),
                        _noteStatistic(
                          '${tags.length}',
                          '标签',
                          'tag-count',
                          CrossAxisAlignment.center,
                        ),
                        _noteStatistic(
                          '$days',
                          '天',
                          'day-count',
                          CrossAxisAlignment.end,
                        ),
                      ],
                    ),
                    const SizedBox(height: OmniSpacing.lg),
                    _noteHeatmap(notes),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                OmniSpacing.lg,
                0,
                OmniSpacing.lg,
                OmniSpacing.xl,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: OmniSpacing.xl),
                  _noteNavigation(
                    '全部笔记',
                    Icons.grid_view_rounded,
                    !_recycle &&
                        _selectedDay == null &&
                        (_tagFilter.isEmpty || _excludeSearchTags),
                    _allNotes,
                  ),
                  const SizedBox(height: OmniSpacing.xl),
                  NoteTagSection(
                    notes: notes,
                    tags: tags,
                    selectedIds: _recycle || _excludeSearchTags
                        ? const {}
                        : _tagFilter,
                    onSelect: (id) => _updateWindows(() {
                      _recycle = false;
                      _untagged = false;
                      _excludeSearchTags = false;
                      _tagFilter
                        ..clear()
                        ..add(id);
                      _closeNoteDrawer();
                    }),
                    onDeleted: (id) =>
                        _updateWindows(() => _tagFilter.remove(id)),
                  ),
                  _noteNavigation(
                    '回收站',
                    Icons.delete_outline,
                    _recycle,
                    () => _updateWindows(() {
                      _recycle = true;
                      _closeNoteDrawer();
                    }),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 侧栏统计提供稳定测试与读屏语义。
  Widget _noteStatistic(
    String count,
    String label,
    String key,
    CrossAxisAlignment alignment,
  ) => Expanded(
    child: NoteStatisticButton(
      count: count,
      label: label,
      countKey: key,
      alignment: alignment,
      onTap: _showNoteStatistics,
    ),
  );

  /// 弹窗选日明确切换至当天全部笔记，保留当前编辑器和原音状态。
  Future<void> _showNoteStatistics() async {
    if (_statisticsOpen) return;
    _statisticsOpen = true;
    try {
      // 路由只返回业务日期，不直接修改页面的过滤条件。
      final String? dayKey = await showNoteStatisticsDialog(context);
      if (!mounted || dayKey == null) return;
      _updateWindows(() {
        _selectedDay = dayKey;
        _recycle = false;
        _tagFilter.clear();
        _search.clear();
        _untagged = false;
        _range = 'all';
        _customRange = null;
        _excludeSearchTags = false;
        _searchContents.clear();
        _closeNoteDrawer();
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _notesScroll.hasClients) _notesScroll.jumpTo(0);
      });
    } finally {
      _statisticsOpen = false;
    }
  }

  /// 平铺的统一按钮保留键盘激活与选中语义。
  Widget _noteNavigation(
    String label,
    IconData icon,
    bool selected,
    VoidCallback onTap,
  ) {
    // 选中行使用主题主色，普通标签继承正文颜色并靠左排列。
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // 统一文字、图标和焦点状态的前景色。
    final Color foreground = selected
        ? scheme.onPrimary
        : OmniColors.of(context).ink;
    return Padding(
      padding: const EdgeInsets.only(bottom: OmniSpacing.xxs),
      child: Semantics(
        selected: selected,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: selected ? scheme.primary : OmniColors.of(context).canvas,
            borderRadius: BorderRadius.circular(OmniRadius.control),
          ),
          child: OmniListRow(
            borderRadius: BorderRadius.circular(OmniRadius.control),
            padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.sm),
            leading: Icon(icon, size: OmniSize.icon, color: foreground),
            title: Text(
              label,
              style: TextStyle(color: foreground),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: onTap,
          ),
        ),
      ),
    );
  }

  /// 周一到周日纵向排列，今天所在周固定在最右侧。
  Widget _noteHeatmap(List<NoteEntryRecord> notes) {
    // 固定自然日，避免跨时区时用持续时长误移日期。
    final DateTime now = DateTime.now();
    // 日期序列同时提供渲染与跨年验证的唯一事实来源。
    // 侧栏由最小到最大宽度逐步展示八至十二周。
    final int weeks = 8 + ((_noteSidebarWidth - 220) / 120 * 4).round();
    // 每次扩展都保留今天所在的最右列，向过去增加周列。
    final List<DateTime> dates = noteHeatmapDates(now, weeks: weeks);
    // 只汇总活动正式笔记。
    final Map<String, int> counts = {};
    for (final NoteEntryRecord note in notes) {
      counts.update(note.dayKey, (count) => count + 1, ifAbsent: () => 1);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 每一列代表一周。
            for (int week = 0; week < weeks; week++)
              Expanded(
                child: Column(
                  children: [
                    // 每一格代表从周一开始的自然日。
                    for (int day = 0; day < 7; day++)
                      Builder(
                        builder: (context) {
                          // 当前格对应的本机自然日。
                          final DateTime date = dates[week * 7 + day];
                          // 与正式记录共用的稳定业务日期。
                          final String key = businessDayKey(date);
                          // 当日正式笔记数量。
                          final int count = counts[key] ?? 0;
                          // 未来格不提供筛选。
                          final bool future = date.isAfter(
                            DateTime(now.year, now.month, now.day),
                          );
                          // 今日与选中日期有独立边框。
                          final bool outlined =
                              key == _selectedDay || key == businessDayKey(now);
                          return Padding(
                            padding: const EdgeInsets.all(OmniSpacing.xxs),
                            child: AspectRatio(
                              aspectRatio: 1,
                              child: _NoteHeatmapCell(
                                key: ValueKey('note-day-$key'),
                                dayKey: key,
                                count: count,
                                future: future,
                                outlined: outlined,
                                selected: key == _selectedDay,
                                onTap: () => _updateWindows(() {
                                  _recycle = false;
                                  _selectedDay = _selectedDay == key
                                      ? null
                                      : key;
                                  _range = 'all';
                                  _customRange = null;
                                  _closeNoteDrawer();
                                }),
                              ),
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ),
          ],
        ),
        const SizedBox(height: OmniSpacing.xs),
        _noteHeatmapMonths(dates, weeks),
      ],
    );
  }

  /// 中文月份按周列定位，窄栏与大字号下避免重叠或越界。
  Widget _noteHeatmapMonths(List<DateTime> dates, int weeks) {
    // 全年中文月份名称。
    const List<String> months = [
      '一月',
      '二月',
      '三月',
      '四月',
      '五月',
      '六月',
      '七月',
      '八月',
      '九月',
      '十月',
      '十一月',
      '十二月',
    ];
    // 与正文辅助文字共用字号及缩放。
    final TextStyle style = Theme.of(context).textTheme.bodySmall!;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 月份从右侧排布，优先保留当前月并跳过过近的前月。
        final List<Widget> labels = [];
        // 下一个标签的左边界。
        double nextLeft = constraints.maxWidth + OmniSpacing.xs;
        // 标签所需行高。
        double height = 0;
        // 每周起点用于识别月份边界。
        for (int week = weeks - 1; week >= 0; week--) {
          // 本周周一。
          final DateTime date = dates[week * 7];
          if (week > 0 && dates[(week - 1) * 7].month == date.month) continue;
          // 当前月份完整的中文名称。
          final String label = months[date.month - 1];
          // 测量真实字形，以免十一月和十二月挤出热图区。
          final TextPainter painter = TextPainter(
            text: TextSpan(text: label, style: style),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          )..layout();
          // 行高始终容纳当前字号。
          height = height < painter.height ? painter.height : height;
          // 靠近右端的标签左移到热图区内。
          final double left = (week * constraints.maxWidth / weeks).clamp(
            0,
            constraints.maxWidth - painter.width,
          );
          if (left + painter.width + OmniSpacing.xs <= nextLeft) {
            labels.add(
              Positioned(
                left: left,
                top: 0,
                child: Text(label, style: style),
              ),
            );
            nextLeft = left;
          }
          painter.dispose();
        }
        return SizedBox(
          height: height,
          child: Stack(children: labels),
        );
      },
    );
  }

  /// 全部笔记同时撤销日期、标签和搜索，作为统一返回入口。
  void _allNotes() => _updateWindows(() {
    _recycle = false;
    _selectedDay = null;
    _tagFilter.clear();
    _search.clear();
    _range = 'all';
    _untagged = false;
    _customRange = null;
    _excludeSearchTags = false;
    _searchContents.clear();
    _closeNoteDrawer();
  });

  /// 只有窄屏抽屉正在显示时才关闭浮层。
  void _closeNoteDrawer() {
    _notesScaffold.currentState?.closeDrawer();
  }

  /// 首个非空行作为标题，其后的正文保留原始换行。
  (String, String) _notePreview(NoteEntryRecord note) {
    // 列表首项必须和后续列表一起渲染，不能被派生成独立标题。
    if (NoteMarkdown.startsWithList(note.body)) {
      return ('', _displayNoteBody(note.body));
    }
    // 空行不会产生空标题。
    final List<String> lines = note.body.split('\n');
    // 第一个有内容的正文行。
    final int index = lines.indexWhere((line) => line.trim().isNotEmpty);
    return index < 0
        ? (
            (ref.watch(_allNoteImagesProvider).value ?? []).any(
                  (image) => image.noteId == note.id && image.deletedAt == null,
                )
                ? '图片笔记'
                : ref
                          .read(_allNoteAudioProvider)
                          .value
                          ?.any(
                            (audio) =>
                                audio.noteId == note.id &&
                                audio.deletedAt == null,
                          ) ==
                      true
                ? '语音笔记'
                : '内容已清空',
            '',
          )
        : (lines[index], _displayNoteBody(lines.skip(index + 1).join('\n')));
  }

  /// 摘要仅移除外围空白行，不改变会影响 Markdown 解释的行首空格。
  String _displayNoteBody(String source) {
    // 原始行文本保持字面内容，包括非列表缩进。
    final List<String> lines = source.split('\n');
    // 首个有内容的行，空白正文直接隐藏。
    final int first = lines.indexWhere((line) => line.trim().isNotEmpty);
    if (first < 0) return '';
    // 末个有内容的行之前保留全部换行。
    final int last = lines.lastIndexWhere((line) => line.trim().isNotEmpty);
    return lines.sublist(first, last + 1).join('\n');
  }

  /// 历史卡片保留标题及两行正文，并提供独立的原音展开入口。
  Widget _historyCard(
    NoteEntryRecord note,
    NoteEditorController editor,
    List<TaxonomyEntry> taxonomy,
    List<NoteAudioSegmentRecord> segments,
    List<NoteAudioLocalFileRecord> local,
    NoteRecordingState recording,
  ) {
    // 同时只有一张卡片拥有真实正文输入框。
    final bool expanded =
        _expandedNoteId == note.id && editor.draft.id == note.id;
    // 展示内容不改写正文模型。
    final (String title, String preview) = _notePreview(note);
    // 创建时间继续使用原始本机展示。
    final DateTime created = note.createdAt.toLocal();
    // 收缩卡片读取所属笔记的原音，不能复用当前编辑器的片段。
    final List<NoteAudioSegmentRecord> audio =
        (ref.watch(_allNoteAudioProvider).value ?? [])
            .where(
              (segment) =>
                  segment.noteId == note.id && segment.deletedAt == null,
            )
            .toList()
          ..sort(
            (first, second) => first.sortOrder.compareTo(second.sortOrder),
          );
    // 小号时间使用灰色，深色模式沿用主题的可读灰度。
    final OmniColors colors = OmniColors.of(context);
    return KeyedSubtree(
      key: ValueKey('note-card-${note.id}'),
      // 稳定卡片语义父节点，展开及裁剪只更新其内部孩子。
      child: Semantics(
        key: ValueKey('note-card-region-${note.id}'),
        container: true,
        explicitChildNodes: true,
        child: _noteCardSize(
          expanded
              ? _noteEditorSurface(editor, taxonomy, segments, local, recording)
              : OmniPanel(
                  onDoubleTap: () => _open(note.id),
                  showBorder: false,
                  hoverColor: Colors.transparent,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${businessDayKey(created)} ${created.hour.toString().padLeft(2, '0')}:${created.minute.toString().padLeft(2, '0')}',
                              key: ValueKey('note-created-${note.id}'),
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    fontSize: 10,
                                    color:
                                        Theme.of(context).brightness ==
                                            Brightness.light
                                        ? NoteComposerStyle.muted
                                        : colors.muted,
                                  ),
                            ),
                          ),
                          OmniPopupMenuButton<String>(
                            key: ValueKey('note-menu-${note.id}'),
                            mouseCursor: SystemMouseCursors.click,
                            tooltip: '笔记操作',
                            icon: const Icon(Icons.more_horiz),
                            onSelected: (action) async {
                              if (action == 'edit') {
                                await _open(note.id);
                              }
                              if (action == 'copy') {
                                await Clipboard.setData(
                                  ClipboardData(text: note.body),
                                );
                              }
                              if (action == 'versions') {
                                await _open(note.id);
                                if (mounted && editor.draft.id == note.id) {
                                  await _showVersions(editor);
                                }
                              }
                              if (action == 'delete') {
                                await _deleteHistoryNote(note.id, editor);
                              }
                            },
                            itemBuilder: (_) => [
                              OmniPopupMenuItem(
                                value: 'edit',
                                label: '编辑',
                                icon: Icons.edit_outlined,
                              ),
                              OmniPopupMenuItem(
                                value: 'copy',
                                label: '复制正文',
                                icon: Icons.copy_outlined,
                              ),
                              OmniPopupMenuItem(
                                value: 'versions',
                                label: '版本记录',
                                icon: Icons.restore,
                              ),
                              OmniPopupMenuItem(
                                value: 'delete',
                                label: '移入回收站',
                                icon: Icons.delete_outline,
                                danger: true,
                              ),
                            ],
                          ),
                        ],
                      ),
                      if (title.isNotEmpty)
                        NoteMarkdownText(
                          source: title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      if (preview.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: OmniSpacing.xs),
                          child: _noteBodyPreview(note, preview),
                        ),
                      _historyImages(note.id, editor),
                      for (final segment in audio)
                        Padding(
                          padding: const EdgeInsets.only(top: OmniSpacing.sm),
                          child: NoteAudioCard(
                            key: ValueKey('note-history-audio-${segment.id}'),
                            compact: true,
                            segment: segment,
                            local: local
                                .where((file) => file.id == segment.id)
                                .firstOrNull,
                            player: ref.read(noteAudioPlayerProvider),
                            recordingActive: recording.isActive,
                            onRecognize: () => _recognize(segment),
                            onCancel: () => _cancelRecognition(segment),
                            onInsert: (text) =>
                                _insertTranscript(segment, text),
                          ),
                        ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  /// 减少动画时直接呈现，避免零时长布局动画在字号变化时重入布局。
  Widget _noteCardSize(Widget child) => OmniMotion.reduce(context)
      ? child
      : AnimatedSize(
          duration: OmniMotion.panel,
          curve: OmniMotion.standardCurve,
          alignment: Alignment.topCenter,
          child: child,
        );

  /// 正文与工具属于同一聚焦区域，悬停不改变卡片表面。
  Widget _noteEditorSurface(
    NoteEditorController editor,
    List<TaxonomyEntry> taxonomy,
    List<NoteAudioSegmentRecord> segments,
    List<NoteAudioLocalFileRecord> local,
    NoteRecordingState recording,
  ) {
    // 深色模式沿用主题表面和边框，浅色按参考图呈现。
    final OmniColors colors = OmniColors.of(context);
    // 浅色截图需要更淡的常态轮廓。
    final bool light = Theme.of(context).brightness == Brightness.light;
    // 历史笔记编辑期间常驻主题色轮廓，失焦不会隐藏编辑状态。
    final bool editing = _expandedNoteId == editor.draft.id;
    // 输入框与动态工具在固定语义容器内更新，避免同时重挂多层节点。
    return Semantics(
      key: ValueKey('note-editor-region-${editor.draft.id}'),
      container: true,
      explicitChildNodes: true,
      child: TextFieldTapRegion(
        child: Focus(
          onFocusChange: (focused) =>
              _updateWindows(() => _composerFocused = focused),
          child: DecoratedBox(
            key: const ValueKey('note-composer-surface'),
            decoration: BoxDecoration(
              color: colors.paper,
              borderRadius: BorderRadius.circular(OmniRadius.dialog),
              border: Border.all(
                color: _composerFocused || _formatMenuOpen || editing
                    ? colors.brand
                    : light
                    ? NoteComposerStyle.border
                    : colors.line,
              ),
              boxShadow: _composerFocused || _formatMenuOpen
                  ? [
                      BoxShadow(
                        color: colors.ink.withValues(alpha: 0.08),
                        blurRadius: OmniSpacing.sm,
                        offset: const Offset(0, OmniSpacing.xxs),
                      ),
                    ]
                  : const [],
            ),
            child: _editorPanel(
              editor,
              taxonomy,
              segments,
              local,
              recording,
              inline: true,
            ),
          ),
        ),
      ),
    );
  }

  /// 底部只保留标签和图标主操作，纯录音也能正常发布。
  Widget _commitActions(
    NoteEditorController editor,
    List<NoteAudioSegmentRecord> segments,
    NoteRecordingState recording,
  ) {
    // 编辑冻结或提交期间，入口保留外观但禁用重复操作。
    final bool editable =
        !editor.frozen &&
        !editor.conflicted &&
        !editor.committing &&
        !_committing &&
        !editor.recordingStarting;
    // 草稿音频流同时驱动回听清单和发布图标。
    return StreamBuilder<List<NoteDraftAudioSegmentRecord>>(
      key: ValueKey('note-composer-action-${editor.draftId}'),
      stream: editor.draftId == null
          ? null
          : (editor.repository.database.select(
              editor.repository.database.noteDraftAudioSegments,
            )..where((table) => table.draftId.equals(editor.draftId!))).watch(),
      builder: (context, snapshot) {
        // 空白表示正文及当前篇的原音都为空，其他篇录音不算当前内容。
        final bool hasContent =
            _expandedNoteId == editor.draft.id ||
            editor.draft.body.trim().isNotEmpty ||
            editor.hasImages ||
            segments.any(
              (segment) =>
                  segment.deletedAt == null &&
                  !editor.isAudioRemoved(segment.id),
            ) ||
            (snapshot.data?.any((item) => !editor.isAudioRemoved(item.id)) ??
                false) ||
            (recording.isActive && recording.noteId == editor.draft.id);
        // 没有内容的主操作是麦克风，录音设备已被占用时不可重复启动。
        final bool enabled = editable && (hasContent || !recording.isActive);
        // 卡片灰色层级在深色模式仍使用主题可读颜色。
        final OmniColors colors = OmniColors.of(context);
        // 浅色外观匹配参考图中的正文与工具颜色。
        final bool light = Theme.of(context).brightness == Brightness.light;
        // 非聚焦工具保留浅灰，单个按钮悬停后独立加深。
        final Color toolColor = light
            ? (_composerFocused || _formatMenuOpen
                  ? NoteComposerStyle.muted
                  : NoteComposerStyle.idleTool)
            : (_composerFocused || _formatMenuOpen
                  ? colors.muted
                  : colors.muted.withValues(alpha: 0.2));
        // 发布和录音均使用当前主题色，不因是否有正文变成灰色。
        final Color background = colors.brand;
        // 无障碍名称和悬停提示补足图标按钮的操作含义。
        final String action = hasContent
            ? (_expandedNoteId == null ? '发布' : '保存')
            : '开始录音';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (editor.frozen || editor.conflicted || editor.error != null)
              Align(
                alignment: Alignment.centerRight,
                child: OmniButton(
                  label: '另存为新笔记',
                  variant: OmniButtonVariant.text,
                  onPressed: editor.committing || _committing
                      ? null
                      : () => _saveDraftAsNew(editor),
                ),
              ),
            if (editor.pendingRecoveryCount > 0)
              Align(
                alignment: Alignment.centerRight,
                child: OmniButton(
                  label: '恢复上次录音',
                  variant: OmniButtonVariant.text,
                  onPressed: editable ? () => _perform(editor.recover) : null,
                ),
              ),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              runSpacing: OmniSpacing.xxs,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    OmniNoteComposerButton(
                      key: const ValueKey('note-composer-tag'),
                      tooltip: '选择标签',
                      icon: const Icon(Icons.tag),
                      foreground: toolColor,
                      hoverForeground: colors.ink,
                      hoverBackground: colors.ink.withValues(alpha: 0.05),
                      onPressed: editable
                          ? () => _updateWindows(
                              () => _showTagEditor = !_showTagEditor,
                            )
                          : null,
                    ),
                    OmniNoteComposerButton(
                      key: const ValueKey('note-composer-image'),
                      tooltip: '插入图片',
                      icon: const Icon(Icons.image_outlined),
                      foreground: toolColor,
                      hoverForeground: colors.ink,
                      hoverBackground: colors.ink.withValues(alpha: 0.05),
                      onPressed:
                          editable && !_pickingImages && !editor.imageAdding
                          ? () => unawaited(_pickNoteImages(editor))
                          : null,
                    ),
                    SizedBox(
                      height: 16,
                      child: VerticalDivider(
                        width: OmniSpacing.sm,
                        color: colors.line,
                      ),
                    ),
                    OmniNoteComposerButton(
                      key: _formatAnchor,
                      tooltip: '文本格式',
                      icon: Builder(
                        builder: (context) => Text(
                          'Aa',
                          style: TextStyle(
                            fontSize: 16,
                            color: IconTheme.of(context).color,
                          ),
                        ),
                      ),
                      foreground: toolColor,
                      hoverForeground: colors.ink,
                      hoverBackground: colors.ink.withValues(alpha: 0.05),
                      selected: _formatMenuOpen,
                      onPressed: editable
                          ? () => unawaited(_showNoteFormats(editor))
                          : null,
                    ),
                    OmniNoteComposerButton(
                      key: const ValueKey('note-composer-bullet-list'),
                      tooltip: '无序列表',
                      icon: const Icon(Icons.format_list_bulleted),
                      foreground: toolColor,
                      hoverForeground: colors.ink,
                      hoverBackground: colors.ink.withValues(alpha: 0.05),
                      selected: _richBody.isBulletList,
                      onPressed: editable
                          ? () {
                              _richBody.toggleList(false);
                              _focus.requestFocus();
                            }
                          : null,
                    ),
                    OmniNoteComposerButton(
                      key: const ValueKey('note-composer-ordered-list'),
                      tooltip: '有序列表',
                      icon: const Icon(Icons.format_list_numbered),
                      foreground: toolColor,
                      hoverForeground: colors.ink,
                      hoverBackground: colors.ink.withValues(alpha: 0.05),
                      selected: _richBody.isOrderedList,
                      onPressed: editable
                          ? () {
                              _richBody.toggleList(true);
                              _focus.requestFocus();
                            }
                          : null,
                    ),
                  ],
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_composerFocused || _formatMenuOpen) ...[
                      Text(
                        '${NoteMarkdown.plainText(editor.draft.body).characters.length}',
                        key: const ValueKey('note-composer-count'),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: light ? NoteComposerStyle.muted : colors.muted,
                        ),
                      ),
                      const SizedBox(width: OmniSpacing.sm),
                    ],
                    if (_expandedNoteId == editor.draft.id) ...[
                      OmniNoteAudioLink(
                        key: const ValueKey('note-edit-cancel'),
                        label: '取消',
                        color: light ? NoteComposerStyle.muted : colors.muted,
                        hoverForeground: colors.brand,
                        showHoverBackground: false,
                        onPressed: _committing || editor.committing
                            ? null
                            : () => _cancelEdit(editor),
                      ),
                      const SizedBox(width: OmniSpacing.xs),
                    ],
                    OmniNoteComposerButton(
                      key: const ValueKey('note-commit'),
                      tooltip: action,
                      size: NoteComposerStyle.actionSize,
                      background: background,
                      foreground: Colors.white,
                      overlay: colors.ink.withValues(alpha: 0.05),
                      // 发布与麦克风字形缩为20dp，保留按钮尺寸和提交指示。
                      icon:
                          _committing ||
                              editor.committing ||
                              editor.recordingStarting
                          ? const SizedBox.square(
                              dimension: OmniSize.icon,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Icon(
                              hasContent ? Icons.send : Icons.mic_none,
                              size: OmniSpacing.lg,
                            ),
                      onPressed: !enabled
                          ? null
                          : hasContent
                          ? () => _finishEdit(editor)
                          : () => _perform(editor.startRecording),
                    ),
                  ],
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  /// 取消丢弃本次正文、插入及原音删除草稿，成功后收起历史编辑器。
  Future<void> _cancelEdit(NoteEditorController editor) => _perform(() async {
    if (_committing || editor.committing) return;
    _updateWindows(() => _committing = true);
    try {
      await editor.cancel();
      if (editor.error != null) return;
      await editor.openComposer();
      _updateWindows(() => _expandedNoteId = null);
    } finally {
      _updateWindows(() => _committing = false);
    }
  });

  /// 正文保存前只暂存录音删除，停止当前回听后保留可取消的原件。
  Future<void> _removeEditedAudio(NoteEditorController editor, String id) =>
      _perform(() async {
        if (_committing ||
            editor.committing ||
            editor.frozen ||
            editor.conflicted) {
          return;
        }
        // 异步查询不能把旧草稿操作带到新篇。
        final String? draftId = editor.draftId;
        // 回听绑定待删除片段时先释放文件，避免以后清理遇到Windows占用。
        final NoteAudioPlayerService player = ref.read(noteAudioPlayerProvider);
        // 原件可能来自正式笔记或当前草稿新增采集。
        final AppDatabase database = editor.repository.database;
        final NoteAudioLocalFileRecord? local = await (database.select(
          database.noteAudioLocalFiles,
        )..where((table) => table.id.equals(id))).getSingleOrNull();
        final NoteDraftAudioSegmentRecord? staged = await (database.select(
          database.noteDraftAudioSegments,
        )..where((table) => table.id.equals(id))).getSingleOrNull();
        if (editor.draftId != draftId || _committing || editor.committing) {
          return;
        }
        if (player.currentPath != null &&
            player.currentPath == (local?.localPath ?? staged?.localPath)) {
          await player.stop();
        }
        await editor.removeAudio(id);
      });

  /// 本机草稿原音只提供回听，不启动上传或转写。
  Widget _draftAudio(NoteEditorController editor) {
    if (editor.draftId == null) return const SizedBox.shrink();
    // 草稿音频查询跟随本次编辑代次。
    final AppDatabase database = editor.repository.database;
    return StreamBuilder<List<NoteDraftAudioSegmentRecord>>(
      key: ValueKey('note-composer-audio-${editor.draftId}'),
      stream:
          (database.select(database.noteDraftAudioSegments)
                ..where((table) => table.draftId.equals(editor.draftId!))
                ..orderBy([(table) => OrderingTerm.asc(table.sortOrder)]))
              .watch(),
      builder: (context, snapshot) => Column(
        children: [
          for (final NoteDraftAudioSegmentRecord audio in snapshot.data ?? [])
            if (!editor.isAudioRemoved(audio.id))
              if (_expandedNoteId == editor.draft.id)
                Padding(
                  padding: const EdgeInsets.only(bottom: OmniSpacing.sm),
                  child: NoteAudioCard(
                    key: ValueKey('note-editor-audio-${audio.id}'),
                    segment: NoteAudioSegmentRecord(
                      id: audio.id,
                      noteId: audio.noteId,
                      durationMs: audio.durationMs,
                      mime: audio.mime,
                      sha256: audio.sha256,
                      byteSize: audio.byteSize,
                      sortOrder: audio.sortOrder,
                      createdAt: audio.startedAt,
                      updatedAt: audio.startedAt,
                    ),
                    local: NoteAudioLocalFileRecord(
                      id: audio.id,
                      localPath: audio.localPath,
                      uploadState: 'local',
                      recognitionState: 'idle',
                      consent: false,
                    ),
                    player: ref.read(noteAudioPlayerProvider),
                    recordingActive: editor.recorder.state.isActive,
                    compact: true,
                    editing: true,
                    recognitionEnabled: false,
                    editEnabled:
                        !editor.frozen &&
                        !editor.conflicted &&
                        !editor.committing &&
                        !_committing,
                    onRecognize: () {},
                    onCancel: () {},
                    onInsert: (_) {},
                    onDelete: () => _removeEditedAudio(editor, audio.id),
                  ),
                )
              else
                OmniListRow(
                  title: Text(
                    '草稿录音 · ${_duration(Duration(milliseconds: audio.durationMs))}',
                  ),
                  subtitle: const Text('原音随草稿保存在本机，发布后同步'),
                  trailing: OmniIconButton(
                    tooltip: '回听草稿录音',
                    icon: const Icon(Icons.play_arrow),
                    onPressed:
                        audio.localPath == null ||
                            editor.recorder.state.isActive
                        ? null
                        : () => _perform(
                            () => ref
                                .read(noteAudioPlayerProvider)
                                .play(audio.localPath!),
                          ),
                  ),
                ),
        ],
      ),
    );
  }

  /// 提交成功才收起编辑器，冲突和失败保持原输入。
  Future<void> _finishEdit(NoteEditorController editor) => _perform(() async {
    if (_committing || editor.committing) return;
    _updateWindows(() => _committing = true);
    try {
      // 仓储明确区分成功与冲突，不能把候选当成已发布。
      final NoteCommitResult result = await editor.commit();
      if (result != NoteCommitResult.committed &&
          result != NoteCommitResult.empty) {
        return;
      }
      await editor.openComposer();
      _updateWindows(() => _expandedNoteId = null);
    } finally {
      _updateWindows(() => _committing = false);
    }
  });

  /// 原篇不可用或冲突时，明确另存才发布成新笔记。
  Future<void> _saveDraftAsNew(NoteEditorController editor) =>
      _perform(() async {
        if (_committing || editor.committing) return;
        _updateWindows(() => _committing = true);
        try {
          await editor.saveAsNew();
          if (editor.error == null && !editor.conflicted) {
            await editor.openComposer();
            _updateWindows(() => _expandedNoteId = null);
          }
        } finally {
          _updateWindows(() => _committing = false);
        }
      });

  /// 切回唯一顶部新建草稿，现有历史修改保留在本机。
  Future<void> _activateComposer(NoteEditorController editor) => _perform(
    () async {
      if (_committing || editor.committing || editor.recordingStarting) return;
      // 异步切换前捕获减少动效偏好。
      final Duration motion = OmniMotion.duration(context, OmniMotion.panel);
      await editor.openComposer();
      _updateWindows(() => _expandedNoteId = null);
      if (!mounted) return;
      if (_notesScroll.hasClients) {
        await _notesScroll.animateTo(
          0,
          duration: motion,
          curve: OmniMotion.standardCurve,
        );
      }
      _focus.requestFocus();
    },
  );

  /// 删除指定历史笔记不切换正文，不结束另一篇的录音。
  Future<void> _deleteHistoryNote(String id, NoteEditorController editor) =>
      _perform(() async {
        // 危险操作确认必须指向明确记录。
        final bool confirmed = await showOmniConfirmDialog(
          context,
          title: '移入笔记回收站？',
          message: '这篇笔记的正文、图片、原音和转写将保留 30 天。',
          confirmLabel: '移入回收站',
          danger: true,
        );
        if (!confirmed) return;
        if (editor.recorder.state.noteId == id) await editor.recorder.stop();
        if (editor.draft.id == id) await editor.flush();
        await editor.repository.softDelete(id);
        if (_expandedNoteId == id) await _activateComposer(editor);
      });

  /// 两端共用独立笔记回收站内容，入口与全局设置完全隔离。
  Widget _noteRecycleView() => SingleChildScrollView(
    padding: const EdgeInsets.all(OmniSpacing.xl),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!_windows)
          Align(
            alignment: Alignment.centerLeft,
            child: OmniButton(
              label: '返回全部笔记',
              icon: Icons.arrow_back,
              variant: OmniButtonVariant.text,
              onPressed: () => _updateWindows(() => _recycle = false),
            ),
          ),
        const RecycleBinSection(scope: RecycleBinScope.notes),
      ],
    ),
  );
}
