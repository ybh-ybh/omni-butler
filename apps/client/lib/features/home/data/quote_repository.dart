import 'package:drift/drift.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:uuid/uuid.dart';

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

  /// 清理可选文本。
  String? _cleanOptional(String? value) {
    // 清理后的文本。
    final String? normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}
