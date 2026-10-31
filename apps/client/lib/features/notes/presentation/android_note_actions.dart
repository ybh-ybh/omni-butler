part of 'android_notes_view.dart';

/// 安卓已有笔记的菜单结果，不携带会变化的当前编辑身份。
enum _AndroidNoteAction { edit, pin, unpin, copy, details, versions, delete }

/// 时间统一转为本机显示，统计字段不冒用归档日期。
String _androidNoteTime(DateTime value, {bool seconds = false}) {
  // 当前记录的真实本机时间。
  final DateTime local = value.toLocal();
  return '${businessDayKey(local)} ${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}'
      '${seconds ? ':${local.second.toString().padLeft(2, '0')}' : ''}';
}

/// 复制只使用可见正文，标签和格式标记不混入剪贴板。
Future<void> _androidCopyNote(BuildContext context, String body) async {
  await Clipboard.setData(ClipboardData(text: NoteMarkdown.plainText(body)));
  if (context.mounted) showOmniMessage(context, message: '正文已复制');
}

/// 只读菜单和删除均固定原仓储，数据源变化或远端删除后停止动作。
Future<NoteEntryRecord> _androidRequireNote(
  BuildContext context,
  WidgetRef ref,
  NoteRepository source,
  String id,
) async {
  // 原库查回最新事实，不使用菜单打开时的旧正文。
  final NoteEntryRecord? note = await source.find(id);
  if (!context.mounted ||
      !identical(ref.read(noteRepositoryProvider), source)) {
    throw StateError('数据源已切换，请重新打开笔记');
  }
  if (note == null || note.deletedAt != null) throw StateError('笔记已删除或不可用');
  return note;
}

/// 回收站事务保护原稿和在途资产，不主动切换编辑器。
Future<bool> _androidDeleteNote(
  BuildContext context,
  WidgetRef ref,
  String id,
) async {
  // 固定本次操作的数据源。
  final NoteRepository source = ref.read(noteRepositoryProvider);
  // 数据源专属编辑器负责排空目标笔记资产。
  final NoteEditorController editor = ref.read(noteEditorProvider);
  // 明确确认只作用于选中的正式篇。
  final bool confirmed = await showOmniConfirmDialog(
    context,
    title: '移入笔记回收站？',
    message: '正文、图片与原音保留 30 天，未发布修改保留在本机草稿中。',
    confirmLabel: '移入回收站',
    danger: true,
  );
  if (!confirmed || !context.mounted) return false;
  try {
    await _androidRequireNote(context, ref, source, id);
    await editor.prepareForDeletion(
      {id},
      action: () async {
        // 等待原音与图片暂存期间也可能换库，事务前再核验原目标。
        await _androidRequireNote(context, ref, source, id);
        await source.softDelete(id);
      },
    );
    return context.mounted &&
        identical(ref.read(noteRepositoryProvider), source);
  } on Object catch (error) {
    if (context.mounted) {
      showOmniMessage(
        context,
        message: '删除失败：$error',
        tone: OmniMessageTone.error,
      );
    }
    return false;
  }
}

/// 两个并排入口保留独立焦点与48dp以上热区，不添加分享占位。
class _AndroidNoteMenuHeader extends PopupMenuEntry<_AndroidNoteAction> {
  /// 菜单顶部的实际内容高度。
  @override
  double get height => OmniSize.touch + OmniSpacing.xs;

  /// 顶部不是单个可选结果，结果由内部两个入口提供。
  @override
  bool represents(_AndroidNoteAction? value) => false;

  /// 创建菜单第一行。
  const _AndroidNoteMenuHeader();

  /// 子按钮拥有独立交互状态。
  @override
  State<_AndroidNoteMenuHeader> createState() => _AndroidNoteMenuHeaderState();
}

