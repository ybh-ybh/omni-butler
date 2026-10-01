import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:uuid/uuid.dart';

/// 名言 JSON 导入方式。
enum QuoteImportMode {
  /// 保留现有名言，仅新增不重复的导入项。
  merge,

  /// 将现有名言移入回收站后写入导入项。
  replace,
}

/// 经过校验与清理的名言 JSON 条目。
class QuoteJsonEntry {
  /// 名言正文。
  final String content;

  /// 可空作者。
  final String? author;

  /// 创建名言 JSON 条目。
  const QuoteJsonEntry({required this.content, required this.author});
}

/// 完整的名言 JSON 导入文档。
class QuoteImportDocument {
  /// 文件中的原始条目数。
  final int totalCount;

  /// 文件内去重后的条目。
  final List<QuoteJsonEntry> entries;

  /// 文件内部重复条目数。
  int get duplicateCount => totalCount - entries.length;

  /// 创建名言导入文档。
  const QuoteImportDocument({required this.totalCount, required this.entries});
}

/// 名言导入前的数量预览。
class QuoteImportPreview {
  /// 已解析的导入文档。
  final QuoteImportDocument document;

  /// 当前未删除名言数。
  final int currentCount;

  /// 合并模式实际可新增数量。
  final int mergeInsertedCount;

  /// 合并模式会跳过的文件条目数。
  int get mergeSkippedCount => document.totalCount - mergeInsertedCount;

  /// 创建名言导入预览。
  const QuoteImportPreview({
    required this.document,
    required this.currentCount,
    required this.mergeInsertedCount,
  });
}

/// 名言导入执行结果。
class QuoteImportResult {
  /// 实际新增数量。
  final int insertedCount;

  /// 因重复而跳过的文件条目数。
  final int skippedCount;

  /// 替换时移入回收站的旧名言数量。
  final int replacedCount;

  /// 创建名言导入结果。
  const QuoteImportResult({
    required this.insertedCount,
    required this.skippedCount,
    required this.replacedCount,
  });
}

/// 名言编辑草稿。
class QuoteDraft {
  /// 可选现有名言标识。
  final String? id;

  /// 名言正文。
  final String content;

  /// 可选出处。
  final String? source;

  /// 是否启用。
  final bool isEnabled;

  /// 创建名言草稿。
  const QuoteDraft({
    this.id,
    required this.content,
    this.source,
    this.isEnabled = true,
  });
}

/// 名言库本地优先仓储。
class QuoteRepository {
  /// 本地数据库。
  final AppDatabase _database;

  /// UUID 生成器。
  final Uuid _uuid;

  /// 创建名言库仓储。
  QuoteRepository(this._database, {this._uuid = const Uuid()});

  /// 监听全部有效名言。
  Stream<List<QuoteRecord>> watchAll() {
    // 名言库查询。
    final query = _database.select(_database.quotes)
      ..where((Quotes table) => table.deletedAt.isNull())
      ..orderBy(<OrderingTerm Function(Quotes)>[
        (Quotes table) => OrderingTerm.desc(table.isEnabled),
        (Quotes table) => OrderingTerm.asc(table.createdAt),
      ]);
    return query.watch();
  }

  /// 保存新增或编辑后的名言。
  Future<void> save(QuoteDraft draft) async {
    // 清理后的正文。
    final String content = draft.content.trim();
    if (content.isEmpty) {
      throw const FormatException('名言正文不能为空');
    }
    // 当前写入时间。
    final DateTime now = DateTime.now();
    if (draft.id == null) {
      await _database
          .into(_database.quotes)
          .insert(
            QuotesCompanion.insert(
              id: _uuid.v7(),
              content: content,
              source: Value<String?>(_cleanOptional(draft.source)),
              isEnabled: Value<bool>(draft.isEnabled),
              createdAt: now,
              updatedAt: now,
            ),
          );
      return;
    }
    await (_database.update(
      _database.quotes,
    )..where((Quotes table) => table.id.equals(draft.id!))).write(
      QuotesCompanion(
        content: Value<String>(content),
        source: Value<String?>(_cleanOptional(draft.source)),
        isEnabled: Value<bool>(draft.isEnabled),
        updatedAt: Value<DateTime>(now),
      ),
    );
  }

