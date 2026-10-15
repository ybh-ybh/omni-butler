part of 'notes_page.dart';

/// 图片事实供纯图片标题读取，文件本身仍由专用图片同步链路管理。
final _allNoteImagesProvider = StreamProvider<List<NoteImageRecord>>((ref) {
  // 当前资料库的正式图片身份，包含回收站事实以便响应恢复。
  final AppDatabase database = ref.watch(appDatabaseProvider);
  return database.select(database.noteImages).watch();
});

/// Aa 的三个固定操作，不扩展到未约定的字体或颜色设置。
enum _NoteFormat { bold, underline, highlight }

/// 单条横向菜单保留项目统一菜单路由、键盘与动画。
class _NoteFormatMenuEntry extends PopupMenuEntry<_NoteFormat> {
  /// 当前选区的格式状态用于无障碍和选中反馈。
  final NoteRichEditorController controller;

  /// 创建三个并排的格式按钮。
  const _NoteFormatMenuEntry({required this.controller});

  /// 菜单行与工具按钮同高，不叠加额外的上下留白。
  @override
  double get height => OmniSize.iconButton;

  /// 行内独立按钮返回值，不由外层条目统一选中。
  @override
  bool represents(_NoteFormat? value) => false;

  /// 菜单路由要求独立的条目状态。
  @override
  State<_NoteFormatMenuEntry> createState() => _NoteFormatMenuEntryState();
}

/// 保持三个按钮可聚焦，弹层不抢占或改写正文选区。
class _NoteFormatMenuEntryState extends State<_NoteFormatMenuEntry> {
  /// 按照截图排列加粗、下划线、高亮图标。
  @override
  Widget build(BuildContext context) {
    // 菜单中性颜色跟随明暗主题。
    final OmniColors colors = OmniColors.of(context);
    return TextFieldTapRegion(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final _NoteFormat format in _NoteFormat.values)
            Semantics(
              selected: switch (format) {
                _NoteFormat.bold => widget.controller.isBold,
                _NoteFormat.underline => widget.controller.isUnderline,
                _NoteFormat.highlight => widget.controller.isHighlight,
              },
              child: OmniNoteComposerButton(
                key: ValueKey('note-format-${format.name}'),
                tooltip: switch (format) {
                  _NoteFormat.bold => '加粗（Ctrl+B）',
                  _NoteFormat.underline => '下划线（Ctrl+U）',
                  _NoteFormat.highlight => '高亮',
                },
                icon: Icon(switch (format) {
                  _NoteFormat.bold => Icons.format_bold,
                  _NoteFormat.underline => Icons.format_underlined,
                  _NoteFormat.highlight => Icons.format_color_fill,
                }, size: OmniSize.icon),
                foreground: colors.muted,
                hoverForeground: colors.ink,
                hoverBackground: colors.ink.withValues(alpha: 0.05),
                onPressed: () => Navigator.of(context).pop(format),
              ),
            ),
        ],
      ),
    );
  }
}

/// Windows 工具动作保持在当前正文和草稿身份中执行。
extension _WindowsNoteTools on _NotesPageState {
  /// 系统选图返回后复查代次，防止迟到结果写到用户已切换的笔记。
  Future<void> _pickNoteImages(NoteEditorController editor) =>
      _perform(() async {
        if (_pickingImages || !_canUseNoteTools(editor)) return;
        // 系统窗口打开前固定篇身份与草稿代次。
        final String noteId = editor.draft.id;
        // 尚未落盘的草稿允许为空，篇身份仍须相同。
        final String? draftId = editor.draftId;
        _updateWindows(() => _pickingImages = true);
        try {
          // 多选保持文件选择顺序，不插入本机路径到 Markdown。
          final List<PlatformFile> files = await FilePicker.pickFiles(
            type: FileType.custom,
            allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp'],
          );
          if (!mounted ||
              editor.draft.id != noteId ||
              editor.draftId != draftId ||
              !_canUseNoteTools(editor)) {
            return;
          }
          // 仅接受系统返回的可读取本机文件。
          final List<String> paths = files
              .map((file) => file.path)
              .whereType<String>()
              .toList();
          if (paths.isNotEmpty) {
            await editor.addImages(paths);
            if (mounted &&
                editor.draft.id == noteId &&
                editor.draftId == draftId) {
              _focus.requestFocus();
            }
          }
        } finally {
          _updateWindows(() => _pickingImages = false);
        }
      });

