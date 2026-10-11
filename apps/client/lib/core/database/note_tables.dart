import 'package:drift/drift.dart';

/// 笔记正文；自然日与真实创建时间分别保存。
@DataClassName('NoteEntryRecord')
class NoteEntries extends Table {
  /// 稳定笔记标识。
  TextColumn get id => text()();

  /// 人工可编辑正文。
  TextColumn get body => text().withDefault(const Constant(''))();

  /// 不随时区漂移的归档自然日。
  TextColumn get dayKey => text()();

  /// 可选自定义类别身份。
  TextColumn get categoryId => text().nullable()();

  /// 删除类别后仍保留的历史名称。
  TextColumn get categoryName => text().nullable()();

  /// 多标签身份的 JSON 数组。
  TextColumn get tags => text().withDefault(const Constant('[]'))();

  /// 当前正文的稳定版本身份。
  TextColumn get revision => text()();

  /// 原始创建时间。
  DateTimeColumn get createdAt => dateTime()();

  /// 创建时设备时区名称与 UTC 偏移，历史未知值不推测。
  TextColumn get creationTimezone =>
      text().withDefault(const Constant('legacy:unknown'))();

  /// 最后修改时间。
  DateTimeColumn get updatedAt => dateTime()();

  /// 整篇进入回收站的时间。
  DateTimeColumn get deletedAt => dateTime().nullable()();

  /// 主键。
  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// 不可变正文版本，离线并发修改可恢复。
@DataClassName('NoteVersionRecord')
class NoteVersions extends Table {
  /// 稳定版本标识。
  TextColumn get id => text()();

  /// 所属笔记。
  TextColumn get noteId => text()();

  /// 此次正文快照。
  TextColumn get body => text()();

  /// 修改所基于的正文版本。
  TextColumn get baseRevision => text()();

  /// 新正文版本身份。
  TextColumn get revision => text()();

  /// 版本创建时间。
  DateTimeColumn get createdAt => dateTime()();

  /// 随笔记进入回收站。
  DateTimeColumn get deletedAt => dateTime().nullable()();

  /// 主键。
  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// 可同步的原音元数据与原始识别文本，不保存本机路径。
@DataClassName('NoteAudioSegmentRecord')
class NoteAudioSegments extends Table {
  /// 原音与识别操作的稳定身份。
  TextColumn get id => text()();

  /// 所属笔记。
  TextColumn get noteId => text()();

  /// 同篇录音顺序。
  IntColumn get sortOrder => integer()();

  /// 实际采样时长，不含暂停。
  IntColumn get durationMs => integer()();

  /// 原音类型。
  TextColumn get mime => text()();

  /// 原音 SHA256，缓存与迁移均须核验。
  TextColumn get sha256 => text()();

  /// 原音字节长度。
  IntColumn get byteSize => integer()();

  /// 供应商原始转写结果，与正文独立。
  TextColumn get transcript => text().nullable()();

  /// 原音创建时间。
  DateTimeColumn get createdAt => dateTime()();

  /// 转写或元数据更新时间。
  DateTimeColumn get updatedAt => dateTime()();

  /// 随笔记进入回收站。
  DateTimeColumn get deletedAt => dateTime().nullable()();

  /// 主键。
  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// 仅本机的文件缓存、识别授权和任务状态。
@DataClassName('NoteAudioLocalFileRecord')
class NoteAudioLocalFiles extends Table {
  /// 对应原音段身份。
  TextColumn get id => text()();

  /// 本机持久音频路径。
  TextColumn get localPath => text().nullable()();

  /// 文件传输状态。
  TextColumn get uploadState => text().withDefault(const Constant('pending'))();

  /// 已持久化识别操作身份。
  TextColumn get recognitionId => text().nullable()();

  /// 当前识别状态。
  TextColumn get recognitionState =>
      text().withDefault(const Constant('idle'))();

  /// 最近失败原因。
  TextColumn get lastError => text().nullable()();

  /// 用户是否同意将本段提交供应商。
  BoolColumn get consent => boolean().withDefault(const Constant(false))();

  /// 已插入正文的版本；waiting:前缀记录首次转写预留位置的起点版本。
  TextColumn get insertedRevision => text().nullable()();

  /// 重新转写的本机候选，不覆盖共享原始转写。
  TextColumn get candidateTranscript => text().nullable()();

  /// 主键。
  @override
  Set<Column<Object>> get primaryKey => {id};
}
