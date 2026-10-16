part of 'android_notes_view.dart';

/// 独立搜索覆盖全局底栏，取消后主列表条件和位置保持原样。
class _AndroidNoteSearch extends ConsumerStatefulWidget {
  /// 搜索结果可以编辑，关闭编辑后仍回到当前查询。
  final Future<void> Function(String id, {NoteVersionRecord? version}) onEdit;

  /// 每次进入从全部正式笔记开始查询。
  const _AndroidNoteSearch({required this.onEdit});

  /// 查询与阅读状态仅属于当前搜索页。
  @override
  ConsumerState<_AndroidNoteSearch> createState() => _AndroidNoteSearchState();
}

/// 输入不自动弹键盘，快捷筛选可直接点击。
class _AndroidNoteSearchState extends ConsumerState<_AndroidNoteSearch> {
  /// 关键词只保存在搜索会话内。
  final TextEditingController _query = TextEditingController();

  /// 结果滚动与主列表分离。
  final ScrollController _scroll = ScrollController();

  /// 已应用的筛选，筛选面板使用独立副本。
  NoteSearchFilter _filter = const NoteSearchFilter.empty();

  /// 搜索结果只展开一篇全文。
  String? _expanded;

  /// 防止重复弹出筛选面板。
  bool _filterOpen = false;

