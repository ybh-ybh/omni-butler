import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/todos/presentation/todo_progress_panel.dart';
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
        // 已完成步骤总量。
        final int completed = steps.where((step) => step.isCompleted).length;
        // 总量为零不视为满进度。
        final bool ready = steps.isNotEmpty && completed == steps.length;
        // 单位不参与步骤标识或计算。
        final String unit = (todo.progressUnit?.trim() ?? '').isEmpty
            ? '步'
            : todo.progressUnit!.trim();
        // 同时包含进度和任务状态的可读文案。
        final String label = steps.isEmpty
            ? '暂无步骤，请补充步骤'
            : '已完成 $completed/${steps.length} $unit'
                  '${todo.isCompleted
                      ? ' · 已完成'
                      : ready
                      ? ' · 待确认完成'
                      : ''}';
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
                      TodoProgressBar(steps: steps, unit: todo.progressUnit),
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
class TodoProgressBar extends StatefulWidget {
  /// 按用户顺序排列的有效步骤。
  final List<TodoProgressStepRecord> steps;

  /// 未命名步骤使用的可选单位。
  final String? unit;

  /// 创建进度条。
  const TodoProgressBar({required this.steps, this.unit, super.key});

  /// 创建悬停说明状态。
  @override
  State<TodoProgressBar> createState() => _TodoProgressBarState();
}

/// 只在鼠标悬停时读取实际尺寸，避免影响首页固有尺寸测量。
class _TodoProgressBarState extends State<TodoProgressBar> {
  /// 当前悬停步骤的序号。
  int? _hoveredIndex;

  /// 构建无拖动手势的进度条及步骤提示。
  @override
  Widget build(BuildContext context) {
    // 当前配色的业务颜色。
    final OmniColors colors = OmniColors.of(context);
    // 当前已完成比例。
    final double ratio = widget.steps.isEmpty
        ? 0
        : widget.steps.where((step) => step.isCompleted).length /
              widget.steps.length;
    // 当前悬停步骤仍然存在时才展示对应名称。
    final int? index =
        _hoveredIndex != null && _hoveredIndex! < widget.steps.length
        ? _hoveredIndex
        : null;
    // 步骤提示不会把跳序完成误写成前若干步完成。
    final String tooltip = index == null
        ? '进度总览：已完成 ${widget.steps.where((step) => step.isCompleted).length}/${widget.steps.length}'
        : '${todoProgressStepLabel(widget.steps[index], index, unit: widget.unit)} · '
              '${widget.steps[index].isCompleted ? '已完成' : '未完成'}';
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        onExit: (_) => setState(() => _hoveredIndex = null),
        onHover: (event) {
          // 当前进度条的真实宽度。
          final double width = context.size?.width ?? 0;
          // 仅分段模式才将鼠标映射为步骤序号。
          final int? nextIndex =
              _TodoProgressPainter.isSegmented(width, widget.steps.length)
              ? ((event.localPosition.dx / width) * widget.steps.length)
                    .floor()
                    .clamp(0, widget.steps.length - 1)
              : null;
          if (nextIndex != _hoveredIndex) {
            setState(() => _hoveredIndex = nextIndex);
          }
        },
        child: ExcludeSemantics(
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(end: ratio),
            duration: OmniMotion.duration(context, OmniMotion.normal),
            builder:
                (BuildContext context, double animatedRatio, Widget? child) {
                  return SizedBox(
                    height: OmniSpacing.xs,
                    child: CustomPaint(
                      key: const ValueKey<String>('todo-progress-bar'),
                      painter: _TodoProgressPainter(
                        steps: widget.steps,
                        ratio: animatedRatio,
                        foreground: colors.brand,
                        background: colors.line,
                      ),
                    ),
                  );
                },
          ),
        ),
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
class TodoProgressTaskTile extends ConsumerWidget {
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

  /// 创建进度任务行。
  const TodoProgressTaskTile({
    required this.todo,
    required this.onEdit,
    required this.onDelete,
    required this.onConfirm,
    this.onMove,
    this.busy = false,
    this.compact = false,
    super.key,
  });

  /// 构建总览、更新入口和结构操作菜单。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 当前已加载的有效步骤。
    final List<TodoProgressStepRecord>? steps = ref
        .watch(todoProgressStepsProvider(todo.id))
        .asData
        ?.value;
    // 非空且全部完成时才显示确认入口。
    final bool ready =
        steps != null &&
        steps.isNotEmpty &&
        steps.every((step) => step.isCompleted);

    /// 打开共享的步骤面板。
    void openProgress() => TodoProgressPanel.show(context, record: todo);
    return Padding(
      key: ValueKey<String>('progress-task-${todo.id}'),
      padding: EdgeInsets.all(compact ? OmniSpacing.xxs : OmniSpacing.xs),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                Icons.track_changes_rounded,
                color: OmniColors.of(context).brand,
                size: OmniSize.icon,
              ),
              const SizedBox(width: OmniSpacing.xs),
              Expanded(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: busy ? null : openProgress,
                    borderRadius: BorderRadius.circular(OmniRadius.control),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: OmniSpacing.xs,
                      ),
                      child: Text(
                        todo.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
              ),
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
                    : '更新进度',
                variant: OmniButtonVariant.text,
                onPressed: busy
                    ? null
                    : todo.isCompleted
                    ? openProgress
                    : ready
                    ? onConfirm
                    : steps?.isEmpty == true
                    ? onEdit
                    : openProgress,
              ),
              OmniPopupMenuButton<String>(
                tooltip: '更多操作',
                onSelected: (String value) {
                  if (busy) return;
                  if (value == 'edit') onEdit();
                  if (value == 'delete') onDelete();
                  if (value == 'move') onMove?.call();
                },
                itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                  OmniPopupMenuItem<String>(
                    value: 'edit',
                    label: '编辑',
                    icon: Icons.edit_outlined,
                    enabled: !busy,
                  ),
                  if (onMove != null)
                    OmniPopupMenuItem<String>(
                      value: 'move',
                      label: '移动象限',
                      icon: Icons.drive_file_move_outline,
                      enabled: !busy,
                    ),
                  OmniPopupMenuItem<String>(
                    value: 'delete',
                    label: '移入回收站',
                    icon: Icons.delete_outline_rounded,
                    danger: true,
                    enabled: !busy,
                  ),
                ],
              ),
            ],
          ),
          TodoProgressSummaryView(
            todo: todo,
            onTap: busy ? null : openProgress,
          ),
        ],
      ),
    );
  }
}
