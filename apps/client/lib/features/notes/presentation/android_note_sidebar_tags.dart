part of 'android_notes_view.dart';

/// 每次异步标签操作都核验原资料库与有效notes/tag身份。
Future<TaxonomyEntry> _androidRequireTag(
  BuildContext context,
  WidgetRef ref,
  AppDatabase source,
  String id,
) async {
  // 仓储查回最新事实，不用菜单打开时的旧名称覆盖新数据。
  final TaxonomyEntry? tag = await (source.select(
    source.taxonomyEntries,
  )..where((table) => table.id.equals(id))).getSingleOrNull();
  if (!context.mounted || !identical(ref.read(appDatabaseProvider), source)) {
    throw StateError('数据源已切换，请重新打开标签');
  }
  if (tag == null ||
      tag.module != 'notes' ||
      tag.kind != 'tag' ||
      tag.deletedAt != null) {
    throw StateError('标签已删除或不可用');
  }
  return tag;
}

/// 安卓标签操作只复用业务层，不调用桌面呈现。
extension _AndroidSidebarTags on _AndroidNoteSidebarState {
  /// 标题与工具在窄屏大字号下自然分行。
  Widget _tagHeader(List<TaxonomyEntry> tags) => LayoutBuilder(
    builder: (context, constraints) {
      // 当前字号对应的小标题宽度，三项工具各保留48dp。
      final bool stacked =
          constraints.maxWidth <
          MediaQuery.textScalerOf(context).scale(70) + OmniSize.touch * 3;
      // 辅助入口使用紧凑图标，排序一击直达。
      final Widget actions = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          OmniIconButton(
            tooltip: '搜索标签',
            icon: const Icon(Icons.search),
            onPressed: _busy
                ? null
                : () => _update(() => _searching = !_searching),
          ),
          OmniIconButton(
            key: const ValueKey('android-tags-sort'),
            tooltip: '标签排序',
            icon: const Icon(Icons.tune),
            onPressed: _busy
                ? null
                : () => _openTagPage(
                    _AndroidTagSortPage(source: widget.source, tags: tags),
                  ),
          ),
          OmniIconButton(
            tooltip: '新建标签',
            icon: const Icon(Icons.add),
            onPressed: _busy
                ? null
                : () => _openTagPage(
                    _AndroidTagEditorPage(source: widget.source),
                  ),
          ),
        ],
      );
      return stacked
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionTitle('全部标签'),
                Align(alignment: Alignment.centerRight, child: actions),
              ],
            )
          : Row(
              children: [
                Expanded(child: _sectionTitle('全部标签')),
                actions,
              ],
            );
    },
  );

  /// 选中外观只落在用户实际点击的分区。
  Widget _tagRow(TaxonomyEntry tag, String partition, String origin) {
    // 置顶与全部分区具有不同的稳定行标识。
    final String rowId = partition == 'pinned' ? 'pinned-${tag.id}' : tag.id;
    // 菜单不触发该行筛选，也不改变已选来源。
    final bool selected =
        !_clearedSelection &&
        !widget.recycle &&
        widget.filter.tagIds.contains(tag.id) &&
        origin == partition;
    return _AndroidSidebarRow(
      key: ValueKey('notes-tag-$rowId'),
      title: tag.name,
      selected: selected,
      leading: NoteTagIcon(
        emoji: tag.iconEmoji,
        color: selected
            ? OmniColors.of(context).accentInk
            : OmniColors.of(context).ink,
      ),
      onTap: () => _select('tag', tag.id, partition),
      trailing: Builder(
        builder: (anchor) => OmniIconButton(
          key: ValueKey('notes-tag-menu-$rowId'),
          tooltip: '标签操作：${tag.name}',
          icon: Icon(
            Icons.more_horiz,
            color: selected ? OmniColors.of(context).accentInk : null,
          ),
          onPressed: _busy ? null : () => _tagMenu(anchor, tag),
        ),
      ),
    );
  }

  /// 二级页面覆盖抽屉但保留它的滚动与搜索。
  Future<void> _openTagPage(Widget page) async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    _update(() => _busy = true);
    try {
      await Navigator.of(context, rootNavigator: true).push<void>(
        _AndroidSidebarPageRoute(
          builder: (_) => page,
          reduced: OmniMotion.reduce(context),
        ),
      );
    } finally {
      _update(() => _busy = false);
    }
  }

  /// 菜单打开和操作完成之间始终固定标签ID。
  Future<void> _tagMenu(
    BuildContext anchorContext,
    TaxonomyEntry snapshot,
  ) async {
    if (_busy || ref.read(noteEditorProvider).committing) return;
    _update(() => _busy = true);
    try {
      // 显示前核验原记录，置顶状态使用最新值。
      final TaxonomyEntry tag = await _androidRequireTag(
        context,
        ref,
        widget.source,
        snapshot.id,
      );
      if (!mounted || !anchorContext.mounted) return;
      // 按钮右下缘为菜单锚点，位置由共享路由自动避让。
      final RenderBox anchor = anchorContext.findRenderObject()! as RenderBox;
      // 根覆盖层与抽屉共用同一坐标空间。
      final RenderBox overlay =
          Navigator.of(
                context,
                rootNavigator: true,
              ).overlay!.context.findRenderObject()!
              as RenderBox;
      // 稳定锚点不在关闭动画阶段再访问旧元素。
      final Offset point = anchor.localToGlobal(
        Offset(anchor.size.width, anchor.size.height),
        ancestor: overlay,
      );
      // 删除子页在同一菜单内切换，不创建第二块侧向浮层。
      final String? action = await showOmniMenu<String>(
        context: context,
        wholePanelTransition: true,
        useRootNavigator: true,
        position: RelativeRect.fromRect(
          point & Size.zero,
          Offset.zero & overlay.size,
        ),
        constraints: BoxConstraints.tightFor(
          width: math.min(240, MediaQuery.sizeOf(context).width - 24),
        ),
        menuPadding: EdgeInsets.zero,
        items: [_AndroidTagMenuEntry(pinned: tag.isPinned)],
      );
      if (!mounted || action == null) return;
      // 等待菜单期间同步删除或换库时停止动作。
      final TaxonomyEntry latest = await _androidRequireTag(
        context,
        ref,
        widget.source,
        tag.id,
      );
      if (!mounted) return;
      if (action == 'pin') {
        await ref
            .read(taxonomyRepositoryProvider)
            .setPinned(latest.id, !latest.isPinned);
        if (mounted &&
            latest.isPinned &&
            widget.filter.tagIds.contains(latest.id)) {
          _update(() => _origin = 'all');
          widget.onOrigin('all');
        }
      } else if (action == 'rename') {
        FocusScope.of(context).unfocus();
        await Navigator.of(context, rootNavigator: true).push<void>(
          _AndroidSidebarPageRoute(
            builder: (_) =>
                _AndroidTagEditorPage(source: widget.source, tag: latest),
            reduced: OmniMotion.reduce(context),
          ),
        );
      } else {
        await _deleteTag(latest, withNotes: action == 'delete-notes');
      }
    } on Object catch (error) {
      if (mounted) {
        showOmniMessage(
          context,
          message: '$error',
          tone: OmniMessageTone.error,
        );
      }
    } finally {
      _update(() => _busy = false);
    }
  }

  /// 两种删除复用既有事务和录音／草稿准备门禁。
  Future<void> _deleteTag(TaxonomyEntry tag, {required bool withNotes}) async {
    // 计数和提交共用原资料库仓储，不在异步间隙重新读取新源。
    final TaxonomyRepository repository = ref.read(taxonomyRepositoryProvider);
    // 原数据源里的业务仓储，不能在确认后临时换成另一库。
    final NoteTagActions actions = NoteTagActions(
      widget.source,
      ref.read(noteRepositoryProvider),
      repository,
    );
    // 固定负责资产排空的原编辑控制器。
    final NoteEditorController editor = ref.read(noteEditorProvider);
    while (mounted) {
      // 整篇回收需要确认准确的有效篇集合。
      final Set<String> ids = withNotes
          ? await actions.activeNoteIds(tag.id)
          : const {};
      // 仅移除标签同样说明关联数量。
      final int count = withNotes
          ? ids.length
          : await repository.affectedNoteCount(tag.id);
      if (!mounted ||
          !identical(ref.read(appDatabaseProvider), widget.source)) {
        return;
      }
      // 选择删除方式并不跳过现有危险操作确认。
      final bool confirmed = await showOmniConfirmDialog(
        context,
        title: withNotes ? '删除“${tag.name}”和笔记？' : '移除“${tag.name}”？',
        message: withNotes
            ? '将删除此标签，并将 $count 篇笔记移入回收站，包含同时有其他标签的笔记。正文、图片和原音保留 30 天，未发布修改保留在本机草稿中。'
            : '将解除 $count 篇笔记中的标签关联，保留全部正文、图片和原音。',
        confirmLabel: withNotes ? '删除标签并移入回收站' : '仅移除标签',
        danger: true,
      );
      if (!confirmed || !mounted) return;
      await _androidRequireTag(context, ref, widget.source, tag.id);
      try {
        if (withNotes) {
          await editor.prepareForDeletion(
            ids,
            action: () async {
              await _androidRequireTag(context, ref, widget.source, tag.id);
              await actions.deleteTagAndNotes(tag.id, expectedNoteIds: ids);
            },
          );
        } else {
          await repository.delete(tag.id);
        }
      } on NoteTagNotesChanged {
        if (!mounted) return;
        showOmniMessage(context, message: '关联笔记已变化，请重新确认删除范围。');
        continue;
      }
      if (!mounted ||
          !identical(ref.read(appDatabaseProvider), widget.source)) {
        return;
      }
      _update(() {
        if (widget.filter.tagIds.contains(tag.id)) _clearedSelection = true;
      });
      widget.onDeleted(tag.id);
      showOmniMessage(
        context,
        message: withNotes ? '标签及关联笔记已移入回收站' : '标签已移除',
        tone: OmniMessageTone.success,
      );
      return;
    }
  }
}

