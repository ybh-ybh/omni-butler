import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_theme_palette.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

/// Keep the floating window dark while retaining the selected accent palette.
ThemeData buildFloatingWindowTheme(AppThemePalette palette) =>
    AppTheme.build(brightness: Brightness.dark, palette: palette);

/// Material values shared only by the desktop floating window.
@immutable
class FloatingGlassStyle {
  /// Creates a material from the current application theme.
  const FloatingGlassStyle({required this.colors});

  /// Existing semantic colors preserve palette and business meaning.
  final OmniColors colors;

  /// The continuous outer contour of the floating glass.
  static const double radius = 24;

  /// Neutral smoke avoids tinting the whole window with the brand color.
  static const Color smoke = Color(0xFF181A1D);

  /// Resolves material colors without adding a second theme preference.
  factory FloatingGlassStyle.of(BuildContext context) =>
      FloatingGlassStyle(colors: OmniColors.of(context));

  /// A single translucent body preserves broad desktop contours.
  Color get surface => smoke.withValues(alpha: 0.48);

  /// Secondary text stays close to ink because wallpaper can lower contrast.
  Color get secondaryInk => Color.lerp(colors.ink, colors.muted, 0.18)!;

  /// A subtle seam separates content without cutting the glass into panels.
  Color get separator => colors.ink.withValues(alpha: 0.12);

  /// Inputs have extra material weight for the caret and entered text.
  Color get field => colors.paper.withValues(alpha: 0.62);

  /// A fine outline keeps interactive boundaries visible on a busy desktop.
  Color get controlBorder => Colors.white.withValues(alpha: 0.24);

  /// A faint inset groups expanded forms without another blur layer.
  Color get composer => colors.paper.withValues(alpha: 0.12);

  /// Resolves button feedback while keeping text fully opaque.
  Color controlFill(Set<WidgetState> states, {bool primary = false}) {
    if (states.contains(WidgetState.disabled)) {
      return colors.paper.withValues(alpha: 0.08);
    }
    // Pressing thickens the same material rather than fading the whole control.
    final double opacity = states.contains(WidgetState.pressed)
        ? 0.30
        : states.contains(WidgetState.hovered)
        ? 0.22
        : 0.12;
    // Brand tint is restricted to the primary action surface.
    final Color base = colors.paper.withValues(alpha: opacity);
    return primary
        ? Color.alphaBlend(colors.brand.withValues(alpha: 0.10), base)
        : base;
  }

  /// Gives compact icon buttons the same rim and material as text buttons.
  ButtonStyle iconButtonStyle({bool selected = false}) => ButtonStyle(
    iconColor: WidgetStateProperty.resolveWith<Color>((states) {
      if (states.contains(WidgetState.disabled)) {
        return colors.muted.withValues(alpha: 0.55);
      }
      return selected || states.contains(WidgetState.focused)
          ? colors.brandStrong
          : colors.ink;
    }),
    backgroundColor: WidgetStateProperty.resolveWith<Color>(
      (states) => controlFill(states, primary: selected),
    ),
    side: WidgetStateProperty.resolveWith<BorderSide>(
      (states) => BorderSide(
        color: states.contains(WidgetState.focused)
            ? colors.brand
            : controlBorder,
        width: states.contains(WidgetState.focused) ? 1.5 : 1,
      ),
    ),
  );
}

/// Paints desktop glass without filtering Flutter content behind the controls.
class FloatingGlassSurface extends StatelessWidget {
  /// Creates a window-sized surface with a conservative opaque fallback.
  const FloatingGlassSurface({
    required this.backdropApplied,
    required this.child,
    super.key,
  });

  /// Whether this window successfully requested its native backdrop.
  final bool backdropApplied;

  /// Existing content and hit targets remain outside the decoration logic.
  final Widget child;

