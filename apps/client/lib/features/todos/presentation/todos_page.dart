import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/todos/data/todo_priority_quadrant.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:omni_butler/features/todos/presentation/todo_editor_dialog.dart';
import 'package:omni_butler/features/todos/presentation/todo_priority_quadrant_style.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 每日待办的一级视图。
enum _TodoPageView {
  /// 跨日期常驻的进行中任务。
  active,

  /// 按完成日期浏览的历史任务。
  history,
}

/// 桌面拖拽携带的主任务信息。
class _TodoDragPayload {
  /// 主任务标识。
  final String rootId;

  /// 拖动开始时的象限。
  final TodoPriorityQuadrant sourceQuadrant;

  /// 创建拖拽信息。
  const _TodoDragPayload({required this.rootId, required this.sourceQuadrant});
}

/// 每日待办页面。
class TodosPage extends ConsumerStatefulWidget {
  /// 从首页带入的初始优先象限。
  final TodoPriorityQuadrant? initialPriorityQuadrant;

  /// 创建每日待办页面。
  const TodosPage({this.initialPriorityQuadrant, super.key});

  /// 创建每日待办页面状态。
  @override
  ConsumerState<TodosPage> createState() => _TodosPageState();
}

/// 每日待办页面状态。
class _TodosPageState extends ConsumerState<TodosPage> {
  /// 当前完成历史日期。
  late DateTime _selectedDay;

  /// 当前一级视图。
  _TodoPageView _pageView = _TodoPageView.active;

  /// 当前聚焦象限。
  TodoPriorityQuadrant? _priorityQuadrantFilter;

  /// 最近一次读取到的进行中任务树。
  List<TodoTreeNode> _latestTrees = <TodoTreeNode>[];

  /// 正在播放完成反馈的待办标识。
  final Set<String> _completingTodoIds = <String>{};

  /// 撤销浮动消息。
  OmniMessageHandle? _undoMessage;

  /// 初始化日期与首页带入的象限。
  @override
  void initState() {
    super.initState();
    _selectedDay = DateUtils.dateOnly(ref.read(nowProvider));
    _priorityQuadrantFilter = widget.initialPriorityQuadrant;
  }

