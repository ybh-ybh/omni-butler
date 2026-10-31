part of 'android_notes_view.dart';

/// 两种标签页面共用视频式顶栏，业务各自控制保存和关闭。
class _AndroidTagPageScaffold extends StatelessWidget {
  /// 当前页面标题。
  final String title;

  /// 正文滚动区。
  final Widget child;

  /// 提交中冻结整个页面。
  final bool busy;

  /// 重命名采用×和勾，排序采用返回和保存。
  final bool appearance;

  /// 明确取消本页草稿。
  final VoidCallback onClose;

  /// 显式保存当前草稿。
  final VoidCallback? onSave;

  /// 创建独立安卓表面。
  const _AndroidTagPageScaffold({
    required this.title,
    required this.child,
    required this.busy,
    required this.onClose,
    required this.onSave,
    this.appearance = false,
  });

  /// 键盘由Scaffold一次避让，顶栏始终可见。
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: OmniColors.of(context).paper,
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: OmniSpacing.xs,
              vertical: OmniSpacing.xs,
            ),
            child: Row(
              children: [
                OmniIconButton(
                  tooltip: appearance ? '取消名称和图标编辑' : '返回标签列表',
                  icon: Icon(appearance ? Icons.close : Icons.chevron_left),
                  onPressed: busy ? null : onClose,
                ),
                Expanded(
                  child: Semantics(
                    namesRoute: true,
                    header: true,
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ),
                if (appearance)
                  OmniIconButton(
                    key: const ValueKey('android-tag-appearance-save'),
                    tooltip: '确认名称和图标',
                    icon: Icon(
                      Icons.check,
                      color: OmniColors.of(context).brand,
                    ),
                    onPressed: busy ? null : onSave,
                  )
                else
                  OmniButton(
                    key: const ValueKey('android-tag-order-save'),
                    label: '保存',
                    visualHeight: OmniSize.pageAction,
                    loading: busy,
                    showLoadingIndicator: false,
                    onPressed: busy ? null : onSave,
                  ),
              ],
            ),
          ),
          Expanded(
            child: AbsorbPointer(absorbing: busy, child: child),
          ),
        ],
      ),
    ),
  );
}

/// 独立排序页只维护本次排列，返回不提前写仓储。
class _AndroidTagSortPage extends ConsumerStatefulWidget {
  /// 打开时的资料库。
  final AppDatabase source;

  /// 按规范顺序提供首帧标签。
  final List<TaxonomyEntry> tags;

  /// 创建排序草稿。
  const _AndroidTagSortPage({required this.source, required this.tags});

  /// 本页拥有拖动顺序和提交门禁。
  @override
  ConsumerState<_AndroidTagSortPage> createState() =>
      _AndroidTagSortPageState();
}

/// 远端只刷新名称和有效集合，不覆盖用户正在拖动的排列。
class _AndroidTagSortPageState extends ConsumerState<_AndroidTagSortPage> {
  /// 稳定ID顺序不随改名变化。
  late List<String> _ids = widget.tags.map((tag) => tag.id).toList();

  /// 保存中的退出保护。
  bool _saving = false;

  /// 松手后的落位动画完成前，保存等待真正的重排回调。
  Completer<void>? _pendingDrop;

  /// 原始拖动位置，用于识别放回原处无需重排的路径。
  int? _dragIndex;

  /// 拖动期间固定有效集合，远端增删时取消旧拖动。
  Set<String> _dragIds = {};

  /// 远端集合变化时替换内部列表，可靠取消SDK中的拖动代理。
  int _listGeneration = 0;

  /// 提交失败仍保留拖动结果。
  String? _error;

  /// 完成、取消或销毁都释放等待，避免保存停留在忙碌状态。
  void _finishDrop() {
    _pendingDrop?.complete();
    _pendingDrop = null;
    _dragIndex = null;
    _dragIds = {};
  }

  /// 关闭页面不遗留等待中的保存任务。
  @override
  void dispose() {
    _finishDrop();
    super.dispose();
  }

