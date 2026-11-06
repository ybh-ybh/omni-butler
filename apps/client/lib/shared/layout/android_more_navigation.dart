import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/audio/microphone_coordinator.dart';
import 'package:omni_butler/features/management/presentation/management_navigation.dart';
import 'package:omni_butler/features/notes/data/note_providers.dart';
import 'package:omni_butler/features/settings/data/feature_preferences.dart';
import 'package:omni_butler/shared/layout/android_more_shortcuts.dart';
import 'package:omni_butler/shared/layout/android_sidebar_swipe_target.dart';
import 'package:omni_butler/shared/layout/primary_navigation_swipe.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// Builds fixed navigation with a toggle and a guarded close-before-action hook.
typedef AndroidMoreNavigationBuilder = Widget Function(
  bool selected,
  VoidCallback onToggle,
  Future<bool> Function() onClose,
);

/// Hosts the compact menu above the fixed navigation without replacing pages.
class AndroidMoreNavigation extends ConsumerStatefulWidget {
  /// Identifies the actual visible route, including pushed secondary pages.
  final String location;

  /// Hides navigation and dismisses its menu on secondary pages or the AI IME.
  final bool showNavigation;

  /// Keeps the existing note keyboard geometry contract.
  final bool resizeToAvoidBottomInset;

  /// Retains the existing branch navigator subtree.
  final Widget child;

  /// Reuses the shell's navigation item rendering.
  final AndroidMoreNavigationBuilder navigationBuilder;

  /// Prevents opening a menu during a guarded primary transition.
  final PrimaryNavigationCoordinator? coordinator;

  /// Creates a compact-only host with no public route of its own.
  const AndroidMoreNavigation({
    required this.location,
    required this.showNavigation,
    required this.resizeToAvoidBottomInset,
    required this.child,
    required this.navigationBuilder,
    this.coordinator,
    super.key,
  });

  /// Owns menu animation and request lifetimes independently from page state.
  @override
  ConsumerState<AndroidMoreNavigation> createState() =>
      _AndroidMoreNavigationState();
}

