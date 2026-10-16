part of 'android_notes_view.dart';

/// 紧凑筛选使用独立条件草稿，只有确认才向搜索页返回结果。
class _AndroidNoteFilterSheet extends ConsumerStatefulWidget {
  /// 已经应用的条件快照。
  final NoteSearchFilter value;

  /// 创建自然高度的筛选面板。
  const _AndroidNoteFilterSheet({required this.value});

  /// 标签选择与普通筛选共用根覆盖层。
  @override
  ConsumerState<_AndroidNoteFilterSheet> createState() =>
      _AndroidNoteFilterSheetState();
}

/// 标签不限是安卓呈现状态，映射为共享查询的空包含条件。
class _AndroidNoteFilterSheetState
    extends ConsumerState<_AndroidNoteFilterSheet> {
  /// 尚未提交的共享查询条件。
  late NoteSearchFilter _value;

  /// 安卓四种标签范围，包含空选择时仍保持用户的选择意图。
  late String _tagScope;

  /// 自定义日期的起点。
  late DateTime _start;

  /// 自定义日期的终点。
  late DateTime _end;

  /// 当前是否正在编辑标签子草稿。
  bool _choosingTags = false;

  /// 当前拖动距离，仅用于显式下滑取消。
  double _dragDistance = 0;

  /// 从已应用条件初始化一次，避免标签流刷新覆盖用户草稿。
  @override
  void initState() {
    super.initState();
    _value = widget.value;
    _tagScope = _value.tagMode == 'include' && _value.tagIds.isEmpty
        ? 'all'
        : _value.tagMode;
    _start = _value.customRange?.start ?? DateUtils.dateOnly(DateTime.now());
    _end = _value.customRange?.end ?? _start;
  }

  /// 子视图取消只丢弃本次标签选择，普通筛选取消整个面板。
  void _cancel() {
    FocusScope.of(context).unfocus();
    if (_choosingTags) {
      setState(() => _choosingTags = false);
    } else {
      Navigator.pop(context);
    }
  }

  /// 标签页返回先关闭键盘，再返回普通筛选视图。
  void _back(bool didPop, NoteSearchFilter? result) {
    if (didPop) return;
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      FocusScope.of(context).unfocus();
      return;
    }
    _cancel();
  }

  /// 重置只修改面板草稿，不提前执行查询。
  void _reset() => setState(() {
    _value = const NoteSearchFilter.empty();
    _tagScope = 'all';
  });

  /// 验证有效标签和日期后再提交，远端删除不会产生无效指定条件。
  void _apply(Set<String> validIds) {
    Navigator.pop(
      context,
      _value.copyWith(
        tagMode: _tagScope == 'all' ? 'include' : _tagScope,
        tagIds: _specified ? _value.tagIds.intersection(validIds) : {},
        customRange: _value.range == 'custom'
            ? DateTimeRange(start: _start, end: _end)
            : null,
      ),
    );
  }

  /// 包含与排除都需要额外指定至少一个有效标签。
  bool get _specified => _tagScope == 'include' || _tagScope == 'exclude';

  /// 展示共享日期条件，往年同日由快捷搜索进入。
  String get _dateLabel => _value.onThisDay
      ? '那年今日'
      : switch (_value.range) {
          'week' => '本周',
          'month' => '本月',
          'custom' => '自定义',
          'today' => '今天',
          'lastMonth' => '上月',
          'last7' => '近 7 天',
          'last30' => '近 30 天',
          _ => '不限时间',
        };

  /// 整个非滚动表面支持下滑，标签页下滑只取消子草稿。
  Widget _dismissOnDrag(Widget child) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onVerticalDragStart: (_) => _dragDistance = 0,
    onVerticalDragUpdate: (details) => _dragDistance += details.delta.dy,
    onVerticalDragEnd: (details) {
      if (_dragDistance > OmniSize.touch ||
          (details.primaryVelocity ?? 0) > 600) {
        _cancel();
      }
    },
    child: child,
  );

  /// 每个菜单都沿用Omni定位与主题，屏幕边缘由原生菜单自动避让。
  Widget _menu({
    required String name,
    required String label,
    required List<(String, String)> choices,
    required Set<String> selected,
    required ValueChanged<String> onSelected,
  }) {
    // 当前颜色用于菜单选中状态及行摘要。
    final OmniColors colors = OmniColors.of(context);
    return Builder(
      builder: (anchorContext) => OmniInkWell(
        key: ValueKey('android-filter-$name'),
        onTap: () async {
          // 缓存行锚点，菜单退场或旋转时不读取已卸载的上下文。
          final RenderBox anchor =
              anchorContext.findRenderObject()! as RenderBox;
          // 浮层与筛选位于同一个根导航覆盖层。
          final RenderBox overlay =
              Navigator.of(context).overlay!.context.findRenderObject()!
                  as RenderBox;
          // 右侧箭头下方为菜单锚点，靠边时由菜单布局自动翻转与钳制。
          RelativeRect position = _menuPosition(anchor, overlay);
          // 取消菜单不修改筛选，单次选择返回后才更新草稿。
          final String? choice = await showOmniMenu<String>(
            context: context,
            positionBuilder: (_, _) {
              if (anchor.attached && overlay.attached) {
                position = _menuPosition(anchor, overlay);
              }
              return position;
            },
            constraints: BoxConstraints(
              minWidth: OmniMenuMetrics.minWidth,
              maxWidth: math.min(
                OmniMenuMetrics.maxWidth,
                MediaQuery.sizeOf(context).width - OmniSpacing.xxl,
              ),
            ),
            menuPadding: const EdgeInsets.all(OmniSpacing.xxs),
            items: [
              // 多选内容同样在单次选择后关闭，下次打开仍显示全部勾选。
              for (final (String, String) choice in choices)
                OmniPopupMenuItem<String>.custom(
                  key: ValueKey('android-filter-option-$name-${choice.$1}'),
                  value: choice.$1,
                  height: OmniSize.touch,
                  padding: const EdgeInsets.symmetric(
                    horizontal: OmniSpacing.sm,
                    vertical: OmniSpacing.xs,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          choice.$2,
                          style: TextStyle(
                            color: selected.contains(choice.$1)
                                ? colors.brand
                                : colors.ink,
                          ),
                        ),
                      ),
                      const SizedBox(width: OmniSpacing.xs),
                      if (selected.contains(choice.$1))
                        Icon(
                          Icons.check,
                          size: OmniSize.icon,
                          color: colors.brand,
                        )
                      else
                        const SizedBox(width: OmniSize.icon),
                    ],
                  ),
                ),
            ],
          );
          if (mounted && choice != null) onSelected(choice);
        },
        child: _AndroidFilterRow(name: name, value: label),
      ),
    );
  }

  /// 从整行右下角定位紧凑菜单，所有坐标均处于当前覆盖层内。
  RelativeRect _menuPosition(RenderBox anchor, RenderBox overlay) {
    // 菜单右缘对齐行箭头，垂直仅保留最小间隔。
    final Offset point = anchor.localToGlobal(
      Offset(
        anchor.size.width - OmniSpacing.md,
        anchor.size.height + OmniSpacing.xxs,
      ),
      ancestor: overlay,
    );
    return RelativeRect.fromRect(point & Size.zero, Offset.zero & overlay.size);
  }

  /// 自然高度和可滚动正文同时支持短屏、大字号及标签键盘。
  @override
  Widget build(BuildContext context) {
    // 候选标签沿用仓储排序，不构造额外层级。
    final List<TaxonomyEntry> tags =
        (ref.watch(noteTaxonomiesProvider).value ?? [])
            .where((tag) => tag.kind == 'tag' && tag.deletedAt == null)
            .toList();
    // 校验只接受当前仍存在的标签。
    final Set<String> validIds = tags.map((tag) => tag.id).toSet();
    // 已选标签按当前列表顺序呈现摘要。
    final List<TaxonomyEntry> selectedTags = tags
        .where((tag) => _value.tagIds.contains(tag.id))
        .toList();
    // 非法标签或倒置日期禁用确认。
    final bool valid =
        (!_specified || selectedTags.isNotEmpty) &&
        (_value.range != 'custom' || !_start.isAfter(_end));
    // 模式本身偏离默认也允许重置。
    final bool dirty = _value.isActive || _tagScope != 'all';
    // 当前表面随浅色与深色主题变化。
    final OmniColors colors = OmniColors.of(context);
    return PopScope<NoteSearchFilter>(
      canPop: !_choosingTags,
      onPopInvokedWithResult: _back,
      child: LayoutBuilder(
        builder: (context, constraints) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: math.max(
                0,
                constraints.maxHeight - MediaQuery.viewInsetsOf(context).bottom,
              ),
            ),
            child: _dismissOnDrag(
              Material(
                key: const ValueKey('android-note-filter-sheet'),
                color: colors.paper,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(OmniRadius.dialog),
                ),
                clipBehavior: Clip.antiAlias,
                child: SafeArea(
                  top: false,
                  child: _choosingTags
                      ? _AndroidNoteTagPicker(
                          tags: tags,
                          selected: _value.tagIds,
                          onCancel: _cancel,
                          onConfirm: (ids) {
                            FocusScope.of(context).unfocus();
                            setState(() {
                              _value = _value.copyWith(tagIds: ids);
                              _choosingTags = false;
                            });
                          },
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _AndroidFilterHeader(
                              title: '筛选',
                              closeTooltip: '收起筛选',
                              closeIcon: Icons.keyboard_arrow_down,
                              onCancel: _cancel,
                              onConfirm: valid ? () => _apply(validIds) : null,
                              onReset: dirty ? _reset : null,
                            ),
                            Flexible(
                              child: SingleChildScrollView(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _menu(
                                      name: '日期范围',
                                      label: _dateLabel,
                                      choices: const [
                                        ('all', '不限时间'),
                                        ('week', '本周'),
                                        ('month', '本月'),
                                        ('custom', '自定义'),
                                      ],
                                      selected: _value.onThisDay
                                          ? {}
                                          : {_value.range},
                                      onSelected: (range) => setState(
                                        () => _value = _value.copyWith(
                                          range: range,
                                          onThisDay: false,
                                        ),
                                      ),
                                    ),
                                    if (_value.range == 'custom' &&
                                        !_value.onThisDay)
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: OmniSpacing.md,
                                        ),
                                        child: Wrap(
                                          spacing: OmniSpacing.xs,
                                          children: [
                                            OmniDatePickerButton(
                                              label:
                                                  '开始 ${businessDayKey(_start)}',
                                              value: _start,
                                              initialDate: _start,
                                              firstDate: DateTime(2000),
                                              lastDate: DateTime.now(),
                                              onChanged: (day) =>
                                                  setState(() => _start = day),
                                            ),
                                            OmniDatePickerButton(
                                              label:
                                                  '结束 ${businessDayKey(_end)}',
                                              value: _end,
                                              initialDate: _end,
                                              firstDate: DateTime(2000),
                                              lastDate: DateTime.now(),
                                              onChanged: (day) =>
                                                  setState(() => _end = day),
                                            ),
                                            if (!valid && _start.isAfter(_end))
                                              const Text('结束日期不能早于开始日期'),
                                          ],
                                        ),
                                      ),
                                    _menu(
                                      name: '标签范围',
                                      label: switch (_tagScope) {
                                        'none' => '无标签',
                                        'include' => '包含指定标签',
                                        'exclude' => '排除指定标签',
                                        _ => '不限标签',
                                      },
                                      choices: const [
                                        ('all', '不限标签'),
                                        ('none', '无标签'),
                                        ('include', '包含指定标签'),
                                        ('exclude', '排除指定标签'),
                                      ],
                                      selected: {_tagScope},
                                      onSelected: (scope) => setState(() {
                                        _tagScope = scope;
                                        _value = _value.copyWith(
                                          tagMode: scope == 'all'
                                              ? 'include'
                                              : scope,
                                          tagIds:
                                              scope == 'all' || scope == 'none'
                                              ? {}
                                              : _value.tagIds,
                                        );
                                      }),
                                    ),
                                    if (_specified)
                                      OmniInkWell(
                                        key: const ValueKey(
                                          'android-filter-tags',
                                        ),
                                        onTap: () => setState(
                                          () => _choosingTags = true,
                                        ),
                                        child: _AndroidFilterRow(
                                          name: '指定标签',
                                          value: selectedTags.isEmpty
                                              ? '无'
                                              : '${selectedTags.first.name}'
                                                    '${selectedTags.length > 1 ? ' 等 ${selectedTags.length} 个' : ''}',
                                          arrow: Icons.chevron_right,
                                        ),
                                      ),
                                    _menu(
                                      name: '内容范围',
                                      label: _value.contents.length > 1
                                          ? '已选 ${_value.contents.length} 项'
                                          : _value.contents.isEmpty
                                          ? '所有内容'
                                          : switch (_value.contents.single) {
                                              'image' => '有图片',
                                              'link' => '有链接',
                                              _ => '有语音',
                                            },
                                      choices: const [
                                        ('all', '所有内容'),
                                        ('image', '有图片'),
                                        ('link', '有链接'),
                                        ('audio', '有语音'),
                                      ],
                                      selected: _value.contents.isEmpty
                                          ? {'all'}
                                          : _value.contents,
                                      onSelected: (type) => setState(() {
                                        // 克隆集合避免修改打开前的条件快照。
                                        final Set<String> contents = {
                                          ..._value.contents,
                                        };
                                        if (type == 'all') {
                                          contents.clear();
                                        } else if (!contents.add(type)) {
                                          contents.remove(type);
                                        }
                                        _value = _value.copyWith(
                                          contents: contents,
                                        );
                                      }),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: OmniSpacing.xs),
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

/// 统一视频中的居中标题、左关闭、右确认与可选重置。
class _AndroidFilterHeader extends StatelessWidget {
  /// 当前视图标题。
  final String title;

  /// 关闭操作的无障碍说明。
  final String closeTooltip;

  /// 普通面板向下，标签子面板使用叉号。
  final IconData closeIcon;

  /// 取消本视图临时修改。
  final VoidCallback onCancel;

  /// 合法条件才可以确认。
  final VoidCallback? onConfirm;

  /// 默认条件下不展示重置。
  final VoidCallback? onReset;

  /// 创建保持标题屏幕居中的紧凑工具栏。
  const _AndroidFilterHeader({
    required this.title,
    required this.closeTooltip,
    required this.closeIcon,
    required this.onCancel,
    required this.onConfirm,
    this.onReset,
  });

  /// 标题与两侧固定触控区分离，不随重置入口出现而跳动。
  @override
  Widget build(BuildContext context) => Stack(
    alignment: Alignment.center,
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: OmniSize.touch * 2),
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      ),
      Row(
        children: [
          OmniIconButton(
            tooltip: closeTooltip,
            icon: Icon(closeIcon, color: OmniColors.of(context).ink),
            onPressed: onCancel,
          ),
          const Spacer(),
          if (onReset != null)
            OmniIconButton(
              tooltip: '重置筛选',
              icon: Icon(Icons.restart_alt, color: OmniColors.of(context).ink),
              onPressed: onReset,
            ),
          OmniIconButton(
            tooltip: title == '筛选' ? '应用筛选' : '确认标签',
            icon: Icon(
              Icons.check,
              color: onConfirm == null
                  ? OmniColors.of(context).muted.withValues(alpha: .45)
                  : OmniColors.of(context).brand,
            ),
            onPressed: onConfirm,
          ),
        ],
      ),
    ],
  );
}

/// 筛选行最小56dp，大字号可撑高，右侧摘要保持灰色。
class _AndroidFilterRow extends StatelessWidget {
  /// 左侧条件名称。
  final String name;

  /// 右侧当前条件摘要。
  final String value;

  /// 普通菜单为双向箭头，标签选择为右箭头。
  final IconData arrow;

  /// 创建整行可触控的筛选摘要。
  const _AndroidFilterRow({
    required this.name,
    required this.value,
    this.arrow = Icons.unfold_more,
  });

  /// 条件长名称与摘要按空间分配，窄屏不溢出。
  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(
      minHeight: OmniSize.touch + OmniSpacing.xs,
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: OmniSpacing.md,
        vertical: OmniSpacing.xs,
      ),
      child: Row(
        children: [
          Expanded(child: Text(name)),
          const SizedBox(width: OmniSpacing.xs),
          Expanded(
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: TextStyle(color: OmniColors.of(context).muted),
            ),
          ),
          const SizedBox(width: OmniSpacing.xxs),
          Icon(arrow, size: OmniSize.icon, color: OmniColors.of(context).muted),
        ],
      ),
    ),
  );
}

