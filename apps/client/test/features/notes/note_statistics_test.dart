import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/notes/data/note_statistics.dart';

/// 直接构造正式数据模型，创建时间与归档日期故意不同。
NoteEntryRecord statisticNote(
  String id,
  String date,
  String body, {
  bool deleted = false,
}) => NoteEntryRecord(
  isPinned: false,
  id: id,
  body: body,
  dayKey: date,
  tags: '[]',
  revision: 'revision-$id',
  createdAt: DateTime.utc(2030, 1, 1),
  creationTimezone: 'UTC',
  updatedAt: DateTime.utc(2030, 1, 1),
  deletedAt: deleted ? DateTime.utc(2030, 1, 2) : null,
);

/// 聚合测试只使用正式记录，不读取真实数据库或草稿。
void main() {
  test('格式标记和列表编号不计入可见字数，纯图正文为零', () {
    // 格式后的可见内容为甲乙、换行、丙丁、换行、戊己，共八字。
    final NoteStatistics statistics = NoteStatistics.fromNotes([
      statisticNote(
        'formatted',
        '2026-10-15',
        '**甲**<u>乙</u>\n- ==丙==丁\n1. 戊己',
      ),
      statisticNote('image-only', '2026-10-15', ''),
    ]);
    expect(statistics.annual[2026]!.words, 8);
    expect(statistics.annual[2026]!.count, 2);
  });
  test('统计按归档日期跨年聚合，闰日去重、Unicode计数并排除墓碑', () {
    // 可见字符为中文、家庭emoji、组合音符、空格、换行，共五个。
    final NoteStatistics statistics = NoteStatistics.fromNotes([
      statisticNote('unicode', '2024-02-29', '中👨‍👩‍👧‍👦e\u0301 \n'),
      statisticNote('same-day', '2024-02-29', '两字'),
      statisticNote('audio-only', '2025-12-31', ''),
      statisticNote('new-year', '2026-01-01', '新年!'),
      statisticNote('deleted', '2023-01-01', '不应计入', deleted: true),
    ]);
    expect(statistics.years, [2026, 2025, 2024]);
    expect(statistics.dates['2024-02-29']!.count, 2);
    expect(statistics.dates['2024-02-29']!.words, 7);
    expect(statistics.dates['2024-02-29']!.days, 1);
    expect(statistics.month(2024, 2).words, 7);
    expect(statistics.annual[2024]!.days, 1);
    expect(statistics.annual[2025]!.count, 1);
    expect(statistics.annual[2025]!.words, 0);
    expect(statistics.month(2026, 2).count, 0);
    expect(statistics.dates, isNot(contains('2030-01-01')));
    expect(statistics.annual, isNot(contains(2023)));
    // 各月份和年份总数必须与日汇总一致。
    expect(
      statistics.months.values.fold(0, (sum, item) => sum + item.count),
      4,
    );
    expect(
      statistics.annual.values.fold(0, (sum, item) => sum + item.words),
      10,
    );
    expect(statistics.annual.values.fold(0, (sum, item) => sum + item.days), 3);
    expect(() => statistics.years.add(2027), throwsUnsupportedError);
  });

  test('空集合没有年份或虚假的记录天数', () {
    // 未发布草稿没有进入此正式数据集合。
    final NoteStatistics statistics = NoteStatistics.fromNotes([]);
    expect(statistics.years, isEmpty);
    expect(statistics.dates, isEmpty);
    expect(statistics.month(2026, 10).days, 0);
  });
}
