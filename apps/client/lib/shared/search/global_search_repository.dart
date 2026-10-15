import 'dart:convert';

import 'package:omni_butler/features/notes/markdown/note_markdown.dart';

import 'package:drift/drift.dart';
import 'package:omni_butler/core/database/app_database.dart';

/// 全局搜索结果类型。
enum GlobalSearchType {
  /// 待办。
  todo,

  /// 周期事件。
  event,

  /// 物品。
  inventory,

  /// 时间记录。
  timeEntry,

  /// 会员。
  membership,

  /// 名言。
  quote,

  /// 笔记。
  note,
}

/// 全局搜索结果。
class GlobalSearchResult {
  /// 结果类型。
  final GlobalSearchType type;

  /// 记录标识。
  final String id;

  /// 主标题。
  final String title;

  /// 辅助说明。
  final String subtitle;

  /// 对应模块路由。
  final String route;

  /// 创建全局搜索结果。
  const GlobalSearchResult({
    required this.type,
    required this.id,
    required this.title,
    required this.subtitle,
    required this.route,
  });
}

/// 全局本地搜索仓储。
class GlobalSearchRepository {
  /// 本地数据库。
  final AppDatabase _database;

  /// 创建全局本地搜索仓储。
  const GlobalSearchRepository(this._database);

