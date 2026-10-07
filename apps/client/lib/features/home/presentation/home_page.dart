import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/attachments/attachment_repository.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/home/data/home_card_preferences.dart';
import 'package:omni_butler/features/home/presentation/home_card_catalog.dart';
import 'package:omni_butler/features/home/presentation/home_card_manager.dart';
import 'package:omni_butler/features/home/presentation/home_context_card.dart';
import 'package:omni_butler/features/home/presentation/home_time_status_card.dart';
import 'package:omni_butler/features/home/presentation/quote_library_dialog.dart';
import 'package:omni_butler/features/settings/data/feature_preferences.dart';
import 'package:omni_butler/features/timeline/presentation/timeline_page.dart';
import 'package:omni_butler/features/todos/data/todo_priority_quadrant.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:omni_butler/features/todos/presentation/todo_editor_dialog.dart';
import 'package:omni_butler/features/todos/presentation/todo_priority_quadrant_style.dart';
import 'package:omni_butler/features/todos/presentation/todo_progress_widgets.dart';
import 'package:omni_butler/shared/attachments/attachment_picker_dialog.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// Android 首页拆分按钮中的次要操作。
enum _HomeMobileAction {
  /// 补记已经完成的时间记录。
  backfill,

  /// 新增待办。
  todo,
}

/// 首页任务行的上下文菜单操作。
enum _HomeTodoAction {
  /// 编辑当前任务。
  edit,

  /// 为主任务添加直属子任务。
  addChild,

  /// 将当前任务及其子任务移入回收站。
  delete,
}

/// 今日工作台页面。
class HomePage extends ConsumerWidget {
  /// Android 悬浮拆分按钮需要避让的滚动内容高度。
  static const double _mobileActionClearance = 88;

  /// 创建今日工作台页面。
  const HomePage({super.key});

  /// 构建可配置卡片式今日工作台。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 当前应用时间。
    final DateTime now = ref.watch(nowProvider);
    // 今日自然日。
    final DateTime today = DateUtils.dateOnly(now);
    // 今日名言异步状态。
    final AsyncValue<QuoteRecord?> quoteAsync = ref.watch(
      quoteForDayProvider(today),
    );
    // 全部进行中待办树异步状态。
    final AsyncValue<List<TodoTreeNode>> todoTreesAsync = ref.watch(
      activeTodoTreesProvider(today),
    );
    // 与每日待办共用跨日期活动集合及仓储排序，首页仅限制象限和展示条数。
    final List<TodoTreeNode> pendingTodoTrees =
        todoTreesAsync.asData?.value ?? <TodoTreeNode>[];
    // 捕获页面生命周期之外仍可用的仓储，完成动画中切页也能提交。
    final TodoRepository todoRepository = ref.watch(todoRepositoryProvider);
    // 当前设备首页卡片偏好。
    final HomeCardPreference cardPreference = ref.watch(
      homeCardPreferenceProvider,
    );
    // 当前设备功能偏好。
    final FeaturePreference featurePreference = ref.watch(
      featurePreferenceProvider,
    );
    // 当前是否使用 Android 紧凑首页。
    final bool androidCompact =
        Theme.of(context).platform == TargetPlatform.android &&
        OmniBreakpoint.isCompact(MediaQuery.sizeOf(context).width);

    /// 打开待办新增弹窗。
    void openTodoEditor() {
      unawaited(TodoEditorDialog.show(context, initialDate: today));
    }

    /// 执行任务菜单操作，返回是否保存了变更。
    Future<bool> handleTodoAction(
      TodoRecord todo,
      _HomeTodoAction action,
    ) async {
      switch (action) {
        case _HomeTodoAction.edit:
          return await TodoEditorDialog.show(context, record: todo) ?? false;
        case _HomeTodoAction.addChild:
          if (todo.parentId != null || todo.taskType == 'progress') {
            return false;
          }
          return await TodoEditorDialog.show(context, parent: todo) ?? false;
        case _HomeTodoAction.delete:
          // 首页使用仓储的单次删除范围，将当前任务树移入回收站。
          final bool confirmed = await showOmniConfirmDialog(
            context,
            title: '删除任务？',
            message:
                '${todo.taskType == 'progress'
                    ? '“${todo.title}”及其进度步骤'
                    : todo.parentId == null
                    ? '“${todo.title}”及其子任务'
                    : '“${todo.title}”'}会移入回收站，可在回收站恢复。'
                '${todo.repeatSeriesId == null ? '' : '\n仅将本次任务移入回收站。'}',
            confirmLabel: '删除任务',
            danger: true,
          );
          if (!confirmed || !context.mounted) {
            return false;
          }
          try {
            await todoRepository.delete(todo.id);
            if (context.mounted) {
              ref.invalidate(recycleBinItemsProvider);
              showOmniMessage(
                context,
                message: '“${todo.title}”已移入回收站',
                tone: OmniMessageTone.success,
              );
            }
            return true;
          } catch (_) {
            if (context.mounted) {
              showOmniMessage(
                context,
                message: '删除失败，请重试',
                tone: OmniMessageTone.error,
              );
            }
            return false;
          }
      }
    }

    // 今日名言卡。
    final Widget quoteCard = _QuoteHero(
      quoteAsync: quoteAsync,
      dense: true,
      onManage: () => QuoteLibraryDialog.show(context),
      onBackground: () => AttachmentPickerDialog.show(
        context,
        businessType: AttachmentBusinessType.quoteBanner,
        businessId: 'home-banner',
        title: '首页横幅背景',
        cropAspectRatio: 3.0,
      ),
      onChange: () async {
        await ref.read(appDatabaseProvider).changeQuoteForDay(today);
        ref.invalidate(quoteForDayProvider(today));
      },
    );
    // 今日时间刻度卡。
    final Widget dayRuler = _DayRuler(now: now);
    // 今日重点待办卡。
    final Widget todoCard = _TodayTodoCard(
      todoTreesAsync: todoTreesAsync,
      pendingTodoTrees: pendingTodoTrees,
      onCreate: openTodoEditor,
      onAction: handleTodoAction,
      onToggle: (TodoRecord todo, bool value) =>
          todoRepository.setCompleted(todo.id, value),
    );
    // 所有稳定标识对应的首页卡片。
    final Map<HomeCardId, Widget> cards = <HomeCardId, Widget>{
      HomeCardId.quote: quoteCard,
      HomeCardId.dayRuler: dayRuler,
      HomeCardId.todos: todoCard,
      HomeCardId.todayContext: HomeTodayContextCard(now: now),
      HomeCardId.timeStatus: HomeTimeStatusCard(now: now),
    };
    // 同时满足用户选择和功能依赖的有序卡片。
    final List<HomeCardId> visibleCards = cardPreference.orderedCards
        .where(
          (HomeCardId card) => isHomeCardAvailable(card, featurePreference),
        )
        .toList(growable: false);

    // 首页卡片与工具栏的完整内容。
    final Widget dashboard = _HomeDashboard(
      visibleCards: visibleCards,
      cards: cards,
      onManageCards: () => showHomeCardManager(context),
      safeBottomPadding: androidCompact ? _mobileActionClearance : 0,
    );
    if (!androidCompact || !featurePreference.isEnabled(AppFeature.timeline)) {
      return dashboard;
    }
    // 当前全部进行中记录，用于同步 Android 首页与时间页的主操作状态。
    final List<TimeEntryRecord> ongoingEntries =
        ref.watch(ongoingTimeEntriesProvider).asData?.value ??
        const <TimeEntryRecord>[];
    // Android 首页拆分按钮中的可用次要操作。
    final List<OmniSplitAction<_HomeMobileAction>> mobileActions =
        <OmniSplitAction<_HomeMobileAction>>[
          const OmniSplitAction<_HomeMobileAction>(
            value: _HomeMobileAction.backfill,
            label: '补记时间',
            icon: Icons.edit_calendar_outlined,
          ),
          if (featurePreference.isEnabled(AppFeature.todos))
            const OmniSplitAction<_HomeMobileAction>(
              value: _HomeMobileAction.todo,
              label: '新增待办',
              icon: Icons.add_task_rounded,
            ),
        ];
    return Scaffold(
      floatingActionButton: OmniSplitActionButton<_HomeMobileAction>(
        keyPrefix: 'home-mobile',
        label: ongoingEntries.isEmpty ? '开始' : '结束记录',
        primaryIcon: ongoingEntries.isEmpty
            ? Icons.play_arrow_rounded
            : Icons.stop_rounded,
        primarySemanticsLabel: ongoingEntries.isEmpty ? '开始记录' : '结束记录',
        menuTooltip: '更多首页操作',
        onPressed: ongoingEntries.isEmpty
            ? () => showStartTimeEntryDialog(context, day: now)
            : () => showFinishTimeEntryDialog(
                context,
                record: ongoingEntries.first,
              ),
        actions: mobileActions,
        onSelected: (_HomeMobileAction action) {
          switch (action) {
            case _HomeMobileAction.backfill:
              showBackfillTimeEntryDialog(context, day: now);
              return;
            case _HomeMobileAction.todo:
              openTodoEditor();
              return;
          }
        },
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      body: dashboard,
    );
  }
}

