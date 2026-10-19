part of 'android_notes_view.dart';

/// 图片流按正式篇及草稿代次缓存，输入重建不重复订阅文件流。
final _androidNoteImagesProvider = StreamProvider.autoDispose
    .family<List<NoteImageView>, ({String noteId, String? draftId})>(
      (ref, identity) => ref
          .watch(noteEditorProvider)
          .images
          .watch(identity.noteId, draftId: identity.draftId),
    );

/// 主列表和搜索结果使用同一张正式笔记卡片。
class _AndroidNoteList extends ConsumerWidget {
  /// 正式笔记及加载状态。
  final AsyncValue<List<NoteEntryRecord>> notes;

  /// 本视图的不可变条件。
  final NoteSearchFilter filter;

  /// 热图归档日筛选。
  final String? selectedDay;

  /// 正文关键词。
  final String query;

  /// 独立保留当前列表的滚动位置。
  final ScrollController? controller;

  /// 唯一展开的笔记。
  final String? expandedId;

  /// 浮动输入栏需要的底部空间。
  final double bottomPadding;

  /// 阅读展开与编辑操作分离。
  final ValueChanged<String> onExpand;

  /// 打开真实编辑面板。
  final Future<void> Function(String id, {NoteVersionRecord? version}) onEdit;

  /// 创建正式笔记列表，不把草稿混入统计或搜索。
  const _AndroidNoteList({
    required this.notes,
    required this.filter,
    this.selectedDay,
    this.query = '',
    this.controller,
    this.expandedId,
    this.bottomPadding = OmniSpacing.xl,
    required this.onExpand,
    required this.onEdit,
  });

  /// 加载和失败分别展示，成功后才判断是否无结果。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 搜索依赖正式标签、原音及图片事实。
    final AsyncValue<List<TaxonomyEntry>> taxonomy = ref.watch(
      noteTaxonomiesProvider,
    );
    // 当前笔记的有效原音集合。
    final AsyncValue<List<NoteAudioSegmentRecord>> audio = ref.watch(
      allNoteAudioProvider,
    );
    // 当前篇已过滤的图片展示快照。
    final AsyncValue<List<NoteImageRecord>> images = ref.watch(
      allNoteImagesProvider,
    );
    if (notes.hasError ||
        taxonomy.hasError ||
        audio.hasError ||
        images.hasError) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('笔记加载失败'),
            OmniButton(
              label: '重试',
              onPressed: () {
                ref.invalidate(notesProvider);
                ref.invalidate(noteTaxonomiesProvider);
                ref.invalidate(allNoteAudioProvider);
                ref.invalidate(allNoteImagesProvider);
              },
            ),
          ],
        ),
      );
    }
    if (!notes.hasValue ||
        !taxonomy.hasValue ||
        !audio.hasValue ||
        !images.hasValue) {
      return const Center(child: CircularProgressIndicator());
    }
    // 正式图片集合不包含未发布图片或回收站墓碑。
    final Set<String> imageIds = images.value!
        .where((image) => image.deletedAt == null)
        .map((image) => image.noteId)
        .toSet();
    // 保持原仓储排序的筛选结果。
    final List<NoteEntryRecord> filtered = notes.value!
        .where(
          (note) => matchesNoteSearch(
            note,
            filter: filter,
            query: query,
            selectedDay: selectedDay,
            taxonomies: taxonomy.value!,
            audio: audio.value!,
            imageNoteIds: imageIds,
          ),
        )
        .toList();
    if (filtered.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(OmniSpacing.xl),
          child: Text(
            query.isNotEmpty || filter.isActive || selectedDay != null
                ? '没有符合条件的笔记'
                : '还没有笔记，点击下方记录想法',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.separated(
      key: const ValueKey('android-notes-list'),
      controller: controller,
      padding: EdgeInsets.fromLTRB(
        OmniSpacing.md,
        OmniSpacing.xs,
        OmniSpacing.md,
        bottomPadding,
      ),
      itemCount: filtered.length,
      separatorBuilder: (_, _) => const SizedBox(height: OmniSpacing.sm),
      itemBuilder: (context, index) {
        // 稳定笔记身份保证录音控件不会串到另一篇。
        final NoteEntryRecord note = filtered[index];
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: _AndroidNoteCard(
              key: ValueKey('android-note-card-${note.id}'),
              note: note,
              expanded: expandedId == note.id,
              onExpand: () => onExpand(note.id),
              onEdit: ({version}) => onEdit(note.id, version: version),
            ),
          ),
        );
      },
    );
  }
}

