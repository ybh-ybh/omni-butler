import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 为浮层验证统一设置平台、字体和辅助功能偏好。
Widget _app({
  required Widget child,
  bool reduceMotion = false,
  bool accessibleNavigation = false,
  double textScale = 1,
  TargetPlatform platform = TargetPlatform.windows,
}) {
  return MaterialApp(
    theme: AppTheme.build(brightness: Brightness.light)
        .copyWith(platform: platform),
    builder: (BuildContext context, Widget? navigator) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        disableAnimations: reduceMotion,
        accessibleNavigation: accessibleNavigation,
        textScaler: TextScaler.linear(textScale),
      ),
      child: navigator!,
    ),
    home: Scaffold(body: child),
  );
}

/// 验证窄屏、键盘和减少动态效果下的浮层交互。
void main() {
  testWidgets('窄屏大字号弹窗的操作换行且关闭后恢复触发器焦点', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // 记录弹窗打开前后的键盘焦点。
    final FocusNode triggerFocus = FocusNode();
    addTearDown(triggerFocus.dispose);
    await tester.pumpWidget(
      _app(
        textScale: 1.7,
        child: Builder(
          builder: (BuildContext context) => TextButton(
            focusNode: triggerFocus,
            onPressed: () => showOmniDialog<void>(
              context: context,
              builder: (BuildContext context) => OmniDialogScaffold(
                title: '编辑事项',
                actions: <Widget>[
                  OmniButton(label: '恢复默认设置', onPressed: () {}),
                  OmniButton(label: '保存当前修改', onPressed: () {}),
                ],
                child: const Text('内容保持可读'),
              ),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );
    triggerFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester.getTopLeft(find.text('保存当前修改')).dy,
      greaterThan(tester.getTopLeft(find.text('恢复默认设置')).dy),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('编辑事项'), findsNothing);
    expect(triggerFocus.hasFocus, isTrue);
  });

  testWidgets('下拉选择结束后键盘焦点回到触发器', (WidgetTester tester) async {
    // 由调用方持有的下拉框焦点。
    final FocusNode dropdownFocus = FocusNode();
    addTearDown(dropdownFocus.dispose);
    // 验证键盘选中的实际值。
    String? selected;
    await tester.pumpWidget(
      _app(
        child: Center(
          child: OmniDropdownButton<String>(
            value: null,
            focusNode: dropdownFocus,
            hint: const Text('选择分类'),
            items: const <DropdownMenuItem<String>>[
              DropdownMenuItem<String>(value: 'work', child: Text('工作')),
              DropdownMenuItem<String>(value: 'life', child: Text('生活')),
            ],
            onChanged: (String? value) => selected = value,
          ),
        ),
      ),
    );
    dropdownFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, isNotNull);
    expect(dropdownFocus.hasFocus, isTrue);
    expect(find.byType(MenuItemButton), findsNothing);
  });

  testWidgets('减少动态效果的侧栏直接就位并允许遮罩关闭', (WidgetTester tester) async {
    await tester.pumpWidget(
      _app(
        reduceMotion: true,
        child: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => showOmniSideSheet<void>(
              context,
              builder: (BuildContext context) => const OmniSideSheetScaffold(
                title: '编辑侧栏',
                child: Text('侧栏内容'),
              ),
            ),
            child: const Text('打开侧栏'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开侧栏'));
    await tester.pump();
    expect(find.text('侧栏内容'), findsOneWidget);
    expect(find.byType(SlideTransition), findsNothing);
    await tester.tapAt(const Offset(20, 300));
    await tester.pumpAndSettle();
    expect(find.text('侧栏内容'), findsNothing);
  });

  // 软键盘避让在正常动效及减少动效模式下都应保留输入和保存入口。
  for (final bool reduceMotion in <bool>[false, true]) {
    testWidgets('触控侧栏避让软键盘并恢复视图 reduceMotion=$reduceMotion', (
      WidgetTester tester,
    ) async {
      await _verifySideSheetKeyboard(tester, reduceMotion: reduceMotion);
    });
  }

  testWidgets('触控选择菜单保留至少 48 的实际点击高度', (WidgetTester tester) async {
    await tester.pumpWidget(
      _app(
        platform: TargetPlatform.android,
        child: Center(
          child: OmniDropdownButton<String>(
            value: 'work',
            items: const <DropdownMenuItem<String>>[
              DropdownMenuItem<String>(value: 'work', child: Text('工作')),
              DropdownMenuItem<String>(value: 'life', child: Text('生活')),
            ],
            onChanged: (String? value) {},
          ),
        ),
      ),
    );
    await tester.tap(find.text('工作'));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.widgetWithText(MenuItemButton, '生活')).height,
      greaterThanOrEqualTo(48),
    );
  });

  testWidgets('日期浮层支持键盘进入当前日期并返回触发器', (WidgetTester tester) async {
    // 键盘确认后实际写入的日期。
    DateTime? selectedDate;
    await tester.pumpWidget(
      _app(
        child: Center(
          child: OmniDatePickerButton(
            value: DateTime(2026, 10, 6),
            initialDate: DateTime(2026, 10, 6),
            firstDate: DateTime(2020),
            lastDate: DateTime(2030),
            label: '选择日期',
            onChanged: (DateTime value) => selectedDate = value,
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selectedDate, DateTime(2026, 10, 7));
    expect(find.byType(GridView), findsNothing);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byWidgetPredicate((Widget widget) => widget is OutlinedButton),
          )
          .focusNode
          ?.hasFocus,
      isTrue,
    );
  });

  testWidgets('时间浮层滚动后将键盘焦点交给当前分钟', (WidgetTester tester) async {
    // 键盘确认后实际写入的时间。
    TimeOfDay? selectedTime;
    await tester.pumpWidget(
      _app(
        child: Center(
          child: OmniTimePickerButton(
            value: const TimeOfDay(hour: 17, minute: 55),
            label: '选择时间',
            onChanged: (TimeOfDay value) => selectedTime = value,
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selectedTime, const TimeOfDay(hour: 18, minute: 0));
    expect(find.byType(MenuItemButton), findsNothing);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byWidgetPredicate((Widget widget) => widget is OutlinedButton),
          )
          .focusNode
          ?.hasFocus,
      isTrue,
    );
  });

  testWidgets('辅助导航下仍可在倒计时内撤销消息', (WidgetTester tester) async {
    // 记录撤销动作是否仍可访问。
    bool undone = false;
    await tester.pumpWidget(
      _app(
        accessibleNavigation: true,
        child: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => showOmniMessage(
              context,
              message: '事项已归档',
              actionLabel: '撤销',
              duration: const Duration(seconds: 1),
              onAction: () => undone = true,
            ),
            child: const Text('显示消息'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('显示消息'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('事项已归档'), findsOneWidget);
    await tester.tap(find.text('撤销'));
    await tester.pump();
    expect(undone, isTrue);
    expect(find.text('事项已归档'), findsNothing);
  });

  testWidgets('触控日历在窄屏完整展示日期网格', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _app(
        platform: TargetPlatform.android,
        textScale: 1.5,
        child: Align(
          alignment: Alignment.topCenter,
          child: OmniDatePickerButton(
            value: DateTime(2026, 10, 6),
            initialDate: DateTime(2026, 10, 6),
            firstDate: DateTime(2020),
            lastDate: DateTime(2030),
            label: '选择日期',
            onChanged: (DateTime date) {},
          ),
        ),
      ),
    );
    await tester.tap(find.text('选择日期'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // 所有日期格都应完整保留在日历网格中。
    final Rect gridBounds = tester.getRect(find.byType(GridView));
    expect(gridBounds.left, greaterThanOrEqualTo(0));
    expect(gridBounds.right, lessThanOrEqualTo(360));
    expect(
      find.descendant(
        of: find.byType(GridView),
        matching: find.byType(TextButton),
      ),
      findsNWidgets(42),
    );
  });
}

/// 在真实视口 inset 变化下验证长表单、固定保存区和关闭后的尺寸恢复。
Future<void> _verifySideSheetKeyboard(
  WidgetTester tester, {
  required bool reduceMotion,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  // 保存位于长表单底部的输入值，确认键盘展开期间能够提交。
  final TextEditingController controller = TextEditingController();
  addTearDown(controller.dispose);
  // 记录保存动作实际收到的值。
  String? savedText;
  // 底层页面的尺寸标识，用于核对关闭后的可用视图。
  const Key pageKey = ValueKey<String>('keyboard-preview-page');
  // 已有业务表单自带的滚动视口标识。
  const Key scrollKey = ValueKey<String>('keyboard-preview-scroll');
  // 长表单底部的输入控件标识。
  const Key inputKey = ValueKey<String>('keyboard-preview-input');
  await tester.pumpWidget(
    _app(
      platform: TargetPlatform.android,
      reduceMotion: reduceMotion,
      child: Builder(
        builder: (BuildContext context) => SizedBox.expand(
          key: pageKey,
          child: Center(
            child: TextButton(
              onPressed: () => showOmniSideSheet<void>(
                context,
                builder: (BuildContext dialogContext) => OmniSideSheetScaffold(
                  title: '软键盘编辑器',
                  actions: <Widget>[
                    OmniButton(
                      label: '保存编辑',
                      onPressed: () {
                        savedText = controller.text;
                        Navigator.of(dialogContext).pop();
                      },
                    ),
                  ],
                  child: SingleChildScrollView(
                    key: scrollKey,
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: <Widget>[
                        const Text('长表单内容'),
                        const SizedBox(height: 700),
                        OmniTextField(
                          key: inputKey,
                          controller: controller,
                          maxLines: 2,
                          decoration: const InputDecoration(labelText: '底部说明'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              child: const Text('打开触控编辑器'),
            ),
          ),
        ),
      ),
    ),
  );
  // 没有软键盘时底层页面的完整可用范围。
  final Rect initialPage = tester.getRect(find.byKey(pageKey));
  await tester.tap(find.text('打开触控编辑器'));
  await tester.pumpAndSettle();
  // 保存按钮沿用现有操作区，不随表单一起滚动。
  final Finder saveButton = find.widgetWithText(OmniButton, '保存编辑');
  // 没有软键盘时操作区的初始坐标。
  final Rect initialSave = tester.getRect(saveButton);
  // 没有软键盘时正文视口的初始高度。
  final double initialScrollHeight = tester
      .getSize(find.byKey(scrollKey))
      .height;
  await tester.ensureVisible(find.byKey(inputKey));
  await tester.enterText(find.byKey(inputKey), '中文第一行\n中文第二行');
  await tester.pump();

  tester.view.viewInsets = const FakeViewPadding(bottom: 300);
  await tester.pump();
  if (reduceMotion) {
    expect(
      tester.getRect(saveButton).bottom,
      closeTo(initialSave.bottom - 300, 0.1),
      reason: '减少动效时键盘避让应在本帧直接就位',
    );
  }
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  expect(tester.getRect(saveButton).bottom, lessThanOrEqualTo(544));
  expect(
    tester.getSize(find.byKey(scrollKey)).height,
    closeTo(initialScrollHeight - 300, 0.1),
  );
  expect(
    MediaQuery.viewInsetsOf(tester.element(find.byKey(inputKey))).bottom,
    0,
    reason: '已消费的 inset 不应让内部表单重复避让',
  );
  await tester.ensureVisible(find.byKey(inputKey));
  await tester.pumpAndSettle();
  expect(
    tester.getRect(find.byKey(inputKey)).bottom,
    lessThanOrEqualTo(tester.getRect(find.byKey(scrollKey)).bottom),
  );
  expect(saveButton.hitTestable(), findsOneWidget);
  await tester.tap(saveButton);
  await tester.pumpAndSettle();
  expect(savedText, '中文第一行\n中文第二行');
  expect(find.text('软键盘编辑器'), findsNothing);

  tester.view.resetViewInsets();
  await tester.pumpAndSettle();
  expect(tester.getRect(find.byKey(pageKey)), initialPage);
  await tester.tap(find.text('打开触控编辑器'));
  await tester.pumpAndSettle();
  expect(tester.getRect(saveButton), initialSave);
  await tester.tap(find.byTooltip('关闭'));
  await tester.pumpAndSettle();
  expect(find.text('软键盘编辑器'), findsNothing);
  expect(tester.takeException(), isNull);
}
