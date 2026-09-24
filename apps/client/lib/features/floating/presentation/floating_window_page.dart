import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/settings/data/feature_preferences.dart';
import 'package:omni_butler/features/timeline/data/time_entry_repository.dart';
import 'package:omni_butler/features/timeline/presentation/timeline_page.dart';
import 'package:omni_butler/features/todos/data/todo_priority_quadrant.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:omni_butler/features/todos/presentation/todo_editor_dialog.dart';
import 'package:omni_butler/features/todos/presentation/todo_priority_quadrant_style.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 悬浮框请求显示主窗口指定路由的回调。
typedef FloatingRouteCallback = Future<void> Function(String location);

/// 悬浮窗当前展开的快速录入类型。
enum _FloatingComposerMode {
  /// 新增今日待办。
  todo,

  /// 开始进行中时间记录。
  startTime,

  /// 补记已经完成的时间记录。
  backfillTime,
}

/// 悬浮窗单个待办项的固定高度。
const double floatingTodoRowHeight = 32;

/// 悬浮窗单个象限最多直接展示的待办项数量。
const int floatingTodoMaxVisibleRows = 5;

/// 悬浮窗内容允许增长到的最大逻辑高度。
const double floatingWindowMaxContentHeight = 900;

/// 根据任务项数量计算象限列表视口高度。
double calculateFloatingTodoViewportHeight(int taskRowCount) {
  // 至少展示一个任务项、最多展示五个任务项。
  final int visibleRows = taskRowCount.clamp(1, floatingTodoMaxVisibleRows);
  return visibleRows * floatingTodoRowHeight;
}

/// Windows 桌面悬浮框的业务内容。
class FloatingWindowPage extends ConsumerStatefulWidget {
  /// 关闭悬浮框功能的回调。
  final Future<void> Function() onClose;

  /// 显示主窗口并打开指定路由的回调。
  final FloatingRouteCallback onOpenRoute;

  /// 开始拖动窗口的回调。
  final VoidCallback onDragStart;

  /// 更新窗口拖动位置的回调。
  final VoidCallback onDragUpdate;

  /// 结束拖动并保存位置的回调。
  final Future<void> Function() onDragEnd;

  /// 内容期望高度变化回调。
  final ValueChanged<double> onPreferredHeightChanged;

  /// 创建 Windows 桌面悬浮框。
  const FloatingWindowPage({
    required this.onClose,
    required this.onOpenRoute,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onPreferredHeightChanged,
    super.key,
  });

  /// 创建悬浮框页面状态。
  @override
  ConsumerState<FloatingWindowPage> createState() => _FloatingWindowPageState();
}

/// 管理悬浮框中的待办完成反馈。
class _FloatingWindowPageState extends ConsumerState<FloatingWindowPage> {
  /// 当前撤销浮动消息。
  OmniMessageHandle? _undoMessage;

  /// 用于测量玻璃主体自然高度的全局键。
  final GlobalKey _contentKey = GlobalKey();

  /// 最近一次上报的内容高度。
  double? _lastReportedHeight;

  /// 当前展开的快速录入区。
  _FloatingComposerMode? _composerMode;

  /// 展开指定快速录入区。
  void _openComposer(_FloatingComposerMode mode) {
    setState(() => _composerMode = mode);
  }

  /// 收起当前快速录入区。
  void _closeComposer() {
    setState(() => _composerMode = null);
  }

