import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/shared/taxonomy/taxonomy_manager_dialog.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

import '../data/note_providers.dart';
import '../data/note_repository.dart';
import '../data/note_tag_actions.dart';
import 'windows_note_tag_editor.dart';

/// 两级标签菜单按参考图使用同宽面板，窗口边缘由共享路由约束。
const double _noteTagMenuWidth = 240;

/// 桌面平铺标签区域独立维护悬停、收起及标签名称搜索。
class NoteTagSection extends ConsumerStatefulWidget {
  /// 接收全量正式笔记，筛选主区不改变标签计数。
  const NoteTagSection({
    required this.notes,
    required this.tags,
    required this.selectedIds,
    required this.onSelect,
    required this.onDeleted,
    this.touchActions = false,
    super.key,
  });

  /// 移动端操作入口常驻，不要求悬停。
  final bool touchActions;

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
  ConsumerState<NoteTagSection> createState() => _NoteTagSectionState();
}

/// 使用独立焦点，避免标签筛选抢占笔记搜索快捷键。
class _NoteTagSectionState extends ConsumerState<NoteTagSection> {
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

  /// 键盘停留在标签行或其更多按钮时，同样保留操作入口。
  String? _focusedTag;

  /// 菜单开启后保留对应行的操作入口。
  String? _menuTag;

  /// 异步标签操作和确认期间避免重复提交。
  bool _busy = false;

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

