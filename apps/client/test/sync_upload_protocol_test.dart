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
import 'package:powersync/powersync.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 记录上传请求且不访问网络的认证替身。
class _RecordingAuth extends AuthRepository {
  /// 已发送请求的独立副本。
  final List<Map<String, dynamic>> requests = <Map<String, dynamic>>[];

  /// 是否模拟服务端处理后响应丢失。
  bool loseResponse = false;

  /// 离线状态下是否已开始请求同步凭证。
  final Completer<void> credentialRequested = Completer<void>();

  /// 创建不访问安全存储的认证替身。
  _RecordingAuth() : super(const FlutterSecureStorage());

  /// 捕获生产连接器提交的真实事务请求体。
  @override
  Future<Response<T>> authorizedRequest<T>(
    String method,
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
  }) async {
    requests.add(jsonDecode(jsonEncode(data)) as Map<String, dynamic>);
    if (loseResponse) {
      throw const ApiFailure('模拟响应丢失');
    }
    return Response<T>(requestOptions: RequestOptions(path: path));
  }

  /// 模拟暂时离线，让 PowerSync 接管后续重试。
  @override
  Future<PowerSyncCredential> fetchPowerSyncCredential() async {
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
              entry.key == 'daily_quote_selections' ? 'PUT' : 'PATCH',
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
      expect(operations, hasLength(6));
      expect(operations.first['op'], 'PUT');
      expect(
        operations.map((dynamic operation) => operation['data']),
        <Map<String, Object?>>[
          <String, Object?>{'quote_id': null},
          <String, Object?>{'name': '分类'},
          <String, Object?>{'name': '会员'},
          <String, Object?>{'amount_cents': 100},
          <String, Object?>{'name': '物品'},
          <String, Object?>{'unknown_future_column': '保留给服务器校验'},
        ],
      );
      expect((await runtime.powerSync.getUploadQueueStats()).count, 7);
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
          'daily_quote_selections',
          '{"is_manual":1}',
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
