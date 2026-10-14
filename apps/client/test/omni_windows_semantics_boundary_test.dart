import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/shared/ui/omni_windows_semantics_boundary.dart';

/// 回归Flutter相邻traversalParentIdentifier不能合并的Windows故障触发条件。
void main() {
  testWidgets('Windows索引列表中的相邻浮层锚点分别保留语义节点', (tester) async {
    // 开启读屏并在测试验证结束前可靠释放。
    final SemanticsHandle handle = tester.ensureSemantics();
    try {
      // 两个独立浮层的父标识必须都能到达序列化树。
      final Object first = Object();
      final Object second = Object();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: Scaffold(
            body: ListView(
              children: [
                Row(
                  children: [
                    OmniWindowsSemanticsBoundary(
                      child: Semantics(
                        key: const ValueKey('first-anchor'),
                        traversalParentIdentifier: first,
                        child: const Text('浮层A'),
                      ),
                    ),
                    OmniWindowsSemanticsBoundary(
                      child: Semantics(
                        key: const ValueKey('second-anchor'),
                        traversalParentIdentifier: second,
                        child: const Text('浮层B'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      // 不能丢掉第二个锚点或把两个锚点变成同一节点。
      final SemanticsNode a = tester.getSemantics(
        find.byKey(const ValueKey('first-anchor')),
      );
      final SemanticsNode b = tester.getSemantics(
        find.byKey(const ValueKey('second-anchor')),
      );
      expect(a.id, isNot(b.id));
      expect(a.getSemanticsData().label, '浮层A');
      expect(b.getSemanticsData().label, '浮层B');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      handle.dispose();
    }
  });

  testWidgets('Android不添加Windows语义隔离层', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: const Scaffold(
          body: OmniWindowsSemanticsBoundary(child: Text('保持原树')),
        ),
      ),
    );
    expect(
      find.descendant(
        of: find.byType(OmniWindowsSemanticsBoundary),
        matching: find.byType(Semantics),
      ),
      findsNothing,
    );
  });
}
