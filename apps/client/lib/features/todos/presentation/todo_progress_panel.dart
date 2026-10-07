import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:omni_butler/features/todos/presentation/todo_editor_dialog.dart';
import 'package:omni_butler/features/todos/presentation/todo_progress_widgets.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 所有待办入口共用的逐项进度面板。
class TodoProgressPanel extends ConsumerStatefulWidget {
  /// 打开面板时的任务快照，后续以实时记录为准。
  final TodoRecord record;

  /// 创建进度面板。
  const TodoProgressPanel({required this.record, super.key});

  /// 在当前窗口内打开进度面板。
  static Future<void> show(
    BuildContext context, {
    required TodoRecord record,
  }) async {
    await showOmniSideSheet<void>(
      context,
      builder: (BuildContext context) => TodoProgressPanel(record: record),
    );
  }

  /// 创建即时保存和批量预览状态。
  @override
  ConsumerState<TodoProgressPanel> createState() => _TodoProgressPanelState();
}

/// 管理步骤提交、失败重试和有条件的撤销。
class _TodoProgressPanelState extends ConsumerState<TodoProgressPanel> {
  /// 批量完成数量输入。
  final TextEditingController _batchController = TextEditingController();

  /// 当前是否存在未结束的提交。
  bool _busy = false;

  /// 当前保存或读取错误。
  String? _error;

  /// 失败操作对应的稳定重试回调。
  Future<void> Function()? _retry;

  /// 最近一次步骤更新的撤销提示。
  OmniMessageHandle? _undoMessage;

  /// 释放面板内输入和提示。
  @override
  void dispose() {
    _batchController.dispose();
    _undoMessage?.dismiss();
    super.dispose();
  }

