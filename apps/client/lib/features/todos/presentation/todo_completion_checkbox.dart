import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

/// 每日待办专用的完成复选框。
class TodoCompletionCheckbox extends StatefulWidget {
  /// 与任务正文形成更协调比例的视觉方框尺寸。
  static const double visualSize = Checkbox.width;

  /// 填充、弹跳与延迟勾线全部播放完毕所需时长。
  static const Duration animationDuration = Duration(milliseconds: 400);

  /// 当前是否完成。
  final bool value;

  /// 完成状态变化回调，为空时禁止交互。
  final ValueChanged<bool>? onChanged;

  /// 无障碍语义标签。
  final String semanticLabel;

  /// 创建每日待办完成复选框。
  const TodoCompletionCheckbox({
    required this.value,
    required this.onChanged,
    this.semanticLabel = '完成任务',
    super.key,
  });

  /// 创建复选框动画状态。
  @override
  State<TodoCompletionCheckbox> createState() => _TodoCompletionCheckboxState();

  /// 按当前平台、主题与视觉密度计算原生复选框的点击区域尺寸。
  static Size tapSizeOf(BuildContext context) {
    // 当前应用主题。
    final ThemeData theme = Theme.of(context);
    // 当前复选框主题。
    final CheckboxThemeData checkboxTheme = CheckboxTheme.of(context);
    // 当前平台对应的点击区域策略。
    final MaterialTapTargetSize tapTargetSize =
        checkboxTheme.materialTapTargetSize ?? theme.materialTapTargetSize;
    // Material 3 默认使用标准密度，应用主题可以显式覆盖。
    final VisualDensity density =
        checkboxTheme.visualDensity ??
        (theme.useMaterial3 ? VisualDensity.standard : theme.visualDensity);
    // 原生 Checkbox 在收缩模式下使用四十像素基准，否则使用四十八像素。
    final double baseSize = tapTargetSize == MaterialTapTargetSize.shrinkWrap
        ? kMinInteractiveDimension - 8
        : kMinInteractiveDimension;
    return Size.square(baseSize) + density.baseSizeAdjustment;
  }

  /// 返回共享复选框的未选中边框色，供树状引导线复用。
  static Color idleBorderColorOf(BuildContext context) {
    return WidgetStateProperty.resolveAs<BorderSide?>(
          CheckboxTheme.of(context).side,
          const <WidgetState>{},
        )?.color ??
        OmniColors.of(context).muted;
  }
}