  /// 与正文共用冻结、提交和录音启动保护，不消费失效选区。
  bool _canUseNoteTools(NoteEditorController editor) =>
      !editor.frozen &&
      !editor.conflicted &&
      !editor.committing &&
      !_committing &&
      !editor.recordingStarting;

  /// 紧凑横向格式弹层位于 Aa 上方，边缘交给项目菜单路由约束。
  Future<void> _showNoteFormats(NoteEditorController editor) async {
    if (_formatMenuOpen || !_canUseNoteTools(editor)) return;
    // 只使用弹出前仍挂载的渲染对象计算锚点。
    final RenderBox? anchor =
        _formatAnchor.currentContext?.findRenderObject() as RenderBox?;
    // 当前窗口内的菜单坐标系。
    final RenderBox overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    if (anchor == null || !anchor.attached) return;
    // 弹层与按钮留出八像素间隙。
    final Offset origin = anchor.localToGlobal(Offset.zero, ancestor: overlay);
    // 弹出期间仅允许操作原篇正文。
    final String noteId = editor.draft.id;
    _updateWindows(() => _formatMenuOpen = true);
    try {
      // 横向行宽固定为三个现有工具按钮，菜单边距另由路由提供。
      final _NoteFormat? format = await showOmniMenu<_NoteFormat>(
        context: context,
        position: RelativeRect.fromRect(
          Rect.fromLTWH(
            origin.dx,
            (origin.dy - OmniSize.iconButton - OmniSpacing.xs).clamp(
              0,
              overlay.size.height,
            ),
            116,
            OmniSize.iconButton,
          ),
          Offset.zero & overlay.size,
        ),
        constraints: const BoxConstraints.tightFor(width: 116),
        menuPadding: const EdgeInsets.symmetric(horizontal: OmniSpacing.xxs),
        requestFocus: true,
        items: [_NoteFormatMenuEntry(controller: _richBody)],
      );
      if (!mounted || editor.draft.id != noteId || !_canUseNoteTools(editor)) {
        return;
      }
      switch (format) {
        case _NoteFormat.bold:
          _richBody.toggleBold();
        case _NoteFormat.underline:
          _richBody.toggleUnderline();
        case _NoteFormat.highlight:
          _richBody.toggleHighlight();
        case null:
          break;
      }
      _focus.requestFocus();
    } finally {
      _updateWindows(() => _formatMenuOpen = false);
    }
  }

  /// 编辑区零图时整块隐藏，第一张导入后才出现末尾加号。
  Widget _editorImages(NoteEditorController editor) =>
      StreamBuilder<List<NoteImageView>>(
        key: ValueKey('note-draft-images-${editor.draft.id}-${editor.draftId}'),
        stream: editor.images.watch(editor.draft.id, draftId: editor.draftId),
        builder: (context, snapshot) {
          // 待删除身份只影响当前草稿，取消可恢复正式图片。
          final List<NoteImageView> images = (snapshot.data ?? [])
              .where((image) => !editor.isImageRemoved(image.id))
              .toList();
          return _noteImageStrip(
            images,
            editable: _canUseNoteTools(editor),
            onAdd: () => unawaited(_pickNoteImages(editor)),
            onRemove: (id) => unawaited(_perform(() => editor.removeImage(id))),
          );
        },
      );

  /// 阅读清单不依赖当前编辑器草稿，下载完成后由图片流直接刷新。
  Widget _historyImages(String noteId, NoteEditorController editor) =>
      StreamBuilder<List<NoteImageView>>(
        key: ValueKey('note-images-$noteId'),
        stream: editor.images.watch(noteId),
        builder: (context, snapshot) => _noteImageStrip(snapshot.data ?? []),
      );