  /// 串行执行操作，失败时保留明确的重试入口。
  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _retry = null;
    });
    try {
      await operation();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error is FormatException
              ? error.message.toString()
              : '保存失败，进度未更新，请重试。';
          _retry = operation;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 使用稳定步骤标识提交一次变更并提供六秒撤销。
  Future<void> _change(List<String> ids, bool completed) async {
    // 点击当下确定的步骤集合，重试不自动扩展到下一批。
    final List<String> stableIds = List<String>.unmodifiable(ids);
    // 页面销毁后仍可执行的仓储。
    final TodoRepository repository = ref.read(todoRepositoryProvider);
    await _run(() async {
      // 仓储记录精确变更，撤销不会覆盖之后的新操作。
      final TodoProgressChange change = await repository
          .setProgressStepsCompleted(widget.record.id, stableIds, completed);
      if (!mounted) return;
      _undoMessage?.dismiss();
      _undoMessage = showOmniMessage(
        context,
        message: completed
            ? '已更新 ${change.changedCount} 个步骤'
            : '已将 ${change.changedCount} 个步骤设为未完成',
        tone: OmniMessageTone.success,
        duration: const Duration(seconds: 6),
        actionLabel: '撤销',
        onAction: () => unawaited(
          _run(() async {
            // 只有未被后续写入覆盖的变更才允许撤销。
            final bool restored = await repository.undoProgressChange(change);
            if (!restored && mounted) {
              setState(() => _error = '这些步骤已有后续修改，本次撤销未覆盖新进度。');
            }
          }),
        ),
      );
    });
  }

  /// 确认任务完成，保留面板中的已完成结果。
  Future<void> _confirm(TodoRecord todo) async {
    // 当前任务仓储。
    final TodoRepository repository = ref.read(todoRepositoryProvider);
    await _run(() async {
      await repository.confirmProgressTask(todo.id);
      if (mounted) {
        _undoMessage?.dismiss();
        showOmniMessage(
          context,
          message: '已完成“${todo.title}”',
          tone: OmniMessageTone.success,
        );
      }
    });
  }

  /// 重新打开任务时保留所有步骤状态。
  Future<void> _reopen(TodoRecord todo) async {
    // 当前任务仓储。
    final TodoRepository repository = ref.read(todoRepositoryProvider);
    await _run(() => repository.setCompleted(todo.id, false));
  }

  /// 构建持续反映数据库状态的步骤面板。
  @override
  Widget build(BuildContext context) {
    // 当前任务最新记录。
    final AsyncValue<TodoRecord?> todoAsync = ref.watch(
      todoByIdProvider(widget.record.id),
    );
    // 当前任务有效步骤。
    final AsyncValue<List<TodoProgressStepRecord>> stepsAsync = ref.watch(
      todoProgressStepsProvider(widget.record.id),
    );
    // 已读取的任务，不使用旧快照覆盖删除结果。
    final TodoRecord? todo = todoAsync.asData?.value;
    // 已读取的步骤。
    final List<TodoProgressStepRecord> steps =
        stepsAsync.asData?.value ?? <TodoProgressStepRecord>[];
    // 只有两份数据都就绪后才能修改。
    final bool loaded =
        todo != null && todo.deletedAt == null && stepsAsync.hasValue;
    // 非空全部完成才进入待确认状态。
    final bool ready =
        loaded && steps.isNotEmpty && steps.every((step) => step.isCompleted);
    return OmniSideSheetScaffold(
      title: todo?.title ?? widget.record.title,
      canClose: !_busy,
      actions: <Widget>[
        if (loaded)
          OmniButton(
            key: const ValueKey<String>('todo-progress-edit'),
            label: '编辑任务',
            variant: OmniButtonVariant.text,
            onPressed: _busy
                ? null
                : () => TodoEditorDialog.show(context, record: todo),
          ),
        OmniButton(
          label: '关闭',
          variant: OmniButtonVariant.secondary,
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
        ),
        if (loaded && todo.isCompleted)
          OmniButton(
            key: const ValueKey<String>('todo-progress-reopen'),
            label: '重新打开',
            loading: _busy,
            onPressed: _busy ? null : () => unawaited(_reopen(todo)),
          )
        else if (ready)
          OmniButton(
            key: const ValueKey<String>('todo-progress-confirm'),
            label: '确认完成',
            loading: _busy,
            onPressed: _busy ? null : () => unawaited(_confirm(todo)),
          ),
      ],
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(OmniSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (todoAsync.hasError || stepsAsync.hasError)
              OmniButton(
                label: '读取失败，重试',
                variant: OmniButtonVariant.secondary,
                onPressed: () {
                  ref.invalidate(todoByIdProvider(widget.record.id));
                  ref.invalidate(todoProgressStepsProvider(widget.record.id));
                },
              )
            else if (todoAsync.isLoading || stepsAsync.isLoading)
              const Text('正在读取进度…')
            else if (todo == null || todo.deletedAt != null)
              const Text('任务已不存在或已移入回收站。')
            else ...<Widget>[
              TodoProgressSummaryView(todo: todo),
              const SizedBox(height: OmniSpacing.sm),
              Text(
                todo.isCompleted
                    ? '任务已完成。重新打开后可以修改步骤，原有进度会保留。'
                    : '点击步骤即可标为完成或未完成，修改自动保存。全部步骤完成后仍需手动确认。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (_error != null) ...<Widget>[
                const SizedBox(height: OmniSpacing.sm),
                Text(
                  _error!,
                  style: TextStyle(color: OmniColors.of(context).danger),
                ),
                if (_retry != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OmniButton(
                      label: '重试',
                      variant: OmniButtonVariant.secondary,
                      onPressed: _busy ? null : () => unawaited(_run(_retry!)),
                    ),
                  ),
              ],
              const SizedBox(height: OmniSpacing.md),
              if (steps.isEmpty)
                OmniButton(
                  label: '补充步骤',
                  onPressed: _busy || todo.isCompleted
                      ? null
                      : () => TodoEditorDialog.show(context, record: todo),
                )
              else ...<Widget>[
                if (!todo.isCompleted) _buildQuickActions(todo, steps),
                const SizedBox(height: OmniSpacing.md),
                for (int index = 0; index < steps.length; index += 1)
                  Padding(
                    padding: const EdgeInsets.only(bottom: OmniSpacing.xs),
                    child: _ProgressStepBlock(
                      step: steps[index],
                      index: index,
                      unit: todo.progressUnit,
                      enabled: !_busy && !todo.isCompleted,
                      onTap: () => unawaited(
                        _change(<String>[
                          steps[index].id,
                        ], !steps[index].isCompleted),
                      ),
                    ),
                  ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  /// 构建带明确目标名称的加一及批量数量预览。
  Widget _buildQuickActions(
    TodoRecord todo,
    List<TodoProgressStepRecord> steps,
  ) {
    // 当前按顺序排列的未完成步骤。
    final List<TodoProgressStepRecord> pending = steps
        .where((step) => !step.isCompleted)
        .toList(growable: false);
    if (pending.isEmpty) return const Text('所有步骤已完成，可以确认完成任务。');
    // 用户请求的批量数量。
    final int? amount = int.tryParse(_batchController.text.trim());
    // 批量输入只接受存在的正整数范围。
    final bool validAmount =
        amount != null && amount > 0 && amount <= pending.length;
    // 预览集合与提交集合共用相同稳定步骤标识。
    final List<TodoProgressStepRecord> preview = validAmount
        ? pending.take(amount).toList(growable: false)
        : <TodoProgressStepRecord>[];
    // 下一个未完成步骤的实际用户顺序。
    final int nextIndex = steps.indexWhere(
      (step) => step.id == pending.first.id,
    );
    return OmniPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            '下一个：${todoProgressStepLabel(pending.first, nextIndex, unit: todo.progressUnit)}',
          ),
          const SizedBox(height: OmniSpacing.xs),
          Align(
            alignment: Alignment.centerLeft,
            child: OmniButton(
              key: const ValueKey<String>('todo-progress-next'),
              label: '完成下一个 +1',
              variant: OmniButtonVariant.text,
              onPressed: _busy
                  ? null
                  : () => unawaited(_change(<String>[pending.first.id], true)),
            ),
          ),
          const SizedBox(height: OmniSpacing.md),
          OmniTextField(
            key: const ValueKey<String>('todo-progress-batch-count'),
            controller: _batchController,
            enabled: !_busy,
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: '批量完成数量',
              hintText: '1 至 ${pending.length}',
              errorText: _batchController.text.isNotEmpty && !validAmount
                  ? '请输入 1 至 ${pending.length} 的整数'
                  : null,
            ),
          ),
          if (preview.isNotEmpty) ...<Widget>[
            const SizedBox(height: OmniSpacing.xs),
            Text('将按顺序完成以下 ${preview.length} 个未完成步骤：'),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: SingleChildScrollView(
                child: Text(
                  preview
                      .map(
                        (step) => todoProgressStepLabel(
                          step,
                          steps.indexWhere(
                            (candidate) => candidate.id == step.id,
                          ),
                          unit: todo.progressUnit,
                        ),
                      )
                      .join('\n'),
                ),
              ),
            ),
            const SizedBox(height: OmniSpacing.xs),
            Align(
              alignment: Alignment.centerLeft,
              child: OmniButton(
                key: const ValueKey<String>('todo-progress-batch-submit'),
                label: '确认完成这 ${preview.length} 个步骤',
                variant: OmniButtonVariant.text,
                onPressed: _busy
                    ? null
                    : () => unawaited(
                        _change(
                          preview
                              .map((step) => step.id)
                              .toList(growable: false),
                          true,
                        ),
                      ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 具有独立按钮语义的步骤块，不使用子任务树结构。
class _ProgressStepBlock extends StatelessWidget {
  /// 当前步骤。
  final TodoProgressStepRecord step;

  /// 当前可见序号。
  final int index;

  /// 空名称展示时使用的单位。
  final String? unit;

  /// 当前是否允许修改。
  final bool enabled;

  /// 切换该步骤完成状态。
  final VoidCallback onTap;

  /// 创建可即时保存的步骤块。
  const _ProgressStepBlock({
    required this.step,
    required this.index,
    this.unit,
    required this.enabled,
    required this.onTap,
  });

  /// 构建带文字、图形和读屏状态的可聚焦按钮。
  @override
  Widget build(BuildContext context) {
    // 当前主题色。
    final OmniColors colors = OmniColors.of(context);
    // 空名称使用展示占位。
    final String label = todoProgressStepLabel(step, index, unit: unit);
    return Semantics(
      button: true,
      enabled: enabled,
      checked: step.isCompleted,
      label: '$label，${step.isCompleted ? '已完成' : '未完成'}',
      child: Material(
        color: step.isCompleted ? colors.brandSoft : colors.paperSubtle,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(OmniRadius.control),
          side: BorderSide(
            color: step.isCompleted ? colors.brand : colors.line,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey<String>('todo-progress-step-${step.id}'),
          onTap: enabled ? onTap : null,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: OmniDensity.controlHeight(context),
            ),
            child: Padding(
              padding: const EdgeInsets.all(OmniSpacing.sm),
              child: ExcludeSemantics(
                child: Row(
                  children: <Widget>[
                    Icon(
                      step.isCompleted
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked_rounded,
                      color: step.isCompleted ? colors.brand : colors.muted,
                      size: OmniSize.icon,
                    ),
                    const SizedBox(width: OmniSpacing.xs),
                    Expanded(child: Text(label)),
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