/// 首页卡片式工作台骨架。
class _HomeDashboard extends StatelessWidget {
  /// 实际可见卡片顺序。
  final List<HomeCardId> visibleCards;

  /// 卡片标识对应的界面内容。
  final Map<HomeCardId, Widget> cards;

  /// 打开卡片管理面板回调。
  final VoidCallback onManageCards;

  /// 滚动到底部时需要额外保留的安全间距。
  final double safeBottomPadding;

  /// 创建首页卡片式工作台。
  const _HomeDashboard({
    required this.visibleCards,
    required this.cards,
    required this.onManageCards,
    required this.safeBottomPadding,
  });

  /// 构建工作台工具栏、响应式网格与空状态。
  @override
  Widget build(BuildContext context) {
    // 当前是否减少界面动画。
    final bool reduceMotion = OmniMotion.reduce(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 扣除页面水平边距后的卡片网格宽度。
        final double contentWidth = constraints.maxWidth > 28
            ? constraints.maxWidth - 28
            : 0;
        // 当前是否使用窄视口单列布局。
        final bool compact = OmniBreakpoint.isCompact(constraints.maxWidth);
        // 当前是否使用十二栏宽屏布局。
        final bool wide = contentWidth >= 1180;
        // 卡片网格列数。
        final int columnCount = compact ? 1 : (wide ? 3 : 2);
        // 卡片间距。
        const double gap = OmniSpacing.xs;
        // 工具栏、上下边距与工具栏后间距占用的垂直空间。
        const double dashboardChromeHeight =
            OmniSpacing.xs + OmniSpacing.xl + OmniSize.control + OmniSpacing.xs;
        // 非移动布局中卡片网格至少填满的剩余视口高度。
        final double minimumGridHeight =
            !compact && constraints.hasBoundedHeight
            ? (constraints.maxHeight - dashboardChromeHeight)
                  .clamp(0, double.infinity)
                  .toDouble()
            : 0;
        // 单列可用宽度。
        final double columnWidth =
            ((contentWidth - (columnCount - 1) * gap) / columnCount)
                .floorToDouble();

        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(14, OmniSpacing.xs, 14, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _HomeDashboardToolbar(onManageCards: onManageCards),
              const SizedBox(height: OmniSpacing.xs),
              if (visibleCards.isEmpty)
                _EmptyHomeDashboard(onManageCards: onManageCards)
              else
                AnimatedSize(
                  duration: reduceMotion ? Duration.zero : OmniMotion.normal,
                  curve: OmniMotion.standardCurve,
                  alignment: Alignment.topLeft,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: minimumGridHeight),
                    child: _FillRemainingCardGrid(
                      gap: gap,
                      fillLastRow: !compact,
                      maxGridHeight:
                          compact ||
                              defaultTargetPlatform != TargetPlatform.windows
                          ? double.infinity
                          : minimumGridHeight,
                      children: _buildGridRows(
                        compact: compact,
                        columnCount: columnCount,
                        columnWidth: columnWidth,
                        gap: gap,
                      ),
                    ),
                  ),
                ),
              SizedBox(height: OmniSpacing.xl + safeBottomPadding),
            ],
          ),
        );
      },
    );
  }

  /// 按卡片顺序构建不会因浮点误差换行的显式网格行。
  List<Widget> _buildGridRows({
    required bool compact,
    required int columnCount,
    required double columnWidth,
    required double gap,
  }) {
    // 已完成的网格行。
    final List<List<HomeCardId>> rows = <List<HomeCardId>>[];
    // 当前正在填充的网格行。
    List<HomeCardId> currentRow = <HomeCardId>[];
    // 当前行已经使用的列数。
    int usedColumns = 0;
    for (final HomeCardId card in visibleCards) {
      // 当前卡片占用的列数。
      final int span = _cardSpan(card: card, compact: compact);
      if (currentRow.isNotEmpty && usedColumns + span > columnCount) {
        rows.add(currentRow);
        currentRow = <HomeCardId>[];
        usedColumns = 0;
      }
      currentRow.add(card);
      usedColumns += span;
    }
    if (currentRow.isNotEmpty) {
      rows.add(currentRow);
    }

    // 不含行间距的网格界面；统一由网格渲染对象添加间距。
    final List<Widget> gridRows = <Widget>[];
    for (int rowIndex = 0; rowIndex < rows.length; rowIndex += 1) {
      // 当前网格行的卡片。
      final List<HomeCardId> rowCards = rows[rowIndex];
      // 当前网格行界面；先测量最高卡片，再让同一行其余卡片填满高度。
      final Widget row = _EqualHeightCardRow(
        gap: gap,
        children: <Widget>[
          for (final HomeCardId card in rowCards)
            _buildCardBox(
              card: card,
              compact: compact,
              columnWidth: columnWidth,
              gap: gap,
              scrollable:
                  defaultTargetPlatform == TargetPlatform.windows &&
                  !compact &&
                  rowIndex == rows.length - 1,
            ),
        ],
      );
      gridRows.add(row);
    }
    return gridRows;
  }

  /// 构建带稳定宽高的单张首页卡片。
  Widget _buildCardBox({
    required HomeCardId card,
    required bool compact,
    required double columnWidth,
    required double gap,
    required bool scrollable,
  }) {
    // 当前卡片占用的列数。
    final int span = _cardSpan(card: card, compact: compact);
    // 当前卡片完整宽度。
    final double width = columnWidth * span + gap * (span - 1);
    // 最后一排卡片在 Windows 视口内独立滚动，避免内容继续撑高整张卡片。
    final Widget cardContent = scrollable
        ? _HomeCardScrollViewport(card: card, child: cards[card]!)
        : cards[card]!;
    return SizedBox(
      key: ValueKey<String>('home-dashboard-card-${card.name}'),
      width: width,
      height:
          !compact && (card == HomeCardId.quote || card == HomeCardId.dayRuler)
          ? 156
          : null,
      child: cardContent,
    );
  }

  /// 返回指定卡片在当前断点下占用的列数。
  int _cardSpan({required HomeCardId card, required bool compact}) {
    if (compact) {
      return 1;
    }
    if (card == HomeCardId.quote) {
      return 2;
    }
    return 1;
  }
}

/// Windows 首页最下一排卡片的独立滚动视口。
class _HomeCardScrollViewport extends StatefulWidget {
  /// 当前卡片标识。
  final HomeCardId card;

  /// 卡片完整内容。
  final Widget child;

  /// 创建卡片内滚动视口。
  const _HomeCardScrollViewport({required this.card, required this.child});

  /// 创建卡片内滚动状态。
  @override
  State<_HomeCardScrollViewport> createState() =>
      _HomeCardScrollViewportState();
}

/// 管理首页卡片自己的滚动位置。
class _HomeCardScrollViewportState extends State<_HomeCardScrollViewport> {
  /// 当前卡片专用滚动控制器，避免同排卡片争用主滚动控制器。
  final ScrollController _scrollController = ScrollController();

  /// 释放卡片滚动控制器。
  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 构建带细滚动条的卡片内视口。
  @override
  Widget build(BuildContext context) {
    return OmniPanelScrollScope(
      key: ValueKey<String>('home-card-scroll-${widget.card.name}'),
      controller: _scrollController,
      child: widget.child,
    );
  }
}

/// 在内容不足时让最后一排卡片填满网格剩余高度。
class _FillRemainingCardGrid extends MultiChildRenderObjectWidget {
  /// 相邻网格行间距。
  final double gap;

  /// 是否拉伸最后一排。
  final bool fillLastRow;

