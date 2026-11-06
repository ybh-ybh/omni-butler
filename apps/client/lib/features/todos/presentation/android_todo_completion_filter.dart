import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/todos/data/todo_completion_entry.dart';
import 'package:omni_butler/shared/ui/omni_modal_bottom_sheet.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// Stores the applied Android history conditions independently of its query.
@immutable
class AndroidTodoCompletionFilter {
  /// Includes both normal tasks and subtasks when the normal kind is selected.
  final TodoCompletionKind? kind;

  /// Includes this local calendar day and all later days.
  final DateTime? startDate;

  /// Includes this local calendar day and all earlier days.
  final DateTime? endDate;

  /// Creates an all-history filter unless specific conditions are supplied.
  const AndroidTodoCompletionFilter({this.kind, this.startDate, this.endDate});

  /// Indicates whether any non-query condition is applied.
  bool get hasFilters => kind != null || startDate != null || endDate != null;

  /// Describes the single shared date condition without exposing query syntax.
  String? get dateLabel {
    // Calendar comparisons ignore time components in external selections.
    final DateTime? first = startDate == null
        ? null
        : DateUtils.dateOnly(startDate!);
    // The inclusive endpoint can also be omitted independently.
    final DateTime? last = endDate == null
        ? null
        : DateUtils.dateOnly(endDate!);
    if (first == null && last == null) return null;
    // One formatter keeps single-day and range descriptions consistent.
    final DateFormat format = DateFormat('yyyy年M月d日');
    if (first == null) return '截至${format.format(last!)}';
    if (last == null) return '${format.format(first)}起';
    if (first == last) return format.format(first);
    if (first.day == 1 && last == DateTime(first.year, first.month + 1, 0)) {
      return DateFormat('yyyy年M月').format(first);
    }
    return '${format.format(first)} — ${format.format(last)}';
  }
}

/// Edits a local draft and returns null when the sheet is dismissed.
Future<AndroidTodoCompletionFilter?> showAndroidTodoCompletionFilter(
  BuildContext context, {
  required AndroidTodoCompletionFilter initial,
}) {
  FocusScope.of(context).unfocus();
  return showOmniModalBottomSheet<AndroidTodoCompletionFilter>(
    context: context,
    builder: (_) => _AndroidCompletionFilterSheet(initial: initial),
  );
}

/// Keeps draft selection local until the explicit apply action.
class _AndroidCompletionFilterSheet extends ConsumerStatefulWidget {
  /// Captures the applied conditions when this editing session starts.
  final AndroidTodoCompletionFilter initial;

  /// Creates a separate draft for one bottom-sheet session.
  const _AndroidCompletionFilterSheet({required this.initial});

  /// Creates the mutable sheet draft.
  @override
  ConsumerState<_AndroidCompletionFilterSheet> createState() =>
      _AndroidCompletionFilterSheetState();
}

