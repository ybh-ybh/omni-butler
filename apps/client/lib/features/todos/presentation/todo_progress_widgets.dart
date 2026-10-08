import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:omni_butler/features/todos/presentation/todo_completion_checkbox.dart';
import 'package:omni_butler/features/todos/presentation/todo_progress_panel.dart';
import 'package:omni_butler/features/todos/presentation/todo_task_actions.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 返回步骤的可读名称，空名称仅在展示时补上序号。
String todoProgressStepLabel(
  TodoProgressStepRecord step,
  int index, {
  String? unit,
}) {
  return step.name?.trim().isNotEmpty == true
      ? '${index + 1}. ${step.name!.trim()}'
      : '第${index + 1}${unit?.trim().isNotEmpty == true ? unit!.trim() : '步'}';
}

/// 统一生成列表、历史与行内摘要的进度文案。
String _todoProgressSummaryLabel(
  TodoRecord todo,
  List<TodoProgressStepRecord> steps,
) {
  if (steps.isEmpty) return '暂无步骤，请补充步骤';
  // 已完成的有效步骤数。
  final int completed = steps.where((step) => step.isCompleted).length;
  // 未指定单位时按步展示。
  final String unit = (todo.progressUnit?.trim() ?? '').isEmpty
      ? '步'
      : todo.progressUnit!.trim();
  return '已完成 $completed/${steps.length} $unit'
      '${todo.isCompleted
          ? ' · 已完成'
          : completed == steps.length
          ? ' · 待确认完成'
          : ''}';
}

/// 在列表、首页和历史中展示同一份步骤进度。
class TodoProgressSummaryView extends ConsumerWidget {
  /// 当前进度任务。
  final TodoRecord todo;

  /// 点击总览时打开步骤面板。
  final VoidCallback? onTap;

  /// 创建任务进度总览。
  const TodoProgressSummaryView({required this.todo, this.onTap, super.key});

