import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/todos/data/todo_completion_entry.dart';
import 'package:omni_butler/features/todos/data/todo_completion_summary.dart';
import 'package:omni_butler/features/todos/presentation/android_todo_completion_filter.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// Opens an isolated archive route and returns only an explicit selection.
Future<AndroidTodoCompletionFilter?> showAndroidTodoCompletionSidebar(
  BuildContext context, {
  required AndroidTodoCompletionFilter initial,
}) {
  FocusScope.of(context).unfocus();
  // Capture the source before opening so a late selection cannot cross databases.
  final AppDatabase source = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(appDatabaseProvider);
  return Navigator.of(
    context,
    rootNavigator: true,
  ).push<AndroidTodoCompletionFilter>(
    _AndroidCompletionSidebarRoute(
      initial: initial,
      source: source,
      reduced: OmniMotion.reduce(context),
    ),
  );
}

/// Gives the archive a modal focus scope and a directly draggable transition.
class _AndroidCompletionSidebarRoute
    extends PopupRoute<AndroidTodoCompletionFilter> {
  /// Keeps the currently applied conditions for the selected row appearance.
  final AndroidTodoCompletionFilter initial;

  /// Locks this archive session to the database that opened it.
  final AppDatabase source;

  /// Disables positional animation when the system requests reduced motion.
  final bool reduced;

  /// Avoids applying the entrance curve twice once a gesture takes control.
  bool _direct = false;

  /// Allows dismissal only after an owned drag ends with a real pointer release.
  bool _dragActive = false;

  /// Creates one independently dismissible archive session.
  _AndroidCompletionSidebarRoute({
    required this.initial,
    required this.source,
    required this.reduced,
  });

  /// Matches the notes sidebar entrance duration.
  @override
  Duration get transitionDuration =>
      reduced ? Duration.zero : OmniMotion.androidModalEnter;

  /// Matches the notes sidebar exit duration.
  @override
  Duration get reverseTransitionDuration =>
      reduced ? Duration.zero : OmniMotion.androidModalExit;

  /// Dims the covered page without applying a blur.
  @override
  Color get barrierColor => Colors.black.withValues(alpha: .42);

  /// Allows the exposed page scrim to cancel the archive.
  @override
  bool get barrierDismissible => true;

  /// Names the dismissal action for screen readers.
  @override
  String get barrierLabel => '关闭完成历史侧栏';

  /// Continues a closing gesture from the current visual transition position.
  void _beginDrag() {
    _dragActive = isCurrent;
    if (!_dragActive) return;
    controller!.stop();
    if (!_direct) {
      _direct = true;
      controller!.value = Curves.easeOutCubic.transform(controller!.value);
    }
  }

  /// Restores an incomplete dismissal without replacing the route.
  void _restore() {
    if (!isCurrent) return;
    controller!.animateTo(
      1,
      duration: reduced ? Duration.zero : OmniMotion.androidModalExit,
      curve: Curves.easeOutCubic,
    );
  }

  /// Invalidates cancellation before Flutter can report it as a drag end.
  void _cancelDrag() {
    if (!_dragActive) return;
    _dragActive = false;
    _restore();
  }

  /// Keeps horizontal dismissal outside the chart's own gesture arena winner.
  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    // The same width drives both layout and direct gesture progress.
    final double width = math.min(MediaQuery.sizeOf(context).width * .82, 360);
    return RawGestureDetector(
      key: const ValueKey('android-completion-sidebar-drag'),
      behavior: HitTestBehavior.translucent,
      excludeFromSemantics: true,
      gestures: <Type, GestureRecognizerFactory>{
        _CompletionSidebarDragRecognizer:
            GestureRecognizerFactoryWithHandlers<
              _CompletionSidebarDragRecognizer
            >(() => _CompletionSidebarDragRecognizer(debugOwner: this), (
              _CompletionSidebarDragRecognizer recognizer,
            ) {
              recognizer
                ..onPointerCancelled = _cancelDrag
                ..onStart = (_) {
                  _beginDrag();
                }
                ..onUpdate = (details) {
                  if (!_dragActive || !isCurrent) return;
                  controller!.value =
                      (controller!.value + details.delta.dx / width).clamp(
                        0,
                        1,
                      );
                }
                ..onEnd = (details) {
                  if (!_dragActive || !isCurrent) return;
                  _dragActive = false;
                  if (controller!.value < .72 ||
                      details.velocity.pixelsPerSecond.dx < -500) {
                    Navigator.pop(context);
                  } else {
                    _restore();
                  }
                }
                ..onCancel = _cancelDrag;
            }),
      },
      child: Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: width,
          height: double.infinity,
          child: Semantics(
            scopesRoute: true,
            namesRoute: true,
            label: '完成历史归档',
            explicitChildNodes: true,
            child: _AndroidCompletionSidebar(initial: initial, source: source),
          ),
        ),
      ),
    );
  }

  /// Slides only by the actual sidebar width while the route owns the scrim.
  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => reduced
      ? child
      : AnimatedBuilder(
          animation: animation,
          child: child,
          builder: (context, child) {
            // Direct drags already store their visible progress in the controller.
            final double value = _direct
                ? animation.value
                : Curves.easeOutCubic.transform(animation.value);
            // Rotation updates the transition geometry alongside the layout.
            final double width = math.min(
              MediaQuery.sizeOf(context).width * .82,
              360,
            );
            return Transform.translate(
              offset: Offset(-width * (1 - value), 0),
              child: child,
            );
          },
        );
}

