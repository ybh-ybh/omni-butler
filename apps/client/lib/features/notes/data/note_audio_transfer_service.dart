import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/notes/data/note_repository.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// 原音传输与异步转写；供应商由后端能力决定，客户端不持有供应商密钥。
class NoteAudioTransferService {
  /// 固定这一代数据库。
  final AppDatabase database;

  /// 固定这一代已授权设备会话。
  final AuthRepository auth;

  /// 正在组词或尚未保存的人工输入禁止自动填入。
  final bool Function(String) hasUnpersistedEdits;

  /// 来源代次，旧响应不得写入新数据源。
  late final int _generation = auth.sessionGeneration;

  /// 自动轮询时钟。
  Timer? _timer;

  /// 正在运行的任务。
  Future<void>? _running;

  /// 同步关闭或迁移的停止标记。
  bool _stopped = false;

  /// 对用户可见的能力和传输说明。
  String status = '等待连接';

  /// 创建固定会话传输器。
  NoteAudioTransferService(
    this.database,
    this.auth, {
    bool Function(String)? hasUnpersistedEdits,
  }) : hasUnpersistedEdits = hasUnpersistedEdits ?? ((_) => false);

  /// 启动自动传输，不主动替用户授权供应商。
  void start() {
    _timer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(tick()),
    );
    unawaited(tick());
  }

  /// 等待在途请求，维护时不能把旧响应写回新库。
  Future<void> stop() async {
    _stopped = true;
    _timer?.cancel();
    await _running;
  }

  /// 一次串行传输轮次。
  Future<void> tick() async {
    if (_stopped || _running != null) return;
    _running = _tick();
    try {
      await _running;
    } finally {
      _running = null;
    }
  }

  /// 仍然绑定同一有效会话才允许落库。
  bool get _active => !_stopped && auth.sessionGeneration == _generation;

  /// 按稳定段顺序同步；每个错误分别记录，不回滚正文。
  Future<void> _tick() async {
    try {
      // 先确认协议和设备身份。
      await auth.ensureSyncSchemaForGeneration(_generation);
      // 服务器独立音频能力。
      final Response<Map<String, dynamic>> capabilities = await auth
          .authorizedRequestForGeneration(
            _generation,
            'GET',
            '/notes/audio/capabilities',
          );
      if (!_active) return;
      // 元数据包括回收站音频，保留期内仍需可回听。
      final List<NoteAudioSegmentRecord> segments = await database
          .select(database.noteAudioSegments)
          .get();
      segments.sort((left, right) => left.sortOrder.compareTo(right.sortOrder));
      for (final NoteAudioSegmentRecord segment in segments) {
        if (!_active) return;
        try {
          await _transfer(segment, capabilities.data ?? {});
        } catch (failure) {
          if (!_active) return;
          await database
              .into(database.noteAudioLocalFiles)
              .insertOnConflictUpdate(
                NoteAudioLocalFilesCompanion(
                  id: Value(segment.id),
                  lastError: Value('$failure'),
                ),
              );
        }
      }
      // 乱序结果只按录音顺序填入仍未修改的位置。
      for (final String noteId
          in segments.map((segment) => segment.noteId).toSet()) {
        if (!_active) return;
        if (!hasUnpersistedEdits(noteId)) {
          await NoteRepository(database).insertReadyTranscripts(noteId);
        }
      }
      status = '原音同步已检查';
    } catch (failure) {
      status = '$failure';
    }
  }

  /// 上传或下载均核验元数据，识别请求复用已持久化操作身份。
  Future<void> _transfer(
    NoteAudioSegmentRecord segment,
    Map<String, dynamic> capabilities,
  ) async {
    // 本机对应状态。
    NoteAudioLocalFileRecord? local = await (database.select(
      database.noteAudioLocalFiles,
    )..where((table) => table.id.equals(segment.id))).getSingleOrNull();
    // 检查当前文件可用性。
    File? file = local?.localPath == null ? null : File(local!.localPath!);
    if (file == null || !await file.exists()) {
      // 第二设备或缓存缺失时下载原音，明确校验实际文件体。
      final Response<List<int>> response = await auth
          .authorizedRequestForGeneration<List<int>>(
            _generation,
            'GET',
            '/notes/audio/${segment.id}/file',
            responseType: ResponseType.bytes,
          );
      if (!_active) return;
      // 长音频落盘目录。
      final session = await auth.loadSession();
      if (!_active || session == null) return;
      // 来源与内容身份共同隔离；同 ID 不同服务器不能覆盖旧备份原件。
      final String sourceKey = sha256
          .convert(utf8.encode('${session.apiBaseUrl}/${session.identity.id}'))
          .toString();
      final Directory directory = Directory(
        p.join(
          (await getApplicationSupportDirectory()).path,
          'notes',
          'cache',
          sourceKey,
        ),
      );
      await directory.create(recursive: true);
      // 下载先写临时文件，校验成功再原子改名。
      final File temporary = File(
        p.join(directory.path, '${segment.id}.${const Uuid().v4()}.download'),
      );
      await temporary.writeAsBytes(response.data!, flush: true);
      try {
        await _verify(temporary, segment);
      } catch (_) {
        // 失败下载不能积累长音频临时文件，更不能替换已有原件。
        if (await temporary.exists()) await temporary.delete();
        rethrow;
      }
      if (!_active) {
        await temporary.delete();
        return;
      }
      file = await temporary.rename(
        p.join(directory.path, '${segment.id}.${segment.sha256}.wav'),
      );
      if (!_active) return;
      await database
          .into(database.noteAudioLocalFiles)
          .insertOnConflictUpdate(
            NoteAudioLocalFilesCompanion(
              id: Value(segment.id),
              localPath: Value(file.path),
              uploadState: const Value('synced'),
              lastError: const Value(null),
            ),
          );
    } else {
      try {
        await _verify(file, segment);
      } catch (_) {
        if (_active && local?.uploadState == 'synced') {
          // 已确认服务器原件存在时，损坏缓存下一轮重新下载；未上传原音仍留待备份恢复。
          await (database.update(
            database.noteAudioLocalFiles,
          )..where((table) => table.id.equals(segment.id))).write(
            const NoteAudioLocalFilesCompanion(localPath: Value(null)),
          );
        }
        rethrow;
      }
      if (!_active) return;
      if (local?.uploadState != 'synced') {
        // 含文件体的 multipart 上传与笔记元数据同步分别确认。
        await auth.authorizedRequestForGeneration(
          _generation,
          'PUT',
          '/notes/audio/${segment.id}',
          data: FormData.fromMap({
            'file': await MultipartFile.fromFile(
              file.path,
              filename: '${segment.id}.wav',
            ),
            'noteId': segment.noteId,
            'durationMs': segment.durationMs.toString(),
            'sha256': segment.sha256,
          }),
        );
        if (!_active) return;
        await (database.update(
          database.noteAudioLocalFiles,
        )..where((table) => table.id.equals(segment.id))).write(
          const NoteAudioLocalFilesCompanion(
            uploadState: Value('synced'),
            lastError: Value(null),
          ),
        );
      }
    }
    // 文件同步后读取最新授权，撤回不能被旧循环覆盖。
    local = await (database.select(
      database.noteAudioLocalFiles,
    )..where((table) => table.id.equals(segment.id))).getSingleOrNull();
    if (local == null || !_active) return;
    if (!local.consent) {
      if (local.recognitionState == 'cancelPending') {
        await auth.authorizedRequestForGeneration(
          _generation,
          'DELETE',
          '/notes/audio/${segment.id}/recognitions/current',
        );
        if (!_active) return;
        await _recognitionState(
          segment.id,
          'cancelled',
          expectedId: local.recognitionId,
          expectedConsent: false,
        );
      }
      return;
    }
    // 上传期间主记录可能已在其他页面删除，提交付费任务前重新核实。
    final NoteEntryRecord? activeNote = await NoteRepository(database)
        .find(segment.noteId);
    final NoteAudioSegmentRecord? activeSegment = await (database.select(
      database.noteAudioSegments,
    )..where((table) => table.id.equals(segment.id))).getSingleOrNull();
    if (activeNote == null ||
        activeNote.deletedAt != null ||
        activeSegment == null ||
        activeSegment.deletedAt != null ||
        local.recognitionState == 'succeeded' ||
        local.recognitionState == 'failed') {
      return;
    }
    // 操作身份先于网络持久化，响应丢失后重复同身份无重复付费。
    final String operationId = local.recognitionId ?? const Uuid().v4();
    if (local.recognitionId == null) {
      await (database.update(
        database.noteAudioLocalFiles,
      )..where((table) => table.id.equals(segment.id))).write(
        NoteAudioLocalFilesCompanion(
          recognitionId: Value(operationId),
          recognitionState: const Value('queued'),
        ),
      );
    }
    // 重放原操作，不以每轮轮询创建新供应商任务。
    final Response<Map<String, dynamic>>? recognized =
        local.recognitionState == 'submissionUnknown'
        ? null
        : await auth.authorizedRequestForGeneration(
            _generation,
            'POST',
            '/notes/audio/${segment.id}/recognitions',
            data: {'operationId': operationId, 'consent': true},
          );
    if (!_active) return;
    // 服务端可能已由另一设备启动同段任务，接受实际任务身份后再轮询。
    final String acceptedId = recognized?.data?['id'] as String? ?? operationId;
    if (acceptedId != operationId) {
      await (database.update(database.noteAudioLocalFiles)..where(
            (table) =>
                table.id.equals(segment.id) &
                table.recognitionId.equals(operationId) &
                table.consent.equals(true),
          ))
          .write(
            NoteAudioLocalFilesCompanion(recognitionId: Value(acceptedId)),
          );
    }
    // 查询系统持久任务，不直接轮询厂商也不涉及厂商身份。
    final Response<Map<String, dynamic>> polled = await auth
        .authorizedRequestForGeneration(
          _generation,
          'GET',
          '/notes/audio/${segment.id}/recognitions/current',
        );
    if (!_active) return;
    // 查询可能短暂不存在，仍采用重放回执。
    final Map<String, dynamic> result = recognized?.data ?? polled.data ?? {};
    final bool accepted = await _recognitionState(
      segment.id,
      result['status'] as String? ?? 'processing',
      error: result['errorCode'] as String?,
      expectedId: acceptedId,
      expectedConsent: true,
    );
    if (!accepted) return;
    if (result['status'] == 'succeeded' && result['transcript'] is String) {
      // 回写前再次验证未删除和授权，迟到结果不复活原记录。
      final NoteEntryRecord? note = await NoteRepository(database)
          .find(segment.noteId);
      final NoteAudioLocalFileRecord? currentLocal = await (database.select(
        database.noteAudioLocalFiles,
      )..where((table) => table.id.equals(segment.id))).getSingleOrNull();
      if (note == null ||
          note.deletedAt != null ||
          currentLocal?.consent != true ||
          !_active) {
        return;
      }
      await database.transaction(() async {
        // 与授权撤回和原文变化串行检查，第二次结果独立保留。
        final NoteAudioSegmentRecord? latest = await (database.select(
          database.noteAudioSegments,
        )..where((table) => table.id.equals(segment.id))).getSingleOrNull();
        final NoteAudioLocalFileRecord? permitted = await (database.select(
          database.noteAudioLocalFiles,
        )..where((table) => table.id.equals(segment.id))).getSingleOrNull();
        if (!_active ||
            latest == null ||
            latest.deletedAt != null ||
            permitted?.consent != true ||
            permitted?.recognitionId != acceptedId) {
          return;
        }
        // 共享原文以服务端明确返回的首次结果为准，不能用本机尚未下行推断为空。
        final String text = result['transcript'] as String;
        final String? canonical = result.containsKey('canonicalTranscript')
            ? result['canonicalTranscript'] as String?
            : latest.transcript ?? text;
        if (canonical != null && latest.transcript != canonical) {
          await (database.update(
            database.noteAudioSegments,
          )..where((table) => table.id.equals(segment.id))).write(
            NoteAudioSegmentsCompanion(
              transcript: Value(canonical),
              updatedAt: Value(DateTime.now()),
            ),
          );
        }
        if (canonical != text) {
          await (database.update(
            database.noteAudioLocalFiles,
          )..where((table) => table.id.equals(segment.id))).write(
            NoteAudioLocalFilesCompanion(candidateTranscript: Value(text)),
          );
        }
      });
    }
  }

  /// SHA 与长度校验失败不得宣称文件同步成功。
  Future<void> _verify(File file, NoteAudioSegmentRecord segment) async {
    if (await file.length() != segment.byteSize ||
        (await sha256.bind(file.openRead()).first).toString() !=
            segment.sha256) {
      throw const FormatException('原音校验失败，请重新下载或恢复备份');
    }
  }

  /// 持久化识别状态且不改人工正文。
  Future<bool> _recognitionState(
    String id,
    String status, {
    String? error,
    required String? expectedId,
    required bool expectedConsent,
  }) async {
    if (!_active) return false;
    final int changed =
        await (database.update(database.noteAudioLocalFiles)..where(
              (table) =>
                  table.id.equals(id) &
                  table.consent.equals(expectedConsent) &
                  (expectedId == null
                      ? table.recognitionId.isNull()
                      : table.recognitionId.equals(expectedId)) &
                  (expectedConsent
                      ? table.recognitionState.equals('cancelPending').not()
                      : table.recognitionState.equals('cancelPending')),
            ))
            .write(
              NoteAudioLocalFilesCompanion(
                recognitionState: Value(status),
                lastError: Value(error),
              ),
            );
    return changed > 0;
  }
}
