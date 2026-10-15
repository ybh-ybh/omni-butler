import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/shared/ui/omni_button.dart';
import 'package:omni_butler/shared/ui/omni_icon_button.dart';
import 'package:omni_butler/shared/ui/omni_interactive_controls.dart';
import 'package:omni_butler/shared/ui/omni_press_feedback.dart';
import 'package:omni_butler/shared/ui/omni_press_surface.dart';
import 'package:omni_butler/shared/ui/omni_selection.dart';
import 'package:omni_butler/shared/ui/omni_switch.dart';
import 'package:omni_butler/shared/ui/omni_taxonomy_chip.dart';

/// 为真实原生控件保留主题、语义与平台分支。
Widget _host(
  Widget child, {
  TargetPlatform platform = TargetPlatform.windows,
  bool reduced = false,
  double textScale = 1,
}) => MaterialApp(
  theme: AppTheme.build(brightness: Brightness.light)
      .copyWith(platform: platform),
  home: MediaQuery(
    data: MediaQueryData(
      disableAnimations: reduced,
      textScaler: TextScaler.linear(textScale),
    ),
    child: Scaffold(
      body: Center(child: SizedBox(width: 360, child: child)),
    ),
  ),
);

/// 读取生产内容层真正绘制的缩放矩阵。
double _scale(WidgetTester tester, Finder root) {
  // 当前交互自己的内容层，排除后代独立按钮。
  final Finder content = find
      .descendant(of: root, matching: find.byType(OmniPressContent))
      .first;
  // 实际绘制变换与占位是相互独立的。
  final Transform transform = tester.widget<Transform>(
    find.descendant(of: content, matching: find.byType(Transform)).first,
  );
  return transform.transform.storage[0];
}

