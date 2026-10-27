import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/audio/microphone_coordinator.dart';
import 'package:omni_butler/features/assistant/data/assistant_voice_controller.dart';
import 'package:omni_butler/features/assistant/data/assistant_voice_preferences.dart';

import 'support/assistant_voice_fakes.dart';

import 'package:shared_preferences/shared_preferences.dart';

/// 隔离单次录音和可见草稿。
class _Harness {
  /// 测试设备锁。
  final MicrophoneCoordinator mic = MicrophoneCoordinator();

  /// 测试采集实例。
  final FakeVoiceRecorder recorder = FakeVoiceRecorder();

  /// 测试网络连接。
  final FakeSpeechConnection connection = FakeSpeechConnection();

  /// 实际控制器。
  late final AssistantVoiceController voice;

  /// 当前输入值。
  TextEditingValue value;

  /// 来源/页面是否仍有效。
  bool current = true;

  /// 自动发送次数。
  int sent = 0;

  /// 发送是否模拟失败。
  bool failSend = false;

  /// 构造真实控制器和假设备。
  _Harness({
    this.value = const TextEditingValue(
      text: '前后',
      selection: TextSelection.collapsed(offset: 1),
    ),
    Duration timeout = const Duration(seconds: 10),
  }) {
    voice = AssistantVoiceController(
      microphone: mic,
      beforeAcquire: () async {},
      createRecorder: () => recorder,
      connect: () async => connection,
      onText: (TextEditingValue next) => value = next,
      timeout: timeout,
    );
  }

  /// 启动后由测试显式决定握手就绪。
  Future<void> start({bool autoSend = false}) => voice.start(
    initial: value,
    autoSend: autoSend,
    isCurrent: () => current,
    send: () async {
      sent++;
      if (failSend) throw StateError('发送失败');
    },
  );

  /// 建立完整正常采集过程。
  Future<void> ready({bool autoSend = false}) async {
    // 启动操作等待上游ready事件。
    final Future<void> startup = start(autoSend: autoSend);
    await _turn();
    expect(recorder.starts, 0);
    connection.output.add(<String, dynamic>{'type': 'ready'});
    await startup;
    expect(voice.phase, AssistantVoicePhase.recording);
  }

  /// 测试结束释放全部资源和广播流。
  Future<void> close() async {
    await voice.cancel();
    voice.dispose();
    await recorder.audio.close();
    await connection.output.close();
  }
}