  /// 响应路由中的象限变化。
  @override
  void didUpdateWidget(covariant TodosPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialPriorityQuadrant != widget.initialPriorityQuadrant) {
      _priorityQuadrantFilter = widget.initialPriorityQuadrant;
      _pageView = _TodoPageView.active;
    }
  }

  /// 释放撤销浮动消息。
  @override
  void dispose() {
    _undoMessage?.dismiss();
    super.dispose();
  }

  /// 构建进行中看板或完成历史。
  @override
  Widget build(BuildContext context) {
    // 当前固定时间。
    final DateTime now = ref.watch(nowProvider);
    // 当前自然日。
    final DateTime today = DateUtils.dateOnly(now);
    // 全部进行中任务树。
    final AsyncValue<List<TodoTreeNode>> activeAsync = ref.watch(
      activeTodoTreesProvider(today),
    );
    // 当前日期的完成历史。
    final AsyncValue<List<TodoHistoryEntry>> historyAsync = ref.watch(
      completedTodosForDayProvider(_selectedDay),
    );
    // 当前是否运行在桌面平台。
    final bool desktopPlatform = OmniBreakpoint.isDesktopPlatform(
      Theme.of(context).platform,
    );
    // 当前是否使用移动端内容流。
    final bool mobile =
        !desktopPlatform &&
        OmniBreakpoint.isCompact(MediaQuery.sizeOf(context).width);
    // 当前主体内容。
    final Widget content = _buildPageContent(
      context,
      activeAsync: activeAsync,
      historyAsync: historyAsync,
      now: now,
      mobile: mobile,
    );

    if (mobile) {
      return Stack(
        children: <Widget>[
          Positioned.fill(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                OmniSpacing.xs,
                OmniSpacing.xs,
                OmniSpacing.xs,
                88,
              ),
              child: content,
            ),
          ),
          if (_pageView == _TodoPageView.active)
            Positioned(
              right: OmniSpacing.md,
              bottom: OmniSpacing.md,
              child: OmniButton(
                key: const ValueKey<String>('todo-mobile-create'),
                label: '新增待办',
                icon: Icons.add_rounded,
                variant: OmniButtonVariant.pagePrimary,
                onPressed: () =>
                    TodoEditorDialog.show(context, initialDate: today),
              ),
            ),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: 14,
        vertical: OmniSpacing.sm,
      ),
      child: content,
    );
  }

  /// 构建页面标题、视图控制与主体。
  Widget _buildPageContent(
    BuildContext context, {
    required AsyncValue<List<TodoTreeNode>> activeAsync,
    required AsyncValue<List<TodoHistoryEntry>> historyAsync,
    required DateTime now,
    required bool mobile,
  }) {
    // 当前进行中任务树。
    final List<TodoTreeNode> trees =
        activeAsync.asData?.value ?? <TodoTreeNode>[];
    _latestTrees = trees;
    // 全部未完成节点数量。
    final int pendingCount = trees.fold<int>(
      0,
      (int count, TodoTreeNode tree) =>
          count + (tree.root.isCompleted ? 0 : 1) + tree.pendingChildrenCount,
    );
    // 当前视图主体。
    final Widget body = _pageView == _TodoPageView.active
        ? activeAsync.when(
            data: (List<TodoTreeNode> records) =>
                _buildActiveContent(context, records, now: now, mobile: mobile),
            loading: _buildLoading,
            error: (Object error, StackTrace stackTrace) =>
                _ErrorCard(message: '待办读取失败：$error'),
          )
        : historyAsync.when(
            data: (List<TodoHistoryEntry> records) => _CompletedTodoHistory(
              entries: records,
              onReopen: (TodoRecord todo) => _setTodoCompleted(todo, false),
              onEdit: (TodoRecord todo) =>
                  TodoEditorDialog.show(context, record: todo),
            ),
            loading: _buildLoading,
            error: (Object error, StackTrace stackTrace) =>
                _ErrorCard(message: '完成历史读取失败：$error'),
          );
    // 页面头部与控制区。
    final List<Widget> header = <Widget>[
      OmniPageHeader(
        title: '每日待办',
        description: _pageView == _TodoPageView.active
            ? '${trees.length} 个主任务 · $pendingCount 项未完成，跨计划日期常驻显示'
            : '${DateFormat('yyyy 年 M 月 d 日').format(_selectedDay)}完成的任务',
        actions: mobile || _pageView == _TodoPageView.history
            ? const <Widget>[]
            : <Widget>[
                OmniButton(
                  key: const ValueKey<String>('todo-primary-create'),
                  label: '新增待办',
                  icon: Icons.add_rounded,
                  variant: OmniButtonVariant.pagePrimary,
                  onPressed: () => TodoEditorDialog.show(
                    context,
                    initialDate: DateUtils.dateOnly(now),
                  ),
                ),
              ],
      ),
      const SizedBox(height: OmniSpacing.sm),
      _TodoViewBar(
        view: _pageView,
        selectedDay: _selectedDay,
        today: DateUtils.dateOnly(now),
        activeCount: pendingCount,
        onViewChanged: (_TodoPageView value) {
          _dismissUndo();
          setState(() {
            _pageView = value;
          });
        },
        onDaySelected: (DateTime value) {
          setState(() => _selectedDay = DateUtils.dateOnly(value));
        },
      ),
      const SizedBox(height: OmniSpacing.sm),
    ];
    if (mobile) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[...header, body],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ...header,
        Expanded(child: body),
      ],
    );
  }

  /// 构建统一加载状态。
  Widget _buildLoading() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(48),
        child: CircularProgressIndicator(),
      ),
    );
  }

  /// 构建按象限分组后的活动任务树。
  Widget _buildActiveContent(
    BuildContext context,
    List<TodoTreeNode> trees, {
    required DateTime now,
    required bool mobile,
  }) {
    // 按象限分组后的任务树。
    final Map<TodoPriorityQuadrant, List<TodoTreeNode>> grouped =
        <TodoPriorityQuadrant, List<TodoTreeNode>>{
          for (final TodoPriorityQuadrant quadrant
              in todoPriorityQuadrantMatrixOrder)
            quadrant: <TodoTreeNode>[],
        };
    for (final TodoTreeNode tree in trees) {
      // 主任务当前象限。
      final TodoPriorityQuadrant quadrant = TodoPriorityQuadrant.fromValue(
        tree.root.priorityQuadrant,
      );
      grouped[quadrant]!.add(tree);
    }
    for (final List<TodoTreeNode> quadrantTrees in grouped.values) {
      quadrantTrees.sort(_compareTrees);
    }
    if (mobile) {
      return _buildMobileBoard(context, grouped, now: now);
    }
    if (_priorityQuadrantFilter != null) {
      // 当前聚焦象限。
      final TodoPriorityQuadrant quadrant = _priorityQuadrantFilter!;
      return ListView(
        children: <Widget>[
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _priorityQuadrantFilter = null),
              icon: const Icon(Icons.arrow_back_rounded, size: 17),
              label: const Text('返回四象限'),
            ),
          ),
          _buildQuadrant(
            context,
            quadrant,
            grouped[quadrant]!,
            now: now,
            allowFocus: false,
            allowDrag: false,
          ),
        ],
      );
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 两列象限卡片宽度。
        final double width = (constraints.maxWidth - OmniSpacing.xs) / 2;
        return SingleChildScrollView(
          key: const ValueKey<String>('todo-quadrant-grid'),
          child: Wrap(
            spacing: OmniSpacing.xs,
            runSpacing: OmniSpacing.xs,
            children: <Widget>[
              for (final TodoPriorityQuadrant quadrant
                  in todoPriorityQuadrantMatrixOrder)
                SizedBox(
                  width: width,
                  child: _buildQuadrant(
                    context,
                    quadrant,
                    grouped[quadrant]!,
                    now: now,
                    allowFocus: true,
                    allowDrag: true,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// 构建移动端纵向象限。
  Widget _buildMobileBoard(
    BuildContext context,
    Map<TodoPriorityQuadrant, List<TodoTreeNode>> grouped, {
    required DateTime now,
  }) {
    // 当前需要展示的象限。
    final List<TodoPriorityQuadrant> quadrants = _priorityQuadrantFilter == null
        ? todoPriorityQuadrantActionOrder
        : <TodoPriorityQuadrant>[_priorityQuadrantFilter!];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _MobileQuadrantNavigation(
          selectedQuadrant: _priorityQuadrantFilter,
          counts: <TodoPriorityQuadrant, int>{
            for (final TodoPriorityQuadrant quadrant in grouped.keys)
              quadrant: grouped[quadrant]!.length,
          },
          onSelected: (TodoPriorityQuadrant? value) {
            setState(() => _priorityQuadrantFilter = value);
          },
        ),
        const SizedBox(height: OmniSpacing.xs),
        for (int index = 0; index < quadrants.length; index += 1) ...<Widget>[
          if (index > 0) const SizedBox(height: OmniSpacing.xs),
          KeyedSubtree(
            key: ValueKey<String>(
              'todo-mobile-section-${quadrants[index].value}-${_priorityQuadrantFilter == null ? 'all' : 'focused'}',
            ),
            child: _buildQuadrant(
              context,
              quadrants[index],
              grouped[quadrants[index]]!,
              now: now,
              allowFocus: false,
              allowDrag: false,
            ),
          ),
        ],
      ],
    );
  }

  /// 构建单个象限放置区。
  Widget _buildQuadrant(
    BuildContext context,
    TodoPriorityQuadrant quadrant,
    List<TodoTreeNode> trees, {
    required DateTime now,
    required bool allowFocus,
    required bool allowDrag,
  }) {
    return _TodoQuadrantDropZone(
      quadrant: quadrant,
      trees: trees,
      now: now,
      completingTodoIds: _completingTodoIds,
      allowDrag: allowDrag,
      onFocus: allowFocus
          ? () => setState(() => _priorityQuadrantFilter = quadrant)
          : null,
      onCreate: () => TodoEditorDialog.show(
        context,
        initialDate: DateUtils.dateOnly(ref.read(nowProvider)),
        initialPriorityQuadrant: quadrant,
      ),
      onDrop: (_TodoDragPayload payload, String? beforeRootId) =>
          _moveTree(payload, quadrant, beforeRootId),
      onCompletedChanged: _setTodoCompleted,
      onEdit: (TodoRecord todo) => TodoEditorDialog.show(context, record: todo),
      onAddChild: (TodoRecord root) => TodoEditorDialog.show(
        context,
        parent: root,
        initialDate: root.scheduledDate,
        initialPriorityQuadrant: quadrant,
      ),
      onMove: _moveTodoByDialog,
      onDelete: _confirmDelete,
    );
  }

  /// 比较同一象限内的任务树顺序。
  int _compareTrees(TodoTreeNode left, TodoTreeNode right) {
    // 用户排序比较结果。
    final int order = left.root.sortOrder.compareTo(right.root.sortOrder);
    if (order != 0) {
      return order;
    }
    // 无截止时间任务使用的远期时间。
    final DateTime distantFuture = DateTime(9999);
    // 截止时间比较结果。
    final int due = (left.root.dueAt ?? distantFuture).compareTo(
      right.root.dueAt ?? distantFuture,
    );
    return due != 0 ? due : left.root.createdAt.compareTo(right.root.createdAt);
  }

  /// 完成或重新打开单个任务，并提供浮动撤销消息。
  Future<void> _setTodoCompleted(TodoRecord todo, bool value) async {
    // 当前任务仓储。
    final TodoRepository repository = ref.read(todoRepositoryProvider);
    if (!value) {
      await repository.setCompleted(todo.id, false);
      return;
    }
    if (_completingTodoIds.contains(todo.id)) {
      return;
    }
    // 当前是否关闭非必要动画。
    final bool disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    // 当前任务树。
    TodoTreeNode? tree;
    if (todo.parentId == null) {
      for (final TodoTreeNode candidate in _latestTrees) {
        if (candidate.root.id == todo.id) {
          tree = candidate;
          break;
        }
      }
    }
    if (tree != null && tree.pendingChildrenCount > 0) {
      // 用户是否确认同时完成未完成子任务。
      final bool confirmed =
          await showDialog<bool>(
            context: context,
            builder: (BuildContext context) => AlertDialog(
              title: const Text('完成整个任务？'),
              content: Text('将同时完成 ${tree!.pendingChildrenCount} 个未完成子任务。'),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('全部完成'),
                ),
              ],
            ),
          ) ??
          false;
      if (!confirmed) {
        return;
      }
    }
    // 本次会改变状态的任务标识。
    final List<String> changedIds = tree == null
        ? <String>[todo.id]
        : <String>[
            if (!tree.root.isCompleted) tree.root.id,
            for (final TodoRecord child in tree.children)
              if (!child.isCompleted) child.id,
          ];
    setState(() => _completingTodoIds.addAll(changedIds));
    await Future<void>.delayed(
      disableAnimations ? Duration.zero : OmniMotion.normal,
    );
    await repository.setCompleted(todo.id, true);
    if (!mounted) {
      return;
    }
    setState(() => _completingTodoIds.removeAll(changedIds));
    _showUndoPopup(todo, changedIds);
  }

  /// 在根浮层中显示完成操作的撤销消息。
  void _showUndoPopup(TodoRecord todo, List<String> changedIds) {
    _dismissUndo();
    // 当前操作的稳定撤销标识。
    final List<String> undoIds = List<String>.of(changedIds);
    _undoMessage = showOmniMessage(
      context,
      message: '已完成“${todo.title}”',
      tone: OmniMessageTone.success,
      duration: const Duration(seconds: 6),
      actionLabel: '撤销',
      onAction: () => unawaited(_undoCompletion(undoIds)),
      onDismissed: () => _undoMessage = null,
    );
  }

  /// 撤销最近一次完成操作。
  Future<void> _undoCompletion(List<String> ids) async {
    for (final String id in ids) {
      await ref.read(todoRepositoryProvider).setCompleted(id, false);
    }
  }

  /// 关闭浮动撤销消息。
  void _dismissUndo() {
    _undoMessage?.dismiss();
    _undoMessage = null;
  }

  /// 将主任务拖动到目标象限与位置。
  Future<void> _moveTree(
    _TodoDragPayload payload,
    TodoPriorityQuadrant targetQuadrant,
    String? beforeRootId,
  ) async {
    // 原象限任务标识。
    final List<String> sourceIds = _latestTrees
        .where(
          (TodoTreeNode tree) =>
              tree.root.priorityQuadrant == payload.sourceQuadrant.value &&
              tree.root.id != payload.rootId,
        )
        .map((TodoTreeNode tree) => tree.root.id)
        .toList();
    // 目标象限任务标识，先移除拖动项避免同象限重复。
    final List<String> targetIds = _latestTrees
        .where(
          (TodoTreeNode tree) =>
              tree.root.priorityQuadrant == targetQuadrant.value &&
              tree.root.id != payload.rootId,
        )
        .map((TodoTreeNode tree) => tree.root.id)
        .toList();
    // 目标插入位置。
    final int foundIndex = beforeRootId == null
        ? targetIds.length
        : targetIds.indexOf(beforeRootId);
    // 安全的目标插入位置。
    final int targetIndex = foundIndex < 0 ? targetIds.length : foundIndex;
    targetIds.insert(targetIndex, payload.rootId);
    // 当前待办仓储。
    final TodoRepository repository = ref.read(todoRepositoryProvider);
    await repository.setPriorityQuadrant(payload.rootId, targetQuadrant);
    if (payload.sourceQuadrant != targetQuadrant) {
      await repository.reorderRoots(payload.sourceQuadrant, sourceIds);
    }
    await repository.reorderRoots(targetQuadrant, targetIds);
  }

  /// 通过菜单选择目标象限。
  Future<void> _moveTodoByDialog(TodoRecord todo) async {
    // 当前象限。
    final TodoPriorityQuadrant current = TodoPriorityQuadrant.fromValue(
      todo.priorityQuadrant,
    );
    // 用户选择的目标象限。
    final TodoPriorityQuadrant? target = await showDialog<TodoPriorityQuadrant>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: const Text('移动到其他象限'),
        children: <Widget>[
          for (final TodoPriorityQuadrant quadrant
              in todoPriorityQuadrantActionOrder)
            SimpleDialogOption(
              onPressed: quadrant == current
                  ? null
                  : () => Navigator.pop(context, quadrant),
              child: ListTile(
                enabled: quadrant != current,
                leading: Icon(quadrant.icon),
                title: Text(quadrant.actionLabel),
                subtitle: Text(quadrant.label),
                trailing: quadrant == current
                    ? const Icon(Icons.check_rounded)
                    : null,
              ),
            ),
        ],
      ),
    );
    if (target != null && target != current) {
      // 菜单移动默认追加到目标象限末尾。
      await _moveTree(
        _TodoDragPayload(
          rootId: todo.parentId ?? todo.id,
          sourceQuadrant: current,
        ),
        target,
        null,
      );
    }
  }

  /// 确认将待办树移入回收站。
  Future<void> _confirmDelete(TodoRecord todo) async {
    // 用户选择的删除范围。
    final TodoSeriesScope? scope = await showDialog<TodoSeriesScope>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('移入回收站？'),
        content: Text(
          todo.parentId == null
              ? '“${todo.title}”及其子任务会一起进入回收站。'
              : '“${todo.title}”会进入回收站。',
        ),
        actions: <Widget>[
          _TodoRecycleActionButton(
            key: const ValueKey<String>('todo-recycle-cancel-button'),
            label: '取消',
            tone: _TodoRecycleActionTone.cancel,
            onPressed: () => Navigator.pop(context),
          ),
          if (todo.repeatSeriesId != null)
            TextButton(
              onPressed: () => Navigator.pop(context, TodoSeriesScope.single),
              child: const Text('仅本次'),
            ),
          _TodoRecycleActionButton(
            key: const ValueKey<String>('todo-recycle-confirm-button'),
            label: todo.repeatSeriesId == null ? '移入回收站' : '本次及以后',
            tone: _TodoRecycleActionTone.danger,
            onPressed: () => Navigator.pop(
              context,
              todo.repeatSeriesId == null
                  ? TodoSeriesScope.single
                  : TodoSeriesScope.future,
            ),
          ),
        ],
      ),
    );
    if (scope == null) {
      return;
    }
    await ref.read(todoRepositoryProvider).delete(todo.id, scope: scope);
    ref.invalidate(recycleBinItemsProvider);
    if (mounted) {
      showOmniMessage(
        context,
        message: '“${todo.title}”已移入回收站',
        tone: OmniMessageTone.success,
      );
    }
  }
}

