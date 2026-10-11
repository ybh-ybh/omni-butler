import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:omni_butler/core/sync/omni_sync_runtime.dart';
import 'package:omni_butler/core/sync/sync_connection_store.dart';
import 'package:omni_butler/core/sync/sync_snapshot.dart';
import 'package:omni_butler/features/notes/audio/note_recorder_service.dart';
import 'package:omni_butler/features/notes/data/note_repository.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

/// 显式绑定一个数据源录音目录和它的删除标记服务。
class NoteCleanupRecordingScope {
  /// 创建待处理恢复目录。
  const NoteCleanupRecordingScope(this.directory, this.recorder);

  /// 只允许清理该目录中的恢复清单。
  final Directory directory;

  /// 与该目录绑定且未启动录音的服务。
  final NoteRecorderService recorder;
}

/// 只输出数量和路径，不输出笔记正文、用户身份或凭据。
class NoteTestCleanupReport {
  /// 汇总已经完成或预览的维护结果。
  const NoteTestCleanupReport({
    required this.executed,
    required this.notes,
    required this.audioSegments,
    required this.localFiles,
    required this.pendingManifests,
    required this.noteQueueRows,
    this.backupPath,
  });

  /// 此次是否实际执行。
  final bool executed;

  /// 正式及回收站笔记数量。
  final int notes;

  /// 原音段数量。
  final int audioSegments;

  /// 本机文件状态数量。
  final int localFiles;

  /// 未落库恢复清单数量。
  final int pendingManifests;

  /// 专属笔记上传队列数量。
  final int noteQueueRows;

  /// 完整数据库及原音回滚备份目录。
  final String? backupPath;

  /// 安全可打印的维护结果。
  Map<String, Object?> toJson() => {
    'executed': executed,
    'notes': notes,
    'audioSegments': audioSegments,
    'localFiles': localFiles,
    'pendingManifests': pendingManifests,
    'noteQueueRows': noteQueueRows,
    'backupPath': backupPath,
  };
}

/// 解析活动库；存在未完成迁移时不允许绕过迁移日志维护真实数据库。
Future<String> locateNoteCleanupDatabase(Directory documents) async {
  // 已验证的应用文档目录。
  final String root = await documents.resolveSymbolicLinks();
  // 已安装应用的持久控制库，不创建缺失的控制库。
  final File control = File(p.join(root, 'omni_butler_connection.sqlite'));
  // 活动库原始路径，保持录音目录摘要一致。
  String selected = p.join(documents.absolute.path, 'omni_butler.sqlite');
  if (await control.exists()) {
    // 只读控制信息，绝不修改active/pending/backup历史。
    final SyncConnectionStore store = SyncConnectionStore(control);
    try {
      if (await store.read('pending') != null) throw StateError('有未完成迁移，拒绝清理');
      // 当前已登记的活动数据库索引。
      final Map<String, dynamic>? active = await store.read('active');
      if (active != null) {
        // 已经确认归属的数据库路径。
        final Object? databasePath = active['databasePath'];
        if (databasePath is! String || databasePath.isEmpty) {
          throw StateError('活动库路径无效');
        }
        selected = databasePath;
      }
    } finally {
      await store.close();
    }
  }
  // 文件必须真实存在且仍属于已明确选择的Documents根。
  final String resolved = await File(selected).resolveSymbolicLinks();
  if (!p.isWithin(root, resolved)) throw StateError('活动库越出应用Documents目录');
  // 产品录音目录按databasePath原字符串摘要，验证后保持原索引拼写。
  return selected;
}

/// 验证原件路径在已明确授权音频目录内，拒绝符号链接及越界文件。
Future<String> _ownedFile(String filePath, List<Directory> roots) async {
  // 原件的普通文件身份。
  final FileSystemEntityType type = await FileSystemEntity.type(
    filePath,
    followLinks: false,
  );
  if (type != FileSystemEntityType.file) {
    throw FileSystemException('原音缺失或不是普通文件', filePath);
  }
  // 原件解析后的真实路径。
  final String actual = await File(filePath).resolveSymbolicLinks();
  // 当前明确授权的音频根目录。
  for (final Directory root in roots) {
    if (await root.exists() &&
        p.isWithin(await root.resolveSymbolicLinks(), actual)) {
      return p.normalize(actual);
    }
  }
  throw FileSystemException('原音不在授权目录', filePath);
}

