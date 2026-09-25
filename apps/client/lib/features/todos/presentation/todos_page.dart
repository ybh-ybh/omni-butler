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
import 'package:omni_butler/features/todos/presentation/todo_completion_checkbox.dart';
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

/// 待办页面当前聚焦象限的会话状态控制器。
class _TodoQuadrantFocusController extends Notifier<TodoPriorityQuadrant?> {
  /// 默认显示完整四象限布局。
  @override
  TodoPriorityQuadrant? build() => null;

  /// 更新当前聚焦象限，空值表示完整四象限布局。
  void setFocusedQuadrant(TodoPriorityQuadrant? quadrant) {
    state = quadrant;
  }
}

/// 跨一级页面切换保留的待办象限状态。
final NotifierProvider<_TodoQuadrantFocusController, TodoPriorityQuadrant?>
_todoQuadrantFocusProvider =
    NotifierProvider<_TodoQuadrantFocusController, TodoPriorityQuadrant?>(
      _TodoQuadrantFocusController.new,
    );

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

  /// 当前跨路由保留的聚焦象限。
  TodoPriorityQuadrant? get _priorityQuadrantFilter =>
      ref.read(_todoQuadrantFocusProvider);

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
    // 路由明确指定的初始象限。
    final TodoPriorityQuadrant? initialQuadrant =
        widget.initialPriorityQuadrant;
    if (initialQuadrant != null) {
      _setPriorityQuadrantFilter(initialQuadrant);
    }
  }

  /// 响应路由中的象限变化。
  @override
  void didUpdateWidget(covariant TodosPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 新路由明确指定的目标象限。
    final TodoPriorityQuadrant? initialQuadrant =
        widget.initialPriorityQuadrant;
    if (initialQuadrant != null &&
        oldWidget.initialPriorityQuadrant != initialQuadrant) {
      _setPriorityQuadrantFilter(initialQuadrant);
      _pageView = _TodoPageView.active;
    }
  }

  /// 更新会话内保留的聚焦象限。
  void _setPriorityQuadrantFilter(TodoPriorityQuadrant? quadrant) {
    ref.read(_todoQuadrantFocusProvider.notifier).setFocusedQuadrant(quadrant);
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
    // 监听跨路由保留的象限状态变化。
    ref.watch(_todoQuadrantFocusProvider);
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
    // 移动端导航展示的各象限主任务数量。
    final Map<TodoPriorityQuadrant, int> quadrantCounts =
        <TodoPriorityQuadrant, int>{
          for (final TodoPriorityQuadrant quadrant
              in todoPriorityQuadrantActionOrder)
            quadrant: 0,
        };
    for (final TodoTreeNode tree in trees) {
      // 当前主任务所属的象限。
      final TodoPriorityQuadrant quadrant = TodoPriorityQuadrant.fromValue(
        tree.root.priorityQuadrant,
      );
      quadrantCounts.update(quadrant, (int count) => count + 1);
    }
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
              key: ValueKey<String>(
                'todo-history-${DateUtils.dateOnly(_selectedDay).toIso8601String()}',
              ),
              mobile: mobile,
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
      if (!mobile) ...<Widget>[
        OmniPageHeader(
          title: '每日待办',
          description: _pageView == _TodoPageView.active
              ? '${trees.length} 个主任务 · $pendingCount 项未完成，跨计划日期常驻显示'
              : '${DateFormat('yyyy 年 M 月 d 日').format(_selectedDay)}完成的任务',
          actions: _pageView == _TodoPageView.history
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
      ],
      _TodoViewBar(
        view: _pageView,
        mobile: mobile,
        selectedDay: _selectedDay,
        today: DateUtils.dateOnly(now),
        activeCount: pendingCount,
        selectedQuadrant: _priorityQuadrantFilter,
        quadrantCounts: quadrantCounts,
        onViewChanged: (_TodoPageView value) {
          _dismissUndo();
          setState(() {
            _pageView = value;
          });
        },
        onDaySelected: (DateTime value) {
          setState(() => _selectedDay = DateUtils.dateOnly(value));
        },
        onQuadrantSelected: _setPriorityQuadrantFilter,
        onReturnToQuadrants:
            !mobile &&
                _pageView == _TodoPageView.active &&
                _priorityQuadrantFilter != null
            ? () => _setPriorityQuadrantFilter(null)
            : null,
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
    // 当前系统是否要求减少动态效果。
    final bool disableLayoutAnimation =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.of(context).accessibleNavigation;
    // 桌面端布局切换时使用的时长。
    final Duration transitionDuration = disableLayoutAnimation
        ? Duration.zero
        : OmniMotion.panel;
    // 当前桌面端象限布局。
    final Widget desktopBoard = _priorityQuadrantFilter == null
        ? _buildDesktopQuadrantGrid(context, grouped, now: now)
        : _buildDesktopFocusedBoard(
            context,
            grouped,
            focusedQuadrant: _priorityQuadrantFilter!,
            now: now,
          );
    return AnimatedSwitcher(
      duration: transitionDuration,
      reverseDuration: transitionDuration,
      switchInCurve: OmniMotion.standardCurve,
      switchOutCurve: OmniMotion.standardCurve,
      layoutBuilder: (Widget? currentChild, List<Widget> previousChildren) =>
          Stack(
            alignment: Alignment.topCenter,
            children: <Widget>[...previousChildren, ?currentChild],
          ),
      transitionBuilder: (Widget child, Animation<double> animation) {
        // 聚焦布局进入时的水平起点。
        final double horizontalOffset = _priorityQuadrantFilter == null
            ? 0
            : (_isLeftQuadrant(_priorityQuadrantFilter!) ? -0.025 : 0.025);
        // 当前布局的位移动画。
        final Animation<Offset> slideAnimation = Tween<Offset>(
          begin: Offset(horizontalOffset, 0),
          end: Offset.zero,
        ).animate(animation);
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(position: slideAnimation, child: child),
        );
      },
      child: desktopBoard,
    );
  }

  /// 构建桌面端默认的两行两列象限。
  Widget _buildDesktopQuadrantGrid(
    BuildContext context,
    Map<TodoPriorityQuadrant, List<TodoTreeNode>> grouped, {
    required DateTime now,
  }) {
    // 桌面端四象限按两行两列排列。
    final List<TodoPriorityQuadrant> quadrants =
        todoPriorityQuadrantMatrixOrder;
    return SingleChildScrollView(
      key: const ValueKey<String>('todo-quadrant-grid'),
      child: Column(
        children: <Widget>[
          for (int index = 0; index < quadrants.length; index += 2) ...<Widget>[
            if (index > 0) const SizedBox(height: OmniSpacing.xs),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(
                    child: _buildQuadrant(
                      context,
                      quadrants[index],
                      grouped[quadrants[index]]!,
                      now: now,
                      allowFocus: true,
                      allowDrag: true,
                    ),
                  ),
                  const SizedBox(width: OmniSpacing.xs),
                  if (index + 1 < quadrants.length)
                    Expanded(
                      child: _buildQuadrant(
                        context,
                        quadrants[index + 1],
                        grouped[quadrants[index + 1]]!,
                        now: now,
                        allowFocus: true,
                        allowDrag: true,
                      ),
                    )
                  else
                    const Spacer(),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 构建桌面端主象限与对侧纵向象限列。
  Widget _buildDesktopFocusedBoard(
    BuildContext context,
    Map<TodoPriorityQuadrant, List<TodoTreeNode>> grouped, {
    required TodoPriorityQuadrant focusedQuadrant,
    required DateTime now,
  }) {
    // 聚焦象限是否来自默认矩阵左侧。
    final bool focusedOnLeft = _isLeftQuadrant(focusedQuadrant);
    // 聚焦后在对侧纵向展示的其余象限。
    final List<TodoPriorityQuadrant> secondaryQuadrants =
        todoPriorityQuadrantMatrixOrder
            .where(
              (TodoPriorityQuadrant quadrant) => quadrant != focusedQuadrant,
            )
            .toList(growable: false);
    // 当前聚焦的主象限卡片。
    final Widget primaryQuadrant = _buildQuadrant(
      context,
      focusedQuadrant,
      grouped[focusedQuadrant]!,
      now: now,
      allowFocus: true,
      allowDrag: true,
    );
    // 对侧纵向排列的象限列。
    final Widget secondaryColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (
          int index = 0;
          index < secondaryQuadrants.length;
          index += 1
        ) ...<Widget>[
          if (index > 0) const SizedBox(height: OmniSpacing.xs),
          _buildQuadrant(
            context,
            secondaryQuadrants[index],
            grouped[secondaryQuadrants[index]]!,
            now: now,
            allowFocus: true,
            allowDrag: true,
          ),
        ],
      ],
    );
    // 聚焦象限和其余象限之间的水平间距。
    const Widget horizontalGap = SizedBox(width: OmniSpacing.xs);
    return SingleChildScrollView(
      key: ValueKey<String>('todo-quadrant-focus-${focusedQuadrant.value}'),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (focusedOnLeft) ...<Widget>[
              Expanded(flex: 2, child: primaryQuadrant),
              horizontalGap,
              Expanded(child: secondaryColumn),
            ] else ...<Widget>[
              Expanded(child: secondaryColumn),
              horizontalGap,
              Expanded(flex: 2, child: primaryQuadrant),
            ],
          ],
        ),
      ),
    );
  }

  /// 判断象限是否位于默认二维矩阵的左侧。
  bool _isLeftQuadrant(TodoPriorityQuadrant quadrant) {
    // 象限在二维矩阵中的位置。
    final int quadrantIndex = todoPriorityQuadrantMatrixOrder.indexOf(quadrant);
    return quadrantIndex.isEven;
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
          ? () => _setPriorityQuadrantFilter(
              _priorityQuadrantFilter == quadrant ? null : quadrant,
            )
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
    // 当前任务所属的任务树。
    TodoTreeNode? tree;
    for (final TodoTreeNode candidate in _latestTrees) {
      if (candidate.root.id == (todo.parentId ?? todo.id)) {
        tree = candidate;
        break;
      }
    }
    // 当前子任务是否为所属主任务的最后一个未完成子任务。
    final bool completesTree =
        todo.parentId != null && tree?.pendingChildrenCount == 1;
    // 本次会改变状态并需要播放离场动画的任务标识。
    final List<String> changedIds;
    if (todo.parentId == null && tree != null) {
      changedIds = <String>[
        if (!tree.root.isCompleted) tree.root.id,
        for (final TodoRecord child in tree.children)
          if (!child.isCompleted) child.id,
      ];
    } else if (completesTree) {
      changedIds = <String>[tree!.root.id, todo.id];
    } else {
      changedIds = <String>[todo.id];
    }
    setState(() => _completingTodoIds.addAll(changedIds));
    await Future<void>.delayed(
      disableAnimations
          ? Duration.zero
          : TodoCompletionCheckbox.animationDuration + OmniMotion.panel,
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
    final TodoPriorityQuadrant? target =
        await showOmniDialog<TodoPriorityQuadrant>(
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
    final TodoSeriesScope? scope = await showOmniDialog<TodoSeriesScope>(
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
                    fontWeight: FontWeight.w400,
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

  /// 是否使用移动端一体化导航。
  final bool mobile;

  /// 当前历史日期。
  final DateTime selectedDay;

  /// 当前自然日。
  final DateTime today;

  /// 未完成节点数量。
  final int activeCount;

  /// 当前移动端聚焦的象限。
  final TodoPriorityQuadrant? selectedQuadrant;

  /// 各象限主任务数量。
  final Map<TodoPriorityQuadrant, int> quadrantCounts;

  /// 视图切换回调。
  final ValueChanged<_TodoPageView> onViewChanged;

  /// 历史日期切换回调。
  final ValueChanged<DateTime> onDaySelected;

  /// 移动端象限切换回调。
  final ValueChanged<TodoPriorityQuadrant?> onQuadrantSelected;

  /// 返回完整四象限布局的回调。
  final VoidCallback? onReturnToQuadrants;

  /// 创建视图控制区。
  const _TodoViewBar({
    required this.view,
    required this.mobile,
    required this.selectedDay,
    required this.today,
    required this.activeCount,
    required this.selectedQuadrant,
    required this.quadrantCounts,
    required this.onViewChanged,
    required this.onDaySelected,
    required this.onQuadrantSelected,
    this.onReturnToQuadrants,
  });

  /// 构建视图切换和可选日期巡航。
  @override
  Widget build(BuildContext context) {
    if (mobile) {
      return _MobileTodoNavigation(
        view: view,
        selectedDay: selectedDay,
        today: today,
        activeCount: activeCount,
        selectedQuadrant: selectedQuadrant,
        quadrantCounts: quadrantCounts,
        onViewChanged: onViewChanged,
        onDaySelected: onDaySelected,
        onQuadrantSelected: onQuadrantSelected,
      );
    }
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
    // 视图切换器与可选返回操作。
    final Widget selectorActions = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        selector,
        if (onReturnToQuadrants != null) ...<Widget>[
          const SizedBox(width: OmniSpacing.xs),
          TextButton.icon(
            key: const ValueKey<String>('todo-return-quadrants'),
            onPressed: onReturnToQuadrants,
            icon: const Icon(Icons.arrow_back_rounded, size: 17),
            label: const Text('返回'),
          ),
        ],
      ],
    );
    if (view == _TodoPageView.active) {
      return Align(alignment: Alignment.centerLeft, child: selectorActions);
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
            children: <Widget>[selectorActions, const Spacer(), dateSelector],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            selectorActions,
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
                        key: ValueKey<String>(
                          'todo-tree-card-${trees[index].root.id}',
                        ),
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
class _TodoTreeCard extends StatefulWidget {
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
    super.key,
  });

  /// 创建任务树展开状态。
  @override
  State<_TodoTreeCard> createState() => _TodoTreeCardState();
}

/// 管理父任务的子任务展开状态与拖拽控制。
class _TodoTreeCardState extends State<_TodoTreeCard> {
  /// 展开控制与拖拽热区尺寸。
  static const double _treeControlSize = 32;

  /// 子任务当前是否展开。
  bool _expanded = true;

  /// 切换当前父任务的子任务展开状态。
  void _toggleChildren() {
    setState(() => _expanded = !_expanded);
  }

  /// 构建可单击展开并可拖动整棵任务树的双用途控制。
  Widget _buildTreeControl(TodoTreeNode tree) {
    // 当前任务树是否包含子任务。
    final bool hasChildren = tree.children.isNotEmpty;
    // 展开控制或纯拖拽手柄。
    final Widget control = SizedBox.square(
      key: hasChildren
          ? ValueKey<String>('todo-tree-toggle-${tree.root.id}')
          : null,
      dimension: _treeControlSize,
      child: IconButton(
        tooltip: hasChildren
            ? _expanded
                  ? '收起子任务'
                  : '展开子任务'
            : '拖动任务',
        onPressed: hasChildren ? _toggleChildren : null,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(
          width: _treeControlSize,
          height: _treeControlSize,
        ),
        icon: Icon(
          key: ValueKey<String>('todo-drag-handle-${tree.root.id}'),
          hasChildren
              ? _expanded
                    ? Icons.expand_more_rounded
                    : Icons.chevron_right_rounded
              : Icons.drag_indicator_rounded,
          size: 18,
        ),
      ),
    );
    if (!widget.allowDrag) {
      return control;
    }
    return Draggable<_TodoDragPayload>(
      data: _TodoDragPayload(
        rootId: tree.root.id,
        sourceQuadrant: widget.quadrant,
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
      childWhenDragging: const SizedBox.square(dimension: _treeControlSize),
      child: control,
    );
  }

  /// 构建主任务、进度与子任务列表。
  @override
  Widget build(BuildContext context) {
    // 当前任务树。
    final TodoTreeNode tree = widget.tree;
    // 当前仍在进行中并需要展示的直属子任务。
    final List<TodoRecord> pendingChildren = tree.children
        .where((TodoRecord child) => !child.isCompleted)
        .toList(growable: false);
    // 当前是否需要显示展开或拖拽控制。
    final bool showsTreeControl = tree.children.isNotEmpty || widget.allowDrag;
    // 父任务左侧的双用途控制。
    final Widget? treeControl = showsTreeControl
        ? _buildTreeControl(tree)
        : null;
    // 当前平台下复选框的完整点击区域尺寸。
    final Size checkboxTapSize = TodoCompletionCheckbox.tapSizeOf(context);
    // 父任务复选框中心轴，同时计入展开或拖拽控制宽度。
    final double treeTrunkX =
        OmniSpacing.sm +
        (treeControl == null ? 0 : _treeControlSize + OmniSpacing.xxs) +
        checkboxTapSize.width / 2;
    // 子任务相对父任务的水平缩进。
    final double childIndent = treeTrunkX + OmniSpacing.xxs;
    // 支线末端停在子任务视觉勾选框之前。
    final double branchEndX =
        childIndent +
        OmniSpacing.sm +
        (checkboxTapSize.width - TodoCompletionCheckbox.visualSize) / 2 -
        OmniSpacing.xxs;
    // 与未选中勾选框完全一致的树线颜色。
    final Color treeLineColor = TodoCompletionCheckbox.idleBorderColorOf(
      context,
    );
    // 主任务行。
    final Widget rootRow = _TodoTaskRow(
      key: ValueKey<String>('todo-tree-root-${tree.root.id}'),
      todo: tree.root,
      now: widget.now,
      completing: widget.completingTodoIds.contains(tree.root.id),
      treeControl: treeControl,
      progressLabel: tree.children.isEmpty ? null : '${tree.children.length}',
      onCompletedChanged: (bool value) =>
          widget.onCompletedChanged(tree.root, value),
      onEdit: () => widget.onEdit(tree.root),
      onAddChild: () => widget.onAddChild(tree.root),
      onMove: () => widget.onMove(tree.root),
      onDelete: () => widget.onDelete(tree.root),
    );
    return Column(
      key: ValueKey<String>('todo-row-${tree.root.id}'),
      children: <Widget>[
        rootRow,
        for (
          int index = 0;
          _expanded && index < pendingChildren.length;
          index += 1
        )
          CustomPaint(
            key: ValueKey<String>(
              'todo-tree-branch-${pendingChildren[index].id}',
            ),
            painter: _TodoTreeBranchPainter(
              lineColor: treeLineColor,
              trunkX: treeTrunkX,
              branchEndX: branchEndX,
              isLast: index == pendingChildren.length - 1,
            ),
            child: Padding(
              key: ValueKey<String>('todo-child-${pendingChildren[index].id}'),
              padding: EdgeInsets.only(left: childIndent),
              child: _TodoTaskRow(
                todo: pendingChildren[index],
                now: widget.now,
                completing: widget.completingTodoIds.contains(
                  pendingChildren[index].id,
                ),
                onCompletedChanged: (bool value) =>
                    widget.onCompletedChanged(pendingChildren[index], value),
                onEdit: () => widget.onEdit(pendingChildren[index]),
                onMove: null,
                onDelete: () => widget.onDelete(pendingChildren[index]),
              ),
            ),
          ),
      ],
    );
  }
}

/// 绘制父子任务之间的竖向主干与圆角支线。
class _TodoTreeBranchPainter extends CustomPainter {
  /// 树线颜色。
  final Color lineColor;

  /// 父任务复选框中心对应的主干横坐标。
  final double trunkX;

  /// 子任务支线结束横坐标。
  final double branchEndX;

  /// 当前子任务是否为最后一项。
  final bool isLast;

  /// 创建任务树引导线绘制器。
  const _TodoTreeBranchPainter({
    required this.lineColor,
    required this.trunkX,
    required this.branchEndX,
    required this.isLast,
  });

  /// 绘制连续主干；最后一个子任务以圆角弯折结束。
  @override
  void paint(Canvas canvas, Size size) {
    // 当前子任务行的垂直中心。
    final double branchY = size.height / 2;
    // 树线画笔。
    final Paint linePaint = Paint()
      ..color = lineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.25
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (!isLast) {
      canvas
        ..drawLine(Offset(trunkX, 0), Offset(trunkX, size.height), linePaint)
        ..drawLine(
          Offset(trunkX, branchY),
          Offset(branchEndX, branchY),
          linePaint,
        );
      return;
    }
    // 最后一条支线使用的圆角半径。
    final double cornerRadius = branchY < OmniSpacing.xs
        ? branchY
        : OmniSpacing.xs;
    // 从主干自然弯向最后一个子任务的路径。
    final Path branchPath = Path()
      ..moveTo(trunkX, 0)
      ..lineTo(trunkX, branchY - cornerRadius)
      ..quadraticBezierTo(trunkX, branchY, trunkX + cornerRadius, branchY)
      ..lineTo(branchEndX, branchY);
    canvas.drawPath(branchPath, linePaint);
  }

  /// 仅在树线几何或颜色变化时重新绘制。
  @override
  bool shouldRepaint(covariant _TodoTreeBranchPainter oldDelegate) {
    return lineColor != oldDelegate.lineColor ||
        trunkX != oldDelegate.trunkX ||
        branchEndX != oldDelegate.branchEndX ||
        isLast != oldDelegate.isLast;
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

  /// 可选展开与拖拽控制。
  final Widget? treeControl;

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
    this.treeControl,
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
    // 当前是否存在需要换行展示的辅助信息。
    final bool hasDetails = _TodoDetails.hasContent(todo);
    // 当前是否关闭非必要动画。
    final bool disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return TweenAnimationBuilder<double>(
      key: ValueKey<String>('todo-completion-transition-${todo.id}'),
      tween: Tween<double>(end: completing ? 1 : 0),
      duration: disableAnimations
          ? Duration.zero
          : TodoCompletionCheckbox.animationDuration + OmniMotion.panel,
      builder: (BuildContext context, double progress, Widget? child) {
        // 勾选动画完成后才开始向右滑出任务行。
        final double slideStart =
            TodoCompletionCheckbox.animationDuration.inMilliseconds /
            (TodoCompletionCheckbox.animationDuration + OmniMotion.panel)
                .inMilliseconds;
        // 滑出阶段使用加速曲线，让任务明确离开当前列表。
        final double slideProgress = progress <= slideStart
            ? 0
            : ((progress - slideStart) / (1 - slideStart)).clamp(0, 1);
        return FractionalTranslation(
          key: ValueKey<String>('todo-completion-slide-${todo.id}'),
          translation: Offset(
            completing ? Curves.easeInCubic.transform(slideProgress) : 0,
            0,
          ),
          child: child,
        );
      },
      child: AbsorbPointer(
        absorbing: completing,
        child: OmniListRow(
          onTap: onEdit,
          borderRadius: BorderRadius.circular(OmniRadius.control),
          padding: const EdgeInsets.symmetric(
            horizontal: OmniSpacing.sm,
            vertical: OmniSpacing.xs,
          ),
          leadingGap: 0,
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (treeControl != null) ...<Widget>[
                treeControl!,
                const SizedBox(width: OmniSpacing.xxs),
              ],
              TodoCompletionCheckbox(
                key: ValueKey<String>('todo-completion-checkbox-${todo.id}'),
                value: todo.isCompleted || completing,
                onChanged: completing ? null : onCompletedChanged,
              ),
            ],
          ),
          title: Row(
            children: <Widget>[
              Expanded(
                child: _TodoInlineTitle(
                  todo: todo,
                  completed: todo.isCompleted,
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
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (onAddChild != null)
                IconButton(
                  key: ValueKey<String>('todo-add-child-${todo.id}'),
                  tooltip: '添加子任务',
                  onPressed: onAddChild,
                  style: IconButton.styleFrom(foregroundColor: colors.todo),
                  icon: const Icon(Icons.playlist_add_rounded, size: 20),
                ),
              OmniPopupMenuButton<String>(
                tooltip: '更多操作',
                onSelected: (String value) {
                  if (value == 'edit') {
                    onEdit();
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
            ],
          ),
        ),
      ),
    );
  }
}

/// 同行展示任务名称与较弱描述文字。
class _TodoInlineTitle extends StatelessWidget {
  /// 当前任务。
  final TodoRecord todo;

  /// 是否使用完成态删除线。
  final bool completed;

  /// 创建任务名称与描述组合。
  const _TodoInlineTitle({required this.todo, required this.completed});

  /// 构建名称优先、描述随后且可省略的单行布局。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 清理后的可选描述。
    final String? description = todo.description?.trim().isNotEmpty ?? false
        ? todo.description!.trim()
        : null;
    // 任务名称样式。
    final TextStyle? titleStyle = Theme.of(context).textTheme.bodyMedium
        ?.copyWith(
          color: completed ? colors.muted : colors.ink,
          decoration: completed ? TextDecoration.lineThrough : null,
        );
    if (description == null) {
      return Text(
        todo.title,
        key: ValueKey<String>('todo-title-${todo.id}'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: titleStyle,
      );
    }
    // 更弱且更小的任务描述样式。
    final TextStyle? descriptionStyle = Theme.of(context).textTheme.bodySmall
        ?.copyWith(
          color: colors.muted,
          decoration: completed ? TextDecoration.lineThrough : null,
        );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        Flexible(
          flex: 3,
          fit: FlexFit.loose,
          child: Text(
            todo.title,
            key: ValueKey<String>('todo-title-${todo.id}'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: titleStyle,
          ),
        ),
        const SizedBox(width: OmniSpacing.xs),
        Flexible(
          flex: 2,
          fit: FlexFit.loose,
          child: Text(
            description,
            key: ValueKey<String>('todo-description-${todo.id}'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: descriptionStyle,
          ),
        ),
      ],
    );
  }
}

/// 已完成任务历史树列表。
class _CompletedTodoHistory extends StatefulWidget {
  /// 是否嵌入移动端页面的外层滚动容器。
  final bool mobile;

  /// 当前日期完成记录。
  final List<TodoHistoryEntry> entries;

  /// 重新打开任务回调。
  final ValueChanged<TodoRecord> onReopen;

  /// 编辑任务回调。
  final ValueChanged<TodoRecord> onEdit;

  /// 创建完成历史列表。
  const _CompletedTodoHistory({
    required this.mobile,
    required this.entries,
    required this.onReopen,
    required this.onEdit,
    super.key,
  });

  /// 创建完成历史树状态。
  @override
  State<_CompletedTodoHistory> createState() => _CompletedTodoHistoryState();
}

/// 管理完成历史分组的展开与收起状态。
class _CompletedTodoHistoryState extends State<_CompletedTodoHistory> {
  /// 用户主动收起的父任务分组标识；默认空集合即全部展开。
  final Set<String> _collapsedGroupIds = <String>{};

  /// 构建按父任务聚类且默认展开的完成历史。
  @override
  Widget build(BuildContext context) {
    if (widget.entries.isEmpty) {
      return const Center(child: Text('这一天还没有完成任务'));
    }
    // 按父任务整理后的历史分组。
    final List<_TodoHistoryGroup> groups = _groupEntries(widget.entries);
    return ListView.separated(
      padding: EdgeInsets.zero,
      shrinkWrap: widget.mobile,
      physics: widget.mobile ? const NeverScrollableScrollPhysics() : null,
      itemCount: groups.length,
      separatorBuilder: (BuildContext context, int index) =>
          const SizedBox(height: OmniSpacing.xs),
      itemBuilder: (BuildContext context, int index) {
        // 当前父任务历史分组。
        final _TodoHistoryGroup group = groups[index];
        // 当前分组是否展开。
        final bool expanded = !_collapsedGroupIds.contains(group.id);
        // 历史行复选框的完整点击区域尺寸。
        final Size checkboxTapSize = TodoCompletionCheckbox.tapSizeOf(context);
        // 历史父任务复选框中心对应的树线主干。
        final double treeTrunkX = OmniSpacing.sm + checkboxTapSize.width / 2;
        // 历史子任务相对父任务的水平缩进。
        final double childIndent = treeTrunkX + OmniSpacing.xxs;
        // 历史支线末端停在子任务视觉勾选框之前。
        final double branchEndX =
            childIndent +
            OmniSpacing.sm +
            (checkboxTapSize.width - TodoCompletionCheckbox.visualSize) / 2 -
            OmniSpacing.xxs;
        // 与历史勾选框边框一致的树线颜色。
        final Color treeLineColor = TodoCompletionCheckbox.idleBorderColorOf(
          context,
        );
        // 当前分组展开状态切换回调。
        final VoidCallback? onToggle = group.children.isEmpty
            ? null
            : () {
                setState(() {
                  if (expanded) {
                    _collapsedGroupIds.add(group.id);
                  } else {
                    _collapsedGroupIds.remove(group.id);
                  }
                });
              };
        return OmniPanel(
          key: ValueKey<String>('todo-history-group-${group.id}'),
          padding: EdgeInsets.zero,
          child: Column(
            children: <Widget>[
              if (group.rootEntry != null)
                _CompletedTodoHistoryRow(
                  key: ValueKey<String>(
                    'todo-history-row-${group.rootEntry!.todo.id}',
                  ),
                  entry: group.rootEntry!,
                  expanded: expanded,
                  onToggle: onToggle,
                  onReopen: widget.onReopen,
                  onEdit: widget.onEdit,
                )
              else
                _TodoHistoryParentContextRow(
                  parent: group.parent,
                  childCount: group.children.length,
                  expanded: expanded,
                  onToggle: onToggle!,
                  onEdit: widget.onEdit,
                ),
              if (expanded && group.children.isNotEmpty)
                Column(
                  key: ValueKey<String>('todo-history-children-${group.id}'),
                  children: <Widget>[
                    const Divider(indent: 36),
                    for (
                      int childIndex = 0;
                      childIndex < group.children.length;
                      childIndex += 1
                    )
                      CustomPaint(
                        key: ValueKey<String>(
                          'todo-history-branch-${group.children[childIndex].todo.id}',
                        ),
                        painter: _TodoTreeBranchPainter(
                          lineColor: treeLineColor,
                          trunkX: treeTrunkX,
                          branchEndX: branchEndX,
                          isLast: childIndex == group.children.length - 1,
                        ),
                        child: Padding(
                          key: ValueKey<String>(
                            'todo-history-child-${group.children[childIndex].todo.id}',
                          ),
                          padding: EdgeInsets.only(left: childIndent),
                          child: _CompletedTodoHistoryRow(
                            key: ValueKey<String>(
                              'todo-history-row-${group.children[childIndex].todo.id}',
                            ),
                            entry: group.children[childIndex],
                            expanded: true,
                            onToggle: null,
                            onReopen: widget.onReopen,
                            onEdit: widget.onEdit,
                          ),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }

  /// 将扁平完成记录按根任务标识组装为两层历史树。
  List<_TodoHistoryGroup> _groupEntries(List<TodoHistoryEntry> entries) {
    // 当天完成的主任务记录索引。
    final Map<String, TodoHistoryEntry> rootsById =
        <String, TodoHistoryEntry>{};
    // 按主任务标识聚合的已完成子任务。
    final Map<String, List<TodoHistoryEntry>> childrenByRootId =
        <String, List<TodoHistoryEntry>>{};
    // 子任务携带的父任务上下文索引。
    final Map<String, TodoRecord> parentsById = <String, TodoRecord>{};
    for (final TodoHistoryEntry entry in entries) {
      // 当前记录的父任务标识。
      final String? parentId = entry.todo.parentId;
      if (parentId == null) {
        rootsById[entry.todo.id] = entry;
      } else {
        childrenByRootId
            .putIfAbsent(parentId, () => <TodoHistoryEntry>[])
            .add(entry);
        if (entry.parent != null) {
          parentsById[parentId] = entry.parent!;
        }
      }
    }
    // 当天历史涉及的全部根任务标识。
    final Set<String> rootIds = <String>{
      ...rootsById.keys,
      ...childrenByRootId.keys,
    };
    // 组装完成的两层历史分组。
    final List<_TodoHistoryGroup> groups = rootIds
        .map((String rootId) {
          // 当前分组的子任务，沿用任务树的用户顺序。
          final List<TodoHistoryEntry> children =
              childrenByRootId[rootId] ?? <TodoHistoryEntry>[];
          children.sort((TodoHistoryEntry left, TodoHistoryEntry right) {
            // 子任务用户排序比较结果。
            final int order = left.todo.sortOrder.compareTo(
              right.todo.sortOrder,
            );
            return order != 0
                ? order
                : left.todo.createdAt.compareTo(right.todo.createdAt);
          });
          return _TodoHistoryGroup(
            id: rootId,
            rootEntry: rootsById[rootId],
            parent: parentsById[rootId],
            children: List<TodoHistoryEntry>.unmodifiable(children),
          );
        })
        .toList(growable: false);
    groups.sort(
      (_TodoHistoryGroup left, _TodoHistoryGroup right) =>
          right.latestCompletedAt.compareTo(left.latestCompletedAt),
    );
    return groups;
  }
}

/// 一个父任务及其当天完成子任务组成的历史分组。
class _TodoHistoryGroup {
  /// 根任务标识。
  final String id;

  /// 当天完成的父任务记录。
  final TodoHistoryEntry? rootEntry;

  /// 父任务上下文；父任务未在当天完成时用于分组标题。
  final TodoRecord? parent;

  /// 当天完成的直属子任务。
  final List<TodoHistoryEntry> children;

  /// 创建完成历史分组。
  const _TodoHistoryGroup({
    required this.id,
    required this.rootEntry,
    required this.parent,
    required this.children,
  });

  /// 当前分组中最近的完成时间。
  DateTime get latestCompletedAt {
    // 当前分组全部完成时间。
    final List<DateTime> completedTimes = <DateTime>[
      if (rootEntry?.todo.completedAt != null) rootEntry!.todo.completedAt!,
      for (final TodoHistoryEntry child in children) child.todo.completedAt!,
    ];
    completedTimes.sort();
    return completedTimes.last;
  }
}

/// 完成历史中的单条已完成任务行。
class _CompletedTodoHistoryRow extends StatelessWidget {
  /// 当前历史条目。
  final TodoHistoryEntry entry;

  /// 当前父任务分组是否展开。
  final bool expanded;

  /// 可选展开状态切换回调。
  final VoidCallback? onToggle;

  /// 重新打开任务回调。
  final ValueChanged<TodoRecord> onReopen;

  /// 编辑任务回调。
  final ValueChanged<TodoRecord> onEdit;

  /// 创建已完成任务行。
  const _CompletedTodoHistoryRow({
    required this.entry,
    required this.expanded,
    required this.onToggle,
    required this.onReopen,
    required this.onEdit,
    super.key,
  });

  /// 构建与进行中任务一致的紧凑历史行。
  @override
  Widget build(BuildContext context) {
    // 当前任务原有优先象限。
    final TodoPriorityQuadrant quadrant = TodoPriorityQuadrant.fromValue(
      entry.todo.priorityQuadrant,
    );
    // 当前象限强调色。
    final Color accent = quadrant.color(OmniColors.of(context));
    // 当前是否存在截止或非时间状态信息。
    final bool hasDetails = _TodoDetails.hasContent(entry.todo);
    return OmniListRow(
      padding: const EdgeInsets.symmetric(
        horizontal: OmniSpacing.sm,
        vertical: OmniSpacing.xs,
      ),
      leadingGap: 0,
      leading: TodoCompletionCheckbox(
        key: ValueKey<String>(
          'todo-history-completion-checkbox-${entry.todo.id}',
        ),
        value: true,
        semanticLabel: '重新打开任务',
        onChanged: (bool value) {
          if (!value) {
            onReopen(entry.todo);
          }
        },
      ),
      title: Row(
        children: <Widget>[
          Expanded(child: _TodoInlineTitle(todo: entry.todo, completed: true)),
          const SizedBox(width: OmniSpacing.xs),
          OmniTag(label: quadrant.actionLabel, color: accent),
        ],
      ),
      subtitle: hasDetails
          ? _TodoDetails(todo: entry.todo, now: entry.todo.completedAt!)
          : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (onToggle != null)
            IconButton(
              key: ValueKey<String>('todo-history-toggle-${entry.todo.id}'),
              tooltip: expanded ? '收起子任务' : '展开子任务',
              onPressed: onToggle,
              icon: Icon(
                expanded
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded,
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
  }
}

/// 父任务未在当天完成时使用的历史分组标题行。
class _TodoHistoryParentContextRow extends StatelessWidget {
  /// 父任务上下文。
  final TodoRecord? parent;

  /// 当天完成的子任务数量。
  final int childCount;

  /// 当前分组是否展开。
  final bool expanded;

  /// 展开状态切换回调。
  final VoidCallback onToggle;

  /// 编辑任务回调。
  final ValueChanged<TodoRecord> onEdit;

  /// 创建父任务上下文行。
  const _TodoHistoryParentContextRow({
    required this.parent,
    required this.childCount,
    required this.expanded,
    required this.onToggle,
    required this.onEdit,
  });

  /// 构建不会伪装成已完成任务的中性父级标题。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 父任务原有优先象限。
    final TodoPriorityQuadrant? quadrant = parent == null
        ? null
        : TodoPriorityQuadrant.fromValue(parent!.priorityQuadrant);
    // 当前象限强调色。
    final Color accent = quadrant?.color(colors) ?? colors.muted;
    // 父任务当前状态说明。
    final String statusLabel = parent == null
        ? '父任务信息不可用'
        : parent!.isCompleted
        ? '父任务已在其他日期完成'
        : '父任务进行中';
    // 与完成复选框保持一致的前置区域尺寸。
    final Size leadingSize = TodoCompletionCheckbox.tapSizeOf(context);
    return OmniListRow(
      key: ValueKey<String>('todo-history-parent-${parent?.id ?? 'missing'}'),
      padding: const EdgeInsets.symmetric(
        horizontal: OmniSpacing.sm,
        vertical: OmniSpacing.xs,
      ),
      leadingGap: 0,
      leading: SizedBox(
        width: leadingSize.width,
        height: leadingSize.height,
        child: Center(
          child: Icon(Icons.account_tree_outlined, size: 16, color: accent),
        ),
      ),
      title: Row(
        children: <Widget>[
          Expanded(child: Text(parent?.title ?? '未知父任务')),
          if (quadrant != null) ...<Widget>[
            const SizedBox(width: OmniSpacing.xs),
            OmniTag(label: quadrant.actionLabel, color: accent),
          ],
        ],
      ),
      subtitle: Text('$statusLabel  ·  当天完成 $childCount 个子任务'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            key: ValueKey<String>(
              'todo-history-toggle-${parent?.id ?? 'missing'}',
            ),
            tooltip: expanded ? '收起子任务' : '展开子任务',
            onPressed: onToggle,
            icon: Icon(
              expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
            ),
          ),
          if (parent != null)
            IconButton(
              tooltip: '编辑',
              onPressed: () => onEdit(parent!),
              icon: const Icon(Icons.edit_outlined),
            ),
        ],
      ),
    );
  }
}

/// 移动端一级视图、象限筛选与历史日期的一体化导航。
class _MobileTodoNavigation extends StatelessWidget {
  /// 当前一级视图。
  final _TodoPageView view;

  /// 当前历史日期。
  final DateTime selectedDay;

  /// 当前自然日。
  final DateTime today;

  /// 未完成节点数量。
  final int activeCount;

  /// 当前聚焦象限。
  final TodoPriorityQuadrant? selectedQuadrant;

  /// 各象限主任务数量。
  final Map<TodoPriorityQuadrant, int> quadrantCounts;

  /// 一级视图切换回调。
  final ValueChanged<_TodoPageView> onViewChanged;

  /// 历史日期切换回调。
  final ValueChanged<DateTime> onDaySelected;

  /// 象限切换回调。
  final ValueChanged<TodoPriorityQuadrant?> onQuadrantSelected;

  /// 创建移动端一体化导航。
  const _MobileTodoNavigation({
    required this.view,
    required this.selectedDay,
    required this.today,
    required this.activeCount,
    required this.selectedQuadrant,
    required this.quadrantCounts,
    required this.onViewChanged,
    required this.onDaySelected,
    required this.onQuadrantSelected,
  });

  /// 返回一级视图标签。
  String _viewLabel(_TodoPageView option) {
    return switch (option) {
      _TodoPageView.active => '进行中 $activeCount',
      _TodoPageView.history => '完成历史',
    };
  }

  /// 返回象限的可见短标签。
  String _quadrantLabel(TodoPriorityQuadrant? quadrant) {
    return quadrant?.actionLabel ?? '全部';
  }

  /// 返回包含非零数量的象限无障碍标签。
  String _quadrantSemanticLabel(TodoPriorityQuadrant? quadrant) {
    if (quadrant == null) {
      return '四象限';
    }
    // 当前象限主任务数量。
    final int count = quadrantCounts[quadrant] ?? 0;
    return count > 0
        ? '${quadrant.actionLabel}，$count 个任务'
        : quadrant.actionLabel;
  }

  /// 构建带非零数量角标的象限标签。
  Widget _buildQuadrantItem(
    BuildContext context,
    TodoPriorityQuadrant? quadrant,
    bool selected,
  ) {
    // 当前主题色。
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // 当前象限主任务数量。
    final int count = quadrant == null ? 0 : quadrantCounts[quadrant] ?? 0;
    // 最多展示两位任务数量。
    final String countLabel = count > 99 ? '99+' : '$count';
    // 当前标签文字颜色。
    final Color labelColor = selected
        ? scheme.onPrimaryContainer
        : scheme.onSurfaceVariant;
    return SizedBox.expand(
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                _quadrantLabel(quadrant),
                maxLines: 1,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: labelColor,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ),
          if (count > 0)
            Positioned(
              top: 1,
              right: 1,
              child: Container(
                key: ValueKey<String>('todo-mobile-count-${quadrant!.value}'),
                height: 13,
                constraints: const BoxConstraints(minWidth: 13),
                padding: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                  color: selected
                      ? scheme.primary
                      : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(OmniRadius.pill),
                ),
                alignment: Alignment.center,
                child: Text(
                  countLabel,
                  style: TextStyle(
                    color: selected
                        ? scheme.onPrimary
                        : scheme.onSurfaceVariant,
                    fontSize: 8,
                    height: 1,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 构建进行中视图的五等分象限导航。
  Widget _buildQuadrantSelector(double width) {
    // 完整四象限与各单象限选项的固定顺序。
    final List<TodoPriorityQuadrant?> options = <TodoPriorityQuadrant?>[
      null,
      ...todoPriorityQuadrantActionOrder,
    ];
    return OmniSlidingSegmentedControl<TodoPriorityQuadrant?>(
      key: const ValueKey<String>('todo-mobile-quadrant-filters'),
      options: options,
      selected: selectedQuadrant,
      width: width,
      height: OmniSize.touch,
      embedded: true,
      labelBuilder: _quadrantSemanticLabel,
      itemBuilder: _buildQuadrantItem,
      itemKeyBuilder: (TodoPriorityQuadrant? quadrant) => ValueKey<String>(
        quadrant == null
            ? 'todo-mobile-filter-all'
            : 'todo-mobile-filter-${quadrant.value}',
      ),
      onChanged: onQuadrantSelected,
    );
  }

  /// 构建完成历史视图的日期导航。
  Widget _buildDateSelector() {
    // 日期按钮的嵌入式样式。
    final ButtonStyle dateButtonStyle = OutlinedButton.styleFrom(
      side: BorderSide.none,
      minimumSize: const Size(0, 36),
      padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.xs),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    return SizedBox(
      key: const ValueKey<String>('todo-mobile-history-date-row'),
      height: OmniSize.touch,
      width: double.infinity,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          IconButton(
            key: const ValueKey<String>('todo-mobile-history-previous-day'),
            tooltip: '前一天',
            constraints: const BoxConstraints.tightFor(
              width: OmniSize.touch,
              height: OmniSize.touch,
            ),
            padding: EdgeInsets.zero,
            onPressed: () =>
                onDaySelected(selectedDay.subtract(const Duration(days: 1))),
            icon: const Icon(Icons.chevron_left_rounded),
          ),
          Expanded(
            child: OmniDatePickerButton(
              key: const ValueKey<String>('todo-mobile-history-date-picker'),
              value: selectedDay,
              initialDate: selectedDay,
              currentDate: today,
              firstDate: DateTime(2000),
              lastDate: DateTime(2100),
              label: DateFormat('yyyy 年 M 月 d 日').format(selectedDay),
              icon: null,
              style: dateButtonStyle,
              onChanged: onDaySelected,
            ),
          ),
          IconButton(
            key: const ValueKey<String>('todo-mobile-history-next-day'),
            tooltip: '后一天',
            constraints: const BoxConstraints.tightFor(
              width: OmniSize.touch,
              height: OmniSize.touch,
            ),
            padding: EdgeInsets.zero,
            onPressed: () =>
                onDaySelected(selectedDay.add(const Duration(days: 1))),
            icon: const Icon(Icons.chevron_right_rounded),
          ),
        ],
      ),
    );
  }

  /// 构建共用外框、滑块动效与上下文第二层的导航面板。
  @override
  Widget build(BuildContext context) {
    // 当前主题色。
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // 当前系统是否要求减少动态效果。
    final bool disableAnimation =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.of(context).accessibleNavigation;
    // 第二层联动切换时长。
    final Duration transitionDuration = disableAnimation
        ? Duration.zero
        : OmniMotion.normal;
    // 一级视图选项固定顺序。
    const List<_TodoPageView> viewOptions = <_TodoPageView>[
      _TodoPageView.active,
      _TodoPageView.history,
    ];
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 导航面板占用的完整可用宽度。
        final double width = constraints.maxWidth;
        // 随一级视图变化的第二层导航。
        final Widget contextNavigation = view == _TodoPageView.active
            ? _buildQuadrantSelector(width)
            : _buildDateSelector();
        return Container(
          key: const ValueKey<String>('todo-mobile-view-navigation'),
          width: width,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(OmniRadius.dialog),
            border: Border.all(color: scheme.outline),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              OmniSlidingSegmentedControl<_TodoPageView>(
                key: const ValueKey<String>('todo-mobile-view-filters'),
                options: viewOptions,
                selected: view,
                width: width,
                height: OmniSize.touch,
                embedded: true,
                labelBuilder: _viewLabel,
                itemKeyBuilder: (_TodoPageView option) =>
                    ValueKey<String>('todo-mobile-view-${option.name}'),
                onChanged: onViewChanged,
              ),
              Divider(height: 1, thickness: 1, color: scheme.outlineVariant),
              SizedBox(
                height: OmniSize.touch,
                width: width,
                child: AnimatedSwitcher(
                  duration: transitionDuration,
                  reverseDuration: transitionDuration,
                  switchInCurve: OmniMotion.standardCurve,
                  switchOutCurve: OmniMotion.standardCurve,
                  layoutBuilder:
                      (Widget? currentChild, List<Widget> previousChildren) =>
                          Stack(
                            alignment: Alignment.center,
                            children: <Widget>[
                              ...previousChildren,
                              ?currentChild,
                            ],
                          ),
                  transitionBuilder: (
                    Widget child,
                    Animation<double> animation,
                  ) => FadeTransition(opacity: animation, child: child),
                  child: contextNavigation,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 任务截止时间与非时间状态元数据。
class _TodoDetails extends StatelessWidget {
  /// 当前待办。
  final TodoRecord todo;

  /// 当前时间。
  final DateTime now;

  /// 创建任务辅助信息。
  const _TodoDetails({required this.todo, required this.now});

  /// 判断任务行是否需要展示截止、重复或同步信息。
  static bool hasContent(TodoRecord todo) {
    return todo.dueAt != null ||
        (todo.repeatRule != null && todo.repeatRule != 'stopped') ||
        todo.syncState != 'localSaved';
  }

  /// 构建紧凑元数据。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 是否已经逾期。
    final bool overdue =
        !todo.isCompleted && todo.dueAt != null && todo.dueAt!.isBefore(now);
    return Wrap(
      spacing: OmniSpacing.sm,
      runSpacing: OmniSpacing.xxs,
      children: <Widget>[
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
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: color),
          ),
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
