import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'omni_press_feedback.dart';

/// 当前横向单选分段的 Windows 内容反馈适配，其他平台保留原生组件。
class OmniSegmentedButton<T> extends StatelessWidget {
  /// 原有分段内容、值、提示与启用状态。
  final List<ButtonSegment<T>> segments;

  /// 当前唯一选择。
  final Set<T> selected;

  /// 选择改变时立即调用，重复点击已选段不重复提交。
  final ValueChanged<Set<T>>? onSelectionChanged;

  /// 是否显示原生勾选标记。
  final bool showSelectedIcon;

  /// 调用方对原生分段主题的局部覆盖。
  final ButtonStyle? style;

  /// 创建适用于现有两个横向单选入口的适配器。
  const OmniSegmentedButton({
    super.key,
    required this.segments,
    required this.selected,
    this.onSelectionChanged,
    this.showSelectedIcon = true,
    this.style,
  }) : assert(segments.length > 0),
       assert(selected.length == 1);

  /// 使用原生相同的段样式筛选，保持64×40基线和密度调整。
  ButtonStyle _segmentStyle(ButtonStyle? source) => ButtonStyle(
    textStyle: source?.textStyle,
    backgroundColor: source?.backgroundColor,
    foregroundColor: source?.foregroundColor,
    overlayColor: source?.overlayColor,
    surfaceTintColor: source?.surfaceTintColor,
    elevation: source?.elevation,
    padding: source?.padding,
    iconColor: source?.iconColor,
    iconSize: source?.iconSize,
    shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
    mouseCursor: source?.mouseCursor,
    visualDensity: source?.visualDensity,
    tapTargetSize: source?.tapTargetSize,
    animationDuration: source?.animationDuration,
    enableFeedback: source?.enableFeedback,
    alignment: source?.alignment,
    splashFactory: source?.splashFactory,
  );

