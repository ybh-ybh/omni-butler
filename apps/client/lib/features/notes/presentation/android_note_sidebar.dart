part of 'android_notes_view.dart';

/// 抽屉路由每次重建，独立保存卸载时的位置，不依赖路由内的PageStorage。
class _AndroidSidebarScrollController extends ScrollController {
  /// 上次关闭时的实际偏移。
  double _saved = 0;

  /// 缓存留在主页面生命周期内。
  _AndroidSidebarScrollController() : super(keepScrollOffset: false);

  /// 新路由首帧直接使用原偏移，避免展开中跳回顶部。
  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => ScrollPositionWithSingleContext(
    physics: physics,
    context: context,
    initialPixels: _saved,
    keepScrollOffset: false,
    oldPosition: oldPosition,
  );

  /// 路由退出时保留最后位置。
  @override
  void detach(ScrollPosition position) {
    _saved = position.pixels;
    super.detach(position);
  }
}

/// 侧栏只返回明确的导航选择，不改变编辑会话。
class _AndroidSidebarSelection {
  /// Selects all notes, a quick category, tag, day, draft, or recycle bin.
  final String kind;

  /// 对应标签或日期身份。
  final String? value;

  /// 同一标签点选的具体分区。
  final String origin;

  /// 创建导航结果。
  const _AndroidSidebarSelection(this.kind, [this.value, this.origin = 'all']);
}

/// Recognizes only standalone quick filters as selected sidebar categories.
String? _androidSidebarFilterKind(NoteSearchFilter filter) {
  // Quick categories never carry date, tag, or anniversary constraints.
  final bool hasSharedCondition =
      filter.range != 'all' ||
      filter.customRange != null ||
      filter.tagIds.isNotEmpty ||
      filter.onThisDay;
  if (hasSharedCondition) return null;
  if (filter.tagMode == 'none' && filter.contents.isEmpty) return 'untagged';
  if (filter.tagMode != 'include' || filter.contents.length != 1) return null;
  if (filter.contents.contains('image')) return 'image';
  if (filter.contents.contains('audio')) return 'audio';
  return null;
}

/// Maps the active quick filter to the title shared by the sidebar and page.
String? _androidSidebarFilterLabel(NoteSearchFilter filter) =>
    switch (_androidSidebarFilterKind(filter)) {
      'untagged' => '无标签',
      'image' => '有图片',
      'audio' => '有语音',
      _ => null,
    };

