part of 'notes_page.dart';

/// 已选标签常驻，未选标签在独立语义边界内向下弹出。
class _NoteComposerTagPicker extends StatelessWidget {
  /// 接收当前本机编辑会话，不拥有其生命周期。
  const _NoteComposerTagPicker({
    required this.editor,
    required this.tags,
    required this.expanded,
    required this.blocked,
  });

  /// 本次输入与标签关联仍通过现有草稿保存。
  final NoteEditorController editor;

  /// 当前有效标签，名称更新保持原身份。
  final List<TaxonomyEntry> tags;

  /// 井号按钮控制未选标签的可见性。
  final bool expanded;

  /// 发布或取消期间禁止更改标签。
  final bool blocked;

  /// 选择或取消只修改本机草稿标签，不改变主区筛选。
  void _select(TaxonomyEntry tag, bool selected) {
    if (blocked || editor.frozen || editor.conflicted || editor.committing) {
      return;
    }
    // 固定标签身份，并保留其他已选关联。
    final Set<String> next = {...editor.draft.tags};
    if (selected) {
      next.add(tag.id);
    } else {
      next.remove(tag.id);
    }
    editor.edit(tags: next);
  }

  /// 两组保留各自父节点，显隐和选择不会重挂原有语义子树。
  @override
  Widget build(BuildContext context) {
    // 已选和可选分组在稳定容器内更新，不使用GlobalKey搬移控件。
    final List<TaxonomyEntry> selected = tags
        .where((tag) => editor.draft.tags.contains(tag.id))
        .toList();
    // 未选标签仅在用户打开井号入口后可操作。
    final List<TaxonomyEntry> available = tags
        .where((tag) => !editor.draft.tags.contains(tag.id))
        .toList();
    // 提交、冻结与冲突沿用现有编辑器保护。
    final bool enabled =
        !blocked && !editor.frozen && !editor.conflicted && !editor.committing;
    return Semantics(
      key: const ValueKey('note-composer-tags'),
      container: true,
      explicitChildNodes: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            container: true,
            explicitChildNodes: true,
            child: Padding(
              padding: EdgeInsets.only(
                bottom: selected.isEmpty ? 0 : OmniSpacing.sm,
              ),
              child: Wrap(
                spacing: OmniSpacing.xs,
                runSpacing: OmniSpacing.xs,
                children: [
                  for (final TaxonomyEntry tag in selected)
                    OmniTaxonomyChip(
                      key: ValueKey('note-selected-tag-${tag.id}'),
                      label: tag.name,
                      selected: true,
                      onSelected: enabled
                          ? (value) => _select(tag, value)
                          : null,
                    ),
                ],
              ),
            ),
          ),
          Semantics(
            container: true,
            explicitChildNodes: true,
            child: ClipRect(
              child: TweenAnimationBuilder<double>(
                key: const ValueKey('note-composer-tags-expansion'),
                tween: Tween<double>(
                  begin: 0,
                  end: expanded && available.isNotEmpty ? 1 : 0,
                ),
                duration: OmniMotion.duration(context, OmniMotion.panel),
                curve: OmniMotion.standardCurve,
                builder: (_, progress, child) => Align(
                  alignment: Alignment.topLeft,
                  heightFactor: progress,
                  child: Opacity(
                    opacity: progress,
                    child: Transform.scale(
                      alignment: Alignment.topLeft,
                      scale: 0.96 + progress * 0.04,
                      child: child,
                    ),
                  ),
                ),
                child: IgnorePointer(
                  ignoring: !expanded,
                  child: ExcludeFocus(
                    excluding: !expanded,
                    child: ExcludeSemantics(
                      excluding: !expanded,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: OmniSpacing.sm),
                        child: Wrap(
                          spacing: OmniSpacing.xs,
                          runSpacing: OmniSpacing.xs,
                          children: [
                            for (final TaxonomyEntry tag in available)
                              OmniTaxonomyChip(
                                key: ValueKey('note-available-tag-${tag.id}'),
                                label: tag.name,
                                selected: false,
                                onSelected: enabled
                                    ? (value) => _select(tag, value)
                                    : null,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
