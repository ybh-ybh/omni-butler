import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

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
  // 笔记多图按独立图片身份核对，不受单图业务字段限制。
  final Map<Object?, Map<String, Object?>> noteFiles = {
    for (final Map<String, Object?> row
        in snapshot.tables['attachments'] ?? <Map<String, Object?>>[])
      if (row['business_type'] == 'noteImage' && row['deleted_at'] == null)
        row['business_id']: row,
  };
  for (final Map<String, Object?> row
      in snapshot.tables['note_images'] ?? <Map<String, Object?>>[]) {
    // 正式图片包括回收站，备份不得丢掉恢复能力。
    final Map<String, Object?>? file = noteFiles[row['id']];
    if (file == null || !await isMigrationNoteImageValid(file)) {
      missing.add('笔记图片：${row['note_id']} / ${row['id']}');
    }
  }
  // 只检查未丢弃草稿，取消后的孤儿不会扩大迁移缺失报告。
  final Set<Object?> drafts = {
    for (final Map<String, Object?> row
        in snapshot.tables['note_local_drafts'] ?? <Map<String, Object?>>[])
      if (row['discarded'] == 0 || row['discarded'] == false) row['id'],
  };
  for (final Map<String, Object?> row
      in snapshot.tables['note_draft_images'] ?? <Map<String, Object?>>[]) {
    if (drafts.contains(row['draft_id']) &&
        !await isMigrationNoteImageValid(row)) {
      missing.add('草稿图片：${row['note_id']} / ${row['id']}');
    }
  }
  return missing;
}

/// 迁移图片按本机登记的长度与摘要核验，不能把损坏文件当成可恢复原件。
Future<bool> isMigrationNoteImageValid(Map<String, Object?> row) async {
  // 文件路径仅作为访问位置，完整性以摘要为准。
  final String? localPath = row['local_path'] as String?;
  if (localPath == null) return false;
  try {
    // 按快照记录读取原件，不依赖旧服务器在线。
    final File file = File(localPath);
    return await file.exists() &&
        await file.length() == row['size_bytes'] &&
        (await sha256.bind(file.openRead()).first).toString() == row['sha256'];
  } on FileSystemException {
    return false;
  }
}

/// 快照图片独占原件副本，候选库清理不触及旧数据源及备份。
Future<SyncSnapshot> backupMigrationNoteImages(
  SyncSnapshot snapshot,
  Directory directory,
) async {
  // 正式图片和有效草稿才拥有必须保留的原件。
  final Set<Object?> ids =
      (snapshot.tables['note_images'] ?? <Map<String, Object?>>[])
          .map((row) => row['id'])
          .toSet();
  // 取消的草稿不再拥有需要备份的原件。
  final Set<Object?> drafts =
      (snapshot.tables['note_local_drafts'] ?? <Map<String, Object?>>[])
          .where((row) => row['discarded'] == 0 || row['discarded'] == false)
          .map((row) => row['id'])
          .toSet();
  // 在副本中重写路径，不改变当前活动数据库。
  final Map<String, List<Map<String, Object?>>> tables = {...snapshot.tables};
  for (final String table in ['attachments', 'note_draft_images']) {
    // 每张本机表单独生成可变路径副本。
    final List<Map<String, Object?>> output = [];
    for (final Map<String, Object?> source
        in snapshot.tables[table] ?? <Map<String, Object?>>[]) {
      // 原始快照用于失败恢复，不直接修改。
      final Map<String, Object?> row = {...source};
      if (table == 'attachments' && row['business_type'] != 'noteImage') {
        output.add(row);
        continue;
      }
      // 孤儿文件只保留元数据，不把旧源路径复制到候选库。
      final bool referenced = table == 'attachments'
          ? ids.contains(row['business_id'])
          : drafts.contains(row['draft_id']);
      if (referenced && await isMigrationNoteImageValid(row)) {
        await directory.create(recursive: true);
        // 摘要文件名隔离不可信业务身份中的路径字符。
        final String name =
            'image-$table-${sha256.convert(utf8.encode(row['id'].toString()))}.image';
        // 独立副本只能由这份迁移备份清理。
        final File copy = await File(row['local_path']! as String)
            .copy(path.join(directory.path, name));
        row['local_path'] = copy.path;
        if (!await isMigrationNoteImageValid(row)) {
          throw const FileSystemException('笔记图片备份校验失败');
        }
      } else {
        row['local_path'] = null;
      }
      output.add(row);
    }
    tables[table] = output;
  }
  return SyncSnapshot(
    tables: tables,
    pendingOperations: snapshot.pendingOperations,
  );
}