/// Uses the notes filter header and allows the fields to scroll at large text.
class _AndroidCompletionFilterSheetState
    extends ConsumerState<_AndroidCompletionFilterSheet> {
  /// Holds the selected visible task category.
  late TodoCompletionKind? _kind = widget.initial.kind;

  /// Holds the uncommitted inclusive start day.
  late DateTime? _start = widget.initial.startDate;

  /// Holds the uncommitted inclusive end day.
  late DateTime? _end = widget.initial.endDate;

  /// Builds the result only when needed, leaving the original object intact.
  AndroidTodoCompletionFilter get _draft => AndroidTodoCompletionFilter(
    kind: _kind,
    startDate: _start,
    endDate: _end,
  );

  /// Resets only the draft so cancellation still restores the applied filter.
  void _reset() => setState(() {
    _kind = null;
    _start = null;
    _end = null;
  });

  /// Applies one valid range without retaining contradictory endpoints.
  void _selectStart(DateTime day) => setState(() {
    _start = day;
    if (_end != null && _end!.isBefore(day)) _end = day;
  });

  /// Moves the opposite endpoint only when the new end would precede it.
  void _selectEnd(DateTime day) => setState(() {
    _end = day;
    if (_start != null && _start!.isAfter(day)) _start = day;
  });

  /// Provides one full-width selection row with a stable touch target.
  Widget _kindRow(TodoCompletionKind? kind, String label) {
    // Selection is exposed to both the visual marker and screen readers.
    final bool selected = _kind == kind;
    // All colors follow the active application palette.
    final OmniColors colors = OmniColors.of(context);
    return Semantics(
      selected: selected,
      child: OmniListTile(
        key: ValueKey('android-completion-filter-kind-${kind?.name ?? 'all'}'),
        contentPadding: const EdgeInsets.symmetric(horizontal: OmniSpacing.md),
        minTileHeight: OmniSize.touch,
        title: Text(label),
        trailing: Icon(
          selected ? Icons.check_circle : Icons.radio_button_unchecked,
          size: OmniSize.navigationIcon,
          color: selected ? colors.brand : colors.muted,
        ),
        onTap: () => setState(() => _kind = kind),
      ),
    );
  }

  /// Keeps date labels readable without squeezing long dates beside field names.
  Widget _dateField({
    required String name,
    required String label,
    required DateTime? value,
    required DateTime today,
    required ValueChanged<DateTime> onChanged,
    required VoidCallback onClear,
  }) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: OmniSpacing.md,
      vertical: OmniSpacing.xs,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: OmniSpacing.xs),
        Row(
          children: [
            Expanded(
              child: OmniDatePickerButton(
                key: ValueKey('android-completion-filter-$name'),
                value: value,
                initialDate: value ?? today,
                currentDate: today,
                firstDate: DateTime(1),
                lastDate: today,
                label: value == null
                    ? '不限'
                    : DateFormat('yyyy年M月d日').format(value),
                wrapLabel: true,
                onChanged: onChanged,
              ),
            ),
            if (value != null)
              OmniIconButton(
                key: ValueKey('android-completion-filter-clear-$name'),
                tooltip: '清除$label',
                icon: const Icon(Icons.close, size: OmniSize.icon),
                onPressed: onClear,
              ),
          ],
        ),
      ],
    ),
  );

  /// Builds a compact fixed header above naturally sized, bounded scroll content.
  @override
  Widget build(BuildContext context) {
    // The clock provider keeps date limits consistent with the history page.
    final DateTime today = DateUtils.dateOnly(ref.watch(nowProvider).toLocal());
    // Reuse semantic colors instead of introducing a platform-specific palette.
    final OmniColors colors = OmniColors.of(context);
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .88,
        ),
        child: Column(
          key: const ValueKey('android-completion-filter'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: OmniSize.touch * 2,
                  ),
                  child: Text(
                    '筛选',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Row(
                  children: [
                    OmniIconButton(
                      key: const ValueKey('android-completion-filter-cancel'),
                      tooltip: '取消筛选',
                      icon: const Icon(Icons.keyboard_arrow_down),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const Spacer(),
                    if (_draft.hasFilters)
                      OmniIconButton(
                        key: const ValueKey('android-completion-filter-reset'),
                        tooltip: '重置筛选',
                        icon: const Icon(Icons.restart_alt),
                        onPressed: _reset,
                      ),
                    OmniIconButton(
                      key: const ValueKey('android-completion-filter-apply'),
                      tooltip: '应用筛选',
                      icon: Icon(Icons.check, color: colors.brand),
                      onPressed: () => Navigator.pop(context, _draft),
                    ),
                  ],
                ),
              ],
            ),
            Flexible(
              child: SingleChildScrollView(
                key: const ValueKey('android-completion-filter-scroll'),
                padding: const EdgeInsets.only(bottom: OmniSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        OmniSpacing.md,
                        OmniSpacing.sm,
                        OmniSpacing.md,
                        OmniSpacing.xs,
                      ),
                      child: Text(
                        '任务类型',
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: colors.muted),
                      ),
                    ),
                    _kindRow(null, '全部任务'),
                    _kindRow(TodoCompletionKind.normal, '普通任务'),
                    _kindRow(TodoCompletionKind.progress, '进度任务'),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: OmniSpacing.md),
                      child: Divider(height: OmniSpacing.lg),
                    ),
                    _dateField(
                      name: 'start-date',
                      label: '开始日期',
                      value: _start,
                      today: today,
                      onChanged: _selectStart,
                      onClear: () => setState(() => _start = null),
                    ),
                    _dateField(
                      name: 'end-date',
                      label: '结束日期',
                      value: _end,
                      today: today,
                      onChanged: _selectEnd,
                      onClear: () => setState(() => _end = null),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