  /// 启用或停用名言。
  Future<void> setEnabled(String id, bool enabled) async {
    await (_database.update(
      _database.quotes,
    )..where((Quotes table) => table.id.equals(id))).write(
      QuotesCompanion(
        isEnabled: Value<bool>(enabled),
        updatedAt: Value<DateTime>(DateTime.now()),
      ),
    );
  }

  /// 将名言移入回收站，保留每日稳定身份供下次读取时重新选择。
  Future<void> delete(String id) async {
    // 当前删除时间。
    final DateTime now = DateTime.now();
    await _database.transaction(() async {
      await (_database.update(
        _database.quotes,
      )..where((Quotes table) => table.id.equals(id))).write(
        QuotesCompanion(
          deletedAt: Value<DateTime>(now),
          updatedAt: Value<DateTime>(now),
        ),
      );
    });
  }

  /// 将未删除名言导出为固定格式的 UTF-8 JSON。
  Future<Uint8List> exportJson() async {
    // 按名言库展示顺序读取的有效记录。
    final List<QuoteRecord> records =
        await (_database.select(_database.quotes)
              ..where((Quotes table) => table.deletedAt.isNull())
              ..orderBy(<OrderingTerm Function(Quotes)>[
                (Quotes table) => OrderingTerm.desc(table.isEnabled),
                (Quotes table) => OrderingTerm.asc(table.createdAt),
              ]))
            .get();
    // 仅包含公开交换字段的 JSON 数据。
    final List<Map<String, String>> values = records
        .map(
          (QuoteRecord record) => <String, String>{
            'content': record.content,
            'author': record.source ?? '',
          },
        )
        .toList(growable: false);
    // 便于人工阅读和版本管理的 JSON 文本。
    final String text =
        '${const JsonEncoder.withIndent('  ').convert(values)}\n';
    return Uint8List.fromList(utf8.encode(text));
  }

  /// 解析、校验并在文件内部去重名言 JSON。
  QuoteImportDocument decodeImportJson(Uint8List bytes) {
    // 严格 UTF-8 解码后的文件内容。
    late final String decodedText;
    try {
      decodedText = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw const FormatException('文件不是有效的 UTF-8 文本');
    }
    // 移除部分编辑器写入的 UTF-8 BOM。
    final String jsonText = decodedText.startsWith('\uFEFF')
        ? decodedText.substring(1)
        : decodedText;
    // JSON 顶层数据。
    late final Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } on FormatException catch (error) {
      throw FormatException('JSON 解析失败：${error.message}');
    }
    if (decoded is! List<Object?>) {
      throw const FormatException('JSON 顶层必须是数组');
    }

