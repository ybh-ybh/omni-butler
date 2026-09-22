import 'package:flutter/material.dart';
import 'package:omni_butler/features/home/data/home_card_preferences.dart';
import 'package:omni_butler/features/settings/data/feature_preferences.dart';

/// 首页卡片的展示元数据。
extension HomeCardPresentation on HomeCardId {
  /// 卡片管理器中的用户可见名称。
  String get label => switch (this) {
    HomeCardId.quote => '每日名言',
    HomeCardId.dayRuler => '今日刻度',
    HomeCardId.todos => '今日待办',
    HomeCardId.todayContext => '今日脉络',
    HomeCardId.timeStatus => '时间状态',
  };

  /// 卡片管理器中的用途说明。
  String get description => switch (this) {
    HomeCardId.quote => '展示当天名言与自定义横幅',
    HomeCardId.dayRuler => '查看今天已经过去的时间',
    HomeCardId.todos => '处理三个重点优先区间的待办',
    HomeCardId.todayContext => '汇总临近事件与会员到期提醒',
    HomeCardId.timeStatus => '查看今日和本周的时间分类',
  };

  /// 卡片管理器中的识别图标。
  IconData get icon => switch (this) {
    HomeCardId.quote => Icons.format_quote_rounded,
    HomeCardId.dayRuler => Icons.schedule_rounded,
    HomeCardId.todos => Icons.check_circle_outline_rounded,
    HomeCardId.todayContext => Icons.hub_outlined,
    HomeCardId.timeStatus => Icons.donut_large_rounded,
  };
}

/// 判断卡片依赖的业务功能当前是否可用。
bool isHomeCardAvailable(HomeCardId card, FeaturePreference featurePreference) {
  return switch (card) {
    HomeCardId.quote || HomeCardId.dayRuler => true,
    HomeCardId.todos => featurePreference.isEnabled(AppFeature.todos),
    HomeCardId.timeStatus => featurePreference.isEnabled(AppFeature.timeline),
    HomeCardId.todayContext =>
      featurePreference.isEnabled(AppFeature.events) ||
          featurePreference.isEnabled(AppFeature.memberships),
  };
}

/// 返回卡片因功能关闭而不可用时的说明。
String? homeCardUnavailableReason(
  HomeCardId card,
  FeaturePreference featurePreference,
) {
  if (isHomeCardAvailable(card, featurePreference)) {
    return null;
  }
  return switch (card) {
    HomeCardId.todos => '每日待办功能已关闭',
    HomeCardId.timeStatus => '时间管理功能已关闭',
    HomeCardId.todayContext => '事件与会员功能均已关闭',
    HomeCardId.quote || HomeCardId.dayRuler => null,
  };
}
