import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/features/todos/data/todo_priority_quadrant.dart';

/// 待办优先象限的视觉语义。
extension TodoPriorityQuadrantStyle on TodoPriorityQuadrant {
  /// 返回当前象限的强调色。
  Color color(OmniColors colors) {
    return switch (this) {
      TodoPriorityQuadrant.urgentImportant => colors.danger,
      TodoPriorityQuadrant.importantNotUrgent => colors.todo,
      TodoPriorityQuadrant.urgentNotImportant => colors.warning,
      TodoPriorityQuadrant.neitherUrgentNorImportant => colors.muted,
    };
  }

  /// 返回当前象限的图标。
  IconData get icon {
    return switch (this) {
      TodoPriorityQuadrant.urgentImportant => Icons.bolt_rounded,
      TodoPriorityQuadrant.importantNotUrgent => Icons.calendar_today_rounded,
      TodoPriorityQuadrant.urgentNotImportant => Icons.flash_on_rounded,
      TodoPriorityQuadrant.neitherUrgentNorImportant => Icons.more_time_rounded,
    };
  }
}
