import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/features/events/data/event_repository.dart';
import 'package:omni_butler/features/inventory/data/inventory_repository.dart';
import 'package:omni_butler/features/memberships/data/membership_repository.dart';
import 'package:omni_butler/features/timeline/data/time_entry_repository.dart';

/// 验证第一阶段四个业务仓储的本地闭环规则。
void main() {
  /// 每个测试使用的内存数据库。
  late AppDatabase database;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await database.close();
  });

  test('事件记录现在、撤销与归档形成闭环', () async {
    // 测试事件仓储。
    final EventRepository repository = EventRepository(database);
    await repository.save(
      const EventDraft(
        name: '更换净水器滤芯',
        category: '居家',
        intervalValue: 3,
        intervalUnit: EventIntervalUnit.month,
        reminderEnabled: true,
        reminderDaysBefore: 7,
      ),
    );
    // 创建后的事件。
    final EventRecord event = (await repository.watchActive().first).single;
    expect(repository.nextDueAt(event), isNull);
    expect(
      repository.dueAtAfterCompletion(event, DateTime(2026, 11, 30, 10)),
      DateTime(2027, 2, 28, 10),
    );

    // 记录完成后的撤销凭据。
    final EventCompletionUndo undo = await repository.recordNow(event);
    // 记录完成后的事件。
    final EventRecord completed = (await repository.watchActive().first).single;
    expect(completed.lastCompletedAt, isNotNull);
    expect(await repository.watchHistory(event.id).first, hasLength(1));
    expect(await repository.watchActiveHistory().first, hasLength(1));
    expect(repository.nextDueAt(completed), isNotNull);

    await repository.undoRecord(undo);
    // 撤销后的事件。
    final EventRecord reverted = (await repository.watchActive().first).single;
    expect(reverted.lastCompletedAt, isNull);
    // 撤销后保留审计历史但不再参与最近完成时间计算。
    final List<EventCompletionRecord> auditHistory = await repository
        .watchHistory(event.id)
        .first;
    expect(auditHistory, hasLength(1));
    expect(auditHistory.single.isRevoked, isTrue);
    expect(await repository.watchActiveHistory().first, isEmpty);

    await repository.addHistory(
      eventId: event.id,
      completedAt: DateTime(2026, 9, 1, 10),
    );
    expect(await repository.watchActiveHistory().first, hasLength(1));

    await repository.setArchived(event.id, true);
    expect(await repository.watchActive().first, isEmpty);
    expect(await repository.watchArchived().first, hasLength(1));
    expect(await repository.watchActiveHistory().first, hasLength(1));

    await repository.delete(event.id);
    expect(await repository.watchActiveHistory().first, isEmpty);
  });

  test('物品支持字段保存、标签规范化与跨字段搜索', () async {
    // 测试物品仓储。
    final InventoryRepository repository = InventoryRepository(database);
    await repository.save(
      InventoryDraft(
        name: '机械键盘',
        category: '数码',
        quantity: 1,
        purchasePriceCents: 69900,
        purchaseDate: DateTime(2026, 8, 20),
        location: '书房抽屉',
        tags: const <String>['工作', '外设', '工作'],
      ),
    );
    // 全部物品。
    final List<InventoryRecord> all = await repository.watchAll().first;
    expect(all, hasLength(1));
    expect(all.single.tags, '工作,外设');
    expect(await repository.watchAll(query: '抽屉').first, hasLength(1));
    expect(await repository.watchAll(query: '厨房').first, isEmpty);

    // 配套物品不单独出现在主列表，但搜索命中时应回溯所属主物品。
    await repository.save(
      InventoryDraft(
        name: '键盘腕托',
        parentItemId: all.single.id,
        quantity: 1,
        purchasePriceCents: 9900,
        location: '书房抽屉',
      ),
    );
    expect(await repository.watchAll().first, hasLength(1));
    expect(await repository.watchAll(query: '腕托').first, hasLength(1));
    expect((await repository.watchAll(query: '腕托').first).single.name, '机械键盘');
    expect(await repository.watchAllAccessories().first, hasLength(1));

    await repository.delete(all.single.id);
    expect(await repository.watchAll().first, isEmpty);
  });

  test('物品默认按使用时间从短到长排列', () async {
    // 测试物品仓储。
    final InventoryRepository repository = InventoryRepository(database);
    await repository.save(
      InventoryDraft(
        name: '较早购买',
        quantity: 1,
        purchaseDate: DateTime(2025, 1, 1),
      ),
    );
    await repository.save(const InventoryDraft(name: '日期未知', quantity: 1));
    await repository.save(
      InventoryDraft(
        name: '最近购买',
        quantity: 1,
        purchaseDate: DateTime(2026, 9, 1),
      ),
    );

    // 按购买日期倒序对应使用时长从短到长，未知日期排在最后。
    final List<InventoryRecord> records = await repository.watchAll().first;
    expect(records.map((InventoryRecord item) => item.name), <String>[
      '最近购买',
      '较早购买',
      '日期未知',
    ]);
  });

  test('物品批量迁移保留分类关联并正确处理配套物品继承', () async {
    // 测试 taxonomy 仓储。
    final TaxonomyRepository taxonomyRepository = TaxonomyRepository(database);
    await taxonomyRepository.save(
      const TaxonomyDraft(
        module: TaxonomyModule.inventory,
        kind: TaxonomyKind.category,
        name: '数码',
        colorValue: 0xFF3370FF,
      ),
    );
    await taxonomyRepository.save(
      const TaxonomyDraft(
        module: TaxonomyModule.inventory,
        kind: TaxonomyKind.location,
        name: '书房',
        colorValue: 0xFF1EA7A1,
      ),
    );
    await taxonomyRepository.save(
      const TaxonomyDraft(
        module: TaxonomyModule.inventory,
        kind: TaxonomyKind.location,
        name: '储物间',
        colorValue: 0xFF1EA7A1,
      ),
    );
    // 测试分类和位置条目。
    final List<TaxonomyEntry> taxonomies = await database
        .select(database.taxonomyEntries)
        .get();
    // 数码分类。
    final TaxonomyEntry category = taxonomies.singleWhere(
      (TaxonomyEntry entry) => entry.name == '数码',
    );
    // 书房位置。
    final TaxonomyEntry study = taxonomies.singleWhere(
      (TaxonomyEntry entry) => entry.name == '书房',
    );
    // 储物间位置。
    final TaxonomyEntry storage = taxonomies.singleWhere(
      (TaxonomyEntry entry) => entry.name == '储物间',
    );
    // 测试物品仓储。
    final InventoryRepository repository = InventoryRepository(database);
    // 主物品标识。
    final String parentId = await repository.save(
      InventoryDraft(
        name: '相机',
        quantity: 1,
        category: category.name,
        categoryIds: <String>{category.id},
        location: study.name,
        locationIds: <String>{study.id},
      ),
    );
    // 随主物品存放的配套物品标识。
    final String inheritedAccessoryId = await repository.save(
      InventoryDraft(name: '相机肩带', quantity: 1, parentItemId: parentId),
    );
    // 独立存放的配套物品标识。
    final String independentAccessoryId = await repository.save(
      InventoryDraft(
        name: '备用电池',
        quantity: 2,
        parentItemId: parentId,
        location: study.name,
        locationIds: <String>{study.id},
      ),
    );
    // 模拟同步中只保留规范位置关联、冗余位置文本暂时缺失的数据。
    await (database.update(database.inventoryItems)..where(
          (InventoryItems table) => table.id.equals(independentAccessoryId),
        ))
        .write(const InventoryItemsCompanion(location: Value<String?>(null)));

    // 同时迁移主物品、继承位置配件和独立位置配件。
    final InventoryMoveResult result = await repository.moveItems(
      itemIds: <String>{parentId, inheritedAccessoryId, independentAccessoryId},
      destinationLocationId: storage.id,
    );
    expect(result.movedCount, 2);
    expect(result.followedCount, 1);
    expect(result.unchangedCount, 0);
    expect(result.affectedCount, 3);

    // 迁移后的全部物品记录。
    final List<InventoryRecord> movedRecords = await database
        .select(database.inventoryItems)
        .get();
    // 迁移后的主物品。
    final InventoryRecord movedParent = movedRecords.singleWhere(
      (InventoryRecord record) => record.id == parentId,
    );
    // 迁移后的继承位置配件。
    final InventoryRecord inheritedAccessory = movedRecords.singleWhere(
      (InventoryRecord record) => record.id == inheritedAccessoryId,
    );
    // 迁移后的独立位置配件。
    final InventoryRecord independentAccessory = movedRecords.singleWhere(
      (InventoryRecord record) => record.id == independentAccessoryId,
    );
    expect(movedParent.location, storage.name);
    expect(inheritedAccessory.location, isNull);
    expect(independentAccessory.location, storage.name);

    // 主物品迁移后的有效 taxonomy 关联。
    final List<RecordTaxonomyLink> activeParentLinks =
        await (database.select(database.recordTaxonomyLinks)..where(
              (RecordTaxonomyLinks table) =>
                  table.recordId.equals(parentId) & table.deletedAt.isNull(),
            ))
            .get();
    expect(
      activeParentLinks.map((RecordTaxonomyLink link) => link.taxonomyId),
      containsAll(<String>[category.id, storage.id]),
    );
    expect(
      activeParentLinks.map((RecordTaxonomyLink link) => link.taxonomyId),
      isNot(contains(study.id)),
    );

    // 单独迁移继承位置配件时，应把它转成独立存放。
    final InventoryMoveResult detachedResult = await repository.moveItems(
      itemIds: <String>{inheritedAccessoryId},
      destinationLocationId: study.id,
    );
    expect(detachedResult.movedCount, 1);
    // 转为独立存放后的配套物品记录。
    final InventoryRecord detachedAccessory =
        await (database.select(database.inventoryItems)..where(
              (InventoryItems table) => table.id.equals(inheritedAccessoryId),
            ))
            .getSingle();
    expect(detachedAccessory.location, study.name);

    // 重复迁移到当前位置时不产生多余写入。
    final InventoryMoveResult unchangedResult = await repository.moveItems(
      itemIds: <String>{parentId, independentAccessoryId},
      destinationLocationId: storage.id,
    );
    expect(unchangedResult.movedCount, 0);
    expect(unchangedResult.unchangedCount, 2);
  });

  test('时间记录拒绝重叠区间并按类别汇总', () async {
    // 测试时间仓储。
    final TimeEntryRepository repository = TimeEntryRepository(database);
    // 测试自然日。
    final DateTime day = DateTime(2026, 9, 4);
    await repository.save(
      TimeEntryDraft(
        entryDate: day,
        startMinute: 540,
        endMinute: 600,
        activity: '项目晨会',
        category: '工作',
      ),
    );
    expect(
      () => repository.save(
        TimeEntryDraft(
          entryDate: day,
          startMinute: 570,
          endMinute: 630,
          activity: '重叠会议',
        ),
      ),
      throwsA(isA<TimeEntryConflict>()),
    );
    await repository.save(
      TimeEntryDraft(
        entryDate: day,
        startMinute: 600,
        endMinute: 660,
        activity: '编码',
        category: '工作',
      ),
    );
    // 当日时间记录。
    final List<TimeEntryRecord> records = await repository
        .watchForDay(day)
        .first;
    expect(records, hasLength(2));
    expect(repository.summarizeByCategory(records)['工作'], 120);
  });

  test('会员保存时创建首笔支付并支持后续续费记录', () async {
    // 测试会员仓储。
    final MembershipRepository repository = MembershipRepository(database);
    await repository.save(
      MembershipDraft(
        name: '开发工具订阅',
        provider: 'Example Inc.',
        category: '软件',
        priceCents: 12000,
        purchaseDate: DateTime(2026, 9, 1),
        expirationDate: DateTime(2027, 9, 1),
        isPermanent: false,
        autoRenew: true,
        renewalDate: DateTime(2027, 9, 1),
      ),
    );
    // 新增后的会员。
    final MembershipRecord membership =
        (await repository.watchAll().first).single;
    expect(membership.autoRenew, isTrue);
    expect(await repository.watchPayments(membership.id).first, hasLength(1));

    await repository.recordPayment(
      membershipId: membership.id,
      amountCents: 12000,
      startDate: DateTime(2027, 9, 1),
      notes: '年度续费',
    );
    // 新增续费后的支付记录。
    final List<MembershipPaymentRecord> payments = await repository
        .watchPayments(membership.id)
        .first;
    expect(payments, hasLength(2));
    expect(payments.first.notes, '年度续费');
    final MembershipRecord renewedMembership =
        (await repository.watchAll().first).single;
    expect(renewedMembership.expirationDate, DateTime(2028, 9, 1));
    expect(renewedMembership.renewalDate, DateTime(2028, 9, 1));
  });

  test('自动续费到期后生成支付记录并且重复检查不会重复续费', () async {
    final MembershipRepository repository = MembershipRepository(database);
    await repository.save(
      MembershipDraft(
        name: '自动续费会员',
        priceCents: 2000,
        billingCycle: BillingCycle.month,
        purchaseDate: DateTime(2026, 1, 1),
        expirationDate: DateTime(2026, 2, 1),
        isPermanent: false,
        autoRenew: true,
        renewalDate: DateTime(2026, 2, 1),
      ),
    );
    final MembershipRecord membership =
        (await repository.watchAll().first).single;

    expect(await repository.processAutoRenewals(DateTime(2026, 2, 15)), 1);
    final List<MembershipPaymentRecord> payments = await repository
        .watchPayments(membership.id)
        .first;
    expect(payments, hasLength(2));
    expect(payments.first.amountCents, 2000);
    expect(payments.first.validFrom, DateTime(2026, 2, 1));

    final MembershipRecord renewed = (await repository.watchAll().first).single;
    expect(renewed.expirationDate, DateTime(2026, 3, 1));
    expect(renewed.renewalDate, DateTime(2026, 3, 1));
    expect(await repository.processAutoRenewals(DateTime(2026, 2, 15)), 0);
    expect(await repository.watchPayments(membership.id).first, hasLength(2));
  });
}