  /// Composes a single body, a narrow rim, and the unmodified content.
  @override
  Widget build(BuildContext context) {
    // High contrast uses the same safe surface as unsupported composition.
    final bool glassEnabled =
        backdropApplied && !MediaQuery.highContrastOf(context);
    // Material colors are scoped to this floating window only.
    final FloatingGlassStyle style = FloatingGlassStyle.of(context);
    // Strengthen secondary text locally without changing any brand or state hue.
    final ThemeData inheritedTheme = Theme.of(context);
    // Preserve all other extensions and keep the theme node stable across modes.
    final ThemeData contentTheme = inheritedTheme.copyWith(
      extensions: inheritedTheme.extensions.values.followedBy([
        style.colors.copyWith(muted: style.secondaryInk),
      ]),
      textTheme: inheritedTheme.textTheme.copyWith(
        bodySmall: inheritedTheme.textTheme.bodySmall?.copyWith(
          color: style.secondaryInk,
        ),
      ),
    );
    // One radius is shared by clipping, body, and edge reflections.
    final BorderRadius borderRadius = BorderRadius.circular(
      FloatingGlassStyle.radius,
    );
    return ColoredBox(
      key: const ValueKey<String>('floating-glass-window-background'),
      color: glassEnabled ? Colors.transparent : style.colors.paper,
      child: Padding(
        padding: const EdgeInsets.all(OmniSpacing.xs),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: glassEnabled ? style.surface : style.colors.paper,
            borderRadius: borderRadius,
            boxShadow: glassEnabled
                ? <BoxShadow>[
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.24),
                      blurRadius: 14,
                      spreadRadius: -3,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : const <BoxShadow>[],
          ),
          child: ClipRRect(
            borderRadius: borderRadius,
            child: CustomPaint(
              foregroundPainter: _GlassRimPainter(
                enabled: glassEnabled,
                fallbackBorder: style.colors.line,
              ),
              child: Theme(data: contentTheme, child: child),
            ),
          ),
        ),
      ),
    );
  }
}

/// Uses static edge reflections rather than an animated full-surface sheen.
class _GlassRimPainter extends CustomPainter {
  /// Creates the rim for the current material mode.
  const _GlassRimPainter({required this.enabled, required this.fallbackBorder});

  /// Whether native composition accepted the backdrop request.
  final bool enabled;

  /// The semantic border used by the opaque fallback.
  final Color fallbackBorder;

  /// Draws highlights only along the rounded perimeter.
  @override
  void paint(Canvas canvas, Size size) {
    // Inset strokes stay completely inside the surface clip.
    final Rect bounds = (Offset.zero & size).deflate(0.5);
    // Outer glass outline.
    final RRect outline = RRect.fromRectAndRadius(
      bounds,
      const Radius.circular(FloatingGlassStyle.radius - 0.5),
    );
    // The light source sits above and left of the panel.
    final Paint edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    if (!enabled) {
      edge.color = fallbackBorder;
      canvas.drawRRect(outline, edge);
      return;
    }
    edge.shader = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: <Color>[
        Colors.white.withValues(alpha: 0.52),
        Colors.white.withValues(alpha: 0.16),
        Colors.black.withValues(alpha: 0.16),
        Colors.white.withValues(alpha: 0.30),
      ],
      stops: const <double>[0, 0.28, 0.72, 1],
    ).createShader(bounds);
    canvas.drawRRect(outline, edge);
    // A second very fine inner edge suggests thickness without a broad glow.
    final Paint innerEdge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[
          Colors.white.withValues(alpha: 0.08),
          Colors.white.withValues(alpha: 0),
          Colors.white.withValues(alpha: 0.12),
        ],
      ).createShader(bounds);
    canvas.drawRRect(outline.deflate(1.2), innerEdge);
  }

  /// Repaints only when material or theme changes.
  @override
  bool shouldRepaint(_GlassRimPainter oldDelegate) =>
      oldDelegate.enabled != enabled ||
      oldDelegate.fallbackBorder != fallbackBorder;
}
