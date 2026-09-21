import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/todos/data/todo_priority_quadrant.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:omni_butler/features/settings/data/recycle_bin_repository.dart';

/// 验证待办本地优先数据规则。
void main() {
  /// 每个测试使用的内存数据库。
  late AppDatabase database;

  /// 每个测试使用的待办仓储。
  late TodoRepository repository;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = TodoRepository(database);
  });

  tearDown(() async {
    await database.close();
  });

  test('新增、完成、软删除与恢复形成本地闭环', () async {
    // 测试所属自然日。
    final DateTime day = DateTime(2026, 9, 4);
    await repository.save(
      TodoDraft(
        title: '整理第一版需求',
        scheduledDate: day,
        priorityQuadrant: TodoPriorityQuadrant.urgentImportant,
      ),
    );

    // 新增后的待办。
    final List<TodoRecord> created = await repository.watchForDay(day).first;
    expect(created, hasLength(1));
    expect(created.single.title, '整理第一版需求');
    expect(created.single.syncState, 'localSaved');

    await repository.setCompleted(created.single.id, true);
    // 完成后的待办。
    final List<TodoRecord> completed = await repository.watchForDay(day).first;
    expect(completed.single.isCompleted, isTrue);
    expect(completed.single.completedAt, isNotNull);

    await repository.delete(created.single.id);
    expect(await repository.watchForDay(day).first, isEmpty);
    expect(await repository.watchDeleted().first, hasLength(1));

    await repository.restore(created.single.id);
    expect(await repository.watchForDay(day).first, hasLength(1));
    expect(await repository.watchDeleted().first, isEmpty);
  });

  test('未完成和高行动优先级象限优先排序', () async {
    // 测试所属自然日。
    final DateTime day = DateTime(2026, 9, 4);
    await repository.save(
      TodoDraft(
        title: '稍后整理',
        scheduledDate: day,
        priorityQuadrant: TodoPriorityQuadrant.neitherUrgentNorImportant,
      ),
    );
    await repository.save(
      TodoDraft(
        title: '立即处理',
        scheduledDate: day,
        priorityQuadrant: TodoPriorityQuadrant.urgentImportant,
      ),
    );
    // 初次排序结果。
    final List<TodoRecord> initial = await repository.watchForDay(day).first;
    expect(initial.first.title, '立即处理');

    await repository.setCompleted(initial.first.id, true);
    // 完成后的排序结果。
    final List<TodoRecord> reordered = await repository.watchForDay(day).first;
    expect(reordered.first.title, '稍后整理');
    expect(reordered.last.title, '立即处理');
  });

  test('同一自然日名言稳定且支持手动更换', () async {
    // 测试所属自然日。
    final DateTime day = DateTime(2026, 9, 4);
    // 第一次读取的名言。
    final QuoteRecord first = await database.quoteForDay(day);
    // 第二次读取的名言。
    final QuoteRecord repeated = await database.quoteForDay(day);
    expect(repeated.id, first.id);

    // 手动更换后的名言。
    final QuoteRecord changed = await database.changeQuoteForDay(day);
    expect(changed.id, isNot(first.id));
    expect((await database.quoteForDay(day)).id, changed.id);
  });

  test('每天重复按需生成独立实例且完成状态互不影响', () async {
    // 重复系列起始日。
    final DateTime firstDay = DateTime(2026, 9, 4);
    await repository.save(
      TodoDraft(
        title: '每日复盘',
        scheduledDate: firstDay,
        priorityQuadrant: TodoPriorityQuadrant.urgentNotImportant,
        repeatRule: TodoRepeatRule.daily,
      ),
    );
    // 次日按需生成的独立实例。
    final TodoRecord next =
        (await repository.watchForDay(DateTime(2026, 9, 5)).first).single;
    // 首日实例。
    final TodoRecord first =
        (await repository.watchForDay(firstDay).first).single;
    expect(next.id, isNot(first.id));
    expect(next.repeatSeriesId, first.repeatSeriesId);

    await repository.setCompleted(first.id, true);
    expect(
      (await repository.watchForDay(DateTime(2026, 9, 5)).first)
          .single
          .isCompleted,
      isFalse,
    );
  });

  test('每月 31 日在短月份回退到月末', () async {
    await repository.save(
      TodoDraft(
        title: '月末盘点',
        scheduledDate: DateTime(2026, 1, 31),
        priorityQuadrant: TodoPriorityQuadrant.urgentNotImportant,
        repeatRule: TodoRepeatRule.monthly,
      ),
    );
    // 二月月末实例。
    final List<TodoRecord> february = await repository
        .watchForDay(DateTime(2026, 2, 28))
        .first;
    expect(february, hasLength(1));
    expect(february.single.title, '月末盘点');
  });

  test('过去、今天和未来计划日期的未完成任务都常驻进行中', () async {
    // 当前测试自然日。
    final DateTime today = DateTime(2026, 9, 20);
    for (final (String, DateTime) draft in <(String, DateTime)>[
      ('过去任务', today.subtract(const Duration(days: 3))),
      ('今日任务', today),
      ('未来任务', today.add(const Duration(days: 5))),
    ]) {
      await repository.save(
        TodoDraft(title: draft.$1, scheduledDate: draft.$2),
      );
    }

    // 跨计划日期的进行中任务树。
    final List<TodoTreeNode> trees = await repository
        .watchActiveTrees(today)
        .first;
    expect(
      trees.map((TodoTreeNode tree) => tree.root.title),
      containsAll(<String>['过去任务', '今日任务', '未来任务']),
    );
  });

  test('子任务继承主任务日期和象限且主任务完成会级联', () async {
    // 主任务计划日。
    final DateTime day = DateTime(2026, 9, 20);
    await repository.save(
      TodoDraft(
        title: '发布版本',
        scheduledDate: day,
        priorityQuadrant: TodoPriorityQuadrant.urgentImportant,
      ),
    );
    // 新增后的主任务。
    final TodoRecord root = (await repository.watchForDay(day).first).single;
    await repository.save(
      TodoDraft(
        title: '整理更新说明',
        parentId: root.id,
        scheduledDate: day.add(const Duration(days: 2)),
        priorityQuadrant: TodoPriorityQuadrant.neitherUrgentNorImportant,
      ),
    );

    // 带子任务的活动树。
    final TodoTreeNode tree =
        (await repository.watchActiveTrees(day).first).single;
    expect(tree.children, hasLength(1));
    expect(tree.children.single.parentId, root.id);
    expect(tree.children.single.scheduledDate, day);
    expect(tree.children.single.priorityQuadrant, root.priorityQuadrant);

    await repository.setCompleted(root.id, true);
    // 同一天完成的主任务与子任务历史。
    final List<TodoHistoryEntry> history = await repository
        .watchCompletedForDay(DateTime.now())
        .first;
    expect(history, hasLength(2));
    expect(
      history.every((TodoHistoryEntry entry) => entry.todo.isCompleted),
      isTrue,
    );
    expect(
      history
          .singleWhere((TodoHistoryEntry entry) => entry.todo.parentId != null)
          .parentTitle,
      '发布版本',
    );
  });

  test('移动主任务会级联更新子任务象限并保存用户顺序', () async {
    // 当前测试自然日。
    final DateTime day = DateTime(2026, 9, 20);
    await repository.save(TodoDraft(title: '任务甲', scheduledDate: day));
    await repository.save(TodoDraft(title: '任务乙', scheduledDate: day));
    // 初始主任务。
    final List<TodoRecord> roots = await repository.watchForDay(day).first;
    // 任务甲记录。
    final TodoRecord first = roots.firstWhere(
      (TodoRecord record) => record.title == '任务甲',
    );
    await repository.save(
      TodoDraft(title: '任务甲子项', parentId: first.id, scheduledDate: day),
    );

    await repository.setPriorityQuadrant(
      first.id,
      TodoPriorityQuadrant.urgentNotImportant,
    );
    await repository.reorderRoots(
      TodoPriorityQuadrant.importantNotUrgent,
      <String>[roots.firstWhere((TodoRecord item) => item.title == '任务乙').id],
    );
    await repository.reorderRoots(
      TodoPriorityQuadrant.urgentNotImportant,
      <String>[first.id],
    );

    // 移动后的任务树。
    final TodoTreeNode moved = (await repository.watchActiveTrees(day).first)
        .firstWhere((TodoTreeNode tree) => tree.root.id == first.id);
    expect(
      moved.root.priorityQuadrant,
      TodoPriorityQuadrant.urgentNotImportant.value,
    );
    expect(
      moved.children.single.priorityQuadrant,
      TodoPriorityQuadrant.urgentNotImportant.value,
    );
    expect(moved.root.sortOrder, 1024);
  });

  test('重复主任务的新实例会复制当前子任务树', () async {
    // 重复系列起始日。
    final DateTime firstDay = DateTime(2026, 9, 20);
    await repository.save(
      TodoDraft(
        title: '每日发布检查',
        scheduledDate: firstDay,
        repeatRule: TodoRepeatRule.daily,
      ),
    );
    // 首日主任务。
    final TodoRecord root =
        (await repository.watchForDay(firstDay).first).single;
    await repository.save(
      TodoDraft(title: '检查监控', parentId: root.id, scheduledDate: firstDay),
    );

    // 次日物化后的活动树。
    final DateTime nextDay = firstDay.add(const Duration(days: 1));
    final List<TodoTreeNode> trees = await repository
        .watchActiveTrees(nextDay)
        .first;
    // 次日重复实例。
    final TodoTreeNode nextTree = trees.singleWhere(
      (TodoTreeNode tree) => tree.root.scheduledDate == nextDay,
    );
    expect(nextTree.root.id, isNot(root.id));
    expect(nextTree.children.single.title, '检查监控');
    expect(nextTree.children.single.parentId, nextTree.root.id);
  });

  test('整树删除在回收站只显示主任务且恢复整棵树', () async {
    // 当前测试自然日。
    final DateTime day = DateTime(2026, 9, 20);
    await repository.save(TodoDraft(title: '准备发布', scheduledDate: day));
    // 主任务记录。
    final TodoRecord root = (await repository.watchForDay(day).first).single;
    await repository.save(
      TodoDraft(title: '检查构建', parentId: root.id, scheduledDate: day),
    );
    await repository.delete(root.id);
    // 统一回收站仓储。
    final RecycleBinRepository recycleBin = RecycleBinRepository(
      database,
      repository,
    );
    // 回收站可见记录。
    final List<RecycleBinItem> items = await recycleBin.loadItems();
    expect(items, hasLength(1));
    expect(items.single.id, root.id);

    await recycleBin.restore(items.single);
    // 恢复后的活动任务树。
    final TodoTreeNode restored =
        (await repository.watchActiveTrees(day).first).single;
    expect(restored.root.id, root.id);
    expect(restored.children.single.title, '检查构建');
  });
}
