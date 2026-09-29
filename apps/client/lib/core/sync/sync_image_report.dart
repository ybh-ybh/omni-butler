import 'dart:io';

import 'package:omni_butler/core/sync/sync_snapshot.dart';

/// 迁移报告与恢复使用同一规则，优先业务路径，再尝试附件缓存路径。
Future<String?> findAvailableMigrationImagePath({
  String? businessPath,
  String? attachmentPath,
}) async {
  // 去重后的候选文件位置，绝不请求已经下线的原服务器。
  final Set<String> candidates = <String>{
    if (businessPath != null && businessPath.isNotEmpty) businessPath,
    if (attachmentPath != null && attachmentPath.isNotEmpty) attachmentPath,
  };
  for (final String candidate in candidates) {
    try {
      if (await File(candidate).exists()) return candidate;
    } on FileSystemException {
      // 单个路径不可访问时仍尝试另一份本机缓存。
    }
  }
  return null;
}

/// 列出本机没有文件的业务主图；缺图不能阻止结构化数据迁移。
Future<List<String>> findMissingMigrationImages(SyncSnapshot snapshot) async {
  // 本机附件身份到文件位置的映射，不尝试访问已经下线的原服务器。
  final Map<String, String?> paths = <String, String?>{
    for (final Map<String, Object?> attachment
        in snapshot.tables['attachments'] ?? <Map<String, Object?>>[])
      attachment['id']! as String: attachment['local_path'] as String?,
  };
  // 可同步图片的两个业务模块；首页背景始终属于本机设置。
  const Map<String, String> tables = <String, String>{
    'inventory_items': '物品',
    'memberships': '会员',
  };
  // 供确认页、完成提示和持久迁移日志使用的业务名称。
  final List<String> missing = <String>[];
  for (final MapEntry<String, String> table in tables.entries) {
    for (final Map<String, Object?> row
        in snapshot.tables[table.key] ?? <Map<String, Object?>>[]) {
      // 从业务主图或附件记录寻找当前设备实际可以迁移的文件。
      final String? attachmentId = row['image_attachment_id'] as String?;
      // 历史版本可能只保存业务字段中的本机位置。
      final String? localPath = row['image_local_path'] as String?;
      if (attachmentId == null && localPath == null) continue;
      // 与候选数据库恢复共用实际文件判断，避免报告可用却未恢复。
      final String? available = await findAvailableMigrationImagePath(
        businessPath: localPath,
        attachmentPath: paths[attachmentId],
      );
      if (available == null) {
        missing.add('${table.value}：${row['name'] ?? row['id']}');
      }
    }
  }
  return missing;
}
