import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/settings/data/recycle_bin_repository.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 分业务显示的回收站，集中管理异步操作与错误状态。
class RecycleBinSection extends ConsumerStatefulWidget {
  /// 创建回收站内容。
  const RecycleBinSection({super.key});

  /// 创建回收站交互状态。
  @override
  ConsumerState<RecycleBinSection> createState() => _RecycleBinSectionState();
}

/// 一次只接受一个恢复或删除请求，确认弹窗期间也阻止重复触发。
class _RecycleBinSectionState extends ConsumerState<RecycleBinSection> {
  /// 当前操作标识，包含业务类型避免跨业务主键冲突。
  String? _operation;

  /// 最近一次失败，持续显示直到重试成功或开始新操作。
  String? _error;

  /// 当前操作是否已进入数据库提交阶段。
  bool _submitting = false;

  /// 构建说明、全局操作和六类业务列表。
  @override
  Widget build(BuildContext context) {
    // 当前回收站查询状态。
    final AsyncValue<List<RecycleBinItem>> items = ref.watch(
      recycleBinItemsProvider,
    );
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 安卓说明与清空操作分行，桌面保留原有紧凑操作条。
    final bool android = Theme.of(context).platform == TargetPlatform.android;
    // 保留期说明单独布局，不挤占清空操作所在行。
    final Widget retentionNotice = Text(
      '删除的数据保留 30 天，超过保留期自动永久删除',
      key: const ValueKey<String>('recycle-retention-notice'),
      style: Theme.of(context).textTheme.bodySmall,
    );
    // 全局清空沿用原确认、加载与禁用边界。
    final Widget clearButton = OmniButton(
      key: const ValueKey<String>('recycle-empty'),
      label: '一键清空',
      compact: true,
      variant: OmniButtonVariant.danger,
      loading: _operation == 'empty' && _submitting,
      onPressed:
          _operation != null ||
              !items.hasValue ||
              items.hasError ||
              items.isLoading ||
              items.value!.isEmpty
          ? null
          : _empty,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (android) ...<Widget>[
          retentionNotice,
          const SizedBox(height: OmniSpacing.xs),
          Align(alignment: Alignment.centerRight, child: clearButton),
        ] else
          Wrap(
            spacing: OmniSpacing.md,
            runSpacing: OmniSpacing.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [retentionNotice, clearButton],
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: OmniSpacing.xs),
            child: Text(
              _error!,
              key: const ValueKey<String>('recycle-operation-error'),
              style: TextStyle(color: colors.danger),
            ),
          ),
        const SizedBox(height: OmniSpacing.lg),
        items.when(
          data: (List<RecycleBinItem> records) {
            if (records.isEmpty) {
              return const OmniListPanel(
                children: [
                  OmniListRow(title: Text('回收站为空'), subtitle: Text('暂无已删除的数据')),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final RecycleEntityType type in RecycleEntityType.values)
                  if (records.any((RecycleBinItem item) => item.type == type))
                    _group(
                      type,
                      records
                          .where((RecycleBinItem item) => item.type == type)
                          .toList(),
                    ),
              ],
            );
          },
          loading: () => const OmniListPanel(
            children: [
              OmniListRow(
                title: Text('正在读取回收站'),
                trailing: SizedBox.square(
                  dimension: OmniSize.icon,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ],
          ),
          error: (Object error, StackTrace stackTrace) => OmniListPanel(
            children: [
              OmniListRow(
                title: const Text('回收站读取失败'),
                subtitle: Text(
                  error.toString(),
                  style: TextStyle(color: colors.danger),
                ),
                trailing: OmniButton(
                  label: '重试',
                  variant: OmniButtonVariant.text,
                  onPressed: () => ref.invalidate(recycleBinItemsProvider),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 每类业务使用独立标题和连续列表面板。
  Widget _group(RecycleEntityType type, List<RecycleBinItem> records) {
    return Padding(
      key: ValueKey<String>('recycle-group-${type.name}'),
      padding: const EdgeInsets.only(bottom: OmniSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                _icon(type),
                size: OmniSize.icon,
                color: OmniColors.of(context).brand,
              ),
              const SizedBox(width: OmniSpacing.xs),
              Text(
                _label(type),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(width: OmniSpacing.xs),
              OmniTag(label: '${records.length}', compact: true),
            ],
          ),
          const SizedBox(height: OmniSpacing.xs),
          OmniListPanel(
            children: [for (final RecycleBinItem item in records) _row(item)],
          ),
        ],
      ),
    );
  }

  /// 窄屏把操作放在内容下方，避免标题被行尾按钮挤出视口。
  Widget _row(RecycleBinItem item) {
    // 当前记录独立的操作标识。
    final String identity = '${item.type.name}-${item.id}';
    // 安卓窄屏的行内操作在说明下方靠右排列。
    final bool android = Theme.of(context).platform == TargetPlatform.android;
    // 本行按钮，触控热区由公共组件保证。
    final Widget actions = Wrap(
      alignment: android ? WrapAlignment.end : WrapAlignment.start,
      spacing: OmniSpacing.xs,
      runSpacing: OmniSpacing.xxs,
      children: [
        OmniButton(
          key: ValueKey<String>('recycle-restore-$identity'),
          label: '恢复',
          compact: true,
          variant: OmniButtonVariant.text,
          loading: _operation == 'restore-$identity' && _submitting,
          onPressed: _operation == null ? () => _restore(item) : null,
        ),
        OmniButton(
          key: ValueKey<String>('recycle-delete-$identity'),
          label: '永久删除',
          compact: true,
          variant: OmniButtonVariant.danger,
          loading: _operation == 'delete-$identity' && _submitting,
          onPressed: _operation == null ? () => _delete(item) : null,
        ),
      ],
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 实际列表行宽度决定排列，窄桌面窗口仍使用桌面控件密度。
        final bool stacked = constraints.maxWidth < 480;
        return OmniListRow(
          key: ValueKey<String>('recycle-item-$identity'),
          title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '删除于 ${DateFormat('yyyy年M月d日 HH:mm').format(item.deletedAt.toLocal())}',
              ),
              if (stacked)
                Padding(
                  padding: const EdgeInsets.only(top: OmniSpacing.xxs),
                  child: android
                      ? Align(alignment: Alignment.centerRight, child: actions)
                      : actions,
                ),
            ],
          ),
          trailing: stacked ? null : actions,
        );
      },
    );
  }

  /// 恢复当前业务记录。
  Future<void> _restore(RecycleBinItem item) => _run(
    operation: 'restore-${item.type.name}-${item.id}',
    execute: () => ref.read(recycleBinRepositoryProvider).restore(item),
    success: '“${item.title}”已恢复',
  );

  /// 永久删除单条记录前要求确认。
  Future<void> _delete(RecycleBinItem item) => _run(
    operation: 'delete-${item.type.name}-${item.id}',
    confirmationTitle: '永久删除？',
    confirmationMessage: '“${item.title}”及其从属记录删除后无法恢复。',
    confirmLabel: '永久删除',
    execute: () =>
        ref.read(recycleBinRepositoryProvider).permanentlyDelete(item),
    success: '“${item.title}”已永久删除',
  );

  /// 全局清空仅在用户确认后重新读取并删除全部软删除数据。
  Future<void> _empty() => _run(
    operation: 'empty',
    confirmationTitle: '清空回收站？',
    confirmationMessage: '将永久删除回收站中所有业务数据及其从属记录，删除后无法恢复。',
    confirmLabel: '清空回收站',
    execute: () async {
      await ref.read(recycleBinRepositoryProvider).empty();
    },
    success: '回收站已清空',
  );

  /// 统一处理确认、提交、成功反馈和可重试错误状态。
  Future<void> _run({
    required String operation,
    required Future<void> Function() execute,
    required String success,
    String? confirmationTitle,
    String? confirmationMessage,
    String confirmLabel = '确认',
  }) async {
    if (_operation != null) return;
    setState(() {
      _operation = operation;
      _error = null;
    });
    try {
      if (confirmationTitle != null) {
        // 确认弹窗关闭期间不允许重复发起新的删除操作。
        final bool confirmed = await showOmniConfirmDialog(
          context,
          title: confirmationTitle,
          message: confirmationMessage!,
          confirmLabel: confirmLabel,
          danger: true,
        );
        if (!confirmed || !mounted) return;
      }
      if (!mounted) return;
      setState(() => _submitting = true);
      await execute();
      if (mounted) {
        showOmniMessage(
          context,
          message: success,
          tone: OmniMessageTone.success,
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = '操作失败，请重试：$error');
    } finally {
      if (mounted) {
        setState(() {
          _operation = null;
          _submitting = false;
        });
      }
    }
  }

  /// 回收站业务名称，与功能导航一致。
  String _label(RecycleEntityType type) => switch (type) {
    RecycleEntityType.todo => '待办',
    RecycleEntityType.event => '事件',
    RecycleEntityType.inventory => '物品',
    RecycleEntityType.timeEntry => '时间记录',
    RecycleEntityType.membership => '会员',
    RecycleEntityType.quote => '名言',
  };

  /// 使用现有业务图标表达各分组。
  IconData _icon(RecycleEntityType type) => switch (type) {
    RecycleEntityType.todo => Icons.task_alt_rounded,
    RecycleEntityType.event => Icons.event_repeat_rounded,
    RecycleEntityType.inventory => Icons.inventory_2_outlined,
    RecycleEntityType.timeEntry => Icons.view_timeline_outlined,
    RecycleEntityType.membership => Icons.loyalty_outlined,
    RecycleEntityType.quote => Icons.format_quote_rounded,
  };
}
