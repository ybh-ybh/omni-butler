import 'dart:ui' show Tristate;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/shared/ui/omni_press_feedback.dart';
import 'package:omni_butler/shared/ui/omni_segmented_button.dart';

/// 创建与两个业务入口一致的横向单选内容。
const List<ButtonSegment<int>> _segments = <ButtonSegment<int>>[
  ButtonSegment(value: 1, label: Text('进行中 12')),
  ButtonSegment(value: 2, label: Text('完成历史')),
];

/// 同时承载原生参照与 Windows 适配器的真实主题。
Widget _host(
  Widget child, {
  TargetPlatform platform = TargetPlatform.windows,
  double scale = 1,
}) => MaterialApp(
  theme: AppTheme.build(brightness: Brightness.light)
      .copyWith(platform: platform),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: Scaffold(body: Center(child: child)),
  ),
);

/// 定位指定段中的实际 TextButton。
Finder _button(Finder root, int index) =>
    find.descendant(of: root, matching: find.byType(TextButton)).at(index);

/// 读取段前景真正绘制的缩放矩阵。
double _scale(WidgetTester tester, Finder button) {
  // 按压只发生在这个独立内容层。
  final Finder content = find.descendant(
    of: button,
    matching: find.byType(OmniPressContent),
  );
  return tester
      .widget<Transform>(
        find.descendant(of: content, matching: find.byType(Transform)).first,
      )
      .transform
      .storage[0];
}