  /// 图片网格自然换行，截图尺寸缩略图和加号共用稳定热区。
  Widget _noteImageStrip(
    List<NoteImageView> images, {
    bool editable = false,
    VoidCallback? onAdd,
    ValueChanged<String>? onRemove,
  }) {
    if (images.isEmpty) return const SizedBox.shrink();
    // 中性轮廓和错误占位跟随明暗主题。
    final OmniColors colors = OmniColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: OmniSpacing.sm),
      child: Wrap(
        key: const ValueKey('note-image-strip'),
        spacing: OmniSpacing.sm,
        runSpacing: OmniSpacing.sm,
        children: [
          for (final NoteImageView image in images)
            SizedBox.square(
              key: ValueKey('note-image-${image.id}'),
              dimension: 68,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(OmniRadius.control),
                      child: OmniInkWell(
                        onTap: image.localPath == null
                            ? null
                            : () => _showNoteImage(image),
                        child: image.localPath == null
                            ? ColoredBox(
                                color: colors.mist,
                                child: Icon(
                                  Icons.image_outlined,
                                  color: colors.muted,
                                ),
                              )
                            : Image.file(
                                File(image.localPath!),
                                fit: BoxFit.cover,
                                cacheWidth: 204,
                                errorBuilder: (_, error, stack) => ColoredBox(
                                  color: colors.mist,
                                  child: Icon(
                                    Icons.broken_image_outlined,
                                    color: colors.muted,
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ),
                  if (onRemove != null)
                    Positioned(
                      top: -5,
                      right: -5,
                      child: OmniNoteComposerButton(
                        key: ValueKey('note-image-remove-${image.id}'),
                        tooltip: '移除图片',
                        icon: const Icon(Icons.close, size: 12),
                        size: const Size.square(20),
                        foreground: Colors.white,
                        background: colors.ink.withValues(alpha: 0.55),
                        onPressed: editable ? () => onRemove(image.id) : null,
                      ),
                    ),
                ],
              ),
            ),
          if (onAdd != null)
            SizedBox.square(
              dimension: 68,
              child: CustomPaint(
                painter: _NoteImageAddBorder(colors.line),
                child: OmniNoteComposerButton(
                  key: const ValueKey('note-image-add'),
                  tooltip: '继续添加图片',
                  icon: const Icon(Icons.add),
                  size: const Size.square(68),
                  foreground: colors.muted,
                  onPressed: editable && !_pickingImages ? onAdd : null,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 原图只从本机私有缓存读取，远端文件由已校验的图片服务下载。
  Future<void> _showNoteImage(NoteImageView image) => showOmniDialog<void>(
    context: context,
    builder: (context) => OmniDialogScaffold(
      title: '查看图片',
      width: 880,
      height: 640,
      child: InteractiveViewer(
        minScale: 0.5,
        maxScale: 5,
        child: Center(
          child: Image.file(
            File(image.localPath!),
            fit: BoxFit.contain,
            errorBuilder: (_, error, stack) => const Text('图片文件暂不可用'),
          ),
        ),
      ),
    ),
  );
}

/// 追加入口使用虚线圆角边框，不改变按钮命中范围。
class _NoteImageAddBorder extends CustomPainter {
  /// 当前主题的弱分隔线颜色。
  final Color color;

  /// 创建仅装饰、不参与命中的边框。
  const _NoteImageAddBorder(this.color);

  /// 沿圆角路径按固定长度交替绘制线段。
  @override
  void paint(Canvas canvas, Size size) {
    // 笔画内缩避免裁掉外侧一半。
    final Path path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(0.5),
          const Radius.circular(OmniRadius.control),
        ),
      );
    // 虚线仅用于装饰。
    final Paint pen = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final metric in path.computeMetrics()) {
      // 每五像素一段，其中三像素为可见线条。
      for (double offset = 0; offset < metric.length; offset += 5) {
        canvas.drawPath(
          metric.extractPath(offset, (offset + 3).clamp(0, metric.length)),
          pen,
        );
      }
    }
  }

  /// 主题变化时才需要重新绘制静态边框。
  @override
  bool shouldRepaint(_NoteImageAddBorder oldDelegate) =>
      oldDelegate.color != color;
}
