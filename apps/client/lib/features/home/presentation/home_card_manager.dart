import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/features/home/data/home_card_preferences.dart';
import 'package:omni_butler/features/home/presentation/home_card_catalog.dart';
import 'package:omni_butler/features/settings/data/feature_preferences.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 显示首页空态使用的卡片管理侧滑面板。
Future<void> showHomeCardManager(BuildContext context) {
  // 以首页视口判定移动模式，避免桌面侧栏宽度影响布局选择。
  final bool mobileLayout =
      Theme.of(context).platform == TargetPlatform.android &&
      OmniBreakpoint.isCompact(MediaQuery.sizeOf(context).width);
  return showOmniSideSheet<void>(
    context,
    desktopWidth: 360,
    builder: (BuildContext sheetContext) => OmniSideSheetScaffold(
      title: mobileLayout ? '首页设置' : '管理卡片',
      child: HomeCardManagerContent(
        mobileLayout: mobileLayout,
        onOpenFeatures: () {
          Navigator.of(sheetContext).pop();
          context.go('/settings');
        },
      ),
    ),
  );
}

/// 设置详情和首页空态共用的卡片管理正文。
class HomeCardManagerContent extends ConsumerWidget {
  /// 是否使用安卓紧凑首页的横幅与内容模块设置。
  final bool mobileLayout;

  /// 切换到功能管理的回调，由宿主处理返回或分类切换。
  final VoidCallback onOpenFeatures;

  /// 创建首页卡片管理正文。
  const HomeCardManagerContent({
    required this.mobileLayout,
    required this.onOpenFeatures,
    super.key,
  });

  /// 构建已添加卡片、可添加卡片和功能提示。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前首页卡片偏好。
    final HomeCardPreference cardPreference = ref.watch(
      homeCardPreferenceProvider,
    );
    // 当前业务功能偏好。
    final FeaturePreference featurePreference = ref.watch(
      featurePreferenceProvider,
    );
    // 当前界面参与增删排序的卡片，移动端名言独立管理。
    final List<HomeCardId> managedCards = HomeCardId.values
        .where((HomeCardId card) => !mobileLayout || card != HomeCardId.quote)
        .toList(growable: false);
    // 保留完整偏好顺序的已添加内容，功能关闭时仍可管理。
    final List<HomeCardId> addedCards = cardPreference.orderedCards
        .where((HomeCardId card) => managedCards.contains(card))
        .toList(growable: false);
    // 尚未添加到首页的卡片。
    final List<HomeCardId> availableCards = managedCards
        .where((HomeCardId card) => !cardPreference.contains(card))
        .toList(growable: false);
    // 当前界面索引对应的持久化排序入口。
    final Future<void> Function(int oldIndex, int newIndex) reorderCards =
        mobileLayout
        ? ref.read(homeCardPreferenceProvider.notifier).reorderContentCards
        : ref.read(homeCardPreferenceProvider.notifier).reorder;

