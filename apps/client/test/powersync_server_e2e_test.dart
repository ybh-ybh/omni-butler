import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/sync/omni_sync_runtime.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:path/path.dart' as path;
import 'package:powersync/powersync.dart';
import 'package:uuid/uuid.dart';

/// 是否显式运行需要隔离 Docker 服务的端到端测试。
const bool _runEndToEnd = bool.fromEnvironment('OMNI_SYNC_E2E');

/// 隔离服务器地址，不包含内部 API 路径，允许避开真实部署端口。
const String _serverAddress = String.fromEnvironment(
  'OMNI_SYNC_SERVER_URL',
  defaultValue: 'http://127.0.0.1:3000',
);

/// 隔离服务的可配置 API 路径，用于验证非默认部署。
const String _apiPrefix = String.fromEnvironment(
  'OMNI_SYNC_API_PREFIX',
  defaultValue: 'api/v1',
);

/// 仅供隔离测试环境使用的同步密钥。
const String _syncKey = String.fromEnvironment(
  'OMNI_SYNC_SECRET',
  defaultValue: 'validation-sync-secret-2026',
);

/// 使用真实服务端会话的认证适配器；上传逻辑完全复用生产连接器。
class _EndToEndAuth extends AuthRepository {
  /// 隔离服务 HTTP 客户端。
  final Dio api;

  /// 服务端真实签发的设备访问令牌。
  final String accessToken;

  /// 服务端返回的内部数据归属。
  final String ownerId;

  /// 上传请求的独立副本，用来检查完整事务及重试身份。
  final List<Map<String, dynamic>> uploads = <Map<String, dynamic>>[];

  /// 模拟服务端已提交，但客户端没有收到成功响应。
  bool loseNextUploadResponse = false;

  /// 创建不依赖操作系统安全存储的测试认证适配器。
  _EndToEndAuth({
    required this.api,
    required this.accessToken,
    required this.ownerId,
  }) : super(const FlutterSecureStorage());

  /// 向真实 API 获取本设备的短期 PowerSync 凭证。
  @override
  Future<PowerSyncCredential> fetchPowerSyncCredential() async {
    // 服务端签名的短期凭证响应。
    final Response<Map<String, dynamic>> response = await authorizedRequest(
      'POST',
      '/auth/powersync-token',
    );
    // 凭证响应正文。
    final Map<String, dynamic> data = response.data!;
    return PowerSyncCredential(
      endpoint: data['endpoint'] as String,
      token: data['token'] as String,
      expiresIn: data['expiresIn'] as int,
      userId: data['userId'] as String,
    );
  }

  /// 转发生产请求，必要时在服务器提交后模拟响应丢失。
  @override
  Future<Response<T>> authorizedRequest<T>(
    String method,
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
  }) async {
    if (path == '/sync/operations') {
      uploads.add(jsonDecode(jsonEncode(data)) as Map<String, dynamic>);
    }
    // 真实服务端 HTTP 响应，成功后才可能模拟断线。
    final Response<T> response = await api.request<T>(
      path,
      data: data,
      queryParameters: queryParameters,
      options: Options(
        method: method,
        headers: <String, String>{'Authorization': 'Bearer $accessToken'},
      ),
    );
    if (path == '/sync/operations' && loseNextUploadResponse) {
      loseNextUploadResponse = false;
      throw const ApiFailure('E2E 模拟上传成功响应丢失');
    }
    return response;
  }
}

/// 为每台测试设备通过实际认证接口建立独立会话。
Future<_EndToEndAuth> _connectTestDevice() async {
  // 测试 API 客户端，不读取真实部署的配置。
  final Dio api = Dio(
    BaseOptions(
      baseUrl: AuthRepository(const FlutterSecureStorage())
          .normalizeBaseUrl(_serverAddress, apiPrefix: _apiPrefix),
    ),
  );
  // 服务端签发的设备令牌组。
  final Response<Map<String, dynamic>> tokens = await api.post(
    '/auth/connect',
    data: <String, String>{'syncKey': _syncKey},
  );
  // 该设备的真实访问令牌。
  final String accessToken = tokens.data!['accessToken'] as String;
  // 服务端当前数据所有者。
  final Response<Map<String, dynamic>> identity = await api.get(
    '/auth/session',
    options: Options(
      headers: <String, String>{'Authorization': 'Bearer $accessToken'},
    ),
  );
  return _EndToEndAuth(
    api: api,
    accessToken: accessToken,
    ownerId: identity.data!['sub'] as String,
  );
}

