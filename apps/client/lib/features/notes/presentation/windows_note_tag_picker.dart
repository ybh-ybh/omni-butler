part of 'notes_page.dart';

/// 单行标签保持稳定身份，选中移到前部，取消后恢复规范顺序。
class _NoteComposerTagPicker extends StatefulWidget {
  /// 接收当前本机编辑会话，不拥有其生命周期。
  const _NoteComposerTagPicker({
    required this.editor,
    required this.tags,
    required this.expanded,
    required this.blocked,
  });

  /// 本次输入与标签关联仍通过现有草稿保存。
  final NoteEditorController editor;

  /// 按管理器规范顺序排列的有效标签。
  final List<TaxonomyEntry> tags;

  /// 井号按钮控制未选标签的可见性。
  final bool expanded;

  /// 发布或取消期间禁止更改标签。
  final bool blocked;

  /// 为连续移位保留动画时钟。
  @override
  State<_NoteComposerTagPicker> createState() => _NoteComposerTagPickerState();
}

/// 每轮从当前位置出发，快速反向不会先跳到上轮终点。
class _NoteComposerTagPickerState extends State<_NoteComposerTagPicker>
    with SingleTickerProviderStateMixin {
  /// 所有标签共享位移动画，显隐仍由各自连续过渡处理。
  late final AnimationController _motion = AnimationController(
    vsync: this,
    value: 1,
    duration: OmniMotion.panel,
  );

  /// 草稿对象会原地更新，因此单独保存已呈现的排序签名。
  late String _signature;

  /// 告知布局在每次改序时记录当前实际位置。
  int _revision = 0;

  /// 首次挂载就记录状态，避免首个选择被惰性初始化当作原状态。
  @override
  void initState() {
    super.initState();
    _signature = _orderSignature();
  }

  /// 当前已选身份、规范顺序与展开状态共同决定布局目标。
  String _orderSignature() =>
      '${widget.expanded}:${[for (final TaxonomyEntry tag in widget.tags) (tag.id, widget.editor.draft.tags.contains(tag.id))]}';

  /// 减少动画时立即结束正在播放的位移。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motion.duration = OmniMotion.duration(context, OmniMotion.panel);
    if (_motion.duration == Duration.zero) _motion.value = 1;
  }

  /// 改序时从上一帧实际位置重新出发。
  @override
  void didUpdateWidget(covariant _NoteComposerTagPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 不比较可变编辑器对象，比较上一轮保存的身份状态。
    final String next = _orderSignature();
    if (next == _signature) return;
    _signature = next;
    _revision++;
    if (_motion.duration == Duration.zero) {
      _motion.value = 1;
    } else {
      _motion.forward(from: 0);
    }
  }

  /// 页面切换时释放本地动画时钟。
  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  /// 选择或取消只修改本机草稿标签，不改变主区筛选。
  void _select(TaxonomyEntry tag, bool selected) {
    if (widget.blocked ||
        widget.editor.frozen ||
        widget.editor.conflicted ||
        widget.editor.committing) {
      return;
    }
    // 保留其他已选关联，不改动管理器持久化顺序。
    final Set<String> next = {...widget.editor.draft.tags};
    if (selected) {
      next.add(tag.id);
    } else {
      next.remove(tag.id);
    }
    widget.editor.edit(tags: next);
  }

  /// 单行不足时横向滚动；节点留在原父级，避免语义子树重挂。
  @override
  Widget build(BuildContext context) {
    // 两个分区内都保留规范顺序，取消后回到未选区原位置。
    final List<String> order = [
      for (final TaxonomyEntry tag in widget.tags)
        if (widget.editor.draft.tags.contains(tag.id)) tag.id,
      for (final TaxonomyEntry tag in widget.tags)
        if (!widget.editor.draft.tags.contains(tag.id)) tag.id,
    ];
    // 提交、冻结与冲突沿用现有编辑器保护。
    final bool enabled =
        !widget.blocked &&
        !widget.editor.frozen &&
        !widget.editor.conflicted &&
        !widget.editor.committing;
    return Semantics(
      key: const ValueKey('note-composer-tags'),
      container: true,
      explicitChildNodes: true,
      child: SingleChildScrollView(
        key: const ValueKey('note-composer-tags-expansion'),
        scrollDirection: Axis.horizontal,
        primary: false,
        child: FocusTraversalGroup(
          policy: OrderedTraversalPolicy(),
          child: AnimatedBuilder(
            animation: _motion,
            builder: (context, _) => _NoteTagMotionRow(
              ids: [for (final TaxonomyEntry tag in widget.tags) tag.id],
              order: order,
              revision: _revision,
              progress: OmniMotion.standardCurve.transform(_motion.value),
              textDirection: Directionality.of(context),
              children: [
                for (final TaxonomyEntry tag in widget.tags)
                  Semantics(
                    key: ValueKey(tag.id),
                    container: true,
                    explicitChildNodes: true,
                    sortKey: OrdinalSortKey(order.indexOf(tag.id).toDouble()),
                    child: FocusTraversalOrder(
                      order: NumericFocusOrder(
                        order.indexOf(tag.id).toDouble(),
                      ),
                      child: _tag(tag, enabled),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 只对未选标签显隐，选中标签留在同一排。
  Widget _tag(TaxonomyEntry tag, bool enabled) {
    // 当前标签的选择状态。
    final bool selected = widget.editor.draft.tags.contains(tag.id);
    // 隐藏立即停止命中、焦点和读屏，不等待退场动画。
    final bool visible = selected || widget.expanded;
    return TweenAnimationBuilder<double>(
      key: ValueKey('note-tag-visibility-${tag.id}'),
      tween: Tween<double>(begin: 0, end: visible ? 1 : 0),
      duration: OmniMotion.duration(context, OmniMotion.panel),
      curve: OmniMotion.standardCurve,
      builder: (_, progress, child) => ClipRect(
        child: Align(
          alignment: Alignment.topLeft,
          widthFactor: progress,
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
      ),
      child: IgnorePointer(
        ignoring: !visible,
        child: ExcludeFocus(
          excluding: !visible,
          child: ExcludeSemantics(
            excluding: !visible,
            child: Padding(
              padding: const EdgeInsetsDirectional.only(
                end: OmniSpacing.xs,
                bottom: OmniSpacing.sm,
              ),
              child: OmniTaxonomyChip(
                key: ValueKey(
                  'note-${selected ? 'selected' : 'available'}-tag-${tag.id}',
                ),
                label: tag.name,
                selected: selected,
                onSelected: enabled ? (value) => _select(tag, value) : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 复用Flex自然尺寸和命中，仅插值子项位置，不重挂元素或语义。
class _NoteTagMotionRow extends MultiChildRenderObjectWidget {
  /// 子项按规范顺序挂载，展示顺序另行传入。
  const _NoteTagMotionRow({
    required this.ids,
    required this.order,
    required this.revision,
    required this.progress,
    required this.textDirection,
    required super.children,
  });

  /// 子项规范身份，与挂载顺序对应。
  final List<String> ids;

  /// 已选优先后的展示顺序。
  final List<String> order;

  /// 新目标代次，用于拍下中断前的位置。
  final int revision;

  /// 本轮连续过渡进度。
  final double progress;

  /// 保留所在界面的阅读方向。
  final TextDirection textDirection;

  /// 创建标准紧凑横排的布局对象。
  @override
  _RenderNoteTagMotionRow createRenderObject(BuildContext context) =>
      _RenderNoteTagMotionRow(textDirection: textDirection)
        ..update(ids, order, revision, progress);

  /// 每帧更新位置而不移动元素或无障碍身份。
  @override
  void updateRenderObject(
    BuildContext context,
    _RenderNoteTagMotionRow renderObject,
  ) {
    renderObject.textDirection = textDirection;
    renderObject.update(ids, order, revision, progress);
  }
}

/// 在Flex原生父数据中保留每个标签的动画起点。
class _NoteTagMotionData extends FlexParentData {
  /// 本轮动画的实际起点。
  Offset? begin;
}

/// 使用真实子项宽高，兼容长名称、字体缩放与窗口变化。
class _RenderNoteTagMotionRow extends RenderFlex {
  /// 横向滚动提供无界宽度，横排只占实际内容尺寸。
  _RenderNoteTagMotionRow({required TextDirection textDirection})
    : super(
        direction: Axis.horizontal,
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        textDirection: textDirection,
      );

  /// 子项的规范身份。
  List<String> _ids = const [];

  /// 当前展示顺序。
  List<String> _order = const [];

  /// 当前目标代次。
  int _revision = 0;

  /// 当前实际插值进度。
  double _progress = 1;

  /// 在原生Flex布局覆盖offset前，保存上一帧真实位置。
  void update(
    List<String> ids,
    List<String> order,
    int revision,
    double progress,
  ) {
    if (revision != _revision) {
      // 每个标签由同一个固定父节点管理。
      RenderBox? child = firstChild;
      while (child != null) {
        // 把仍在移动的位置作为下一段起点。
        final _NoteTagMotionData data = child.parentData! as _NoteTagMotionData;
        data.begin = data.offset;
        child = data.nextSibling;
      }
    }
    _ids = ids;
    _order = order;
    _revision = revision;
    _progress = progress;
    markNeedsLayout();
  }

  /// 附加动画数据，保留Flex原有布局协议。
  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _NoteTagMotionData) {
      child.parentData = _NoteTagMotionData();
    }
  }

  /// 先测量自然宽高，再按稳定身份计算同排目标。
  @override
  void performLayout() {
    super.performLayout();
    // 从规范子链建立身份映射，不按视觉顺序重挂子项。
    final Map<String, RenderBox> childrenById = {};
    // 遍历标准Flex子链。
    RenderBox? child = firstChild;
    for (final String id in _ids) {
      if (child == null) break;
      childrenById[id] = child;
      child = (child.parentData! as _NoteTagMotionData).nextSibling;
    }
    // 从阅读起点累加真实宽度，隐藏标签宽度也连续收回。
    double x = 0;
    for (final String id in _order) {
      // 本轮目标身份可能因外部删除而消失。
      final RenderBox? item = childrenById[id];
      if (item == null) continue;
      // 子项位置同时用于原生命中、焦点和读屏区域。
      final _NoteTagMotionData data = item.parentData! as _NoteTagMotionData;
      // RTL镜像目标，不改变规范排序语义。
      final Offset target = Offset(
        textDirection == TextDirection.rtl
            ? size.width - x - item.size.width
            : x,
        0,
      );
      data.begin ??= target;
      data.offset = Offset.lerp(data.begin, target, _progress)!;
      x += item.size.width;
    }
  }
}
