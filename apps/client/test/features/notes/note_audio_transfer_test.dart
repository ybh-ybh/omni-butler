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

  /// 整理接口与已有 ASR 假服务分开，便于验证独立付费链路。
  late Future<Object?> Function(RequestOptions) polishRespond;

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
        return {'sub': 'test-owner', 'syncSchemaVersion': syncSchemaVersion};
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
    polishRespond = (request) async => {
      'id': null,
      'recognitionId':
          request.queryParameters['recognitionId'] ??
          (request.data as Map?)?['recognitionId'],
      'enabled': false,
      'status': 'disabled',
      'text': null,
      'errorCode': null,
      'sourceHash': null,
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
                    data: await (request.path.endsWith('/polish')
                        ? polishRespond(request)
                        : respond(request)),
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

  /// 只统计真正经过生产授权仓储发出的语音识别计费请求。
  List<RequestOptions> submits() => requests
      .where(
        (request) =>
            request.method == 'POST' && request.path.endsWith('/recognitions'),
      )
      .toList();

  /// 为已完成 ASR 保留自动插入起点，使用生产数据库与真实文件。
  Future<void> seedPolish() async {
    await seed(recognitionState: 'succeeded', transcript: '嗯，今天阅读了一小时，嗯。');
    // 固定当时正文版本，后台不能越过后续人工编辑。
    final NoteEntryRecord note = (await repository.find('note'))!;
    await (database.update(
      database.noteAudioLocalFiles,
    )..where((table) => table.id.equals('segment'))).write(
      NoteAudioLocalFilesCompanion(
        insertedRevision: Value('waiting:${note.revision}'),
      ),
    );
    service = NoteAudioTransferService(database, auth);
  }

  /// 每次回应的来源摘要必须对应真实原始转写。
  Map<String, Object?> polishResult(String state, {String? text}) => {
    'id': 'polish-job',
    'recognitionId': 'operation',
    'enabled': true,
    'status': state,
    'text': text,
    'errorCode': state == 'failed' ? 'AI_PROVIDER_ERROR' : null,
    'sourceHash': sha256.convert(utf8.encode('嗯，今天阅读了一小时，嗯。')).toString(),
  };

  test('ASR已成功仍轮询整理，等待时不插原文，成功只采用一次', () async {
    await seedPolish();
    polishRespond = (_) async => polishResult('processing');
    await service.tick();
    expect((await repository.find('note'))!.body, '人工正文');
    expect((await local()).polishState, 'processing');
    polishRespond = (_) async => polishResult('succeeded', text: '今天阅读了一小时。');
    await service.tick();
    await service.tick();
    expect((await repository.find('note'))!.body, '人工正文\n\n今天阅读了一小时。');
    expect(
      (await database.select(database.noteAudioSegments).getSingle())
          .transcript,
      '嗯，今天阅读了一小时，嗯。',
    );
    expect(submits(), isEmpty);
  });

  // 查询断连前已采用与尚在等待的结果都应保持，连接恢复后清除旧错误。
  for (final bool alreadyAdopted in [false, true]) {
    test('整理状态查询断连只记录简短原因，恢复后清除错误：已采用$alreadyAdopted', () async {
      await seedPolish();
      polishRespond = (_) async => polishResult('succeeded', text: '今天阅读了一小时。');
      if (alreadyAdopted) await service.tick();
      polishRespond = (request) async => throw DioException(
        requestOptions: request,
        type: DioExceptionType.connectionError,
        message: 'private unit-secret',
        error: HttpException(
          'Connection closed before full header was received',
          uri: Uri.parse('https://private.example.test/polish?key=unit-secret'),
        ),
      );
      await service.tick();
      expect((await local()).lastError, '服务器连接中断，稍后会自动重试连接；原音和已保存文字仍保留。');
      expect((await local()).lastError, isNot(contains('unit-secret')));
      expect((await local()).recognitionState, 'succeeded');
      expect((await local()).recognitionId, 'operation');
      if (alreadyAdopted) {
        expect((await local()).polishedText, '今天阅读了一小时。');
        expect((await local()).polishAdoptedHash, isNotNull);
      }
      polishRespond = (_) async => polishResult('succeeded', text: '今天阅读了一小时。');
      await service.tick();
      expect((await local()).lastError, isNull);
      expect((await local()).polishError, isNull);
      expect((await repository.find('note'))!.body, '人工正文\n\n今天阅读了一小时。');
      expect(submits(), isEmpty);
      expect(
        requests.where(
          (request) =>
              request.method == 'POST' && request.path.endsWith('/polish'),
        ),
        isEmpty,
      );
    });
  }

  test('旧版本保存的原始连接异常在查询恢复后清除', () async {
    await seedPolish();
    await (database.update(
      database.noteAudioLocalFiles,
    )..where((table) => table.id.equals('segment'))).write(
      const NoteAudioLocalFilesCompanion(
        lastError: Value('DioException: uri=https://private.example.test'),
      ),
    );
    polishRespond = (_) async => polishResult('processing');
    await service.tick();
    expect((await local()).lastError, isNull);
    expect((await local()).polishState, 'processing');
    expect((await repository.find('note'))!.body, '人工正文');
  });

  test('整理失败回退原文，显式重试只调用整理并精确替换原范围', () async {
    await seedPolish();
    polishRespond = (_) async => polishResult('failed');
    await service.tick();
    expect((await repository.find('note'))!.body, '人工正文\n\n嗯，今天阅读了一小时，嗯。');
    polishRespond = (_) async => polishResult('succeeded', text: '今天阅读了一小时。');
    await service.retryPolish('segment');
    expect((await repository.find('note'))!.body, '人工正文\n\n今天阅读了一小时。');
    expect(submits(), isEmpty);
    expect(
      requests.where(
        (request) =>
            request.method == 'POST' && request.path.endsWith('/polish'),
      ),
      hasLength(1),
    );
  });

  test('等待整理时人工修改，成功结果保候选不覆盖正文', () async {
    await seedPolish();
    polishRespond = (_) async => polishResult('processing');
    await service.tick();
    // 人工保存产生新的正文版本，不能被模型响应替换。
    final NoteEntryRecord before = (await repository.find('note'))!;
    await repository.save(
      NoteDraft(
        id: before.id,
        body: '人工后来修改',
        dayKey: before.dayKey,
        baseRevision: before.revision,
      ),
    );
    polishRespond = (_) async => polishResult('succeeded', text: '今天阅读了一小时。');
    await service.tick();
    expect((await repository.find('note'))!.body, '人工后来修改');
    expect((await local()).polishedText, '今天阅读了一小时。');
  });

  test('整理来源摘要不匹配时回退原文，不采用错误结果', () async {
    await seedPolish();
    polishRespond = (_) async => {
      ...polishResult('succeeded', text: '错误段落'),
      'sourceHash': 'another-source',
    };
    await service.tick();
    expect((await local()).polishState, 'failed');
    expect((await repository.find('note'))!.body, '人工正文\n\n嗯，今天阅读了一小时，嗯。');
  });

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

  test('整理POST回执丢失后重放相同operationId，不重新ASR', () async {
    await seedPolish();
    polishRespond = (_) async => polishResult('failed');
    await service.tick();
    // 首次整理POST只丢失回执，保留持久操作身份供恢复。
    int posts = 0;
    polishRespond = (request) async {
      if (request.method == 'POST' && ++posts == 1) {
        throw DioException(
          requestOptions: request,
          type: DioExceptionType.receiveTimeout,
        );
      }
      return polishResult('succeeded', text: '今天阅读了一小时。');
    };
    await service.retryPolish('segment');
    // 未知回执不会清空身份，也不会再次插入原文。
    final String? operationId = (await local()).polishOperationId;
    expect(operationId, isNotNull);
    await service.tick();
    // 所有重发只对应同一次用户明确要求的尝试。
    final List<RequestOptions> attempts = requests
        .where(
          (request) =>
              request.path.endsWith('/polish') && request.method == 'POST',
        )
        .toList();
    expect(attempts, hasLength(2));
    expect(
      attempts.map((request) => (request.data as Map)['operationId']).toSet(),
      {operationId},
    );
    expect((await local()).polishOperationId, isNull);
    expect((await repository.find('note'))!.body, '人工正文\n\n今天阅读了一小时。');
    expect(submits(), isEmpty);
  });

  test('快速双击整理重试只分配一次操作身份', () async {
    await seedPolish();
    polishRespond = (_) async => polishResult('failed');
    await service.tick();
    // 原请求处于在途时第二次点击不得另建计费尝试。
    final Completer<void> entered = Completer<void>();
    final Completer<Object?> release = Completer<Object?>();
    polishRespond = (_) {
      entered.complete();
      return release.future;
    };
    // 第一点击保留网络屏障，第二点击复用已持久身份。
    final Future<void> first = service.retryPolish('segment');
    await entered.future;
    final String? operationId = (await local()).polishOperationId;
    await service.retryPolish('segment');
    expect((await local()).polishOperationId, operationId);
    release.complete(polishResult('succeeded', text: '今天阅读了一小时。'));
    await first;
    expect(
      requests.where(
        (request) =>
            request.path.endsWith('/polish') && request.method == 'POST',
      ),
      hasLength(1),
    );
  });

  test('整理重试确定4xx拒绝后停止自动POST', () async {
    await seedPolish();
    polishRespond = (_) async => polishResult('failed');
    await service.tick();
    polishRespond = (request) async {
      if (request.method == 'POST') {
        throw DioException(
          requestOptions: request,
          type: DioExceptionType.badResponse,
          response: Response(
            requestOptions: request,
            statusCode: 400,
            data: {'message': '请先开启笔记 AI 整理'},
          ),
        );
      }
      return polishResult('failed');
    };
    await service.retryPolish('segment');
    expect((await local()).polishState, 'failed');
    expect((await local()).polishOperationId, isNull);
    expect((await local()).polishError, '请先开启笔记 AI 整理');
    await service.tick();
    expect(
      requests.where(
        (request) =>
            request.path.endsWith('/polish') && request.method == 'POST',
      ),
      hasLength(1),
    );
  });

  for (final bool changeSource in [false, true]) {
    test('整理GET在途${changeSource ? '换服' : '撤回'}不采用迟到结果', () async {
      await seedPolish();
      // 屏障固定网络结果晚于本机撤回或换服。
      final Completer<void> entered = Completer<void>();
      final Completer<Object?> release = Completer<Object?>();
      polishRespond = (_) {
        entered.complete();
        return release.future;
      };
      // 保留生产传输与实际授权仓储的全部代次校验。
      final Future<void> pending = service.tick();
      await entered.future;
      if (changeSource) {
        await auth.clearSession();
      } else {
        await withdraw();
      }
      release.complete(polishResult('succeeded', text: '迟到结果'));
      await pending;
      expect((await repository.find('note'))!.body, '人工正文');
      expect((await local()).polishedText, isNull);
    });
  }

  test('原音损坏也先送达撤回，不下载或重复计费', () async {
    await seedPolish();
    await withdraw();
    // 损坏原件仍保留供恢复，撤回不应先经过文件校验。
    final String path = (await local()).localPath!;
    await File(path).writeAsBytes([0, 1, 2]);
    await service.tick();
    expect(
      requests.where((request) => request.method == 'DELETE'),
      hasLength(1),
    );
    expect(
      requests.where(
        (request) => request.path.endsWith('/file') || request.method == 'PUT',
      ),
      isEmpty,
    );
    expect((await local()).polishState, 'cancelled');
    expect(submits(), isEmpty);
  });

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
