import 'package:flutter/foundation.dart' show defaultTargetPlatform;
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
import 'package:omni_butler/features/floating/data/floating_window_preferences.dart';
import 'package:omni_butler/features/settings/data/feature_preferences.dart';
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

/// 设置页一级分类。
enum _SettingsCategory {
  /// 功能开关。
  features,

  /// 外观主题。
  appearance,

  /// 通知提醒。
  notifications,

  /// 数据同步。
  sync,

  /// 数据与存储。
  storage,
}

/// 设置页一级分类展示信息。
extension _SettingsCategoryPresentation on _SettingsCategory {
  /// 一级分类名称。
  String get label => switch (this) {
    _SettingsCategory.features => '功能管理',
    _SettingsCategory.appearance => '外观与主题',
    _SettingsCategory.notifications => '通知提醒',
    _SettingsCategory.sync => '数据同步',
    _SettingsCategory.storage => '数据与存储',
  };

  /// 一级分类说明。
  String get description => switch (this) {
    _SettingsCategory.features => '只保留你真正使用的功能，关闭后数据仍会安全保留。',
    _SettingsCategory.appearance => '调整当前设备的显示模式与视觉体验。',
    _SettingsCategory.notifications => '管理当前设备上的系统提醒。',
    _SettingsCategory.sync => '连接自托管服务，在多个设备之间同步数据。',
    _SettingsCategory.storage => '查看并处理已删除的数据。',
  };

  /// 一级分类图标。
  IconData get icon => switch (this) {
    _SettingsCategory.features => Icons.widgets_outlined,
    _SettingsCategory.appearance => Icons.palette_outlined,
    _SettingsCategory.notifications => Icons.notifications_outlined,
    _SettingsCategory.sync => Icons.cloud_sync_outlined,
    _SettingsCategory.storage => Icons.storage_outlined,
  };
}

/// 设置页面。
class SettingsPage extends ConsumerStatefulWidget {
  /// 创建设置页面。
  const SettingsPage({super.key});

  /// 创建设置页面状态。
  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

/// 设置页面状态。
class _SettingsPageState extends ConsumerState<SettingsPage> {
  /// 当前选中的一级分类。
  _SettingsCategory _selectedCategory = _SettingsCategory.features;

  /// Android 紧凑布局当前打开的二级分类，空值表示分类主页。
  _SettingsCategory? _androidSelectedCategory;

  /// 构建桌面双栏或窄窗口单栏设置布局。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 当前是否采用 Android 专用的二级设置结构。
        final bool showAndroidHierarchy =
            Theme.of(context).platform == TargetPlatform.android &&
            OmniBreakpoint.isCompact(constraints.maxWidth);
        if (showAndroidHierarchy) {
          return _buildAndroidSettings(colors);
        }
        // 当前是否展示 Windows 风格的左侧一级分类栏。
        final bool showSidebar = constraints.maxWidth >= 760;
        // 当前分类对应的右侧内容。
        final Widget content = _SettingsCategoryContent(
          category: _selectedCategory,
          colors: colors,
        );

        if (showSidebar) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SizedBox(
                width: 228,
                child: _SettingsSidebar(
                  selectedCategory: _selectedCategory,
                  onSelected: _selectCategory,
                ),
              ),
              VerticalDivider(width: 1, color: colors.line),
              Expanded(child: content),
            ],
          );
        }

        return Column(
          children: <Widget>[
            _CompactSettingsNavigation(
              selectedCategory: _selectedCategory,
              onSelected: _selectCategory,
            ),
            Divider(height: 1, color: colors.line),
            Expanded(child: content),
          ],
        );
      },
    );
  }

  /// 切换当前设置一级分类。
  void _selectCategory(_SettingsCategory category) {
    setState(() => _selectedCategory = category);
  }

  /// 构建 Android 分类主页或当前二级分类详情。
  Widget _buildAndroidSettings(OmniColors colors) {
    // 当前 Android 二级分类。
    final _SettingsCategory? selectedCategory = _androidSelectedCategory;
    return PopScope<Object?>(
      canPop: selectedCategory == null,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop && _androidSelectedCategory != null) {
          _closeAndroidCategory();
        }
      },
      child: selectedCategory == null
          ? _AndroidSettingsOverview(onSelected: _openAndroidCategory)
          : _AndroidSettingsDetail(
              category: selectedCategory,
              onBack: _closeAndroidCategory,
              child: _SettingsCategoryContent(
                category: selectedCategory,
                colors: colors,
                showPageHeader: false,
              ),
            ),
    );
  }

  /// 打开 Android 指定二级分类并同步桌面选中状态。
  void _openAndroidCategory(_SettingsCategory category) {
    setState(() {
      _selectedCategory = category;
      _androidSelectedCategory = category;
    });
  }

  /// 返回 Android 设置分类主页。
  void _closeAndroidCategory() {
    setState(() => _androidSelectedCategory = null);
  }
}