/// 标签搜索与多选拥有独立副本，取消不改变普通筛选草稿。
class _AndroidNoteTagPicker extends StatefulWidget {
  /// 按现有顺序排列的有效标签。
  final List<TaxonomyEntry> tags;

  /// 打开子视图时的选择。
  final Set<String> selected;

  /// 正文标签编辑允许确认空集合，搜索指定标签默认仍要求非空。
  final bool allowEmpty;

  /// 放弃子视图修改。
  final VoidCallback onCancel;

  /// 确认当前有效标签集合。
  final ValueChanged<Set<String>> onConfirm;

  /// 创建一次标签选择会话。
  const _AndroidNoteTagPicker({
    required this.tags,
    required this.selected,
    required this.onCancel,
    required this.onConfirm,
    this.allowEmpty = false,
  });

  /// 输入焦点与候选筛选仅属于标签子视图。
  @override
  State<_AndroidNoteTagPicker> createState() => _AndroidNoteTagPickerState();
}

/// 关键词只改变候选列表，不删除已勾选标签。
class _AndroidNoteTagPickerState extends State<_AndroidNoteTagPicker> {
  /// 标签子草稿独立克隆，不修改父筛选条件。
  late final Set<String> _selected = {...widget.selected};

  /// 搜索候选标签的关键词。
  final TextEditingController _query = TextEditingController();

