import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:omni_butler/core/attachments/attachment_repository.dart';
import 'package:omni_butler/core/attachments/image_sync_service.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/sync/omni_sync_runtime.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

/// 真实链路只能显式开启，地址固定隔离测试端口。
const bool _enabled = bool.fromEnvironment('OMNI_IMAGE_E2E');

/// 公开测试密钥，不读取真实部署配置。
const String _secret = 'omni_image_sync_test_secret_only';

/// 允许真实 HTTP，保留安全存储的测试插件通道。
class _NetworkBinding extends AutomatedTestWidgetsFlutterBinding {
  /// 关闭组件测试默认的 HTTP 400 替身。
  @override
  bool get overrideHttpClient => false;
}

/// 一个独立 SQLite 和本机图片目录的真实客户端。
class _Device {
  /// 独立应用目录。
  final Directory directory;

  /// 使用真实认证的会话仓储。
  final AuthRepository auth;

  /// 真实 PowerSync SQLite 运行时。
  final OmniSyncRuntime runtime;

  /// 真实图片传输器。
  late ImageSyncService images = ImageSyncService(
    database: runtime.database,
    auth: auth,
    directoryProvider: () async => directory,
  );

  /// 用户选择图片的生产仓储。
  late final AttachmentRepository attachments = AttachmentRepository(
    runtime.database,
    directoryProvider: () async => directory,
  );

  /// 仅注入故障，不替换真实 HTTP。
  bool offline = false;

  /// 模拟提交成功响应丢失。
  bool loseResponse = false;

  /// 记录重试是否沿用原操作身份。
  final List<String> uploadIds = [];

  /// 保留测试服务器的错误正文，失败时能定位协议边界。
  Object? lastFailure;

  /// 持有这一台设备的固定资源。
  _Device(this.directory, this.auth, this.runtime);

  /// 连接专属测试服务并完成真实初始复制。
  static Future<_Device> open(Directory root, String name) async {
    // 当前设备私有目录。
    final Directory directory = await Directory(path.join(root.path, name))
        .create();
    // 供网络工厂注入连接后的故障。
    _Device? device;
    // 每台设备使用独立安全存储键。
    final AuthRepository auth = AuthRepository(
      const FlutterSecureStorage(),
      storageKey: 'image-e2e-$name',
      clientFactory: (String base) {
        // 真实 API 客户端。
        final Dio dio = Dio(BaseOptions(baseUrl: base));
        dio.interceptors.add(
          InterceptorsWrapper(
            onError: (error, handler) {
              device?.lastFailure = error.response?.data;
              handler.next(error);
            },
            onRequest: (options, handler) {
              if (device?.offline == true) {
                handler.reject(
                  DioException(
                    requestOptions: options,
                    type: DioExceptionType.connectionError,
                  ),
                );
                return;
              }
              if (options.method == 'PUT' &&
                  options.path.startsWith('/images/')) {
                device?.uploadIds.add(
                  (options.data as FormData).fields
                      .firstWhere((entry) => entry.key == 'operationId')
                      .value,
                );
              }
              handler.next(options);
            },
            onResponse: (response, handler) {
              if (device?.loseResponse == true &&
                  response.requestOptions.method == 'PUT' &&
                  response.requestOptions.path.startsWith('/images/')) {
                device!.loseResponse = false;
                handler.reject(
                  DioException(
                    requestOptions: response.requestOptions,
                    type: DioExceptionType.connectionError,
                  ),
                );
                return;
              }
              handler.next(response);
            },
          ),
        );
        return dio;
      },
    );
    // 每台客户端独占真实磁盘 SQLite。
    final OmniSyncRuntime runtime = await OmniSyncRuntime.openAtPath(
      auth,
      path.join(directory.path, 'client.sqlite'),
      initializeUpload: false,
    );
    device = _Device(directory, auth, runtime);
    // 服务端签发的真实 owner 和设备会话。
    final session = await auth.connect(
      apiBaseUrl: 'http://127.0.0.1:35530',
      syncKey: _secret,
    );
    await runtime.connect(session.identity.id, session: session);
    await runtime.catchUp();
    return device;
  }

  /// 用生产仓储选择图片。
  Future<void> select(String id, File file) async {
    await attachments.attachLocalFile(
      businessType: AttachmentBusinessType.inventoryImage,
      businessId: id,
      sourcePath: file.path,
      mimeType: 'image/png',
    );
  }

