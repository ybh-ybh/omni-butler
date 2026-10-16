part of 'android_notes_view.dart';

/// 侧栏动作只返回选择，根路由关闭后再修改主视图或打开其他面板。
class _AndroidSidebarSelection {
  /// 全部、标签、日期、草稿列表或回收站。
  final String kind;

  /// 具体标签或日期身份。
  final String? value;

  /// 创建一次侧栏选择。
  const _AndroidSidebarSelection(this.kind, [this.value]);
}

/// 抽屉拥有独立根导航遮罩，不让横向手势穿透一级导航。
extension _AndroidNotesSidebar on _AndroidNotesViewState {
  /// 打开左侧抽屉，关闭后恢复底栏及主列表原位置。
  Future<void> _showSidebar() async {
    // 当前宽度限制保证手机右侧仍有可关闭的遮罩。
    final double width = math.min(MediaQuery.sizeOf(context).width * .82, 360);
    // 根抽屉返回的明确导航选择。
    final _AndroidSidebarSelection? selection =
        await Navigator.of(
          context,
          rootNavigator: true,
        ).push<_AndroidSidebarSelection>(
          RawDialogRoute<_AndroidSidebarSelection>(
            barrierDismissible: true,
            barrierLabel: '关闭笔记侧栏',
            barrierColor: Colors.black.withValues(alpha: .42),
            transitionDuration: OmniMotion.duration(context, OmniMotion.panel),
            pageBuilder: (context, _, _) => Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: width,
                height: double.infinity,
                child: _AndroidNoteSidebar(
                  filter: _filter,
                  selectedDay: _day,
                  recycle: _recycle,
                ),
              ),
            ),
            transitionBuilder: (_, animation, _, child) => SlideTransition(
              position:
                  Tween<Offset>(
                    begin: const Offset(-1, 0),
                    end: Offset.zero,
                  ).animate(
                    CurvedAnimation(
                      parent: animation,
                      curve: OmniMotion.standardCurve,
                    ),
                  ),
              child: child,
            ),
          ),
        );
    if (!mounted || selection == null) return;
    switch (selection.kind) {
      case 'all':
        _update(() {
          _filter = const NoteSearchFilter.empty();
          _day = null;
          _recycle = false;
        });
      case 'tag':
        _update(() {
          _filter = NoteSearchFilter(tagIds: {selection.value!});
          _day = null;
          _recycle = false;
        });
      case 'day':
        _update(() {
          _filter = const NoteSearchFilter.empty();
          _day = selection.value;
          _recycle = false;
        });
      case 'recycle':
        _update(() => _recycle = true);
      case 'drafts':
        await _showDrafts();
    }
  }

  /// 草稿列表按本机持久流更新，历史修改也能显式恢复。
  Future<void> _showDrafts() async {
    await _editor.flush();
    if (!mounted || _editor.dirty) return;
    // 先选择代次，列表关闭之后再打开编辑器，避免覆盖层相互遮挡。
    final String? id = await showOmniDialog<String>(
      context: context,
      builder: (context) => OmniDialogScaffold(
        title: '本机草稿',
        width: 560,
        height: 480,
        child: StreamBuilder<List<NoteLocalDraftRecord>>(
          stream: _editor.localDrafts.watch(),
          builder: (context, snapshot) {
            if (snapshot.hasError) return const Text('草稿加载失败，请关闭后重试');
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.data!.isEmpty) {
              return const Center(child: Text('暂无本机草稿'));
            }
            return ListView(
              children: [
                for (final NoteLocalDraftRecord draft in snapshot.data!)
                  OmniListTile(
                    title: Text(
                      NoteMarkdown.plainText(draft.body).trim().isEmpty
                          ? '图片或语音草稿'
                          : NoteMarkdown.plainText(draft.body),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${draft.isNew ? '未发布' : '历史修改'} · ${draft.dayKey}',
                    ),
                    onTap: () => Navigator.pop(context, draft.id),
                  ),
              ],
            );
          },
        ),
      ),
    );
    if (id != null && mounted) await _openEditor(draftId: id);
  }
}

/// 统计、热图和标签来自正式全量数据，不随列表过滤变化。
class _AndroidNoteSidebar extends ConsumerWidget {
  /// 主列表当前条件只用于导航选中态。
  final NoteSearchFilter filter;

  /// 当前归档日。
  final String? selectedDay;

  /// 是否正在浏览回收站。
  final bool recycle;

  /// 创建触屏友好的笔记抽屉。
  const _AndroidNoteSidebar({
    required this.filter,
    required this.selectedDay,
    required this.recycle,
  });

  /// 返回选择由父页面处理，避免在已退出的抽屉内打开新覆盖层。
  void _select(BuildContext context, String kind, [String? value]) =>
      Navigator.of(context).pop(_AndroidSidebarSelection(kind, value));

  /// 统计弹窗仍使用同一套聚合，选择有效日期后返回主列表。
  Future<void> _statistics(BuildContext context) async {
    // 统计弹窗选择的归档日。
    final String? day = await showNoteStatisticsDialog(context);
    if (day != null && context.mounted) _select(context, 'day', day);
  }