/// 排序和名称编辑是普通二级导航，按视频从右侧进入。
class _AndroidSidebarPageRoute extends PageRouteBuilder<void> {
  /// 根路由覆盖全局底栏，其他模态动效不变。
  _AndroidSidebarPageRoute({
    required WidgetBuilder builder,
    required bool reduced,
  }) : super(
         transitionDuration: reduced
             ? Duration.zero
             : const Duration(milliseconds: 300),
         reverseTransitionDuration: reduced
             ? Duration.zero
             : const Duration(milliseconds: 220),
         pageBuilder: (context, _, _) => builder(context),
         transitionsBuilder: (context, animation, _, child) => reduced
             ? child
             : SlideTransition(
                 position: animation
                     .drive(CurveTween(curve: Curves.easeOutCubic))
                     .drive(Tween(begin: const Offset(1, 0), end: Offset.zero)),
                 child: child,
               ),
       );
}

/// 自定义内容仍通过Omni菜单提供遮罩、定位与焦点恢复。
class _AndroidTagMenuEntry extends PopupMenuEntry<String> {
  /// 菜单打开时的最新置顶事实。
  final bool pinned;

  /// 创建同宽的两层菜单。
  const _AndroidTagMenuEntry({required this.pinned});

  /// 实际内容可随字号自然增高。
  @override
  double get height => OmniSize.touch * 3 + 8;

