import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:go_router/go_router.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

/// Suspends sidebar gestures while an in-place navigation surface is visible.
class AndroidSidebarSwipeScope extends InheritedWidget {
  /// Only the unobscured workspace may start or finish a sidebar gesture.
  final bool enabled;

  /// Keeps the workspace mounted while its gesture availability changes.
  const AndroidSidebarSwipeScope({
    required this.enabled,
    required super.child,
    super.key,
  });

  /// Standalone pages allow gestures unless an ancestor explicitly blocks them.
  static bool enabledOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<AndroidSidebarSwipeScope>()
          ?.enabled ??
      true;

  /// Cancels active gestures when a navigation panel obscures the workspace.
  @override
  bool updateShouldNotify(AndroidSidebarSwipeScope oldWidget) =>
      enabled != oldWidget.enabled;
}

/// Opens an existing sidebar after a deliberate right swipe in its workspace.
class AndroidSidebarSwipeTarget extends StatefulWidget {
  /// The production drawer width determines the distance threshold.
  final double sidebarWidth;

  /// Reuses the page's existing sidebar and its lifecycle guards.
  final VoidCallback onOpen;

  /// Local overlays can suspend gestures without replacing the content subtree.
  final bool enabled;

  /// Overlay content can exclude a sibling composer using its actual bounds.
  final bool Function(Offset globalPosition)? canStartAt;

  /// Horizontal controls and selection inside this subtree keep gesture priority.
  final Widget child;

  /// Adds a compact Android gesture without changing desktop or tablet behavior.
  const AndroidSidebarSwipeTarget({
    required this.sidebarWidth,
    required this.onOpen,
    required this.child,
    this.enabled = true,
    this.canStartAt,
    super.key,
  });

  /// Owns one drag at a time and invalidates it when its route changes.
  @override
  State<AndroidSidebarSwipeTarget> createState() =>
      _AndroidSidebarSwipeTargetState();
}

/// Leaves taps, vertical scrolling and child horizontal gestures untouched.
class _AndroidSidebarSwipeTargetState extends State<AndroidSidebarSwipeTarget> {
  /// Accumulates signed motion after the horizontal gesture wins its arena.
  double _distance = 0;

  /// A reversed final movement must not open the sidebar on release.
  double _lastDelta = 0;

  /// Identifies the route visible when the user started dragging.
  String? _sourcePath;

  /// A cancelled or obscured drag cannot be revived by a late pointer-up.
  bool _active = false;

  /// Dependency updates invalidate gestures before a newly shown overlay reacts.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_enabled) _cancel();
  }

  /// A local guard or geometry change invalidates the old drag threshold.
  @override
  void didUpdateWidget(AndroidSidebarSwipeTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled || widget.sidebarWidth != oldWidget.sidebarWidth) {
      _cancel();
    }
  }

  /// Only the compact Android workspace participates in this gesture.
  bool get _enabled =>
      widget.enabled &&
      Theme.of(context).platform == TargetPlatform.android &&
      OmniBreakpoint.isCompact(MediaQuery.sizeOf(context).width) &&
      AndroidSidebarSwipeScope.enabledOf(context);

  /// Captures the actual route, including imperative secondary-page pushes.
  String? get _currentPath => GoRouter.maybeOf(context)?.state.uri.path;

  /// Starts tracking only after horizontal motion beats taps and vertical scroll.
  void _start(DragStartDetails details) {
    _active = _enabled;
    _distance = 0;
    _lastDelta = 0;
    _sourcePath = _currentPath;
  }

  /// Keeps direction and net travel separate so a reversal cannot open a drawer.
  void _update(DragUpdateDetails details) {
    if (!_active) return;
    _lastDelta = details.primaryDelta ?? 0;
    _distance += _lastDelta;
  }

  /// Short, reversed, cancelled and stale drags never call the page action.
  void _end(DragEndDetails details) {
    // Commit only a still-owned gesture with positive travel and direction.
    final bool owned =
        _active &&
        _enabled &&
        _sourcePath == _currentPath &&
        _distance > 0 &&
        _lastDelta > 0;
    // Fast gestures use the same velocity scale as the existing close gesture.
    final double velocity = details.primaryVelocity ?? 0;
    // The existing close threshold leaves 72% visible; opening mirrors its travel.
    final bool shouldOpen =
        owned &&
        velocity >= 0 &&
        (_distance >= widget.sidebarWidth * .28 || velocity > 500);
    _cancel();
    if (shouldOpen) widget.onOpen();
  }

  /// Clears ownership without changing the page or its sidebar.
  void _cancel() {
    _active = false;
    _distance = 0;
    _lastDelta = 0;
    _sourcePath = null;
  }

  /// The parent recognizer yields to interactive horizontal descendants.
  @override
  Widget build(BuildContext context) {
    // Keep the gesture host stable even when a panel temporarily disables it.
    final bool enabled = _enabled;
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      excludeFromSemantics: true,
      gestures: <Type, GestureRecognizerFactory>{
        if (enabled)
          _SidebarHorizontalDragRecognizer:
              GestureRecognizerFactoryWithHandlers<
                _SidebarHorizontalDragRecognizer
              >(() => _SidebarHorizontalDragRecognizer(debugOwner: this), (
                _SidebarHorizontalDragRecognizer recognizer,
              ) {
                recognizer
                  ..canStartAt = widget.canStartAt
                  ..onPointerCancelled = _cancel
                  ..onStart = _start
                  ..onUpdate = _update
                  ..onEnd = _end
                  ..onCancel = _cancel;
              }),
      },
      child: widget.child,
    );
  }
}

/// Invalidates cancelled pointers before Flutter reports an accepted drag's end.
class _SidebarHorizontalDragRecognizer extends HorizontalDragGestureRecognizer {
  /// Owning state receives pointer cancellation before any terminal callback.
  VoidCallback? onPointerCancelled;

  /// Lets an overlaid status surface preserve the underlying composer controls.
  bool Function(Offset globalPosition)? canStartAt;

  /// Retains Flutter's standard touch slop, competition and velocity estimation.
  _SidebarHorizontalDragRecognizer({super.debugOwner});

  /// Rejects excluded areas before this recognizer can enter the gesture arena.
  @override
  bool isPointerAllowed(PointerEvent event) =>
      (canStartAt?.call(event.position) ?? true) &&
      super.isPointerAllowed(event);

  /// Pointer-cancel must never be interpreted as the approved release gesture.
  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerCancelEvent) onPointerCancelled?.call();
    super.handleEvent(event);
  }
}
