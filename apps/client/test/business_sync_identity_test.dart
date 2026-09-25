import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/features/events/data/event_repository.dart';
import 'package:omni_butler/features/home/data/quote_repository.dart';
import 'package:omni_butler/features/memberships/data/membership_repository.dart';
import 'package:omni_butler/features/settings/data/recycle_bin_repository.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';

/// 在两个独立本地库中验证离线生成的业务身份和事件历史收敛输入。
void main() {
  // 双设备测试使用独立执行器，显式关闭 Drift 的同类数据库提示。
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  /// 第一台设备的独立数据库。
  late AppDatabase first;

  /// 第二台设备的独立数据库。
  late AppDatabase second;

  setUp(() {
    first = AppDatabase.forTesting(NativeDatabase.memory());
    second = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await first.close();
    await second.close();
  });

  test('同日首页在两端生成相同默认名言和选择身份', () async {
    // 两台设备分别离线打开同一天首页。
    final DateTime day = DateTime(2026, 9, 25);
    await first.quoteForDay(day);
    await second.quoteForDay(day);
    // 两端独立生成的选择。
    final DailyQuoteSelectionRecord firstSelection = await first
        .select(first.dailyQuoteSelections)
        .getSingle();
    final DailyQuoteSelectionRecord secondSelection = await second
        .select(second.dailyQuoteSelections)
        .getSingle();
    expect(firstSelection.id, secondSelection.id);
    expect(firstSelection.quoteId, secondSelection.quoteId);
    expect(
      (await first.select(first.quotes).get()).map((QuoteRecord row) => row.id),
      (await second.select(second.quotes).get()).map(
        (QuoteRecord row) => row.id,
      ),
    );
  });

  test('删除当天名言后保留选择身份并原位改选', () async {
    // 初始每日选择和所选名言。
    final DateTime day = DateTime(2026, 9, 25);
    final QuoteRecord quote = (await first.quoteForDay(day))!;
    final DailyQuoteSelectionRecord original = await first
        .select(first.dailyQuoteSelections)
        .getSingle();
    await QuoteRepository(first).delete(quote.id);
    // 软删除名言不能删除每日单例，否则服务器墓碑会阻止重建。
    expect(
      (await first.select(first.dailyQuoteSelections).getSingle()).id,
      original.id,
    );
    final QuoteRecord replacement = (await first.quoteForDay(day))!;
    final DailyQuoteSelectionRecord changed = await first
        .select(first.dailyQuoteSelections)
        .getSingle();
    expect(changed.id, original.id);
    expect(changed.quoteId, replacement.id);
    expect(replacement.id, isNot(quote.id));
    await first.changeQuoteForDay(day);
    expect(
      (await first.select(first.dailyQuoteSelections).getSingle()).id,
      original.id,
    );
  });

  test('永久清空名言保留每日空引用且不会重建内置身份', () async {
    // 初始化名言及当天稳定选择。
    final DateTime day = DateTime(2026, 9, 25);
    await first.quoteForDay(day);
    final DailyQuoteSelectionRecord original = await first
        .select(first.dailyQuoteSelections)
        .getSingle();
    // 通过真实回收站路径永久清理全部默认名言。
    final QuoteRepository quotes = QuoteRepository(first);
    final RecycleBinRepository recycle = RecycleBinRepository(
      first,
      TodoRepository(first),
    );
    for (final QuoteRecord quote in await quotes.watchAll().first) {
      await quotes.delete(quote.id);
    }
    for (final RecycleBinItem item in await recycle.loadItems()) {
      await recycle.permanentlyDelete(item);
    }
    expect(await first.quoteForDay(day), isNull);
    expect(await first.changeQuoteForDay(day), isNull);
    expect(await first.select(first.quotes).get(), isEmpty);
    // 空引用保留同一行，重复读取不再生成更新时间变化。
    final DailyQuoteSelectionRecord empty = await first
        .select(first.dailyQuoteSelections)
        .getSingle();
    expect(empty.id, original.id);
    expect(empty.quoteId, isNull);
    await first.quoteForDay(day);
    expect(
      (await first.select(first.dailyQuoteSelections).getSingle()).updatedAt,
      empty.updatedAt,
    );
    await quotes.save(const QuoteDraft(content: '新的名言'));
    expect((await first.quoteForDay(day))!.content, '新的名言');
    expect(
      (await first.select(first.dailyQuoteSelections).getSingle()).id,
      original.id,
    );
  });

  test('停用全部名言后返回空选择且换一条不会除零', () async {
    // 默认名言已创建并选中其中一条。
    final DateTime day = DateTime(2026, 9, 25);
    await first.quoteForDay(day);
    final QuoteRepository quotes = QuoteRepository(first);
    for (final QuoteRecord quote in await quotes.watchAll().first) {
      await quotes.setEnabled(quote.id, false);
    }
    expect(await first.quoteForDay(day), isNull);
    expect(await first.changeQuoteForDay(day), isNull);
    expect(
      (await first.select(first.dailyQuoteSelections).getSingle()).quoteId,
      isNull,
    );
  });

  test('重开父任务同时重开孩子以免服务端重新完成父任务', () async {
    // 一棵主子任务树。
    final TodoRepository todos = TodoRepository(first);
    final DateTime day = DateTime(2026, 9, 25);
    await todos.save(TodoDraft(title: '主任务', scheduledDate: day));
    final TodoRecord parent = (await todos.watchForDay(day).first).single;
    await todos.save(
      TodoDraft(title: '子任务', parentId: parent.id, scheduledDate: day),
    );
    await todos.setCompleted(parent.id, true);
    await todos.setCompleted(parent.id, false);
    final List<TodoRecord> rows = await first.select(first.todoItems).get();
    expect(rows, hasLength(2));
    expect(rows.every((TodoRecord row) => !row.isCompleted), isTrue);
    expect(rows.every((TodoRecord row) => row.completedAt == null), isTrue);
  });

  test('两端默认分类和同名分类身份相同且软删除后可原位恢复', () async {
    // 两端分类仓储。
    final TaxonomyRepository left = TaxonomyRepository(first);
    final TaxonomyRepository right = TaxonomyRepository(second);
    // 两端自动生成的默认类别。
    final List<TaxonomyEntry> leftDefaults = await left
        .watch(module: TaxonomyModule.timeline, kind: TaxonomyKind.category)
        .first;
    final List<TaxonomyEntry> rightDefaults = await right
        .watch(module: TaxonomyModule.timeline, kind: TaxonomyKind.category)
        .first;
    expect(
      leftDefaults.map((TaxonomyEntry row) => row.id),
      rightDefaults.map((TaxonomyEntry row) => row.id),
    );
    // 大小写与首尾空白不会产生不同业务身份。
    const TaxonomyDraft draft = TaxonomyDraft(
      module: TaxonomyModule.inventory,
      kind: TaxonomyKind.tag,
      name: ' Work ',
      colorValue: 0xFF3370FF,
    );
    await left.save(draft);
    await right.save(
      const TaxonomyDraft(
        module: TaxonomyModule.inventory,
        kind: TaxonomyKind.tag,
        name: 'work',
        colorValue: 0xFF3370FF,
      ),
    );
    // 新生成的同名标签。
    final TaxonomyEntry tag =
        (await left
                .watch(module: TaxonomyModule.inventory, kind: TaxonomyKind.tag)
                .first)
            .single;
    expect(
      tag.id,
      (await right
              .watch(module: TaxonomyModule.inventory, kind: TaxonomyKind.tag)
              .first)
          .single
          .id,
    );
    await left.delete(tag.id);
    await left.save(draft);
    // 重建实际上恢复原身份，关联无需改写。
    final TaxonomyEntry restored =
        (await left
                .watch(module: TaxonomyModule.inventory, kind: TaxonomyKind.tag)
                .first)
            .single;
    expect(restored.id, tag.id);
    expect(restored.deletedAt, isNull);
  });

  test('重命名后重新使用旧分类名不会覆盖已重命名条目', () async {
    // 当前分类仓储。
    final TaxonomyRepository repository = TaxonomyRepository(first);
    await repository.save(
      const TaxonomyDraft(
        module: TaxonomyModule.inventory,
        kind: TaxonomyKind.tag,
        name: '旧名',
        colorValue: 0xFF3370FF,
      ),
    );
    // 原始分类身份。
    final TaxonomyEntry initial =
        (await repository
                .watch(module: TaxonomyModule.inventory, kind: TaxonomyKind.tag)
                .first)
            .single;
    await repository.save(
      TaxonomyDraft(
        id: initial.id,
        module: TaxonomyModule.inventory,
        kind: TaxonomyKind.tag,
        name: '新名',
        colorValue: 0xFF3370FF,
      ),
    );
    await repository.save(
      const TaxonomyDraft(
        module: TaxonomyModule.inventory,
        kind: TaxonomyKind.tag,
        name: '旧名',
        colorValue: 0xFF3370FF,
      ),
    );
    // 新旧名称应作为不同记录存在。
    final List<TaxonomyEntry> records = await repository
        .watch(module: TaxonomyModule.inventory, kind: TaxonomyKind.tag)
        .first;
    expect(records, hasLength(2));
    expect(
      records.singleWhere((TaxonomyEntry row) => row.id == initial.id).name,
      '新名',
    );
  });

  test('同一重复系列在两端生成相同日期的同一棵子任务树', () async {
    // 初始种子日期和下一重复日。
    final DateTime day = DateTime(2026, 9, 24);
    final DateTime nextDay = DateTime(2026, 9, 25);
    // 第一台设备创建并向第二台设备复制共享种子。
    final TodoRepository left = TodoRepository(first);
    await left.save(
      TodoDraft(
        title: '每天整理',
        scheduledDate: day,
        repeatRule: TodoRepeatRule.daily,
      ),
    );
    // 原系列主任务。
    final TodoRecord root = (await left.watchForDay(day).first).single;
    await left.save(
      TodoDraft(title: '收拾桌面', parentId: root.id, scheduledDate: day),
    );
    for (final TodoRecord row in await first.select(first.todoItems).get()) {
      await second.into(second.todoItems).insert(row.toCompanion(true));
    }
    await left.watchForDay(nextDay).first;
    await TodoRepository(second).watchForDay(nextDay).first;
    // 比较主、子两条生成记录的身份。
    final List<TodoRecord> leftRows = await (first.select(
      first.todoItems,
    )..where((TodoItems table) => table.scheduledDate.equals(nextDay))).get();
    final List<TodoRecord> rightRows = await (second.select(
      second.todoItems,
    )..where((TodoItems table) => table.scheduledDate.equals(nextDay))).get();
    expect(leftRows, hasLength(2));
    expect(
      leftRows.map((TodoRecord row) => row.id).toSet(),
      rightRows.map((TodoRecord row) => row.id).toSet(),
    );
    await left.watchForDay(nextDay).first;
    expect(await first.select(first.todoItems).get(), hasLength(4));
  });

  test('两端同一自动续费账期共用账单身份而人工支付保持独立', () async {
    // 两端会员仓储。
    final MembershipRepository left = MembershipRepository(first);
    final MembershipRepository right = MembershipRepository(second);
    await left.save(
      MembershipDraft(
        name: '月度会员',
        priceCents: 2000,
        billingCycle: BillingCycle.month,
        purchaseDate: DateTime(2026, 1, 1),
        expirationDate: DateTime(2026, 2, 1),
        isPermanent: false,
        autoRenew: true,
      ),
    );
    // 复制同一会员起点，模拟两端同步后离线。
    final MembershipRecord membership = (await left.watchAll().first).single;
    await second.into(second.memberships).insert(membership.toCompanion(true));
    expect(await left.processAutoRenewals(DateTime(2026, 2, 15)), 1);
    expect(await right.processAutoRenewals(DateTime(2026, 2, 15)), 1);
    // 自动续费账单具有相同身份和有效期。
    final MembershipPaymentRecord leftPayment =
        (await left.watchPayments(membership.id).first).singleWhere(
          (MembershipPaymentRecord row) => row.notes == '自动续费',
        );
    final MembershipPaymentRecord rightPayment =
        (await right.watchPayments(membership.id).first).single;
    expect(leftPayment.id, rightPayment.id);
    expect(leftPayment.validUntil, rightPayment.validUntil);
    // RawTable 原样上传 SQLite 文本；日期前缀必须与自动账单身份一致。
    final QueryRow rawPayment = await first
        .customSelect(
          'SELECT valid_from FROM membership_payments WHERE id = ?',
          variables: <Variable<Object>>[Variable<String>(leftPayment.id)],
        )
        .getSingle();
    expect(
      rawPayment.read<String>('valid_from').substring(0, 10),
      '2026-02-01',
    );
    await left.recordPayment(
      membershipId: membership.id,
      amountCents: 2000,
      startDate: DateTime(2026, 2, 1),
    );
    expect(
      (await left.watchPayments(membership.id).first)
          .map((MembershipPaymentRecord row) => row.id)
          .toSet(),
      hasLength(3),
    );
    expect(await right.processAutoRenewals(DateTime(2026, 2, 15)), 0);
  });

  test('初始完成时间进入历史且撤销只撤销自己的记录', () async {
    // 事件仓储和初始时间。
    final EventRepository repository = EventRepository(first);
    final DateTime initial = DateTime(2026, 1, 1);
    await repository.save(
      EventDraft(
        name: '维护',
        intervalValue: 1,
        intervalUnit: EventIntervalUnit.month,
        lastCompletedAt: initial,
      ),
    );
    // 新事件已经拥有初始完成历史。
    final EventRecord event = (await repository.watchActive().first).single;
    expect(
      (await repository.watchHistory(event.id).first).single.source,
      'initial',
    );
    // 模拟其他设备的新历史在撤销本机记录前已经合并。
    final EventCompletionUndo undo = await repository.recordNow(event);
    final DateTime remote = DateTime(2090, 1, 1);
    await repository.addHistory(eventId: event.id, completedAt: remote);
    await repository.undoRecord(undo);
    expect(
      (await repository.watchActive().first).single.lastCompletedAt,
      remote,
    );
    // 删除最新有效历史后回到初始记录。
    final EventCompletionRecord latest =
        (await repository.watchHistory(event.id).first).singleWhere(
          (EventCompletionRecord row) => row.completedAt == remote,
        );
    await repository.deleteHistory(latest);
    expect(
      (await repository.watchActive().first).single.lastCompletedAt,
      initial,
    );
    await repository.save(
      EventDraft(
        id: event.id,
        name: '维护',
        intervalValue: 1,
        intervalUnit: EventIntervalUnit.month,
        lastCompletedAt: DateTime(2026, 2, 1),
      ),
    );
    expect(
      (await repository.watchActive().first).single.lastCompletedAt,
      DateTime(2026, 2, 1),
    );
  });
}