  /// 释放本页输入资源。
  @override
  void dispose() {
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 快捷条件按交集组合，无标签明确清除指定标签。
  void _toggle(String kind) => setState(() {
    if (kind == 'none') {
      _filter = _filter.copyWith(
        tagMode: _filter.tagMode == 'none' ? 'include' : 'none',
        tagIds: {},
      );
    } else if (kind == 'anniversary') {
      _filter = _filter.copyWith(onThisDay: !_filter.onThisDay);
    } else {
      // 复制集合，不修改任何已应用快照。
      final Set<String> contents = {..._filter.contents};
      if (!contents.add(kind)) contents.remove(kind);
      _filter = _filter.copyWith(contents: contents);
    }
    _expanded = null;
    if (_scroll.hasClients) _scroll.jumpTo(0);
  });

  /// 仅明确提交时记录完整词条，组合输入期间不提交候选文字。
  void _submit([String? query]) {
    if (_query.value.composing.isValid && !_query.value.composing.isCollapsed) {
      return;
    }
    // 正式提交去除首尾空白，保留关键词内部格式。
    final String text = (query ?? _query.text).trim();
    _query.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    unawaited(ref.read(noteSearchHistoryProvider.notifier).record(text));
    FocusScope.of(context).unfocus();
    setState(() => _expanded = null);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  /// 打开结果编辑前提交查询词，返回后保留当前结果。
  Future<void> _editResult(String id, {NoteVersionRecord? version}) async {
    // 编辑只记录明确的查询历史，不重新提交查询或把结果滚回顶部。
    if (!_query.value.composing.isValid || _query.value.composing.isCollapsed) {
      await ref
          .read(noteSearchHistoryProvider.notifier)
          .record(_query.text.trim());
    }
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    await widget.onEdit(id, version: version);
  }

  /// 点击应用才替换查询条件，返回和遮罩都丢弃面板临时选择。
  Future<void> _filters() async {
    if (_filterOpen) return;
    _filterOpen = true;
    try {
      // 输入焦点不随筛选关闭恢复，防止取消筛选后意外弹出键盘。
      FocusScope.of(context).unfocus();
      // 自然高度的根导航面板，原搜索页和一级导航都保留状态。
      final NoteSearchFilter? filter =
          await Navigator.of(
            context,
            rootNavigator: true,
          ).push<NoteSearchFilter>(
            ModalBottomSheetRoute<NoteSearchFilter>(
              builder: (_) => _AndroidNoteFilterSheet(value: _filter),
              capturedThemes: InheritedTheme.capture(
                from: context,
                to: Navigator.of(context, rootNavigator: true).context,
              ),
              isScrollControlled: true,
              useSafeArea: true,
              enableDrag: false,
              showDragHandle: false,
              backgroundColor: Colors.transparent,
              modalBarrierColor: Colors.black.withValues(alpha: .42),
              barrierLabel: '取消筛选',
              sheetAnimationStyle: OmniMotion.reduce(context)
                  ? AnimationStyle.noAnimation
                  : const AnimationStyle(
                      duration: OmniMotion.panel,
                      reverseDuration: OmniMotion.panel,
                    ),
            ),
          );
      if (mounted && filter != null) {
        setState(() {
          _filter = filter;
          _expanded = null;
        });
        _submit();
      }
    } finally {
      _filterOpen = false;
    }
  }

  /// 搜索框、快捷条件和结果在同一页面，不覆盖主列表查询。
  @override
  Widget build(BuildContext context) {
    // 搜索始终基于正式全量笔记。
    final AsyncValue<List<NoteEntryRecord>> notes = ref.watch(notesProvider);
    // 当前主题的语义颜色。
    final OmniColors colors = OmniColors.of(context);
    // 关键词或筛选是否已形成实际查询。
    final bool active = _query.text.trim().isNotEmpty || _filter.isActive;
    return Scaffold(
      key: const ValueKey('android-note-search-page'),
      backgroundColor: colors.canvas,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(OmniSpacing.md),
              child: Row(
                children: [
                  Expanded(
                    child: OmniTextField(
                      key: const ValueKey('android-note-search-input'),
                      controller: _query,
                      textInputAction: TextInputAction.search,
                      onSubmitted: _submit,
                      // 保留组合区供提交门禁检查，不能让框架先清空再误记候选。
                      onEditingComplete: () {},
                      decoration: InputDecoration(
                        hintText: '搜索',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: OmniIconButton(
                          tooltip: '筛选笔记',
                          icon: Icon(
                            Icons.filter_list,
                            color: _filter.isActive
                                ? colors.brand
                                : colors.muted,
                          ),
                          onPressed: _filters,
                        ),
                      ),
                      onChanged: (_) => setState(() {
                        _expanded = null;
                      }),
                    ),
                  ),
                  OmniButton(
                    label: '取消',
                    variant: OmniButtonVariant.text,
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            if (_query.text.trim().isEmpty)
              Flexible(
                fit: FlexFit.loose,
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      OmniSpacing.md,
                      OmniSpacing.sm,
                      OmniSpacing.md,
                      OmniSpacing.md,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '快捷搜索',
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(color: colors.muted),
                        ),
                        const SizedBox(height: OmniSpacing.md),
                        Wrap(
                          spacing: OmniSpacing.xs,
                          children: [
                            // 快捷条件保留交集，视觉40dp与触控48dp分别约束。
                            for (final (String, String, IconData) item in [
                              ('none', '无标签', Icons.sell_outlined),
                              ('link', '有链接', Icons.link),
                              ('image', '有图片', Icons.image_outlined),
                              ('audio', '有语音', Icons.graphic_eq),
                              (
                                'anniversary',
                                '那年今日',
                                Icons.calendar_today_outlined,
                              ),
                            ])
                              _AndroidSearchChip(
                                key: ValueKey('android-quick-${item.$1}'),
                                label: item.$2,
                                icon: item.$3,
                                selected: item.$1 == 'none'
                                    ? _filter.tagMode == 'none'
                                    : item.$1 == 'anniversary'
                                    ? _filter.onThisDay
                                    : _filter.contents.contains(item.$1),
                                onTap: () => _toggle(item.$1),
                              ),
                          ],
                        ),
                        _AndroidSearchHistory(onSelected: _submit),
                      ],
                    ),
                  ),
                ),
              ),
            if (_filter.isActive)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.md),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: OmniButton(
                    label: '清除筛选',
                    variant: OmniButtonVariant.text,
                    onPressed: () => setState(
                      () => _filter = const NoteSearchFilter.empty(),
                    ),
                  ),
                ),
              ),
            if (active)
              Expanded(
                child: _AndroidNoteList(
                  notes: notes,
                  filter: _filter,
                  query: _query.text,
                  controller: _scroll,
                  expandedId: _expanded,
                  onExpand: (id) {
                    // 首次展开正文视为打开结果，收起不产生新的历史提交。
                    final bool collapse = _expanded == id;
                    if (!collapse) _submit();
                    setState(() => _expanded = collapse ? null : id);
                  },
                  onEdit: _editResult,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
