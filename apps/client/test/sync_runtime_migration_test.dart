import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/sync/omni_sync_runtime.dart';
import 'package:omni_butler/core/sync/sync_snapshot.dart';
import 'package:omni_butler/core/sync/sync_image_report.dart';
import 'package:omni_butler/core/sync/sync_write_gate.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:powersync/powersync.dart';

/// 通过真实 PowerSync SQLite 验证跨服务器迁移的本地数据边界。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 每个运行时均使用独立文件，允许此测试同时打开旧库和候选库。
  final bool previousWarningSetting =
      driftRuntimeOptions.dontWarnAboutMultipleDatabases;
  setUpAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });
  tearDownAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = previousWarningSetting;
  });

  // 每个测试独占目录，绝不打开用户真实数据库。
  late Directory directory;
  // 不发起网络请求的认证仓储。
  late AuthRepository auth;
  // 迁移前的旧数据库。
  late OmniSyncRuntime source;
  // 需统一释放的候选运行时。
  final List<OmniSyncRuntime> candidates = <OmniSyncRuntime>[];
  // 固定日期保证快照结果可断言。
  final DateTime now = DateTime.utc(2026, 9, 27);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('omni_sync_migration_');
    auth = AuthRepository(const FlutterSecureStorage());
    source = await OmniSyncRuntime.openAtPath(
      auth,
      '${directory.path}/source.sqlite',
    );
  });

  tearDown(() async {
    for (final OmniSyncRuntime candidate in candidates.reversed) {
      await candidate.close();
    }
    candidates.clear();
    await source.close();
    await directory.delete(recursive: true);
  });

  /// 创建包含本机专属字段的软删除待办。
  Future<void> seedTodo(String id) => source.database
      .into(source.database.todoItems)
      .insert(
        TodoItemsCompanion.insert(
          id: id,
          title: '保留当前状态',
          scheduledDate: now,
          syncState: const Value<String>('localSaved'),
          deletedAt: Value<DateTime?>(now),
          createdAt: now,
          updatedAt: now,
        ),
      );

  test('冻结等待已开始事务完成，并拒绝旧仓储的新写入、批量和 RETURNING', () async {
    // 明确暂停在事务中间，证明冻结不会抢先导出半段数据。
    final Completer<void> started = Completer<void>();
    // 由测试放行事务第二段业务修改。
    final Completer<void> release = Completer<void>();
    // 已开始事务的完成信号。
    final Future<void> transaction = source.database.transaction(() async {
      await seedTodo('before-freeze');
      started.complete();
      await release.future;
      await seedTodo('after-freeze-in-same-transaction');
    });
    await started.future;
    // 维护开始后仍保留旧数据库引用模拟悬浮窗或旧仓储。
    final AppDatabase captured = source.database;
    // 冻结是否已经完成，用于证明确实等待在途事务。
    bool frozen = false;
    // 与业务事务并行启动的冻结请求。
    final Future<void> freezing = source.freezeWrites().then((_) {
      frozen = true;
    });
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(frozen, isFalse);
    await expectLater(seedTodo('rejected'), throwsA(isA<SyncWritesFrozen>()));
    release.complete();
    await transaction;
    await freezing;
    expect((await source.exportSnapshot()).counts['todo_items'], 2);
    await expectLater(
      captured.customSelect('DELETE FROM todo_items RETURNING *').get(),
      throwsA(isA<SyncWritesFrozen>()),
    );
    await expectLater(
      captured.batch((batch) {
        batch.deleteAll(captured.todoItems);
      }),
      throwsA(isA<SyncWritesFrozen>()),
    );
    expect(await captured.select(captured.todoItems).get(), hasLength(2));
    source.resumeWrites();
    await seedTodo('resumed');
    expect(await captured.select(captured.todoItems).get(), hasLength(3));
  });

  test('首次合并只产生完整 PUT 事务，覆盖服务器不复制旧队列或 clientId', () async {
    await seedTodo('todo');
    await source.powerSync.execute(
      'INSERT INTO device_sync_metadata(id, value) VALUES(?, ?)',
      <Object?>['owner', 'A'],
    );
    await source.freezeWrites();
    // JSON 往返确保实际持久化恢复使用相同快照格式。
    final SyncSnapshot snapshot = SyncSnapshot.fromJson(
      jsonDecode(jsonEncode((await source.exportSnapshot()).toJson()))
          as Map<String, dynamic>,
    );
    expect(snapshot.totalCount, 1);
    expect(snapshot.deletedCount, 1);
    expect(snapshot.pendingOperations, 1);
    expect(snapshot.tables.keys, unorderedEquals(SyncSnapshot.tableNames));
    expect(snapshot.tables, hasLength(13));
    expect(snapshot.operations.single['data'], isNot(contains('sync_state')));
    for (final bool merge in <bool>[true, false]) {
      // 两种保留本机的策略均从全新候选库开始。
      final OmniSyncRuntime candidate = await OmniSyncRuntime.createCandidate(
        auth,
        '${directory.path}/candidate-$merge.sqlite',
        snapshot,
        'B',
        mergeInitial: merge,
        useLocalData: true,
      );
      candidates.add(candidate);
      expect(await candidate.ownerId, 'B');
      expect(await source.ownerId, 'A');
      expect(
        await candidate.database.select(candidate.database.todoItems).get(),
        hasLength(1),
      );
      // 每个数据库都有独立的事务幂等身份。
      final Map<String, Object?> sourceIdentity = await source.powerSync.get(
        "SELECT value FROM device_sync_metadata WHERE id = 'client_id'",
      );
      // 候选库不会复用 A 的客户端身份。
      final Map<String, Object?> candidateIdentity = await candidate.powerSync
          .get("SELECT value FROM device_sync_metadata WHERE id = 'client_id'");
      expect(candidateIdentity['value'], isNot(sourceIdentity['value']));
      // 合并有且仅有当前全量 PUT，覆盖策略没有冗余上传。
      final CrudTransaction? pending = await candidate.powerSync
          .getNextCrudTransaction();
      if (merge) {
        expect(pending!.crud, hasLength(1));
        expect(pending.crud.single.op, UpdateType.put);
        expect(pending.crud.single.opData!['deleted_at'], isNotNull);
        await pending.complete();
      } else {
        expect(pending, isNull);
      }
      expect(await candidate.powerSync.getNextCrudTransaction(), isNull);
    }
    // 原库及其未上传操作仍完整保留作为备份。
    expect(await source.powerSync.getNextCrudTransaction(), isNotNull);
  });

  test('采用服务器时仅保留背景，下载后只恢复相同业务类型与 ID 的图片', () async {
    await source.database
        .into(source.database.inventoryItems)
        .insert(
          InventoryItemsCompanion.insert(
            id: 'shared',
            name: '相机',
            imageAttachmentId: const Value<String?>('inventory-image'),
            imageLocalPath: const Value<String?>('/local/inventory-image.png'),
            createdAt: now,
            updatedAt: now,
          ),
        );
    await source.database
        .into(source.database.memberships)
        .insert(
          MembershipsCompanion.insert(
            id: 'old-member',
            name: '会员',
            imageAttachmentId: const Value<String?>('member-image'),
            imageLocalPath: const Value<String?>('/local/member-image.png'),
            purchaseDate: now,
            createdAt: now,
            updatedAt: now,
          ),
        );
    await source.database
        .into(source.database.memberships)
        .insert(
          MembershipsCompanion.insert(
            id: 'shared-member',
            name: '保留图片的会员',
            imageAttachmentId: const Value<String?>('matched-member-image'),
            imageLocalPath: const Value<String?>(
              '/local/matched-member-image.png',
            ),
            purchaseDate: now,
            createdAt: now,
            updatedAt: now,
          ),
        );
    for (final Map<String, String> item in <Map<String, String>>[
      <String, String>{
        'id': 'inventory-image',
        'type': 'inventoryImage',
        'business': 'shared',
      },
      <String, String>{
        'id': 'member-image',
        'type': 'membershipImage',
        'business': 'old-member',
      },
      <String, String>{
        'id': 'matched-member-image',
        'type': 'membershipImage',
        'business': 'shared-member',
      },
      <String, String>{
        'id': 'background',
        'type': 'quoteBanner',
        'business': 'home',
      },
    ]) {
      await source.database
          .into(source.database.attachments)
          .insert(
            AttachmentsCompanion.insert(
              id: item['id']!,
              businessType: item['type']!,
              businessId: item['business']!,
              localPath: Value<String?>('/local/${item['id']}.png'),
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
    await source.database
        .into(source.database.bannerSettings)
        .insert(
          BannerSettingsCompanion.insert(
            id: 'banner',
            key: 'home',
            attachmentId: const Value<String?>('background'),
            updatedAt: now,
          ),
        );
    await source.freezeWrites();
    // 附件映射持久化在迁移快照中，业务数据不会先行导入采用服务器的库。
    final SyncSnapshot snapshot = await source.exportSnapshot();
    // 新候选库只有本机背景，没有旧业务与旧队列。
    final OmniSyncRuntime candidate = await OmniSyncRuntime.createCandidate(
      auth,
      '${directory.path}/remote.sqlite',
      snapshot,
      'B',
      mergeInitial: false,
      useLocalData: false,
    );
    candidates.add(candidate);
    expect(
      await candidate.database.select(candidate.database.inventoryItems).get(),
      isEmpty,
    );
    expect(
      await candidate.database.select(candidate.database.memberships).get(),
      isEmpty,
    );
    expect(
      (await candidate.database.select(candidate.database.attachments).get())
          .single
          .id,
      'background',
    );
    expect(await candidate.powerSync.getNextCrudTransaction(), isNull);
    // 用普通插入模拟服务器最终下行，然后确认该测试夹具队列。
    await candidate.database
        .into(candidate.database.inventoryItems)
        .insert(
          InventoryItemsCompanion.insert(
            id: 'shared',
            name: 'B 的相机',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await candidate.database
        .into(candidate.database.inventoryItems)
        .insert(
          InventoryItemsCompanion.insert(
            id: 'old-member',
            name: '同 ID 不同类型',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await candidate.database
        .into(candidate.database.memberships)
        .insert(
          MembershipsCompanion.insert(
            id: 'shared-member',
            name: 'B 的会员',
            purchaseDate: now,
            createdAt: now,
            updatedAt: now,
          ),
        );
    await (await candidate.powerSync.getCrudBatch())!.complete();
    await candidate.restoreLocalAttachments(snapshot, matchingOnly: true);
    expect(
      (await candidate.database.select(candidate.database.attachments).get())
          .map((row) => row.id),
      unorderedEquals(<String>[
        'background',
        'inventory-image',
        'matched-member-image',
      ]),
    );
    expect(
      (await candidate.powerSync.get(
        'SELECT image_attachment_id FROM inventory_items WHERE id = ?',
        <Object?>['shared'],
      ))['image_attachment_id'],
      'inventory-image',
    );
    expect(
      (await candidate.powerSync.get(
        'SELECT image_attachment_id FROM inventory_items WHERE id = ?',
        <Object?>['old-member'],
      ))['image_attachment_id'],
      isNull,
    );
    expect(
      (await candidate.powerSync.get(
        'SELECT image_local_path FROM inventory_items WHERE id = ?',
        <Object?>['shared'],
      ))['image_local_path'],
      '/local/inventory-image.png',
    );
    expect(
      (await candidate.powerSync.get(
        'SELECT image_local_path FROM inventory_items WHERE id = ?',
        <Object?>['old-member'],
      ))['image_local_path'],
      isNull,
    );
    expect(
      await candidate.powerSync.get(
        'SELECT image_attachment_id, image_local_path FROM memberships WHERE id = ?',
        <Object?>['shared-member'],
      ),
      <String, Object?>{
        'image_attachment_id': 'matched-member-image',
        'image_local_path': '/local/matched-member-image.png',
      },
    );
    expect(await candidate.powerSync.getNextCrudTransaction(), isNull);
    expect((await source.exportSnapshot()).tables['attachments'], hasLength(4));
  });

  test('采用服务器恢复真实有效路径，兼容仅业务路径并保留无上传边界', () async {
    // 业务字段中的文件与附件缓存中的文件分别模拟两种有效来源。
    final File businessFile = File('${directory.path}/business.png');
    final File attachmentFile = File('${directory.path}/attachment.png');
    await businessFile.writeAsBytes(<int>[1, 2, 3]);
    await attachmentFile.writeAsBytes(<int>[4, 5, 6]);
    for (final String id in <String>['business-path', 'attachment-path']) {
      await source.database
          .into(source.database.inventoryItems)
          .insert(
            InventoryItemsCompanion.insert(
              id: id,
              name: id,
              imageAttachmentId: Value<String?>('$id-image'),
              imageLocalPath: Value<String?>(
                id == 'business-path'
                    ? businessFile.path
                    : '${directory.path}/lost.png',
              ),
              createdAt: now,
              updatedAt: now,
            ),
          );
      await source.database
          .into(source.database.attachments)
          .insert(
            AttachmentsCompanion.insert(
              id: '$id-image',
              businessType: 'inventoryImage',
              businessId: id,
              localPath: Value<String?>(
                id == 'business-path' ? null : attachmentFile.path,
              ),
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
    for (final String id in <String>['legacy', 'different-type']) {
      await source.database
          .into(source.database.memberships)
          .insert(
            MembershipsCompanion.insert(
              id: id,
              name: id,
              imageLocalPath: Value<String?>(businessFile.path),
              purchaseDate: now,
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
    // 报告判定的有效文件必须在采用服务器的候选库真正恢复。
    final SyncSnapshot snapshot = await source.exportSnapshot();
    expect(await findMissingMigrationImages(snapshot), isEmpty);
    final OmniSyncRuntime candidate = await OmniSyncRuntime.createCandidate(
      auth,
      '${directory.path}/paths.sqlite',
      snapshot,
      'B',
      mergeInitial: false,
      useLocalData: false,
    );
    candidates.add(candidate);
    for (final String id in <String>[
      'business-path',
      'attachment-path',
      'different-type',
    ]) {
      await candidate.database
          .into(candidate.database.inventoryItems)
          .insert(
            InventoryItemsCompanion.insert(
              id: id,
              name: id,
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
    await candidate.database
        .into(candidate.database.memberships)
        .insert(
          MembershipsCompanion.insert(
            id: 'legacy',
            name: 'B会员',
            purchaseDate: now,
            createdAt: now,
            updatedAt: now,
          ),
        );
    // 清理用于模拟服务器下行的测试插入事务。
    while (true) {
      // 测试插入的待确认批次。
      final batch = await candidate.powerSync.getCrudBatch();
      if (batch == null) break;
      await batch.complete();
    }
    await candidate.restoreLocalAttachments(snapshot, matchingOnly: true);
    for (final MapEntry<String, String> expected in <String, String>{
      'business-path': businessFile.path,
      'attachment-path': attachmentFile.path,
    }.entries) {
      // 两个业务路径均与报告选中的现存文件一致。
      final Map<String, Object?> row = await candidate.powerSync.get(
        'SELECT image_local_path FROM inventory_items WHERE id = ?',
        <Object?>[expected.key],
      );
      expect(row['image_local_path'], expected.value);
      final Map<String, Object?> attachment = await candidate.powerSync.get(
        'SELECT local_path FROM attachments WHERE id = ?',
        <Object?>['${expected.key}-image'],
      );
      expect(attachment['local_path'], expected.value);
    }
    expect(
      await candidate.powerSync.get(
        'SELECT image_attachment_id,image_local_path FROM memberships WHERE id = ?',
        <Object?>['legacy'],
      ),
      <String, Object?>{
        'image_attachment_id': null,
        'image_local_path': businessFile.path,
      },
    );
    expect(
      (await candidate.powerSync.get(
        'SELECT image_local_path FROM inventory_items WHERE id = ?',
        <Object?>['different-type'],
      ))['image_local_path'],
      isNull,
    );
    expect(await candidate.powerSync.getNextCrudTransaction(), isNull);
  });

  test('候选文件重开不生成初始上传，重复创建不会覆盖已存在文件', () async {
    await seedTodo('old');
    // 恢复时使用的快照。
    final SyncSnapshot snapshot = await source.exportSnapshot();
    // 候选路径在重启后保持不变。
    final String candidatePath = '${directory.path}/resume.sqlite';
    // 初始化完成但尚未激活的候选库。
    final OmniSyncRuntime candidate = await OmniSyncRuntime.createCandidate(
      auth,
      candidatePath,
      snapshot,
      'B',
      mergeInitial: false,
      useLocalData: true,
    );
    await candidate.close();
    // 重启恢复明确关闭初始上传补齐逻辑。
    final OmniSyncRuntime reopened = await OmniSyncRuntime.openAtPath(
      auth,
      candidatePath,
      initializeUpload: false,
    );
    candidates.add(reopened);
    expect(await reopened.powerSync.getNextCrudTransaction(), isNull);
    expect(await reopened.ownerId, 'B');
    await expectLater(
      OmniSyncRuntime.createCandidate(
        auth,
        candidatePath,
        snapshot,
        'C',
        mergeInitial: false,
        useLocalData: false,
      ),
      throwsStateError,
    );
    expect((await reopened.exportSnapshot()).counts['todo_items'], 1);
  });

  test('全部候选策略冷启动后读取空首页和分类都不补造业务行或 CRUD', () async {
    // 空快照同样代表用户明确选择的数据状态。
    final SyncSnapshot snapshot = await source.exportSnapshot();
    for (final ({String name, bool merge, bool local}) strategy
        in <({String name, bool merge, bool local})>[
          (name: 'merge', merge: true, local: true),
          (name: 'replace-server', merge: false, local: true),
          (name: 'replace-local', merge: false, local: false),
        ]) {
      // 每种策略拥有独立候选文件，模拟激活后的普通冷启动。
      final String candidatePath = '${directory.path}/${strategy.name}.sqlite';
      // 标志在候选准备时写入，而不是依赖页面的临时开关。
      final OmniSyncRuntime candidate = await OmniSyncRuntime.createCandidate(
        auth,
        candidatePath,
        snapshot,
        'B',
        mergeInitial: strategy.merge,
        useLocalData: strategy.local,
      );
      await candidate.close();
      // 故意使用普通启动默认参数，证明重开不会取消候选的播种策略。
      final OmniSyncRuntime reopened = await OmniSyncRuntime.openAtPath(
        auth,
        candidatePath,
      );
      candidates.add(reopened);
      expect(
        await reopened.database.isDefaultBusinessSeedingDisabled(),
        isTrue,
      );
      expect(await reopened.database.quoteForDay(now), isNull);
      expect(
        await reopened.database.quoteForDay(now.add(const Duration(days: 1))),
        isNull,
      );
      // 所有模块分类读取都曾经触发内置时间分类初始化。
      final TaxonomyRepository taxonomy = TaxonomyRepository(reopened.database);
      for (final TaxonomyModule module in TaxonomyModule.values) {
        expect(
          await taxonomy
              .watch(module: module, kind: TaxonomyKind.category)
              .first,
          isEmpty,
        );
      }
      expect((await reopened.exportSnapshot()).totalCount, 0);
      expect(await reopened.powerSync.getNextCrudTransaction(), isNull);
    }
  });

  test('禁止默认播种仍保留已有每日身份的更新，不为没有名言的新日期建立空身份', () async {
    // 已有每日身份不属于默认数据播种，仍需维护失效引用。
    final OmniSyncRuntime candidate = await OmniSyncRuntime.createCandidate(
      auth,
      '${directory.path}/existing-day.sqlite',
      await source.exportSnapshot(),
      'B',
      mergeInitial: false,
      useLocalData: false,
    );
    candidates.add(candidate);
    await candidate.database
        .into(candidate.database.dailyQuoteSelections)
        .insert(
          DailyQuoteSelectionsCompanion.insert(
            id: 'existing-day',
            dayKey: businessDayKey(now),
            quoteId: const Value<String?>('removed-quote'),
            createdAt: now,
            updatedAt: now,
          ),
        );
    // 确认测试夹具的创建操作后，只观察正常读取导致的必要引用修正。
    await (await candidate.powerSync.getNextCrudTransaction())!.complete();
    expect(await candidate.database.quoteForDay(now), isNull);
    // 身份及创建时间保留，只把失效引用修正为空。
    final DailyQuoteSelectionRecord selection = await candidate.database
        .select(candidate.database.dailyQuoteSelections)
        .getSingle();
    expect(selection.id, 'existing-day');
    expect(selection.createdAt, now);
    expect(selection.quoteId, isNull);
    // 修正旧引用仍是正常可上传的 PATCH。
    final CrudTransaction? correction = await candidate.powerSync
        .getNextCrudTransaction();
    expect(correction!.crud, hasLength(1));
    expect(correction.crud.single.op, UpdateType.patch);
    expect(correction.crud.single.opData, containsPair('quote_id', null));
    await correction.complete();
    expect(
      await candidate.database.quoteForDay(now.add(const Duration(days: 1))),
      isNull,
    );
    expect((await candidate.exportSnapshot()).totalCount, 1);
    expect(await candidate.powerSync.getNextCrudTransaction(), isNull);
  });

  test('没有迁移标志的普通 PowerSync 与纯 Drift 本地库继续初始化默认业务数据', () async {
    // 纯 Drift 测试库不存在 device_sync_metadata，读取标志不得报表缺失。
    final AppDatabase local = AppDatabase.forTesting(NativeDatabase.memory());
    try {
      for (final AppDatabase database in <AppDatabase>[
        source.database,
        local,
      ]) {
        expect(await database.isDefaultBusinessSeedingDisabled(), isFalse);
        expect(await database.quoteForDay(now), isNotNull);
        expect(await database.select(database.quotes).get(), hasLength(2));
        expect(
          await database.select(database.dailyQuoteSelections).get(),
          hasLength(1),
        );
        expect(
          await TaxonomyRepository(database)
              .watch(
                module: TaxonomyModule.timeline,
                kind: TaxonomyKind.category,
              )
              .first,
          hasLength(6),
        );
      }
    } finally {
      await local.close();
    }
  });

  test('在途业务事务失败时冻结等待回滚，快照不包含部分写入', () async {
    // 事务开始与冻结之间的确定性同步信号。
    final Completer<void> started = Completer<void>();
    // 放行业务事务，使其在冻结后失败并回滚。
    final Completer<void> release = Completer<void>();
    // 模拟写入一半后抛出业务异常的异步操作。
    final Future<void> writing = source.database.transaction(() async {
      await seedTodo('rolled-back');
      started.complete();
      await release.future;
      throw StateError('模拟业务失败');
    });
    // 在放行之前安装错误处理，避免未处理异步异常干扰测试。
    final Future<void> expectedFailure = expectLater(writing, throwsStateError);
    await started.future;
    // 冻结必须等到整个事务真正回滚。
    final Future<void> freezing = source.freezeWrites();
    release.complete();
    await expectedFailure;
    await freezing;
    expect((await source.exportSnapshot()).totalCount, 0);
    expect(await source.powerSync.getNextCrudTransaction(), isNull);
  });

  test('已冻结及跨异步边界退休的旧运行时都不能重新启动连接', () async {
    await source.powerSync.execute(
      'INSERT INTO device_sync_metadata(id,value) VALUES(?,?)',
      <Object?>['owner', 'A'],
    );
    // 此连接正在 await 读取 owner，冻结随后在同一事件循环关闭准入。
    final Future<void> connecting = source.connect('A');
    // 提前安装错误观察，不让旧连接失败泄漏到测试事件循环。
    final Future<void> rejected = expectLater(
      connecting,
      throwsA(isA<SyncWritesFrozen>()),
    );
    await source.freezeWrites();
    await rejected;
    await expectLater(source.connect('A'), throwsA(isA<SyncWritesFrozen>()));
    expect(source.powerSync.connected, isFalse);
    expect(await source.ownerId, 'A');
  });

  test('候选导入遇到未知字段完整回滚，原数据库不受影响', () async {
    await seedTodo('safe');
    // 模拟磁盘快照在新版本中含有不可识别字段。
    final SyncSnapshot snapshot = SyncSnapshot.fromJson(
      jsonDecode(jsonEncode((await source.exportSnapshot()).toJson()))
          as Map<String, dynamic>,
    );
    snapshot.tables['todo_items']!.single['unknown_column'] = '拒绝导入';
    // 失败的候选路径仍只属于当前临时测试目录。
    final String candidatePath = '${directory.path}/failed.sqlite';
    await expectLater(
      OmniSyncRuntime.createCandidate(
        auth,
        candidatePath,
        snapshot,
        'B',
        mergeInitial: false,
        useLocalData: true,
      ),
      throwsFormatException,
    );
    // 失败库可被诊断或丢弃，但不会被误认为已完整准备。
    final OmniSyncRuntime failed = await OmniSyncRuntime.openAtPath(
      auth,
      candidatePath,
      initializeUpload: false,
    );
    candidates.add(failed);
    expect((await failed.exportSnapshot()).totalCount, 0);
    expect(await failed.ownerId, isNull);
    expect((await source.exportSnapshot()).totalCount, 1);
  });
}