  /// 打开标签视图自动聚焦，取消搜索可以明确收起键盘。
  final FocusNode _focus = FocusNode();

  /// 释放标签搜索资源。
  @override
  void dispose() {
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 清空只改变候选查询，保持标签选择。
  void _clear() => setState(_query.clear);

  /// 平铺标签使用圆形多选标记，正文自适应剩余键盘空间。
  @override
  Widget build(BuildContext context) {
    // 选择只能提交仍存在的标签。
    final Set<String> ids = _selected.intersection(
      widget.tags.map((tag) => tag.id).toSet(),
    );
    // 标签关键词忽略首尾空白与大小写。
    final String keyword = _query.text.trim().toLowerCase();
    // 候选排序保留仓储原顺序。
    final List<TaxonomyEntry> candidates = widget.tags
        .where((tag) => tag.name.toLowerCase().contains(keyword))
        .toList();
    // 当前主题控制选中与未选中圆圈。
    final OmniColors colors = OmniColors.of(context);
    return SizedBox(
      key: const ValueKey('android-filter-tag-picker'),
      // 键盘占用从面板总高度中扣除，保持普通手机上的顶部位置。
      height: math.max(
        OmniSize.touch * 4,
        MediaQuery.sizeOf(context).height * .70 -
            MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        children: [
          _AndroidFilterHeader(
            title: '选择标签',
            closeTooltip: '取消标签选择',
            closeIcon: Icons.close,
            onCancel: widget.onCancel,
            onConfirm: ids.isEmpty && !widget.allowEmpty
                ? null
                : () => widget.onConfirm(ids),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.md),
            child: Row(
              children: [
                Expanded(
                  child: OmniTextField(
                    key: const ValueKey('android-filter-tag-search'),
                    controller: _query,
                    focusNode: _focus,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _focus.unfocus(),
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: '搜索标签',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _query.text.isEmpty
                          ? null
                          : OmniIconButton(
                              tooltip: '清空标签搜索',
                              icon: const Icon(Icons.cancel_outlined),
                              onPressed: _clear,
                            ),
                    ),
                  ),
                ),
                OmniButton(
                  label: '取消',
                  variant: OmniButtonVariant.text,
                  onPressed: () {
                    _clear();
                    _focus.unfocus();
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: OmniSpacing.xs),
          Expanded(
            child: ListView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              children: [
                if (candidates.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(OmniSpacing.md),
                    child: Text('没有匹配的标签'),
                  ),
                // 搜索隐藏候选时，选择集合仍独立保留。
                for (final TaxonomyEntry tag in candidates)
                  Semantics(
                    checked: ids.contains(tag.id),
                    child: OmniInkWell(
                      key: ValueKey('android-filter-tag-${tag.id}'),
                      onTap: () => setState(() {
                        if (!_selected.add(tag.id)) _selected.remove(tag.id);
                      }),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: OmniSpacing.md,
                          vertical: OmniSpacing.md,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${tag.iconEmoji ?? '#'} ${tag.name}',
                              ),
                            ),
                            const SizedBox(width: OmniSpacing.xs),
                            Icon(
                              ids.contains(tag.id)
                                  ? Icons.check_circle
                                  : Icons.radio_button_unchecked,
                              color: ids.contains(tag.id)
                                  ? colors.brand
                                  : colors.muted,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
