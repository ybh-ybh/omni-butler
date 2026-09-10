import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_providers.dart';
import 'package:omni_butler/core/notifications/local_notification_service.dart';
import 'package:omni_butler/core/notifications/notification_preferences.dart';
import 'package:omni_butler/core/notifications/notification_providers.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/sync/sync_preferences.dart';
import 'package:omni_butler/core/sync/sync_providers.dart';
import 'package:omni_butler/features/settings/data/recycle_bin_repository.dart';
import 'package:omni_butler/features/settings/presentation/sync_connection_dialog.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';
import 'package:powersync/powersync.dart' show SyncStatus;

/// 断开服务器时对本机数据的明确处理方式。
enum _DisconnectChoice {
  /// 保留本机业务数据。
  keep,

  /// 删除本机业务数据。
  delete,
}

/// 更多与设置页面。
class SettingsPage extends ConsumerWidget {
  /// 创建更多与设置页面。
  const SettingsPage({super.key});

  /// 构建主题、同步状态和回收站设置。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前主题偏好。
    final ThemePreference preference = ref.watch(themeControllerProvider);
    // 统一回收站异步状态。
    final AsyncValue<List<RecycleBinItem>> recycleBinItems = ref.watch(
      recycleBinItemsProvider,
    );

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 当前页面是否采用紧凑边距。
        final bool compact = OmniBreakpoint.isCompact(constraints.maxWidth);
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            compact ? OmniSpacing.md : OmniSpacing.xl,
            OmniSpacing.lg,
            compact ? OmniSpacing.md : OmniSpacing.xl,
            OmniSpacing.xxl,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 880),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const OmniPageHeader(
                    title: '更多与设置',
                    description: '管理当前设备的外观、通知、数据同步和低频入口。',
                  ),
                  const SizedBox(height: OmniSpacing.lg),
                  _ModuleGateways(colors: colors),
                  const SizedBox(height: OmniSpacing.md),
                  _AppearanceCard(preference: preference),
                  const SizedBox(height: OmniSpacing.md),
                  const _NotificationCard(),
                  const SizedBox(height: OmniSpacing.md),
                  _SyncSettingsCard(colors: colors),
                  const SizedBox(height: OmniSpacing.md),
                  _RecycleBinCard(items: recycleBinItems),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 当前设备通知设置卡。
class _NotificationCard extends ConsumerStatefulWidget {
  /// 创建通知设置卡。
  const _NotificationCard();

  /// 创建通知设置卡状态。
  @override
  ConsumerState<_NotificationCard> createState() => _NotificationCardState();
}

/// 当前设备通知设置卡状态。
class _NotificationCardState extends ConsumerState<_NotificationCard> {
  /// 构建通知状态、分类开关和测试入口。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前设备通知偏好。
    final NotificationPreference preference = ref.watch(
      notificationPreferenceProvider,
    );
    // 当前平台通知服务。
    final LocalNotificationService service = ref.watch(
      localNotificationServiceProvider,
    );
    // 当前通知服务状态文字。
    final String statusText = switch (service.availability) {
      NotificationAvailability.ready => '已就绪',
      NotificationAvailability.unsupported => '当前环境不可用',
      NotificationAvailability.failed => '需要检查',
    };
    // 当前通知服务状态颜色。
    final Color statusColor = switch (service.availability) {
      NotificationAvailability.ready => colors.success,
      NotificationAvailability.unsupported => colors.muted,
      NotificationAvailability.failed => colors.danger,
    };

