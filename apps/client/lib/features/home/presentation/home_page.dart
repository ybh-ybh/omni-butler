import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/attachments/attachment_repository.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/todos/data/todo_priority_quadrant.dart';
import 'package:omni_butler/features/todos/presentation/todo_editor_dialog.dart';
import 'package:omni_butler/features/todos/presentation/todo_priority_quadrant_style.dart';
import 'package:omni_butler/features/home/presentation/quote_library_dialog.dart';
import 'package:omni_butler/shared/attachments/attachment_picker_dialog.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 今日工作台页面。
class HomePage extends ConsumerWidget {
  /// 创建今日工作台页面。
  const HomePage({super.key});

  /// 构建左右分栏的今日工作台。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 当前应用时间。
    final DateTime now = ref.watch(nowProvider);
    // 今日自然日。
    final DateTime today = DateUtils.dateOnly(now);
    // 今日名言异步状态。
    final AsyncValue<QuoteRecord> quoteAsync = ref.watch(
      quoteForDayProvider(today),
    );
    // 今日待办异步状态。
    final AsyncValue<List<TodoRecord>> todosAsync = ref.watch(
      todosForDayProvider(today),
    );
    // 今日待办。
    final List<TodoRecord> todos = todosAsync.asData?.value ?? <TodoRecord>[];
    // 今日未完成待办。
    final List<TodoRecord> pendingTodos = todos
        .where((TodoRecord item) => !item.isCompleted)
        .toList(growable: false);
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 今日名言卡。
    final Widget quoteCard = _QuoteHero(
      quoteAsync: quoteAsync,
      onManage: () => QuoteLibraryDialog.show(context),
      onBackground: () => AttachmentPickerDialog.show(
        context,
        businessType: AttachmentBusinessType.quoteBanner,
        businessId: 'home-banner',
        title: '首页横幅背景',
        cropAspectRatio: 3.0,
      ),
      onChange: () async {
        await ref.read(appDatabaseProvider).changeQuoteForDay(today);
        ref.invalidate(quoteForDayProvider(today));
      },
    );
    // 今日时间刻度卡。
    final Widget dayRuler = _DayRuler(now: now);
    // 今日待办卡。
    final Widget todoCard = _TodayTodoCard(
      todosAsync: todosAsync,
      pendingTodos: pendingTodos,
      onCreate: () => TodoEditorDialog.show(context, initialDate: today),
      onCreateInQuadrant: (TodoPriorityQuadrant quadrant) =>
          TodoEditorDialog.show(
            context,
            initialDate: today,
            initialPriorityQuadrant: quadrant,
          ),
      onOpenQuadrant: (TodoPriorityQuadrant quadrant) =>
          context.go('/todos?quadrant=${quadrant.value}'),
      onToggle: (TodoRecord todo, bool value) =>
          _setTodoCompleted(ref, todo, value),
    );
    // 今日脉络卡。
    final Widget contextCard = _TodayContextCard(colors: colors);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 当前是否运行在桌面端。
        final bool isDesktopPlatform = OmniBreakpoint.isDesktopPlatform(
          Theme.of(context).platform,
        );
        // 当前是否使用移动端纵向内容流。
        final bool useMobileFlow =
            !isDesktopPlatform &&
            OmniBreakpoint.isCompact(constraints.maxWidth);

