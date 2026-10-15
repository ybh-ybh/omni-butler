import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 读取卡片留白的真实像素，包括 Material 上的焦点墨水层。
Future<int> _pixel(
  WidgetTester tester,
  GlobalKey boundaryKey,
  Offset point,
) async {
  // 捕获包含菜单覆盖层的完整窗口。
  final RenderRepaintBoundary boundary =
      boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  return (await tester.runAsync(() async {
    // 固定一倍像素采样，避开文字和圆角。
    final ui.Image image = await boundary.toImage();
    try {
      // 读取真实合成后的颜色，不能只检查 focusColor 配置。
      final ByteData bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      // 当前采样点对应的 RGBA 字节。
      final int offset =
          (point.dy.floor() * image.width + point.dx.floor()) * 4;
      return bytes.getUint32(offset);
    } finally {
      image.dispose();
    }
  }))!;
}

/// 验证鼠标不抢焦点、键盘恢复和后续业务弹窗的实际行为。
void main() {
  testWidgets('二级菜单取消恢复原输入焦点且叶子弹窗保持焦点', (tester) async {
    // 菜单打开前的真实输入焦点。
    final FocusNode inputFocus = FocusNode();
    // 叶子选择后新业务弹窗的焦点。
    final FocusNode dialogFocus = FocusNode();
    // 父项展开和取消不能增加业务回调次数。
    int selections = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light)
            .copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: Column(
            children: <Widget>[
              TextField(focusNode: inputFocus, onTapOutside: (_) {}),
              Builder(
                builder: (context) => OmniPopupMenuButton<String>(
                  tooltip: '二级业务菜单',
                  itemBuilder: (_) => <PopupMenuEntry<String>>[
                    OmniPopupMenuItem<String>.submenu(
                      label: '删除标签',
                      danger: true,
                      children: <PopupMenuEntry<String>>[
                        OmniPopupMenuItem<String>(
                          value: 'deleteAll',
                          label: '删除标签和笔记',
                          icon: null,
                          danger: true,
                        ),
                      ],
                    ),
                  ],
                  onSelected: (_) {
                    selections += 1;
                    showDialog<void>(
                      context: context,
                      builder: (_) => AlertDialog(
                        content: TextField(
                          autofocus: true,
                          focusNode: dialogFocus,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    inputFocus.requestFocus();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('二级业务菜单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除标签'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(20, 400));
    await tester.pumpAndSettle();
    expect(inputFocus.hasPrimaryFocus, isTrue);
    expect(selections, 0);
    await tester.tap(find.byTooltip('二级业务菜单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除标签'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除标签和笔记'));
    await tester.pumpAndSettle();
    expect(dialogFocus.hasPrimaryFocus, isTrue);
    expect(selections, 1);
    expect(find.text('删除标签'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    inputFocus.dispose();
    dialogFocus.dispose();
  });

  testWidgets('鼠标关闭卡片菜单后明暗底色不残留且不抢原输入焦点', (tester) async {
    // 明暗主题及两种菜单触发器都复用相同的焦点恢复规则。
    for (final Brightness brightness in Brightness.values) {
      for (final bool custom in <bool>[false, true]) {
        // 单次宿主的实际渲染边界。
        final GlobalKey boundaryKey = GlobalKey();
        // 模拟打开菜单前正在编辑的输入框。
        final FocusNode inputFocus = FocusNode();
        // 菜单取消不能触发笔记编辑。
        int edits = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.build(brightness: brightness)
                .copyWith(platform: TargetPlatform.windows),
            builder: (context, child) =>
                RepaintBoundary(key: boundaryKey, child: child!),
            home: Scaffold(
              body: Column(
                children: <Widget>[
                  // 显式保留输入框自身的外部点击策略，仅验证菜单不抢焦点。
                  TextField(focusNode: inputFocus, onTapOutside: (_) {}),
                  OmniPanel(
                    key: const ValueKey<String>('card'),
                    onDoubleTap: () => edits += 1,
                    child: SizedBox(
                      height: 100,
                      child: Align(
                        alignment: Alignment.topRight,
                        child: OmniPopupMenuButton<String>(
                          tooltip: '卡片菜单',
                          itemBuilder: (_) => <PopupMenuEntry<String>>[
                            OmniPopupMenuItem<String>(
                              value: 'edit',
                              label: '编辑',
                              icon: Icons.edit_outlined,
                            ),
                          ],
                          child: custom
                              ? const SizedBox(
                                  width: 32,
                                  height: 32,
                                  child: Icon(Icons.more_horiz),
                                )
                              : null,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        inputFocus.requestFocus();
        await tester.pumpAndSettle();
        // 卡片左下方不受文字、菜单、hover 或边框影响。
        final Offset sample =
            tester.getBottomLeft(find.byKey(const ValueKey<String>('card'))) +
            const Offset(32, -32);
        // 打开前的真实卡片底色。
        final int before = await _pixel(tester, boundaryKey, sample);
        // 全程同一鼠标，不能用触摸事件掩盖 Windows 焦点高亮。
        final TestGesture mouse = await tester.createGesture(
          kind: ui.PointerDeviceKind.mouse,
        );
        await mouse.addPointer(location: Offset.zero);
        // 连续两次确认关闭后焦点与底色均可稳定恢复。
        for (int cycle = 0; cycle < 2; cycle += 1) {
          await mouse.moveTo(tester.getCenter(find.byTooltip('卡片菜单')));
          await mouse.down(tester.getCenter(find.byTooltip('卡片菜单')));
          await mouse.up();
          // 自定义入口与父卡双击共用仲裁，等待真实单击确认时限。
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pumpAndSettle();
          expect(find.text('编辑'), findsOneWidget);
          await mouse.moveTo(const Offset(20, 400));
          await mouse.down(const Offset(20, 400));
          await mouse.up();
          await tester.pumpAndSettle();
          expect(find.text('编辑'), findsNothing);
          expect(await _pixel(tester, boundaryKey, sample), before);
          expect(inputFocus.hasPrimaryFocus, isTrue);
          expect(edits, 0);
        }
        await mouse.removePointer();
        await tester.pumpWidget(const SizedBox.shrink());
        inputFocus.dispose();
      }
    }
  });

  testWidgets('菜单选择打开业务弹窗后焦点留在弹窗输入框', (tester) async {
    // 对话框拥有独立且可检查的焦点。
    final FocusNode dialogFocus = FocusNode();
    // 一次菜单选择只能执行一次业务操作。
    int selections = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light)
            .copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: Builder(
            builder: (context) => OmniPopupMenuButton<String>(
              tooltip: '业务菜单',
              itemBuilder: (_) => <PopupMenuEntry<String>>[
                OmniPopupMenuItem<String>(
                  value: 'edit',
                  label: '编辑',
                  icon: Icons.edit_outlined,
                ),
              ],
              onSelected: (_) {
                selections += 1;
                showDialog<void>(
                  context: context,
                  builder: (_) => AlertDialog(
                    content: TextField(autofocus: true, focusNode: dialogFocus),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('业务菜单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(dialogFocus.hasPrimaryFocus, isTrue);
    expect(selections, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    dialogFocus.dispose();
  });
}