  /// 当前页面内卡片网格可占用的最大高度。
  final double maxGridHeight;

  /// 创建可填满剩余高度的首页网格。
  const _FillRemainingCardGrid({
    required this.gap,
    required this.fillLastRow,
    required this.maxGridHeight,
    required super.children,
  });

  /// 创建纵向网格渲染对象。
  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderFillRemainingCardGrid(gap, fillLastRow, maxGridHeight);
  }

  /// 更新网格间距与最后一排填充策略。
  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderFillRemainingCardGrid renderObject,
  ) {
    renderObject
      ..gap = gap
      ..fillLastRow = fillLastRow
      ..maxGridHeight = maxGridHeight;
  }
}

/// 可填满剩余高度网格的子元素布局数据。
class _FillRemainingCardGridParentData
    extends ContainerBoxParentData<RenderBox> {}

/// 先自然排列各行，再将视口剩余高度分配给最后一排。
class _RenderFillRemainingCardGrid extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _FillRemainingCardGridParentData>,
        RenderBoxContainerDefaultsMixin<
          RenderBox,
          _FillRemainingCardGridParentData
        > {
  /// 相邻网格行间距。
  double _gap;

  /// 是否拉伸最后一排。
  bool _fillLastRow;

  /// 当前页面内卡片网格可占用的最大高度。
  double _maxGridHeight;

  /// 创建可填满剩余高度的网格渲染对象。
  _RenderFillRemainingCardGrid(
    this._gap,
    this._fillLastRow,
    this._maxGridHeight,
  );

  /// 当前相邻网格行间距。
  double get gap => _gap;

  /// 更新相邻网格行间距并触发布局。
  set gap(double value) {
    if (_gap == value) {
      return;
    }
    _gap = value;
    markNeedsLayout();
  }

  /// 当前是否拉伸最后一排。
  bool get fillLastRow => _fillLastRow;

  /// 更新最后一排填充策略并触发布局。
  set fillLastRow(bool value) {
    if (_fillLastRow == value) {
      return;
    }
    _fillLastRow = value;
    markNeedsLayout();
  }

  /// 当前页面内卡片网格可占用的最大高度。
  double get maxGridHeight => _maxGridHeight;

  /// 更新卡片网格高度上限并触发布局。
  set maxGridHeight(double value) {
    if (_maxGridHeight == value) {
      return;
    }
    _maxGridHeight = value;
    markNeedsLayout();
  }

  /// 为每一排安装纵向偏移数据。
  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _FillRemainingCardGridParentData) {
      child.parentData = _FillRemainingCardGridParentData();
    }
  }

  /// 测量自然总高度并将不足部分补到最后一排。
  @override
  void performLayout() {
    if (childCount == 0) {
      size = constraints.constrain(Size.zero);
      return;
    }
    // 每一排使用的水平约束。
    final BoxConstraints rowConstraints = BoxConstraints(
      minWidth: constraints.minWidth,
      maxWidth: constraints.maxWidth,
    );
    // 所有网格行的自然总高度。
    double naturalHeight = gap * (childCount - 1);
    // 网格行中的最大自然宽度。
    double naturalWidth = 0;
    // 最后一排至少容纳固定卡头与一行内容，过矮时交给外层页面滚动。
    const double minimumLastRowHeight = 120;
    // 当前待测量网格行。
    RenderBox? child = firstChild;
    while (child != null) {
      // 最后一排从当前页面剩余空间中计算高度上限。
      final double remainingGridHeight = maxGridHeight - naturalHeight;
      // 剩余空间不足时，最后一排滚入视口；不把固定卡头压进几像素高度。
      final double lastRowHeightLimit =
          remainingGridHeight >= minimumLastRowHeight
          ? remainingGridHeight
          : maxGridHeight
                .clamp(minimumLastRowHeight, double.infinity)
                .toDouble();
      // 只有最后一排需要限制高度，其余排继续按自然高度参与页面滚动。
      final BoxConstraints effectiveRowConstraints = child == lastChild
          ? rowConstraints.copyWith(maxHeight: lastRowHeightLimit)
          : rowConstraints;
      child.layout(effectiveRowConstraints, parentUsesSize: true);
      naturalHeight += child.size.height;
      if (child.size.width > naturalWidth) {
        naturalWidth = child.size.width;
      }
      // 当前网格行布局数据。
      final _FillRemainingCardGridParentData parentData =
          child.parentData! as _FillRemainingCardGridParentData;
      child = parentData.nextSibling;
    }
    // 网格受父级最小高度约束后的目标总高度。
    final double targetHeight = constraints.constrainHeight(naturalHeight);
    // 最后一排需要额外吸收的剩余高度。
    final double remainingHeight = fillLastRow
        ? targetHeight - naturalHeight
        : 0;
    if (remainingHeight > 0 && lastChild != null) {
      // 最后一排扩展后的目标高度。
      final double lastRowHeight = (lastChild!.size.height + remainingHeight)
          .clamp(0, maxGridHeight)
          .toDouble();
      lastChild!.layout(
        BoxConstraints(
          minWidth: constraints.minWidth,
          maxWidth: constraints.maxWidth,
          minHeight: lastRowHeight,
          maxHeight: lastRowHeight,
        ),
        parentUsesSize: true,
      );
    }
    // 下一排起始纵坐标。
    double offsetY = 0;
    child = firstChild;
    while (child != null) {
      // 当前网格行布局数据。
      final _FillRemainingCardGridParentData parentData =
          child.parentData! as _FillRemainingCardGridParentData;
      parentData.offset = Offset(0, offsetY);
      offsetY += child.size.height + gap;
      child = parentData.nextSibling;
    }
    size = constraints.constrain(Size(naturalWidth, targetHeight));
  }

  /// 按纵向偏移绘制全部网格行。
  @override
  void paint(PaintingContext context, Offset offset) {
    defaultPaint(context, offset);
  }

  /// 将点击命中转发给对应网格行。
  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    return defaultHitTestChildren(result, position: position);
  }
}

/// 让同一网格行中的卡片以最高内容为准填满高度。
class _EqualHeightCardRow extends MultiChildRenderObjectWidget {
  /// 相邻卡片间距。
  final double gap;

  /// 创建等高卡片行。
  const _EqualHeightCardRow({required this.gap, required super.children});

  /// 创建两阶段测量的等高行渲染对象。
  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderEqualHeightCardRow(gap: gap);
  }

  /// 更新卡片间距。
  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderEqualHeightCardRow renderObject,
  ) {
    renderObject.gap = gap;
  }
}

/// 等高卡片行的子元素布局数据。
class _EqualHeightCardRowParentData extends ContainerBoxParentData<RenderBox> {}

/// 先自然测量再按最大高度重排的卡片行渲染对象。
class _RenderEqualHeightCardRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _EqualHeightCardRowParentData>,
        RenderBoxContainerDefaultsMixin<
          RenderBox,
          _EqualHeightCardRowParentData
        > {
  /// 相邻卡片间距。
  double _gap;

  /// 创建等高卡片行渲染对象。
  _RenderEqualHeightCardRow({required this._gap});

  /// 当前相邻卡片间距。
  double get gap => _gap;

  /// 更新相邻卡片间距并触发布局。
  set gap(double value) {
    if (_gap == value) {
      return;
    }
    _gap = value;
    markNeedsLayout();
  }

  /// 为卡片子元素安装行内偏移数据。
  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _EqualHeightCardRowParentData) {
      child.parentData = _EqualHeightCardRowParentData();
    }
  }

  /// 测量每张卡片的自然高度并按最大值重新布局。
  @override
  void performLayout() {
    // 首轮自然测量使用的宽松高度约束。
    final BoxConstraints naturalConstraints = BoxConstraints(
      maxWidth: constraints.maxWidth,
    );
    // 当前行自然内容总宽度。
    double totalWidth = 0;
    // 当前行自然内容最大高度。
    double maxHeight = 0;
    // 当前待测量子卡片。
    RenderBox? child = firstChild;
    while (child != null) {
      child.layout(naturalConstraints, parentUsesSize: true);
      // 当前卡片基于真实内容计算的最大固有高度。
      final double intrinsicHeight = child.getMaxIntrinsicHeight(
        child.size.width,
      );
      // 当前卡片用于等高比较的可靠高度。
      final double naturalHeight = intrinsicHeight > child.size.height
          ? intrinsicHeight
          : child.size.height;
      totalWidth += child.size.width;
      if (naturalHeight > maxHeight) {
        maxHeight = naturalHeight;
      }
      // 当前卡片布局数据。
      final _EqualHeightCardRowParentData parentData =
          child.parentData! as _EqualHeightCardRowParentData;
      child = parentData.nextSibling;
    }
    if (childCount > 1) {
      totalWidth += gap * (childCount - 1);
    }
    // 受父布局约束后的整行尺寸。
    final Size rowSize = constraints.constrain(Size(totalWidth, maxHeight));
    // 当前卡片的水平偏移。
    double offsetX = 0;
    child = firstChild;
    while (child != null) {
      // 当前卡片在首轮测量得到的宽度。
      final double childWidth = child.size.width;
      child.layout(
        BoxConstraints.tightFor(width: childWidth, height: rowSize.height),
        parentUsesSize: true,
      );
      // 当前卡片布局数据。
      final _EqualHeightCardRowParentData parentData =
          child.parentData! as _EqualHeightCardRowParentData;
      parentData.offset = Offset(offsetX, 0);
      offsetX += childWidth + gap;
      child = parentData.nextSibling;
    }
    size = rowSize;
  }

  /// 按行内偏移绘制全部卡片。
  @override
  void paint(PaintingContext context, Offset offset) {
    defaultPaint(context, offset);
  }

  /// 将点击命中转发给对应卡片。
  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    return defaultHitTestChildren(result, position: position);
  }
}

