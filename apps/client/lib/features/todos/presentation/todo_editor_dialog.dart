import 'dart:math' as math;

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

  /// 已移除但可能仍被当前帧使用的步骤输入资源。
  final List<_EditableProgressStep> _retiredProgressSteps =
      <_EditableProgressStep>[];

  /// 添加步骤时可主动展开名称列表。
  final ExpansibleController _progressListExpansion = ExpansibleController();

  /// 长步骤列表的独立滚动位置。
  final ScrollController _progressListScroll = ScrollController();

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

  /// 时间设置展开时隐藏折叠摘要。
  bool _timeSettingsExpanded = false;

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
    _progressListExpansion.dispose();
    _progressListScroll.dispose();
    for (final _EditableProgressStep step in _progressSteps) {
      step.dispose();
    }
    for (final _EditableProgressStep step in _retiredProgressSteps) {
      step.dispose();
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
              if (widget.parent != null) ...<Widget>[
                Text(
                  '所属主任务：${widget.parent!.title}；计划日期和象限跟随主任务。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: OmniSpacing.lg),
              ],
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
              _buildTimeSettings(isChild: isChild),
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
    // 完成历史的步骤必须重新打开任务后展示可编辑结构。
    final bool readOnly = widget.record?.isCompleted == true;
    // 加载、错误和提交期间禁止修改结构。
    final bool enabled =
        !_saving && !_loadingSteps && !_stepsLoadFailed && !readOnly;
    return OmniPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('进度设置', style: Theme.of(context).textTheme.titleSmall),
          if (readOnly) ...<Widget>[
            const SizedBox(height: OmniSpacing.xs),
            Text(
              '任务已完成，重新打开后才能修改步骤。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: OmniSpacing.sm),
          _buildProgressBasics(enabled: enabled),
          if (_progressError != null) ...<Widget>[
            const SizedBox(height: OmniSpacing.xs),
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
            controller: _progressListExpansion,
            initiallyExpanded: widget.record != null,
            tilePadding: EdgeInsets.zero,
            shape: const Border(),
            collapsedShape: const Border(),
            title: Text('步骤列表 · ${_progressSteps.length} 项'),
            children: <Widget>[_buildProgressStepList(enabled: enabled)],
          ),
          const SizedBox(height: OmniSpacing.xs),
          Align(
            alignment: Alignment.centerLeft,
            child: OmniButton(
              label: '添加步骤',
              icon: Icons.add_rounded,
              variant: OmniButtonVariant.text,
              onPressed: enabled && _progressSteps.length < 1000
                  ? _addProgressStep
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  /// 统一步骤输入行高度，保留触控热区与放大字号空间。
  double get _progressRowHeight => math.max(
    OmniDensity.controlHeight(context, large: true),
    MediaQuery.textScalerOf(context).scale(14) * 1.55 + OmniSpacing.md,
  );

  /// 基础字段使用外置标签，避免标签压在边框上。
  Widget _buildProgressField({required String label, required Widget child}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: OmniSpacing.xs),
        child,
      ],
    );
  }

  /// 数量与单位在桌面同排；窄屏或放大字号时按阅读顺序分行。
  Widget _buildProgressBasics({required bool enabled}) {
    // 单位沿用原长度限制，计数只在接近上限时显示在框内。
    final Widget unitField = _buildProgressField(
      label: '单位（可选）',
      child: _buildProgressTextInput(
        fieldKey: const ValueKey<String>('todo-progress-unit'),
        controller: _progressUnitController,
        enabled: enabled,
        maxLength: 10,
        counterThreshold: 8,
        hint: '例如：章',
        semanticLabel: '单位（可选）',
      ),
    );
    // 已有步骤总数来自列表，不能绕过指定步骤的删除确认。
    final Widget countField = widget.record != null
        ? _buildProgressField(
            label: '步骤总数',
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: _progressRowHeight),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '共 ${_progressSteps.length} 步',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
          )
        : _buildProgressField(
            label: '步骤总数',
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _stepCountController,
              builder:
                  (
                    BuildContext context,
                    TextEditingValue value,
                    Widget? child,
                  ) {
                    // 数量无变化时不提供重复应用操作；无效输入仍可得到具体错误。
                    final bool changed =
                        int.tryParse(value.text.trim()) !=
                        _progressSteps.length;
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        SizedBox(
                          width:
                              OmniSize.control * 2 +
                              MediaQuery.textScalerOf(context)
                                  .scale(OmniSpacing.md),
                          child: OmniTextFormField(
                            key: const ValueKey<String>('todo-progress-total'),
                            controller: _stepCountController,
                            enabled: enabled,
                            keyboardType: TextInputType.number,
                            textAlign: TextAlign.center,
                            decoration: InputDecoration(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: OmniSpacing.sm,
                                vertical: OmniSpacing.sm,
                              ),
                              constraints: BoxConstraints(
                                minHeight: _progressRowHeight,
                              ),
                            ),
                            validator: (String? value) {
                              // 保留原有步骤数量校验范围。
                              final int? count = int.tryParse(
                                value?.trim() ?? '',
                              );
                              return count == null || count < 1 || count > 1000
                                  ? '请输入 1 至 1000 的整数'
                                  : null;
                            },
                          ),
                        ),
                        const SizedBox(width: OmniSpacing.xs),
                        Flexible(
                          child: OmniButton(
                            key: const ValueKey<String>(
                              'todo-progress-apply-total',
                            ),
                            label: '更新步骤',
                            large: true,
                            variant: OmniButtonVariant.text,
                            onPressed: enabled && changed
                                ? _applyStepCount
                                : null,
                          ),
                        ),
                      ],
                    );
                  },
            ),
          );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 两组字段在字体放大后需要更多横向空间。
        final double textScale =
            MediaQuery.textScalerOf(context).scale(14) / 14;
        if (constraints.maxWidth < OmniSize.control * 12 * textScale) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              countField,
              const SizedBox(height: OmniSpacing.sm),
              unitField,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(flex: 3, child: countField),
            const SizedBox(width: OmniSpacing.sm),
            Expanded(flex: 2, child: unitField),
          ],
        );
      },
    );
  }

  /// 在输入框内部按需显示字数，不增加单独的计数行。
  Widget _buildProgressTextInput({
    required Key fieldKey,
    required TextEditingController controller,
    required bool enabled,
    required int maxLength,
    required int counterThreshold,
    required String hint,
    required String semanticLabel,
    FocusNode? focusNode,
  }) {
    return Semantics(
      label: semanticLabel,
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (BuildContext context, TextEditingValue value, Widget? child) {
          // 按用户可见字符计数，与原生 maxLength 对组合字符的口径一致。
          final int length = value.text.characters.length;
          return OmniTextFormField(
            key: fieldKey,
            controller: controller,
            focusNode: focusNode,
            enabled: enabled,
            maxLength: maxLength,
            decoration: InputDecoration(
              hintText: hint,
              counterText: '',
              contentPadding: const EdgeInsets.symmetric(
                horizontal: OmniSpacing.sm,
                vertical: OmniSpacing.sm,
              ),
              suffixText: length >= counterThreshold
                  ? '$length/$maxLength'
                  : null,
              suffixStyle: Theme.of(context).textTheme.bodySmall,
              constraints: BoxConstraints(minHeight: _progressRowHeight),
            ),
          );
        },
      ),
    );
  }

  /// 少量步骤完整展示，较长列表按窗口可用高度限制并保持惰性构建。
  Widget _buildProgressStepList({required bool enabled}) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 操作区以实际宽度和字号决定是否收进更多菜单。
        final double textScale =
            MediaQuery.textScalerOf(context).scale(14) / 14;
        // 桌面窄窗同样使用菜单，但不改变平台本身的点击密度。
        final bool compact =
            constraints.maxWidth < OmniSize.control * 12 * textScale;
        // 统一行高包括下方间距，使长列表定位到末项时无需猜测尺寸。
        final double itemExtent = _progressRowHeight + OmniSpacing.xs;
        // 按当前字体实测序号宽度，避免数字与完成图标在不同字体下挤压。
        final TextPainter numberMeasure = TextPainter(
          text: TextSpan(
            text: _progressSteps.length.toString(),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          textScaler: MediaQuery.textScalerOf(context),
          textDirection: Directionality.of(context),
        )..layout();
        // 所有行共用序号列，额外空间容纳完成图标和两侧间距。
        final double numberWidth = math.max(
          OmniSize.control,
          numberMeasure.width.ceilToDouble() + OmniSpacing.lg,
        );
        numberMeasure.dispose();
        if (_progressSteps.length <= 5) {
          return Column(
            children: <Widget>[
              // 当前步骤在列表中的位置。
              for (int index = 0; index < _progressSteps.length; index += 1)
                _buildProgressStepRow(
                  index,
                  enabled: enabled,
                  compact: compact,
                  numberWidth: numberWidth,
                ),
            ],
          );
        }
        // 软键盘出现时降低列表上限，列表之外仍由整个编辑器滚动。
        final double visibleHeight = math.max(
          0,
          MediaQuery.sizeOf(context).height -
              MediaQuery.viewInsetsOf(context).bottom,
        );
        // 常规窗口最多约六行，较矮窗口至少保留两行可操作内容。
        final double listHeight = (visibleHeight * 0.35)
            .clamp(itemExtent * 2, itemExtent * 6)
            .toDouble();
        return SizedBox(
          key: const ValueKey<String>('todo-progress-scroll-list'),
          height: listHeight,
          child: Scrollbar(
            controller: _progressListScroll,
            child: ListView.builder(
              controller: _progressListScroll,
              primary: false,
              padding: EdgeInsets.zero,
              itemExtent: itemExtent,
              itemCount: _progressSteps.length,
              findChildIndexCallback: (Key key) {
                // 排序时复用对应步骤的输入节点及选择状态。
                final int index = key is ObjectKey
                    ? _progressSteps.indexOf(key.value as _EditableProgressStep)
                    : -1;
                return index < 0 ? null : index;
              },
              itemBuilder: (BuildContext context, int index) =>
                  _buildProgressStepRow(
                    index,
                    enabled: enabled,
                    compact: compact,
                    numberWidth: numberWidth,
                  ),
            ),
          ),
        );
      },
    );
  }

  /// 单个步骤将序号、名称及其操作放在同一行。
  Widget _buildProgressStepRow(
    int index, {
    required bool enabled,
    required bool compact,
    required double numberWidth,
  }) {
    // 稳定草稿对象保留输入、完成状态和焦点身份。
    final _EditableProgressStep step = _progressSteps[index];
    return Padding(
      key: ObjectKey(step),
      padding: const EdgeInsets.only(bottom: OmniSpacing.xs),
      child: SizedBox(
        height: _progressRowHeight,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              width: numberWidth,
              child: Center(
                child: Tooltip(
                  message: step.completed
                      ? '步骤 ${index + 1}，已完成'
                      : '步骤 ${index + 1}',
                  child: Semantics(
                    label: '步骤 ${index + 1}${step.completed ? '，已完成' : ''}',
                    excludeSemantics: true,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          '${index + 1}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        if (step.completed) ...<Widget>[
                          const SizedBox(width: OmniSpacing.xxs),
                          const Icon(Icons.check_rounded, size: OmniSpacing.sm),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: OmniSpacing.xxs),
            Expanded(
              child: _buildProgressTextInput(
                fieldKey: step.fieldKey,
                controller: step.controller,
                focusNode: step.focusNode,
                enabled: enabled,
                maxLength: 200,
                counterThreshold: 180,
                hint: '名称（可选）',
                semanticLabel: '步骤 ${index + 1} 名称',
              ),
            ),
            const SizedBox(width: OmniSpacing.xxs),
            _buildProgressStepActions(
              index,
              enabled: enabled,
              compact: compact,
            ),
          ],
        ),
      ),
    );
  }

  /// 两种布局共用同一组可用条件和步骤结构操作。
  Widget _buildProgressStepActions(
    int index, {
    required bool enabled,
    required bool compact,
  }) {
    if (compact) {
      return SizedBox(
        width: OmniDensity.controlHeight(context),
        child: OmniPopupMenuButton<String>(
          tooltip: '步骤 ${index + 1} 操作',
          enabled: enabled,
          itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
            OmniPopupMenuItem<String>(
              value: 'up',
              label: '上移',
              icon: Icons.arrow_upward_rounded,
              enabled: index > 0,
            ),
            OmniPopupMenuItem<String>(
              value: 'down',
              label: '下移',
              icon: Icons.arrow_downward_rounded,
              enabled: index < _progressSteps.length - 1,
            ),
            OmniPopupMenuItem<String>(
              value: 'delete',
              label: '删除',
              icon: Icons.delete_outline_rounded,
              danger: true,
              enabled: _progressSteps.length > 1,
            ),
          ],
          onSelected: (String action) {
            switch (action) {
              case 'up':
                _moveStep(index, index - 1);
              case 'down':
                _moveStep(index, index + 1);
              case 'delete':
                _removeSteps(<_EditableProgressStep>[_progressSteps[index]]);
            }
          },
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
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
          onPressed: enabled && index < _progressSteps.length - 1
              ? () => _moveStep(index, index + 1)
              : null,
          icon: const Icon(Icons.arrow_downward_rounded),
        ),
        OmniIconButton(
          tooltip: '删除步骤 ${index + 1}',
          onPressed: enabled && _progressSteps.length > 1
              ? () =>
                    _removeSteps(<_EditableProgressStep>[_progressSteps[index]])
              : null,
          icon: const Icon(Icons.delete_outline_rounded),
        ),
      ],
    );
  }

  /// 添加后展开列表，滚入新行并将焦点交给名称输入框。
  Future<void> _addProgressStep() async {
    // 新步骤的身份和输入资源在本次编辑期间保持稳定。
    final _EditableProgressStep step = _EditableProgressStep();
    setState(() {
      _progressSteps.add(step);
      _stepCountController.text = _progressSteps.length.toString();
    });
    _progressListExpansion.expand();
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || _progressSteps.last != step) return;
    if (_progressListScroll.hasClients) {
      _progressListScroll.jumpTo(_progressListScroll.position.maxScrollExtent);
      await WidgetsBinding.instance.endOfFrame;
    }
    if (!mounted || _progressSteps.last != step) return;
    // 惰性列表完成末项挂载后再定位外层编辑器。
    final BuildContext? fieldContext = step.fieldKey.currentContext;
    if (fieldContext == null || !fieldContext.mounted) return;
    await Scrollable.ensureVisible(
      fieldContext,
      alignment: 1,
      duration: OmniMotion.duration(context, OmniMotion.panel),
      curve: OmniMotion.standardCurve,
    );
    if (mounted && _progressSteps.contains(step)) {
      step.focusNode.requestFocus();
    }
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
        step.focusNode.unfocus();
        _retiredProgressSteps.add(step);
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

  /// 当年日期使用中文短格式，跨年日期保留年份以免混淆。
  String _timeDateLabel(DateTime date) {
    return DateFormat(date.year == DateTime.now().year ? 'M月d日' : 'yyyy/M/d')
        .format(date);
  }

  /// 汇总当前已生效的时间设置供收起时核对。
  String _timeSettingsSummary({required bool isChild}) {
    // 只汇总当前任务可设置且已有值的字段。
    final List<String> parts = <String>[
      if (!isChild) '计划 ${_timeDateLabel(_scheduledDate)}',
      if (_dueAt != null)
        '截止 ${_timeDateLabel(_dueAt!)} ${DateFormat('HH:mm').format(_dueAt!)}',
      if (_reminderAt != null)
        '提醒 ${_timeDateLabel(_reminderAt!)} ${DateFormat('HH:mm').format(_reminderAt!)}',
      if (!isChild &&
          _taskType == TodoTaskType.normal &&
          _repeatRule != TodoRepeatRule.none)
        _repeatLabel(_repeatRule),
    ];
    return parts.isEmpty ? '未设置截止或提醒' : parts.join(' · ');
  }

  /// 以统一外置标签组织计划日期、截止、提醒和重复。
  Widget _buildTimeSettings({required bool isChild}) {
    return OutlinedButtonTheme(
      data: OutlinedButtonThemeData(
        style: _timeControlStyle.merge(OutlinedButtonTheme.of(context).style),
      ),
      child: OmniPanel(
        padding: EdgeInsets.zero,
        child: ExpansionTile(
          key: const ValueKey<String>('todo-time-settings'),
          initiallyExpanded: _timeSettingsExpanded,
          onExpansionChanged: (bool expanded) {
            setState(() => _timeSettingsExpanded = expanded);
          },
          leading: const Icon(Icons.schedule_outlined),
          title: const Text('时间设置'),
          subtitle: _timeSettingsExpanded
              ? null
              : Text(
                  _timeSettingsSummary(isChild: isChild),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
          tilePadding: const EdgeInsets.symmetric(horizontal: OmniSpacing.md),
          childrenPadding: const EdgeInsets.fromLTRB(
            OmniSpacing.md,
            OmniSpacing.xxs,
            OmniSpacing.md,
            OmniSpacing.md,
          ),
          children: <Widget>[
            if (!isChild) ...<Widget>[
              _buildTimeField(
                label: '计划日期',
                child: OmniDatePickerButton(
                  value: _scheduledDate,
                  initialDate: _scheduledDate,
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                  label: _timeDateLabel(_scheduledDate),
                  icon: null,
                  onChanged: (DateTime selected) {
                    setState(() => _scheduledDate = selected);
                  },
                ),
              ),
              const SizedBox(height: OmniSpacing.sm),
            ],
            _buildTimeField(
              label: '截止时间',
              child: _buildDateTimeControls(
                value: _dueAt,
                defaultHour: 18,
                emptyDateLabel: '添加截止',
                clearTooltip: '清除截止时间',
                onChanged: (DateTime? value) => setState(() => _dueAt = value),
              ),
            ),
            const SizedBox(height: OmniSpacing.sm),
            _buildTimeField(
              label: '提醒时间',
              child: _buildDateTimeControls(
                value: _reminderAt,
                defaultHour: 9,
                emptyDateLabel: '添加提醒',
                clearTooltip: '清除提醒时间',
                onChanged: (DateTime? value) =>
                    setState(() => _reminderAt = value),
              ),
            ),
            if (!isChild && _taskType == TodoTaskType.normal) ...<Widget>[
              const SizedBox(height: OmniSpacing.sm),
              _buildTimeField(
                label: '重复',
                child: OmniDropdownButton<TodoRepeatRule>(
                  value: _repeatRule,
                  width: double.infinity,
                  height: OmniDensity.controlHeight(context, large: true),
                  items: <DropdownMenuItem<TodoRepeatRule>>[
                    // 当前可选重复规则。
                    for (final TodoRepeatRule rule in TodoRepeatRule.values)
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
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 日期和时间控件使用同一高度与内边距，触控端保留完整热区。
  ButtonStyle get _timeControlStyle => ButtonStyle(
    minimumSize: WidgetStatePropertyAll<Size>(
      Size(0, OmniDensity.controlHeight(context, large: true)),
    ),
    padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
      EdgeInsets.symmetric(horizontal: OmniSpacing.xs),
    ),
  );

  /// 宽屏使用固定标签列，窄屏或大字号将标签放到控件上方。
  Widget _buildTimeField({required String label, required Widget child}) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 字号放大后同步增加标签列与横排所需空间。
        final double textScale =
            MediaQuery.textScalerOf(context).scale(14) / 14;
        // 所有字段共享同一宽度判断，避免上下行切换成不同布局。
        final bool stacked =
            constraints.maxWidth < OmniSize.control * 12 * textScale;
        // 外置标签始终可见，不随日期是否设置而变化。
        final Widget fieldLabel = Text(
          label,
          style: Theme.of(context).textTheme.labelLarge,
        );
        if (stacked) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              fieldLabel,
              const SizedBox(height: OmniSpacing.xs),
              child,
            ],
          );
        }
        return Row(
          children: <Widget>[
            SizedBox(
              width: (OmniSize.control * 2 + OmniSpacing.xs) * textScale,
              child: fieldLabel,
            ),
            const SizedBox(width: OmniSpacing.sm),
            Expanded(child: child),
          ],
        );
      },
    );
  }

  /// 未设置时添加入口占满字段宽度，选定后按日期、时间和清除列对齐。
  Widget _buildDateTimeControls({
    required DateTime? value,
    required int defaultHour,
    required String emptyDateLabel,
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
    // 日期入口的状态切换不改变当前已选时刻。
    final Widget dateControl = OmniDatePickerButton(
      value: value,
      initialDate: effectiveValue,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      label: value == null ? emptyDateLabel : _timeDateLabel(value),
      icon: value == null ? Icons.add_rounded : null,
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
    );
    if (value == null) {
      return dateControl;
    }
    // 已设置的截止与提醒使用同宽清除操作列。
    final Widget clearControl = SizedBox(
      width: OmniDensity.controlHeight(context),
      child: OmniIconButton(
        tooltip: clearTooltip,
        onPressed: () => onChanged(null),
        icon: const Icon(Icons.close_rounded),
      ),
    );
    // 只有日期已设置时才允许选择时间，避免默认值被误认为已启用。
    final Widget timeControl = OmniTimePickerButton(
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
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 时间列随字号增长，正常尺寸下仍保持紧凑宽度。
        final double timeWidth =
            MediaQuery.textScalerOf(context).scale(14) /
                14 *
                (OmniSize.control * 2) +
            OmniSpacing.sm;
        // 用较长跨年格式为两行预留一致的日期空间，不因选值而错位。
        final TextPainter dateMeasure = TextPainter(
          text: TextSpan(
            text: '2000/12/30',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          textScaler: MediaQuery.textScalerOf(context),
          textDirection: Directionality.of(context),
        )..layout();
        // 日期文字、控件间距及清除热区共同决定换行边界。
        final double requiredWidth =
            dateMeasure.width +
            OmniSpacing.xs * 4 +
            timeWidth +
            OmniDensity.controlHeight(context);
        dateMeasure.dispose();
        if (constraints.maxWidth < requiredWidth) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              dateControl,
              const SizedBox(height: OmniSpacing.xs),
              Row(
                children: <Widget>[
                  Expanded(child: timeControl),
                  const SizedBox(width: OmniSpacing.xs),
                  clearControl,
                ],
              ),
            ],
          );
        }
        return Row(
          children: <Widget>[
            Expanded(child: dateControl),
            const SizedBox(width: OmniSpacing.xs),
            SizedBox(width: timeWidth, child: timeControl),
            const SizedBox(width: OmniSpacing.xs),
            clearControl,
          ],
        );
      },
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
        setState(() => _progressError = '步骤数量尚未更新，请先点击“更新步骤”。');
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

  /// 输入节点随步骤移动，新增后用于定位焦点。
  final FocusNode focusNode = FocusNode();

  /// 输入框的稳定挂载位置，供滚动定位与排序复用。
  final GlobalKey fieldKey = GlobalKey();

  /// 加载时的完成状态，只用于删除确认和说明。
  final bool completed;

  /// 创建结构编辑草稿。
  _EditableProgressStep({this.id, String? name, this.completed = false})
    : controller = TextEditingController(text: name ?? '');

  /// 在编辑器销毁时统一释放输入资源。
  void dispose() {
    controller.dispose();
    focusNode.dispose();
  }
}
