import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/home/data/quote_repository.dart';

/// 验证名言 JSON 编解码、去重和事务导入行为。
void main() {
  /// 每项测试独立使用的内存数据库。
  late AppDatabase database;

  /// 每项测试使用的名言仓储。
  late QuoteRepository repository;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = QuoteRepository(database);
  });

  tearDown(() async {
    await database.close();
  });

  test('解析 UTF-8 BOM、清理空白并按正文和作者保留首次出现项', () {
    // 含 BOM、额外字段和重复项的合法 JSON。
    final List<int> bytes = utf8.encode('''\uFEFF[
      {"content":"  进窄门、走暗路、耕瘦田。  ","author":"  ","extra":true},
      {"content":"进窄门、走暗路、耕瘦田。","author":""},
      {"content":"进窄门、走暗路、耕瘦田。","author":"另一作者"}
    ]''');

    // 解析并去重后的导入文档。
    final QuoteImportDocument document = repository.decodeImportJson(
      Uint8List.fromList(bytes),
    );

    expect(document.totalCount, 3);
    expect(document.duplicateCount, 1);
    expect(document.entries, hasLength(2));
    expect(document.entries.first.content, '进窄门、走暗路、耕瘦田。');
    expect(document.entries.first.author, isNull);
    expect(document.entries.last.author, '另一作者');
  });

  test('格式错误会指出条目位置并拒绝整份文档', () {
    // 作者字段类型错误的 JSON。
    final Uint8List bytes = Uint8List.fromList(
      utf8.encode('[{"content":"合法","author":""},{"content":"错误","author":1}]'),
    );

    expect(
      () => repository.decodeImportJson(bytes),
      throwsA(
        isA<FormatException>().having(
          (FormatException error) => error.message,
          'message',
          contains('第 2 项'),
        ),
      ),
    );
  });

  test('正文为空、超过 1000 字和非数组顶层均被拒绝', () {
    // 超过数据库限制的正文。
    final String oversized = List<String>.filled(1001, '字').join();
    // 三种必须拒绝的 JSON 字节。
    final List<Uint8List> invalidDocuments = <Uint8List>[
      Uint8List.fromList(utf8.encode('{"content":"错误","author":""}')),
      Uint8List.fromList(utf8.encode('[{"content":"  ","author":""}]')),
      Uint8List.fromList(utf8.encode('[{"content":"$oversized","author":""}]')),
    ];

    for (final Uint8List bytes in invalidDocuments) {
      expect(() => repository.decodeImportJson(bytes), throwsFormatException);
    }
  });

  test('合并会跳过现有与文件内重复项并保留同文不同作者', () async {
    await repository.save(
      const QuoteDraft(content: '已有正文', source: '', isEnabled: false),
    );
    // 当前唯一名言。
    final QuoteRecord existing = await database
        .select(database.quotes)
        .getSingle();
    await repository.setEnabled(existing.id, false);
    // 同时包含现有项、文件内重复项和同文不同作者的文档。
    final QuoteImportDocument document = repository.decodeImportJson(
      Uint8List.fromList(
        utf8.encode('''[
          {"content":"已有正文","author":""},
          {"content":"新正文","author":"作者甲"},
          {"content":"新正文","author":"作者甲"},
          {"content":"已有正文","author":"作者乙"}
        ]'''),
      ),
    );
    // 写入前数量预览。
    final QuoteImportPreview preview = await repository.previewImport(document);
    expect(preview.currentCount, 1);
    expect(preview.mergeInsertedCount, 2);
    expect(preview.mergeSkippedCount, 2);

    // 实际合并结果。
    final QuoteImportResult result = await repository.importJson(
      document,
      QuoteImportMode.merge,
    );
    // 合并后的全部未删除名言。
    final List<QuoteRecord> records = await (database.select(
      database.quotes,
    )..where((Quotes table) => table.deletedAt.isNull())).get();

    expect(result.insertedCount, 2);
    expect(result.skippedCount, 2);
    expect(records, hasLength(3));
    expect(
      records.singleWhere((QuoteRecord row) => row.id == existing.id).isEnabled,
      isFalse,
    );
    expect(
      records
          .where((QuoteRecord row) => row.id != existing.id)
          .every((QuoteRecord row) => row.isEnabled),
      isTrue,
    );
  });

  test('回收站记录不阻止同内容重新合并导入', () async {
    await repository.save(const QuoteDraft(content: '重新加入', source: '作者'));
    // 即将软删除的旧记录。
    final QuoteRecord deleted = await database
        .select(database.quotes)
        .getSingle();
    await repository.delete(deleted.id);
    // 与回收站记录内容相同的导入文档。
    final QuoteImportDocument document = repository.decodeImportJson(
      Uint8List.fromList(utf8.encode('[{"content":"重新加入","author":"作者"}]')),
    );

    // 实际合并结果。
    final QuoteImportResult result = await repository.importJson(
      document,
      QuoteImportMode.merge,
    );
    // 同内容的新旧两条记录。
    final List<QuoteRecord> records = await database
        .select(database.quotes)
        .get();

    expect(result.insertedCount, 1);
    expect(records, hasLength(2));
    expect(
      records.where((QuoteRecord row) => row.deletedAt == null),
      hasLength(1),
    );
  });

  test('替换会软删除全部旧名言并让当天选择改为新名言', () async {
    // 两条现有名言，其中一条停用。
    await repository.save(const QuoteDraft(content: '旧名言一', source: '旧作者'));
    await repository.save(const QuoteDraft(content: '旧名言二'));
    // 需要停用的旧名言。
    final QuoteRecord disabled = (await database.select(database.quotes).get())
        .singleWhere((QuoteRecord row) => row.content == '旧名言二');
    await repository.setEnabled(disabled.id, false);
    // 测试当天。
    final DateTime day = DateTime(2026, 10, 1);
    await database.quoteForDay(day);
    // 替换前的稳定每日选择。
    final DailyQuoteSelectionRecord selectionBefore = await database
        .select(database.dailyQuoteSelections)
        .getSingle();
    // 仅包含一条新名言的导入文档。
    final QuoteImportDocument document = repository.decodeImportJson(
      Uint8List.fromList(utf8.encode('[{"content":"新名言","author":"新作者"}]')),
    );

    // 实际替换结果。
    final QuoteImportResult result = await repository.importJson(
      document,
      QuoteImportMode.replace,
    );
    // 替换后的当天名言。
    final QuoteRecord? selectedAfter = await database.quoteForDay(day);
    // 替换后的稳定每日选择。
    final DailyQuoteSelectionRecord selectionAfter = await database
        .select(database.dailyQuoteSelections)
        .getSingle();
    // 全部新旧名言。
    final List<QuoteRecord> allRecords = await database
        .select(database.quotes)
        .get();

    expect(result.replacedCount, 2);
    expect(result.insertedCount, 1);
    expect(
      allRecords.where((QuoteRecord row) => row.deletedAt != null),
      hasLength(2),
    );
    expect(selectedAfter?.content, '新名言');
    expect(selectionAfter.id, selectionBefore.id);
    expect(selectionAfter.quoteId, selectedAfter?.id);
  });

  test('替换中任一插入失败会回滚软删除和已插入记录', () async {
    await repository.save(const QuoteDraft(content: '必须保留'));
    await database.customStatement('''
CREATE TRIGGER fail_quote_import
BEFORE INSERT ON quotes
WHEN NEW.content = '触发失败'
BEGIN
  SELECT RAISE(ABORT, 'injected import failure');
END
''');
    // 第二条会触发数据库失败的导入文档。
    final QuoteImportDocument document = repository.decodeImportJson(
      Uint8List.fromList(
        utf8.encode('''[
          {"content":"本应回滚","author":""},
          {"content":"触发失败","author":""}
        ]'''),
      ),
    );

    await expectLater(
      repository.importJson(document, QuoteImportMode.replace),
      throwsA(anything),
    );
    // 回滚后的全部记录。
    final List<QuoteRecord> records = await database
        .select(database.quotes)
        .get();

    expect(records, hasLength(1));
    expect(records.single.content, '必须保留');
    expect(records.single.deletedAt, isNull);
  });

  test('导出包含停用名言、排除回收站并映射 author 字段', () async {
    await repository.save(const QuoteDraft(content: '启用名言', source: '作者甲'));
    await repository.save(const QuoteDraft(content: '停用名言'));
    await repository.save(const QuoteDraft(content: '已删除名言', source: '作者丙'));
    // 三条记录的当前快照。
    final List<QuoteRecord> records = await database
        .select(database.quotes)
        .get();
    // 需要停用的记录。
    final QuoteRecord disabled = records.singleWhere(
      (QuoteRecord row) => row.content == '停用名言',
    );
    // 需要软删除的记录。
    final QuoteRecord deleted = records.singleWhere(
      (QuoteRecord row) => row.content == '已删除名言',
    );
    await repository.setEnabled(disabled.id, false);
    await repository.delete(deleted.id);

    // 导出的 JSON 数组。
    final List<dynamic> exported =
        jsonDecode(utf8.decode(await repository.exportJson())) as List<dynamic>;

    expect(exported, <Map<String, String>>[
      <String, String>{'content': '启用名言', 'author': '作者甲'},
      <String, String>{'content': '停用名言', 'author': ''},
    ]);
  });

  test('空名言库导出空数组', () async {
    // 空库导出的 JSON 值。
    final Object? exported = jsonDecode(
      utf8.decode(await repository.exportJson()),
    );

    expect(exported, isEmpty);
  });
}
