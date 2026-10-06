import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/events/data/event_repository.dart';
import 'package:omni_butler/features/home/data/home_event_attention.dart';

/// 验证首页近期预览与事件通知提前窗口相互独立。
void main() {
  /// 供真实事件仓储计算日期的内存数据库。
  late AppDatabase database;

  /// 保留真实周期推算规则的测试仓储。
  late EventRepository repository;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = EventRepository(database);
  });

  tearDown(() async {
    await database.close();
  });

  test('包含全部超期、今天未到时和第七日末尾，排除第八日零点', () {
    // 固定在当天午后，验证近期范围不会从当前时刻起算。
    final DateTime now = DateTime(2026, 10, 6, 14);
    // 刻意打乱输入顺序，同时覆盖七个自然日的精确边界。
    final List<EventRecord> events = [
      _event(id: 'eighth-day', lastCompletedAt: DateTime(2026, 10, 12)),
      _event(
        id: 'seventh-day-end',
        lastCompletedAt: DateTime(2026, 10, 11, 23, 59, 59, 999, 999),
      ),
      _event(id: 'today-evening', lastCompletedAt: DateTime(2026, 10, 5, 23)),
      _event(id: 'overdue', lastCompletedAt: DateTime(2026, 9, 1, 9)),
    ];
    // 实际入选的事件，必须按应做时间排列。
    final List<EventRecord> selected = selectHomeAttentionEvents(
      events: events,
      repository: repository,
      now: now,
    );

    expect(selected.map((event) => event.id), [
      'overdue',
      'today-evening',
      'seventh-day-end',
    ]);
  });

  test('关闭通知提醒仍预览七日内事项', () {
    // 固定业务当前时间。
    final DateTime now = DateTime(2026, 10, 6, 14);
    // 关闭通知且零天提前提醒的事件将在三天后应做。
    final EventRecord event = _event(lastCompletedAt: DateTime(2026, 10, 8, 9));

    expect(repository.statusFor(event, now), EventDueStatus.normal);
    expect(
      selectHomeAttentionEvents(
        events: [event],
        repository: repository,
        now: now,
      ),
      [event],
    );
  });

  test('默认提前一天提醒不阻止更早显示近期事项', () {
    // 固定业务当前时间。
    final DateTime now = DateTime(2026, 10, 6, 14);
    // 三天后应做，尚未进入提前一天的通知窗口。
    final EventRecord event = _event(
      lastCompletedAt: DateTime(2026, 10, 8, 9),
      reminderEnabled: true,
      reminderDaysBefore: 1,
    );

    expect(repository.statusFor(event, now), EventDueStatus.normal);
    expect(
      selectHomeAttentionEvents(
        events: [event],
        repository: repository,
        now: now,
      ),
      [event],
    );
  });

  test('七日范围外保留已进入较长提醒窗口的事项', () {
    // 固定业务当前时间。
    final DateTime now = DateTime(2026, 10, 6, 14);
    // 十天后应做，但已进入提前十四天的提醒窗口。
    final EventRecord longWindowEvent = _event(
      id: 'long-window',
      lastCompletedAt: DateTime(2026, 10, 15, 9),
      reminderEnabled: true,
      reminderDaysBefore: 14,
    );
    // 同日应做但尚未进入提醒窗口的事项。
    final EventRecord laterEvent = _event(
      id: 'later',
      lastCompletedAt: DateTime(2026, 10, 15, 9),
      reminderEnabled: true,
      reminderDaysBefore: 1,
    );

    expect(
      selectHomeAttentionEvents(
        events: [laterEvent, longWindowEvent],
        repository: repository,
        now: now,
      ),
      [longWindowEvent],
    );
  });

  test('尚未首次记录的事项不推测应做日期', () {
    // 未提供最近完成时间的事项。
    final EventRecord event = _event(reminderDaysBefore: 30);

    expect(repository.nextDueAt(event), isNull);
    expect(
      selectHomeAttentionEvents(
        events: [event],
        repository: repository,
        now: DateTime(2026, 10, 6),
      ),
      isEmpty,
    );
  });

  test('UTC 存储与本地时间表示选择相同的七日边界', () {
    // 本地午夜附近的当前时间，用于暴露 UTC 与本地日期差异。
    final DateTime localNow = DateTime(2026, 10, 6, 0, 15);
    // 七日窗口中最后一个本地自然日凌晨的事件。
    final EventRecord localIncluded = _event(
      id: 'included',
      lastCompletedAt: DateTime(2026, 10, 11, 0, 30),
    );
    // 位于排他上界的本地事件。
    final EventRecord localExcluded = _event(
      id: 'excluded',
      lastCompletedAt: DateTime(2026, 10, 12),
    );
    // 使用真实 UTC 时间点存储的等价事件。
    final List<EventRecord> utcEvents = [
      _event(
        id: 'included',
        lastCompletedAt: localIncluded.lastCompletedAt!.toUtc(),
      ),
      _event(
        id: 'excluded',
        lastCompletedAt: localExcluded.lastCompletedAt!.toUtc(),
      ),
    ];
    // 本地表示的筛选结果。
    final List<EventRecord> localSelected = selectHomeAttentionEvents(
      events: [localIncluded, localExcluded],
      repository: repository,
      now: localNow,
    );
    // UTC 表示的筛选结果。
    final List<EventRecord> utcSelected = selectHomeAttentionEvents(
      events: utcEvents,
      repository: repository,
      now: localNow.toUtc(),
    );

    expect(localSelected.map((event) => event.id), ['included']);
    expect(
      utcSelected.map((event) => event.id),
      localSelected.map((event) => event.id),
    );
  });

  test('月末周期按仓储截到二月末，七日范围跨入三月', () {
    // 一月三十一日完成的月周期，在二月最后一天应做。
    final EventRecord monthEndEvent = _event(
      id: 'month-end',
      lastCompletedAt: DateTime(2026, 1, 31, 18),
      intervalUnit: 'month',
    );
    // 三月四日零点恰好超出二月二十五日起的七个自然日。
    final EventRecord outsideEvent = _event(
      id: 'outside',
      lastCompletedAt: DateTime(2026, 3, 3),
    );

    expect(repository.nextDueAt(monthEndEvent), DateTime(2026, 2, 28, 18));
    expect(
      selectHomeAttentionEvents(
        events: [outsideEvent, monthEndEvent],
        repository: repository,
        now: DateTime(2026, 2, 25, 12),
      ),
      [monthEndEvent],
    );
  });

  test('七日范围正确跨年', () {
    // 跨年后第七个自然日的最后一分钟。
    final EventRecord includedEvent = _event(
      id: 'included',
      lastCompletedAt: DateTime(2027, 1, 3, 23, 59),
    );
    // 第八个自然日零点。
    final EventRecord excludedEvent = _event(
      id: 'excluded',
      lastCompletedAt: DateTime(2027, 1, 4),
    );

    expect(
      selectHomeAttentionEvents(
        events: [excludedEvent, includedEvent],
        repository: repository,
        now: DateTime(2026, 12, 29, 12),
      ),
      [includedEvent],
    );
  });

  test('同一应做时间按名称和标识确定排序且不修改输入', () {
    // 同时应做且名称相同的后序标识。
    final EventRecord secondEvent = _event(
      id: 'b',
      name: 'A',
      lastCompletedAt: DateTime(2026, 10, 5, 18),
    );
    // 同时应做但名称排序靠后的事项。
    final EventRecord thirdEvent = _event(
      id: 'c',
      name: 'B',
      lastCompletedAt: DateTime(2026, 10, 5, 18),
    );
    // 同时应做且名称相同的前序标识。
    final EventRecord firstEvent = _event(
      id: 'a',
      name: 'A',
      lastCompletedAt: DateTime(2026, 10, 5, 18),
    );
    // 共享源列表保留调用前的输入顺序。
    final List<EventRecord> events = [secondEvent, thirdEvent, firstEvent];

    expect(
      selectHomeAttentionEvents(
        events: events,
        repository: repository,
        now: DateTime(2026, 10, 6, 14),
      ),
      [firstEvent, secondEvent, thirdEvent],
    );
    expect(events, [secondEvent, thirdEvent, firstEvent]);
  });
}

/// 创建只携带周期计算必需字段的有效事件。
EventRecord _event({
  String id = 'event',
  String? name,
  DateTime? lastCompletedAt,
  String intervalUnit = 'day',
  bool reminderEnabled = false,
  int reminderDaysBefore = 0,
}) {
  return EventRecord(
    id: id,
    name: name ?? id,
    intervalValue: 1,
    intervalUnit: intervalUnit,
    lastCompletedAt: lastCompletedAt,
    reminderEnabled: reminderEnabled,
    reminderDaysBefore: reminderDaysBefore,
    reminderTimeMinutes: 540,
    isArchived: false,
    syncState: 'localSaved',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );
}
