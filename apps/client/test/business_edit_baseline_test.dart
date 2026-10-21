import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/home/data/quote_repository.dart';
import 'package:omni_butler/features/inventory/data/inventory_repository.dart';
import 'package:omni_butler/features/events/data/event_repository.dart';
import 'package:omni_butler/features/memberships/data/membership_repository.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:omni_butler/features/timeline/data/time_entry_repository.dart';

/// 旧表单与远端已下行的新事实必须在同一SQLite事务内比较。
void main() {
  // 每个测试只操作新的内存库，不碰用户运行中的数据文件。
  late AppDatabase database;
  // 各模块共用的有效业务日。
  final DateTime day = DateTime.utc(2026, 10, 20);
  setUp(() {
    database = AppDatabase.withExecutor(NativeDatabase.memory());
  });
  tearDown(() async {
    await database.close();
  });

  test('名言旧编辑表单不能复制回已下行的MCP内容', () async {
    // 真实仓储及打开表单时的原始记录。
    final QuoteRepository repository = QuoteRepository(database);
    await repository.save(const QuoteDraft(content: '打开时内容'));
    // 基线必须在用户编辑开始时固定。
    final QuoteRecord original = await database
        .select(database.quotes)
        .getSingle();
    await database
        .update(database.quotes)
        .write(const QuotesCompanion(content: Value<String>('MCP新内容')));
    await expectLater(
      repository.save(
        QuoteDraft(
          id: original.id,
          baseline: original.toJson(),
          content: '旧表单内容',
        ),
      ),
      throwsFormatException,
    );
    expect(
      (await database.select(database.quotes).getSingle()).content,
      'MCP新内容',
    );
  });

  test('物品旧表单不能撤销远端状态及位置变化', () async {
    // 原表单字段与后来的服务器下行彼此独立。
    final InventoryRepository repository = InventoryRepository(database);
    await repository.save(
      const InventoryDraft(
        quantity: 1,
        name: '物品',
        status: InventoryStatus.inUse,
      ),
    );
    // 用户打开时的完整事实。
    final InventoryRecord original = await database
        .select(database.inventoryItems)
        .getSingle();
    await database
        .update(database.inventoryItems)
        .write(
          const InventoryItemsCompanion(location: Value<String?>('MCP新位置')),
        );
    await expectLater(
      repository.save(
        InventoryDraft(
          quantity: 1,
          id: original.id,
          baseline: original.toJson(),
          name: '用户草稿',
          status: InventoryStatus.inUse,
        ),
      ),
      throwsFormatException,
    );
    expect(
      (await database.select(database.inventoryItems).getSingle()).location,
      'MCP新位置',
    );
  });

  test('会员表单不能把MCP新账期复制回旧值', () async {
    // 保存参数合法，失败必须来自基线而不是日期校验。
    final MembershipRepository repository = MembershipRepository(database);
    await repository.save(
      MembershipDraft(
        isPermanent: false,
        autoRenew: false,
        name: '会员',
        priceCents: 100,
        purchaseDate: day,
        expirationDate: day.add(const Duration(days: 30)),
      ),
    );
    // 编辑开始时保存的旧账期事实。
    final MembershipRecord original = await database
        .select(database.memberships)
        .getSingle();
    await database
        .update(database.memberships)
        .write(
          MembershipsCompanion(
            expirationDate: Value<DateTime?>(day.add(const Duration(days: 60))),
          ),
        );
    await expectLater(
      repository.save(
        MembershipDraft(
          isPermanent: false,
          autoRenew: false,
          id: original.id,
          baseline: original.toJson(),
          name: '用户草稿',
          priceCents: 100,
          purchaseDate: day,
          expirationDate: original.expirationDate,
        ),
      ),
      throwsFormatException,
    );
    expect(
      (await database.select(database.memberships).getSingle()).expirationDate,
      day.add(const Duration(days: 60)),
    );
  });

  test('事件旧表单不能清除MCP刚登记的最近完成事实', () async {
    // 普通周期事务，使用现有历史协调。
    final EventRepository repository = EventRepository(database);
    await repository.save(
      const EventDraft(
        intervalValue: 1,
        intervalUnit: EventIntervalUnit.month,
        name: '周期事务',
      ),
    );
    // 原来的空完成事实不能覆盖后来有效历史的汇总。
    final EventRecord original = await database
        .select(database.events)
        .getSingle();
    await database
        .update(database.events)
        .write(EventsCompanion(lastCompletedAt: Value<DateTime?>(day)));
    await expectLater(
      repository.save(
        EventDraft(
          intervalValue: 1,
          intervalUnit: EventIntervalUnit.month,
          id: original.id,
          baseline: original.toJson(),
          name: '旧表单草稿',
          lastCompletedAt: original.lastCompletedAt,
        ),
      ),
      throwsFormatException,
    );
    expect(
      (await database.select(database.events).getSingle()).lastCompletedAt,
      day,
    );
  });

  test('待办旧表单不能复制回MCP已修改的标题和完成状态', () async {
    // 原来的普通待办编辑器。
    final TodoRepository repository = TodoRepository(database);
    await repository.save(TodoDraft(title: '原标题', scheduledDate: day));
    // 编辑器打开时固定，而不是在保存时重新从数据库取基线。
    final TodoRecord original = await database
        .select(database.todoItems)
        .getSingle();
    await database
        .update(database.todoItems)
        .write(const TodoItemsCompanion(title: Value<String>('MCP新标题')));
    await expectLater(
      repository.save(
        TodoDraft(
          id: original.id,
          baseline: original.toJson(),
          title: '旧表单',
          scheduledDate: day,
        ),
      ),
      throwsFormatException,
    );
    expect(
      (await database.select(database.todoItems).getSingle()).title,
      'MCP新标题',
    );
  });

  test('时间记录旧表单不能覆盖已下行的新活动内容', () async {
    // 完整且无重叠的区间。
    final TimeEntryRepository repository = TimeEntryRepository(database);
    await repository.save(
      TimeEntryDraft(
        startedAt: day.subtract(const Duration(days: 1)),
        endedAt: day
            .subtract(const Duration(days: 1))
            .add(const Duration(hours: 1)),
        activity: '原活动',
      ),
    );
    // 真实读取编辑开始时记录。
    final TimeEntryRecord original = await database
        .select(database.timeEntries)
        .getSingle();
    await database
        .update(database.timeEntries)
        .write(const TimeEntriesCompanion(activity: Value<String?>('MCP新活动')));
    await expectLater(
      repository.save(
        TimeEntryDraft(
          id: original.id,
          baseline: original.toJson(),
          startedAt: original.startedAt,
          endedAt: original.endedAt,
          activity: '旧表单',
        ),
      ),
      throwsFormatException,
    );
    expect(
      (await database.select(database.timeEntries).getSingle()).activity,
      'MCP新活动',
    );
  });

  test('基线未变化可正常保存，不根据设备时钟先后猜测', () async {
    // 只排除非业务的syncState，不以时间先后代替事实比较。
    final QuoteRepository repository = QuoteRepository(database);
    await repository.save(const QuoteDraft(content: '原内容'));
    // 未变化的明确基线。
    final QuoteRecord original = await database
        .select(database.quotes)
        .getSingle();
    await repository.save(
      QuoteDraft(
        id: original.id,
        baseline: original.toJson(),
        content: '明确新编辑',
      ),
    );
    expect(
      (await database.select(database.quotes).getSingle()).content,
      '明确新编辑',
    );
  });

  test('会员分类关联失败时本体与首购一起回滚，不留下半笔本机事务', () async {
    // 在真实SQLite约束边界注入最后一步失败，而非模拟仓储返回值。
    await database.customStatement('''
      CREATE TRIGGER fail_membership_link BEFORE INSERT ON record_taxonomy_links
      WHEN NEW.module = 'membership'
      BEGIN SELECT RAISE(ABORT, 'isolated membership link failure'); END
    ''');
    // 合法会员与正金额确保本体、首购先经过真实保存路径。
    final MembershipRepository repository = MembershipRepository(database);
    await expectLater(
      repository.save(
        MembershipDraft(
          name: '事务回滚验证',
          priceCents: 100,
          purchaseDate: day,
          expirationDate: day.add(const Duration(days: 30)),
          isPermanent: false,
          autoRenew: false,
          tagIds: const <String>{'00000000-0000-4000-8000-000000000001'},
        ),
      ),
      throwsA(isA<Exception>()),
    );
    expect(await database.select(database.memberships).get(), isEmpty);
    expect(await database.select(database.membershipPayments).get(), isEmpty);
    expect(await database.select(database.recordTaxonomyLinks).get(), isEmpty);
  });
}
