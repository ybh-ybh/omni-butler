part of 'notes_page.dart';

/// 桌面平铺标签区域独立维护悬停、收起及标签名称搜索。
class _NoteTagSection extends ConsumerStatefulWidget {
  /// 接收全量正式笔记，筛选主区不改变标签计数。
  const _NoteTagSection({
    required this.notes,
    required this.tags,
    required this.selectedIds,
    required this.onSelect,
    required this.onDeleted,
  });

  /// 未删除的正式笔记。
  final List<NoteEntryRecord> notes;

  /// 用户定义的有效标签，包括未使用的标签。
  final List<TaxonomyEntry> tags;

  /// 主区选中的标签身份。
  final Set<String> selectedIds;

  /// 点击标签只修改主区标签筛选。
  final ValueChanged<String> onSelect;

  /// 删除标签后清理失效的主区筛选。
  final ValueChanged<String> onDeleted;

  /// 创建区域内交互状态。
  @override
  ConsumerState<_NoteTagSection> createState() => _NoteTagSectionState();
}

/// 使用独立焦点，避免标签筛选抢占笔记搜索快捷键。
class _NoteTagSectionState extends ConsumerState<_NoteTagSection> {
  /// 标签名称搜索内容。
  final TextEditingController _query = TextEditingController();

  /// 搜索打开后立即聚焦。
  final FocusNode _searchFocus = FocusNode();

  /// 区域悬停显示工具和篇数。
  bool _hovered = false;

  /// 标题行悬停强调文字并显示折叠箭头。
  bool _headerHovered = false;

  /// 折叠指示图标只在自身悬停时使用正文色。
  bool _collapseHovered = false;

  /// 是否收起标签列表。
  bool _collapsed = false;

  /// 是否以搜索框替换标题行。
  bool _searching = false;

  /// 当前悬停的标签行。
  String? _hoveredTag;

  /// 菜单开启后保留对应行的操作入口。
  String? _menuTag;

