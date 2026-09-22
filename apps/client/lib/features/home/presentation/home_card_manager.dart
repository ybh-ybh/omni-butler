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

/// 显示首页卡片管理侧滑面板。
Future<void> showHomeCardManager(BuildContext context) {
  return showOmniSideSheet<void>(
    context,
    desktopWidth: 360,
    builder: (BuildContext sheetContext) => const _HomeCardManagerSheet(),
  );
}

/// 首页卡片管理侧滑面板。
class _HomeCardManagerSheet extends ConsumerWidget {
  /// 创建首页卡片管理侧滑面板。
  const _HomeCardManagerSheet();

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
    // 尚未添加到首页的卡片。
    final List<HomeCardId> availableCards = HomeCardId.values
        .where((HomeCardId card) => !cardPreference.contains(card))
        .toList(growable: false);

    return OmniSideSheetScaffold(
      title: '管理卡片',
      child: CustomScrollView(
        slivers: <Widget>[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              OmniSpacing.md,
              OmniSpacing.md,
              OmniSpacing.md,
              OmniSpacing.xs,
            ),
            sliver: SliverToBoxAdapter(
              child: Text(
                '拖动调整顺序，修改会立即保存到当前设备。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.md),
            sliver: SliverToBoxAdapter(
              child: _SectionLabel(
                label: '已添加',
                count: cardPreference.orderedCards.length,
              ),
            ),
          ),
          if (cardPreference.orderedCards.isEmpty)
            const SliverPadding(
              padding: EdgeInsets.all(OmniSpacing.md),
              sliver: SliverToBoxAdapter(child: Text('还没有添加卡片，可以从下方选择。')),
            )
          else
            SliverReorderableList(
              itemCount: cardPreference.orderedCards.length,
              onReorderItem: (int oldIndex, int newIndex) => ref
                  .read(homeCardPreferenceProvider.notifier)
                  .reorder(oldIndex, newIndex),
              itemBuilder: (BuildContext context, int index) {
                // 当前已添加卡片。
                final HomeCardId card = cardPreference.orderedCards[index];
                // 当前卡片不可用的原因。
                final String? unavailableReason = homeCardUnavailableReason(
                  card,
                  featurePreference,
                );
                return _CardManagerRow(
                  key: ValueKey<String>('home-card-manager-${card.name}'),
                  card: card,
                  subtitle: unavailableReason ?? card.description,
                  enabled: unavailableReason == null,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      IconButton(
                        tooltip: '移除${card.label}',
                        onPressed: () => ref
                            .read(homeCardPreferenceProvider.notifier)
                            .setVisible(card, false),
                        icon: const Icon(Icons.remove_circle_outline_rounded),
                      ),
                      _KeyboardReorderHandle(
                        index: index,
                        itemCount: cardPreference.orderedCards.length,
                        label: card.label,
                        color: colors.muted,
                        onReorder: ref
                            .read(homeCardPreferenceProvider.notifier)
                            .reorder,
                      ),
                    ],
                  ),
                );
              },
            ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              OmniSpacing.md,
              OmniSpacing.lg,
              OmniSpacing.md,
              0,
            ),
            sliver: SliverToBoxAdapter(
              child: _SectionLabel(label: '可添加', count: availableCards.length),
            ),
          ),
          if (availableCards.isEmpty)
            const SliverPadding(
              padding: EdgeInsets.all(OmniSpacing.md),
              sliver: SliverToBoxAdapter(child: Text('所有卡片都已添加。')),
            )
          else
            SliverList.builder(
              itemCount: availableCards.length,
              itemBuilder: (BuildContext context, int index) {
                // 当前可添加卡片。
                final HomeCardId card = availableCards[index];
                // 当前卡片是否满足功能依赖。
                final bool enabled = isHomeCardAvailable(
                  card,
                  featurePreference,
                );
                // 当前卡片不可用的原因。
                final String? unavailableReason = homeCardUnavailableReason(
                  card,
                  featurePreference,
                );
                return _CardManagerRow(
                  card: card,
                  subtitle: unavailableReason ?? card.description,
                  enabled: enabled,
                  trailing: IconButton(
                    tooltip: enabled ? '添加${card.label}' : '需要先开启相关功能',
                    onPressed: enabled
                        ? () => ref
                              .read(homeCardPreferenceProvider.notifier)
                              .setVisible(card, true)
                        : null,
                    icon: const Icon(Icons.add_circle_outline_rounded),
                  ),
                );
              },
            ),
          SliverPadding(
            padding: const EdgeInsets.all(OmniSpacing.md),
            sliver: SliverToBoxAdapter(
              child: Container(
                padding: const EdgeInsets.all(OmniSpacing.sm),
                decoration: BoxDecoration(
                  color: colors.brandSoft,
                  borderRadius: BorderRadius.circular(OmniRadius.panel),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(
                      Icons.info_outline_rounded,
                      color: colors.brand,
                      size: OmniSize.icon,
                    ),
                    const SizedBox(width: OmniSpacing.xs),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Text('功能关闭后，相关卡片会暂时隐藏。'),
                          TextButton(
                            onPressed: () {
                              Navigator.of(context).pop();
                              context.go('/settings');
                            },
                            child: const Text('前往功能管理'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
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

  /// 创建卡片管理行。
  const _CardManagerRow({
    required this.card,
    required this.subtitle,
    required this.enabled,
    required this.trailing,
    super.key,
  });

  /// 构建卡片图标、名称、说明和操作。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.md),
      child: OmniListRow(
        leading: Container(
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
        ),
        title: Text(card.label),
        subtitle: Text(
          subtitle,
          style: TextStyle(color: enabled ? colors.muted : colors.warning),
        ),
        trailing: trailing,
      ),
    );
  }
}