/// 根抽屉与二级页面独立，不让横滑传给一级导航。
extension _AndroidNotesSidebar on _AndroidNotesViewState {
  /// 退出后保留抽屉滚动及点选来源。
  Future<void> _showSidebar() async {
    // 数据源固定到本次抽屉，异步结果不作用于另一资料库。
    final AppDatabase source = ref.read(appDatabaseProvider);
    // 原过滤只用于选中外观。
    final _AndroidSidebarSelection? selection =
        await Navigator.of(
          context,
          rootNavigator: true,
        ).push<_AndroidSidebarSelection>(
          _AndroidSidebarRoute(
            builder: (_) => _AndroidNoteSidebar(
              source: source,
              filter: _filter,
              selectedDay: _day,
              recycle: _recycle,
              controller: _sidebarScroll,
              origin: _sidebarOrigin,
              onOrigin: (value) => _sidebarOrigin = value,
              onDeleted: (id) {
                if (!mounted ||
                    !identical(ref.read(appDatabaseProvider), source)) {
                  return;
                }
                if (_filter.tagIds.contains(id)) {
                  _update(() {
                    _filter = const NoteSearchFilter.empty();
                    _sidebarOrigin = 'all';
                  });
                }
              },
            ),
            reduced: OmniMotion.reduce(context),
          ),
        );
    if (!mounted ||
        selection == null ||
        !identical(ref.read(appDatabaseProvider), source)) {
      return;
    }
    switch (selection.kind) {
      case 'all':
        _update(() {
          _filter = const NoteSearchFilter.empty();
          _day = null;
          _recycle = false;
          _sidebarOrigin = 'all';
        });
      case 'untagged':
        _update(() {
          _filter = NoteSearchFilter(tagMode: 'none');
          _day = null;
          _recycle = false;
          _sidebarOrigin = 'all';
        });
      case 'image':
        _update(() {
          _filter = NoteSearchFilter(contents: {'image'});
          _day = null;
          _recycle = false;
          _sidebarOrigin = 'all';
        });
      case 'audio':
        _update(() {
          _filter = NoteSearchFilter(contents: {'audio'});
          _day = null;
          _recycle = false;
          _sidebarOrigin = 'all';
        });
      case 'tag':
        _update(() {
          _filter = NoteSearchFilter(tagIds: {selection.value!});
          _day = null;
          _recycle = false;
          _sidebarOrigin = selection.origin;
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

  /// 草稿选择仍使用既有持久代次，打开后自动选择紧凑或历史呈现。
  Future<void> _showDrafts() async {
    await _editor.flush();
    if (!mounted || _editor.dirty) return;
    // 列表只选择草稿，不提前加载另一编辑身份。
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

/// 只覆盖本抽屉的水平过渡，手势接管同一个路由进度。
class _AndroidSidebarRoute extends PopupRoute<_AndroidSidebarSelection> {
  /// 内容由原页面保活的控制器提供。
  final WidgetBuilder builder;

  /// 系统减少动画直接显示。
  final bool reduced;

  /// 手势接管后进度直接对应位移。
  bool _direct = false;

  /// 创建可跟手收起的左抽屉。
  _AndroidSidebarRoute({required this.builder, required this.reduced});

  /// 视频的进入时长。
  @override
  Duration get transitionDuration =>
      reduced ? Duration.zero : const Duration(milliseconds: 300);

  /// 收起比展开更快。
  @override
  Duration get reverseTransitionDuration =>
      reduced ? Duration.zero : const Duration(milliseconds: 220);

  /// 遮罩保留主列表清晰背景。
  @override
  Color get barrierColor => Colors.black.withValues(alpha: .42);

  /// 点击遮罩退出。
  @override
  bool get barrierDismissible => true;

  /// 遮罩读屏说明。
  @override
  String get barrierLabel => '关闭笔记侧栏';

  /// 手势在当前位置接管，避免套第二段曲线发生跳变。
  void _beginDrag() {
    controller!.stop();
    if (!_direct) {
      _direct = true;
      controller!.value = Curves.easeOutCubic.transform(controller!.value);
    }
  }

  /// 拖动取消或未达到关闭阈值时，从当前画面吸附回展开位置。
  void _restore() => controller!.animateTo(
    1,
    duration: reduced ? Duration.zero : const Duration(milliseconds: 220),
    curve: Curves.easeOutCubic,
  );

  /// 横向拖动只操作抽屉，不传给一级导航。
  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    // 屏幕旋转后按新宽度重算抽屉和手势比例。
    final double width = math.min(MediaQuery.sizeOf(context).width * .82, 360);
    return Align(
      alignment: Alignment.centerLeft,
      child: SizedBox(
        width: width,
        height: double.infinity,
        child: GestureDetector(
          excludeFromSemantics: true,
          onHorizontalDragStart: (_) => _beginDrag(),
          onHorizontalDragUpdate: (details) => controller!.value =
              (controller!.value + details.delta.dx / width).clamp(0, 1),
          onHorizontalDragEnd: (details) {
            if (controller!.value < .72 ||
                details.velocity.pixelsPerSecond.dx < -500) {
              Navigator.pop(context);
            } else {
              _restore();
            }
          },
          onHorizontalDragCancel: _restore,
          child: builder(context),
        ),
      ),
    );
  }

  /// 整个抽屉同进度移动，遮罩由根路由管理。
  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => reduced
      ? child
      : AnimatedBuilder(
          animation: animation,
          child: child,
          builder: (context, child) {
            // 进入使用缓动，手势及其吸附沿实际进度继续。
            final double value = _direct
                ? animation.value
                : Curves.easeOutCubic.transform(animation.value);
            // 外部画布全屏，位移按实际抽屉宽度而非整屏。
            final double width = math.min(
              MediaQuery.sizeOf(context).width * .82,
              360,
            );
            return Transform.translate(
              offset: Offset(-width * (1 - value), 0),
              child: child,
            );
          },
        );
}

/// 安卓独立侧栏，统计和标签状态来自正式数据流。
class _AndroidNoteSidebar extends ConsumerStatefulWidget {
  /// 本次覆盖层的数据源。
  final AppDatabase source;

  /// 主列表已应用的标签条件。
  final NoteSearchFilter filter;

  /// 当前归档日筛选。
  final String? selectedDay;

  /// 回收站选择状态。
  final bool recycle;

  /// 原页面持有滚动控制器。
  final ScrollController controller;

  /// 上次选择的标签分区。
  final String origin;

  /// 取消置顶后同步选择来源。
  final ValueChanged<String> onOrigin;

  /// 删除后清理原列表失效条件。
  final ValueChanged<String> onDeleted;

  /// 创建本次抽屉。
  const _AndroidNoteSidebar({
    required this.source,
    required this.filter,
    required this.selectedDay,
    required this.recycle,
    required this.controller,
    required this.origin,
    required this.onOrigin,
    required this.onDeleted,
  });

  /// 建立搜索和菜单门禁。
  @override
  ConsumerState<_AndroidNoteSidebar> createState() =>
      _AndroidNoteSidebarState();
}

/// Keeps pinned and all-tag sections backed by the full active tag set.
class _AndroidNoteSidebarState extends ConsumerState<_AndroidNoteSidebar> {
  /// 菜单和异步提交只允许执行一次。
  bool _busy = false;

  /// 源变更后关闭所有本抽屉拥有的覆盖。
  bool _leaving = false;

  /// 原位删除当前筛选后立即显示全部笔记选中态。
  bool _clearedSelection = false;

  /// 当前具体分区，取消置顶后可回退。
  late String _origin = widget.origin;

  /// Keeps the active quick category visible when the sidebar reopens.
  late bool _allNotesExpanded;

  /// Keeps pinned tags visible until their heading is explicitly collapsed.
  bool _pinnedTagsExpanded = true;

  /// Keeps the complete tag list visible until its heading is collapsed.
  bool _allTagsExpanded = true;

  /// Restores disclosure visibility from the applied list filter.
  @override
  void initState() {
    super.initState();
    _allNotesExpanded =
        !widget.recycle &&
        widget.selectedDay == null &&
        _androidSidebarFilterKind(widget.filter) != null;
  }

  /// 扩展方法通过这里更新，保持State的受保护成员边界。
  void _update(VoidCallback action) {
    if (mounted) setState(action);
  }

  /// 导航结果在关闭后由根页面处理。
  void _select(String kind, [String? value, String origin = 'all']) =>
      Navigator.pop(context, _AndroidSidebarSelection(kind, value, origin));

  /// 统计选择归档日后一起关闭两层覆盖。
  Future<void> _statistics() async {
    FocusScope.of(context).unfocus();
    // 统计不继承主列表条件。
    final String? day = await showOmniModalBottomSheet<String>(
      context: context,
      builder: (_) => _AndroidNoteStatistics(source: widget.source),
    );
    if (mounted &&
        day != null &&
        identical(ref.read(appDatabaseProvider), widget.source)) {
      _select('day', day);
    }
  }

  /// 真实正式篇和标签驱动侧栏，不包含本机未发布内容。
  @override
  Widget build(BuildContext context) {
    if (!identical(ref.watch(appDatabaseProvider), widget.source) &&
        !_leaving) {
      _leaving = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // 二级页面和菜单必须先退出，不能只弹出最上面一个浮层。
        final ModalRoute<Object?>? own = ModalRoute.of(context);
        Navigator.of(context).popUntil((route) => identical(route, own));
        Navigator.pop(context);
      });
    }
    // 正式有效篇集合及其加载状态。
    final AsyncValue<List<NoteEntryRecord>> state = ref.watch(notesProvider);
    // 所有平铺有效标签。
    final AsyncValue<List<TaxonomyEntry>> taxonomy = ref.watch(
      noteTaxonomiesProvider,
    );
    // 统计排除墓碑，不受主列表筛选影响。
    final List<NoteEntryRecord> notes = (state.value ?? [])
        .where((note) => note.deletedAt == null)
        .toList();
    // 标签列表保持仓储顺序。
    final List<TaxonomyEntry> tags = (taxonomy.value ?? [])
        .where((tag) => tag.kind == 'tag' && tag.deletedAt == null)
        .toList();
    // 取消置顶后选中源自动回到全部标签。
    final String origin =
        _origin == 'pinned' &&
            taxonomy.hasValue &&
            !taxonomy.hasError &&
            !taxonomy.isLoading &&
            !tags.any(
              (tag) => tag.isPinned && widget.filter.tagIds.contains(tag.id),
            )
        ? 'all'
        : _origin;
    if (origin != _origin) {
      _origin = origin;
      widget.onOrigin(origin);
    }
    // 主题外观不采用参考产品的固定品牌色。
    final OmniColors colors = OmniColors.of(context);
    return Material(
      key: const ValueKey('android-notes-sidebar'),
      color: colors.paper,
      child: SafeArea(
        child: SingleChildScrollView(
          key: const ValueKey('android-sidebar-scroll'),
          controller: widget.controller,
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
              const SizedBox(height: OmniSpacing.xl),
              if (state.isLoading || taxonomy.isLoading)
                const LinearProgressIndicator(),
              if (state.hasError || taxonomy.hasError) const Text('统计加载失败'),
              Row(
                children: [
                  // Each statistic owns one third with left, center, or right alignment.
                  for (final (String, String, CrossAxisAlignment) item in [
                    ('${notes.length}', '笔记', CrossAxisAlignment.start),
                    ('${tags.length}', '标签', CrossAxisAlignment.center),
                    (
                      '${notes.map((note) => note.dayKey).toSet().length}',
                      '天',
                      CrossAxisAlignment.end,
                    ),
                  ])
                    Expanded(
                      child: OmniInkWell(
                        key: ValueKey('android-note-stat-${item.$2}'),
                        onTap: _statistics,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: OmniSpacing.sm,
                          ),
                          child: Column(
                            crossAxisAlignment: item.$3,
                            children: [
                              Text(
                                item.$1,
                                style: Theme.of(context).textTheme.headlineLarge
                                    ?.copyWith(color: colors.muted),
                              ),
                              Text(
                                item.$2,
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(color: colors.muted),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: OmniSpacing.md),
              _heatmap(notes),
              const SizedBox(height: OmniSpacing.xl),
              _allNotesNavigation(),
              const SizedBox(height: OmniSpacing.lg),
              if (tags.any((tag) => tag.isPinned)) ...[
                _sectionToggle(
                  '置顶标签',
                  expanded: _pinnedTagsExpanded,
                  onTap: () =>
                      _update(() => _pinnedTagsExpanded = !_pinnedTagsExpanded),
                ),
                OmniDisclosure(
                  key: const ValueKey('android-sidebar-pinned-tags'),
                  expanded: _pinnedTagsExpanded,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final TaxonomyEntry tag in tags.where(
                        (tag) => tag.isPinned,
                      ))
                        _tagRow(tag, 'pinned', origin),
                    ],
                  ),
                ),
                const SizedBox(height: OmniSpacing.lg),
              ],
              _tagHeader(tags),
              OmniDisclosure(
                key: const ValueKey('android-sidebar-all-tags'),
                expanded: _allTagsExpanded,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final TaxonomyEntry tag in tags)
                      _tagRow(tag, 'all', origin),
                    if (tags.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(OmniSpacing.sm),
                        child: Text('还没有标签'),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: OmniSpacing.lg),
              _navigation(
                '回收站',
                Icons.delete_outline,
                widget.recycle,
                () => _select('recycle'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Uses the lighter secondary hierarchy from the reference video.
  Widget _sectionTitle(String title, {String? label}) => Padding(
    key: ValueKey('android-sidebar-section-$title'),
    padding: const EdgeInsets.symmetric(
      horizontal: OmniSpacing.sm,
      vertical: OmniSpacing.xs,
    ),
    child: Text(
      label ?? title,
      style: Theme.of(context).textTheme.labelLarge
          ?.copyWith(color: const Color(0xFFC8C0A8)),
    ),
  );

  /// Turns a section heading into the reference disclosure trigger.
  Widget _sectionToggle(
    String title, {
    required bool expanded,
    required VoidCallback onTap,
  }) => OmniDisclosureToggle(
    expanded: expanded,
    child: OmniInkWell(
      key: ValueKey('android-sidebar-section-toggle-$title'),
      onTap: onTap,
      child: _sectionTitle(title, label: expanded ? title : '$title...'),
    ),
  );

  /// Separates all-notes selection from its quick-category disclosure button.
  Widget _allNotesNavigation() {
    // Combined search conditions must not falsely select the all-notes row.
    final bool allSelected =
        !widget.recycle &&
        widget.selectedDay == null &&
        (!widget.filter.isActive || _clearedSelection);
    // The disclosure arrow uses the exact foreground color of its parent row.
    final OmniColors colors = OmniColors.of(context);
    // Selected rows use accent ink while inactive rows use regular text ink.
    final Color rowForeground = allSelected ? colors.accentInk : colors.ink;
    // A child is selected only while its standalone category owns the view.
    final String? category =
        _clearedSelection || widget.recycle || widget.selectedDay != null
        ? null
        : _androidSidebarFilterKind(widget.filter);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _AndroidSidebarRow(
          key: const ValueKey('android-sidebar-all-notes'),
          selected: allSelected,
          leading: const Icon(Icons.grid_view_rounded),
          title: '全部笔记',
          onTap: () => _select('all'),
          trailing: OmniDisclosureToggle(
            expanded: _allNotesExpanded,
            child: OmniIconButton(
              key: const ValueKey('android-sidebar-all-notes-toggle'),
              tooltip: _allNotesExpanded ? '收起笔记分类' : '展开笔记分类',
              constraints: const BoxConstraints.tightFor(
                width: _AndroidSidebarRow.compactHeight,
                height: _AndroidSidebarRow.compactHeight,
              ),
              padding: EdgeInsets.zero,
              color: rowForeground,
              icon: AnimatedRotation(
                turns: _allNotesExpanded ? 0.25 : 0,
                duration: OmniMotion.duration(context, OmniMotion.panel),
                curve: OmniMotion.standardCurve,
                child: const Icon(Icons.chevron_right),
              ),
              onPressed: () =>
                  _update(() => _allNotesExpanded = !_allNotesExpanded),
            ),
          ),
        ),
        OmniDisclosure(
          key: const ValueKey('android-sidebar-note-categories'),
          expanded: _allNotesExpanded,
          child: Padding(
            padding: const EdgeInsets.only(left: OmniSpacing.xl),
            child: DecoratedBox(
              key: const ValueKey('android-sidebar-note-categories-guide'),
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: colors.line)),
              ),
              child: Padding(
                padding: const EdgeInsets.only(left: OmniSpacing.xs),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _navigation(
                      '无标签',
                      Icons.label_outline,
                      category == 'untagged',
                      () => _select('untagged'),
                      key: const ValueKey('android-sidebar-filter-untagged'),
                    ),
                    _navigation(
                      '有图片',
                      Icons.image_outlined,
                      category == 'image',
                      () => _select('image'),
                      key: const ValueKey('android-sidebar-filter-image'),
                    ),
                    _navigation(
                      '有语音',
                      Icons.mic_none_rounded,
                      category == 'audio',
                      () => _select('audio'),
                      key: const ValueKey('android-sidebar-filter-audio'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 主导航与标签使用相同圆角选中表面。
  Widget _navigation(
    String label,
    IconData icon,
    bool selected,
    VoidCallback action, {
    Key? key,
  }) => _AndroidSidebarRow(
    key: key,
    selected: selected,
    leading: Icon(icon),
    title: label,
    onTap: action,
  );

  /// 热图自然周与统计共用归档日，不把空白格做成假按钮。
  Widget _heatmap(List<NoteEntryRecord> notes) => LayoutBuilder(
    builder: (context, constraints) {
      // 今天为右侧最后一周，不受月份和跨年影响。
      final DateTime now = DateTime.now();
      // 十二个完整周的起点。
      final DateTime start = DateTime(
        now.year,
        now.month,
        now.day - now.weekday + 1 - 11 * 7,
      );
      // 按正式篇计数。
      final Map<String, int> counts = {};
      for (final NoteEntryRecord note in notes) {
        counts.update(note.dayKey, (count) => count + 1, ifAbsent: () => 1);
      }
      // 可读的主题色及格子边长。
      final OmniColors colors = OmniColors.of(context);
      // 窄屏保持十二列，不压缩文字字号。
      final double cell = math.max(0, (constraints.maxWidth - 11 * 5) / 12);
      return Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (int week = 0; week < 12; week++) ...[
                if (week > 0) const SizedBox(width: 5),
                Column(
                  children: [
                    for (int day = 0; day < 7; day++)
                      Builder(
                        builder: (context) {
                          // 日历构造避免夏令时重复日期。
                          final String key = businessDayKey(
                            DateTime(
                              start.year,
                              start.month,
                              start.day + week * 7 + day,
                            ),
                          );
                          // 当前格子的篇数。
                          final int count = counts[key] ?? 0;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 5),
                            child: Semantics(
                              label: '$key，$count 篇笔记',
                              button: count > 0,
                              selected: key == widget.selectedDay,
                              child: OmniInkWell(
                                onTap: count == 0
                                    ? null
                                    : () => _select('day', key),
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
                                        key == widget.selectedDay ||
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
          const SizedBox(height: OmniSpacing.sm),
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

/// 通用安卓侧栏行，选中色与文本反色在同一处处理。
class _AndroidSidebarRow extends StatelessWidget {
  /// Matches the compact reference row while allowing large text to grow.
  static const double compactHeight = 40;

  /// 左侧图标或标签emoji。
  final Widget leading;

  /// 行内完整名称。
  final String title;

  /// 只点选来源行高亮。
  final bool selected;

  /// 行主体执行筛选。
  final VoidCallback onTap;

  /// 独立菜单热区。
  final Widget? trailing;

  /// 创建紧凑的侧栏项。
  const _AndroidSidebarRow({
    super.key,
    required this.leading,
    required this.title,
    required this.selected,
    required this.onTap,
    this.trailing,
  });

  /// 触控热区随长文字自然增长。
  @override
  Widget build(BuildContext context) {
    // 前景和选中表面统一取主题。
    final OmniColors colors = OmniColors.of(context);
    // 主题主色的对应反色文字。
    final Color foreground = selected ? colors.accentInk : colors.ink;
    return Material(
      color: selected ? colors.brand : Colors.transparent,
      borderRadius: BorderRadius.circular(OmniSpacing.md),
      clipBehavior: Clip.antiAlias,
      child: IconTheme(
        data: IconThemeData(color: foreground, size: OmniSpacing.lg),
        child: DefaultTextStyle(
          style: Theme.of(context).textTheme.titleMedium!
              .copyWith(color: foreground),
          child: Row(
            children: [
              Expanded(
                child: OmniInkWell(
                  onTap: onTap,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: compactHeight),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: OmniSpacing.sm,
                        vertical: OmniSpacing.xxs,
                      ),
                      child: Row(
                        children: [
                          leading,
                          const SizedBox(width: OmniSpacing.sm),
                          Expanded(child: Text(title)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (trailing != null)
                SizedBox.square(dimension: compactHeight, child: trailing),
            ],
          ),
        ),
      ),
    );
  }
}
