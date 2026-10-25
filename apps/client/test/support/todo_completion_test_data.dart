import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';

/// 创建不读取真实数据库的完成历史测试任务。
TodoRecord completionTestTodo(
  String id,
  String title, {
  String? description,
  String? parentId,
  bool progress = false,
}) => TodoRecord(
  id: id,
  title: title,
  description: description,
  parentId: parentId,
  taskType: progress ? 'progress' : 'normal',
  progressUnit: progress ? '章' : null,
  scheduledDate: DateTime(2026, 1, 1),
  priorityQuadrant: 2,
  isCompleted: false,
  sortOrder: 0,
  syncState: 'localSaved',
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
);

/// 创建指定日期的完整完成单元，可保留父任务和原始章节序号。
TodoCompletionEntry completionTestEntry(
  String id,
  DateTime completedAt, {
  TodoRecord? todo,
  TodoRecord? parent,
  int? ordinal,
  String? stepName,
}) {
  // 默认独立任务上下文。
  final TodoRecord record = todo ?? completionTestTodo(id, id);
  return TodoCompletionEntry(
    id: id,
    todo: record,
    parent: parent,
    completedAt: completedAt,
    kind: ordinal != null
        ? TodoCompletionKind.progress
        : parent != null
        ? TodoCompletionKind.subtask
        : TodoCompletionKind.normal,
    stepOrdinal: ordinal,
    step: ordinal == null
        ? null
        : TodoProgressStepRecord(
            id: id,
            todoId: record.id,
            name: stepName,
            sortOrder: ordinal * 1024,
            isCompleted: true,
            completedAt: completedAt,
            createdAt: DateTime(2026, 1, 1),
            updatedAt: completedAt,
          ),
  );
}

/// 固定示例覆盖独立任务、同日子项、跨日章节和一年以前的历史。
List<TodoCompletionEntry> completionTestEntries() {
  // 进度父任务尚未确认，也应显示各章完成记录。
  final TodoRecord progress = completionTestTodo(
    'java',
    'Java 学习',
    description: '阅读后端实践笔记',
    progress: true,
  );
  // 普通父任务只负责上下文，不作为完成记录计数。
  final TodoRecord parent = completionTestTodo('release', '项目收尾');
  return <TodoCompletionEntry>[
    completionTestEntry(
      'mail',
      DateTime(2026, 10, 25, 12),
      todo: completionTestTodo('mail', '回复邮件'),
    ),
    completionTestEntry(
      'build',
      DateTime(2026, 10, 25, 11),
      todo: completionTestTodo('build', '检查构建', parentId: parent.id),
      parent: parent,
    ),
    completionTestEntry(
      'notes',
      DateTime(2026, 10, 25, 8),
      todo: completionTestTodo('notes', '整理说明', parentId: parent.id),
      parent: parent,
    ),
    completionTestEntry(
      'chapter-3',
      DateTime(2026, 10, 25, 10, 30),
      todo: progress,
      ordinal: 3,
      stepName: '集合与泛型',
    ),
    completionTestEntry(
      'chapter-8',
      DateTime(2026, 10, 25, 9),
      todo: progress,
      ordinal: 8,
    ),
    completionTestEntry(
      'chapter-12',
      DateTime(2026, 10, 24, 20),
      todo: progress,
      ordinal: 12,
      stepName: '并发与线程池',
    ),
    completionTestEntry(
      'old',
      DateTime(2024, 5, 1, 16),
      todo: completionTestTodo('old', '归档旧资料'),
    ),
  ];
}

/// 为预览补充确定性的全年示例，所有内容均为测试数据。
List<TodoCompletionEntry> completionPreviewEntries() {
  // 页面顶部使用简洁可展开的固定示例。
  final List<TodoCompletionEntry> entries = completionTestEntries();
  for (int day = 2; day < 365; day += 1) {
    // 用不同密度验证固定五档热力图。
    final int count = (day * 7 + day ~/ 3) % 13;
    for (int item = 0; item < count; item += 1) {
      // 使用日历构造跨月日期，避免时区影响。
      final DateTime completedAt = DateTime(2026, 10, 25 - day, 18, item * 3);
      entries.add(
        completionTestEntry(
          'preview-$day-$item',
          completedAt,
          todo: completionTestTodo(
            'preview-$day-$item',
            <String>['整理阅读笔记', '核对接口文档', '完成每日练习', '回顾本周进度'][item % 4],
          ),
        ),
      );
    }
  }
  return entries;
}