/// 管理复选框选择、悬停、按压与焦点状态。
class _TodoCompletionCheckboxState extends State<TodoCompletionCheckbox>
    with SingleTickerProviderStateMixin {
  /// 选择状态动画控制器。
  late final AnimationController _selectionController;

  /// 当前是否悬停。
  bool _hovered = false;

  /// 当前是否处于按压反馈。
  bool _pressed = false;

  /// 当前是否拥有键盘焦点。
  bool _focused = false;

  /// 初始化选择状态动画。
  @override
  void initState() {
    super.initState();
    _selectionController = AnimationController(
      vsync: this,
      duration: TodoCompletionCheckbox.animationDuration,
      value: widget.value ? 1 : 0,
    );
  }

  /// 响应外部完成状态变化并播放正向或反向动画。
  @override
  void didUpdateWidget(covariant TodoCompletionCheckbox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value == widget.value) {
      return;
    }
    // 当前是否关闭非必要动画。
    final bool disableAnimations = OmniMotion.reduce(context);
    if (disableAnimations) {
      _selectionController.value = widget.value ? 1 : 0;
      return;
    }
    if (widget.value) {
      _selectionController.forward();
    } else {
      _selectionController.reverse();
    }
  }

  /// 释放选择状态动画控制器。
  @override
  void dispose() {
    _selectionController.dispose();
    super.dispose();
  }

  /// 更新悬停状态。
  void _handleHover(bool value) {
    if (_hovered != value) {
      setState(() => _hovered = value);
    }
  }

  /// 更新按压状态。
  void _handleHighlight(bool value) {
    if (_pressed != value) {
      setState(() => _pressed = value);
    }
  }

  /// 更新键盘焦点状态。
  void _handleFocus(bool value) {
    if (_focused != value) {
      setState(() => _focused = value);
    }
  }

  /// 构建保留原尺寸的复选框和参考样式动效。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前是否允许切换状态。
    final bool enabled = widget.onChanged != null;
    // 当前是否关闭非必要动画。
    final bool disableAnimations = OmniMotion.reduce(context);
    // 与替换前原生 Checkbox 完全相同的点击区域尺寸。
    final Size tapSize = TodoCompletionCheckbox.tapSizeOf(context);
    // 未选中边框使用更清晰的品牌同色阶。
    final Color idleBorder = TodoCompletionCheckbox.idleBorderColorOf(context);
    // 按压轻微收缩；减少动态效果时以颜色提供反馈。
    final double interactionScale = _pressed && !disableAnimations ? 0.96 : 1;

    return Semantics(
      checked: widget.value,
      enabled: enabled,
      label: widget.semanticLabel,
      onTap: enabled ? () => widget.onChanged!(!widget.value) : null,
      child: SizedBox(
        width: tapSize.width,
        height: tapSize.height,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: const ValueKey<String>('todo-completion-interaction'),
            onTap: enabled ? () => widget.onChanged!(!widget.value) : null,
            onHover: _handleHover,
            onHighlightChanged: _handleHighlight,
            onFocusChange: _handleFocus,
            excludeFromSemantics: true,
            mouseCursor: enabled
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            overlayColor: const WidgetStatePropertyAll<Color>(
              Colors.transparent,
            ),
            customBorder: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(OmniRadius.panel)),
            ),
            child: Center(
              child: AnimatedScale(
                scale: interactionScale,
                duration: OmniMotion.duration(context, OmniMotion.fast),
                curve: OmniMotion.standardCurve,
                child: AnimatedBuilder(
                  animation: _selectionController,
                  builder: (BuildContext context, Widget? child) {
                    // 当前选择动画进度。
                    final double progress = _selectionController.value;
                    return Opacity(
                      opacity: enabled ? 1 : 0.45,
                      child: CustomPaint(
                        key: const ValueKey<String>('todo-completion-box'),
                        size: const Size.square(
                          TodoCompletionCheckbox.visualSize,
                        ),
                        painter: _TodoCompletionCheckboxPainter(
                          progress: progress,
                          activeColor: colors.brand,
                          idleBorderColor: _hovered ? colors.brand : idleBorder,
                          surfaceColor: colors.paper,
                          checkColor: colors.accentInk,
                          focusColor: colors.brand.withValues(alpha: 0.16),
                          focused: _focused,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 绘制复选框背景、焦点环与逐段出现的勾线。
class _TodoCompletionCheckboxPainter extends CustomPainter {
  /// 当前选择动画进度。
  final double progress;

  /// 选中填充色。
  final Color activeColor;

  /// 未选中边框色。
  final Color idleBorderColor;

  /// 未选中表面色。
  final Color surfaceColor;

  /// 与共享复选框一致的勾线对比色。
  final Color checkColor;

  /// 键盘焦点环颜色。
  final Color focusColor;

  /// 当前是否拥有键盘焦点。
  final bool focused;

  /// 创建完成复选框绘制器。
  const _TodoCompletionCheckboxPainter({
    required this.progress,
    required this.activeColor,
    required this.idleBorderColor,
    required this.surfaceColor,
    required this.checkColor,
    required this.focusColor,
    required this.focused,
  });

  /// 绘制两百毫秒填充与延迟一百毫秒开始的三百毫秒勾线。
  @override
  void paint(Canvas canvas, Size size) {
    // 填充和图标缩放在动画前两百毫秒完成。
    final double fillProgress = Curves.ease.transform(
      (progress / 0.5).clamp(0, 1),
    );
    // 勾线在一百毫秒后开始，并于四百毫秒时完成。
    final double pathProgress = Curves.ease.transform(
      ((progress - 0.25) / 0.75).clamp(0, 1),
    );
    // 当前视觉方框。
    final RRect box = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(OmniRadius.tiny),
    );
    if (focused) {
      // 四像素焦点环画笔。
      final Paint focusPaint = Paint()..color = focusColor;
      canvas.drawRRect(box.inflate(4), focusPaint);
    }
    // 背景随选择进度从表面色过渡到品牌色。
    final Paint backgroundPaint = Paint()
      ..color = Color.lerp(surfaceColor, activeColor, fillProgress)!;
    canvas.drawRRect(box, backgroundPaint);
    // 边框与背景同步过渡到品牌色。
    final Paint borderPaint = Paint()
      ..color = Color.lerp(idleBorderColor, activeColor, fillProgress)!
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRRect(box.deflate(0.75), borderPaint);
    if (fillProgress == 0 || pathProgress == 0) {
      return;
    }
    // 按参考 SVG 的 24 × 24 坐标构建完整勾线路径。
    final Path checkPath = Path()
      ..moveTo(size.width * (4 / 24), size.height * (12 / 24))
      ..lineTo(size.width * (10 / 24), size.height * (18 / 24))
      ..lineTo(size.width * (20 / 24), size.height * (6 / 24));
    // 用路径度量实现 stroke-dashoffset 等效的逐段绘制。
    final PathMetric metric = checkPath.computeMetrics().first;
    // 当前需要显示的勾线路径片段。
    final Path visiblePath = metric.extractPath(
      0,
      metric.length * pathProgress,
    );
    // 使用主题对比色的勾线画笔。
    final Paint checkPaint = Paint()
      ..color = checkColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // 图标缩放中心。
    final Offset center = size.center(Offset.zero);
    canvas
      ..save()
      ..translate(center.dx, center.dy)
      ..scale(math.max(fillProgress, 0.001))
      ..translate(-center.dx, -center.dy)
      ..drawPath(visiblePath, checkPaint)
      ..restore();
  }

  /// 仅在视觉输入变化时重绘。
  @override
  bool shouldRepaint(covariant _TodoCompletionCheckboxPainter oldDelegate) {
    return progress != oldDelegate.progress ||
        activeColor != oldDelegate.activeColor ||
        idleBorderColor != oldDelegate.idleBorderColor ||
        surfaceColor != oldDelegate.surfaceColor ||
        checkColor != oldDelegate.checkColor ||
        focusColor != oldDelegate.focusColor ||
        focused != oldDelegate.focused;
  }
}
