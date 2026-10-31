import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// Supplies the shared return action to pages with their own header.
class AndroidSecondaryPageScope extends InheritedWidget {
  /// Activates compact chrome while retaining the same business-page ancestry.
  final bool enabled;

  /// Returns through local guards before leaving the feature page.
  final VoidCallback onBack;

  /// Shares the feature-page return action without replacing its content.
  const AndroidSecondaryPageScope({
    required this.enabled,
    required this.onBack,
    required super.child,
    super.key,
  });

  /// Finds a compact Android feature-page host, if present.
  static AndroidSecondaryPageScope? maybeOf(BuildContext context) {
    // Wide layouts keep the scope mounted without exposing a back action.
    final AndroidSecondaryPageScope? scope = context
        .dependOnInheritedWidgetOfExactType<AndroidSecondaryPageScope>();
    return scope?.enabled == true ? scope : null;
  }

  /// Refreshes consumers when the host return action changes.
  @override
  bool updateShouldNotify(AndroidSecondaryPageScope oldWidget) =>
      oldWidget.onBack != onBack || oldWidget.enabled != enabled;
}

/// Adds compact Android return navigation to an existing business page.
class AndroidSecondaryPage extends StatelessWidget {
  /// Identifies the actual top route, including imperative pushes.
  final String location;

  /// Labels the shared header; null lets the page use its own header.
  final String? title;

  /// Keeps the existing business UI and its local navigation guards.
  final Widget child;

  /// Wraps a secondary feature without changing desktop or tablet layouts.
  const AndroidSecondaryPage({
    required this.location,
    required this.child,
    this.title,
    super.key,
  });

  /// Closes input and nested surfaces before popping or returning home.
  Future<bool> _back(BuildContext context) async {
    // Ignore preloaded routes and inactive branch navigators.
    final GoRouter router = GoRouter.of(context);
    if (router.state.uri.path != location) return false;
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      FocusManager.instance.primaryFocus?.unfocus();
      return true;
    }
    // The delegate closes root dialogs before consulting branch PopScopes.
    final bool handled = await router.routerDelegate.popRoute();
    if (!handled && context.mounted) router.go('/home');
    return true;
  }

  /// Builds a full-screen feature surface only on compact Android.
  @override
  Widget build(BuildContext context) {
    // Wide Android and desktop retain their original page chrome.
    final bool compactAndroid =
        Theme.of(context).platform == TargetPlatform.android &&
        OmniBreakpoint.isCompact(MediaQuery.sizeOf(context).width);
    // Let the title grow with accessibility text without clipping the toolbar.
    final double headerHeight = math.max(
      56,
      MediaQuery.textScalerOf(context)
                  .scale(Theme.of(context).textTheme.titleLarge!.fontSize!) *
              1.4 +
          OmniSpacing.md,
    );
    return BackButtonListener(
      onBackButtonPressed: () =>
          compactAndroid ? _back(context) : Future<bool>.value(false),
      child: AndroidSecondaryPageScope(
        enabled: compactAndroid,
        onBack: () => unawaited(_back(context)),
        child: Column(
          children: <Widget>[
            if (compactAndroid && title != null)
              SizedBox(
                key: const ValueKey<String>('android-secondary-header'),
                height: headerHeight,
                child: Row(
                  children: <Widget>[
                    OmniIconButton(
                      key: const ValueKey<String>('android-secondary-back'),
                      tooltip: '返回',
                      icon: const Icon(Icons.arrow_back_rounded),
                      onPressed: () => unawaited(_back(context)),
                    ),
                    Expanded(
                      child: Text(
                        title!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    const SizedBox(width: OmniSize.touch),
                  ],
                ),
              ),
            Expanded(
              key: const ValueKey<String>('android-secondary-body'),
              child: child,
            ),
          ],
        ),
      ),
    );
  }
}
