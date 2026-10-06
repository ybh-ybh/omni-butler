import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/shared/layout/primary_navigation_swipe.dart';

/// 验证页面吸附与统计卡片原生分页的目标、速度和逐帧位移一致。
void main() {
  test('双向吸附与原生分页的落点和弹簧轨迹一致', () {
    // 相邻页方向归一化后的拖动距离与离手速度。
    const List<({double distance, double velocity})> samples =
        <({double distance, double velocity})>[
          (distance: 20, velocity: 0),
          (distance: 194, velocity: 0),
          (distance: 195, velocity: 0),
          (distance: 220, velocity: 0),
          (distance: 20, velocity: 600),
          (distance: 220, velocity: -600),
          (distance: 20, velocity: 15),
          (distance: 220, velocity: -15),
        ];
    // 同时覆盖低密度与高密度设备的停止容差。
    for (final double devicePixelRatio in <double>[1, 3]) {
      // 正向与反向卡片应使用镜像轨迹。
      for (final int direction in <int>[1, -1]) {
        // 当前待验证的原生分页输入。
        for (final ({double distance, double velocity}) sample in samples) {
          // 统计卡片原生分页计算出的完整物理轨迹。
          final Simulation native = _nativeSimulation(
            distance: sample.distance,
            velocity: sample.velocity,
            devicePixelRatio: devicePixelRatio,
          );
          // 原生弹簧稳定后的目标页位置。
          final double nativeTarget = native.x(10);
          // 自定义卡片以手指方向为正负的当前位移。
          final double offset = -sample.distance * direction;
          // 自定义卡片以手指方向为正负的离手速度。
          final double velocity = -sample.velocity * direction;
          expect(
            OmniPageSwipePhysics.shouldCommit(
              distance: offset,
              velocity: velocity,
              viewportWidth: 390,
              targetDirection: direction,
              devicePixelRatio: devicePixelRatio,
            ),
            nativeTarget == 390,
            reason: '方向 $direction，密度 $devicePixelRatio，输入 $sample',
          );
          // 页面容器实际使用的带边界弹簧。
          final Simulation actual =
              OmniPageSwipePhysics.createSettlingSimulation(
                offset: offset,
                targetOffset: -nativeTarget * direction,
                velocity: velocity,
                viewportWidth: 390,
                targetDirection: direction,
                devicePixelRatio: devicePixelRatio,
              );
          // 覆盖离手瞬间、首帧、过渡中段与最终落位。
          for (final double time in <double>[0, 0.016, 0.1, 0.3, 0.6, 1.2]) {
            expect(
              actual.x(time),
              closeTo(-native.x(time) * direction, 0.000001),
              reason: '方向 $direction，输入 $sample，时间 $time',
            );
            if (!native.isDone(time)) {
              expect(
                actual.dx(time),
                closeTo(-native.dx(time) * direction, 0.000001),
              );
            } else {
              expect(actual.dx(time), 0);
            }
          }
          expect(actual.isDone(10), isTrue);
          expect(actual.x(10), -nativeTarget * direction);
        }
      }
    }
  });

  test('原生速度容差随屏幕密度变化且无效分页不能提交', () {
    expect(
      OmniPageSwipePhysics.shouldCommit(
        distance: -20,
        velocity: -15,
        viewportWidth: 390,
        targetDirection: 1,
      ),
      isFalse,
    );
    expect(
      OmniPageSwipePhysics.shouldCommit(
        distance: -20,
        velocity: -15,
        viewportWidth: 390,
        targetDirection: 1,
        devicePixelRatio: 3,
      ),
      isTrue,
    );
    expect(
      OmniPageSwipePhysics.shouldCommit(
        distance: -220,
        velocity: -600,
        viewportWidth: 0,
        targetDirection: 1,
      ),
      isFalse,
    );
    expect(
      OmniPageSwipePhysics.shouldCommit(
        distance: -220,
        velocity: -600,
        viewportWidth: 390,
        targetDirection: 0,
      ),
      isFalse,
    );
  });

  test('高速吸附触达两页边界即停止且不会越界露白', () {
    // 双向翻页都应限制在当前页与相邻页之间。
    for (final int direction in <int>[1, -1]) {
      // 同时覆盖高速提交到相邻页和高速退回当前页。
      for (final bool commit in <bool>[true, false]) {
        // 向指定边界快速甩动的原生分页轨迹。
        final Simulation native = _nativeSimulation(
          distance: commit ? 380 : 10,
          velocity: commit ? 8000 : -8000,
        );
        // 截止到当前两页范围内的卡片轨迹。
        final Simulation actual = OmniPageSwipePhysics.createSettlingSimulation(
          offset: -(commit ? 380.0 : 10.0) * direction,
          targetOffset: -(commit ? 390.0 : 0.0) * direction,
          velocity: -(commit ? 8000.0 : -8000.0) * direction,
          viewportWidth: 390,
          targetDirection: direction,
          devicePixelRatio: 3,
        );
        expect(native.x(0.016), commit ? greaterThan(390) : lessThan(0));
        expect(actual.x(0.016), -(commit ? 390.0 : 0.0) * direction);
        expect(actual.isDone(0.016), isTrue);
        expect(actual.dx(0.016), 0);
        // 更晚的采样也不应落到可见两页之外。
        for (final double time in <double>[0, 0.016, 0.1, 0.3, 0.6, 1.2]) {
          expect(actual.x(time).abs(), lessThanOrEqualTo(390));
          expect(actual.x(time) * direction, lessThanOrEqualTo(0));
        }
      }
    }
  });

  test('卡片已经到达目标时不会被反向离手速度拉回', () {
    // 左右两个落点都应保持静止，与原生目标等于当前位置时一致。
    for (final int direction in <int>[1, -1]) {
      // 完全到位后反向松手的模拟。
      final Simulation settled = OmniPageSwipePhysics.createSettlingSimulation(
        offset: -390.0 * direction,
        targetOffset: -390.0 * direction,
        velocity: 600.0 * direction,
        viewportWidth: 390,
        targetDirection: direction,
        devicePixelRatio: 3,
      );
      expect(settled.isDone(0), isTrue);
      expect(settled.x(0.016), -390.0 * direction);
      expect(settled.dx(0.016), 0);
    }
  });

  // 拖到整页落点后，两个方向都不应出现退回再吸附。
  for (final int direction in <int>[1, -1]) {
    testWidgets('内部分页完整到位后反向松手立即提交：$direction', (WidgetTester tester) async {
      // 记录即时完成的内部页码变更。
      final List<int> selectedPages = <int>[];
      await _pumpSwipeSurface(tester, onPageChanged: selectedPages.add);
      _startDrag(tester);
      _updateDrag(tester, -390.0 * direction);
      await tester.pump();
      _endDrag(tester, 600.0 * direction);
      await tester.pump();
      expect(selectedPages, <int>[direction]);
      expect(_currentOffset(tester), 0);
      expect(tester.hasRunningAnimations, isFalse);
    });
  }

  // 分别验证向后提交、向前提交及跨过半页后反向回弹。
  for (final ({int direction, double velocity, bool commit}) sample
      in <({int direction, double velocity, bool commit})>[
        (direction: 1, velocity: 600, commit: true),
        (direction: -1, velocity: 600, commit: true),
        (direction: 1, velocity: -600, commit: false),
      ]) {
    testWidgets('内部分页逐帧跟随原生弹簧：$sample', (WidgetTester tester) async {
      // 记录已完成的内部切页，确保不会提前切换业务状态。
      final List<int> selectedPages = <int>[];
      // 记录导航指示块收到的连续分页偏移。
      final List<double?> pageOffsets = <double?>[];
      await _pumpSwipeSurface(
        tester,
        onPageChanged: selectedPages.add,
        onPageOffsetChanged: pageOffsets.add,
      );
      _startDrag(tester);
      _updateDrag(tester, -220.0 * sample.direction);
      await tester.pump();
      _endDrag(tester, -sample.velocity * sample.direction);
      await tester.pump();

      // 与统计卡片相同的原生分页轨迹作为独立对照。
      final Simulation native = _nativeSimulation(
        distance: 220,
        velocity: sample.velocity,
      );
      // 从松手开始累计的动画时间。
      int elapsedMilliseconds = 0;
      // 依次观察 16ms、100ms 和 300ms 三个关键时刻。
      for (final int milliseconds in <int>[16, 84, 200]) {
        elapsedMilliseconds += milliseconds;
        await tester.pump(Duration(milliseconds: milliseconds));
        // 该时刻当前卡片应处于的真实横向位置。
        final double expectedOffset =
            -native.x(elapsedMilliseconds / 1000) * sample.direction;
        expect(_currentOffset(tester), closeTo(expectedOffset, 0.000001));
        expect(pageOffsets.last, closeTo(-expectedOffset / 390, 0.000001));
        expect(selectedPages, isEmpty);
      }
      await tester.pumpAndSettle();
      expect(selectedPages, sample.commit ? <int>[sample.direction] : isEmpty);
      expect(_currentOffset(tester), 0);
      expect(pageOffsets.last, isNull);
    });
  }

  testWidgets('吸附中重新拖动接管当前位置且旧动画不提交', (WidgetTester tester) async {
    // 记录切页回调，检查被打断的动画不会晚到提交。
    final List<int> selectedPages = <int>[];
    await _pumpSwipeSurface(tester, onPageChanged: selectedPages.add);
    _startDrag(tester);
    _updateDrag(tester, -220);
    await tester.pump();
    _endDrag(tester, 0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // 新手势应原地接手的弹簧中间位置。
    final double interruptedOffset = _currentOffset(tester);
    expect(interruptedOffset, lessThan(-220));
    _startDrag(tester);
    await tester.pump();
    expect(_currentOffset(tester), closeTo(interruptedOffset + 390, 0.000001));
    _updateDrag(tester, 40);
    await tester.pump();
    expect(_currentOffset(tester), closeTo(interruptedOffset + 430, 0.000001));
    _endDrag(tester, 600);
    await tester.pumpAndSettle();
    expect(selectedPages, <int>[1, -1]);
    expect(_currentOffset(tester), 0);
  });

  testWidgets('辅助导航开启时内部快滑保持坐标、滑块和页面子树连续', (WidgetTester tester) async {
    // 业务页码变化记录。
    final List<int> selectedPages = <int>[];
    // 导航指示块当前的相对页码偏移。
    final List<double?> pageOffsets = <double?>[];
    await _pumpSwipeSurface(
      tester,
      onPageChanged: selectedPages.add,
      onPageOffsetChanged: pageOffsets.add,
      accessibleNavigation: true,
      pageCount: 6,
    );
    _startDrag(tester);
    _updateDrag(tester, -230);
    _endDrag(tester, -900);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // 即将接手的页面真实坐标及元素身份，不能因角色交换而重建。
    final double enteringOffset = _currentOffset(tester) + 390;
    // 绝对指示器页码应在基准切换前后保持一致。
    final double indicatorBefore = 1 + pageOffsets.last!;
    // 进入页中实际已挂载的内容元素。
    final Element enteringElement = tester.element(find.text('page-2'));
    _startDrag(tester);
    await tester.pump();
    expect(_currentOffset(tester), closeTo(enteringOffset, 0.000001));
    expect(2 + pageOffsets.last!, closeTo(indicatorBefore, 0.000001));
    expect(tester.element(find.text('page-2')), same(enteringElement));
    _updateDrag(tester, -230);
    _endDrag(tester, -900);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // 再次连续接手，既不等待旧弹簧，也不被迟到的旧回调重复推进。
    for (final int index in <int>[3, 4]) {
      _startDrag(tester);
      _updateDrag(tester, -230);
      _endDrag(tester, -900);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('page-${index + 1}'), findsOneWidget);
      expect(tester.hasRunningAnimations, isTrue);
    }
    await tester.pumpAndSettle();
    expect(selectedPages, <int>[1, 1, 1, 1]);
    expect(find.text('page-5'), findsOneWidget);
    expect(pageOffsets.last, isNull);
  });

  testWidgets('同一帧接手并拖到下一页终点使用绝对页码且不重复提交', (WidgetTester tester) async {
    // 记录两次快滑实际提交的业务变化。
    final List<int> selectedPages = <int>[];
    await _pumpSwipeSurface(
      tester,
      onPageChanged: selectedPages.add,
      pageCount: 5,
    );
    _startDrag(tester);
    _updateDrag(tester, -230);
    _endDrag(tester, -900);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // 起手、拖动与松手之间不重建父组件，覆盖最激进的快滑时序。
    _startDrag(tester);
    _updateDrag(tester, -390);
    _endDrag(tester, -900);
    await tester.pumpAndSettle();
    expect(selectedPages, <int>[1, 1]);
    expect(find.text('page-3'), findsOneWidget);
    expect(_currentOffset(tester), 0);
  });

  testWidgets('吸附中外部缩减页数取消旧提交并清除导航残留', (WidgetTester tester) async {
    // 记录过期动画是否仍然提交。
    final List<int> selectedPages = <int>[];
    // 固定顶部导航当前偏移。
    final List<double?> pageOffsets = <double?>[];
    await _pumpSwipeSurface(
      tester,
      initialIndex: 0,
      onPageChanged: selectedPages.add,
      onPageOffsetChanged: pageOffsets.add,
    );
    _startDrag(tester);
    _updateDrag(tester, -230);
    _endDrag(tester, -900);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // 模拟用户切到完成历史或关闭其余功能，仅保留一页。
    await _pumpSwipeSurface(
      tester,
      initialIndex: 0,
      pageCount: 1,
      onPageChanged: selectedPages.add,
      onPageOffsetChanged: pageOffsets.add,
    );
    await tester.pumpAndSettle();
    expect(selectedPages, isEmpty);
    expect(pageOffsets.last, isNull);
    expect(_currentOffset(tester), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('内部拖动恰好回到起点时页面和导航偏移同步归零', (WidgetTester tester) async {
    // 记录业务切页以排除回到起点后误提交。
    final List<int> selectedPages = <int>[];
    // 记录顶部导航指示块收到的位置。
    final List<double?> pageOffsets = <double?>[];
    await _pumpSwipeSurface(
      tester,
      onPageChanged: selectedPages.add,
      onPageOffsetChanged: pageOffsets.add,
    );
    _startDrag(tester);
    _updateDrag(tester, -100);
    await tester.pump();
    _updateDrag(tester, 100);
    await tester.pump();
    expect(_currentOffset(tester), 0);
    expect(pageOffsets.last, 0);
    expect(
      find.byKey(const ValueKey<String>('nested-page-swipe-2-translation')),
      findsNothing,
    );
    _endDrag(tester, 0);
    await tester.pumpAndSettle();
    expect(selectedPages, isEmpty);
    expect(pageOffsets.last, isNull);
  });

  testWidgets('减少动态效果时内部分页立即落位并清理连续偏移', (WidgetTester tester) async {
    // 记录减少动画模式下的即时切页。
    final List<int> selectedPages = <int>[];
    // 记录顶部导航偏移是否在即时切页后清除。
    final List<double?> pageOffsets = <double?>[];
    await _pumpSwipeSurface(
      tester,
      onPageChanged: selectedPages.add,
      onPageOffsetChanged: pageOffsets.add,
      reduceMotion: true,
    );
    _startDrag(tester);
    _updateDrag(tester, -220);
    await tester.pump();
    _endDrag(tester, 0);
    await tester.pump();
    expect(selectedPages, <int>[1]);
    expect(_currentOffset(tester), 0);
    expect(pageOffsets.last, isNull);
    expect(
      find.byKey(const ValueKey<String>('nested-page-swipe-1-translation')),
      findsNothing,
    );
  });
}

/// 创建统计卡片使用的原生分页模拟，坐标始终朝相邻页递增。
Simulation _nativeSimulation({
  required double distance,
  required double velocity,
  double devicePixelRatio = 3,
}) {
  return const PageScrollPhysics().createBallisticSimulation(
    FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: 390,
      pixels: distance,
      viewportDimension: 390,
      axisDirection: AxisDirection.right,
      devicePixelRatio: devicePixelRatio,
    ),
    velocity,
  )!;
}

/// 构建仅包含内部分页和真实主题的轻量测试环境。
Future<void> _pumpSwipeSurface(
  WidgetTester tester, {
  required ValueChanged<int> onPageChanged,
  ValueChanged<double?>? onPageOffsetChanged,
  bool reduceMotion = false,
  bool accessibleNavigation = false,
  int pageCount = 3,
  int initialIndex = 1,
}) async {
  // 业务选中页码与分页回调同步，模拟待办和管理父组件的真实更新。
  int selectedIndex = initialIndex;
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(brightness: Brightness.light),
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(390, 600),
          devicePixelRatio: 3,
          disableAnimations: reduceMotion,
          accessibleNavigation: accessibleNavigation,
        ),
        child: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 390,
              height: 500,
              child: StatefulBuilder(
                builder: (BuildContext context, StateSetter setState) =>
                    NestedPageSwipeSurface(
                      surfaceKey: const ValueKey<String>(
                        'physics-test-swipe-surface',
                      ),
                      onPageChanged: (int index) {
                        // 用绝对页码推导变化量，沿用物理测试的双向回调断言。
                        final int direction = index - selectedIndex;
                        setState(() => selectedIndex = index);
                        onPageChanged(direction);
                      },
                      onPageOffsetChanged: onPageOffsetChanged,
                      pageIndex: selectedIndex,
                      pageCount: pageCount,
                      pageBuilder: (int index) => ColoredBox(
                        color: <Color>[
                          Colors.blue,
                          Colors.red,
                          Colors.green,
                        ][index % 3],
                        child: Text('page-$index'),
                      ),
                    ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// 返回分页表面的真实手势回调，排除测试手势速度估算误差。
GestureDetector _detector(WidgetTester tester) {
  return tester.widget<GestureDetector>(
    find.byKey(const ValueKey<String>('physics-test-swipe-surface')),
  );
}

/// 让新的水平拖动接管当前分页位置。
void _startDrag(WidgetTester tester) {
  _detector(tester)
      .onHorizontalDragStart!(DragStartDetails(globalPosition: Offset.zero));
}

/// 向内部分页传入精确的增量位移。
void _updateDrag(WidgetTester tester, double delta) {
  _detector(tester).onHorizontalDragUpdate!(
    DragUpdateDetails(
      delta: Offset(delta, 0),
      primaryDelta: delta,
      globalPosition: Offset(delta, 0),
    ),
  );
}

/// 用确定的离手速度触发吸附，保证轨迹对比可重复。
void _endDrag(WidgetTester tester, double velocity) {
  _detector(tester).onHorizontalDragEnd!(
    DragEndDetails(
      velocity: Velocity(pixelsPerSecond: Offset(velocity, 0)),
      primaryVelocity: velocity,
    ),
  );
}

/// 读取当前卡片的像素位移，不混入卡片自身的缩放变换。
double _currentOffset(WidgetTester tester) {
  // 父组件当前业务页码。
  final int index = tester
      .widget<NestedPageSwipeSurface>(find.byType(NestedPageSwipeSurface))
      .pageIndex;
  // 当前页面的外层平移变换。
  final Transform translation = tester.widget<Transform>(
    find.byKey(ValueKey<String>('nested-page-swipe-$index-translation')),
  );
  return translation.transform.storage[12];
}