/// 回收站弹窗按钮的语义色类型。
enum _TodoRecycleActionTone {
  /// 取消操作使用品牌色。
  cancel,

  /// 移入回收站操作使用危险色。
  danger,
}

/// 每日待办回收站弹窗的边框揭示按钮。
class _TodoRecycleActionButton extends StatefulWidget {
  /// 按钮文字。
  final String label;

  /// 点击回调。
  final VoidCallback onPressed;

  /// 按钮语义色类型。
  final _TodoRecycleActionTone tone;

  /// 创建回收站弹窗按钮。
  const _TodoRecycleActionButton({
    required this.label,
    required this.onPressed,
    required this.tone,
    super.key,
  });

  /// 创建边框揭示动画状态。
  @override
  State<_TodoRecycleActionButton> createState() =>
      _TodoRecycleActionButtonState();
}

/// 回收站弹窗按钮的交互与动画状态。
class _TodoRecycleActionButtonState extends State<_TodoRecycleActionButton>
    with SingleTickerProviderStateMixin {
  /// 参考样式使用的完整动画时长。
  static const Duration _revealDuration = Duration(milliseconds: 300);

  /// 驱动两层遮罩依次退场的动画控制器。
  late final AnimationController _controller;

  /// 鼠标当前是否悬停在按钮上。
  bool _hovered = false;

  /// 键盘焦点当前是否位于按钮上。
  bool _focused = false;

  /// 初始化边框揭示动画。
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(duration: _revealDuration, vsync: this);
  }

  /// 根据无障碍设置切换正常动画或即时反馈。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 当前是否关闭非必要动画。
    final bool disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    _controller.duration = disableAnimations ? Duration.zero : _revealDuration;
  }

  /// 释放动画资源。
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 更新悬停状态并同步边框动画。
  void _handleHover(bool value) {
    _hovered = value;
    _syncRevealAnimation();
  }

  /// 更新键盘焦点状态并同步边框动画。
  void _handleFocus(bool value) {
    _focused = value;
    _syncRevealAnimation();
  }

  /// 让悬停与键盘焦点共用同一套揭示反馈。
  void _syncRevealAnimation() {
    // 当前是否需要显示完整边框。
    final bool reveal = _hovered || _focused;
    if (reveal) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  /// 构建主题自适应的按钮外观。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前按钮强调色。
    final Color toneColor = switch (widget.tone) {
      _TodoRecycleActionTone.cancel => colors.brandStrong,
      _TodoRecycleActionTone.danger => colors.danger,
    };
    // 按照原按钮类型保留水平内边距。
    final double horizontalPadding = switch (widget.tone) {
      _TodoRecycleActionTone.cancel => 10,
      _TodoRecycleActionTone.danger => 16,
    };
    // 当前按钮边框绘制区的测试标识。
    final String borderKey = switch (widget.tone) {
      _TodoRecycleActionTone.cancel => 'todo-recycle-cancel-border',
      _TodoRecycleActionTone.danger => 'todo-recycle-confirm-border',
    };
    // 当前按钮内容内边距的测试标识。
    final String paddingKey = switch (widget.tone) {
      _TodoRecycleActionTone.cancel => 'todo-recycle-cancel-padding',
      _TodoRecycleActionTone.danger => 'todo-recycle-confirm-padding',
    };
    // 当前按钮原生点击区域的测试标识。
    final String actionKey = switch (widget.tone) {
      _TodoRecycleActionTone.cancel => 'todo-recycle-cancel-action',
      _TodoRecycleActionTone.danger => 'todo-recycle-confirm-action',
    };
    // 当前主题紧凑密度对按钮视觉区域的尺寸调整。
    final Offset densityAdjustment = Theme.of(context)
        .visualDensity
        .baseSizeAdjustment;
    // 修改前 TextButton 与 FilledButton 的实际视觉高度。
    final double visualHeight = OmniSize.control + densityAdjustment.dy;

    return TextButton(
      key: ValueKey<String>(actionKey),
      onPressed: widget.onPressed,
      onHover: _handleHover,
      onFocusChange: _handleFocus,
      style: const ButtonStyle(
        padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(EdgeInsets.zero),
        backgroundColor: WidgetStatePropertyAll<Color>(Colors.transparent),
        overlayColor: WidgetStatePropertyAll<Color>(Colors.transparent),
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(OmniRadius.control)),
          ),
        ),
      ),
      child: SizedBox(
        height: visualHeight,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (BuildContext context, Widget? child) {
            return CustomPaint(
              key: ValueKey<String>(borderKey),
              painter: _TodoRecycleActionBorderPainter(
                progress: _controller.value,
                toneColor: toneColor,
                surfaceColor: colors.paper,
              ),
              child: child,
            );
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                key: ValueKey<String>(paddingKey),
                padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
                child: Text(
                  widget.label,
                  style: TextStyle(
                    color: toneColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 绘制参考样式中的边框和两层表面色遮罩。
class _TodoRecycleActionBorderPainter extends CustomPainter {
  /// 当前揭示进度。
  final double progress;

  /// 按钮边框语义色。
  final Color toneColor;

  /// 用于遮挡边框的弹窗表面色。
  final Color surfaceColor;

  /// 创建回收站按钮边框绘制器。
  const _TodoRecycleActionBorderPainter({
    required this.progress,
    required this.toneColor,
    required this.surfaceColor,
  });

  /// 绘制逐步露出的边框与延迟收起的顶部遮罩。
  @override
  void paint(Canvas canvas, Size size) {
    // 第一层遮罩沿用参考样式的缓出曲线。
    final double easedProgress = Curves.easeOut.transform(progress);
    // 按钮背景画笔。
    final Paint surfacePaint = Paint()..color = surfaceColor;
    // 按钮边框画笔。
    final Paint borderPaint = Paint()
      ..color = toneColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    // 按钮圆角矩形。
    final RRect buttonRect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(OmniRadius.control),
    );
    canvas.drawRRect(buttonRect, surfacePaint);
    canvas.drawRRect(buttonRect.deflate(1), borderPaint);

    // 第一层遮罩的最大高度，为常驻底边预留两个像素。
    final double primaryCoverMaxHeight = size.height - 2;
    // 第一层遮罩随动画向上移动并收缩高度。
    final double primaryCoverHeight =
        primaryCoverMaxHeight * (1 - easedProgress);
    // 第一层遮罩向上的位移量。
    final double primaryCoverTop = -2 - (25 * easedProgress);
    if (primaryCoverHeight > 0) {
      canvas.drawRect(
        Rect.fromLTWH(
          -2,
          primaryCoverTop,
          size.width + 6,
          primaryCoverHeight + 2,
        ),
        surfacePaint,
      );
    }

    // 第二层遮罩在动画后半段开始横向收缩。
    final double delayedLinearProgress = ((progress - 0.5) * 2).clamp(0, 1);
    // 第二层遮罩独立使用缓出曲线，保留 150 毫秒延迟。
    final double delayedProgress = Curves.easeOut.transform(
      delayedLinearProgress,
    );
    // 第二层遮罩的完整宽度。
    final double secondaryCoverFullWidth = size.width + 4;
    // 第二层遮罩当前宽度。
    final double secondaryCoverWidth =
        secondaryCoverFullWidth * (1 - delayedProgress);
    // 第二层遮罩的左右居中偏移。
    final double secondaryCoverLeft =
        -2 + ((secondaryCoverFullWidth - secondaryCoverWidth) / 2);
    // 第二层遮罩按控件高度保持与参考样式相同的窄条比例。
    final double secondaryCoverHeight = size.height * 0.18;
    if (secondaryCoverWidth > 0) {
      canvas.drawRect(
        Rect.fromLTWH(
          secondaryCoverLeft,
          -2,
          secondaryCoverWidth,
          secondaryCoverHeight,
        ),
        surfacePaint,
      );
    }
  }

  /// 仅在动画进度或主题色变化时重新绘制。
  @override
  bool shouldRepaint(covariant _TodoRecycleActionBorderPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.toneColor != toneColor ||
        oldDelegate.surfaceColor != surfaceColor;
  }
}

/// 一级视图和历史日期控制区。
class _TodoViewBar extends StatelessWidget {
  /// 当前视图。
  final _TodoPageView view;

  /// 当前历史日期。
  final DateTime selectedDay;

  /// 当前自然日。
  final DateTime today;

  /// 未完成节点数量。
  final int activeCount;

  /// 视图切换回调。
  final ValueChanged<_TodoPageView> onViewChanged;

  /// 历史日期切换回调。
  final ValueChanged<DateTime> onDaySelected;

  /// 创建视图控制区。
  const _TodoViewBar({
    required this.view,
    required this.selectedDay,
    required this.today,
    required this.activeCount,
    required this.onViewChanged,
    required this.onDaySelected,
  });

  /// 构建视图切换和可选日期巡航。
  @override
  Widget build(BuildContext context) {
    // 进行中与完成历史切换。
    final Widget selector = SegmentedButton<_TodoPageView>(
      showSelectedIcon: false,
      segments: <ButtonSegment<_TodoPageView>>[
        ButtonSegment<_TodoPageView>(
          value: _TodoPageView.active,
          label: Text('进行中 $activeCount'),
        ),
        const ButtonSegment<_TodoPageView>(
          value: _TodoPageView.history,
          label: Text('完成历史'),
        ),
      ],
      selected: <_TodoPageView>{view},
      onSelectionChanged: (Set<_TodoPageView> values) {
        onViewChanged(values.first);
      },
    );
    if (view == _TodoPageView.active) {
      return Align(alignment: Alignment.centerLeft, child: selector);
    }
    // 完成历史日期巡航。
    final Widget dateSelector = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        IconButton(
          tooltip: '前一天',
          onPressed: () =>
              onDaySelected(selectedDay.subtract(const Duration(days: 1))),
          icon: const Icon(Icons.chevron_left_rounded),
        ),
        OmniDatePickerButton(
          value: selectedDay,
          initialDate: selectedDay,
          currentDate: today,
          firstDate: DateTime(2000),
          lastDate: DateTime(2100),
          label: DateFormat('yyyy 年 M 月 d 日').format(selectedDay),
          onChanged: onDaySelected,
        ),
        IconButton(
          tooltip: '后一天',
          onPressed: () =>
              onDaySelected(selectedDay.add(const Duration(days: 1))),
          icon: const Icon(Icons.chevron_right_rounded),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth >= 720) {
          return Row(
            children: <Widget>[selector, const Spacer(), dateSelector],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            selector,
            const SizedBox(height: OmniSpacing.xs),
            dateSelector,
          ],
        );
      },
    );
  }
}

/// 单个四象限任务树放置区。
class _TodoQuadrantDropZone extends StatelessWidget {
  /// 当前象限。
  final TodoPriorityQuadrant quadrant;

  /// 当前象限任务树。
  final List<TodoTreeNode> trees;

  /// 当前时间。
  final DateTime now;

  /// 正在完成的待办标识。
  final Set<String> completingTodoIds;

  /// 是否允许桌面拖拽。
  final bool allowDrag;

  /// 聚焦象限回调。
  final VoidCallback? onFocus;

  /// 新增任务回调。
  final VoidCallback onCreate;

  /// 拖入任务回调。
  final Future<void> Function(_TodoDragPayload payload, String? beforeRootId)
  onDrop;

  /// 完成状态变化回调。
  final Future<void> Function(TodoRecord todo, bool value) onCompletedChanged;

  /// 编辑任务回调。
  final ValueChanged<TodoRecord> onEdit;

  /// 新增子任务回调。
  final ValueChanged<TodoRecord> onAddChild;

  /// 菜单移动回调。
  final ValueChanged<TodoRecord> onMove;

  /// 删除任务回调。
  final ValueChanged<TodoRecord> onDelete;

  /// 创建象限放置区。
  const _TodoQuadrantDropZone({
    required this.quadrant,
    required this.trees,
    required this.now,
    required this.completingTodoIds,
    required this.allowDrag,
    required this.onFocus,
    required this.onCreate,
    required this.onDrop,
    required this.onCompletedChanged,
    required this.onEdit,
    required this.onAddChild,
    required this.onMove,
    required this.onDelete,
  });

  /// 构建带悬停高亮和插入位置的象限卡片。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前象限强调色。
    final Color accent = quadrant.color(colors);
    return DragTarget<_TodoDragPayload>(
      key: ValueKey<String>('todo-drop-quadrant-${quadrant.value}'),
      onWillAcceptWithDetails: (DragTargetDetails<_TodoDragPayload> details) =>
          allowDrag,
      onAcceptWithDetails: (DragTargetDetails<_TodoDragPayload> details) {
        unawaited(onDrop(details.data, null));
      },
      builder:
          (
            BuildContext context,
            List<_TodoDragPayload?> candidates,
            List<dynamic> rejected,
          ) {
            // 当前是否有可接收的拖拽任务。
            final bool highlighted = allowDrag && candidates.isNotEmpty;
            return AnimatedContainer(
              duration: OmniMotion.fast,
              key: ValueKey<String>('todo-quadrant-card-${quadrant.value}'),
              decoration: BoxDecoration(
                color: highlighted
                    ? accent.withValues(alpha: 0.08)
                    : colors.paper,
                borderRadius: BorderRadius.circular(OmniRadius.panel),
                border: Border.all(
                  color: highlighted ? accent : colors.line,
                  width: highlighted ? 1.5 : 1,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Material(
                    color: accent.withValues(alpha: 0.055),
                    child: InkWell(
                      key: ValueKey<String>(
                        'todo-quadrant-heading-${quadrant.value}',
                      ),
                      onTap: onFocus,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          OmniSpacing.md,
                          OmniSpacing.xs,
                          OmniSpacing.xs,
                          OmniSpacing.xs,
                        ),
                        child: Row(
                          children: <Widget>[
                            Icon(quadrant.icon, size: 18, color: accent),
                            const SizedBox(width: OmniSpacing.xs),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    quadrant.actionLabel,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall
                                        ?.copyWith(fontWeight: FontWeight.w600),
                                  ),
                                  Text(
                                    quadrant.label,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(color: accent),
                                  ),
                                ],
                              ),
                            ),
                            OmniTag(label: '${trees.length}', color: accent),
                            IconButton(
                              tooltip: '添加到${quadrant.label}',
                              onPressed: onCreate,
                              icon: const Icon(Icons.add_rounded),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Divider(color: colors.line),
                  if (trees.isEmpty)
                    _QuadrantEmptyState(onCreate: onCreate)
                  else
                    for (
                      int index = 0;
                      index < trees.length;
                      index += 1
                    ) ...<Widget>[
                      if (index > 0) const Divider(indent: OmniSpacing.md),
                      if (allowDrag)
                        _TodoInsertTarget(
                          quadrant: quadrant,
                          beforeRootId: trees[index].root.id,
                          onDrop: onDrop,
                        ),
                      _TodoTreeCard(
                        tree: trees[index],
                        now: now,
                        completingTodoIds: completingTodoIds,
                        allowDrag: allowDrag,
                        quadrant: quadrant,
                        onCompletedChanged: onCompletedChanged,
                        onEdit: onEdit,
                        onAddChild: onAddChild,
                        onMove: onMove,
                        onDelete: onDelete,
                      ),
                    ],
                ],
              ),
            );
          },
    );
  }
}

