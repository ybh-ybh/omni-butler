import 'dart:ui' show PathMetric;

import 'package:flutter/gestures.dart' show PointerEnterEvent, PointerExitEvent;
import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/shared/ui/omni_button.dart';
import 'package:omni_butler/shared/ui/omni_icon_button.dart';

/// 顶部浮动消息的语义类型。
enum OmniMessageTone {
  /// 普通信息。
  info,

  /// 成功反馈。
  success,

  /// 需要注意的反馈。
  warning,

  /// 错误反馈。
  error,
}

/// 可主动关闭的浮动消息句柄。
class OmniMessageHandle {
  /// 当前浮层条目。
  OverlayEntry? _entry;

  /// 关闭后的可选回调。
  VoidCallback? _onDismissed;

  /// 创建浮动消息句柄。
  OmniMessageHandle._();

  /// 当前消息是否仍在显示。
  bool get isVisible => _entry?.mounted ?? false;

  /// 关闭当前消息。
  void dismiss() {
    // 当前待移除条目。
    final OverlayEntry? entry = _entry;
    _entry = null;
    if (entry?.mounted ?? false) {
      entry!.remove();
    }
    if (identical(_activeOmniMessage, this)) {
      _activeOmniMessage = null;
    }
    // 当前关闭回调只执行一次。
    final VoidCallback? callback = _onDismissed;
    _onDismissed = null;
    callback?.call();
  }
}

/// 当前窗口正在展示的唯一浮动消息。
OmniMessageHandle? _activeOmniMessage;

/// 在窗口根浮层顶部显示统一操作消息。
OmniMessageHandle showOmniMessage(
  BuildContext context, {
  required String message,
  OmniMessageTone tone = OmniMessageTone.info,
  Duration duration = const Duration(seconds: 4),
  String? actionLabel,
  VoidCallback? onAction,
  VoidCallback? onDismissed,
}) {
  _activeOmniMessage?.dismiss();
  // 当前消息句柄。
  final OmniMessageHandle handle = OmniMessageHandle._();
  // 当前窗口根浮层。
  final OverlayState? overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) {
    return handle;
  }
  handle._onDismissed = onDismissed;
  // 当前浮层条目。
  final OverlayEntry entry = OverlayEntry(
    builder: (BuildContext overlayContext) => Positioned(
      key: const ValueKey<String>('omni-message-positioned'),
      top: OmniSpacing.md,
      left: OmniSpacing.md,
      right: OmniSpacing.md,
      child: SafeArea(
        bottom: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: _OmniMessagePopup(
              message: message,
              tone: tone,
              duration: duration,
              actionLabel: actionLabel,
              onAction: onAction == null
                  ? null
                  : () {
                      handle.dismiss();
                      onAction();
                    },
              onDismiss: handle.dismiss,
            ),
          ),
        ),
      ),
    ),
  );
  handle._entry = entry;
  entry.addListener(() {
    if (!entry.mounted && identical(handle._entry, entry)) {
      handle.dismiss();
    }
  });
  _activeOmniMessage = handle;
  overlay.insert(entry);
  return handle;
}

/// 顶部浮动消息内容。
class _OmniMessagePopup extends StatefulWidget {
  /// 消息正文。
  final String message;

  /// 消息语义类型。
  final OmniMessageTone tone;

  /// 消息显示与边框倒计时的总时长。
  final Duration duration;

  /// 可选操作文案。
  final String? actionLabel;

  /// 可选操作回调。
  final VoidCallback? onAction;

  /// 关闭回调。
  final VoidCallback onDismiss;

  /// 创建浮动消息内容。
  const _OmniMessagePopup({
    required this.message,
    required this.tone,
    required this.duration,
    required this.actionLabel,
    required this.onAction,
    required this.onDismiss,
  });

  /// 创建消息弹窗的倒计时状态。
  @override
  State<_OmniMessagePopup> createState() => _OmniMessagePopupState();
}