  /// 两种删除共用确认流程，关联笔记回收前保护未发布内容。
  Future<void> _delete(TaxonomyEntry tag, {bool withNotes = false}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // 同一数据源内组合既有仓储，不让通用标签层依赖笔记业务。
      final NoteTagActions actions = NoteTagActions(
        ref.read(appDatabaseProvider),
        ref.read(noteRepositoryProvider),
        ref.read(taxonomyRepositoryProvider),
      );
      while (mounted) {
        // 固定本次确认对象，准备期间同步变化必须重新确认。
        final Set<String> noteIds = withNotes
            ? await actions.activeNoteIds(tag.id)
            : const {};
        // 仅删标签的计数包含回收站中仍保留的关联。
        final int count = withNotes
            ? noteIds.length
            : await ref
                  .read(taxonomyRepositoryProvider)
                  .affectedNoteCount(tag.id);
        if (!mounted) return;
        // 多标签笔记也会整篇回收，确认前明确恢复期限。
        final bool confirmed = await showOmniConfirmDialog(
          context,
          title: withNotes ? '删除“${tag.name}”和笔记？' : '删除“${tag.name}”？',
          message: withNotes
              ? '将删除此标签，并将 $count 篇笔记移入回收站，包含同时有其他标签的笔记。正文、图片和原音保留 30 天，未发布修改保留在本机草稿中。'
              : '将解除 $count 篇笔记中的标签关联，保留全部正文和原音。',
          confirmLabel: withNotes ? '删除标签并移入回收站' : '删除',
          danger: true,
        );
        if (!confirmed || !mounted) return;
        if (withNotes) {
          try {
            await ref
                .read(noteEditorProvider)
                .prepareForDeletion(
                  noteIds,
                  action: () async {
                    if (!mounted) return;
                    await actions.deleteTagAndNotes(
                      tag.id,
                      expectedNoteIds: noteIds,
                    );
                  },
                );
          } on NoteTagNotesChanged {
            if (!mounted) return;
            showOmniMessage(context, message: '关联笔记已变化，请重新确认删除范围。');
            continue;
          }
        } else {
          await ref.read(taxonomyRepositoryProvider).delete(tag.id);
        }
        if (!mounted) return;
        widget.onDeleted(tag.id);
        showOmniMessage(
          context,
          message: withNotes
              ? '已删除“${tag.name}”，$count 篇笔记已移入回收站'
              : '已删除“${tag.name}”',
          tone: OmniMessageTone.success,
        );
        return;
      }
    } on Object catch (error) {
      if (mounted) {
        showOmniMessage(
          context,
          message: '删除失败：$error',
          tone: OmniMessageTone.error,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 置顶只修改标签字段，不改变当前笔记或标签筛选。
  Future<void> _setPinned(TaxonomyEntry tag) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(taxonomyRepositoryProvider)
          .setPinned(tag.id, !tag.isPinned);
    } on Object catch (error) {
      if (mounted) {
        showOmniMessage(
          context,
          message: '置顶设置失败：$error',
          tone: OmniMessageTone.error,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 编辑期间保持原行的入口，浮层关闭后恢复正常悬停显示。
  void _selectAction(
    String action,
    TaxonomyEntry tag, {
    required BuildContext anchorContext,
    required String rowId,
  }) {
    // 被编辑器提交保护拦截的动作同样应清理菜单入口状态。
    final bool blocked = _busy || ref.read(noteEditorProvider).committing;
    setState(() => _menuTag = !blocked && action == 'rename' ? rowId : null);
    if (blocked) return;
    if (action == 'delete') {
      unawaited(_delete(tag));
    } else if (action == 'delete-notes') {
      unawaited(_delete(tag, withNotes: true));
    } else if (action == 'pin') {
      unawaited(_setPinned(tag));
    } else if (action == 'rename') {
      unawaited(
        showWindowsNoteTagEditor(
          context: context,
          anchorContext: anchorContext,
          tag: tag,
        ).whenComplete(() {
          if (mounted) setState(() => _menuTag = null);
        }),
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
    // 置顶快捷入口保留管理器顺序，不受全部标签搜索和收起影响。
    final List<TaxonomyEntry> pinned = widget.tags
        .where((tag) => tag.isPinned)
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
            Semantics(
              key: const ValueKey('notes-pinned-tags-region'),
              container: true,
              explicitChildNodes: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (pinned.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.only(
                        left: OmniSpacing.sm,
                        top: OmniSpacing.xs,
                        bottom: OmniSpacing.xs,
                      ),
                      child: Text(
                        '置顶标签',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    for (final TaxonomyEntry tag in pinned)
                      _tagRow(tag, counts[tag.id] ?? 0, pinned: true),
                    const SizedBox(height: OmniSpacing.lg),
                  ],
                ],
              ),
            ),
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
  Widget _headerTitle() => OmniDisclosureToggle(
    expanded: !_collapsed,
    child: OmniInkWell(
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
              visible: _headerHovered || widget.touchActions,
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
    ),
  );

  /// 工具保留36dp热区，只有背景绘制缩小为28dp。
  Widget _headerTools() => OmniHoverReveal(
    visible: _hovered || widget.touchActions,
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
  Widget _tagRow(TaxonomyEntry tag, int count, {bool pinned = false}) {
    // 两个分区共享业务身份，但交互和语义节点必须分别稳定。
    final String rowId = pinned ? 'pinned-${tag.id}' : tag.id;
    // 选中标签保留浅主题底色，菜单的中性灰和正文色都清晰可见。
    final bool selected = widget.selectedIds.contains(tag.id);
    // 数量和更多图标使用相同的布局占位。
    final Color foreground = OmniColors.of(context).ink;
    // 菜单弹出后鼠标进入覆盖层也保留入口。
    final bool menu =
        widget.touchActions ||
        _hoveredTag == rowId ||
        _focusedTag == rowId ||
        _menuTag == rowId;
    return Focus(
      skipTraversal: true,
      onFocusChange: (focused) {
        if ((_focusedTag == rowId) == focused) return;
        setState(() => _focusedTag = focused ? rowId : null);
      },
      child: MouseRegion(
        key: ValueKey('notes-tag-$rowId'),
        onEnter: (_) => setState(() => _hoveredTag = rowId),
        onExit: (_) {
          if (_hoveredTag == rowId) setState(() => _hoveredTag = null);
        },
        child: Padding(
          padding: const EdgeInsets.only(bottom: OmniSpacing.xxs),
          child: Semantics(
            key: ValueKey('notes-tag-region-$rowId'),
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
                leading: NoteTagIcon(
                  key: ValueKey('notes-tag-icon-$rowId'),
                  emoji: tag.iconEmoji,
                  color: foreground,
                ),
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
                            key: ValueKey('notes-tag-count-$rowId'),
                            style: TextStyle(color: foreground),
                          ),
                        ),
                      ),
                      OmniHoverReveal(
                        visible: menu,
                        child: Builder(
                          builder: (anchorContext) =>
                              OmniPopupMenuButton<String>(
                                key: ValueKey('notes-tag-menu-$rowId'),
                                tooltip: '标签操作',
                                icon: const Icon(Icons.more_horiz),
                                enabled: !_busy,
                                menuConstraints: const BoxConstraints.tightFor(
                                  width: _noteTagMenuWidth,
                                ),
                                onOpened: () =>
                                    setState(() => _menuTag = rowId),
                                onCanceled: () =>
                                    setState(() => _menuTag = null),
                                onSelected: (action) => _selectAction(
                                  action,
                                  tag,
                                  anchorContext: anchorContext,
                                  rowId: rowId,
                                ),
                                itemBuilder: (_) => [
                                  OmniPopupMenuItem(
                                    key: ValueKey('notes-tag-pin-menu-$rowId'),
                                    value: 'pin',
                                    label: tag.isPinned ? '取消置顶' : '置顶',
                                    icon: tag.isPinned
                                        ? Icons.push_pin
                                        : Icons.push_pin_outlined,
                                  ),
                                  OmniPopupMenuItem(
                                    value: 'rename',
                                    label: '编辑名称/图标',
                                    icon: Icons.edit_outlined,
                                  ),
                                  const PopupMenuDivider(),
                                  OmniPopupMenuItem<String>.submenu(
                                    key: ValueKey(
                                      'notes-tag-delete-menu-$rowId',
                                    ),
                                    label: '删除标签',
                                    icon: Icons.delete_outline,
                                    danger: true,
                                    children: [
                                      OmniPopupMenuItem<String>.custom(
                                        key: const ValueKey(
                                          'notes-tag-delete-only',
                                        ),
                                        value: 'delete',
                                        danger: true,
                                        child: const Padding(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: OmniSpacing.sm,
                                          ),
                                          child: Text('仅删除标签'),
                                        ),
                                      ),
                                      OmniPopupMenuItem<String>.custom(
                                        key: const ValueKey(
                                          'notes-tag-delete-notes',
                                        ),
                                        value: 'delete-notes',
                                        danger: true,
                                        child: const Padding(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: OmniSpacing.sm,
                                          ),
                                          child: Text('删除标签和笔记'),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