/// 主任务前的精确插入目标。
class _TodoInsertTarget extends StatelessWidget {
  /// 目标象限。
  final TodoPriorityQuadrant quadrant;

  /// 插入位置后的主任务标识。
  final String beforeRootId;

  /// 放置回调。
  final Future<void> Function(_TodoDragPayload payload, String? beforeRootId)
  onDrop;

  /// 创建插入目标。
  const _TodoInsertTarget({
    required this.quadrant,
    required this.beforeRootId,
    required this.onDrop,
  });

  /// 构建窄插入线放置目标。
  @override
  Widget build(BuildContext context) {
    // 当前象限颜色。
    final Color accent = quadrant.color(OmniColors.of(context));
    return DragTarget<_TodoDragPayload>(
      key: ValueKey<String>('todo-drop-before-$beforeRootId'),
      onWillAcceptWithDetails: (DragTargetDetails<_TodoDragPayload> details) =>
          true,
      onAcceptWithDetails: (DragTargetDetails<_TodoDragPayload> details) {
        unawaited(onDrop(details.data, beforeRootId));
      },
      builder:
          (
            BuildContext context,
            List<_TodoDragPayload?> candidates,
            List<dynamic> rejected,
          ) {
            return AnimatedContainer(
              duration: OmniMotion.fast,
              height: candidates.isEmpty ? 2 : 8,
              color: candidates.isEmpty ? Colors.transparent : accent,
            );
          },
    );
  }
}

