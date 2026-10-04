import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/features/floating/platform/floating_resize_scheduler.dart';

/// 验证提交与原生绘制完成同步，不依赖固定延迟。
void main() {
  test('同一事件轮只提交最新矩形且无需等待16ms', () async {
    // 模拟指针最新位置。
    int cursor = 0;
    // 实际提交的位置列表。
    final List<int> applied = <int>[];
    // 异步尺寸提交器。
    final FloatingResizeScheduler scheduler = FloatingResizeScheduler(() async {
      applied.add(cursor);
    });
    for (int index = 1; index <= 20; index += 1) {
      cursor = index;
      unawaited(scheduler.schedule());
    }
    expect(applied, isEmpty);
    await scheduler.flush();
    expect(applied, <int>[20]);
    scheduler.dispose();
  });

  test('原生更新期间只保留最新请求并且没有并行提交', () async {
    // 控制第一次原生更新何时完成。
    final Completer<void> nativeFrame = Completer<void>();
    // 当前指针位置。
    int cursor = 1;
    // 实际提交的位置。
    final List<int> applied = <int>[];
    // 当前并行提交数。
    int active = 0;
    // 尺寸提交器。
    final FloatingResizeScheduler scheduler = FloatingResizeScheduler(() async {
      active += 1;
      expect(active, 1);
      applied.add(cursor);
      if (applied.length == 1) await nativeFrame.future;
      active -= 1;
    });
    // 第一次更新的完成信号。
    final Future<void> updating = scheduler.schedule();
    await Future<void>.delayed(Duration.zero);
    cursor = 2;
    unawaited(scheduler.schedule());
    cursor = 3;
    unawaited(scheduler.schedule());
    expect(applied, <int>[1]);
    nativeFrame.complete();
    await updating;
    expect(applied, <int>[1, 3]);
    scheduler.dispose();
  });

  test('松开时等待最新矩形落地，之后才保存位置尺寸', () async {
    // 当前未完成的原生绘制。
    final Completer<void> nativeFrame = Completer<void>();
    // 是否已经提交最终矩形。
    bool saved = false;
    // 尺寸更新器。
    final FloatingResizeScheduler scheduler = FloatingResizeScheduler(
      () => nativeFrame.future,
    );
    unawaited(scheduler.schedule());
    // 模拟结束回调必须等待最终原生更新。
    final Future<void> ending = scheduler.flush().then((_) => saved = true);
    await Future<void>.delayed(Duration.zero);
    expect(saved, false);
    nativeFrame.complete();
    await ending;
    expect(saved, true);
    scheduler.dispose();
  });

  test('关闭丢弃待提交请求，已开始的请求完成后不再继续', () async {
    // 当前原生更新的完成信号。
    final Completer<void> nativeFrame = Completer<void>();
    // 实际提交次数。
    int calls = 0;
    // 尺寸更新器。
    final FloatingResizeScheduler scheduler = FloatingResizeScheduler(() async {
      calls += 1;
      await nativeFrame.future;
    });
    // 当前原生任务。
    final Future<void> updating = scheduler.schedule();
    await Future<void>.delayed(Duration.zero);
    unawaited(scheduler.schedule());
    scheduler.dispose();
    nativeFrame.complete();
    await updating;
    await scheduler.schedule();
    await scheduler.flush();
    expect(calls, 1);
  });

  test('原生提交失败后可以继续下一次缩放', () async {
    // 累计调用次数。
    int calls = 0;
    // 可重试的尺寸更新器。
    final FloatingResizeScheduler scheduler = FloatingResizeScheduler(() async {
      calls += 1;
      if (calls == 1) throw StateError('模拟原生失败');
    });
    await expectLater(scheduler.schedule(), throwsStateError);
    await scheduler.schedule();
    expect(calls, 2);
    scheduler.dispose();
  });
}