/// 顶部浮动消息的倒计时与悬停状态。
class _OmniMessagePopupState extends State<_OmniMessagePopup>
    with SingleTickerProviderStateMixin {
  /// 倒计时边框的绘制宽度。
  static const double _countdownStrokeWidth = 2;

  /// 同时驱动边框进度和自动关闭的动画控制器。
  late final AnimationController _countdownController;

  /// 鼠标当前是否停留在消息内。
  bool _hovered = false;

  /// 键盘焦点当前是否位于消息内。
  bool _focused = false;

  /// 初始化并启动消息倒计时。
  @override
  void initState() {
    super.initState();
    _countdownController = AnimationController(
      duration: widget.duration.isNegative ? Duration.zero : widget.duration,
      animationBehavior: AnimationBehavior.preserve,
      vsync: this,
    )..addStatusListener(_handleCountdownStatus);
    if (widget.duration <= Duration.zero) {
      WidgetsBinding.instance.addPostFrameCallback(_dismissExpiredMessage);
      return;
    }
    _countdownController.forward();
  }

  /// 在倒计时结束后关闭消息。
  void _handleCountdownStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      widget.onDismiss();
    }
  }

  /// 在首帧结束后关闭非正时长的消息。
  void _dismissExpiredMessage(Duration elapsed) {
    if (mounted) {
      widget.onDismiss();
    }
  }

  /// 鼠标进入消息时暂停倒计时。
  void _handlePointerEnter(PointerEnterEvent event) {
    _hovered = true;
    _syncCountdown();
  }

  /// 鼠标离开消息时继续剩余倒计时。
  void _handlePointerExit(PointerExitEvent event) {
    _hovered = false;
    _syncCountdown();
  }

  /// 辅助导航开启时保留带操作的消息，给用户足够时间完成操作。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncCountdown();
  }

  /// 焦点停留在操作或关闭按钮时暂停倒计时。
  void _handleFocusChange(bool focused) {
    _focused = focused;
    _syncCountdown();
  }

  /// 根据悬停、焦点和辅助导航状态管理剩余倒计时。
  void _syncCountdown() {
    if (_countdownController.isCompleted || widget.duration <= Duration.zero) {
      return;
    }
    // 带操作的辅助导航消息必须由用户主动关闭。
    final bool persistentAction =
        (MediaQuery.maybeOf(context)?.accessibleNavigation ?? false) &&
        widget.onAction != null;
    if (_hovered || _focused || persistentAction) {
      _countdownController.stop();
    } else {
      _countdownController.forward();
    }
  }

  /// 释放倒计时动画资源。
  @override
  void dispose() {
    _countdownController.dispose();
    super.dispose();
  }

  /// 构建带语义色、阴影和进入动效的浮动消息。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前消息强调色。
    final Color accent = switch (widget.tone) {
      OmniMessageTone.info => colors.info,
      OmniMessageTone.success => colors.success,
      OmniMessageTone.warning => colors.warning,
      OmniMessageTone.error => colors.danger,
    };
    // 当前消息图标。
    final IconData icon = switch (widget.tone) {
      OmniMessageTone.info => Icons.info_rounded,
      OmniMessageTone.success => Icons.check_circle_rounded,
      OmniMessageTone.warning => Icons.warning_amber_rounded,
      OmniMessageTone.error => Icons.error_rounded,
    };
    // 当前系统是否要求关闭非必要动画。
    final bool disableAnimations = OmniMotion.reduce(context);
    return Focus(
      onFocusChange: _handleFocusChange,
      child: MouseRegion(
        onEnter: _handlePointerEnter,
        onExit: _handlePointerExit,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: 1),
          duration: OmniMotion.duration(context, OmniMotion.fast),
          curve: OmniMotion.standardCurve,
          builder: (BuildContext context, double value, Widget? child) =>
              Opacity(
                opacity: value,
                child: Transform.translate(
                  offset: disableAnimations
                      ? Offset.zero
                      : Offset(0, -8 * (1 - value)),
                  child: child,
                ),
              ),
          child: Semantics(
            liveRegion: true,
            child: Material(
              key: const ValueKey<String>('omni-message-popup'),
              color: colors.paper,
              elevation: 4,
              shadowColor: colors.ink.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(OmniRadius.control),
              clipBehavior: Clip.antiAlias,
              child: AnimatedBuilder(
                animation: _countdownController,
                builder: (BuildContext context, Widget? child) {
                  // 当前边框的剩余进度，关闭动画时保持完整边框。
                  final double remainingProgress = disableAnimations
                      ? 1
                      : 1 - _countdownController.value;
                  return CustomPaint(
                    key: const ValueKey<String>(
                      'omni-message-countdown-border',
                    ),
                    foregroundPainter: _OmniMessageCountdownBorderPainter(
                      remainingProgress: remainingProgress,
                      color: accent,
                      strokeWidth: _countdownStrokeWidth,
                    ),
                    child: child,
                  );
                },
                child: Container(
                  constraints: const BoxConstraints(minHeight: 48),
                  padding: const EdgeInsets.only(left: OmniSpacing.md),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.1),
                    border: Border.all(color: accent.withValues(alpha: 0.3)),
                    borderRadius: BorderRadius.circular(OmniRadius.control),
                  ),
                  child: _buildContent(context, icon, accent),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 让消息操作在紧凑宽度或大字号下换到下一行。
  Widget _buildContent(BuildContext context, IconData icon, Color accent) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 文本放大或窄屏时为操作独立保留一行。
        final bool stacked =
            constraints.maxWidth < 400 ||
            MediaQuery.textScalerOf(context).scale(14) > 20;
        // 当前消息的可选操作。
        final Widget? action =
            widget.actionLabel != null && widget.onAction != null
            ? OmniButton(
                label: widget.actionLabel!,
                variant: OmniButtonVariant.text,
                onPressed: widget.onAction,
              )
            : null;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(icon, color: accent, size: 18),
                const SizedBox(width: OmniSpacing.xs),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: OmniSpacing.xs,
                    ),
                    child: Text(
                      widget.message,
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                if (!stacked && action != null) action,
                OmniIconButton(
                  tooltip: '关闭提示',
                  onPressed: widget.onDismiss,
                  icon: const Icon(Icons.close_rounded, size: 18),
                ),
              ],
            ),
            if (stacked && action != null)
              Align(alignment: Alignment.centerRight, child: action),
          ],
        );
      },
    );
  }
}

