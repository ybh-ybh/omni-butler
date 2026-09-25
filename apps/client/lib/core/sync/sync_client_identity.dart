import 'package:powersync/powersync.dart';
import 'package:uuid/uuid.dart';

/// 读取当前本地数据库的上传身份；清空数据库后生成全新身份。
Future<String> ensureSyncClientId(PowerSyncDatabase database) {
  return database.writeTransaction((transaction) async {
    // 当前数据库已经持久化的客户端身份。
    final existing = await transaction.getOptional(
      'SELECT value FROM device_sync_metadata WHERE id = ?',
      <Object?>['client_id'],
    );
    if (existing != null) {
      return existing['value']! as String;
    }
    // 与 SDK 自增事务号共同组成幂等键的新客户端 UUID。
    final String clientId = const Uuid().v4();
    await transaction.execute(
      'INSERT INTO device_sync_metadata(id, value) VALUES(?, ?)',
      <Object?>['client_id', clientId],
    );
    return clientId;
  });
}
