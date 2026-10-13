import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/core/sync/sync_snapshot.dart';
import 'package:path/path.dart' as path;

/// 验证录音文件体与同步元数据一致，不能把损坏文件当成完整备份。
Future<bool> isMigrationNoteAudioValid(
  String? localPath,
  Map<String, Object?> segment,
) async {
  if (localPath == null || localPath.isEmpty) return false;
  try {
    // 本次检查的私有录音文件。
    final File file = File(localPath);
    if (!await file.exists() || await file.length() != segment['byte_size']) {
      return false;
    }
    // 流式读取避免长录音一次性占用内存。
    final Digest digest = await sha256.bind(file.openRead()).first;
    return digest.toString() == segment['sha256'];
  } on FileSystemException {
    return false;
  }
}

/// 列出当前设备缺失或校验不通过的原音，迁移确认不能声称原音完整。
Future<List<String>> findMissingMigrationNoteAudio(
  SyncSnapshot snapshot,
) async {
  // 本机音频文件位置按段标识索引。
  final Map<Object?, String?> files = <Object?, String?>{
    for (final Map<String, Object?> row
        in snapshot.tables['note_audio_local_files'] ??
            <Map<String, Object?>>[])
      row['id']: row['local_path'] as String?,
  };
  // 供迁移确认使用的缺音记录说明。
  final List<String> missing = <String>[];
  for (final Map<String, Object?> segment
      in snapshot.tables['note_audio_segments'] ?? <Map<String, Object?>>[]) {
    if (!await isMigrationNoteAudioValid(files[segment['id']], segment)) {
      missing.add('笔记原音：${segment['note_id']} / ${segment['id']}');
    }
  }
  for (final Map<String, Object?> segment
      in snapshot.tables['note_draft_audio_segments'] ??
          <Map<String, Object?>>[]) {
    if (!await isMigrationNoteAudioValid(
      segment['local_path'] as String?,
      segment,
    )) {
      missing.add('草稿原音：${segment['note_id']} / ${segment['id']}');
    }
  }
  return missing;
}

/// 为快照保留独立文件体与哈希验证，返回指向备份副本的本机元数据。
Future<SyncSnapshot> backupMigrationNoteAudio(
  SyncSnapshot snapshot,
  Directory backupDirectory,
) async {
  // 音频同步元数据按标识索引，用于校验本机文件。
  final Map<Object?, Map<String, Object?>> segments = {
    for (final Map<String, Object?> row
        in snapshot.tables['note_audio_segments'] ?? <Map<String, Object?>>[])
      row['id']: row,
  };
  // 不修改原始拍摄结果，后续日志持久化独立的完整备份。
  final List<Map<String, Object?>> files = [];
  for (final Map<String, Object?> source
      in snapshot.tables['note_audio_local_files'] ??
          <Map<String, Object?>>[]) {
    // 可以调整文件引用的本机行副本。
    final Map<String, Object?> row = Map<String, Object?>.from(source);
    // 当前文件所属的有效或回收站录音段。
    final Map<String, Object?>? segment = segments[row['id']];
    if (segment != null &&
        await isMigrationNoteAudioValid(
          row['local_path'] as String?,
          segment,
        )) {
      await backupDirectory.create(recursive: true);
      // 使用标识摘要作为文件名，禁止外部标识控制目录或覆盖其他文件。
      final String fileName =
          '${sha256.convert(utf8.encode(row['id'].toString()))}.audio';
      // 只写入这次迁移拥有的独立文件。
      final File copy = await File(row['local_path']! as String)
          .copy(path.join(backupDirectory.path, fileName));
      if (!await isMigrationNoteAudioValid(copy.path, segment)) {
        throw const FileSystemException('笔记原音备份校验失败');
      }
      row['local_path'] = copy.path;
    } else {
      // 缺失引用显式清空，不能在新数据源误读旧目录中的未验证文件。
      row['local_path'] = null;
    }
    files.add(row);
  }
  // 草稿原音仅保留独立本机副本，不进入服务器暂存请求。
  final List<Map<String, Object?>> draftFiles = [];
  for (final Map<String, Object?> source
      in snapshot.tables['note_draft_audio_segments'] ??
          <Map<String, Object?>>[]) {
    // 不改写原数据库路径。
    final Map<String, Object?> row = Map<String, Object?>.from(source);
    if (await isMigrationNoteAudioValid(row['local_path'] as String?, row)) {
      await backupDirectory.create(recursive: true);
      // 草稿命名空间避免与正式原音意外同身份覆盖。
      final String fileName =
          'draft-${sha256.convert(utf8.encode(row['id'].toString()))}.audio';
      final File copy = await File(row['local_path']! as String)
          .copy(path.join(backupDirectory.path, fileName));
      if (!await isMigrationNoteAudioValid(copy.path, row)) {
        throw const FileSystemException('草稿原音备份校验失败');
      }
      row['local_path'] = copy.path;
    } else {
      row['local_path'] = null;
    }
    draftFiles.add(row);
  }
  return SyncSnapshot(
    tables: {
      ...snapshot.tables,
      'note_audio_local_files': files,
      'note_draft_audio_segments': draftFiles,
    },
    pendingOperations: snapshot.pendingOperations,
  );
}

