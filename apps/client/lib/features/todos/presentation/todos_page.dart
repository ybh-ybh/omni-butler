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

/// 待办状态筛选。
enum _TodoStatusFilter {
  /// 未完成待办。
  pending,

  /// 全部待办。
  all,

  /// 已完成待办。
  completed,
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
  /// 当前选中的自然日。
  late DateTime _selectedDay;

  /// 当前状态筛选。
  _TodoStatusFilter _statusFilter = _TodoStatusFilter.pending;

  /// 当前聚焦的优先象限。
  TodoPriorityQuadrant? _priorityQuadrantFilter;

  /// 正在播放完成反馈的待办标识。
  final Set<String> _completingTodoIds = <String>{};

  /// 当前可撤销完成操作的待办。
  TodoRecord? _undoTodo;

  /// 撤销入口自动关闭计时器。
  Timer? _undoTimer;

  /// 初始化日期与首页带入的象限聚焦。
  @override
  void initState() {
    super.initState();
    _selectedDay = DateUtils.dateOnly(ref.read(nowProvider));
    _priorityQuadrantFilter = widget.initialPriorityQuadrant;
  }

  /// 响应路由参数中的象限筛选变化。
  @override
  void didUpdateWidget(covariant TodosPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialPriorityQuadrant != widget.initialPriorityQuadrant) {
      _priorityQuadrantFilter = widget.initialPriorityQuadrant;
    }
  }

  /// 释放撤销入口计时器。
  @override
  void dispose() {
    _undoTimer?.cancel();
    super.dispose();
  }

  /// 构建响应式四象限待办页面。
  @override
  Widget build(BuildContext context) {
    // 当日待办异步状态。
    final AsyncValue<List<TodoRecord>> todosAsync = ref.watch(
      todosForDayProvider(_selectedDay),
    );
    // 当前是否运行在桌面端。
    final bool isDesktopPlatform = OmniBreakpoint.isDesktopPlatform(
      Theme.of(context).platform,
    );
    // 当前是否使用移动端纵向内容流。
    final bool useMobileFlow =
        !isDesktopPlatform &&
        OmniBreakpoint.isCompact(MediaQuery.sizeOf(context).width);

    if (useMobileFlow) {
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
              child: _buildPageContent(context, todosAsync, mobile: true),
            ),
          ),
          Positioned(
            right: OmniSpacing.md,
            bottom: OmniSpacing.md,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(OmniRadius.panel),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.12),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: OmniButton(
                key: const ValueKey<String>('todo-mobile-create'),
                label: '新增待办',
                icon: Icons.add_rounded,
                variant: OmniButtonVariant.pagePrimary,
                onPressed: () =>
                    TodoEditorDialog.show(context, initialDate: _selectedDay),
              ),
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
      child: _buildPageContent(context, todosAsync, mobile: false),
    );
  }

  /// 构建页面标题、控制区与四象限内容。
  Widget _buildPageContent(
    BuildContext context,
    AsyncValue<List<TodoRecord>> todosAsync, {
    required bool mobile,
  }) {
    // 当前已经读取到的待办。
    final List<TodoRecord> todos = todosAsync.asData?.value ?? <TodoRecord>[];
    // 当前固定的现在时间。
    final DateTime now = ref.watch(nowProvider);
    // 当前是否关闭非必要动画。
    final bool disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    // 当前异步状态对应的页面主体。
    final Widget body = todosAsync.when(
      data: (List<TodoRecord> records) =>
          _buildQuadrantContent(context, records, mobile: mobile, now: now),
      loading: () => const Center(
        child: Padding(
          padding: EdgeInsets.all(48),
          child: CircularProgressIndicator(),
        ),
      ),
      error: (Object error, StackTrace stackTrace) =>
          _ErrorCard(message: '待办读取失败：$error'),
    );
    // 页面标题、工具栏和反馈区域。
    final List<Widget> leadingContent = <Widget>[
      _buildHeader(context, todos, now, mobile: mobile),
      const SizedBox(height: OmniSpacing.sm),
      _TodoControlBar(
        selectedDay: _selectedDay,
        today: DateUtils.dateOnly(now),
        statusFilter: _statusFilter,
        pendingCount: todos
            .where((TodoRecord todo) => !todo.isCompleted)
            .length,
        completedCount: todos
            .where((TodoRecord todo) => todo.isCompleted)
            .length,
        onDaySelected: _selectDay,
        onStatusSelected: (_TodoStatusFilter value) {
          setState(() => _statusFilter = value);
        },
      ),
      AnimatedSize(
        duration: disableAnimations ? Duration.zero : OmniMotion.normal,
        curve: OmniMotion.standardCurve,
        child: _undoTodo == null
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.only(top: OmniSpacing.xs),
                child: _TodoUndoBanner(
                  todo: _undoTodo!,
                  onUndo: () => unawaited(_undoCompletion()),
                  onDismiss: _dismissUndo,
                ),
              ),
      ),
      const SizedBox(height: OmniSpacing.sm),
    ];

    if (mobile) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[...leadingContent, body],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ...leadingContent,
        Expanded(
          child: AnimatedSwitcher(
            duration: disableAnimations ? Duration.zero : OmniMotion.panel,
            switchInCurve: OmniMotion.standardCurve,
            switchOutCurve: OmniMotion.standardCurve,
            child: KeyedSubtree(
              key: ValueKey<String>(
                'todo-layout-${_priorityQuadrantFilter?.value ?? 'matrix'}',
              ),
              child: body,
            ),
          ),
        ),
      ],
    );
  }

  /// 构建带日期、任务概况与主操作的页面标题。
  Widget _buildHeader(
    BuildContext context,
    List<TodoRecord> todos,
    DateTime now, {
    required bool mobile,
  }) {
    // 当前未完成待办。
    final List<TodoRecord> pendingTodos = todos
        .where((TodoRecord todo) => !todo.isCompleted)
        .toList(growable: false);
    // 当前已经逾期的待办数量。
    final int overdueCount = pendingTodos.where((TodoRecord todo) {
      return todo.dueAt != null && todo.dueAt!.isBefore(now);
    }).length;
    // 当前日期与任务概况说明。
    final String description = _headerDescription(
      pendingCount: pendingTodos.length,
      overdueCount: overdueCount,
      today: DateUtils.dateOnly(now),
    );

    return OmniPageHeader(
      title: '每日待办',
      description: description,
      actions: mobile
          ? const <Widget>[]
          : <Widget>[
              OmniButton(
                key: const ValueKey<String>('todo-primary-create'),
                label: '新增待办',
                icon: Icons.add_rounded,
                variant: OmniButtonVariant.pagePrimary,
                onPressed: () =>
                    TodoEditorDialog.show(context, initialDate: _selectedDay),
              ),
            ],
    );
  }

  /// 返回标题区使用的日期与任务概况文案。
  String _headerDescription({
    required int pendingCount,
    required int overdueCount,
    required DateTime today,
  }) {
    // 中文星期短标签。
    const List<String> weekdays = <String>['一', '二', '三', '四', '五', '六', '日'];
    // 当前日期是否为今天。
    final bool isToday = DateUtils.isSameDay(_selectedDay, today);
    // 当前日期文本。
    final String dateLabel =
        '${_selectedDay.month} 月 ${_selectedDay.day} 日 · 周${weekdays[_selectedDay.weekday - 1]}';
    // 当前日期前缀。
    final String datePrefix = isToday ? '今天 · ' : '';
    // 当前逾期概况。
    final String overdueSummary = overdueCount > 0
        ? ' · $overdueCount 项逾期'
        : '';
    return '$datePrefix$dateLabel · $pendingCount 项待处理$overdueSummary';
  }

  /// 选择新的自然日并清理上一日的临时反馈。
  void _selectDay(DateTime day) {
    _undoTimer?.cancel();
    setState(() {
      _selectedDay = DateUtils.dateOnly(day);
      _undoTodo = null;
    });
  }

  /// 构建筛选并分组后的四象限内容。
  Widget _buildQuadrantContent(
    BuildContext context,
    List<TodoRecord> todos, {
    required bool mobile,
    required DateTime now,
  }) {
    // 按完成状态筛选后的待办。
    final List<TodoRecord> statusFilteredTodos = todos
        .where((TodoRecord todo) {
          return switch (_statusFilter) {
            _TodoStatusFilter.pending => !todo.isCompleted,
            _TodoStatusFilter.all => true,
            _TodoStatusFilter.completed => todo.isCompleted,
          };
        })
        .toList(growable: false);
    // 按象限分组后的待办。
    final Map<TodoPriorityQuadrant, List<TodoRecord>> groupedTodos =
        <TodoPriorityQuadrant, List<TodoRecord>>{
          for (final TodoPriorityQuadrant quadrant
              in todoPriorityQuadrantMatrixOrder)
            quadrant: <TodoRecord>[],
        };
    for (final TodoRecord todo in statusFilteredTodos) {
      // 当前待办所属象限。
      final TodoPriorityQuadrant quadrant = TodoPriorityQuadrant.fromValue(
        todo.priorityQuadrant,
      );
      groupedTodos[quadrant]!.add(todo);
    }
    for (final List<TodoRecord> quadrantTodos in groupedTodos.values) {
      quadrantTodos.sort(_compareTodoPriority);
    }
    if (mobile) {
      return _buildMobileQuadrants(context, groupedTodos, now: now);
    }
    if (_priorityQuadrantFilter != null) {
      return _buildFocusedQuadrant(
        context,
        _priorityQuadrantFilter!,
        groupedTodos[_priorityQuadrantFilter!]!,
        now: now,
      );
    }
    return _buildDesktopQuadrants(context, groupedTodos, now: now);
  }

  /// 构建桌面端紧凑的四象限卡片网格。
  Widget _buildDesktopQuadrants(
    BuildContext context,
    Map<TodoPriorityQuadrant, List<TodoRecord>> groupedTodos, {
    required DateTime now,
  }) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 两列卡片之间保留与其他管理页一致的紧凑间距。
        final double cardWidth = (constraints.maxWidth - OmniSpacing.xs) / 2;
        return SizedBox.expand(
          child: SingleChildScrollView(
            key: const ValueKey<String>('todo-quadrant-grid'),
            child: Wrap(
              spacing: OmniSpacing.xs,
              runSpacing: OmniSpacing.xs,
              children: <Widget>[
                for (final TodoPriorityQuadrant quadrant
                    in todoPriorityQuadrantMatrixOrder)
                  SizedBox(
                    width: cardWidth,
                    child: _buildQuadrantCell(
                      quadrant,
                      groupedTodos[quadrant]!,
                      now: now,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 构建桌面端单象限聚焦视图。
  Widget _buildFocusedQuadrant(
    BuildContext context,
    TodoPriorityQuadrant quadrant,
    List<TodoRecord> todos, {
    required DateTime now,
  }) {
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
        const SizedBox(height: OmniSpacing.xs),
        _buildQuadrantCell(quadrant, todos, now: now, allowFocus: false),
      ],
    );
  }

  /// 构建移动端象限导航与纵向分区。
  Widget _buildMobileQuadrants(
    BuildContext context,
    Map<TodoPriorityQuadrant, List<TodoRecord>> groupedTodos, {
    required DateTime now,
  }) {
    // 当前需要展示的象限。
    final List<TodoPriorityQuadrant> visibleQuadrants =
        _priorityQuadrantFilter == null
        ? todoPriorityQuadrantActionOrder
        : <TodoPriorityQuadrant>[_priorityQuadrantFilter!];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _MobileQuadrantNavigation(
          selectedQuadrant: _priorityQuadrantFilter,
          counts: <TodoPriorityQuadrant, int>{
            for (final TodoPriorityQuadrant quadrant
                in todoPriorityQuadrantMatrixOrder)
              quadrant: groupedTodos[quadrant]!.length,
          },
          onSelected: (TodoPriorityQuadrant? value) {
            setState(() => _priorityQuadrantFilter = value);
          },
        ),
        const SizedBox(height: OmniSpacing.xs),
        for (
          int index = 0;
          index < visibleQuadrants.length;
          index += 1
        ) ...<Widget>[
          if (index > 0) const SizedBox(height: OmniSpacing.xs),
          _TodoMobileSection(
            key: ValueKey<String>(
              'todo-mobile-section-${visibleQuadrants[index].value}-${_priorityQuadrantFilter == null ? 'all' : 'focused'}',
            ),
            quadrant: visibleQuadrants[index],
            todos: groupedTodos[visibleQuadrants[index]]!,
            statusFilter: _statusFilter,
            now: now,
            completingTodoIds: _completingTodoIds,
            forceExpanded: _priorityQuadrantFilter != null,
            onCreate: () => TodoEditorDialog.show(
              context,
              initialDate: _selectedDay,
              initialPriorityQuadrant: visibleQuadrants[index],
            ),
            onCompletedChanged: _setTodoCompleted,
            onEdit: (TodoRecord todo) =>
                TodoEditorDialog.show(context, record: todo),
            onMove: _moveTodo,
            onDelete: _confirmDelete,
          ),
        ],
      ],
    );
  }

  /// 构建一个可操作的象限单元格。
  Widget _buildQuadrantCell(
    TodoPriorityQuadrant quadrant,
    List<TodoRecord> todos, {
    required DateTime now,
    bool allowFocus = true,
  }) {
    return _TodoQuadrantCell(
      quadrant: quadrant,
      todos: todos,
      statusFilter: _statusFilter,
      now: now,
      completingTodoIds: _completingTodoIds,
      onFocus: allowFocus
          ? () => setState(() => _priorityQuadrantFilter = quadrant)
          : null,
      onCreate: () => TodoEditorDialog.show(
        context,
        initialDate: _selectedDay,
        initialPriorityQuadrant: quadrant,
      ),
      onCompletedChanged: _setTodoCompleted,
      onEdit: (TodoRecord todo) => TodoEditorDialog.show(context, record: todo),
      onMove: _moveTodo,
      onDelete: _confirmDelete,
    );
  }

  /// 比较同一象限内待办的展示顺序。
  int _compareTodoPriority(TodoRecord left, TodoRecord right) {
    // 完成状态比较结果。
    final int completedComparison = (left.isCompleted ? 1 : 0).compareTo(
      right.isCompleted ? 1 : 0,
    );
    if (completedComparison != 0) {
      return completedComparison;
    }
    // 无截止时间任务使用的远期时间。
    final DateTime distantFuture = DateTime(9999);
    // 截止时间比较结果。
    final int dueComparison = (left.dueAt ?? distantFuture).compareTo(
      right.dueAt ?? distantFuture,
    );
    if (dueComparison != 0) {
      return dueComparison;
    }
    // 用户排序值比较结果。
    final int sortOrderComparison = left.sortOrder.compareTo(right.sortOrder);
    if (sortOrderComparison != 0) {
      return sortOrderComparison;
    }
    return left.createdAt.compareTo(right.createdAt);
  }

  /// 更新完成状态并在完成时播放短暂淡出反馈。
  Future<void> _setTodoCompleted(TodoRecord todo, bool value) async {
    // 当前待办仓储。
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
    setState(() => _completingTodoIds.add(todo.id));
    await Future<void>.delayed(
      disableAnimations ? Duration.zero : OmniMotion.normal,
    );
    await repository.setCompleted(todo.id, true);
    if (!mounted) {
      return;
    }
    _undoTimer?.cancel();
    setState(() {
      _completingTodoIds.remove(todo.id);
      _undoTodo = todo;
    });
    _undoTimer = Timer(const Duration(seconds: 6), _dismissUndo);
  }

  /// 撤销最近一次完成操作。
  Future<void> _undoCompletion() async {
    // 当前准备恢复的待办。
    final TodoRecord? todo = _undoTodo;
    if (todo == null) {
      return;
    }
    _undoTimer?.cancel();
    await ref.read(todoRepositoryProvider).setCompleted(todo.id, false);
    if (mounted && _undoTodo?.id == todo.id) {
      setState(() => _undoTodo = null);
    }
  }

  /// 关闭页面内撤销入口。
  void _dismissUndo() {
    _undoTimer?.cancel();
    if (mounted && _undoTodo != null) {
      setState(() => _undoTodo = null);
    }
  }

  /// 选择并更新待办所属优先象限。
  Future<void> _moveTodo(TodoRecord todo) async {
    // 当前待办所属象限。
    final TodoPriorityQuadrant currentQuadrant = TodoPriorityQuadrant.fromValue(
      todo.priorityQuadrant,
    );
    // 用户选择的目标象限。
    final TodoPriorityQuadrant? targetQuadrant =
        await showDialog<TodoPriorityQuadrant>(
          context: context,
          builder: (BuildContext context) {
            return OmniDialogScaffold(
              title: '移动到其他象限',
              actions: <Widget>[
                OmniButton(
                  label: '取消',
                  variant: OmniButtonVariant.text,
                  onPressed: () => Navigator.pop(context),
                ),
              ],
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  for (final TodoPriorityQuadrant quadrant
                      in todoPriorityQuadrantActionOrder)
                    ListTile(
                      enabled: quadrant != currentQuadrant,
                      leading: Icon(quadrant.icon),
                      title: Text(quadrant.label),
                      subtitle: Text(quadrant.actionLabel),
                      trailing: quadrant == currentQuadrant
                          ? const Icon(Icons.check_rounded)
                          : null,
                      onTap: quadrant == currentQuadrant
                          ? null
                          : () => Navigator.pop(context, quadrant),
                    ),
                ],
              ),
            );
          },
        );
    if (targetQuadrant == null || targetQuadrant == currentQuadrant) {
      return;
    }
    await ref
        .read(todoRepositoryProvider)
        .setPriorityQuadrant(todo.id, targetQuadrant);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已移动到“${targetQuadrant.label}”')));
    }
  }

  /// 确认将待办移入回收站。
  Future<void> _confirmDelete(TodoRecord todo) async {
    // 用户选择的删除范围。
    final TodoSeriesScope? scope = await showDialog<TodoSeriesScope>(
      context: context,
      builder: (BuildContext context) {
        return OmniDialogScaffold(
          title: '移入回收站？',
          actions: <Widget>[
            OmniButton(
              label: '取消',
              variant: OmniButtonVariant.text,
              onPressed: () => Navigator.pop(context),
            ),
            if (todo.repeatSeriesId != null)
              OmniButton(
                label: '仅本次',
                variant: OmniButtonVariant.secondary,
                onPressed: () => Navigator.pop(context, TodoSeriesScope.single),
              ),
            OmniButton(
              label: todo.repeatSeriesId == null ? '移入回收站' : '本次及以后',
              variant: OmniButtonVariant.danger,
              onPressed: () => Navigator.pop(
                context,
                todo.repeatSeriesId == null
                    ? TodoSeriesScope.single
                    : TodoSeriesScope.future,
              ),
            ),
          ],
          child: Text('“${todo.title}”会保留 30 天，可以在设置中恢复。'),
        );
      },
    );
    if (scope == null) {
      return;
    }
    await ref.read(todoRepositoryProvider).delete(todo.id, scope: scope);
    ref.invalidate(recycleBinItemsProvider);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已将“${todo.title}”移入回收站'),
          action: scope == TodoSeriesScope.single
              ? SnackBarAction(
                  label: '撤销',
                  onPressed: () =>
                      ref.read(todoRepositoryProvider).restore(todo.id),
                )
              : null,
        ),
      );
    }
  }
}

