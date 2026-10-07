import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/todos/data/todo_priority_quadrant.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:omni_butler/features/todos/presentation/todo_priority_quadrant_style.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 待办新增与编辑对话框。
class TodoEditorDialog extends ConsumerStatefulWidget {
  /// 可选现有待办。
  final TodoRecord? record;

  /// 新增子任务时所属的主任务。
  final TodoRecord? parent;

  /// 默认所属日期。
  final DateTime initialDate;

  /// 新增待办时默认选中的优先象限。
  final TodoPriorityQuadrant initialPriorityQuadrant;

  /// 创建待办编辑对话框。
  TodoEditorDialog({
    this.record,
    this.parent,
    DateTime? initialDate,
    this.initialPriorityQuadrant = TodoPriorityQuadrant.importantNotUrgent,
    super.key,
  }) : initialDate = DateUtils.dateOnly(initialDate ?? DateTime.now());

  /// 显示待办编辑对话框。
  static Future<bool?> show(
    BuildContext context, {
    TodoRecord? record,
    TodoRecord? parent,
    DateTime? initialDate,
    TodoPriorityQuadrant initialPriorityQuadrant =
        TodoPriorityQuadrant.importantNotUrgent,
  }) {
    return showOmniSideSheet<bool>(
      context,
      builder: (BuildContext context) {
        return TodoEditorDialog(
          record: record,
          parent: parent,
          initialDate: initialDate,
          initialPriorityQuadrant: initialPriorityQuadrant,
        );
      },
    );
  }

  /// 创建待办编辑状态。
  @override
  ConsumerState<TodoEditorDialog> createState() => _TodoEditorDialogState();
}

/// 编辑器中的单个优先象限选项。
class _PriorityQuadrantOption extends StatelessWidget {
  /// 当前象限。
  final TodoPriorityQuadrant quadrant;

  /// 是否已经选中。
  final bool selected;

  /// 选中回调。
  final VoidCallback onSelected;

  /// 创建优先象限选项。
  const _PriorityQuadrantOption({
    required this.quadrant,
    required this.selected,
    required this.onSelected,
  });

  /// 构建可聚焦的象限选择卡。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前象限强调色。
    final Color accentColor = quadrant.color(colors);

