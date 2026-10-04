import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/features/floating/platform/floating_resize_scheduler.dart';

/// 验证高频事件、原生消息重入、最后位置提交和关闭后的取消。
void main() {
  testWidgets('同一帧的多次指针更新只提交最新位置', (WidgetTester tester) async {
    // 模拟鼠标最新位置。
    int cursor = 0;
    // 实际提交的位置列表。
    final List<int> applied = <int>[];
    // 尺寸更新器。
    final FloatingResizeScheduler scheduler = FloatingResizeScheduler(
      () => applied.add(cursor),
    );
    addTearDown(scheduler.dispose);
    for (int index = 1; index <= 20; index += 1) {
      cursor = index;
      scheduler.schedule();
    }
    expect(applied, isEmpty);
    await tester.pump(const Duration(milliseconds: 16));
    expect(applied, <int>[20]);
  });

  testWidgets('原生消息重入不会嵌套执行尺寸更新', (WidgetTester tester) async {
    // 当前嵌套提交深度。
    int depth = 0;
    // 最大嵌套提交深度。
    int maxDepth = 0;
    // 累计提交次数。
    int calls = 0;
    // 模拟可重入的原生提交器。
    late final FloatingResizeScheduler scheduler;
    scheduler = FloatingResizeScheduler(() {
      depth += 1;
      maxDepth = depth > maxDepth ? depth : maxDepth;
      calls += 1;
      if (calls == 1) {
        scheduler.flush();
      }
      depth -= 1;
    });
    addTearDown(scheduler.dispose);
    scheduler.flush();
    expect(calls, 1);
    await tester.pump(const Duration(milliseconds: 16));
    expect(calls, 2);
    expect(maxDepth, 1);
  });

  testWidgets('结束立即提交，销毁取消尚未提交的事件', (WidgetTester tester) async {
    // 累计尺寸提交次数。
    int calls = 0;
    // 尺寸更新器。
    final FloatingResizeScheduler scheduler = FloatingResizeScheduler(
      () => calls += 1,
    );
    scheduler.schedule();
    scheduler.flush();
    expect(calls, 1);
    await tester.pump(const Duration(milliseconds: 16));
    expect(calls, 1);
    scheduler.schedule();
    scheduler.dispose();
    scheduler.flush();
    scheduler.schedule();
    await tester.pump(const Duration(milliseconds: 32));
    expect(calls, 1);
  });
}