  /// 读取本机展示图片的实际内容。
  Future<List<int>?> bytes(String id) async {
    // 当前业务主图路径。
    final row = await (runtime.database.select(
      runtime.database.inventoryItems,
    )..where((table) => table.id.equals(id))).getSingle();
    return row.imageLocalPath == null
        ? null
        : File(row.imageLocalPath!).readAsBytes();
  }

  /// 模拟后台任务重启，保留 SQLite 待办状态。
  Future<void> restartImages() async {
    await images.stop();
    images = ImageSyncService(
      database: runtime.database,
      auth: auth,
      directoryProvider: () async => directory,
    );
  }

  /// 排空任务并关闭连接。
  Future<void> close() async {
    await images.stop();
    await runtime.close();
  }
}

/// 验证真实 API、MinIO、PowerSync 和三份本机数据库。
void main() {
  _NetworkBinding();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  test(
    '三客户端图片补传下载、丢响应重试、离线缓存及清空标记',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      // 仅创建临时测试文件，不接触应用真实目录。
      final Directory root = await Directory.systemTemp.createTemp(
        'omni-image-e2e-',
      );
      // 按打开顺序登记便于失败时释放。
      final List<_Device> devices = [];
      addTearDown(() async {
        for (final _Device device in devices.reversed) {
          await device.close();
        }
        await root.delete(recursive: true);
      });
      // 第一台客户端创建唯一业务记录。
      final _Device a = await _Device.open(root, 'a');
      devices.add(a);
      final String id = const Uuid().v4();
      final DateTime now = DateTime.now();
      await a.runtime.database
          .into(a.runtime.database.inventoryItems)
          .insert(
            InventoryItemsCompanion.insert(
              id: id,
              name: '图片真实链路测试',
              createdAt: now,
              updatedAt: now,
            ),
          );
      await a.runtime.catchUp();
      // 生成能被真实服务端解码校验的两张不同图片。
      final File red = File(path.join(root.path, 'red.png'));
      final File blue = File(path.join(root.path, 'blue.png'));
      await red.writeAsBytes(
        img.encodePng(
          img.fill(
            img.Image(width: 2, height: 2),
            color: img.ColorRgb8(255, 0, 0),
          ),
        ),
      );
      await blue.writeAsBytes(
        img.encodePng(
          img.fill(
            img.Image(width: 2, height: 2),
            color: img.ColorRgb8(0, 0, 255),
          ),
        ),
      );
      await a.select(id, red);
      await a.images.runOnce();
      expect(a.images.state.error, isNull, reason: '${a.lastFailure}');
      // 第二台通过真实复制获取业务，再自动下载图片。
      final _Device b = await _Device.open(root, 'b');
      devices.add(b);
      await b.images.runOnce();
      expect(b.images.state.error, isNull);
      expect(await b.bytes(id), await red.readAsBytes());
      // 第三台携带历史图片，但尚未见过服务器图片清单。
      final _Device c = await _Device.open(root, 'c');
      devices.add(c);
      await c.select(id, red);
      // 主动换图在服务器提交后丢响应，重建任务仍用原操作 ID 重试。
      await a.select(id, blue);
      a.loseResponse = true;
      await a.images.runOnce();
      expect(a.images.state.failed, 1);
      await a.restartImages();
      await a.images.runOnce();
      expect(a.images.state.error, isNull);
      expect(
        a.uploadIds[a.uploadIds.length - 1],
        a.uploadIds[a.uploadIds.length - 2],
      );
      await b.images.runOnce();
      expect(await b.bytes(id), await blue.readAsBytes());
      // 断网时图片仍能直接读取，主动编辑持久保存待恢复。
      b.offline = true;
      await b.images.runOnce();
      expect(b.images.state.error, isNotNull);
      expect(await b.bytes(id), await blue.readAsBytes());
      await b.select(id, red);
      await b.restartImages();
      b.offline = false;
      await b.images.runOnce();
      expect(b.images.state.error, isNull);
      await a.images.runOnce();
      expect(await a.bytes(id), await red.readAsBytes());
      // 明确清空后，历史设备的旧图不得重新补传复活。
      await b.attachments.removeCurrent(
        businessType: AttachmentBusinessType.inventoryImage,
        businessId: id,
      );
      await b.images.runOnce();
      expect(b.images.state.error, isNull);
      await c.images.runOnce();
      expect(c.images.state.error, isNull);
      expect(c.uploadIds, isEmpty);
      expect(await c.bytes(id), isNull);
      await a.images.runOnce();
      expect(await a.bytes(id), isNull);
    },
    skip: !_enabled,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