  /// 在布局完成后上报玻璃主体的自然高度。
  void _reportPreferredHeight() {
    // 当前玻璃主体渲染对象。
    final RenderBox? renderBox =
        _contentKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) {
      return;
    }
    // 向上取整后的期望窗口高度。
    final double preferredHeight = renderBox.size.height.ceilToDouble();
    if (_lastReportedHeight != null &&
        (_lastReportedHeight! - preferredHeight).abs() < 0.5) {
      return;
    }
    _lastReportedHeight = preferredHeight;
    widget.onPreferredHeightChanged(preferredHeight);
  }

  /// 完成指定待办并提供六秒撤销入口。
  Future<void> _completeTodo(TodoRecord todo) async {
    try {
      await ref.read(todoRepositoryProvider).setCompleted(todo.id, true);
    } catch (_) {
      if (mounted) {
        showOmniMessage(
          context,
          message: '待办保存失败，请重试',
          tone: OmniMessageTone.error,
        );
      }
      return;
    }
    if (!mounted) {
      return;
    }
    _undoMessage?.dismiss();
    _undoMessage = showOmniMessage(
      context,
      message: '已完成“${todo.title}”',
      tone: OmniMessageTone.success,
      duration: const Duration(seconds: 6),
      actionLabel: '撤销',
      onAction: () => unawaited(
        ref.read(todoRepositoryProvider).setCompleted(todo.id, false),
      ),
      onDismissed: () => _undoMessage = null,
    );
  }

  /// 释放尚未关闭的撤销消息。
  @override
  void dispose() {
    _undoMessage?.dismiss();
    super.dispose();
  }

  /// 构建半透明卡片、待办分区与时间操作区。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前设备业务功能偏好。
    final FeaturePreference featurePreference = ref.watch(
      featurePreferenceProvider,
    );
    // 当前时间。
    final DateTime now = ref.watch(nowProvider);
    // 今日自然日。
    final DateTime today = DateUtils.dateOnly(now);
    // 今日待办功能是否可用。
    final bool todoEnabled = featurePreference.isEnabled(AppFeature.todos);
    // 时间管理功能是否可用。
    final bool timelineEnabled = featurePreference.isEnabled(
      AppFeature.timeline,
    );
    // 当前是否使用深色主题。
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    // 均匀的半透明玻璃主体色。
    final Color glassSurface = isDark
        ? const Color(0xB8182233)
        : const Color(0xA8EAF0F6);
    // 玻璃主体高光边框色。
    final Color glassBorder = isDark
        ? Colors.white.withValues(alpha: 0.18)
        : Colors.white.withValues(alpha: 0.72);

    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted) {
        _reportPreferredHeight();
      }
    });

    return Material(
      type: MaterialType.transparency,
      child: OverflowBox(
        alignment: Alignment.topCenter,
        minHeight: 0,
        maxHeight: double.infinity,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxHeight: floatingWindowMaxContentHeight,
          ),
          child: SingleChildScrollView(
            key: _contentKey,
            primary: false,
            child: Padding(
              padding: const EdgeInsets.all(OmniSpacing.xs),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: glassSurface,
                  border: Border.all(color: glassBorder),
                  borderRadius: BorderRadius.circular(OmniRadius.dialog),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: isDark ? 0.30 : 0.18,
                      ),
                      blurRadius: 24,
                      spreadRadius: -4,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(OmniRadius.dialog),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _FloatingTitleBar(
                          now: now,
                          onClose: widget.onClose,
                          onDragStart: widget.onDragStart,
                          onDragUpdate: widget.onDragUpdate,
                          onDragEnd: widget.onDragEnd,
                        ),
                        Divider(
                          height: 1,
                          color: colors.line.withValues(alpha: 0.72),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(
                            OmniSpacing.md,
                            OmniSpacing.sm,
                            OmniSpacing.md,
                            OmniSpacing.md,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              if (todoEnabled)
                                _FloatingTodos(
                                  today: today,
                                  onComplete: _completeTodo,
                                  onOpenRoute: widget.onOpenRoute,
                                  onToggleComposer:
                                      _composerMode ==
                                          _FloatingComposerMode.todo
                                      ? _closeComposer
                                      : () => _openComposer(
                                          _FloatingComposerMode.todo,
                                        ),
                                  composer:
                                      _composerMode ==
                                          _FloatingComposerMode.todo
                                      ? _FloatingTodoComposer(
                                          today: today,
                                          onClose: _closeComposer,
                                        )
                                      : null,
                                ),
                              if (todoEnabled && timelineEnabled) ...<Widget>[
                                const SizedBox(height: OmniSpacing.sm),
                                Divider(
                                  height: 1,
                                  color: colors.line.withValues(alpha: 0.64),
                                ),
                                const SizedBox(height: OmniSpacing.sm),
                              ],
                              if (timelineEnabled)
                                _FloatingTimeStatus(
                                  onOpenRoute: widget.onOpenRoute,
                                  onStart: () => _openComposer(
                                    _FloatingComposerMode.startTime,
                                  ),
                                  onBackfill: () => _openComposer(
                                    _FloatingComposerMode.backfillTime,
                                  ),
                                  composer:
                                      _composerMode ==
                                          _FloatingComposerMode.startTime
                                      ? _FloatingTimeComposer(
                                          key: const ValueKey<String>(
                                            'floating-start-composer',
                                          ),
                                          mode: _FloatingTimeComposerMode.start,
                                          day: now,
                                          onClose: _closeComposer,
                                        )
                                      : _composerMode ==
                                            _FloatingComposerMode.backfillTime
                                      ? _FloatingTimeComposer(
                                          key: const ValueKey<String>(
                                            'floating-backfill-composer',
                                          ),
                                          mode: _FloatingTimeComposerMode
                                              .backfill,
                                          day: now,
                                          onClose: _closeComposer,
                                        )
                                      : null,
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
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

/// 悬浮框顶部的窗口拖动区。
class _FloatingTitleBar extends StatelessWidget {
  /// 当前时间。
  final DateTime now;

  /// 关闭悬浮框功能的回调。
  final Future<void> Function() onClose;

  /// 开始拖动窗口的回调。
  final VoidCallback onDragStart;

  /// 更新窗口拖动位置的回调。
  final VoidCallback onDragUpdate;

  /// 结束拖动并保存位置的回调。
  final Future<void> Function() onDragEnd;

  /// 创建悬浮框标题栏。
  const _FloatingTitleBar({
    required this.now,
    required this.onClose,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  /// 构建可拖动标题和独立关闭热区。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前日期标题。
    final String dateLabel = DateFormat('MM月dd日').format(now);
    return SizedBox(
      height: 46,
      child: Row(
        children: <Widget>[
          Expanded(
            child: GestureDetector(
              key: const ValueKey<String>('floating-window-drag-area'),
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => onDragStart(),
              onPanUpdate: (_) => onDragUpdate(),
              onPanEnd: (_) => unawaited(onDragEnd()),
              child: Padding(
                padding: const EdgeInsets.only(left: OmniSpacing.md),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.today_outlined, size: 17, color: colors.brand),
                    const SizedBox(width: OmniSpacing.xs),
                    Expanded(
                      child: Text(
                        'Omni Butler · $dateLabel',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            key: const ValueKey<String>('floating-window-close-button'),
            tooltip: '关闭桌面悬浮框',
            onPressed: () => unawaited(onClose()),
            icon: const Icon(Icons.close_rounded, size: OmniSize.icon),
          ),
          const SizedBox(width: OmniSpacing.xxs),
        ],
      ),
    );
  }
}

/// 悬浮框中的今日待办分区。
class _FloatingTodos extends ConsumerWidget {
  /// 今日自然日。
  final DateTime today;

  /// 完成指定待办的回调。
  final Future<void> Function(TodoRecord todo) onComplete;

  /// 显示主窗口指定路由的回调。
  final FloatingRouteCallback onOpenRoute;

  /// 切换新增待办快速录入区的回调。
  final VoidCallback onToggleComposer;

  /// 可选的新增待办快速录入区。
  final Widget? composer;

  /// 创建悬浮框今日待办分区。
  const _FloatingTodos({
    required this.today,
    required this.onComplete,
    required this.onOpenRoute,
    required this.onToggleComposer,
    required this.composer,
  });

  /// 构建标题、三个独立象限列表和查看全部入口。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 全部进行中待办树异步状态。
    final AsyncValue<List<TodoTreeNode>> todoTreesAsync = ref.watch(
      activeTodoTreesProvider(today),
    );
    // 今日仍有未完成内容的待办树。
    final List<TodoTreeNode> todayTrees =
        (todoTreesAsync.asData?.value ?? const <TodoTreeNode>[])
            .where(
              (TodoTreeNode tree) =>
                  DateUtils.isSameDay(tree.root.scheduledDate, today),
            )
            .toList(growable: false);
    // 三个重点象限的固定顺序。
    const List<TodoPriorityQuadrant> focusQuadrants = <TodoPriorityQuadrant>[
      TodoPriorityQuadrant.urgentImportant,
      TodoPriorityQuadrant.importantNotUrgent,
      TodoPriorityQuadrant.urgentNotImportant,
    ];
    // 按重点象限分组的今日根任务树。
    final Map<TodoPriorityQuadrant, List<TodoTreeNode>> groupedTrees =
        <TodoPriorityQuadrant, List<TodoTreeNode>>{
          for (final TodoPriorityQuadrant quadrant in focusQuadrants)
            quadrant: <TodoTreeNode>[],
        };
    for (final TodoTreeNode tree in todayTrees) {
      // 当前根任务所属象限。
      final TodoPriorityQuadrant quadrant = TodoPriorityQuadrant.fromValue(
        tree.root.priorityQuadrant,
      );
      groupedTrees[quadrant]?.add(tree);
    }
    for (final List<TodoTreeNode> trees in groupedTrees.values) {
      trees.sort(_compareFloatingTodoTrees);
    }
    // 新增待办录入区当前是否展开。
    final bool composerOpen = composer != null;
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 系统是否要求关闭动画。
    final bool disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Expanded(
              child: Text(
                '今日待办',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            SizedBox.square(
              dimension: OmniSize.control,
              child: IconButton(
                key: const ValueKey<String>('floating-todo-create'),
                tooltip: composerOpen ? '取消新增待办' : '新增待办',
                padding: EdgeInsets.zero,
                iconSize: 18,
                style: ButtonStyle(
                  foregroundColor: WidgetStateProperty.resolveWith<Color?>((
                    Set<WidgetState> states,
                  ) {
                    if (states.contains(WidgetState.hovered) ||
                        states.contains(WidgetState.focused) ||
                        composerOpen) {
                      return colors.brand;
                    }
                    return colors.muted;
                  }),
                  backgroundColor: WidgetStateProperty.resolveWith<Color?>((
                    Set<WidgetState> states,
                  ) {
                    if (states.contains(WidgetState.pressed)) {
                      return colors.brandSoft.withValues(alpha: 0.78);
                    }
                    if (states.contains(WidgetState.hovered) || composerOpen) {
                      return colors.brandSoft.withValues(alpha: 0.52);
                    }
                    return Colors.transparent;
                  }),
                  shape: WidgetStatePropertyAll<OutlinedBorder>(
                    RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(OmniRadius.control),
                    ),
                  ),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: onToggleComposer,
                icon: AnimatedRotation(
                  turns: composerOpen ? 0.125 : 0,
                  duration: disableAnimations ? Duration.zero : OmniMotion.fast,
                  curve: OmniMotion.standardCurve,
                  child: const Icon(Icons.add_rounded),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: OmniSpacing.xs),
        if (composer != null) ...<Widget>[
          composer!,
          const SizedBox(height: OmniSpacing.xs),
        ],
        if (todoTreesAsync.isLoading)
          const SizedBox(
            height: floatingTodoRowHeight * 3,
            child: Center(child: CircularProgressIndicator()),
          )
        else if (todoTreesAsync.hasError)
          _FloatingErrorState(
            message: '待办暂时无法读取',
            onRetry: () => ref.invalidate(activeTodoTreesProvider(today)),
          )
        else
          for (final TodoPriorityQuadrant quadrant
              in focusQuadrants) ...<Widget>[
            _FloatingTodoQuadrant(
              quadrant: quadrant,
              todoTrees: groupedTrees[quadrant]!,
              onComplete: onComplete,
            ),
            if (quadrant != focusQuadrants.last)
              const SizedBox(height: OmniSpacing.xs),
          ],
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            key: const ValueKey<String>('floating-todo-view-all'),
            onPressed: () => unawaited(onOpenRoute('/todos')),
            child: const Text('查看全部'),
          ),
        ),
      ],
    );
  }
}

/// 悬浮窗内联快速录入区的扁平框架。
class _FloatingComposerFrame extends StatelessWidget {
  /// 可选的录入区标题。
  final String? title;

  /// 可选的关闭录入区回调。
  final VoidCallback? onClose;

  /// 录入区内容。
  final Widget child;

  /// 创建扁平快速录入框架。
  const _FloatingComposerFrame({required this.child, this.title, this.onClose})
    : assert((title == null) == (onClose == null), '录入区标题和关闭回调必须同时提供');

  /// 构建无阴影、仅以淡色和分隔线区分的内联区域。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.brandSoft.withValues(alpha: 0.34),
        border: Border.symmetric(
          horizontal: BorderSide(color: colors.line.withValues(alpha: 0.82)),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: OmniSpacing.xs,
          vertical: OmniSpacing.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (title != null && onClose != null) ...<Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      title!,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  SizedBox.square(
                    dimension: 28,
                    child: IconButton(
                      tooltip: '取消',
                      padding: EdgeInsets.zero,
                      onPressed: onClose,
                      icon: const Icon(Icons.close_rounded, size: 16),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: OmniSpacing.xs),
            ],
            child,
          ],
        ),
      ),
    );
  }
}

/// 创建适配毛玻璃悬浮窗的飞书式紧凑输入装饰。
InputDecoration _floatingFieldDecoration(
  BuildContext context, {
  String? hintText,
}) {
  // 当前主题语义色。
  final OmniColors colors = OmniColors.of(context);
  // 当前是否使用深色主题。
  final bool isDark = Theme.of(context).brightness == Brightness.dark;
  // 默认输入边框。
  final OutlineInputBorder enabledBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(6),
    borderSide: BorderSide(color: colors.line.withValues(alpha: 0.88)),
  );
  // 聚焦输入边框。
  final OutlineInputBorder focusedBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(6),
    borderSide: BorderSide(color: colors.brand, width: 1.5),
  );
  // 错误输入边框。
  final OutlineInputBorder errorBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(6),
    borderSide: BorderSide(color: colors.danger),
  );
  return InputDecoration(
    hintText: hintText,
    filled: true,
    fillColor: colors.paper.withValues(alpha: isDark ? 0.16 : 0.62),
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
    border: enabledBorder,
    enabledBorder: enabledBorder,
    focusedBorder: focusedBorder,
    errorBorder: errorBorder,
    focusedErrorBorder: errorBorder.copyWith(
      borderSide: BorderSide(color: colors.danger, width: 1.5),
    ),
    hintStyle: TextStyle(color: colors.muted, fontSize: 13),
    errorStyle: TextStyle(color: colors.danger, fontSize: 11, height: 1),
  );
}

/// 悬浮窗紧凑输入控件的外置标签。
class _FloatingLabeledField extends StatelessWidget {
  /// 字段标签。
  final String label;

  /// 实际输入控件。
  final Widget child;

  /// 创建带外置标签的紧凑字段。
  const _FloatingLabeledField({required this.label, required this.child});

  /// 构建飞书式上标签、下控件布局。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: colors.muted,
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: OmniSpacing.xxs),
        child,
      ],
    );
  }
}