/// 使用统一触控组件，避免禁用菜单项吞掉内部按钮的语义。
class _AndroidNoteMenuHeaderState extends State<_AndroidNoteMenuHeader> {
  /// 单个图标与文字入口将动作交回菜单调用者。
  Widget _item(String label, IconData icon, _AndroidNoteAction action) =>
      SizedBox(
        width: OmniSize.touch + OmniSpacing.md,
        child: OmniInkWell(
          onTap: () => Navigator.pop(context, action),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: OmniSize.touch + OmniSpacing.xs,
              minWidth: OmniSize.touch,
            ),
            child: Padding(
              padding: const EdgeInsets.all(OmniSpacing.xxs),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: OmniSpacing.lg),
                  const SizedBox(height: OmniSpacing.xxs),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  /// Center two fixed-width actions without leaving a missing third column.
  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      _item('编辑', Icons.edit_outlined, _AndroidNoteAction.edit),
      const SizedBox(width: OmniSpacing.xxs),
      _item('复制', Icons.copy_outlined, _AndroidNoteAction.copy),
    ],
  );
}

/// Build one compact text action for the Android note menu.
Widget _androidNoteMenuLabel(
  BuildContext context,
  String label, {
  bool danger = false,
}) {
  // Resolve the semantic foreground without changing the shared menu theme.
  final OmniColors colors = OmniColors.of(context);
  return Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: OmniSpacing.sm,
      vertical: OmniSpacing.xxs,
    ),
    child: Text(
      label,
      style: Theme.of(context).textTheme.bodyMedium!
          .copyWith(color: danger ? colors.danger : colors.ink),
    ),
  );
}

/// 菜单沿触发按钮定位，原生菜单负责短屏滚动与边缘避让。
Future<_AndroidNoteAction?> _androidShowNoteMenu(
  BuildContext context,
  NoteEntryRecord note,
) {
  // Adapt translucency and shadow contrast to the active brightness.
  final bool dark = Theme.of(context).brightness == Brightness.dark;
  // Preserve the semantic paper tone while allowing the note beneath to show.
  final Color panelColor = OmniColors.of(context).paper
      .withValues(alpha: dark ? 0.96 : 0.94);
  // 实际按钮和根导航覆盖层的坐标空间。
  final RenderBox anchor = context.findRenderObject()! as RenderBox;
  // 同一路由覆盖底部导航，但不模糊列表。
  final RenderBox overlay =
      Navigator.of(
            context,
            rootNavigator: true,
          ).overlay!.context.findRenderObject()!
          as RenderBox;
  // 对齐按钮右下缘，交给菜单自动调整最终位置。
  final Offset point = anchor.localToGlobal(
    Offset(anchor.size.width, anchor.size.height),
    ancestor: overlay,
  );
  return showOmniMenu<_AndroidNoteAction>(
    wholePanelTransition: true,
    context: context,
    useRootNavigator: true,
    position: RelativeRect.fromRect(
      point & Size.zero,
      Offset.zero & overlay.size,
    ),
    constraints: BoxConstraints.tightFor(
      width: math.min(200, MediaQuery.sizeOf(context).width - OmniSpacing.xl),
    ),
    menuPadding: EdgeInsets.zero,
    panelColor: panelColor,
    panelShadows: <BoxShadow>[
      BoxShadow(
        color: Colors.black.withValues(alpha: dark ? 0.30 : 0.15),
        blurRadius: 24,
        offset: const Offset(0, 8),
      ),
      BoxShadow(
        color: Colors.black.withValues(alpha: dark ? 0.16 : 0.07),
        blurRadius: 6,
        offset: const Offset(0, 2),
      ),
    ],
    items: [
      const _AndroidNoteMenuHeader(),
      const PopupMenuDivider(height: OmniSpacing.xxs, thickness: 0.5),
      OmniPopupMenuItem.custom(
        value: note.isPinned
            ? _AndroidNoteAction.unpin
            : _AndroidNoteAction.pin,
        height: OmniSize.controlLarge,
        child: _androidNoteMenuLabel(context, note.isPinned ? '取消置顶' : '置顶'),
      ),
      OmniPopupMenuItem.custom(
        value: _AndroidNoteAction.details,
        height: OmniSize.controlLarge,
        danger: false,
        child: _androidNoteMenuLabel(context, '查看详情'),
      ),
      OmniPopupMenuItem.custom(
        value: _AndroidNoteAction.versions,
        height: OmniSize.controlLarge,
        danger: false,
        child: _androidNoteMenuLabel(context, '历史版本'),
      ),
      OmniPopupMenuItem.custom(
        value: _AndroidNoteAction.delete,
        height: OmniSize.controlLarge,
        danger: true,
        child: _androidNoteMenuLabel(context, '删除', danger: true),
      ),
      const PopupMenuDivider(height: OmniSpacing.xs),
      OmniPopupMenuItem<_AndroidNoteAction>.custom(
        value: _AndroidNoteAction.details,
        enabled: false,
        padding: const EdgeInsets.fromLTRB(
          OmniSpacing.sm,
          OmniSpacing.xs,
          OmniSpacing.sm,
          OmniSpacing.sm,
        ),
        child: DefaultTextStyle(
          style: Theme.of(context).textTheme.bodySmall!
              .copyWith(color: OmniColors.of(context).muted),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '字数统计：${NoteMarkdown.plainText(note.body).characters.length}',
              ),
              Text('创建时间：${_androidNoteTime(note.createdAt)}'),
              Text('最后编辑：${_androidNoteTime(note.updatedAt)}'),
            ],
          ),
        ),
      ),
    ],
  );
}

