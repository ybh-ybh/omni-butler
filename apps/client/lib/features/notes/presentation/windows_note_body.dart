part of 'notes_page.dart';

/// 只读正文展开与编辑器切换分离，正文高度变化推动下方音频和卡片。
extension _WindowsNoteBody on _NotesPageState {
  /// 阅读其他正文前暂存当前编辑，保留唯一完整展开的笔记。
  Future<void> _toggleBodyPreview(String id) => _perform(() async {
    // 正在保存或申请录音时不能越过当前编辑身份。
    final NoteEditorController editor = ref.read(noteEditorProvider);
    if (_committing || editor.committing || editor.recordingStarting) return;
    if (_expandedNoteId != null) {
      await editor.openComposer();
      if (editor.dirty || !mounted) return;
    }
    _updateWindows(() {
      _expandedNoteId = null;
      _expandedBodyNoteId = _expandedBodyNoteId == id ? null : id;
    });
  });

  /// 超出两行时显示灰色展开入口，始终保留完整文字供裁剪动画使用。
  Widget _noteBodyPreview(NoteEntryRecord note, String preview) => Semantics(
    key: ValueKey('note-body-region-${note.id}'),
    container: true,
    explicitChildNodes: true,
    child: LayoutBuilder(
      builder: (context, constraints) {
        // 测量与实际正文使用相同字体、缩放和行宽。
        final TextStyle style =
            Theme.of(context).textTheme.bodyMedium ??
            const TextStyle(fontSize: 14);
        // 当前布局方向与用户字号。
        final TextDirection direction = Directionality.of(context);
        final TextScaler scaler = MediaQuery.textScalerOf(context);
        // 两行及完整正文的实际高度，避免切换文本造成收起时突然消失。
        final double closedHeight = NoteMarkdownText.measureHeight(
          preview,
          maxWidth: constraints.maxWidth,
          style: style,
          textDirection: direction,
          textScaler: scaler,
          maxLines: 2,
        );
        // 全文按相同的列表缩进和格式字体测量。
        final double fullHeight = NoteMarkdownText.measureHeight(
          preview,
          maxWidth: constraints.maxWidth,
          style: style,
          textDirection: direction,
          textScaler: scaler,
        );
        // 超长正文才需要展开，不给已经完整显示的内容添加空操作。
        final bool overflow = fullHeight > closedHeight + 0.1;
        if (!overflow) {
          return NoteMarkdownText(
            source: preview,
            key: ValueKey('note-preview-${note.id}'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: style,
          );
        }
        // 会话中只保存一个展开身份，切换时旧卡片同步反向收起。
        final bool expanded = _expandedBodyNoteId == note.id;
        final OmniColors colors = OmniColors.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TweenAnimationBuilder<double>(
              key: ValueKey('note-body-expansion-${note.id}'),
              tween: Tween<double>(begin: 0, end: expanded ? 1 : 0),
              duration: OmniMotion.duration(context, OmniMotion.panel),
              curve: OmniMotion.standardCurve,
              child: NoteMarkdownText(
                source: preview,
                key: ValueKey('note-preview-${note.id}'),
                style: style,
              ),
              builder: (_, progress, child) => SizedBox(
                height: closedHeight + (fullHeight - closedHeight) * progress,
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.topLeft,
                    minWidth: constraints.maxWidth,
                    maxWidth: constraints.maxWidth,
                    minHeight: fullHeight,
                    maxHeight: fullHeight,
                    child: child,
                  ),
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: OmniDisclosureToggle(
                expanded: expanded,
                child: OmniNoteAudioLink(
                  key: ValueKey('note-body-toggle-${note.id}'),
                  label: expanded ? '收起' : '展开',
                  color: Theme.of(context).brightness == Brightness.light
                      ? NoteComposerStyle.muted
                      : colors.muted,
                  hoverForeground: colors.brand,
                  showHoverBackground: false,
                  onPressed: () => unawaited(_toggleBodyPreview(note.id)),
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}