/// 单棵两层任务树。
class _TodoTreeCard extends StatelessWidget {
  /// 当前任务树。
  final TodoTreeNode tree;

  /// 当前时间。
  final DateTime now;

  /// 正在完成的待办标识。
  final Set<String> completingTodoIds;

  /// 是否允许主任务拖动。
  final bool allowDrag;

  /// 当前象限。
  final TodoPriorityQuadrant quadrant;

  /// 完成状态变化回调。
  final Future<void> Function(TodoRecord todo, bool value) onCompletedChanged;

  /// 编辑回调。
  final ValueChanged<TodoRecord> onEdit;

  /// 新增子任务回调。
  final ValueChanged<TodoRecord> onAddChild;

  /// 移动回调。
  final ValueChanged<TodoRecord> onMove;

  /// 删除回调。
  final ValueChanged<TodoRecord> onDelete;

  /// 创建任务树卡片。
  const _TodoTreeCard({
    required this.tree,
    required this.now,
    required this.completingTodoIds,
    required this.allowDrag,
    required this.quadrant,
    required this.onCompletedChanged,
    required this.onEdit,
    required this.onAddChild,
    required this.onMove,
    required this.onDelete,
  });

  /// 构建主任务、进度与子任务列表。
  @override
  Widget build(BuildContext context) {
    // 主任务行。
    final Widget rootRow = _TodoTaskRow(
      key: ValueKey<String>('todo-tree-root-${tree.root.id}'),
      todo: tree.root,
      now: now,
      completing: completingTodoIds.contains(tree.root.id),
      dragHandle: allowDrag
          ? Draggable<_TodoDragPayload>(
              data: _TodoDragPayload(
                rootId: tree.root.id,
                sourceQuadrant: quadrant,
              ),
              feedback: ExcludeSemantics(
                child: Material(
                  elevation: 6,
                  borderRadius: BorderRadius.circular(OmniRadius.control),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 320),
                    child: Padding(
                      padding: const EdgeInsets.all(OmniSpacing.sm),
                      child: Text(tree.root.title),
                    ),
                  ),
                ),
              ),
              childWhenDragging: const Icon(
                Icons.drag_indicator_rounded,
                color: Colors.transparent,
              ),
              child: Icon(
                key: ValueKey<String>('todo-drag-handle-${tree.root.id}'),
                Icons.drag_indicator_rounded,
                size: 18,
              ),
            )
          : null,
      progressLabel: tree.children.isEmpty
          ? null
          : '${tree.completedChildrenCount}/${tree.children.length}',
      onCompletedChanged: (bool value) => onCompletedChanged(tree.root, value),
      onEdit: () => onEdit(tree.root),
      onAddChild: () => onAddChild(tree.root),
      onMove: () => onMove(tree.root),
      onDelete: () => onDelete(tree.root),
    );
    return Column(
      key: ValueKey<String>('todo-row-${tree.root.id}'),
      children: <Widget>[
        rootRow,
        for (final TodoRecord child in tree.children)
          Padding(
            key: ValueKey<String>('todo-child-${child.id}'),
            padding: const EdgeInsets.only(left: 36),
            child: _TodoTaskRow(
              todo: child,
              now: now,
              completing: completingTodoIds.contains(child.id),
              onCompletedChanged: (bool value) =>
                  onCompletedChanged(child, value),
              onEdit: () => onEdit(child),
              onMove: null,
              onDelete: () => onDelete(child),
            ),
          ),
      ],
    );
  }
}

