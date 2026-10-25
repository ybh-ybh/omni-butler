import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 逐帧验证高度变化、反向接续、隐藏交互及独立按钮的反馈边界。
void main() {
  setUpAll(() async {
    if (Platform.environment['DISCLOSURE_PREVIEW'] != '1') return;
    // 显式预览使用本机真实中文字体，常规测试不依赖系统文件。
    final ByteData bytes = ByteData.sublistView(
      await File('C:/Windows/Fonts/msyh.ttc').readAsBytes(),
    );
    for (final String family in <String>[
      'Ahem',
      'Roboto',
      'Microsoft YaHei UI',
      'Microsoft YaHei',
    ]) {
      // 所有主题候选使用相同中文字形，避免截图出现占位方块。
      final FontLoader loader = FontLoader(family)
        ..addFont(Future.value(bytes));
      await loader.load();
    }
  });
  testWidgets('子项向下展开向上收起，反向点击接续当前高度且内容不缩放', (WidgetTester tester) async {
    // 业务层持有的展开状态。
    bool expanded = false;
    // 用于主动反向切换的测试宿主。
    late StateSetter update;
    // 原尺寸与动画中间帧的真实像素边界。
    final GlobalKey boundary = GlobalKey();
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return RepaintBoundary(
              key: boundary,
              child: ColoredBox(
                color: Colors.white,
                child: SizedBox(
                  width: 360,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      OmniDisclosureToggle(
                        expanded: expanded,
                        child: OmniButton(
                          label: '展开子项',
                          onPressed: () => update(() => expanded = !expanded),
                        ),
                      ),
                      OmniDisclosure(
                        key: const ValueKey('disclosure'),
                        expanded: expanded,
                        child: const SizedBox(
                          key: ValueKey('details'),
                          height: 180,
                          child: Center(child: Text('子项内容保持原始字号')),
                        ),
                      ),
                      const SizedBox(
                        key: ValueKey('next'),
                        height: 32,
                        child: Text('下一项'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
    // 折叠时下一项紧接标题，且不挂载隐藏内容。
    final double closedY = tester
        .getTopLeft(find.byKey(const ValueKey('next')))
        .dy;
    expect(find.byKey(const ValueKey('details')), findsNothing);
    await tester.tap(find.text('展开子项'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // 开启过程只改变占用高度，内部文字绘制矩阵保持一比一。
    final double openingHeight = tester
        .getSize(find.byKey(const ValueKey('disclosure')))
        .height;
    expect(openingHeight, allOf(greaterThan(0), lessThan(180)));
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('next'))).dy,
      closeTo(closedY + openingHeight, .01),
    );
    final RenderBox content = tester.renderObject(
      find.byKey(const ValueKey('details')),
    );
    expect(content.getTransformTo(null).storage[0], 1);
    expect(content.getTransformTo(null).storage[5], 1);
    await _capture(tester, boundary, 'opening');
    update(() => expanded = false);
    await tester.pump();
    expect(
      tester.getSize(find.byKey(const ValueKey('disclosure'))).height,
      closeTo(openingHeight, .01),
    );
    await tester.pump(const Duration(milliseconds: 30));
    expect(
      tester.getSize(find.byKey(const ValueKey('disclosure'))).height,
      lessThan(openingHeight),
    );
    // 收起中内容仍绘制，从当前高度反向展开不会闪回零高度。
    expect(find.byKey(const ValueKey('details')), findsOneWidget);
    update(() => expanded = true);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const ValueKey('disclosure'))).height,
      180,
    );
    await _capture(tester, boundary, 'expanded');
    update(() => expanded = false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('details')), findsOneWidget);
    await _capture(tester, boundary, 'closing');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('details')), findsNothing);
    expect(tester.getTopLeft(find.byKey(const ValueKey('next'))).dy, closedY);
    await _capture(tester, boundary, 'collapsed');
    expect(tester.takeException(), isNull);
  });

  testWidgets('展开行不缩放，行内普通按钮仍独立缩放并执行一次', (WidgetTester tester) async {
    // 两种操作分别计数，检查原手势排他行为。
    int toggles = 0;
    // 独立子按钮不得触发父行展开。
    int actions = 0;
    await tester.pumpWidget(
      _host(
        OmniDisclosureToggle(
          expanded: false,
          child: OmniListRow(
            title: const Text('父项'),
            onTap: () => toggles++,
            trailing: OmniIconButton(
              tooltip: '独立操作',
              icon: const Icon(Icons.add),
              onPressed: () => actions++,
            ),
          ),
        ),
      ),
    );
    // 真实按住父标题不压缩其内容。
    final TestGesture parentPress = await tester.startGesture(
      tester.getCenter(find.text('父项')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    expect(
      tester
          .renderObject<RenderBox>(find.text('父项'))
          .getTransformTo(null)
          .storage[0],
      1,
    );
    await parentPress.up();
    await tester.pumpAndSettle();
    expect(toggles, 1);
    final TestGesture childPress = await tester.startGesture(
      tester.getCenter(find.byIcon(Icons.add)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 90));
    expect(
      tester
          .renderObject<RenderBox>(find.byIcon(Icons.add))
          .getTransformTo(null)
          .storage[0],
      closeTo(.97, .0001),
    );
    expect(
      tester
          .renderObject<RenderBox>(find.text('父项'))
          .getTransformTo(null)
          .storage[0],
      1,
    );
    await childPress.up();
    await tester.pumpAndSettle();
    expect(actions, 1);
    expect(toggles, 1);
  });

  testWidgets('惰性组展开期间只构建视口行，滚动到底仍可反向收起', (WidgetTester tester) async {
    // 千行数据的构建量不随动画进度接近零而放大。
    bool expanded = false;
    // 允许在滚动后从业务层收起整组。
    late StateSetter update;
    // 精确滚动到组末尾以覆盖非零 scrollOffset。
    final ScrollController scroll = ScrollController();
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return SizedBox(
              height: 400,
              child: CustomScrollView(
                controller: scroll,
                slivers: <Widget>[
                  const SliverToBoxAdapter(child: SizedBox(height: 40)),
                  OmniDisclosure.sliver(
                    expanded: expanded,
                    child: SliverList.builder(
                      itemCount: 1000,
                      itemBuilder: (context, index) =>
                          SizedBox(height: 50, child: Text('惰性子项 $index')),
                    ),
                  ),
                  const SliverToBoxAdapter(
                    child: SizedBox(height: 40, child: Text('后续分组')),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
    update(() => expanded = true);
    await tester.pump();
    expect(find.textContaining('惰性子项').evaluate().length, lessThan(30));
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.textContaining('惰性子项').evaluate().length, lessThan(30));
    await tester.pumpAndSettle();
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text('后续分组').hitTestable(), findsOneWidget);
    update(() => expanded = false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(find.textContaining('惰性子项'), findsNothing);
    expect(find.text('后续分组').hitTestable(), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    scroll.dispose();
  });

  testWidgets('减少动画即时展开收起，保活表单保持输入且隐藏操作退出焦点和语义', (WidgetTester tester) async {
    // 验证在关闭与重新开启时仍持有同一个输入值。
    final TextEditingController controller = TextEditingController(
      text: '保留的内容',
    );
    // 原输入焦点由表单持有。
    final FocusNode focus = FocusNode();
    // 测试从已经展开的表单开始。
    bool expanded = true;
    // 受控宿主模拟系统偏好和业务状态更新。
    late StateSetter update;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return OmniDisclosure(
              key: const ValueKey('form-disclosure'),
              expanded: expanded,
              maintainState: true,
              child: TextField(controller: controller, focusNode: focus),
            );
          },
        ),
        reduced: true,
      ),
    );
    focus.requestFocus();
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    update(() => expanded = false);
    await tester.pump();
    expect(
      tester.getSize(find.byKey(const ValueKey('form-disclosure'))).height,
      0,
    );
    expect(focus.hasFocus, isFalse);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(TextField, skipOffstage: false), findsOneWidget);
    update(() => expanded = true);
    await tester.pump();
    expect(
      tester.getSize(find.byKey(const ValueKey('form-disclosure'))).height,
      greaterThan(0),
    );
    expect(controller.text, '保留的内容');
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    focus.dispose();
    expect(tester.takeException(), isNull);
  });
}

/// 固定桌面平台并通过真实媒体偏好控制减少动画。
Widget _host(Widget child, {bool reduced = false}) => MaterialApp(
  theme: AppTheme.build(brightness: Brightness.light)
      .copyWith(platform: TargetPlatform.windows),
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduced),
    child: Scaffold(
      body: Align(alignment: Alignment.topCenter, child: child),
    ),
  ),
);

/// 可选输出生产组件各动画阶段的实际渲染像素。
Future<void> _capture(
  WidgetTester tester,
  GlobalKey boundary,
  String name,
) async {
  // 默认回归不写文件，显式开启时才生成可检查的 PNG。
  if (Platform.environment['DISCLOSURE_PREVIEW'] != '1') return;
  // 边界直接来自本次屏幕上的生产组件。
  final RenderRepaintBoundary render =
      boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    // 捕获实际绘制结果，避免根据布局参数推断动效。
    final ui.Image image = await render.toImage();
    // PNG 编码写入独立验证目录。
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    // 输出目录不包含用户业务数据。
    final Directory directory = Directory('../../output/disclosure-preview');
    await directory.create(recursive: true);
    await File('${directory.path}/$name.png')
        .writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}
