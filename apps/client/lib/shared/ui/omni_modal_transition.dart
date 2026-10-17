import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

/// 只移动弹窗表面，遮罩继续由路由独立管理。
class OmniModalSlideTransition extends StatefulWidget {
  /// 导航路由持有的进出进度，不创建第二个动画控制器。
  final Animation<double> animation;

  /// 保留布局和业务状态的弹窗内容。
  final Widget child;

  /// 已布局的紧凑面板使用实际离屏距离，其余使用完整路由高度。
  final double? distance;

  /// 动画调用方可保留已有的显式曲线覆盖。
  final Curve curve;

  /// 显式退出曲线可独立覆盖，默认沿原路径反向播放。
  final Curve reverseCurve;

  /// 创建可在任意进度反向关闭的底部位移。
  const OmniModalSlideTransition({
    required this.animation,
    required this.child,
    this.distance,
    this.curve = OmniMotion.androidModalCurve,
    this.reverseCurve = OmniMotion.androidModalCurve,
    super.key,
  });

  /// 缓存曲线动画，避免重建及中途关闭重置方向。
  @override
  State<OmniModalSlideTransition> createState() =>
      _OmniModalSlideTransitionState();
}

/// 曲线监听与组件生命周期一致，退出后不遗留动画监听。
class _OmniModalSlideTransitionState extends State<OmniModalSlideTransition> {
  /// 与路由共用控制器的曲线进度。
  late CurvedAnimation _progress;

  /// 首次绑定导航进度。
  @override
  void initState() {
    super.initState();
    _bindAnimation();
  }

  /// 绑定当前路由和两端曲线。
  void _bindAnimation() {
    _progress = CurvedAnimation(
      parent: widget.animation,
      curve: widget.curve,
      reverseCurve: widget.reverseCurve,
    );
  }

  /// 只有动画来源或曲线改变时才重新绑定。
  @override
  void didUpdateWidget(OmniModalSlideTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation ||
        oldWidget.curve != widget.curve ||
        oldWidget.reverseCurve != widget.reverseCurve) {
      _progress.dispose();
      _bindAnimation();
    }
  }

  /// 释放方向监听，不接管路由控制器的生命周期。
  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  /// 始终从当前路由进度计算位置，完整保留稳定的内容子树。
  @override
  Widget build(BuildContext context) {
    if (OmniMotion.reduce(context)) return widget.child;
    return AnimatedBuilder(
      animation: _progress,
      child: widget.child,
      builder: (BuildContext context, Widget? child) {
        // 反向时仍取同一进度的位置，避免重新构造曲线导致跳变。
        final double remaining = 1 - _progress.value;
        return widget.distance == null
            ? FractionalTranslation(
                translation: Offset(0, remaining),
                child: child,
              )
            : Transform.translate(
                offset: Offset(0, widget.distance! * remaining),
                child: child,
              );
      },
    );
  }
}
