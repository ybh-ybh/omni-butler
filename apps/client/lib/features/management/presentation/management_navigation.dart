import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/features/settings/data/feature_preferences.dart';

/// 管理页可切换的业务分区。
enum ManagementSection {
  /// 事件记录。
  events,

  /// 会员管理。
  memberships,

  /// 物品管理。
  inventory,
}

/// 管理分区的展示与导航信息。
extension ManagementSectionPresentation on ManagementSection {
  /// 顶部切换控件的展示文案。
  String get label => switch (this) {
    ManagementSection.inventory => '物品管理',
    ManagementSection.events => '事件记录',
    ManagementSection.memberships => '会员管理',
  };

  /// 对应的现有业务路由。
  String get route => switch (this) {
    ManagementSection.inventory => '/inventory',
    ManagementSection.events => '/events',
    ManagementSection.memberships => '/memberships',
  };

  /// 对应的功能开关。
  AppFeature get feature => switch (this) {
    ManagementSection.inventory => AppFeature.inventory,
    ManagementSection.events => AppFeature.events,
    ManagementSection.memberships => AppFeature.memberships,
  };
}

/// 管理页会话内最后选中分区控制器。
class ManagementSectionController extends Notifier<ManagementSection> {
  /// 首次进入默认显示物品管理。
  @override
  ManagementSection build() => ManagementSection.inventory;

  /// 记住用户最近选中的管理分区。
  void select(ManagementSection section) {
    if (state == section) {
      return;
    }
    state = section;
  }
}

/// 管理页会话内选中分区。
final NotifierProvider<ManagementSectionController, ManagementSection>
managementSectionProvider =
    NotifierProvider<ManagementSectionController, ManagementSection>(
      ManagementSectionController.new,
    );

/// 返回当前已启用的管理分区。
List<ManagementSection> enabledManagementSections(
  FeaturePreference preference,
) {
  return ManagementSection.values
      .where(
        (ManagementSection section) => preference.isEnabled(section.feature),
      )
      .toList(growable: false);
}

/// 返回可用的首选分区；全部关闭时返回空值。
ManagementSection? resolveManagementSection(
  FeaturePreference preference,
  ManagementSection preferred,
) {
  // 当前已启用的管理分区列表。
  final List<ManagementSection> sections = enabledManagementSections(
    preference,
  );
  if (sections.isEmpty) {
    return null;
  }
  return sections.contains(preferred) ? preferred : sections.first;
}
