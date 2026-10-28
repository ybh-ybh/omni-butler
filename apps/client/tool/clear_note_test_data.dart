import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:omni_butler/core/sync/omni_sync_runtime.dart';
import 'package:omni_butler/core/sync/sync_connection_store.dart';
import 'package:omni_butler/core/sync/sync_snapshot.dart';
import 'package:omni_butler/features/notes/audio/note_file_paths.dart';
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
Future<String> _ownedFile(String filePath, List<Directory> roots) =>
    NoteFilePaths.ownedFile(filePath, roots);

/// Write one journal phase without replacing it with a partial JSON document.
Future<void> _writeCleanupJournal(
  File journal,
  Map<String, Object?> state,
) async {
  // The temporary entry must not be a link or a non-file.
  final File temporary = File('${journal.path}.tmp');
  await NoteFilePaths.ownedFile(
    temporary.path,
    [journal.parent],
    directChild: true,
    allowMissing: true,
  );
  await temporary.writeAsString(jsonEncode(state), flush: true);
  await temporary.rename(journal.path);
}

/// Read a complete backup and validate the stopped operation before retrying it.
Future<NoteTestCleanupReport> _resumeNoteCleanup({
  required OmniSyncRuntime runtime,
  required List<NoteCleanupRecordingScope> recordings,
  required List<Directory> audioRoots,
  required Directory backupParent,
  required Directory backup,
}) async {
  // The backup must be a direct child of the explicitly authorized parent.
  final String parent = await NoteFilePaths.directory(backupParent);
  // Resolve the directory without following a final-component link.
  final String actualBackup = await NoteFilePaths.directory(backup);
  if (!p.equals(p.dirname(actualBackup), parent)) {
    throw StateError('恢复备份不属于指定备份目录');
  }
  for (final Directory root in audioRoots) {
    // A physical audio root must never contain the backup directory.
    final String identity = await NoteFilePaths.prospectiveDirectory(root);
    if (p.equals(identity, actualBackup) ||
        p.isWithin(identity, actualBackup)) {
      throw StateError('恢复备份不能位于原音目录');
    }
  }
  // The manifest and database backup must both be ordinary owned files.
  final File journal = File(p.join(actualBackup, 'manifest.json'));
  await NoteFilePaths.ownedFile(journal.path, [
    Directory(actualBackup),
  ], directChild: true);
  // Verify the database backup before trusting any recovery metadata.
  final String databaseBackup = await NoteFilePaths.ownedFile(
    p.join(actualBackup, 'database.sqlite'),
    [Directory(actualBackup)],
    directChild: true,
  );
  // Older or interrupted journals do not contain enough evidence to resume.
  final Map<String, dynamic> state =
      jsonDecode(await journal.readAsString()) as Map<String, dynamic>;
  if (state['schemaVersion'] != 1 ||
      (state['phase'] != 'database-cleaned' && state['phase'] != 'completed')) {
    throw StateError('备份阶段或版本不支持自动恢复');
  }
  // A modified or truncated SQLite backup is not a valid recovery source.
  final Map<String, dynamic> databaseMetadata = (state['databaseBackup'] as Map)
      .cast<String, dynamic>();
  if (await File(databaseBackup).length() != databaseMetadata['byteSize'] ||
      (await sha256.bind(File(databaseBackup).openRead()).first).toString() !=
          databaseMetadata['sha256']) {
    throw StateError('数据库备份完整性校验失败');
  }
  await _verifyCleanupBaseline(
    runtime,
    recordings,
    audioRoots,
    Directory(actualBackup),
    state,
  );
  if (state['phase'] == 'completed') {
    await _verifyCleanupCompletion(
      runtime,
      audioRoots,
      Directory(actualBackup),
      state,
    );
    return _cleanupReport(Directory(actualBackup), state);
  }
  return _finishNoteCleanup(
    runtime: runtime,
    recordings: recordings,
    audioRoots: audioRoots,
    backup: Directory(actualBackup),
    state: state,
  );
}