/// 日期巡航与状态计数控制区。
class _TodoControlBar extends StatelessWidget {
  /// 当前选中的自然日。
  final DateTime selectedDay;

  /// 当前自然日。
  final DateTime today;

  /// 当前状态筛选。
  final _TodoStatusFilter statusFilter;

  /// 未完成待办数量。
  final int pendingCount;

  /// 已完成待办数量。
  final int completedCount;

  /// 日期选择回调。
  final ValueChanged<DateTime> onDaySelected;

  /// 状态筛选回调。
  final ValueChanged<_TodoStatusFilter> onStatusSelected;

  /// 创建日期与状态控制区。
  const _TodoControlBar({
    required this.selectedDay,
    required this.today,
    required this.statusFilter,
    required this.pendingCount,
    required this.completedCount,
    required this.onDaySelected,
    required this.onStatusSelected,
  });

  /// 构建桌面双端对齐或移动端纵向排列的控制区。
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 日期巡航控件。
        final Widget dateSelector = _DateSelector(
          selectedDay: selectedDay,
          today: today,
          onSelected: onDaySelected,
        );
        // 带数量的状态切换控件。
        final Widget statusSelector = _TodoStatusSelector(
          selected: statusFilter,
          pendingCount: pendingCount,
          completedCount: completedCount,
          onSelected: onStatusSelected,
        );
        if (constraints.maxWidth >= 720) {
          return Row(
            children: <Widget>[dateSelector, const Spacer(), statusSelector],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            dateSelector,
            const SizedBox(height: OmniSpacing.xs),
            statusSelector,
          ],
        );
      },
    );
  }
}

