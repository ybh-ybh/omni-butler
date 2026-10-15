import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/shared/ui/omni_note_audio_controls.dart';

/// 从读屏树找到唯一的可调进度节点，外层标签容器本身不是滑块。
SemanticsNode _sliderNode(WidgetTester tester) {
  // 记录实际提供滑块角色的节点，防止局部浮层引入重复操作。
  final List<SemanticsNode> sliders = <SemanticsNode>[];
  // 递归读取当前生产控件的语义子树。
  void visit(SemanticsNode node) {
    if (node.getSemanticsData().flagsCollection.isSlider) sliders.add(node);
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  visit(tester.getSemantics(find.byType(OmniNoteAudioSeekBar)));
  expect(sliders, hasLength(1));
  return sliders.single;
}

/// 局部浮层必须保留音频进度条的几何、唯一读屏操作及键盘控制。
void main() {
  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.windows,
    TargetPlatform.android,
  ]) {
    testWidgets('$platform 音频进度保持24dp且键盘和读屏操作只提交一次', (tester) async {
      // 全程启用语义，不以禁用无障碍规避原生问题。
      final SemanticsHandle semantics = tester.ensureSemantics();
      try {
        // 内存位置与调用计数区分一次激活和重复业务回调。
        double value = 5000;
        // 每个键盘或读屏动作只能分派一次位置变更。
        int changes = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.build(brightness: Brightness.light)
                .copyWith(platform: platform),
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 320,
                  child: StatefulBuilder(
                    builder: (context, setState) => OmniNoteAudioSeekBar(
                      value: value,
                      total: 10000,
                      label: '第1段播放进度',
                      onChanged: (next) => setState(() {
                        value = next;
                        changes++;
                      }),
                      onChangeEnd: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byType(OmniNoteAudioSeekBar)),
          const Size(320, 24),
        );
        expect(_sliderNode(tester).getSemanticsData().value, '5秒');
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(value, greaterThan(5000));
        expect(changes, 1);
        // 原生滑块继续提供唯一的增减操作及当前时间，而非重复操作节点。
        final SemanticsNode node = _sliderNode(tester);
        expect(
          node.getSemanticsData().hasAction(SemanticsAction.decrease),
          isTrue,
        );
        // 不同平台的默认步长可能不同，检查回调与方向而非复制内部常量。
        final double afterKeyboard = value;
        node.owner!.performAction(node.id, SemanticsAction.decrease);
        await tester.pumpAndSettle();
        expect(changes, 2);
        expect(value, lessThan(afterKeyboard));
        expect(
          tester
              .getSemantics(find.byType(OmniNoteAudioSeekBar))
              .getSemanticsData()
              .label,
          '第1段播放进度',
        );
        expect(
          tester.getSize(find.byType(OmniNoteAudioSeekBar)),
          const Size(320, 24),
        );
      } finally {
        semantics.dispose();
      }
    });
  }
}
