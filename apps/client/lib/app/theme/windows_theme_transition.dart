import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

/// 在唯一活页面上擦除旧画面，让 Windows 新主题从右上渐变至左下。
class WindowsThemeTransition extends StatefulWidget {
  /// 创建主窗口主题过渡，主题标识只包含实际影响外观的值。
  const WindowsThemeTransition({
    super.key,
    required this.themeKey,
    required this.child,
  });

  /// 当前实际明暗和配色的稳定标识。
  final Object themeKey;

  /// 保持挂载、焦点及路由状态的唯一窗口内容。
  final Widget child;

  /// 创建管理旧画面生命周期的状态。
  @override
  State<WindowsThemeTransition> createState() => _WindowsThemeTransitionState();
}

/// 仅在主题变化时截取已显示帧，动画每帧只重绘前景遮罩。
class _WindowsThemeTransitionState extends State<WindowsThemeTransition>
    with SingleTickerProviderStateMixin {
  /// 单张截图最多约 16MB，限制高 DPI 大窗口的临时纹理占用。
  static const double _maxSnapshotPixels = 4000000;

  /// 复合截图会保留前一张的原生引用，极端快切最多保留四层。
  static const int _maxSnapshotDepth = 4;

  /// 捕获当前复合画面（包括正在播放的旧图遮罩）的边界。
  final GlobalKey _frameKey = GlobalKey();

  /// 从右上向左下推进的时间进度。
  late final AnimationController _controller;

  /// 最近一次主题变化前已显示的复合画面。
  ui.Image? _snapshot;

  /// 截图对应的逻辑尺寸，尺寸变化时立即取消旧画面。
  Size? _snapshotSize;

  /// 当前视图像素密度，用于截图清晰度及跨屏失效判断。
  double _pixelRatio = 1;

  /// 当前是否遵循系统禁用动画偏好。
  bool _reduceMotion = false;

  /// 本轮连续中断形成的截图引用深度。
  int _snapshotDepth = 0;

  /// 清除遮罩后必须等一帧真正绘制，才能重新开始截图计数。
  bool _awaitingCleanFrame = false;

  /// 初始化唯一的主题动画控制器。
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: OmniMotion.themeChange,
    )..addStatusListener(_handleAnimationStatus);
  }

  /// 系统关闭动画或窗口跨越不同 DPI 屏幕时立即使用最新主题。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 当前窗口自己的缩放比例，不使用隐式全局视图。
    final double pixelRatio = MediaQuery.devicePixelRatioOf(context);
    _reduceMotion = OmniMotion.reduce(context);
    if (_reduceMotion || pixelRatio != _pixelRatio) _clearSnapshot();
    _pixelRatio = pixelRatio;
  }

  /// 在新子树构建前捕获上一帧；同外观的偏好变化不重复播放。
  @override
  void didUpdateWidget(covariant WindowsThemeTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.themeKey == widget.themeKey) return;
    if (_reduceMotion ||
        _awaitingCleanFrame ||
        _snapshotDepth >= _maxSnapshotDepth) {
      _clearSnapshot();
      return;
    }
    // 新主题尚未布局绘制，已有图层仍是用户刚看到的画面。
    final RenderObject? renderObject = _frameKey.currentContext
        ?.findRenderObject();
    if (renderObject is! _RenderThemeFrameBoundary ||
        !renderObject.hasSize ||
        renderObject.size.isEmpty) {
      return;
    }
    // 保留本窗口实际像素密度，同时限制总像素数。
    final double captureRatio = math.min(
      _pixelRatio,
      math.sqrt(
        _maxSnapshotPixels /
            (renderObject.size.width * renderObject.size.height),
      ),
    );
    try {
      // 同步取得旧画面句柄，避免异步等待期间截到新主题。
      final ui.Image? nextSnapshot = renderObject.captureLastFrame(
        captureRatio,
      );
      if (nextSnapshot == null) return;
      _retireSnapshot(_snapshot);
      _snapshot = nextSnapshot;
      _snapshotSize = renderObject.size;
      _snapshotDepth += 1;
      _controller.forward(from: 0);
    } catch (error, stackTrace) {
      _clearSnapshot();
      debugPrint('Windows 主题画面捕获失败：$error\n$stackTrace');
    }
  }

  /// 动画结束即移除截图，不让旧内容覆盖后续输入和页面更新。
  void _handleAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted) {
      setState(_clearSnapshot);
    }
  }

  /// 延迟到新画面绘制后释放句柄，避免旧 painter 在本帧访问已释放图像。
  void _retireSnapshot(ui.Image? snapshot) {
    if (snapshot == null) return;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      snapshot.dispose();
    });
  }

  /// 清理旧画面；引用深度只有在无遮罩帧完成后才可重置。
  void _clearSnapshot() {
    _controller.stop();
    if (_snapshot == null) return;
    _retireSnapshot(_snapshot);
    _snapshot = null;
    _snapshotSize = null;
    _awaitingCleanFrame = true;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      _snapshotDepth = 0;
      _awaitingCleanFrame = false;
    });
  }

  /// 栅格化失败可能直到绘制才报告，帧末降级而不在 paint 内更新状态。
  void _handleRasterFailure(ui.Image failedSnapshot) {
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted && identical(_snapshot, failedSnapshot)) {
        setState(_clearSnapshot);
      }
    });
  }

  /// 释放动画与当前截图，已排队的旧句柄仍由各自帧末回调释放。
  @override
  void dispose() {
    _controller.dispose();
    _snapshot?.dispose();
    super.dispose();
  }

  /// 前景绘制不参与命中与语义，内层边界避免每帧重绘整个页面。
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (_snapshot != null && constraints.biggest != _snapshotSize) {
          _clearSnapshot();
        }
        return _ThemeFrameBoundary(
          key: _frameKey,
          child: CustomPaint(
            foregroundPainter: _snapshot == null
                ? null
                : _ThemeSnapshotPainter(
                    image: _snapshot!,
                    progress: _controller,
                    onRasterFailure: _handleRasterFailure,
                  ),
            child: RepaintBoundary(child: widget.child),
          ),
        );
      },
    );
  }
}