    return _SettingsSection(
      title: '本地通知',
      description: '提醒只在当前设备调度；编辑或删除提醒后会同步撤销本机计划。',
      icon: Icons.notifications_outlined,
      tag: OmniTag(label: statusText, color: statusColor),
      error: service.lastError == null ? null : '通知初始化失败：${service.lastError}',
      children: <Widget>[
        OmniListRow(
          title: const Text('启用本地通知'),
          subtitle: const Text('关闭后不会生成任何新的系统提醒'),
          trailing: OmniSwitch(
            value: preference.enabled,
            onChanged: (bool value) => ref
                .read(notificationPreferenceProvider.notifier)
                .setEnabled(value),
          ),
        ),
        OmniListRow(
          title: const Text('每日待办'),
          trailing: OmniSwitch(
            value: preference.todoEnabled,
            onChanged: preference.enabled
                ? (bool value) => ref
                      .read(notificationPreferenceProvider.notifier)
                      .setTodoEnabled(value)
                : null,
          ),
        ),
        OmniListRow(
          title: const Text('周期事件'),
          trailing: OmniSwitch(
            value: preference.eventEnabled,
            onChanged: preference.enabled
                ? (bool value) => ref
                      .read(notificationPreferenceProvider.notifier)
                      .setEventEnabled(value)
                : null,
          ),
        ),
        OmniListRow(
          title: const Text('会员到期与续费'),
          trailing: OmniSwitch(
            value: preference.membershipEnabled,
            onChanged: preference.enabled
                ? (bool value) => ref
                      .read(notificationPreferenceProvider.notifier)
                      .setMembershipEnabled(value)
                : null,
          ),
        ),
        OmniListRow(
          title: const Text('测试系统通知'),
          subtitle: const Text('立即发送一条测试提醒，确认系统权限和安装环境正常'),
          trailing: OmniButton(
            label: '发送测试',
            icon: Icons.notification_add_outlined,
            variant: OmniButtonVariant.secondary,
            onPressed: service.availability == NotificationAvailability.ready
                ? _sendTestNotification
                : null,
          ),
        ),
      ],
    );
  }

  /// 发送即时测试通知并显示结果。
  Future<void> _sendTestNotification() async {
    // 当前平台通知服务。
    final LocalNotificationService service = ref.read(
      localNotificationServiceProvider,
    );
    // 系统通知发送结果。
    final bool succeeded = await service.showTestNotification();
    if (!mounted) {
      return;
    }
    setState(() {});
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(succeeded ? '测试通知已发送' : '测试通知发送失败')));
  }
}

/// 紧凑布局的低频模块入口。
class _ModuleGateways extends StatelessWidget {
  /// 当前主题语义色。
  final OmniColors colors;

  /// 创建低频模块入口。
  const _ModuleGateways({required this.colors});

  /// 构建事件与会员入口。
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 当前是否运行在桌面端。
        final bool isDesktopPlatform = OmniBreakpoint.isDesktopPlatform(
          Theme.of(context).platform,
        );
        if (isDesktopPlatform || constraints.maxWidth >= 720) {
          return const SizedBox.shrink();
        }
        return OmniListPanel(
          children: <Widget>[
            _GatewayTile(
              icon: Icons.event_repeat_rounded,
              color: colors.event,
              title: '事件记录',
              onTap: () => context.go('/events'),
            ),
            _GatewayTile(
              icon: Icons.loyalty_rounded,
              color: colors.member,
              title: '会员管理',
              onTap: () => context.go('/memberships'),
            ),
          ],
        );
      },
    );
  }
}

/// 单个低频模块入口。
class _GatewayTile extends StatelessWidget {
  /// 模块图标。
  final IconData icon;

  /// 模块颜色。
  final Color color;

  /// 模块名称。
  final String title;

  /// 点击回调。
  final VoidCallback onTap;

  /// 创建低频模块入口。
  const _GatewayTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.onTap,
  });

  /// 构建低频模块入口。
  @override
  Widget build(BuildContext context) {
    return OmniListRow(
      leading: Icon(icon, color: color, size: OmniSize.navigationIcon),
      title: Text(title),
      trailing: const Icon(Icons.chevron_right_rounded, size: OmniSize.icon),
      onTap: onTap,
    );
  }
}

/// 外观设置卡。
class _AppearanceCard extends ConsumerWidget {
  /// 当前主题偏好。
  final ThemePreference preference;

  /// 创建外观设置卡。
  const _AppearanceCard({required this.preference});

  /// 构建统一品牌主题与明暗模式设置。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _SettingsSection(
      title: '外观与主题',
      description: '统一飞书蓝品牌主题，明暗模式只影响当前设备。',
      icon: Icons.palette_outlined,
      children: <Widget>[
        OmniListRow(
          title: const Text('明暗模式'),
          subtitle: const Text('可跟随系统自动切换'),
          trailing: OmniDropdownButton<ThemeMode>(
            value: preference.mode,
            width: 144,
            items: const <DropdownMenuItem<ThemeMode>>[
              DropdownMenuItem<ThemeMode>(
                value: ThemeMode.system,
                child: Text('跟随系统'),
              ),
              DropdownMenuItem<ThemeMode>(
                value: ThemeMode.light,
                child: Text('浅色'),
              ),
              DropdownMenuItem<ThemeMode>(
                value: ThemeMode.dark,
                child: Text('深色'),
              ),
            ],
            onChanged: (ThemeMode? mode) {
              if (mode != null) {
                ref.read(themeControllerProvider.notifier).setThemeMode(mode);
              }
            },
          ),
        ),
      ],
    );
  }
}