  /// 构建明确区分已完成数与总数的总览。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 当前任务的有效步骤流。
    final AsyncValue<List<TodoProgressStepRecord>> stepsAsync = ref.watch(
      todoProgressStepsProvider(todo.id),
    );
    return stepsAsync.when(
      loading: () => const Text('正在读取进度…'),
      error: (Object error, StackTrace stack) => const Text('进度读取失败'),
      data: (List<TodoProgressStepRecord> steps) {
        // 同时包含进度和任务状态的可读文案。
        final String label = _todoProgressSummaryLabel(todo, steps);
        return Semantics(
          label: label,
          button: onTap != null,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(OmniRadius.control),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: OmniSpacing.xxs),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    ExcludeSemantics(
                      child: Text(
                        label,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    if (steps.isNotEmpty) ...<Widget>[
                      const SizedBox(height: OmniSpacing.xxs),
                      TodoProgressBar(steps: steps),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 自动在分段总览和连续总览之间切换的只读进度条。
class TodoProgressBar extends StatelessWidget {
  /// 按用户顺序排列的有效步骤。
  final List<TodoProgressStepRecord> steps;

  /// 创建进度条。
  const TodoProgressBar({required this.steps, super.key});

  /// 构建仅展示进度的条形图，不提供节点悬停提示。
  @override
  Widget build(BuildContext context) {
    // 当前配色的业务颜色。
    final OmniColors colors = OmniColors.of(context);
    // 当前已完成比例。
    final double ratio = steps.isEmpty
        ? 0
        : steps.where((step) => step.isCompleted).length / steps.length;
    return ExcludeSemantics(
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: ratio),
        duration: OmniMotion.duration(context, OmniMotion.normal),
        builder: (BuildContext context, double animatedRatio, Widget? child) {
          return SizedBox(
            height: OmniSpacing.xs,
            child: CustomPaint(
              key: const ValueKey<String>('todo-progress-bar'),
              painter: _TodoProgressPainter(
                steps: steps,
                ratio: animatedRatio,
                foreground: colors.brand,
                background: colors.line,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 在已分配的尺寸中绘制真实步骤状态，不依赖 LayoutBuilder。
class _TodoProgressPainter extends CustomPainter {
  /// 当前步骤状态。
  final List<TodoProgressStepRecord> steps;

  /// 连续模式的动画填充比例。
  final double ratio;

  /// 完成部分颜色。
  final Color foreground;

  /// 未完成部分颜色。
  final Color background;

  /// 创建步骤总览画笔。
  const _TodoProgressPainter({
    required this.steps,
    required this.ratio,
    required this.foreground,
    required this.background,
  });

  /// 至多二十四段，且每段至少八像素时使用分段模式。
  static bool isSegmented(double width, int count) =>
      count > 0 &&
      count <= 24 &&
      (width - (count - 1) * OmniSpacing.xxs) / count >= 8;

  /// 绘制按真实序号点亮的分段或总体填充。
  @override
  void paint(Canvas canvas, Size size) {
    // 共用圆角。
    const Radius radius = Radius.circular(OmniRadius.tiny);
    // 本次绘制的画笔。
    final Paint paint = Paint();
    if (isSegmented(size.width, steps.length)) {
      // 分段之间保留统一间距。
      final double segmentWidth =
          (size.width - (steps.length - 1) * OmniSpacing.xxs) / steps.length;
      for (int index = 0; index < steps.length; index += 1) {
        paint.color = steps[index].isCompleted ? foreground : background;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              index * (segmentWidth + OmniSpacing.xxs),
              0,
              segmentWidth,
              size.height,
            ),
            radius,
          ),
          paint,
        );
      }
      return;
    }
    paint.color = background;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, radius),
      paint,
    );
    paint.color = foreground;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, size.width * ratio, size.height),
        radius,
      ),
      paint,
    );
  }

  /// 步骤状态、颜色或动画变化后重绘。
  @override
  bool shouldRepaint(covariant _TodoProgressPainter oldDelegate) =>
      oldDelegate.steps != steps ||
      oldDelegate.ratio != ratio ||
      oldDelegate.foreground != foreground ||
      oldDelegate.background != background;
}

/// 待办看板与首页共用的双行进度任务。
class TodoProgressTaskTile extends ConsumerStatefulWidget {
  /// 当前任务。
  final TodoRecord todo;

  /// 打开结构编辑器。
  final VoidCallback onEdit;

  /// 删除任务。
  final VoidCallback onDelete;

  /// 在全部步骤完成后确认结束任务。
  final VoidCallback onConfirm;

  /// 可选移动象限入口。
  final VoidCallback? onMove;

  /// 是否正在提交或离场。
  final bool busy;

  /// 是否使用紧凑排版。
  final bool compact;

  /// 看板标题行内的可选拖动控件。
  final Widget? leading;

  /// 创建进度任务行。
  const TodoProgressTaskTile({
    required this.todo,
    required this.onEdit,
    required this.onDelete,
    required this.onConfirm,
    this.onMove,
    this.busy = false,
    this.compact = false,
    this.leading,
    super.key,
  });

  /// 创建行内进度提交与撤销状态。
  @override
  ConsumerState<TodoProgressTaskTile> createState() =>
      _TodoProgressTaskTileState();
}

/// 让两个任务列表共用串行提交、错误反馈和精确撤销。
class _TodoProgressTaskTileState extends ConsumerState<TodoProgressTaskTile> {
  /// 当前行是否正在提交进度变更。
  bool _submitting = false;

  /// 最近一次完成步骤的撤销提示。
  OmniMessageHandle? _undoMessage;

  /// 列表复用状态时清除属于旧任务的提示。
  @override
  void didUpdateWidget(covariant TodoProgressTaskTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.todo.id != widget.todo.id) _undoMessage?.dismiss();
  }

  /// 移除依赖当前任务行的反馈入口。
  @override
  void dispose() {
    _undoMessage?.dismiss();
    super.dispose();
  }

  /// 同步锁住当前行，业务提交在页面销毁后也继续执行。
  Future<void> _runProgressAction(Future<void> Function() action) async {
    if (_submitting || widget.busy) return;
    // 错误提示只属于发起操作时的任务。
    final String todoId = widget.todo.id;
    setState(() => _submitting = true);
    _undoMessage?.dismiss();
    try {
      await action();
    } catch (error) {
      if (mounted && widget.todo.id == todoId) {
        showOmniMessage(
          context,
          message: error is FormatException
              ? error.message.toString()
              : '进度更新失败，请重试。',
          tone: OmniMessageTone.error,
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// 只完成点击时选中的下一个步骤，不因后续流更新扩大操作范围。
  Future<void> _completeNext(TodoProgressStepRecord step, int index) async {
    // 提交前捕获仓储，避免切页后再读取 WidgetRef。
    final TodoRepository repository = ref.read(todoRepositoryProvider);
    // 当前任务的稳定身份。
    final String todoId = widget.todo.id;
    // 成功反馈使用点击时所见的步骤名称。
    final String stepLabel = todoProgressStepLabel(
      step,
      index,
      unit: widget.todo.progressUnit,
    );
    await _runProgressAction(() async {
      // 仓储只记录本次真正发生的变更，用于有条件撤销。
      final TodoProgressChange change = await repository
          .setProgressStepsCompleted(todoId, <String>[step.id], true);
      if (!mounted || widget.todo.id != todoId) return;
      if (change.changedCount == 0) {
        showOmniMessage(context, message: '该步骤已完成，进度已同步。');
        return;
      }
      _undoMessage?.dismiss();
      _undoMessage = showOmniMessage(
        context,
        message: '已完成“$stepLabel”',
        tone: OmniMessageTone.success,
        duration: const Duration(seconds: 6),
        actionLabel: '撤销',
        onAction: () => unawaited(
          _runProgressAction(() async {
            // 只撤销仍属于此次提交的状态，不覆盖后续修改。
            final bool restored = await repository.undoProgressChange(change);
            if (!mounted || widget.todo.id != todoId) return;
            showOmniMessage(
              context,
              message: restored ? '已撤销本次进度更新' : '该步骤已有后续修改，本次未撤销。',
              tone: restored
                  ? OmniMessageTone.success
                  : OmniMessageTone.warning,
            );
          }),
        ),
      );
    });
  }

  /// 构建总览、完成下一个入口和结构操作菜单。
  @override
  Widget build(BuildContext context) {
    // 本轮展示对应的最新任务记录。
    final TodoRecord todo = widget.todo;
    // 外部完成动画与内部进度提交都禁止重复操作。
    final bool busy = widget.busy || _submitting;
    // 进度读取状态供行内摘要和按钮共同使用。
    final AsyncValue<List<TodoProgressStepRecord>> stepsAsync = ref.watch(
      todoProgressStepsProvider(todo.id),
    );
    // 当前已加载的有效步骤。
    final List<TodoProgressStepRecord>? steps = stepsAsync.asData?.value;
    // 首个未完成步骤沿用仓储返回的用户排序，读取未就绪时禁用加一。
    final int nextIndex = stepsAsync.isLoading || stepsAsync.hasError
        ? -1
        : steps?.indexWhere((step) => !step.isCompleted) ?? -1;
    // 非空且全部完成时才显示确认入口。
    final bool ready =
        steps != null &&
        steps.isNotEmpty &&
        steps.every((step) => step.isCompleted);
    // 首页紧凑行使用固定三十二像素槽位，完整列表沿用平台复选框槽位。
    final Size statusSize = widget.compact
        ? const Size.square(OmniSize.control)
        : TodoCompletionCheckbox.tapSizeOf(context);
    // 首页进度条避让图标槽位留白，与蓝色图标左边缘对齐。
    final double progressInset =
        (widget.leading == null ? 0 : OmniSize.control + OmniSpacing.xxs) +
        (widget.compact ? (statusSize.width - OmniSize.icon) / 2 : 0);
    // 任务名称右侧的进度文案，读取失败仍明确反馈。
    final String label = stepsAsync.when(
      data: (steps) => _todoProgressSummaryLabel(todo, steps),
      loading: () => '正在读取进度…',
      error: (error, stack) => '进度读取失败',
    );
    // 任务整行沿用普通任务的悬停色与圆角。
    final OmniColors colors = OmniColors.of(context);

    /// 打开共享的步骤面板。
    void openProgress() => TodoProgressPanel.show(context, record: todo);
    return TodoTaskContextMenu(
      enabled: !busy,
      onEdit: widget.onEdit,
      onMove: widget.onMove,
      onDelete: widget.onDelete,
      child: Material(
        key: ValueKey<String>('progress-task-${todo.id}'),
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(OmniRadius.control),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey<String>('progress-task-surface-${todo.id}'),
          onTap: busy ? null : openProgress,
          borderRadius: BorderRadius.circular(OmniRadius.control),
          hoverColor: colors.ink.withValues(alpha: 0.04),
          highlightColor: Theme.of(context).platform == TargetPlatform.android
              ? Colors.transparent
              : colors.ink.withValues(alpha: 0.08),
          focusColor: colors.brand.withValues(alpha: 0.12),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: widget.compact ? OmniSpacing.xs : OmniSpacing.sm,
              vertical: OmniSpacing.xxs,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    if (widget.leading != null) ...<Widget>[
                      SizedBox(width: OmniSize.control, child: widget.leading),
                      const SizedBox(width: OmniSpacing.xxs),
                    ],
                    SizedBox.fromSize(
                      size: statusSize,
                      child: Icon(
                        key: ValueKey<String>('progress-status-${todo.id}'),
                        Icons.track_changes_rounded,
                        color: colors.brand,
                        size: OmniSize.icon,
                      ),
                    ),
                    if (widget.compact) const SizedBox(width: OmniSpacing.xxs),
                    Expanded(
                      child: Row(
                        children: <Widget>[
                          Flexible(
                            flex: 3,
                            child: Text(
                              todo.title,
                              key: ValueKey<String>(
                                'progress-title-${todo.id}',
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ),
                          const SizedBox(width: OmniSpacing.xs),
                          Flexible(
                            flex: 2,
                            child: Text(
                              label,
                              key: ValueKey<String>(
                                'progress-label-${todo.id}',
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (!todo.isCompleted && !ready && steps?.isEmpty != true)
                      // 禁用按钮仍消费点击，避免穿透到整行的打开面板操作。
                      GestureDetector(
                        excludeFromSemantics: true,
                        onTap: busy || nextIndex < 0 ? () {} : null,
                        child: OmniIconButton(
                          key: ValueKey<String>('progress-update-${todo.id}'),
                          tooltip: '完成下一个',
                          style: todoTaskActionButtonStyle(
                            context,
                            colors.brand,
                          ),
                          icon: const Icon(Icons.plus_one_rounded, size: 20),
                          onPressed: busy || nextIndex < 0
                              ? null
                              : () => unawaited(
                                  _completeNext(steps![nextIndex], nextIndex),
                                ),
                        ),
                      )
                    else
                      OmniButton(
                        key: ValueKey<String>(
                          ready && !todo.isCompleted
                              ? 'progress-confirm-${todo.id}'
                              : 'progress-update-${todo.id}',
                        ),
                        label: todo.isCompleted
                            ? '查看进度'
                            : ready
                            ? '确认完成'
                            : steps?.isEmpty == true
                            ? '补充步骤'
                            : '查看进度',
                        variant: OmniButtonVariant.text,
                        onPressed: busy
                            ? null
                            : todo.isCompleted
                            ? openProgress
                            : ready
                            ? widget.onConfirm
                            : steps?.isEmpty == true
                            ? widget.onEdit
                            : openProgress,
                      ),
                  ],
                ),
                if (steps?.isNotEmpty == true)
                  Padding(
                    padding: EdgeInsets.only(
                      left: progressInset,
                      top: OmniSpacing.xxs,
                    ),
                    child: TodoProgressBar(steps: steps!),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
