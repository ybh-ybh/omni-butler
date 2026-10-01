import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 验证 Windows 弹窗的 Enter 提交键盘交互。
void main() {
  testWidgets('Windows 普通 Enter 和数字键盘 Enter 触发提交', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    // 已触发的提交次数。
    int submitCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OmniWindowsEnterSubmit(
            onSubmit: () => submitCount += 1,
            child: const TextField(autofocus: true, maxLines: 3),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(submitCount, 1);
    await tester.sendKeyEvent(
      LogicalKeyboardKey.numpadEnter,
      platform: 'linux',
    );
    expect(submitCount, 2);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(submitCount, 2);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('非 Windows 或回调为空时不触发提交', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    // 已触发的提交次数。
    int submitCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OmniWindowsEnterSubmit(
            onSubmit: () => submitCount += 1,
            child: const TextField(autofocus: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(submitCount, 0);

    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: OmniWindowsEnterSubmit(
            onSubmit: null,
            child: TextField(autofocus: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(submitCount, 0);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('没有可聚焦子控件时作用域主动接收 Enter', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    // 已触发的提交次数。
    int submitCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OmniWindowsEnterSubmit(
            onSubmit: () => submitCount += 1,
            child: const Text('弹窗内容'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(submitCount, 1);
    debugDefaultTargetPlatformOverride = null;
  });
}