/// 首页工作台工具栏。
class _HomeDashboardToolbar extends StatelessWidget {
  /// 打开卡片管理面板回调。
  final VoidCallback onManageCards;

  /// 创建首页工作台工具栏。
  const _HomeDashboardToolbar({required this.onManageCards});

  /// 构建工作台名称与管理入口。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return SizedBox(
      height: OmniSize.control,
      child: Row(
        children: <Widget>[
          Icon(Icons.dashboard_customize_outlined, color: colors.muted),
          const SizedBox(width: OmniSpacing.xs),
          Expanded(
            child: Text('今日工作台', style: Theme.of(context).textTheme.labelLarge),
          ),
          OmniButton(
            label: '管理卡片',
            icon: Icons.tune_rounded,
            variant: OmniButtonVariant.secondary,
            onPressed: onManageCards,
          ),
        ],
      ),
    );
  }
}

/// 首页没有任何实际可见卡片时的空状态。
class _EmptyHomeDashboard extends StatelessWidget {
  /// 打开卡片管理面板回调。
  final VoidCallback onManageCards;

  /// 创建首页工作台空状态。
  const _EmptyHomeDashboard({required this.onManageCards});

  /// 构建添加卡片引导。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return OmniPanel(
      key: const ValueKey<String>('home-dashboard-empty'),
      padding: const EdgeInsets.symmetric(vertical: 72, horizontal: 24),
      child: Column(
        children: <Widget>[
          Icon(
            Icons.dashboard_customize_outlined,
            size: 42,
            color: colors.muted,
          ),
          const SizedBox(height: OmniSpacing.md),
          Text('首页还没有卡片', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: OmniSpacing.xs),
          Text('添加你每天最想先看到的内容。', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: OmniSpacing.lg),
          OmniButton(
            label: '添加卡片',
            icon: Icons.add_rounded,
            onPressed: onManageCards,
          ),
        ],
      ),
    );
  }
}

/// 每日名言横幅。
class _QuoteHero extends ConsumerWidget {
  /// 今日名言异步状态。
  final AsyncValue<QuoteRecord?> quoteAsync;

  /// 手动换一条回调。
  final Future<void> Function() onChange;

  /// 打开名言库回调。
  final VoidCallback onManage;

  /// 管理横幅背景回调。
  final VoidCallback onBackground;

  /// 是否使用桌面分栏中的紧凑样式。
  final bool dense;

  /// 创建每日名言横幅。
  const _QuoteHero({
    required this.quoteAsync,
    required this.onChange,
    required this.onManage,
    required this.onBackground,
    this.dense = false,
  });

  /// 构建具有时间流动感的名言区域。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前横幅附件。
    final Attachment? banner = ref
        .watch(
          currentAttachmentProvider((
            AttachmentBusinessType.quoteBanner,
            'home-banner',
          )),
        )
        .asData
        ?.value;
    // 当前可读本地背景路径。
    final String? backgroundPath = banner?.localPath;
    // 当前名言内容。
    final Widget quoteContent = quoteAsync.when(
      data: (QuoteRecord? quote) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            quote == null ? '暂无可用名言，可在名言库中添加' : '“${quote.content}”',
            maxLines: dense ? 2 : null,
            overflow: dense ? TextOverflow.ellipsis : TextOverflow.visible,
            style: TextStyle(
              color: colors.heroInk,
              fontSize: dense ? 18 : 20,
              height: dense ? 1.35 : 1.45,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: dense ? 2 : OmniSpacing.sm),
          Text(
            quote == null ? '' : '— ${quote.source ?? '未署名'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: TextStyle(
              color: colors.heroInk.withValues(alpha: 0.84),
              fontSize: dense ? 12 : 13,
            ),
          ),
        ],
      ),
      loading: () => LinearProgressIndicator(
        color: colors.heroInk,
        backgroundColor: colors.heroInk.withValues(alpha: 0.15),
      ),
      error: (Object error, StackTrace stackTrace) =>
          Text('名言暂时无法读取', style: TextStyle(color: colors.heroInk)),
    );

    return Container(
      key: const ValueKey<String>('home-quote-card'),
      constraints: BoxConstraints(minHeight: dense ? 0 : 156),
      padding: dense
          ? const EdgeInsets.fromLTRB(18, 12, 12, 12)
          : const EdgeInsets.all(OmniSpacing.lg),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[colors.heroStart, colors.heroEnd],
        ),
        borderRadius: BorderRadius.circular(OmniRadius.dialog),
        border: Border.all(color: colors.brand.withValues(alpha: 0.24)),
        image: backgroundPath == null
            ? null
            : DecorationImage(
                image: FileImage(File(backgroundPath)),
                fit: BoxFit.cover,
                colorFilter: ColorFilter.mode(
                  Colors.black.withValues(alpha: 0.42),
                  BlendMode.darken,
                ),
                onError: (_, _) {},
              ),
      ),
      child: Stack(
        children: <Widget>[
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Spacer(),
                  OmniIconButton(
                    tooltip: '名言库',
                    onPressed: onManage,
                    color: colors.heroInk,
                    icon: const Icon(Icons.library_books_outlined),
                  ),
                  OmniIconButton(
                    tooltip: '设置横幅背景',
                    onPressed: onBackground,
                    color: colors.heroInk,
                    constraints: dense
                        ? const BoxConstraints.tightFor(width: 32, height: 32)
                        : null,
                    padding: dense ? EdgeInsets.zero : null,
                    visualDensity: dense ? VisualDensity.compact : null,
                    icon: const Icon(Icons.wallpaper_rounded),
                  ),
                  OmniIconButton(
                    tooltip: '换一条',
                    onPressed: onChange,
                    color: colors.heroInk,
                    constraints: dense
                        ? const BoxConstraints.tightFor(width: 32, height: 32)
                        : null,
                    padding: dense ? EdgeInsets.zero : null,
                    visualDensity: dense ? VisualDensity.compact : null,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
              SizedBox(height: dense ? 4 : OmniSpacing.md),
              quoteContent,
            ],
          ),
        ],
      ),
    );
  }
}

/// 当日真实时间刻度。
class _DayRuler extends StatelessWidget {
  /// 当前时间。
  final DateTime now;

  /// 创建当日时间刻度。
  const _DayRuler({required this.now});

  /// 构建日期、大号当前时刻和当天已过去比例。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 今日自然日。
    final DateTime today = DateUtils.dateOnly(now);
    // 星期中文名称。
    final String weekday = const <String>[
      '星期一',
      '星期二',
      '星期三',
      '星期四',
      '星期五',
      '星期六',
      '星期日',
    ][today.weekday - 1];
    // 今日完整日期标签。
    final String dateLabel =
        '${DateFormat('yyyy年M月d日').format(today)} · $weekday';
    // 今日已经过去的分钟数。
    final int elapsedMinutes = now.hour * 60 + now.minute;
    // 今日时间进度。
    final double progress = elapsedMinutes / 1440;

