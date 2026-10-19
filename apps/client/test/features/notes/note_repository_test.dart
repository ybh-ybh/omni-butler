import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/notes/audio/note_wav.dart';
import 'package:omni_butler/features/notes/data/note_repository.dart';

/// 延迟两个外层事务入场，让真实并发请求在同一旧状态完成校验。
class _BarrierDatabase extends AppDatabase {
  /// 仍由真实SQLite负责隔离和提交。
  _BarrierDatabase(File file) : super.forTesting(NativeDatabase(file));

  /// 测试显式启用的两次事务入场屏障。
  Completer<void>? barrier;

  /// 已到达屏障的请求数量。
  int arrivals = 0;

  /// 只阻塞前两次事务，不影响之后的嵌套save事务。
  @override
  Future<T> transaction<T>(
    Future<T> Function() action, {
    bool requireNew = false,
  }) async {
    // 固定本次事务等待的屏障。
    final Completer<void>? waiting = barrier;
    if (waiting != null && arrivals < 2) {
      arrivals++;
      if (arrivals == 2) {
        barrier = null;
        waiting.complete();
      }
      await waiting.future;
    }
    return super.transaction(action, requireNew: requireNew);
  }
}

/// 真实 SQLite 事务验证历史、原音与物理文件的生命周期。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 每例独立持久化库。
  late AppDatabase database;
  // 生产仓储。
  late NoteRepository repository;
  // 每例独立音频目录。
  late Directory directory;
  // 可播放格式的原音。
  late File audio;
  // 固定归档日的新草稿。
  const NoteDraft initial = NoteDraft(
    id: 'note',
    body: '人工正文',
    dayKey: '2026-10-11',
    baseRevision: '',
  );
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('note-repository-test-');
    database = _BarrierDatabase(File('${directory.path}/notes.sqlite'));
    repository = NoteRepository(database);
    audio = File('${directory.path}/original.wav');
    await audio.writeAsBytes([...NoteWav.header(4), 0, 0, 1, 0]);
  });
  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  /// 从正式记录构造下一次编辑，保留版本起点。
  NoteDraft next(NoteEntryRecord note, String body) => NoteDraft(
    id: note.id,
    body: body,
    dayKey: note.dayKey,
    baseRevision: note.revision,
  );

  /// 持久化真实文件体，时长独立注入以验证配额边界。
  Future<void> add(String id, int milliseconds, {NoteDraft draft = initial}) =>
      repository.addAudio(
        draft: draft,
        id: id,
        localPath: audio.path,
        durationMs: milliseconds,
        mime: 'audio/wav',
      );

  test('首次创建时刻时区不可变，修改正文日期不重写原始创建信息', () async {
    // 从其他时区恢复的真实开始时刻。
    final DateTime started = DateTime.utc(2026, 10, 10, 23, 59);
    final NoteEntryRecord created = (await repository.save(
      NoteDraft(
        id: 'created',
        body: '初次输入',
        dayKey: '2026-10-11',
        baseRevision: '',
        createdAt: started,
        creationTimezone: 'JST|+09:00',
      ),
    ))!;
    expect(created.createdAt.toUtc(), started);
    expect(created.creationTimezone, 'JST|+09:00');
    final NoteEntryRecord edited = (await repository.save(
      NoteDraft(
        id: created.id,
        body: '改过的正文',
        dayKey: '2026-10-01',
        baseRevision: created.revision,
        createdAt: DateTime.utc(2026, 10, 12),
        creationTimezone: 'UTC|+00:00',
      ),
    ))!;
    expect(edited.dayKey, '2026-10-01');
    expect(edited.createdAt.toUtc(), started);
    expect(edited.creationTimezone, 'JST|+09:00');
    // 原音段记录实际开始而非回调完成时刻。
    await repository.addAudio(
      draft: next(edited, edited.body),
      id: 'started-audio',
      localPath: audio.path,
      durationMs: 1000,
      mime: 'audio/wav',
      startedAt: started,
    );
    expect(
      (await database.select(database.noteAudioSegments).getSingle()).createdAt
          .toUtc(),
      started,
    );
  });

  test('另存回收站笔记保留原转写并独立段身份，原篇永久删除不删副本原音', () async {
    await add('original-audio', 1000);
    // 明确区分供应商原始转写、本机候选及已有授权。
    await database
        .update(database.noteAudioSegments)
        .write(const NoteAudioSegmentsCompanion(transcript: Value('供应商原始转写')));
    await database
        .update(database.noteAudioLocalFiles)
        .write(
          const NoteAudioLocalFilesCompanion(
            consent: Value(true),
            recognitionId: Value('old-recognition'),
            recognitionState: Value('ready'),
            insertedRevision: Value('old-inserted'),
            candidateTranscript: Value('重识别候选'),
          ),
        );
    final NoteEntryRecord original = (await repository.find('note'))!;
    await repository.softDelete(original.id);
    final NoteEntryRecord copy = await repository.saveAsNew(
      next(original, '另存的人工输入'),
    );
    expect(copy.id, isNot(original.id));
    expect(copy.body, '另存的人工输入');
    expect(copy.deletedAt, isNull);
    // 副本与原篇持有不同的业务音频身份、相同的实际文件引用。
    final NoteAudioSegmentRecord copiedAudio = await (database.select(
      database.noteAudioSegments,
    )..where((row) => row.noteId.equals(copy.id))).getSingle();
    expect(copiedAudio.id, isNot('original-audio'));
    expect(copiedAudio.transcript, '供应商原始转写');
    expect(
      copiedAudio.sha256,
      sha256.convert(await audio.readAsBytes()).toString(),
    );
    final NoteAudioLocalFileRecord copiedLocal = await (database.select(
      database.noteAudioLocalFiles,
    )..where((row) => row.id.equals(copiedAudio.id))).getSingle();
    expect(copiedLocal.localPath, audio.path);
    expect(copiedLocal.consent, isFalse);
    expect(copiedLocal.recognitionId, isNull);
    expect(copiedLocal.recognitionState, 'idle');
    expect(copiedLocal.insertedRevision, isNull);
    expect(copiedLocal.candidateTranscript, isNull);
    await repository.permanentlyDelete(original.id);
    await repository.purgeOrphanFiles();
    expect(await repository.find(original.id), isNull);
    expect(await audio.exists(), isTrue);
    expect(
      (await database.select(database.noteAudioLocalFiles).get()).single.id,
      copiedAudio.id,
    );
    expect(
      (await database.select(database.noteAudioSegments).get())
          .single
          .transcript,
      '供应商原始转写',
    );
  });

  test('仅空白与元数据不创建正式记录或版本', () async {
    expect(
      await repository.save(
        const NoteDraft(
          id: 'blank',
          body: ' \n ',
          dayKey: '2026-10-09',
          baseRevision: '',
          tags: {'tag'},
        ),
      ),
      isNull,
    );
    expect(await database.select(database.noteEntries).get(), isEmpty);
    expect(await database.select(database.noteVersions).get(), isEmpty);
  });

  test('保存正文和版本原子落库，重复正文不制造额外版本', () async {
    // 首次正式记录。
    final NoteEntryRecord first = (await repository.save(initial))!;
    // 第二次正文版本。
    final NoteEntryRecord second = (await repository.save(
      next(first, '修改后的正文'),
    ))!;
    expect(second.createdAt, first.createdAt);
    expect(second.revision, isNot(first.revision));
    await repository.save(next(second, second.body));
    expect(await database.select(database.noteVersions).get(), hasLength(2));
  });

  test('陈旧正文版本只写持久候选，正式正文不受覆盖', () async {
    // 共同编辑起点。
    final NoteEntryRecord base = (await repository.save(initial))!;
    // 先提交的远端正文。
    final NoteEntryRecord remote = (await repository.save(next(base, '远端修改')))!;
    // 陈旧起点提交返回当前正式版。
    final NoteEntryRecord result = (await repository.save(next(base, '离线候选')))!;
    expect(result.revision, remote.revision);
    expect((await repository.find(base.id))!.body, '远端修改');
    // 候选即使重新打开 SQLite 也必须保留。
    await database.close();
    database = AppDatabase.forTesting(
      NativeDatabase(File('${directory.path}/notes.sqlite')),
    );
    repository = NoteRepository(database);
    expect(
      (await database.select(database.noteVersions).get()).map((v) => v.body),
      contains('离线候选'),
    );
    expect((await repository.find(base.id))!.body, '远端修改');
  });

  test('回收或永久删除后陈旧baseRevision不能使笔记复活', () async {
    // 删除前正式版本。
    final NoteEntryRecord saved = (await repository.save(initial))!;
    await repository.softDelete(saved.id);
    await expectLater(repository.save(next(saved, '迟到输入')), throwsStateError);
    expect((await repository.find(saved.id))!.deletedAt, isNotNull);
    await repository.permanentlyDelete(saved.id);
    await expectLater(repository.save(next(saved, '迟到输入')), throwsStateError);
    expect(await repository.find(saved.id), isNull);
    expect(await database.select(database.noteVersions).get(), isEmpty);
  });

  test('本地原音真实hash与长度入库，转写候选不改变人工正文', () async {
    await add('audio', 1000);
    // 持久化原音元数据。
    final NoteAudioSegmentRecord segment = await database
        .select(database.noteAudioSegments)
        .getSingle();
    expect(segment.byteSize, await audio.length());
    expect(
      segment.sha256,
      sha256.convert(await audio.readAsBytes()).toString(),
    );
    expect(segment.transcript, isNull);
    await (database.update(database.noteAudioSegments)
          ..where((row) => row.id.equals('audio')))
        .write(const NoteAudioSegmentsCompanion(transcript: Value('识别候选')));
    await repository.insertReadyTranscripts('note');
    expect((await repository.find('note'))!.body, '人工正文');
    expect(
      (await database.select(database.noteAudioSegments).getSingle())
          .transcript,
      '识别候选',
    );
    // 重复完成事件不能生成重复资产。
    await add('audio', 1000);
    expect(
      await database.select(database.noteAudioSegments).get(),
      hasLength(1),
    );
    expect(
      await database.select(database.noteAudioLocalFiles).get(),
      hasLength(1),
    );
  });

  test('无正文也可保存有效原音，空采样拒绝且原件仍保留', () async {
    await add(
      'voice-only',
      1000,
      draft: const NoteDraft(
        id: 'voice',
        body: '',
        dayKey: '2026-10-11',
        baseRevision: '',
      ),
    );
    expect((await repository.find('voice'))!.body, isEmpty);
    await audio.writeAsBytes(NoteWav.header(0));
    await expectLater(add('empty', 1000), throwsFormatException);
    expect(await audio.exists(), isTrue);
    expect(await repository.find('note'), isNull);
  });

  test('单段30分钟及单篇60分钟边界允许，超出拒绝并保留原件', () async {
    await expectLater(add('too-long', 1800001), throwsFormatException);
    expect(await repository.find('note'), isNull);
    await add('first', 1800000);
    // 第二段使用现有正式版本，避免模拟陈旧正文。
    final NoteDraft current = next((await repository.find('note'))!, '人工正文');
    await add('second', 1800000, draft: current);
    await expectLater(
      add('overflow', 1, draft: current),
      throwsFormatException,
    );
    expect(
      await database.select(database.noteAudioSegments).get(),
      hasLength(2),
    );
    expect(await audio.exists(), isTrue);
  });

  test('同时补回两段原音仍不能越过单篇60分钟或生成重复顺序', () async {
    await add('first', 1800000);
    // 恢复清单并发到达时共享同一已保存起点。
    final NoteDraft current = next((await repository.find('note'))!, '人工正文');
    // 确保两段的真实读取都发生在第一段事务提交之前。
    (database as _BarrierDatabase).barrier = Completer<void>();
    // 两个请求各自不足30分钟，但合计超过剩余30分钟。
    final List<Object?> results = await Future.wait([
      add(
        'second',
        1200000,
        draft: current,
      ).then<Object?>((_) => null).catchError((Object error) => error),
      add(
        'third',
        1200000,
        draft: current,
      ).then<Object?>((_) => null).catchError((Object error) => error),
    ]);
    expect(results.whereType<FormatException>(), hasLength(1));
    // 真正落库的总配额与稳定顺序。
    final List<NoteAudioSegmentRecord> segments = await database
        .select(database.noteAudioSegments)
        .get();
    expect(
      segments.fold<int>(0, (sum, item) => sum + item.durationMs),
      lessThanOrEqualTo(3600000),
    );
    expect(
      segments.map((item) => item.sortOrder).toSet(),
      hasLength(segments.length),
    );
  });

  test('转写乱序到达时等待前段，再按录音顺序一次插入且不重复', () async {
    await add('first', 1000);
    // 两段预留相同的首次录音正文起点。
    final NoteEntryRecord base = (await repository.find('note'))!;
    await add('second', 1000, draft: next(base, base.body));
    await database
        .update(database.noteAudioLocalFiles)
        .write(
          NoteAudioLocalFilesCompanion(
            consent: const Value(true),
            insertedRevision: Value('waiting:${base.revision}'),
          ),
        );
    await (database.update(database.noteAudioSegments)
          ..where((row) => row.id.equals('second')))
        .write(const NoteAudioSegmentsCompanion(transcript: Value('后段内容')));
    await repository.insertReadyTranscripts('note');
    expect((await repository.find('note'))!.body, '人工正文');
    await (database.update(database.noteAudioSegments)
          ..where((row) => row.id.equals('first')))
        .write(const NoteAudioSegmentsCompanion(transcript: Value('前段内容')));
    await repository.insertReadyTranscripts('note');
    expect((await repository.find('note'))!.body, '人工正文\n\n前段内容\n\n后段内容');
    // 重试和重新进入不能重复自动插入。
    await repository.insertReadyTranscripts('note');
    expect((await repository.find('note'))!.body, '人工正文\n\n前段内容\n\n后段内容');
    expect(await database.select(database.noteVersions).get(), hasLength(3));
    expect(
      (await database.select(database.noteAudioLocalFiles).get()).every(
        (row) => !row.insertedRevision!.startsWith('waiting:'),
      ),
      isTrue,
    );
  });

  test('AI整理等待首段并按录音顺序采用候选，原文保持完整', () async {
    await add('first-ai', 1000);
    // 两段共享同一个原始正文起点。
    final NoteEntryRecord base = (await repository.find('note'))!;
    await add('second-ai', 1000, draft: next(base, base.body));
    await database
        .update(database.noteAudioLocalFiles)
        .write(
          NoteAudioLocalFilesCompanion(
            consent: const Value(true),
            insertedRevision: Value('waiting:${base.revision}'),
            polishState: const Value('processing'),
          ),
        );
    await database
        .update(database.noteAudioSegments)
        .write(const NoteAudioSegmentsCompanion(transcript: Value('嗯原始转写')));
    await (database.update(
      database.noteAudioLocalFiles,
    )..where((row) => row.id.equals('second-ai'))).write(
      const NoteAudioLocalFilesCompanion(
        polishState: Value('succeeded'),
        polishedText: Value('第二段笔记'),
      ),
    );
    await repository.insertReadyTranscripts('note');
    expect((await repository.find('note'))!.body, base.body);
    await (database.update(
      database.noteAudioLocalFiles,
    )..where((row) => row.id.equals('first-ai'))).write(
      const NoteAudioLocalFilesCompanion(
        polishState: Value('succeeded'),
        polishedText: Value('第一段笔记'),
      ),
    );
    await repository.insertReadyTranscripts('note');
    await repository.insertReadyTranscripts('note');
    expect((await repository.find('note'))!.body, '人工正文\n\n第一段笔记\n\n第二段笔记');
    expect(
      (await database.select(database.noteAudioSegments).get()).every(
        (row) => row.transcript == '嗯原始转写',
      ),
      isTrue,
    );
  });

  test('AI失败回退原文，重试只替换精确范围且后续段范围继续有效', () async {
    await add('first-ai', 1000);
    // 两段均回退，用后续替换验证自动追加后的锚点推进。
    final NoteEntryRecord base = (await repository.find('note'))!;
    await add('second-ai', 1000, draft: next(base, base.body));
    await database
        .update(database.noteAudioLocalFiles)
        .write(
          NoteAudioLocalFilesCompanion(
            consent: const Value(true),
            insertedRevision: Value('waiting:${base.revision}'),
            polishState: const Value('failed'),
          ),
        );
    await database
        .update(database.noteAudioSegments)
        .write(const NoteAudioSegmentsCompanion(transcript: Value('同样原文')));
    await repository.insertReadyTranscripts('note');
    expect((await repository.find('note'))!.body, '人工正文\n\n同样原文\n\n同样原文');
    await (database.update(
      database.noteAudioLocalFiles,
    )..where((row) => row.id.equals('first-ai'))).write(
      const NoteAudioLocalFilesCompanion(
        polishState: Value('succeeded'),
        polishedText: Value('第一段整理较长'),
      ),
    );
    expect(await repository.adoptPolishedTranscript('first-ai'), isTrue);
    expect(await repository.adoptPolishedTranscript('first-ai'), isFalse);
    await (database.update(
      database.noteAudioLocalFiles,
    )..where((row) => row.id.equals('second-ai'))).write(
      const NoteAudioLocalFilesCompanion(
        polishState: Value('succeeded'),
        polishedText: Value('第二段整理'),
      ),
    );
    expect(await repository.adoptPolishedTranscript('second-ai'), isTrue);
    expect((await repository.find('note'))!.body, '人工正文\n\n第一段整理较长\n\n第二段整理');
  });

  test('AI原文回退后人工修改阻止自动替换，明确采用仅追加一次', () async {
    await add('ai', 1000);
    // 固定一次合法自动采用的起点。
    final NoteEntryRecord base = (await repository.find('note'))!;
    await database
        .update(database.noteAudioLocalFiles)
        .write(
          NoteAudioLocalFilesCompanion(
            consent: const Value(true),
            insertedRevision: Value('waiting:${base.revision}'),
            polishState: const Value('failed'),
          ),
        );
    await database
        .update(database.noteAudioSegments)
        .write(const NoteAudioSegmentsCompanion(transcript: Value('原文')));
    await repository.insertReadyTranscripts('note');
    await repository.save(next((await repository.find('note'))!, '人工更改'));
    await database
        .update(database.noteAudioLocalFiles)
        .write(
          const NoteAudioLocalFilesCompanion(
            polishState: Value('succeeded'),
            polishedText: Value('整理候选'),
          ),
        );
    await repository.insertReadyTranscripts('note');
    expect(await repository.adoptPolishedTranscript('ai'), isFalse);
    expect((await repository.find('note'))!.body, '人工更改');
    expect(
      await repository.adoptPolishedTranscript('ai', allowAppend: true),
      isTrue,
    );
    expect(
      await repository.adoptPolishedTranscript('ai', allowAppend: true),
      isFalse,
    );
    expect((await repository.find('note'))!.body, '人工更改\n\n整理候选');
  });

  test('AI候选摘要不匹配时不能自动采用或手动写入正文', () async {
    await add('ai', 1000);
    // 明确授权仍不能绕过输入摘要一致性校验。
    final NoteEntryRecord base = (await repository.find('note'))!;
    await database
        .update(database.noteAudioLocalFiles)
        .write(
          NoteAudioLocalFilesCompanion(
            consent: const Value(true),
            insertedRevision: Value('waiting:${base.revision}'),
            polishState: const Value('succeeded'),
            polishedText: const Value('别的原文生成的结果'),
            polishSourceHash: const Value('different-input-hash'),
          ),
        );
    await database
        .update(database.noteAudioSegments)
        .write(const NoteAudioSegmentsCompanion(transcript: Value('当前原文')));
    await repository.insertReadyTranscripts('note');
    expect(
      await repository.adoptPolishedTranscript('ai', allowAppend: true),
      isFalse,
    );
    expect((await repository.find('note'))!.body, base.body);
  });

  test('预览候选指纹变化时拒绝采用，重新确认最新结果后才允许写入', () async {
    await add('ai', 1000);
    await database
        .update(database.noteAudioSegments)
        .write(const NoteAudioSegmentsCompanion(transcript: Value('原始转写')));
    await database
        .update(database.noteAudioLocalFiles)
        .write(
          const NoteAudioLocalFilesCompanion(
            polishState: Value('succeeded'),
            polishedText: Value('用户预览的候选A'),
          ),
        );
    // 用户打开弹窗时固定候选A的身份。
    final String previewFingerprint = notePolishFingerprint(
      await database.select(database.noteAudioLocalFiles).getSingle(),
    )!;
    await database
        .update(database.noteAudioLocalFiles)
        .write(
          const NoteAudioLocalFilesCompanion(polishedText: Value('后台更新后的候选B')),
        );
    expect(
      await repository.adoptPolishedTranscript(
        'ai',
        allowAppend: true,
        expectedFingerprint: previewFingerprint,
      ),
      isFalse,
    );
    expect((await repository.find('note'))!.body, '人工正文');
    // 只有重新预览确认B，才可以采用当前结果。
    final String latestFingerprint = notePolishFingerprint(
      await database.select(database.noteAudioLocalFiles).getSingle(),
    )!;
    expect(
      await repository.adoptPolishedTranscript(
        'ai',
        allowAppend: true,
        expectedFingerprint: latestFingerprint,
      ),
      isTrue,
    );
    expect((await repository.find('note'))!.body, '人工正文\n\n后台更新后的候选B');
  });

  test('重新识别的整理来源匹配候选原文时可以明确采用且不会重复', () async {
    await add('ai', 1000);
    // 模拟原始ASR已采用，新的识别只保留本机候选。
    final NoteEntryRecord base = (await repository.find('note'))!;
    await database
        .update(database.noteAudioSegments)
        .write(const NoteAudioSegmentsCompanion(transcript: Value('旧原文')));
    await database
        .update(database.noteAudioLocalFiles)
        .write(
          NoteAudioLocalFilesCompanion(
            insertedRevision: Value(base.revision),
            candidateTranscript: const Value('重新识别原文'),
            polishState: const Value('succeeded'),
            polishedText: const Value('重新识别整理结果'),
            polishSourceHash: Value(
              sha256.convert(utf8.encode('重新识别原文')).toString(),
            ),
          ),
        );
    // 用户明确采用允许使用新候选，但不改变原始转写。
    final NoteAudioSegmentRecord segment = await database
        .select(database.noteAudioSegments)
        .getSingle();
    // 卡片可区分原ASR采用与新整理候选是否已采用。
    final NoteAudioLocalFileRecord local = await database
        .select(database.noteAudioLocalFiles)
        .getSingle();
    expect(repository.hasUnadoptedPolishedText(segment, local), isTrue);
    expect(
      await repository.adoptPolishedTranscript('ai', allowAppend: true),
      isTrue,
    );
    expect(
      await repository.adoptPolishedTranscript('ai', allowAppend: true),
      isFalse,
    );
    expect((await repository.find('note'))!.body, '人工正文\n\n重新识别整理结果');
    expect(
      (await database.select(database.noteAudioSegments).getSingle())
          .transcript,
      '旧原文',
    );
  });

  test('旧笔记缺少时间新列时自动转写保留创建时钟和归档日', () async {
    await add('legacy-audio', 1000);
    // 模拟升级后仍使用兼容解析的旧记录，自动插入不能改成当前时钟。
    await database
        .update(database.noteEntries)
        .write(
          NoteEntriesCompanion(
            recordTimeSeconds: const Value(null),
            recordUtcOffsetMinutes: const Value(null),
            createdAt: Value(DateTime.utc(2020, 2, 29, 1, 2, 3)),
            creationTimezone: const Value('CST|+08:00'),
          ),
        );
    // 固定正文起点，原音完成后允许自动插入。
    final NoteEntryRecord before = (await repository.find('note'))!;
    await database
        .update(database.noteAudioLocalFiles)
        .write(
          NoteAudioLocalFilesCompanion(
            consent: const Value(true),
            insertedRevision: Value('waiting:${before.revision}'),
          ),
        );
    await database
        .update(database.noteAudioSegments)
        .write(const NoteAudioSegmentsCompanion(transcript: Value('新转写')));
    await repository.insertReadyTranscripts('note');
    // 正文改变，记录时间、真实创建时间和时区全部保留。
    final NoteEntryRecord after = (await repository.find('note'))!;
    expect(after.body, '人工正文\n\n新转写');
    expect(after.recordTime.label, before.recordTime.label);
    expect(
      after.recordTime.utcOffsetMinutes,
      before.recordTime.utcOffsetMinutes,
    );
    expect(after.createdAt, before.createdAt);
  });

  test('等待转写期间人工编辑正文后只保留候选，不能覆盖输入', () async {
    await add('audio', 1000);
    // 原先明确授权的空位锚点。
    final NoteEntryRecord anchor = (await repository.find('note'))!;
    await database
        .update(database.noteAudioLocalFiles)
        .write(
          NoteAudioLocalFilesCompanion(
            consent: const Value(true),
            insertedRevision: Value('waiting:${anchor.revision}'),
          ),
        );
    await repository.save(next(anchor, '用户刚刚改过的正文'));
    await database
        .update(database.noteAudioSegments)
        .write(const NoteAudioSegmentsCompanion(transcript: Value('原始识别候选')));
    await repository.insertReadyTranscripts('note');
    expect((await repository.find('note'))!.body, '用户刚刚改过的正文');
    expect(
      (await database.select(database.noteAudioSegments).getSingle())
          .transcript,
      '原始识别候选',
    );
    expect(
      (await database.select(database.noteAudioLocalFiles).getSingle())
          .insertedRevision,
      'waiting:${anchor.revision}',
    );
  });

  test('自动转写会超出正文20k时保留原音候选而不截断正文', () async {
    // 达到正文上限的人工内容。
    final String body = List.filled(20000, '字').join();
    await add(
      'audio',
      1000,
      draft: NoteDraft(
        id: 'note',
        body: body,
        dayKey: initial.dayKey,
        baseRevision: '',
      ),
    );
    final NoteEntryRecord anchor = (await repository.find('note'))!;
    await database
        .update(database.noteAudioLocalFiles)
        .write(
          NoteAudioLocalFilesCompanion(
            consent: const Value(true),
            insertedRevision: Value('waiting:${anchor.revision}'),
          ),
        );
    await database
        .update(database.noteAudioSegments)
        .write(const NoteAudioSegmentsCompanion(transcript: Value('不能截断的候选')));
    await repository.insertReadyTranscripts('note');
    expect((await repository.find('note'))!.body, body);
    expect(
      (await database.select(database.noteAudioSegments).getSingle())
          .transcript,
      '不能截断的候选',
    );
    expect(await audio.exists(), isTrue);
  });

  test('外层回收事务失败会恢复SQL，物理文件不提前删除', () async {
    await add('audio', 1000);
    await repository.softDelete('note');
    await expectLater(
      database.transaction(() async {
        await repository.permanentlyDelete('note');
        throw StateError('另一回收条目失败');
      }),
      throwsStateError,
    );
    expect((await repository.find('note'))!.deletedAt, isNotNull);
    expect(
      await database.select(database.noteAudioSegments).get(),
      hasLength(1),
    );
    await repository.purgeOrphanFiles();
    expect(await audio.exists(), isTrue);
    await repository.permanentlyDelete('note');
    expect(await audio.exists(), isTrue);
    await repository.purgeOrphanFiles();
    expect(await audio.exists(), isFalse);
    expect(await database.select(database.noteAudioLocalFiles).get(), isEmpty);
  });

  test('共享路径仍被另一有效片段引用时只移除孤儿元数据', () async {
    await add('deleted-audio', 1000);
    await add(
      'active-audio',
      1000,
      draft: const NoteDraft(
        id: 'active',
        body: '保留',
        dayKey: '2026-10-11',
        baseRevision: '',
      ),
    );
    await repository.permanentlyDelete('note');
    await repository.purgeOrphanFiles();
    expect(await audio.exists(), isTrue);
    expect(
      (await database.select(database.noteAudioLocalFiles).get()).single.id,
      'active-audio',
    );
  });
}