/// 详情只订阅正式事实，不加载或覆盖本机编辑草稿。
class _AndroidNoteDetails extends ConsumerWidget {
  /// 打开时的数据源身份。
  final NoteRepository source;

  /// 稳定正式笔记身份。
  final String id;

  /// 创建只读详情表面。
  const _AndroidNoteDetails({required this.source, required this.id});

  /// 各类统计只依据本篇有效正式资产。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 数据源变更后不把同名ID解释为另一库的记录。
    final bool sameSource = identical(
      ref.watch(noteRepositoryProvider),
      source,
    );
    // 正式篇的最新状态。
    final AsyncValue<NoteEntryRecord?> state = ref.watch(noteByIdProvider(id));
    // 有效标签按仓储顺序展示。
    final List<TaxonomyEntry> tags =
        ref.watch(noteTaxonomiesProvider).value ?? [];
    // 本篇有效图片数量。
    final int images = (ref.watch(allNoteImagesProvider).value ?? [])
        .where((item) => item.noteId == id && item.deletedAt == null)
        .length;
    // 采样时长不含暂停，不计其他篇和草稿。
    final List<NoteAudioSegmentRecord> audio =
        (ref.watch(allNoteAudioProvider).value ?? [])
            .where((item) => item.noteId == id && item.deletedAt == null)
            .toList();
    // 当前可展示的正式内容。
    final NoteEntryRecord? note = state.value;
    // 标签汇总不将已删除名称混入详情。
    final String labels = note == null
        ? ''
        : tags
              .where(
                (tag) =>
                    tag.deletedAt == null &&
                    noteTagIds(note.tags).contains(tag.id),
              )
              .map((tag) => '${tag.iconEmoji ?? '#'} ${tag.name}')
              .join('、');
    return _AndroidReadOnlySheet(
      title: '笔记详情',
      child: !sameSource
          ? const Text('数据源已切换，请重新打开')
          : state.hasError
          ? const Text('详情加载失败，请重新打开重试')
          : !state.hasValue
          ? const Center(child: CircularProgressIndicator())
          : note == null || note.deletedAt != null
          ? const Text('笔记已删除或不可用')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('记录时间：${note.recordTime.label}'),
                Text('归档日期：${note.dayKey}'),
                Text('创建时间：${_androidNoteTime(note.createdAt, seconds: true)}'),
                Text('最后编辑：${_androidNoteTime(note.updatedAt, seconds: true)}'),
                Text(
                  '字数统计：${NoteMarkdown.plainText(note.body).characters.length}',
                ),
                Text('标签：${labels.isEmpty ? '无' : labels}'),
                Text('图片：$images 张'),
                Text(
                  '语音：${audio.length} 段 · ${_audioDuration(Duration(milliseconds: audio.fold<int>(0, (sum, item) => sum + item.durationMs)))}',
                ),
              ],
            ),
    );
  }
}