    return OmniPanel(
      key: const ValueKey<String>('home-day-ruler'),
      padding: const EdgeInsets.all(OmniSpacing.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: colors.brandSoft,
                  borderRadius: BorderRadius.circular(OmniRadius.control),
                ),
                child: Icon(
                  Icons.schedule_rounded,
                  color: colors.brand,
                  size: OmniSize.icon,
                ),
              ),
              const SizedBox(width: OmniSpacing.xs),
              Expanded(
                child: Text(
                  '今日刻度',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              Text(
                '${(progress * 100).round()}% 已经过',
                style: TextStyle(color: colors.muted, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: OmniSpacing.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Expanded(
                child: Text(
                  DateFormat('HH:mm').format(now),
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    color: colors.brand,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  dateLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: OmniSpacing.xs),
          ClipRRect(
            borderRadius: BorderRadius.circular(OmniRadius.tiny),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 7,
              color: colors.accent,
              backgroundColor: colors.mist,
            ),
          ),
          const SizedBox(height: OmniSpacing.xxs),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text('00:00', style: Theme.of(context).textTheme.bodySmall),
              Text('24:00', style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ],
      ),
    );
  }
}

/// 今日待办摘要卡。
class _TodayTodoCard extends StatefulWidget {
  /// 今日待办树异步状态。
  final AsyncValue<List<TodoTreeNode>> todoTreesAsync;

  /// 今日仍有未完成内容的待办树。
  final List<TodoTreeNode> pendingTodoTrees;

  /// 新增回调。
  final VoidCallback onCreate;

  /// 执行指定待办的菜单操作。
  final Future<bool> Function(TodoRecord todo, _HomeTodoAction action) onAction;

  /// 完成状态变化回调。
  final Future<void> Function(TodoRecord todo, bool value) onToggle;

  /// 创建今日待办摘要卡。
  const _TodayTodoCard({
    required this.todoTreesAsync,
    required this.pendingTodoTrees,
    required this.onCreate,
    required this.onAction,
    required this.onToggle,
  });

  /// 创建今日待办摘要卡状态。
  @override
  State<_TodayTodoCard> createState() => _TodayTodoCardState();
}

/// 今日待办摘要卡状态。
class _TodayTodoCardState extends State<_TodayTodoCard> {
  /// 首页展示的三个重点待办象限。
  static const List<TodoPriorityQuadrant> _focusQuadrants =
      <TodoPriorityQuadrant>[
        TodoPriorityQuadrant.urgentImportant,
        TodoPriorityQuadrant.importantNotUrgent,
        TodoPriorityQuadrant.urgentNotImportant,
      ];

  /// 当前撤销浮动消息。
  OmniMessageHandle? _undoMessage;

  /// 当前手动展开子任务的父任务标识，未操作的任务默认折叠。
  final Set<String> _expandedTreeIds = <String>{};

  /// 新增子任务保存成功后展开父任务，让新内容立即可见。
  Future<bool> _handleAction(TodoRecord todo, _HomeTodoAction action) async {
    // 弹窗返回的保存结果。
    final bool saved = await widget.onAction(todo, action);
    if (saved && mounted && action == _HomeTodoAction.addChild) {
      setState(() => _expandedTreeIds.add(todo.id));
    }
    return saved;
  }

  /// 切换指定父任务的子任务展开状态。
  void _toggleTree(String rootId) {
    setState(() {
      if (!_expandedTreeIds.remove(rootId)) {
        _expandedTreeIds.add(rootId);
      }
    });
  }

  /// 根据当前整体状态收起或展开全部可见子任务。
  void _toggleAllTrees(Set<String> expandableTreeIds, bool allCollapsed) {
    setState(() {
      if (allCollapsed) {
        _expandedTreeIds.addAll(expandableTreeIds);
      } else {
        _expandedTreeIds.removeAll(expandableTreeIds);
      }
    });
  }

  /// 返回首页实际展示且包含未完成子任务的父任务标识。
  Set<String> _visibleExpandableTreeIds() {
    // 每个重点象限已经选入首页的父任务数量。
    final Map<TodoPriorityQuadrant, int> visibleCounts =
        <TodoPriorityQuadrant, int>{
          for (final TodoPriorityQuadrant quadrant in _focusQuadrants)
            quadrant: 0,
        };
    // 最终可以批量展开或折叠的父任务标识。
    final Set<String> expandableTreeIds = <String>{};
    for (final TodoTreeNode tree in widget.pendingTodoTrees) {
      // 当前待办树所属象限。
      final TodoPriorityQuadrant quadrant = TodoPriorityQuadrant.fromValue(
        tree.root.priorityQuadrant,
      );
      // 当前象限已经选入的父任务数量。
      final int? visibleCount = visibleCounts[quadrant];
      if (visibleCount == null || visibleCount >= 3) {
        continue;
      }
      visibleCounts[quadrant] = visibleCount + 1;
      if (tree.children.any((TodoRecord child) => !child.isCompleted)) {
        expandableTreeIds.add(tree.root.id);
      }
    }
    return expandableTreeIds;
  }

  /// 完成任务并展示顶部浮动撤销消息。
  Future<void> _completeTodo(TodoRecord todo) async {
    await widget.onToggle(todo, true);
    if (!mounted) {
      return;
    }
    _undoMessage?.dismiss();
    _undoMessage = showOmniMessage(
      context,
      message: '已完成“${todo.title}”',
      tone: OmniMessageTone.success,
      duration: const Duration(seconds: 6),
      actionLabel: '撤销',
      onAction: () => unawaited(widget.onToggle(todo, false)),
      onDismissed: () => _undoMessage = null,
    );
  }

  /// 释放撤销浮动消息。
  @override
  void dispose() {
    _undoMessage?.dismiss();
    super.dispose();
  }

  /// 构建今日优先待办。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前是否使用 Android 紧凑首页。
    final bool androidCompact =
        Theme.of(context).platform == TargetPlatform.android &&
        OmniBreakpoint.isCompact(MediaQuery.sizeOf(context).width);
    // 首页可见且含有未完成子任务的父任务标识。
    final Set<String> expandableTreeIds = _visibleExpandableTreeIds();
    // 当前是否已收起全部可见子任务。
    final bool allTreesCollapsed =
        expandableTreeIds.isNotEmpty &&
        expandableTreeIds.every((String id) => !_expandedTreeIds.contains(id));
    // 待办列表或状态内容。
    final Widget todoContent = _buildTodoContent(context, colors);
    return OmniPanel(
      key: const ValueKey<String>('home-todo-card'),
      padding: const EdgeInsets.fromLTRB(
        OmniSpacing.md,
        0,
        OmniSpacing.md,
        OmniSpacing.md,
      ),
      header: Padding(
        key: const ValueKey<String>('home-todo-header'),
        padding: const EdgeInsets.fromLTRB(
          OmniSpacing.md,
          OmniSpacing.md,
          OmniSpacing.md,
          OmniSpacing.xs,
        ),
        child: Row(
          children: <Widget>[
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: colors.todo.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(OmniRadius.control),
              ),
              child: Icon(
                Icons.check_circle_outline_rounded,
                color: colors.todo,
                size: 19,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '今日待办',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (androidCompact)
              SizedBox.square(
                dimension: 30,
                child: OmniIconButton(
                  key: const ValueKey<String>('home-todo-toggle-all'),
                  tooltip: allTreesCollapsed ? '展开全部子任务' : '收起全部子任务',
                  onPressed: expandableTreeIds.isEmpty
                      ? null
                      : () => _toggleAllTrees(
                          expandableTreeIds,
                          allTreesCollapsed,
                        ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 30,
                    height: 30,
                  ),
                  icon: Icon(
                    allTreesCollapsed
                        ? Icons.unfold_more_rounded
                        : Icons.unfold_less_rounded,
                    size: 18,
                  ),
                ),
              )
            else
              SizedBox(
                key: const ValueKey<String>('home-todo-create-button'),
                height: 30,
                child: OmniButton(
                  label: '新增',
                  icon: Icons.add_rounded,
                  onPressed: widget.onCreate,
                ),
              ),
          ],
        ),
      ),
      child: KeyedSubtree(
        key: const ValueKey<String>('home-todo-content'),
        child: todoContent,
      ),
    );
  }

