import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/features/assistant/data/assistant_repository.dart';
import 'package:omni_butler/features/assistant/data/assistant_voice_transport.dart';

/// 只替换令牌存储，传输层仍建立真实本地 WebSocket。
class _Auth implements AuthRepository {
  /// 可推进的来源代次。
  int generation = 1;

  /// 记录令牌请求绑定的服务器。
  String? requestedBase;

  /// 当前设备来源。
  @override
  int get sessionGeneration => generation;

  /// 返回不具备任何真实权限的测试令牌。
  @override
  Future<String> ensureAccessToken({String? baseUrl}) async {
    requestedBase = baseUrl;
    return 'synthetic-device-token';
  }

  /// 测试不使用其他认证能力。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 验证真实 URI、鉴权请求头、二进制音频及控制消息编码。
void main() {
  test('真实WebSocket保留API前缀且无查询参数，PCM与结束标记双向贯通', () async {
    // 仅监听回环地址，不访问真实服务商。
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    // 保留升级请求用于精确路径和令牌位置断言。
    final Completer<HttpRequest> upgrade = Completer<HttpRequest>();
    // 远端连接用于注入真实协议事件。
    final Completer<WebSocket> peerReady = Completer<WebSocket>();
    server.listen((HttpRequest request) async {
      upgrade.complete(request);
      peerReady.complete(await WebSocketTransformer.upgrade(request));
    });
    // 合成认证不读取本机安全存储。
    final _Auth auth = _Auth();
    // 正式仓储保留来源代次规则。
    final AssistantRepository repository = AssistantRepository(auth);
    // 路径包含代理前缀和尾斜线。
    final String base = 'http://127.0.0.1:${server.port}/omni-butler/api/v1/';
    // 正式传输实现建立真实升级连接。
    final AssistantSpeechConnection connection =
        await AssistantWebSocketSpeech.connect(repository, base);
    // 请求不能带空问号，否则服务端精确路由会拒绝。
    final HttpRequest request = await upgrade.future;
    expect(
      request.uri.toString(),
      '/omni-butler/api/v1/assistant/speech/stream',
    );
    expect(
      request.headers.value(HttpHeaders.authorizationHeader),
      'Bearer synthetic-device-token',
    );
    expect(auth.requestedBase, base);
    // 使用流迭代器严格核对消息先后顺序。
    final WebSocket peer = await peerReady.future;
    // 从客户端收到的原始 WebSocket 帧。
    final StreamIterator<dynamic> incoming = StreamIterator<dynamic>(peer);
    // 客户端解码后的应用协议。
    final StreamIterator<Map<String, dynamic>> events = StreamIterator(
      connection.events,
    );
    try {
      peer.add('{"type":"ready"}');
      expect(await events.moveNext(), isTrue);
      expect(events.current['type'], 'ready');
      await connection.sendAudio(Uint8List.fromList(<int>[0, 1, 2, 3]));
      expect(await incoming.moveNext(), isTrue);
      expect(incoming.current, <int>[0, 1, 2, 3]);
      connection.finish(manual: true);
      expect(await incoming.moveNext(), isTrue);
      expect(jsonDecode(incoming.current as String), <String, String>{
        'type': 'end',
        'reason': 'manual',
      });
      peer.add('{"type":"completed","text":"你好","reason":"manual"}');
      expect(await events.moveNext(), isTrue);
      expect(events.current['text'], '你好');
      auth.generation++;
      await expectLater(
        connection.sendAudio(Uint8List(2)),
        throwsA(isA<ApiFailure>()),
      );
    } finally {
      await events.cancel();
      await incoming.cancel();
      await connection.close();
      await peer.close();
      await server.close(force: true);
    }
  });
}
