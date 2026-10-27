import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/audio/microphone_coordinator.dart';

/// 验证两个业务入口的真实占用竞争及窗口取消的等待边界。
void main() {
  test('两个入口互斥且旧身份不能释放新会话', () {
    // 应用级唯一协调器。
    final MicrophoneCoordinator coordinator = MicrophoneCoordinator();
    // 两个独立业务采集的身份。
    final Object note = Object();
    // 下一次助手采集身份。
    final Object voice = Object();
    expect(coordinator.tryAcquire(note), isTrue);
    expect(coordinator.tryAcquire(voice), isFalse);
    coordinator.release(voice);
    expect(coordinator.isOccupied, isTrue);
    coordinator.release(note);
    expect(coordinator.tryAcquire(voice), isTrue);
    coordinator.release(note);
    expect(coordinator.isOccupied, isTrue);
    coordinator.release(voice);
    expect(coordinator.isOccupied, isFalse);
  });

  test('隐藏和退出合并取消，直到草稿落盘回执后才完成', () async {
    // 窗口宿主使用的生命周期桥。
    final VoiceInputLifecycle lifecycle = VoiceInputLifecycle();
    // 当前页面身份。
    final Object owner = Object();
    // 模拟尚未完成的真实保存。
    final Completer<void> flushed = Completer<void>();
    // 确认重复事件不会执行第二次取消。
    int calls = 0;
    lifecycle.register(owner, () {
      calls++;
      return flushed.future;
    });
    // 几乎同时到达的隐藏与退出信号。
    final Future<void> hidden = lifecycle.cancelAll();
    // 第二个调用应复用同一过程。
    final Future<void> exiting = lifecycle.cancelAll();
    expect(identical(hidden, exiting), isTrue);
    expect(calls, 1);
    // 退出尚不能继续销毁窗口。
    bool completed = false;
    unawaited(exiting.then((_) => completed = true));
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    lifecycle.unregister(owner);
    flushed.complete();
    await exiting;
    expect(completed, isTrue);
    await lifecycle.cancelAll();
    expect(calls, 1);
  });

  test('草稿保存失败阻止窗口操作但下次可重试', () async {
    // 当前窗口语音桥。
    final VoiceInputLifecycle lifecycle = VoiceInputLifecycle();
    // 测试页面身份。
    final Object owner = Object();
    lifecycle.register(owner, () async => throw StateError('保存失败'));
    await expectLater(lifecycle.cancelAll(), throwsStateError);
    lifecycle.register(owner, () async {});
    await lifecycle.cancelAll();
  });
}
