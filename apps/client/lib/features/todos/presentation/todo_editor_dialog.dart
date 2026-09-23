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
            constraints: const BoxConstraints(minHeight: 94),
            child: Padding(
              padding: const EdgeInsets.all(OmniSpacing.sm),
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
                  const SizedBox(height: OmniSpacing.xxs),
                  Text(
                    quadrant.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
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
          onPressed: _saving ? null : _save,
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
              TextFormField(
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
              TextFormField(
                controller: _descriptionController,
                maxLines: 3,
                decoration: const InputDecoration(labelText: '描述（可选）'),
              ),
              const SizedBox(height: OmniSpacing.md),
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
                    if (!isChild) ...<Widget>[
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
            ],
          ),
        ),
      ),
    );
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
          IconButton(
            tooltip: clearTooltip,
            onPressed: () => onChanged(null),
            icon: const Icon(Icons.close_rounded),
          ),
      ],
    );
  }

  /// 校验并保存待办。
  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    // 重复系列编辑范围。
    final TodoSeriesScope? scope = await _chooseSeriesScope();
    if (scope == null) {
      return;
    }
    setState(() => _saving = true);
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
        ),
        scope: scope,
      );
      if (mounted) {
        Navigator.pop(context, true);
      }
    } on FormatException catch (error) {
      if (mounted) {
        showOmniMessage(
          context,
          message: error.message,
          tone: OmniMessageTone.error,
        );
      }
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
    return showDialog<TodoSeriesScope>(
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
