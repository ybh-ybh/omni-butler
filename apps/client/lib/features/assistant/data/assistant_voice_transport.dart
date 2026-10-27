import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/features/assistant/data/assistant_repository.dart';
import 'package:record/record.dart';

/// 可替换的实时连接，测试不访问收费语音服务。
abstract class AssistantSpeechConnection {
  /// 服务端状态和完整转写快照。
  Stream<Map<String, dynamic>> get events;

  /// 按实时节奏发送PCM，不缓存整段录音。
  Future<void> sendAudio(Uint8List bytes);

  /// 请求最终转写。
  void finish({required bool manual});

  /// 取消本次识别。
  void cancel();

  /// 释放网络资源。
  Future<void> close();
}

/// 仅连接当前应用服务器，腾讯密钥不会到达客户端。
class AssistantWebSocketSpeech implements AssistantSpeechConnection {
  /// 当前鉴权连接。
  final WebSocket _socket;

  /// 固定来源，迟到令牌不可连接其他服务器。
  final AssistantRepository _repository;

  /// 包装已完成HTTP握手的连接。
  AssistantWebSocketSpeech._(this._socket, this._repository);

  /// 每次获取新鲜设备令牌，路径保留完整API前缀。
  static Future<AssistantSpeechConnection> connect(
    AssistantRepository repository,
    String apiBaseUrl,
  ) async {
    if (!repository.isCurrent) throw const ApiFailure('服务器已切换');
    // 设备令牌只置于请求头。
    final String token = await repository.auth.ensureAccessToken(
      baseUrl: apiBaseUrl,
    );
    if (!repository.isCurrent) throw const ApiFailure('服务器已切换');
    // 不使用resolve的绝对路径，避免丢失反向代理前缀。
    final Uri base = Uri.parse(apiBaseUrl);
    if (!<String>{'http', 'https'}.contains(base.scheme)) {
      throw const ApiFailure('服务器地址无效');
    }
    // WebSocket沿用服务器的传输安全等级。
    final Uri uri = Uri(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      host: base.host,
      port: base.hasPort ? base.port : null,
      path:
          '${base.path.replaceFirst(RegExp(r'/+$'), '')}/assistant/speech/stream',
    );
    // 超时后关闭迟到成功的握手，避免孤儿连接。
    bool expired = false;
    try {
      // 不允许底层异常携带鉴权地址进入UI。
      final WebSocket socket =
          await WebSocket.connect(
                uri.toString(),
                headers: <String, String>{
                  HttpHeaders.authorizationHeader: 'Bearer $token',
                },
                compression: CompressionOptions.compressionOff,
              )
              .then((WebSocket socket) {
                if (expired || !repository.isCurrent) {
                  unawaited(socket.close());
                  throw const ApiFailure('语音连接已取消');
                }
                return socket;
              })
              .timeout(const Duration(seconds: 10));
      socket.pingInterval = const Duration(seconds: 15);
      return AssistantWebSocketSpeech._(socket, repository);
    } catch (_) {
      expired = true;
      throw const ApiFailure('无法连接语音服务，请检查网络和服务端版本');
    }
  }

  /// 严格限制接收大小，不输出服务端原始响应。
  @override
  Stream<Map<String, dynamic>> get events => _socket.map((Object? data) {
    if (!_repository.isCurrent) throw const ApiFailure('服务器已切换');
    if (data is! String || data.length > 131072) {
      throw const ApiFailure('语音服务返回无效数据');
    }
    // 只接收JSON对象，业务字段由控制器核验。
    final Object? decoded = jsonDecode(data);
    if (decoded is! Map<String, dynamic>) throw const ApiFailure('语音服务返回无效数据');
    return decoded;
  });

  /// 串行发送由控制器负责，超时使本次识别失败。
  @override
  Future<void> sendAudio(Uint8List bytes) async {
    if (!_repository.isCurrent || _socket.readyState != WebSocket.open) {
      throw const ApiFailure('语音连接已断开');
    }
    await _socket
        .addStream(Stream<Uint8List>.value(bytes))
        .timeout(const Duration(seconds: 2));
  }

  /// 手动结束和限额结束采用不同原因。
  @override
  void finish({required bool manual}) => _socket.add(
    jsonEncode(<String, String>{
      'type': 'end',
      'reason': manual ? 'manual' : 'limit',
    }),
  );

  /// 取消不请求最终结果，也不触发发送。
  @override
  void cancel() {
    if (_socket.readyState == WebSocket.open) _socket.add('{"type":"cancel"}');
  }

  /// 收尾最多等待一秒，不让退出依赖网络可达。
  @override
  Future<void> close() async {
    try {
      await _socket.close().timeout(const Duration(seconds: 1));
    } catch (_) {}
  }
}

/// 可注入的麦克风采集边界。
abstract class AssistantVoiceRecorder {
  /// 只在用户点击后申请权限。
  Future<bool> hasPermission();

  /// 输出16kHz单声道16-bit PCM。
  Future<Stream<Uint8List>> start();

  /// 实际停止采集后才能释放麦克风占用。
  Future<void> stop();

  /// 销毁本次插件实例。
  Future<void> dispose();
}

/// 助手采集不沿用笔记的WAV文件和后台服务。
class AssistantRecordVoice implements AssistantVoiceRecorder {
  /// 每次语音独立的插件实例。
  final AudioRecorder _recorder = AudioRecorder();

  /// 请求系统权限。
  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  /// 直接取得PCM流，不创建临时音频文件。
  @override
  Future<Stream<Uint8List>> start() => _recorder.startStream(
    const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
    ),
  );

  /// 停止插件的真实设备采集。
  @override
  Future<void> stop() async {
    await _recorder.stop();
  }

  /// 销毁原生资源。
  @override
  Future<void> dispose() => _recorder.dispose();
}
