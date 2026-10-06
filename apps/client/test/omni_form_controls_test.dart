import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/features/todos/presentation/todo_completion_checkbox.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 创建保留平台焦点行为的控件测试环境。
Widget _host(Widget child, {TargetPlatform platform = TargetPlatform.windows}) {
  return MaterialApp(
    theme: AppTheme.build(brightness: Brightness.light)
        .copyWith(platform: platform),
    home: Scaffold(
      body: Center(child: SizedBox(width: 360, child: child)),
    ),
  );
}

/// 验证输入、选择与图标操作的业务语义和无障碍能力。
void main() {
  testWidgets('表单保留校验、保存、中文输入法组合与多行编辑', (WidgetTester tester) async {
    // 由业务持有的表单状态。
    final GlobalKey<FormState> formKey = GlobalKey<FormState>();
    // 由业务持有的文本控制器。
    final TextEditingController controller = TextEditingController();
    // 提交后的业务数据。
    String? saved;
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _host(
        Form(
          key: formKey,
          child: OmniTextFormField(
            controller: controller,
            maxLines: 3,
            decoration: const InputDecoration(labelText: '备注'),
            validator: (String? value) =>
                value == null || value.isEmpty ? '请输入备注' : null,
            onSaved: (String? value) => saved = value,
          ),
        ),
      ),
    );
    expect(formKey.currentState!.validate(), isFalse);
    await tester.pump();
    expect(find.text('请输入备注'), findsOneWidget);
    await tester.tap(find.byType(TextField));
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'zhong',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 0, end: 5),
      ),
    );
    await tester.pump();
    expect(controller.value.composing, const TextRange(start: 0, end: 5));
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '中文\n第二行',
        selection: TextSelection.collapsed(offset: 6),
      ),
    );
    await tester.pump();
    expect(formKey.currentState!.validate(), isTrue);
    formKey.currentState!.save();
    expect(saved, '中文\n第二行');
    expect(tester.widget<TextField>(find.byType(TextField)).maxLines, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('输入字段保留 Tab 焦点顺序和提交回调', (WidgetTester tester) async {
    // 第一个字段的焦点节点。
    final FocusNode firstFocus = FocusNode();
    // 第二个字段的焦点节点。
    final FocusNode secondFocus = FocusNode();
    // 捕获输入动作提交的值。
    String? submitted;
    addTearDown(firstFocus.dispose);
    addTearDown(secondFocus.dispose);
    await tester.pumpWidget(
      _host(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            OmniTextField(focusNode: firstFocus),
            OmniTextField(
              focusNode: secondFocus,
              onSubmitted: (String value) => submitted = value,
            ),
          ],
        ),
      ),
    );
    firstFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(secondFocus.hasFocus, isTrue);
    await tester.enterText(find.byType(TextField).last, '提交内容');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(submitted, '提交内容');
  });

  testWidgets('触摸输入框保留热区并随大字体和多行内容增长', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(const OmniTextField(), platform: TargetPlatform.android),
    );
    // 普通字号下的字段高度。
    final double normalHeight = tester.getSize(find.byType(TextField)).height;
    expect(normalHeight, greaterThanOrEqualTo(OmniSize.touch));
    // 用户放大字号后的多行编辑内容。
    final TextEditingController controller = TextEditingController(
      text: '中文\n第二行',
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _host(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: OmniTextField(
            controller: controller,
            minLines: 2,
            maxLines: 4,
          ),
        ),
        platform: TargetPlatform.android,
      ),
    );
    expect(
      tester.getSize(find.byType(TextField)).height,
      greaterThan(normalHeight),
    );
    // 不设置最大高度，让文本自身布局决定所需空间。
    final TextField field = tester.widget<TextField>(find.byType(TextField));
    expect(field.decoration!.constraints!.maxHeight, double.infinity);
    expect(tester.takeException(), isNull);
  });

  testWidgets('三态复选框保留键盘切换并禁用无效操作', (WidgetTester tester) async {
    // 当前由业务维护的三态选择值。
    bool? value = false;
    // 是否允许用户改变值。
    bool enabled = true;
    // 供键盘测试定位的焦点节点。
    final FocusNode focusNode = FocusNode();
    // 局部重建入口。
    late StateSetter rebuild;
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            rebuild = setState;
            return OmniCheckbox(
              value: value,
              tristate: true,
              focusNode: focusNode,
              semanticLabel: '选择物品',
              onChanged: enabled
                  ? (bool? next) => setState(() => value = next)
                  : null,
            );
          },
        ),
      ),
    );
    focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(value, isTrue);
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    expect(value, isNull);
    rebuild(() => enabled = false);
    await tester.pump();
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    expect(value, isNull);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).onChanged, isNull);
  });

  testWidgets('单选行仍由 RadioGroup 管理方向键选择', (WidgetTester tester) async {
    // 当前选择值。
    int selection = 1;
    // 第一选项的焦点节点。
    final FocusNode focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            return RadioGroup<int>(
              groupValue: selection,
              onChanged: (int? value) => setState(() => selection = value!),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  OmniRadioListTile<int>(
                    value: 1,
                    title: const Text('合并'),
                    focusNode: focusNode,
                  ),
                  const OmniRadioListTile<int>(value: 2, title: Text('替换')),
                ],
              ),
            );
          },
        ),
      ),
    );
    focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(selection, 2);
  });

  testWidgets('触摸图标按钮和复选框具有最小热区', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            OmniIconButton(
              tooltip: '编辑',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () {},
            ),
            OmniCheckbox(value: false, onChanged: (bool? value) {}),
          ],
        ),
        platform: TargetPlatform.android,
      ),
    );
    expect(
      tester.getSize(find.byType(IconButton)).height,
      greaterThanOrEqualTo(OmniSize.touch),
    );
    expect(
      tester.getSize(find.byType(Checkbox)).height,
      greaterThanOrEqualTo(OmniSize.touch),
    );
    expect(find.byTooltip('编辑'), findsOneWidget);
  });

  testWidgets('嵌入式图标按钮完整覆盖默认热区约束且不溢出', (WidgetTester tester) async {
    // 需要兼容桌面悬浮窗与移动紧凑工具栏的平台。
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.windows,
      TargetPlatform.android,
    ]) {
      // 已有受控嵌入区域使用的视觉尺寸。
      for (final double extent in <double>[30, 32]) {
        await tester.pumpWidget(
          _host(
            Center(
              child: SizedBox.square(
                dimension: extent,
                child: OmniIconButton(
                  constraints: BoxConstraints.tightFor(
                    width: extent,
                    height: extent,
                  ),
                  padding: EdgeInsets.zero,
                  tooltip: '嵌入操作',
                  icon: const Icon(Icons.more_horiz_rounded),
                  onPressed: () {},
                ),
              ),
            ),
            platform: platform,
          ),
        );
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(IconButton)), Size.square(extent));
        // 对称覆盖的尺寸同时用于底层 Material 约束解析。
        final IconButton button = tester.widget<IconButton>(
          find.byType(IconButton),
        );
        expect(
          button.style!.minimumSize!.resolve(<WidgetState>{}),
          Size.square(extent),
        );
        expect(
          button.style!.maximumSize!.resolve(<WidgetState>{}),
          Size.square(extent),
        );
      }
    }
  });

  testWidgets('待办完成控件提供可操作读屏语义并响应减少动态效果', (WidgetTester tester) async {
    // 当前完成状态。
    bool value = false;
    // 读屏语义测试句柄。
    final SemanticsHandle handle = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        _host(
          MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) {
                return TodoCompletionCheckbox(
                  value: value,
                  onChanged: (bool next) => setState(() => value = next),
                );
              },
            ),
          ),
        ),
      );
      expect(
        tester.getSemantics(find.byType(TodoCompletionCheckbox)),
        matchesSemantics(
          label: '完成任务',
          hasCheckedState: true,
          hasEnabledState: true,
          isEnabled: true,
          isFocusable: true,
          hasFocusAction: true,
          hasTapAction: true,
        ),
      );
      await tester.tap(find.byType(TodoCompletionCheckbox));
      await tester.pump();
      expect(value, isTrue);
      expect(tester.hasRunningAnimations, isFalse);
    } finally {
      handle.dispose();
    }
  });
}