/// 一次性本机维护；只在用户已明确声明本机笔记均为测试数据时使用。
Future<NoteTestCleanupReport> clearNoteTestData({
  required OmniSyncRuntime runtime,
  required List<NoteCleanupRecordingScope> recordings,
  required List<Directory> audioRoots,
  required Directory backupParent,
  // 只有显式opt-in才允许实际清理。
  bool execute = false,
}) async {
  if (runtime.powerSync.connected ||
      recordings.any((scope) => scope.recorder.state.isActive)) {
    throw StateError('同步或录音仍在运行，拒绝维护');
  }
  // 清理前按物理表保存非笔记业务，文件共享保护也从这里读取。
  final SyncSnapshot before = await runtime.exportSnapshot();
  // 本次唯一允许删除的笔记表白名单。
  final Set<String> noteTables = {
    'note_entries',
    'note_versions',
    'note_audio_segments',
    'note_audio_local_files',
  };
  // 清理前必须逐行保持的其他业务记录。
  final Map<String, Object?> protectedBusiness = {
    // 逐项处理当前集合中的记录。
    for (final MapEntry<String, List<Map<String, Object?>>> table
        in before.tables.entries)
      if (!noteTables.contains(table.key)) table.key: table.value,
  };
  // 设备来源和上传身份不属于笔记业务，维护也必须逐行保留。
  protectedBusiness['device_sync_metadata'] = await runtime.powerSync.getAll(
    'SELECT * FROM device_sync_metadata ORDER BY id',
  );
  // 清理前带原始身份和负载的上传队列。
  final List<Map<String, Object?>> queue = await runtime.powerSync.getAll(
    'SELECT * FROM ps_crud ORDER BY id',
  );

  /// 是否仅属于这次允许清理的笔记协议表。
  bool isNoteQueue(Map<String, Object?> row) {
    // 当前队列行中的原始操作对象。
    final Map<String, dynamic> payload =
        jsonDecode(row['data']! as String) as Map<String, dynamic>;
    return {
      'note_entries',
      'note_versions',
      'note_audio_segments',
    }.contains(payload['type']);
  }

  // 本次必须完整保留的非笔记队列行。
  final List<Map<String, Object?>> otherQueue = queue
      .where((row) => !isNoteQueue(row))
      .toList();
  // 笔记本机文件状态与识别候选记录。
  final List<Map<String, Object?>> local =
      before.tables['note_audio_local_files']!;
  // 需要持久删除标记保护的全部笔记身份。
  final Set<String> ids = {
    // 当前业务或队列的原始数据行。
    for (final Map<String, Object?> row in before.tables['note_entries']!)
      row['id']! as String,
    // 当前快照表及其原始行列表。
    for (final String table in ['note_versions', 'note_audio_segments'])
      // 当前业务或队列的原始数据行。
      for (final Map<String, Object?> row in before.tables[table]!)
        row['note_id']! as String,
  };
  // 其他模块仍引用的共享文件路径。
  final Set<String> protectedPaths = {};
  // 逐项处理当前集合中的记录。
  for (final List<Map<String, Object?>> rows
      in before.tables.entries
          .where((entry) => !noteTables.contains(entry.key))
          .map((entry) => entry.value)) {
    // 当前业务或队列的原始数据行。
    for (final Map<String, Object?> row in rows) {
      // 用于检查共享路径的当前业务字段值。
      for (final Object? value in row.values) {
        if (value is String && p.isAbsolute(value)) {
          protectedPaths.add(p.normalize(value));
          if (await File(value).exists()) {
            protectedPaths.add(
              p.normalize(await File(value).resolveSymbolicLinks()),
            );
          }
        }
      }
    }
  }
  // 全部将删或受引用保护的文件先验证；预检失败不得删除任何数据。
  final Set<String> filePaths = {};
  // 当前业务或队列的原始数据行。
  for (final Map<String, Object?> row in local) {
    // 当前本机文件状态声明的原音位置。
    final String? path = row['local_path'] as String?;
    if (path != null) {
      // 已确认属于授权音频根的真实路径。
      final String owned = await _ownedFile(path, audioRoots);
      filePaths.add(owned);
      if (protectedPaths.contains(owned)) protectedPaths.add(p.normalize(path));
    }
  }
  // 当前数据源尚未确认的恢复清单。
  final List<File> manifests = [];
  // 当前录音目录及其专属删除服务。
  for (final NoteCleanupRecordingScope scope in recordings) {
    if (!await scope.directory.exists()) continue;
    if (await FileSystemEntity.type(scope.directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw StateError('录音恢复目录不是普通目录');
    }
    // 当前恢复目录或测试隔离目录。
    final String directory = await scope.directory.resolveSymbolicLinks();
    await for (final FileSystemEntity entry in scope.directory.list(
      followLinks: false,
    )) {
      if (!entry.path.endsWith('.pending.json')) continue;
      if (entry is! File) throw FileSystemException('恢复清单不是普通文件', entry.path);
      // 当前恢复清单及其归属信息。
      final Map<String, dynamic> manifest =
          jsonDecode(await entry.readAsString()) as Map<String, dynamic>;
      // 原音绑定的笔记身份。
      final Object? noteId = manifest['noteId'];
      // 原始文件或恢复清单声明的文件位置。
      final Object? original = manifest['path'];
      if (noteId is! String ||
          noteId.isEmpty ||
          original is! String ||
          !p.equals(p.dirname(p.normalize(original)), p.normalize(directory))) {
        throw StateError('恢复清单身份或目录损坏');
      }
      ids.add(noteId);
      manifests.add(entry);
      // 已确认属于授权音频根的真实路径。
      final String owned = await _ownedFile(original, audioRoots);
      filePaths.add(owned);
      if (protectedPaths.contains(owned)) {
        protectedPaths.add(p.normalize(original));
      }
    }
  }
  // 队列里已经永久删除的根也需要持久删除marker。
  for (final Map<String, Object?> row in queue.where(isNoteQueue)) {
    // 当前队列行中的原始操作对象。
    final Map<String, dynamic> payload =
        jsonDecode(row['data']! as String) as Map<String, dynamic>;
    if (payload['type'] == 'note_entries' && payload['id'] is String) {
      ids.add(payload['id'] as String);
    }
  }
  // 默认只预览，不新建目录或触碰队列。
  final NoteTestCleanupReport preview = NoteTestCleanupReport(
    executed: false,
    notes: before.tables['note_entries']!.length,
    audioSegments: before.tables['note_audio_segments']!.length,
    localFiles: local.length,
    pendingManifests: manifests.length,
    noteQueueRows: queue.where(isNoteQueue).length,
  );
  if (!execute) return preview;
  // 独立备份根不得位于本次将处理的录音目录内。
  final String parent = p.normalize(backupParent.absolute.path);
  // 应用文档目录的真实边界。
  for (final Directory root in audioRoots) {
    if (p.equals(p.normalize(root.absolute.path), parent) ||
        p.isWithin(p.normalize(root.absolute.path), parent)) {
      throw StateError('备份目录不能位于原音清理目录');
    }
  }
  await backupParent.create(recursive: true);
  // 本次唯一备份目录或真实备份运行时。
  final Directory backup = await Directory(
    p.join(await backupParent.resolveSymbolicLinks(), const Uuid().v4()),
  ).create();
  // 记录备份、SQL提交及文件完成阶段的清单。
  final File journal = File(p.join(backup.path, 'manifest.json'));
  // SQLite真实一致性备份包含业务、原始队列和本机元数据，不使用裸文件复制。
  await runtime.powerSync.execute('VACUUM INTO ?', [
    p.join(backup.path, 'database.sqlite'),
  ]);
  // 逐个原件的回滚位置及校验摘要。
  final List<Map<String, Object?>> copies = [];
  // 原始文件或恢复清单声明的文件位置。
  for (final String original in {
    ...filePaths,
    ...manifests.map((file) => file.path),
  }) {
    // 当前已经生成的独立文件备份。
    final File copy = await File(original)
        .copy(p.join(backup.path, '${copies.length}.backup'));
    copies.add({
      'originalPath': original,
      'backupPath': copy.path,
      'byteSize': await copy.length(),
      'sha256': (await sha256.bind(copy.openRead()).first).toString(),
      'protected': protectedPaths.contains(p.normalize(original)),
    });
  }
  await journal.writeAsString(
    jsonEncode({
      'phase': 'backed-up',
      'databasePath': runtime.databasePath,
      'noteIds': ids.toList(),
      'files': copies,
    }),
    flush: true,
  );
  // 删除SQL和笔记队列同一事务；保护其他模块共享文件不交给孤儿清理器。
  final NoteRepository repository = NoteRepository(runtime.database);
  await runtime.database.transaction(() async {
    // 本次待明确永久删除的笔记身份。
    for (final String id in ids) {
      await repository.permanentlyDelete(id);
    }
    await runtime.database.delete(runtime.database.noteVersions).go();
    await runtime.database.delete(runtime.database.noteAudioSegments).go();
    await runtime.database.delete(runtime.database.noteEntries).go();
    // 当前业务或队列的原始数据行。
    for (final Map<String, Object?> row in local) {
      if (protectedPaths.contains(
        p.normalize(row['local_path'] as String? ?? ''),
      )) {
        await (runtime.database.delete(
          runtime.database.noteAudioLocalFiles,
        )..where((table) => table.id.equals(row['id']! as String))).go();
      }
    }
    await runtime.database.customStatement(
      "DELETE FROM ps_crud WHERE json_extract(data, '\$.type') IN ('note_entries', 'note_versions', 'note_audio_segments')",
    );
  });
  // 明确区分SQL已提交与文件清理完成；后续失败可依据完整备份重试或回滚。
  await journal.writeAsString(
    jsonEncode({
      'phase': 'database-cleaned',
      'databasePath': runtime.databasePath,
      'noteIds': ids.toList(),
      'files': copies,
    }),
    flush: true,
  );
  // 提交后清物理原件；失败向调用方抛出，不声称全量清理成功。
  for (final NoteCleanupRecordingScope scope in recordings) {
    // 本次待明确永久删除的笔记身份。
    for (final String id in ids) {
      await scope.recorder.discardPendingForNote(
        id,
        protectedPaths: protectedPaths,
      );
    }
  }
  await repository.purgeOrphanFiles();
  // 清理完成后的业务快照。
  final SyncSnapshot after = await runtime.exportSnapshot();
  // 清理后必须与原快照严格一致的非笔记业务。
  final Map<String, Object?> remainingBusiness = {
    // 逐项处理当前集合中的记录。
    for (final MapEntry<String, List<Map<String, Object?>>> table
        in after.tables.entries)
      if (!noteTables.contains(table.key)) table.key: table.value,
  };
  remainingBusiness['device_sync_metadata'] = await runtime.powerSync.getAll(
    'SELECT * FROM device_sync_metadata ORDER BY id',
  );
  // 清理后应保持原身份和负载的非笔记队列。
  final List<Map<String, Object?>> remainingQueue = await runtime.powerSync
      .getAll('SELECT * FROM ps_crud ORDER BY id');
  if (jsonEncode(protectedBusiness) != jsonEncode(remainingBusiness) ||
      jsonEncode(otherQueue) != jsonEncode(remainingQueue) ||
      noteTables.any((table) => after.tables[table]!.isNotEmpty)) {
    throw StateError('清理后完整性比对失败，请使用备份恢复');
  }
  await journal.writeAsString(
    jsonEncode({
      'phase': 'completed',
      'databasePath': runtime.databasePath,
      'noteIds': ids.toList(),
      'files': copies,
    }),
    flush: true,
  );
  return NoteTestCleanupReport(
    executed: true,
    notes: preview.notes,
    audioSegments: preview.audioSegments,
    localFiles: preview.localFiles,
    pendingManifests: preview.pendingManifests,
    noteQueueRows: preview.noteQueueRows,
    backupPath: backup.path,
  );
}