/// Verify a post-commit snapshot, backup contents and every remaining original.
Future<void> _verifyCleanupBaseline(
  OmniSyncRuntime runtime,
  List<NoteCleanupRecordingScope> recordings,
  List<Directory> audioRoots,
  Directory backup,
  Map<String, dynamic> state,
) async {
  // Validate all control fields before any recorder or filesystem mutation.
  final Map<String, dynamic> counts = (state['counts'] as Map)
      .cast<String, dynamic>();
  for (final String field in [
    'notes',
    'audioSegments',
    'localFiles',
    'pendingManifests',
    'noteQueueRows',
  ]) {
    if (counts[field] is! int || (counts[field] as int) < 0) {
      throw StateError('备份计数无效');
    }
  }
  // Each owner can only be retried in a recorded scope.
  final Set<String> allOwners = (state['noteIds'] as List)
      .cast<String>()
      .toSet();
  // Validate the persisted owner list for each recording scope.
  final List<dynamic> scopeOwners = state['recordingOwners'] as List;
  if (scopeOwners.length != recordings.length ||
      scopeOwners.any(
        (raw) => (raw as List).cast<String>().any(
          (owner) => !allOwners.contains(owner),
        ),
      )) {
    throw StateError('恢复录音范围无效');
  }
  if (state['databasePath'] != runtime.databasePath ||
      !p.equals(
        state['databaseIdentity'] as String,
        await NoteFilePaths.file(runtime.databasePath),
      )) {
    throw StateError('恢复数据库身份不匹配');
  }
  // Validate every configured physical root against the original operation.
  final List<String> expectedRoots = (state['audioRootIdentities'] as List)
      .cast<String>();
  if (expectedRoots.length != audioRoots.length) throw StateError('恢复原音目录不匹配');
  for (int i = 0; i < audioRoots.length; i++) {
    if (!p.equals(
      expectedRoots[i],
      await NoteFilePaths.prospectiveDirectory(audioRoots[i]),
    )) {
      throw StateError('恢复原音目录不匹配');
    }
  }
  // Both the scope and recorder must retain their original physical directory.
  final List<String> expectedRecordings = (state['recordingIdentities'] as List)
      .cast<String>();
  if (expectedRecordings.length != recordings.length) {
    throw StateError('恢复录音目录不匹配');
  }
  for (int i = 0; i < recordings.length; i++) {
    if (!p.equals(
          expectedRecordings[i],
          await NoteFilePaths.prospectiveDirectory(recordings[i].directory),
        ) ||
        !p.equals(
          expectedRecordings[i],
          await recordings[i].recorder.recordingDirectoryIdentity(),
        )) {
      throw StateError('恢复录音目录不匹配');
    }
  }
  // Every backup byte must match the recorded length and digest.
  final List<dynamic> files = state['files'] as List;
  for (final dynamic raw in files) {
    // Each entry has an original, its physical identity and one owned backup.
    final Map<String, dynamic> entry = (raw as Map).cast<String, dynamic>();
    // Distinguish original audio from a pending manifest backup.
    final String kind = entry['kind'] as String;
    if ((kind != 'audio' && kind != 'pending') ||
        entry['protected'] is! bool ||
        entry['byteSize'] is! int ||
        (entry['byteSize'] as int) < 0 ||
        entry['sha256'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(entry['sha256'] as String)) {
      throw StateError('备份文件元数据无效');
    }
    // Resolve the copy inside the authorized backup directory.
    final String saved = await NoteFilePaths.ownedFile(
      entry['backupPath'] as String,
      [backup],
      directChild: true,
    );
    if (await File(saved).length() != entry['byteSize'] ||
        (await sha256.bind(File(saved).openRead()).first).toString() !=
            entry['sha256']) {
      throw StateError('备份文件完整性校验失败');
    }
    // Revalidate the stored physical identity and ownership even when absent.
    final String original = entry['originalPath'] as String;
    // Pending manifests must remain directly inside a recording scope.
    final List<Directory> owners = kind == 'pending'
        ? recordings.map((scope) => scope.directory).toList()
        : audioRoots;
    // Confirm the original path resolves to its recorded identity.
    final String identity = await NoteFilePaths.ownedFile(
      original,
      owners,
      directChild: kind == 'pending',
      allowMissing: true,
    );
    if (!p.equals(identity, entry['identity'] as String)) {
      throw StateError('恢复原件身份不匹配');
    }
    // A missing unprotected original is allowed only in explicit recovery.
    if (await FileSystemEntity.type(identity, followLinks: false) ==
        FileSystemEntityType.notFound) {
      if (entry['protected'] == true) throw StateError('受保护原件已缺失');
      continue;
    }
    await NoteFilePaths.file(original);
    if (await File(identity).length() != entry['byteSize'] ||
        (await sha256.bind(File(identity).openRead()).first).toString() !=
            entry['sha256']) {
      throw StateError('恢复原件与备份不一致');
    }
  }
  // A path already absent at backup time must not acquire an unbacked file.
  for (final String rawPath
      in (state['missingMarkerPendingPaths'] as List).cast<String>()) {
    // Revalidate ownership before checking whether a new entry appeared.
    final String path = await NoteFilePaths.ownedFile(
      rawPath,
      audioRoots,
      allowMissing: true,
    );
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw StateError('先前缺失的原音已重建，拒绝恢复');
    }
  }
  // The database must still have the exact non-target state from the journal.
  final SyncSnapshot snapshot = await runtime.exportSnapshot();
  // Only these tables were authorized for the original cleanup.
  const Set<String> targets = {
    'note_entries',
    'note_versions',
    'note_audio_segments',
    'note_audio_local_files',
  };
  if ([
    'note_entries',
    'note_versions',
    'note_audio_segments',
  ].any((table) => snapshot.tables[table]!.isNotEmpty)) {
    throw StateError('目标笔记数据已重建，拒绝恢复');
  }
  // Current local rows must be an unchanged subset of the original rows.
  final Map<String, dynamic> originals = {
    for (final dynamic raw in state['localRows'] as List)
      (raw as Map)['id'] as String: raw,
  };
  if (originals.length != (state['localRows'] as List).length) {
    throw StateError('本机原音备份身份重复');
  }
  // Every originally recorded path must have an explicitly backed-up original.
  final Set<String> backedAudio = NoteFilePaths.identitySet();
  for (final dynamic raw in files) {
    final Map<String, dynamic> entry = (raw as Map).cast<String, dynamic>();
    if (entry['kind'] == 'audio') backedAudio.add(entry['identity'] as String);
  }
  for (final dynamic raw in originals.values) {
    // A missing local path needs no physical file backup.
    final String? path = (raw as Map)['local_path'] as String?;
    if (path != null &&
        !backedAudio.contains(
          await NoteFilePaths.file(path, allowMissing: true),
        )) {
      throw StateError('本机原音缺少对应备份');
    }
  }
  for (final Map<String, Object?> row
      in snapshot.tables['note_audio_local_files']!) {
    if (!originals.containsKey(row['id']) ||
        jsonEncode(originals[row['id']]) != jsonEncode(row)) {
      throw StateError('本机原音记录已变化，拒绝恢复');
    }
  }
  // Non-target records and all surviving queue rows must match exactly.
  final Map<String, Object?> business = {
    for (final MapEntry<String, List<Map<String, Object?>>> table
        in snapshot.tables.entries)
      if (!targets.contains(table.key)) table.key: table.value,
  };
  business['device_sync_metadata'] = await runtime.powerSync.getAll(
    'SELECT * FROM device_sync_metadata ORDER BY id',
  );
  // Read the complete current queue for exact baseline comparison.
  final List<Map<String, Object?>> queue = await runtime.powerSync.getAll(
    'SELECT * FROM ps_crud ORDER BY id',
  );
  if (jsonEncode(business) != jsonEncode(state['protectedBusiness']) ||
      jsonEncode(queue) != jsonEncode(state['otherQueue'])) {
    throw StateError('其他业务或上传队列已变化，拒绝恢复');
  }
  await _verifyResumeMarkers(recordings, audioRoots, state);
}