/// 验证当前两个业务所需几何、状态和命中，而不访问SDK测试专用状态。
void main() {
  testWidgets('默认与32像素密度同原生宽高及选中色完全一致', (tester) async {
    // 待办默认密度和事件32像素密度分别与同配置原生组件比较。
    for (final ButtonStyle? style in <ButtonStyle?>[
      null,
      const ButtonStyle(
        visualDensity: VisualDensity(vertical: -2),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ]) {
      // 普通与大字号保持原生的自适应尺寸。
      for (final double textScale in <double>[1, 1.8]) {
        await tester.pumpWidget(
          _host(
            Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SegmentedButton<int>(
                  key: const ValueKey('native'),
                  segments: _segments,
                  selected: const <int>{1},
                  onSelectionChanged: (_) {},
                  showSelectedIcon: false,
                  style: style,
                ),
                const SizedBox(height: 20),
                OmniSegmentedButton<int>(
                  key: const ValueKey('omni'),
                  segments: _segments,
                  selected: const <int>{1},
                  onSelectionChanged: (_) {},
                  showSelectedIcon: false,
                  style: style,
                ),
              ],
            ),
            scale: textScale,
          ),
        );
        await tester.pumpAndSettle();
        // 两种组件都按最长标签等宽分段。
        final Finder native = find.byKey(const ValueKey('native'));
        final Finder omni = find.byKey(const ValueKey('omni'));
        expect(tester.getSize(omni), tester.getSize(native));
        for (int index = 0; index < 2; index++) {
          // 比较真实按钮 Material，而非只比较外部样式配置。
          final Material nativeMaterial = tester.widget<Material>(
            find
                .descendant(
                  of: _button(native, index),
                  matching: find.byType(Material),
                )
                .first,
          );
          final Material omniMaterial = tester.widget<Material>(
            find
                .descendant(
                  of: _button(omni, index),
                  matching: find.byType(Material),
                )
                .first,
          );
          expect(
            tester.getSize(_button(omni, index)),
            tester.getSize(_button(native, index)),
          );
          expect(omniMaterial.color, nativeMaterial.color);
          expect(
            omniMaterial.textStyle?.color,
            nativeMaterial.textStyle?.color,
          );
        }
      }
    }
  });

  testWidgets('快速选择立即回调，背景与命中固定且连按只切换一次', (tester) async {
    // 由业务持有单选状态与提交次数。
    Set<int> selected = <int>{1};
    int changes = 0;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, rebuild) => OmniSegmentedButton<int>(
            segments: _segments,
            selected: selected,
            showSelectedIcon: false,
            onSelectionChanged: (value) {
              changes++;
              rebuild(() => selected = value);
            },
          ),
        ),
      ),
    );
    // 固定外框与按钮占位不会参与内容压缩。
    final Finder root = find.byType(OmniSegmentedButton<int>);
    final Rect original = tester.getRect(root);
    final Finder second = _button(root, 1);
    final Rect secondBounds = tester.getRect(second);
    await tester.tap(second);
    expect(selected, <int>{2});
    expect(changes, 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 45));
    expect(_scale(tester, second), lessThan(1));
    expect(tester.getRect(root), original);
    expect(tester.getRect(second), secondBounds);
    // 连按已经选择的段只反馈，不重复提交业务。
    await tester.tap(second);
    expect(changes, 1);
    await tester.pumpAndSettle();
    expect(_scale(tester, second), 1);
  });

  testWidgets('按住背景不缩，原边沿仍可点击，松手160毫秒恢复', (tester) async {
    // 点击边缘时仍使用原来的业务入口。
    int changes = 0;
    await tester.pumpWidget(
      _host(
        OmniSegmentedButton<int>(
          segments: _segments,
          selected: const <int>{1},
          showSelectedIcon: false,
          onSelectionChanged: (_) => changes++,
        ),
      ),
    );
    // 第二段最右侧仍属于原矩形热区。
    final Finder root = find.byType(OmniSegmentedButton<int>);
    final Finder second = _button(root, 1);
    final Rect original = tester.getRect(second);
    final TestGesture pointer = await tester.startGesture(
      Offset(original.right - 0.5, original.center.dy),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 90));
    expect(_scale(tester, second), closeTo(0.97, 0.0001));
    expect(tester.getRect(second), original);
    await pointer.up();
    expect(changes, 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    expect(_scale(tester, second), 1);
  });

  testWidgets('禁用段无操作无按压，语义激活保持单选状态', (tester) async {
    // 语义句柄在测试结束前释放。
    final SemanticsHandle semantics = tester.ensureSemantics();
    // 选择仍由上层业务控制。
    Set<int> selected = <int>{1};
    int changes = 0;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, rebuild) => OmniSegmentedButton<int>(
            segments: const <ButtonSegment<int>>[
              ButtonSegment(value: 1, label: Text('第一项')),
              ButtonSegment(value: 2, label: Text('禁用项'), enabled: false),
              ButtonSegment(value: 3, label: Text('第三项')),
            ],
            selected: selected,
            showSelectedIcon: false,
            onSelectionChanged: (value) {
              changes++;
              rebuild(() => selected = value);
            },
          ),
        ),
      ),
    );
    // 禁用段保持布局但不接收业务。
    final Finder root = find.byType(OmniSegmentedButton<int>);
    await tester.tap(_button(root, 1));
    await tester.pump(const Duration(milliseconds: 45));
    expect(changes, 0);
    expect(_scale(tester, _button(root, 1)), 1);
    // 真实语义节点仍提供互斥选择与点击动作。
    final SemanticsNode node = tester.getSemantics(_button(root, 2));
    node.owner!.performAction(node.id, SemanticsAction.tap);
    expect(changes, 1);
    expect(selected, <int>{3});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 45));
    expect(_scale(tester, _button(root, 2)), lessThan(1));
    await tester.pumpAndSettle();
    expect(
      tester
          .getSemantics(_button(root, 2))
          .getSemanticsData()
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );
    semantics.dispose();
  });

  testWidgets('Android仍构建原生分段且无Windows内容层', (tester) async {
    await tester.pumpWidget(
      _host(
        OmniSegmentedButton<int>(
          segments: _segments,
          selected: const <int>{1},
          onSelectionChanged: (_) {},
          showSelectedIcon: false,
        ),
        platform: TargetPlatform.android,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SegmentedButton<int>), findsOneWidget);
    expect(find.byType(OmniPressContent), findsNothing);
  });
}
