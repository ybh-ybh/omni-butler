import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/features/assistant/data/assistant_models.dart';
import 'package:omni_butler/features/assistant/data/assistant_repository.dart';

/// 使用 Dio 的真实 Uint8List 响应类型，不访问网络或真实凭证。
class _EventStreamAdapter implements HttpClientAdapter {
  /// 分片输入保持开启，测试首段正文不依赖 HTTP 响应结束。
  final StreamController<Uint8List> bytes = StreamController<Uint8List>();

  /// 记录鉴权与恢复游标，验证使用真实仓储请求路径。
  final List<RequestOptions> requests = <RequestOptions>[];

  /// 返回保持连接的 SSE 响应，使 Dio 执行真实传输结果转换。
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody(
      bytes.stream,
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['text/event-stream; charset=utf-8'],
      },
    );
  }

  /// 字节流由测试清理，不让客户端关闭覆盖增量读取断言。
  @override
  void close({bool force = false}) {}
}

/// 附件接口使用真实 Dio multipart 与二进制响应转换，但不访问网络。
class _AttachmentAdapter implements HttpClientAdapter {
  /// 请求头和路径用于核对私有设备认证。
  final List<RequestOptions> requests = <RequestOptions>[];

  /// 收到的 multipart 字节用于核对字段名及上传内容。
  final List<int> uploaded = <int>[];

  /// 返回原件或稳定上传回执。
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (requestStream != null) {
      await for (final Uint8List chunk in requestStream) {
        uploaded.addAll(chunk);
      }
    }
    if (options.path.endsWith('/file')) {
      return ResponseBody.fromBytes(
        <int>[0, 1, 255],
        200,
        headers: <String, List<String>>{
          'content-type': <String>['application/octet-stream'],
        },
      );
    }
    return ResponseBody.fromString(
      '{"id":"upload-id","status":"processing"}',
      200,
      headers: <String, List<String>>{
        'content-type': <String>['application/json'],
      },
    );
  }

  /// 本替身不持有实际连接。
  @override
  void close({bool force = false}) {}
}

/// 覆盖原生 Dio 字节类型与首段到达时间，防止模拟仓储掩盖断流错误。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('私有附件上传使用 multipart file，下载走设备认证二进制接口', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'sync.device_session': jsonEncode(<String, dynamic>{
        'baseUrl': 'https://assistant.example/omni-butler/api/v1',
        'accessToken': 'test-access',
        'refreshToken': 'test-device',
        'expiresAt': DateTime.now()
            .add(const Duration(hours: 1))
            .toIso8601String(),
        'identity': <String, String>{'sub': 'test-owner'},
      }),
    });
    // 真实 Dio 数据转换入口。
    final _AttachmentAdapter adapter = _AttachmentAdapter();
    // 使用隔离安全存储中的合成设备会话。
    final AuthRepository auth = AuthRepository(
      const FlutterSecureStorage(),
      clientFactory: (String baseUrl) =>
          Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter,
    );
    // 正式仓储构造 multipart，不在测试中替换请求方法。
    final AssistantRepository repository = AssistantRepository(auth);
    await repository.request(
      'PUT',
      '/conversations/conversation/attachments/upload-id',
      data: FormData.fromMap(<String, dynamic>{
        'file': MultipartFile.fromBytes(<int>[
          65,
          66,
          67,
        ], filename: 'sample.txt'),
      }),
    );
    expect(
      utf8.decode(adapter.uploaded),
      contains('name="file"; filename="sample.txt"'),
    );
    expect(utf8.decode(adapter.uploaded), contains('ABC'));
    expect(await repository.attachmentBytes('upload-id'), <int>[0, 1, 255]);
    expect(adapter.requests.last.path, '/assistant/attachments/upload-id/file');
    expect(adapter.requests.last.responseType, ResponseType.bytes);
    expect(
      adapter.requests.every(
        (item) => item.headers['Authorization'] == 'Bearer test-access',
      ),
      isTrue,
    );
    expect(
      adapter.requests.every((item) => item.queryParameters.isEmpty),
      isTrue,
    );
  });

  test('Dio Uint8List SSE 在连接仍打开时逐段交付中文正文并保留恢复游标', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'sync.device_session': jsonEncode(<String, dynamic>{
        'baseUrl': 'https://assistant.example/omni-butler/api/v1',
        'accessToken': 'test-access',
        'refreshToken': 'test-device',
        'expiresAt': DateTime.now()
            .add(const Duration(hours: 1))
            .toIso8601String(),
        'identity': <String, String>{'sub': 'test-owner'},
      }),
    });
    // 内存适配器保留 Dio 的响应转换链和响应字节运行时类型。
    final _EventStreamAdapter adapter = _EventStreamAdapter();
    // 真实认证仓储读取隔离的测试安全存储，并逐次核对会话代次。
    final AuthRepository auth = AuthRepository(
      const FlutterSecureStorage(),
      clientFactory: (String baseUrl) =>
          Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter,
    );
    // 真实助手仓储负责将 HTTP 字节送入 SSE 解码器。
    final AssistantRepository repository = AssistantRepository(auth);
    // 当前请求的取消边界与正式客户端一致。
    final CancelToken token = auth.createSessionStreamToken(
      auth.sessionGeneration,
    );
    // 顺序读取器可以证明第一段到达时第二段和结束帧都尚未发送。
    final StreamIterator<AssistantEvent> events =
        StreamIterator<AssistantEvent>(repository.events('run', 7, token));
    addTearDown(() async {
      token.cancel('测试结束');
      await events.cancel();
      await adapter.bytes.close();
    });
    // 第一段在一个中文 UTF8 字符内部断开，模拟原生网络分片。
    final Uint8List first = Uint8List.fromList(
      utf8.encode(
        'id: 8\r\ndata: {"seq":8,"type":"message.delta","runId":"run","data":{"messageId":"answer","text":"你好"}}\r\n\r\n',
      ),
    );
    // 该位置落在第一个中文字节之后，必须由有状态 UTF8 解码器接续。
    final int split = first.indexOf(0xe4) + 1;
    // 先开始等待，响应主体仍然保持打开。
    final Future<bool> firstArrived = events.moveNext();
    adapter.bytes.add(Uint8List.sublistView(first, 0, split));
    adapter.bytes.add(Uint8List.sublistView(first, split));
    expect(await firstArrived.timeout(const Duration(seconds: 2)), isTrue);
    expect(adapter.bytes.isClosed, isFalse);
    expect(events.current.seq, 8);
    expect(events.current.data['text'], '你好');
    expect(adapter.requests.single.responseType, ResponseType.stream);
    expect(adapter.requests.single.queryParameters['after'], 7);
    expect(
      adapter.requests.single.headers['Authorization'],
      'Bearer test-access',
    );

    // 首段已经交付后才发送第二段，不能先缓冲完整回答再统一返回。
    final Future<bool> secondArrived = events.moveNext();
    adapter.bytes.add(
      Uint8List.fromList(
        utf8.encode(
          ': heartbeat\n\nid: 9\ndata: {"seq":9,"type":"message.delta","runId":"run","data":{"messageId":"answer","text":"，世界"}}\n\n',
        ),
      ),
    );
    expect(await secondArrived.timeout(const Duration(seconds: 2)), isTrue);
    expect(adapter.bytes.isClosed, isFalse);
    expect(events.current.seq, 9);
    expect(events.current.data['text'], '，世界');
    // 两段都已读到才允许正常结束 HTTP 响应。
    final Future<bool> finished = events.moveNext();
    await adapter.bytes.close();
    expect(await finished.timeout(const Duration(seconds: 2)), isFalse);
  });
}