  /// 在第一期业务记录中执行模糊搜索。
  Future<List<GlobalSearchResult>> search(String query) async {
    // 标准化搜索词。
    final String keyword = query.trim().toLowerCase();
    if (keyword.isEmpty) {
      return const <GlobalSearchResult>[];
    }
    // 搜索结果集合。
    final List<GlobalSearchResult> results = <GlobalSearchResult>[];
    // 有效待办。
    final List<TodoRecord> todos = await (_database.select(
      _database.todoItems,
    )..where((TodoItems table) => table.deletedAt.isNull())).get();
    for (final TodoRecord record in todos) {
      if (_matches(keyword, <String?>[record.title, record.description])) {
        results.add(
          GlobalSearchResult(
            type: GlobalSearchType.todo,
            id: record.id,
            title: record.title,
            subtitle: record.description ?? '每日待办',
            route: '/todos',
          ),
        );
      }
    }
    // 有效事件。
    final List<EventRecord> events = await (_database.select(
      _database.events,
    )..where((Events table) => table.deletedAt.isNull())).get();
    for (final EventRecord record in events) {
      if (_matches(keyword, <String?>[
        record.name,
        record.category,
        record.notes,
      ])) {
        results.add(
          GlobalSearchResult(
            type: GlobalSearchType.event,
            id: record.id,
            title: record.name,
            subtitle: record.category ?? '周期事件',
            route: '/events',
          ),
        );
      }
    }
    // 有效顶层物品。
    final List<InventoryRecord> inventory =
        await (_database.select(_database.inventoryItems)..where(
              (InventoryItems table) =>
                  table.deletedAt.isNull() & table.parentItemId.isNull(),
            ))
            .get();
    for (final InventoryRecord record in inventory) {
      if (_matches(keyword, <String?>[
        record.name,
        record.category,
        record.location,
        record.tags,
        record.notes,
      ])) {
        results.add(
          GlobalSearchResult(
            type: GlobalSearchType.inventory,
            id: record.id,
            title: record.name,
            subtitle: record.location ?? record.category ?? '物品',
            route: '/inventory',
          ),
        );
      }
    }
    // 有效时间记录。
    final List<TimeEntryRecord> entries = await (_database.select(
      _database.timeEntries,
    )..where((TimeEntries table) => table.deletedAt.isNull())).get();
    for (final TimeEntryRecord record in entries) {
      if (_matches(keyword, <String?>[
        record.activity,
        record.category,
        record.notes,
      ])) {
        results.add(
          GlobalSearchResult(
            type: GlobalSearchType.timeEntry,
            id: record.id,
            title: record.activity ?? '未命名记录',
            subtitle: record.category ?? '时间记录',
            route: '/timeline',
          ),
        );
      }
    }
    // 有效会员。
    final List<MembershipRecord> memberships = await (_database.select(
      _database.memberships,
    )..where((Memberships table) => table.deletedAt.isNull())).get();
    for (final MembershipRecord record in memberships) {
      if (_matches(keyword, <String?>[
        record.name,
        record.provider,
        record.category,
        record.cancelGuide,
        record.notes,
      ])) {
        results.add(
          GlobalSearchResult(
            type: GlobalSearchType.membership,
            id: record.id,
            title: record.name,
            subtitle: record.provider ?? record.category ?? '会员',
            route: '/memberships',
          ),
        );
      }
    }
    // 有效名言。
    final List<QuoteRecord> quotes = await (_database.select(
      _database.quotes,
    )..where((Quotes table) => table.deletedAt.isNull())).get();
    for (final QuoteRecord record in quotes) {
      if (_matches(keyword, <String?>[record.content, record.source])) {
        results.add(
          GlobalSearchResult(
            type: GlobalSearchType.quote,
            id: record.id,
            title: record.content,
            subtitle: record.source ?? '名言',
            route: '/home',
          ),
        );
      }
    }
    // 有效笔记按记录日期倒序搜索，正文、原始转写、类别与标签都可命中。
    final List<NoteEntryRecord> notes =
        await (_database.select(_database.noteEntries)
              ..where((NoteEntries table) => table.deletedAt.isNull())
              ..orderBy([
                (NoteEntries table) => OrderingTerm.desc(table.dayKey),
              ]))
            .get();
    // 原始转写按笔记索引，已删除音频不参与全局搜索。
    final List<NoteAudioSegmentRecord> audio = await (_database.select(
      _database.noteAudioSegments,
    )..where((NoteAudioSegments table) => table.deletedAt.isNull())).get();
    // 类别与标签的真实显示名称，已删除的标签不再作为分类命中。
    final List<TaxonomyEntry> taxonomy =
        await (_database.select(_database.taxonomyEntries)..where(
              (TaxonomyEntries table) =>
                  table.module.equals('notes') & table.deletedAt.isNull(),
            ))
            .get();
    // 有效类别和标签名称按身份索引。
    final Map<String, String> names = {
      for (final TaxonomyEntry entry in taxonomy) entry.id: entry.name,
    };
    // 纯图片笔记被标签命中时也应使用正确的派生标题。
    final Set<String> imageNotes =
        (await (_database.select(
              _database.noteImages,
            )..where((table) => table.deletedAt.isNull())).get())
            .map((image) => image.noteId)
            .toSet();
    for (final NoteEntryRecord record in notes) {
      // 全局搜索和标题使用可见文字，格式分隔符不会打断词组。
      final String visibleBody = NoteMarkdown.plainText(record.body);
      if (_matches(keyword, <String?>[
        visibleBody,
        ..._tagNames(record.tags, names),
        ...audio
            .where(
              (NoteAudioSegmentRecord segment) => segment.noteId == record.id,
            )
            .map((NoteAudioSegmentRecord segment) => segment.transcript),
      ])) {
        results.add(
          GlobalSearchResult(
            type: GlobalSearchType.note,
            id: record.id,
            title: visibleBody.trim().isEmpty
                ? imageNotes.contains(record.id)
                      ? '图片笔记'
                      : '语音笔记'
                : visibleBody.trim().split('\n').first,
            subtitle: record.dayKey,
            route: '/notes?id=${Uri.encodeQueryComponent(record.id)}',
          ),
        );
      }
    }
    return results.take(50).toList(growable: false);
  }

  /// 从持久标签身份解析有效显示名称，坏旧数据不阻止搜索其他字段。
  List<String> _tagNames(String encoded, Map<String, String> names) {
    try {
      // 本篇笔记保存的标签身份数组。
      final Object? decoded = jsonDecode(encoded);
      if (decoded is! List) return const [];
      return decoded
          .map((dynamic id) => names[id])
          .whereType<String>()
          .toList();
    } on FormatException {
      return const [];
    }
  }

  /// 判断一组可选字段是否包含搜索词。
  bool _matches(String keyword, List<String?> fields) {
    return fields.any(
      (String? value) => value?.toLowerCase().contains(keyword) ?? false,
    );
  }
}