  /// 抽屉内容整体滚动，大字号和短屏不裁掉下方标签或回收站。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 全量正式笔记和有效标签，草稿单独显示数量。
    final AsyncValue<List<NoteEntryRecord>> state = ref.watch(notesProvider);
    // 当前标签流的加载及失败状态。
    final AsyncValue<List<TaxonomyEntry>> taxonomy = ref.watch(
      noteTaxonomiesProvider,
    );
    // 当前实际数据源的正式笔记集合。
    final List<NoteEntryRecord> notes = state.value ?? [];
    // 当前可用的有效标签集合。
    final List<TaxonomyEntry> tags = (taxonomy.value ?? [])
        .where((tag) => tag.kind == 'tag' && tag.deletedAt == null)
        .toList();
    // 当前主题的语义颜色。
    final OmniColors colors = OmniColors.of(context);
    return Material(
      key: const ValueKey('android-notes-sidebar'),
      color: colors.canvas,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(OmniSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '我的笔记',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  OmniIconButton(
                    tooltip: '关闭笔记侧栏',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: OmniSpacing.lg),
              if (state.isLoading || taxonomy.isLoading)
                const LinearProgressIndicator(),
              if (state.hasError || taxonomy.hasError) const Text('统计加载失败'),
              Row(
                children: [
                  for (final (String, String) item in [
                    ('${notes.length}', '笔记'),
                    ('${tags.length}', '标签'),
                    ('${notes.map((note) => note.dayKey).toSet().length}', '天'),
                  ])
                    Expanded(
                      child: OmniInkWell(
                        key: ValueKey('android-note-stat-${item.$2}'),
                        onTap: () => _statistics(context),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: OmniSpacing.sm,
                          ),
                          child: Column(
                            children: [
                              Text(
                                item.$1,
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineMedium,
                              ),
                              Text(
                                item.$2,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: OmniSpacing.md),
              _heatmap(context, notes),
              const SizedBox(height: OmniSpacing.lg),
              OmniListTile(
                selected:
                    !recycle && selectedDay == null && filter.tagIds.isEmpty,
                leading: const Icon(Icons.grid_view_rounded),
                title: const Text('全部笔记'),
                onTap: () => _select(context, 'all'),
              ),
              OmniListTile(
                leading: const Icon(Icons.drafts_outlined),
                title: const Text('草稿'),
                onTap: () => _select(context, 'drafts'),
              ),
              NoteTagSection(
                notes: notes,
                tags: tags,
                touchActions: true,
                selectedIds: recycle ? const {} : filter.tagIds,
                onSelect: (id) => _select(context, 'tag', id),
                onDeleted: (_) {},
              ),
              OmniListTile(
                selected: recycle,
                leading: const Icon(Icons.delete_outline),
                title: const Text('回收站'),
                onTap: () => _select(context, 'recycle'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 十二个完整周按自然日生成；空格没有误导性的筛选动作。
  Widget _heatmap(
    BuildContext context,
    List<NoteEntryRecord> notes,
  ) => LayoutBuilder(
    builder: (context, constraints) {
      // 使用当天所在周作最后一列，跨年仍从周一开始。
      final DateTime now = DateTime.now();
      // 完整周热图的首个归档日。
      final DateTime start = DateTime(
        now.year,
        now.month,
        now.day - now.weekday + 1 - 11 * 7,
      );
      // 归档日期对应的正式笔记数量。
      final Map<String, int> counts = {};
      for (final NoteEntryRecord note in notes) {
        counts.update(note.dayKey, (count) => count + 1, ifAbsent: () => 1);
      }
      // 当前主题的语义颜色。
      final OmniColors colors = OmniColors.of(context);
      // 在当前抽屉宽度下计算的热图格边长。
      final double cell = math.max(
        0,
        (constraints.maxWidth - OmniSpacing.xs * 11) / 12,
      );
      return Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (int week = 0; week < 12; week++) ...[
                if (week > 0) const SizedBox(width: OmniSpacing.xs),
                Column(
                  children: [
                    for (int day = 0; day < 7; day++)
                      Builder(
                        builder: (context) {
                          // 日期用构造器前进，避免夏令时导致日期重复。
                          final DateTime date = DateTime(
                            start.year,
                            start.month,
                            start.day + week * 7 + day,
                          );
                          // 与时区转换分离的稳定归档日期键。
                          final String key = businessDayKey(date);
                          // 该日期对应的正式笔记数量。
                          final int count = counts[key] ?? 0;
                          return Padding(
                            padding: const EdgeInsets.only(
                              bottom: OmniSpacing.xs,
                            ),
                            child: Semantics(
                              label: '$key，$count 篇笔记',
                              button: count > 0,
                              selected: key == selectedDay,
                              child: OmniInkWell(
                                onTap: count == 0
                                    ? null
                                    : () => _select(context, 'day', key),
                                child: Container(
                                  width: cell,
                                  height: cell,
                                  decoration: BoxDecoration(
                                    color: count == 0
                                        ? colors.mist
                                        : Color.lerp(
                                            colors.brandSoft,
                                            colors.brand,
                                            count.clamp(1, 5) / 5,
                                          ),
                                    borderRadius: BorderRadius.circular(
                                      OmniRadius.tiny,
                                    ),
                                    border:
                                        key == selectedDay ||
                                            key == businessDayKey(now)
                                        ? Border.all(color: colors.brand)
                                        : null,
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ],
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('${start.month}月'),
              Text(
                '${DateTime(start.year, start.month, start.day + 42).month}月',
              ),
              Text('${now.month}月'),
            ],
          ),
        ],
      );
    },
  );
}
