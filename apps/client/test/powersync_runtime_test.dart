import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/sync/omni_sync_runtime.dart';
import 'package:omni_butler/core/sync/omni_sync_schema.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/features/events/data/event_repository.dart';
import 'package:omni_butler/features/memberships/data/membership_repository.dart';
import 'package:omni_butler/features/settings/data/recycle_bin_repository.dart';
import 'package:omni_butler/features/timeline/data/time_entry_repository.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:powersync/powersync.dart';

/// 验证 PowerSync Raw Table 与 Drift 业务表共用同一 SQLite 文件。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('v20同步库升级保留旧标签PATCH且新触发器开始捕获置顶', () async {
    // 独立文件用于保留升级前的真实CRUD队列。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_pin_sync_upgrade_',
    );
    // 升级前后复用同一路径。
    final String databasePath = '${directory.path}/runtime.sqlite';
    // 本用例不连接任何服务器。
    final AuthRepository auth = AuthRepository(const FlutterSecureStorage());
    // 可关闭后重开的同步运行时。
    OmniSyncRuntime runtime = await OmniSyncRuntime.openAtPath(
      auth,
      databasePath,
    );
    try {
      // 当前schema去掉置顶和图标列才是v20的真实同步触发器形状。
      final RawTable oldTable = RawTable.inferred(
        name: 'taxonomy_entries',
        schema: RawTableSchema(
          syncedColumns: [
            ...omniSyncSchema.rawTables
                .singleWhere((table) => table.name == 'taxonomy_entries')
                .schema!
                .syncedColumns!
                .where(
                  (column) => column != 'is_pinned' && column != 'icon_emoji',
                ),
          ],
        ),
      );
      // 删除新触发器后才允许SQLite删除其引用的列。
      for (final String operation in ['INSERT', 'UPDATE', 'DELETE']) {
        await runtime.powerSync.execute(
          'DROP TRIGGER "powersync_taxonomy_entries_${operation.toLowerCase()}"',
        );
      }
      await runtime.database.customStatement(
        'ALTER TABLE taxonomy_entries DROP COLUMN is_pinned',
      );
      await runtime.database.customStatement(
        'ALTER TABLE taxonomy_entries DROP COLUMN icon_emoji',
      );
      // 按生产SDK安装旧版触发器，不直接伪造持久队列。
      for (final String operation in ['INSERT', 'UPDATE', 'DELETE']) {
        await runtime.powerSync.execute(
          'SELECT powersync_create_raw_table_crud_trigger(?, ?, ?)',
          [
            jsonEncode(oldTable),
            'powersync_taxonomy_entries_${operation.toLowerCase()}',
            operation,
          ],
        );
      }
      await runtime.database.customStatement(
        "INSERT INTO taxonomy_entries(id,module,kind,name,color_value,created_at,updated_at) VALUES('legacy-tag','notes','tag','旧标签',NULL,'2026-10-15T00:00:00Z','2026-10-15T00:00:00Z')",
      );
      await (await runtime.powerSync.getNextCrudTransaction())!.complete();
      await runtime.database.customStatement(
        "UPDATE taxonomy_entries SET name='升级前改名' WHERE id='legacy-tag'",
      );
      await runtime.database.customStatement('PRAGMA user_version = 20');
      await runtime.close();
      runtime = await OmniSyncRuntime.openAtPath(auth, databasePath);
      expect(
        (await runtime.database
                .select(runtime.database.taxonomyEntries)
                .getSingle())
            .isPinned,
        isFalse,
      );
      // 旧PATCH升级后仍不带默认false，避免覆盖其他设备的置顶。
      final CrudTransaction legacy = (await runtime.powerSync
          .getNextCrudTransaction())!;
      expect(legacy.crud.single.op, UpdateType.patch);
      expect(legacy.crud.single.opData, containsPair('name', '升级前改名'));
      expect(legacy.crud.single.opData, isNot(contains('is_pinned')));
      expect(legacy.crud.single.opData, isNot(contains('icon_emoji')));
      await legacy.complete();
      await runtime.database
          .update(runtime.database.taxonomyEntries)
          .write(const TaxonomyEntriesCompanion(isPinned: Value(true)));
      // 重建后的触发器捕获新增字段，名称不被重复提交。
      final CrudTransaction pinned = (await runtime.powerSync
          .getNextCrudTransaction())!;
      expect(pinned.crud.single.opData, containsPair('is_pinned', 1));
      expect(pinned.crud.single.opData, isNot(contains('name')));
    } finally {
      await runtime.close();
      await directory.delete(recursive: true);
    }
  });

  test('v21同步库升级保留旧改名PATCH，新触发器捕获组合图标与显式移除', () async {
    // 临时文件完整保留升级前的真实SDK队列，不访问用户数据库。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_icon_sync_upgrade_',
    );
    // 升级前后使用同一同步数据库文件。
    final String databasePath = '${directory.path}/runtime.sqlite';
    // 本用例不会启动网络连接。
    final AuthRepository auth = AuthRepository(const FlutterSecureStorage());
    // 可重开的生产同步运行时。
    OmniSyncRuntime runtime = await OmniSyncRuntime.openAtPath(
      auth,
      databasePath,
    );
    try {
      // v21已经支持置顶，但尚未声明或保存图标。
      final RawTable oldTable = RawTable.inferred(
        name: 'taxonomy_entries',
        schema: RawTableSchema(
          syncedColumns: [
            ...omniSyncSchema.rawTables
                .singleWhere((table) => table.name == 'taxonomy_entries')
                .schema!
                .syncedColumns!
                .where((column) => column != 'icon_emoji'),
          ],
        ),
      );
      // 先移除引用新列的当前触发器，再还原物理表结构。
      for (final String operation in ['INSERT', 'UPDATE', 'DELETE']) {
        await runtime.powerSync.execute(
          'DROP TRIGGER "powersync_taxonomy_entries_${operation.toLowerCase()}"',
        );
      }
      await runtime.database.customStatement(
        'ALTER TABLE taxonomy_entries DROP COLUMN icon_emoji',
      );
      // 旧触发器由生产SDK安装，CRUD记录由实际业务SQL生成。
      for (final String operation in ['INSERT', 'UPDATE', 'DELETE']) {
        await runtime.powerSync.execute(
          'SELECT powersync_create_raw_table_crud_trigger(?, ?, ?)',
          [
            jsonEncode(oldTable),
            'powersync_taxonomy_entries_${operation.toLowerCase()}',
            operation,
          ],
        );
      }
      await runtime.database.customStatement(
        "INSERT INTO taxonomy_entries(id,module,kind,name,color_value,sort_order,is_pinned,created_at,updated_at) VALUES('legacy-tag','notes','tag','旧标签',NULL,7,1,'2026-10-15T00:00:00Z','2026-10-15T00:00:00Z')",
      );
      await (await runtime.powerSync.getNextCrudTransaction())!.complete();
      await runtime.database.customStatement(
        "UPDATE taxonomy_entries SET name='升级前改名' WHERE id='legacy-tag'",
      );
      // 保存旧事务身份和负载，重开不能把默认空图标混入旧PATCH。
      final CrudTransaction beforeUpgrade = (await runtime.powerSync
          .getNextCrudTransaction())!;
      expect(beforeUpgrade.crud.single.opData, {'name': '升级前改名'});
      await runtime.database.customStatement('PRAGMA user_version = 21');
      await runtime.close();
      runtime = await OmniSyncRuntime.openAtPath(auth, databasePath);

      // 升级保留旧标签事实，新增可空图标不改变其他字段。
      final TaxonomyEntry upgraded = await runtime.database
          .select(runtime.database.taxonomyEntries)
          .getSingle();
      expect(upgraded.name, '升级前改名');
      expect(upgraded.iconEmoji, isNull);
      expect(upgraded.isPinned, isTrue);
      expect(upgraded.colorValue, isNull);
      expect(upgraded.sortOrder, 7);
      expect((await runtime.powerSync.getUploadQueueStats()).count, 1);
      // 已持久化的旧队列保持身份及原始差量，不能被升级改写。
      final CrudTransaction legacy = (await runtime.powerSync
          .getNextCrudTransaction())!;
      expect(legacy.transactionId, beforeUpgrade.transactionId);
      expect(legacy.crud.single.op, UpdateType.patch);
      expect(legacy.crud.single.opData, beforeUpgrade.crud.single.opData);
      expect(legacy.crud.single.opData, isNot(contains('icon_emoji')));
      await legacy.complete();

      // 升级后的实际业务入口只提交新修改的字段。
      final TaxonomyRepository repository = TaxonomyRepository(
        runtime.database,
      );
      await repository.updateNoteTagAppearance(
        upgraded.id,
        iconEmoji: const Value('👩🏽‍💻'),
      );
      // 新版触发器必须捕获完整多码点序列，且不附带名称或排序。
      final CrudTransaction selected = (await runtime.powerSync
          .getNextCrudTransaction())!;
      expect(selected.crud.single.op, UpdateType.patch);
      expect(
        selected.crud.single.opData,
        containsPair('icon_emoji', '👩🏽‍💻'),
      );
      expect(
        selected.crud.single.opData!.keys,
        unorderedEquals(['icon_emoji', 'updated_at']),
      );
      await selected.complete();
      await repository.save(
        TaxonomyDraft(
          id: upgraded.id,
          module: TaxonomyModule.notes,
          kind: TaxonomyKind.tag,
          name: '普通入口改名',
          colorValue: upgraded.colorValue,
          sortOrder: upgraded.sortOrder,
        ),
      );
      // 普通编辑入口也不能把本机图标加入自己的改名差量。
      final CrudTransaction renamed = (await runtime.powerSync
          .getNextCrudTransaction())!;
      expect(renamed.crud.single.opData, containsPair('name', '普通入口改名'));
      expect(renamed.crud.single.opData, isNot(contains('icon_emoji')));
      expect(
        (await runtime.database
                .select(runtime.database.taxonomyEntries)
                .getSingle())
            .iconEmoji,
        '👩🏽‍💻',
      );
      await renamed.complete();
      await repository.updateNoteTagAppearance(
        upgraded.id,
        iconEmoji: const Value(null),
      );
      // 移除必须产生显式null，省略字段只代表没有修改图标。
      final CrudTransaction removed = (await runtime.powerSync
          .getNextCrudTransaction())!;
      expect(removed.crud.single.opData, containsPair('icon_emoji', null));
      expect(removed.crud.single.opData, isNot(contains('name')));
      await removed.complete();
      expect((await runtime.powerSync.getUploadQueueStats()).count, 0);
      expect(
        (await runtime.database
                .select(runtime.database.taxonomyEntries)
                .getSingle())
            .iconEmoji,
        isNull,
      );
    } finally {
      await runtime.close();
      await directory.delete(recursive: true);
    }
  });

  test('v15 同步库升级保留历史队列，重装事件触发器后仅捕获备注', () async {
    // 独占临时数据库路径。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_event_sync_upgrade_',
    );
    // 升级前后复用同一个文件。
    final String databasePath = '${directory.path}/runtime.sqlite';
    // 本测试不发起网络请求。
    final AuthRepository auth = AuthRepository(const FlutterSecureStorage());
    // 构造带旧列和旧 PowerSync 触发器的同步库。
    OmniSyncRuntime runtime = await OmniSyncRuntime.openAtPath(
      auth,
      databasePath,
    );
    try {
      await runtime.database.customStatement(
        'ALTER TABLE events ADD COLUMN description TEXT',
      );
      // 还原 v15 事件同步列，保留历史 CRUD 负载。
      final RawTable oldTable = RawTable.inferred(
        name: 'events',
        schema: RawTableSchema(
          syncedColumns: <String>[
            ...omniSyncSchema.rawTables
                .singleWhere((RawTable table) => table.name == 'events')
                .schema!
                .syncedColumns!,
            'description',
          ],
        ),
      );
      for (final String operation in <String>['INSERT', 'UPDATE', 'DELETE']) {
        // 旧版真实同步触发器名称。
        final String trigger = 'powersync_events_${operation.toLowerCase()}';
        await runtime.powerSync.execute('DROP TRIGGER "$trigger"');
        await runtime.powerSync.execute(
          'SELECT powersync_create_raw_table_crud_trigger(?, ?, ?)',
          <Object?>[jsonEncode(oldTable), trigger, operation],
        );
      }
      await runtime.database.customStatement(
        'INSERT INTO events(id, name, notes, description, created_at, updated_at) VALUES(?, ?, ?, ?, ?, ?)',
        <Object?>[
          'preserved-event',
          '检查滤芯',
          '保留备注',
          '删除说明',
          '2026-10-11T03:00:00Z',
          '2026-10-11T03:00:00Z',
        ],
      );
      expect((await runtime.powerSync.getUploadQueueStats()).count, 1);
      await runtime.database.customStatement('PRAGMA user_version = 15');
      await runtime.close();
      runtime = await OmniSyncRuntime.openAtPath(auth, databasePath);
      expect(
        (await runtime.database.select(runtime.database.events).getSingle())
            .notes,
        '保留备注',
      );
      expect((await runtime.powerSync.getUploadQueueStats()).count, 1);
      // 已存在的旧队列仍可由退休字段适配器处理。
      final CrudTransaction? legacy = await runtime.powerSync
          .getNextCrudTransaction();
      expect(legacy!.crud.single.opData!['description'], '删除说明');
      await legacy.complete();
      await runtime.database
          .update(runtime.database.events)
          .write(const EventsCompanion(notes: Value<String?>('更新备注')));
      // 重新安装后的触发器不再引用已删除列。
      final CrudTransaction? updated = await runtime.powerSync
          .getNextCrudTransaction();
      expect(updated!.crud.single.opData, containsPair('notes', '更新备注'));
      expect(updated.crud.single.opData, isNot(contains('description')));
    } finally {
      await runtime.close();
      await directory.delete(recursive: true);
    }
  });

  test('真实 PowerSync 下支付统计流会收到订阅后的续费记录', () async {
    // 当前测试独占的真实 SQLite 文件目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_membership_payment_watch_',
    );
    // 真实 PowerSync 与 Drift 共用的 SQLite 文件路径。
    final String databasePath =
        '${directory.path}${Platform.pathSeparator}runtime.sqlite';
    // 无需真正读写安全存储的认证仓储。
    final AuthRepository auth = AuthRepository(const FlutterSecureStorage());
    // 生产路径使用的真实 PowerSync 运行时。
    final OmniSyncRuntime runtime = await OmniSyncRuntime.openAtPath(
      auth,
      databasePath,
      initializeUpload: false,
    );
    // 通过生产数据库创建的会员仓储。
    final MembershipRepository repository = MembershipRepository(
      runtime.database,
    );
    // 支付统计流迭代器，模拟会员页面持续订阅。
    final StreamIterator<List<MembershipPaymentRecord>> paymentEvents =
        StreamIterator<List<MembershipPaymentRecord>>(
          repository.watchActivePayments(),
        );
    try {
      // 待续费的会员标识。
      final String membershipId = await repository.save(
        MembershipDraft(
          name: '支付统计流回归会员',
          priceCents: 1000,
          billingCycle: BillingCycle.month,
          purchaseDate: DateTime(2026, 9, 1),
          expirationDate: DateTime(2026, 10, 1),
          isPermanent: false,
          autoRenew: false,
        ),
      );
      expect(await paymentEvents.moveNext(), isTrue);
      expect(paymentEvents.current, hasLength(1));

      await repository.recordPayment(
        membershipId: membershipId,
        amountCents: 1000,
        paidAt: DateTime(2026, 10, 1),
        billingCycle: BillingCycle.month,
      );

      expect(
        await paymentEvents.moveNext().timeout(const Duration(seconds: 5)),
        isTrue,
      );
      expect(paymentEvents.current, hasLength(2));
      expect(
        repository.summarizeSpending(
          paymentEvents.current,
          year: 2026,
          month: 10,
        ),
        1000,
      );
    } finally {
      await paymentEvents.cancel();
      await runtime.close();
      await directory.delete(recursive: true);
    }
  });

  test('真实 PowerSync 下业务时间点统一转换为设备本地时间', () async {
    // 当前测试独占的真实 SQLite 文件目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_local_timestamp_read_',
    );
    // 真实 PowerSync 与 Drift 共用的 SQLite 文件路径。
    final String databasePath =
        '${directory.path}${Platform.pathSeparator}runtime.sqlite';
    // 无需真正读写安全存储的认证仓储。
    final AuthRepository auth = AuthRepository(const FlutterSecureStorage());
    // 生产路径使用的真实 PowerSync 运行时。
    final OmniSyncRuntime runtime = await OmniSyncRuntime.openAtPath(
      auth,
      databasePath,
      initializeUpload: false,
    );
    // 模拟服务端下行的 UTC 时间点。
    final DateTime storedInstant = DateTime.utc(2026, 9, 30, 16, 30);
    // 当前设备对应的本地时间点。
    final DateTime localInstant = storedInstant.toLocal();
    // 当前设备对应的本地自然日。
    final DateTime localDay = DateTime(
      localInstant.year,
      localInstant.month,
      localInstant.day,
    );
    // 固定记录创建时间。
    final DateTime createdAt = DateTime.utc(2026, 9, 30, 15);
    try {
      await runtime.database
          .into(runtime.database.todoItems)
          .insert(
            TodoItemsCompanion.insert(
              id: '01990000-7000-8002-8000-000000000201',
              title: '跨时区完成待办',
              scheduledDate: localDay,
              dueAt: Value<DateTime?>(storedInstant),
              isCompleted: const Value<bool>(true),
              completedAt: Value<DateTime?>(storedInstant),
              createdAt: createdAt,
              updatedAt: createdAt,
            ),
          );
      // 生产待办仓储。
      final TodoRepository todoRepository = TodoRepository(runtime.database);
      // 本地自然日内的完成历史。
      final TodoHistoryEntry todoHistory =
          (await todoRepository.watchCompletedForDay(localDay).first).single;
      expect(todoHistory.todo.completedAt, localInstant);
      expect(todoHistory.todo.dueAt, localInstant);
      expect(todoHistory.todo.completedAt!.isUtc, isFalse);

      await runtime.database
          .into(runtime.database.events)
          .insert(
            EventsCompanion.insert(
              id: '01990000-7000-8002-8000-000000000202',
              name: '跨时区周期事件',
              intervalValue: const Value<int>(1),
              intervalUnit: const Value<String>('month'),
              lastCompletedAt: Value<DateTime?>(storedInstant),
              createdAt: createdAt,
              updatedAt: createdAt,
            ),
          );
      await runtime.database
          .into(runtime.database.eventCompletions)
          .insert(
            EventCompletionsCompanion.insert(
              id: '01990000-7000-8002-8000-000000000203',
              eventId: '01990000-7000-8002-8000-000000000202',
              completedAt: storedInstant,
              createdAt: createdAt,
            ),
          );
      // 生产事件仓储。
      final EventRepository eventRepository = EventRepository(runtime.database);
      // 本地化后的事件记录。
      final EventRecord event = (await eventRepository.watchActive().first)
          .singleWhere((EventRecord record) => record.name == '跨时区周期事件');
      // 本地化后的事件完成记录。
      final EventCompletionRecord completion =
          (await eventRepository.watchActiveHistory().first).single;
      expect(event.lastCompletedAt, localInstant);
      expect(completion.completedAt, localInstant);
      expect(completion.completedAt.isUtc, isFalse);

      await runtime.database
          .into(runtime.database.timeEntries)
          .insert(
            TimeEntriesCompanion.insert(
              id: '01990000-7000-8002-8000-000000000204',
              entryDate: localDay,
              startMinute: localInstant.hour * 60 + localInstant.minute,
              endMinute: localInstant.hour * 60 + localInstant.minute + 60,
              startedAt: storedInstant,
              endedAt: Value<DateTime?>(
                storedInstant.add(const Duration(hours: 1)),
              ),
              activity: const Value<String?>('跨时区时间记录'),
              createdAt: createdAt,
              updatedAt: createdAt,
            ),
          );
      // 生产时间记录仓储。
      final TimeEntryRepository timeRepository = TimeEntryRepository(
        runtime.database,
      );
      // 本地自然日内的时间记录。
      final TimeEntryRecord timeEntry =
          (await timeRepository.watchForDay(localDay).first).single;
      expect(timeEntry.startedAt, localInstant);
      expect(timeEntry.startedAt.isUtc, isFalse);

      await (runtime.database.update(runtime.database.todoItems)
            ..where((TodoItems table) => table.id.equals(todoHistory.todo.id)))
          .write(
            TodoItemsCompanion(deletedAt: Value<DateTime?>(storedInstant)),
          );
      // 生产回收站仓储。
      final RecycleBinRepository recycleRepository = RecycleBinRepository(
        runtime.database,
        todoRepository,
      );
      // 回收站内的待办记录。
      final RecycleBinItem recycleItem = (await recycleRepository.loadItems())
          .singleWhere((RecycleBinItem item) => item.id == todoHistory.todo.id);
      expect(recycleItem.deletedAt, localInstant);
      expect(recycleItem.deletedAt.isUtc, isFalse);
    } finally {
      await runtime.close();
      await directory.delete(recursive: true);
    }
  });

  test('每日选择下行 SQL 归并旧身份且旧身份删除不影响后续正常上传', () async {
    // 当前用例独占的真实 SQLite 文件目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_daily_downlink_',
    );
    // SQL 归并和后续真实运行时共用的文件。
    final String databasePath =
        '${directory.path}${Platform.pathSeparator}runtime.sqlite';
    // 下行 SQL 先在没有业务写入触发器的真实 SQLite 上验证。
    final AppDatabase fixture = AppDatabase.forTesting(
      NativeDatabase(File(databasePath)),
    );
    // 后续安装生产 CRUD 触发器，验证普通编辑仍可上传。
    OmniSyncRuntime? runtime;
    // 生产每日选择映射，保留 inferred schema 供初始化和触发器使用。
    final RawTable table = omniSyncSchema.rawTables.singleWhere(
      (RawTable table) => table.name == 'daily_quote_selections',
    );
    // 服务端时间仍使用 ISO 文本，交由 Drift 正常解析。
    final DateTime createdAt = DateTime.utc(2099, 1, 1, 2, 3);
    // 服务端最后更新时间。
    final DateTime updatedAt = DateTime.utc(2099, 1, 1, 4, 5);
    try {
      expect(table.schema!.syncedColumns, <String>[
        'day_key',
        'quote_id',
        'created_at',
        'updated_at',
      ]);
      try {
        await fixture
            .into(fixture.quotes)
            .insert(
              QuotesCompanion.insert(
                id: 'quote',
                content: '每日选择回归',
                createdAt: createdAt,
                updatedAt: createdAt,
              ),
            );
        await fixture
            .into(fixture.dailyQuoteSelections)
            .insert(
              DailyQuoteSelectionsCompanion.insert(
                id: 'legacy',
                dayKey: '2099-01-01',
                quoteId: const Value<String?>('quote'),
                createdAt: createdAt,
                updatedAt: createdAt,
              ),
            );
        // 直接验证 SQL 约束和日期映射；同步上下文的触发器抑制另由 E2E 覆盖。
        await fixture.customStatement(table.put!.sql, <Object?>[
          'canonical',
          '2099-01-01',
          null,
          createdAt.toIso8601String(),
          updatedAt.toIso8601String(),
        ]);
        // 相同主键的后续下行更新也应保持单行。
        await fixture.customStatement(table.put!.sql, <Object?>[
          'canonical',
          '2099-01-01',
          'quote',
          createdAt.toIso8601String(),
          updatedAt.toIso8601String(),
        ]);
        await fixture.customStatement(table.delete!.sql, <Object?>['legacy']);
      } finally {
        await fixture.close();
      }
      runtime = await OmniSyncRuntime.openAtPath(
        AuthRepository(const FlutterSecureStorage()),
        databasePath,
      );
      // 归并后的唯一业务记录。
      final DailyQuoteSelectionRecord selection = await runtime.database
          .select(runtime.database.dailyQuoteSelections)
          .getSingle();
      expect(selection.id, 'canonical');
      expect(selection.quoteId, 'quote');
      expect(selection.createdAt, createdAt);
      expect(selection.updatedAt, updatedAt);
      // 先确认运行时首次导入的完整 PUT 队列。
      final CrudBatch? fixtureBatch = await runtime.powerSync.getCrudBatch();
      expect(
        fixtureBatch!.crud
            .where((CrudEntry entry) => entry.table == 'daily_quote_selections')
            .single
            .id,
        'canonical',
      );
      await fixtureBatch.complete();
      await (runtime.database.update(
        runtime.database.dailyQuoteSelections,
      )..where((DailyQuoteSelections row) => row.id.equals('canonical'))).write(
        const DailyQuoteSelectionsCompanion(quoteId: Value<String?>(null)),
      );
      // 身份归并后正常业务修改必须仍由原有触发器捕获为 PATCH。
      final CrudBatch? localEdit = await runtime.powerSync.getCrudBatch();
      expect(localEdit!.crud, hasLength(1));
      expect(localEdit.crud.single.op, UpdateType.patch);
      expect(localEdit.crud.single.id, 'canonical');
      expect(localEdit.crud.single.opData, containsPair('quote_id', null));
    } finally {
      await runtime?.close();
      await directory.delete(recursive: true);
    }
  });

  test('v11 会员闲置字段删除后保留计费周期和支付有效期并生成兼容 PUT', () async {
    // 当前测试独占的临时目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_membership_v12_',
    );
    // 真实 PowerSync 与 Drift 共用的数据库路径。
    final String databasePath =
        '${directory.path}${Platform.pathSeparator}db.sqlite';
    // 用当前结构补回旧字段构造 v11 夹具。
    final AppDatabase fixture = AppDatabase.forTesting(
      NativeDatabase(File(databasePath)),
    );
    // 固定业务日期。
    final DateTime now = DateTime.utc(2026, 9, 25);
    // 当前打开的运行时。
    OmniSyncRuntime? runtime;
    try {
      try {
        await fixture
            .into(fixture.memberships)
            .insert(
              MembershipsCompanion.insert(
                id: '01990000-7000-8002-8000-000000000111',
                name: '保留的月费会员',
                billingCycle: const Value<String>('month'),
                purchaseDate: now,
                createdAt: now,
                updatedAt: now,
              ),
            );
        await fixture
            .into(fixture.membershipPayments)
            .insert(
              MembershipPaymentsCompanion.insert(
                id: '01990000-7000-8002-8000-000000000112',
                membershipId: '01990000-7000-8002-8000-000000000111',
                amountCents: 2000,
                paidAt: now,
                validFrom: Value<DateTime>(now),
                validUntil: Value<DateTime>(DateTime.utc(2026, 10, 25)),
                createdAt: now,
              ),
            );
        await fixture.customStatement(
          'ALTER TABLE memberships ADD COLUMN payment_method TEXT',
        );
        await fixture.customStatement(
          'ALTER TABLE memberships ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0',
        );
        await fixture.customStatement(
          'ALTER TABLE membership_payments ADD COLUMN billing_cycle TEXT',
        );
        await fixture.customStatement('PRAGMA user_version = 11');
      } finally {
        await fixture.close();
      }
      runtime = await OmniSyncRuntime.openAtPath(
        AuthRepository(const FlutterSecureStorage()),
        databasePath,
      );
      // 升级后保留的会员主记录。
      final MembershipRecord membership = await runtime.database
          .select(runtime.database.memberships)
          .getSingle();
      // 升级后保留的支付记录。
      final MembershipPaymentRecord payment = await runtime.database
          .select(runtime.database.membershipPayments)
          .getSingle();
      expect(membership.billingCycle, 'month');
      expect(payment.amountCents, 2000);
      expect(payment.validUntil, DateTime.utc(2026, 10, 25));
      // 会员表物理列名。
      final List<Map<String, Object?>> memberColumns = await runtime.powerSync
          .getAll("PRAGMA table_info('memberships')");
      // 支付表物理列名。
      final List<Map<String, Object?>> paymentColumns = await runtime.powerSync
          .getAll("PRAGMA table_info('membership_payments')");
      expect(
        memberColumns.map((row) => row['name']),
        isNot(contains('payment_method')),
      );
      expect(
        memberColumns.map((row) => row['name']),
        isNot(contains('is_favorite')),
      );
      expect(
        paymentColumns.map((row) => row['name']),
        isNot(contains('billing_cycle')),
      );
      // 初次同步导入的完整事务。
      final CrudTransaction? imported = await runtime.powerSync
          .getNextCrudTransaction();
      expect(imported!.crud, hasLength(2));
      expect(imported.crud.first.opData!['billing_cycle'], 'month');
      expect(imported.crud.first.opData, isNot(contains('payment_method')));
      expect(imported.crud.first.opData, isNot(contains('is_favorite')));
      expect(imported.crud.last.opData, isNot(contains('billing_cycle')));
    } finally {
      await runtime?.close();
      await directory.delete(recursive: true);
    }
  });

  test('捕获业务写入并排除仅本机字段', () async {
    // 本测试独占的临时目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_butler_powersync_',
    );
    // 无需真正读写安全存储的认证仓储。
    final AuthRepository auth = AuthRepository(const FlutterSecureStorage());
    // 使用真实 PowerSync SQLite 引擎的测试运行时。
    final OmniSyncRuntime runtime = await OmniSyncRuntime.openAtPath(
      auth,
      '${directory.path}${Platform.pathSeparator}runtime.sqlite',
    );
    try {
      // 当前 PowerSync 物品表字段信息。
      final List<Map<String, Object?>> inventoryColumns = await runtime
          .powerSync
          .getAll("PRAGMA table_info('inventory_items')");
      // 当前 PowerSync 物品表字段名。
      final List<String> inventoryColumnNames = inventoryColumns
          .map((Map<String, Object?> row) => row['name']! as String)
          .toList(growable: false);
      expect(inventoryColumnNames, isNot(contains('brand')));
      expect(inventoryColumnNames, isNot(contains('model')));

      // 固定业务创建时间。
      final DateTime now = DateTime.utc(2026, 9, 5, 1, 2, 3);
      await runtime.database
          .into(runtime.database.todoItems)
          .insert(
            TodoItemsCompanion.insert(
              id: '01990000-7000-8002-8000-000000000001',
              title: '验证离线队列',
              scheduledDate: DateTime.utc(2026, 9, 5),
              syncState: const Value<String>('localSaved'),
              createdAt: now,
              updatedAt: now,
            ),
          );

      // 捕获到的第一批 PowerSync 操作。
      final CrudBatch? batch = await runtime.powerSync.getCrudBatch();
      expect(batch, isNotNull);
      expect(batch!.crud, hasLength(1));
      // 待办新增操作。
      final CrudEntry operation = batch.crud.single;
      expect(operation.table, 'todo_items');
      expect(operation.op, UpdateType.put);
      expect(operation.opData?['title'], '验证离线队列');
      expect(operation.opData?['created_at'], isA<String>());
      expect(operation.opData, isNot(contains('sync_state')));
      await batch.complete();

      await (runtime.database.update(runtime.database.todoItems)
            ..where((TodoItems table) => table.id.equals(operation.id)))
          .write(const TodoItemsCompanion(syncState: Value<String>('synced')));
      // 只改本机同步提示不应形成新的云端写入。
      final CrudBatch? localOnlyBatch = await runtime.powerSync.getCrudBatch();
      expect(localOnlyBatch, isNull);

      await runtime.powerSync.execute(
        'INSERT INTO device_sync_metadata(id, value) VALUES(?, ?)',
        <Object?>['owner', '01990000-7000-8002-8000-000000000099'],
      );
      await runtime.disconnectAndClear();
      // 用户明确删除本机数据后，业务行与服务端身份归属都被清空。
      final List<TodoRecord> remainingTodos = await runtime.database
          .select(runtime.database.todoItems)
          .get();
      // 清空后的本机服务端身份归属元数据。
      final owner = await runtime.powerSync.getOptional(
        'SELECT value FROM device_sync_metadata WHERE id = ?',
        <Object?>['owner'],
      );
      expect(remainingTodos, isEmpty);
      expect(owner, isNull);
    } finally {
      await runtime.close();
      await directory.delete(recursive: true);
    }
  });

  test('旧待办紧急程度字段可经真实 PowerSync 运行时升级为优先象限', () async {
    // 本测试独占的临时目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_butler_powersync_migration_',
    );
    // 真实 PowerSync 与 Drift 共用的 SQLite 文件路径。
    final String databasePath =
        '${directory.path}${Platform.pathSeparator}migration.sqlite';
    // 用最新结构创建后回退字段名的 v4 测试夹具。
    final AppDatabase fixture = AppDatabase.forTesting(
      NativeDatabase(File(databasePath)),
    );
    await fixture.customSelect('SELECT 1').get();
    await fixture.customStatement(
      'ALTER TABLE todo_items RENAME COLUMN priority_quadrant TO urgency',
    );
    await fixture.customStatement('PRAGMA user_version = 4');
    await fixture.close();

    // 无需真正读写安全存储的认证仓储。
    final AuthRepository auth = AuthRepository(const FlutterSecureStorage());
    // 从旧结构打开的新同步运行时。
    final OmniSyncRuntime runtime = await OmniSyncRuntime.openAtPath(
      auth,
      databasePath,
    );
    try {
      // 新运行时中的待办表字段信息。
      final List<Map<String, Object?>> columns = await runtime.powerSync.getAll(
        "PRAGMA table_info('todo_items')",
      );
      // 新运行时中的待办表字段名。
      final List<String> columnNames = columns
          .map((Map<String, Object?> row) => row['name']! as String)
          .toList(growable: false);
      expect(columnNames, contains('priority_quadrant'));
      expect(columnNames, isNot(contains('urgency')));
      expect(columnNames, isNot(contains('notes')));
    } finally {
      await runtime.close();
      await directory.delete(recursive: true);
    }
  });

  test('旧物品品牌型号字段可经真实 PowerSync 运行时安全删除', () async {
    // 本测试独占的临时目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_butler_powersync_inventory_migration_',
    );
    // 真实 PowerSync 与 Drift 共用的 SQLite 文件路径。
    final String databasePath =
        '${directory.path}${Platform.pathSeparator}migration.sqlite';
    // 固定测试数据时间。
    final DateTime now = DateTime.utc(2026, 9, 8, 2);
    // 用最新结构创建后补回品牌型号列，构造 v6 测试夹具。
    final AppDatabase fixture = AppDatabase.forTesting(
      NativeDatabase(File(databasePath)),
    );
    await fixture.customSelect('SELECT 1').get();
    await fixture
        .into(fixture.inventoryItems)
        .insert(
          InventoryItemsCompanion.insert(
            id: 'legacy-powersync-inventory-item',
            name: '旧同步相机',
            notes: const Value<String?>('保留同步备注'),
            createdAt: now,
            updatedAt: now,
          ),
        );
    await fixture.customStatement(
      'ALTER TABLE inventory_items ADD COLUMN brand TEXT',
    );
    await fixture.customStatement(
      'ALTER TABLE inventory_items ADD COLUMN model TEXT',
    );
    await fixture.customStatement('PRAGMA user_version = 6');
    await fixture.close();

    // 无需真正读写安全存储的认证仓储。
    final AuthRepository auth = AuthRepository(const FlutterSecureStorage());
    // 从旧结构打开的新同步运行时。
    final OmniSyncRuntime runtime = await OmniSyncRuntime.openAtPath(
      auth,
      databasePath,
    );
    try {
      // 新运行时中的物品表字段信息。
      final List<Map<String, Object?>> columns = await runtime.powerSync.getAll(
        "PRAGMA table_info('inventory_items')",
      );
      // 新运行时中的物品表字段名。
      final List<String> columnNames = columns
          .map((Map<String, Object?> row) => row['name']! as String)
          .toList(growable: false);
      // 升级后保留下来的物品记录。
      final InventoryRecord item = await runtime.database
          .select(runtime.database.inventoryItems)
          .getSingle();

      expect(columnNames, isNot(contains('brand')));
      expect(columnNames, isNot(contains('model')));
      expect(item.name, '旧同步相机');
      expect(item.notes, '保留同步备注');
    } finally {
      await runtime.close();
      await directory.delete(recursive: true);
    }
  });
}
