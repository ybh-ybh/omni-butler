import 'dart:async';
import 'dart:typed_data';

import 'package:omni_butler/features/assistant/data/assistant_voice_transport.dart';

/// 可延迟权限或启动回执的采集器，不访问系统麦克风。
class FakeVoiceRecorder implements AssistantVoiceRecorder {
  /// 有界合成PCM来源。
  final StreamController<Uint8List> audio =
      StreamController<Uint8List>.broadcast(sync: true);

  /// 受控权限返回。
  Future<bool> permission = Future<bool>.value(true);

  /// 允许模拟权限通过后的原生启动挂起。
  Completer<void>? startGate;

  /// 真实开启次数。
  int starts = 0;

  /// 实际释放设备次数。
  int stops = 0;

  /// 资源销毁次数。
  int disposals = 0;

  /// 模拟设备停止和销毁均失败，验证占用不能提前释放。
  bool failCleanup = false;

  /// 返回测试指定权限。
  @override
  Future<bool> hasPermission() => permission;

  /// 模拟原生异步开麦。
  @override
  Future<Stream<Uint8List>> start() async {
    starts++;
    await startGate?.future;
    return audio.stream;
  }

  /// 停止设备。
  @override
  Future<void> stop() async {
    stops++;
    if (failCleanup) throw StateError('设备停止失败');
  }

  /// 记录资源清理。
  @override
  Future<void> dispose() async {
    disposals++;
    if (failCleanup) throw StateError('设备销毁失败');
  }
}

/// 模拟应用服务器，只有显式事件能完成识别。
class FakeSpeechConnection implements AssistantSpeechConnection {
  /// 主动控制句子和完成顺序。
  final StreamController<Map<String, dynamic>> output =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);

  /// 已发送的完整音频包。
  final List<Uint8List> packets = <Uint8List>[];

  /// 实际结束请求的原因。
  final List<bool> endings = <bool>[];

  /// 清理次数。
  int closes = 0;

  /// 受控服务端事件。
  @override
  Stream<Map<String, dynamic>> get events => output.stream;

  /// 保留字节副本供采样顺序核对。
  @override
  Future<void> sendAudio(Uint8List bytes) async {
    packets.add(Uint8List.fromList(bytes));
  }

  /// 结束请求不擅自模拟成功。
  @override
  void finish({required bool manual}) {
    endings.add(manual);
  }

  /// 取消无需响应。
  @override
  void cancel() {}

  /// 断开后仍可注入迟到事件验证控制器隔离。
  @override
  Future<void> close() async {
    closes++;
  }

  /// 注入完整当前转写。
  void text(String text) =>
      output.add(<String, dynamic>{'type': 'transcript', 'text': text});

  /// 注入整次完成信号。
  void complete(String text, {String reason = 'manual'}) => output.add(
    <String, dynamic>{'type': 'completed', 'text': text, 'reason': reason},
  );
}