/// 悬浮窗内联新增待办表单。
class _FloatingTodoComposer extends ConsumerStatefulWidget {
  /// 新待办所属自然日。
  final DateTime today;

  /// 关闭表单的回调。
  final VoidCallback onClose;

  /// 创建内联新增待办表单。
  const _FloatingTodoComposer({required this.today, required this.onClose});

  /// 创建内联待办表单状态。
  @override
  ConsumerState<_FloatingTodoComposer> createState() =>
      _FloatingTodoComposerState();
}

/// 管理悬浮窗内联待办输入与保存。
class _FloatingTodoComposerState extends ConsumerState<_FloatingTodoComposer> {
  /// 待办表单键。
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  /// 待办标题控制器。
  final TextEditingController _titleController = TextEditingController();

  /// 当前选择的待办象限。
  TodoPriorityQuadrant _quadrant = TodoPriorityQuadrant.importantNotUrgent;

  /// 当前是否正在保存。
  bool _saving = false;

  /// 当前保存错误。
  String? _errorMessage;

  /// 释放待办标题控制器。
  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  /// 校验并保存今日待办。
  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    setState(() {
      _saving = true;
      _errorMessage = null;
    });
    try {
      await ref
          .read(todoRepositoryProvider)
          .save(
            TodoDraft(
              title: _titleController.text,
              scheduledDate: DateUtils.dateOnly(widget.today),
              priorityQuadrant: _quadrant,
            ),
          );
      if (mounted) {
        widget.onClose();
      }
    } on FormatException catch (error) {
      if (mounted) {
        setState(() => _errorMessage = error.message);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _errorMessage = '待办保存失败，请重试');
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  /// 构建标题、象限和紧凑保存操作。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return _FloatingComposerFrame(
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _FloatingLabeledField(
              label: '待办标题',
              child: TextFormField(
                key: const ValueKey<String>('floating-todo-title-field'),
                controller: _titleController,
                autofocus: true,
                maxLength: 200,
                textInputAction: TextInputAction.done,
                style: const TextStyle(fontSize: 13),
                decoration: _floatingFieldDecoration(
                  context,
                  hintText: '例如：整理本周发票',
                ).copyWith(counterText: ''),
                validator: (String? value) =>
                    value == null || value.trim().isEmpty ? '请输入待办标题' : null,
                onFieldSubmitted: (_) => _saving ? null : _save(),
              ),
            ),
            const SizedBox(height: OmniSpacing.xs),
            _FloatingLabeledField(
              label: '优先级',
              child: OmniDropdownButtonFormField<TodoPriorityQuadrant>(
                key: const ValueKey<String>('floating-todo-priority-field'),
                initialValue: _quadrant,
                decoration: _floatingFieldDecoration(context),
                selectionIndicatorPosition:
                    OmniDropdownSelectionIndicatorPosition.trailing,
                items: <DropdownMenuItem<TodoPriorityQuadrant>>[
                  for (final TodoPriorityQuadrant quadrant
                      in todoPriorityQuadrantMatrixOrder)
                    DropdownMenuItem<TodoPriorityQuadrant>(
                      value: quadrant,
                      child: Row(
                        children: <Widget>[
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: quadrant.color(colors),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: OmniSpacing.xs),
                          Expanded(child: Text(quadrant.label)),
                        ],
                      ),
                    ),
                ],
                onChanged: _saving
                    ? null
                    : (TodoPriorityQuadrant? value) {
                        if (value != null) {
                          setState(() => _quadrant = value);
                        }
                      },
              ),
            ),
            if (_errorMessage != null) ...<Widget>[
              const SizedBox(height: OmniSpacing.xs),
              _FloatingComposerError(message: _errorMessage!),
            ],
            const SizedBox(height: OmniSpacing.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                _FloatingCompactButton(
                  key: const ValueKey<String>('floating-todo-inline-cancel'),
                  label: '取消',
                  secondary: true,
                  onPressed: _saving ? null : widget.onClose,
                ),
                const SizedBox(width: OmniSpacing.xxs),
                _FloatingCompactButton(
                  key: const ValueKey<String>('floating-todo-inline-save'),
                  label: '保存',
                  loading: _saving,
                  onPressed: _saving ? null : _save,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 悬浮窗内联时间表单模式。
enum _FloatingTimeComposerMode {
  /// 创建进行中记录。
  start,

  /// 创建已经完成的记录。
  backfill,
}

/// 悬浮窗内联时间记录表单。
class _FloatingTimeComposer extends ConsumerStatefulWidget {
  /// 当前时间录入模式。
  final _FloatingTimeComposerMode mode;

  /// 新记录所属自然日。
  final DateTime day;

  /// 关闭表单的回调。
  final VoidCallback onClose;

  /// 创建内联时间记录表单。
  const _FloatingTimeComposer({
    required this.mode,
    required this.day,
    required this.onClose,
    super.key,
  });

  /// 创建内联时间表单状态。
  @override
  ConsumerState<_FloatingTimeComposer> createState() =>
      _FloatingTimeComposerState();
}

/// 管理悬浮窗内联时间输入与保存。
class _FloatingTimeComposerState extends ConsumerState<_FloatingTimeComposer> {
  /// 时间记录表单键。
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  /// 活动内容控制器。
  final TextEditingController _activityController = TextEditingController();

  /// 类别控制器。
  final TextEditingController _categoryController = TextEditingController();

  /// 开始时间控制器。
  late final TextEditingController _startController;

  /// 结束时间控制器。
  late final TextEditingController _endController;

  /// 表单使用的自然日。
  late final DateTime _day;

  /// 当前是否正在保存。
  bool _saving = false;

  /// 当前保存错误。
  String? _errorMessage;

  /// 初始化五分钟粒度的默认时间。
  @override
  void initState() {
    super.initState();
    // 当前时间。
    final DateTime now = ref.read(nowProvider);
    // 表单固定使用的自然日。
    _day = DateUtils.dateOnly(widget.day);
    // 当前时间在自然日内向下取整后的分钟数。
    final int roundedMinute = ((now.hour * 60 + now.minute) ~/ 5 * 5).clamp(
      0,
      1435,
    );
    // 补记默认结束分钟，午夜时至少保留五分钟区间。
    final int defaultEndMinute = roundedMinute < 5 ? 5 : roundedMinute;
    // 补记默认开始分钟。
    final int defaultStartMinute =
        widget.mode == _FloatingTimeComposerMode.start
        ? roundedMinute
        : (defaultEndMinute - 60).clamp(0, 1435);
    _startController = TextEditingController(
      text: _formatMinuteOfDay(defaultStartMinute),
    );
    _endController = TextEditingController(
      text: _formatMinuteOfDay(defaultEndMinute),
    );
  }

  /// 释放时间记录表单控制器。
  @override
  void dispose() {
    _activityController.dispose();
    _categoryController.dispose();
    _startController.dispose();
    _endController.dispose();
    super.dispose();
  }

  /// 将自然日内分钟数格式化为 HH:mm。
  String _formatMinuteOfDay(int minute) {
    // 小时部分。
    final int hour = minute ~/ 60;
    // 分钟部分。
    final int minutePart = minute % 60;
    return '${hour.toString().padLeft(2, '0')}:${minutePart.toString().padLeft(2, '0')}';
  }

  /// 将 HH:mm 输入解析为当天绝对时间。
  DateTime? _parseClock(String value) {
    // 清理后的时间文本。
    final String normalized = value.trim();
    // HH:mm 格式匹配结果。
    final RegExpMatch? match = RegExp(r'^(\d{1,2}):(\d{2})$')
        .firstMatch(normalized);
    if (match == null) {
      return null;
    }
    // 输入小时。
    final int? hour = int.tryParse(match.group(1)!);
    // 输入分钟。
    final int? minute = int.tryParse(match.group(2)!);
    if (hour == null || minute == null || hour > 23 || minute > 59) {
      return null;
    }
    return DateTime(_day.year, _day.month, _day.day, hour, minute);
  }

  /// 校验 HH:mm 时间输入。
  String? _validateClock(String? value) {
    return value == null || _parseClock(value) == null ? '格式 HH:mm' : null;
  }

  /// 校验并保存时间记录。
  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    // 解析后的开始时间。
    final DateTime startedAt = _parseClock(_startController.text)!;
    // 解析后的可选结束时间。
    final DateTime? endedAt = widget.mode == _FloatingTimeComposerMode.backfill
        ? _parseClock(_endController.text)
        : null;
    if (endedAt != null && !endedAt.isAfter(startedAt)) {
      setState(() => _errorMessage = '结束时间必须晚于开始时间');
      return;
    }
    setState(() {
      _saving = true;
      _errorMessage = null;
    });
    try {
      await ref
          .read(timeEntryRepositoryProvider)
          .save(
            TimeEntryDraft(
              startedAt: startedAt,
              endedAt: endedAt,
              activity: _activityController.text,
              category: _categoryController.text,
            ),
          );
      if (mounted) {
        widget.onClose();
      }
    } on ActiveTimeEntryConflict catch (error) {
      if (mounted) {
        setState(() => _errorMessage = error.toString());
      }
    } on TimeEntryConflict catch (error) {
      if (mounted) {
        setState(() => _errorMessage = error.toString());
      }
    } on FormatException catch (error) {
      if (mounted) {
        setState(() => _errorMessage = error.message);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _errorMessage = '时间记录保存失败，请重试');
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  /// 构建活动、类别、时间和紧凑保存操作。
  @override
  Widget build(BuildContext context) {
    // 当前是否为补记模式。
    final bool backfill = widget.mode == _FloatingTimeComposerMode.backfill;
    return _FloatingComposerFrame(
      title: backfill ? '补记时间' : '开始记录',
      onClose: widget.onClose,
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _FloatingLabeledField(
              label: backfill ? '活动内容' : '正在做什么',
              child: TextFormField(
                key: const ValueKey<String>('floating-time-activity-field'),
                controller: _activityController,
                autofocus: true,
                textInputAction: TextInputAction.next,
                style: const TextStyle(fontSize: 13),
                decoration: _floatingFieldDecoration(
                  context,
                  hintText: backfill ? '必填，例如：整理资料' : '可留空，稍后补充',
                ),
                validator: (String? value) {
                  if (backfill && (value == null || value.trim().isEmpty)) {
                    return '请输入活动内容';
                  }
                  return null;
                },
              ),
            ),
            const SizedBox(height: OmniSpacing.xs),
            _FloatingLabeledField(
              label: '类别',
              child: TextFormField(
                key: const ValueKey<String>('floating-time-category-field'),
                controller: _categoryController,
                textInputAction: TextInputAction.next,
                style: const TextStyle(fontSize: 13),
                decoration: _floatingFieldDecoration(context, hintText: '可选'),
              ),
            ),
            const SizedBox(height: OmniSpacing.xs),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: _FloatingLabeledField(
                    label: '开始时间',
                    child: TextFormField(
                      key: const ValueKey<String>('floating-time-start-field'),
                      controller: _startController,
                      keyboardType: TextInputType.datetime,
                      textInputAction: backfill
                          ? TextInputAction.next
                          : TextInputAction.done,
                      style: const TextStyle(fontSize: 13),
                      decoration: _floatingFieldDecoration(
                        context,
                        hintText: 'HH:mm',
                      ),
                      validator: _validateClock,
                      onFieldSubmitted: (_) =>
                          backfill || _saving ? null : _save(),
                    ),
                  ),
                ),
                if (backfill) ...<Widget>[
                  const SizedBox(width: OmniSpacing.xs),
                  Expanded(
                    child: _FloatingLabeledField(
                      label: '结束时间',
                      child: TextFormField(
                        key: const ValueKey<String>('floating-time-end-field'),
                        controller: _endController,
                        keyboardType: TextInputType.datetime,
                        textInputAction: TextInputAction.done,
                        style: const TextStyle(fontSize: 13),
                        decoration: _floatingFieldDecoration(
                          context,
                          hintText: 'HH:mm',
                        ),
                        validator: _validateClock,
                        onFieldSubmitted: (_) => _saving ? null : _save(),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            if (_errorMessage != null) ...<Widget>[
              const SizedBox(height: OmniSpacing.xs),
              _FloatingComposerError(message: _errorMessage!),
            ],
            const SizedBox(height: OmniSpacing.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                _FloatingCompactButton(
                  key: const ValueKey<String>('floating-time-inline-cancel'),
                  label: '取消',
                  secondary: true,
                  onPressed: _saving ? null : widget.onClose,
                ),
                const SizedBox(width: OmniSpacing.xxs),
                _FloatingCompactButton(
                  key: const ValueKey<String>('floating-time-inline-save'),
                  label: backfill ? '保存' : '开始',
                  loading: _saving,
                  onPressed: _saving ? null : _save,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 悬浮窗内联表单的错误提示。
class _FloatingComposerError extends StatelessWidget {
  /// 错误说明。
  final String message;

  /// 创建内联错误提示。
  const _FloatingComposerError({required this.message});

  /// 构建带图标的紧凑错误说明。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(Icons.error_outline_rounded, size: 15, color: colors.danger),
        const SizedBox(width: OmniSpacing.xxs),
        Expanded(
          child: Text(
            message,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.danger),
          ),
        ),
      ],
    );
  }
}

/// 比较同一象限中悬浮框根任务的展示顺序。
int _compareFloatingTodoTrees(TodoTreeNode left, TodoTreeNode right) {
  // 无截止时间任务使用的远期时间。
  final DateTime distantFuture = DateTime(9999);
  // 截止时间比较结果。
  final int dueComparison = (left.root.dueAt ?? distantFuture).compareTo(
    right.root.dueAt ?? distantFuture,
  );
  if (dueComparison != 0) {
    return dueComparison;
  }
  // 用户排序值比较结果。
  final int orderComparison = left.root.sortOrder.compareTo(
    right.root.sortOrder,
  );
  return orderComparison != 0
      ? orderComparison
      : left.root.createdAt.compareTo(right.root.createdAt);
}

/// 悬浮框中的单个重点象限。
class _FloatingTodoQuadrant extends StatelessWidget {
  /// 当前重点象限。
  final TodoPriorityQuadrant quadrant;

  /// 当前象限全部今日根任务树。
  final List<TodoTreeNode> todoTrees;

  /// 完成指定待办的回调。
  final Future<void> Function(TodoRecord todo) onComplete;

  /// 创建悬浮框待办象限。
  const _FloatingTodoQuadrant({
    required this.quadrant,
    required this.todoTrees,
    required this.onComplete,
  });

  /// 构建象限标题和固定五行高度的独立滚动列表。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前象限强调色。
    final Color accent = quadrant.color(colors);
    // 当前象限包含的根任务与未完成直属子任务总行数。
    final int taskRowCount = todoTrees.fold<int>(0, (
      int count,
      TodoTreeNode tree,
    ) {
      // 当前根任务仍未完成的直属子任务数量。
      final int pendingChildCount = tree.children
          .where((TodoRecord child) => !child.isCompleted)
          .length;
      return count + 1 + pendingChildCount;
    });
    // 当前象限列表视口高度。
    final double viewportHeight = calculateFloatingTodoViewportHeight(
      taskRowCount,
    );
    return Column(
      key: ValueKey<String>('floating-todo-quadrant-${quadrant.value}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              quadrant.label,
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: accent, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: OmniSpacing.xs),
            Expanded(child: Divider(color: accent.withValues(alpha: 0.58))),
            const SizedBox(width: OmniSpacing.xs),
            Text(
              '${todoTrees.length}',
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: colors.muted),
            ),
          ],
        ),
        const SizedBox(height: OmniSpacing.xxs),
        SizedBox(
          key: ValueKey<String>('floating-todo-viewport-${quadrant.value}'),
          height: viewportHeight,
          child: todoTrees.isEmpty
              ? Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 30),
                    child: Text('暂无任务', style: TextStyle(color: colors.muted)),
                  ),
                )
              : Scrollbar(
                  child: ListView.builder(
                    key: PageStorageKey<String>(
                      'floating-quadrant-${quadrant.value}',
                    ),
                    primary: false,
                    padding: EdgeInsets.zero,
                    itemCount: todoTrees.length,
                    itemBuilder: (BuildContext context, int index) {
                      // 当前滚动位置对应的根任务树。
                      final TodoTreeNode tree = todoTrees[index];
                      return _FloatingTodoTree(
                        key: ValueKey<String>(
                          'floating-todo-tree-${tree.root.id}',
                        ),
                        tree: tree,
                        accent: accent,
                        onComplete: onComplete,
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

/// 悬浮框中可以展开直属子任务的根任务树。
class _FloatingTodoTree extends StatefulWidget {
  /// 当前根任务树。
  final TodoTreeNode tree;

  /// 当前象限强调色。
  final Color accent;

  /// 完成指定待办的回调。
  final Future<void> Function(TodoRecord todo) onComplete;

  /// 创建悬浮框根任务树。
  const _FloatingTodoTree({
    required this.tree,
    required this.accent,
    required this.onComplete,
    super.key,
  });

  /// 创建任务树展开状态。
  @override
  State<_FloatingTodoTree> createState() => _FloatingTodoTreeState();
}

/// 管理悬浮框根任务的子任务展开状态。
class _FloatingTodoTreeState extends State<_FloatingTodoTree> {
  /// 子任务是否展开。
  bool _expanded = true;

  /// 切换直属子任务展开状态。
  void _toggleExpanded() {
    setState(() => _expanded = !_expanded);
  }

  /// 构建根任务和未完成直属子任务。
  @override
  Widget build(BuildContext context) {
    // 当前仍未完成的直属子任务。
    final List<TodoRecord> pendingChildren = widget.tree.children
        .where((TodoRecord child) => !child.isCompleted)
        .toList(growable: false);
    // 当前根任务是否存在可展示子任务。
    final bool hasChildren = pendingChildren.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _FloatingTodoRow(
          todo: widget.tree.root,
          accent: widget.accent,
          onComplete: widget.onComplete,
          expanded: hasChildren ? _expanded : null,
          onToggleExpanded: hasChildren ? _toggleExpanded : null,
        ),
        if (_expanded && hasChildren)
          for (final TodoRecord child in pendingChildren)
            Padding(
              padding: const EdgeInsets.only(left: OmniSpacing.lg),
              child: _FloatingTodoRow(
                todo: child,
                accent: widget.accent,
                onComplete: widget.onComplete,
                child: true,
              ),
            ),
      ],
    );
  }
}

/// 悬浮框中的单条紧凑待办。
class _FloatingTodoRow extends StatelessWidget {
  /// 当前待办。
  final TodoRecord todo;

  /// 当前象限强调色。
  final Color accent;

  /// 完成指定待办的回调。
  final Future<void> Function(TodoRecord todo) onComplete;

  /// 当前行是否为直属子任务。
  final bool child;

  /// 可选子任务展开状态。
  final bool? expanded;

  /// 可选子任务展开状态切换回调。
  final VoidCallback? onToggleExpanded;

  /// 创建悬浮框待办行。
  const _FloatingTodoRow({
    required this.todo,
    required this.accent,
    required this.onComplete,
    this.child = false,
    this.expanded,
    this.onToggleExpanded,
  });

  /// 构建完成入口、标题、截止时间和展开按钮。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前待办紧凑截止时间。
    final String? dueLabel = todo.dueAt == null
        ? null
        : DateFormat('HH:mm').format(todo.dueAt!);
    return SizedBox(
      height: floatingTodoRowHeight,
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 30,
            height: 30,
            child: IconButton(
              key: ValueKey<String>('floating-todo-complete-${todo.id}'),
              tooltip: todo.isCompleted ? '已完成' : '完成任务',
              padding: EdgeInsets.zero,
              onPressed: todo.isCompleted
                  ? null
                  : () => unawaited(onComplete(todo)),
              icon: Icon(
                todo.isCompleted
                    ? Icons.check_box_rounded
                    : Icons.check_box_outline_blank_rounded,
                size: 17,
                color: todo.isCompleted ? accent : colors.muted,
              ),
            ),
          ),
          if (child)
            Icon(
              Icons.subdirectory_arrow_right_rounded,
              size: 13,
              color: colors.muted,
            ),
          Expanded(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                key: ValueKey<String>('floating-todo-edit-${todo.id}'),
                borderRadius: BorderRadius.circular(OmniRadius.control),
                onTap: () => TodoEditorDialog.show(context, record: todo),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    todo.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: todo.isCompleted ? colors.muted : colors.ink,
                      decoration: todo.isCompleted
                          ? TextDecoration.lineThrough
                          : TextDecoration.none,
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (dueLabel != null) ...<Widget>[
            const SizedBox(width: OmniSpacing.xxs),
            Text(
              dueLabel,
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: colors.muted),
            ),
          ],
          if (onToggleExpanded != null)
            SizedBox(
              width: 30,
              height: 30,
              child: IconButton(
                key: ValueKey<String>('floating-todo-expand-${todo.id}'),
                tooltip: expanded! ? '收起子任务' : '展开子任务',
                padding: EdgeInsets.zero,
                onPressed: onToggleExpanded,
                icon: Icon(
                  expanded!
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 17,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 悬浮框中的时间记录操作区。
class _FloatingTimeStatus extends ConsumerWidget {
  /// 显示主窗口指定路由的回调。
  final FloatingRouteCallback onOpenRoute;

  /// 展开开始记录快速录入区的回调。
  final VoidCallback onStart;

  /// 展开补记快速录入区的回调。
  final VoidCallback onBackfill;

  /// 可选的时间记录快速录入区。
  final Widget? composer;

  /// 创建悬浮框时间状态区。
  const _FloatingTimeStatus({
    required this.onOpenRoute,
    required this.onStart,
    required this.onBackfill,
    required this.composer,
  });

  /// 构建未计时、进行中或同步冲突状态。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 全部进行中时间记录异步状态。
    final AsyncValue<List<TimeEntryRecord>> ongoingAsync = ref.watch(
      ongoingTimeEntriesProvider,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Text('时间状态', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: OmniSpacing.xs),
        ongoingAsync.when(
          loading: () => const SizedBox(
            height: 44,
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (_, _) => _FloatingErrorState(
            message: '时间状态暂时无法读取',
            onRetry: () => ref.invalidate(ongoingTimeEntriesProvider),
          ),
          data: (List<TimeEntryRecord> records) {
            if (records.length > 1) {
              return _TimeConflictState(
                count: records.length,
                onProcess: () => onOpenRoute('/timeline'),
                onBackfill: onBackfill,
              );
            }
            if (records.isEmpty) {
              return _IdleTimeState(onStart: onStart, onBackfill: onBackfill);
            }
            return _OngoingTimeState(
              record: records.single,
              onFinish: () =>
                  showFinishTimeEntryDialog(context, record: records.single),
              onBackfill: onBackfill,
            );
          },
        ),
        if (composer != null) ...<Widget>[
          const SizedBox(height: OmniSpacing.sm),
          composer!,
        ],
      ],
    );
  }
}

/// 悬浮窗内使用的紧凑操作按钮。
class _FloatingCompactButton extends StatelessWidget {
  /// 按钮文字。
  final String label;

  /// 点击回调。
  final VoidCallback? onPressed;

  /// 是否使用次要描边样式。
  final bool secondary;

  /// 是否展示保存中状态。
  final bool loading;

  /// 创建紧凑操作按钮。
  const _FloatingCompactButton({
    required this.label,
    required this.onPressed,
    this.secondary = false,
    this.loading = false,
    super.key,
  });

  /// 构建 30px 高的窄窗操作按钮。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前是否使用深色主题。
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    // 紧凑按钮的公共样式。
    final ButtonStyle style = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 30)),
      padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.symmetric(horizontal: 11),
      ),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
      textStyle: const WidgetStatePropertyAll<TextStyle>(
        TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
      ),
      foregroundColor: WidgetStateProperty.resolveWith<Color?>((
        Set<WidgetState> states,
      ) {
        if (states.contains(WidgetState.disabled)) {
          return colors.muted.withValues(alpha: 0.62);
        }
        return secondary ? colors.ink : colors.brandStrong;
      }),
      backgroundColor: WidgetStateProperty.resolveWith<Color?>((
        Set<WidgetState> states,
      ) {
        if (states.contains(WidgetState.disabled)) {
          return colors.mist.withValues(alpha: isDark ? 0.18 : 0.42);
        }
        if (states.contains(WidgetState.pressed)) {
          return secondary
              ? colors.mist.withValues(alpha: isDark ? 0.46 : 0.82)
              : Color.alphaBlend(
                  colors.brand.withValues(alpha: 0.14),
                  colors.brandSoft.withValues(alpha: isDark ? 0.46 : 0.84),
                );
        }
        if (states.contains(WidgetState.hovered)) {
          return secondary
              ? colors.paper.withValues(alpha: isDark ? 0.20 : 0.62)
              : colors.brandSoft.withValues(alpha: isDark ? 0.46 : 0.84);
        }
        return secondary
            ? colors.paper.withValues(alpha: isDark ? 0.10 : 0.38)
            : colors.brandSoft.withValues(alpha: isDark ? 0.34 : 0.70);
      }),
      side: WidgetStateProperty.resolveWith<BorderSide?>((
        Set<WidgetState> states,
      ) {
        if (states.contains(WidgetState.focused)) {
          return BorderSide(color: colors.brand, width: 1.5);
        }
        if (states.contains(WidgetState.disabled)) {
          return BorderSide(color: colors.line.withValues(alpha: 0.42));
        }
        return BorderSide(
          color: secondary
              ? colors.line.withValues(alpha: 0.86)
              : colors.brand.withValues(alpha: 0.28),
        );
      }),
      shape: WidgetStatePropertyAll<OutlinedBorder>(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(OmniRadius.control),
        ),
      ),
      overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
      elevation: const WidgetStatePropertyAll<double>(0),
      animationDuration: OmniMotion.fast,
    );
    // 保存状态下显示的按钮内容。
    final Widget child = loading
        ? const SizedBox.square(
            dimension: 13,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Text(label);
    return OutlinedButton(onPressed: onPressed, style: style, child: child);
  }
}

/// 没有进行中记录时的时间操作。
class _IdleTimeState extends StatelessWidget {
  /// 开始记录回调。
  final VoidCallback onStart;

  /// 补记时间回调。
  final VoidCallback onBackfill;

  /// 创建未计时时间状态。
  const _IdleTimeState({required this.onStart, required this.onBackfill});

  /// 构建说明和双操作按钮。
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Text('当前没有进行中的记录'),
        const SizedBox(height: OmniSpacing.xs),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            _FloatingCompactButton(
              key: const ValueKey<String>('floating-time-start'),
              label: '开始',
              onPressed: onStart,
            ),
            const SizedBox(width: OmniSpacing.xxs),
            _FloatingCompactButton(
              key: const ValueKey<String>('floating-time-backfill'),
              label: '补记',
              secondary: true,
              onPressed: onBackfill,
            ),
          ],
        ),
      ],
    );
  }
}