/// 每日待办页的日期巡航控件。
class _DateSelector extends StatelessWidget {
  /// 当前选中的自然日。
  final DateTime selectedDay;

  /// 当前自然日。
  final DateTime today;

  /// 日期选择回调。
  final ValueChanged<DateTime> onSelected;

  /// 创建日期巡航控件。
  const _DateSelector({
    required this.selectedDay,
    required this.today,
    required this.onSelected,
  });

  /// 构建前后日期导航、日期选择与回到今天入口。
  @override
  Widget build(BuildContext context) {
    // 当前选择是否为今天。
    final bool isToday = DateUtils.isSameDay(selectedDay, today);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        IconButton(
          tooltip: '前一天',
          onPressed: () => onSelected(
            DateUtils.dateOnly(selectedDay.subtract(const Duration(days: 1))),
          ),
          icon: const Icon(Icons.chevron_left_rounded),
        ),
        OmniDatePickerButton(
          value: selectedDay,
          initialDate: selectedDay,
          currentDate: today,
          firstDate: DateTime(2000),
          lastDate: DateTime(2100),
          label: DateFormat('yyyy 年 M 月 d 日').format(selectedDay),
          onChanged: onSelected,
        ),
        IconButton(
          tooltip: '后一天',
          onPressed: () => onSelected(
            DateUtils.dateOnly(selectedDay.add(const Duration(days: 1))),
          ),
          icon: const Icon(Icons.chevron_right_rounded),
        ),
        if (!isToday) ...<Widget>[
          const SizedBox(width: OmniSpacing.xxs),
          TextButton(
            onPressed: () => onSelected(today),
            child: const Text('回到今天'),
          ),
        ],
      ],
    );
  }
}