  /// 构建待办列表、加载状态或空状态。
  Widget _buildTodoContent(BuildContext context, OmniColors colors) {
    if (widget.todoTreesAsync.isLoading) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (widget.todoTreesAsync.hasError) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text('待办暂时无法读取', style: TextStyle(color: colors.danger)),
      );
    }
    // 按重点区间分组后的今日待办树。
    final Map<TodoPriorityQuadrant, List<TodoTreeNode>> groupedTodoTrees =
        <TodoPriorityQuadrant, List<TodoTreeNode>>{
          for (final TodoPriorityQuadrant quadrant in _focusQuadrants)
            quadrant: <TodoTreeNode>[],
        };
    for (final TodoTreeNode tree in widget.pendingTodoTrees) {
      // 当前待办树所属象限。
      final TodoPriorityQuadrant quadrant = TodoPriorityQuadrant.fromValue(
        tree.root.priorityQuadrant,
      );
      groupedTodoTrees[quadrant]?.add(tree);
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (
          int index = 0;
          index < _focusQuadrants.length;
          index += 1
        ) ...<Widget>[
          _HomeTodoQuadrant(
            quadrant: _focusQuadrants[index],
            todoTrees: groupedTodoTrees[_focusQuadrants[index]]!,
            expandedTreeIds: _expandedTreeIds,
            onToggleTree: _toggleTree,
            onAction: _handleAction,
            onToggle: (TodoRecord todo, bool value) =>
                value ? _completeTodo(todo) : widget.onToggle(todo, false),
          ),
        ],
      ],
    );
  }
}

/// 首页今日待办卡中的单个象限摘要。
class _HomeTodoQuadrant extends StatelessWidget {
  /// 当前象限。
  final TodoPriorityQuadrant quadrant;

  /// 当前象限全部未完成待办树。
  final List<TodoTreeNode> todoTrees;

  /// 当前手动展开子任务的父任务标识，未操作的任务默认折叠。
  final Set<String> expandedTreeIds;

  /// 切换指定父任务子任务展开状态的回调。
  final ValueChanged<String> onToggleTree;

  /// 执行指定待办的菜单操作。
  final Future<bool> Function(TodoRecord todo, _HomeTodoAction action) onAction;

  /// 完成状态变化回调。
  final Future<void> Function(TodoRecord todo, bool value) onToggle;

  /// 创建首页象限摘要。
  const _HomeTodoQuadrant({
    required this.quadrant,
    required this.todoTrees,
    required this.expandedTreeIds,
    required this.onToggleTree,
    required this.onAction,
    required this.onToggle,
  });

  /// 按共享任务流的用户排序展示当前象限的全部任务。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前象限用于轻量分区的语义色。
    final Color accentColor = quadrant.color(colors);
    // 当前象限任务内容。
    final Widget todoContent = todoTrees.isEmpty
        ? _buildEmptyState(context)
        : _buildTodoTreeList(context);

    return Column(
      key: ValueKey<String>('home-todo-quadrant-${quadrant.value}'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: OmniSpacing.sm),
          child: Row(
            children: <Widget>[
              Text(
                quadrant.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: accentColor, fontWeight: FontWeight.w500),
              ),
              const SizedBox(width: OmniSpacing.xs),
              Expanded(child: Divider(color: accentColor)),
            ],
          ),
        ),
        todoContent,
      ],
    );
  }

  /// 构建当前象限的任务列表。
  Widget _buildTodoTreeList(BuildContext context) {
    // 带分隔线的任务树列表内容。
    final List<Widget> children = <Widget>[];
    // 当前根任务在用户排序中的位置。
    for (int index = 0; index < todoTrees.length; index += 1) {
      if (index > 0) {
        children.add(const Divider(indent: 28));
      }
      // 当前任务树。
      final TodoTreeNode tree = todoTrees[index];
      children.add(
        _HomeTodoTree(
          key: ValueKey<String>('home-todo-tree-${tree.root.id}'),
          tree: tree,
          accentColor: quadrant.color(OmniColors.of(context)),
          childrenExpanded: expandedTreeIds.contains(tree.root.id),
          onToggleChildren: () => onToggleTree(tree.root.id),
          onAction: onAction,
          onComplete: (TodoRecord todo) => onToggle(todo, true),
        ),
      );
    }
    return Column(mainAxisSize: MainAxisSize.min, children: children);
  }

  /// 构建当前象限的紧凑空状态。
  Widget _buildEmptyState(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(27, OmniSpacing.xs, 0, OmniSpacing.sm),
      child: Text('暂无任务', style: TextStyle(color: colors.muted)),
    );
  }
}

/// 首页中的单棵两层待办树。
class _HomeTodoTree extends StatelessWidget {
  /// 当前待办树。
  final TodoTreeNode tree;

  /// 当前任务所属象限强调色。
  final Color accentColor;

  /// 子任务当前是否展开。
  final bool childrenExpanded;

  /// 切换子任务展开状态的回调。
  final VoidCallback onToggleChildren;

  /// 执行指定待办的菜单操作。
  final Future<bool> Function(TodoRecord todo, _HomeTodoAction action) onAction;

  /// 完成任务回调。
  final Future<void> Function(TodoRecord todo) onComplete;

  /// 创建首页待办树。
  const _HomeTodoTree({
    required this.tree,
    required this.accentColor,
    required this.childrenExpanded,
    required this.onToggleChildren,
    required this.onAction,
    required this.onComplete,
    super.key,
  });

  /// 父任务勾选框中心对应的树形主干横坐标。
  static const double _treeTrunkX = OmniSpacing.xs + 16;

  /// 子任务相对任务树左侧的缩进。
  static const double _childIndent = _treeTrunkX + OmniSpacing.xxs;

  /// 子任务支线停在勾选框左侧的横坐标。
  static const double _branchEndX = _childIndent + OmniSpacing.xs + 7;

