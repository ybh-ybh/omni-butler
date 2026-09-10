import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:powersync/powersync.dart';

/// 通过 Omni Butler NestJS API 上传本地 PowerSync 变更。
class OmniPowerSyncConnector extends PowerSyncBackendConnector {
  /// 设备会话与受保护 API 请求仓储。
  final AuthRepository _auth;

  /// 创建后端同步连接器。
  OmniPowerSyncConnector(this._auth);

  /// 获取当前设备的短期 PowerSync 凭证。
  @override
  Future<PowerSyncCredentials?> fetchCredentials() async {
    // 服务端签发的短期凭证。
    final credential = await _auth.fetchPowerSyncCredential();
    return PowerSyncCredentials(
      endpoint: credential.endpoint,
      token: credential.token,
      userId: credential.userId,
      expiresAt: DateTime.now().add(Duration(seconds: credential.expiresIn)),
    );
  }

  /// 按服务端上限分批上传队列，并仅在事务成功后确认本地批次。
  @override
  Future<void> uploadData(PowerSyncDatabase database) async {
    while (true) {
      // 当前最多二百条的待上传批次。
      final CrudBatch? batch = await database.getCrudBatch(limit: 200);
      if (batch == null) {
        return;
      }
      // 符合 NestJS 同步接口契约的操作列表。
      final List<Map<String, Object?>> operations = batch.crud
          .map(_operationPayload)
          .toList(growable: false);
      await _auth.authorizedRequest<void>(
        'POST',
        '/sync/operations',
        data: <String, Object?>{'operations': operations},
      );
      await batch.complete();
      if (!batch.haveMore) {
        return;
      }
    }
  }

  /// 将 PowerSync SDK 操作转换为服务端 DTO。
  Map<String, Object?> _operationPayload(CrudEntry entry) {
    return <String, Object?>{
      'op': entry.op.toJson(),
      'table': entry.table,
      'id': entry.id,
      if (entry.opData != null) 'data': entry.opData,
    };
  }
}
