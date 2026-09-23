import 'package:flutter/material.dart';

/// 为 Android 提供与 iOS 一致的边界弹性回弹。
class OmniScrollBehavior extends MaterialScrollBehavior {
  /// 创建应用级滚动行为。
  const OmniScrollBehavior();

  /// iOS 默认使用的弹性滚动物理。
  static const ScrollPhysics _iosBouncingPhysics = BouncingScrollPhysics(
    parent: RangeMaintainingScrollPhysics(),
  );

  /// Android 使用 iOS 弹性物理，其余平台保留 Flutter 默认行为。
  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    if (getPlatform(context) == TargetPlatform.android) {
      return _iosBouncingPhysics;
    }
    return super.getScrollPhysics(context);
  }

  /// Android 使用回弹本身表达越界，不再叠加拉伸或发光效果。
  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    if (getPlatform(context) == TargetPlatform.android) {
      return child;
    }
    return super.buildOverscrollIndicator(context, child, details);
  }
}