/// 带任务数量的状态切换控件。
class _TodoStatusSelector extends StatelessWidget {
  /// 当前选中状态。
  final _TodoStatusFilter selected;

  /// 未完成待办数量。
  final int pendingCount;

  /// 已完成待办数量。
  final int completedCount;

  /// 状态选择回调。
  final ValueChanged<_TodoStatusFilter> onSelected;

  /// 创建状态切换控件。
  const _TodoStatusSelector({
    required this.selected,
    required this.pendingCount,
    required this.completedCount,
    required this.onSelected,
  });

  /// 构建未完成、全部与已完成分段按钮。
  @override
  Widget build(BuildContext context) {
    // 全部待办数量。
    final int totalCount = pendingCount + completedCount;
    return SegmentedButton<_TodoStatusFilter>(
      showSelectedIcon: false,
      segments: <ButtonSegment<_TodoStatusFilter>>[
        ButtonSegment<_TodoStatusFilter>(
          value: _TodoStatusFilter.pending,
          label: Text('未完成 $pendingCount'),
        ),
        ButtonSegment<_TodoStatusFilter>(
          value: _TodoStatusFilter.all,
          label: Text('全部 $totalCount'),
        ),
        ButtonSegment<_TodoStatusFilter>(
          value: _TodoStatusFilter.completed,
          label: Text('已完成 $completedCount'),
        ),
      ],
      selected: <_TodoStatusFilter>{selected},
      onSelectionChanged: (Set<_TodoStatusFilter> values) {
        onSelected(values.first);
      },
    );
  }
}

