import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

/// 为已有长按条目提供触点扩散与轻微缩放，保留原点击和菜单行为。
class OmniPressSurface extends StatefulWidget {
  /// 原条目及其独立操作按钮。
  final Widget child;

  /// 是否允许条目交互和按下反馈。
  final bool enabled;

  /// 原条目的轮廓；为空时按矩形裁剪。
  final BorderRadius? borderRadius;

  /// 原整行点击回调，子按钮仍自行处理点击。
  final GestureTapCallback? onTap;

  /// 原鼠标右键回调。
  final GestureTapUpCallback? onSecondaryTapUp;

  /// 原长按业务回调，反馈恢复后仍在原时机触发。
  final GestureLongPressStartCallback? onLongPressStart;

  /// 是否由调用方另行提供语义操作。
  final bool excludeFromSemantics;

  /// 创建保留原手势覆盖范围的按下表面。
  const OmniPressSurface({
    required this.child,
    this.enabled = true,
    this.borderRadius,
    this.onTap,
    this.onSecondaryTapUp,
    this.onLongPressStart,
    this.excludeFromSemantics = false,
    super.key,
  });

  /// 创建可接续和取消的按下动画状态。
  @override
  State<OmniPressSurface> createState() => _OmniPressSurfaceState();
}

/// 使用原长按识别器的按下和取消事件驱动动画，不额外竞争手势。
class _OmniPressSurfaceState extends State<OmniPressSurface>
    with TickerProviderStateMixin {
  /// 灰色扩散和加深的进度。
  late final AnimationController _spread;

  /// 可被新按下接管的缩放强度。
  late final AnimationController _compression;

  /// 释放时淡出的强度，扩散半径保持在释放位置。
  late final AnimationController _visibility;

  /// 合并动画更新，保留业务子树身份。
  late final Listenable _animation;

  /// 未缩放条目中的实际初始触点。
  Offset _origin = Offset.zero;

  /// 当前是否仍处于按下候选阶段。
  bool _pressed = false;

  /// 当前平台是否启用新反馈。
  bool _android = false;

  /// 当前是否要求减少动画。
  bool _reduced = false;

  /// 初始化独立的扩散、缩放和释放控制器。
  @override
  void initState() {
    super.initState();
    _spread = AnimationController(
      vsync: this,
      duration: OmniMotion.pressSpread,
    );
    _compression = AnimationController(vsync: this);
    _visibility = AnimationController(vsync: this);
    _animation = Listenable.merge(<Listenable>[
      _spread,
      _compression,
      _visibility,
    ]);
  }

  /// 平台和减少动画偏好变化时立即同步反馈状态。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 偏好变化前的减少动画状态。
    final bool previouslyReduced = _reduced;
    _android = Theme.of(context).platform == TargetPlatform.android;
    _reduced = OmniMotion.reduce(context);
    if (!_android || !widget.enabled) {
      _clearFeedback();
    } else if (_reduced) {
      _spread.value = _pressed ? 1 : 0;
      _compression.value = 0;
      _visibility.value = _pressed ? 1 : 0;
    } else if (previouslyReduced && _pressed) {
      _compression.animateTo(
        1,
        duration: OmniMotion.fast,
        curve: OmniMotion.standardCurve,
      );
    }
  }

  /// 业务提交期间禁用条目时，清理所有在途反馈。
  @override
  void didUpdateWidget(OmniPressSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _clearFeedback();
  }

  /// 在手指落下时记录触点，即使最后只是短按也立即反馈。
  void _beginPress(LongPressDownDetails details) {
    if (!_android || !widget.enabled) return;
    setState(() {
      _pressed = true;
      _origin = details.localPosition;
    });
    _visibility.value = 1;
    if (_reduced) {
      _spread.value = 1;
      _compression.value = 0;
      return;
    }
    _spread.forward(from: 0);
    _compression.animateTo(
      1,
      duration: OmniMotion.fast,
      curve: OmniMotion.standardCurve,
    );
  }

  /// 松手或滚动取消后淡出当前灰色，避免倒放扩散。
  void _releasePress() {
    if (!_pressed) return;
    _pressed = false;
    _spread.stop();
    if (_reduced || !_android || !widget.enabled) {
      _clearFeedback();
      return;
    }
    _visibility.animateTo(
      0,
      duration: OmniMotion.normal,
      curve: OmniMotion.standardCurve,
    );
    _compression.animateTo(
      0,
      duration: OmniMotion.normal,
      curve: OmniMotion.standardCurve,
    );
  }

  /// 菜单打开前恢复视觉并给一次安卓长按触觉反馈。
  void _startLongPress(LongPressStartDetails details) {
    _releasePress();
    if (_android && widget.enabled && widget.onLongPressStart != null) {
      unawaited(HapticFeedback.vibrate());
    }
    widget.onLongPressStart?.call(details);
  }

  /// 停止动画并立即恢复原视觉状态。
  void _clearFeedback() {
    _pressed = false;
    _spread.value = 0;
    _compression.value = 0;
    _visibility.value = 0;
  }

  /// 释放全部动画资源，不保留延迟回调。
  @override
  void dispose() {
    _spread.dispose();
    _compression.dispose();
    _visibility.dispose();
    super.dispose();
  }

  /// 保持手势宿主的原尺寸，绘制与缩放仅作用于可见条目。
  @override
  Widget build(BuildContext context) {
    // 新按下反馈只覆盖启用中的安卓条目。
    final bool feedback = _android && widget.enabled;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: widget.excludeFromSemantics,
      onTap: widget.enabled ? widget.onTap : null,
      onSecondaryTapUp: widget.enabled ? widget.onSecondaryTapUp : null,
      onLongPressDown: feedback ? _beginPress : null,
      onLongPressCancel: feedback ? _releasePress : null,
      onLongPressEnd: feedback ? (_) => _releasePress() : null,
      onLongPressStart: widget.enabled
          ? feedback
                ? _startLongPress
                : widget.onLongPressStart
          : null,
      child: AnimatedBuilder(
        animation: _animation,
        child: widget.child,
        builder: (BuildContext context, Widget? child) {
          // 颜色强度线性增加，半径另用连续缓动。
          final Color tint = OmniPressColors.tintOf(context, _spread.value);
          return Transform.scale(
            scale: 1 - (1 - OmniMotion.pressScale) * _compression.value,
            transformHitTests: false,
            child: CustomPaint(
              foregroundPainter: _OmniPressPainter(
                origin: _origin,
                progress: OmniMotion.standardCurve.transform(_spread.value),
                color: tint.withValues(alpha: tint.a * _visibility.value),
                borderRadius: widget.borderRadius,
              ),
              child: child,
            ),
          );
        },
      ),
    );
  }
}

