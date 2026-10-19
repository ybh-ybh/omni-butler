import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/notes/data/note_repository.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// 网络错误只展示固定说明，兼容已有错误记录，不显示请求地址或底层异常正文。
String noteAudioTransferErrorMessage(Object failure) {
  if (failure is DioException) {
    return switch (failure.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout => '连接服务器超时，稍后会自动重试连接；原音和已保存文字仍保留。',
      DioExceptionType.badCertificate => '服务器证书验证失败，请检查 HTTPS 配置。',
      DioExceptionType.badResponse =>
        failure.response?.statusCode == null
            ? '服务器请求失败，请检查服务器状态。'
            : '服务器请求失败（HTTP ${failure.response!.statusCode}），请检查服务器状态。',
      _ => '服务器连接中断，稍后会自动重试连接；原音和已保存文字仍保留。',
    };
  }
  if (failure is String) {
    if (failure.startsWith('DioException') ||
        failure.startsWith('HttpException') ||
        failure.startsWith('SocketException')) {
      return '服务器连接中断，稍后会自动重试连接；原音和已保存文字仍保留。';
    }
    return failure;
  }
  if (failure is ApiFailure) return failure.message;
  if (failure is FormatException) return failure.message.toString();
  if (failure is FileSystemException) return '原音文件读写失败，请检查文件或存储空间后重试。';
  if (failure is StateError) return failure.message.toString();
  return '原音同步或转写处理失败，请稍后重试。';
}

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
      // 先冻结所有首次结果的位置，避免共享原文先下行而绕过整理判定。
      await database.customStatement('''
        UPDATE note_audio_local_files SET polish_state = 'waiting'
        WHERE consent = 1 AND recognition_state NOT IN ('failed', 'cancelled', 'cancelPending')
          AND polish_recognition_id IS NULL AND polish_state = 'disabled'
          AND inserted_revision LIKE 'waiting:%'
      ''');
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
                  lastError: Value(noteAudioTransferErrorMessage(failure)),
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
          // 失败回退后的重试只替换精确基线，绝不再次追加同一段原文。
          for (final NoteAudioSegmentRecord segment in segments.where(
            (item) => item.noteId == noteId,
          )) {
            if (!_active) return;
            await NoteRepository(database).adoptPolishedTranscript(segment.id);
          }
        }
      }
      status = '原音同步已检查';
    } catch (failure) {
      status = noteAudioTransferErrorMessage(failure);
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
    // 撤回与文件可用性无关，损坏或缺失原音也必须先停止后端付费工作。
    if (local?.consent == false && local?.recognitionState == 'cancelPending') {
      await _deliverCancellation(segment.id, local!.recognitionId);
      return;
    }
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
        await _deliverCancellation(segment.id, local.recognitionId);
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
        local.recognitionState == 'failed') {
      return;
    }
    if (local.recognitionState == 'succeeded') {
      if (local.recognitionId != null) {
        await _pollPolish(segment, local.recognitionId!);
      }
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
    if (const {'failed', 'cancelled'}.contains(result['status'])) {
      // 上游失败没有待整理文本，不能永久停留在整理中。
      await (database.update(database.noteAudioLocalFiles)..where(
            (table) =>
                table.id.equals(segment.id) &
                table.recognitionId.equals(acceptedId),
          ))
          .write(
            const NoteAudioLocalFilesCompanion(polishState: Value('cancelled')),
          );
    }
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
      // ASR 终态不是整条处理链终态，仍需获取对应整理任务。
      await _pollPolish(segment, acceptedId);
    }
  }

  /// 显式重试只重做文本整理，身份先落盘，不重新识别或上传原音。
  Future<void> retryPolish(String segmentId) async {
    if (!_active) throw StateError('当前服务器连接已失效');
    await database.transaction(() async {
      // 同一事务内读取和分配身份，快速双击不会产生两次计费尝试。
      final NoteAudioLocalFileRecord? local = await (database.select(
        database.noteAudioLocalFiles,
      )..where((table) => table.id.equals(segmentId))).getSingleOrNull();
      if (!_active ||
          local?.consent != true ||
          local?.recognitionState != 'succeeded' ||
          local?.recognitionId == null) {
        throw StateError('请先完成本段语音识别并保留转写授权');
      }
      if (local!.polishOperationId != null) return;
      if (const {
        'waiting',
        'queued',
        'processing',
      }.contains(local.polishState)) {
        throw StateError('本段正在整理，请等待本次任务完成');
      }
      // 同一显式尝试在回执未知时复用身份。
      final String operationId = const Uuid().v4();
      await (database.update(database.noteAudioLocalFiles)..where(
            (table) => table.id.equals(segmentId) & table.consent.equals(true),
          ))
          .write(
            NoteAudioLocalFilesCompanion(
              polishOperationId: Value(operationId),
              polishRecognitionId: Value(local.recognitionId),
              polishState: const Value('queued'),
              polishError: const Value(null),
            ),
          );
    });
    await tick();
  }

  /// 撤回优先于任何文件请求，服务端同步取消关联整理任务。
  Future<void> _deliverCancellation(
    String segmentId,
    String? recognitionId,
  ) async {
    if (!_active) return;
    await auth.authorizedRequestForGeneration(
      _generation,
      'DELETE',
      '/notes/audio/$segmentId/recognitions/current',
    );
    if (!_active) return;
    // 网络往返期间若重新授权新任务，旧撤回不能覆盖新状态。
    final bool changed = await _recognitionState(
      segmentId,
      'cancelled',
      expectedId: recognitionId,
      expectedConsent: false,
    );
    if (!changed || !_active) return;
    await (database.update(database.noteAudioLocalFiles)..where(
          (table) =>
              table.id.equals(segmentId) &
              table.consent.equals(false) &
              table.recognitionState.equals('cancelled'),
        ))
        .write(
          const NoteAudioLocalFilesCompanion(
            polishState: Value('cancelled'),
            polishOperationId: Value(null),
          ),
        );
  }

  /// 查询原 ASR 对应的整理任务，恢复显式重试回执且校验文本来源。
  Future<void> _pollPolish(
    NoteAudioSegmentRecord segment,
    String recognitionId,
  ) async {
    if (!_active) return;
    // 固定请求前的授权和尝试身份，迟到结果不能覆盖另一次重试。
    final NoteAudioLocalFileRecord? before = await (database.select(
      database.noteAudioLocalFiles,
    )..where((table) => table.id.equals(segment.id))).getSingleOrNull();
    if (before?.consent != true || before?.recognitionId != recognitionId) {
      return;
    }
    // 有未确认的 POST 时仅重放同一个操作，其他情况均为只读查询。
    final String? operationId = before!.polishOperationId;
    late final Response<Map<String, dynamic>> response;
    try {
      response = await auth.authorizedRequestForGeneration(
        _generation,
        operationId == null ? 'GET' : 'POST',
        '/notes/audio/${segment.id}/polish',
        data: operationId == null
            ? null
            : {'operationId': operationId, 'recognitionId': recognitionId},
        queryParameters: operationId == null
            ? {'recognitionId': recognitionId}
            : null,
        preserveTransportErrors: true,
      );
    } on DioException catch (failure) {
      // 确定拒绝的重试不能形成无限自动 POST，网络未知仍保留原操作身份。
      final int? code = failure.response?.statusCode;
      if (_active &&
          operationId != null &&
          const {400, 403, 404, 409, 422}.contains(code)) {
        // 只使用应用接口的清晰错误说明，不持久化请求头或原始异常。
        final Object? body = failure.response?.data;
        final String message = body is Map && body['message'] is String
            ? body['message'] as String
            : '整理重试未获接受，请检查模型设置';
        await (database.update(database.noteAudioLocalFiles)..where(
              (table) =>
                  table.id.equals(segment.id) &
                  table.polishOperationId.equals(operationId) &
                  table.consent.equals(true),
            ))
            .write(
              NoteAudioLocalFilesCompanion(
                polishOperationId: const Value(null),
                polishState: const Value('failed'),
                polishError: Value(message),
                lastError: const Value(null),
              ),
            );
        return;
      }
      rethrow;
    }
    if (!_active) return;
    // 严格处理新协议，响应异常不得将待整理原文误判为无需整理。
    final Map<String, dynamic> result = response.data ?? {};
    if (result['recognitionId'] != recognitionId ||
        result['enabled'] is! bool ||
        !const {
          'disabled',
          'waiting',
          'queued',
          'processing',
          'succeeded',
          'failed',
          'cancelled',
          'submissionUnknown',
        }.contains(result['status'])) {
      throw const FormatException('AI 整理状态无效，请更新服务器后重试');
    }
    await database.transaction(() async {
      // 在写入结果的同一事务内复核记录与本机授权。
      final NoteAudioSegmentRecord? current = await (database.select(
        database.noteAudioSegments,
      )..where((table) => table.id.equals(segment.id))).getSingleOrNull();
      final NoteAudioLocalFileRecord? permitted = await (database.select(
        database.noteAudioLocalFiles,
      )..where((table) => table.id.equals(segment.id))).getSingleOrNull();
      final NoteEntryRecord? note = await NoteRepository(database)
          .find(segment.noteId);
      if (!_active ||
          current == null ||
          current.deletedAt != null ||
          note == null ||
          note.deletedAt != null ||
          permitted?.consent != true ||
          permitted?.recognitionId != recognitionId ||
          permitted?.polishOperationId != operationId) {
        return;
      }
      // 整理只能对应同次识别文本，不能把别段或旧任务结果写入正文。
      final String? sourceHash = result['sourceHash'] as String?;
      final String? text = result['text'] as String?;
      final bool sourceMatches =
          sourceHash != null &&
          [
            current.transcript,
            permitted!.candidateTranscript,
          ].whereType<String>().any(
            (source) =>
                sha256.convert(utf8.encode(source)).toString() == sourceHash,
          );
      // 超限或空候选不可触发任何正文变化。
      final bool validText =
          text != null && text.trim().isNotEmpty && text.length <= 20000;
      // 成功状态也必须经过内容与来源的本机核验。
      final bool invalidSuccess =
          result['status'] == 'succeeded' && (!sourceMatches || !validText);
      await (database.update(
        database.noteAudioLocalFiles,
      )..where((table) => table.id.equals(segment.id))).write(
        NoteAudioLocalFilesCompanion(
          polishId: Value(result['id'] as String?),
          polishOperationId: const Value(null),
          polishRecognitionId: Value(recognitionId),
          polishSourceHash: Value(sourceHash),
          polishState: Value(
            invalidSuccess ? 'failed' : result['status'] as String,
          ),
          polishedText: Value(invalidSuccess ? null : text),
          polishError: Value(
            invalidSuccess
                ? 'AI 整理结果与原文不匹配或内容无效'
                : result['errorCode'] as String?,
          ),
          lastError: const Value(null),
        ),
      );
    });
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
