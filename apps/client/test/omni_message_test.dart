import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 读取消息倒计时边框当前剩余进度。
double _countdownProgress(WidgetTester tester) {
  // 当前倒计时边框的绘制组件。
  final CustomPaint countdownPaint = tester.widget<CustomPaint>(
    find.byKey(const ValueKey<String>('omni-message-countdown-border')),
  );
  // 绘制器为库内私有类型，通过动态访问只验证公开进度字段。
  final dynamic countdownPainter = countdownPaint.foregroundPainter;
  return countdownPainter.remainingProgress as double;
}

/// 验证全应用统一顶部浮动消息的层级和交互。
void main() {
  // 覆盖桌面宽窄窗口、字号放大与移动端触控布局。
  for (final ({TargetPlatform platform, double width, double textScale}) layout
      in <({TargetPlatform platform, double width, double textScale})>[
        (platform: TargetPlatform.windows, width: 800, textScale: 1),
        (platform: TargetPlatform.windows, width: 367, textScale: 1),
        (platform: TargetPlatform.windows, width: 520, textScale: 2),
        (platform: TargetPlatform.android, width: 360, textScale: 1),
        (platform: TargetPlatform.android, width: 360, textScale: 2),
      ]) {
    testWidgets(
      '消息内容垂直居中且撤销保持同行：${layout.platform.name}/${layout.width}/${layout.textScale}',
      (WidgetTester tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(layout.width, 600);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        // 当前消息句柄，在断言失败时也移除浮层。
        OmniMessageHandle? handle;
        addTearDown(() => handle?.dismiss());
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.build(brightness: Brightness.light),
            builder: (BuildContext context, Widget? child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(layout.textScale)),
              child: child!,
            ),
            home: Builder(
              builder: (BuildContext context) => Scaffold(
                body: FilledButton(
                  onPressed: () => handle = showOmniMessage(
                    context,
                    message: '已完成“摘简历”',
                    tone: OmniMessageTone.success,
                    actionLabel: '撤销',
                    onAction: () {},
                  ),
                  child: const Text('显示消息'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('显示消息'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        // 当前消息的边界，用于核对内容相对弹窗的垂直中心。
        final Rect popupRect = tester.getRect(
          find.byKey(const ValueKey<String>('omni-message-popup')),
        );
        // 所有内容均应相对整个弹窗居中，而不是只在顶部内容行居中。
        final List<Finder> content = <Finder>[
          find.byIcon(Icons.check_circle_rounded),
          find.text('已完成“摘简历”'),
          find.text('撤销'),
          find.byIcon(Icons.close_rounded),
        ];
        // 逐项确认内容的中心与边界。
        for (final Finder element in content) {
          expect(
            tester.getCenter(element).dy,
            closeTo(popupRect.center.dy, 0.5),
          );
          expect(popupRect.contains(tester.getTopLeft(element)), isTrue);
          expect(popupRect.contains(tester.getBottomRight(element)), isTrue);
        }
        if (layout.textScale == 1) {
          expect(popupRect.height, inInclusiveRange(48, 50));
        }
        expect(tester.takeException(), isNull);
        handle!.dismiss();
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant(<TargetPlatform>{layout.platform}),
    );
  }

  testWidgets('操作消息浮动在窗口顶部并支持替换、操作和自动关闭', (WidgetTester tester) async {
    // 操作按钮是否被触发。
    bool actionCalled = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Column(
              children: <Widget>[
                FilledButton(
                  onPressed: () => showOmniMessage(
                    context,
                    message: '已移入回收站',
                    tone: OmniMessageTone.success,
                    actionLabel: '撤销',
                    onAction: () => actionCalled = true,
                  ),
                  child: const Text('显示成功消息'),
                ),
                FilledButton(
                  onPressed: () => showOmniMessage(
                    context,
                    message: '保存失败',
                    tone: OmniMessageTone.error,
                    duration: const Duration(seconds: 6),
                  ),
                  child: const Text('显示错误消息'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('显示成功消息'));
    await tester.pump(const Duration(milliseconds: 200));
    // 当前顶部浮动消息。
    final Finder popup = find.byKey(
      const ValueKey<String>('omni-message-popup'),
    );
    expect(popup, findsOneWidget);
    expect(find.text('已移入回收站'), findsOneWidget);
    expect(tester.getTopLeft(popup).dy, lessThan(80));
    expect(tester.getSize(popup).width, lessThanOrEqualTo(560));
    expect(
      find.byKey(const ValueKey<String>('omni-message-countdown-border')),
      findsOneWidget,
    );

    await tester.tap(find.text('显示错误消息'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('已移入回收站'), findsNothing);
    expect(find.text('保存失败'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    expect(popup, findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 1));
    expect(popup, findsNothing);

    await tester.tap(find.text('显示成功消息'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('撤销'));
    await tester.pump();
    expect(actionCalled, isTrue);
    expect(popup, findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('倒计时边框按消息时长缩短并在归零时关闭', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: FilledButton(
              onPressed: () => showOmniMessage(
                context,
                message: '倒计时消息',
                tone: OmniMessageTone.success,
              ),
              child: const Text('显示倒计时消息'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('显示倒计时消息'));
    await tester.pump();
    expect(_countdownProgress(tester), closeTo(1, 0.01));

    await tester.pump(const Duration(seconds: 2));
    expect(_countdownProgress(tester), closeTo(0.5, 0.02));

    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 1));
    expect(
      find.byKey(const ValueKey<String>('omni-message-popup')),
      findsNothing,
    );
  });

  testWidgets('鼠标悬停暂停边框和自动关闭并在移开后继续', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: FilledButton(
              onPressed: () => showOmniMessage(
                context,
                message: '可悬停消息',
                tone: OmniMessageTone.info,
              ),
              child: const Text('显示可悬停消息'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('显示可悬停消息'));
    await tester.pump(const Duration(seconds: 1));
    // 当前消息弹窗。
    final Finder popup = find.byKey(
      const ValueKey<String>('omni-message-popup'),
    );
    // 用于模拟悬停和移出的鼠标指针。
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(popup));
    await tester.pump();
    // 鼠标进入后被冻结的剩余进度。
    final double pausedProgress = _countdownProgress(tester);

    await tester.pump(const Duration(seconds: 5));
    expect(popup, findsOneWidget);
    expect(_countdownProgress(tester), closeTo(pausedProgress, 0.001));

    await mouse.moveTo(Offset.zero);
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 1));
    expect(popup, findsNothing);
    await mouse.removePointer();
  });

  testWidgets('关闭动画时保持静态边框且非正时长立即关闭', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Column(
              children: <Widget>[
                FilledButton(
                  onPressed: () => showOmniMessage(
                    context,
                    message: '静态边框消息',
                    duration: const Duration(seconds: 1),
                  ),
                  child: const Text('显示静态边框消息'),
                ),
                FilledButton(
                  onPressed: () => showOmniMessage(
                    context,
                    message: '立即关闭消息',
                    duration: Duration.zero,
                  ),
                  child: const Text('显示立即关闭消息'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('显示静态边框消息'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(_countdownProgress(tester), 1);
    await tester.pump(const Duration(milliseconds: 501));
    expect(
      find.byKey(const ValueKey<String>('omni-message-popup')),
      findsNothing,
    );

    await tester.tap(find.text('显示立即关闭消息'));
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('omni-message-popup')),
      findsNothing,
    );
  });
}