/// 单条主任务或子任务行。
class _TodoTaskRow extends StatelessWidget {
  /// 当前任务。
  final TodoRecord todo;

  /// 当前时间。
  final DateTime now;

  /// 是否正在播放完成反馈。
  final bool completing;

  /// 可选拖动手柄。
  final Widget? dragHandle;

  /// 可选子任务进度。
  final String? progressLabel;

  /// 完成状态回调。
  final ValueChanged<bool> onCompletedChanged;

  /// 编辑回调。
  final VoidCallback onEdit;

  /// 可选新增子任务回调。
  final VoidCallback? onAddChild;

  /// 可选移动回调。
  final VoidCallback? onMove;

  /// 删除回调。
  final VoidCallback onDelete;

  /// 创建任务行。
  const _TodoTaskRow({
    required this.todo,
    required this.now,
    required this.completing,
    required this.onCompletedChanged,
    required this.onEdit,
    required this.onDelete,
    this.dragHandle,
    this.progressLabel,
    this.onAddChild,
    this.onMove,
    super.key,
  });

  /// 构建任务内容、元数据与操作菜单。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前是否存在辅助信息。
    final bool hasDetails =
        (todo.description?.trim().isNotEmpty ?? false) ||
        todo.dueAt != null ||
        todo.repeatRule != null ||
        todo.syncState != 'localSaved';
    // 当前是否关闭非必要动画。
    final bool disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return AnimatedOpacity(
      opacity: completing ? 0 : 1,
      duration: disableAnimations ? Duration.zero : OmniMotion.normal,
      child: AbsorbPointer(
        absorbing: completing,
        child: OmniListRow(
          onTap: onEdit,
          padding: const EdgeInsets.symmetric(
            horizontal: OmniSpacing.sm,
            vertical: OmniSpacing.xs,
          ),
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (dragHandle != null) ...<Widget>[
                dragHandle!,
                const SizedBox(width: OmniSpacing.xxs),
              ],
              Checkbox(
                value: todo.isCompleted || completing,
                onChanged: completing
                    ? null
                    : (bool? value) => onCompletedChanged(value ?? false),
              ),
            ],
          ),
          title: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  todo.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: todo.isCompleted ? colors.muted : colors.ink,
                    decoration: todo.isCompleted
                        ? TextDecoration.lineThrough
                        : null,
                  ),
                ),
              ),
              if (progressLabel != null)
                Padding(
                  padding: const EdgeInsets.only(left: OmniSpacing.xs),
                  child: OmniTag(
                    key: ValueKey<String>('todo-tree-progress-${todo.id}'),
                    label: progressLabel!,
                    color: colors.todo,
                  ),
                ),
            ],
          ),
          subtitle: hasDetails ? _TodoDetails(todo: todo, now: now) : null,
          trailing: OmniPopupMenuButton<String>(
            tooltip: '更多操作',
            onSelected: (String value) {
              if (value == 'edit') {
                onEdit();
              } else if (value == 'child') {
                onAddChild?.call();
              } else if (value == 'move') {
                onMove?.call();
              } else if (value == 'delete') {
                onDelete();
              }
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              OmniPopupMenuItem<String>(
                value: 'edit',
                label: '编辑',
                icon: Icons.edit_outlined,
              ),
              if (onAddChild != null)
                OmniPopupMenuItem<String>(
                  key: ValueKey<String>('todo-add-child-${todo.id}'),
                  value: 'child',
                  label: '添加子任务',
                  icon: Icons.subdirectory_arrow_right_rounded,
                ),
              if (onMove != null)
                OmniPopupMenuItem<String>(
                  value: 'move',
                  label: '移动象限',
                  icon: Icons.drive_file_move_outline,
                ),
              OmniPopupMenuItem<String>(
                value: 'delete',
                label: '移入回收站',
                icon: Icons.delete_outline_rounded,
                danger: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 已完成任务历史列表。
class _CompletedTodoHistory extends StatelessWidget {
  /// 当前日期完成记录。
  final List<TodoHistoryEntry> entries;

  /// 重新打开任务回调。
  final ValueChanged<TodoRecord> onReopen;

  /// 编辑任务回调。
  final ValueChanged<TodoRecord> onEdit;

  /// 创建完成历史列表。
  const _CompletedTodoHistory({
    required this.entries,
    required this.onReopen,
    required this.onEdit,
  });

  /// 构建按完成时间倒序排列的历史。
  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const Center(child: Text('这一天还没有完成任务'));
    }
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: entries.length,
      separatorBuilder: (BuildContext context, int index) =>
          const SizedBox(height: OmniSpacing.xs),
      itemBuilder: (BuildContext context, int index) {
        // 当前历史条目。
        final TodoHistoryEntry entry = entries[index];
        // 当前完成时间。
        final DateTime completedAt = entry.todo.completedAt!;
        // 当前任务原有优先象限。
        final TodoPriorityQuadrant quadrant = TodoPriorityQuadrant.fromValue(
          entry.todo.priorityQuadrant,
        );
        // 当前象限强调色。
        final Color accent = quadrant.color(
          Theme.of(context).extension<OmniColors>()!,
        );
        return OmniPanel(
          key: ValueKey<String>('todo-history-row-${entry.todo.id}'),
          padding: const EdgeInsets.all(OmniSpacing.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Checkbox(
                value: true,
                onChanged: (bool? value) {
                  if (value == false) {
                    onReopen(entry.todo);
                  }
                },
              ),
              const SizedBox(width: OmniSpacing.xs),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            entry.todo.title,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  decoration: TextDecoration.lineThrough,
                                ),
                          ),
                        ),
                        const SizedBox(width: OmniSpacing.xs),
                        OmniTag(label: quadrant.actionLabel, color: accent),
                      ],
                    ),
                    if (entry.parentTitle != null)
                      Text(
                        '所属主任务：${entry.parentTitle}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    const SizedBox(height: OmniSpacing.xxs),
                    Text(
                      '创建 ${DateFormat('M月d日 HH:mm').format(entry.todo.createdAt)}  ·  '
                      '完成 ${DateFormat('HH:mm').format(completedAt)}  ·  '
                      '计划 ${DateFormat('M月d日').format(entry.todo.scheduledDate)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '编辑',
                onPressed: () => onEdit(entry.todo),
                icon: const Icon(Icons.edit_outlined),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 移动端象限导航。
class _MobileQuadrantNavigation extends StatelessWidget {
  /// 当前选中象限。
  final TodoPriorityQuadrant? selectedQuadrant;

  /// 各象限主任务数量。
  final Map<TodoPriorityQuadrant, int> counts;

  /// 象限选择回调。
  final ValueChanged<TodoPriorityQuadrant?> onSelected;

  /// 创建移动端象限导航。
  const _MobileQuadrantNavigation({
    required this.selectedQuadrant,
    required this.counts,
    required this.onSelected,
  });

  /// 构建横向滚动选择项。
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: <Widget>[
          ChoiceChip(
            key: const ValueKey<String>('todo-mobile-filter-all'),
            label: const Text('四象限'),
            selected: selectedQuadrant == null,
            onSelected: (bool selected) {
              if (selected) {
                onSelected(null);
              }
            },
          ),
          const SizedBox(width: OmniSpacing.xs),
          for (final TodoPriorityQuadrant quadrant
              in todoPriorityQuadrantActionOrder) ...<Widget>[
            ChoiceChip(
              key: ValueKey<String>('todo-mobile-filter-${quadrant.value}'),
              label: Text('${quadrant.actionLabel} ${counts[quadrant] ?? 0}'),
              selected: selectedQuadrant == quadrant,
              onSelected: (bool selected) {
                if (selected) {
                  onSelected(quadrant);
                }
              },
            ),
            const SizedBox(width: OmniSpacing.xs),
          ],
        ],
      ),
    );
  }
}