/// 在实底内容上绘制薄灰层，不影响输入命中和语义树。
class _OmniPressPainter extends CustomPainter {
  /// 初始触点。
  final Offset origin;

  /// 扩散半径进度。
  final double progress;

  /// 当前加深和淡出后的中性灰。
  final Color color;

  /// 条目的原轮廓。
  final BorderRadius? borderRadius;

  /// 创建固定触点的灰色扩散绘制器。
  const _OmniPressPainter({
    required this.origin,
    required this.progress,
    required this.color,
    required this.borderRadius,
  });

  /// 以最远角为目标半径，保证偏心按下也覆盖整个条目。
  @override
  void paint(Canvas canvas, Size size) {
    if (color.a == 0 || progress == 0 || size.isEmpty) return;
    // 未缩放条目的完整边界。
    final Rect bounds = Offset.zero & size;
    // 实际触点距最远角的距离。
    final double radius = <Offset>[
      bounds.topLeft,
      bounds.topRight,
      bounds.bottomLeft,
      bounds.bottomRight,
    ].map((corner) => (corner - origin).distance).reduce(math.max);
    // 薄灰层只覆盖已扩散区域。
    final Paint paint = Paint()..color = color;
    canvas.save();
    canvas.clipRRect((borderRadius ?? BorderRadius.zero).toRRect(bounds));
    canvas.drawCircle(origin, radius * progress, paint);
    canvas.restore();
  }

  /// 触点、轮廓或动画采样变化时重新绘制。
  @override
  bool shouldRepaint(_OmniPressPainter oldDelegate) =>
      origin != oldDelegate.origin ||
      progress != oldDelegate.progress ||
      color != oldDelegate.color ||
      borderRadius != oldDelegate.borderRadius;
}