/// 单条进行中记录的实时状态。
class _OngoingTimeState extends StatefulWidget {
  /// 当前进行中记录。
  final TimeEntryRecord record;

  /// 结束记录回调。
  final VoidCallback onFinish;

  /// 补记时间回调。
  final VoidCallback onBackfill;

  /// 创建进行中时间状态。
  const _OngoingTimeState({
    required this.record,
    required this.onFinish,
    required this.onBackfill,
  });

  /// 创建实时累计时长状态。
  @override
  State<_OngoingTimeState> createState() => _OngoingTimeStateState();
}

/// 每秒按绝对时间刷新进行中时长。
class _OngoingTimeStateState extends State<_OngoingTimeState> {
  /// 当前绝对时间。
  DateTime _now = DateTime.now();

  /// 每秒刷新定时器。
  Timer? _timer;

  /// 启动每秒绝对时间刷新。
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _now = DateTime.now());
      }
    });
  }

  /// 释放每秒刷新定时器。
  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// 构建实时活动摘要、累计时长和结束入口。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前记录已经持续的非负时长。
    final Duration elapsed = _now.isBefore(widget.record.startedAt)
        ? Duration.zero
        : _now.difference(widget.record.startedAt);
    // 当前记录活动或类别摘要。
    final String activity = timeEntryDisplayActivity(widget.record);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            _TimePulseDot(color: colors.time),
            const SizedBox(width: OmniSpacing.xs),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    activity,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                  Text(
                    '${DateFormat('HH:mm').format(widget.record.startedAt)} 开始 · ${_formatElapsed(elapsed)}',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: colors.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: OmniSpacing.xs),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            _FloatingCompactButton(
              key: const ValueKey<String>('floating-time-finish'),
              label: '结束',
              onPressed: widget.onFinish,
            ),
            const SizedBox(width: OmniSpacing.xxs),
            _FloatingCompactButton(
              key: const ValueKey<String>('floating-time-backfill'),
              label: '补记',
              secondary: true,
              onPressed: widget.onBackfill,
            ),
          ],
        ),
      ],
    );
  }
}