/// Recheck every current marker and reject unplanned protection or pending data.
Future<void> _verifyResumeMarkers(
  List<NoteCleanupRecordingScope> recordings,
  List<Directory> audioRoots,
  Map<String, dynamic> state,
) async {
  // The original protection set remains authoritative for the retry.
  final Set<String> protected = await NoteFilePaths.identities(
    (state['protectedPaths'] as List).cast<String>(),
  );
  // Previously backed-up audio and known absent retry paths are the only targets.
  final Set<String> knownAudio = NoteFilePaths.identitySet();
  // Pending manifest identities are separately tracked for recreation detection.
  final Set<String> knownManifests = NoteFilePaths.identitySet();
  for (final dynamic raw in state['files'] as List) {
    // File identity was already checked against both original and backup bytes.
    final Map<String, dynamic> entry = (raw as Map).cast<String, dynamic>();
    if (entry['kind'] == 'audio') {
      knownAudio.add(entry['identity'] as String);
      if ((entry['protected'] == true) !=
          protected.contains(entry['identity'])) {
        throw StateError('备份保护关系不一致');
      }
    } else if (entry['kind'] == 'pending') {
      knownManifests.add(entry['identity'] as String);
    } else {
      throw StateError('备份文件类型无效');
    }
  }
  knownAudio.addAll(
    await NoteFilePaths.identities(
      (state['markerPendingPaths'] as List).cast<String>(),
    ),
  );
  // A marker is permitted only for a note owner captured at preflight.
  final Set<String> owners = (state['noteIds'] as List).cast<String>().toSet();
  for (final NoteCleanupRecordingScope scope in recordings) {
    if (await FileSystemEntity.type(scope.directory.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      continue;
    }
    await for (final FileSystemEntity entry in scope.directory.list(
      followLinks: false,
    )) {
      if (!entry.path.endsWith('.pending.json') &&
          !entry.path.endsWith('.deleted.json')) {
        continue;
      }
      // Do not read or trust links, directories or files outside the scope.
      final String identity = await NoteFilePaths.ownedFile(entry.path, [
        scope.directory,
      ], directChild: true);
      if (entry.path.endsWith('.pending.json')) {
        if (!knownManifests.contains(identity)) throw StateError('检测到新待恢复清单');
        continue;
      }
      // Validate the owner-derived marker identity and its protection list.
      final Map<String, dynamic> marker = jsonDecode(
        await File(entry.path).readAsString(),
      ) as Map<String, dynamic>;
      // The marker owner determines its only permitted filename.
      final String owner = marker['noteId'] as String;
      // Derive the same stable name as the recording service.
      final String expected =
          '${const Uuid().v5(Namespace.url.value, 'notes-deleted:$owner')}.deleted.json';
      if (!owners.contains(owner) ||
          p.basename(entry.path) != expected ||
          marker['protectedPaths'] is! List ||
          (marker['pendingPaths'] != null && marker['pendingPaths'] is! List)) {
        throw StateError('删除标记不属于恢复计划');
      }
      // Normalize every current marker protection before comparison.
      final Set<String> currentProtection = await NoteFilePaths.identities(
        (marker['protectedPaths'] as List).cast<String>(),
      );
      if (currentProtection.any((path) => !protected.contains(path))) {
        throw StateError('删除标记保护关系已变化');
      }
      for (final String rawPath
          in (marker['pendingPaths'] as List? ?? const []).cast<String>()) {
        // Each retry original must match both its recording scope and root.
        final String path = await NoteFilePaths.ownedFile(
          rawPath,
          [scope.directory],
          directChild: true,
          allowMissing: true,
        );
        await NoteFilePaths.ownedFile(rawPath, audioRoots, allowMissing: true);
        if (!knownAudio.contains(path)) throw StateError('删除标记包含计划外原音');
      }
    }
  }
}

/// Finish file work using only the journaled owners and local audio IDs.
Future<NoteTestCleanupReport> _finishNoteCleanup({
  required OmniSyncRuntime runtime,
  required List<NoteCleanupRecordingScope> recordings,
  required List<Directory> audioRoots,
  required Directory backup,
  required Map<String, dynamic> state,
}) async {
  await _verifyCleanupBaseline(runtime, recordings, audioRoots, backup, state);
  // Every recorder receives the same persisted non-target protection paths.
  final Set<String> protected = (state['protectedPaths'] as List)
      .cast<String>()
      .toSet();
  // Scope lists remain recorded so malformed journals cannot widen the plan.
  final List<dynamic> scopeOwners = state['recordingOwners'] as List;
  if (scopeOwners.length != recordings.length) throw StateError('恢复录音范围无效');
  for (int i = 0; i < recordings.length; i++) {
    // Every verified scope was originally authorized for all target owners.
    final Iterable<String> owners = (state['noteIds'] as List).cast<String>();
    for (final String owner in owners) {
      await recordings[i].recorder.discardPendingForNote(
        owner,
        protectedPaths: protected,
      );
    }
  }
  // Limit metadata and file cleanup to the original local file IDs.
  final Set<String> ids = {
    for (final dynamic raw in state['localRows'] as List)
      (raw as Map)['id'] as String,
  };
  await NoteRepository(runtime.database)
      .purgeOrphanFiles(additionalProtectedPaths: protected, localFileIds: ids);
  await _verifyCleanupBaseline(runtime, recordings, audioRoots, backup, state);
  await _verifyCleanupCompletion(runtime, audioRoots, backup, state);
  state['phase'] = 'completed';
  await _writeCleanupJournal(File(p.join(backup.path, 'manifest.json')), state);
  return _cleanupReport(backup, state);
}

/// Require every planned file and local metadata row to be fully handled.
Future<void> _verifyCleanupCompletion(
  OmniSyncRuntime runtime,
  List<Directory> audioRoots,
  Directory backup,
  Map<String, dynamic> state,
) async {
  for (final dynamic raw in state['files'] as List) {
    // The baseline records exactly which original must remain protected.
    final Map<String, dynamic> entry = (raw as Map).cast<String, dynamic>();
    // Completion compares the physical identity recorded at backup time.
    final String path = entry['identity'] as String;
    if (entry['protected'] == true && entry['kind'] == 'audio') {
      await NoteFilePaths.ownedFile(path, audioRoots);
      if (await File(path).length() != entry['byteSize'] ||
          (await sha256.bind(File(path).openRead()).first).toString() !=
              entry['sha256']) {
        throw StateError('受保护原音已变化');
      }
    } else if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw FileSystemException(
        'Cleanup completion/original-file: ${p.basename(path)}',
      );
    }
  }
  // Completion requires all original local rows to be gone, too.
  final SyncSnapshot after = await runtime.exportSnapshot();
  if ([
    'note_entries',
    'note_versions',
    'note_audio_segments',
    'note_audio_local_files',
  ].any((table) => after.tables[table]!.isNotEmpty)) {
    throw StateError('清理后仍有目标记录');
  }
  // Preserve the same non-target business and queue baseline after all work.
  const Set<String> targets = {
    'note_entries',
    'note_versions',
    'note_audio_segments',
    'note_audio_local_files',
  };
  // Rebuild the non-target business snapshot for exact comparison.
  final Map<String, Object?> business = {
    for (final MapEntry<String, List<Map<String, Object?>>> table
        in after.tables.entries)
      if (!targets.contains(table.key)) table.key: table.value,
  };
  business['device_sync_metadata'] = await runtime.powerSync.getAll(
    'SELECT * FROM device_sync_metadata ORDER BY id',
  );
  // Preserve all original non-note queue entries and payloads.
  final List<Map<String, Object?>> queue = await runtime.powerSync.getAll(
    'SELECT * FROM ps_crud ORDER BY id',
  );
  if (jsonEncode(business) != jsonEncode(state['protectedBusiness']) ||
      jsonEncode(queue) != jsonEncode(state['otherQueue'])) {
    throw StateError('清理后完整性比对失败');
  }
}

