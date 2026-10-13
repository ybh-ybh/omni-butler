import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

/// 仅缩小桌面图标背景的绘制范围，保留布局占位和点击热区。
class OmniIconButtonShape extends RoundedRectangleBorder {
  /// 统一背景圆角，保留业务边框的兼容入口。
  const OmniIconButtonShape({
    super.side,
    super.borderRadius = const BorderRadius.all(
      Radius.circular(OmniRadius.control),
    ),
  });

  /// 嵌入式小按钮至少保留字形四周留白，避免裁切图标。
  Rect _backgroundRect(Rect rect) {
    // 36dp热区内缩4dp得到28dp背景，小尺寸自动减少内缩。
    final double inset =
        ((rect.shortestSide - OmniSize.icon - OmniSpacing.xxs) / 2)
            .clamp(0.0, OmniSpacing.xxs)
            .toDouble();
    return rect.deflate(inset);
  }

  /// 背景与悬停墨迹使用同一个居中轮廓。
  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      super.getOuterPath(_backgroundRect(rect), textDirection: textDirection);

  /// 边框内部也沿用缩小后的轮廓。
  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      super.getInnerPath(_backgroundRect(rect), textDirection: textDirection);

  /// 直接填充形状的控件也使用同一个缩小背景。
  @override
  void paintInterior(
    Canvas canvas,
    Rect rect,
    Paint paint, {
    TextDirection? textDirection,
  }) => super.paintInterior(
    canvas,
    _backgroundRect(rect),
    paint,
    textDirection: textDirection,
  );

  /// 绘制边框时保持与填充同心。
  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) =>
      super.paint(canvas, _backgroundRect(rect), textDirection: textDirection);

  /// 复制业务边框时仍保留缩小背景的行为。
  @override
  OmniIconButtonShape copyWith({
    BorderSide? side,
    BorderRadiusGeometry? borderRadius,
  }) => OmniIconButtonShape(
    side: side ?? this.side,
    borderRadius: borderRadius ?? this.borderRadius,
  );

  /// 从空轮廓过渡时也保留背景内缩规则。
  @override
  OmniIconButtonShape scale(double t) =>
      OmniIconButtonShape(side: side.scale(t), borderRadius: borderRadius * t);

  /// 主题过渡期间保持背景尺寸，避免暂时放大回整个热区。
  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) {
    if (a is OmniIconButtonShape) {
      return copyWith(
        side: BorderSide.lerp(a.side, side, t),
        borderRadius: BorderRadiusGeometry.lerp(
          a.borderRadius,
          borderRadius,
          t,
        ),
      );
    }
    return super.lerpFrom(a, t);
  }

  /// 两个统一图标轮廓沿相同路径插值。
  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) =>
      b is OmniIconButtonShape ? b.lerpFrom(this, t) : super.lerpTo(b, t);
}
