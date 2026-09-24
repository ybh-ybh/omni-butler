import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/shared/ui/omni_sliding_segmented_control.dart';

/// 验证连续轨道控件遵循系统动效偏好。
void main() {
  testWidgets('系统减少动态效果时滑块即时切换', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: OmniSlidingSegmentedControl<int>(
              options: const <int>[0, 1],
              selected: 0,
              width: 240,
              labelBuilder: (int option) => '选项 $option',
              onChanged: (int option) {},
            ),
          ),
        ),
      ),
    );

    // 减少动态效果后的滑块组件。
    final AnimatedAlign indicator = tester.widget<AnimatedAlign>(
      find.byType(AnimatedAlign),
    );
    expect(indicator.duration, Duration.zero);
  });

  testWidgets('单个选项仍显示完整滑块且不产生非法对齐', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OmniSlidingSegmentedControl<int>(
            options: const <int>[0],
            selected: 0,
            width: 240,
            labelBuilder: (int option) => '唯一选项',
            onChanged: (int option) {},
          ),
        ),
      ),
    );

    // 单选项滑块的居中对齐。
    final AnimatedAlign indicator = tester.widget<AnimatedAlign>(
      find.byType(AnimatedAlign),
    );
    expect(indicator.alignment, Alignment.center);
    expect(find.text('唯一选项'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
