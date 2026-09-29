import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:uuid/uuid.dart';

/// 本机图片协议状态，独立于同步业务数据与附件文件。
class ImageSyncStore {
  /// 当前活动数据库。
  final AppDatabase database;

  /// 创建数据库状态访问器。
  ImageSyncStore(this.database);

  /// 查询单个持久状态。
  Future<Map<String, dynamic>?> read(String key) async {
    // 当前状态行。
    final QueryRow? row = await database
        .customSelect(
          'SELECT value FROM image_sync_metadata WHERE id = ?',
          variables: <Variable<Object>>[Variable<String>(key)],
        )
        .getSingleOrNull();
    return row == null
        ? null
        : jsonDecode(row.read<String>('value')) as Map<String, dynamic>;
  }

  /// 原子覆盖单个持久状态。
  Future<void> write(String key, Map<String, dynamic> value) =>
      database.customStatement(
        'INSERT INTO image_sync_metadata(id,value) VALUES(?,?) '
        'ON CONFLICT(id) DO UPDATE SET value=excluded.value',
        <Object?>[key, jsonEncode(value)],
      );

  /// 删除已经确认的本机操作。
  Future<void> remove(String key) => database.customStatement(
    'DELETE FROM image_sync_metadata WHERE id = ?',
    <Object?>[key],
  );

  /// 用户选择或删除图片时，与本机业务引用在同一事务保存操作。
  Future<void> recordIntent(
    String type,
    String id,
    String? attachmentId,
  ) async {
    if (type == 'quoteBanner') return;
    // 最近使用的数据源，未连接时暂不绑定。
    final Map<String, dynamic>? current = await read('scope');
    // 用户编辑时已见到的服务端版本，绝不能在上传前偷换成最新版本。
    final Map<String, dynamic>? baseline = await read('remote:$type:$id');
    await write('intent:$type:$id', <String, dynamic>{
      'operationId': const Uuid().v4(),
      'attachmentId': attachmentId,
      'scope': current?['value'],
      'expectedRevision': baseline?['revision'],
      'known': baseline != null,
    });
  }
}