/// 桌面四象限网格中的单个内容卡片。
class _TodoQuadrantCell extends StatelessWidget {
  /// 当前象限。
  final TodoPriorityQuadrant quadrant;

  /// 当前象限内的待办。
  final List<TodoRecord> todos;

  /// 当前状态筛选。
  final _TodoStatusFilter statusFilter;

  /// 当前固定时间。
  final DateTime now;

  /// 正在播放完成反馈的待办标识。
  final Set<String> completingTodoIds;

  /// 可选象限聚焦回调。
  final VoidCallback? onFocus;

  /// 新增回调。
  final VoidCallback onCreate;

  /// 完成状态变化回调。
  final Future<void> Function(TodoRecord todo, bool value) onCompletedChanged;

  /// 编辑回调。
  final ValueChanged<TodoRecord> onEdit;

  /// 移动象限回调。
  final ValueChanged<TodoRecord> onMove;

  /// 删除回调。
  final ValueChanged<TodoRecord> onDelete;

  /// 创建一个象限内容卡片。
  const _TodoQuadrantCell({
    required this.quadrant,
    required this.todos,
    required this.statusFilter,
    required this.now,
    required this.completingTodoIds,
    required this.onFocus,
    required this.onCreate,
    required this.onCompletedChanged,
    required this.onEdit,
    required this.onMove,
    required this.onDelete,
  });