/// Android 设置分类主页。
class _AndroidSettingsOverview extends StatelessWidget {
  /// 分类选择回调。
  final ValueChanged<_SettingsCategory> onSelected;

  /// 创建 Android 设置分类主页。
  const _AndroidSettingsOverview({required this.onSelected});

  /// 构建分组三组的设置分类卡片。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 按用途划分的 Android 设置分类组。
    const List<List<_SettingsCategory>> categoryGroups =
        <List<_SettingsCategory>>[
          <_SettingsCategory>[_SettingsCategory.features],
          <_SettingsCategory>[
            _SettingsCategory.appearance,
            _SettingsCategory.notifications,
          ],
          <_SettingsCategory>[
            _SettingsCategory.sync,
            _SettingsCategory.storage,
          ],
        ];

    return ColoredBox(
      key: const ValueKey<String>('android-settings-overview'),
      color: colors.canvas,
      child: Column(
        children: <Widget>[
          const _AndroidSettingsHeader(title: '设置'),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                OmniSpacing.md,
                OmniSpacing.md,
                OmniSpacing.md,
                OmniSpacing.xxl,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (
                    int index = 0;
                    index < categoryGroups.length;
                    index += 1
                  ) ...<Widget>[
                    _AndroidSettingsGroupCard(
                      categories: categoryGroups[index],
                      onSelected: onSelected,
                    ),
                    if (index < categoryGroups.length - 1)
                      const SizedBox(height: OmniSpacing.md),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Android 设置二级分类详情。
class _AndroidSettingsDetail extends StatelessWidget {
  /// 当前分类。
  final _SettingsCategory category;

  /// 返回分类主页回调。
  final VoidCallback onBack;

  /// 当前分类内容。
  final Widget child;

  /// 创建 Android 设置二级分类详情。
  const _AndroidSettingsDetail({
    required this.category,
    required this.onBack,
    required this.child,
  });

  /// 构建带返回标题栏的分类详情。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return ColoredBox(
      key: ValueKey<String>('android-settings-detail-${category.name}'),
      color: colors.canvas,
      child: Column(
        children: <Widget>[
          _AndroidSettingsHeader(title: category.label, onBack: onBack),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// Android 设置页面居中标题栏。
class _AndroidSettingsHeader extends StatelessWidget {
  /// 标题文字。
  final String title;

  /// 可选返回回调。
  final VoidCallback? onBack;

  /// 创建 Android 设置标题栏。
  const _AndroidSettingsHeader({required this.title, this.onBack});

  /// 构建居中标题与可选返回按钮。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return SizedBox(
      key: const ValueKey<String>('android-settings-header'),
      height: 60,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Text(title, style: Theme.of(context).textTheme.headlineMedium),
          if (onBack != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: OmniSpacing.xxs),
                child: IconButton(
                  key: const ValueKey<String>('android-settings-back'),
                  tooltip: '返回设置',
                  onPressed: onBack,
                  color: colors.ink,
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Android 设置分类分组卡片。
class _AndroidSettingsGroupCard extends StatelessWidget {
  /// 当前分组分类。
  final List<_SettingsCategory> categories;

  /// 分类选择回调。
  final ValueChanged<_SettingsCategory> onSelected;

  /// 创建 Android 设置分类分组卡片。
  const _AndroidSettingsGroupCard({
    required this.categories,
    required this.onSelected,
  });

  /// 构建无边框圆角卡片与组内分隔线。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Material(
      key: ValueKey<String>('android-settings-group-${categories.first.name}'),
      color: colors.paper,
      borderRadius: BorderRadius.circular(OmniRadius.dialog),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (
            int index = 0;
            index < categories.length;
            index += 1
          ) ...<Widget>[
            if (index > 0)
              Divider(
                indent: OmniSpacing.lg,
                endIndent: OmniSpacing.lg,
                color: colors.line,
              ),
            _AndroidSettingsCategoryRow(
              category: categories[index],
              onTap: () => onSelected(categories[index]),
            ),
          ],
        ],
      ),
    );
  }
}

/// Android 设置分类入口行。
class _AndroidSettingsCategoryRow extends StatelessWidget {
  /// 当前分类。
  final _SettingsCategory category;

  /// 点击回调。
  final VoidCallback onTap;

  /// 创建 Android 设置分类入口行。
  const _AndroidSettingsCategoryRow({
    required this.category,
    required this.onTap,
  });

  /// 构建纯文字与右箭头入口。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return InkWell(
      key: ValueKey<String>('android-settings-category-${category.name}'),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.lg),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  category.label,
                  style: Theme.of(context).textTheme.bodyLarge
                      ?.copyWith(fontWeight: FontWeight.w500),
                ),
              ),
              const SizedBox(width: OmniSpacing.sm),
              Icon(Icons.chevron_right_rounded, size: 24, color: colors.muted),
            ],
          ),
        ),
      ),
    );
  }
}

