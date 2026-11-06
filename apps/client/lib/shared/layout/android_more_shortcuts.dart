import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/features/management/presentation/management_navigation.dart';
import 'package:omni_butler/features/settings/data/feature_preferences.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// Lists enabled secondary features inside the Android navigation panel.
class AndroidMoreShortcuts extends ConsumerWidget {
  /// Creates shortcuts that respect the existing feature preferences.
  const AndroidMoreShortcuts({required this.onSelected, super.key});

  /// Delegates guarded navigation to the owning menu host.
  final ValueChanged<String> onSelected;

  /// Measures labels before choosing a single row or a two-column layout.
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Only enabled features may appear as shortcuts.
    final FeaturePreference preference = ref.watch(featurePreferenceProvider);
    // Management reopens the most recently selected available section.
    final ManagementSection? management = resolveManagementSection(
      preference,
      ref.watch(managementSectionProvider),
    );
    // Stable identifiers are separate from the current management route.
    final List<({String id, String label, IconData icon})> entries =
        <({String id, String label, IconData icon})>[
          if (preference.isEnabled(AppFeature.todos))
            (id: 'todos', label: '全部待办', icon: Icons.check_box_outlined),
          if (preference.isEnabled(AppFeature.timeline))
            (id: 'timeline', label: '时间记录', icon: Icons.access_time_outlined),
          if (management != null)
            (
              id: 'management',
              label: '管理',
              icon: Icons.dashboard_customize_outlined,
            ),
          (id: 'settings', label: '设置', icon: Icons.settings_outlined),
        ];
    // Reuse the current theme rather than adding a new shortcut palette.
    final OmniColors colors = OmniColors.of(context);
    // The measured and painted labels use identical font metrics.
    final TextStyle labelStyle = Theme.of(context).textTheme.labelMedium!
        .copyWith(color: colors.ink);
    // Respect nonlinear system text scaling when selecting the layout.
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // All shortcuts share the width required by the longest label.
        double requiredWidth = OmniSize.touch;
        for (final entry in entries) {
          // Measure the actual localized label instead of assuming a device size.
          final TextPainter painter = TextPainter(
            text: TextSpan(text: entry.label, style: labelStyle),
            textDirection: Directionality.of(context),
            textScaler: scaler,
          )..layout();
          requiredWidth = math.max(
            requiredWidth,
            painter.width + OmniSpacing.xs * 2,
          );
          painter.dispose();
        }
        // A normal phone uses one row; large labels use at most two columns.
        final int columns =
            requiredWidth * entries.length <= constraints.maxWidth
            ? entries.length
            : math.min(2, entries.length);
        // The available width includes each shortcut's own horizontal padding.
        final double width = constraints.maxWidth / columns;
        return Wrap(
          key: const ValueKey<String>('android-more-shortcuts'),
          children: <Widget>[
            for (final entry in entries)
              SizedBox(
                key: ValueKey<String>('more-shortcut-${entry.id}'),
                width: width,
                child: Material(
                  color: Colors.transparent,
                  child: OmniInkWell(
                    onTap: () => onSelected(entry.id),
                    borderRadius: BorderRadius.circular(OmniRadius.control),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minWidth: OmniSize.touch,
                        minHeight: OmniSize.touch,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(OmniSpacing.xs),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Icon(
                              entry.icon,
                              size: OmniSize.navigationIcon,
                              color: colors.muted,
                            ),
                            const SizedBox(height: OmniSpacing.xxs),
                            Text(
                              entry.label,
                              textAlign: TextAlign.center,
                              style: labelStyle,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