        if (useMobileFlow) {
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              OmniSpacing.xs,
              OmniSpacing.xs,
              OmniSpacing.xs,
              OmniSpacing.md,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                quoteCard,
                const SizedBox(height: OmniSpacing.xs),
                dayRuler,
                const SizedBox(height: OmniSpacing.xs),
                todoCard,
                const SizedBox(height: OmniSpacing.xs),
                contextCard,
              ],
            ),
          );
        }

        // 桌面内容可用高度。
        final double contentHeight = math.max(constraints.maxHeight - 48, 0);
        // 当前是否有足够的整窗宽度显示次要脉络面板。
        final bool showContext = MediaQuery.sizeOf(context).width >= 1320;
        // 当前高度是否足以显示名言横幅。
        final bool showQuote = contentHeight >= 560;
        // 当前高度是否足以显示时间刻度。
        final bool showRuler = contentHeight >= 320;
        // 根据窗口高度平滑调整名言横幅高度。
        final double quoteHeight = math.min(
          174,
          math.max(144, contentHeight * 0.2),
        );
        // 右侧脉络面板宽度，宽屏增长但不超过阅读上限。
        final double contextWidth = math.min(
          380,
          math.max(320, constraints.maxWidth * 0.28),
        );

        return Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: OmniSpacing.sm,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (showQuote) ...<Widget>[
                      SizedBox(
                        height: quoteHeight,
                        child: _QuoteHero(
                          quoteAsync: quoteAsync,
                          dense: true,
                          onManage: () => QuoteLibraryDialog.show(context),
                          onBackground: () => AttachmentPickerDialog.show(
                            context,
                            businessType: AttachmentBusinessType.quoteBanner,
                            businessId: 'home-banner',
                            title: '首页横幅背景',
                            cropAspectRatio: 3.0,
                          ),
                          onChange: () async {
                            await ref
                                .read(appDatabaseProvider)
                                .changeQuoteForDay(today);
                            ref.invalidate(quoteForDayProvider(today));
                          },
                        ),
                      ),
                      const SizedBox(height: OmniSpacing.xs),
                    ],
                    if (showRuler) ...<Widget>[
                      SizedBox(height: 86, child: dayRuler),
                      const SizedBox(height: OmniSpacing.xs),
                    ],
                    Expanded(
                      child: _TodayTodoCard(
                        todosAsync: todosAsync,
                        pendingTodos: pendingTodos,
                        fillHeight: true,
                        onCreate: () =>
                            TodoEditorDialog.show(context, initialDate: today),
                        onCreateInQuadrant: (TodoPriorityQuadrant quadrant) =>
                            TodoEditorDialog.show(
                              context,
                              initialDate: today,
                              initialPriorityQuadrant: quadrant,
                            ),
                        onOpenQuadrant: (TodoPriorityQuadrant quadrant) =>
                            context.go('/todos?quadrant=${quadrant.value}'),
                        onToggle: (TodoRecord todo, bool value) =>
                            _setTodoCompleted(ref, todo, value),
                      ),
                    ),
                  ],
                ),
              ),
              if (showContext) ...<Widget>[
                const SizedBox(width: OmniSpacing.xs),
                SizedBox(width: contextWidth, child: contextCard),
              ],
            ],
          ),
        );
      },
    );
  }

  /// 更新首页待办完成状态。
  Future<void> _setTodoCompleted(
    WidgetRef ref,
    TodoRecord todo,
    bool completed,
  ) => ref.read(todoRepositoryProvider).setCompleted(todo.id, completed);
}

/// 每日名言横幅。
class _QuoteHero extends ConsumerWidget {
  /// 今日名言异步状态。
  final AsyncValue<QuoteRecord> quoteAsync;

  /// 手动换一条回调。
  final Future<void> Function() onChange;

  /// 打开名言库回调。
  final VoidCallback onManage;

  /// 管理横幅背景回调。
  final VoidCallback onBackground;

  /// 是否使用桌面分栏中的紧凑样式。
  final bool dense;

  /// 创建每日名言横幅。
  const _QuoteHero({
    required this.quoteAsync,
    required this.onChange,
    required this.onManage,
    required this.onBackground,
    this.dense = false,
  });

