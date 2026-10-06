import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/features/management/presentation/management_navigation.dart';
import 'package:omni_butler/features/settings/data/feature_preferences.dart';
import 'package:omni_butler/shared/ui/omni_dropdown.dart';

export 'management_navigation.dart' show ManagementSection;

/// 桌面管理页左上角的标题下拉切换器。
class DesktopManagementSwitcher extends ConsumerStatefulWidget {
  /// 当前页面对应的管理分区。
  final ManagementSection selectedSection;

  /// 创建管理分区标题切换器。
  const DesktopManagementSwitcher({required this.selectedSection, super.key});

  /// 创建标题切换器状态。
  @override
  ConsumerState<DesktopManagementSwitcher> createState() =>
      _DesktopManagementSwitcherState();
}

/// 同步直达路由并展示管理分区菜单。
class _DesktopManagementSwitcherState
    extends ConsumerState<DesktopManagementSwitcher> {
  /// 桌面菜单按事件、物品、会员组织，独立于移动端横滑顺序。
  static const List<ManagementSection> _menuOrder = <ManagementSection>[
    ManagementSection.events,
    ManagementSection.inventory,
    ManagementSection.memberships,
  ];

  /// 首次进入页面时记住直达路由。
  @override
  void initState() {
    super.initState();
    _rememberSelectedSection();
  }

  /// 复用标题组件时同步新的分区。
  @override
  void didUpdateWidget(covariant DesktopManagementSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedSection != widget.selectedSection) {
      _rememberSelectedSection();
    }
  }

  /// 在构建结束后记录当前路由，避免隐藏页面覆盖最近选择。
  void _rememberSelectedSection() {
    // 本次待同步的分区。
    final ManagementSection section = widget.selectedSection;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted || widget.selectedSection != section) {
        return;
      }
      // 独立页面预览可能没有路由器。
      final GoRouter? router = GoRouter.maybeOf(context);
      if (router?.routeInformationProvider.value.uri.path == section.route) {
        ref.read(managementSectionProvider.notifier).select(section);
      }
    });
  }

  /// 菜单确认后进入仍然启用的管理分区。
  void _selectSection(ManagementSection section) {
    if (!ref.read(featurePreferenceProvider).isEnabled(section.feature)) {
      return;
    }
    ref.read(managementSectionProvider.notifier).select(section);
    if (section != widget.selectedSection) {
      context.go(section.route);
    }
  }

  /// 返回各分区的简短用途说明。
  String _description(ManagementSection section) => switch (section) {
    ManagementSection.events => '记录周期事件，掌握下次时间',
    ManagementSection.inventory => '整理物品，查看位置与使用状态',
    ManagementSection.memberships => '管理会员，跟进到期与续费',
  };

  /// 构建标题按钮与带选中勾的下拉菜单。
  @override
  Widget build(BuildContext context) {
    // 当前主题及字体。
    final ThemeData theme = Theme.of(context);
    // 普通标题供没有侧栏或路由器的布局使用。
    final Widget title = Text(
      widget.selectedSection.label,
      style: theme.textTheme.headlineLarge,
    );
    if ((!OmniBreakpoint.isDesktopPlatform(theme.platform) &&
            OmniBreakpoint.isCompact(MediaQuery.sizeOf(context).width)) ||
        GoRouter.maybeOf(context) == null) {
      return title;
    }
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 根据独立功能开关过滤菜单。
    final FeaturePreference preference = ref.watch(featurePreferenceProvider);

    return PopupMenuTheme(
      data: theme.popupMenuTheme.copyWith(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(OmniRadius.dialog),
          side: BorderSide(color: colors.line),
        ),
      ),
      child: OmniPopupMenuButton<ManagementSection>(
        key: const ValueKey<String>('desktop-management-switcher'),
        tooltip: '',
        borderRadius: BorderRadius.circular(OmniRadius.dialog),
        menuConstraints: const BoxConstraints.tightFor(width: 288),
        onSelected: _selectSection,
        itemBuilder: (BuildContext context) =>
            <PopupMenuEntry<ManagementSection>>[
              // 每个启用分区保留独立的菜单行和选中语义。
              for (final ManagementSection section in _menuOrder)
                if (preference.isEnabled(section.feature))
                  PopupMenuItem<ManagementSection>(
                    key: ValueKey<String>(
                      'desktop-management-option-${section.name}',
                    ),
                    value: section,
                    height: 68,
                    padding: const EdgeInsets.symmetric(
                      horizontal: OmniSpacing.sm,
                      vertical: OmniSpacing.xs,
                    ),
                    child: Semantics(
                      selected: section == widget.selectedSection,
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  section.label,
                                  style: theme.textTheme.titleMedium,
                                ),
                                Text(
                                  _description(section),
                                  style: theme.textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: OmniSpacing.xs),
                          if (section == widget.selectedSection)
                            Icon(
                              Icons.check_rounded,
                              key: ValueKey<String>(
                                'desktop-management-selected-${section.name}',
                              ),
                              color: colors.ink,
                              size: OmniSize.icon,
                            )
                          else
                            const SizedBox(width: OmniSize.icon),
                        ],
                      ),
                    ),
                  ),
            ],
        child: Ink(
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(OmniRadius.dialog),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: OmniSpacing.sm,
            vertical: OmniSpacing.xxs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Flexible(child: title),
              const SizedBox(width: OmniSpacing.xs),
              Icon(
                Icons.expand_more_rounded,
                color: colors.muted,
                size: OmniSize.icon,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