/// 仅非交互阅读区域响应双击；图片、音频与菜单不进入这个手势竞争域。
class _AndroidNoteEditTarget extends StatelessWidget {
  /// 唯一历史编辑入口。
  final VoidCallback onEdit;

  /// 保留原样的只读内容。
  final Widget child;

  /// 创建独立阅读热区。
  const _AndroidNoteEditTarget({required this.onEdit, required this.child});

  /// 读屏激活使用同一动作，物理单击保持阅读。
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '双击编辑笔记',
    onTap: onEdit,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      onDoubleTap: onEdit,
      child: child,
    ),
  );
}

/// 卡片正文只读，操作按钮不会隐式切换当前编辑归属。
class _AndroidNoteCard extends ConsumerWidget {
  /// 当前正式笔记事实。
  final NoteEntryRecord note;

  /// 当前全文是否展开。
  final bool expanded;

  /// 展开或收起全文。
  final VoidCallback onExpand;

  /// 从菜单打开编辑。
  final Future<void> Function({NoteVersionRecord? version}) onEdit;

  /// 创建紧凑摘要卡片。
  const _AndroidNoteCard({
    super.key,
    required this.note,
    required this.expanded,
    required this.onExpand,
    required this.onEdit,
  });

  /// 菜单动作始终绑定本篇和原数据源，不通过当前编辑身份猜测。
  Future<void> _menu(BuildContext context, WidgetRef ref) async {
    // 菜单打开时固定原仓储。
    final NoteRepository source = ref.read(noteRepositoryProvider);
    try {
      // 展示菜单前读回最新字数和时间。
      final NoteEntryRecord current = await _androidRequireNote(
        context,
        ref,
        source,
        note.id,
      );
      if (!context.mounted) return;
      // 选择动作后再校验，远端删除不能使用旧菜单继续编辑。
      final _AndroidNoteAction? action = await _androidShowNoteMenu(
        context,
        current,
      );
      if (action == null || !context.mounted) return;
      // 只读动作不打开编辑器或改变其他草稿。
      final NoteEntryRecord latest = await _androidRequireNote(
        context,
        ref,
        source,
        note.id,
      );
      if (!context.mounted) return;
      switch (action) {
        case _AndroidNoteAction.edit:
          await onEdit();
        case _AndroidNoteAction.pin:
        case _AndroidNoteAction.unpin:
          await source.setPinned(latest.id, action == _AndroidNoteAction.pin);
        case _AndroidNoteAction.copy:
          await _androidCopyNote(context, latest.body);
        case _AndroidNoteAction.details:
          await _androidReadOnlySheet<void>(
            context,
            (_) => _AndroidNoteDetails(source: source, id: note.id),
          );
        case _AndroidNoteAction.versions:
          // 面板只返回用户明确选中的版本，关闭不切换草稿。
          final NoteVersionRecord? version =
              await _androidReadOnlySheet<NoteVersionRecord>(
                context,
                (_) => _AndroidNoteVersions(source: source, id: note.id),
              );
          if (version != null && context.mounted) {
            await _androidRequireNote(context, ref, source, note.id);
            await onEdit(version: version);
          }
        case _AndroidNoteAction.delete:
          await _androidDeleteNote(context, ref, note.id);
      }
    } on Object catch (error) {
      if (context.mounted) {
        showOmniMessage(
          context,
          message: '$error',
          tone: OmniMessageTone.error,
        );
      }
    }
  }

