import 'package:omni_butler/core/database/app_database.dart';

/// 完成历史中每个计数单元的来源。
enum TodoCompletionKind {
  /// 不包含有效子任务的普通任务。
  normal,

  /// 普通父任务下的独立子任务。
  subtask,

  /// 进度任务中的一个有效步骤。
  progress,
}

/// 统计与历史共用的当前有效完成单元。
class TodoCompletionEntry {
  /// 带来源前缀的稳定标识，避免任务和步骤身份混淆。
  final String id;

  /// 完成的普通任务，或进度步骤所属的任务。
  final TodoRecord todo;

  /// 普通子任务所属的有效父任务。
  final TodoRecord? parent;

  /// 进度完成单元对应的步骤。
  final TodoProgressStepRecord? step;

  /// 步骤在全部有效步骤中的一基序号，不受筛选影响。
  final int? stepOrdinal;

  /// 此完成单元最近一次完成的本地时间。
  final DateTime completedAt;

  /// 完成单元的业务来源。
  final TodoCompletionKind kind;

  /// 创建不可变的完成记录投影。
  const TodoCompletionEntry({
    required this.id,
    required this.todo,
    required this.completedAt,
    required this.kind,
    this.parent,
    this.step,
    this.stepOrdinal,
  });

  /// 分组时使用所属根任务的上下文。
  TodoRecord get root => parent ?? todo;

  /// 按设备本地时间归属的完成自然日。
  DateTime get day {
    // UTC 下行与本地写入使用同一自然日口径。
    final DateTime local = completedAt.toLocal();
    return DateTime(local.year, local.month, local.day);
  }

  /// 普通任务使用标题，进度项使用名称或原始步骤序号。
  String get title {
    if (step == null) return todo.title;
    // 去除步骤名称两侧空白，不改写持久化内容。
    final String name = step!.name?.trim() ?? '';
    if (name.isNotEmpty) return name;
    // 未指定单位时与既有进度面板统一使用“步”。
    final String unit = todo.progressUnit?.trim() ?? '';
    return '第${stepOrdinal ?? 1}${unit.isEmpty ? '步' : unit}';
  }

  /// 同时检索完成内容及所属任务上下文，忽略英文大小写。
  String get searchText => <String>[
    title,
    todo.title,
    if (todo.description != null) todo.description!,
    if (parent != null) parent!.title,
    if (parent?.description != null) parent!.description!,
  ].join('\n').toLowerCase();
}
