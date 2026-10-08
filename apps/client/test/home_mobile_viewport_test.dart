import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/features/home/data/home_card_preferences.dart';
import 'package:omni_butler/features/home/presentation/home_mobile_dashboard.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 检查顶部滚动边界、极短视口和动态分页的真实布局。
void main() {
  testWidgets('标准视口在顶部竖拖不会让模块进入固定头部后方', (WidgetTester tester) async {
    await _pumpDashboard(tester);
    // 拖动前模块标题与标签的边界。
    final Rect before = tester.getRect(_key('viewport-title-todos'));
    await tester.drag(_key('viewport-quote'), const Offset(0, -180));
    await tester.pumpAndSettle();
    expect(tester.getRect(_key('viewport-title-todos')), before);
    _expectBodyBelowTabs(tester, HomeCardId.todos);
    expect(tester.takeException(), isNull);
  });

  testWidgets('短屏收起顶部后模块标题始终在吸顶标签下方', (WidgetTester tester) async {
    await _pumpDashboard(tester, size: const Size(360, 420), quoteHeight: 260);
    await tester.dragFrom(const Offset(180, 220), const Offset(0, -420));
    await tester.pumpAndSettle();
    _expectBodyBelowTabs(tester, HomeCardId.todos);
    expect(tester.takeException(), isNull);
  });

  testWidgets('长横幅超过短屏时正文仍有布局空间且可滚到内容', (WidgetTester tester) async {
    await _pumpDashboard(tester, size: const Size(360, 400), quoteHeight: 560);
    expect(tester.takeException(), isNull);
    await tester.dragFrom(const Offset(180, 240), const Offset(0, -700));
    await tester.pumpAndSettle();
    _expectBodyBelowTabs(tester, HomeCardId.todos);
    expect(_key('viewport-title-todos').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('重排删除并新增末页后一次点按可以跨越中间模块', (WidgetTester tester) async {
    // 精确复现真实设置的模块增删顺序。
    final ValueNotifier<List<HomeCardId>> order = await _pumpDashboard(tester);
    await tester.tap(_key('home-mobile-tab-timeStatus'));
    await tester.pumpAndSettle();
    order.value = <HomeCardId>[
      HomeCardId.quote,
      HomeCardId.timeStatus,
      HomeCardId.todos,
      HomeCardId.todayContext,
    ];
    await tester.pumpAndSettle();
    order.value = <HomeCardId>[
      HomeCardId.quote,
      HomeCardId.todos,
      HomeCardId.todayContext,
    ];
    await tester.pumpAndSettle();
    order.value = <HomeCardId>[...order.value, HomeCardId.dayRuler];
    await tester.pumpAndSettle();
    await tester.tap(_key('home-mobile-tab-dayRuler'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<PageView>(_key('home-mobile-pager')).controller!.page,
      closeTo(2, 0.001),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('标准短屏往返保留正文状态和偏移并恢复顶部位置', (WidgetTester tester) async {
    await _pumpDashboard(tester);
    // 首次展开的正文状态必须跨视口模式保持同一实例。
    final State<StatefulWidget> originalState = tester.state(
      _key('viewport-probe-todos'),
    );
    await tester.tap(_key('viewport-toggle-todos'));
    await tester.pumpAndSettle();
    await tester.drag(_key('home-mobile-pager'), const Offset(0, -220));
    await tester.pumpAndSettle();
    // 标准视口下独立正文的真实滚动偏移。
    final double originalOffset = _bodyScroll(tester).pixels;
    // 名言在恢复标准视口后应重新落回初始位置。
    final Rect originalHeader = tester.getRect(_key('viewport-quote'));
    expect(originalOffset, greaterThan(100));

    tester.view.physicalSize = const Size(390, 300);
    await tester.pumpAndSettle();
    expect(_bodyScroll(tester).pixels, closeTo(originalOffset, 0.1));
    expect(tester.state(_key('viewport-probe-todos')), same(originalState));
    expect(find.text('已展开todos'), findsOneWidget);
    await tester.dragFrom(const Offset(180, 150), const Offset(0, -180));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(_key('viewport-quote')).dy,
      lessThan(originalHeader.top),
    );
    // 切换回标准模式前记录真实位置，避免把顶部收起误算为正文滚动。
    final double shortOffset = _bodyScroll(tester).pixels;

    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    expect(tester.getRect(_key('viewport-quote')), originalHeader);
    expect(_bodyScroll(tester).pixels, closeTo(shortOffset, 0.1));
    expect(tester.state(_key('viewport-probe-todos')), same(originalState));
    expect(find.text('已展开todos'), findsOneWidget);
    _expectBodyBelowTabs(tester, HomeCardId.todos);
    expect(tester.takeException(), isNull);
  });
}

/// 返回测试控件的稳定标识。
Finder _key(String value) => find.byKey(ValueKey<String>(value));

/// 读取待办模拟正文的唯一纵向滚动位置。
ScrollPosition _bodyScroll(WidgetTester tester) => tester
    .stateList<ScrollableState>(
      find.descendant(
        of: _key('home-mobile-page-todos'),
        matching: find.byType(Scrollable),
      ),
    )
    .singleWhere(
      (ScrollableState state) => state.position.axis == Axis.vertical,
    )
    .position;

/// 断言固定模块标题没有进入吸顶标签背后。
void _expectBodyBelowTabs(WidgetTester tester, HomeCardId card) {
  expect(
    tester.getTopLeft(_key('viewport-title-${card.name}')).dy,
    greaterThanOrEqualTo(tester.getBottomLeft(_key('home-mobile-tabs')).dy),
  );
}

/// 使用生产面板构建不依赖数据库的布局测试环境。
Future<ValueNotifier<List<HomeCardId>>> _pumpDashboard(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double quoteHeight = 180,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // 可以模拟首页设置动态增删排序的模块顺序。
  final ValueNotifier<List<HomeCardId>> order = ValueNotifier<List<HomeCardId>>(
    <HomeCardId>[
      HomeCardId.quote,
      HomeCardId.todos,
      HomeCardId.timeStatus,
      HomeCardId.todayContext,
    ],
  );
  addTearDown(order.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(brightness: Brightness.light)
          .copyWith(platform: TargetPlatform.android),
      home: Scaffold(
        body: ValueListenableBuilder<List<HomeCardId>>(
          valueListenable: order,
          builder:
              (
                BuildContext context,
                List<HomeCardId> cards,
                Widget? child,
              ) => HomeMobileDashboard(
                visibleCards: cards,
                bottomPadding: 80,
                onManageCards: () {},
                cards: <HomeCardId, Widget>{
                  HomeCardId.quote: SizedBox(
                    key: const ValueKey<String>('viewport-quote'),
                    height: quoteHeight,
                    child: const ColoredBox(color: Colors.blue),
                  ),
                  for (final HomeCardId card in HomeCardId.values)
                    if (card != HomeCardId.quote)
                      card: OmniPanel(
                        flat: true,
                        header: SizedBox(
                          key: ValueKey<String>('viewport-title-${card.name}'),
                          height: 60,
                          child: Text(card.name),
                        ),
                        child: _ViewportProbe(
                          key: ValueKey<String>('viewport-probe-${card.name}'),
                          card: card,
                        ),
                      ),
                },
              ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return order;
}

/// 具有可验证局部状态的长正文，检查滚动模式切换不会重置业务状态。
class _ViewportProbe extends StatefulWidget {
  /// 当前内容所属模块。
  final HomeCardId card;

  /// 创建用于状态回归的正文。
  const _ViewportProbe({required this.card, super.key});

  /// 创建可展开正文状态。
  @override
  State<_ViewportProbe> createState() => _ViewportProbeState();
}

/// 保持展开状态的正文实现。
class _ViewportProbeState extends State<_ViewportProbe> {
  /// 用户是否已经展开正文。
  bool _expanded = false;

  /// 构建带展开操作的长内容。
  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        TextButton(
          key: ValueKey<String>('viewport-toggle-${widget.card.name}'),
          onPressed: () => setState(() => _expanded = !_expanded),
          child: Text('${_expanded ? '已展开' : '展开'}${widget.card.name}'),
        ),
        SizedBox(height: _expanded ? 1900 : 1800),
      ],
    );
  }
}