  /// 标题派生自首个非空行，不增加或改写持久字段。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 当前篇的正式媒体与有效标签。
    final List<NoteAudioSegmentRecord> audio =
        (ref.watch(allNoteAudioProvider).value ?? [])
            .where((item) => item.noteId == note.id && item.deletedAt == null)
            .toList()
          ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    // 当前可用的有效标签集合。
    final List<TaxonomyEntry> tags =
        (ref.watch(noteTaxonomiesProvider).value ?? [])
            .where(
              (tag) =>
                  tag.deletedAt == null &&
                  tag.kind == 'tag' &&
                  noteTagIds(note.tags).contains(tag.id),
            )
            .toList();
    // 正式图片事实决定纯图片笔记的标题。
    final bool hasImages = (ref.watch(allNoteImagesProvider).value ?? []).any(
      (image) => image.noteId == note.id && image.deletedAt == null,
    );
    // 保留原始缩进及换行的正文行。
    final List<String> lines = note.body.split('\n');
    // 首个有内容的正文行位置。
    final int first = lines.indexWhere((line) => line.trim().isNotEmpty);
    // 当前视图或卡片使用的可见标题。
    final String title = first >= 0
        ? lines[first]
        : hasImages
        ? '图片笔记'
        : audio.isNotEmpty
        ? '语音笔记'
        : '内容已清空';
    // 首行之后的只读正文摘要。
    final String preview = first < 0
        ? ''
        : lines.skip(first + 1).join('\n').trimRight();
    // 记录时间保持选择时的墙钟字段。
    final NoteRecordTime recorded = note.recordTime;
    // 当前主题的语义颜色。
    final OmniColors colors = OmniColors.of(context);
    return OmniPanel(
      showBorder: false,
      padding: EdgeInsets.zero,
      child: Stack(
        children: [
          // 背景仅在上层内容未命中时接收双击，不参与媒体子控件的竞技场。
          Positioned.fill(
            child: _AndroidNoteEditTarget(
              onEdit: () => onEdit(),
              child: const SizedBox.expand(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(OmniSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _AndroidNoteEditTarget(
                        onEdit: () => onEdit(),
                        child: Row(
                          children: [
                            if (note.isPinned) ...[
                              NotePinIndicator(noteId: note.id),
                              const SizedBox(width: OmniSpacing.xxs),
                            ],
                            Flexible(
                              child: Text(
                                recorded.label,
                                key: ValueKey(
                                  'android-note-created-${note.id}',
                                ),
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: colors.muted),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Builder(
                      builder: (anchorContext) => OmniIconButton(
                        tooltip: '笔记操作',
                        icon: const Icon(Icons.more_horiz),
                        onPressed: () => _menu(anchorContext, ref),
                      ),
                    ),
                  ],
                ),
                _AndroidNoteEditTarget(
                  onEdit: () => onEdit(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      NoteMarkdownText(
                        source: title,
                        maxLines: expanded ? null : 2,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (preview.trim().isNotEmpty) ...[
                        const SizedBox(height: OmniSpacing.xs),
                        NoteMarkdownText(
                          source: preview,
                          maxLines: expanded ? null : 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ],
                  ),
                ),
                // 使用实际布局测量判断是否需要展开入口，避免短正文多出无效按钮。
                LayoutBuilder(
                  builder: (context, constraints) {
                    // 标题与正文分别沿用当前字号及系统缩放。
                    final TextStyle heading = Theme.of(context)
                        .textTheme
                        .titleMedium!;
                    // 摘要采用的正文排版样式。
                    final TextStyle body = Theme.of(context)
                        .textTheme
                        .bodyMedium!;
                    // 按实际字号测量后决定是否提供展开操作。
                    final bool overflow =
                        NoteMarkdownText.measureHeight(
                              title,
                              maxWidth: constraints.maxWidth,
                              style: heading,
                              textDirection: Directionality.of(context),
                              textScaler: MediaQuery.textScalerOf(context),
                            ) >
                            NoteMarkdownText.measureHeight(
                                  title,
                                  maxWidth: constraints.maxWidth,
                                  style: heading,
                                  textDirection: Directionality.of(context),
                                  textScaler: MediaQuery.textScalerOf(context),
                                  maxLines: 2,
                                ) +
                                .1 ||
                        NoteMarkdownText.measureHeight(
                              preview,
                              maxWidth: constraints.maxWidth,
                              style: body,
                              textDirection: Directionality.of(context),
                              textScaler: MediaQuery.textScalerOf(context),
                            ) >
                            NoteMarkdownText.measureHeight(
                                  preview,
                                  maxWidth: constraints.maxWidth,
                                  style: body,
                                  textDirection: Directionality.of(context),
                                  textScaler: MediaQuery.textScalerOf(context),
                                  maxLines: 2,
                                ) +
                                .1;
                    return overflow
                        ? Align(
                            alignment: Alignment.centerLeft,
                            child: OmniButton(
                              label: expanded ? '收起' : '展开',
                              variant: OmniButtonVariant.text,
                              onPressed: onExpand,
                            ),
                          )
                        : const SizedBox.shrink();
                  },
                ),
                if (tags.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: OmniSpacing.sm),
                    child: _AndroidNoteEditTarget(
                      onEdit: () => onEdit(),
                      child: Wrap(
                        spacing: OmniSpacing.xs,
                        runSpacing: OmniSpacing.xs,
                        children: [
                          for (final TaxonomyEntry tag in tags)
                            OmniTag(
                              label: '${tag.iconEmoji ?? '#'} ${tag.name}',
                            ),
                        ],
                      ),
                    ),
                  ),
                _AndroidNoteImages(noteId: note.id),
                for (final NoteAudioSegmentRecord segment in audio)
                  _AndroidNoteAudio(segment: segment),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 图片预览与编辑共用文件加载、缺失提示及缩放查看。
class _AndroidNoteImages extends ConsumerWidget {
  /// 图片所属正式笔记身份。
  final String noteId;

  /// 编辑时合并本机草稿图片。
  final String? draftId;

  /// 未提供时为只读缩略图。
  final Future<void> Function(String id)? onRemove;

  /// 创建按身份绑定的图片条。
  const _AndroidNoteImages({required this.noteId, this.draftId, this.onRemove});

  /// 显示完整原图，文件缺失保持可恢复的占位。
  Future<void> _preview(BuildContext context, NoteImageView image) =>
      showOmniDialog<void>(
        context: context,
        builder: (_) => OmniDialogScaffold(
          title: '查看图片',
          width: 880,
          height: 640,
          child: InteractiveViewer(
            minScale: .5,
            maxScale: 5,
            child: Center(
              child: Image.file(
                File(image.localPath!),
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const Text('图片文件暂不可用'),
              ),
            ),
          ),
        ),
      );

  /// 图片随流更新，取消草稿不触碰正式原件。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 稳定流身份避免每次文字输入重启加载。
    final AsyncValue<List<NoteImageView>> state = ref.watch(
      _androidNoteImagesProvider((noteId: noteId, draftId: draftId)),
    );
    // 当前实际数据源拥有的唯一编辑会话。
    final NoteEditorController editor = ref.watch(noteEditorProvider);
    // 当前篇已过滤的图片展示快照。
    final List<NoteImageView> images = (state.value ?? [])
        .where((image) => draftId == null || !editor.isImageRemoved(image.id))
        .toList();
    if (state.hasError) return const Text('图片加载失败');
    if (images.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: OmniSpacing.sm),
      child: Wrap(
        spacing: OmniSpacing.sm,
        runSpacing: OmniSpacing.sm,
        children: [
          for (final NoteImageView image in images)
            SizedBox(
              width: 96,
              child: Column(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(OmniRadius.control),
                    child: OmniInkWell(
                      onTap: image.localPath == null
                          ? null
                          : () => _preview(context, image),
                      child: SizedBox.square(
                        dimension: 96,
                        child: image.localPath == null
                            ? const Center(child: Icon(Icons.image_outlined))
                            : Image.file(
                                File(image.localPath!),
                                fit: BoxFit.cover,
                                cacheWidth: 288,
                                errorBuilder: (_, _, _) => const Center(
                                  child: Icon(Icons.broken_image_outlined),
                                ),
                              ),
                      ),
                    ),
                  ),
                  if (onRemove != null)
                    OmniIconButton(
                      tooltip: '移除图片',
                      icon: const Icon(Icons.close),
                      onPressed:
                          editor.committing ||
                              editor.frozen ||
                              editor.conflicted
                          ? null
                          : () => onRemove!(image.id),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 原音操作复用既有组件，读取每段自己的传输状态。
class _AndroidNoteAudio extends ConsumerWidget {
  /// 正式或适配后的草稿原音。
  final NoteAudioSegmentRecord segment;

  /// 草稿原音的本机文件快照。
  final NoteAudioLocalFileRecord? draftLocal;

  /// 只有编辑态允许插入和暂存删除。
  final bool editing;

  /// 草稿原音没有正式识别身份。
  final bool staged;

  /// 插入文本遵循编辑器的当前选区。
  final Future<void> Function(String text)? onInsert;

  /// 删除只写草稿，提交后才变更正式记录。
  final VoidCallback? onDelete;

  /// 创建紧凑原音条。
  const _AndroidNoteAudio({
    required this.segment,
    this.draftLocal,
    this.editing = false,
    this.staged = false,
    this.onInsert,
    this.onDelete,
  });

  /// 单段授权后复用持久任务身份，未知提交不会重复创建付费任务。
  Future<void> _recognize(BuildContext context, WidgetRef ref) async {
    if (!ref.read(syncPreferenceProvider)) {
      showOmniMessage(context, message: '请先在设置中连接服务器并开启同步');
      return;
    }
    // 用户仅授权当前原音，不修改人工正文。
    final bool confirmed = await showOmniConfirmDialog(
      context,
      title: '将这段原音转为文字？',
      message: '原音会通过你的服务器提交给语音识别服务，结果作为可选文本，不覆盖人工正文。',
      confirmLabel: '转文字',
    );
    if (!confirmed || !context.mounted) return;
    try {
      // 使用当前数据库和已存在任务状态。
      final AppDatabase database = ref.read(appDatabaseProvider);
      // 原音已有的本机任务身份及状态。
      final NoteAudioLocalFileRecord? current = await (database.select(
        database.noteAudioLocalFiles,
      )..where((table) => table.id.equals(segment.id))).getSingleOrNull();
      // 只有确定终态才生成新的识别任务身份。
      final bool retry =
          current != null &&
          [
            'failed',
            'cancelled',
            'succeeded',
          ].contains(current.recognitionState);
      await database
          .into(database.noteAudioLocalFiles)
          .insertOnConflictUpdate(
            NoteAudioLocalFilesCompanion(
              id: Value(segment.id),
              consent: const Value(true),
              recognitionId: retry || current?.recognitionId == null
                  ? Value(const Uuid().v4())
                  : const Value.absent(),
              recognitionState: const Value('queued'),
              lastError: const Value(null),
            ),
          );
      await ref.read(noteAudioTransferProvider)?.tick();
    } on Object catch (error) {
      if (context.mounted) {
        showOmniMessage(
          context,
          message: '识别失败：$error',
          tone: OmniMessageTone.error,
        );
      }
    }
  }

  /// 撤回请求持久化，离线后仍能继续送达服务端。
  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    try {
      // 当前实际数据源。
      final AppDatabase database = ref.read(appDatabaseProvider);
      await (database.update(
        database.noteAudioLocalFiles,
      )..where((table) => table.id.equals(segment.id))).write(
        const NoteAudioLocalFilesCompanion(
          consent: Value(false),
          recognitionState: Value('cancelPending'),
        ),
      );
      await ref.read(noteAudioTransferProvider)?.tick();
    } on Object catch (error) {
      if (context.mounted) {
        showOmniMessage(
          context,
          message: '撤回失败：$error',
          tone: OmniMessageTone.error,
        );
      }
    }
  }

  /// 点击、读屏与拖动继续由既有原音组件实现。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 本段原音绑定自己的本机状态，不能使用当前编辑篇代替。
    final NoteAudioLocalFileRecord? local =
        draftLocal ??
        (ref.watch(noteLocalAudioProvider).value ?? [])
            .where((file) => file.id == segment.id)
            .firstOrNull;
    // 当前实际数据源拥有的唯一编辑会话。
    final NoteEditorController editor = ref.watch(noteEditorProvider);
    // 当前采集器的实际状态快照。
    final NoteRecordingState recording =
        ref.watch(noteRecordingProvider).value ?? editor.recorder.state;
    return Padding(
      padding: const EdgeInsets.only(top: OmniSpacing.sm),
      child: NoteAudioCard(
        key: ValueKey('android-note-audio-${segment.id}'),
        segment: segment,
        local: local,
        player: ref.watch(noteAudioPlayerProvider),
        recordingActive: recording.isActive,
        compact: true,
        editing: editing,
        recognitionEnabled: !staged,
        editEnabled:
            !editor.committing &&
            !editor.frozen &&
            !editor.conflicted &&
            !editor.recordingStarting,
        onDelete: onDelete,
        onRecognize: () => _recognize(context, ref),
        onCancel: () => _cancel(context, ref),
        onInsert: (text) => onInsert?.call(text),
      ),
    );
  }
}
