import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/shared/ui/omni_overlay.dart';

/// A named choice whose value is returned only after explicit activation.
@immutable
class OmniActionSheetAction<T> {
  /// Visible, accessible name of this choice.
  final String label;

  /// Business value returned to the caller.
  final T value;

  /// Whether this choice has destructive consequences.
  final bool danger;

  /// Optional stable identity retained from a business entry point.
  final Key? key;

  /// Creates one choice without running business work inside the route.
  const OmniActionSheetAction({
    required this.label,
    required this.value,
    this.danger = false,
    this.key,
  });
}

/// Opens a bottom confirmation surface using the existing modal route.
Future<T?> showOmniActionSheet<T>({
  required BuildContext context,
  required String title,
  required String message,
  required List<OmniActionSheetAction<T>> actions,
  Key? cancelKey,
}) => showOmniDialog<T>(
  context: context,
  useSafeArea: false,
  builder: (BuildContext context) => _OmniActionSheet<T>(
    title: title,
    message: message,
    actions: actions,
    cancelKey: cancelKey,
  ),
);

/// Keeps all confirmation choices on a single, bottom-aligned surface.
class _OmniActionSheet<T> extends StatefulWidget {
  /// Route name announced to accessibility services instead of a title bar.
  final String title;

  /// Complete explanation of the selected object's consequences.
  final String message;

  /// Ordered business choices, excluding the separate cancel row.
  final List<OmniActionSheetAction<T>> actions;

  /// Optional identity for the cancel row.
  final Key? cancelKey;

  /// Creates an adaptive confirmation with an independent cancel action.
  const _OmniActionSheet({
    required this.title,
    required this.message,
    required this.actions,
    required this.cancelKey,
  });

  /// Retains a dismissal guard throughout the exit animation.
  @override
  State<_OmniActionSheet<T>> createState() => _OmniActionSheetState<T>();
}

/// Handles adaptive layout and prevents repeated taps from popping a parent.
class _OmniActionSheetState<T> extends State<_OmniActionSheet<T>> {
  /// Whether an explicit choice has already started closing this route.
  bool _closing = false;

  /// Resolves at most one choice and leaves all business mutations to callers.
  void _choose([T? value]) {
    if (_closing || ModalRoute.of(context)?.isCurrent != true) return;
    setState(() => _closing = true);
    Navigator.of(context).pop(value);
  }

  /// Builds a full-width text action with a wrapping label and touch target.
  Widget _action({
    required String label,
    required Color color,
    required VoidCallback onPressed,
    Key? key,
  }) => TextButton(
    key: key,
    onPressed: _closing ? null : onPressed,
    style: TextButton.styleFrom(
      foregroundColor: color,
      disabledForegroundColor: color,
      backgroundColor: Colors.transparent,
      minimumSize: const Size(double.infinity, 56),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
      shape: const RoundedRectangleBorder(),
      textStyle: Theme.of(context).textTheme.bodyLarge
          ?.copyWith(fontSize: 16, height: 1.4, fontWeight: FontWeight.w400),
    ),
    child: Text(label, textAlign: TextAlign.center),
  );

  /// Leaves the surface flush with the viewport while protecting its contents.
  @override
  Widget build(BuildContext context) {
    // Resolve semantic colors without inheriting a filled button appearance.
    final OmniColors colors = OmniColors.of(context);
    // Follow the active keyboard without changing the route's animation.
    final double keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    return AnimatedPadding(
      duration: OmniMotion.duration(context, OmniMotion.normal),
      curve: OmniMotion.standardCurve,
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: SafeArea(
        left: false,
        right: false,
        bottom: false,
        minimum: const EdgeInsets.only(top: 24),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Semantics(
            scopesRoute: true,
            namesRoute: true,
            explicitChildNodes: true,
            label: widget.title,
            child: Material(
              key: const ValueKey<String>('omni-action-sheet-surface'),
              color: Theme.of(context).brightness == Brightness.light
                  ? Colors.white
                  : colors.paper,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(12),
              ),
              clipBehavior: Clip.antiAlias,
              child: SafeArea(
                top: false,
                child: SizedBox(
                  width: double.infinity,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Flexible(
                        child: SingleChildScrollView(
                          primary: false,
                          padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                          child: Text(
                            widget.message,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: colors.muted,
                                  fontSize: 13,
                                  height: 1.5,
                                ),
                          ),
                        ),
                      ),
                      Flexible(
                        flex: 2,
                        child: SingleChildScrollView(
                          primary: false,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              // Each choice preserves its business order and value.
                              for (final OmniActionSheetAction<T> action
                                  in widget.actions)
                                _action(
                                  key: action.key,
                                  label: action.label,
                                  color: action.danger
                                      ? Theme.of(context).brightness ==
                                                Brightness.dark
                                            ? colors.danger
                                            : Theme.of(context)
                                                  .colorScheme
                                                  .error
                                      : colors.brandStrong,
                                  onPressed: () => _choose(action.value),
                                ),
                            ],
                          ),
                        ),
                      ),
                      Divider(height: 1, thickness: 0.5, color: colors.line),
                      _action(
                        key:
                            widget.cancelKey ??
                            const ValueKey<String>('omni-action-sheet-cancel'),
                        label: '取消',
                        color: colors.ink,
                        onPressed: _choose,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