  /// 入口自身不代表某一个动作。
  @override
  bool represents(String? value) => false;

  /// 子页切换只影响本浮层。
  @override
  State<_AndroidTagMenuEntry> createState() => _AndroidTagMenuState();
}

/// 同一浮层内横向切换删除选项，按返回先回一级菜单。
class _AndroidTagMenuState extends State<_AndroidTagMenuEntry> {
  /// 当前是否显示删除选项。
  bool _deleting = false;

  /// 菜单行完整保留48dp以上触控与换行。
  Widget _row(
    String label,
    IconData icon,
    VoidCallback action, {
    bool danger = false,
    bool arrow = false,
  }) => OmniInkWell(
    onTap: action,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: OmniSize.touch),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: OmniSpacing.md,
          vertical: OmniSpacing.sm,
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: OmniSize.icon,
              color: danger
                  ? OmniColors.of(context).danger
                  : OmniColors.of(context).ink,
            ),
            const SizedBox(width: OmniSpacing.sm),
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: danger
                      ? OmniColors.of(context).danger
                      : OmniColors.of(context).ink,
                ),
              ),
            ),
            if (arrow) const Icon(Icons.chevron_right),
          ],
        ),
      ),
    ),
  );

  /// 固定宽度内淡入横移，不改变背景抽屉状态。
  @override
  Widget build(BuildContext context) => PopScope<String>(
    canPop: !_deleting,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) setState(() => _deleting = false);
    },
    child: ClipRect(
      child: AnimatedSwitcher(
        duration: OmniMotion.duration(
          context,
          const Duration(milliseconds: 160),
        ),
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: animation.drive(
              Tween(
                begin: OmniMotion.reduce(context)
                    ? Offset.zero
                    : const Offset(.12, 0),
                end: Offset.zero,
              ),
            ),
            child: child,
          ),
        ),
        child: Column(
          key: ValueKey(_deleting),
          mainAxisSize: MainAxisSize.min,
          children: _deleting
              ? [
                  _row(
                    '删除标签',
                    Icons.chevron_left,
                    () => setState(() => _deleting = false),
                  ),
                  const Divider(height: 1),
                  _row(
                    '仅移除标签',
                    Icons.label_off_outlined,
                    () => Navigator.pop(context, 'delete'),
                    danger: true,
                  ),
                  _row(
                    '删除标签和笔记',
                    Icons.delete_outline,
                    () => Navigator.pop(context, 'delete-notes'),
                    danger: true,
                  ),
                ]
              : [
                  _row(
                    widget.pinned ? '取消置顶' : '置顶',
                    Icons.vertical_align_top,
                    () => Navigator.pop(context, 'pin'),
                  ),
                  _row(
                    '编辑名称和图标',
                    Icons.edit_outlined,
                    () => Navigator.pop(context, 'rename'),
                  ),
                  const Divider(height: 1),
                  _row(
                    '删除标签',
                    Icons.delete_outline,
                    () => setState(() => _deleting = true),
                    danger: true,
                    arrow: true,
                  ),
                ],
        ),
      ),
    ),
  );
}
