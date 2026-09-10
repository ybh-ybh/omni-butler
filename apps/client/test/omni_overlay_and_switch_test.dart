import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 验证统一侧栏与开关的关键交互。
void main() {
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

  testWidgets('统一开关缩小视觉尺寸并保留触控区域', (WidgetTester tester) async {
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
      const Size(OmniSize.touch, OmniSize.controlLarge),
    );
    // 轻点视觉开关外、触控区域内的边缘。
    final Offset switchTopLeft = tester.getTopLeft(find.byType(OmniSwitch));
    await tester.tapAt(switchTopLeft + const Offset(2, 20));
    await tester.pumpAndSettle();
    expect(value, isTrue);
    expect(changeCount, 1);

    await tester.tap(find.byType(Switch));
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