/// 让网络与设备的微任务链完成，不依赖真实外部服务。
Future<void> _turn() async {
  for (int i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// 覆盖终态、草稿、设备占用与本机偏好的运行时契约。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('光标插入与中间结果替换，默认只留草稿', () async {
    // 包含前后文的真实输入快照。
    final _Harness h = _Harness();
    addTearDown(h.close);
    await h.ready();
    h.connection.text('今天');
    h.connection.text('今天开会');
    expect(h.value.text, '前今天开会后');
    expect(h.value.selection.baseOffset, 5);
    await h.voice.finish();
    expect(h.voice.phase, AssistantVoicePhase.finishing);
    expect(h.mic.isOccupied, isFalse);
    expect(h.sent, 0);
    h.connection.complete('今天开会。');
    await _turn();
    expect(h.value.text, '前今天开会。后');
    expect(h.voice.busy, isFalse);
    expect(h.sent, 0);
  });

  test('替换选区并且仅最终成功后自动发送一次', () async {
    // 选中旧词，语音只替换选区。
    final _Harness h = _Harness(
      value: const TextEditingValue(
        text: '前旧词后',
        selection: TextSelection(baseOffset: 1, extentOffset: 3),
      ),
    );
    addTearDown(h.close);
    await h.ready(autoSend: true);
    h.connection.text('新词');
    expect(h.value.text, '前新词后');
    expect(h.sent, 0);
    await h.voice.finish();
    h.connection.complete('新词');
    h.connection.complete('重复');
    await _turn();
    expect(h.sent, 1);
    expect(h.value.text, '前新词后');
  });

  test('空识别恢复完整原文和选区，不发送已有草稿', () async {
    // 空结果不能删除原选区。
    final TextEditingValue original = const TextEditingValue(
      text: '保留原草稿',
      selection: TextSelection(baseOffset: 1, extentOffset: 4),
    );
    // 已有文字也不能误触发发送。
    final _Harness h = _Harness(value: original);
    addTearDown(h.close);
    await h.ready(autoSend: true);
    await h.voice.finish();
    h.connection.complete('');
    await _turn();
    expect(h.value, original);
    expect(h.sent, 0);
    expect(h.voice.message, contains('未识别到'));
  });

  test('取消保留最后可见文字，迟到final不写入不发送', () async {
    // 模拟导航取消。
    final _Harness h = _Harness();
    addTearDown(h.close);
    await h.ready(autoSend: true);
    h.connection.text('保留');
    await h.voice.cancel();
    h.current = false;
    h.connection.complete('不能出现');
    await _turn();
    expect(h.value.text, '前保留后');
    expect(h.sent, 0);
    expect(h.mic.isOccupied, isFalse);
  });

  test('等待权限时取消，迟到授权不会重新开麦', () async {
    // 权限对话框模拟挂起。
    final Completer<bool> permission = Completer<bool>();
    // 停止过程必须等权限回执才能释放占用。
    final _Harness h = _Harness();
    addTearDown(h.close);
    h.recorder.permission = permission.future;
    // 先开始异步准备。
    final Future<void> startup = h.start();
    await _turn();
    expect(h.mic.isOccupied, isTrue);
    // 取消同步隔离回调，但暂不释放设备。
    final Future<void> cancellation = h.voice.cancel();
    expect(h.mic.isOccupied, isTrue);
    permission.complete(true);
    await startup;
    await cancellation;
    expect(h.recorder.starts, 0);
    expect(h.mic.isOccupied, isFalse);
  });

  test('原生启动回执迟到，取消后停止设备并释放锁', () async {
    // 模拟已经启动但尚未响应Dart的原生调用。
    final _Harness h = _Harness();
    addTearDown(h.close);
    h.recorder.startGate = Completer<void>();
    // 开始操作仍在准备中。
    final Future<void> startup = h.start();
    await _turn();
    h.connection.output.add(<String, dynamic>{'type': 'ready'});
    await _turn();
    expect(h.recorder.starts, 1);
    // 暂时保持麦克风所有权。
    final Future<void> cancellation = h.voice.cancel();
    expect(h.mic.isOccupied, isTrue);
    h.recorder.startGate!.complete();
    await startup;
    await cancellation;
    expect(h.recorder.stops, greaterThanOrEqualTo(1));
    expect(h.recorder.disposals, 1);
    expect(h.mic.isOccupied, isFalse);
  });

  test('路由与窗口重复取消都等待迟到启动和实际停麦', () async {
    // 两个生命周期入口同时取消同一录音。
    final _Harness h = _Harness();
    addTearDown(h.close);
    h.recorder.startGate = Completer<void>();
    // 原生启动尚未回执。
    final Future<void> startup = h.start();
    await _turn();
    h.connection.output.add(<String, dynamic>{'type': 'ready'});
    await _turn();
    // 记录两个调用是否过早返回。
    bool firstDone = false;
    bool secondDone = false;
    // 路由先触发取消。
    final Future<void> first = h.voice.cancel().then((_) => firstDone = true);
    // 隐藏或退出必须共享同一个等待过程。
    final Future<void> second = h.voice.cancel().then((_) => secondDone = true);
    await _turn();
    expect(firstDone, isFalse);
    expect(secondDone, isFalse);
    h.recorder.startGate!.complete();
    await startup;
    await Future.wait(<Future<void>>[first, second]);
    expect(h.recorder.disposals, 1);
    expect(h.mic.isOccupied, isFalse);
  });

  test('合并草稿超限保留最后有效文字并拒绝自动发送', () async {
    // 已有草稿接近接口上限。
    final String original = '字' * 19995;
    // 光标在末尾时仍需校验合并总长。
    final _Harness h = _Harness(
      value: TextEditingValue(
        text: original,
        selection: const TextSelection.collapsed(offset: 19995),
      ),
    );
    addTearDown(h.close);
    await h.ready(autoSend: true);
    h.connection.text('短句');
    h.connection.text('超过剩余空间的一句话');
    await _turn();
    expect(h.value.text, '$original短句');
    expect(h.sent, 0);
    expect(h.voice.message, contains('20000'));
  });

  test('停止和销毁均失败时保留占用并明确提示恢复措施', () async {
    // 原生插件异常不能放行另一入口抢占设备。
    final _Harness h = _Harness();
    addTearDown(h.close);
    await h.ready();
    h.recorder.failCleanup = true;
    await h.voice.cancel();
    expect(h.mic.isOccupied, isTrue);
    expect(h.voice.message, contains('重启应用'));
  });

  test('权限拒绝和笔记录音占用都不会连接收费识别', () async {
    // 模拟权限拒绝。
    final _Harness denied = _Harness();
    addTearDown(denied.close);
    denied.recorder.permission = Future<bool>.value(false);
    await denied.start();
    expect(denied.voice.message, contains('权限'));
    expect(denied.recorder.starts, 0);
    expect(denied.mic.isOccupied, isFalse);
    // 已有笔记占用不允许抢占。
    final _Harness occupied = _Harness();
    addTearDown(occupied.close);
    // 笔记保有独立令牌。
    final Object note = Object();
    occupied.mic.tryAcquire(note);
    await occupied.start();
    expect(occupied.voice.message, contains('笔记录音'));
    expect(occupied.mic.isOccupied, isTrue);
    occupied.mic.release(note);
  });

  test('end后断连不能当作完成，转写草稿可恢复', () async {
    // 手动结束后仍缺少整次完成。
    final _Harness h = _Harness();
    addTearDown(h.close);
    await h.ready(autoSend: true);
    h.connection.text('待检查');
    await h.voice.finish();
    h.connection.output.addError(StateError('网络故障'));
    await _turn();
    expect(h.sent, 0);
    expect(h.value.text, '前待检查后');
    expect(h.voice.message, contains('断开'));
  });

  test('最终结果超时后不发送，迟到完成不能覆盖', () async {
    // 缩短最终等待避免测试真实十秒。
    final _Harness h = _Harness(timeout: const Duration(milliseconds: 50));
    addTearDown(h.close);
    await h.ready(autoSend: true);
    h.connection.text('待检查');
    await h.voice.finish();
    await Future<void>.delayed(const Duration(milliseconds: 70));
    await _turn();
    h.connection.complete('迟到');
    expect(h.sent, 0);
    expect(h.value.text, '前待检查后');
    expect(h.voice.message, contains('超时'));
  });

  test('上游主动限时完成保留草稿，不自动发送', () async {
    // 用户没有主动结束。
    final _Harness h = _Harness();
    addTearDown(h.close);
    await h.ready(autoSend: true);
    h.connection.complete('达到限额', reason: 'limit');
    await _turn();
    expect(h.sent, 0);
    expect(h.voice.message, contains('上限'));
    expect(h.mic.isOccupied, isFalse);
  });

  test('发送失败保留转写文字，不再次发送', () async {
    // 模拟原消息发送链路失败。
    final _Harness h = _Harness()..failSend = true;
    addTearDown(h.close);
    await h.ready(autoSend: true);
    await h.voice.finish();
    h.connection.complete('失败仍保留');
    await _turn();
    expect(h.sent, 1);
    expect(h.value.text, '前失败仍保留后');
    expect(h.voice.message, contains('自动发送未完成'));
  });

  test('PCM按6400字节发送，结束时发送剩余完整采样', () async {
    // 合成一包加尾包，不访问音频设备。
    final _Harness h = _Harness();
    addTearDown(h.close);
    await h.ready();
    h.recorder.audio.add(
      Uint8List.fromList(List<int>.generate(6600, (int index) => index % 256)),
    );
    await Future<void>.delayed(const Duration(milliseconds: 230));
    await h.voice.finish();
    expect(h.connection.packets.map((Uint8List packet) => packet.length), <int>[
      6400,
      200,
    ]);
    expect(
      h.connection.packets.expand((Uint8List packet) => packet).toList(),
      List<int>.generate(6600, (int index) => index % 256),
    );
    expect(h.connection.endings, <bool>[true]);
  });

  test('异常大音频块不会无限堆积', () async {
    // 一个超过缓冲预算的异常设备回调。
    final _Harness h = _Harness();
    addTearDown(h.close);
    await h.ready(autoSend: true);
    h.recorder.audio.add(Uint8List(65538));
    await _turn();
    expect(h.voice.busy, isFalse);
    expect(h.sent, 0);
    expect(h.mic.isOccupied, isFalse);
  });

  test('本机自动发送默认关闭，重建后保留且设备间独立', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 第一个设备偏好。
    final SharedPreferences first = await SharedPreferences.getInstance();
    // 第一个应用容器。
    final ProviderContainer container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(first)],
    );
    expect(container.read(assistantVoicePreferenceProvider), isFalse);
    await container
        .read(assistantVoicePreferenceProvider.notifier)
        .setEnabled(true);
    container.dispose();
    // 同设备重启后恢复。
    final ProviderContainer restored = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(first)],
    );
    expect(restored.read(assistantVoicePreferenceProvider), isTrue);
    restored.dispose();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 第二台设备使用独立本机存储。
    final SharedPreferences second = await SharedPreferences.getInstance();
    // 不读取第一个设备的开关。
    final ProviderContainer other = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(second)],
    );
    expect(other.read(assistantVoicePreferenceProvider), isFalse);
    other.dispose();
  });
}