  /// 原生 M3 分段默认色只在应用主题没有给值时生效。
  ButtonStyle _defaults(BuildContext context) {
    // 当前主题的原生语义色。
    final ColorScheme colors = Theme.of(context).colorScheme;
    return ButtonStyle(
      textStyle: WidgetStatePropertyAll(Theme.of(context).textTheme.labelLarge),
      backgroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? null
            : states.contains(WidgetState.selected)
            ? colors.secondaryContainer
            : null,
      ),
      foregroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? colors.onSurface.withValues(alpha: 0.38)
            : states.contains(WidgetState.selected)
            ? colors.onSecondaryContainer
            : colors.onSurface,
      ),
      overlayColor: WidgetStateProperty.resolveWith((states) {
        // 选中段使用容器上的原生叠层色。
        final Color tint = states.contains(WidgetState.selected)
            ? colors.onSecondaryContainer
            : colors.onSurface;
        return states.contains(WidgetState.pressed) ||
                states.contains(WidgetState.focused)
            ? tint.withValues(alpha: 0.1)
            : states.contains(WidgetState.hovered)
            ? tint.withValues(alpha: 0.08)
            : null;
      }),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      elevation: const WidgetStatePropertyAll(0),
      iconSize: const WidgetStatePropertyAll(18),
      side: WidgetStateProperty.resolveWith(
        (states) => BorderSide(
          color: states.contains(WidgetState.disabled)
              ? colors.onSurface.withValues(alpha: 0.12)
              : colors.outline,
        ),
      ),
      shape: const WidgetStatePropertyAll(StadiumBorder()),
    );
  }

  /// 原有背景、等宽布局和外框固定，每段仅变换前景。
  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).platform != TargetPlatform.windows) {
      return SegmentedButton<T>(
        segments: segments,
        selected: selected,
        onSelectionChanged: onSelectionChanged,
        showSelectedIcon: showSelectedIcon,
        style: style,
      );
    }
    // 原生主题与调用样式保持相同优先级。
    final ButtonStyle defaults = _defaults(context);
    // 应用分段主题，不能误用普通文字按钮主题。
    final ButtonStyle themed =
        SegmentedButtonTheme.of(context).style?.merge(defaults) ?? defaults;
    // 容器外框使用未筛选样式。
    final ButtonStyle effective = style?.merge(themed) ?? themed;
    // 子段样式有意不继承整体最小宽高与外圆角。
    final ButtonStyle segmentStyle = _segmentStyle(style);
    // 原生 SegmentedButton 同样通过局部主题提供段默认值。
    final ButtonStyle segmentTheme = _segmentStyle(themed);
    // 当前整体是否可操作。
    final bool enabled = onSelectionChanged != null;
    // 外框与禁止状态使用原生解析集合。
    final Set<WidgetState> containerStates = <WidgetState>{
      if (!enabled) WidgetState.disabled,
    };
    // 容器普通轮廓与边线。
    final OutlinedBorder border =
        (effective.shape?.resolve(containerStates) ?? const StadiumBorder())
            .copyWith(side: effective.side?.resolve(containerStates));
    // 局部禁用段保留原生的禁用外框。
    final OutlinedBorder disabledBorder =
        (effective.shape?.resolve(const <WidgetState>{WidgetState.disabled}) ??
                const StadiumBorder())
            .copyWith(
              side: effective.side?.resolve(const <WidgetState>{
                WidgetState.disabled,
              }),
            );
    // 密度影响原生40像素基线和触控区域外围留白。
    final VisualDensity density =
        effective.visualDensity ?? Theme.of(context).visualDensity;
    // 当前原生段内边距。
    final EdgeInsetsGeometry padding =
        effective.padding?.resolve(containerStates) ?? EdgeInsets.zero;
    // 原生用于估算触控外围留白的文字尺寸。
    final double fontSize =
        effective.textStyle?.resolve(containerStates)?.fontSize ?? 20;
    // 固定背景绘制区域不包含原生额外触控留白。
    final double verticalInset =
        (effective.tapTargetSize ?? Theme.of(context).materialTapTargetSize) ==
            MaterialTapTargetSize.shrinkWrap
        ? 0
        : math.max(
            0,
            48 +
                density.baseSizeAdjustment.dy -
                math.max(
                  fontSize +
                      padding.vertical +
                      density.baseSizeAdjustment.dy * 2,
                  40 + density.baseSizeAdjustment.dy,
                ),
          );
    // 横向排布与分隔线遵循界面文字方向。
    final TextDirection direction = Directionality.of(context);
    return Material(
      type: MaterialType.transparency,
      elevation: effective.elevation?.resolve(containerStates) ?? 0,
      shadowColor: effective.shadowColor?.resolve(containerStates),
      surfaceTintColor: effective.surfaceTintColor?.resolve(containerStates),
      child: CustomPaint(
        foregroundPainter: _OmniSegmentBorderPainter(
          border: border,
          disabledBorder: disabledBorder,
          enabled: segments
              .map((segment) => enabled && segment.enabled)
              .toList(),
          direction: direction,
          verticalInset: verticalInset,
        ),
        child: _OmniSegmentPaintClip(
          clipper: _OmniSegmentClipper(
            border: border,
            direction: direction,
            verticalInset: verticalInset,
          ),
          child: TextButtonTheme(
            data: TextButtonThemeData(style: segmentTheme),
            child: IntrinsicWidth(
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (final ButtonSegment<T> segment in segments)
                      Expanded(
                        child: _OmniSegment<T>(
                          segment: segment,
                          selected: selected.contains(segment.value),
                          enabled: enabled && segment.enabled,
                          showSelectedIcon: showSelectedIcon,
                          style: segmentStyle,
                          onSelectionChanged: onSelectionChanged,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 一个分段继续使用原生 TextButton 的键盘和语义激活。
class _OmniSegment<T> extends StatelessWidget {
  /// 当前分段的业务值与内容。
  final ButtonSegment<T> segment;

  /// 当前分段是否被选择。
  final bool selected;

  /// 当前分段是否允许激活。
  final bool enabled;

  /// 是否显示选中勾选标记。
  final bool showSelectedIcon;

  /// 不含整体圆角的原生段样式。
  final ButtonStyle style;

  /// 父级唯一业务选择回调。
  final ValueChanged<Set<T>>? onSelectionChanged;

  /// 创建独立反馈但保持连续外框的段。
  const _OmniSegment({
    required this.segment,
    required this.selected,
    required this.enabled,
    required this.showSelectedIcon,
    required this.style,
    required this.onSelectionChanged,
  });

  /// 保留选择标记与文字图标的原生布局。
  @override
  Widget build(BuildContext context) => OmniPressBinding(
    enabled: enabled,
    builder: (context, feedback) {
      feedback.statesController.update(WidgetState.selected, selected);
      // 原生段优先显示标签，否则显示图标。
      final Widget label =
          segment.label ?? segment.icon ?? const SizedBox.shrink();
      // 勾选标记遵循原生主题默认值。
      final Widget? icon = selected && showSelectedIcon
          ? SegmentedButtonTheme.of(context).selectedIcon ??
                const Icon(Icons.check)
          : segment.label != null
          ? segment.icon
          : null;
      // 原生图文段的间距随文字缩放收敛。
      final double fontSize =
          style.textStyle?.resolve(const <WidgetState>{})?.fontSize ?? 14;
      // 原生图文段按14像素基线计算缩放，而非布局宽度。
      final double textScale =
          MediaQuery.textScalerOf(context).scale(fontSize) / 14;
      // 有图标时保持SDK原有的特殊段内边距。
      final ButtonStyle contentStyle = icon == null
          ? style
          : style.copyWith(
              padding: WidgetStatePropertyAll(
                ButtonStyleButton.scaledPadding(
                  const EdgeInsetsDirectional.fromSTEB(12, 8, 16, 8),
                  const EdgeInsets.symmetric(horizontal: 4),
                  const EdgeInsets.symmetric(horizontal: 4),
                  textScale,
                ),
              ),
            );
      // 每段文字或图文作为一个整体参与缩放。
      final Widget content = icon == null
          ? label
          : Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 8 - 4 * (textScale.clamp(1, 2) - 1),
              children: <Widget>[
                icon,
                Flexible(child: label),
              ],
            );
      // 按已选项不重新提交，仍提供完整点击反馈。
      final Widget button = TextButton(
        clipBehavior: Clip.none,
        statesController: feedback.statesController,
        style: contentStyle.copyWith(
          foregroundBuilder: feedback.foregroundBuilder,
        ),
        onPressed: enabled
            ? () {
                feedback.activate();
                if (!selected) onSelectionChanged?.call(<T>{segment.value});
              }
            : null,
        child: content,
      );
      return MergeSemantics(
        child: Semantics(
          selected: selected,
          inMutuallyExclusiveGroup: true,
          child: segment.tooltip == null
              ? button
              : Tooltip(message: segment.tooltip!, child: button),
        ),
      );
    },
  );
}

/// 按原生外框内沿裁剪背景，内容缩放不改变裁剪区域。
class _OmniSegmentClipper extends CustomClipper<Path> {
  /// 原生整体外框。
  final OutlinedBorder border;

  /// 文字方向决定方向圆角的解析。
  final TextDirection direction;

  /// 原生触控热区额外高度。
  final double verticalInset;

  /// 创建固定的分段内沿裁剪器。
  const _OmniSegmentClipper({
    required this.border,
    required this.direction,
    required this.verticalInset,
  });

  /// 从整体尺寸计算视觉背景区域。
  @override
  Path getClip(Size size) => border.getInnerPath(
    Rect.fromLTWH(
      0,
      verticalInset / 2,
      size.width,
      math.max(0, size.height - verticalInset),
    ),
    textDirection: direction,
  );

  /// 只有形状、方向或热区留白改变时更新裁剪。
  @override
  bool shouldReclip(_OmniSegmentClipper oldClipper) =>
      border != oldClipper.border ||
      direction != oldClipper.direction ||
      verticalInset != oldClipper.verticalInset;
}

/// 原生分段只裁剪绘制，热区仍是完整矩形，因此不使用会裁剪命中的 ClipPath。
class _OmniSegmentPaintClip extends SingleChildRenderObjectWidget {
  /// 固定外框内沿的裁剪路径。
  final CustomClipper<Path> clipper;

  /// 创建保留完整命中区的绘制裁剪。
  const _OmniSegmentPaintClip({required this.clipper, required super.child});

  /// 创建只影响绘制的代理渲染对象。
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _OmniSegmentPaintClipBox(clipper);

  /// 外框变化时只更新绘制裁剪。
  @override
  void updateRenderObject(
    BuildContext context,
    _OmniSegmentPaintClipBox renderObject,
  ) => renderObject.clipper = clipper;
}

/// 继承默认矩形命中规则，避免圆角外沿点击被裁掉。
class _OmniSegmentPaintClipBox extends RenderProxyBox {
  /// 当前固定外框裁剪器。
  CustomClipper<Path> _clipper;

  /// 初始化绘制代理。
  _OmniSegmentPaintClipBox(this._clipper);

  /// 更新主题或尺寸相关的外框配置。
  set clipper(CustomClipper<Path> value) {
    _clipper = value;
    markNeedsPaint();
  }

  /// 保留原始布局和命中，只给背景绘制添加内沿裁剪。
  @override
  void paint(PaintingContext context, Offset offset) => context.pushClipPath(
    needsCompositing,
    offset,
    Offset.zero & size,
    _clipper.getClip(size),
    super.paint,
    clipBehavior: Clip.antiAlias,
  );
}

/// 绘制固定外框和等宽分隔线，不参与各段内容缩放。
class _OmniSegmentBorderPainter extends CustomPainter {
  /// 可操作段使用的外框。
  final OutlinedBorder border;

  /// 禁用段使用的外框。
  final OutlinedBorder disabledBorder;

  /// 各逻辑段是否启用。
  final List<bool> enabled;

  /// 界面文字方向。
  final TextDirection direction;

  /// 原生额外触控留白。
  final double verticalInset;

  /// 创建与段背景独立的外框绘制器。
  const _OmniSegmentBorderPainter({
    required this.border,
    required this.disabledBorder,
    required this.enabled,
    required this.direction,
    required this.verticalInset,
  });

  /// 分别裁剪各段边线，连续圆角保持同一整体轮廓。
  @override
  void paint(Canvas canvas, Size size) {
    // 不包含触控外围留白的实际边框区域。
    final Rect bounds = Rect.fromLTWH(
      0,
      verticalInset / 2,
      size.width,
      math.max(0, size.height - verticalInset),
    );
    // 等宽段的真实布局宽度。
    final double width = size.width / enabled.length;
    for (int index = 0; index < enabled.length; index++) {
      // 逻辑顺序映射到实际绘制顺序。
      final int visual = direction == TextDirection.ltr
          ? index
          : enabled.length - index - 1;
      // 当前段按其可操作性使用对应边框。
      final OutlinedBorder current = enabled[index] ? border : disabledBorder;
      canvas.save();
      canvas.clipRect(
        Rect.fromLTRB(
          visual == 0 ? -1 : visual * width,
          -1,
          visual == enabled.length - 1 ? size.width + 1 : (visual + 1) * width,
          size.height + 1,
        ),
      );
      current.paint(canvas, bounds, textDirection: direction);
      canvas.restore();
      if (index > 0) {
        // 相邻两段都禁用时才使用禁用分隔线。
        final BorderSide divider =
            (enabled[index] || enabled[index - 1]
                    ? border.side
                    : disabledBorder.side)
                .copyWith(strokeAlign: 0);
        // 分隔线位于逻辑前一段与当前段之间。
        final double x = direction == TextDirection.ltr
            ? index * width
            : size.width - index * width;
        canvas.drawLine(
          Offset(x, bounds.top),
          Offset(x, bounds.bottom),
          divider.toPaint(),
        );
      }
    }
  }

  /// 控件状态改变时更新外框，按压动画本身不触发背景重绘。
  @override
  bool shouldRepaint(_OmniSegmentBorderPainter oldDelegate) =>
      border != oldDelegate.border ||
      disabledBorder != oldDelegate.disabledBorder ||
      direction != oldDelegate.direction ||
      verticalInset != oldDelegate.verticalInset ||
      enabled.toString() != oldDelegate.enabled.toString();
}