/// 本机模式与多端同步状态卡。
class _SyncSettingsCard extends ConsumerWidget {
  /// 当前主题语义色。
  final OmniColors colors;

  /// 创建本机模式与同步状态卡。
  const _SyncSettingsCard({required this.colors});

  /// 构建本机模式与服务器连接说明。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 用户是否明确开启多端同步。
    final bool syncEnabled = ref.watch(syncPreferenceProvider);
    // 当前设备同步会话异步状态。
    final AsyncValue<SyncSession?> sessionState = ref.watch(
      authControllerProvider,
    );
    // 已恢复的设备同步会话。
    final SyncSession? session = sessionState.value;
    // 设备会话驱动的同步连接结果。
    final AsyncValue<void> syncController = ref.watch(syncControllerProvider);
    // PowerSync 实时状态。
    final SyncStatus? syncStatus = ref.watch(syncStatusProvider).value;
    // 本机待上传操作数量。
    final int queuedOperations =
        ref.watch(syncUploadQueueCountProvider).value ?? 0;
    // 当前同步状态短文本。
    final String syncLabel = _syncLabel(
      syncEnabled: syncEnabled,
      session: session,
      controller: syncController,
      status: syncStatus,
      queuedOperations: queuedOperations,
    );

    // 当前同步状态强调色。
    final Color syncStatusColor =
        !syncEnabled || session == null || session.isOffline
        ? colors.muted
        : colors.success;
    // 当前同步状态标题。
    final String syncTitle = !syncEnabled
        ? '仅本机模式'
        : session == null
        ? '尚未连接服务器'
        : '已连接自托管服务器';
    // 当前同步状态说明。
    final String syncDescription = !syncEnabled
        ? '服务器连接已停止；重新开启后，本机产生的结构化数据会进入同步。图片仍只保存在本机。'
        : session == null
        ? '请连接自己部署的 Omni Butler 后端。当前不接入第三方同步服务和腾讯云 COS。'
        : session.isOffline
        ? '当前离线，业务编辑仍会正常保存；联网后会继续同步。'
        : '服务器：${session.apiBaseUrl}';
    // 当前同步状态可用操作。
    final List<Widget> syncActions = <Widget>[
      if (syncEnabled && session == null)
        OmniButton(
          label: '连接服务器',
          icon: Icons.dns_outlined,
          loading: sessionState.isLoading,
          onPressed: () => _openConnection(context, ref),
        )
      else if (syncEnabled && session != null) ...<Widget>[
        if (session.isOffline)
          OmniButton(
            label: '重试连接',
            icon: Icons.refresh_rounded,
            variant: OmniButtonVariant.secondary,
            loading: sessionState.isLoading,
            onPressed: () =>
                ref.read(authControllerProvider.notifier).refreshSession(),
          ),
        OmniButton(
          label: '断开服务器',
          variant: OmniButtonVariant.text,
          onPressed: sessionState.isLoading
              ? null
              : () => _confirmDisconnect(context, ref),
        ),
      ],
    ];

