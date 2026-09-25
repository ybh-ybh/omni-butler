// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'package:flutter/material.dart';
import 'package:flutter/src/foundation/_features.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 验证统一侧栏与开关的关键交互。
void main() {
  testWidgets('统一弹窗在启用多窗口时仍保留在当前窗口', (WidgetTester tester) async {
    // 测试前的 Flutter 多窗口特性状态。
    final bool previousWindowingEnabled = isWindowingEnabled;
    isWindowingEnabled = true;
    addTearDown(() => isWindowingEnabled = previousWindowingEnabled);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light),
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => showOmniDialog<void>(
              context,
              builder: (BuildContext context) => const AlertDialog(
                title: Text('应用内弹窗'),
                content: Text('不能创建独立原生窗口'),
              ),
            ),
            child: const Text('打开弹窗'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开弹窗'));
    await tester.pumpAndSettle();

    expect(find.text('应用内弹窗'), findsOneWidget);
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(ModalBarrier), findsWidgets);
    expect(tester.binding.platformDispatcher.views, hasLength(1));
  });

  testWidgets('点击侧栏左侧遮罩会关闭侧栏', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light),
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => showOmniSideSheet<void>(
              context,
              builder: (BuildContext context) =>
                  const Material(child: Text('侧栏内容')),
            ),
            child: const Text('打开侧栏'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开侧栏'));
    await tester.pumpAndSettle();
    expect(find.text('侧栏内容'), findsOneWidget);

    await tester.tapAt(const Offset(40, 300));
    await tester.pumpAndSettle();
    expect(find.text('侧栏内容'), findsNothing);
  });

  testWidgets('统一开关使用立体样式并保留完整交互能力', (WidgetTester tester) async {
    // 开关当前值。
    bool value = false;
    // 开关回调次数。
    int changeCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) => Center(
              child: OmniSwitch(
                value: value,
                onChanged: (bool nextValue) {
                  changeCount += 1;
                  setState(() => value = nextValue);
                },
              ),
            ),
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.byType(OmniSwitch)),
      const Size(OmniSize.switchTapWidth, OmniSize.controlLarge),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey<String>('omni-switch-track'))),
      const Size(OmniSize.switchTrackWidth, OmniSize.switchTrackHeight),
    );
    // 浅色主题轨道容器。
    final Container track = tester.widget<Container>(
      find.byKey(const ValueKey<String>('omni-switch-track')),
    );
    // 浅色主题轨道装饰。
    final BoxDecoration trackDecoration = track.decoration! as BoxDecoration;
    // 浅色主题轨道渐变。
    final LinearGradient trackGradient =
        trackDecoration.gradient! as LinearGradient;
    expect(trackGradient.colors.first, const Color(0xFFC3CBD6));
    expect(trackDecoration.border, isNotNull);
    // 当前开关交互层。
    final InkWell interaction = tester.widget<InkWell>(
      find.byKey(const ValueKey<String>('omni-switch-interaction')),
    );
    expect(
      interaction.overlayColor?.resolve(<WidgetState>{WidgetState.hovered}),
      Colors.transparent,
    );
    expect(
      interaction.overlayColor?.resolve(<WidgetState>{WidgetState.focused}),
      isNot(Colors.transparent),
    );
    // 关闭状态滑块位置。
    AnimatedAlign thumbPosition = tester.widget<AnimatedAlign>(
      find.byKey(const ValueKey<String>('omni-switch-thumb-position')),
    );
    expect(thumbPosition.alignment, Alignment.centerLeft);
    expect(thumbPosition.duration, const Duration(milliseconds: 210));
    expect(thumbPosition.curve, Curves.easeIn);
    // 关闭状态环位置。
    final AnimatedAlign indicatorPosition = tester.widget<AnimatedAlign>(
      find.byKey(const ValueKey<String>('omni-switch-indicator-position')),
    );
    expect(indicatorPosition.duration, const Duration(milliseconds: 700));
    // 状态环左右内收间距。
    final Padding indicatorInset = tester.widget<Padding>(
      find.byKey(const ValueKey<String>('omni-switch-indicator-inset')),
    );
    expect(
      indicatorInset.padding,
      const EdgeInsets.symmetric(horizontal: OmniSize.switchIndicatorInset),
    );
    // 轻点视觉开关外、触控区域内的边缘。
    final Offset switchTopLeft = tester.getTopLeft(find.byType(OmniSwitch));
    await tester.tapAt(switchTopLeft + const Offset(2, 20));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 210));
    expect(value, isTrue);
    expect(changeCount, 1);
    // 运行到 CSS 30% 关键帧时的状态环淡出值。
    FadeTransition indicatorFade = tester.widget<FadeTransition>(
      find.byKey(const ValueKey<String>('omni-switch-indicator-fade')),
    );
    expect(indicatorFade.opacity.value, closeTo(0, 0.01));
    thumbPosition = tester.widget<AnimatedAlign>(
      find.byKey(const ValueKey<String>('omni-switch-thumb-position')),
    );
    expect(thumbPosition.alignment, Alignment.centerRight);
    await tester.pump(const Duration(milliseconds: 490));
    indicatorFade = tester.widget<FadeTransition>(
      find.byKey(const ValueKey<String>('omni-switch-indicator-fade')),
    );
    expect(indicatorFade.opacity.value, closeTo(1, 0.01));

    await tester.tap(
      find.byKey(const ValueKey<String>('omni-switch-interaction')),
    );
    await tester.pumpAndSettle();
    expect(value, isFalse);
    expect(changeCount, 2);
  });

  testWidgets('统一开关列表项保留悬停底色内边距', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light),
        home: const Scaffold(
          body: OmniSwitchListTile(
            value: false,
            onChanged: null,
            title: Text('开关列表项'),
          ),
        ),
      ),
    );

    // 共享开关列表项内部使用的列表项。
    final ListTile listTile = tester.widget<ListTile>(find.byType(ListTile));
    expect(
      listTile.contentPadding,
      const EdgeInsets.symmetric(horizontal: OmniSpacing.sm, vertical: 2),
    );
  });
}
