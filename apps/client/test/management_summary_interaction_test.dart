import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/features/management/presentation/management_mobile_scaffold.dart';

/// 验证真实手势中间态、列表几何、遮罩和可取消的弹簧。
void main() {
  // 明暗主题都应使用覆盖卡片四周的同一层半透明遮罩。
  for (final Brightness brightness in Brightness.values) {
    testWidgets('统计展开后四周统一遮罩且边缘点击可收起 ${brightness.name}', (
      WidgetTester tester,
    ) async {
      await _pump(tester, brightness: brightness);
      // 卡片顶部、左侧、右侧和底部留白的真实点击位置。
      for (final Offset point in <Offset>[
        const Offset(195, 2),
        const Offset(2, 100),
        const Offset(388, 100),
        const Offset(195, 600),
      ]) {
        await tester.tap(_key('management-summary-toggle'));
        await tester.pumpAndSettle();
        // 遮罩必须覆盖整个管理内容区，包括圆角外的留白。
        expect(
          tester.getRect(_key('management-summary-scrim')),
          tester.getRect(find.byType(ManagementMobileScaffold)),
        );
        // 直接点击卡片标题仍应命中前景卡片，统计详情保持可滚动。
        expect(_key('management-summary-toggle').hitTestable(), findsOneWidget);
        expect(
          _key('management-summary-details').hitTestable(),
          findsOneWidget,
        );
        await tester.tapAt(point);
        await tester.pumpAndSettle();
        expect(_key('management-summary-scrim'), findsNothing);
        expect(_translation(tester), 0);
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('摘要横滑消费层无空滚动语义且保留收起入口读屏范围', (WidgetTester tester) async {
    // 读取实际交给系统辅助功能的语义节点。
    final SemanticsHandle semantics = tester.ensureSemantics();
    try {
      await _pump(tester);
      await tester.tap(_key('management-summary-toggle'));
      await tester.pumpAndSettle();
      // 展开后的标题和底部手柄均保留独立且准确的读屏热区。
      for (final String key in <String>[
        'management-summary-toggle',
        'management-summary-handle',
      ]) {
        // 当前收起入口对应的实际节点。
        final SemanticsNode control = tester.getSemantics(
          find
              .ancestor(
                of: _key(key),
                matching: find.byWidgetPredicate(
                  (Widget widget) =>
                      widget is Semantics &&
                      widget.properties.label == '收起物品统计',
                ),
              )
              .first,
        );
        // 当前可见交互表面的大小。
        final Size size = tester.getSize(_key(key));
        expect(control.rect.isEmpty, isFalse);
        expect(control.rect.width, lessThanOrEqualTo(size.width), reason: key);
        expect(
          control.rect.height,
          lessThanOrEqualTo(size.height),
          reason: key,
        );
        expect(control.label, contains('收起物品统计'));
        expect(
          control.getSemanticsData().hasAction(SemanticsAction.tap),
          isTrue,
        );
        expect(
          control.getSemanticsData().hasAction(SemanticsAction.scrollLeft),
          isFalse,
        );
        expect(
          control.getSemanticsData().hasAction(SemanticsAction.scrollRight),
          isFalse,
        );
      }
      // 面板消费层不应向读屏暴露无法执行的横向滚动。
      final SemanticsNode boundary = tester.getSemantics(
        _key('management-summary-surface'),
      );
      expect(
        boundary.getSemanticsData().hasAction(SemanticsAction.scrollLeft),
        isFalse,
      );
      expect(
        boundary.getSemanticsData().hasAction(SemanticsAction.scrollRight),
        isFalse,
      );
      // 通过真实辅助功能动作收起，确保排除外层后操作仍然可用。
      final SemanticsNode handle = tester.getSemantics(
        _key('management-summary-handle'),
      );
      tester
          .element(_key('management-summary-handle'))
          .findRenderObject()!
          .owner!
          .semanticsOwner!
          .performAction(handle.id, SemanticsAction.tap);
      await tester.pumpAndSettle();
      expect(_translation(tester), 0);
      expect(_key('management-summary-scrim'), findsNothing);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('摘要遮罩读屏点击收起且没有无用横滚动作', (WidgetTester tester) async {
    // 读取实际交给系统辅助功能的语义节点。
    final SemanticsHandle semantics = tester.ensureSemantics();
    try {
      await _pump(tester);
      await tester.tap(_key('management-summary-toggle'));
      await tester.pumpAndSettle();
      // 遮罩保留明确的读屏收起动作。
      final SemanticsNode scrim = tester.getSemantics(
        _key('management-summary-scrim'),
      );
      expect(scrim.label, '收起物品统计');
      expect(scrim.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      expect(
        scrim.getSemanticsData().hasAction(SemanticsAction.scrollLeft),
        isFalse,
      );
      expect(
        scrim.getSemanticsData().hasAction(SemanticsAction.scrollRight),
        isFalse,
      );
      tester
          .element(_key('management-summary-scrim'))
          .findRenderObject()!
          .owner!
          .semanticsOwner!
          .performAction(scrim.id, SemanticsAction.tap);
      await tester.pumpAndSettle();
      expect(_translation(tester), 0);
      expect(_key('management-summary-scrim'), findsNothing);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('混合加载与失败时优先显示错误并允许重试', (WidgetTester tester) async {
    // 真实重试回调次数。
    int retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light),
        home: Scaffold(
          body: ManagementSummaryLine(
            metrics: const <ManagementSummaryMetric>[],
            loading: true,
            error: '读取失败',
            onRetry: () => retries++,
          ),
        ),
      ),
    );
    expect(find.text('统计读取失败'), findsOneWidget);
    expect(find.text('正在读取统计'), findsNothing);
    await tester.tap(find.text('重试'));
    expect(retries, 1);
  });
  testWidgets('下拉中间帧等距推动正文，遮罩同步且不会触发背景按钮', (WidgetTester tester) async {
    // 背景操作记录，确保不存在点击穿透。
    int taps = 0;
    await _pump(tester, onBodyTap: () => taps++);
    // 初始面板边界。
    final Rect before = tester.getRect(_key('management-summary-surface'));
    // 真实带时间的触摸轨迹。
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(_key('management-summary-toggle')),
    );
    await gesture.moveBy(
      const Offset(0, 24),
      timeStamp: const Duration(milliseconds: 50),
    );
    await tester.pump();
    await gesture.moveBy(
      const Offset(0, 80),
      timeStamp: const Duration(milliseconds: 150),
    );
    await tester.pump();
    // 当前正文真实平移量。
    final Transform translation = tester.widget<Transform>(
      _key('management-body-translation'),
    );
    expect(translation.transform.storage[13], closeTo(80, 1));
    expect(
      tester.getRect(_key('management-summary-surface')).height - before.height,
      closeTo(translation.transform.storage[13], 0.1),
    );
    expect(_key('management-summary-scrim'), findsOneWidget);
    expect(
      tester.getRect(_key('management-summary-scrim')),
      tester.getRect(find.byType(ManagementMobileScaffold)),
    );
    await gesture.up(timeStamp: const Duration(milliseconds: 180));
    await tester.pumpAndSettle();
    if (_key('management-summary-scrim').evaluate().isNotEmpty) {
      await tester.tap(_key('management-summary-scrim'));
    }
    await tester.pumpAndSettle();
    expect(taps, 0);
    expect(_key('management-summary-scrim'), findsNothing);
    expect(_translation(tester), 0);
  });

  testWidgets('列表滚动与统计详情滚动独立，收起后保持列表位置', (WidgetTester tester) async {
    // 真实列表控制器，用于检查视口不被逐帧挤压。
    final ScrollController list = ScrollController();
    addTearDown(list.dispose);
    await _pump(tester, list: list);
    await tester.drag(_key('test-list'), const Offset(0, -240));
    await tester.pumpAndSettle();
    // 展开前记录位置和视口。
    final double offset = list.offset;
    final double viewport = list.position.viewportDimension;
    expect(_translation(tester), 0);
    await tester.tap(_key('management-summary-toggle'));
    await tester.pumpAndSettle();
    expect(list.offset, offset);
    expect(list.position.viewportDimension, viewport);
    await tester.drag(
      _key('management-summary-details'),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    expect(_key('management-summary-scrim'), findsOneWidget);
    expect(list.offset, offset);
    await tester.tap(_key('management-summary-handle'));
    await tester.pumpAndSettle();
    expect(list.offset, offset);
    expect(_translation(tester), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('连续反向拖动立即接管弹簧，取消手势能正常落位', (WidgetTester tester) async {
    await _pump(tester);
    await tester.tap(_key('management-summary-toggle'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    // 接管动画时当前位移。
    final double before = _translation(tester);
    expect(before, greaterThan(0));
    // 反方向真实手势。
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(_key('management-summary-toggle')),
    );
    await gesture.moveBy(const Offset(0, -24));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump();
    expect(_translation(tester), lessThan(before));
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (_key('management-summary-scrim').evaluate().isNotEmpty) {
      await tester.tap(_key('management-summary-scrim'));
    }
    await tester.pumpAndSettle();
    expect(_translation(tester), 0);
  });

  testWidgets('系统返回先收起统计且不离开当前页面', (WidgetTester tester) async {
    await _pump(tester);
    await tester.tap(_key('management-summary-toggle'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_key('management-summary-toggle'), findsOneWidget);
    expect(_key('management-summary-scrim'), findsNothing);
  });

  testWidgets('失活和重新进入保活页时终止旧动画并解除锁定', (WidgetTester tester) async {
    // 模拟真实宿主的可见状态。
    final ValueNotifier<bool> active = ValueNotifier<bool>(true);
    addTearDown(active.dispose);
    // 宿主最后收到的横滑锁。
    bool locked = false;
    await _pump(tester, active: active, onLock: (bool value) => locked = value);
    await tester.tap(_key('management-summary-toggle'));
    await tester.pump(const Duration(milliseconds: 50));
    active.value = false;
    await tester.pumpAndSettle();
    expect(_translation(tester), 0);
    expect(locked, isFalse);
    active.value = true;
    await tester.pumpAndSettle();
    expect(_key('management-summary-scrim'), findsNothing);
    // 手指未离开时切出分区，迟到的离手不能重新展开保活页。
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(_key('management-summary-toggle')),
    );
    await gesture.moveBy(const Offset(0, 25));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 80));
    await tester.pump();
    active.value = false;
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    active.value = true;
    await tester.pumpAndSettle();
    expect(_translation(tester), 0);
    expect(locked, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('短屏双倍字号和减少动画保留入口，主动拖动仍跟手', (WidgetTester tester) async {
    await _pump(tester, size: const Size(320, 320), scale: 2, reduced: true);
    await tester.tap(_key('management-summary-toggle'));
    await tester.pump();
    expect(_translation(tester), greaterThan(0));
    expect(tester.takeException(), isNull);
    await tester.tap(_key('management-summary-toggle'));
    await tester.pump();
    expect(_translation(tester), 0);
    // 关闭动画不影响直接拖动的反馈。
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(_key('management-summary-toggle')),
    );
    await gesture.moveBy(const Offset(0, 24));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 25));
    await tester.pump();
    expect(_translation(tester), greaterThan(0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

/// 公共控件稳定键。
Finder _key(String value) => find.byKey(ValueKey<String>(value));

/// 读取实际正文展示位移。
double _translation(WidgetTester tester) => tester
    .widget<Transform>(_key('management-body-translation'))
    .transform
    .storage[13];

/// 建立不依赖业务仓储的真实可滚动测试表面。
Future<void> _pump(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double scale = 1,
  bool reduced = false,
  Brightness brightness = Brightness.light,
  ScrollController? list,
  VoidCallback? onBodyTap,
  ValueNotifier<bool>? active,
  ValueChanged<bool>? onLock,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // 当前管理页面内容。
  final Widget page = ManagementMobileScaffold(
    title: '物品统计',
    summary: const ManagementSummaryLine(
      metrics: <ManagementSummaryMetric>[
        ManagementSummaryMetric(label: '在用', value: '30'),
        ManagementSummaryMetric(label: '闲置', value: '18'),
        ManagementSummaryMetric(label: '借出', value: '3'),
      ],
    ),
    statistics: Column(
      children: <Widget>[
        for (int index = 0; index < 12; index++)
          SizedBox(height: 60, child: Text('统计 $index')),
      ],
    ),
    floatingActionButton: const Text('新增'),
    body: Column(
      children: <Widget>[
        const SizedBox(height: 60, child: Text('搜索与筛选')),
        Expanded(
          child: ListView.builder(
            key: const ValueKey<String>('test-list'),
            controller: list,
            itemCount: 80,
            itemBuilder: (BuildContext context, int index) => GestureDetector(
              onTap: onBodyTap,
              child: SizedBox(height: 60, child: Text('记录 $index')),
            ),
          ),
        ),
      ],
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(brightness: brightness)
          .copyWith(platform: TargetPlatform.android),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: reduced,
        ),
        child: child!,
      ),
      home: Scaffold(
        body: active == null
            ? page
            : ValueListenableBuilder<bool>(
                valueListenable: active,
                builder: (BuildContext context, bool visible, Widget? child) =>
                    ManagementMobileScope(
                      active: visible,
                      collapseEpoch: 0,
                      onExpansionChanged: onLock ?? (bool _) {},
                      child: child!,
                    ),
                child: page,
              ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
