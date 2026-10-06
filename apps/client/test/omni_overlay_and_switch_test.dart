// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:ui' show SemanticsAction, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
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
              context: context,
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

  testWidgets('统一开关保持完整热区且动画可中途反向', (WidgetTester tester) async {
    // 开关当前值。
    bool value = false;
    // 开关回调次数。
    int changeCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light)
            .copyWith(platform: TargetPlatform.windows),
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
    // 关闭时滑块的实际中心点。
    final Offset offCenter = tester.getCenter(
      find.byKey(const ValueKey<String>('omni-switch-thumb')),
    );
    // 轻点视觉轨道以外、完整热区以内。
    final Offset switchTopLeft = tester.getTopLeft(find.byType(OmniSwitch));
    await tester.tapAt(switchTopLeft + const Offset(2, 20));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    // 动画进行中的实际滑块位置。
    final Offset intermediate = tester.getCenter(
      find.byKey(const ValueKey<String>('omni-switch-thumb')),
    );
    expect(value, isTrue);
    expect(intermediate.dx, greaterThan(offCenter.dx));
    await tester.tap(find.byType(OmniSwitch));
    await tester.pump();
    expect(
      tester
          .getCenter(find.byKey(const ValueKey<String>('omni-switch-thumb')))
          .dx,
      closeTo(intermediate.dx, 0.1),
    );
    await tester.pumpAndSettle();
    expect(value, isFalse);
    expect(changeCount, 2);
    expect(
      tester
          .getCenter(find.byKey(const ValueKey<String>('omni-switch-thumb')))
          .dx,
      closeTo(offCenter.dx, 0.1),
    );
    expect(
      find.byKey(const ValueKey<String>('omni-switch-indicator')),
      findsNothing,
    );
  });

  testWidgets('开关支持键盘并尊重减少动效和触控热区', (WidgetTester tester) async {
    // 当前开关状态。
    bool value = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light)
            .copyWith(platform: TargetPlatform.android),
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) =>
                  OmniSwitch(
                    value: value,
                    onChanged: (bool nextValue) =>
                        setState(() => value = nextValue),
                  ),
            ),
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byType(OmniSwitch)).height, OmniSize.touch);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(value, isTrue);
    // 减少动效时滑块立即到达目标位置。
    final AnimatedAlign position = tester.widget<AnimatedAlign>(
      find.byKey(const ValueKey<String>('omni-switch-thumb-position')),
    );
    expect(position.duration, Duration.zero);
    expect(position.alignment, AlignmentDirectional.centerEnd);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(value, isFalse);
  });

  testWidgets('禁用开关不接收点击且整行开关只有一次状态变更', (WidgetTester tester) async {
    // 整行开关累计操作次数。
    int changeCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light),
        home: Scaffold(
          body: Column(
            children: <Widget>[
              const OmniSwitch(
                key: ValueKey<String>('disabled-switch'),
                value: false,
                onChanged: null,
              ),
              OmniSwitchListTile(
                value: false,
                onChanged: (bool value) => changeCount += 1,
                title: const Text('自动保存'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('disabled-switch')),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(changeCount, 0);
    await tester.tap(find.byType(OmniSwitch).last);
    await tester.pumpAndSettle();
    expect(changeCount, 1);
  });
  testWidgets('开关向读屏暴露切换状态和可操作状态', (WidgetTester tester) async {
    // 启用语义树以验证辅助技术使用的真实节点。
    final SemanticsHandle semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(brightness: Brightness.light),
          home: Scaffold(
            body: Column(
              children: <Widget>[
                OmniSwitch(value: true, onChanged: (bool value) {}),
                const OmniSwitch(value: false, onChanged: null),
              ],
            ),
          ),
        ),
      );
      // 可交互开关的语义状态。
      final SemanticsData enabled = tester
          .getSemantics(find.byType(OmniSwitch).first)
          .getSemanticsData();
      // 禁用开关的语义状态。
      final SemanticsData disabled = tester
          .getSemantics(find.byType(OmniSwitch).last)
          .getSemanticsData();
      expect(enabled.flagsCollection.isToggled, Tristate.isTrue);
      expect(enabled.flagsCollection.isEnabled, Tristate.isTrue);
      expect(enabled.hasAction(SemanticsAction.tap), isTrue);
      expect(disabled.flagsCollection.isToggled, Tristate.isFalse);
      expect(disabled.flagsCollection.isEnabled, Tristate.isFalse);
      expect(disabled.hasAction(SemanticsAction.tap), isFalse);
    } finally {
      semantics.dispose();
    }
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