/// 任务描述、计划日期、截止与同步元数据。
class _TodoDetails extends StatelessWidget {
  /// 当前待办。
  final TodoRecord todo;

  /// 当前时间。
  final DateTime now;

  /// 创建任务辅助信息。
  const _TodoDetails({required this.todo, required this.now});

  /// 构建紧凑元数据。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 是否已经逾期。
    final bool overdue =
        !todo.isCompleted && todo.dueAt != null && todo.dueAt!.isBefore(now);
    // 清理后的描述。
    final String? description = todo.description?.trim().isNotEmpty ?? false
        ? todo.description!.trim()
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (description != null)
          Text(
            description,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colors.muted),
          ),
        Wrap(
          spacing: OmniSpacing.sm,
          runSpacing: OmniSpacing.xxs,
          children: <Widget>[
            _TodoMetadataItem(
              icon: Icons.event_outlined,
              label: '计划 ${DateFormat('M月d日').format(todo.scheduledDate)}',
              color: colors.muted,
            ),
            if (todo.dueAt != null)
              _TodoMetadataItem(
                icon: overdue
                    ? Icons.error_outline_rounded
                    : Icons.schedule_outlined,
                label: overdue
                    ? '已逾期 ${DateFormat('M月d日 HH:mm').format(todo.dueAt!)}'
                    : '截止 ${DateFormat('M月d日 HH:mm').format(todo.dueAt!)}',
                color: overdue ? colors.danger : colors.muted,
              ),
            if (todo.repeatRule != null && todo.repeatRule != 'stopped')
              _TodoMetadataItem(
                icon: Icons.repeat_rounded,
                label: _repeatLabel(todo.repeatRule!),
                color: colors.muted,
              ),
            if (todo.syncState != 'localSaved')
              _TodoMetadataItem(
                icon: Icons.cloud_sync_outlined,
                label: '等待同步',
                color: colors.warning,
              ),
          ],
        ),
      ],
    );
  }

  /// 返回重复规则名称。
  String _repeatLabel(String value) {
    return switch (value) {
      'daily' => '每天',
      'weekly' => '每周',
      'monthly' => '每月',
      _ => '重复',
    };
  }
}