  /// 构建带独立边界的象限标题与紧凑任务内容。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前象限强调色。
    final Color accentColor = quadrant.color(colors);
    return Container(
      key: ValueKey<String>('todo-quadrant-card-${quadrant.value}'),
      decoration: BoxDecoration(
        color: colors.paper,
        borderRadius: BorderRadius.circular(OmniRadius.panel),
        border: Border.all(color: colors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Material(
            color: accentColor.withValues(alpha: 0.055),
            child: InkWell(
              key: ValueKey<String>('todo-quadrant-heading-${quadrant.value}'),
              onTap: onFocus,
              hoverColor: accentColor.withValues(alpha: 0.08),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  OmniSpacing.md,
                  OmniSpacing.xs,
                  OmniSpacing.xs,
                  OmniSpacing.xs,
                ),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: accentColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(OmniRadius.control),
                      ),
                      child: Icon(quadrant.icon, size: 17, color: accentColor),
                    ),
                    const SizedBox(width: OmniSpacing.xs),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            quadrant.actionLabel,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            quadrant.label,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: accentColor,
                                  fontWeight: FontWeight.w500,
                                ),
                          ),
                        ],
                      ),
                    ),
                    OmniTag(label: '${todos.length}', color: accentColor),
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
          _TodoTaskList(
            quadrant: quadrant,
            todos: todos,
            statusFilter: statusFilter,
            now: now,
            completingTodoIds: completingTodoIds,
            fillHeight: false,
            onCreate: onCreate,
            onCompletedChanged: onCompletedChanged,
            onEdit: onEdit,
            onMove: onMove,
            onDelete: onDelete,
          ),
        ],
      ),
    );
  }
}

/// 移动端象限选择导航。
class _MobileQuadrantNavigation extends StatelessWidget {
  /// 当前选中的象限；为空表示查看全部。
  final TodoPriorityQuadrant? selectedQuadrant;

  /// 各象限当前筛选下的待办数量。
  final Map<TodoPriorityQuadrant, int> counts;

  /// 象限选择回调。
  final ValueChanged<TodoPriorityQuadrant?> onSelected;

  /// 创建移动端象限导航。
  const _MobileQuadrantNavigation({
    required this.selectedQuadrant,
    required this.counts,
    required this.onSelected,
  });

  /// 构建可横向滚动的象限选择项。
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

/// 移动端纵向象限分区。
class _TodoMobileSection extends StatelessWidget {
  /// 当前象限。
  final TodoPriorityQuadrant quadrant;

  /// 当前象限内待办。
  final List<TodoRecord> todos;

  /// 当前状态筛选。
  final _TodoStatusFilter statusFilter;

  /// 当前固定时间。
  final DateTime now;

  /// 正在播放完成反馈的待办标识。
  final Set<String> completingTodoIds;

  /// 是否强制初始展开。
  final bool forceExpanded;

  /// 新增回调。
  final VoidCallback onCreate;

  /// 完成状态变化回调。
  final Future<void> Function(TodoRecord todo, bool value) onCompletedChanged;

  /// 编辑回调。
  final ValueChanged<TodoRecord> onEdit;

  /// 移动象限回调。
  final ValueChanged<TodoRecord> onMove;

  /// 删除回调。
  final ValueChanged<TodoRecord> onDelete;

  /// 创建移动端纵向象限分区。
  const _TodoMobileSection({
    required this.quadrant,
    required this.todos,
    required this.statusFilter,
    required this.now,
    required this.completingTodoIds,
    required this.forceExpanded,
    required this.onCreate,
    required this.onCompletedChanged,
    required this.onEdit,
    required this.onMove,
    required this.onDelete,
    super.key,
  });

