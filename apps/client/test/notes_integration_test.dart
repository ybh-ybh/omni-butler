import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/sync/omni_sync_runtime.dart';
import 'package:omni_butler/core/sync/omni_powersync_connector.dart';
import 'package:omni_butler/core/sync/sync_note_audio_backup.dart';
import 'package:omni_butler/core/sync/sync_snapshot.dart';
import 'package:omni_butler/features/settings/data/recycle_bin_repository.dart';
import 'package:omni_butler/features/notes/data/note_repository.dart';
import 'package:omni_butler/features/notes/audio/note_wav.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:omni_butler/shared/search/global_search_repository.dart';
import 'package:powersync/powersync.dart' show CrudTransaction, UpdateType;
import 'package:uuid/uuid.dart';

/// 仅截获连接器最终HTTP请求，不模拟操作负载转换。
class _FixtureAuth extends AuthRepository {
  /// 无真实账号的测试认证仓储。
  _FixtureAuth() : super(const FlutterSecureStorage());

  /// 实际connector发送的事务负载。
  final List<Map<String, Object?>> payloads = [];

  /// 不访问服务器的协议版本检查。
  @override
  Future<void> ensureSyncSchemaForGeneration(int generation) async {}

  /// 捕获最终HTTP DTO并返回成功，使SDK完成真实本地队列。
  @override
  Future<Response<T>> authorizedRequestForGeneration<T>(
    int generation,
    String method,
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    ResponseType? responseType,
    bool preserveTransportErrors = false,
  }) async {
    expect(method, 'POST');
    expect(path, '/sync/operations');
    payloads.add(Map<String, Object?>.from(data! as Map));
    return Response<T>(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
    );
  }
}