  /// 构建具有时间流动感的名言区域。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前横幅附件。
    final Attachment? banner = ref
        .watch(
          currentAttachmentProvider((
            AttachmentBusinessType.quoteBanner,
            'home-banner',
          )),
        )
        .asData
        ?.value;
    // 当前可读本地背景路径。
    final String? backgroundPath = banner?.localPath;
    // 当前名言内容。
    final Widget quoteContent = quoteAsync.when(
      data: (QuoteRecord quote) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            '“${quote.content}”',
            maxLines: dense ? 2 : null,
            overflow: dense ? TextOverflow.ellipsis : TextOverflow.visible,
            style: TextStyle(
              color: colors.heroInk,
              fontSize: dense ? 18 : 20,
              height: dense ? 1.35 : 1.45,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: dense ? 2 : OmniSpacing.sm),
          Text(
            '— ${quote.source ?? '未署名'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: TextStyle(
              color: colors.heroInk.withValues(alpha: 0.84),
              fontSize: dense ? 12 : 13,
            ),
          ),
        ],
      ),
      loading: () => LinearProgressIndicator(
        color: colors.heroInk,
        backgroundColor: colors.heroInk.withValues(alpha: 0.15),
      ),
      error: (Object error, StackTrace stackTrace) =>
          Text('名言暂时无法读取', style: TextStyle(color: colors.heroInk)),
    );

    return Container(
      key: const ValueKey<String>('home-quote-card'),
      constraints: BoxConstraints(minHeight: dense ? 0 : 156),
      padding: dense
          ? const EdgeInsets.fromLTRB(18, 12, 12, 12)
          : const EdgeInsets.all(OmniSpacing.lg),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[colors.heroStart, colors.heroEnd],
        ),
        borderRadius: BorderRadius.circular(OmniRadius.dialog),
        border: Border.all(color: colors.brand.withValues(alpha: 0.24)),
        image: backgroundPath == null
            ? null
            : DecorationImage(
                image: FileImage(File(backgroundPath)),
                fit: BoxFit.cover,
                colorFilter: ColorFilter.mode(
                  Colors.black.withValues(alpha: 0.42),
                  BlendMode.darken,
                ),
                onError: (_, _) {},
              ),
      ),
      child: Stack(
        children: <Widget>[
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Spacer(),
                  IconButton(
                    tooltip: '名言库',
                    onPressed: onManage,
                    color: colors.heroInk,
                    icon: const Icon(Icons.library_books_outlined),
                  ),
                  IconButton(
                    tooltip: '设置横幅背景',
                    onPressed: onBackground,
                    color: colors.heroInk,
                    constraints: dense
                        ? const BoxConstraints.tightFor(width: 32, height: 32)
                        : null,
                    padding: dense ? EdgeInsets.zero : null,
                    visualDensity: dense ? VisualDensity.compact : null,
                    icon: const Icon(Icons.wallpaper_rounded),
                  ),
                  IconButton(
                    tooltip: '换一条',
                    onPressed: onChange,
                    color: colors.heroInk,
                    constraints: dense
                        ? const BoxConstraints.tightFor(width: 32, height: 32)
                        : null,
                    padding: dense ? EdgeInsets.zero : null,
                    visualDensity: dense ? VisualDensity.compact : null,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
              SizedBox(height: dense ? 4 : OmniSpacing.md),
              quoteContent,
            ],
          ),
        ],
      ),
    );
  }
}

/// 当日真实时间刻度。
class _DayRuler extends StatelessWidget {
  /// 当前时间。
  final DateTime now;

  /// 创建当日时间刻度。
  const _DayRuler({required this.now});

  /// 构建当天已过去比例。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 今日自然日。
    final DateTime today = DateUtils.dateOnly(now);
    // 星期中文名称。
    final String weekday = const <String>[
      '星期一',
      '星期二',
      '星期三',
      '星期四',
      '星期五',
      '星期六',
      '星期日',
    ][today.weekday - 1];
    // 今日完整日期标签。
    final String dateLabel =
        '${DateFormat('yyyy年M月d日').format(today)} · $weekday';
    // 今日已经过去的分钟数。
    final int elapsedMinutes = now.hour * 60 + now.minute;
    // 今日时间进度。
    final double progress = elapsedMinutes / 1440;

    return OmniPanel(
      key: const ValueKey<String>('home-day-ruler'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 7),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text('今日刻度', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(width: OmniSpacing.xs),
              Expanded(
                child: Text(
                  dateLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.muted, fontSize: 11),
                ),
              ),
              const SizedBox(width: OmniSpacing.xs),
              Text(
                '${(progress * 100).round()}% 已经过',
                style: TextStyle(color: colors.muted, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(OmniRadius.tiny),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              color: colors.accent,
              backgroundColor: colors.mist,
            ),
          ),
          const SizedBox(height: 3),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text('00:00', style: Theme.of(context).textTheme.bodySmall),
              Text(
                DateFormat('HH:mm').format(now),
                style: TextStyle(
                  color: colors.accent,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
              Text('24:00', style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ],
      ),
    );
  }
}

/// 今日待办摘要卡。
class _TodayTodoCard extends StatefulWidget {
  /// 今日待办异步状态。
  final AsyncValue<List<TodoRecord>> todosAsync;

  /// 今日未完成待办。
  final List<TodoRecord> pendingTodos;

  /// 新增回调。
  final VoidCallback onCreate;