  /// 构建默认展开有内容象限、折叠空象限的移动端分区。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前象限强调色。
    final Color accentColor = quadrant.color(colors);
    // 当前象限是否默认展开。
    final bool initiallyExpanded =
        forceExpanded ||
        todos.isNotEmpty ||
        quadrant == TodoPriorityQuadrant.urgentImportant;
    return Material(
      color: colors.paper,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(OmniRadius.panel),
        side: BorderSide(color: colors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          tilePadding: const EdgeInsets.only(
            left: OmniSpacing.sm,
            right: OmniSpacing.xs,
          ),
          childrenPadding: EdgeInsets.zero,
          leading: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: accentColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(OmniRadius.control),
            ),
            child: Icon(quadrant.icon, size: 17, color: accentColor),
          ),
          title: Text(
            quadrant.actionLabel,
            style: Theme.of(context).textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            quadrant.label,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: accentColor, fontWeight: FontWeight.w500),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              OmniTag(label: '${todos.length}', color: accentColor),
              IconButton(
                tooltip: '添加到${quadrant.label}',
                onPressed: onCreate,
                icon: const Icon(Icons.add_rounded),
              ),
              const Icon(Icons.expand_more_rounded),
            ],
          ),
          children: <Widget>[
            Divider(color: colors.line),
            _TodoTaskList(
              quadrant: quadrant,
              todos: todos,
              statusFilter: statusFilter,
              now: now,
              completingTodoIds: completingTodoIds,
              fillHeight: false,
              onCreate: onCreate,
              onCompletedChanged: onCompletedChanged,
              onEdit: onEdit,
              onMove: onMove,
              onDelete: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

/// 单个象限的任务列表内容。
class _TodoTaskList extends StatelessWidget {
  /// 当前象限。
  final TodoPriorityQuadrant quadrant;

  /// 当前象限内待办。
  final List<TodoRecord> todos;

  /// 当前状态筛选。
  final _TodoStatusFilter statusFilter;

  /// 当前固定时间。
  final DateTime now;

  /// 正在播放完成反馈的待办标识。
  final Set<String> completingTodoIds;

  /// 是否填满分配高度。
  final bool fillHeight;

  /// 新增回调。
  final VoidCallback onCreate;

  /// 完成状态变化回调。
  final Future<void> Function(TodoRecord todo, bool value) onCompletedChanged;

  /// 编辑回调。
  final ValueChanged<TodoRecord> onEdit;

  /// 移动象限回调。
  final ValueChanged<TodoRecord> onMove;

  /// 删除回调。
  final ValueChanged<TodoRecord> onDelete;

  /// 创建象限任务列表。
  const _TodoTaskList({
    required this.quadrant,
    required this.todos,
    required this.statusFilter,
    required this.now,
    required this.completingTodoIds,
    required this.fillHeight,
    required this.onCreate,
    required this.onCompletedChanged,
    required this.onEdit,
    required this.onMove,
    required this.onDelete,
  });

  /// 构建当前筛选状态对应的任务内容。
  @override
  Widget build(BuildContext context) {
    if (todos.isEmpty) {
      return _QuadrantEmptyState(
        statusFilter: statusFilter,
        onCreate: onCreate,
      );
    }
    // 当前象限未完成待办。
    final List<TodoRecord> pendingTodos = todos
        .where((TodoRecord todo) => !todo.isCompleted)
        .toList(growable: false);
    // 当前象限已完成待办。
    final List<TodoRecord> completedTodos = todos
        .where((TodoRecord todo) => todo.isCompleted)
        .toList(growable: false);
    // 当前需要直接展示的任务。
    final List<TodoRecord> directTodos = switch (statusFilter) {
      _TodoStatusFilter.pending => pendingTodos,
      _TodoStatusFilter.all => pendingTodos,
      _TodoStatusFilter.completed => completedTodos,
    };
    // 当前任务列表内容。
    final List<Widget> children = <Widget>[
      ..._buildSeparatedRows(directTodos),
      if (statusFilter == _TodoStatusFilter.all && completedTodos.isNotEmpty)
        ExpansionTile(
          initiallyExpanded: pendingTodos.isEmpty,
          tilePadding: const EdgeInsets.symmetric(horizontal: OmniSpacing.md),
          childrenPadding: EdgeInsets.zero,
          title: Text('已完成 ${completedTodos.length} 项'),
          children: _buildSeparatedRows(completedTodos),
        ),
    ];

    if (fillHeight) {
      return ListView(padding: EdgeInsets.zero, children: children);
    }
    return Column(mainAxisSize: MainAxisSize.min, children: children);
  }

  /// 构建插入分隔线后的任务行。
  List<Widget> _buildSeparatedRows(List<TodoRecord> records) {
    // 带分隔线的任务行。
    final List<Widget> rows = <Widget>[];
    for (int index = 0; index < records.length; index += 1) {
      if (index > 0) {
        rows.add(const Divider(indent: OmniSpacing.md));
      }
      // 当前任务。
      final TodoRecord todo = records[index];
      rows.add(
        _TodoRow(
          todo: todo,
          now: now,
          completing: completingTodoIds.contains(todo.id),
          onCompletedChanged: (bool value) => onCompletedChanged(todo, value),
          onEdit: () => onEdit(todo),
          onMove: () => onMove(todo),
          onDelete: () => onDelete(todo),
        ),
      );
    }
    return rows;
  }
}

/// 单条待办行。
class _TodoRow extends StatelessWidget {
  /// 当前待办。
  final TodoRecord todo;

  /// 当前固定时间。
  final DateTime now;

  /// 是否正在播放完成反馈。
  final bool completing;

  /// 完成状态变化回调。
  final ValueChanged<bool> onCompletedChanged;

  /// 编辑回调。
  final VoidCallback onEdit;

  /// 移动象限回调。
  final VoidCallback onMove;

  /// 删除回调。
  final VoidCallback onDelete;

  /// 创建待办行。
  const _TodoRow({
    required this.todo,
    required this.now,
    required this.completing,
    required this.onCompletedChanged,
    required this.onEdit,
    required this.onMove,
    required this.onDelete,
  });

  /// 构建待办内容、完成反馈与操作。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前待办是否具有辅助信息。
    final bool hasDetails =
        (todo.description?.trim().isNotEmpty ?? false) ||
        todo.dueAt != null ||
        todo.repeatRule != null ||
        todo.syncState != 'localSaved';
    // 当前任务行主体。
    final Widget row = OmniListRow(
      onTap: onEdit,
      padding: const EdgeInsets.symmetric(
        horizontal: OmniSpacing.md,
        vertical: OmniSpacing.xs,
      ),
      leading: Semantics(
        label: todo.isCompleted ? '取消完成 ${todo.title}' : '完成 ${todo.title}',
        child: Checkbox(
          value: todo.isCompleted || completing,
          onChanged: completing
              ? null
              : (bool? value) => onCompletedChanged(value ?? false),
        ),
      ),
      title: Text(
        todo.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: todo.isCompleted ? colors.muted : colors.ink,
          decoration: todo.isCompleted ? TextDecoration.lineThrough : null,
        ),
      ),
      subtitle: hasDetails ? _TodoDetails(todo: todo, now: now) : null,
      trailing: OmniPopupMenuButton<String>(
        tooltip: '更多操作',
        onSelected: (String value) {
          if (value == 'edit') {
            onEdit();
          } else if (value == 'move') {
            onMove();
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
    );
    // 当前是否关闭非必要动画。
    final bool disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return AnimatedOpacity(
      key: ValueKey<String>('todo-row-${todo.id}'),
      opacity: completing ? 0 : 1,
      duration: disableAnimations ? Duration.zero : OmniMotion.normal,
      curve: OmniMotion.standardCurve,
      child: AbsorbPointer(absorbing: completing, child: row),
    );
  }
}

/// 待办描述、时间、重复和异常同步信息。
class _TodoDetails extends StatelessWidget {
  /// 当前待办。
  final TodoRecord todo;

  /// 当前固定时间。
  final DateTime now;

  /// 创建待办辅助信息。
  const _TodoDetails({required this.todo, required this.now});

  /// 构建一行描述和紧凑元数据。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前截止时间是否已经逾期。
    final bool overdue =
        !todo.isCompleted && todo.dueAt != null && todo.dueAt!.isBefore(now);
    // 当前待办描述。
    final String? description = todo.description?.trim().isNotEmpty ?? false
        ? todo.description!.trim()
        : null;
    // 当前是否存在元数据。
    final bool hasMetadata =
        todo.dueAt != null ||
        todo.repeatRule != null ||
        todo.syncState != 'localSaved';
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
        if (description != null && hasMetadata)
          const SizedBox(height: OmniSpacing.xxs),
        if (hasMetadata)
          Wrap(
            spacing: OmniSpacing.sm,
            runSpacing: OmniSpacing.xxs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              if (todo.dueAt != null)
                _TodoMetadataItem(
                  icon: overdue
                      ? Icons.error_outline_rounded
                      : Icons.schedule_outlined,
                  label: overdue
                      ? '已逾期 ${DateFormat('HH:mm').format(todo.dueAt!)}'
                      : '截止 ${DateFormat('HH:mm').format(todo.dueAt!)}',
                  color: overdue ? colors.danger : colors.muted,
                ),
              if (todo.repeatRule != null)
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

  /// 返回重复规则展示名称。
  String _repeatLabel(String value) {
    return switch (value) {
      'daily' => '每天',
      'weekly' => '每周',
      'monthly' => '每月',
      _ => '重复',
    };
  }
}

/// 单个待办元数据项。
class _TodoMetadataItem extends StatelessWidget {
  /// 元数据图标。
  final IconData icon;

  /// 元数据文字。
  final String label;

  /// 元数据颜色。
  final Color color;

  /// 创建待办元数据项。
  const _TodoMetadataItem({
    required this.icon,
    required this.label,
    required this.color,
  });

  /// 构建图标与文字组合。
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 13, color: color),
        const SizedBox(width: OmniSpacing.xxs),
        Text(label, style: TextStyle(color: color)),
      ],
    );
  }
}

