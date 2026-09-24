import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/shared/ui/omni_statistics_carousel.dart';

/// 验证统计卡片轮播的分页、指示点与无障碍状态。
void main() {
  testWidgets('横滑卡片后更新活动指示点与页码语义', (WidgetTester tester) async {
    await tester.pumpWidget(
      _CarouselTestApp(
        child: OmniStatisticsCarousel(
          cardHeight: 144,
          children: const <Widget>[
            ColoredBox(color: Colors.red, child: Text('第一张')),
            ColoredBox(color: Colors.green, child: Text('第二张')),
            ColoredBox(color: Colors.blue, child: Text('第三张')),
          ],
        ),
      ),
    );

    expect(_findCarouselSemantics('统计卡片，第 1 张，共 3 张'), findsOneWidget);
    expect(
      tester
          .getSize(
            find.byKey(
              const ValueKey<String>('statistics-carousel-indicator-0'),
            ),
          )
          .width,
      18,
    );
    // 分页点位于统计卡片视口内部，而不是卡片下方。
    final Rect carouselRect = tester.getRect(
      find.byKey(const ValueKey<String>('statistics-carousel-pages')),
    );
    // 第一枚分页点的实际位置。
    final Rect indicatorRect = tester.getRect(
      find.byKey(const ValueKey<String>('statistics-carousel-indicator-0')),
    );
    expect(indicatorRect.top, greaterThan(carouselRect.top));
    expect(indicatorRect.bottom, lessThan(carouselRect.bottom));

    await tester.drag(
      find.byKey(const ValueKey<String>('statistics-carousel-pages')),
      const Offset(-260, 0),
    );
    await tester.pumpAndSettle();

    expect(_findCarouselSemantics('统计卡片，第 2 张，共 3 张'), findsOneWidget);
    expect(
      tester
          .getSize(
            find.byKey(
              const ValueKey<String>('statistics-carousel-indicator-1'),
            ),
          )
          .width,
      18,
    );
    expect(
      tester
          .getSize(
            find.byKey(
              const ValueKey<String>('statistics-carousel-indicator-0'),
            ),
          )
          .width,
      6,
    );
  });

  testWidgets('单张统计卡片不显示分页点', (WidgetTester tester) async {
    await tester.pumpWidget(
      _CarouselTestApp(
        child: OmniStatisticsCarousel(
          cardHeight: 144,
          children: const <Widget>[Text('唯一卡片')],
        ),
      ),
    );

    expect(_findCarouselSemantics('统计卡片，第 1 张，共 1 张'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('statistics-carousel-indicator-0')),
      findsNothing,
    );
  });
}

/// 查找带指定页码文案的统计轮播语义组件。
Finder _findCarouselSemantics(String label) {
  return find.byWidgetPredicate(
    (Widget widget) => widget is Semantics && widget.properties.label == label,
  );
}

/// 为统计轮播提供完整主题的测试应用。
class _CarouselTestApp extends StatelessWidget {
  /// 待验证的统计轮播。
  final Widget child;

  /// 创建统计轮播测试应用。
  const _CarouselTestApp({required this.child});

  /// 构建带 Omni 主题的测试页面。
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: AppTheme.build(brightness: Brightness.light),
      home: Scaffold(
        body: Center(child: SizedBox(width: 390, child: child)),
      ),
    );
  }
}