/// Windows 设置页左侧一级分类栏。
class _SettingsSidebar extends StatelessWidget {
  /// 当前选中的一级分类。
  final _SettingsCategory selectedCategory;

  /// 分类选择回调。
  final ValueChanged<_SettingsCategory> onSelected;

  /// 创建设置一级分类栏。
  const _SettingsSidebar({
    required this.selectedCategory,
    required this.onSelected,
  });

  /// 构建带标题和选中反馈的一级分类栏。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return ColoredBox(
      color: colors.paper,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            OmniSpacing.md,
            OmniSpacing.lg,
            OmniSpacing.md,
            OmniSpacing.md,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.xs),
                child: Text(
                  '设置',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              const SizedBox(height: OmniSpacing.xxs),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.xs),
                child: Text(
                  '当前设备',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const SizedBox(height: OmniSpacing.lg),
              for (final _SettingsCategory category
                  in _SettingsCategory.values) ...<Widget>[
                _SettingsNavigationItem(
                  category: category,
                  selected: category == selectedCategory,
                  onTap: () => onSelected(category),
                ),
                const SizedBox(height: OmniSpacing.xxs),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 设置页单个一级分类项。
class _SettingsNavigationItem extends StatelessWidget {
  /// 当前分类。
  final _SettingsCategory category;

  /// 是否为选中态。
  final bool selected;

  /// 点击回调。
  final VoidCallback onTap;

  /// 创建一级分类项。
  const _SettingsNavigationItem({
    required this.category,
    required this.selected,
    required this.onTap,
  });

  /// 构建带图标的分类入口。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Material(
      key: ValueKey<String>('settings-category-${category.name}'),
      color: selected ? colors.brandSoft : Colors.transparent,
      borderRadius: BorderRadius.circular(OmniRadius.panel),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(OmniRadius.panel),
        child: SizedBox(
          height: 48,
          child: Row(
            children: <Widget>[
              AnimatedContainer(
                duration: OmniMotion.fast,
                width: 3,
                height: selected ? 24 : 0,
                decoration: BoxDecoration(
                  color: colors.brand,
                  borderRadius: BorderRadius.circular(OmniRadius.pill),
                ),
              ),
              const SizedBox(width: OmniSpacing.sm),
              Icon(
                category.icon,
                size: OmniSize.navigationIcon,
                color: selected ? colors.brand : colors.muted,
              ),
              const SizedBox(width: OmniSpacing.sm),
              Expanded(
                child: Text(
                  category.label,
                  style: TextStyle(
                    color: selected ? colors.brandStrong : colors.ink,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 窄窗口顶部一级分类导航。
class _CompactSettingsNavigation extends StatelessWidget {
  /// 当前选中的一级分类。
  final _SettingsCategory selectedCategory;

  /// 分类选择回调。
  final ValueChanged<_SettingsCategory> onSelected;

  /// 创建窄窗口分类导航。
  const _CompactSettingsNavigation({
    required this.selectedCategory,
    required this.onSelected,
  });

  /// 构建可横向滚动的分类入口。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return ColoredBox(
      color: colors.paper,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(OmniSpacing.sm),
        child: Row(
          children: <Widget>[
            for (final _SettingsCategory category
                in _SettingsCategory.values) ...<Widget>[
              ChoiceChip(
                label: Text(category.label),
                avatar: Icon(category.icon, size: OmniSize.icon),
                selected: category == selectedCategory,
                onSelected: (bool selected) {
                  if (selected) {
                    onSelected(category);
                  }
                },
              ),
              const SizedBox(width: OmniSpacing.xs),
            ],
          ],
        ),
      ),
    );
  }
}

/// 设置页当前一级分类内容。
class _SettingsCategoryContent extends ConsumerWidget {
  /// 当前一级分类。
  final _SettingsCategory category;

  /// 当前主题语义色。
  final OmniColors colors;

  /// 是否展示分类页面标题与说明。
  final bool showPageHeader;

  /// 创建一级分类内容。
  const _SettingsCategoryContent({
    required this.category,
    required this.colors,
    this.showPageHeader = true,
  });

  /// 构建带分类标题的可滚动内容区。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 当前页面是否采用紧凑边距。
    final bool compact = MediaQuery.sizeOf(context).width < 720;
    // 当前分类的设置主体。
    final Widget categoryBody = switch (category) {
      _SettingsCategory.features => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _ModuleGateways(colors: colors),
          const _FeatureManagementCard(),
        ],
      ),
      _SettingsCategory.appearance => _AppearanceCard(
        preference: ref.watch(themeControllerProvider),
      ),
      _SettingsCategory.notifications => const _NotificationCard(),
      _SettingsCategory.sync => _SyncSettingsCard(colors: colors),
      _SettingsCategory.storage => _RecycleBinCard(
        items: ref.watch(recycleBinItemsProvider),
      ),
    };

    return SingleChildScrollView(
      key: ValueKey<String>('settings-content-${category.name}'),
      padding: EdgeInsets.fromLTRB(
        compact ? OmniSpacing.md : OmniSpacing.xxl,
        OmniSpacing.xl,
        compact ? OmniSpacing.md : OmniSpacing.xxl,
        OmniSpacing.xxl,
      ),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (showPageHeader) ...<Widget>[
                OmniPageHeader(
                  title: category.label,
                  description: category.description,
                ),
                const SizedBox(height: OmniSpacing.xl),
              ],
              categoryBody,
            ],
          ),
        ),
      ),
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
    // 当前设备功能偏好。
    final FeaturePreference featurePreference = ref.watch(
      featurePreferenceProvider,
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
          subtitle: featurePreference.isEnabled(AppFeature.todos)
              ? null
              : const Text('每日待办功能已关闭'),
          trailing: OmniSwitch(
            value: preference.todoEnabled,
            onChanged:
                preference.enabled &&
                    featurePreference.isEnabled(AppFeature.todos)
                ? (bool value) => ref
                      .read(notificationPreferenceProvider.notifier)
                      .setTodoEnabled(value)
                : null,
          ),
        ),
        OmniListRow(
          title: const Text('周期事件'),
          subtitle: featurePreference.isEnabled(AppFeature.events)
              ? null
              : const Text('事件管理功能已关闭'),
          trailing: OmniSwitch(
            value: preference.eventEnabled,
            onChanged:
                preference.enabled &&
                    featurePreference.isEnabled(AppFeature.events)
                ? (bool value) => ref
                      .read(notificationPreferenceProvider.notifier)
                      .setEventEnabled(value)
                : null,
          ),
        ),
        OmniListRow(
          title: const Text('会员到期与续费'),
          subtitle: featurePreference.isEnabled(AppFeature.memberships)
              ? null
              : const Text('会员管理功能已关闭'),
          trailing: OmniSwitch(
            value: preference.membershipEnabled,
            onChanged:
                preference.enabled &&
                    featurePreference.isEnabled(AppFeature.memberships)
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
    showOmniMessage(
      context,
      message: succeeded ? '测试通知已发送' : '测试通知发送失败',
      tone: succeeded ? OmniMessageTone.success : OmniMessageTone.error,
    );
  }
}

/// 可开关业务功能的展示信息。
extension _AppFeaturePresentation on AppFeature {
  /// 功能名称。
  String get label => switch (this) {
    AppFeature.todos => '每日待办',
    AppFeature.timeline => '时间管理',
    AppFeature.events => '事件管理',
    AppFeature.inventory => '物品管理',
    AppFeature.memberships => '会员管理',
  };

  /// 功能用途说明。
  String get description => switch (this) {
    AppFeature.todos => '安排每日任务与优先级',
    AppFeature.timeline => '记录时间投入并回顾一天',
    AppFeature.events => '跟踪周期事件与完成记录',
    AppFeature.inventory => '管理物品、位置与配套关系',
    AppFeature.memberships => '管理会员、续费与到期提醒',
  };

  /// 功能图标。
  IconData get icon => switch (this) {
    AppFeature.todos => Icons.check_box_outlined,
    AppFeature.timeline => Icons.access_time_outlined,
    AppFeature.events => Icons.calendar_today_outlined,
    AppFeature.inventory => Icons.inventory_2_outlined,
    AppFeature.memberships => Icons.credit_card_outlined,
  };
}

/// 功能开关设置卡。
class _FeatureManagementCard extends ConsumerWidget {
  /// 创建功能开关设置卡。
  const _FeatureManagementCard();

  /// 构建首页固定状态与全部业务功能开关。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前设备功能偏好。
    final FeaturePreference preference = ref.watch(featurePreferenceProvider);
    // 当前设备悬浮框偏好。
    final FloatingWindowPreference floatingPreference = ref.watch(
      floatingWindowPreferenceProvider,
    );
    // 当前是否运行在 Windows 平台。
    final bool isWindows = defaultTargetPlatform == TargetPlatform.windows;
    // 悬浮框当前是否至少有一个可展示的业务分区。
    final bool floatingContentAvailable =
        preference.isEnabled(AppFeature.todos) ||
        preference.isEnabled(AppFeature.timeline);

    return _SettingsSection(
      title: '可用功能',
      description: '关闭后会隐藏导航、搜索及首页相关卡片内容；已有数据不会删除。',
      icon: Icons.tune_rounded,
      children: <Widget>[
        OmniListRow(
          leading: _FeatureIcon(
            icon: Icons.home_outlined,
            enabled: true,
            colors: colors,
          ),
          title: const Text('首页'),
          subtitle: const Text('应用的起点，始终保持开启'),
          trailing: OmniTag(label: '始终开启', color: colors.success),
        ),
        for (final AppFeature feature in AppFeature.values)
          OmniListRow(
            leading: _FeatureIcon(
              icon: feature.icon,
              enabled: preference.isEnabled(feature),
              colors: colors,
            ),
            title: Text(feature.label),
            subtitle: Text(feature.description),
            trailing: OmniSwitch(
              key: ValueKey<String>('feature-toggle-${feature.name}'),
              value: preference.isEnabled(feature),
              onChanged: (bool enabled) => ref
                  .read(featurePreferenceProvider.notifier)
                  .setFeatureEnabled(feature, enabled),
            ),
          ),
        if (isWindows)
          OmniListRow(
            leading: _FeatureIcon(
              icon: Icons.picture_in_picture_alt_outlined,
              enabled: floatingPreference.enabled && floatingContentAvailable,
              colors: colors,
            ),
            title: const Text('Windows 桌面悬浮框'),
            subtitle: Text(
              floatingContentAvailable
                  ? '在桌面显示今日待办和时间记录快捷操作，仅保存在当前设备'
                  : floatingPreference.enabled
                  ? '相关功能均已关闭，悬浮框已暂时隐藏'
                  : '请先开启每日待办或时间管理',
            ),
            trailing: OmniSwitch(
              key: const ValueKey<String>('floating-window-toggle'),
              value: floatingPreference.enabled,
              onChanged: floatingContentAvailable || floatingPreference.enabled
                  ? (bool enabled) => ref
                        .read(floatingWindowPreferenceProvider.notifier)
                        .setEnabled(enabled)
                  : null,
            ),
          ),
      ],
    );
  }
}

/// 功能列表行图标。
class _FeatureIcon extends StatelessWidget {
  /// 功能图标。
  final IconData icon;

  /// 功能是否启用。
  final bool enabled;

  /// 当前主题语义色。
  final OmniColors colors;

  /// 创建功能列表行图标。
  const _FeatureIcon({
    required this.icon,
    required this.enabled,
    required this.colors,
  });

  /// 构建随开关状态变化的图标底座。
  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: OmniMotion.normal,
      width: OmniSize.touch,
      height: OmniSize.touch,
      decoration: BoxDecoration(
        color: enabled ? colors.brandSoft : colors.paperSubtle,
        borderRadius: BorderRadius.circular(OmniRadius.control),
      ),
      child: Icon(
        icon,
        size: OmniSize.navigationIcon,
        color: enabled ? colors.brand : colors.muted,
      ),
    );
  }
}

