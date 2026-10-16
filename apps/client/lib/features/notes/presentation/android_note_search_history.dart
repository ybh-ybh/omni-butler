part of 'android_notes_view.dart';

/// 搜索入口共用紧凑视觉和至少48dp的触控热区。
class _AndroidSearchChip extends StatelessWidget {
  /// 可提交的完整关键词或快捷条件名称。
  final String label;

  /// 快捷条件图标，历史词条没有图标。
  final IconData? icon;

  /// 快捷条件是否已经应用。
  final bool selected;

  /// 由搜索页提交查询或切换条件。
  final VoidCallback onTap;

  /// 创建自适应字号的触控入口。
  const _AndroidSearchChip({
    required this.label,
    required this.onTap,
    this.icon,
    this.selected = false,
    super.key,
  });

  /// 垂直4dp透明热区包裹40dp视觉，换行不额外增加行间距。
  @override
  Widget build(BuildContext context) {
    // 颜色始终跟随应用主题。
    final OmniColors colors = OmniColors.of(context);
    return Semantics(
      button: true,
      selected: selected,
      child: OmniInkWell(
        borderRadius: BorderRadius.circular(OmniRadius.control),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: OmniSpacing.xxs),
          child: Container(
            constraints: const BoxConstraints(minHeight: OmniSize.controlLarge),
            padding: const EdgeInsets.symmetric(
              horizontal: OmniSpacing.sm,
              vertical: OmniSpacing.xs,
            ),
            decoration: BoxDecoration(
              color: selected ? colors.brandSoft : colors.mist,
              borderRadius: BorderRadius.circular(OmniRadius.control),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: OmniSize.icon, color: colors.ink),
                  const SizedBox(width: OmniSpacing.xxs),
                ],
                Flexible(
                  child: Text(label, style: TextStyle(color: colors.ink)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 空关键词时展示本机历史，清空不改变搜索框或已应用条件。
class _AndroidSearchHistory extends ConsumerWidget {
  /// 点击历史词立即按当前筛选查询。
  final ValueChanged<String> onSelected;

  /// 将历史提交交给搜索页统一处理。
  const _AndroidSearchHistory({required this.onSelected});

  /// 历史为空时不保留标题或区块间距。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 服务提供已去重且最多五条的持久化历史。
    final List<String> history = ref.watch(noteSearchHistoryProvider);
    if (history.isEmpty) return const SizedBox.shrink();
    return Padding(
      key: const ValueKey('android-search-history'),
      padding: const EdgeInsets.only(top: OmniSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '最近搜索',
                  style: Theme.of(context).textTheme.titleSmall
                      ?.copyWith(color: OmniColors.of(context).muted),
                ),
              ),
              OmniIconButton(
                tooltip: '清空最近搜索',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => unawaited(
                  ref.read(noteSearchHistoryProvider.notifier).clear(),
                ),
              ),
            ],
          ),
          Wrap(
            spacing: OmniSpacing.xs,
            children: [
              // 完整词条自然换行，不截断实际提交内容。
              for (final String query in history)
                _AndroidSearchChip(
                  key: ValueKey('android-search-history-$query'),
                  label: query,
                  onTap: () => onSelected(query),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
