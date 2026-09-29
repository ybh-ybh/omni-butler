import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/attachments/attachment_repository.dart';
import 'package:omni_butler/core/attachments/image_sync_service.dart';
import 'package:omni_butler/core/attachments/image_sync_store.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/core/database/app_database.dart';

/// 内存服务端配合真实 SQLite 与物理文件验证图片队列。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 当前测试的真实本机数据库。
  late AppDatabase database;
  // 当前测试的物理附件目录。
  late Directory directory;
  // 当前测试的业务附件入口。
  late AttachmentRepository repository;
  // 当前测试的传输器。
  late ImageSyncService service;
  // 当前测试的认证仓储。
  late AuthRepository auth;
  // 内存服务端功能开关。
  late bool enabled;
  // 服务端当前图片映射。
  late Map<String, Map<String, dynamic>> images;
  // 服务端已接收的请求。
  late List<RequestOptions> requests;
  // 可选网络故障或暂停注入器。
  Future<void> Function(RequestOptions)? beforeResponse;
  // 测试图片内容。
  const List<int> bytes = <int>[137, 80, 78, 71, 1, 2, 3];

  /// 构造服务端图片关联。
  Map<String, dynamic> remote({
    String? attachmentId = 'remote-image',
    String revision = 'revision-1',
    String type = 'inventoryImage',
  }) => <String, dynamic>{
    'businessType': type,
    'businessId': 'record-1',
    'attachmentId': attachmentId,
    'revision': revision,
    'sha256': attachmentId == null ? null : sha256.convert(bytes).toString(),
    'mimeType': attachmentId == null ? null : 'image/png',
    'sizeBytes': attachmentId == null ? null : bytes.length,
  };

  /// 保存一张当前测试的本机图片。
  Future<Attachment> attach({
    AttachmentBusinessType type = AttachmentBusinessType.inventoryImage,
    List<int> content = bytes,
  }) async {
    // 选择器交付的源文件。
    final File source = File('${directory.path}/source.png');
    await source.writeAsBytes(content);
    return repository.attachLocalFile(
      businessType: type,
      businessId: 'record-1',
      sourcePath: source.path,
      mimeType: 'image/png',
    );
  }

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    directory = await Directory.systemTemp.createTemp('omni-image-client-');
    repository = AttachmentRepository(
      database,
      directoryProvider: () async => directory,
    );
    enabled = true;
    images = <String, Map<String, dynamic>>{};
    requests = <RequestOptions>[];
    beforeResponse = null;
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'sync.device_session': jsonEncode(<String, dynamic>{
        'baseUrl': 'https://test.invalid/omni-butler/api/v1',
        'accessToken': 'access',
        'refreshToken': 'refresh',
        'expiresAt': DateTime.now()
            .add(const Duration(hours: 1))
            .toIso8601String(),
        'identity': <String, String>{'sub': 'owner-a'},
      }),
    });
    auth = AuthRepository(
      const FlutterSecureStorage(),
      clientFactory: (String baseUrl) {
        // 标准认证代码仍经过真实 Dio 拦截器。
        final Dio dio = Dio(BaseOptions(baseUrl: baseUrl));
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest:
                (
                  RequestOptions request,
                  RequestInterceptorHandler handler,
                ) async {
                  requests.add(request);
                  try {
                    await beforeResponse?.call(request);
                    // 每个请求对应的内存响应。
                    Object? response;
                    if (request.path == '/images/capabilities') {
                      response = <String, dynamic>{
                        'enabled': enabled,
                        'maxBytes': 20971520,
                      };
                    } else if (request.path == '/images') {
                      response = <String, dynamic>{
                        'items': images.values.toList(),
                      };
                    } else if (request.path.endsWith('/file')) {
                      response = ResponseBody.fromBytes(bytes, 200);
                    } else {
                      // 本轮写入目标的业务类型。
                      final String type = request.path.split('/')[2];
                      // 解析真实 multipart 表单中的协议字段。
                      final Map<String, dynamic> fields =
                          request.data is FormData
                          ? Map<String, String>.fromEntries(
                              (request.data as FormData).fields,
                            )
                          : Map<String, dynamic>.from(request.data as Map);
                      // 记录服务端返回的版本。
                      final Map<String, dynamic> image = remote(
                        type: type,
                        attachmentId: fields['attachmentId'] as String?,
                        revision: 'revision-${requests.length}',
                      );
                      images['$type:record-1'] = image;
                      response = <String, dynamic>{
                        'status': 'applied',
                        'image': image,
                      };
                    }
                    handler.resolve(
                      Response<dynamic>(
                        requestOptions: request,
                        statusCode: 200,
                        data: response,
                      ),
                    );
                  } on DioException catch (error) {
                    handler.reject(error);
                  }
                },
          ),
        );
        return dio;
      },
    );
    service = ImageSyncService(
      database: database,
      auth: auth,
      directoryProvider: () async => directory,
    );
    // 两种图片所属业务均存在。
    final DateTime now = DateTime.now();
    await database
        .into(database.inventoryItems)
        .insert(
          InventoryItemsCompanion.insert(
            id: 'record-1',
            name: '物品',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await database
        .into(database.memberships)
        .insert(
          MembershipsCompanion.insert(
            id: 'record-1',
            name: '会员',
            purchaseDate: now,
            createdAt: now,
            updatedAt: now,
          ),
        );
  });

  tearDown(() async {
    await service.stop();
    await database.close();
    await directory.delete(recursive: true);
  });

  test('关闭时保留本机操作，开启后自动补传且首页背景不传', () async {
    enabled = false;
    await attach();
    await attach(type: AttachmentBusinessType.quoteBanner);
    await service.runOnce();
    expect(service.state.enabled, false);
    expect(
      requests.where((RequestOptions request) => request.method == 'PUT'),
      isEmpty,
    );
    expect(
      await ImageSyncStore(database).read('intent:inventoryImage:record-1'),
      isNotNull,
    );
    enabled = true;
    await service.runOnce();
    expect(
      requests.where((RequestOptions request) => request.method == 'PUT'),
      hasLength(1),
    );
    expect(
      Map<String, String>.fromEntries(
        (requests
                    .lastWhere(
                      (RequestOptions request) => request.method == 'PUT',
                    )
                    .data
                as FormData)
            .fields,
      )['onlyIfMissing'],
      'true',
    );
    expect(
      await ImageSyncStore(database).read('intent:inventoryImage:record-1'),
      isNull,
    );
    expect(
      (await repository
              .watchCurrent(
                businessType: AttachmentBusinessType.inventoryImage,
                businessId: 'record-1',
              )
              .first)
          ?.uploadState,
      'synced',
    );
  });

  test('已有服务器图片优先于未见过服务器的旧本机图并完整下载', () async {
    // 本机旧图片文件迁移后仍保留。
    final Attachment old = await attach();
    images['inventoryImage:record-1'] = remote();
    await service.runOnce();
    expect(service.state.failed, 0);
    expect(
      requests.where((RequestOptions request) => request.method == 'PUT'),
      isEmpty,
    );
    // 新图引用与本机文件一起落库。
    final InventoryRecord item = await database
        .select(database.inventoryItems)
        .getSingle();
    expect(item.imageAttachmentId, 'remote-image');
    expect(await File(item.imageLocalPath!).readAsBytes(), bytes);
    expect(await File(old.localPath!).exists(), true);
    expect(
      (await repository
              .watchCurrent(
                businessType: AttachmentBusinessType.inventoryImage,
                businessId: 'record-1',
              )
              .first)
          ?.id,
      'remote-image',
    );
  });

  test('服务器清图标记阻止旧图片复活', () async {
    await attach();
    images['inventoryImage:record-1'] = remote(attachmentId: null);
    await service.runOnce();
    expect(
      (await database.select(database.inventoryItems).getSingle())
          .imageAttachmentId,
      isNull,
    );
    expect(
      requests.where((RequestOptions request) => request.method == 'PUT'),
      isEmpty,
    );
    await service.runOnce();
    expect(
      requests.where((RequestOptions request) => request.method == 'PUT'),
      isEmpty,
    );
  });

  test('会员图片自动下载，重扫复用本机缓存', () async {
    images['membershipImage:record-1'] = remote(type: 'membershipImage');
    await service.runOnce();
    await service.runOnce();
    expect(
      (await database.select(database.memberships).getSingle())
          .imageAttachmentId,
      'remote-image',
    );
    expect(
      requests.where(
        (RequestOptions request) => request.path.endsWith('/file'),
      ),
      hasLength(1),
    );
  });

  test('删除在关闭期间持久保存，重启传输器后使用旧已知版本清图', () async {
    images['inventoryImage:record-1'] = remote();
    await service.runOnce();
    enabled = false;
    await repository.removeCurrent(
      businessType: AttachmentBusinessType.inventoryImage,
      businessId: 'record-1',
    );
    await service.runOnce();
    await service.stop();
    service = ImageSyncService(
      database: database,
      auth: auth,
      directoryProvider: () async => directory,
    );
    enabled = true;
    await service.runOnce();
    expect(
      (requests
              .lastWhere((RequestOptions request) => request.method == 'DELETE')
              .data
          as Map)['expectedRevision'],
      'revision-1',
    );
    expect(
      await ImageSyncStore(database).read('intent:inventoryImage:record-1'),
      isNull,
    );
  });

  test('断网或业务尚未同步时重试复用原操作标识', () async {
    await attach();
    beforeResponse = (RequestOptions request) async {
      if (request.method == 'PUT') {
        throw DioException(
          requestOptions: request,
          response: Response<dynamic>(requestOptions: request, statusCode: 404),
        );
      }
    };
    await service.runOnce();
    expect(service.state.failed, 1);
    beforeResponse = null;
    await service.runOnce();
    // 两次网络尝试使用同一持久操作。
    final List<FormData> uploads = requests
        .where((RequestOptions request) => request.method == 'PUT')
        .map((RequestOptions request) => request.data as FormData)
        .toList();
    expect(uploads, hasLength(2));
    expect(
      Map<String, String>.fromEntries(uploads[0].fields)['operationId'],
      Map<String, String>.fromEntries(uploads[1].fields)['operationId'],
    );
  });

  test('下载暂停时停止服务，晚到响应不修改本机文件路径', () async {
    images['inventoryImage:record-1'] = remote();
    // 人工暂停服务器下载响应。
    final Completer<void> started = Completer<void>();
    final Completer<void> release = Completer<void>();
    beforeResponse = (RequestOptions request) async {
      if (request.path.endsWith('/file')) {
        started.complete();
        await release.future;
      }
    };
    // 在途下载仍由 stop 排空。
    final Future<void> running = service.runOnce();
    await started.future;
    final Future<void> stopping = service.stop();
    release.complete();
    await running;
    await stopping;
    expect(
      (await database.select(database.inventoryItems).getSingle())
          .imageLocalPath,
      isNull,
    );
    expect(
      (await database.select(database.inventoryItems).getSingle())
          .imageAttachmentId,
      'remote-image',
    );
  });

  test('库owner与会话不匹配时完全不请求图片接口', () async {
    await database.customStatement(
      'CREATE TABLE device_sync_metadata(id TEXT,value TEXT)',
    );
    await database.customStatement(
      "INSERT INTO device_sync_metadata VALUES('owner','owner-other')",
    );
    await attach();
    await service.runOnce();
    expect(requests, isEmpty);
  });

  test('旧后端404能力被视为关闭而不上传', () async {
    beforeResponse = (RequestOptions request) async {
      throw DioException(
        requestOptions: request,
        response: Response<dynamic>(requestOptions: request, statusCode: 404),
      );
    };
    await attach();
    await service.runOnce();
    expect(service.state.enabled, false);
    expect(requests, hasLength(1));
  });

  test('已知版本后的显式换图使用CAS且不偷换为最新清单版本', () async {
    images['inventoryImage:record-1'] = remote();
    await service.runOnce();
    await attach(content: <int>[137, 80, 78, 71, 9, 8, 7]);
    images['inventoryImage:record-1'] = remote(
      revision: 'changed-by-other-device',
    );
    beforeResponse = (RequestOptions request) async {
      if (request.method == 'PUT') {
        throw DioException(
          requestOptions: request,
          response: Response<dynamic>(requestOptions: request, statusCode: 409),
        );
      }
    };
    await service.runOnce();
    // 显式修改携带用户编辑时看到的旧版本。
    final Map<String, String> fields = Map<String, String>.fromEntries(
      (requests
                  .lastWhere(
                    (RequestOptions request) => request.method == 'PUT',
                  )
                  .data
              as FormData)
          .fields,
    );
    expect(fields['onlyIfMissing'], 'false');
    expect(fields['expectedRevision'], 'revision-1');
    expect(
      await ImageSyncStore(database).read('intent:inventoryImage:record-1'),
      isNull,
    );
    beforeResponse = null;
    await service.runOnce();
    expect(
      (await database.select(database.inventoryItems).getSingle())
          .imageAttachmentId,
      'remote-image',
    );
  });

  test('下载内容摘要错误不登记本机缓存且保留缺失引用', () async {
    images['inventoryImage:record-1'] = remote()..['sha256'] = 'wrong-hash';
    await service.runOnce();
    expect(service.state.failed, 1);
    // 身份保留供迁移报告，校验失败文件不能被展示。
    final InventoryRecord record = await database
        .select(database.inventoryItems)
        .getSingle();
    expect(record.imageAttachmentId, 'remote-image');
    expect(record.imageLocalPath, isNull);
    expect(
      await directory
          .list(recursive: true)
          .where((FileSystemEntity item) => item.path.endsWith('.part'))
          .toList(),
      isEmpty,
    );
  });

  test('下载期间用户的新选择不会被迟到图片覆盖', () async {
    images['inventoryImage:record-1'] = remote();
    // 用户操作在响应返回前发生。
    Attachment? selected;
    beforeResponse = (RequestOptions request) async {
      if (request.path.endsWith('/file')) {
        selected = await attach(content: <int>[1, 2, 3, 4]);
      }
    };
    await service.runOnce();
    expect(
      (await database.select(database.inventoryItems).getSingle())
          .imageAttachmentId,
      selected!.id,
    );
    expect(
      await ImageSyncStore(database).read('intent:inventoryImage:record-1'),
      isNotNull,
    );
  });

  test('会话撤销期间晚到清单不写本机业务数据', () async {
    images['inventoryImage:record-1'] = remote();
    beforeResponse = (RequestOptions request) async {
      if (request.path == '/images') await auth.clearSession();
    };
    await service.runOnce();
    expect(
      (await database.select(database.inventoryItems).getSingle())
          .imageAttachmentId,
      isNull,
    );
    expect(
      requests.where(
        (RequestOptions request) => request.path.endsWith('/file'),
      ),
      isEmpty,
    );
  });
}