/// 多条进行中记录的同步冲突状态。
class _TimeConflictState extends StatelessWidget {
  /// 当前进行中记录数量。
  final int count;

  /// 进入时间管理页处理回调。
  final VoidCallback onProcess;

  /// 补记时间回调。
  final VoidCallback onBackfill;

  /// 创建时间记录冲突状态。
  const _TimeConflictState({
    required this.count,
    required this.onProcess,
    required this.onBackfill,
  });

  /// 构建冲突说明和处理入口。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(Icons.warning_amber_rounded, color: colors.warning, size: 20),
            const SizedBox(width: OmniSpacing.xs),
            Expanded(child: Text('有 $count 条进行中记录，请先处理冲突')),
          ],
        ),
        const SizedBox(height: OmniSpacing.xs),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            _FloatingCompactButton(label: '处理', onPressed: onProcess),
            const SizedBox(width: OmniSpacing.xxs),
            _FloatingCompactButton(
              label: '补记',
              secondary: true,
              onPressed: onBackfill,
            ),
          ],
        ),
      ],
    );
  }
}

/// 进行中时间状态的轻量脉冲标记。
class _TimePulseDot extends StatefulWidget {
  /// 脉冲语义色。
  final Color color;

  /// 创建进行中脉冲标记。
  const _TimePulseDot({required this.color});

