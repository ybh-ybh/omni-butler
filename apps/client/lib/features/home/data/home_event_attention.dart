import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/events/data/event_repository.dart';

/// 从有效事件中选出超期、含今天的七个自然日内应做及已进入提醒窗口的事项。
List<EventRecord> selectHomeAttentionEvents({
  required List<EventRecord> events,
  required EventRepository repository,
  required DateTime now,
}) {
  // 当前设备本地时间，避免 UTC 日期跨日导致近期范围偏移。
  final DateTime localNow = now.toLocal();
  // 七个自然日后的午夜为排他上界，包含今天与随后六天。
  final DateTime windowEnd = DateTime(
    localNow.year,
    localNow.month,
    localNow.day + 7,
  );
  // 一次计算应做时间，供筛选和稳定排序共用。
  final List<({EventRecord event, DateTime dueAt})> attention = [];
  // 逐项检查有效事件，未首次记录时保留无到期日期的原始语义。
  for (final EventRecord event in events) {
    // 按既有周期规则推算的本地应做时间。
    final DateTime? dueAt = repository.nextDueAt(event);
    if (dueAt == null) {
      continue;
    }
    if (dueAt.isBefore(windowEnd) ||
        repository.statusFor(event, localNow) == EventDueStatus.upcoming) {
      attention.add((event: event, dueAt: dueAt));
    }
  }
  attention.sort((left, right) {
    // 先按应做时间从早到晚排列。
    final int dueComparison = left.dueAt.compareTo(right.dueAt);
    if (dueComparison != 0) {
      return dueComparison;
    }
    // 同一时刻按名称排列，避免数据库返回顺序影响展示。
    final int nameComparison = left.event.name.compareTo(right.event.name);
    if (nameComparison != 0) {
      return nameComparison;
    }
    return left.event.id.compareTo(right.event.id);
  });
  return attention.map((item) => item.event).toList(growable: false);
}