/// 替换服务端之前持久暂存原音，失败时服务器的原业务快照保持不变。
Future<List<String>> stageMigrationNoteAudio({
  required AuthRepository auth,
  required String serverAddress,
  required String syncKey,
  required String migrationId,
  required SyncSnapshot snapshot,
}) async {
  // 同一迁移身份复用服务端暂存回执；鉴权不依赖旧设备会话。
  final String baseUrl = auth.normalizeBaseUrl(serverAddress);
  // 复用仓储注入的 HTTP 工厂，支持断网、响应丢失和重试验证。
  final Dio client =
      auth.clientFactory?.call(baseUrl) ?? Dio(BaseOptions(baseUrl: baseUrl));
  // 与经过确认的缺音报告对应的明确省略段身份。
  final List<String> omitted = [];
  // 快照音频体按稳定身份索引。
  final Map<Object?, String?> files = {
    for (final Map<String, Object?> row
        in snapshot.tables['note_audio_local_files'] ??
            <Map<String, Object?>>[])
      row['id']: row['local_path'] as String?,
  };
  for (final Map<String, Object?> segment
      in snapshot.tables['note_audio_segments'] ?? <Map<String, Object?>>[]) {
    // 使用备份的独立文件，而非读取已经退休的数据源。
    final String? localPath = files[segment['id']];
    if (!await isMigrationNoteAudioValid(localPath, segment)) {
      if (localPath != null) {
        throw const ApiFailure('迁移原音备份损坏，请修复备份后重试；服务器业务数据未替换');
      }
      omitted.add(segment['id']! as String);
      continue;
    }
    try {
      // 每次重试新建 multipart 文件流，不能复用已经消耗的请求体。
      final FormData body = FormData.fromMap({
        'syncKey': syncKey,
        'migrationId': migrationId,
        'segmentId': segment['id'],
        'sha256': segment['sha256'],
        'mime': segment['mime'],
        'file': await MultipartFile.fromFile(
          localPath!,
          filename: 'recording.wav',
          contentType: DioMediaType.parse(segment['mime']! as String),
        ),
      });
      // 暂存成功必须返回文件体的服务端摘要与长度，不能仅凭 HTTP 成功判断完整。
      final Response<Map<String, dynamic>> response = await client
          .put<Map<String, dynamic>>(
            '/notes/audio/migration/stage',
            data: body,
            options: Options(
              sendTimeout: const Duration(minutes: 10),
              receiveTimeout: const Duration(minutes: 2),
            ),
          );
      // 校验该回执属于当前迁移和当前原音内容。
      final Map<String, dynamic>? receipt = response.data;
      if (receipt == null ||
          receipt['migrationId'] != migrationId ||
          receipt['segmentId'] != segment['id'] ||
          receipt['sha256'] != segment['sha256'] ||
          receipt['byteSize'] != segment['byte_size']) {
        throw const ApiFailure('目标服务器原音暂存回执校验失败，未替换业务数据');
      }
    } on DioException {
      throw const ApiFailure('目标服务器原音暂存失败，请重试同一次迁移；服务器业务数据未替换');
    }
  }
  return omitted;
}
