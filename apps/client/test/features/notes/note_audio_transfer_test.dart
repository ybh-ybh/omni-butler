import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/notes/audio/note_wav.dart';
import 'package:omni_butler/features/notes/data/note_audio_transfer_service.dart';
import 'package:omni_butler/features/notes/data/note_repository.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// 测试下载只能落入独立临时目录，不能碰真实应用支持目录。
class _NotesPathProvider extends PathProviderPlatform {
  /// 每例独占的应用支持目录。
  final String supportPath;

  /// 固定本例下载目录。
  _NotesPathProvider(this.supportPath);

  /// 只替换目录发现，文件校验和原子落盘仍执行生产实现。
  @override
  Future<String?> getApplicationSupportPath() async => supportPath;
}

/// 注入网络层但保留生产认证、状态机、SQLite事务和真实原音文件。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 每例独立的持久SQLite。
  late AppDatabase database;

  /// 每例独立的原音目录。
  late Directory directory;

  /// 实际授权设备会话仓储。
  late AuthRepository auth;

  /// 被测生产传输服务。
  late NoteAudioTransferService service;

  /// 真实仓储用于删除生命周期。
  late NoteRepository repository;

  /// 每例独占HTTP请求记录。
  late List<RequestOptions> requests;

  /// 网络回应可由屏障控制返回时刻。
  late Future<Object?> Function(RequestOptions) respond;

  /// 原平台路径提供器，结束时精确恢复避免串测试。
  late PathProviderPlatform originalPathProvider;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('notes-transfer-test-');
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _NotesPathProvider(
      p.join(directory.path, 'support'),
    );
    database = AppDatabase.forTesting(
      NativeDatabase(File('${directory.path}/notes.sqlite')),
    );
    repository = NoteRepository(database);
    requests = [];
    FlutterSecureStorage.setMockInitialValues({
      'sync.device_session': jsonEncode({
        'baseUrl': 'https://notes.example.test/omni-butler/api/v1',
        'accessToken': 'test-only-access',
        'refreshToken': 'test-only-refresh',
        'expiresAt': DateTime.now()
            .add(const Duration(days: 1))
            .toIso8601String(),
        'identity': {'sub': 'test-owner'},
      }),
    });
    respond = (request) async {
      if (request.path == '/auth/session') {
        return {'sub': 'test-owner', 'syncSchemaVersion': 3};
      }
      if (request.path.endsWith('/capabilities')) {
        return {
          'audioUpload': true,
          'recognition': true,
          'provider': 'tencent',
        };
      }
      if (request.method == 'DELETE') {
        return {'cancelled': true, 'alreadySubmitted': false};
      }
      return {
        'id': 'operation',
        'status': 'processing',
        'segmentId': 'segment',
        'transcript': null,
      };
    };
    auth = AuthRepository(
      const FlutterSecureStorage(),
      clientFactory: (baseUrl) {
        /// 仅替换HTTP传输，生产代次和凭证检查仍实际执行。
        final Dio dio = Dio(BaseOptions(baseUrl: baseUrl));
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) async {
              requests.add(request);
              try {
                handler.resolve(
                  Response<dynamic>(
                    requestOptions: request,
                    statusCode: 200,
                    data: await respond(request),
                  ),
                );
              } on DioException catch (failure) {
                handler.reject(failure);
              }
            },
          ),
        );
        return dio;
      },
    );
    service = NoteAudioTransferService(
      database,
      auth,
      hasUnpersistedEdits: (_) => true,
    );
  });
  tearDown(() async {
    await service.stop();
    PathProviderPlatform.instance = originalPathProvider;
    await database.close();
    await directory.delete(recursive: true);
  });

  /// 使用真实仓储创建有文件体且已授权的一段笔记。
  Future<void> seed({
    String uploadState = 'synced',
    String recognitionState = 'queued',
    String? transcript,
  }) async {
    /// 可播放且可校验的测试容器，绝不发送真实厂商。
    final File file = File('${directory.path}/original.wav');
    await file.writeAsBytes([...NoteWav.header(4), 0, 0, 1, 0], flush: true);
    await repository.addAudio(
      draft: const NoteDraft(
        id: 'note',
        body: '人工正文',
        dayKey: '2026-10-11',
        baseRevision: '',
      ),
      id: 'segment',
      localPath: file.path,
      durationMs: 1000,
      mime: 'audio/wav',
    );
    await (database.update(database.noteAudioSegments)
          ..where((table) => table.id.equals('segment')))
        .write(NoteAudioSegmentsCompanion(transcript: Value(transcript)));
    await (database.update(
      database.noteAudioLocalFiles,
    )..where((table) => table.id.equals('segment'))).write(
      NoteAudioLocalFilesCompanion(
        uploadState: Value(uploadState),
        recognitionId: const Value('operation'),
        recognitionState: Value(recognitionState),
        consent: const Value(true),
      ),
    );
    expect(
      (await database.select(database.noteAudioSegments).getSingle()).sha256,
      sha256.convert(await file.readAsBytes()).toString(),
    );
  }

  /// 读取真实数据库本机状态，不以内存变量替代落库断言。
  Future<NoteAudioLocalFileRecord> local() =>
      database.select(database.noteAudioLocalFiles).getSingle();

  /// 模拟用户撤回操作，与产品使用相同持久字段。
  Future<void> withdraw() =>
      (database.update(
        database.noteAudioLocalFiles,
      )..where((table) => table.id.equals('segment'))).write(
        const NoteAudioLocalFilesCompanion(
          consent: Value(false),
          recognitionState: Value('cancelPending'),
        ),
      );

  /// 只统计真正经过生产授权仓储发出的计费请求。
  List<RequestOptions> submits() => requests
      .where(
        (request) =>
            request.method == 'POST' && request.path.endsWith('/recognitions'),
      )
      .toList();

  for (final bool duringPost in [true, false]) {
    test('在途${duringPost ? 'POST' : 'poll'}撤回不被迟到成功覆盖，下一轮真正DELETE', () async {
      await seed();

      /// 请求已开始的信号。
      final Completer<void> entered = Completer<void>();

      /// 用户操作完成后才允许原网络结果返回。
      final Completer<Object?> release = Completer<Object?>();

      /// 先保留能力和身份回应。
      final Future<Object?> Function(RequestOptions) original = respond;
      respond = (request) async {
        if ((duringPost && request.method == 'POST') ||
            (!duringPost &&
                request.path.endsWith('/recognitions/current') &&
                request.method == 'GET')) {
          entered.complete();
          return release.future;
        }
        return original(request);
      };

      /// 一个真实在途传输轮次。
      final Future<void> running = service.tick();
      await entered.future.timeout(const Duration(seconds: 5));
      await withdraw();
      release.complete({
        'id': 'operation',
        'status': 'succeeded',
        'transcript': '迟到转写',
      });
      await running;
      expect((await local()).consent, isFalse);
      expect((await local()).recognitionState, 'cancelPending');
      expect(
        (await database.select(database.noteAudioSegments).getSingle())
            .transcript,
        isNull,
      );
      respond = original;
      await service.tick();
      expect(
        requests.where((request) => request.method == 'DELETE'),
        hasLength(1),
      );
      expect((await local()).recognitionState, 'cancelled');
      expect(submits(), hasLength(1));
    });
  }

  test('撤回DELETE在途重新授权新操作，旧撤回结果不能覆盖新任务', () async {
    await seed();
    await withdraw();

    /// 服务端撤回请求已发出的信号。
    final Completer<void> entered = Completer<void>();

    /// 旧撤回回执由新授权完成后释放。
    final Completer<Object?> release = Completer<Object?>();

    /// 保留常规能力和身份回应。
    final Future<Object?> Function(RequestOptions) original = respond;
    respond = (request) async {
      if (request.method == 'DELETE') {
        entered.complete();
        return release.future;
      }
      return original(request);
    };

    /// 撤回轮次尚未返回。
    final Future<void> running = service.tick();
    await entered.future.timeout(const Duration(seconds: 5));
    await (database.update(
      database.noteAudioLocalFiles,
    )..where((table) => table.id.equals('segment'))).write(
      const NoteAudioLocalFilesCompanion(
        consent: Value(true),
        recognitionId: Value('new-operation'),
        recognitionState: Value('queued'),
      ),
    );
    release.complete({'cancelled': true, 'alreadySubmitted': false});
    await running;
    expect((await local()).recognitionId, 'new-operation');
    expect((await local()).recognitionState, 'queued');
    expect((await local()).consent, isTrue);
  });

  test('接受另一设备已有任务ID，后续重放真实任务身份且保留回执结果', () async {
    await seed();

    /// 常规能力与身份回应。
    final Future<Object?> Function(RequestOptions) original = respond;
    respond = (request) async {
      if (request.method == 'POST') {
        return {
          'id': 'existing-other-device-job',
          'status': submits().length == 1 ? 'processing' : 'succeeded',
          'transcript': '实际任务结果',
        };
      }
      if (request.path.endsWith('/recognitions/current')) {
        return {'id': 'later-job', 'status': 'processing'};
      }
      return original(request);
    };
    await service.tick();
    expect((await local()).recognitionId, 'existing-other-device-job');
    await service.tick();
    expect(
      (submits().last.data as Map)['operationId'],
      'existing-other-device-job',
    );
    expect((await local()).recognitionState, 'succeeded');
    expect(
      (await database.select(database.noteAudioSegments).getSingle())
          .transcript,
      '实际任务结果',
    );
  });

  test('重识别成功只保存新本机候选，原始转写与人工正文保留', () async {
    await seed(transcript: '第一次原始转写');

    /// 保留身份与能力请求。
    final Future<Object?> Function(RequestOptions) original = respond;
    respond = (request) async => request.method == 'POST'
        ? {'id': 'operation', 'status': 'succeeded', 'transcript': '第二次候选'}
        : original(request);
    await service.tick();
    expect(
      (await database.select(database.noteAudioSegments).getSingle())
          .transcript,
      '第一次原始转写',
    );
    expect((await local()).candidateTranscript, '第二次候选');
    expect((await repository.find('note'))!.body, '人工正文');
    expect((await local()).recognitionState, 'succeeded');
    await service.tick();
    expect(submits(), hasLength(1));
  });

  for (final bool duringPost in [true, false]) {
    test('原文下行未到达时${duringPost ? 'POST' : 'poll'}采用共享原文，重识别仅存本机候选', () async {
      await seed(recognitionState: duringPost ? 'queued' : 'submissionUnknown');

      /// 本机原文确实仍为空，不通过预写原始转写掩盖跨设备竞态。
      expect(
        (await database.select(database.noteAudioSegments).getSingle())
            .transcript,
        isNull,
      );

      /// 保留真实授权检查和能力响应，仅替换对应任务回执。
      final Future<Object?> Function(RequestOptions) original = respond;
      respond = (request) async {
        if ((duringPost && request.method == 'POST') ||
            (!duringPost &&
                request.method == 'GET' &&
                request.path.endsWith('/recognitions/current'))) {
          return {
            'id': 'operation',
            'segmentId': 'segment',
            'status': 'succeeded',
            'transcript': '另一设备重新识别候选',
            'canonicalTranscript': '另一设备第一次原始转写',
            'errorCode': null,
          };
        }
        return original(request);
      };
      await service.tick();
      expect(
        (await database.select(database.noteAudioSegments).getSingle())
            .transcript,
        '另一设备第一次原始转写',
      );
      expect((await local()).candidateTranscript, '另一设备重新识别候选');
      expect((await local()).recognitionState, 'succeeded');
      expect((await repository.find('note'))!.body, '人工正文');
      expect(submits(), hasLength(duringPost ? 1 : 0));
      await service.tick();
      expect(submits(), hasLength(duringPost ? 1 : 0));
    });
  }

  test('原音上传在途时整篇删除，字节同步完成但不启动识别计费', () async {
    await seed(uploadState: 'pending');

    /// 上传进入网络的信号。
    final Completer<void> entered = Completer<void>();

    /// 本次实际multipart上传回执。
    final Completer<Object?> release = Completer<Object?>();

    /// 保留常规身份与能力回应。
    final Future<Object?> Function(RequestOptions) original = respond;
    respond = (request) async {
      if (request.method == 'PUT') {
        expect(request.data, isA<FormData>());
        entered.complete();
        return release.future;
      }
      return original(request);
    };

    /// 上传未返回时用户操作仍通过真实事务执行。
    final Future<void> running = service.tick();
    await entered.future.timeout(const Duration(seconds: 5));
    await repository.softDelete('note');
    release.complete({'segmentId': 'segment'});
    await running;
    expect((await local()).uploadState, 'synced');
    expect(submits(), isEmpty);
    expect((await repository.find('note'))!.deletedAt, isNotNull);
  });

  for (final bool changeSource in [true, false]) {
    test('${changeSource ? '数据源代次改变' : '维护stop'}后迟到网络结果不能落库', () async {
      await seed();

      /// 计费任务请求进入网络的信号。
      final Completer<void> entered = Completer<void>();

      /// 原会话网络请求。
      final Completer<Object?> release = Completer<Object?>();

      /// 保留原能力与身份回应。
      final Future<Object?> Function(RequestOptions) original = respond;
      respond = (request) async {
        if (request.method == 'POST') {
          entered.complete();
          return release.future;
        }
        return original(request);
      };

      /// 真正绑定旧会话的请求。
      final Future<void> running = service.tick();
      await entered.future.timeout(const Duration(seconds: 5));

      /// stop必须等待在途返回，但立即禁用结果写回。
      final Future<void> stopped = changeSource
          ? auth.clearSession()
          : service.stop();
      if (changeSource) await stopped;
      release.complete({
        'id': 'operation',
        'status': 'succeeded',
        'transcript': '旧源结果',
      });
      await running;
      await stopped;
      expect((await local()).recognitionState, 'queued');
      expect((await local()).candidateTranscript, isNull);
      expect(
        (await database.select(database.noteAudioSegments).getSingle())
            .transcript,
        isNull,
      );
      expect(
        requests.where(
          (request) => request.path.endsWith('/recognitions/current'),
        ),
        isEmpty,
      );
    });
  }

  test('提交结果未知只轮询原任务，网络丢失重试继续复用持久操作ID', () async {
    await seed(recognitionState: 'submissionUnknown');
    await service.tick();
    expect(submits(), isEmpty);
    expect((await local()).recognitionId, 'operation');
    await (database.update(
      database.noteAudioLocalFiles,
    )..where((table) => table.id.equals('segment'))).write(
      const NoteAudioLocalFilesCompanion(recognitionState: Value('queued')),
    );

    /// 能力和身份不受故障注入影响。
    final Future<Object?> Function(RequestOptions) original = respond;
    respond = (request) async {
      if (request.method == 'POST' && submits().length == 1) {
        throw DioException(
          requestOptions: request,
          type: DioExceptionType.receiveTimeout,
        );
      }
      return original(request);
    };
    await service.tick();
    expect((await local()).recognitionId, 'operation');
    expect((await local()).lastError, isNotNull);
    await service.tick();
    expect(submits(), hasLength(2));
    expect(
      submits().map((request) => (request.data as Map)['operationId']).toSet(),
      {'operation'},
    );
  });

  /// 缓存身份必须包含真实会话来源及音频内容摘要。
  Future<String> expectedCachePath() async {
    /// 同生产来源标识，不能把不同服务器同ID的文件合并。
    final session = (await auth.loadSession())!;

    /// 保留原段事实中的不可变内容摘要。
    final segment = await database
        .select(database.noteAudioSegments)
        .getSingle();

    /// 来源标识由服务器API地址和归属共同构成。
    final String sourceKey = sha256
        .convert(utf8.encode('${session.apiBaseUrl}/${session.identity.id}'))
        .toString();
    return p.join(
      directory.path,
      'support',
      'notes',
      'cache',
      sourceKey,
      'segment.${segment.sha256}.wav',
    );
  }

  test('已同步原音被同长度篡改后清缓存指针，下一轮下载恢复且不重复识别', () async {
    await seed(recognitionState: 'succeeded', transcript: '已识别的原始转写');

    /// 保存服务器应有的真实字节，故障仅改变本机缓存。
    final File damaged = File((await local()).localPath!);

    /// 原音下载回应使用完整原件而不是合成替代内容。
    final List<int> originalBytes = await damaged.readAsBytes();

    /// 相同长度足以越过只检查size的错误实现，必须检查SHA。
    final List<int> corruptedBytes = [...originalBytes];
    corruptedBytes[44] ^= 1;
    await damaged.writeAsBytes(corruptedBytes, flush: true);

    /// 保留身份及能力响应，只有原音下载返回字节。
    final Future<Object?> Function(RequestOptions) original = respond;
    respond = (request) async =>
        request.path.endsWith('/file') ? originalBytes : original(request);
    await service.tick();
    expect((await local()).localPath, isNull);
    expect((await local()).lastError, isNotNull);
    expect((await local()).recognitionId, 'operation');
    expect((await local()).recognitionState, 'succeeded');
    expect(
      requests.where((request) => request.path.endsWith('/file')),
      isEmpty,
    );
    // 下一轮才重新获取已确认存在的服务器资产，不删除备份原件。
    await service.tick();

    /// 生产落库指针指向真实校验过的来源隔离缓存。
    final NoteAudioLocalFileRecord restored = await local();
    expect(restored.localPath, await expectedCachePath());
    expect(p.isWithin(directory.path, restored.localPath!), isTrue);
    expect(await File(restored.localPath!).readAsBytes(), originalBytes);
    expect(await damaged.readAsBytes(), corruptedBytes);
    expect(restored.uploadState, 'synced');
    expect(restored.lastError, isNull);
    expect(restored.recognitionId, 'operation');
    expect(restored.recognitionState, 'succeeded');
    expect(
      requests.where((request) => request.path.endsWith('/file')),
      hasLength(1),
    );
    expect(
      File(restored.localPath!).parent
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.download')),
      isEmpty,
    );
    expect(submits(), isEmpty);
    expect(requests.where((request) => request.method == 'PUT'), isEmpty);
    expect(
      (await database.select(database.noteAudioSegments).getSingle())
          .transcript,
      '已识别的原始转写',
    );
    expect((await repository.find('note'))!.body, '人工正文');
  });

  test('同metadata缓存下载错SHA会删除临时文件，原件和已有正确缓存不被替换', () async {
    await seed(recognitionState: 'succeeded', transcript: '保留文字');

    /// 本机原件独立于下载缓存，修复失败不能污染原件。
    final File originalFile = File((await local()).localPath!);

    /// 服务器正确原音字节。
    final List<int> originalBytes = await originalFile.readAsBytes();

    /// 同元数据最终路径已有正确内容，模拟恢复备份留下的缓存。
    final File protectedCache = File(await expectedCachePath());
    await protectedCache.parent.create(recursive: true);
    await protectedCache.writeAsBytes(originalBytes, flush: true);
    await (database.update(database.noteAudioLocalFiles)
          ..where((table) => table.id.equals('segment')))
        .write(const NoteAudioLocalFilesCompanion(localPath: Value(null)));

    /// 错误下载保留容器和字节数，仅内容SHA不同。
    final List<int> wrongBytes = [...originalBytes];
    wrongBytes[44] ^= 1;

    /// 保留常规协议回应。
    final Future<Object?> Function(RequestOptions) original = respond;
    respond = (request) async =>
        request.path.endsWith('/file') ? wrongBytes : original(request);
    await service.tick();
    expect((await local()).localPath, isNull);
    expect((await local()).lastError, isNotNull);
    expect(await originalFile.readAsBytes(), originalBytes);
    expect(await protectedCache.readAsBytes(), originalBytes);
    expect(
      protectedCache.parent.listSync().whereType<File>().where(
        (file) => file.path.endsWith('.download'),
      ),
      isEmpty,
    );
    expect(submits(), isEmpty);
    expect((await local()).recognitionId, 'operation');
    // 正确回执可恢复同一段，之前下载失败不能永久阻塞缓存重试。
    respond = (request) async =>
        request.path.endsWith('/file') ? originalBytes : original(request);
    await service.tick();
    expect((await local()).localPath, protectedCache.path);
    expect((await local()).lastError, isNull);
    expect(await protectedCache.readAsBytes(), originalBytes);
    expect(submits(), isEmpty);
    expect(
      requests.where((request) => request.path.endsWith('/file')),
      hasLength(2),
    );
  });

  test('未同步原音校验失败保留原件指针供备份恢复，不假定服务器已有原音', () async {
    await seed(uploadState: 'pending', recognitionState: 'succeeded');

    /// 还未上传的唯一原件必须保留指针。
    final String path = (await local()).localPath!;

    /// 用相同长度损坏验证上传前SHA校验。
    final List<int> bytes = await File(path).readAsBytes();
    bytes[44] ^= 1;
    await File(path).writeAsBytes(bytes, flush: true);
    await service.tick();
    await service.tick();
    expect((await local()).localPath, path);
    expect((await local()).uploadState, 'pending');
    expect(await File(path).readAsBytes(), bytes);
    expect(
      requests.where(
        (request) => request.path.endsWith('/file') || request.method == 'PUT',
      ),
      isEmpty,
    );
    expect(submits(), isEmpty);
  });
}