/// 单个象限的紧凑空状态。
class _QuadrantEmptyState extends StatelessWidget {
  /// 当前状态筛选。
  final _TodoStatusFilter statusFilter;

  /// 新增回调。
  final VoidCallback onCreate;

  /// 创建象限空状态。
  const _QuadrantEmptyState({
    required this.statusFilter,
    required this.onCreate,
  });

  /// 构建靠近内容起点的可行动空状态。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前筛选对应的空状态文字。
    final String label = statusFilter == _TodoStatusFilter.completed
        ? '还没有已完成待办'
        : '这里还没有待办';
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: OmniSpacing.md,
        vertical: OmniSpacing.sm,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(label, style: TextStyle(color: colors.muted)),
          ),
          if (statusFilter != _TodoStatusFilter.completed)
            TextButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add_rounded, size: 16),
              label: const Text('添加一项'),
            ),
        ],
      ),
    );
  }
}

/// 页面内可撤销完成操作的反馈条。
class _TodoUndoBanner extends StatelessWidget {
  /// 最近完成的待办。
  final TodoRecord todo;

  /// 撤销回调。
  final VoidCallback onUndo;

  /// 关闭回调。
  final VoidCallback onDismiss;

  /// 创建页面内撤销反馈条。
  const _TodoUndoBanner({
    required this.todo,
    required this.onUndo,
    required this.onDismiss,
  });

  /// 构建不会遮挡四象限内容的内嵌反馈。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Container(
      key: const ValueKey<String>('todo-undo-banner'),
      padding: const EdgeInsets.only(left: OmniSpacing.md),
      decoration: BoxDecoration(
        color: colors.paper,
        borderRadius: BorderRadius.circular(OmniRadius.control),
        border: Border.all(color: colors.line),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.check_circle_outline_rounded, color: colors.success),
          const SizedBox(width: OmniSpacing.xs),
          Expanded(child: Text('已完成“${todo.title}”')),
          TextButton(onPressed: onUndo, child: const Text('撤销')),
          IconButton(
            tooltip: '关闭',
            onPressed: onDismiss,
            icon: const Icon(Icons.close_rounded, size: 17),
          ),
        ],
      ),
    );
  }
}

/// 数据读取错误卡。
class _ErrorCard extends StatelessWidget {
  /// 错误说明。
  final String message;

  /// 创建数据读取错误卡。
  const _ErrorCard({required this.message});

  /// 构建错误卡。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return OmniPanel(
      padding: const EdgeInsets.all(OmniSpacing.xl),
      child: Row(
        children: <Widget>[
          Icon(Icons.error_outline_rounded, color: colors.danger),
          const SizedBox(width: 12),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }
}