    return Semantics(
      button: true,
      selected: selected,
      label: '${quadrant.label}，${quadrant.actionLabel}',
      child: Material(
        color: selected
            ? accentColor.withValues(alpha: 0.12)
            : colors.paperSubtle,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(OmniRadius.control),
          side: BorderSide(
            color: selected ? accentColor : colors.line,
            width: selected ? 1.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onSelected,
          child: ConstrainedBox(
            key: ValueKey<String>('todo-priority-option-${quadrant.value}'),
            constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: OmniSpacing.sm,
                vertical: OmniSpacing.xs,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(quadrant.icon, size: 17, color: accentColor),
                      const SizedBox(width: OmniSpacing.xs),
                      Expanded(
                        child: Text(
                          quadrant.label,
                          style: TextStyle(
                            color: selected ? accentColor : colors.ink,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (selected)
                        Icon(
                          Icons.check_circle_rounded,
                          size: 17,
                          color: accentColor,
                        ),
                    ],
                  ),
                  const SizedBox(height: OmniSpacing.xs),
                  Text(
                    quadrant.actionLabel,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: accentColor,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 待办编辑状态。
class _TodoEditorDialogState extends ConsumerState<TodoEditorDialog> {
  /// 表单校验键。
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  /// 标题输入控制器。
  late final TextEditingController _titleController;

  /// 描述输入控制器。
  late final TextEditingController _descriptionController;

  /// 进度单位输入。
  late final TextEditingController _progressUnitController;

  /// 当前步骤总数输入，点击应用后更新结构。
  final TextEditingController _stepCountController = TextEditingController(
    text: '1',
  );

  /// 保存时固定的任务类型，编辑既有任务不允许转换。
  late TodoTaskType _taskType;

  /// 待保存的有序步骤草稿。
  final List<_EditableProgressStep> _progressSteps = <_EditableProgressStep>[];

  /// 打开编辑器时的结构基线，不包含可能持续变化的完成状态。
  final List<TodoProgressStepDraft> _progressStepsBaseline =
      <TodoProgressStepDraft>[];

  /// 已移除但可能仍被当前帧使用的输入控制器。
  final List<TextEditingController> _retiredStepControllers =
      <TextEditingController>[];

  /// 结构是否仍在读取。
  bool _loadingSteps = false;

  /// 读取失败时禁止用不完整结构覆盖原有步骤。
  bool _stepsLoadFailed = false;

  /// 靠近进度设置展示的输入或读取错误。
  String? _progressError;

  /// 靠近保存操作展示的错误。
  String? _saveError;

  /// 当前所属日期。
  late DateTime _scheduledDate;

  /// 当前优先象限。
  late TodoPriorityQuadrant _priorityQuadrant;

  /// 当前重复规则。
  late TodoRepeatRule _repeatRule;

  /// 可选截止时间。
  DateTime? _dueAt;

  /// 可选提醒时间。
  DateTime? _reminderAt;

  /// 是否正在保存。
  bool _saving = false;

  /// 初始化编辑表单。
  @override
  void initState() {
    super.initState();
    // 当前待办记录。
    final TodoRecord? record = widget.record;
    _titleController = TextEditingController(text: record?.title ?? '');
    _descriptionController = TextEditingController(
      text: record?.description ?? '',
    );
    _progressUnitController = TextEditingController(
      text: record?.progressUnit ?? '',
    );
    _taskType = record?.taskType == 'progress'
        ? TodoTaskType.progress
        : TodoTaskType.normal;
    if (_taskType == TodoTaskType.progress && record != null) {
      _loadingSteps = true;
      _loadProgressSteps();
    } else {
      _progressSteps.add(_EditableProgressStep());
    }
    _scheduledDate = DateUtils.dateOnly(
      record?.scheduledDate ??
          widget.parent?.scheduledDate ??
          widget.initialDate,
    );
    _priorityQuadrant = TodoPriorityQuadrant.fromValue(
      record?.priorityQuadrant ??
          widget.parent?.priorityQuadrant ??
          widget.initialPriorityQuadrant.value,
    );
    _repeatRule = TodoRepeatRule.values.firstWhere(
      (TodoRepeatRule value) => value.name == record?.repeatRule,
      orElse: () => TodoRepeatRule.none,
    );
    _dueAt = record?.dueAt;
    _reminderAt = record?.reminderAt;
  }

  /// 释放文本输入控制器。
  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _progressUnitController.dispose();
    _stepCountController.dispose();
    for (final _EditableProgressStep step in _progressSteps) {
      step.controller.dispose();
    }
    for (final TextEditingController controller in _retiredStepControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  /// 构建待办编辑表单。
  @override
  Widget build(BuildContext context) {
    // 是否编辑现有待办。
    final bool isEditing = widget.record != null;
    // 当前是否新增或编辑子任务。
    final bool isChild =
        widget.parent != null || widget.record?.parentId != null;

    return OmniSideSheetScaffold(
      onWindowsEnter: _saving || _loadingSteps || _stepsLoadFailed
          ? null
          : _save,
      title: isEditing
          ? isChild
                ? '编辑子任务'
                : '编辑待办'
          : isChild
          ? '新增子任务'
          : '新增待办',
      canClose: !_saving,
      actions: <Widget>[
        OmniButton(
          label: '取消',
          variant: OmniButtonVariant.secondary,
          onPressed: _saving ? null : () => Navigator.pop(context, false),
        ),
        OmniButton(
          label: _saving ? '正在保存' : '保存',
          icon: Icons.save_outlined,
          loading: _saving,
          onPressed: _saving || _loadingSteps || _stepsLoadFailed
              ? null
              : _save,
        ),
      ],
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(OmniSpacing.xl),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                widget.parent == null
                    ? '先保存到本机，联网后再同步。'
                    : '所属主任务：${widget.parent!.title}；计划日期和象限跟随主任务。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: OmniSpacing.lg),
              if (!isChild && !isEditing) ...<Widget>[
                LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    return OmniSlidingSegmentedControl<TodoTaskType>(
                      key: const ValueKey<String>('todo-task-type'),
                      options: TodoTaskType.values,
                      selected: _taskType,
                      width: constraints.maxWidth,
                      labelBuilder: (TodoTaskType type) =>
                          type == TodoTaskType.progress ? '进度任务' : '普通任务',
                      onChanged: (TodoTaskType type) {
                        if (_saving) return;
                        setState(() {
                          _taskType = type;
                          if (type == TodoTaskType.progress) {
                            _repeatRule = TodoRepeatRule.none;
                          }
                        });
                      },
                    );
                  },
                ),
                const SizedBox(height: OmniSpacing.md),
              ],
              OmniTextFormField(
                controller: _titleController,
                autofocus: true,
                maxLength: 200,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: '标题',
                  hintText: '例如：整理本周发票',
                ),
                validator: (String? value) {
                  return value == null || value.trim().isEmpty
                      ? '请输入待办标题'
                      : null;
                },
              ),
              const SizedBox(height: OmniSpacing.sm),
              OmniTextFormField(
                controller: _descriptionController,
                maxLines: 3,
                decoration: const InputDecoration(labelText: '描述（可选）'),
              ),
              const SizedBox(height: OmniSpacing.md),
              if (_taskType == TodoTaskType.progress) ...<Widget>[
                _buildProgressSettings(),
                const SizedBox(height: OmniSpacing.md),
              ],
              if (!isChild) ...<Widget>[
                Text('优先象限', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: OmniSpacing.xs),
                LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    // 单个象限选项的可用宽度。
                    final double optionWidth =
                        (constraints.maxWidth - OmniSpacing.xs) / 2;
                    return Wrap(
                      spacing: OmniSpacing.xs,
                      runSpacing: OmniSpacing.xs,
                      children: <Widget>[
                        for (final TodoPriorityQuadrant quadrant
                            in todoPriorityQuadrantMatrixOrder)
                          SizedBox(
                            width: optionWidth,
                            child: _PriorityQuadrantOption(
                              quadrant: quadrant,
                              selected: quadrant == _priorityQuadrant,
                              onSelected: () {
                                setState(() => _priorityQuadrant = quadrant);
                              },
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ],
              const SizedBox(height: OmniSpacing.md),
              OmniPanel(
                padding: EdgeInsets.zero,
                child: ExpansionTile(
                  key: const ValueKey<String>('todo-time-settings'),
                  initiallyExpanded: false,
                  leading: const Icon(Icons.schedule_outlined),
                  title: const Text('时间设置'),
                  subtitle: const Text('计划日期、截止与提醒'),
                  tilePadding: const EdgeInsets.symmetric(
                    horizontal: OmniSpacing.md,
                  ),
                  childrenPadding: const EdgeInsets.fromLTRB(
                    OmniSpacing.md,
                    0,
                    OmniSpacing.md,
                    OmniSpacing.md,
                  ),
                  children: <Widget>[
                    if (!isChild) ...<Widget>[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '计划日期',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                      ),
                      const SizedBox(height: OmniSpacing.xs),
                      OmniDatePickerButton(
                        value: _scheduledDate,
                        initialDate: _scheduledDate,
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                        label: DateFormat('yyyy年M月d日').format(_scheduledDate),
                        onChanged: (DateTime selected) {
                          setState(() => _scheduledDate = selected);
                        },
                      ),
                      const SizedBox(height: OmniSpacing.md),
                    ],
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '截止与提醒',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                    const SizedBox(height: OmniSpacing.xs),
                    _buildDateTimeControls(
                      value: _dueAt,
                      defaultHour: 18,
                      emptyDateLabel: '设置截止日期',
                      dateIcon: Icons.flag_outlined,
                      clearTooltip: '清除截止时间',
                      onChanged: (DateTime? value) =>
                          setState(() => _dueAt = value),
                    ),
                    const SizedBox(height: OmniSpacing.xs),
                    _buildDateTimeControls(
                      value: _reminderAt,
                      defaultHour: 9,
                      emptyDateLabel: '设置提醒日期',
                      dateIcon: Icons.notifications_outlined,
                      clearTooltip: '清除提醒时间',
                      onChanged: (DateTime? value) =>
                          setState(() => _reminderAt = value),
                    ),
                    if (!isChild &&
                        _taskType == TodoTaskType.normal) ...<Widget>[
                      const SizedBox(height: OmniSpacing.md),
                      OmniDropdownButtonFormField<TodoRepeatRule>(
                        initialValue: _repeatRule,
                        decoration: const InputDecoration(labelText: '重复'),
                        items: <DropdownMenuItem<TodoRepeatRule>>[
                          for (final TodoRepeatRule rule
                              in TodoRepeatRule.values)
                            DropdownMenuItem<TodoRepeatRule>(
                              value: rule,
                              child: Text(_repeatLabel(rule)),
                            ),
                        ],
                        onChanged: (TodoRepeatRule? value) {
                          if (value != null) {
                            setState(() => _repeatRule = value);
                          }
                        },
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: OmniSpacing.xl),
              if (_saveError != null)
                Text(
                  _saveError!,
                  style: TextStyle(color: OmniColors.of(context).danger),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 读取结构一次，后续输入不被数据流刷新覆盖。
  Future<void> _loadProgressSteps() async {
    try {
      // 仓储中的最新有效步骤。
      final List<TodoProgressStepRecord> steps = await ref
          .read(todoRepositoryProvider)
          .watchProgressSteps(widget.record!.id)
          .first;
      if (!mounted) return;
      setState(() {
        _progressSteps.addAll(
          steps.map(
            (step) => _EditableProgressStep(
              id: step.id,
              name: step.name,
              completed: step.isCompleted,
            ),
          ),
        );
        _stepCountController.text = _progressSteps.length.toString();
        _progressStepsBaseline.addAll(
          steps.map(
            (step) => TodoProgressStepDraft(id: step.id, name: step.name),
          ),
        );
        _loadingSteps = false;
        _stepsLoadFailed = false;
        _progressError = null;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadingSteps = false;
          _stepsLoadFailed = true;
          _progressError = '步骤读取失败，请重试后再保存。';
        });
      }
    }
  }

  /// 构建与任务元数据分组的步骤结构编辑器。
  Widget _buildProgressSettings() {
    // 完成历史的步骤必须重新打开任务后再修改。
    final bool readOnly = widget.record?.isCompleted == true;
    // 结构编辑的统一可用状态。
    final bool enabled =
        !_saving && !_loadingSteps && !_stepsLoadFailed && !readOnly;
    return OmniPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('进度设置', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: OmniSpacing.xs),
          Text(
            readOnly ? '任务已完成，重新打开后才能修改步骤。' : '步骤可跳序完成，名称可留空。进度任务不支持子任务和重复。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: OmniSpacing.sm),
          OmniTextFormField(
            key: const ValueKey<String>('todo-progress-unit'),
            controller: _progressUnitController,
            enabled: enabled,
            maxLength: 10,
            decoration: const InputDecoration(
              labelText: '单位（可选）',
              hintText: '例如：章、节、次',
            ),
          ),
          const SizedBox(height: OmniSpacing.xs),
          if (widget.record != null)
            Text('步骤总数：${_progressSteps.length}；通过下方增删调整')
          else
            Row(
              children: <Widget>[
                Expanded(
                  child: OmniTextFormField(
                    key: const ValueKey<String>('todo-progress-total'),
                    controller: _stepCountController,
                    enabled: enabled,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '步骤总数',
                      helperText: '1 至 1000',
                    ),
                    validator: (String? value) {
                      // 用户输入的有效步骤数量。
                      final int? count = int.tryParse(value?.trim() ?? '');
                      return count == null || count < 1 || count > 1000
                          ? '请输入 1 至 1000 的整数'
                          : null;
                    },
                  ),
                ),
                const SizedBox(width: OmniSpacing.xs),
                OmniButton(
                  key: const ValueKey<String>('todo-progress-apply-total'),
                  label: '应用数量',
                  variant: OmniButtonVariant.text,
                  onPressed: enabled ? _applyStepCount : null,
                ),
              ],
            ),
          if (_progressError != null) ...<Widget>[
            Text(
              _progressError!,
              style: TextStyle(color: OmniColors.of(context).danger),
            ),
            if (_progressSteps.isEmpty && widget.record != null)
              OmniButton(
                label: '重新读取步骤',
                variant: OmniButtonVariant.text,
                onPressed: _loadingSteps
                    ? null
                    : () {
                        setState(() => _loadingSteps = true);
                        _loadProgressSteps();
                      },
              ),
          ],
          if (_loadingSteps) const Text('正在读取步骤…'),
          const SizedBox(height: OmniSpacing.sm),
          ExpansionTile(
            key: const ValueKey<String>('todo-progress-step-names'),
            initiallyExpanded: widget.record != null,
            title: const Text('步骤名称（可选）'),
            subtitle: const Text('留空时按序号和单位显示'),
            children: <Widget>[
              SizedBox(
                height: _progressSteps.isEmpty ? 0 : 280,
                child: ListView.builder(
                  itemCount: _progressSteps.length,
                  itemBuilder: (BuildContext context, int index) {
                    // 当前结构草稿，控制器与稳定对象绑定而非序号。
                    final _EditableProgressStep step = _progressSteps[index];
                    return Padding(
                      key: ObjectKey(step),
                      padding: const EdgeInsets.only(bottom: OmniSpacing.xs),
                      child: Column(
                        children: <Widget>[
                          OmniTextFormField(
                            controller: step.controller,
                            enabled: enabled,
                            maxLength: 200,
                            decoration: InputDecoration(
                              labelText: '步骤 ${index + 1}（名称可选）',
                              helperText: step.completed
                                  ? '已完成，改名或移动不会丢失进度'
                                  : null,
                            ),
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: <Widget>[
                              OmniIconButton(
                                tooltip: '上移步骤 ${index + 1}',
                                onPressed: enabled && index > 0
                                    ? () => _moveStep(index, index - 1)
                                    : null,
                                icon: const Icon(Icons.arrow_upward_rounded),
                              ),
                              OmniIconButton(
                                tooltip: '下移步骤 ${index + 1}',
                                onPressed:
                                    enabled && index < _progressSteps.length - 1
                                    ? () => _moveStep(index, index + 1)
                                    : null,
                                icon: const Icon(Icons.arrow_downward_rounded),
                              ),
                              OmniIconButton(
                                tooltip: '删除步骤 ${index + 1}',
                                onPressed: enabled && _progressSteps.length > 1
                                    ? () => _removeSteps(
                                        <_EditableProgressStep>[step],
                                      )
                                    : null,
                                icon: const Icon(Icons.delete_outline_rounded),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: OmniButton(
              label: '添加步骤',
              icon: Icons.add_rounded,
              variant: OmniButtonVariant.text,
              onPressed: enabled && _progressSteps.length < 1000
                  ? () => setState(() {
                      _progressSteps.add(_EditableProgressStep());
                      _stepCountController.text = _progressSteps.length
                          .toString();
                    })
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  /// 应用步骤总数，减少有内容的步骤前明确确认。
  Future<bool> _applyStepCount() async {
    // 待应用的正整数总数。
    final int? count = int.tryParse(_stepCountController.text.trim());
    if (count == null || count < 1 || count > 1000) {
      setState(() => _progressError = '步骤总数必须是 1 至 1000 的整数。');
      return false;
    }
    if (count < _progressSteps.length) {
      return _removeSteps(_progressSteps.skip(count).toList(growable: false));
    } else {
      setState(() {
        while (_progressSteps.length < count) {
          _progressSteps.add(_EditableProgressStep());
        }
        _progressError = null;
      });
    }
    return true;
  }

  /// 删除有名称或已完成步骤前展示具体影响。
  Future<bool> _removeSteps(List<_EditableProgressStep> removed) async {
    if (removed.any(
      (step) => step.completed || step.controller.text.trim().isNotEmpty,
    )) {
      // 当前操作会丢失的已命名或已完成步骤数量。
      final int meaningfulCount = removed
          .where(
            (step) => step.completed || step.controller.text.trim().isNotEmpty,
          )
          .length;
      // 删除后仍保留的完整结构。
      final List<_EditableProgressStep> remaining = _progressSteps
          .where((step) => !removed.contains(step))
          .toList(growable: false);
      // 用原始序号与名称列出此次删除的影响。
      final String affectedNames = removed
          .take(8)
          .map((step) {
            // 删除前的可见序号。
            final int number = _progressSteps.indexOf(step) + 1;
            return '$number. ${step.controller.text.trim().isEmpty ? '未命名' : step.controller.text.trim()}${step.completed ? '（已完成）' : ''}';
          })
          .join('\n');
      // 用户对这次结构删除的明确选择。
      final bool confirmed = await showOmniConfirmDialog(
        context,
        title: '删除这些步骤？',
        message:
            '将删除 ${removed.length} 个步骤，其中 $meaningfulCount 个已有名称或完成记录。\n$affectedNames${removed.length > 8 ? '\n另有 ${removed.length - 8} 个步骤' : ''}\n删除后进度为 ${remaining.where((step) => step.completed).length}/${remaining.length}。保存任务后生效。',
        confirmLabel: '删除步骤',
        danger: true,
      );
      if (!confirmed || !mounted) {
        if (mounted) {
          _stepCountController.text = _progressSteps.length.toString();
        }
        return false;
      }
    }
    if (!mounted) return false;
    setState(() {
      for (final _EditableProgressStep step in removed) {
        _progressSteps.remove(step);
        _retiredStepControllers.add(step.controller);
      }
      _stepCountController.text = _progressSteps.length.toString();
      _progressError = null;
    });
    return true;
  }

  /// 改变列表顺序但保持步骤标识和完成状态。
  void _moveStep(int from, int to) {
    setState(() {
      // 正在移动的稳定步骤草稿。
      final _EditableProgressStep step = _progressSteps.removeAt(from);
      _progressSteps.insert(to, step);
    });
  }

  /// 只比较结构，元数据修改不覆盖其他窗口新增或调整的步骤。
  bool get _progressStructureChanged {
    if (widget.record == null ||
        _progressSteps.length != _progressStepsBaseline.length) {
      return true;
    }
    for (int index = 0; index < _progressSteps.length; index += 1) {
      if (_progressSteps[index].id != _progressStepsBaseline[index].id ||
          _progressSteps[index].controller.text.trim() !=
              (_progressStepsBaseline[index].name?.trim() ?? '')) {
        return true;
      }
    }
    return false;
  }

  /// 构建可分别展开日期与时间浮层的可选日期时间控件。
  Widget _buildDateTimeControls({
    required DateTime? value,
    required int defaultHour,
    required String emptyDateLabel,
    required IconData dateIcon,
    required String clearTooltip,
    required ValueChanged<DateTime?> onChanged,
  }) {
    // 未设置时使用所属日期和默认小时作为浮层初值。
    final DateTime effectiveValue =
        value ??
        DateTime(
          _scheduledDate.year,
          _scheduledDate.month,
          _scheduledDate.day,
          defaultHour,
        );
    return Row(
      children: <Widget>[
        Expanded(
          child: OmniDatePickerButton(
            value: value,
            initialDate: effectiveValue,
            firstDate: DateTime(2000),
            lastDate: DateTime(2100),
            label: value == null
                ? emptyDateLabel
                : DateFormat('M月d日').format(value),
            icon: dateIcon,
            onChanged: (DateTime selectedDate) {
              // 合并新日期与当前时刻后的值。
              final DateTime nextValue = DateTime(
                selectedDate.year,
                selectedDate.month,
                selectedDate.day,
                effectiveValue.hour,
                effectiveValue.minute,
              );
              onChanged(nextValue);
            },
          ),
        ),
        const SizedBox(width: OmniSpacing.xs),
        SizedBox(
          width: 108,
          child: OmniTimePickerButton(
            value: TimeOfDay.fromDateTime(effectiveValue),
            label: DateFormat('HH:mm').format(effectiveValue),
            icon: null,
            onChanged: (TimeOfDay selectedTime) {
              // 合并当前日期与新时刻后的值。
              final DateTime nextValue = DateTime(
                effectiveValue.year,
                effectiveValue.month,
                effectiveValue.day,
                selectedTime.hour,
                selectedTime.minute,
              );
              onChanged(nextValue);
            },
          ),
        ),
        if (value != null)
          OmniIconButton(
            tooltip: clearTooltip,
            onPressed: () => onChanged(null),
            icon: const Icon(Icons.close_rounded),
          ),
      ],
    );
  }

  /// 校验并保存待办。
  Future<void> _save() async {
    if (_saving || _loadingSteps || _stepsLoadFailed) return;
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    if (_taskType == TodoTaskType.progress && widget.record == null) {
      // 新建时直接采用输入数量，预览按钮不是保存的前置操作。
      final bool applied;
      setState(() => _saving = true);
      try {
        applied = await _applyStepCount();
      } finally {
        if (mounted) setState(() => _saving = false);
      }
      if (!applied || !mounted) return;
    }
    if (_taskType == TodoTaskType.progress &&
        widget.record?.isCompleted != true) {
      if (_progressSteps.isEmpty) {
        setState(() => _progressError = '请先补充至少一个步骤。');
        return;
      }
      if (int.tryParse(_stepCountController.text.trim()) !=
          _progressSteps.length) {
        setState(() => _progressError = '步骤数量尚未应用，请先点击“应用数量”。');
        return;
      }
    }
    // 重复系列编辑范围。
    final TodoSeriesScope? scope = await _chooseSeriesScope();
    if (scope == null) {
      return;
    }
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      // 待办仓储。
      final TodoRepository repository = ref.read(todoRepositoryProvider);
      await repository.save(
        TodoDraft(
          id: widget.record?.id,
          title: _titleController.text,
          description: _descriptionController.text,
          parentId: widget.parent?.id ?? widget.record?.parentId,
          scheduledDate: _scheduledDate,
          dueAt: _dueAt,
          priorityQuadrant: _priorityQuadrant,
          reminderAt: _reminderAt,
          repeatRule: _repeatRule,
          taskType: _taskType,
          progressUnit: _taskType == TodoTaskType.progress
              ? _progressUnitController.text
              : null,
          progressSteps:
              _taskType == TodoTaskType.progress &&
                  widget.record?.isCompleted != true &&
                  _progressStructureChanged
              ? _progressSteps
                    .map(
                      (step) => TodoProgressStepDraft(
                        id: step.id,
                        name: step.controller.text,
                      ),
                    )
                    .toList(growable: false)
              : null,
          progressStepsBaseline:
              widget.record != null &&
                  _taskType == TodoTaskType.progress &&
                  _progressStructureChanged
              ? List<TodoProgressStepDraft>.unmodifiable(_progressStepsBaseline)
              : null,
        ),
        scope: scope,
      );
      if (mounted) {
        Navigator.pop(context, true);
      }
    } on FormatException catch (error) {
      if (mounted) {
        setState(() => _saveError = error.message.toString());
        showOmniMessage(
          context,
          message: error.message,
          tone: OmniMessageTone.error,
        );
      }
    } catch (_) {
      if (mounted) setState(() => _saveError = '保存失败，请重试。输入内容已保留。');
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  /// 在编辑重复实例时选择影响范围。
  Future<TodoSeriesScope?> _chooseSeriesScope() async {
    // 当前待办记录。
    final TodoRecord? record = widget.record;
    if (record?.repeatSeriesId == null) {
      return TodoSeriesScope.single;
    }
    return showOmniDialog<TodoSeriesScope>(
      context: context,
      builder: (BuildContext context) => OmniDialogScaffold(
        title: '修改重复待办',
        actions: <Widget>[
          OmniButton(
            label: '取消',
            variant: OmniButtonVariant.text,
            onPressed: () => Navigator.of(context).pop(),
          ),
          OmniButton(
            label: '仅本次',
            variant: OmniButtonVariant.secondary,
            onPressed: () => Navigator.of(context).pop(TodoSeriesScope.single),
          ),
          OmniButton(
            label: '本次及以后',
            onPressed: () => Navigator.of(context).pop(TodoSeriesScope.future),
          ),
        ],
        child: const Text('这条待办属于一个重复系列，请选择本次修改的范围。'),
      ),
    );
  }

  /// 返回重复规则中文名称。
  String _repeatLabel(TodoRepeatRule rule) {
    return switch (rule) {
      TodoRepeatRule.none => '不重复',
      TodoRepeatRule.daily => '每天',
      TodoRepeatRule.weekly => '每周',
      TodoRepeatRule.monthly => '每月',
    };
  }
}

/// 与完成状态分离的结构编辑草稿。
class _EditableProgressStep {
  /// 已存在步骤的稳定标识，新增步骤为空。
  final String? id;

  /// 名称输入控制器。
  final TextEditingController controller;

  /// 加载时的完成状态，只用于删除确认和说明。
  final bool completed;

  /// 创建结构编辑草稿。
  _EditableProgressStep({this.id, String? name, this.completed = false})
    : controller = TextEditingController(text: name ?? '');
}