    return _SettingsSection(
      title: '数据同步',
      description: '控制当前设备是否连接自托管服务器。',
      icon: Icons.cloud_sync_outlined,
      tag: OmniTag(label: syncLabel, color: syncStatusColor),
      children: <Widget>[
        OmniListRow(
          title: const Text('开启多端数据同步'),
          subtitle: const Text('默认关闭；关闭时不会连接服务器，全部业务数据只保存在本机'),
          trailing: OmniSwitch(
            value: syncEnabled,
            onChanged: sessionState.isLoading
                ? null
                : (bool value) => _setSyncEnabled(context, ref, value),
          ),
        ),
        OmniListRow(
          leading: Container(
            width: OmniSize.touch,
            height: OmniSize.touch,
            decoration: BoxDecoration(
              color: colors.paperSubtle,
              borderRadius: BorderRadius.circular(OmniRadius.control),
            ),
            child: Icon(
              syncEnabled ? Icons.cloud_sync_outlined : Icons.computer_rounded,
              color: colors.brand,
              size: OmniSize.navigationIcon,
            ),
          ),
          title: Text(syncTitle),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(syncDescription),
              if (sessionState.hasError) ...<Widget>[
                const SizedBox(height: OmniSpacing.xxs),
                Text(
                  sessionState.error.toString(),
                  style: TextStyle(color: colors.danger),
                ),
              ],
              if (syncController.hasError) ...<Widget>[
                const SizedBox(height: OmniSpacing.xxs),
                Text(
                  syncController.error.toString(),
                  style: TextStyle(color: colors.danger),
                ),
              ],
              if (syncActions.isNotEmpty) ...<Widget>[
                const SizedBox(height: OmniSpacing.sm),
                Wrap(
                  spacing: OmniSpacing.xs,
                  runSpacing: OmniSpacing.xs,
                  children: syncActions,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 根据设备会话、连接和队列状态生成紧凑状态标签。
  String _syncLabel({
    required bool syncEnabled,
    required SyncSession? session,
    required AsyncValue<void> controller,
    required SyncStatus? status,
    required int queuedOperations,
  }) {
    if (!syncEnabled) {
      return queuedOperations == 0 ? '同步已关闭' : '已关闭 · 待同步 $queuedOperations';
    }
    if (session == null) {
      return queuedOperations == 0 ? '等待配置' : '待同步 $queuedOperations';
    }
    if (session.isOffline) {
      return '离线';
    }
    if (controller.isLoading || status?.connecting == true) {
      return '连接中';
    }
    if (controller.hasError || status?.anyError != null) {
      return '同步异常';
    }
    if (status?.uploading == true || status?.downloading == true) {
      return '同步中';
    }
    if (queuedOperations > 0) {
      return '待上传 $queuedOperations';
    }
    if (status?.connected == true) {
      return '已同步';
    }
    return '已连接';
  }

  /// 切换同步总开关，并在首次开启时引导连接自托管服务器。
  Future<void> _setSyncEnabled(
    BuildContext context,
    WidgetRef ref,
    bool enabled,
  ) async {
    await ref.read(syncPreferenceProvider.notifier).setEnabled(enabled);
    if (!enabled) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('多端同步已关闭，当前只保存到本机')));
      }
      return;
    }
    // 开启后从安全存储恢复的设备会话。
    final SyncSession? session = await ref.read(authControllerProvider.future);
    if (!context.mounted || session != null) {
      return;
    }
    // 首次连接是否成功。
    final bool succeeded = await showSyncConnectionDialog(context);
    if (!succeeded) {
      await ref.read(syncPreferenceProvider.notifier).setEnabled(false);
      return;
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已连接服务器，正在同步本机结构化数据')));
    }
  }

  /// 打开服务器连接弹窗并反馈成功状态。
  Future<void> _openConnection(BuildContext context, WidgetRef ref) async {
    // 服务器连接是否成功。
    final bool succeeded = await showSyncConnectionDialog(context);
    if (!context.mounted || !succeeded) {
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已连接服务器，正在同步本机结构化数据')));
  }

  /// 确认断开服务器并说明本机数据保留规则。
  Future<void> _confirmDisconnect(BuildContext context, WidgetRef ref) async {
    // 用户选择的本机数据处理方式。
    final _DisconnectChoice? choice = await showDialog<_DisconnectChoice>(
      context: context,
      builder: (BuildContext dialogContext) => OmniDialogScaffold(
        title: '断开当前服务器？',
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text('请明确选择这台设备上的数据处理方式。“删除本机数据”不会删除云端数据，且无法撤销。'),
            const SizedBox(height: OmniSpacing.lg),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: OmniSpacing.xs,
              runSpacing: OmniSpacing.xs,
              children: <Widget>[
                OmniButton(
                  label: '取消',
                  variant: OmniButtonVariant.secondary,
                  onPressed: () => Navigator.pop(dialogContext),
                ),
                OmniButton(
                  label: '断开并删除本机数据',
                  variant: OmniButtonVariant.danger,
                  onPressed: () =>
                      Navigator.pop(dialogContext, _DisconnectChoice.delete),
                ),
                OmniButton(
                  label: '断开并保留本机数据',
                  onPressed: () =>
                      Navigator.pop(dialogContext, _DisconnectChoice.keep),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (choice == null) {
      return;
    }
    if (choice == _DisconnectChoice.delete) {
      await ref.read(syncControllerProvider.notifier).clearLocalData();
    }
    await ref.read(authControllerProvider.notifier).disconnect();
    if (!context.mounted) {
      return;
    }
    // 与选择一致的断开结果提示。
    final String message = choice == _DisconnectChoice.delete
        ? '已断开服务器并删除本机数据'
        : '已断开服务器，本机数据仍然保留';
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

/// 统一回收站卡。
class _RecycleBinCard extends ConsumerWidget {
  /// 统一回收站异步状态。
  final AsyncValue<List<RecycleBinItem>> items;

  /// 创建统一回收站卡。
  const _RecycleBinCard({required this.items});

  /// 构建可恢复与永久删除的回收站。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);

    // 当前回收站列表行。
    final List<Widget> rows = items.when(
      data: (List<RecycleBinItem> records) {
        if (records.isEmpty) {
          return const <Widget>[
            OmniListRow(
              title: Text('回收站为空'),
              subtitle: Text('删除的业务记录会在这里保留 30 天'),
            ),
          ];
        }
        return <Widget>[
          for (final RecycleBinItem item in records)
            OmniListRow(
              leading: Icon(_iconFor(item.type), size: OmniSize.icon),
              title: Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${_typeLabel(item.type)} · 删除于 ${DateFormat('M月d日 HH:mm').format(item.deletedAt)}',
              ),
              trailing: Wrap(
                spacing: OmniSpacing.xxs,
                children: <Widget>[
                  OmniButton(
                    label: '恢复',
                    variant: OmniButtonVariant.text,
                    onPressed: () async {
                      await ref
                          .read(recycleBinRepositoryProvider)
                          .restore(item);
                      ref.invalidate(recycleBinItemsProvider);
                    },
                  ),
                  OmniButton(
                    label: '永久删除',
                    variant: OmniButtonVariant.danger,
                    onPressed: () =>
                        _confirmPermanentDelete(context, ref, item),
                  ),
                ],
              ),
            ),
        ];
      },
      loading: () => const <Widget>[
        OmniListRow(
          title: Text('正在读取回收站'),
          trailing: SizedBox.square(
            dimension: OmniSize.icon,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ],
      error: (Object error, StackTrace stackTrace) => <Widget>[
        OmniListRow(
          title: const Text('回收站读取失败'),
          subtitle: Text(
            error.toString(),
            style: TextStyle(color: colors.danger),
          ),
        ),
      ],
    );

    return _SettingsSection(
      title: '回收站',
      description: '删除的业务记录默认保留 30 天。',
      icon: Icons.delete_outline_rounded,
      children: rows,
    );
  }

  /// 返回回收站类型名称。
  String _typeLabel(RecycleEntityType type) {
    return switch (type) {
      RecycleEntityType.todo => '待办',
      RecycleEntityType.event => '事件',
      RecycleEntityType.inventory => '物品',
      RecycleEntityType.timeEntry => '时间记录',
      RecycleEntityType.membership => '会员',
      RecycleEntityType.quote => '名言',
    };
  }

  /// 返回回收站类型图标。
  IconData _iconFor(RecycleEntityType type) {
    return switch (type) {
      RecycleEntityType.todo => Icons.task_alt_rounded,
      RecycleEntityType.event => Icons.event_repeat_rounded,
      RecycleEntityType.inventory => Icons.inventory_2_outlined,
      RecycleEntityType.timeEntry => Icons.view_timeline_outlined,
      RecycleEntityType.membership => Icons.loyalty_outlined,
      RecycleEntityType.quote => Icons.format_quote_rounded,
    };
  }

  /// 确认永久删除记录。
  Future<void> _confirmPermanentDelete(
    BuildContext context,
    WidgetRef ref,
    RecycleBinItem item,
  ) async {
    // 用户是否确认永久删除。
    final bool confirmed = await showOmniConfirmDialog(
      context,
      title: '永久删除？',
      message: '“${item.title}”删除后无法恢复。',
      confirmLabel: '永久删除',
      danger: true,
    );
    if (confirmed) {
      await ref.read(recycleBinRepositoryProvider).permanentlyDelete(item);
      ref.invalidate(recycleBinItemsProvider);
    }
  }
}

/// 设置页统一分区。
class _SettingsSection extends StatelessWidget {
  /// 分区标题。
  final String title;

  /// 分区说明。
  final String description;

  /// 分区图标。
  final IconData icon;

  /// 可选状态标签。
  final Widget? tag;

  /// 可选错误说明。
  final String? error;

  /// 分区列表行。
  final List<Widget> children;

  /// 创建设置页分区。
  const _SettingsSection({
    required this.title,
    required this.description,
    required this.icon,
    required this.children,
    this.tag,
    this.error,
  });

  /// 构建标题说明和连续设置列表。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.xxs),
          child: Row(
            children: <Widget>[
              Icon(icon, color: colors.brand, size: OmniSize.icon),
              const SizedBox(width: OmniSpacing.xs),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              ?tag,
            ],
          ),
        ),
        const SizedBox(height: OmniSpacing.xxs),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.xxs),
          child: Text(
            description,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        if (error != null) ...<Widget>[
          const SizedBox(height: OmniSpacing.xxs),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.xxs),
            child: Text(error!, style: TextStyle(color: colors.danger)),
          ),
        ],
        const SizedBox(height: OmniSpacing.xs),
        OmniListPanel(children: children),
      ],
    );
  }
}