/// 等待本地队列清空，失败时报告引擎错误。
Future<void> _waitForUpload(PowerSyncDatabase database) async {
  // 上传及一次 SDK 重试的等待截止时间。
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 60));
  while (DateTime.now().isBefore(deadline)) {
    // 当前队列统计。
    final UploadQueueStats stats = await database.getUploadQueueStats();
    if (stats.count == 0) return;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  throw TimeoutException('上传队列未清空：${database.currentStatus.anyError}');
}

/// 等待真实下行满足 SQL 条件，避免只断言连接状态。
Future<List<Map<String, Object?>>> _waitForRows(
  PowerSyncDatabase database,
  String sql,
  List<Object?> parameters,
  bool Function(List<Map<String, Object?>> rows) matches,
) async {
  // 下行复制与应用的等待截止时间。
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 40));
  while (DateTime.now().isBefore(deadline)) {
    // 当前本地查询结果。
    final List<Map<String, Object?>> rows = await database.getAll(
      sql,
      parameters,
    );
    if (matches(rows)) return rows;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  throw TimeoutException(
    '下行数据未收敛：${database.currentStatus.anyError}；'
    '查询=$sql；当前行=${await database.getAll(sql, parameters)}',
  );
}

/// 使用生产运行时验证完整事务、响应重试及关键字段的双设备收敛。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  test(
    '真实双设备同步完整事务、购买平台、ARGB 颜色和稳定业务身份',
    () async {
      // 本测试独占的临时目录。
      final Directory directory = await Directory.systemTemp.createTemp(
        'omni-powersync-e2e-',
      );
      // 设备 A 的真实认证会话。
      _EndToEndAuth? authA;
      // 设备 B 的真实认证会话。
      _EndToEndAuth? authB;
      // 当前打开的设备 A 运行时。
      OmniSyncRuntime? deviceA;
      // 当前打开的设备 B 运行时。
      OmniSyncRuntime? deviceB;
      try {
        authA = await _connectTestDevice();
        authB = await _connectTestDevice();
        deviceA = await OmniSyncRuntime.openAtPath(
          authA,
          path.join(directory.path, 'device-a.sqlite'),
        );
        deviceB = await OmniSyncRuntime.openAtPath(
          authB,
          path.join(directory.path, 'device-b.sqlite'),
        );
        // 设备 A 的生产 Drift 数据库。
        final AppDatabase driftA = deviceA.database;
        // 本次运行独有的数据标识。
        final String runId = const Uuid().v7();
        // 固定自然日和业务时间。
        final DateTime now = DateTime.utc(2026, 9, 25);
        // 第一条待办标识，用于下行检查。
        final String todoId = const Uuid().v7();
        await driftA.transaction(() async {
          // 同一事务的序号，必须超过旧上限 200 条。
          for (int index = 0; index < 201; index += 1) {
            await driftA
                .into(driftA.todoItems)
                .insert(
                  TodoItemsCompanion.insert(
                    id: index == 0 ? todoId : const Uuid().v7(),
                    title: 'E2E $runId $index',
                    scheduledDate: now,
                    createdAt: now,
                    updatedAt: now,
                  ),
                );
          }
        });
        // 购买平台测试物品标识。
        final String inventoryId = const Uuid().v7();
        await driftA
            .into(driftA.inventoryItems)
            .insert(
              InventoryItemsCompanion.insert(
                id: inventoryId,
                name: 'E2E 物品 $runId',
                purchasePlatform: const Value<String?>('官方商城'),
                createdAt: now,
                updatedAt: now,
              ),
            );
        // 两设备离线创建同名分类，应获得同一业务身份。
        final TaxonomyDraft category = TaxonomyDraft(
          module: TaxonomyModule.inventory,
          kind: TaxonomyKind.category,
          name: 'E2E 分类 $runId',
          colorValue: 0xFF336699,
        );
        await TaxonomyRepository(deviceA.database).save(category);
        await TaxonomyRepository(deviceB.database).save(category);
        await deviceA.database.quoteForDay(now);
        await deviceB.database.quoteForDay(now);
        // 离线生成的 A 端每日选择。
        final DailyQuoteSelectionRecord selectionA = await deviceA.database
            .select(deviceA.database.dailyQuoteSelections)
            .getSingle();
        // 离线生成的 B 端每日选择。
        final DailyQuoteSelectionRecord selectionB = await deviceB.database
            .select(deviceB.database.dailyQuoteSelections)
            .getSingle();
        expect(selectionA.id, selectionB.id);
        expect(selectionA.quoteId, selectionB.quoteId);
        authA.loseNextUploadResponse = true;
        await deviceA.connect(authA.ownerId);
        await deviceB.connect(authB.ownerId);
        await Future.wait(<Future<void>>[
          _waitForUpload(deviceA.powerSync),
          _waitForUpload(deviceB.powerSync),
        ]);
        await Future.wait(<Future<void>>[
          deviceA.powerSync.waitForFirstSync().timeout(
            const Duration(seconds: 40),
          ),
          deviceB.powerSync.waitForFirstSync().timeout(
            const Duration(seconds: 40),
          ),
        ]);
        // 响应丢失后重试的完整 201 条事务请求。
        final List<Map<String, dynamic>> largeUploads = authA.uploads
            .where(
              (Map<String, dynamic> body) =>
                  (body['operations'] as List).length == 201,
            )
            .toList();
        expect(largeUploads, hasLength(2));
        expect(largeUploads[1], largeUploads[0]);
        await _waitForRows(
          deviceB.powerSync,
          'SELECT id FROM todo_items WHERE id = ?',
          <Object?>[todoId],
          (rows) => rows.length == 1,
        );
        await _waitForRows(
          deviceB.powerSync,
          'SELECT purchase_platform FROM inventory_items WHERE id = ?',
          <Object?>[inventoryId],
          (rows) =>
              rows.length == 1 && rows.single['purchase_platform'] == '官方商城',
        );
        await _waitForRows(
          deviceA.powerSync,
          'SELECT purchase_platform FROM inventory_items WHERE id = ?',
          <Object?>[inventoryId],
          (rows) =>
              rows.length == 1 && rows.single['purchase_platform'] == '官方商城',
        );
        // 修改颜色以确保 B 的最终颜色来自下行而非本地原值。
        final TaxonomyEntry syncedCategory =
            await (deviceA.database.select(deviceA.database.taxonomyEntries)
                  ..where(
                    (TaxonomyEntries table) => table.name.equals(category.name),
                  ))
                .getSingle();
        await TaxonomyRepository(deviceA.database).save(
          TaxonomyDraft(
            id: syncedCategory.id,
            module: category.module,
            kind: category.kind,
            name: category.name,
            colorValue: 0xFFFEDCBA,
          ),
        );
        await _waitForUpload(deviceA.powerSync);
        await _waitForRows(
          deviceB.powerSync,
          'SELECT color_value FROM taxonomy_entries WHERE name = ?',
          <Object?>[category.name],
          (rows) =>
              rows.length == 1 && rows.single['color_value'] == 0xFFFEDCBA,
        );
        // 每日选择双向合并后仍只有一个业务键。
        final List<Map<String, Object?>> dailyRows = await _waitForRows(
          deviceB.powerSync,
          'SELECT id, quote_id FROM daily_quote_selections WHERE day_key = ?',
          <Object?>['2026-09-25'],
          (rows) => rows.length == 1,
        );
        expect(dailyRows.single['id'], selectionA.id);
        expect(dailyRows.single['quote_id'], selectionA.quoteId);
      } finally {
        await deviceA?.disconnect();
        await deviceB?.disconnect();
        await deviceA?.close();
        await deviceB?.close();
        authA?.api.close(force: true);
        authB?.api.close(force: true);
        await directory.delete(recursive: true);
      }
    },
    skip: _runEndToEnd ? false : '需要显式启动隔离 Docker 同步服务',
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    '真实双设备旧版随机每日身份与离线后续修改收敛到同一行',
    () async {
      // 两个独立 SQLite 文件只属于本次隔离回归。
      final Directory directory = await Directory.systemTemp.createTemp(
        'omni-powersync-legacy-daily-',
      );
      // 两端实际认证会话。
      _EndToEndAuth? authA;
      _EndToEndAuth? authB;
      // 两端生产 PowerSync 运行时。
      OmniSyncRuntime? deviceA;
      OmniSyncRuntime? deviceB;
      try {
        authA = await _connectTestDevice();
        authB = await _connectTestDevice();
        deviceA = await OmniSyncRuntime.openAtPath(
          authA,
          path.join(directory.path, 'legacy-a.sqlite'),
        );
        deviceB = await OmniSyncRuntime.openAtPath(
          authB,
          path.join(directory.path, 'legacy-b.sqlite'),
        );
        await deviceA.connect(authA.ownerId);
        await deviceA.powerSync.waitForFirstSync().timeout(
          const Duration(seconds: 40),
        );
        // 查询已复制的测试日，重复执行不复用上次保留的业务日。
        final List<Map<String, Object?>> previousDays = await deviceA.powerSync
            .getAll(
              'SELECT day_key FROM daily_quote_selections '
              'WHERE day_key >= ? AND day_key < ?',
              <Object?>['2099-01-01', '2100-01-01'],
            );
        // 已占用的 2099 年日期键。
        final Set<String> occupiedDays = previousDays
            .map((Map<String, Object?> row) => row['day_key'] as String)
            .toSet();
        // 本次使用的自然日，不与原 E2E 的 2026 年数据混用。
        final DateTime day =
            List<DateTime>.generate(
              365,
              (int index) =>
                  DateTime.utc(2099, 1, 1).add(Duration(days: index)),
            ).firstWhere(
              (DateTime candidate) =>
                  !occupiedDays.contains(businessDayKey(candidate)),
              orElse: () => throw StateError('2099 年隔离测试日期已用完，请重建测试服务'),
            );
        // 两端旧版各自生成的不同随机 daily ID。
        final String canonicalId = const Uuid().v7();
        final String legacyId = const Uuid().v7();
        // 初次选择和离线修改后的名言，使用本次独占身份。
        final String firstQuoteId = const Uuid().v7();
        final String secondQuoteId = const Uuid().v7();
        // 本次写入时刻用于保持两个设备所持快照一致。
        final DateTime createdAt = DateTime.now().toUtc();
        // A 端生产 Drift 数据库。
        final AppDatabase driftA = deviceA.database;
        await driftA.transaction(() async {
          for (final String quoteId in <String>[firstQuoteId, secondQuoteId]) {
            await driftA
                .into(driftA.quotes)
                .insert(
                  QuotesCompanion.insert(
                    id: quoteId,
                    content: '旧版每日身份回归 $quoteId',
                    createdAt: createdAt,
                    updatedAt: createdAt,
                  ),
                );
          }
          await driftA
              .into(driftA.dailyQuoteSelections)
              .insert(
                DailyQuoteSelectionsCompanion.insert(
                  id: canonicalId,
                  dayKey: businessDayKey(day),
                  quoteId: Value<String?>(firstQuoteId),
                  createdAt: createdAt,
                  updatedAt: createdAt,
                ),
              );
        });
        // A 的服务器事务先完成，保证其旧随机 ID 成为 canonical。
        await _waitForUpload(deviceA.powerSync);
        // B 仍未连接，模拟旧版本从共享名言快照独立创建每日行。
        final AppDatabase driftB = deviceB.database;
        await driftB.transaction(() async {
          for (final String quoteId in <String>[firstQuoteId, secondQuoteId]) {
            await driftB
                .into(driftB.quotes)
                .insert(
                  QuotesCompanion.insert(
                    id: quoteId,
                    content: '旧版每日身份回归 $quoteId',
                    createdAt: createdAt,
                    updatedAt: createdAt,
                  ),
                );
          }
          await driftB
              .into(driftB.dailyQuoteSelections)
              .insert(
                DailyQuoteSelectionsCompanion.insert(
                  id: legacyId,
                  dayKey: businessDayKey(day),
                  quoteId: Value<String?>(firstQuoteId),
                  createdAt: createdAt,
                  updatedAt: createdAt,
                ),
              );
        });
        // 第二个离线事务必须以旧 ID PATCH，验证持久别名而非只吞掉重复 PUT。
        await (driftB.update(
              driftB.dailyQuoteSelections,
            )..where((DailyQuoteSelections table) => table.id.equals(legacyId)))
            .write(
              DailyQuoteSelectionsCompanion(
                quoteId: Value<String?>(secondQuoteId),
                updatedAt: Value<DateTime>(
                  createdAt.add(const Duration(seconds: 1)),
                ),
              ),
            );
        await deviceB.connect(authB.ownerId);
        await _waitForUpload(deviceB.powerSync);
        await deviceB.powerSync.waitForFirstSync().timeout(
          const Duration(seconds: 40),
        );
        // A 收到 B 的离线 PATCH，B 收到 A 的 canonical 身份。
        for (final OmniSyncRuntime device in <OmniSyncRuntime>[
          deviceA,
          deviceB,
        ]) {
          // 只有下载 checkpoint 应用成功才可能满足 canonical ID 和新内容。
          final List<Map<String, Object?>> rows = await _waitForRows(
            device.powerSync,
            'SELECT id, quote_id FROM daily_quote_selections WHERE day_key = ?',
            <Object?>[businessDayKey(day)],
            (rows) =>
                rows.length == 1 &&
                rows.single['id'] == canonicalId &&
                rows.single['quote_id'] == secondQuoteId,
          );
          expect(rows.single['id'], isNot(legacyId));
          expect((await device.powerSync.getUploadQueueStats()).count, 0);
          expect(device.powerSync.currentStatus.lastSyncedAt, isNotNull);
          expect(device.powerSync.currentStatus.downloadError, isNull);
        }
        expect(
          authB.uploads
              .expand(
                (Map<String, dynamic> body) =>
                    body['operations'] as List<dynamic>,
              )
              .any(
                (dynamic operation) =>
                    operation['table'] == 'daily_quote_selections' &&
                    operation['id'] == legacyId &&
                    operation['op'] == 'PATCH',
              ),
          isTrue,
        );
        // 收敛后通过实际业务接口再次重选，验证 B 后续写入仍能上传。
        final QuoteRecord? changed = await driftB.changeQuoteForDay(day);
        expect(changed, isNotNull);
        expect(changed!.id, isNot(secondQuoteId));
        await _waitForUpload(deviceB.powerSync);
        for (final OmniSyncRuntime device in <OmniSyncRuntime>[
          deviceA,
          deviceB,
        ]) {
          await _waitForRows(
            device.powerSync,
            'SELECT id, quote_id FROM daily_quote_selections WHERE day_key = ?',
            <Object?>[businessDayKey(day)],
            (rows) =>
                rows.length == 1 &&
                rows.single['id'] == canonicalId &&
                rows.single['quote_id'] == changed.id,
          );
        }
      } finally {
        await deviceA?.disconnect();
        await deviceB?.disconnect();
        await deviceA?.close();
        await deviceB?.close();
        authA?.api.close(force: true);
        authB?.api.close(force: true);
        await directory.delete(recursive: true);
      }
    },
    skip: _runEndToEnd ? false : '需要显式启动隔离 Docker 同步服务',
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
