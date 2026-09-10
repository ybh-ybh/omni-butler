/// 待办的四象限优先分类。
enum TodoPriorityQuadrant {
  /// 不急且不重要，适合有空时处理。
  neitherUrgentNorImportant(
    value: 0,
    label: '不紧急·不重要',
    actionLabel: '有空再做',
    description: '暂时不影响目标，也没有明确时限',
  ),

  /// 紧急但不重要，适合快速处理。
  urgentNotImportant(
    value: 1,
    label: '紧急·不重要',
    actionLabel: '快速处理',
    description: '时间临近，但对核心目标影响较小',
  ),

  /// 重要但不紧急，适合安排时间推进。
  importantNotUrgent(
    value: 2,
    label: '重要·不紧急',
    actionLabel: '安排时间',
    description: '影响长期目标，但暂时没有迫近时限',
  ),

  /// 紧急且重要，应当立即处理。
  urgentImportant(
    value: 3,
    label: '重要·紧急',
    actionLabel: '立即处理',
    description: '影响核心目标，需要尽快完成',
  );

  /// 数据库存储值。
  final int value;

  /// 用户可见名称。
  final String label;

  /// 建议行动。
  final String actionLabel;

  /// 分类说明。
  final String description;

  /// 创建待办优先象限。
  const TodoPriorityQuadrant({
    required this.value,
    required this.label,
    required this.actionLabel,
    required this.description,
  });

  /// 根据数据库值返回对应象限。
  static TodoPriorityQuadrant fromValue(int value) {
    return TodoPriorityQuadrant.values.firstWhere(
      (TodoPriorityQuadrant quadrant) => quadrant.value == value,
      orElse: () => TodoPriorityQuadrant.importantNotUrgent,
    );
  }
}

/// 四象限在二维看板中的固定位置顺序。
const List<TodoPriorityQuadrant> todoPriorityQuadrantMatrixOrder =
    <TodoPriorityQuadrant>[
      TodoPriorityQuadrant.urgentImportant,
      TodoPriorityQuadrant.urgentNotImportant,
      TodoPriorityQuadrant.importantNotUrgent,
      TodoPriorityQuadrant.neitherUrgentNorImportant,
    ];

/// 四象限按行动优先级排列的顺序。
const List<TodoPriorityQuadrant> todoPriorityQuadrantActionOrder =
    <TodoPriorityQuadrant>[
      TodoPriorityQuadrant.urgentImportant,
      TodoPriorityQuadrant.importantNotUrgent,
      TodoPriorityQuadrant.urgentNotImportant,
      TodoPriorityQuadrant.neitherUrgentNorImportant,
    ];