  /// 创建脉冲动画状态。
  @override
  State<_TimePulseDot> createState() => _TimePulseDotState();
}

/// 管理进行中时间状态的单一签名动效。
class _TimePulseDotState extends State<_TimePulseDot>
    with SingleTickerProviderStateMixin {
  /// 脉冲动画控制器。
  late final AnimationController _controller;

  /// 初始化循环脉冲动画。
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  /// 释放脉冲动画控制器。
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 构建尊重减少动态效果设置的双层圆点。
  @override
  Widget build(BuildContext context) {
    // 当前是否关闭非必要动画。
    final bool disableAnimations = MediaQuery.of(context).disableAnimations;
    if (disableAnimations) {
      return _buildDot(1);
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        return _buildDot(0.86 + _controller.value * 0.14);
      },
    );
  }

  /// 按给定比例构建脉冲圆点。
  Widget _buildDot(double scale) {
    return Transform.scale(
      scale: scale,
      child: Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          color: widget.color.withValues(alpha: 0.16),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: widget.color,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}

/// 悬浮框分区内的紧凑读取失败状态。
class _FloatingErrorState extends StatelessWidget {
  /// 用户可理解的错误说明。
  final String message;

  /// 重新读取数据的回调。
  final VoidCallback onRetry;

  /// 创建悬浮框读取失败状态。
  const _FloatingErrorState({required this.message, required this.onRetry});

  /// 构建错误说明和重试入口。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(message, style: TextStyle(color: colors.danger)),
        ),
        TextButton(onPressed: onRetry, child: const Text('重试')),
      ],
    );
  }
}

/// 将进行中记录时长格式化为小时、分钟和秒。
String _formatElapsed(Duration duration) {
  // 非负总小时数。
  final int hours = duration.inHours.clamp(0, 9999);
  // 当前小时内的分钟数。
  final int minutes = duration.inMinutes.remainder(60);
  // 当前分钟内的秒数。
  final int seconds = duration.inSeconds.remainder(60);
  return '${hours.toString().padLeft(2, '0')}:'
      '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}';
}
