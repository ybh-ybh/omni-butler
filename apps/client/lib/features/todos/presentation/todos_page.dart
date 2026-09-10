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
  DateTime _selectedDay = DateUtils.dateOnly(DateTime.now());

  /// 当前状态筛选。
  _TodoStatusFilter _statusFilter = _TodoStatusFilter.pending;

  /// 当前优先象限筛选。
  TodoPriorityQuadrant? _priorityQuadrantFilter;

  /// 初始化首页带入的象限筛选。
  @override
  void initState() {
    super.initState();
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
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          OmniSpacing.xs,
          OmniSpacing.xs,
          OmniSpacing.xs,
          OmniSpacing.md,
        ),
        child: _buildPageContent(context, todosAsync, mobile: true),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: 14,
        vertical: OmniSpacing.sm,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1240),
          child: _buildPageContent(context, todosAsync, mobile: false),
        ),
      ),
    );
  }

  /// 构建页面标题、工具栏与象限内容。
  Widget _buildPageContent(
    BuildContext context,
    AsyncValue<List<TodoRecord>> todosAsync, {
    required bool mobile,
  }) {
    // 页面标题与工具栏。
    final List<Widget> leadingContent = <Widget>[
      _buildHeader(context),
      const SizedBox(height: OmniSpacing.xs),
      _DateSelector(
        selectedDay: _selectedDay,
        onSelected: (DateTime day) => setState(() => _selectedDay = day),
      ),
      const SizedBox(height: OmniSpacing.xs),
      _buildFilters(context),
      const SizedBox(height: OmniSpacing.xs),
    ];
    // 当前异步状态对应的页面主体。
    final Widget body = todosAsync.when(
      data: (List<TodoRecord> todos) =>
          _buildQuadrantContent(context, todos, mobile: mobile),
      loading: () => const Center(
        child: Padding(
          padding: EdgeInsets.all(48),
          child: CircularProgressIndicator(),
        ),
      ),
      error: (Object error, StackTrace stackTrace) =>
          _ErrorCard(message: '待办读取失败：$error'),
    );

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
        Expanded(child: body),
      ],
    );
  }

  /// 构建页面标题区。
  Widget _buildHeader(BuildContext context) {
    return OmniPageHeader(
      title: '每日待办',
      description: '按紧急与重要程度把今天安排清楚。',
      actions: <Widget>[
        OmniButton(
          label: '回到今天',
          icon: Icons.today_outlined,
          variant: OmniButtonVariant.secondary,
          onPressed: () =>
              setState(() => _selectedDay = DateUtils.dateOnly(DateTime.now())),
        ),
        OmniButton(
          label: '新增待办',
          icon: Icons.add_rounded,
          variant: OmniButtonVariant.pagePrimary,
          onPressed: () =>
              TodoEditorDialog.show(context, initialDate: _selectedDay),
        ),
      ],
    );
  }

  /// 构建状态与优先象限筛选。
  Widget _buildFilters(BuildContext context) {
    return OmniToolbar(
      children: <Widget>[
        SegmentedButton<_TodoStatusFilter>(
          showSelectedIcon: false,
          segments: const <ButtonSegment<_TodoStatusFilter>>[
            ButtonSegment<_TodoStatusFilter>(
              value: _TodoStatusFilter.pending,
              label: Text('未完成'),
            ),
            ButtonSegment<_TodoStatusFilter>(
              value: _TodoStatusFilter.all,
              label: Text('全部'),
            ),
            ButtonSegment<_TodoStatusFilter>(
              value: _TodoStatusFilter.completed,
              label: Text('已完成'),
            ),
          ],
          selected: <_TodoStatusFilter>{_statusFilter},
          onSelectionChanged: (Set<_TodoStatusFilter> values) {
            setState(() => _statusFilter = values.first);
          },
        ),
        OmniDropdownButton<TodoPriorityQuadrant?>(
          value: _priorityQuadrantFilter,
          hint: const Text('全部象限'),
          items: <DropdownMenuItem<TodoPriorityQuadrant?>>[
            const DropdownMenuItem<TodoPriorityQuadrant?>(
              value: null,
              child: Text('全部象限'),
            ),
            for (final TodoPriorityQuadrant quadrant
                in todoPriorityQuadrantActionOrder)
              DropdownMenuItem<TodoPriorityQuadrant?>(
                value: quadrant,
                child: Text(quadrant.label),
              ),
          ],
          onChanged: (TodoPriorityQuadrant? value) {
            setState(() => _priorityQuadrantFilter = value);
          },
        ),
      ],
    );
  }

  /// 构建筛选并分组后的四象限内容。
  Widget _buildQuadrantContent(
    BuildContext context,
    List<TodoRecord> todos, {
    required bool mobile,
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
    // 当前需要显示的象限。
    final List<TodoPriorityQuadrant> visibleQuadrants =
        _priorityQuadrantFilter == null
        ? todoPriorityQuadrantMatrixOrder
        : <TodoPriorityQuadrant>[_priorityQuadrantFilter!];
    // 按象限分组后的待办。
    final Map<TodoPriorityQuadrant, List<TodoRecord>> groupedTodos =
        <TodoPriorityQuadrant, List<TodoRecord>>{
          for (final TodoPriorityQuadrant quadrant in visibleQuadrants)
            quadrant: <TodoRecord>[],
        };
    for (final TodoRecord todo in statusFilteredTodos) {
      // 当前待办所属象限。
      final TodoPriorityQuadrant quadrant = TodoPriorityQuadrant.fromValue(
        todo.priorityQuadrant,
      );
      groupedTodos[quadrant]?.add(todo);
    }
    for (final List<TodoRecord> quadrantTodos in groupedTodos.values) {
      quadrantTodos.sort(_compareTodoPriority);
    }

    if (mobile) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int index = 0; index < visibleQuadrants.length; index += 1) ...[
            if (index > 0) const SizedBox(height: OmniSpacing.xs),
            _buildQuadrantPanel(
              context,
              visibleQuadrants[index],
              groupedTodos[visibleQuadrants[index]]!,
              fillHeight: false,
            ),
          ],
        ],
      );
    }

    if (visibleQuadrants.length == 1) {
      // 当前唯一显示的象限。
      final TodoPriorityQuadrant quadrant = visibleQuadrants.single;
      return _buildQuadrantPanel(
        context,
        quadrant,
        groupedTodos[quadrant]!,
        fillHeight: true,
      );
    }

    return Column(
      children: <Widget>[
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                child: _buildQuadrantPanel(
                  context,
                  visibleQuadrants[0],
                  groupedTodos[visibleQuadrants[0]]!,
                  fillHeight: true,
                ),
              ),
              const SizedBox(width: OmniSpacing.xs),
              Expanded(
                child: _buildQuadrantPanel(
                  context,
                  visibleQuadrants[1],
                  groupedTodos[visibleQuadrants[1]]!,
                  fillHeight: true,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: OmniSpacing.xs),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                child: _buildQuadrantPanel(
                  context,
                  visibleQuadrants[2],
                  groupedTodos[visibleQuadrants[2]]!,
                  fillHeight: true,
                ),
              ),
              const SizedBox(width: OmniSpacing.xs),
              Expanded(
                child: _buildQuadrantPanel(
                  context,
                  visibleQuadrants[3],
                  groupedTodos[visibleQuadrants[3]]!,
                  fillHeight: true,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 构建一个可操作的象限面板。
  Widget _buildQuadrantPanel(
    BuildContext context,
    TodoPriorityQuadrant quadrant,
    List<TodoRecord> todos, {
    required bool fillHeight,
  }) {
    return _TodoQuadrantPanel(
      quadrant: quadrant,
      todos: todos,
      statusFilter: _statusFilter,
      fillHeight: fillHeight,
      onCreate: () => TodoEditorDialog.show(
        context,
        initialDate: _selectedDay,
        initialPriorityQuadrant: quadrant,
      ),
      onCompletedChanged: (TodoRecord todo, bool value) {
        ref.read(todoRepositoryProvider).setCompleted(todo.id, value);
      },
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

/// 每日待办页的统一日期选择器。
class _DateSelector extends StatelessWidget {
  /// 当前选中的自然日。
  final DateTime selectedDay;

  /// 日期选择回调。
  final ValueChanged<DateTime> onSelected;

  /// 创建日期选择器。
  const _DateSelector({required this.selectedDay, required this.onSelected});

  /// 构建前后日期导航与锚定式日历浮层。
  @override
  Widget build(BuildContext context) {
    return OmniToolbar(
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
      ],
    );
  }
}

/// 一个四象限待办分区。
class _TodoQuadrantPanel extends StatelessWidget {
  /// 当前象限。
  final TodoPriorityQuadrant quadrant;

  /// 当前象限内的待办。
  final List<TodoRecord> todos;

  /// 当前状态筛选。
  final _TodoStatusFilter statusFilter;

  /// 是否填满桌面网格分配的高度。
  final bool fillHeight;

  /// 新增回调。
  final VoidCallback onCreate;

  /// 完成状态变化回调。
  final void Function(TodoRecord todo, bool value) onCompletedChanged;

  /// 编辑回调。
  final ValueChanged<TodoRecord> onEdit;

  /// 移动象限回调。
  final ValueChanged<TodoRecord> onMove;

  /// 删除回调。
  final ValueChanged<TodoRecord> onDelete;

  /// 创建四象限待办分区。
  const _TodoQuadrantPanel({
    required this.quadrant,
    required this.todos,
    required this.statusFilter,
    required this.fillHeight,
    required this.onCreate,
    required this.onCompletedChanged,
    required this.onEdit,
    required this.onMove,
    required this.onDelete,
  });

  /// 构建含固定位置、文字和颜色线索的象限面板。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前象限强调色。
    final Color accentColor = quadrant.color(colors);
    // 当前象限未完成待办。
    final List<TodoRecord> pendingTodos = todos
        .where((TodoRecord todo) => !todo.isCompleted)
        .toList(growable: false);
    // 当前象限已完成待办。
    final List<TodoRecord> completedTodos = todos
        .where((TodoRecord todo) => todo.isCompleted)
        .toList(growable: false);
    // 当前象限的任务内容。
    final Widget content = _buildContent(context, pendingTodos, completedTodos);

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.paper,
        borderRadius: BorderRadius.circular(OmniRadius.panel),
        border: Border.all(color: colors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(height: 3, color: accentColor),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              OmniSpacing.md,
              OmniSpacing.sm,
              OmniSpacing.xs,
              OmniSpacing.sm,
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
                        quadrant.label,
                        style: Theme.of(context).textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        quadrant.actionLabel,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: accentColor,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                OmniTag(label: '${todos.length} 项', color: accentColor),
                IconButton(
                  tooltip: '添加到${quadrant.label}',
                  onPressed: onCreate,
                  icon: const Icon(Icons.add_rounded),
                ),
              ],
            ),
          ),
          Divider(color: colors.line),
          if (fillHeight) Expanded(child: content) else content,
        ],
      ),
    );
  }

  /// 构建当前筛选状态对应的任务内容。
  Widget _buildContent(
    BuildContext context,
    List<TodoRecord> pendingTodos,
    List<TodoRecord> completedTodos,
  ) {
    if (todos.isEmpty) {
      return _QuadrantEmptyState(quadrant: quadrant, onCreate: onCreate);
    }
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
    required this.onCompletedChanged,
    required this.onEdit,
    required this.onMove,
    required this.onDelete,
  });

  /// 构建待办内容与操作。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);

    return OmniListRow(
      onTap: onEdit,
      leading: Semantics(
        label: todo.isCompleted ? '取消完成 ${todo.title}' : '完成 ${todo.title}',
        child: Checkbox(
          value: todo.isCompleted,
          onChanged: (bool? value) => onCompletedChanged(value ?? false),
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
      subtitle: _TodoMetadata(todo: todo),
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
  }
}

/// 待办行的时间与重复信息。
class _TodoMetadata extends StatelessWidget {
  /// 当前待办。
  final TodoRecord todo;

  /// 创建待办元数据。
  const _TodoMetadata({required this.todo});

  /// 构建简洁的辅助信息。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前截止时间是否已经逾期。
    final bool overdue =
        !todo.isCompleted &&
        todo.dueAt != null &&
        todo.dueAt!.isBefore(DateTime.now());

    return Wrap(
      spacing: OmniSpacing.xs,
      runSpacing: OmniSpacing.xxs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        if (todo.dueAt != null)
          Text(
            overdue
                ? '已逾期 ${DateFormat('HH:mm').format(todo.dueAt!)}'
                : '截止 ${DateFormat('HH:mm').format(todo.dueAt!)}',
            style: TextStyle(color: overdue ? colors.danger : colors.muted),
          ),
        if (todo.repeatRule != null)
          Text(
            '· ${_repeatLabel(todo.repeatRule!)}',
            style: TextStyle(color: colors.muted),
          ),
        Text('· 已保存到本机', style: TextStyle(color: colors.muted)),
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

/// 单个象限的空状态。
class _QuadrantEmptyState extends StatelessWidget {
  /// 当前象限。
  final TodoPriorityQuadrant quadrant;

  /// 新增回调。
  final VoidCallback onCreate;

  /// 创建象限空状态。
  const _QuadrantEmptyState({required this.quadrant, required this.onCreate});

  /// 构建保留象限结构的可行动空状态。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前象限强调色。
    final Color accentColor = quadrant.color(colors);

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: OmniSpacing.md,
        vertical: OmniSpacing.lg,
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(quadrant.icon, size: 26, color: accentColor),
            const SizedBox(height: OmniSpacing.xs),
            TextButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add_rounded, size: 16),
              label: const Text('添加待办'),
            ),
          ],
        ),
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
