import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 验证统一下拉选择与操作菜单的关键交互。
void main() {
  testWidgets('独立下拉框展示选中态并返回新值', (WidgetTester tester) async {
    // 测试过程中当前选中的紧急程度。
    int? selectedUrgency;

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(brightness: Brightness.light),
        home: Scaffold(
          body: Center(
            child: StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) {
                return OmniDropdownButton<int?>(
                  value: selectedUrgency,
                  items: const <DropdownMenuItem<int?>>[
                    DropdownMenuItem<int?>(value: null, child: Text('全部紧急程度')),
                    DropdownMenuItem<int?>(value: 2, child: Text('高')),
                    DropdownMenuItem<int?>(value: 0, child: Text('低')),
                  ],
                  onChanged: (int? value) {
                    setState(() => selectedUrgency = value);
                  },
                );
              },
            ),
          ),
        ),
      ),
    );

    // 未聚焦时使用普通边框。
    AnimatedContainer trigger = tester.widget<AnimatedContainer>(
      find.byType(AnimatedContainer).first,
    );
    BoxDecoration decoration = trigger.decoration! as BoxDecoration;
    final OmniColors colors = OmniColors.of(
      tester.element(find.byType(AnimatedContainer).first),
    );
    expect(decoration.border?.top.color, colors.line);

    await tester.tap(find.text('全部紧急程度'));
    await tester.pumpAndSettle();

    // 菜单展开时显示焦点边框。
    trigger = tester.widget<AnimatedContainer>(
      find.byType(AnimatedContainer).first,
    );
    decoration = trigger.decoration! as BoxDecoration;
    expect(decoration.border?.top.color, colors.brand);

    expect(find.text('高'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);

    await tester.tap(find.text('高'));
    await tester.pumpAndSettle();

    expect(selectedUrgency, 2);
    expect(find.text('高'), findsOneWidget);
    // 菜单关闭后焦点释放，恢复普通边框。
    trigger = tester.widget<AnimatedContainer>(
      find.byType(AnimatedContainer).first,
    );
    decoration = trigger.decoration! as BoxDecoration;
    expect(decoration.border?.top.color, colors.line);
  });

  testWidgets('操作菜单使用紧凑图标项并返回操作', (WidgetTester tester) async {
    // 测试过程中最后选中的操作。
    String? selectedAction;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light),
        home: Scaffold(
          body: Center(
            child: OmniPopupMenuButton<String>(
              tooltip: '更多操作',
              onSelected: (String value) => selectedAction = value,
              itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                OmniPopupMenuItem<String>(
                  value: 'edit',
                  label: '编辑',
                  icon: Icons.edit_outlined,
                ),
                OmniPopupMenuItem<String>(
                  value: 'delete',
                  label: '移入回收站',
                  icon: Icons.delete_outline_rounded,
                  danger: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline_rounded), findsOneWidget);

    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    expect(selectedAction, 'edit');
  });

  testWidgets('飞书式下拉菜单视觉基线', (WidgetTester tester) async {
    // 下拉菜单视觉基线尺寸。
    const Size viewport = Size(420, 360);
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(brightness: Brightness.light),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(32),
            child: Align(
              alignment: Alignment.topLeft,
              child: OmniDropdownButton<int?>(
                value: null,
                items: const <DropdownMenuItem<int?>>[
                  DropdownMenuItem<int?>(value: null, child: Text('全部紧急程度')),
                  DropdownMenuItem<int?>(value: 3, child: Text('紧急')),
                  DropdownMenuItem<int?>(value: 2, child: Text('高')),
                  DropdownMenuItem<int?>(value: 1, child: Text('中')),
                  DropdownMenuItem<int?>(value: 0, child: Text('低')),
                ],
                onChanged: (int? value) {},
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('全部紧急程度'));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/omni_dropdown_feishu_light.png'),
    );
  });
}