/// 验证 Windows 内容按压、业务时序和单一交互所有权。
void main() {
  testWidgets('上下文右键只缩一层内容，禁用和减少动画保持原尺寸', (tester) async {
    // 直接覆盖上下文手势与内容边界的启用及减少动画组合。
    for (final bool enabled in <bool>[true, false]) {
      // 减少动画只取消缩放，不取消原本允许的菜单动作。
      for (final bool reduced in <bool>[false, true]) {
        // 原右键菜单和行内左键业务独立计数。
        int menus = 0;
        int actions = 0;
        await tester.pumpWidget(
          _host(
            OmniPressSurface(
              enabled: enabled,
              onSecondaryTapUp: (_) => menus++,
              child: ColoredBox(
                key: const ValueKey('secondary-background'),
                color: Colors.white,
                child: OmniSecondaryPressContent(
                  child: Row(
                    children: <Widget>[
                      const Expanded(child: Text('上下文条目')),
                      OmniIconButton(
                        key: const ValueKey('secondary-child'),
                        icon: const Icon(Icons.add),
                        onPressed: () => actions++,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            reduced: reduced,
          ),
        );
        // 背景位于内容缩放边界之外。
        final Rect background = tester.getRect(
          find.byKey(const ValueKey('secondary-background')),
        );
        // 完整绘制矩阵可以识别后代是否重复叠加同一反馈。
        final RenderBox label = tester.renderObject<RenderBox>(
          find.text('上下文条目'),
        );
        // 从原有右键识别器发起按压。
        final TestGesture pointer = await tester.startGesture(
          tester.getCenter(find.text('上下文条目')),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        await tester.pump(const Duration(milliseconds: 90));
        expect(
          label.getTransformTo(null).storage[0],
          closeTo(enabled && !reduced ? 0.97 : 1, 0.00001),
        );
        expect(
          _scale(tester, find.byKey(const ValueKey('secondary-child'))),
          1,
        );
        expect(
          tester.getRect(find.byKey(const ValueKey('secondary-background'))),
          background,
        );
        await pointer.up();
        expect(menus, enabled ? 1 : 0);
        expect(actions, 0);
        await tester.pumpAndSettle();
        expect(label.getTransformTo(null).storage[0], 1);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });

  testWidgets('原生 pressed 中间帧只缩内容，取消从当前值恢复且热区不变', (tester) async {
    // 从实际按钮中取得生产状态控制器。
    await tester.pumpWidget(_host(OmniButton(label: '保存', onPressed: () {})));
    // 原生按钮的固定边界。
    final Finder button = find.byType(FilledButton);
    final Rect original = tester.getRect(button);
    // 由原生状态控制器发出的按压边沿。
    final WidgetStatesController states = tester
        .widget<FilledButton>(button)
        .statesController!;
    states.update(WidgetState.pressed, true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 45));
    expect(_scale(tester, button), inExclusiveRange(0.97, 1));
    expect(tester.getRect(button), original);
    states.update(WidgetState.pressed, false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(_scale(tester, button), inExclusiveRange(0.97, 1));
    expect(tester.getRect(button), original);
    await tester.pumpAndSettle();
    expect(_scale(tester, button), 1);
  });

  testWidgets('快速有效点击立即执行业务，下一帧仍可见缩小再恢复', (tester) async {
    // 业务次数不因视觉动画重复。
    int calls = 0;
    await tester.pumpWidget(
      _host(OmniButton(label: '提交', onPressed: () => calls++)),
    );
    await tester.tap(find.text('提交'));
    expect(calls, 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 45));
    expect(_scale(tester, find.byType(FilledButton)), lessThan(1));
    await tester.pumpAndSettle();
    expect(_scale(tester, find.byType(FilledButton)), 1);
    expect(calls, 1);
  });

  testWidgets('完整按住后释放160毫秒恢复，不补播第二次压下', (tester) async {
    // 真实鼠标操作与业务时序同时验证。
    int calls = 0;
    await tester.pumpWidget(
      _host(OmniButton(label: '确认', onPressed: () => calls++)),
    );
    // 等待识别器与压下动画完整完成。
    final TestGesture pointer = await tester.startGesture(
      tester.getCenter(find.text('确认')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 90));
    expect(_scale(tester, find.byType(FilledButton)), closeTo(0.97, 0.0001));
    await pointer.up();
    expect(calls, 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(_scale(tester, find.byType(FilledButton)), greaterThan(0.97));
    await tester.pump(const Duration(milliseconds: 80));
    expect(_scale(tester, find.byType(FilledButton)), 1);
  });

  testWidgets('子图标按住只缩自己，不压缩父行或触发父回调', (tester) async {
    // 父子业务分别统计。
    int parentCalls = 0;
    int childCalls = 0;
    await tester.pumpWidget(
      _host(
        Material(
          child: OmniInkWell(
            key: const ValueKey('parent'),
            onTap: () => parentCalls++,
            child: Row(
              children: <Widget>[
                const Expanded(child: Text('父项')),
                OmniIconButton(
                  key: const ValueKey('child'),
                  icon: const Icon(Icons.add),
                  onPressed: () => childCalls++,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // 实际鼠标按住覆盖手势竞技场的父子竞争。
    final TestGesture pointer = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('child'))),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 90));
    expect(_scale(tester, find.byKey(const ValueKey('parent'))), 1);
    expect(
      _scale(tester, find.byKey(const ValueKey('child'))),
      closeTo(0.97, 0.0001),
    );
    await pointer.up();
    expect(childCalls, 1);
    expect(parentCalls, 0);
    await tester.pumpAndSettle();
  });

  testWidgets('右键快速点击同样压缩内容且不触发左键业务，取消只恢复', (tester) async {
    // 鼠标两个按键保留独立业务。
    int taps = 0;
    int menus = 0;
    await tester.pumpWidget(
      _host(
        Material(
          child: OmniInkWell(
            onTap: () => taps++,
            onSecondaryTap: () => menus++,
            child: const SizedBox(height: 48, child: Center(child: Text('条目'))),
          ),
        ),
      ),
    );
    await tester.tap(
      find.text('条目'),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pump();
    expect(menus, 1);
    expect(taps, 0);
    await tester.pump(const Duration(milliseconds: 45));
    expect(_scale(tester, find.byType(OmniInkWell)), lessThan(1));
    await tester.pumpAndSettle();
    // 取消不会被当成快速成功点击补播压缩。
    final TestGesture pointer = await tester.startGesture(
      tester.getCenter(find.text('条目')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await pointer.cancel();
    await tester.pumpAndSettle();
    expect(taps, 0);
    expect(_scale(tester, find.byType(OmniInkWell)), 1);
  });

  testWidgets('键盘及语义激活都保留一次业务与可见内容反馈', (tester) async {
    // 原生焦点与语义通过同一按钮入口。
    int calls = 0;
    final FocusNode focus = FocusNode();
    final SemanticsHandle semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(
        OmniIconButton(
          tooltip: '新增',
          icon: const Icon(Icons.add),
          focusNode: focus,
          onPressed: () => calls++,
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(calls, 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 45));
    expect(_scale(tester, find.byType(OmniIconButton)), lessThan(1));
    await tester.pumpAndSettle();
    // 读屏动作同步经过 true/false 边沿，仍需显示有效点击。
    final SemanticsNode node = tester.getSemantics(find.byType(IconButton));
    node.owner!.performAction(node.id, SemanticsAction.tap);
    expect(calls, 2);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 45));
    expect(_scale(tester, find.byType(OmniIconButton)), lessThan(1));
    await tester.pumpAndSettle();
    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    focus.dispose();
  });

  testWidgets('复选框三态与开关由唯一宿主操作，点击圆圈和标签均有效', (tester) async {
    // 三态复选框和开关分别保存状态。
    bool? checked = false;
    bool switched = false;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, rebuild) => Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              OmniCheckbox(
                value: checked,
                tristate: true,
                onChanged: (value) => rebuild(() => checked = value),
              ),
              OmniSwitchListTile(
                value: switched,
                title: const Text('启用提醒'),
                onChanged: (value) => rebuild(() => switched = value),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tapAt(tester.getCenter(find.byType(Checkbox)));
    expect(checked, true);
    await tester.pumpAndSettle();
    await tester.tapAt(tester.getCenter(find.byType(Checkbox)));
    expect(checked, isNull);
    await tester.pumpAndSettle();
    await tester.tap(find.text('启用提醒'));
    expect(switched, true);
    await tester.pumpAndSettle();
    await tester.tapAt(tester.getCenter(find.byType(OmniSwitch)));
    expect(switched, false);
    await tester.pumpAndSettle();
  });

  testWidgets('单选圆圈与行共享热区，方向键跳过禁用项并只提交一次', (tester) async {
    // 组值和提交次数由真实 RadioGroup 管理。
    int selected = 1;
    int changes = 0;
    final FocusNode firstFocus = FocusNode();
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, rebuild) => RadioGroup<int>(
            groupValue: selected,
            onChanged: (value) {
              changes++;
              rebuild(() => selected = value!);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                OmniRadioListTile(
                  value: 1,
                  title: const Text('第一项'),
                  focusNode: firstFocus,
                ),
                const OmniRadioListTile(
                  value: 2,
                  title: Text('禁用项'),
                  enabled: false,
                ),
                const OmniRadioListTile(value: 3, title: Text('第三项')),
              ],
            ),
          ),
        ),
      ),
    );
    firstFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(selected, 3);
    expect(changes, 1);
    await tester.tapAt(tester.getCenter(find.byType(Radio<bool>).first));
    await tester.pumpAndSettle();
    expect(selected, 1);
    expect(changes, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    firstFocus.dispose();
  });

  testWidgets('已选单选项空格仍有按压反馈且组业务不重复', (tester) async {
    // 原生组对已选且不可取消的项不应发出变更。
    int changes = 0;
    final FocusNode focus = FocusNode();
    await tester.pumpWidget(
      _host(
        RadioGroup<int>(
          groupValue: 1,
          onChanged: (_) => changes++,
          child: OmniRadioListTile<int>(
            value: 1,
            title: const Text('已选项'),
            focusNode: focus,
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 45));
    expect(_scale(tester, find.byType(OmniRadioListTile<int>)), lessThan(1));
    expect(changes, 0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(_scale(tester, find.byType(OmniRadioListTile<int>)), 1);
    expect(changes, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    focus.dispose();
  });

  testWidgets('选择气泡保留选中语义和回调，按压不改变背景边界', (tester) async {
    // 气泡业务更新由调用方持有。
    bool selected = false;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, rebuild) => Align(
            child: OmniFilterChip(
              label: const Text('标签'),
              selected: selected,
              onSelected: (value) => rebuild(() => selected = value),
            ),
          ),
        ),
      ),
    );
    // 选择前后背景热区保持不变。
    final Rect original = tester.getRect(find.byType(TextButton));
    await tester.tap(find.text('标签'));
    expect(selected, true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 45));
    expect(_scale(tester, find.byType(TextButton)), lessThan(1));
    expect(tester.getRect(find.byType(TextButton)).height, original.height);
    await tester.pumpAndSettle();
  });

  testWidgets('减少动画只保留原交互，Android 内容不增加变换', (tester) async {
    // 可操作性不因系统减少动画而消失。
    int calls = 0;
    await tester.pumpWidget(
      _host(OmniButton(label: '操作', onPressed: () => calls++), reduced: true),
    );
    await tester.tap(find.text('操作'));
    await tester.pump(const Duration(milliseconds: 45));
    expect(calls, 1);
    expect(_scale(tester, find.byType(FilledButton)), 1);
    await tester.pumpWidget(
      _host(
        OmniButton(label: '操作', onPressed: () => calls++),
        platform: TargetPlatform.android,
      ),
    );
    // MaterialApp 的 AnimatedTheme 完成后才真正切到 Android 平台。
    await tester.pumpAndSettle();
    await tester.tap(find.text('操作'));
    await tester.pump();
    // Android 内容层直接返回 child，不创建 Windows 变换。
    final Finder content = find.byType(OmniPressContent);
    expect(
      find.descendant(of: content, matching: find.byType(Transform)),
      findsNothing,
    );
    expect(calls, 2);
    await tester.pumpAndSettle();
  });

  testWidgets('紧凑标签与设置头像气泡在正常及大字号下保持原生尺寸和文字位置', (tester) async {
    // 真实Windows主题确保compact密度与产品中的静止几何相同。
    for (final double textScale in <double>[1, 1.6]) {
      for (final bool selected in <bool>[false, true]) {
        for (final bool enabled in <bool>[true, false]) {
          await tester.pumpWidget(
            _host(
              Builder(
                builder: (BuildContext context) {
                  // 复用生产标签色及字体，仅原生控件承担参照布局。
                  final OmniColors colors = OmniColors.of(context);
                  // 两侧保持同一可操作状态，禁用样式不影响尺寸。
                  final ValueChanged<bool>? onSelected = enabled
                      ? (_) {}
                      : null;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      FilterChip(
                        key: const ValueKey('native-taxonomy'),
                        label: const Text('工作标签'),
                        selected: selected,
                        showCheckmark: false,
                        onSelected: onSelected,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        backgroundColor: colors.paper,
                        selectedColor: colors.brand.withValues(alpha: 0.12),
                        side: BorderSide(
                          color: selected
                              ? colors.brand.withValues(alpha: 0.42)
                              : colors.line,
                        ),
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.all(Radius.circular(8)),
                        ),
                        labelStyle: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: selected ? colors.brand : colors.muted,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                      ),
                      OmniTaxonomyChip(
                        key: const ValueKey('omni-taxonomy'),
                        label: '工作标签',
                        selected: selected,
                        onSelected: onSelected,
                      ),
                      ChoiceChip(
                        key: const ValueKey('native-settings'),
                        label: const Text('外观与主题'),
                        avatar: const Icon(Icons.palette_outlined, size: 20),
                        selected: selected,
                        onSelected: onSelected,
                      ),
                      OmniChoiceChip(
                        key: const ValueKey('omni-settings'),
                        label: const Text('外观与主题'),
                        avatar: const Icon(Icons.palette_outlined, size: 20),
                        selected: selected,
                        onSelected: onSelected,
                      ),
                    ],
                  );
                },
              ),
              textScale: textScale,
            ),
          );
          await tester.pumpAndSettle();
          for (final String kind in <String>['taxonomy', 'settings']) {
            // 比较完整热区与文字相对位置，防止只有外框相等但内部错位。
            final Finder native = find.byKey(ValueKey<String>('native-$kind'));
            final Finder adapted = find.byKey(ValueKey<String>('omni-$kind'));
            final Finder nativeText = find.descendant(
              of: native,
              matching: find.byType(Text),
            );
            final Finder adaptedText = find.descendant(
              of: adapted,
              matching: find.byType(Text),
            );
            expect(tester.getSize(adapted), tester.getSize(native));
            expect(tester.getSize(adaptedText), tester.getSize(nativeText));
            expect(
              tester.getTopLeft(adaptedText) - tester.getTopLeft(adapted),
              tester.getTopLeft(nativeText) - tester.getTopLeft(native),
            );
          }
          expect(tester.takeException(), isNull);
        }
      }
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('Checkbox与Radio行的原生圆圈热区和文字几何保持一致', (tester) async {
    // 正常及大字号均复用原生同配置绘制，不能改变行高或圆圈间距。
    for (final double textScale in <double>[1, 1.6]) {
      for (final bool enabled in <bool>[true, false]) {
        await tester.pumpWidget(
          _host(
            RadioGroup<int>(
              groupValue: 1,
              onChanged: (_) {},
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Checkbox(
                    key: const ValueKey('native-checkbox'),
                    value: true,
                    onChanged: enabled ? (_) {} : null,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  OmniCheckbox(
                    key: const ValueKey('omni-checkbox'),
                    value: true,
                    onChanged: enabled ? (_) {} : null,
                  ),
                  RadioListTile<int>(
                    key: const ValueKey('native-radio'),
                    value: 1,
                    enabled: enabled,
                    title: const Text('第一项'),
                    subtitle: const Text('原来的说明文字'),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                  ),
                  RadioGroup<int>(
                    groupValue: 1,
                    onChanged: (_) {},
                    child: OmniRadioListTile<int>(
                      key: const ValueKey('omni-radio'),
                      value: 1,
                      enabled: enabled,
                      title: const Text('第一项'),
                      subtitle: const Text('原来的说明文字'),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            textScale: textScale,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byKey(const ValueKey('omni-checkbox'))),
          tester.getSize(find.byKey(const ValueKey('native-checkbox'))),
        );
        // 原生RadioListTile内部圆圈与适配器视觉圆圈使用同样的shrinkWrap热区。
        final Finder native = find.byKey(const ValueKey('native-radio'));
        final Finder adapted = find.byKey(const ValueKey('omni-radio'));
        final Finder nativeCircle = find.descendant(
          of: native,
          matching: find.byType(Radio<int>),
        );
        final Finder adaptedCircle = find.descendant(
          of: adapted,
          matching: find.byType(Radio<bool>),
        );
        expect(tester.getSize(adapted), tester.getSize(native));
        expect(tester.getSize(adaptedCircle), tester.getSize(nativeCircle));
        expect(
          tester.getTopLeft(adaptedCircle) - tester.getTopLeft(adapted),
          tester.getTopLeft(nativeCircle) - tester.getTopLeft(native),
        );
        for (final String text in <String>['第一项', '原来的说明文字']) {
          // 对照圆圈后标题与副标题的真实相对位置。
          final Finder nativeText = find.descendant(
            of: native,
            matching: find.text(text),
          );
          final Finder adaptedText = find.descendant(
            of: adapted,
            matching: find.text(text),
          );
          expect(
            tester.getTopLeft(adaptedText) - tester.getTopLeft(adapted),
            tester.getTopLeft(nativeText) - tester.getTopLeft(native),
          );
        }
        expect(tester.takeException(), isNull);
      }
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