    // 文件内已经出现的正文与作者组合。
    final Set<(String, String)> seen = <(String, String)>{};
    // 按首次出现顺序保留的唯一条目。
    final List<QuoteJsonEntry> entries = <QuoteJsonEntry>[];
    for (int index = 0; index < decoded.length; index += 1) {
      // 当前原始条目。
      final Object? rawEntry = decoded[index];
      if (rawEntry is! Map<String, dynamic>) {
        throw FormatException('第 ${index + 1} 项必须是对象');
      }
      if (!rawEntry.containsKey('content') || rawEntry['content'] is! String) {
        throw FormatException('第 ${index + 1} 项的 content 必须是字符串');
      }
      if (!rawEntry.containsKey('author') || rawEntry['author'] is! String) {
        throw FormatException('第 ${index + 1} 项的 author 必须是字符串');
      }
      // 清理首尾空白后的正文。
      final String content = (rawEntry['content'] as String).trim();
      if (content.isEmpty) {
        throw FormatException('第 ${index + 1} 项的 content 不能为空');
      }
      if (content.runes.length > 1000) {
        throw FormatException('第 ${index + 1} 项的 content 不能超过 1000 个字符');
      }
      // 清理首尾空白后的作者。
      final String normalizedAuthor = (rawEntry['author'] as String).trim();
      // 当前条目的去重键。
      final (String, String) key = (content, normalizedAuthor);
      if (!seen.add(key)) {
        continue;
      }
      entries.add(
        QuoteJsonEntry(
          content: content,
          author: normalizedAuthor.isEmpty ? null : normalizedAuthor,
        ),
      );
    }
    return QuoteImportDocument(
      totalCount: decoded.length,
      entries: List<QuoteJsonEntry>.unmodifiable(entries),
    );
  }

  /// 计算合并与替换两种模式的导入数量。
  Future<QuoteImportPreview> previewImport(QuoteImportDocument document) async {
    // 当前所有未删除名言。
    final List<QuoteRecord> current = await (_database.select(
      _database.quotes,
    )..where((Quotes table) => table.deletedAt.isNull())).get();
    // 当前名言正文与作者的去重键。
    final Set<(String, String)> currentKeys = current.map(_recordKey).toSet();
    // 合并模式真正需要新增的条目数。
    final int mergeInsertedCount = document.entries
        .where(
          (QuoteJsonEntry entry) => !currentKeys.contains(_entryKey(entry)),
        )
        .length;
    return QuoteImportPreview(
      document: document,
      currentCount: current.length,
      mergeInsertedCount: mergeInsertedCount,
    );
  }

  /// 在单个数据库事务中合并或替换名言库。
  Future<QuoteImportResult> importJson(
    QuoteImportDocument document,
    QuoteImportMode mode,
  ) {
    return _database.transaction(() async {
      // 当前未删除名言。
      final List<QuoteRecord> current = await (_database.select(
        _database.quotes,
      )..where((Quotes table) => table.deletedAt.isNull())).get();
      // 本次真正需要插入的条目。
      late final List<QuoteJsonEntry> entriesToInsert;
      // 替换时进入回收站的数量。
      late final int replacedCount;
      // 统一的导入操作时间。
      final DateTime now = DateTime.now();
      if (mode == QuoteImportMode.replace) {
        entriesToInsert = document.entries;
        replacedCount = current.length;
        await (_database.update(
          _database.quotes,
        )..where((Quotes table) => table.deletedAt.isNull())).write(
          QuotesCompanion(
            deletedAt: Value<DateTime>(now),
            updatedAt: Value<DateTime>(now),
          ),
        );
      } else {
        // 当前名言正文与作者的去重键。
        final Set<(String, String)> currentKeys = current
            .map(_recordKey)
            .toSet();
        entriesToInsert = document.entries
            .where(
              (QuoteJsonEntry entry) => !currentKeys.contains(_entryKey(entry)),
            )
            .toList(growable: false);
        replacedCount = 0;
      }

      for (int index = 0; index < entriesToInsert.length; index += 1) {
        // 当前待插入的名言。
        final QuoteJsonEntry entry = entriesToInsert[index];
        // 保持文件顺序的稳定创建时间。
        final DateTime createdAt = now.add(Duration(microseconds: index));
        await _database
            .into(_database.quotes)
            .insert(
              QuotesCompanion.insert(
                id: _uuid.v7(),
                content: entry.content,
                source: Value<String?>(entry.author),
                isEnabled: const Value<bool>(true),
                createdAt: createdAt,
                updatedAt: createdAt,
              ),
            );
      }
      return QuoteImportResult(
        insertedCount: entriesToInsert.length,
        skippedCount: document.totalCount - entriesToInsert.length,
        replacedCount: replacedCount,
      );
    });
  }

  /// 清理可选文本。
  String? _cleanOptional(String? value) {
    // 清理后的文本。
    final String? normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  /// 返回数据库名言的正文与作者去重键。
  (String, String) _recordKey(QuoteRecord record) {
    return (record.content.trim(), record.source?.trim() ?? '');
  }

  /// 返回导入条目的正文与作者去重键。
  (String, String) _entryKey(QuoteJsonEntry entry) {
    return (entry.content, entry.author ?? '');
  }
}
