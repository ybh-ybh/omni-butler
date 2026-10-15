import 'dart:convert';

/// 沿用本机音频编辑JSON存储，兼容旧的片段到插入标记映射。
class NoteDraftAudioEdits {
  /// 与正文一起提交的原始转写／候选插入记录。
  final Map<String, bool> insertions;

  /// 保存前暂存的片段删除，取消不会影响正式原音。
  final Set<String> deletions;

  /// 保存前暂存的图片删除，与音频保持独立身份集合。
  final Set<String> imageDeletions;

  /// 本机专用的删除元数据键，不进入同步协议。
  static const String _deletionKey = 'deletedAudioIds';

  /// 创建不可变的本机音频编辑快照。
  const NoteDraftAudioEdits({
    this.insertions = const {},
    this.deletions = const {},
    this.imageDeletions = const {},
  });

  /// 旧JSON的所有布尔标记保持原含义，新增数组只用于暂存删除。
  factory NoteDraftAudioEdits.fromJson(String source) {
    // 已落盘的音频编辑元数据。
    final Map<String, dynamic> values =
        jsonDecode(source) as Map<String, dynamic>;
    // 独立解析删除列表，不能把它当作一次正文插入。
    final dynamic removed = values[_deletionKey];
    return NoteDraftAudioEdits(
      insertions: {
        for (final MapEntry<String, dynamic> item in values.entries)
          if (item.value is bool) item.key: item.value as bool,
      },
      deletions: removed is List
          ? removed.whereType<String>().toSet()
          : const {},
      imageDeletions: values['deletedImageIds'] is List
          ? (values['deletedImageIds'] as List).whereType<String>().toSet()
          : const {},
    );
  }

  /// 无删除时保持旧JSON格式，不需要数据库或同步迁移。
  String toJson() => jsonEncode({
    ...insertions,
    if (deletions.isNotEmpty) _deletionKey: deletions.toList()..sort(),
    if (imageDeletions.isNotEmpty)
      'deletedImageIds': imageDeletions.toList()..sort(),
  });
}