/// 暴露已完成绘制的图层快照，允许新主题构建前读取上一帧。
class _ThemeFrameBoundary extends SingleChildRenderObjectWidget {
  /// 创建窗口复合画面的独立重绘边界。
  const _ThemeFrameBoundary({super.key, required super.child});

  /// 创建可捕获上一帧的渲染对象。
  @override
  RenderRepaintBoundary createRenderObject(BuildContext context) =>
      _RenderThemeFrameBoundary();
}

/// 在渲染对象内部访问保留图层，避免依赖受保护的外部访问。
class _RenderThemeFrameBoundary extends RenderRepaintBoundary {
  /// 点击或动画可标脏边界，但新一轮 paint 前的图层仍是已显示画面。
  ui.Image? captureLastFrame(double pixelRatio) {
    // 首帧前没有可读取的已绘制图层。
    final ContainerLayer? paintedLayer = layer;
    if (paintedLayer is! OffsetLayer) return null;
    return paintedLayer.toImageSync(Offset.zero & size, pixelRatio: pixelRatio);
  }
}

/// 用柔和透明带擦除旧图；底下始终是真实、可操作的新主题页面。
class _ThemeSnapshotPainter extends CustomPainter {
  /// 直接监听动画重绘，不每帧构建业务子树。
  _ThemeSnapshotPainter({
    required this.image,
    required this.progress,
    required this.onRasterFailure,
  }) : super(repaint: progress);

  /// 已显示的旧主题或被中断的复合画面。
  final ui.Image image;

  /// 当前过渡时间进度。
  final Animation<double> progress;

  /// 通知状态在安全的帧末移除栅格化失败的截图。
  final ValueChanged<ui.Image> onRasterFailure;

  /// 只对独立旧图层做 alpha 混合，避免擦除下方活页面。
  @override
  void paint(Canvas canvas, Size size) {
    // 从右上到左下覆盖整窗的渐变轴。
    final Offset diagonal = Offset(-size.width, size.height);
    // 渐变轴在右上角的起点。
    final Offset origin = Offset(size.width, 0);
    // 过渡带占整条对角线的比例。
    const double feather = 0.2;
    // 对称缓动让半程的柔和过渡带穿过窗口中心。
    final double edge =
        Curves.easeInOutCubic.transform(progress.value) * (1 + feather);
    // 旧截图在窗口中的绘制范围。
    final Rect bounds = Offset.zero & size;
    canvas.saveLayer(bounds, Paint());
    try {
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        bounds,
        Paint()..filterQuality = FilterQuality.low,
      );
      canvas.drawRect(
        bounds,
        Paint()
          ..blendMode = BlendMode.dstIn
          ..shader = ui.Gradient.linear(
            origin + diagonal * (edge - feather),
            origin + diagonal * edge,
            const <Color>[Colors.transparent, Colors.white],
          ),
      );
    } on ui.PictureRasterizationException {
      onRasterFailure(image);
    } finally {
      canvas.restore();
    }
  }

  /// 新截图到达时更新前景，其余帧由同一个动画监听器推进。
  @override
  bool shouldRepaint(covariant _ThemeSnapshotPainter oldDelegate) =>
      oldDelegate.image != image || oldDelegate.progress != progress;
}
