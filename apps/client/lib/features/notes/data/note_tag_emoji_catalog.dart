import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 一个可选的标签图标，始终保留完整 Unicode 序列。
@immutable
class NoteTagEmoji {
  /// 冻结关键词，避免界面修改共享目录或搜索索引。
  NoteTagEmoji._({
    required this.emoji,
    required this.category,
    required List<String> keywordsZh,
    required List<String> keywordsEn,
  }) : keywordsZh = List.unmodifiable(keywordsZh),
       keywordsEn = List.unmodifiable(keywordsEn),
       _searchKeywords = List.unmodifiable({
         ...keywordsZh.map((keyword) => keyword.toLowerCase()),
         ...keywordsEn.map((keyword) => keyword.toLowerCase()),
       });

  /// 可直接展示及持久化的完整 emoji 字符串。
  final String emoji;

  /// 对应 NoteTagEmojiCatalog.categoryLabels 的稳定类别标识。
  final String category;

  /// 上游中文名称及同义词，顺序与来源一致。
  final List<String> keywordsZh;

  /// 上游英文名称及同义词，顺序与来源一致。
  final List<String> keywordsEn;

  /// 只建立一次的小写搜索索引，减少每次输入时的重复转换。
  final List<String> _searchKeywords;

  /// 首个中文关键词作友好标签，不将它宣称为正式 Unicode 名称。
  String get label => keywordsZh.isNotEmpty
      ? keywordsZh.first
      : (keywordsEn.isNotEmpty ? keywordsEn.first : emoji);

  /// 从受版本和摘要约束的离线资产构造条目。
  factory NoteTagEmoji._fromJson(Map<String, dynamic> json) => NoteTagEmoji._(
    emoji: json['emoji'] as String,
    category: json['category'] as String,
    keywordsZh: (json['keywordsZh'] as List<dynamic>).cast<String>(),
    keywordsEn: (json['keywordsEn'] as List<dynamic>).cast<String>(),
  );

  /// 多个查询词均需命中任一中英关键词，允许两种语言混合。
  bool _matches(List<String> terms) => terms.every(
    (term) => _searchKeywords.any((keyword) => keyword.contains(term)),
  );
}

/// 笔记标签图标的离线目录，不读写偏好或调用平台插件。
class NoteTagEmojiCatalog {
  /// 冻结原始类别顺序，并缓存用于随机排除的条目位置。
  NoteTagEmojiCatalog._(List<NoteTagEmoji> entries)
    : entries = List.unmodifiable(entries),
      _indexByEmoji = {
        // 索引依完整序列区分变体选择符和组合 emoji。
        for (final (index, entry) in entries.indexed) entry.emoji: index,
      };

  /// 随应用一起分发的唯一数据资产，其中包含完整许可通知。
  static const String assetPath = 'assets/emoji/note_tag_emoji_catalog.json';

  /// 类别顺序沿用固定版本源数据，名称用于中文界面展示。
  static const Map<String, String> categoryLabels = {
    'smileys': '表情 & 人物',
    'animals': '动物 & 自然',
    'foods': '食物 & 饮品',
    'travel': '旅行 & 地点',
    'activities': '活动',
    'objects': '物品',
    'symbols': '符号',
    'flags': '旗帜',
  };

  /// 多个编辑浮层共享同一个离线加载任务。
  static Future<NoteTagEmojiCatalog>? _cachedLoad;

  /// 只在搜索时拆分用户输入，不改变 emoji 序列。
  static final RegExp _queryWhitespace = RegExp(r'\s+');

  /// 按类别原顺序排列且已经去重的完整目录。
  final List<NoteTagEmoji> entries;

  /// 当前图标的索引使随机排除无需每次复制目录。
  final Map<String, int> _indexByEmoji;

  /// 默认随机源在目录生命周期内复用，测试可注入替代源。
  final Random _random = Random();

  /// 成功加载共享 Future；失败后清除缓存，让浮层可以真正重试。
  static Future<NoteTagEmojiCatalog> load() =>
      _cachedLoad ??= _loadAsset().then(
        (catalog) => catalog,
        onError: (Object error, StackTrace stackTrace) {
          _cachedLoad = null;
          Error.throwWithStackTrace(error, stackTrace);
        },
      );

  /// 测试隔离全局缓存，正式界面通过 load 共享成功结果。
  @visibleForTesting
  static void resetCacheForTesting() => _cachedLoad = null;

  /// 解码内置资源；错误交给浮层展示，不伪装成空目录。
  static Future<NoteTagEmojiCatalog> _loadAsset() async {
    // 资源由 Flutter 资产包提供，运行时完全不请求网络。
    final String content = await rootBundle.loadString(assetPath, cache: false);
    // JSON 顶层同时含版本来源和许可，模型只消费条目。
    final Map<String, dynamic> document =
        jsonDecode(content) as Map<String, dynamic>;
    // 全部条目一次转换，后续分类、搜索和随机共用同一对象。
    final List<NoteTagEmoji> entries = (document['entries'] as List<dynamic>)
        .map((entry) => NoteTagEmoji._fromJson(entry as Map<String, dynamic>))
        .toList(growable: false);
    if (entries.isEmpty) {
      throw const FormatException('标签 emoji 目录为空');
    }
    return NoteTagEmojiCatalog._(entries);
  }

  /// 跨全部类别搜索中英文关键词或完整 emoji，空输入保留目录顺序。
  List<NoteTagEmoji> search(String query) {
    // 去除输入首尾空白，直接粘贴 emoji 也能精确匹配。
    final String normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return entries;
    // 多个词按“全部命中”处理；相同词只检查一次。
    final List<String> terms = normalized
        .split(_queryWhitespace)
        .toSet()
        .toList(growable: false);
    return List.unmodifiable(
      entries.where(
        (entry) => entry.emoji == normalized || entry._matches(terms),
      ),
    );
  }

  /// 从全目录等概率抽取，排除当前图标且不受搜索结果影响。
  NoteTagEmoji random({String? excluding, Random? random}) {
    // 当前值不在目录时不排除任何合法候选项。
    final int? excludedIndex = _indexByEmoji[excluding];
    // 排除一个条目后直接映射抽样索引，避免重试或无限循环。
    final int candidateCount = entries.length - (excludedIndex == null ? 0 : 1);
    if (candidateCount == 0) {
      throw StateError('没有可替换的标签 emoji');
    }
    // 确定性测试使用传入的随机源，界面默认复用目录随机源。
    final int sampledIndex = (random ?? _random).nextInt(candidateCount);
    // 越过被排除的下标，保证边界条目同样不会被重新选中。
    final int entryIndex =
        excludedIndex != null && sampledIndex >= excludedIndex
        ? sampledIndex + 1
        : sampledIndex;
    return entries[entryIndex];
  }
}