/// 验证笔记真实数据库的同步边界、原音备份、搜索与回收站。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 迁移测试同时保留源库与候选库。
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  // 固定业务时钟，独立于实际测试执行日期。
  final DateTime now = DateTime.utc(2026, 10, 11);
  // 每个测试独占文件目录。
  late Directory directory;
  // 与生产相同的源数据库运行时。
  late OmniSyncRuntime source;
  // 不连接任何真实账户的认证仓储。
  late AuthRepository auth;
  // 已打开的候选库需要独立释放。
  OmniSyncRuntime? candidate;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'omni-notes-integration-',
    );
    auth = AuthRepository(const FlutterSecureStorage());
    source = await OmniSyncRuntime.openAtPath(
      auth,
      '${directory.path}/source.sqlite',
    );
  });
  tearDown(() async {
    await candidate?.close();
    candidate = null;
    await source.close();
    await directory.delete(recursive: true);
  });

  /// 写入带旧数据源识别状态的笔记与真实文件体。
  Future<File> seedNote() async {
    // 可按真实长度与摘要校验的测试原音。
    final File file = File('${directory.path}/original.wav');
    await file.writeAsBytes([1, 2, 3, 4]);
    await source.database
        .into(source.database.noteEntries)
        .insert(
          NoteEntriesCompanion.insert(
            id: 'note',
            body: const Value('会议素材'),
            dayKey: '2026-10-11',
            revision: 'revision',
            tags: const Value('["tag"]'),
            createdAt: now,
            updatedAt: now,
          ),
        );
    await source.database
        .into(source.database.noteVersions)
        .insert(
          NoteVersionsCompanion.insert(
            id: 'version',
            noteId: 'note',
            body: '会议素材',
            baseRevision: '',
            revision: 'revision',
            createdAt: now,
          ),
        );
    await source.database
        .into(source.database.noteAudioSegments)
        .insert(
          NoteAudioSegmentsCompanion.insert(
            id: 'segment',
            noteId: 'note',
            sortOrder: 0,
            durationMs: 1000,
            mime: 'audio/wav',
            sha256: sha256.convert([1, 2, 3, 4]).toString(),
            byteSize: 4,
            transcript: const Value('原始转写独有词'),
            createdAt: now,
            updatedAt: now,
          ),
        );
    await source.database
        .into(source.database.noteAudioLocalFiles)
        .insert(
          NoteAudioLocalFilesCompanion.insert(
            id: 'segment',
            localPath: Value(file.path),
            consent: const Value(true),
            recognitionId: const Value('old-task'),
            recognitionState: const Value('running'),
            candidateTranscript: const Value('旧来源重识别候选'),
          ),
        );
    return file;
  }

  test('完整迁移保留独立原音文件体并清除旧源识别任务，文件不进同步操作', () async {
    // 原文件删除后备份仍须可恢复。
    final File original = await seedNote();
    await source.freezeWrites();
    // 文件体复制后的完整快照。
    final SyncSnapshot snapshot = await backupMigrationNoteAudio(
      await source.exportSnapshot(),
      Directory('${directory.path}/backup'),
    );
    expect(
      snapshot.operations.any(
        (Map<String, Object?> row) => row['table'] == 'note_audio_local_files',
      ),
      isFalse,
    );
    await original.delete();
    expect(await findMissingMigrationNoteAudio(snapshot), isEmpty);
    candidate = await OmniSyncRuntime.createCandidate(
      auth,
      '${directory.path}/candidate.sqlite',
      snapshot,
      'new-owner',
      mergeInitial: true,
      useLocalData: true,
    );
    // 候选库原音有独立副本，旧凭证和待识别任务不会跨源。
    final NoteAudioLocalFileRecord local = await candidate!.database
        .select(candidate!.database.noteAudioLocalFiles)
        .getSingle();
    expect(local.recognitionId, isNull);
    expect(local.recognitionState, 'idle');
    expect(local.consent, isFalse);
    expect(local.candidateTranscript, isNull);
    expect(
      local.localPath,
      isNot(snapshot.tables['note_audio_local_files']!.single['local_path']),
    );
    expect(await File(local.localPath!).readAsBytes(), [1, 2, 3, 4]);
    // 损坏备份不能继续被宣称为完整。
    await File(
      snapshot.tables['note_audio_local_files']!.single['local_path']!
          as String,
    ).writeAsBytes([4, 3, 2, 1]);
    expect(await findMissingMigrationNoteAudio(snapshot), hasLength(1));
    expect(await File(local.localPath!).readAsBytes(), [1, 2, 3, 4]);
  });

  test('v1与v2快照补齐空笔记表而不修改原控制文件', () async {
    // 旧持久格式的全部历史业务表。
    final Map<String, List<Map<String, Object?>>> tables = {
      for (final String name in SyncSnapshot.tableNames)
        if (!name.startsWith('note_')) name: [],
    };
    for (final int version in [1, 2]) {
      // JSON 往返模拟历史控制文件输入。
      final Map<String, dynamic> encoded = jsonDecode(
        jsonEncode({
          'version': version,
          'tables': tables,
          'pendingOperations': 0,
        }),
      );
      // 升级只修改内存副本，不损害原始快照校验。
      final SyncSnapshot snapshot = SyncSnapshot.fromJson(encoded);
      expect(snapshot.tables['note_entries'], isEmpty);
      expect(snapshot.tables['note_audio_local_files'], isEmpty);
      expect(encoded['tables'].containsKey('note_entries'), isFalse);
    }
  });

  test('真实PowerSync CRUD保持版本先于正文且可跨端重放完整生命周期', () async {
    // 全部业务身份均由客户端真实生成，可交给服务器 UUID DTO 校验。
    final String noteId = const Uuid().v4();
    final String segmentId = const Uuid().v4();
    final String categoryId = const Uuid().v4();
    final String tagId = const Uuid().v4();
    // 认证边界只拦截HTTP，实际连接器负责负载转换与持久设备身份。
    final _FixtureAuth capturing = _FixtureAuth();
    final OmniPowerSyncConnector connector = OmniPowerSyncConnector(capturing);
    // 直接捕获SDK排队结果，不从snapshot重建PUT推断PATCH顺序。
    final List<Map<String, Object?>> transactions = [];

    /// 读取并确认一组真实事务，下一业务动作生成下一组。
    Future<List<Map<String, Object?>>> capture() async {
      final CrudTransaction? transaction = await source.powerSync
          .getNextCrudTransaction();
      expect(transaction, isNotNull);
      final List<Map<String, Object?>> operations = transaction!.crud
          .map(
            (entry) => <String, Object?>{
              'op': entry.op.toJson(),
              'table': entry.table,
              'id': entry.id,
              if (entry.opData != null)
                'data': <String, Object?>{
                  ...entry.opData!,
                  // 仅预期映射读取SDK持久前态，导出仍使用真实connector请求。
                  if (entry.table == 'note_entries' &&
                      entry.op == UpdateType.patch &&
                      entry.opData!.containsKey('tags'))
                    'tags_base': entry.previousValues?['tags'],
                },
            },
          )
          .toList();
      expect(
        operations.any((entry) => entry['table'] == 'note_audio_local_files'),
        isFalse,
      );
      await connector.uploadData(source.powerSync);
      // 最终发送内容必须与真实SDK队列一致。
      expect(capturing.payloads.last['operations'], operations);
      transactions.add(capturing.payloads.last);
      return operations;
    }

    await source.database.transaction(() async {
      for (final MapEntry<String, String> identity in {tagId: 'tag'}.entries) {
        await source.database
            .into(source.database.taxonomyEntries)
            .insert(
              TaxonomyEntriesCompanion.insert(
                id: identity.key,
                module: 'notes',
                kind: identity.value,
                name: '测试${identity.value}',
                colorValue: 0,
                createdAt: now,
                updatedAt: now,
              ),
            );
      }
    });
    await capture();
    // 产品仓储产生真实队列。
    final NoteRepository repository = NoteRepository(source.database);
    final NoteEntryRecord created = (await repository.save(
      NoteDraft(
        id: noteId,
        body: '客户端创建',
        dayKey: '2026-10-11',
        baseRevision: '',
      ),
    ))!;
    final List<Map<String, Object?>> creation = await capture();
    final Map<String, Object?> initialVersion = creation.firstWhere(
      (entry) => entry['table'] == 'note_versions',
    );
    expect((initialVersion['data']! as Map)['base_revision'], created.revision);
    final NoteEntryRecord edited = (await repository.save(
      NoteDraft(
        id: noteId,
        body: '客户端编辑后的正文',
        dayKey: created.dayKey,
        baseRevision: created.revision,
      ),
    ))!;
    final List<Map<String, Object?>> editing = await capture();
    expect(
      editing.indexWhere((entry) => entry['table'] == 'note_versions'),
      lessThan(editing.indexWhere((entry) => entry['table'] == 'note_entries')),
    );
    expect(editing.first['op'], UpdateType.put.toJson());
    expect(editing.last['op'], UpdateType.patch.toJson());
    final NoteEntryRecord classified = (await repository.save(
      NoteDraft(
        id: noteId,
        body: edited.body,
        dayKey: edited.dayKey,
        baseRevision: edited.revision,
        tags: {tagId},
      ),
    ))!;
    await capture();
    // 真正可播放的WAV文件也输出到隔离fixture目录供HTTP上传使用。
    final File file = File('${directory.path}/client-audio.wav');
    await file.writeAsBytes([
      ...NoteWav.header(32000),
      ...List.filled(32000, 0),
    ]);
    await repository.addAudio(
      draft: NoteDraft(
        id: noteId,
        body: classified.body,
        dayKey: classified.dayKey,
        baseRevision: classified.revision,
        tags: {tagId},
      ),
      id: segmentId,
      localPath: file.path,
      durationMs: 1000,
      mime: 'audio/wav',
    );
    await capture();
    await repository.softDelete(noteId);
    await capture();
    await repository.restore(noteId);
    await capture();
    expect(await source.powerSync.getNextCrudTransaction(), isNull);
    // 仅显式启用时导出跨端测试输入，普通测试不写仓库目录。
    if (const bool.fromEnvironment('NOTES_CLIENT_FIXTURE')) {
      final Directory fixture = Directory('../server/.local/notes-test');
      await fixture.create(recursive: true);
      final File fixtureAudio = await file.copy(
        '${fixture.path}/client-audio.wav',
      );
      await File('${fixture.path}/client-ops.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'clientId': transactions.first['clientId'],
          'noteId': noteId,
          'segmentId': segmentId,
          'categoryId': categoryId,
          'tagId': tagId,
          'audioPath': fixtureAudio.absolute.path,
          'audioSha256': sha256
              .convert(await fixtureAudio.readAsBytes())
              .toString(),
          'audioByteSize': await fixtureAudio.length(),
          'transactions': transactions,
          'source': 'Flutter NoteRepository → real PowerSync SQLite CRUD → OmniPowerSyncConnector authorizedRequestForGeneration capture; command flutter test test/notes_integration_test.dart --plain-name 真实PowerSync --dart-define=NOTES_CLIENT_FIXTURE=true',
          'expected': {
            'body': classified.body,
            'dayKey': classified.dayKey,
            'revision': classified.revision,
            'tags': [tagId],
            'deletedAt': null,
            'audioCount': 1,
            'versionCount': 2,
          },
        }),
      );
    }
  });

  test('搜索命中正文原始转写和标签名称，删除记录排除且路由精确到笔记', () async {
    await seedNote();
    await source.database
        .into(source.database.taxonomyEntries)
        .insert(
          TaxonomyEntriesCompanion.insert(
            id: 'tag',
            module: 'notes',
            kind: 'tag',
            name: '项目标签独有词',
            colorValue: 0,
            createdAt: now,
            updatedAt: now,
          ),
        );
    // 真实全局搜索仓储。
    final GlobalSearchRepository search = GlobalSearchRepository(
      source.database,
    );
    for (final String keyword in ['会议素材', '原始转写独有词', '项目标签独有词']) {
      // 每个字段必须真实命中同一已有笔记。
      final List<GlobalSearchResult> results = await search.search(keyword);
      expect(results.single.type, GlobalSearchType.note);
      expect(results.single.route, '/notes?id=note');
    }
    await (source.database.update(source.database.noteEntries)
          ..where((NoteEntries table) => table.id.equals('note')))
        .write(NoteEntriesCompanion(deletedAt: Value(now)));
    expect(await search.search('会议素材'), isEmpty);
  });

  test('笔记回收站恢复绑定原音与历史版本，永久删除保留有效其他业务', () async {
    await seedNote();
    await (source.database.update(source.database.noteEntries)
          ..where((NoteEntries table) => table.id.equals('note')))
        .write(NoteEntriesCompanion(deletedAt: Value(now)));
    await (source.database.update(source.database.noteAudioSegments)
          ..where((NoteAudioSegments table) => table.noteId.equals('note')))
        .write(NoteAudioSegmentsCompanion(deletedAt: Value(now)));
    await (source.database.update(source.database.noteVersions)
          ..where((NoteVersions table) => table.noteId.equals('note')))
        .write(NoteVersionsCompanion(deletedAt: Value(now)));
    // 真实跨模块回收站。
    final RecycleBinRepository recycle = RecycleBinRepository(
      source.database,
      TodoRepository(source.database),
    );
    expect((await recycle.loadItems()).single.type, RecycleEntityType.note);
    await recycle.restore((await recycle.loadItems()).single);
    expect(
      (await source.database.select(source.database.noteEntries).getSingle())
          .deletedAt,
      isNull,
    );
    expect(
      (await source.database
              .select(source.database.noteAudioSegments)
              .getSingle())
          .deletedAt,
      isNull,
    );
    expect(
      (await source.database.select(source.database.noteVersions).getSingle())
          .deletedAt,
      isNull,
    );
    await (source.database.update(source.database.noteEntries)
          ..where((NoteEntries table) => table.id.equals('note')))
        .write(NoteEntriesCompanion(deletedAt: Value(now)));
    await recycle.permanentlyDelete((await recycle.loadItems()).single);
    expect(
      await source.database.select(source.database.noteEntries).get(),
      isEmpty,
    );
    expect(
      await source.database.select(source.database.noteAudioSegments).get(),
      isEmpty,
    );
    expect(
      await source.database.select(source.database.noteVersions).get(),
      isEmpty,
    );
  });
}