/// 单个任务元数据。
class _TodoMetadataItem extends StatelessWidget {
  /// 图标。
  final IconData icon;

  /// 文本。
  final String label;

  /// 颜色。
  final Color color;

  /// 创建任务元数据。
  const _TodoMetadataItem({
    required this.icon,
    required this.label,
    required this.color,
  });

  /// 构建图标与文本。
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 3),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
        ),
      ],
    );
  }
}

/// 空象限提示。
class _QuadrantEmptyState extends StatelessWidget {
  /// 新增回调。
  final VoidCallback onCreate;

  /// 创建空象限提示。
  const _QuadrantEmptyState({required this.onCreate});

  /// 构建紧凑空状态。
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(OmniSpacing.md),
      child: Row(
        children: <Widget>[
          const Expanded(child: Text('暂无进行中任务')),
          TextButton.icon(
            onPressed: onCreate,
            icon: const Icon(Icons.add_rounded, size: 16),
            label: const Text('添加'),
          ),
        ],
      ),
    );
  }
}

/// 页面错误卡片。
class _ErrorCard extends StatelessWidget {
  /// 错误说明。
  final String message;

  /// 创建错误卡片。
  const _ErrorCard({required this.message});

  /// 构建错误内容。
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        message,
        style: TextStyle(color: OmniColors.of(context).danger),
      ),
    );
  }
}