  /// 构建父任务、展开控制与直属子任务。
  @override
  Widget build(BuildContext context) {
    // 当前仍未完成的直属子任务。
    final List<TodoRecord> pendingChildren = tree.children
        .where((TodoRecord child) => !child.isCompleted)
        .toList(growable: false);
    // 当前任务树是否存在需要展示的子任务。
    final bool hasChildren = pendingChildren.isNotEmpty;
    // 当前是否关闭非必要动画。
    final bool disableAnimations = OmniMotion.reduce(context);
    // 子任务展开收起动画时长。
    final Duration duration = disableAnimations
        ? Duration.zero
        : OmniMotion.normal;
    // 父任务行；展开控制收纳在行尾，确保勾选框始终位于最左侧。
    final Widget rootRow = _HomeTodoRow(
      key: ValueKey<String>('home-todo-row-${tree.root.id}'),
      todo: tree.root,
      accentColor: accentColor,
      onAction: onAction,
      onComplete: onComplete,
      childrenExpanded: hasChildren ? childrenExpanded : null,
      onToggleChildren: hasChildren ? onToggleChildren : null,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        rootRow,
        AnimatedSize(
          alignment: Alignment.topCenter,
          duration: duration,
          curve: OmniMotion.standardCurve,
          child: childrenExpanded && hasChildren
              ? Column(
                  key: ValueKey<String>(
                    'home-todo-tree-children-${tree.root.id}',
                  ),
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    for (
                      int index = 0;
                      index < pendingChildren.length;
                      index += 1
                    )
                      CustomPaint(
                        key: ValueKey<String>(
                          'home-todo-tree-branch-${pendingChildren[index].id}',
                        ),
                        painter: _HomeTodoTreeBranchPainter(
                          lineColor: OmniColors.of(context).muted
                              .withValues(alpha: 0.46),
                          trunkX: _treeTrunkX,
                          branchEndX: _branchEndX,
                          isLast: index == pendingChildren.length - 1,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.only(left: _childIndent),
                          child: _HomeTodoRow(
                            key: ValueKey<String>(
                              'home-todo-row-${pendingChildren[index].id}',
                            ),
                            todo: pendingChildren[index],
                            accentColor: accentColor,
                            onAction: onAction,
                            onComplete: onComplete,
                          ),
                        ),
                      ),
                  ],
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// 绘制首页父子任务之间的竖向主干与圆角支线。
class _HomeTodoTreeBranchPainter extends CustomPainter {
  /// 树线颜色。
  final Color lineColor;

  /// 父任务勾选框中心对应的主干横坐标。
  final double trunkX;

  /// 子任务支线结束横坐标。
  final double branchEndX;

  /// 当前子任务是否为最后一项。
  final bool isLast;

  /// 创建首页待办树引导线绘制器。
  const _HomeTodoTreeBranchPainter({
    required this.lineColor,
    required this.trunkX,
    required this.branchEndX,
    required this.isLast,
  });

  /// 绘制连续主干和指向子任务的圆角支线。
  @override
  void paint(Canvas canvas, Size size) {
    // 当前子任务行的垂直中心。
    final double branchY = size.height / 2;
    // 树线画笔。
    final Paint linePaint = Paint()
      ..color = lineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.25
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (!isLast) {
      canvas
        ..drawLine(Offset(trunkX, 0), Offset(trunkX, size.height), linePaint)
        ..drawLine(
          Offset(trunkX, branchY),
          Offset(branchEndX, branchY),
          linePaint,
        );
      return;
    }
    // 最后一条支线的圆角半径。
    final double cornerRadius = branchY < OmniSpacing.xs
        ? branchY
        : OmniSpacing.xs;
    // 最后一条支线的圆角路径。
    final Path branchPath = Path()
      ..moveTo(trunkX, 0)
      ..lineTo(trunkX, branchY - cornerRadius)
      ..quadraticBezierTo(trunkX, branchY, trunkX + cornerRadius, branchY)
      ..lineTo(branchEndX, branchY);
    canvas.drawPath(branchPath, linePaint);
  }

  /// 仅在线条几何或颜色变化时重绘。
  @override
  bool shouldRepaint(covariant _HomeTodoTreeBranchPainter oldDelegate) {
    return oldDelegate.lineColor != lineColor ||
        oldDelegate.trunkX != trunkX ||
        oldDelegate.branchEndX != branchEndX ||
        oldDelegate.isLast != isLast;
  }
}

/// 首页任务完成时的分阶段反馈行。
class _HomeTodoRow extends StatefulWidget {
  /// 当前任务。
  final TodoRecord todo;

  /// 当前任务所属象限强调色。
  final Color accentColor;

  /// 执行当前任务的菜单操作。
  final Future<bool> Function(TodoRecord todo, _HomeTodoAction action) onAction;

  /// 完成动画结束后的提交回调。
  final Future<void> Function(TodoRecord todo) onComplete;

  /// 可选子任务展开状态；为空表示当前任务没有子任务。
  final bool? childrenExpanded;

  /// 可选子任务展开状态切换回调。
  final VoidCallback? onToggleChildren;

  /// 创建首页任务反馈行。
  const _HomeTodoRow({
    required this.todo,
    required this.accentColor,
    required this.onAction,
    required this.onComplete,
    this.childrenExpanded,
    this.onToggleChildren,
    super.key,
  });

  /// 创建首页任务反馈行状态。
  @override
  State<_HomeTodoRow> createState() => _HomeTodoRowState();
}

/// 首页任务反馈行状态。
class _HomeTodoRowState extends State<_HomeTodoRow> {
  /// 是否已经呈现勾选状态。
  bool _checked = false;

  /// 是否已经进入淡出阶段。
  bool _fading = false;

  /// 是否已经进入收起阶段。
  bool _collapsed = false;

  /// 是否正在提交完成操作。
  bool _submitting = false;

  /// 鼠标当前是否悬停在整行任务上。
  bool _hovered = false;

  /// 鼠标当前是否悬停在勾选框热区上。
  bool _checkboxHovered = false;

  /// 勾选框当前是否获得键盘焦点。
  bool _checkboxFocused = false;

  /// 菜单或其弹窗正在处理，防止同一行重复打开。
  bool _menuOpen = false;

  /// 在鼠标或长按位置显示任务操作菜单。
  Future<void> _showContextMenu(Offset globalPosition) async {
    if (_submitting || _menuOpen) {
      return;
    }
    _menuOpen = true;
    try {
      // 菜单所在导航覆盖层及指针在其内部的位置。
      final RenderBox overlay =
          Navigator.of(context).overlay!.context.findRenderObject()!
              as RenderBox;
      // 转换坐标以兼容卡片内部滚动与窗口缩放。
      final Offset position = overlay.globalToLocal(globalPosition);
      // 用户选中的任务操作，关闭菜单时为空。
      final _HomeTodoAction? action = await showMenu<_HomeTodoAction>(
        context: context,
        popUpAnimationStyle: OmniMotion.reduce(context)
            ? AnimationStyle.noAnimation
            : const AnimationStyle(
                duration: OmniMotion.fast,
                reverseDuration: OmniMotion.fast,
                curve: OmniMotion.standardCurve,
                reverseCurve: Curves.easeInCubic,
              ),
        position: RelativeRect.fromRect(
          position & Size.zero,
          Offset.zero & overlay.size,
        ),
        menuPadding: const EdgeInsets.all(OmniSpacing.xxs),
        items: <PopupMenuEntry<_HomeTodoAction>>[
          OmniPopupMenuItem<_HomeTodoAction>(
            value: _HomeTodoAction.edit,
            label: '编辑任务',
            icon: Icons.edit_outlined,
          ),
          OmniPopupMenuItem<_HomeTodoAction>(
            value: _HomeTodoAction.addChild,
            label: '添加子任务',
            icon: Icons.subdirectory_arrow_right_rounded,
            enabled: widget.todo.parentId == null,
          ),
          OmniPopupMenuItem<_HomeTodoAction>(
            value: _HomeTodoAction.delete,
            label: '删除任务',
            icon: Icons.delete_outline_rounded,
            danger: true,
          ),
        ],
      );
      if (action != null && mounted && !_submitting) {
        await widget.onAction(widget.todo, action);
      }
    } finally {
      _menuOpen = false;
    }
  }

  /// 更新整行任务的悬停状态。
  void _setHovered(bool hovered) {
    if (_hovered == hovered) {
      return;
    }
    setState(() => _hovered = hovered);
  }

  /// 更新勾选框热区的悬停状态。
  void _setCheckboxHovered(bool hovered) {
    if (_checkboxHovered == hovered) {
      return;
    }
    setState(() => _checkboxHovered = hovered);
  }

  /// 更新勾选框的键盘焦点状态。
  void _setCheckboxFocused(bool focused) {
    if (_checkboxFocused == focused) {
      return;
    }
    setState(() => _checkboxFocused = focused);
  }

  /// 依次播放勾选、淡出与收起动画，再提交完成状态。
  Future<void> _complete() async {
    if (_submitting) {
      return;
    }
    // 点击时确定的任务与提交回调，不能被后续重建或页面销毁改变。
    final TodoRecord todo = widget.todo;
    // 回调已捕获业务仓储，不依赖销毁后的 WidgetRef。
    final Future<void> Function(TodoRecord) onComplete = widget.onComplete;
    try {
      await _animateCompletion();
      // 动画可因切页提前结束，但用户确认的业务操作必须继续提交。
      await onComplete(todo);
    } catch (error) {
      if (mounted) {
        setState(() {
          _checked = false;
          _fading = false;
          _collapsed = false;
          _submitting = false;
        });
        showOmniMessage(
          context,
          message: error is FormatException ? error.message : '完成失败，请重试',
          tone: OmniMessageTone.error,
        );
      }
    }
  }

  /// 仅控制视觉反馈；页面销毁只结束动画，不取消完成操作。
  Future<void> _animateCompletion() async {
    // 当前是否关闭非必要动画。
    final bool disableAnimations = OmniMotion.reduce(context);
    // 勾选反馈停留时长。
    final Duration checkDuration = disableAnimations
        ? Duration.zero
        : OmniMotion.normal;
    // 淡出反馈时长。
    final Duration fadeDuration = disableAnimations
        ? Duration.zero
        : OmniMotion.normal;
    // 高度收起时长。
    final Duration collapseDuration = disableAnimations
        ? Duration.zero
        : OmniMotion.panel;
    setState(() {
      _submitting = true;
      _checked = true;
    });
    await Future<void>.delayed(checkDuration);
    if (!mounted) {
      return;
    }
    setState(() => _fading = true);
    await Future<void>.delayed(fadeDuration);
    if (!mounted) {
      return;
    }
    setState(() => _collapsed = true);
    await Future<void>.delayed(collapseDuration);
  }

  /// 构建带完成反馈的任务行。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前是否关闭非必要动画。
    final bool disableAnimations = OmniMotion.reduce(context);
    // 当前淡出动画时长。
    final Duration fadeDuration = disableAnimations
        ? Duration.zero
        : OmniMotion.normal;
    // 当前收起动画时长。
    final Duration collapseDuration = disableAnimations
        ? Duration.zero
        : OmniMotion.panel;
    // 当前任务紧凑的截止时间文字。
    final String? dueLabel = widget.todo.dueAt == null
        ? null
        : _formatHomeTodoDueAt(widget.todo);
    // 所有平台的左键点击只切换子任务，完成中的任务不再响应展开。
    final VoidCallback? onTitleTap = _submitting
        ? null
        : widget.onToggleChildren;

    if (widget.todo.taskType == 'progress') {
      return AnimatedSize(
        duration: collapseDuration,
        curve: OmniMotion.standardCurve,
        child: _collapsed
            ? const SizedBox.shrink()
            : AnimatedOpacity(
                opacity: _fading ? 0 : 1,
                duration: fadeDuration,
                child: IgnorePointer(
                  ignoring: _submitting,
                  child: TodoProgressTaskTile(
                    todo: widget.todo,
                    compact: true,
                    onEdit: () => unawaited(
                      widget.onAction(widget.todo, _HomeTodoAction.edit),
                    ),
                    onDelete: () => unawaited(
                      widget.onAction(widget.todo, _HomeTodoAction.delete),
                    ),
                    onConfirm: () => unawaited(_complete()),
                  ),
                ),
              ),
      );
    }

    return AnimatedSize(
      duration: collapseDuration,
      curve: OmniMotion.standardCurve,
      alignment: Alignment.topCenter,
      child: _collapsed
          ? const SizedBox.shrink()
          : AnimatedSlide(
              offset: _fading ? const Offset(0.04, 0) : Offset.zero,
              duration: fadeDuration,
              curve: OmniMotion.standardCurve,
              child: AnimatedOpacity(
                opacity: _fading ? 0 : 1,
                duration: fadeDuration,
                curve: OmniMotion.standardCurve,
                child: MouseRegion(
                  onEnter: (_) => _setHovered(true),
                  onExit: (_) => _setHovered(false),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onTitleTap,
                    onSecondaryTapUp: (TapUpDetails details) =>
                        unawaited(_showContextMenu(details.globalPosition)),
                    onLongPressStart: (LongPressStartDetails details) =>
                        unawaited(_showContextMenu(details.globalPosition)),
                    child: AnimatedContainer(
                      key: ValueKey<String>(
                        'home-todo-hover-${widget.todo.id}',
                      ),
                      duration: disableAnimations
                          ? Duration.zero
                          : OmniMotion.fast,
                      curve: OmniMotion.standardCurve,
                      decoration: BoxDecoration(
                        color: _hovered
                            ? colors.ink.withValues(alpha: 0.06)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(OmniRadius.control),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: OmniSpacing.xs,
                          vertical: OmniSpacing.xxs,
                        ),
                        child: Row(
                          children: <Widget>[
                            Material(
                              color: Colors.transparent,
                              child: InkWell(
                                key: ValueKey<String>(
                                  'home-todo-checkbox-action-${widget.todo.id}',
                                ),
                                onTap: _submitting
                                    ? null
                                    : () => unawaited(_complete()),
                                onHover: _setCheckboxHovered,
                                onFocusChange: _setCheckboxFocused,
                                borderRadius: BorderRadius.circular(
                                  OmniRadius.control,
                                ),
                                hoverColor: Colors.transparent,
                                focusColor: Colors.transparent,
                                splashColor: Colors.transparent,
                                highlightColor: Colors.transparent,
                                child: SizedBox(
                                  key: ValueKey<String>(
                                    'home-todo-checkbox-${widget.todo.id}',
                                  ),
                                  width: 32,
                                  height: 32,
                                  child: Center(
                                    child: _HomeTodoCheckIndicator(
                                      checked: _checked,
                                      highlighted:
                                          _checkboxHovered || _checkboxFocused,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: OmniSpacing.xxs),
                            Expanded(
                              child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  key: ValueKey<String>(
                                    'home-todo-title-action-${widget.todo.id}',
                                  ),
                                  onTap: onTitleTap,
                                  borderRadius: BorderRadius.circular(
                                    OmniRadius.control,
                                  ),
                                  hoverColor: Colors.transparent,
                                  focusColor: colors.brandSoft,
                                  child: SizedBox(
                                    height: 32,
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: AnimatedDefaultTextStyle(
                                        duration: disableAnimations
                                            ? Duration.zero
                                            : OmniMotion.fast,
                                        curve: OmniMotion.standardCurve,
                                        // 动画样式替换默认文字样式时保留平台字体与排版。
                                        style: DefaultTextStyle.of(context)
                                            .style
                                            .copyWith(
                                              color: _checked
                                                  ? colors.muted
                                                  : colors.ink,
                                              fontWeight: FontWeight.w400,
                                              decoration: _checked
                                                  ? TextDecoration.lineThrough
                                                  : TextDecoration.none,
                                            ),
                                        child: Text(
                                          widget.todo.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            if (dueLabel != null) ...<Widget>[
                              const SizedBox(width: OmniSpacing.xs),
                              Text(
                                dueLabel,
                                key: ValueKey<String>(
                                  'home-todo-due-${widget.todo.id}',
                                ),
                                maxLines: 1,
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(color: colors.muted),
                              ),
                            ],
                            if (widget.onToggleChildren != null) ...<Widget>[
                              const SizedBox(width: OmniSpacing.xxs),
                              SizedBox.square(
                                dimension: 28,
                                child: OmniIconButton(
                                  key: ValueKey<String>(
                                    'home-todo-tree-toggle-${widget.todo.id}',
                                  ),
                                  tooltip: widget.childrenExpanded ?? false
                                      ? '收起子任务'
                                      : '展开子任务',
                                  onPressed: onTitleTap,
                                  hoverColor: Colors.transparent,
                                  style: const ButtonStyle(
                                    backgroundColor:
                                        WidgetStatePropertyAll<Color>(
                                          Colors.transparent,
                                        ),
                                  ),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints.tightFor(
                                    width: 28,
                                    height: 28,
                                  ),
                                  icon: Icon(
                                    widget.childrenExpanded ?? false
                                        ? Icons.expand_more_rounded
                                        : Icons.chevron_right_rounded,
                                    color: colors.muted,
                                    size: 18,
                                  ),
                                ),
                              ),
                            ],
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

  /// 将首页任务截止时间格式化为紧凑文本。
  String _formatHomeTodoDueAt(TodoRecord todo) {
    // 当前任务截止时间。
    final DateTime dueAt = todo.dueAt!;
    if (DateUtils.isSameDay(dueAt, todo.scheduledDate)) {
      return DateFormat('HH:mm').format(dueAt);
    }
    return DateFormat('M月d日 HH:mm').format(dueAt);
  }
}

/// 首页任务的统一勾选反馈，完成流程继续由任务行控制。
class _HomeTodoCheckIndicator extends StatelessWidget {
  /// 是否处于完成状态。
  final bool checked;

  /// 是否处于悬停或键盘焦点状态。
  final bool highlighted;

  /// 创建首页任务勾选反馈。
  const _HomeTodoCheckIndicator({
    required this.checked,
    required this.highlighted,
  });

  /// 构建统一方框与无弹跳勾线，不改变任务完成等待时序。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 两项系统无障碍偏好共同决定颜色与透明度过渡时长。
    final Duration duration = OmniMotion.duration(context, OmniMotion.fast);
    return AnimatedContainer(
      width: Checkbox.width,
      height: Checkbox.width,
      duration: duration,
      curve: OmniMotion.standardCurve,
      decoration: BoxDecoration(
        color: checked ? colors.brand : colors.paper,
        borderRadius: BorderRadius.circular(OmniRadius.tiny),
        border: Border.all(
          color: checked || highlighted ? colors.brand : colors.muted,
          width: 1.5,
        ),
      ),
      child: AnimatedOpacity(
        key: const ValueKey<String>('home-todo-check-mark'),
        opacity: checked ? 1 : 0,
        duration: duration,
        curve: OmniMotion.standardCurve,
        child: Icon(Icons.check_rounded, size: 14, color: colors.accentInk),
      ),
    );
  }
}