/// Restore the original counts without exposing protected business content.
NoteTestCleanupReport _cleanupReport(
  Directory backup,
  Map<String, dynamic> state,
) {
  // The counts are part of the original, versioned backup manifest.
  final Map<String, dynamic> counts = (state['counts'] as Map)
      .cast<String, dynamic>();
  return NoteTestCleanupReport(
    executed: true,
    notes: counts['notes'] as int,
    audioSegments: counts['audioSegments'] as int,
    localFiles: counts['localFiles'] as int,
    pendingManifests: counts['pendingManifests'] as int,
    noteQueueRows: counts['noteQueueRows'] as int,
    backupPath: backup.path,
  );
}

/// 一次性本机维护；只在用户已明确声明本机笔记均为测试数据时使用。
Future<NoteTestCleanupReport> clearNoteTestData({
  required OmniSyncRuntime runtime,
  required List<NoteCleanupRecordingScope> recordings,
  required List<Directory> audioRoots,
  required Directory backupParent,
  // 只有显式opt-in才允许实际清理。
  bool execute = false,
  Directory? resumeFrom,
}) async {
  if (runtime.powerSync.connected ||
      recordings.any((scope) => scope.recorder.state.isActive)) {
    throw StateError('同步或录音仍在运行，拒绝维护');
  }
  if (resumeFrom != null) {
    if (!execute) throw StateError('恢复清理必须显式启用执行');
    return _resumeNoteCleanup(
      runtime: runtime,
      recordings: recordings,
      audioRoots: audioRoots,
      backupParent: backupParent,
      backup: resumeFrom,
    );
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
          protectedPaths.add(value);
        }
      }
    }
  }
  // 全部将删或受引用保护的文件先验证；预检失败不得删除任何数据。
  final Set<String> filePaths = NoteFilePaths.identitySet();
  // Preserve original spelling in backups while deduplicating physical files.
  final Map<String, String> originalPaths = HashMap(
    equals: p.equals,
    hashCode: p.hash,
  );
  // Track each local row's validated identity before touching business data.
  final Map<String, String> localIdentities = {};
  // 当前业务或队列的原始数据行。
  for (final Map<String, Object?> row in local) {
    // 当前本机文件状态声明的原音位置。
    final String? path = row['local_path'] as String?;
    if (path != null) {
      // 已确认属于授权音频根的真实路径。
      final String owned = await _ownedFile(path, audioRoots);
      filePaths.add(owned);
      originalPaths.putIfAbsent(owned, () => path);
      localIdentities[row['id']! as String] = owned;
    }
  }
  // 当前数据源尚未确认的恢复清单。
  final List<File> manifests = [];
  // Keep preexisting marker retry paths, including already absent originals.
  final List<String> markerPendingPaths = [];
  // Paths absent before backup cannot later be treated as backed-up originals.
  final List<String> missingMarkerPendingPaths = [];
  // Conflicting pending owners require protection or manual resolution before SQL.
  final Map<String, Set<String>> pendingOwners = HashMap(
    equals: p.equals,
    hashCode: p.hash,
  );
  // Remember which owners were actually present in each recording scope.
  final List<Set<String>> recordingOwners = [];
  // 当前录音目录及其专属删除服务。
  for (final NoteCleanupRecordingScope scope in recordings) {
    // Owners may be retried only in this exact authorized scope.
    final Set<String> owners = <String>{};
    recordingOwners.add(owners);
    // A scope must authorize the same physical directory the service will use.
    final String expectedDirectory = await NoteFilePaths.prospectiveDirectory(
      scope.directory,
    );
    if (!p.equals(
      expectedDirectory,
      await scope.recorder.recordingDirectoryIdentity(),
    )) {
      throw FileSystemException(
        'Cleanup preflight/recording-scope: ${p.basename(scope.directory.path)}',
      );
    }
    if (await FileSystemEntity.type(scope.directory.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      continue;
    }
    // 当前恢复目录或测试隔离目录。
    final String directory = await NoteFilePaths.directory(scope.directory);
    await for (final FileSystemEntity entry in scope.directory.list(
      followLinks: false,
    )) {
      if (!entry.path.endsWith('.pending.json') &&
          !entry.path.endsWith('.deleted.json')) {
        continue;
      }
      await NoteFilePaths.ownedFile(entry.path, [
        Directory(directory),
      ], directChild: true);
      // 当前恢复清单及其归属信息。
      final Map<String, dynamic> manifest = jsonDecode(
        await File(entry.path).readAsString(),
      ) as Map<String, dynamic>;
      // 原音绑定的笔记身份。
      final Object? noteId = manifest['noteId'];
      if (noteId is! String || noteId.isEmpty) {
        throw FileSystemException(
          'Cleanup preflight/manifest-owner: ${p.basename(entry.path)}',
        );
      }
      owners.add(noteId);
      if (entry.path.endsWith('.deleted.json')) {
        // Old markers keep their format, owner identity and original path spelling.
        final String expected =
            '${const Uuid().v5(Namespace.url.value, 'notes-deleted:$noteId')}.deleted.json';
        if (p.basename(entry.path) != expected ||
            manifest['protectedPaths'] is! List ||
            (manifest['pendingPaths'] != null &&
                manifest['pendingPaths'] is! List)) {
          throw FileSystemException(
            'Cleanup preflight/deletion-marker: ${p.basename(entry.path)}',
          );
        }
        // Protection must be decoded before either SQL or file deletion.
        for (final Object? path in manifest['protectedPaths'] as List) {
          if (path is! String) {
            throw FileSystemException(
              'Cleanup preflight/protected-path: ${p.basename(entry.path)}',
            );
          }
          protectedPaths.add(path);
        }
        // Already absent retry files are complete; surviving originals need backup.
        for (final Object? path
            in manifest['pendingPaths'] as List? ?? const []) {
          if (path is! String) {
            throw FileSystemException(
              'Cleanup preflight/retry-path: ${p.basename(entry.path)}',
            );
          }
          // Both the source scope and the configured roots authorize each retry.
          final String owned = await NoteFilePaths.ownedFile(
            path,
            [Directory(directory)],
            directChild: true,
            allowMissing: true,
          );
          await NoteFilePaths.ownedFile(path, audioRoots, allowMissing: true);
          markerPendingPaths.add(path);
          if (await File(owned).exists()) {
            filePaths.add(owned);
            originalPaths.putIfAbsent(owned, () => path);
          } else {
            missingMarkerPendingPaths.add(path);
          }
        }
        ids.add(noteId);
        continue;
      }
      // 原始文件或恢复清单声明的文件位置。
      final Object? original = manifest['path'];
      if (original is! String ||
          manifest['id'] is! String ||
          manifest['id'] !=
              p.basename(entry.path).replaceFirst('.pending.json', '')) {
        throw FileSystemException(
          'Cleanup preflight/pending-manifest: ${p.basename(entry.path)}',
        );
      }
      await NoteFilePaths.ownedFile(original, [
        Directory(directory),
      ], directChild: true);
      ids.add(noteId);
      manifests.add(File(entry.path));
      // 已确认属于授权音频根的真实路径。
      final String owned = await _ownedFile(original, audioRoots);
      filePaths.add(owned);
      originalPaths.putIfAbsent(owned, () => original);
      pendingOwners.putIfAbsent(owned, () => <String>{}).add(noteId);
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
  // Keep this maintenance operation within its supported table whitelist.
  if (['note_images', 'note_local_drafts'].any(
    (table) => before.tables[table]!.any((row) => ids.contains(row['note_id'])),
  )) {
    throw StateError('清理目标含图片或本机草稿，超出本工具原音清理范围');
  }
  // Canonical protection is separate from paths persisted in old manifests.
  final Set<String> protectedIdentities = await NoteFilePaths.identities(
    protectedPaths,
  );
  // Do not create mutually protective deletion markers after committing SQL.
  for (final MapEntry<String, Set<String>> entry in pendingOwners.entries) {
    if (entry.value.length > 1 && !protectedIdentities.contains(entry.key)) {
      throw FileSystemException(
        'Cleanup preflight/shared-pending-owner: ${p.basename(entry.key)}',
      );
    }
  }
  // Validate the real backup boundary without creating any missing directories.
  final String parent = await NoteFilePaths.prospectiveDirectory(backupParent);
  // Compare physical roots so short aliases and redirected ancestors cannot bypass it.
  for (final Directory root in audioRoots) {
    // An absent root cannot contain any existing candidate but still has a boundary.
    final String actual = await NoteFilePaths.prospectiveDirectory(root);
    if (p.equals(actual, parent) || p.isWithin(actual, parent)) {
      throw StateError('备份目录不能位于原音清理目录');
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
  // Record the exact live database identity before making a backup.
  final String databaseIdentity = await NoteFilePaths.file(
    runtime.databasePath,
  );
  // Capture every authorized root and recorder scope without creating them.
  final List<String> rootIdentities = [];
  for (final Directory root in audioRoots) {
    rootIdentities.add(await NoteFilePaths.prospectiveDirectory(root));
  }
  // Scope ordering is stable and bound to the supplied recorder instances.
  final List<String> recordingIdentities = [];
  for (final NoteCleanupRecordingScope scope in recordings) {
    recordingIdentities.add(
      await NoteFilePaths.prospectiveDirectory(scope.directory),
    );
  }
  await Directory(parent).create(recursive: true);
  // 本次唯一备份目录或真实备份运行时。
  final Directory backup = await Directory(
    p.join(await NoteFilePaths.directory(Directory(parent)), const Uuid().v4()),
  ).create();
  // 记录备份、SQL提交及文件完成阶段的清单。
  final File journal = File(p.join(backup.path, 'manifest.json'));
  // SQLite真实一致性备份包含业务、原始队列和本机元数据，不使用裸文件复制。
  await runtime.powerSync.execute('VACUUM INTO ?', [
    p.join(backup.path, 'database.sqlite'),
  ]);
  // Record the database backup digest independently of the live database.
  final File databaseBackup = File(p.join(backup.path, 'database.sqlite'));
  // The journal must detect truncation or later replacement of the backup.
  final Map<String, Object?> databaseBackupMetadata = {
    'byteSize': await databaseBackup.length(),
    'sha256': (await sha256.bind(databaseBackup.openRead()).first).toString(),
  };
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
      'originalPath': originalPaths[original] ?? original,
      'identity': await NoteFilePaths.file(original),
      'kind': manifests.any((file) => p.equals(file.path, original))
          ? 'pending'
          : 'audio',
      'backupPath': copy.path,
      'byteSize': await copy.length(),
      'sha256': (await sha256.bind(copy.openRead()).first).toString(),
      'protected': protectedIdentities.contains(original),
    });
  }
  // Record a complete baseline so explicit recovery never guesses after failure.
  final Map<String, Object?> journalState = {
    'schemaVersion': 1,
    'phase': 'backed-up',
    'databasePath': runtime.databasePath,
    'databaseIdentity': databaseIdentity,
    'databaseBackup': databaseBackupMetadata,
    'audioRootIdentities': rootIdentities,
    'recordingIdentities': recordingIdentities,
    'recordingOwners': [
      for (final Set<String> owners in recordingOwners) owners.toList(),
    ],
    'noteIds': ids.toList(),
    'localRows': local,
    'protectedBusiness': protectedBusiness,
    'otherQueue': otherQueue,
    'protectedPaths': protectedPaths.toList(),
    'markerPendingPaths': markerPendingPaths,
    'missingMarkerPendingPaths': missingMarkerPendingPaths,
    'files': copies,
    'counts': {
      'notes': preview.notes,
      'audioSegments': preview.audioSegments,
      'localFiles': preview.localFiles,
      'pendingManifests': preview.pendingManifests,
      'noteQueueRows': preview.noteQueueRows,
    },
  };
  await _writeCleanupJournal(journal, journalState);
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
      if (protectedIdentities.contains(localIdentities[row['id']])) {
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
  journalState['phase'] = 'database-cleaned';
  await _writeCleanupJournal(journal, journalState);
  return _finishNoteCleanup(
    runtime: runtime,
    recordings: recordings,
    audioRoots: audioRoots,
    backup: backup,
    state: journalState,
  );
}