/// Keeps a closing menu modal until its final frame and serializes navigation.
class _AndroidMoreNavigationState extends ConsumerState<AndroidMoreNavigation>
    with SingleTickerProviderStateMixin {
  /// Drives only the menu and scrim, leaving content geometry unchanged.
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: OmniMotion.androidModalEnter,
    reverseDuration: OmniMotion.androidModalExit,
  );

  /// Shares the application's modal curve across both surfaces.
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _motion,
    curve: OmniMotion.androidModalCurve,
    reverseCurve: OmniMotion.androidModalCurve,
  );

  /// Retains the modal input boundary throughout the reverse transition.
  bool _present = false;

  /// Prevents duplicate stop/save requests.
  bool _pending = false;

  /// Invalidates asynchronous work when navigation or user intent changes.
  int _request = 0;

  /// Tracks a downward dismissal gesture in logical pixels.
  double _drag = 0;

  /// Dismisses obsolete surfaces before rendering a new route or layout.
  @override
  void didUpdateWidget(covariant AndroidMoreNavigation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.location != widget.location || !widget.showNavigation) {
      _request++;
      _motion.value = 0;
      _present = false;
      _pending = false;
    }
  }

  /// Releases animation resources and invalidates delayed operations.
  @override
  void dispose() {
    _request++;
    _curve.dispose();
    _motion.dispose();
    super.dispose();
  }

  /// Reads pushed routes instead of the possibly retained browser URL.
  String get _path =>
      GoRouter.maybeOf(context)?.state.uri.path ?? widget.location;

  /// Rejects results belonging to a previous page, menu, or save attempt.
  bool _owns(int request, String source) =>
      mounted &&
      request == _request &&
      widget.showNavigation &&
      _path == source;

  /// Stops AI voice and persists its draft before obscuring the composer.
  Future<void> _toggle() async {
    if (_present) {
      await _close();
      return;
    }
    if (_pending ||
        !widget.showNavigation ||
        widget.coordinator?.isTransitioning == true) {
      return;
    }
    // Freeze the originating route across asynchronous voice cancellation.
    final String source = _path;
    // This request alone may reveal the menu after persistence completes.
    final int request = ++_request;
    setState(() => _pending = true);
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      if (source == '/assistant') {
        await ref.read(voiceInputLifecycleProvider).cancelAll();
      }
      if (!mounted || !_owns(request, source)) return;
      setState(() => _present = true);
      if (OmniMotion.reduce(context)) {
        _motion.value = 1;
      } else {
        unawaited(_motion.forward());
      }
    } catch (_) {
      if (_owns(request, source)) _saveFailure();
    } finally {
      if (mounted && request == _request) {
        setState(() => _pending = false);
      }
    }
  }

  /// Closes only this menu and invalidates any previous pending destination.
  Future<bool> _close({bool cancelPending = true}) async {
    // A later click or route change supersedes this reverse animation.
    final int request = ++_request;
    if (cancelPending && _pending) setState(() => _pending = false);
    if (!_present) return true;
    try {
      if (OmniMotion.reduce(context)) {
        _motion.value = 0;
      } else {
        await _motion.reverse().orCancel;
      }
      if (mounted && request == _request) {
        setState(() => _present = false);
        return true;
      }
    } on TickerCanceled {
      // Disposal or another menu operation owns the current visual state.
    }
    return false;
  }

  /// Resolves current feature preferences again after a potentially slow save.
  String? _destination(String id) {
    // Changes to feature preferences must not navigate to a disabled route.
    final FeaturePreference preference = ref.read(featurePreferenceProvider);
    return switch (id) {
      'todos' => preference.isEnabled(AppFeature.todos) ? '/todos' : null,
      'timeline' =>
        preference.isEnabled(AppFeature.timeline) ? '/timeline' : null,
      'management' => resolveManagementSection(
        preference,
        ref.read(managementSectionProvider),
      )?.route,
      'settings' => '/settings',
      _ => null,
    };
  }

  /// Pushes existing features so native back restores the original page.
  Future<void> _select(String id) async {
    if (_pending) return;
    // Capture the origin before dismissing the panel.
    final String source = _path;
    setState(() => _pending = true);
    // Capture dismissal ownership before waiting for its animation.
    final Future<bool> closing = _close(cancelPending: false);
    // New intent during persistence must cancel this navigation request.
    final int request = _request;
    try {
      if (!await closing || !_owns(request, source)) return;
      if (source == '/notes') {
        // Reuse the actual editor; failed persistence keeps its draft intact.
        final editor = ref.read(noteEditorProvider);
        await editor.flush();
        if (editor.dirty) {
          if (_owns(request, source)) _saveFailure();
          return;
        }
      }
      if (source == '/assistant') {
        await ref.read(voiceInputLifecycleProvider).cancelAll();
      }
      if (!mounted || !_owns(request, source)) return;
      // Resolve management memory and feature gates at the final commit point.
      final String? destination = _destination(id);
      if (destination != null) unawaited(context.push<void>(destination));
    } catch (_) {
      if (_owns(request, source)) _saveFailure();
    } finally {
      if (mounted && request == _request) {
        setState(() => _pending = false);
      }
    }
  }

  /// Uses the existing message surface while keeping the originating page.
  void _saveFailure() => showOmniMessage(
    context,
    message: '草稿未能保存，请检查后重试',
    tone: OmniMessageTone.error,
  );

  /// Consumes native back before any retained page or root fallback can pop.
  Future<bool> _back() async {
    unawaited(_close());
    return true;
  }

  /// Keeps the branch subtree, scaffold and navigation geometry stable.
  @override
  Widget build(BuildContext context) {
    // Resolve colors dynamically so open menus follow theme changes.
    final OmniColors colors = OmniColors.of(context);
    // Saving belongs to the same modal interaction boundary as the panel.
    final bool blocked = _present || _pending;
    return PopScope<Object?>(
      canPop: !blocked,
      child: Scaffold(
        resizeToAvoidBottomInset: widget.resizeToAvoidBottomInset,
        backgroundColor: colors.canvas,
        body: SafeArea(
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              AndroidSidebarSwipeScope(
                enabled: !blocked,
                child: ExcludeSemantics(
                  excluding: blocked,
                  child: ExcludeFocus(
                    excluding: blocked,
                    child: IgnorePointer(
                      ignoring: blocked,
                      child: widget.child,
                    ),
                  ),
                ),
              ),
              if (blocked)
                BackButtonListener(
                  onBackButtonPressed: _back,
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      if (_present)
                        FadeTransition(
                          opacity: _curve,
                          child: ModalBarrier(
                            key: const ValueKey<String>(
                              'android-more-backdrop',
                            ),
                            color: Colors.black.withValues(alpha: .42),
                            onDismiss: () => unawaited(_close()),
                            semanticsLabel: '关闭更多',
                          ),
                        ),
                      if (_present)
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: SlideTransition(
                            position: Tween<Offset>(
                              begin: const Offset(0, 1),
                              end: Offset.zero,
                            ).animate(_curve),
                            child: GestureDetector(
                              excludeFromSemantics: true,
                              onVerticalDragStart: (_) => _drag = 0,
                              onVerticalDragUpdate: (details) =>
                                  _drag += details.delta.dy,
                              onVerticalDragEnd: (details) {
                                if (_drag > 24 ||
                                    details.velocity.pixelsPerSecond.dy > 500) {
                                  unawaited(_close());
                                }
                              },
                              child: Material(
                                key: const ValueKey<String>(
                                  'android-more-panel',
                                ),
                                color: colors.paper,
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(OmniRadius.dialog),
                                ),
                                clipBehavior: Clip.antiAlias,
                                child: SingleChildScrollView(
                                  padding: const EdgeInsets.all(OmniSpacing.md),
                                  child: AndroidMoreShortcuts(
                                    onSelected: (id) => unawaited(_select(id)),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        bottomNavigationBar: widget.showNavigation
            ? widget.navigationBuilder(
                _present,
                () => unawaited(_toggle()),
                _close,
              )
            : null,
      ),
    );
  }
}
