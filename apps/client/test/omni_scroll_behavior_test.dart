import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/omni_scroll_behavior.dart';

/// 验证应用级滚动行为的平台差异与边界回弹。
void main() {
  testWidgets('Android 在顶部和底部使用 iOS 弹性回弹', (WidgetTester tester) async {
    // 被测列表的滚动控制器。
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        scrollBehavior: const OmniScrollBehavior(),
        home: Scaffold(
          body: ListView(
            controller: controller,
            children: List<Widget>.filled(20, const SizedBox(height: 80)),
          ),
        ),
      ),
    );

    expect(find.byType(StretchingOverscrollIndicator), findsNothing);
    expect(find.byType(GlowingOverscrollIndicator), findsNothing);
    expect(controller.position.physics, isA<BouncingScrollPhysics>());

    // 顶部越界拖拽手势。
    final TestGesture topGesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
    );
    await topGesture.moveBy(const Offset(0, 120));
    await tester.pump();
    expect(controller.offset, lessThan(0));
    await topGesture.up();
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(0, 0.01));

    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    // 列表底部的最大合法滚动位置。
    final double maxScrollExtent = controller.position.maxScrollExtent;
    // 底部越界拖拽手势。
    final TestGesture bottomGesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
    );
    await bottomGesture.moveBy(const Offset(0, -120));
    await tester.pump();
    expect(controller.offset, greaterThan(maxScrollExtent));
    await bottomGesture.up();
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(maxScrollExtent, 0.01));
  });

  testWidgets('Windows 保留默认夹紧滚动物理', (WidgetTester tester) async {
    // 被测列表的滚动控制器。
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        scrollBehavior: const OmniScrollBehavior(),
        home: ListView(
          controller: controller,
          children: List<Widget>.filled(20, const SizedBox(height: 80)),
        ),
      ),
    );

    expect(controller.position.physics, isA<ClampingScrollPhysics>());
  });
}