/// 非 Android 紧凑布局的低频模块入口。
class _ModuleGateways extends ConsumerWidget {
  /// 当前主题语义色。
  final OmniColors colors;

  /// 创建低频模块入口。
  const _ModuleGateways({required this.colors});

  /// 仅在未使用管理聚合页的紧凑平台展示事件与会员入口。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 当前设备功能偏好。
    final FeaturePreference preference = ref.watch(featurePreferenceProvider);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 当前是否运行在桌面端。
        final bool isDesktopPlatform = OmniBreakpoint.isDesktopPlatform(
          Theme.of(context).platform,
        );
        // Android 已使用底栏管理聚合入口。
        final bool isAndroidPlatform =
            Theme.of(context).platform == TargetPlatform.android;
        if (isDesktopPlatform ||
            isAndroidPlatform ||
            constraints.maxWidth >= 720) {
          return const SizedBox.shrink();
        }
        // 当前可展示的低频功能入口。
        final List<Widget> gateways = <Widget>[
          if (preference.isEnabled(AppFeature.events))
            _GatewayTile(
              icon: Icons.event_repeat_rounded,
              color: colors.event,
              title: '事件记录',
              onTap: () => context.go('/events'),
            ),
          if (preference.isEnabled(AppFeature.memberships))
            _GatewayTile(
              icon: Icons.loyalty_rounded,
              color: colors.member,
              title: '会员管理',
              onTap: () => context.go('/memberships'),
            ),
        ];
        if (gateways.isEmpty) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: OmniSpacing.md),
          child: OmniListPanel(children: gateways),
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
    final Color syncStatusColor = syncLabel == '同步异常'
        ? colors.danger
        : !syncEnabled || session == null || session.isOffline
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
        : '服务器：${session.serverAddress}';
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
        showOmniMessage(context, message: '多端同步已关闭，当前只保存到本机');
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
      showOmniMessage(
        context,
        message: '已连接服务器，正在同步本机结构化数据',
        tone: OmniMessageTone.success,
      );
    }
  }

  /// 打开服务器连接弹窗并反馈成功状态。
  Future<void> _openConnection(BuildContext context, WidgetRef ref) async {
    // 服务器连接是否成功。
    final bool succeeded = await showSyncConnectionDialog(context);
    if (!context.mounted || !succeeded) {
      return;
    }
    showOmniMessage(
      context,
      message: '已连接服务器，正在同步本机结构化数据',
      tone: OmniMessageTone.success,
    );
  }

  /// 确认断开服务器并说明本机数据保留规则。
  Future<void> _confirmDisconnect(BuildContext context, WidgetRef ref) async {
    // 用户选择的本机数据处理方式。
    final _DisconnectChoice? choice = await showOmniDialog<_DisconnectChoice>(
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
    showOmniMessage(context, message: message, tone: OmniMessageTone.success);
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
                      if (context.mounted) {
                        showOmniMessage(
                          context,
                          message: '“${item.title}”已恢复',
                          tone: OmniMessageTone.success,
                        );
                      }
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
      if (context.mounted) {
        showOmniMessage(
          context,
          message: '“${item.title}”已永久删除',
          tone: OmniMessageTone.success,
        );
      }
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
