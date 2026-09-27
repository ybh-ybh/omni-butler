import 'dart:convert';

import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/core/sync/sync_client_identity.dart';
import 'package:powersync/powersync.dart';

/// 通过 Omni Butler NestJS API 上传本地 PowerSync 变更。
class OmniPowerSyncConnector extends PowerSyncBackendConnector {
  /// 已明确下线的同步列；旧队列只移除这些字段，未知字段仍由服务器校验。
  static const Map<String, Set<String>> _retiredColumns = <String, Set<String>>{
    'daily_quote_selections': <String>{'is_manual'},
    'taxonomy_entries': <String>{'normalized_name', 'icon_code_point'},
    'memberships': <String>{
      'payment_method',
      'is_favorite',
      'image_attachment_id',
    },
    'membership_payments': <String>{'billing_cycle'},
    'inventory_items': <String>{'image_attachment_id'},
  };

  /// 设备会话与受保护 API 请求仓储。
  final AuthRepository _auth;

  /// 连接器创建时固定的会话代次，不随仓储重新连接而变化。
  final int _generation;

  /// 明确提供的服务器及 owner 作用域。
  final SyncSession? session;

  /// 首次凭证确认的 owner，兼容仅传仓储的旧调用。
  String? _credentialOwnerId;

  /// 首次上传后固定数据库实例，防止错误确认其他数据库的事务。
  PowerSyncDatabase? _database;

  /// 创建后端同步连接器。
  OmniPowerSyncConnector(this._auth, {this.session})
    : _generation = _auth.sessionGeneration;

  /// 在网络及数据库异步边界核对固定会话，旧结果不能确认新状态。
  Future<void> _assertScope() async {
    if (_auth.sessionGeneration != _generation) {
      throw const ApiFailure('同步会话已变更，请重新建立同步连接');
    }
    if (session != null || _credentialOwnerId != null) {
      // 当前设备会话必须继续属于连接器固定的 owner 和服务器。
      final SyncSession? current = await _auth.loadSession();
      if (_auth.sessionGeneration != _generation ||
          current == null ||
          current.identity.id != (session?.identity.id ?? _credentialOwnerId) ||
          (session != null && current.apiBaseUrl != session!.apiBaseUrl)) {
        throw const ApiFailure('同步数据源已变更，旧连接已停止');
      }
    }
  }

  /// 获取当前设备的短期 PowerSync 凭证。
  @override
  Future<PowerSyncCredentials?> fetchCredentials() async {
    await _assertScope();
    // 服务端签发的短期凭证。
    final credential = await _auth.fetchPowerSyncCredentialForGeneration(
      _generation,
    );
    if ((session != null && credential.userId != session!.identity.id) ||
        (_credentialOwnerId != null &&
            credential.userId != _credentialOwnerId)) {
      throw const ApiFailure('同步凭证的数据源与当前连接不一致');
    }
    _credentialOwnerId = credential.userId;
    await _assertScope();
    return PowerSyncCredentials(
      endpoint: credential.endpoint,
      token: credential.token,
      userId: credential.userId,
      expiresAt: DateTime.now().add(Duration(seconds: credential.expiresIn)),
    );
  }

  /// 完整上传每个本地事务，并用持久身份保证响应丢失后安全重试。
  @override
  Future<void> uploadData(PowerSyncDatabase database) async {
    await _assertScope();
    if (_database != null && !identical(_database, database)) {
      throw const ApiFailure('同步连接器不能跨数据库复用');
    }
    _database = database;
    // 当前数据库生命周期内保持稳定的上传身份。
    final String clientId = await ensureSyncClientId(database);
    while (true) {
      await _assertScope();
      // SDK 保留本地事务边界的下一组操作。
      final CrudTransaction? transaction = await database
          .getNextCrudTransaction();
      if (transaction == null) {
        return;
      }
      if (transaction.transactionId == null) {
        throw const ApiFailure('本地同步事务缺少标识，请检查客户端数据库版本');
      }
      // 符合 NestJS 同步接口契约的操作列表。
      final List<Map<String, Object?>> operations = transaction.crud
          .map(_operationPayload)
          .whereType<Map<String, Object?>>()
          .toList(growable: false);
      if (operations.isEmpty) {
        // 仅修改已下线字段的旧事务没有剩余业务作用，无需提交空请求。
        await _assertScope();
        await transaction.complete();
        continue;
      }
      // 在重试期间不会变化的事务请求体。
      final Map<String, Object?> payload = <String, Object?>{
        'clientId': clientId,
        'transactionId': transaction.transactionId.toString(),
        'operations': operations,
      };
      if (operations.length > 100000 ||
          utf8.encode(jsonEncode(payload)).length > 32 * 1024 * 1024) {
        throw const ApiFailure('单次同步事务超过 100000 条或 32 MB，无法拆分上传，请减少单次导入规模');
      }
      await _auth.authorizedRequestForGeneration<void>(
        _generation,
        'POST',
        '/sync/operations',
        data: payload,
      );
      await _assertScope();
      await transaction.complete();
    }
  }

  /// 将 PowerSync SDK 操作转换为服务端 DTO。
  Map<String, Object?>? _operationPayload(CrudEntry entry) {
    // 复制历史负载，不修改 SDK 保存的原始队列或事务身份。
    final Map<String, Object?>? data = entry.opData == null
        ? null
        : Map<String, Object?>.from(entry.opData!);
    // 当前表明确退休的字段。
    final Set<String> retired =
        _retiredColumns[entry.table] ?? const <String>{};
    // 仅退休字段构成的 PATCH 可以安全忽略，原本无效的空 PATCH 仍交给服务器拒绝。
    final bool removed = data?.keys.any(retired.contains) ?? false;
    data?.removeWhere((String column, Object? _) => retired.contains(column));
    if (entry.op == UpdateType.patch && removed && data!.isEmpty) {
      return null;
    }
    return <String, Object?>{
      'op': entry.op.toJson(),
      'table': entry.table,
      'id': entry.id,
      'data': ?data,
    };
  }
}
