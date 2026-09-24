import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

/// 统计卡片使用的全宽分页轮播。
class OmniStatisticsCarousel extends StatefulWidget {
  /// 按展示顺序排列的统计卡片。
  final List<Widget> children;

  /// 单张统计卡片的固定高度。
  final double cardHeight;

  /// 创建统计卡片分页轮播。
  const OmniStatisticsCarousel({
    required this.children,
    required this.cardHeight,
    super.key,
  }) : assert(cardHeight > 0);

  /// 创建统计轮播状态。
  @override
  State<OmniStatisticsCarousel> createState() => _OmniStatisticsCarouselState();
}

/// 统计卡片分页轮播状态。
class _OmniStatisticsCarouselState extends State<OmniStatisticsCarousel> {
  /// 统计卡片分页控制器。
  late final PageController _pageController;

  /// 当前展示的统计卡片索引。
  int _currentIndex = 0;

  /// 初始化分页控制器。
  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  /// 释放分页控制器。
  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// 更新当前统计卡片索引。
  void _selectPage(int index) {
    if (_currentIndex == index) {
      return;
    }
    setState(() => _currentIndex = index);
  }

  /// 构建统计卡片视口与卡片内部的底部分页指示点。
  @override
  Widget build(BuildContext context) {
    if (widget.children.isEmpty) {
      return const SizedBox.shrink();
    }
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前系统是否要求关闭动画。
    final bool disableAnimations = MediaQuery.disableAnimationsOf(context);
    // 当前卡片总数。
    final int pageCount = widget.children.length;
    // 固定高度的统计卡片分页视口。
    final Widget pageView = SizedBox(
      height: widget.cardHeight,
      child: PageView.builder(
        key: const ValueKey<String>('statistics-carousel-pages'),
        controller: _pageController,
        itemCount: pageCount,
        pageSnapping: true,
        physics: const PageScrollPhysics(),
        onPageChanged: _selectPage,
        itemBuilder: (BuildContext context, int index) =>
            widget.children[index],
      ),
    );
    if (pageCount == 1) {
      return Semantics(
        container: true,
        label: '统计卡片，第 1 张，共 1 张',
        child: pageView,
      );
    }

    return Semantics(
      container: true,
      liveRegion: true,
      label: '统计卡片，第 ${_currentIndex + 1} 张，共 $pageCount 张',
      child: Stack(
        children: <Widget>[
          pageView,
          Positioned(
            left: 0,
            right: 0,
            bottom: OmniSpacing.xxs,
            child: ExcludeSemantics(
              child: SizedBox(
                height: 6,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: OmniSpacing.xxs,
                    ),
                    decoration: BoxDecoration(
                      color: colors.paper,
                      borderRadius: BorderRadius.circular(OmniRadius.pill),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        for (
                          int index = 0;
                          index < pageCount;
                          index += 1
                        ) ...<Widget>[
                          if (index > 0) const SizedBox(width: OmniSpacing.xxs),
                          AnimatedContainer(
                            key: ValueKey<String>(
                              'statistics-carousel-indicator-$index',
                            ),
                            duration: disableAnimations
                                ? Duration.zero
                                : OmniMotion.normal,
                            curve: OmniMotion.standardCurve,
                            width: index == _currentIndex ? 18 : 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: index == _currentIndex
                                  ? colors.brand
                                  : colors.line,
                              borderRadius: BorderRadius.circular(
                                OmniRadius.pill,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