  /// 释放本区域的输入与焦点资源。
  @override
  void dispose() {
    _query.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// 搜索打开时展开列表，关闭时恢复完整标签集合。
  void _toggleSearch(bool open) {
    setState(() {
      _searching = open;
      _hoveredTag = null;
      _headerHovered = false;
      _collapseHovered = false;
      if (open) _collapsed = false;
      if (!open) _query.clear();
    });
    if (open) _searchFocus.requestFocus();
  }

  /// 删除仅解除标签关联，正文、版本和原音由仓储保留。
  Future<void> _delete(TaxonomyEntry tag) async {
    try {
      // 确认文案覆盖回收站内仍保留的关联。
      final int count = await ref
          .read(taxonomyRepositoryProvider)
          .affectedNoteCount(tag.id);
      if (!mounted) return;
      // 沿用项目标签删除确认语义。
      final bool confirmed = await showOmniConfirmDialog(
        context,
        title: '删除“${tag.name}”？',
        message: '将解除 $count 篇笔记中的标签关联，保留全部正文和原音。',
        confirmLabel: '删除',
        danger: true,
      );
      if (!confirmed || !mounted) return;
      await ref.read(taxonomyRepositoryProvider).delete(tag.id);
      if (!mounted) return;
      widget.onDeleted(tag.id);
      showOmniMessage(
        context,
        message: '已删除“${tag.name}”',
        tone: OmniMessageTone.success,
      );
    } on Object catch (error) {
      if (mounted) {
        showOmniMessage(
          context,
          message: '删除失败：$error',
          tone: OmniMessageTone.error,
        );
      }
    }
  }

  /// 菜单只提供删除标签及编辑名称两个操作。
  void _selectAction(String action, TaxonomyEntry tag) {
    setState(() => _menuTag = null);
    if (action == 'delete') {
      unawaited(_delete(tag));
    } else {
      unawaited(
        showOmniDialog<void>(
          context: context,
          builder: (_) => _NoteTagNameDialog(tag: tag),
        ),
      );
    }
  }

  /// 构建管理入口、搜索输入及平铺标签。
  @override
  Widget build(BuildContext context) {
    // 篇数只汇总正式活动笔记，与草稿和主区筛选无关。
    final Map<String, int> counts = {};
    for (final NoteEntryRecord note in widget.notes) {
      for (final String id in noteTagIds(note.tags)) {
        counts.update(id, (count) => count + 1, ifAbsent: () => 1);
      }
    }
    // 标签搜索与主区查询完全独立。
    final String query = _query.text.trim().toLowerCase();
    // 拷贝后排序，避免修改流提供的集合。
    final List<TaxonomyEntry> tags = widget.tags
        .where((tag) => tag.name.toLowerCase().contains(query))
        .toList();
    // 侧栏标签保留固定父节点，折叠和悬停不把孩子挂回整个滚动页。
    return Semantics(
      key: const ValueKey('notes-tags-region'),
      container: true,
      explicitChildNodes: true,
      child: MouseRegion(
        key: const ValueKey('notes-tags-section'),
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_searching) _searchHeader() else _header(),
            ClipRect(
              child: TweenAnimationBuilder<double>(
                key: const ValueKey('notes-tags-expansion'),
                tween: Tween<double>(begin: 1, end: _collapsed ? 0 : 1),
                duration: OmniMotion.duration(context, OmniMotion.panel),
                curve: OmniMotion.standardCurve,
                builder: (_, progress, child) => Align(
                  alignment: Alignment.topCenter,
                  heightFactor: progress,
                  child: child,
                ),
                child: IgnorePointer(
                  ignoring: _collapsed,
                  child: ExcludeFocus(
                    excluding: _collapsed,
                    child: ExcludeSemantics(
                      excluding: _collapsed,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (tags.isEmpty && !_searching)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: OmniSpacing.sm,
                              ),
                              child: Text(
                                '还没有标签',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          for (final TaxonomyEntry tag in tags)
                            _tagRow(tag, counts[tag.id] ?? 0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 标题与回收站图标对齐，窄栏大字号时将工具放到下一行。
  Widget _header() => MouseRegion(
    key: const ValueKey('notes-tags-header'),
    onEnter: (_) => setState(() => _headerHovered = true),
    onExit: (_) => setState(() => _headerHovered = false),
    child: LayoutBuilder(
      builder: (context, constraints) {
        // 实际字体宽度用于判断四字标题、箭头和工具是否能同排。
        final TextPainter title = TextPainter(
          text: TextSpan(
            text: '全部标签',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout();
        // 标题左内边距、折叠箭头及两个工具各自保留原热区。
        final bool stacked =
            constraints.maxWidth <
            title.width +
                OmniSpacing.sm +
                OmniSize.icon +
                OmniSize.iconButton * 2;
        title.dispose();
        if (stacked) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _headerTitle(),
              Align(alignment: Alignment.centerRight, child: _headerTools()),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: _headerTitle()),
            _headerTools(),
          ],
        );
      },
    ),
  );

  /// 标题保留整行点击，指示箭头沿用独立悬停颜色。
  Widget _headerTitle() => InkWell(
    key: const ValueKey('notes-tags-toggle'),
    onTap: () => setState(() => _collapsed = !_collapsed),
    borderRadius: BorderRadius.circular(OmniRadius.control),
    hoverColor: Colors.transparent,
    highlightColor: Colors.transparent,
    splashColor: Colors.transparent,
    child: Padding(
      padding: const EdgeInsets.only(
        left: OmniSpacing.sm,
        top: OmniSpacing.xs,
        bottom: OmniSpacing.xs,
      ),
      child: Row(
        children: [
          Flexible(
            child: Text(
              '全部标签',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: _headerHovered
                    ? OmniColors.of(context).ink
                    : OmniColors.of(context).muted,
              ),
            ),
          ),
          OmniHoverReveal(
            visible: _headerHovered,
            child: MouseRegion(
              onEnter: (_) => setState(() => _collapseHovered = true),
              onExit: (_) => setState(() => _collapseHovered = false),
              child: Icon(
                _collapsed ? Icons.chevron_right : Icons.expand_more,
                key: const ValueKey('notes-tags-collapse'),
                size: OmniSize.icon,
                color: _collapseHovered
                    ? OmniColors.of(context).ink
                    : OmniColors.of(context).muted,
              ),
            ),
          ),
        ],
      ),
    ),
  );

  /// 工具保留36dp热区，只有背景绘制缩小为28dp。
  Widget _headerTools() => OmniHoverReveal(
    visible: _hovered,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        OmniIconButton(
          tooltip: '搜索标签',
          icon: const Icon(Icons.search, size: OmniSize.icon),
          onPressed: () => _toggleSearch(true),
        ),
        OmniIconButton(
          key: const ValueKey('notes-tags-manage'),
          tooltip: '管理标签',
          icon: const Icon(Icons.sell_outlined, size: OmniSize.icon),
          onPressed: () => TaxonomyManagerDialog.show(
            context,
            module: TaxonomyModule.notes,
            kind: TaxonomyKind.tag,
          ),
        ),
      ],
    ),
  );

  /// 紧凑搜索行替换标题，关闭和 Escape 都清除标签查询。
  Widget _searchHeader() => Focus(
    onKeyEvent: (_, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.escape) {
        _toggleSearch(false);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: OmniTextField(
      key: const ValueKey('notes-tags-search'),
      controller: _query,
      focusNode: _searchFocus,
      onChanged: (_) => setState(() {}),
      style: Theme.of(context).textTheme.bodyMedium,
      textAlignVertical: TextAlignVertical.center,
      decoration: InputDecoration(
        hintText: '筛选',
        filled: true,
        fillColor: Color.alphaBlend(
          OmniColors.of(context).ink.withValues(alpha: 0.08),
          OmniColors.of(context).paper,
        ),
        hoverColor: Colors.transparent,
        focusColor: Colors.transparent,
        hintStyle: Theme.of(context).textTheme.bodyMedium
            ?.copyWith(color: OmniColors.of(context).muted),
        contentPadding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(height: OmniSize.iconButton),
        border: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(OmniRadius.panel)),
          borderSide: BorderSide.none,
        ),
        enabledBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(OmniRadius.panel)),
          borderSide: BorderSide.none,
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(OmniRadius.panel)),
          borderSide: BorderSide.none,
        ),
        prefixIcon: const Icon(Icons.search, size: OmniSize.icon),
        prefixIconConstraints: const BoxConstraints.tightFor(
          width: OmniSize.iconButton,
          height: OmniSize.iconButton,
        ),
        suffixIconConstraints: const BoxConstraints.tightFor(
          width: OmniSize.iconButton,
          height: OmniSize.iconButton,
        ),
        suffixIcon: OmniIconButton(
          tooltip: '关闭标签搜索',
          icon: const Icon(Icons.close, size: OmniSize.icon),
          onPressed: () => _toggleSearch(false),
        ),
      ),
    ),
  );

  /// 行悬停以菜单替换篇数，菜单点击不触发主区筛选。
  Widget _tagRow(TaxonomyEntry tag, int count) {
    // 选中标签保留浅主题底色，菜单的中性灰和正文色都清晰可见。
    final bool selected = widget.selectedIds.contains(tag.id);
    // 数量和更多图标使用相同的布局占位。
    final Color foreground = OmniColors.of(context).ink;
    // 菜单弹出后鼠标进入覆盖层也保留入口。
    final bool menu = _hoveredTag == tag.id || _menuTag == tag.id;
    return MouseRegion(
      key: ValueKey('notes-tag-${tag.id}'),
      onEnter: (_) => setState(() => _hoveredTag = tag.id),
      onExit: (_) => setState(() => _hoveredTag = null),
      child: Padding(
        padding: const EdgeInsets.only(bottom: OmniSpacing.xxs),
        child: Semantics(
          key: ValueKey('notes-tag-region-${tag.id}'),
          container: true,
          explicitChildNodes: true,
          selected: selected,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: selected
                  ? Theme.of(context).colorScheme.primaryContainer
                  : OmniColors.of(context).canvas,
              borderRadius: BorderRadius.circular(OmniRadius.control),
            ),
            child: OmniListRow(
              borderRadius: BorderRadius.circular(OmniRadius.control),
              padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.sm),
              leading: Icon(Icons.tag, size: OmniSize.icon, color: foreground),
              title: Text(
                tag.name,
                style: TextStyle(color: foreground),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => widget.onSelect(tag.id),
              trailing: SizedBox.square(
                dimension: OmniSize.iconButton,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    OmniHoverReveal(
                      visible: _hovered && !menu,
                      child: Center(
                        child: Text(
                          '$count',
                          key: ValueKey('notes-tag-count-${tag.id}'),
                          style: TextStyle(color: foreground),
                        ),
                      ),
                    ),
                    OmniHoverReveal(
                      visible: menu,
                      child: OmniPopupMenuButton<String>(
                        key: ValueKey('notes-tag-menu-${tag.id}'),
                        tooltip: '标签操作',
                        icon: const Icon(Icons.more_horiz),
                        onOpened: () => setState(() => _menuTag = tag.id),
                        onCanceled: () => setState(() => _menuTag = null),
                        onSelected: (action) => _selectAction(action, tag),
                        itemBuilder: (_) => [
                          OmniPopupMenuItem(
                            value: 'delete',
                            label: '删除标签',
                            icon: Icons.delete_outline,
                            danger: true,
                          ),
                          OmniPopupMenuItem(
                            value: 'rename',
                            label: '编辑名称',
                            icon: Icons.edit_outlined,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 平铺标签名称编辑，保留原有身份、颜色与排列位置。
class _NoteTagNameDialog extends ConsumerStatefulWidget {
  /// 创建名称编辑小弹窗。
  const _NoteTagNameDialog({required this.tag});

  /// 需要改名的有效标签。
  final TaxonomyEntry tag;

  /// 创建名称输入及保存状态。
  @override
  ConsumerState<_NoteTagNameDialog> createState() => _NoteTagNameDialogState();
}

/// 失败时保留输入，只有仓储成功后关闭弹窗。
class _NoteTagNameDialogState extends ConsumerState<_NoteTagNameDialog> {
  /// 保留当前名称及用户未提交的输入。
  late final TextEditingController _name = TextEditingController(
    text: widget.tag.name,
  );

  /// 阻止保存中的重复提交。
  bool _saving = false;

  /// 展示名称约束或持久化错误。
  String? _error;

  /// 释放弹窗输入。
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// 保存平铺名称，不生成层级标签。
  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(taxonomyRepositoryProvider)
          .save(
            TaxonomyDraft(
              id: widget.tag.id,
              module: TaxonomyModule.notes,
              kind: TaxonomyKind.tag,
              name: _name.text,
              colorValue: widget.tag.colorValue,
              sortOrder: widget.tag.sortOrder,
            ),
          );
      if (mounted) Navigator.of(context).pop();
    } on Object catch (error) {
      if (mounted) {
        setState(
          () =>
              _error = error is FormatException ? error.message : '保存失败：$error',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 图标、名称和保存按钮排在同一行，沿用 Omni 弹窗样式。
  @override
  Widget build(BuildContext context) => OmniDialogScaffold(
    title: '编辑名称',
    width: 420,
    onWindowsEnter: () => unawaited(_save()),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: OmniSpacing.xs),
          child: Icon(Icons.tag),
        ),
        const SizedBox(width: OmniSpacing.sm),
        Expanded(
          child: OmniTextField(
            key: const ValueKey('notes-tag-name'),
            controller: _name,
            autofocus: true,
            enabled: !_saving,
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            decoration: InputDecoration(hintText: '标签名称', errorText: _error),
          ),
        ),
        const SizedBox(width: OmniSpacing.sm),
        OmniButton(
          onPressed: _saving ? null : () => unawaited(_save()),
          label: _saving ? '保存中' : '保存',
        ),
      ],
    ),
  );
}