/// 详情和版本共用手机安全区、可滚动正文与明确关闭入口。
class _AndroidReadOnlySheet extends StatelessWidget {
  /// 当前只读任务名称。
  final String title;

  /// 不修改草稿的内容。
  final Widget child;

  /// 创建自然安全高度的移动面板。
  const _AndroidReadOnlySheet({required this.title, required this.child});

  /// 短屏大字号正文可滚动，标题和关闭保持可操作。
  @override
  Widget build(BuildContext context) => Material(
    color: OmniColors.of(context).paper,
    borderRadius: const BorderRadius.vertical(
      top: Radius.circular(OmniSpacing.xl),
    ),
    clipBehavior: Clip.antiAlias,
    child: SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const SizedBox(width: OmniSize.touch),
                Expanded(
                  child: Text(
                    title,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                OmniIconButton(
                  tooltip: '关闭$title',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(OmniSpacing.md),
                child: SizedBox(width: double.infinity, child: child),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 版本正文独立阅读，确认恢复才通知调用者打开对应历史草稿。
class _AndroidNoteVersions extends ConsumerWidget {
  /// 固定原数据源。
  final NoteRepository source;

  /// 版本必须属于这一篇。
  final String id;

  /// 创建与编辑器解耦的版本列表。
  const _AndroidNoteVersions({required this.source, required this.id});

  /// 实时订阅原仓储，远端删除和源变更后禁用恢复。
  @override
  Widget build(
    BuildContext context,
    WidgetRef ref,
  ) => StreamBuilder<List<NoteVersionRecord>>(
    stream: source.watchVersions(id),
    builder: (context, snapshot) {
      // 恢复只在原正式篇仍存在时提供。
      final NoteEntryRecord? note = ref.watch(noteByIdProvider(id)).value;
      // 不把版本应用到另一数据源的同名笔记。
      final bool valid =
          identical(ref.watch(noteRepositoryProvider), source) &&
          note != null &&
          note.deletedAt == null;
      return _AndroidReadOnlySheet(
        title: '历史版本',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!valid) const Text('笔记或数据源已变化，无法恢复'),
            if (snapshot.hasError) const Text('版本加载失败，请重新打开重试'),
            if (!snapshot.hasData && !snapshot.hasError)
              const Center(child: CircularProgressIndicator()),
            if (snapshot.hasData && snapshot.data!.isEmpty)
              const Text('暂无历史版本'),
            for (final NoteVersionRecord version in snapshot.data ?? []) ...[
              Text(
                _androidNoteTime(version.createdAt, seconds: true),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              NoteMarkdownText(source: version.body),
              OmniButton(
                label: '恢复此版本',
                variant: OmniButtonVariant.text,
                onPressed: valid ? () => Navigator.pop(context, version) : null,
              ),
              const Divider(),
            ],
          ],
        ),
      );
    },
  );
}

/// 打开只读根面板，底层列表筛选和滚动不变。
Future<T?> _androidReadOnlySheet<T>(
  BuildContext context,
  WidgetBuilder builder,
) => Navigator.of(context, rootNavigator: true).push<T>(
  ModalBottomSheetRoute<T>(
    builder: builder,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    sheetAnimationStyle: OmniMotion.androidModalStyle(context),
  ),
);