  /// 显式保存一次事务，不能作用于新资料库。
  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _pendingDrop?.future;
      if (!mounted) return;
      if (!identical(ref.read(appDatabaseProvider), widget.source)) {
        throw StateError('数据源已切换，请重新打开排序');
      }
      // 固定提交给原数据源的仓储。
      final TaxonomyRepository repository = ref.read(
        taxonomyRepositoryProvider,
      );
      await repository.reorderNoteTags(List.of(_ids));
      if (mounted && identical(ref.read(appDatabaseProvider), widget.source)) {
        Navigator.pop(context);
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 返回丢弃当前未保存排列。
  void _close() {
    if (!_saving) Navigator.pop(context);
  }

  /// 列表按ID对齐远端新增和删除，保存不覆写其他标签字段。
  @override
  Widget build(BuildContext context) {
    // 继续订阅有效平铺标签，错误不能被当成空集合保存。
    final AsyncValue<List<TaxonomyEntry>> state = ref.watch(
      noteTaxonomiesProvider,
    );
    // 当前有效资料库必须与打开时一致。
    final bool same = identical(ref.watch(appDatabaseProvider), widget.source);
    // 加载期间保留首帧顺序，成功后才协调集合。
    final List<TaxonomyEntry> tags = (state.value ?? widget.tags)
        .where((tag) => tag.kind == 'tag' && tag.deletedAt == null)
        .toList();
    // 字典用于显示最新名称和图标。
    final Map<String, TaxonomyEntry> byId = {
      for (final TaxonomyEntry tag in tags) tag.id: tag,
    };
    if (_pendingDrop != null &&
        (!same || !setEquals(_dragIds, byId.keys.toSet()))) {
      _finishDrop();
      _listGeneration++;
    }
    _ids = [
      ..._ids.where(byId.containsKey),
      ...tags.map((tag) => tag.id).where((id) => !_ids.contains(id)),
    ];
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: _AndroidTagPageScaffold(
        title: '标签排序',
        busy: _saving,
        onClose: _close,
        onSave: same && !state.hasError && state.hasValue && _ids.isNotEmpty
            ? _save
            : null,
        child: Column(
          key: const ValueKey('android-tag-sort-page'),
          children: [
            if (!same) const Text('数据源已切换，请重新打开'),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(OmniSpacing.md),
                child: Text(
                  _error!,
                  style: TextStyle(color: OmniColors.of(context).danger),
                ),
              ),
            if (state.hasError) const Text('标签加载失败，请返回重试'),
            Expanded(
              child: _ids.isEmpty
                  ? const Center(child: Text('暂无可排序标签'))
                  : Listener(
                      key: const ValueKey('android-tag-order-list'),
                      onPointerCancel: (_) => _finishDrop(),
                      child: ReorderableListView.builder(
                        key: ValueKey('android-tag-reorder-$_listGeneration'),
                        buildDefaultDragHandles: false,
                        itemCount: _ids.length,
                        padding: const EdgeInsets.symmetric(
                          vertical: OmniSpacing.sm,
                        ),
                        onReorderItem: (oldIndex, newIndex) {
                          if (!same) {
                            _finishDrop();
                            return;
                          }
                          setState(() {
                            _ids.insert(newIndex, _ids.removeAt(oldIndex));
                          });
                          _finishDrop();
                        },
                        onReorderStart: (index) {
                          _finishDrop();
                          _pendingDrop = Completer<void>();
                          _dragIndex = index;
                          _dragIds = _ids.toSet();
                        },
                        onReorderEnd: (index) {
                          // SDK的结束位置尚含被拖项，放回原位时不会触发onReorderItem。
                          final int? original = _dragIndex;
                          if (original != null &&
                              (index > original ? index - 1 : index) ==
                                  original) {
                            _finishDrop();
                          }
                        },
                        proxyDecorator: (child, index, animation) => Material(
                          color: OmniColors.of(context).paper,
                          elevation: 6,
                          borderRadius: BorderRadius.circular(OmniRadius.panel),
                          child: child,
                        ),
                        itemBuilder: (context, index) {
                          // 每个拖动项保持自己的身份和内容。
                          final TaxonomyEntry tag = byId[_ids[index]]!;
                          return Row(
                            key: ValueKey('android-tag-order-${tag.id}'),
                            children: [
                              ReorderableDragStartListener(
                                index: index,
                                enabled: !_saving && same,
                                child: Semantics(
                                  label: '拖动排序：${tag.name}',
                                  child: SizedBox(
                                    key: ValueKey(
                                      'android-tag-order-handle-${tag.id}',
                                    ),
                                    width: OmniSize.controlLarge,
                                    height: OmniSize.touch,
                                    child: Icon(
                                      Icons.drag_handle,
                                      size: OmniSize.icon,
                                      color: OmniColors.of(context).muted,
                                    ),
                                  ),
                                ),
                              ),
                              NoteTagIcon(emoji: tag.iconEmoji),
                              const SizedBox(width: OmniSpacing.sm),
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: OmniSpacing.md,
                                  ),
                                  child: Text(
                                    tag.name,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium,
                                  ),
                                ),
                              ),
                              const SizedBox(width: OmniSpacing.md),
                            ],
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 名称与图标共用一份本页草稿，确认之前不产生任何持久更新。
class _AndroidTagEditorPage extends ConsumerStatefulWidget {
  /// 打开时的资料库身份。
  final AppDatabase source;

  /// 为空时复用同一表面新增标签。
  final TaxonomyEntry? tag;

  /// 创建名称和图标编辑页。
  const _AndroidTagEditorPage({required this.source, this.tag});

  /// 本页拥有输入法、emoji和保存状态。
  @override
  ConsumerState<_AndroidTagEditorPage> createState() =>
      _AndroidTagEditorPageState();
}

/// 不自动弹键盘，短屏和系统键盘下整个正文都能滚动。
class _AndroidTagEditorPageState extends ConsumerState<_AndroidTagEditorPage> {
  /// 未提交的名称，不回写原始快照。
  late final TextEditingController _name = TextEditingController(
    text: widget.tag?.name ?? '',
  );

  /// emoji检索不改变已选图标。
  final TextEditingController _search = TextEditingController();

  /// 本页图标，空值是默认井号。
  late String? _emoji = widget.tag?.iconEmoji;

  /// 离线目录失败后允许重新读取。
  Future<NoteTagEmojiCatalog> _catalog = NoteTagEmojiCatalog.load();

  /// 原子提交期间冻结关闭和输入。
  bool _saving = false;

  /// 失败信息保留在当前正文内。
  String? _error;

  /// 释放本页输入资源。
  @override
  void dispose() {
    _name.dispose();
    _search.dispose();
    super.dispose();
  }

  /// 系统返回先收键盘，明确×直接取消本页草稿。
  void _close({bool back = false}) {
    if (_saving) return;
    if (back && MediaQuery.viewInsetsOf(context).bottom > 0) {
      FocusScope.of(context).unfocus();
    } else {
      Navigator.pop(context);
    }
  }

  /// 只提交用户实际改动的字段，避免覆盖远端改名或置顶。
  Future<void> _save() async {
    if (_saving ||
        (_name.value.composing.isValid && !_name.value.composing.isCollapsed)) {
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (!identical(ref.read(appDatabaseProvider), widget.source)) {
        throw StateError('数据源已切换，请重新打开标签');
      }
      // 名称首尾空白沿用仓储规范，重复校验也由仓储统一处理。
      final String name = _name.text.trim();
      if (name.isEmpty) throw const FormatException('名称不能为空');
      // 原库仓储在整个提交期间保持固定。
      final TaxonomyRepository repository = ref.read(
        taxonomyRepositoryProvider,
      );
      if (widget.tag != null) {
        await _androidRequireTag(context, ref, widget.source, widget.tag!.id);
        await repository.updateNoteTagAppearance(
          widget.tag!.id,
          name: name != widget.tag!.name ? Value(name) : const Value.absent(),
          iconEmoji: _emoji != widget.tag!.iconEmoji
              ? Value(_emoji)
              : const Value.absent(),
        );
      } else {
        // 新标签追加到规范排列末尾，不重排已有标签。
        final List<TaxonomyEntry> tags =
            ref.read(noteTaxonomiesProvider).value ?? [];
        await repository.save(
          TaxonomyDraft(
            module: TaxonomyModule.notes,
            kind: TaxonomyKind.tag,
            name: name,
            iconEmoji: _emoji,
            sortOrder:
                tags.fold<int>(
                  -1,
                  (value, tag) => math.max(value, tag.sortOrder),
                ) +
                1,
          ),
        );
      }
      if (mounted && identical(ref.read(appDatabaseProvider), widget.source)) {
        Navigator.pop(context);
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// emoji与默认井号保持同样触控热区和选择反馈。
  Widget _emojiTile(String? emoji, {String? label}) => Semantics(
    key: ValueKey('android-tag-icon-${emoji ?? 'default'}'),
    selected: emoji == _emoji,
    label: label ?? emoji ?? '默认井号',
    button: true,
    child: OmniInkWell(
      onTap: () => setState(() => _emoji = emoji),
      borderRadius: BorderRadius.circular(OmniRadius.control),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: emoji == _emoji
              ? OmniColors.of(context).brandSoft
              : Colors.transparent,
          borderRadius: BorderRadius.circular(OmniRadius.control),
        ),
        child: Center(child: NoteTagIcon(emoji: emoji, size: 28)),
      ),
    ),
  );

  /// 分类标题和网格均使用延迟构建，避免一次装载全部1611个控件。
  List<Widget> _emojiSlivers(NoteTagEmojiCatalog catalog, int columns) {
    // 搜索跨所有类别，选中图标持续保留。
    final List<NoteTagEmoji> entries = catalog.search(_search.text);
    // 常用只放默认井号，不引入新的本机收藏协议。
    final List<Widget> slivers = [
      const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: OmniSpacing.md),
          child: Text('常用'),
        ),
      ),
      SliverToBoxAdapter(
        child: Align(
          alignment: Alignment.centerLeft,
          child: SizedBox.square(dimension: 48, child: _emojiTile(null)),
        ),
      ),
    ];
    if (entries.isEmpty) {
      slivers.add(
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(OmniSpacing.md),
            child: Text('没有匹配的图标'),
          ),
        ),
      );
    }
    for (final MapEntry<String, String> category
        in NoteTagEmojiCatalog.categoryLabels.entries) {
      // 当前类别命中的原始稳定顺序。
      final List<NoteTagEmoji> group = entries
          .where((entry) => entry.category == category.key)
          .toList();
      if (group.isEmpty) continue;
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: OmniSpacing.md),
            child: Text(
              category.value,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ),
      );
      slivers.add(
        SliverGrid(
          delegate: SliverChildBuilderDelegate(
            (context, index) =>
                _emojiTile(group[index].emoji, label: group[index].label),
            childCount: group.length,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisExtent: math.max(
              48,
              MediaQuery.textScalerOf(context).scale(36),
            ),
            mainAxisSpacing: OmniSpacing.xxs,
            crossAxisSpacing: OmniSpacing.xxs,
          ),
        ),
      );
    }
    return slivers;
  }

  /// 顶栏固定，其余内容可以自然上滚，保留48dp以上候选热区。
  @override
  Widget build(BuildContext context) {
    // 资料库切换不能把旧表单提交给新源。
    final bool same = identical(ref.watch(appDatabaseProvider), widget.source);
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close(back: true);
      },
      child: _AndroidTagPageScaffold(
        title: widget.tag == null ? '新建标签' : '编辑名称和图标',
        appearance: true,
        busy: _saving,
        onClose: _close,
        onSave: same ? _save : null,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 常规七列，大字号窄屏减少列数，不缩小热区。
            final int columns =
                ((constraints.maxWidth - 32) /
                        math.max(
                          48,
                          MediaQuery.textScalerOf(context).scale(36),
                        ))
                    .floor()
                    .clamp(1, 7);
            return FutureBuilder<NoteTagEmojiCatalog>(
              future: _catalog,
              builder: (context, snapshot) => CustomScrollView(
                key: const ValueKey('android-tag-appearance-page'),
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: OmniSpacing.md,
                    ),
                    sliver: SliverMainAxisGroup(
                      slivers: [
                        SliverToBoxAdapter(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const SizedBox(height: OmniSpacing.xl),
                              Center(
                                child: SizedBox(
                                  height: 104,
                                  child: NoteTagIcon(emoji: _emoji, size: 72),
                                ),
                              ),
                              const SizedBox(height: OmniSpacing.md),
                              OmniTextField(
                                key: const ValueKey('android-tag-name'),
                                controller: _name,
                                enabled: !_saving && same,
                                decoration: const InputDecoration(
                                  hintText: '标签名称',
                                ),
                                textInputAction: TextInputAction.done,
                                onEditingComplete: () {},
                                onSubmitted: (_) => _save(),
                              ),
                              if (!same) const Text('数据源已切换，请重新打开'),
                              if (_error != null)
                                Text(
                                  _error!,
                                  style: TextStyle(
                                    color: OmniColors.of(context).danger,
                                  ),
                                ),
                              const SizedBox(height: OmniSpacing.lg),
                              OmniTextField(
                                key: const ValueKey('android-tag-icon-search'),
                                controller: _search,
                                decoration: InputDecoration(
                                  hintText: '搜索图标',
                                  prefixIcon: const Icon(Icons.search),
                                  suffixIcon: _search.text.isEmpty
                                      ? null
                                      : OmniIconButton(
                                          tooltip: '清空图标搜索',
                                          icon: const Icon(Icons.close),
                                          onPressed: () =>
                                              setState(() => _search.clear()),
                                        ),
                                ),
                                onChanged: (_) => setState(() {}),
                              ),
                            ],
                          ),
                        ),
                        if (snapshot.hasData)
                          ..._emojiSlivers(snapshot.data!, columns)
                        else if (snapshot.hasError)
                          SliverToBoxAdapter(
                            child: Column(
                              children: [
                                const Text('图标加载失败'),
                                OmniButton(
                                  label: '重试加载图标',
                                  onPressed: () => setState(
                                    () => _catalog = NoteTagEmojiCatalog.load(),
                                  ),
                                ),
                              ],
                            ),
                          )
                        else
                          const SliverToBoxAdapter(
                            child: Center(child: CircularProgressIndicator()),
                          ),
                        const SliverToBoxAdapter(
                          child: SizedBox(height: OmniSpacing.xl),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
