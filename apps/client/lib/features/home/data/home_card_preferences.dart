import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 首页可配置卡片的稳定标识。
enum HomeCardId {
  /// 每日名言卡片。
  quote,

  /// 今日自然时间刻度卡片。
  dayRuler,

  /// 今日重点待办卡片。
  todos,

  /// 临近事件与会员到期提醒的今日脉络卡片。
  todayContext,

  /// 今日与本周时间分类状态卡片。
  timeStatus,
}

/// 首页卡片顺序的本机存储键。
const String _homeCardOrderKey = 'home.cards.order';

/// 首页卡片的默认展示顺序。
const List<HomeCardId> defaultHomeCardOrder = <HomeCardId>[
  HomeCardId.quote,
  HomeCardId.dayRuler,
  HomeCardId.todos,
  HomeCardId.todayContext,
  HomeCardId.timeStatus,
];

/// 当前设备的首页卡片偏好。
@immutable
class HomeCardPreference {
  /// 用户已添加卡片的有序列表。
  final List<HomeCardId> orderedCards;

  /// 创建首页卡片偏好。
  HomeCardPreference({required List<HomeCardId> orderedCards})
    : orderedCards = List<HomeCardId>.unmodifiable(orderedCards);

  /// 判断卡片是否已被用户添加到首页。
  bool contains(HomeCardId card) => orderedCards.contains(card);
}

/// 当前设备首页卡片偏好控制器。
class HomeCardPreferenceController extends Notifier<HomeCardPreference> {
  /// 从本机存储恢复首页卡片顺序。
  @override
  HomeCardPreference build() {
    // 当前设备偏好存储。
    final SharedPreferences preferences = ref.watch(sharedPreferencesProvider);
    // 已保存的稳定卡片标识。
    final List<String>? storedNames = preferences.getStringList(
      _homeCardOrderKey,
    );
    if (storedNames == null) {
      return HomeCardPreference(orderedCards: defaultHomeCardOrder);
    }
    // 去重并忽略未知标识后的卡片顺序。
    final List<HomeCardId> restoredCards = <HomeCardId>[];
    for (final String name in storedNames) {
      // 当前名称对应的已知卡片。
      HomeCardId? card;
      for (final HomeCardId candidate in HomeCardId.values) {
        if (candidate.name == name) {
          card = candidate;
          break;
        }
      }
      if (card != null && !restoredCards.contains(card)) {
        restoredCards.add(card);
      }
    }
    return HomeCardPreference(orderedCards: restoredCards);
  }

  /// 添加或移除一张首页卡片并立即保存。
  Future<void> setVisible(HomeCardId card, bool visible) async {
    // 修改后的卡片顺序。
    final List<HomeCardId> updatedCards = List<HomeCardId>.of(
      state.orderedCards,
    );
    if (visible && !updatedCards.contains(card)) {
      updatedCards.add(card);
    } else if (!visible) {
      updatedCards.remove(card);
    }
    await _save(updatedCards);
  }

  /// 按拖拽原索引和最终插入索引调整已添加卡片顺序。
  Future<void> reorder(int oldIndex, int newIndex) async {
    // 修改后的卡片顺序。
    final List<HomeCardId> updatedCards = List<HomeCardId>.of(
      state.orderedCards,
    );
    // 被移动的卡片。
    final HomeCardId movedCard = updatedCards.removeAt(oldIndex);
    updatedCards.insert(newIndex, movedCard);
    await _save(updatedCards);
  }

  /// 保存完整顺序并发布最新状态。
  Future<void> _save(List<HomeCardId> cards) async {
    state = HomeCardPreference(orderedCards: cards);
    // 当前设备偏好存储。
    final SharedPreferences preferences = ref.read(sharedPreferencesProvider);
    await preferences.setStringList(
      _homeCardOrderKey,
      cards.map((HomeCardId card) => card.name).toList(growable: false),
    );
  }
}

/// 当前设备首页卡片偏好提供者。
final NotifierProvider<HomeCardPreferenceController, HomeCardPreference>
homeCardPreferenceProvider =
    NotifierProvider<HomeCardPreferenceController, HomeCardPreference>(
      HomeCardPreferenceController.new,
    );
