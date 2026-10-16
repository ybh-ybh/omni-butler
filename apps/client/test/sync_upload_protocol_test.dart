import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_providers.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/sync/omni_powersync_connector.dart';
import 'package:omni_butler/core/sync/omni_sync_runtime.dart';
import 'package:omni_butler/core/sync/omni_sync_schema.dart';
import 'package:omni_butler/core/sync/sync_providers.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/features/notes/data/note_repository.dart';
import 'package:omni_butler/features/notes/data/note_tag_actions.dart';
import 'package:powersync/powersync.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 记录上传请求且不访问网络的认证替身。
class _RecordingAuth extends AuthRepository {
  /// 已发送请求的独立副本。
  final List<Map<String, dynamic>> requests = <Map<String, dynamic>>[];

  /// 是否模拟服务端处理后响应丢失。
  bool loseResponse = false;

  /// 是否模拟服务器已不支持当前业务结构。
  bool schemaCompatible = true;

  /// 可选上传开始信号，供会话竞态测试使用。
  Completer<void>? uploadStarted;

  /// 可选上传响应闸门，供会话竞态测试使用。
  Completer<void>? uploadRelease;

  /// 离线状态下是否已开始请求同步凭证。
  final Completer<void> credentialRequested = Completer<void>();

  /// 创建不访问安全存储的认证替身。
  _RecordingAuth() : super(const FlutterSecureStorage());

  /// 上传协议用例专注事务重试；真实握手由认证仓储测试覆盖。
  @override
  Future<void> ensureSyncSchemaForGeneration(int generation) async {
    if (!schemaCompatible) throw const SyncSchemaMismatch();
  }

  /// 捕获生产连接器提交的真实事务请求体。
  @override
  Future<Response<T>> authorizedRequest<T>(
    String method,
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    ResponseType? responseType,
    bool preserveTransportErrors = false,
  }) async {
    requests.add(jsonDecode(jsonEncode(data)) as Map<String, dynamic>);
    uploadStarted?.complete();
    await uploadRelease?.future;
    if (loseResponse) {
      throw const ApiFailure('模拟响应丢失');
    }
    return Response<T>(requestOptions: RequestOptions(path: path));
  }

  /// 模拟暂时离线，让 PowerSync 接管后续重试。
  @override
  Future<PowerSyncCredential> fetchPowerSyncCredential() async {
    if (!schemaCompatible) throw const SyncSchemaMismatch();
    if (!credentialRequested.isCompleted) {
      credentialRequested.complete();
    }
    throw const ApiFailure('模拟暂时离线');
  }
}

/// 从缓存恢复离线会话的控制器替身。
class _OfflineAuthController extends AuthController {
  /// 返回已经验证归属的缓存身份。
  @override
  Future<SyncSession?> build() async => const SyncSession(
    identity: SyncIdentity(id: '01990000-7000-8002-8000-000000000099'),
    apiBaseUrl: 'http://127.0.0.1:3000/omni-butler/api/v1',
    isOffline: true,
  );
}

/// 在批量回收的最后一步失败，验证真实同步队列也服从外层事务。
class _FailingDeletionTaxonomy extends TaxonomyRepository {
  /// 与笔记仓储共用生产同步数据库。
  _FailingDeletionTaxonomy(super.database);

  /// 标签解绑及软删除都完成后再触发事务回滚。
  @override
  Future<void> delete(String id, {bool retainUndoLinks = true}) async {
    await super.delete(id, retainUndoLinks: retainUndoLinks);
    throw StateError('模拟批量回收最后一步失败');
  }
}

/// 写入合法的测试待办，供旧数据库和生产 Drift 桥接共用。
Future<void> _insertTodo(AppDatabase database, String id) async {
  // 固定业务时间，避免测试依赖时钟。
  final DateTime now = DateTime.utc(2026, 9, 24);
  await database
      .into(database.todoItems)
      .insert(
        TodoItemsCompanion.insert(
          id: id,
          title: '同步协议测试',
          scheduledDate: now,
          createdAt: now,
          updatedAt: now,
        ),
      );
}

