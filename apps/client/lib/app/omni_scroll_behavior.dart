import 'package:flutter/material.dart';

/// 保留 iOS 式边界回弹，并收紧 Android 上的越界拖动幅度。
class _GentleBouncingScrollPhysics extends BouncingScrollPhysics {
  /// 创建较克制的弹性滚动物理。
  const _GentleBouncingScrollPhysics({super.parent});

  /// 相对 Flutter 默认 iOS 回弹保留的向外拖动位移比例。
  static const double _outwardOffsetScale = 0.65;

  /// 组合父级滚动物理时保留当前的低幅回弹行为。
  @override
  _GentleBouncingScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return _GentleBouncingScrollPhysics(parent: buildParent(ancestor));
  }

  /// 仅压缩继续向外越界的位移，避免影响用户向边界内收回的手感。
  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    if (!position.outOfRange) {
      return super.applyPhysicsToUserOffset(position, offset);
    }

    // 当前手势是否正在把顶部越界内容拉回合法范围。
    final bool easingAtStart =
        position.pixels < position.minScrollExtent && offset < 0;
    // 当前手势是否正在把底部越界内容拉回合法范围。
    final bool easingAtEnd =
        position.pixels > position.maxScrollExtent && offset > 0;
    // Flutter 默认弹性物理计算出的实际滚动位移。
    final double adjustedOffset = super.applyPhysicsToUserOffset(
      position,
      offset,
    );
    if (easingAtStart || easingAtEnd) {
      return adjustedOffset;
    }
    return adjustedOffset * _outwardOffsetScale;
  }
}

/// 为 Android 提供与 iOS 一致的边界弹性回弹。
class OmniScrollBehavior extends MaterialScrollBehavior {
  /// 创建应用级滚动行为。
  const OmniScrollBehavior();

  /// Android 使用的低幅弹性滚动物理。
  static const ScrollPhysics _androidBouncingPhysics =
      _GentleBouncingScrollPhysics(parent: RangeMaintainingScrollPhysics());

  /// Android 使用 iOS 弹性物理，其余平台保留 Flutter 默认行为。
  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    if (getPlatform(context) == TargetPlatform.android) {
      return _androidBouncingPhysics;
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
