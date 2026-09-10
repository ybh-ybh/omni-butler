import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/todos/data/todo_priority_quadrant.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';

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
}