/// 绘制从顶部中央开始顺时针消退的消息倒计时边框。
class _OmniMessageCountdownBorderPainter extends CustomPainter {
  /// 当前剩余的边框比例。
  final double remainingProgress;

  /// 倒计时边框颜色。
  final Color color;

  /// 倒计时边框宽度。
  final double strokeWidth;

  /// 创建消息倒计时边框绘制器。
  const _OmniMessageCountdownBorderPainter({
    required this.remainingProgress,
    required this.color,
    required this.strokeWidth,
  });

  /// 绘制圆角矩形路径中的剩余边框。
  @override
  void paint(Canvas canvas, Size size) {
    // 当前可见进度限制在有效范围内。
    final double visibleProgress = remainingProgress.clamp(0.0, 1.0);
    if (visibleProgress <= 0 || size.isEmpty) {
      return;
    }
    // 边框中心线相对组件边缘的内缩距离。
    final double inset = strokeWidth / 2;
    // 边框中心线所在的矩形。
    final Rect borderRect = (Offset.zero & size).deflate(inset);
    // 适配极小尺寸的实际圆角半径。
    final double radius = OmniRadius.control.clamp(
      0.0,
      borderRect.shortestSide / 2,
    );
    // 从顶部中央开始并顺时针闭合的圆角矩形路径。
    final Path borderPath = _buildClockwiseBorderPath(borderRect, radius);
    // 圆角矩形路径只有一个连续度量。
    final PathMetric borderMetric = borderPath.computeMetrics().first;
    // 已经消退的路径长度。
    final double elapsedLength = borderMetric.length * (1 - visibleProgress);
    // 当前仍需显示的路径片段。
    final Path visiblePath = borderMetric.extractPath(
      elapsedLength,
      borderMetric.length,
    );
    // 倒计时强调边框画笔。
    final Paint borderPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(visiblePath, borderPaint);
  }

  /// 创建从顶部中央出发的顺时针圆角矩形路径。
  Path _buildClockwiseBorderPath(Rect rect, double radius) {
    // 路径顶部中央的起点。
    final Offset topCenter = Offset(rect.center.dx, rect.top);
    // 绘制边框使用的圆角尺寸。
    final Radius cornerRadius = Radius.circular(radius);
    // 顺时针连接四条边与四个圆角的完整路径。
    final Path path = Path()
      ..moveTo(topCenter.dx, topCenter.dy)
      ..lineTo(rect.right - radius, rect.top)
      ..arcToPoint(
        Offset(rect.right, rect.top + radius),
        radius: cornerRadius,
        clockwise: true,
      )
      ..lineTo(rect.right, rect.bottom - radius)
      ..arcToPoint(
        Offset(rect.right - radius, rect.bottom),
        radius: cornerRadius,
        clockwise: true,
      )
      ..lineTo(rect.left + radius, rect.bottom)
      ..arcToPoint(
        Offset(rect.left, rect.bottom - radius),
        radius: cornerRadius,
        clockwise: true,
      )
      ..lineTo(rect.left, rect.top + radius)
      ..arcToPoint(
        Offset(rect.left + radius, rect.top),
        radius: cornerRadius,
        clockwise: true,
      )
      ..lineTo(topCenter.dx, topCenter.dy);
    return path;
  }

  /// 仅在进度或绘制样式变化时重绘边框。
  @override
  bool shouldRepaint(covariant _OmniMessageCountdownBorderPainter oldDelegate) {
    return oldDelegate.remainingProgress != remainingProgress ||
        oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}
