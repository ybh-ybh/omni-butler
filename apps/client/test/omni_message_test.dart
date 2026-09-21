import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 验证全应用统一顶部浮动消息的层级和交互。
void main() {
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

    await tester.tap(find.text('显示错误消息'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('已移入回收站'), findsNothing);
    expect(find.text('保存失败'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
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
}