/// 验证完整事务、幂等重试、初始导入和离线启动行为。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('批量回收失败不留同步队列，成功时正文附件和标签基线只上传一个事务', () async {
    // 使用真实触发器生成上传队列，不手动伪造 CRUD 记录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_note_tag_delete_upload_',
    );
    // 只记录生产连接器生成的上传请求，不访问网络。
    final _RecordingAuth auth = _RecordingAuth();
    // 隔离的生产 PowerSync 数据库。
    final OmniSyncRuntime runtime = await OmniSyncRuntime.openAtPath(
      auth,
      '${directory.path}/db.sqlite',
    );
    try {
      // 正式笔记仓储负责版本和子资源生命周期。
      final NoteRepository notes = NoteRepository(runtime.database);
      // 本次删除的标签身份。
      const String tagId = '01990000-7000-8002-8000-000000000201';
      // 多标签笔记上仍应保留的标签身份。
      const String otherTagId = '01990000-7000-8002-8000-000000000202';
      // 单标签、多标签及无关笔记的原始标签快照。
      const Map<String, Set<String>> originalTags = {
        '01990000-7000-8002-8000-000000000203': {tagId},
        '01990000-7000-8002-8000-000000000204': {tagId, otherTagId},
        '01990000-7000-8002-8000-000000000205': {otherTagId},
      };
      // 多标签笔记同时拥有录音和图片。
      const String multiNoteId = '01990000-7000-8002-8000-000000000204';
      // 正式图片身份。
      const String imageId = '01990000-7000-8002-8000-000000000206';
      // 正式录音身份。
      const String audioId = '01990000-7000-8002-8000-000000000207';
      // 确认框捕获的全部活动笔记身份。
      final Set<String> expectedNoteIds = originalTags.entries
          .where((entry) => entry.value.contains(tagId))
          .map((entry) => entry.key)
          .toSet();
      // 固定种子时间。
      final DateTime now = DateTime.utc(2026, 10, 15);
      // 写入两条有效笔记标签。
      for (final String id in [tagId, otherTagId]) {
        await runtime.database
            .into(runtime.database.taxonomyEntries)
            .insert(
              TaxonomyEntriesCompanion.insert(
                id: id,
                module: 'notes',
                kind: 'tag',
                name: id,
                colorValue: 0,
                createdAt: now,
                updatedAt: now,
              ),
            );
      }
      // 每篇正式笔记都通过生产保存入口生成不可变版本。
      for (final MapEntry<String, Set<String>> entry in originalTags.entries) {
        await notes.save(
          NoteDraft(
            id: entry.key,
            body: entry.key,
            dayKey: '2026-10-15',
            baseRevision: '',
            tags: entry.value,
          ),
        );
      }
      await runtime.database
          .into(runtime.database.noteImages)
          .insert(
            NoteImagesCompanion.insert(
              id: imageId,
              noteId: multiNoteId,
              sortOrder: 0,
              createdAt: now,
              updatedAt: now,
            ),
          );
      await runtime.database
          .into(runtime.database.noteAudioSegments)
          .insert(
            NoteAudioSegmentsCompanion.insert(
              id: audioId,
              noteId: multiNoteId,
              sortOrder: 0,
              durationMs: 1000,
              mime: 'audio/wav',
              sha256: 'hash',
              byteSize: 100,
              createdAt: now,
              updatedAt: now,
            ),
          );
      // 记录应被回收的版本身份，不能仅断言操作条数。
      final Set<String> versionIds =
          (await runtime.database.select(runtime.database.noteVersions).get())
              .where((version) => expectedNoteIds.contains(version.noteId))
              .map((version) => version.id)
              .toSet();
      await OmniPowerSyncConnector(auth).uploadData(runtime.powerSync);
      auth.requests.clear();
      // 最后一步失败应回滚正文、附件、标签以及触发器生成的队列。
      final NoteTagActions failing = NoteTagActions(
        runtime.database,
        notes,
        _FailingDeletionTaxonomy(runtime.database),
      );
      await expectLater(
        failing.deleteTagAndNotes(tagId, expectedNoteIds: expectedNoteIds),
        throwsStateError,
      );
      expect((await runtime.powerSync.getUploadQueueStats()).count, 0);
      await OmniPowerSyncConnector(auth).uploadData(runtime.powerSync);
      expect(auth.requests, isEmpty);
      expect((await notes.find(multiNoteId))!.deletedAt, isNull);
      expect(
        noteTagIds((await notes.find(multiNoteId))!.tags),
        originalTags[multiNoteId],
      );

      // 用同一确认集合重试正式领域入口。
      final NoteTagActions actions = NoteTagActions(
        runtime.database,
        notes,
        TaxonomyRepository(runtime.database),
      );
      expect(
        await actions.deleteTagAndNotes(
          tagId,
          expectedNoteIds: expectedNoteIds,
        ),
        expectedNoteIds,
      );
      // 捕获真实队列身份，确认上传没有拆开事务。
      final CrudTransaction transaction = (await runtime.powerSync
          .getNextCrudTransaction())!;
      await OmniPowerSyncConnector(auth).uploadData(runtime.powerSync);
      expect(auth.requests, hasLength(1));
      expect(
        auth.requests.single['transactionId'],
        transaction.transactionId.toString(),
      );
      // 真实上传中的所有操作都来自同一次批量回收。
      final List<Map> operations = (auth.requests.single['operations'] as List)
          .cast<Map>();
      expect(operations, hasLength(transaction.crud.length));
      expect(
        operations.every((operation) => operation['op'] == 'PATCH'),
        isTrue,
      );
      // 每类生命周期对象的精确身份，排除无关笔记和标签被误修改。
      final Map<String, Set<String>> expectedDeleted = {
        'note_entries': expectedNoteIds,
        'note_versions': versionIds,
        'note_images': {imageId},
        'note_audio_segments': {audioId},
        'taxonomy_entries': {tagId},
      };
      expect(
        operations.map((operation) => operation['table']).toSet(),
        expectedDeleted.keys.toSet(),
      );
      // 正文、历史版本、原音、图片及标签都携带软删除字段。
      for (final MapEntry<String, Set<String>> entry
          in expectedDeleted.entries) {
        expect(
          operations
              .where((operation) => operation['table'] == entry.key)
              .map((operation) => operation['id'])
              .toSet(),
          entry.value,
        );
        expect(
          operations
              .where(
                (operation) =>
                    operation['table'] == entry.key &&
                    (operation['data'] as Map)['deleted_at'] != null,
              )
              .map((operation) => operation['id'])
              .toSet(),
          entry.value,
        );
      }
      // 标签解绑必须携带触发器保存的真实旧值，保留多标签笔记的其他标签。
      final List<Map> tagChanges = operations
          .where(
            (operation) =>
                operation['table'] == 'note_entries' &&
                (operation['data'] as Map).containsKey('tags'),
          )
          .toList();
      expect(tagChanges, hasLength(expectedNoteIds.length));
      // 对每条笔记验证基线与删除后的标签，而不依赖 JSON 排列顺序。
      for (final Map operation in tagChanges) {
        // 本条标签变化的实际负载。
        final Map data = operation['data'] as Map;
        expect(
          noteTagIds(data['tags_base'] as String),
          originalTags[operation['id']],
        );
        expect(
          noteTagIds(data['tags'] as String),
          originalTags[operation['id']]!.difference({tagId}),
        );
      }
      expect((await runtime.powerSync.getUploadQueueStats()).count, 0);
    } finally {
      await runtime.close();
      await directory.delete(recursive: true);
    }
  });

  test('置顶上传仅携带自身差量，离线改名和排序不覆盖跨端置顶', () async {
    // 独立运行真实PowerSync触发器和持久队列。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_tag_pin_upload_',
    );
    // 仅捕获上传负载，不连接网络。
    final _RecordingAuth auth = _RecordingAuth();
    // 实际同步数据库。
    final OmniSyncRuntime runtime = await OmniSyncRuntime.openAtPath(
      auth,
      '${directory.path}/db.sqlite',
    );
    try {
      // 生产仓储负责所有差量写入。
      final TaxonomyRepository repository = TaxonomyRepository(
        runtime.database,
      );
      await repository.save(
        const TaxonomyDraft(
          module: TaxonomyModule.notes,
          kind: TaxonomyKind.tag,
          name: '工作',
          colorValue: 42,
        ),
      );
      // 从真实创建队列取得标签身份，避免触发默认分类播种。
      final CrudTransaction creation = (await runtime.powerSync
          .getNextCrudTransaction())!;
      // 本次创建的稳定标签ID。
      final String id = creation.crud.single.id;
      await OmniPowerSyncConnector(auth).uploadData(runtime.powerSync);
      expect(
        ((auth.requests.single['operations'] as List).single['data']
            as Map)['is_pinned'],
        0,
      );
      auth.requests.clear();
      await repository.setPinned(id, true);
      await repository.save(
        TaxonomyDraft(
          id: id,
          module: TaxonomyModule.notes,
          kind: TaxonomyKind.tag,
          name: '已改名',
          colorValue: 42,
        ),
      );
      await repository.reorder([id]);
      await OmniPowerSyncConnector(auth).uploadData(runtime.powerSync);
      // 三次事务保持各自字段，不因最终数据库状态而扩充旧PATCH。
      final List<Map> operations = [
        for (final Map<String, dynamic> request in auth.requests)
          ...(request['operations'] as List).cast<Map>(),
      ];
      expect(operations, hasLength(3));
      expect((operations.first['data'] as Map)['is_pinned'], 1);
      expect((operations.first['data'] as Map).containsKey('name'), isFalse);
      expect(
        (operations.first['data'] as Map).containsKey('sort_order'),
        isFalse,
      );
      for (final Map operation in operations.skip(1)) {
        expect((operation['data'] as Map).containsKey('is_pinned'), isFalse);
      }
    } finally {
      await runtime.close();
      await directory.delete(recursive: true);
    }
  });

  test('图标上传保留组合字符与显式移除，普通标签更新不携带图标', () async {
    // 使用实际触发器与队列，验证更新没有扩散为整行写入。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_tag_appearance_upload_',
    );
    // 仅记录请求，不连接网络。
    final _RecordingAuth auth = _RecordingAuth();
    // 实际 PowerSync 数据库。
    final OmniSyncRuntime runtime = await OmniSyncRuntime.openAtPath(
      auth,
      '${directory.path}/db.sqlite',
    );
    try {
      // 所有改动走生产仓储。
      final TaxonomyRepository repository = TaxonomyRepository(
        runtime.database,
      );
      await repository.save(
        const TaxonomyDraft(
          module: TaxonomyModule.notes,
          kind: TaxonomyKind.tag,
          name: '工作',
          colorValue: 42,
        ),
      );
      // 从创建事务中取得真实的稳定标签身份。
      final CrudTransaction creation = (await runtime.powerSync
          .getNextCrudTransaction())!;
      // 刚创建的标签标识。
      final String id = creation.crud.single.id;
      await OmniPowerSyncConnector(auth).uploadData(runtime.powerSync);
      // 正常创建队列省略空列，服务器使用 nullable 默认值。
      final Map creationData =
          (auth.requests.single['operations'] as List).single['data'] as Map;
      expect(creationData['icon_emoji'], isNull);
      auth.requests.clear();

      await repository.updateNoteTagAppearance(
        id,
        name: const Value('开发'),
        iconEmoji: const Value('👩🏽‍💻'),
      );
      await repository.save(
        TaxonomyDraft(
          id: id,
          module: TaxonomyModule.notes,
          kind: TaxonomyKind.tag,
          name: '普通入口改名',
          colorValue: 42,
        ),
      );
      await repository.reorder([id]);
      await repository.setPinned(id, true);
      await repository.updateNoteTagAppearance(
        id,
        iconEmoji: const Value(null),
      );
      await OmniPowerSyncConnector(auth).uploadData(runtime.powerSync);
      // 保留每次事务的原始差量，不能用最终行状态覆盖旧操作。
      final List<Map> operations = [
        for (final Map<String, dynamic> request in auth.requests)
          ...(request['operations'] as List).cast<Map>(),
      ];
      expect(operations, hasLength(5));
      expect((operations.first['data'] as Map)['name'], '开发');
      expect((operations.first['data'] as Map)['icon_emoji'], '👩🏽‍💻');
      expect(
        (operations.first['data'] as Map).keys,
        unorderedEquals(['name', 'icon_emoji', 'updated_at']),
      );
      // 普通改名、排序和置顶不能携带旧图标值。
      for (final Map operation in operations.skip(1).take(3)) {
        expect((operation['data'] as Map).containsKey('icon_emoji'), isFalse);
      }
      expect(
        (operations.last['data'] as Map).containsKey('icon_emoji'),
        isTrue,
      );
      expect((operations.last['data'] as Map)['icon_emoji'], isNull);
      expect((operations.last['data'] as Map).containsKey('name'), isFalse);
      expect((await runtime.powerSync.getUploadQueueStats()).count, 0);
    } finally {
      await runtime.close();
      await directory.delete(recursive: true);
    }
  });

  test('真实笔记PUT不携带标签基线，正文日期PATCH不附带未修改标签基线', () async {
    // 仅使用真实生产触发器生成队列，不手工插入powersync_crud。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_note_tags_shape_',
    );
    // 捕获真实连接器最终请求。
    final _RecordingAuth auth = _RecordingAuth();
    // 隔离运行时与业务数据库。
    final OmniSyncRuntime runtime = await OmniSyncRuntime.openAtPath(
      auth,
      '${directory.path}/db.sqlite',
    );
    // 初始归档时刻。
    final DateTime now = DateTime.utc(2026, 10, 11);
    try {
      await runtime.database
          .into(runtime.database.noteEntries)
          .insert(
            NoteEntriesCompanion.insert(
              id: '01990000-7000-8002-8000-000000000101',
              body: const Value('初始正文'),
              dayKey: '2026-10-11',
              tags: const Value('["initial"]'),
              revision: '01990000-7000-8002-8000-000000000102',
              createdAt: now,
              updatedAt: now,
            ),
          );
      // SDK实际创建操作，不是快照合成操作。
      final CrudTransaction? creation = await runtime.powerSync
          .getNextCrudTransaction();
      expect(creation!.crud.single.op, UpdateType.put);
      await OmniPowerSyncConnector(auth).uploadData(runtime.powerSync);
      // 首次PUT以完整tags定义新记录，不需要旧版本基线。
      final Map<String, dynamic> created =
          (auth.requests.single['operations'] as List).single
              as Map<String, dynamic>;
      expect(created['data']['tags'], '["initial"]');
      expect((created['data'] as Map).containsKey('tags_base'), isFalse);
      auth.requests.clear();
      await (runtime.database.update(runtime.database.noteEntries)..where(
            (row) => row.id.equals('01990000-7000-8002-8000-000000000101'),
          ))
          .write(const NoteEntriesCompanion(body: Value('只改正文')));
      await (runtime.database.update(runtime.database.noteEntries)..where(
            (row) => row.id.equals('01990000-7000-8002-8000-000000000101'),
          ))
          .write(const NoteEntriesCompanion(dayKey: Value('2026-10-10')));
      await OmniPowerSyncConnector(auth).uploadData(runtime.powerSync);
      expect(auth.requests, hasLength(2));
      for (final Map<String, dynamic> request in auth.requests) {
        // 两次独立PATCH不得意外传入其他设备标签整理的旧基线。
        final Map<String, dynamic> operation =
            (request['operations'] as List).single as Map<String, dynamic>;
        expect(operation['op'], 'PATCH');
        expect((operation['data'] as Map).containsKey('tags'), isFalse);
        expect((operation['data'] as Map).containsKey('tags_base'), isFalse);
      }
    } finally {
      await runtime.close();
      await directory.delete(recursive: true);
    }
  });

  test('连续离线标签增删持久保留各自OLD.tags，响应丢失重启重试身份与基线不变', () async {
    // 重启后保留同一真实SQLite与SDK队列。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_note_tags_retry_',
    );
    final String databasePath = '${directory.path}/db.sqlite';
    // 服务端响应可由测试独立丢弃。
    final _RecordingAuth auth = _RecordingAuth();
    OmniSyncRuntime? runtime = await OmniSyncRuntime.openAtPath(
      auth,
      databasePath,
    );
    final DateTime now = DateTime.utc(2026, 10, 11);
    try {
      await runtime.database
          .into(runtime.database.noteEntries)
          .insert(
            NoteEntriesCompanion.insert(
              id: '01990000-7000-8002-8000-000000000101',
              dayKey: '2026-10-11',
              tags: const Value('["initial"]'),
              revision: '01990000-7000-8002-8000-000000000102',
              createdAt: now,
              updatedAt: now,
            ),
          );
      await OmniPowerSyncConnector(auth).uploadData(runtime.powerSync);
      auth.requests.clear();
      await (runtime.database.update(runtime.database.noteEntries)..where(
            (row) => row.id.equals('01990000-7000-8002-8000-000000000101'),
          ))
          .write(
            const NoteEntriesCompanion(tags: Value('["initial","added"]')),
          );
      await (runtime.database.update(runtime.database.noteEntries)..where(
            (row) => row.id.equals('01990000-7000-8002-8000-000000000101'),
          ))
          .write(const NoteEntriesCompanion(tags: Value('["added"]')));
      // 真正的SDK前态捕获应区别于最新业务表中的最终标签。
      final CrudTransaction? queued = await runtime.powerSync
          .getNextCrudTransaction();
      expect(queued!.crud.single.previousValues?['tags'], '["initial"]');
      expect(queued.crud.single.opData!['tags'], '["initial","added"]');
      auth.loseResponse = true;
      await expectLater(
        OmniPowerSyncConnector(auth).uploadData(runtime.powerSync),
        throwsA(isA<ApiFailure>()),
      );
      final Map<String, dynamic> first =
          (auth.requests.single['operations'] as List).single
              as Map<String, dynamic>;
      expect(first['data']['tags_base'], '["initial"]');
      expect(first['data']['tags'], '["initial","added"]');
      expect((await runtime.powerSync.getUploadQueueStats()).count, 2);
      await runtime.close();
      runtime = null;
      runtime = await OmniSyncRuntime.openAtPath(auth, databasePath);
      // 重启后SDK仍持有旧前态，不能改读当前表中的[added]。
      final CrudTransaction? restarted = await runtime.powerSync
          .getNextCrudTransaction();
      expect(restarted!.crud.single.previousValues?['tags'], '["initial"]');
      auth.loseResponse = false;
      await OmniPowerSyncConnector(auth).uploadData(runtime.powerSync);
      expect(auth.requests, hasLength(3));
      expect(auth.requests[1], auth.requests[0]);
      // 后续移除操作的独立前态必须是上一笔加入完成后的标签集合。
      final Map<String, dynamic> second =
          (auth.requests.last['operations'] as List).single
              as Map<String, dynamic>;
      expect(second['data']['tags_base'], '["initial","added"]');
      expect(second['data']['tags'], '["added"]');
      expect(
        auth.requests.last['transactionId'],
        isNot(auth.requests.first['transactionId']),
      );
      expect((await runtime.powerSync.getUploadQueueStats()).count, 0);
    } finally {
      await runtime?.close();
      await directory.delete(recursive: true);
    }
  });

  test('结构版本不兼容时停止同步并保留可见错误及未确认队列', () async {
    // 使用真实 PowerSync 引擎证明停止重试和队列保留。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_schema_gate_',
    );
    final _RecordingAuth auth = _RecordingAuth()..schemaCompatible = false;
    final OmniSyncRuntime runtime = await OmniSyncRuntime.openAtPath(
      auth,
      '${directory.path}/db.sqlite',
    );
    try {
      await _insertTodo(
        runtime.database,
        '01990000-7000-8002-8000-000000000001',
      );
      // 连接前先注册错误监听，避免错过立即返回的错误。
      final Future<SyncSchemaMismatch> failed = runtime.schemaErrors.first;
      try {
        await runtime
            .connect('01990000-7000-8002-8000-000000000099')
            .timeout(
              const Duration(seconds: 5),
              onTimeout: () => throw StateError('版本拒绝后 connect 未返回'),
            );
      } on SyncSchemaMismatch {
        // SDK 可能在 connect 返回前报告不兼容，也可能稍后通过流通知。
      }
      await failed.timeout(const Duration(seconds: 5));
      // 等异步停止离开 SDK 回调栈并完成连接释放。
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(runtime.schemaError, isA<SyncSchemaMismatch>());
      expect(runtime.powerSync.connected, isFalse);
      expect(await runtime.powerSync.getNextCrudTransaction(), isNotNull);
      expect(auth.requests, isEmpty);
      SharedPreferences.setMockInitialValues(<String, Object>{
        'sync.enabled': true,
      });
      // 现有同步状态界面通过控制器错误继续看到升级原因。
      final SharedPreferences preferences =
          await SharedPreferences.getInstance();
      final ProviderContainer container = ProviderContainer(
        overrides: [
          syncRuntimeProvider.overrideWithValue(runtime),
          authControllerProvider.overrideWith(_OfflineAuthController.new),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
      );
      try {
        await expectLater(
          container
              .read(syncControllerProvider.future)
              .timeout(
                const Duration(seconds: 5),
                onTimeout: () => throw StateError('版本拒绝后状态控制器未返回'),
              ),
          throwsA(isA<SyncSchemaMismatch>()),
        );
        expect(
          container.read(syncControllerProvider).error,
          isA<SyncSchemaMismatch>(),
        );
      } finally {
        container.dispose();
      }
      await expectLater(
        runtime.connect('01990000-7000-8002-8000-000000000099'),
        throwsA(isA<SyncSchemaMismatch>()),
      );
    } finally {
      await runtime.close().timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw StateError('版本拒绝后 close 未返回'),
      );
      await directory.delete(recursive: true);
    }
  });

  test('上传期间会话代次变化时保留队列且旧连接器不可复用', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    // 本测试独占数据库目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_scope_',
    );
    // 上传开始和返回由测试控制，模拟用户切换服务器。
    final _RecordingAuth auth = _RecordingAuth()
      ..uploadStarted = Completer<void>()
      ..uploadRelease = Completer<void>();
    // 真实 SQLite 上传队列。
    final OmniSyncRuntime runtime = await OmniSyncRuntime.openAtPath(
      auth,
      '${directory.path}${Platform.pathSeparator}db.sqlite',
    );
    try {
      await _insertTodo(
        runtime.database,
        '01990000-7000-8002-8000-000000000001',
      );
      // 连接器捕获切换前的会话代次。
      final OmniPowerSyncConnector connector = OmniPowerSyncConnector(auth);
      // 先订阅错误，防止异步未处理异常。
      final Future<void> assertion = expectLater(
        connector.uploadData(runtime.powerSync),
        throwsA(isA<ApiFailure>()),
      );
      await auth.uploadStarted!.future;
      await auth.clearSession();
      auth.uploadRelease!.complete();
      await assertion;
      expect((await runtime.powerSync.getUploadQueueStats()).count, 1);
      await expectLater(
        connector.uploadData(runtime.powerSync),
        throwsA(isA<ApiFailure>()),
      );
      expect(auth.requests, hasLength(1));
    } finally {
      await runtime.close();
      await directory.delete(recursive: true);
    }
  });

  test('未绑定旧库用当前快照替换历史队列，避免悬空引用先于完整导入上传', () async {
    // 本测试独占数据库目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_legacy_queue_',
    );
    // 旧库路径。
    final String databasePath =
        '${directory.path}${Platform.pathSeparator}db.sqlite';
    // 已有业务数据但没有初始上传标记的旧 Drift 数据库。
    final AppDatabase fixture = AppDatabase.forTesting(
      NativeDatabase(File(databasePath)),
    );
    await _insertTodo(fixture, '01990000-7000-8002-8000-000000000001');
    await fixture.close();
    // 旧版 PowerSync 留下的历史操作，引用名言已不在当前快照中。
    final PowerSyncDatabase legacy = PowerSyncDatabase(
      schema: omniSyncSchema,
      path: databasePath,
    );
    await legacy.initialize();
    await legacy.execute(
      'INSERT INTO powersync_crud(op, id, type, data) VALUES(?, ?, ?, ?)',
      <Object?>[
        'PUT',
        '01990000-7000-8002-8000-000000000002',
        'daily_quote_selections',
        jsonEncode(<String, Object?>{
          'is_manual': 1,
          'quote_id': 'missing-legacy-quote',
        }),
      ],
    );
    await legacy.close();
    // 新运行时必须原子替换旧队列，而非将快照排在旧队列后面。
    final OmniSyncRuntime runtime = await OmniSyncRuntime.openAtPath(
      _RecordingAuth(),
      databasePath,
    );
    try {
      // 首个事务应只包含当前有效快照。
      final CrudTransaction? first = await runtime.powerSync
          .getNextCrudTransaction();
      expect(first!.crud, hasLength(1));
      expect(first.crud.single.table, 'todo_items');
      expect(first.crud.single.opData!['title'], '同步协议测试');
      await first.complete();
      expect(await runtime.powerSync.getNextCrudTransaction(), isNull);
      expect(
        await runtime.database.select(runtime.database.todoItems).get(),
        hasLength(1),
      );
    } finally {
      await runtime.close();
      await directory.delete(recursive: true);
    }
  });

  test('旧队列移除退休字段，混合事务重试保持身份和负载且不吞未知字段', () async {
    // 本测试独占数据库目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_retired_fields_',
    );
    // 重启前后复用数据库路径。
    final String databasePath =
        '${directory.path}${Platform.pathSeparator}db.sqlite';
    // 捕获生产连接器请求。
    final _RecordingAuth auth = _RecordingAuth();
    // 用于验证重启重试的运行时。
    OmniSyncRuntime? runtime = await OmniSyncRuntime.openAtPath(
      auth,
      databasePath,
    );
    try {
      // 各表真实旧版队列可能保留的退休字段。
      final Map<String, Map<String, Object?>> legacyData =
          <String, Map<String, Object?>>{
            'events': <String, Object?>{
              'notes': '保留事件备注',
              'description': '删除旧事件说明',
            },
            'daily_quote_selections': <String, Object?>{
              'quote_id': null,
              'is_manual': 1,
            },
            'taxonomy_entries': <String, Object?>{
              'name': '分类',
              'normalized_name': '分类',
              'icon_code_point': 1,
            },
            'memberships': <String, Object?>{
              'name': '会员',
              'payment_method': 'card',
              'is_favorite': 1,
              'image_attachment_id': 'local',
            },
            'membership_payments': <String, Object?>{
              'amount_cents': 100,
              'billing_cycle': 'monthly',
            },
            'inventory_items': <String, Object?>{
              'name': '物品',
              'image_attachment_id': 'local',
            },
            'quotes': <String, Object?>{'unknown_future_column': '保留给服务器校验'},
          };
      await runtime.powerSync.writeTransaction((transaction) async {
        for (final MapEntry<String, Map<String, Object?>> entry
            in legacyData.entries) {
          await transaction.execute(
            'INSERT INTO powersync_crud(op, id, type, data) VALUES(?, ?, ?, ?)',
            <Object?>[
              entry.key == 'daily_quote_selections' || entry.key == 'events'
                  ? 'PUT'
                  : 'PATCH',
              '01990000-7000-8002-8000-000000000001',
              entry.key,
              jsonEncode(entry.value),
            ],
          );
        }
        await transaction.execute(
          'INSERT INTO powersync_crud(op, id, type, data) VALUES(?, ?, ?, ?)',
          <Object?>[
            'PATCH',
            '01990000-7000-8002-8000-000000000001',
            'daily_quote_selections',
            '{"is_manual":1}',
          ],
        );
      });
      auth.loseResponse = true;
      await expectLater(
        OmniPowerSyncConnector(auth).uploadData(runtime.powerSync),
        throwsA(isA<ApiFailure>()),
      );
      // 所有有效操作保持原顺序，纯退休列 PATCH 被忽略。
      final List<dynamic> operations =
          auth.requests.single['operations'] as List<dynamic>;
      expect(operations, hasLength(7));
      expect(operations.first['op'], 'PUT');
      expect(
        operations.map((dynamic operation) => operation['data']),
        <Map<String, Object?>>[
          <String, Object?>{'notes': '保留事件备注'},
          <String, Object?>{'quote_id': null},
          <String, Object?>{'name': '分类'},
          <String, Object?>{'name': '会员'},
          <String, Object?>{'amount_cents': 100},
          <String, Object?>{'name': '物品'},
          <String, Object?>{'unknown_future_column': '保留给服务器校验'},
        ],
      );
      expect((await runtime.powerSync.getUploadQueueStats()).count, 8);
      await runtime.close();
      runtime = await OmniSyncRuntime.openAtPath(auth, databasePath);
      auth.loseResponse = false;
      await OmniPowerSyncConnector(auth).uploadData(runtime.powerSync);
      expect(auth.requests.last, auth.requests.first);
      expect((await runtime.powerSync.getUploadQueueStats()).count, 0);
    } finally {
      await runtime?.close();
      await directory.delete(recursive: true);
    }
  });

  test('仅退休字段的旧事务直接确认，不提交空操作列表', () async {
    // 本测试独占数据库目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_retired_only_',
    );
    // 请求捕获替身。
    final _RecordingAuth auth = _RecordingAuth();
    // 真实生产运行时。
    final OmniSyncRuntime runtime = await OmniSyncRuntime.openAtPath(
      auth,
      '${directory.path}${Platform.pathSeparator}db.sqlite',
    );
    try {
      await runtime.powerSync.execute(
        'INSERT INTO powersync_crud(op, id, type, data) VALUES(?, ?, ?, ?)',
        <Object?>[
          'PATCH',
          '01990000-7000-8002-8000-000000000001',
          'events',
          '{"description":"删除旧说明"}',
        ],
      );
      await OmniPowerSyncConnector(auth).uploadData(runtime.powerSync);
      expect(auth.requests, isEmpty);
      expect((await runtime.powerSync.getUploadQueueStats()).count, 0);
    } finally {
      await runtime.close();
      await directory.delete(recursive: true);
    }
  });

  test('201 条 Drift 事务完整上传，响应丢失与重启后仍使用同一幂等键', () async {
    // 本测试独占的临时目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_protocol_',
    );
    // 重启前后复用的数据库路径。
    final String databasePath =
        '${directory.path}${Platform.pathSeparator}db.sqlite';
    // 请求捕获替身。
    final _RecordingAuth auth = _RecordingAuth();
    // 当前打开的运行时。
    OmniSyncRuntime? runtime;
    try {
      runtime = await OmniSyncRuntime.openAtPath(auth, databasePath);
      // 使用生产 Drift 事务验证桥接层确实保留事务号。
      final AppDatabase database = runtime.database;
      await database.transaction(() async {
        // 同一事务中的写入序号。
        for (int index = 0; index < 201; index += 1) {
          await _insertTodo(
            database,
            '01990000-7000-8002-8000-${(index + 1).toString().padLeft(12, '0')}',
          );
        }
      });
      // 首次模拟响应丢失。
      final OmniPowerSyncConnector connector = OmniPowerSyncConnector(auth);
      auth.loseResponse = true;
      await expectLater(
        connector.uploadData(runtime.powerSync),
        throwsA(isA<ApiFailure>()),
      );
      expect(auth.requests, hasLength(1));
      expect(auth.requests.single['operations'], hasLength(201));
      expect((await runtime.powerSync.getUploadQueueStats()).count, 201);
      await runtime.close();
      runtime = null;
      runtime = await OmniSyncRuntime.openAtPath(auth, databasePath);
      auth.loseResponse = false;
      await OmniPowerSyncConnector(auth).uploadData(runtime.powerSync);
      expect(auth.requests, hasLength(2));
      expect(auth.requests[1], auth.requests[0]);
      expect((await runtime.powerSync.getUploadQueueStats()).count, 0);
      // 清空数据后不能复用先前的设备上传身份。
      final String oldClientId = auth.requests.first['clientId'] as String;
      await runtime.disconnectAndClear();
      await _insertTodo(
        runtime.database,
        '01990000-7000-8002-8000-000000000999',
      );
      await OmniPowerSyncConnector(auth).uploadData(runtime.powerSync);
      expect(auth.requests.last['clientId'], isNot(oldClientId));
    } finally {
      await runtime?.close();
      await directory.delete(recursive: true);
    }
  });

  test('旧 Drift 行原子生成完整 PUT，确认后重启不重复导入', () async {
    // 本测试独占的临时目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_import_',
    );
    // 初始纯 Drift 数据库路径。
    final String databasePath =
        '${directory.path}${Platform.pathSeparator}db.sqlite';
    // 请求捕获替身。
    final _RecordingAuth auth = _RecordingAuth();
    // 初始旧版数据库。
    final AppDatabase fixture = AppDatabase.forTesting(
      NativeDatabase(File(databasePath)),
    );
    // 当前打开的运行时。
    OmniSyncRuntime? runtime;
    try {
      await _insertTodo(fixture, '01990000-7000-8002-8000-000000000001');
    } finally {
      await fixture.close();
    }
    try {
      runtime = await OmniSyncRuntime.openAtPath(auth, databasePath);
      // 初始导入产生的一整个事务。
      final CrudTransaction? imported = await runtime.powerSync
          .getNextCrudTransaction();
      expect(imported, isNotNull);
      expect(imported!.crud, hasLength(1));
      expect(imported.crud.single.op, UpdateType.put);
      expect(imported.crud.single.opData!['title'], '同步协议测试');
      expect(imported.crud.single.opData!.containsKey('sync_state'), isFalse);
      expect(imported.crud.single.opData!.containsKey('created_at'), isTrue);
      await imported.complete();
      await runtime.close();
      runtime = null;
      runtime = await OmniSyncRuntime.openAtPath(auth, databasePath);
      expect(await runtime.powerSync.getNextCrudTransaction(), isNull);
      await (runtime.database.update(runtime.database.todoItems)..where(
            (TodoItems table) =>
                table.id.equals('01990000-7000-8002-8000-000000000001'),
          ))
          .write(const TodoItemsCompanion(title: Value<String>('后续编辑')));
      // 完成初始导入后，正常编辑仍然保留 PATCH 语义。
      final CrudTransaction? edited = await runtime.powerSync
          .getNextCrudTransaction();
      expect(edited!.crud.single.op, UpdateType.patch);
    } finally {
      await runtime?.close();
      await directory.delete(recursive: true);
    }
  });

  test('已有服务端归属的旧库不把下载的数据再次作为 PUT 上传', () async {
    // 本测试独占的临时目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_existing_owner_',
    );
    // 已同步设备数据库路径。
    final String databasePath =
        '${directory.path}${Platform.pathSeparator}db.sqlite';
    // 未安装新运行时导入逻辑的数据库夹具。
    final AppDatabase fixture = AppDatabase.forTesting(
      NativeDatabase(File(databasePath)),
    );
    await _insertTodo(fixture, '01990000-7000-8002-8000-000000000001');
    await fixture.close();
    // 模拟旧运行时曾经记录的同步身份。
    final PowerSyncDatabase oldSync = PowerSyncDatabase(
      schema: omniSyncSchema,
      path: databasePath,
    );
    await oldSync.initialize();
    await oldSync.execute(
      'INSERT INTO device_sync_metadata(id, value) VALUES(?, ?)',
      <Object?>['owner', '01990000-7000-8002-8000-000000000099'],
    );
    await oldSync.close();
    // 当前打开的运行时。
    OmniSyncRuntime? runtime;
    try {
      runtime = await OmniSyncRuntime.openAtPath(
        _RecordingAuth(),
        databasePath,
      );
      expect(await runtime.powerSync.getNextCrudTransaction(), isNull);
      expect(
        await runtime.database.select(runtime.database.todoItems).get(),
        hasLength(1),
      );
    } finally {
      await runtime?.close();
      await directory.delete(recursive: true);
    }
  });

  test('初始导入中途失败时队列和标记同时回滚，重开可完整重试', () async {
    // 本测试独占的临时目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_import_retry_',
    );
    // 旧数据库文件路径。
    final String databasePath =
        '${directory.path}${Platform.pathSeparator}db.sqlite';
    // 尚未接入 PowerSync 的业务库。
    final AppDatabase fixture = AppDatabase.forTesting(
      NativeDatabase(File(databasePath)),
    );
    // 固定业务时间。
    final DateTime now = DateTime.utc(2026, 9, 24);
    // 用来注入故障和检查回滚的独立 PowerSync 连接。
    PowerSyncDatabase? inspector;
    // 最终成功初始化的生产运行时。
    OmniSyncRuntime? runtime;
    try {
      try {
        await _insertTodo(fixture, '01990000-7000-8002-8000-000000000001');
        await fixture
            .into(fixture.quotes)
            .insert(
              QuotesCompanion.insert(
                id: '01990000-7000-8002-8000-000000000002',
                content: '初始导入回滚测试',
                createdAt: now,
                updatedAt: now,
              ),
            );
      } finally {
        await fixture.close();
      }
      inspector = PowerSyncDatabase(schema: omniSyncSchema, path: databasePath);
      await inspector.initialize();
      // 导入失败时这条旧操作也必须保留，不能只回滚新快照。
      await inspector.execute(
        'INSERT INTO powersync_crud(op, id, type, data) VALUES(?, ?, ?, ?)',
        <Object?>[
          'PATCH',
          '01990000-7000-8002-8000-000000000001',
          'todo_items',
          '{"title":"旧队列待上传"}',
        ],
      );
      // 仅在测试内阻止第二张表入队，确保首张表已产生的 PUT 也必须回滚。
      await inspector.execute('''
CREATE TRIGGER audit_fail_import BEFORE INSERT ON ps_crud
WHEN json_extract(NEW.data, '\$.type') = 'quotes'
BEGIN SELECT RAISE(ABORT, 'audit injected import failure'); END
''');
      await inspector.close();
      inspector = null;
      await expectLater(
        OmniSyncRuntime.openAtPath(_RecordingAuth(), databasePath),
        throwsA(isA<Exception>()),
      );
      inspector = PowerSyncDatabase(schema: omniSyncSchema, path: databasePath);
      await inspector.initialize();
      // 原始历史队列和业务数据均未被失败的首次导入破坏。
      final CrudTransaction? preserved = await inspector
          .getNextCrudTransaction();
      expect(preserved!.crud, hasLength(1));
      expect(preserved.crud.single.opData!['title'], '旧队列待上传');
      expect(
        await inspector.getOptional(
          'SELECT value FROM device_sync_metadata WHERE id = ?',
          <Object?>['initial_upload'],
        ),
        isNull,
      );
      await inspector.execute('DROP TRIGGER audit_fail_import');
      await inspector.close();
      inspector = null;
      runtime = await OmniSyncRuntime.openAtPath(
        _RecordingAuth(),
        databasePath,
      );
      // 重试后两个业务表都应出现在同一个初始导入事务中。
      final CrudTransaction? imported = await runtime.powerSync
          .getNextCrudTransaction();
      expect(imported!.crud.map((CrudEntry entry) => entry.table), <String>[
        'todo_items',
        'quotes',
      ]);
      expect(
        imported.crud.every((CrudEntry entry) => entry.op == UpdateType.put),
        isTrue,
      );
    } finally {
      await inspector?.close();
      await runtime?.close();
      await directory.delete(recursive: true);
    }
  });

  test('离线缓存会话仍启动 PowerSync 凭证重试', () async {
    // 本测试独占的临时目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_offline_',
    );
    // 离线请求替身。
    final _RecordingAuth auth = _RecordingAuth();
    // 使用真实 PowerSync 引擎的运行时。
    final OmniSyncRuntime runtime = await OmniSyncRuntime.openAtPath(
      auth,
      '${directory.path}${Platform.pathSeparator}db.sqlite',
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      'sync.enabled': true,
    });
    // 同步偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 覆盖缓存认证状态的 Riverpod 容器。
    final ProviderContainer container = ProviderContainer(
      overrides: [
        syncRuntimeProvider.overrideWithValue(runtime),
        authControllerProvider.overrideWith(_OfflineAuthController.new),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
    );
    try {
      await container.read(syncControllerProvider.future);
      await auth.credentialRequested.future.timeout(const Duration(seconds: 5));
      expect(auth.credentialRequested.isCompleted, isTrue);
    } finally {
      container.dispose();
      await runtime.close();
      await directory.delete(recursive: true);
    }
  });
}