  /// 在指定象限新增回调。
  final ValueChanged<TodoPriorityQuadrant> onCreateInQuadrant;

  /// 查看指定象限回调。
  final ValueChanged<TodoPriorityQuadrant> onOpenQuadrant;

  /// 完成状态变化回调。
  final Future<void> Function(TodoRecord todo, bool value) onToggle;

  /// 是否填满桌面左栏分配的高度。
  final bool fillHeight;

  /// 创建今日待办摘要卡。
  const _TodayTodoCard({
    required this.todosAsync,
    required this.pendingTodos,
    required this.onCreate,
    required this.onCreateInQuadrant,
    required this.onOpenQuadrant,
    required this.onToggle,
    this.fillHeight = false,
  });

  /// 创建今日待办摘要卡状态。
  @override
  State<_TodayTodoCard> createState() => _TodayTodoCardState();
}

/// 今日待办摘要卡状态。
class _TodayTodoCardState extends State<_TodayTodoCard> {
  /// 当前可撤销的已完成待办。
  TodoRecord? _undoTodo;

  /// 撤销横幅自动关闭计时器。
  Timer? _undoTimer;

  /// 完成任务并在模块内展示撤销入口。
  Future<void> _completeTodo(TodoRecord todo) async {
    await widget.onToggle(todo, true);
    if (!mounted) {
      return;
    }
    _undoTimer?.cancel();
    setState(() => _undoTodo = todo);
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
    await widget.onToggle(todo, false);
    if (mounted && _undoTodo?.id == todo.id) {
      setState(() => _undoTodo = null);
    }
  }

  /// 关闭模块内撤销横幅。
  void _dismissUndo() {
    _undoTimer?.cancel();
    if (mounted && _undoTodo != null) {
      setState(() => _undoTodo = null);
    }
  }

  /// 释放撤销横幅计时器。
  @override
  void dispose() {
    _undoTimer?.cancel();
    super.dispose();
  }