    /// 构建已添加卡片，移动列表在行间插入同通知设置一致的分隔线。
    Widget buildAddedCard(BuildContext context, int index) {
      // 当前已添加卡片。
      final HomeCardId card = addedCards[index];
      // 当前卡片不可用的原因。
      final String? unavailableReason = homeCardUnavailableReason(
        card,
        featurePreference,
      );
      return Column(
        key: ValueKey<String>('home-card-manager-${card.name}'),
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (mobileLayout && index > 0) Divider(color: colors.line),
          _CardManagerRow(
            card: card,
            subtitle: unavailableReason ?? card.description,
            enabled: unavailableReason == null,
            showIcon: !mobileLayout,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                OmniIconButton(
                  tooltip: '移除${card.label}',
                  onPressed: () => ref
                      .read(homeCardPreferenceProvider.notifier)
                      .setVisible(card, false),
                  icon: const Icon(Icons.remove_circle_outline_rounded),
                ),
                _KeyboardReorderHandle(
                  index: index,
                  itemCount: addedCards.length,
                  label: card.label,
                  color: colors.muted,
                  onReorder: reorderCards,
                ),
              ],
            ),
          ),
        ],
      );
    }

    /// 构建可添加卡片，功能依赖沿用原来的禁用条件。
    Widget buildAvailableCard(BuildContext context, int index) {
      // 当前可添加卡片。
      final HomeCardId card = availableCards[index];
      // 当前卡片是否满足功能依赖。
      final bool enabled = isHomeCardAvailable(card, featurePreference);
      return _CardManagerRow(
        key: ValueKey<String>('home-card-available-${card.name}'),
        card: card,
        subtitle:
            homeCardUnavailableReason(card, featurePreference) ??
            card.description,
        enabled: enabled,
        showIcon: !mobileLayout,
        trailing: OmniIconButton(
          tooltip: enabled ? '添加${card.label}' : '需要先开启相关功能',
          onPressed: enabled
              ? () => ref
                    .read(homeCardPreferenceProvider.notifier)
                    .setVisible(card, true)
              : null,
          icon: const Icon(Icons.add_circle_outline_rounded),
        ),
      );
    }

    return CustomScrollView(
      key: const ValueKey<String>('home-card-manager-content'),
      slivers: <Widget>[
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            OmniSpacing.md,
            mobileLayout ? OmniSpacing.xl : OmniSpacing.md,
            OmniSpacing.md,
            OmniSpacing.xxl,
          ),
          sliver: SliverMainAxisGroup(
            slivers: <Widget>[
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (mobileLayout) ...<Widget>[
                      Row(
                        children: <Widget>[
                          Icon(
                            Icons.dashboard_customize_outlined,
                            color: colors.brand,
                            size: OmniSize.icon,
                          ),
                          const SizedBox(width: OmniSpacing.xs),
                          Text(
                            '首页内容',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ],
                      ),
                      const SizedBox(height: OmniSpacing.xxs),
                    ],
                    Text(
                      mobileLayout
                          ? '名言固定在顶部，内容模块可拖动排序。修改会立即保存到当前设备。'
                          : '拖动调整顺序，修改会立即保存到当前设备。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: OmniSpacing.xs),
                    if (mobileLayout) ...<Widget>[
                      const _SectionLabel(label: '顶部横幅', count: 1),
                      const SizedBox(height: OmniSpacing.xs),
                      OmniListPanel(
                        key: const ValueKey<String>(
                          'home-settings-banner-panel',
                        ),
                        children: <Widget>[
                          _CardManagerRow(
                            key: const ValueKey<String>('home-settings-quote'),
                            card: HomeCardId.quote,
                            subtitle: '固定显示在内容模块上方',
                            enabled: true,
                            showIcon: false,
                            trailing: Semantics(
                              label: '显示每日名言',
                              child: OmniSwitch(
                                key: const ValueKey<String>(
                                  'home-settings-quote-switch',
                                ),
                                value: cardPreference.contains(
                                  HomeCardId.quote,
                                ),
                                onChanged: (bool visible) => ref
                                    .read(homeCardPreferenceProvider.notifier)
                                    .setVisible(HomeCardId.quote, visible),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: OmniSpacing.lg),
                    ],
                    _SectionLabel(
                      label: mobileLayout ? '已添加模块' : '已添加',
                      count: addedCards.length,
                    ),
                    const SizedBox(height: OmniSpacing.xs),
                  ],
                ),
              ),
              if (addedCards.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(OmniSpacing.md),
                    child: Text(
                      mobileLayout ? '还没有添加内容模块，可以从下方选择。' : '还没有添加卡片，可以从下方选择。',
                    ),
                  ),
                )
              else if (mobileLayout)
                SliverToBoxAdapter(
                  child: OmniPanel(
                    key: const ValueKey<String>('home-settings-added-panel'),
                    padding: EdgeInsets.zero,
                    child: ReorderableListView.builder(
                      shrinkWrap: true,
                      primary: false,
                      physics: const NeverScrollableScrollPhysics(),
                      buildDefaultDragHandles: false,
                      itemCount: addedCards.length,
                      onReorderItem: reorderCards,
                      itemBuilder: buildAddedCard,
                    ),
                  ),
                )
              else
                SliverReorderableList(
                  itemCount: addedCards.length,
                  onReorderItem: reorderCards,
                  itemBuilder: buildAddedCard,
                ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(
                    top: OmniSpacing.lg,
                    bottom: OmniSpacing.xs,
                  ),
                  child: _SectionLabel(
                    label: mobileLayout ? '可添加模块' : '可添加',
                    count: availableCards.length,
                  ),
                ),
              ),
              if (availableCards.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(OmniSpacing.md),
                    child: Text(mobileLayout ? '所有内容模块都已添加。' : '所有卡片都已添加。'),
                  ),
                )
              else if (mobileLayout)
                SliverToBoxAdapter(
                  child: OmniListPanel(
                    key: const ValueKey<String>(
                      'home-settings-available-panel',
                    ),
                    children: <Widget>[
                      // 按目录顺序呈现每个可添加模块。
                      for (
                        int index = 0;
                        index < availableCards.length;
                        index += 1
                      )
                        buildAvailableCard(context, index),
                    ],
                  ),
                )
              else
                SliverList.builder(
                  itemCount: availableCards.length,
                  itemBuilder: buildAvailableCard,
                ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: OmniSpacing.md),
                  child: OmniListPanel(
                    children: <Widget>[
                      OmniListRow(
                        leading: Icon(
                          Icons.info_outline_rounded,
                          color: colors.brand,
                          size: OmniSize.icon,
                        ),
                        title: Text(
                          mobileLayout
                              ? '功能关闭后，相关内容模块会暂时隐藏，原有顺序会保留。'
                              : '功能关闭后，相关卡片会暂时隐藏。',
                        ),
                        subtitle: Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            onPressed: onOpenFeatures,
                            child: const Text('前往功能管理'),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 通过方向键移动卡片的排序意图。
class _MoveHomeCardIntent extends Intent {
  /// 相对当前位置的移动量。
  final int offset;

  /// 创建首页卡片移动意图。
  const _MoveHomeCardIntent(this.offset);
}

/// 同时支持鼠标拖拽和键盘方向键的排序手柄。
class _KeyboardReorderHandle extends StatefulWidget {
  /// 当前卡片索引。
  final int index;

  /// 已添加卡片总数。
  final int itemCount;

  /// 当前卡片名称。
  final String label;

  /// 手柄图标颜色。
  final Color color;

  /// 排序回调。
  final Future<void> Function(int oldIndex, int newIndex) onReorder;

  /// 创建可聚焦排序手柄。
  const _KeyboardReorderHandle({
    required this.index,
    required this.itemCount,
    required this.label,
    required this.color,
    required this.onReorder,
  });

  /// 创建排序手柄状态。
  @override
  State<_KeyboardReorderHandle> createState() => _KeyboardReorderHandleState();
}

/// 可聚焦排序手柄状态。
class _KeyboardReorderHandleState extends State<_KeyboardReorderHandle> {
  /// 当前是否显示键盘焦点。
  bool _showFocus = false;

  /// 按给定偏移移动当前卡片。
  Future<void> _move(int offset) async {
    // 移动后的目标索引。
    final int targetIndex = widget.index + offset;
    if (targetIndex < 0 || targetIndex >= widget.itemCount) {
      return;
    }
    await widget.onReorder(widget.index, targetIndex);
  }

  /// 构建拖拽手柄和上下方向键快捷操作。
  @override
  Widget build(BuildContext context) {
    // 排序方向键映射。
    const Map<ShortcutActivator, Intent> shortcuts =
        <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.arrowUp): _MoveHomeCardIntent(-1),
          SingleActivator(LogicalKeyboardKey.arrowDown): _MoveHomeCardIntent(1),
        };
    // 排序意图处理器。
    final Map<Type, Action<Intent>> actions = <Type, Action<Intent>>{
      _MoveHomeCardIntent: CallbackAction<_MoveHomeCardIntent>(
        onInvoke: (_MoveHomeCardIntent intent) => _move(intent.offset),
      ),
    };
    return FocusableActionDetector(
      shortcuts: shortcuts,
      actions: actions,
      onShowFocusHighlight: (bool value) {
        if (_showFocus != value) {
          setState(() => _showFocus = value);
        }
      },
      child: Semantics(
        button: true,
        label: '${widget.label}排序手柄，按上下方向键调整',
        child: ReorderableDragStartListener(
          index: widget.index,
          child: MouseRegion(
            cursor: SystemMouseCursors.grab,
            child: Container(
              key: ValueKey<String>(
                'home-card-reorder-${widget.label}-${widget.index}',
              ),
              constraints: BoxConstraints(
                minWidth: OmniDensity.controlHeight(context, large: true),
                minHeight: OmniDensity.controlHeight(context, large: true),
              ),
              padding: const EdgeInsets.all(OmniSpacing.xs),
              decoration: BoxDecoration(
                border: Border.all(
                  color: _showFocus ? widget.color : Colors.transparent,
                ),
                borderRadius: BorderRadius.circular(OmniRadius.control),
              ),
              child: Icon(Icons.drag_indicator_rounded, color: widget.color),
            ),
          ),
        ),
      ),
    );
  }
}

/// 卡片管理区域标题。
class _SectionLabel extends StatelessWidget {
  /// 区域名称。
  final String label;

  /// 当前区域数量。
  final int count;

  /// 创建卡片管理区域标题。
  const _SectionLabel({required this.label, required this.count});

  /// 构建名称与数量。
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: OmniSpacing.xs),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.titleSmall),
          ),
          Text('$count', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// 卡片管理器中的单张卡片行。
class _CardManagerRow extends StatelessWidget {
  /// 当前卡片。
  final HomeCardId card;

  /// 当前说明文字。
  final String subtitle;

  /// 当前卡片是否满足功能依赖。
  final bool enabled;

  /// 右侧操作区。
  final Widget trailing;

  /// 桌面保留卡片图标，移动设置采用同通知设置一致的文字行。
  final bool showIcon;

  /// 创建卡片管理行。
  const _CardManagerRow({
    required this.card,
    required this.subtitle,
    required this.enabled,
    required this.trailing,
    this.showIcon = true,
    super.key,
  });

  /// 构建卡片图标、名称、说明和操作。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return OmniListRow(
      leading: showIcon
          ? Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: enabled ? colors.brandSoft : colors.paperSubtle,
                borderRadius: BorderRadius.circular(OmniRadius.control),
              ),
              child: Icon(
                card.icon,
                color: enabled ? colors.brand : colors.muted,
                size: OmniSize.navigationIcon,
              ),
            )
          : null,
      title: Text(card.label),
      subtitle: Text(
        subtitle,
        style: TextStyle(color: enabled ? colors.muted : colors.warning),
      ),
      trailing: trailing,
    );
  }
}
