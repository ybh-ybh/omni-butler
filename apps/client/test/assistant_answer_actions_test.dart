import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_answer_actions.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_windows_tokens.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 使用正式主题挂载实际操作区，不伪造鼠标状态。
Future<void> _mount(
  WidgetTester tester, {
  bool mobile = false,
  bool saved = false,
  bool saving = false,
  String? error,
  String messageId = 'answer',
  TargetPlatform platform = TargetPlatform.windows,
  double width = 1000,
  double scale = 1,
  Brightness brightness = Brightness.light,
  String? createdAt = '2026-10-25T09:30:00',
  VoidCallback? onSave,
}) async {
  tester.view.physicalSize = Size(width, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(brightness: brightness)
          .copyWith(platform: platform),
      home: Scaffold(
        body: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: AssistantAnswerActions(
                messageId: messageId,
                createdAt: createdAt,
                colors: AssistantWindowsPalette.of(context),
                alwaysVisible: mobile,
                saved: saved,
                saving: saving,
                error: error,
                showSave: true,
                onSave: onSave,
                child: const SizedBox(height: 130, child: Text('完整回答正文')),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('安卓保存笔记及重试期间固定文案且不沿用其他消息状态', (tester) async {
    // Identify the actual native action across controller-driven rebuilds.
    final Finder button = find.byKey(
      const ValueKey<String>('assistant-save-note-answer'),
    );
    await _mount(tester, mobile: true, platform: TargetPlatform.android);
    // Compare the original action size with the pending first attempt.
    final Rect original = tester.getRect(button);
    await _mount(
      tester,
      mobile: true,
      platform: TargetPlatform.android,
      saving: true,
    );
    expect(find.text('保存笔记'), findsOneWidget);
    expect(tester.getRect(button), original);
    expect(tester.widget<OmniTextButton>(button).onPressed, isNull);
    await _mount(
      tester,
      mobile: true,
      platform: TargetPlatform.android,
      error: '连接中断',
    );
    // A retry is wider and must keep its own pre-submit text after error clears.
    final Rect retry = tester.getRect(button);
    await _mount(
      tester,
      mobile: true,
      platform: TargetPlatform.android,
      saving: true,
    );
    expect(find.text('重试保存'), findsOneWidget);
    expect(tester.getRect(button), retry);
    await _mount(
      tester,
      mobile: true,
      platform: TargetPlatform.android,
      messageId: 'other-answer',
      saving: true,
    );
    expect(find.text('保存笔记'), findsOneWidget);
    expect(find.text('重试保存'), findsNothing);
    await _mount(
      tester,
      mobile: true,
      platform: TargetPlatform.android,
      saved: true,
    );
    expect(find.text('已保存'), findsOneWidget);
    await _mount(tester, mobile: true, saving: true);
    expect(find.text('保存中…'), findsOneWidget);
  });

  testWidgets('整行悬停显示操作和真实时间，离开隐藏且布局不跳动', (tester) async {
    await _mount(tester, onSave: () {});
    // 操作区占据固定高度，但默认不可见。
    final Finder actions = find.byKey(
      const ValueKey<String>('assistant-answer-actions-answer'),
    );
    // 用正文位置验证悬停前后几何稳定。
    final Rect before = tester.getRect(find.text('完整回答正文'));
    expect(tester.widget<AnimatedOpacity>(actions).opacity, 0);
    // 鼠标进入回答空白也应触发整行显隐。
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: const Offset(5, 5));
    await mouse.moveTo(const Offset(800, 80));
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(actions).opacity, 1);
    expect(find.text('09:30'), findsOneWidget);
    expect(tester.getRect(find.text('完整回答正文')), before);
    await mouse.moveTo(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(actions).opacity, 0);
    await mouse.removePointer();
  });

  for (final Brightness brightness in Brightness.values) {
    testWidgets('${brightness.name} 保存按钮悬停只改变文字颜色，背景透明且点击一次', (tester) async {
      // 独立记录业务按钮调用。
      int saves = 0;
      await _mount(tester, brightness: brightness, onSave: () => saves++);
      // 悬停原生文字按钮，检查最终样式状态。
      final Finder button = find.byKey(
        const ValueKey<String>('assistant-save-note-answer'),
      );
      // 所有状态均来自原生ButtonStyle的真实解析。
      final ButtonStyle style = tester.widget<OmniTextButton>(button).style!;
      expect(
        style.overlayColor!.resolve(<WidgetState>{WidgetState.hovered}),
        Colors.transparent,
      );
      expect(
        style.backgroundColor!.resolve(<WidgetState>{WidgetState.hovered}),
        Colors.transparent,
      );
      expect(
        style.foregroundColor!.resolve(<WidgetState>{WidgetState.hovered}),
        isNot(style.foregroundColor!.resolve(<WidgetState>{})),
      );
      // 进入整行后才能命中不常驻的按钮。
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: const Offset(800, 80));
      await tester.pumpAndSettle();
      await mouse.moveTo(tester.getCenter(button));
      await tester.pumpAndSettle();
      await tester.tap(button);
      expect(saves, 1);
      expect(tester.takeException(), isNull);
      await mouse.removePointer();
    });
  }

  testWidgets('键盘聚焦显示入口，手机常驻且320宽双倍字号不溢出', (tester) async {
    await _mount(tester, onSave: () {});
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.byKey(
              const ValueKey<String>('assistant-answer-actions-answer'),
            ),
          )
          .opacity,
      1,
    );
    await _mount(tester, mobile: true, width: 320, scale: 2, saved: true);
    expect(find.text('已保存'), findsOneWidget);
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.byKey(
              const ValueKey<String>('assistant-answer-actions-answer'),
            ),
          )
          .opacity,
      1,
    );
    expect(
      tester
          .widget<OmniTextButton>(
            find.byKey(const ValueKey<String>('assistant-save-note-answer')),
          )
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('旧缓存缺少消息时间时不补造日期', (tester) async {
    await _mount(tester, mobile: true, createdAt: null);
    expect(
      find.byKey(const ValueKey<String>('assistant-answer-date-answer')),
      findsNothing,
    );
  });
}