  /// 构建今日优先待办。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 待办列表或状态内容。
    final Widget todoContent = _buildTodoContent(context, colors);
    // 当前可撤销的已完成待办。
    final TodoRecord? undoTodo = _undoTodo;
    // 当前是否关闭非必要动画。
    final bool disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    return OmniPanel(
      key: const ValueKey<String>('home-todo-card'),
      padding: const EdgeInsets.all(OmniSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: colors.todo.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(OmniRadius.control),
                ),
                child: Icon(
                  Icons.check_circle_outline_rounded,
                  color: colors.todo,
                  size: 19,
                ),
              ),
              const SizedBox(width: 10),
              Text('今日待办', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(width: OmniSpacing.xs),
              OmniButton(
                label: '新增待办',
                icon: Icons.add_rounded,
                onPressed: widget.onCreate,
              ),
              const Spacer(),
              OmniTag(
                label: '${widget.pendingTodos.length} 项未完成',
                color: colors.todo,
              ),
            ],
          ),
          AnimatedSize(
            duration: disableAnimations ? Duration.zero : OmniMotion.normal,
            curve: OmniMotion.standardCurve,
            child: undoTodo == null
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(top: OmniSpacing.xs),
                    child: _HomeTodoUndoBanner(
                      key: ValueKey<String>('home-todo-undo-${undoTodo.id}'),
                      todo: undoTodo,
                      onUndo: () => unawaited(_undoCompletion()),
                      onDismiss: _dismissUndo,
                    ),
                  ),
          ),
          const SizedBox(height: 14),
          if (widget.fillHeight) Expanded(child: todoContent) else todoContent,
        ],
      ),
    );
  }

  /// 构建待办列表、加载状态或空状态。
  Widget _buildTodoContent(BuildContext context, OmniColors colors) {
    if (widget.todosAsync.isLoading) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (widget.todosAsync.hasError) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text('待办暂时无法读取', style: TextStyle(color: colors.danger)),
      );
    }
    // 按象限分组后的今日待办。
    final Map<TodoPriorityQuadrant, List<TodoRecord>> groupedTodos =
        <TodoPriorityQuadrant, List<TodoRecord>>{
          for (final TodoPriorityQuadrant quadrant
              in todoPriorityQuadrantMatrixOrder)
            quadrant: <TodoRecord>[],
        };
    for (final TodoRecord todo in widget.pendingTodos) {
      // 当前待办所属象限。
      final TodoPriorityQuadrant quadrant = TodoPriorityQuadrant.fromValue(
        todo.priorityQuadrant,
      );
      groupedTodos[quadrant]!.add(todo);
    }
    // 当前是否运行在桌面端。
    final bool isDesktopPlatform = OmniBreakpoint.isDesktopPlatform(
      Theme.of(context).platform,
    );
    // 移动平台使用纵向象限，确保任务标题与触控区域不被压缩。
    final bool useVerticalQuadrants = !isDesktopPlatform;

    if (useVerticalQuadrants) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (
            int index = 0;
            index < todoPriorityQuadrantMatrixOrder.length;
            index += 1
          ) ...<Widget>[
            if (index > 0) const SizedBox(height: OmniSpacing.xs),
            _HomeTodoQuadrant(
              quadrant: todoPriorityQuadrantMatrixOrder[index],
              todos: groupedTodos[todoPriorityQuadrantMatrixOrder[index]]!,
              fillHeight: false,
              onCreate: () => widget.onCreateInQuadrant(
                todoPriorityQuadrantMatrixOrder[index],
              ),
              onOpen: () =>
                  widget.onOpenQuadrant(todoPriorityQuadrantMatrixOrder[index]),
              onToggle: (TodoRecord todo, bool value) =>
                  value ? _completeTodo(todo) : widget.onToggle(todo, false),
            ),
          ],
        ],
      );
    }

    return Column(
      children: <Widget>[
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (int index = 0; index < 2; index += 1) ...<Widget>[
                if (index > 0) const SizedBox(width: OmniSpacing.xs),
                Expanded(
                  child: _HomeTodoQuadrant(
                    quadrant: todoPriorityQuadrantMatrixOrder[index],
                    todos:
                        groupedTodos[todoPriorityQuadrantMatrixOrder[index]]!,
                    fillHeight: widget.fillHeight,
                    onCreate: () => widget.onCreateInQuadrant(
                      todoPriorityQuadrantMatrixOrder[index],
                    ),
                    onOpen: () => widget.onOpenQuadrant(
                      todoPriorityQuadrantMatrixOrder[index],
                    ),
                    onToggle: (TodoRecord todo, bool value) => value
                        ? _completeTodo(todo)
                        : widget.onToggle(todo, false),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: OmniSpacing.xs),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (int index = 2; index < 4; index += 1) ...<Widget>[
                if (index > 2) const SizedBox(width: OmniSpacing.xs),
                Expanded(
                  child: _HomeTodoQuadrant(
                    quadrant: todoPriorityQuadrantMatrixOrder[index],
                    todos:
                        groupedTodos[todoPriorityQuadrantMatrixOrder[index]]!,
                    fillHeight: widget.fillHeight,
                    onCreate: () => widget.onCreateInQuadrant(
                      todoPriorityQuadrantMatrixOrder[index],
                    ),
                    onOpen: () => widget.onOpenQuadrant(
                      todoPriorityQuadrantMatrixOrder[index],
                    ),
                    onToggle: (TodoRecord todo, bool value) => value
                        ? _completeTodo(todo)
                        : widget.onToggle(todo, false),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 首页今日待办卡中的单个象限摘要。
class _HomeTodoQuadrant extends StatelessWidget {
  /// 当前象限。
  final TodoPriorityQuadrant quadrant;

  /// 当前象限全部未完成待办。
  final List<TodoRecord> todos;

  /// 是否填满桌面网格高度。
  final bool fillHeight;

  /// 新增回调。
  final VoidCallback onCreate;

  /// 查看当前象限回调。
  final VoidCallback onOpen;

  /// 完成状态变化回调。
  final Future<void> Function(TodoRecord todo, bool value) onToggle;

  /// 创建首页象限摘要。
  const _HomeTodoQuadrant({
    required this.quadrant,
    required this.todos,
    required this.fillHeight,
    required this.onCreate,
    required this.onOpen,
    required this.onToggle,
  });

  /// 构建最多展示三条任务的象限摘要。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前象限强调色。
    final Color accentColor = quadrant.color(colors);
    // 浅色主题使用白色象限表面，避免大面积灰底压迫内容。
    final Color quadrantSurface =
        Theme.of(context).brightness == Brightness.light
        ? colors.paper
        : colors.paperSubtle;
    // 按截止时间与用户顺序整理后的象限待办。
    final List<TodoRecord> sortedTodos = List<TodoRecord>.of(todos)
      ..sort(_compareTodoPriority);
    // 首页当前象限最多展示的三条待办。
    final List<TodoRecord> visibleTodos = sortedTodos
        .take(3)
        .toList(growable: false);
    // 未直接展示的待办数量。
    final int hiddenCount = todos.length - visibleTodos.length;
    // 当前象限任务内容。
    final Widget todoContent = visibleTodos.isEmpty
        ? _buildEmptyState(context, accentColor)
        : _buildTodoList(context, visibleTodos, hiddenCount);

    return Container(
      key: ValueKey<String>('home-todo-quadrant-${quadrant.value}'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: quadrantSurface,
        borderRadius: BorderRadius.circular(OmniRadius.control),
        border: Border.all(color: colors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(height: 3, color: accentColor),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onOpen,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  OmniSpacing.sm,
                  OmniSpacing.xs,
                  OmniSpacing.xs,
                  OmniSpacing.xs,
                ),
                child: Row(
                  children: <Widget>[
                    Icon(quadrant.icon, size: 15, color: accentColor),
                    const SizedBox(width: OmniSpacing.xs),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            quadrant.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            quadrant.actionLabel,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: accentColor),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      '${todos.length}',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: accentColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded, color: colors.muted),
                  ],
                ),
              ),
            ),
          ),
          if (fillHeight) Expanded(child: todoContent) else todoContent,
        ],
      ),
    );
  }

  /// 构建当前象限的任务列表。
  Widget _buildTodoList(
    BuildContext context,
    List<TodoRecord> visibleTodos,
    int hiddenCount,
  ) {
    // 带分隔线的任务列表内容。
    final List<Widget> children = <Widget>[];
    for (int index = 0; index < visibleTodos.length; index += 1) {
      if (index > 0) {
        children.add(const Divider(indent: 40));
      }
      // 当前任务。
      final TodoRecord todo = visibleTodos[index];
      children.add(
        _HomeTodoRow(
          key: ValueKey<String>('home-todo-row-${todo.id}'),
          todo: todo,
          accentColor: quadrant.color(OmniColors.of(context)),
          onComplete: (TodoRecord currentTodo) => onToggle(currentTodo, true),
        ),
      );
    }
    if (hiddenCount > 0) {
      children.add(
        TextButton(onPressed: onOpen, child: Text('还有 $hiddenCount 项')),
      );
    }
    return fillHeight
        ? ListView(padding: EdgeInsets.zero, children: children)
        : Column(mainAxisSize: MainAxisSize.min, children: children);
  }

  /// 构建当前象限的紧凑空状态。
  Widget _buildEmptyState(BuildContext context, Color accentColor) {
    return TextButton.icon(
      onPressed: onCreate,
      icon: Icon(Icons.add_rounded, size: 16, color: accentColor),
      label: Text('新增任务', style: TextStyle(color: accentColor)),
    );
  }

  /// 比较首页同一象限内待办的展示顺序。
  int _compareTodoPriority(TodoRecord left, TodoRecord right) {
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
}

/// 首页任务完成时的分阶段反馈行。
class _HomeTodoRow extends StatefulWidget {
  /// 当前任务。
  final TodoRecord todo;

  /// 当前任务所属象限强调色。
  final Color accentColor;

  /// 完成动画结束后的提交回调。
  final Future<void> Function(TodoRecord todo) onComplete;

  /// 创建首页任务反馈行。
  const _HomeTodoRow({
    required this.todo,
    required this.accentColor,
    required this.onComplete,
    super.key,
  });

  /// 创建首页任务反馈行状态。
  @override
  State<_HomeTodoRow> createState() => _HomeTodoRowState();
}

/// 首页任务反馈行状态。
class _HomeTodoRowState extends State<_HomeTodoRow> {
  /// 是否已经呈现勾选状态。
  bool _checked = false;

  /// 是否已经进入淡出阶段。
  bool _fading = false;

  /// 是否已经进入收起阶段。
  bool _collapsed = false;

  /// 是否正在提交完成操作。
  bool _submitting = false;

  /// 依次播放勾选、淡出与收起动画，再提交完成状态。
  Future<void> _complete() async {
    if (_submitting) {
      return;
    }
    // 当前是否关闭非必要动画。
    final bool disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    // 勾选反馈停留时长。
    final Duration checkDuration = disableAnimations
        ? Duration.zero
        : OmniMotion.normal;
    // 淡出反馈时长。
    final Duration fadeDuration = disableAnimations
        ? Duration.zero
        : OmniMotion.normal;
    // 高度收起时长。
    final Duration collapseDuration = disableAnimations
        ? Duration.zero
        : OmniMotion.panel;

    setState(() {
      _submitting = true;
      _checked = true;
    });
    await Future<void>.delayed(checkDuration);
    if (!mounted) {
      return;
    }
    setState(() => _fading = true);
    await Future<void>.delayed(fadeDuration);
    if (!mounted) {
      return;
    }
    setState(() => _collapsed = true);
    await Future<void>.delayed(collapseDuration);
    if (!mounted) {
      return;
    }

    try {
      await widget.onComplete(widget.todo);
    } catch (_) {
      if (mounted) {
        setState(() {
          _checked = false;
          _fading = false;
          _collapsed = false;
          _submitting = false;
        });
      }
      rethrow;
    }
  }

  /// 构建带完成反馈的任务行。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前是否关闭非必要动画。
    final bool disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    // 当前淡出动画时长。
    final Duration fadeDuration = disableAnimations
        ? Duration.zero
        : OmniMotion.normal;
    // 当前收起动画时长。
    final Duration collapseDuration = disableAnimations
        ? Duration.zero
        : OmniMotion.panel;

    return AnimatedSize(
      duration: collapseDuration,
      curve: OmniMotion.standardCurve,
      alignment: Alignment.topCenter,
      child: _collapsed
          ? const SizedBox.shrink()
          : AnimatedSlide(
              offset: _fading ? const Offset(0.04, 0) : Offset.zero,
              duration: fadeDuration,
              curve: OmniMotion.standardCurve,
              child: AnimatedOpacity(
                opacity: _fading ? 0 : 1,
                duration: fadeDuration,
                curve: OmniMotion.standardCurve,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _submitting ? null : () => unawaited(_complete()),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: OmniSpacing.xs,
                        vertical: OmniSpacing.xxs,
                      ),
                      child: Row(
                        children: <Widget>[
                          SizedBox(
                            width: 32,
                            height: 32,
                            child: Center(
                              child: _HomeTodoCheckIndicator(
                                checked: _checked,
                                accentColor: widget.accentColor,
                              ),
                            ),
                          ),
                          const SizedBox(width: OmniSpacing.xxs),
                          Expanded(
                            child: AnimatedDefaultTextStyle(
                              duration: disableAnimations
                                  ? Duration.zero
                                  : OmniMotion.fast,
                              curve: OmniMotion.standardCurve,
                              style: TextStyle(
                                color: _checked ? colors.muted : colors.ink,
                                fontWeight: FontWeight.w500,
                                decoration: _checked
                                    ? TextDecoration.lineThrough
                                    : TextDecoration.none,
                              ),
                              child: Text(
                                widget.todo.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

/// 首页任务的自定义勾选反馈。
class _HomeTodoCheckIndicator extends StatelessWidget {
  /// 是否处于完成状态。
  final bool checked;

  /// 当前任务所属象限强调色。
  final Color accentColor;

  /// 创建首页任务勾选反馈。
  const _HomeTodoCheckIndicator({
    required this.checked,
    required this.accentColor,
  });

  /// 构建带填色与勾号缩放效果的方形指示器。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前是否关闭非必要动画。
    final bool disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    // 勾选状态切换时长。
    final Duration duration = disableAnimations
        ? Duration.zero
        : OmniMotion.fast;

    return AnimatedScale(
      scale: checked ? 1.08 : 1,
      duration: duration,
      curve: Curves.easeOutBack,
      child: AnimatedContainer(
        width: 18,
        height: 18,
        duration: duration,
        curve: OmniMotion.standardCurve,
        decoration: BoxDecoration(
          color: checked ? accentColor : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: checked ? accentColor : colors.muted.withValues(alpha: 0.72),
            width: checked ? 1.5 : 1,
          ),
          boxShadow: checked
              ? <BoxShadow>[
                  BoxShadow(
                    color: accentColor.withValues(alpha: 0.22),
                    blurRadius: 6,
                    spreadRadius: 1,
                  ),
                ]
              : const <BoxShadow>[],
        ),
        child: AnimatedOpacity(
          key: const ValueKey<String>('home-todo-check-mark'),
          opacity: checked ? 1 : 0,
          duration: duration,
          curve: OmniMotion.standardCurve,
          child: AnimatedScale(
            scale: checked ? 1 : 0.45,
            duration: duration,
            curve: Curves.easeOutBack,
            child: const Icon(
              Icons.check_rounded,
              size: 14,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

/// 今日待办模块内部的完成撤销横幅。
class _HomeTodoUndoBanner extends StatelessWidget {
  /// 刚完成的待办。
  final TodoRecord todo;

  /// 撤销完成操作回调。
  final VoidCallback onUndo;

  /// 关闭横幅回调。
  final VoidCallback onDismiss;

  /// 创建模块内撤销横幅。
  const _HomeTodoUndoBanner({
    required this.todo,
    required this.onUndo,
    required this.onDismiss,
    super.key,
  });

  /// 构建紧凑且不遮挡象限内容的横幅。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);

    return Container(
      key: const ValueKey<String>('home-todo-undo-banner'),
      constraints: const BoxConstraints(minHeight: 40),
      padding: const EdgeInsets.only(left: OmniSpacing.sm),
      decoration: BoxDecoration(
        color: colors.success.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(OmniRadius.control),
        border: Border.all(color: colors.success.withValues(alpha: 0.24)),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.check_circle_rounded, size: 18, color: colors.success),
          const SizedBox(width: OmniSpacing.xs),
          Expanded(
            child: Text(
              '已完成“${todo.title}”',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.ink, fontWeight: FontWeight.w500),
            ),
          ),
          TextButton(onPressed: onUndo, child: const Text('撤销')),
          IconButton(
            tooltip: '关闭提示',
            onPressed: onDismiss,
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.close_rounded, size: 18, color: colors.muted),
          ),
        ],
      ),
    );
  }
}

/// 今日跨模块脉络卡。
class _TodayContextCard extends StatelessWidget {
  /// 当前主题语义色。
  final OmniColors colors;

  /// 创建今日脉络卡。
  const _TodayContextCard({required this.colors});

  /// 构建其他模块的首版入口与空状态。
  @override
  Widget build(BuildContext context) {
    return OmniPanel(
      key: const ValueKey<String>('home-context-card'),
      padding: const EdgeInsets.all(OmniSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('今日脉络', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            '把到期、记录与空白放在同一条时间线上。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 22),
          _ContextItem(
            icon: Icons.event_repeat_rounded,
            color: colors.event,
            title: '周期事件',
            detail: '暂无即将到期事件',
            onTap: () => context.go('/events'),
          ),
          Divider(color: colors.line),
          _ContextItem(
            icon: Icons.view_timeline_rounded,
            color: colors.time,
            title: '时间记录',
            detail: '今天尚未记录时间',
            onTap: () => context.go('/timeline'),
          ),
          Divider(color: colors.line),
          _ContextItem(
            icon: Icons.loyalty_rounded,
            color: colors.member,
            title: '会员提醒',
            detail: '暂无近期续费',
            onTap: () => context.go('/memberships'),
          ),
        ],
      ),
    );
  }
}

/// 今日脉络单项。
class _ContextItem extends StatelessWidget {
  /// 模块图标。
  final IconData icon;

  /// 模块颜色。
  final Color color;

  /// 模块标题。
  final String title;

  /// 模块摘要。
  final String detail;

  /// 打开模块回调。
  final VoidCallback onTap;

  /// 创建今日脉络单项。
  const _ContextItem({
    required this.icon,
    required this.color,
    required this.title,
    required this.detail,
    required this.onTap,
  });

  /// 构建模块摘要入口。
  @override
  Widget build(BuildContext context) {
    return OmniListRow(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(vertical: OmniSpacing.xs),
      leading: Icon(icon, color: color, size: OmniSize.navigationIcon),
      title: Text(title),
      subtitle: Text(detail),
      trailing: const Icon(Icons.chevron_right_rounded, size: OmniSize.icon),
    );
  }
}
