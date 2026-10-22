import 'package:drift/drift.dart' show Value;
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
    final QuoteRecord first = (await database.quoteForDay(day))!;
    // 第二次读取的名言。
    final QuoteRecord repeated = (await database.quoteForDay(day))!;
    expect(repeated.id, first.id);

    // 手动更换后的名言。
    final QuoteRecord changed = (await database.changeQuoteForDay(day))!;
    expect(changed.id, isNot(first.id));
    expect((await database.quoteForDay(day))!.id, changed.id);
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

  test('重复待办复制数据库 UTC 时间对应的本地时刻', () async {
    // 重复系列起始日。
    final DateTime firstDay = DateTime(2026, 10, 1);
    // 模拟 PowerSync 下行的 UTC 截止时间。
    final DateTime storedDueAt = DateTime.utc(2026, 9, 30, 16, 30);
    await repository.save(
      TodoDraft(
        title: '跨时区每日任务',
        scheduledDate: firstDay,
        dueAt: storedDueAt,
        repeatRule: TodoRepeatRule.daily,
      ),
    );

    // 次日按需生成的独立实例。
    final TodoRecord next =
        (await repository.watchForDay(DateTime(2026, 10, 2)).first).single;
    // UTC 时间在当前设备上的本地时刻。
    final DateTime expectedLocalTime = storedDueAt.toLocal();
    expect(next.dueAt!.isUtc, isFalse);
    expect(next.dueAt!.hour, expectedLocalTime.hour);
    expect(next.dueAt!.minute, expectedLocalTime.minute);
  });

  test('本条及未来关闭重复写入停止标记，保留已生成实例且不再续生', () async {
    // 先建立较早种子，确保停止标记不能被旧规则绕过。
    final DateTime firstDay = DateTime(2026, 9, 4);
    await repository.save(
      TodoDraft(
        title: '每日复盘',
        scheduledDate: firstDay,
        repeatRule: TodoRepeatRule.daily,
      ),
    );
    // 当前及未来两条都已经存在，关闭重复不等于删除这些任务。
    final TodoRecord current =
        (await repository.watchForDay(DateTime(2026, 9, 5)).first).single;
    await repository.watchForDay(DateTime(2026, 9, 6)).first;
    await repository.save(
      TodoDraft(
        id: current.id,
        title: current.title,
        scheduledDate: current.scheduledDate,
      ),
      scope: TodoSeriesScope.future,
    );
    // 服务器与客户端共用stopped，而不是把null误解成缺少模板。
    final List<TodoRecord> saved = await database
        .select(database.todoItems)
        .get();
    expect(saved, hasLength(3));
    expect(
      saved
          .singleWhere((record) => record.scheduledDate == firstDay)
          .repeatRule,
      'daily',
    );
    expect(
      saved
          .where((record) => record.scheduledDate.isAfter(firstDay))
          .map((record) => record.repeatRule),
      everyElement('stopped'),
    );
    expect(saved.map((record) => record.deletedAt), everyElement(isNull));
    expect(await repository.watchForDay(DateTime(2026, 9, 7)).first, isEmpty);
  });

  test('已停止实例普通编辑保留停止事实，明确重新启用才恢复未来生成', () async {
    // 较早种子继续保留原规则，检验后续停止点是否仍生效。
    final DateTime firstDay = DateTime(2026, 9, 4);
    await repository.save(
      TodoDraft(
        title: '每日复盘',
        scheduledDate: firstDay,
        repeatRule: TodoRepeatRule.daily,
      ),
    );
    // 在第二天停止系列，再模拟编辑器默认不重复时仅修改标题。
    final TodoRecord current =
        (await repository.watchForDay(DateTime(2026, 9, 5)).first).single;
    await repository.save(
      TodoDraft(
        id: current.id,
        title: current.title,
        scheduledDate: current.scheduledDate,
      ),
      scope: TodoSeriesScope.future,
    );
    await repository.save(
      TodoDraft(
        id: current.id,
        title: '已停止，仅改标题',
        scheduledDate: current.scheduledDate,
      ),
    );
    expect(
      (await repository.watchForDay(current.scheduledDate).first)
          .single
          .repeatRule,
      'stopped',
    );
    expect(await repository.watchForDay(DateTime(2026, 9, 6)).first, isEmpty);
    await repository.save(
      TodoDraft(
        id: current.id,
        title: '明确恢复每日',
        scheduledDate: current.scheduledDate,
        repeatRule: TodoRepeatRule.daily,
      ),
      scope: TodoSeriesScope.future,
    );
    expect(
      (await repository.watchForDay(DateTime(2026, 9, 6)).first).single.title,
      '明确恢复每日',
    );
  });

  test('单条关闭仍为null例外，不停止后续系列也不重复生成当天实例', () async {
    // 单次例外与终止整个系列必须继续区分。
    final DateTime firstDay = DateTime(2026, 9, 4);
    await repository.save(
      TodoDraft(
        title: '每日复盘',
        scheduledDate: firstDay,
        repeatRule: TodoRepeatRule.daily,
      ),
    );
    // 当天实例只改为不重复，保留其稳定身份。
    final TodoRecord current =
        (await repository.watchForDay(DateTime(2026, 9, 5)).first).single;
    await repository.save(
      TodoDraft(
        id: current.id,
        title: '仅此一次',
        scheduledDate: current.scheduledDate,
      ),
    );
    // 再次读取同一天不能因其不在重复模板集合而新建副本。
    final List<TodoRecord> sameDay = await repository
        .watchForDay(current.scheduledDate)
        .first;
    expect(sameDay, hasLength(1));
    expect(sameDay.single.id, current.id);
    expect(sameDay.single.repeatRule, isNull);
    expect(
      (await repository.watchForDay(DateTime(2026, 9, 6)).first)
          .single
          .repeatRule,
      'daily',
    );
  });

  test('未来编辑重复子项保持null，不终止父任务系列', () async {
    // 子系列继承主任务日历，不能写入根系列的stopped标记。
    final DateTime firstDay = DateTime(2026, 9, 4);
    await repository.save(
      TodoDraft(
        title: '每日检查',
        scheduledDate: firstDay,
        repeatRule: TodoRepeatRule.daily,
      ),
    );
    // 从真实主任务身份创建子项，随后让仓储生成下一天的树。
    final TodoRecord root =
        (await repository.watchForDay(firstDay).first).single;
    await repository.save(
      TodoDraft(title: '检查子项', parentId: root.id, scheduledDate: firstDay),
    );
    // 下一天实例代表将要编辑的子系列。
    final List<TodoTreeNode> trees = await repository
        .watchActiveTrees(DateTime(2026, 9, 5))
        .first;
    final TodoRecord child = trees
        .singleWhere((tree) => tree.root.scheduledDate == DateTime(2026, 9, 5))
        .children
        .single;
    await repository.save(
      TodoDraft(
        id: child.id,
        title: '后续子项说明',
        parentId: child.parentId,
        scheduledDate: child.scheduledDate,
      ),
      scope: TodoSeriesScope.future,
    );
    // 子项未来编辑只影响内容，次日父子都仍能生成。
    final List<TodoTreeNode> nextTrees = await repository
        .watchActiveTrees(DateTime(2026, 9, 6))
        .first;
    final TodoTreeNode next = nextTrees.singleWhere(
      (tree) => tree.root.scheduledDate == DateTime(2026, 9, 6),
    );
    expect(next.root.repeatRule, 'daily');
    expect(next.children.single.repeatRule, isNull);
    expect(next.children.single.title, '后续子项说明');
  });

  test('无系列字段的旧重复种子关闭未来也生成有效停止标记', () async {
    // 构造旧版只有重复规则、没有独立系列身份的合法记录。
    final DateTime firstDay = DateTime(2026, 9, 4);
    await repository.save(
      TodoDraft(
        title: '旧系列',
        scheduledDate: firstDay,
        repeatRule: TodoRepeatRule.daily,
      ),
    );
    // 旧身份兼容行为保持使用种子id，不创建新系列。
    final TodoRecord root =
        (await repository.watchForDay(firstDay).first).single;
    await database.updateTodo(
      root.id,
      const TodoItemsCompanion(repeatSeriesId: Value<String?>(null)),
    );
    await repository.watchForDay(DateTime(2026, 9, 5)).first;
    await repository.save(
      TodoDraft(id: root.id, title: root.title, scheduledDate: firstDay),
      scope: TodoSeriesScope.future,
    );
    // 种子本身和已经生成的后继都被同一未来范围处理。
    final List<TodoRecord> saved = await database
        .select(database.todoItems)
        .get();
    expect(saved, hasLength(2));
    expect(saved.map((record) => record.repeatRule), everyElement('stopped'));
    expect(await repository.watchForDay(DateTime(2026, 9, 6)).first, isEmpty);
  });

  test('后续每周实例改为每天后使用新规则，不沿用最初种子的频率', () async {
    await repository.save(
      TodoDraft(
        title: '每周任务',
        scheduledDate: DateTime(2026, 9, 4),
        repeatRule: TodoRepeatRule.weekly,
      ),
    );
    // 后续实例的规则转换不能修改早期种子的日历事实。
    final TodoRecord current =
        (await repository.watchForDay(DateTime(2026, 9, 11)).first).single;
    await repository.save(
      TodoDraft(
        id: current.id,
        title: '改为每天',
        scheduledDate: current.scheduledDate,
        repeatRule: TodoRepeatRule.daily,
      ),
      scope: TodoSeriesScope.future,
    );
    expect(
      (await repository.watchForDay(DateTime(2026, 9, 12)).first)
          .single
          .repeatRule,
      'daily',
    );
    expect(
      (await repository.watchForDay(DateTime(2026, 9, 4)).first)
          .single
          .repeatRule,
      'weekly',
    );
  });

  test('每天改为每周以修改实例为新锚点，同规则生成不移动锚点', () async {
    await repository.save(
      TodoDraft(
        title: '每天任务',
        scheduledDate: DateTime(2026, 9, 4),
        repeatRule: TodoRepeatRule.daily,
      ),
    );
    // 新周期从修改的5日开始，每周12日、19日出现。
    final TodoRecord current =
        (await repository.watchForDay(DateTime(2026, 9, 5)).first).single;
    await repository.save(
      TodoDraft(
        id: current.id,
        title: '改为每周',
        scheduledDate: current.scheduledDate,
        repeatRule: TodoRepeatRule.weekly,
      ),
      scope: TodoSeriesScope.future,
    );
    expect(await repository.watchForDay(DateTime(2026, 9, 6)).first, isEmpty);
    expect(
      (await repository.watchForDay(DateTime(2026, 9, 12)).first)
          .single
          .repeatRule,
      'weekly',
    );
    expect(await repository.watchForDay(DateTime(2026, 9, 13)).first, isEmpty);
    expect(
      await repository.watchForDay(DateTime(2026, 9, 19)).first,
      hasLength(1),
    );
  });

  test('每天改为每月保留31日锚点，二月生成实例不会把三月移到28日', () async {
    await repository.save(
      TodoDraft(
        title: '每天任务',
        scheduledDate: DateTime(2026, 1, 30),
        repeatRule: TodoRepeatRule.daily,
      ),
    );
    // 每月的新日历锚点来自31日的规则转换实例。
    final TodoRecord current =
        (await repository.watchForDay(DateTime(2026, 1, 31)).first).single;
    await repository.save(
      TodoDraft(
        id: current.id,
        title: '月末任务',
        scheduledDate: current.scheduledDate,
        repeatRule: TodoRepeatRule.monthly,
      ),
      scope: TodoSeriesScope.future,
    );
    expect(await repository.watchForDay(DateTime(2026, 2, 1)).first, isEmpty);
    expect(
      (await repository.watchForDay(DateTime(2026, 2, 28)).first)
          .single
          .repeatRule,
      'monthly',
    );
    expect(await repository.watchForDay(DateTime(2026, 3, 28)).first, isEmpty);
    expect(
      await repository.watchForDay(DateTime(2026, 3, 31)).first,
      hasLength(1),
    );
  });

  test('同系列已有不同身份的null单次例外时，该日期不能双生', () async {
    await repository.save(
      TodoDraft(
        title: '每天任务',
        scheduledDate: DateTime(2026, 9, 4),
        repeatRule: TodoRepeatRule.daily,
      ),
    );
    // 服务器或旧备份中的同系列实例不保证使用当前稳定生成身份。
    final TodoRecord root =
        (await repository.watchForDay(DateTime(2026, 9, 4)).first).single;
    await database.createTodo(
      TodoItemsCompanion.insert(
        id: '487d31e0-28f0-4f90-a321-bc5873a03f70',
        title: '同步的单次例外',
        scheduledDate: DateTime(2026, 9, 5),
        repeatSeriesId: Value<String?>(root.repeatSeriesId),
        createdAt: DateTime(2026, 9, 4),
        updatedAt: DateTime(2026, 9, 4),
      ),
    );
    // 读取应保留既有例外，而不是用原规则再生成一条同日任务。
    final List<TodoRecord> sameDay = await repository
        .watchForDay(DateTime(2026, 9, 5))
        .first;
    expect(sameDay, hasLength(1));
    expect(sameDay.single.title, '同步的单次例外');
    expect(
      (await repository.watchForDay(DateTime(2026, 9, 6)).first).single.title,
      '每天任务',
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

  test('普通任务的子任务全部完成后仍等待手动完成主任务', () async {
    // 固定任务所属自然日。
    final DateTime day = DateTime(2026, 9, 20);
    await repository.save(TodoDraft(title: '手动确认发布', scheduledDate: day));
    // 子任务所属的主任务。
    final TodoRecord root = (await repository.watchForDay(day).first).single;
    for (final String title in <String>['编写说明', '检查构建']) {
      await repository.save(
        TodoDraft(title: title, parentId: root.id, scheduledDate: day),
      );
    }
    // 逐个完成的直属子任务。
    final List<TodoRecord> children =
        (await repository.watchActiveTrees(day).first).single.children;
    for (final TodoRecord child in children) {
      await repository.setCompleted(child.id, true);
      expect((await repository.watchById(root.id).first)!.isCompleted, isFalse);
      expect((await repository.watchById(root.id).first)!.completedAt, isNull);
    }
    // 全部子任务完成后，主任务仍在活动树中等待确认。
    final TodoTreeNode pending =
        (await repository.watchActiveTrees(day).first).single;
    expect(pending.pendingChildrenCount, 0);
    expect(pending.hasPending, isTrue);
    expect(
      await repository.watchCompletedForDay(DateTime.now()).first,
      hasLength(2),
    );

    await repository.setCompleted(root.id, true);
    expect((await repository.watchById(root.id).first)!.completedAt, isNotNull);
    expect(await repository.watchActiveTrees(day).first, isEmpty);
    expect(
      await repository.watchCompletedForDay(DateTime.now()).first,
      hasLength(3),
    );
    for (final TodoRecord child in pending.children) {
      expect(
        (await repository.watchById(child.id).first)!.completedAt,
        child.completedAt,
      );
    }

    await repository.setCompleted(children.first.id, false);
    expect((await repository.watchById(root.id).first)!.isCompleted, isFalse);
    await repository.setCompleted(children.first.id, true);
    expect((await repository.watchById(root.id).first)!.isCompleted, isFalse);
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
