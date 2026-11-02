import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

/// Four colored dots expand into rotating rounded arcs, following the reference.
class AssistantLoadingIndicator extends StatefulWidget {
  /// Only an actual in-flight request drives continuous motion.
  final bool animating;

  /// Retain the same centered mark when displaying a connection failure.
  const AssistantLoadingIndicator({required this.animating, super.key});

  /// Own the short repeating motion independently from chat state.
  @override
  State<AssistantLoadingIndicator> createState() =>
      _AssistantLoadingIndicatorState();
}

/// A repaint-only ticker avoids rebuilding the surrounding conversation.
class _AssistantLoadingIndicatorState extends State<AssistantLoadingIndicator>
    with SingleTickerProviderStateMixin {
  /// A two-second cycle alternates a line of dots and an open ring.
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
    value: .35,
  );

  /// Respect reduced motion and the current request lifecycle.
  void _syncMotion() {
    if (widget.animating && !OmniMotion.reduce(context)) {
      if (!_motion.isAnimating) _motion.repeat();
    } else {
      _motion.stop();
      _motion.value = .35;
    }
  }

  /// Recheck the accessibility setting without observing keyboard geometry.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  /// A failed request leaves a static mark rather than implying active work.
  @override
  void didUpdateWidget(covariant AssistantLoadingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncMotion();
  }

  /// Never leave a ticker alive after this page stops displaying connection state.
  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  /// The mark keeps fixed bounds while its dots and arcs move inside them.
  @override
  Widget build(BuildContext context) => Semantics(
    label: widget.animating ? '正在加载' : '连接未完成',
    child: RepaintBoundary(
      child: SizedBox.square(
        dimension: 64,
        child: CustomPaint(painter: _LoadingPainter(_motion)),
      ),
    ),
  );
}

/// Interpolate between four dots on a line and four rotating round-ended arcs.
class _LoadingPainter extends CustomPainter {
  /// Normalized cycle position is also the repaint notification source.
  final Animation<double> phase;

  /// Paint directly on animation ticks without rebuilding widgets.
  _LoadingPainter(this.phase) : super(repaint: phase);

  /// Use the reference's four colors and a smooth expanding circular trajectory.
  @override
  void paint(Canvas canvas, Size size) {
    // Smooth expansion returns to the line once per cycle.
    final double spread = math
        .pow(math.sin(math.pi * phase.value), 2)
        .toDouble();
    // A full rotation reverses the dot order halfway through the cycle.
    final double turn = phase.value * math.pi * 2;
    // Every mark has a stable color while moving around the shared center.
    final List<Color> colors = <Color>[
      Colors.red,
      Colors.orange,
      Colors.blue,
      Colors.pink,
    ];
    // Center remains constant across loading, failure and reduced motion.
    final Offset center = size.center(Offset.zero);
    for (int index = 0; index < colors.length; index++) {
      // Dots begin evenly spaced along a horizontal baseline.
      final Offset line = Offset((index - 1.5) * 14, 0);
      // Different phase offsets create a balanced four-quadrant ring.
      final double angle = turn + index * math.pi / 2;
      // A rounded arc grows out of each initial dot.
      final double sweep = .01 + spread * .65;
      // Expansion follows the reference's compact circular silhouette.
      final Offset ring = Offset(math.cos(angle), math.sin(angle)) * 22;
      // Blend the dot baseline into the circular arrangement without jumps.
      final Offset point = center + Offset.lerp(line, ring, spread)!;
      // Consistent round caps turn very short strokes into circles.
      final Paint paint = Paint()
        ..color = colors[index]
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;
      if (spread < .02) {
        canvas.drawCircle(point, 3, paint..style = PaintingStyle.fill);
      } else {
        // Center each short arc on its interpolated dot position.
        final Offset arcCenter =
            point - Offset(math.cos(angle), math.sin(angle)) * 22;
        canvas.drawArc(
          Rect.fromCircle(center: arcCenter, radius: 22),
          angle - sweep / 2,
          sweep,
          false,
          paint,
        );
      }
    }
  }

  /// Animation ticks request repaint through the constructor's Listenable.
  @override
  bool shouldRepaint(covariant _LoadingPainter oldDelegate) =>
      oldDelegate.phase != phase;
}