/// Marks pointer cancellation before the base recognizer invokes end callbacks.
class _CompletionSidebarDragRecognizer extends HorizontalDragGestureRecognizer {
  /// Withdraws route dismissal ownership before processing a cancelled pointer.
  VoidCallback? onPointerCancelled;

  /// Retains standard drag slop and competition with the nested heatmap scroll.
  _CompletionSidebarDragRecognizer({super.debugOwner});

  /// Prevents an accepted drag cancellation from acting like a release.
  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerCancelEvent) onPointerCancelled?.call();
    super.handleEvent(event);
  }
}

/// Reads complete history for statistics and archives independently of filters.
class _AndroidCompletionSidebar extends ConsumerStatefulWidget {
  /// Records the filter applied before the archive opened.
  final AndroidTodoCompletionFilter initial;

  /// Prevents another database's records from entering this selection session.
  final AppDatabase source;

  /// Creates a complete-history archive with local route ownership.
  const _AndroidCompletionSidebar({
    required this.initial,
    required this.source,
  });

  /// Creates the route-local nested sheet gate.
  @override
  ConsumerState<_AndroidCompletionSidebar> createState() =>
      _AndroidCompletionSidebarState();
}

/// Returns one changed filter dimension while preserving the other dimension.
class _AndroidCompletionSidebarState
    extends ConsumerState<_AndroidCompletionSidebar> {
  /// Prevents multiple custom-date sheets from opening simultaneously.
  bool _filterOpen = false;

  /// Schedules source-change dismissal at most once.
  bool _leaving = false;

  /// Returns a selection only while this route still owns its original source.
  void _select(AndroidTodoCompletionFilter value) {
    if (!identical(ref.read(appDatabaseProvider), widget.source)) return;
    Navigator.pop(context, value);
  }

  /// Changes only the date condition and preserves the active task category.
  void _selectRange(DateTime? start, DateTime? end) => _select(
    AndroidTodoCompletionFilter(
      kind: widget.initial.kind,
      startDate: start,
      endDate: end,
    ),
  );

  /// Toggles one category without discarding the selected date range.
  void _selectKind(TodoCompletionKind kind) => _select(
    AndroidTodoCompletionFilter(
      kind: widget.initial.kind == kind ? null : kind,
      startDate: widget.initial.startDate,
      endDate: widget.initial.endDate,
    ),
  );

  /// Applies the nested draft only after its explicit confirmation.
  Future<void> _customDates() async {
    if (_filterOpen) return;
    _filterOpen = true;
    try {
      // A cancelled draft keeps the archive and its original conditions intact.
      final AndroidTodoCompletionFilter? result =
          await showAndroidTodoCompletionFilter(
            context,
            initial: widget.initial,
          );
      if (mounted && result != null) _select(result);
    } finally {
      _filterOpen = false;
    }
  }

  /// Gives each archive section a quiet label without another card container.
  Widget _label(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(
      OmniSpacing.xs,
      OmniSpacing.md,
      OmniSpacing.xs,
      OmniSpacing.xs,
    ),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: OmniColors.of(context).muted),
    ),
  );

  /// Builds archive rows with wrapping titles and stable minimum touch height.
  Widget _choice({
    required String key,
    required String title,
    required bool selected,
    required VoidCallback onTap,
    int? count,
  }) {
    // Selection is a subdued theme tint rather than a new card boundary.
    final OmniColors colors = OmniColors.of(context);
    return Semantics(
      selected: selected,
      child: Material(
        color: selected ? colors.brand.withValues(alpha: .10) : colors.paper,
        borderRadius: BorderRadius.circular(OmniRadius.control),
        child: OmniListTile(
          key: ValueKey('android-completion-$key'),
          minTileHeight: OmniSize.touch,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: OmniSpacing.xs,
          ),
          title: Text(
            title,
            style: TextStyle(color: selected ? colors.brand : colors.ink),
          ),
          trailing: count == null
              ? null
              : Text(
                  '$count',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colors.muted),
                ),
          onTap: onTap,
        ),
      ),
    );
  }

  /// Uses explicit rolling windows so mobile labels do not imply calendar totals.
  Widget _statistics(TodoCompletionSummary summary) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      // Each metric owns one equal column and keeps its full semantic label.
      for (final int days in [7, 30, 365])
        Expanded(
          child: Semantics(
            key: ValueKey('android-completion-stat-$days'),
            label: '最近$days天完成${summary.countLastDays(days)}项',
            excludeSemantics: true,
            child: Column(
              crossAxisAlignment: days == 7
                  ? CrossAxisAlignment.start
                  : days == 30
                  ? CrossAxisAlignment.center
                  : CrossAxisAlignment.end,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '${summary.countLastDays(days)}',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                const SizedBox(height: OmniSpacing.xxs),
                Text(
                  '近$days天',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: OmniColors.of(context).muted),
                ),
              ],
            ),
          ),
        ),
    ],
  );

  /// Keeps existing data readable through refresh failures and permits retry.
  @override
  Widget build(BuildContext context) {
    // Switching databases invalidates this route and any nested filter draft.
    final bool same = identical(ref.watch(appDatabaseProvider), widget.source);
    if (!same && !_leaving) {
      _leaving = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // Close nested surfaces before closing their owning archive route.
        final ModalRoute<Object?>? own = ModalRoute.of(context);
        if (own == null || !own.isActive) return;
        Navigator.of(context).popUntil((route) => identical(route, own));
        Navigator.pop(context);
      });
    }
    // All displayed totals come from the full current completion projection.
    final AsyncValue<List<TodoCompletionEntry>> state = ref.watch(
      todoCompletionEntriesProvider,
    );
    // A minute clock refreshes rolling totals across local midnight.
    final DateTime now = ref.watch(nowProvider);
    // Missing data remains distinct from an actual empty history.
    final List<TodoCompletionEntry>? entries = state.value;
    // Reuse shared counting and grouping semantics without platform duplication.
    final TodoCompletionSummary? summary = entries == null
        ? null
        : TodoCompletionSummary(entries: entries, now: now);
    // The neutral surface follows the active theme in both brightness modes.
    final OmniColors colors = OmniColors.of(context);
    return Material(
      key: const ValueKey('android-completion-sidebar'),
      color: colors.paper,
      child: SafeArea(
        child: SingleChildScrollView(
          key: const ValueKey('android-completion-sidebar-scroll'),
          padding: const EdgeInsets.all(OmniSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '完成概览',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  OmniIconButton(
                    key: const ValueKey('android-completion-sidebar-close'),
                    tooltip: '关闭完成历史侧栏',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: OmniSpacing.lg),
              if (state.isLoading && entries == null)
                const LinearProgressIndicator(),
              if (state.hasError) ...[
                const Text('完成历史读取失败'),
                OmniButton(
                  key: const ValueKey('android-completion-sidebar-retry'),
                  label: '重试',
                  variant: OmniButtonVariant.text,
                  onPressed: () =>
                      ref.invalidate(todoCompletionEntriesProvider),
                ),
              ],
              if (summary != null && same) ...[
                _statistics(summary),
                const SizedBox(height: OmniSpacing.lg),
                _AndroidCompletionHeatmap(
                  summary: summary,
                  selectedDay:
                      widget.initial.startDate == widget.initial.endDate
                      ? widget.initial.startDate
                      : null,
                  onSelected: (day) {
                    if (widget.initial.startDate == day &&
                        widget.initial.endDate == day) {
                      _selectRange(null, null);
                    } else {
                      _selectRange(day, day);
                    }
                  },
                ),
                _label('任务类型'),
                _choice(
                  key: 'kind-all',
                  title: '全部类型',
                  selected: widget.initial.kind == null,
                  onTap: () => _select(
                    AndroidTodoCompletionFilter(
                      startDate: widget.initial.startDate,
                      endDate: widget.initial.endDate,
                    ),
                  ),
                ),
                _choice(
                  key: 'kind-normal',
                  title: '普通任务',
                  selected: widget.initial.kind == TodoCompletionKind.normal,
                  onTap: () => _selectKind(TodoCompletionKind.normal),
                ),
                _choice(
                  key: 'kind-progress',
                  title: '进度任务',
                  selected: widget.initial.kind == TodoCompletionKind.progress,
                  onTap: () => _selectKind(TodoCompletionKind.progress),
                ),
                const Divider(height: OmniSpacing.lg),
                _label('月份归档'),
                _choice(
                  key: 'all-dates',
                  title: '全部时间',
                  count: summary.entries.length,
                  selected:
                      widget.initial.startDate == null &&
                      widget.initial.endDate == null,
                  onTap: () => _selectRange(null, null),
                ),
                _choice(
                  key: 'custom-dates',
                  title: '自定义日期',
                  selected: false,
                  onTap: _customDates,
                ),
                // Year headings separate complete archive months chronologically.
                for (final (int index, DateTime month)
                    in summary.months.indexed) ...[
                  if (index == 0 ||
                      summary.months[index - 1].year != month.year)
                    _label('${month.year}年'),
                  _choice(
                    key: 'month-${DateFormat('yyyy-MM').format(month)}',
                    title: '${month.month}月',
                    count: summary.monthCounts[month],
                    selected:
                        widget.initial.startDate == month &&
                        widget.initial.endDate ==
                            DateTime(month.year, month.month + 1, 0),
                    onTap: () => _selectRange(
                      month,
                      DateTime(month.year, month.month + 1, 0),
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Shows the complete rolling year through an approximately twelve-week viewport.
class _AndroidCompletionHeatmap extends StatefulWidget {
  /// Supplies unfiltered day counts and the current rolling-year bounds.
  final TodoCompletionSummary summary;

  /// Marks a currently selected single day, if one is applied.
  final DateTime? selectedDay;

  /// Returns only days with at least one valid completed item.
  final ValueChanged<DateTime> onSelected;

  /// Creates one independent chart scroll session.
  const _AndroidCompletionHeatmap({
    required this.summary,
    required this.selectedDay,
    required this.onSelected,
  });

  /// Creates the horizontal controller and initial latest-day positioning gate.
  @override
  State<_AndroidCompletionHeatmap> createState() =>
      _AndroidCompletionHeatmapState();
}

/// Keeps chart gestures isolated even when its horizontal scroll reaches an edge.
class _AndroidCompletionHeatmapState extends State<_AndroidCompletionHeatmap> {
  /// Owns the chart's horizontal offset independently of the archive's scroll.
  final ScrollController _scroll = ScrollController();

  /// Positions the current day once without interrupting later manual browsing.
  bool _positioned = false;

  /// Releases the chart's independent scroll resources.
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Chooses the same fixed intensity buckets as the Windows overview.
  Color _dayColor(int count, OmniColors colors) => switch (count) {
    0 => colors.mist,
    <= 2 => Color.lerp(colors.paper, colors.brand, .22)!,
    <= 5 => Color.lerp(colors.paper, colors.brand, .46)!,
    <= 9 => Color.lerp(colors.paper, colors.brand, .72)!,
    _ => colors.brand,
  };

  /// Exposes every real calendar day and ignores empty-day taps.
  Widget _day(DateTime day, double pitch, OmniColors colors) {
    if (day.isBefore(widget.summary.firstHeatmapDay) ||
        day.isAfter(widget.summary.today)) {
      return SizedBox.square(dimension: pitch);
    }
    // Each visible cell represents exactly one complete local natural day.
    final int count = widget.summary.dayCounts[day] ?? 0;
    // Selected and current dates retain a distinct outline in any palette.
    final bool outlined =
        day == widget.selectedDay || day == widget.summary.today;
    // Accessible text does not depend on interpreting color intensity.
    final String label = '${DateFormat('yyyy年M月d日').format(day)}，完成$count项';
    return Semantics(
      label: label,
      button: count > 0,
      selected: day == widget.selectedDay,
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: OmniInkWell(
          key: ValueKey('android-completion-day-${businessDayKey(day)}'),
          onTap: count > 0 ? () => widget.onSelected(day) : null,
          borderRadius: BorderRadius.circular(OmniRadius.tiny),
          child: SizedBox.square(
            dimension: pitch,
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: _dayColor(count, colors),
                  borderRadius: BorderRadius.circular(OmniRadius.tiny),
                  border: outlined ? Border.all(color: colors.brand) : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Marks the first week crossing each month boundary.
  String _month(DateTime start) {
    // A seven-day column may cross into the next calendar month.
    final DateTime end = completionDayOffset(start, 6);
    if (start.day == 1) return '${start.month}月';
    if (start.month != end.month) return '${end.month}月';
    return '';
  }

  /// Builds a year-wide scrollable grid without letting it dismiss the sidebar.
  @override
  Widget build(BuildContext context) {
    // The graph uses the shared current palette and neutral empty-cell tone.
    final OmniColors colors = OmniColors.of(context);
    // Align the rolling-year start to Monday, leaving out-of-window cells blank.
    final DateTime aligned = completionDayOffset(
      widget.summary.firstHeatmapDay,
      1 - widget.summary.firstHeatmapDay.weekday,
    );
    // A leap-independent 365-day range occupies at most fifty-three week columns.
    final int columns =
        (364 + widget.summary.firstHeatmapDay.weekday - 1) ~/ 7 + 1;
    return GestureDetector(
      key: const ValueKey('android-completion-heatmap'),
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      onHorizontalDragStart: (_) {},
      onHorizontalDragUpdate: (_) {},
      onHorizontalDragEnd: (_) {},
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Normal drawer widths expose approximately the latest twelve weeks.
          final double pitch = math.max(18, constraints.maxWidth / 12);
          // Text labels expand vertically without shrinking the user's font.
          final double labelHeight = MediaQuery.textScalerOf(context).scale(24);
          if (!_positioned) {
            _positioned = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || !_scroll.hasClients) return;
              _scroll.jumpTo(_scroll.position.maxScrollExtent);
            });
          }
          return SingleChildScrollView(
            key: const ValueKey('android-completion-heatmap-scroll'),
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            physics: const AlwaysScrollableScrollPhysics(
              parent: ClampingScrollPhysics(),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Week columns retain complete day identity during all scrolling.
                for (int column = 0; column < columns; column++)
                  SizedBox(
                    width: pitch,
                    child: Column(
                      children: [
                        SizedBox(
                          height: labelHeight,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              _month(completionDayOffset(aligned, column * 7)),
                              softWrap: false,
                              overflow: TextOverflow.visible,
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(color: colors.muted),
                            ),
                          ),
                        ),
                        // Every column uses a fixed Monday-to-Sunday day order.
                        for (int row = 0; row < 7; row++)
                          _day(
                            completionDayOffset(aligned, column * 7 + row),
                            pitch,
                            colors,
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
