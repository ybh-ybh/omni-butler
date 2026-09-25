import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:uuid/uuid.dart';

part 'app_database.g.dart';

/// 用业务身份生成跨设备一致的 UUID，不包含设备时间或随机量。
String stableBusinessId(String kind, List<String> parts) => const Uuid().v5(
  Namespace.url.value,
  'https://omni-butler.local/$kind/${parts.map(Uri.encodeComponent).join('/')}',
);

/// 将业务自然日编码为不受设备时区换算影响的日期键。
String businessDayKey(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

/// 待办记录表。
@DataClassName('TodoRecord')
class TodoItems extends Table {
  /// 客户端生成的稳定标识。
  TextColumn get id => text()();

  /// 待办标题。
  TextColumn get title => text().withLength(min: 1, max: 200)();

  /// 待办描述。
  TextColumn get description => text().nullable()();

  /// 可选父任务标识；为空表示主任务。
  TextColumn get parentId => text().nullable()();

  /// 所属自然日。
  DateTimeColumn get scheduledDate => dateTime()();

  /// 可选截止时间。
  DateTimeColumn get dueAt => dateTime().nullable()();

  /// 四象限优先分类。
  IntColumn get priorityQuadrant =>
      integer().withDefault(const Constant<int>(2))();

  /// 是否已经完成。
  BoolColumn get isCompleted =>
      boolean().withDefault(const Constant<bool>(false))();

  /// 完成时间。
  DateTimeColumn get completedAt => dateTime().nullable()();

  /// 提醒时间。
  DateTimeColumn get reminderAt => dateTime().nullable()();

  /// 重复规则。
  TextColumn get repeatRule => text().nullable()();

  /// 重复系列标识。
  TextColumn get repeatSeriesId => text().nullable()();

  /// 用户排序值。
  IntColumn get sortOrder => integer().withDefault(const Constant<int>(0))();

  /// 同步状态。
  TextColumn get syncState =>
      text().withDefault(const Constant<String>('localSaved'))();

  /// 创建时间。
  DateTimeColumn get createdAt => dateTime()();

  /// 更新时间。
  DateTimeColumn get updatedAt => dateTime()();

  /// 软删除时间。
  DateTimeColumn get deletedAt => dateTime().nullable()();

  /// 使用稳定标识作为主键。
  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// 名言库记录表。
@DataClassName('QuoteRecord')
class Quotes extends Table {
  /// 名言稳定标识。
  TextColumn get id => text()();

  /// 名言正文。
  TextColumn get content => text().withLength(min: 1, max: 1000)();

  /// 名言出处。
  TextColumn get source => text().nullable()();

  /// 是否参与每日选择。
  BoolColumn get isEnabled =>
      boolean().withDefault(const Constant<bool>(true))();

  /// 创建时间。
  DateTimeColumn get createdAt => dateTime()();

  /// 更新时间。
  DateTimeColumn get updatedAt => dateTime()();

  /// 软删除时间。
  DateTimeColumn get deletedAt => dateTime().nullable()();

  /// 使用稳定标识作为主键。
  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// 每日名言选择表。
@DataClassName('DailyQuoteSelectionRecord')
class DailyQuoteSelections extends Table {
  /// 每日选择稳定标识。
  TextColumn get id => text()();

  /// 自然日文本标识。
  TextColumn get dayKey => text()();

  /// 当日名言标识。
  TextColumn get quoteId =>
      text().nullable().references(Quotes, #id, onDelete: KeyAction.setNull)();

  /// 创建时间。
  DateTimeColumn get createdAt => dateTime()();

  /// 更新时间。
  DateTimeColumn get updatedAt => dateTime()();

  /// 使用稳定标识作为主键。
  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  /// 每个自然日只保存一条选择。
  @override
  List<Set<Column<Object>>> get uniqueKeys => <Set<Column<Object>>>[
    <Column<Object>>{dayKey},
  ];
}

/// 首页横幅设置表。
class BannerSettings extends Table {
  /// 横幅设置稳定标识。
  TextColumn get id => text()();

  /// 固定设置键。
  TextColumn get key => text()();

  /// 当前背景附件标识。
  TextColumn get attachmentId => text().nullable()();

  /// 图片遮罩强度。
  RealColumn get overlayStrength =>
      real().withDefault(const Constant<double>(0.45))();

  /// 自定义文字颜色值。
  IntColumn get textColorValue => integer().nullable()();

  /// 更新时间。
  DateTimeColumn get updatedAt => dateTime()();

  /// 使用稳定标识作为主键。
  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  /// 每种设置键只保存一条配置。
  @override
  List<Set<Column<Object>>> get uniqueKeys => <Set<Column<Object>>>[
    <Column<Object>>{key},
  ];
}

/// 本地附件表；云端字段留待下一期附件同步使用。
class Attachments extends Table {
  /// 附件稳定标识。
  TextColumn get id => text()();

  /// 业务类型。
  TextColumn get businessType => text()();

  /// 所属业务记录标识。
  TextColumn get businessId => text()();

  /// 当前设备私有文件路径。
  TextColumn get localPath => text().nullable()();

  /// 下一期云端对象键。
  TextColumn get objectKey => text().nullable()();

  /// 文件 MIME 类型。
  TextColumn get mimeType => text().nullable()();

  /// 文件字节数。
  IntColumn get sizeBytes => integer().nullable()();

  /// 文件 SHA-256 摘要。
  TextColumn get sha256 => text().nullable()();

  /// 本地保存或下一期云端上传状态。
  TextColumn get uploadState =>
      text().withDefault(const Constant<String>('localOnly'))();

  /// 最近一次失败原因。
  TextColumn get lastError => text().nullable()();

  /// 创建时间。
  DateTimeColumn get createdAt => dateTime()();

  /// 更新时间。
  DateTimeColumn get updatedAt => dateTime()();

  /// 软删除时间。
  DateTimeColumn get deletedAt => dateTime().nullable()();

  /// 使用稳定标识作为主键。
  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// 模块内分类与标签表。
class TaxonomyEntries extends Table {
  /// 分类或标签稳定标识。
  TextColumn get id => text()();

  /// 所属模块。
  TextColumn get module => text()();

  /// category 或 tag 类型。
  TextColumn get kind => text()();

  /// 显示名称。
  TextColumn get name => text()();

  /// ARGB 颜色值。
  IntColumn get colorValue => integer()();

  /// 用户排序值。
  IntColumn get sortOrder => integer().withDefault(const Constant<int>(0))();

  /// 是否允许用于新记录。
  BoolColumn get isEnabled =>
      boolean().withDefault(const Constant<bool>(true))();

  /// 创建时间。
  DateTimeColumn get createdAt => dateTime()();

  /// 更新时间。
  DateTimeColumn get updatedAt => dateTime()();

  /// 软删除时间。
  DateTimeColumn get deletedAt => dateTime().nullable()();

  /// 使用稳定标识作为主键。
  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// 业务记录与分类标签关联表。
class RecordTaxonomyLinks extends Table {
  /// 关联稳定标识。
  TextColumn get id => text()();

  /// 所属模块。
  TextColumn get module => text()();

  /// 业务记录标识。
  TextColumn get recordId => text()();

  /// 分类或标签标识。
  TextColumn get taxonomyId => text().references(TaxonomyEntries, #id)();

  /// 创建时间。
  DateTimeColumn get createdAt => dateTime()();

  /// 软删除时间。
  DateTimeColumn get deletedAt => dateTime().nullable()();

  /// 使用稳定标识作为主键。
  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// 周期事件表。
@DataClassName('EventRecord')
class Events extends Table {
  /// 事件稳定标识。
  TextColumn get id => text()();

  /// 事件名称。
  TextColumn get name => text().withLength(min: 1, max: 200)();

  /// 事件分类。
  TextColumn get category => text().nullable()();

  /// 事件说明。
  TextColumn get description => text().nullable()();

  /// 周期间隔数值。
  IntColumn get intervalValue =>
      integer().withDefault(const Constant<int>(1))();

  /// 周期单位。
  TextColumn get intervalUnit =>
      text().withDefault(const Constant<String>('month'))();

  /// 最近完成时间。
  DateTimeColumn get lastCompletedAt => dateTime().nullable()();

  /// 是否启用提醒。
  BoolColumn get reminderEnabled =>
      boolean().withDefault(const Constant<bool>(false))();

  /// 提前提醒天数。
  IntColumn get reminderDaysBefore =>
      integer().withDefault(const Constant<int>(0))();

  /// 提醒时刻相对午夜的分钟数。
  IntColumn get reminderTimeMinutes =>
      integer().withDefault(const Constant<int>(540))();

  /// 是否归档。
  BoolColumn get isArchived =>
      boolean().withDefault(const Constant<bool>(false))();

  /// 归档时间。
  DateTimeColumn get archivedAt => dateTime().nullable()();

  /// 备注。
  TextColumn get notes => text().nullable()();

  /// 同步状态。
  TextColumn get syncState =>
      text().withDefault(const Constant<String>('localSaved'))();

  /// 创建时间。
  DateTimeColumn get createdAt => dateTime()();

  /// 更新时间。
  DateTimeColumn get updatedAt => dateTime()();

  /// 软删除时间。
  DateTimeColumn get deletedAt => dateTime().nullable()();

  /// 使用稳定标识作为主键。
  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// 周期事件完成历史表。
@DataClassName('EventCompletionRecord')
class EventCompletions extends Table {
  /// 历史稳定标识。
  TextColumn get id => text()();

  /// 所属事件标识。
  TextColumn get eventId => text().references(Events, #id)();

  /// 完成时间。
  DateTimeColumn get completedAt => dateTime()();

  /// 历史备注。
  TextColumn get notes => text().nullable()();

  /// 完成记录来源。
  TextColumn get source =>
      text().withDefault(const Constant<String>('manual'))();

  /// 是否已撤销。
  BoolColumn get isRevoked =>
      boolean().withDefault(const Constant<bool>(false))();

  /// 创建时间。
  DateTimeColumn get createdAt => dateTime()();

  /// 软删除时间。
  DateTimeColumn get deletedAt => dateTime().nullable()();

  /// 使用稳定标识作为主键。
  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// 物品记录表。
@DataClassName('InventoryRecord')
class InventoryItems extends Table {
  /// 物品稳定标识。
  TextColumn get id => text()();

  /// 物品名称。
  TextColumn get name => text().withLength(min: 1, max: 200)();

  /// 分类名称。
  TextColumn get category => text().nullable()();

  /// 数量。
  IntColumn get quantity => integer().withDefault(const Constant<int>(1))();

  /// 购买金额分值。
  IntColumn get purchasePriceCents => integer().nullable()();

  /// 购买日期。
  DateTimeColumn get purchaseDate => dateTime().nullable()();

  /// 购买链接。
  TextColumn get purchaseUrl => text().nullable()();

  /// 购买平台。
  TextColumn get purchasePlatform => text().nullable()();

  /// 存放位置。
  TextColumn get location => text().nullable()();

  /// 在用、闲置、已借出、已售出或已丢弃状态。
  TextColumn get status =>
      text().withDefault(const Constant<String>('inUse'))();

  /// 保修到期日。
  DateTimeColumn get warrantyExpiration => dateTime().nullable()();

  /// 逗号分隔标签。
  TextColumn get tags => text().nullable()();

  /// 父物品标识。
  TextColumn get parentItemId => text().nullable()();

  /// 本地图片路径。
  TextColumn get imageLocalPath => text().nullable()();

  /// 云端附件标识。
  TextColumn get imageAttachmentId => text().nullable()();

  /// 备注。
  TextColumn get notes => text().nullable()();

  /// 同步状态。
  TextColumn get syncState =>
      text().withDefault(const Constant<String>('localSaved'))();

  /// 创建时间。
  DateTimeColumn get createdAt => dateTime()();

  /// 更新时间。
  DateTimeColumn get updatedAt => dateTime()();

  /// 软删除时间。
  DateTimeColumn get deletedAt => dateTime().nullable()();

  /// 使用稳定标识作为主键。
  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// 24 小时时间记录表。
@DataClassName('TimeEntryRecord')
class TimeEntries extends Table {
  /// 时间记录稳定标识。
  TextColumn get id => text()();

  /// 兼容旧客户端的起始自然日。
  DateTimeColumn get entryDate => dateTime()();

  /// 兼容旧客户端的起始分钟数。
  IntColumn get startMinute => integer()();

  /// 兼容旧客户端的结束分钟数；跨天时允许大于 1440，进行中时等于开始分钟数。
  IntColumn get endMinute => integer()();

  /// 绝对开始时间。
  DateTimeColumn get startedAt => dateTime()();

  /// 绝对结束时间；为空表示记录仍在进行。
  DateTimeColumn get endedAt => dateTime().nullable()();

  /// 活动内容；进行中记录允许稍后补充。
  TextColumn get activity => text().withLength(max: 200).nullable()();

  /// 活动类别。
  TextColumn get category => text().nullable()();

  /// 备注。
  TextColumn get notes => text().nullable()();

  /// 同步状态。
  TextColumn get syncState =>
      text().withDefault(const Constant<String>('localSaved'))();

  /// 创建时间。
  DateTimeColumn get createdAt => dateTime()();

  /// 更新时间。
  DateTimeColumn get updatedAt => dateTime()();

  /// 软删除时间。
  DateTimeColumn get deletedAt => dateTime().nullable()();

  /// 使用稳定标识作为主键。
  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// 软件与工具会员表。
@DataClassName('MembershipRecord')
class Memberships extends Table {
  /// 会员稳定标识。
  TextColumn get id => text()();

  /// 会员名称。
  TextColumn get name => text().withLength(min: 1, max: 200)();

  /// 服务提供方。
  TextColumn get provider => text().nullable()();

  /// 分类名称。
  TextColumn get category => text().nullable()();

  /// 会员说明。
  TextColumn get description => text().nullable()();

  /// 官方网站。
  TextColumn get websiteUrl => text().nullable()();

  /// 购买平台。
  TextColumn get purchasePlatform => text().nullable()();

  /// 价格分值。
  IntColumn get priceCents => integer().withDefault(const Constant<int>(0))();

  /// 计费周期。
  TextColumn get billingCycle =>
      text().withDefault(const Constant<String>('year'))();

  /// 试用中、使用中或已取消基础状态。
  TextColumn get baseStatus =>
      text().withDefault(const Constant<String>('active'))();

  /// 购买日期。
  DateTimeColumn get purchaseDate => dateTime()();

  /// 到期日期。
  DateTimeColumn get expirationDate => dateTime().nullable()();

  /// 是否永久有效。
  BoolColumn get isPermanent =>
      boolean().withDefault(const Constant<bool>(false))();

  /// 是否自动续费。
  BoolColumn get autoRenew =>
      boolean().withDefault(const Constant<bool>(false))();

  /// 下次续费日期。
  DateTimeColumn get renewalDate => dateTime().nullable()();

  /// 是否明确需要续费。
  BoolColumn get needsRenewal =>
      boolean().withDefault(const Constant<bool>(false))();

  /// 是否开启到期提醒。
  BoolColumn get expirationReminderEnabled =>
      boolean().withDefault(const Constant<bool>(false))();

  /// 到期提醒提前天数。
  IntColumn get expirationReminderDays =>
      integer().withDefault(const Constant<int>(30))();

  /// 是否开启自动续费提醒。
  BoolColumn get renewalReminderEnabled =>
      boolean().withDefault(const Constant<bool>(false))();

  /// 自动续费提醒提前天数。
  IntColumn get renewalReminderDays =>
      integer().withDefault(const Constant<int>(7))();

  /// 提醒时刻相对午夜的分钟数。
  IntColumn get reminderTimeMinutes =>
      integer().withDefault(const Constant<int>(540))();

  /// 取消续费说明。
  TextColumn get cancelGuide => text().nullable()();

  /// 备注。
  TextColumn get notes => text().nullable()();

  /// 本地图片路径。
  TextColumn get imageLocalPath => text().nullable()();

  /// 云端附件标识。
  TextColumn get imageAttachmentId => text().nullable()();

  /// 同步状态。
  TextColumn get syncState =>
      text().withDefault(const Constant<String>('localSaved'))();

  /// 创建时间。
  DateTimeColumn get createdAt => dateTime()();

  /// 更新时间。
  DateTimeColumn get updatedAt => dateTime()();

  /// 软删除时间。
  DateTimeColumn get deletedAt => dateTime().nullable()();

  /// 使用稳定标识作为主键。
  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// 会员购买与续费历史表。
@DataClassName('MembershipPaymentRecord')
class MembershipPayments extends Table {
  /// 历史稳定标识。
  TextColumn get id => text()();

  /// 所属会员标识。
  TextColumn get membershipId => text().references(Memberships, #id)();

  /// 支付金额分值。
  IntColumn get amountCents => integer()();

  /// 支付时间。
  DateTimeColumn get paidAt => dateTime()();

  /// 本次有效期开始时间。
  DateTimeColumn get validFrom => dateTime().nullable()();

  /// 本次有效期结束时间。
  DateTimeColumn get validUntil => dateTime().nullable()();

  /// 历史备注。
  TextColumn get notes => text().nullable()();

  /// 创建时间。
  DateTimeColumn get createdAt => dateTime()();

  /// 软删除时间。
  DateTimeColumn get deletedAt => dateTime().nullable()();

  /// 使用稳定标识作为主键。
  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// 应用本地数据库。
@DriftDatabase(
  tables: <Type>[
    TodoItems,
    Quotes,
    DailyQuoteSelections,
    BannerSettings,
    Attachments,
    TaxonomyEntries,
    RecordTaxonomyLinks,
    Events,
    EventCompletions,
    InventoryItems,
    TimeEntries,
    Memberships,
    MembershipPayments,
  ],
)
class AppDatabase extends _$AppDatabase {
  /// 创建默认持久化数据库。
  AppDatabase() : super(driftDatabase(name: 'omni_butler'));

  /// 使用外部 PowerSync 连接创建生产数据库。
  AppDatabase.withExecutor(super.executor);

  /// 创建可注入执行器的数据库用于测试。
  AppDatabase.forTesting(super.executor);

  /// 当前数据库结构版本。
  @override
  int get schemaVersion => 13;

  /// 创建数据库并从旧版本安全升级。
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator migrator) async {
      await migrator.createAll();
      await _createTodoIndexes();
    },
    onUpgrade: (Migrator migrator, int from, int to) async {
      if (from < 2) {
        await migrator.createTable(bannerSettings);
        await migrator.createTable(attachments);
        await migrator.createTable(taxonomyEntries);
        await migrator.createTable(recordTaxonomyLinks);
        await migrator.addColumn(events, events.description);
        await migrator.addColumn(events, events.reminderTimeMinutes);
        await migrator.addColumn(events, events.archivedAt);
        await migrator.addColumn(eventCompletions, eventCompletions.source);
        await migrator.addColumn(eventCompletions, eventCompletions.isRevoked);
        await migrator.addColumn(inventoryItems, inventoryItems.purchaseUrl);
        await migrator.addColumn(inventoryItems, inventoryItems.status);
        await migrator.addColumn(
          inventoryItems,
          inventoryItems.warrantyExpiration,
        );
        await migrator.addColumn(memberships, memberships.description);
        await migrator.addColumn(memberships, memberships.websiteUrl);
        await migrator.addColumn(memberships, memberships.purchasePlatform);
        await migrator.addColumn(memberships, memberships.billingCycle);
        await migrator.addColumn(memberships, memberships.baseStatus);
        await migrator.addColumn(memberships, memberships.needsRenewal);
        await migrator.addColumn(
          memberships,
          memberships.expirationReminderEnabled,
        );
        await migrator.addColumn(
          memberships,
          memberships.expirationReminderDays,
        );
        await migrator.addColumn(
          memberships,
          memberships.renewalReminderEnabled,
        );
        await migrator.addColumn(memberships, memberships.renewalReminderDays);
        await migrator.addColumn(memberships, memberships.reminderTimeMinutes);
        await migrator.addColumn(
          membershipPayments,
          membershipPayments.validFrom,
        );
        await migrator.addColumn(
          membershipPayments,
          membershipPayments.validUntil,
        );
      }
      if (from < 6) {
        final List<QueryRow> inventoryColumns = await customSelect(
          "PRAGMA table_info('inventory_items')",
        ).get();
        final bool hasPurchasePlatform = inventoryColumns.any(
          (QueryRow row) => row.read<String>('name') == 'purchase_platform',
        );
        if (!hasPurchasePlatform) {
          await migrator.addColumn(
            inventoryItems,
            inventoryItems.purchasePlatform,
          );
        }
      }
      if (from < 3) {
        await _migrateToSyncCompatibleSchema();
      }
      if (from < 4) {
        await customStatement(
          "UPDATE attachments SET upload_state = 'localOnly', "
          'object_key = NULL, last_error = NULL',
        );
      }
      if (from < 5) {
        await customStatement(
          'ALTER TABLE todo_items RENAME COLUMN urgency TO priority_quadrant',
        );
        await migrator.alterTable(TableMigration(todoItems));
      }
      if (from < 7) {
        // 按当前表定义重建物品表，永久删除已下线的品牌与型号列。
        await migrator.alterTable(TableMigration(inventoryItems));
      }
      if (from < 8) {
        // 当前时间记录表字段信息。
        final List<QueryRow> timeEntryColumns = await customSelect(
          "PRAGMA table_info('time_entries')",
        ).get();
        // 是否已经存在绝对开始时间列。
        final bool hasStartedAt = timeEntryColumns.any(
          (QueryRow row) => row.read<String>('name') == 'started_at',
        );
        if (!hasStartedAt) {
          // 先添加可空绝对时间列，确保旧记录可以原地回填。
          await customStatement(
            'ALTER TABLE time_entries ADD COLUMN started_at TEXT',
          );
          await customStatement(
            'ALTER TABLE time_entries ADD COLUMN ended_at TEXT',
          );
          // 将旧自然日和分钟偏移转换为跨天安全的绝对时间。
          await customStatement('''
UPDATE time_entries
SET started_at = datetime(entry_date, printf('+%d minutes', start_minute)),
    ended_at = datetime(entry_date, printf('+%d minutes', end_minute))
''');
          // 按 v8 定义重建表，使开始时间必填并允许进行中记录暂不填写活动内容。
          await migrator.alterTable(TableMigration(timeEntries));
        }
      }
      if (from < 9) {
        // 当前待办表字段信息。
        final List<QueryRow> todoColumns = await customSelect(
          "PRAGMA table_info('todo_items')",
        ).get();
        // 是否已经存在父任务字段。
        final bool hasParentId = todoColumns.any(
          (QueryRow row) => row.read<String>('name') == 'parent_id',
        );
        if (!hasParentId) {
          // 为旧待办补充可空父任务字段，旧记录继续作为主任务。
          await migrator.addColumn(todoItems, todoItems.parentId);
        }
        await _createTodoIndexes();
      }
      if (from < 10) {
        // 按 v10 定义重建待办表，直接丢弃已下线的备注列及旧数据。
        await migrator.alterTable(TableMigration(todoItems));
        await _createTodoIndexes();
      }
      if (from < 11) {
        // 重建表以删除未被业务读取的展示冗余列，其余数据保持原样。
        await migrator.alterTable(TableMigration(dailyQuoteSelections));
        await migrator.alterTable(TableMigration(taxonomyEntries));
      }
      if (from < 12) {
        // 删除无消费的会员隐藏字段及支付周期副本，保留会员计费规则和支付有效期。
        await migrator.alterTable(TableMigration(memberships));
        await migrator.alterTable(TableMigration(membershipPayments));
      }
      if (from < 13) {
        // 每日选择身份永久保留，删除名言只清空可选引用。
        await migrator.alterTable(TableMigration(dailyQuoteSelections));
      }
    },
  );

  /// 创建待办树、排序和完成历史查询索引。
  Future<void> _createTodoIndexes() async {
    await customStatement(
      'CREATE INDEX IF NOT EXISTS todo_items_parent_sort_idx '
      'ON todo_items(parent_id, sort_order)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS todo_items_completed_at_idx '
      'ON todo_items(is_completed, completed_at)',
    );
  }

  /// 监听全部未删除待办，用于在仓储层组装进行中的任务树。
  Stream<List<TodoRecord>> watchAllTodos() {
    // 全部有效待办查询。
    final query = select(todoItems)
      ..where((TodoItems table) => table.deletedAt.isNull())
      ..orderBy(<OrderingTerm Function(TodoItems)>[
        (TodoItems table) => OrderingTerm.desc(table.priorityQuadrant),
        (TodoItems table) => OrderingTerm.asc(table.sortOrder),
        (TodoItems table) => OrderingTerm.asc(table.createdAt),
      ]);
    return query.watch();
  }

  /// 监听指定完成日期的历史待办。
  Stream<List<TodoRecord>> watchCompletedTodosForDay(DateTime day) {
    // 指定完成自然日的零点。
    final DateTime start = DateTime(day.year, day.month, day.day);
    // 下一自然日的零点。
    final DateTime end = start.add(const Duration(days: 1));
    // 当天完成记录查询。
    final query = select(todoItems)
      ..where(
        (TodoItems table) =>
            table.isCompleted.equals(true) &
            table.completedAt.isBiggerOrEqualValue(start) &
            table.completedAt.isSmallerThanValue(end) &
            table.deletedAt.isNull(),
      )
      ..orderBy(<OrderingTerm Function(TodoItems)>[
        (TodoItems table) => OrderingTerm.desc(table.completedAt),
        (TodoItems table) => OrderingTerm.asc(table.createdAt),
      ]);
    return query.watch();
  }

  /// 按 PRD 排序规则监听指定自然日的有效待办。
  Stream<List<TodoRecord>> watchTodosForDay(DateTime day) {
    // 指定自然日的零点。
    final DateTime start = DateTime(day.year, day.month, day.day);
    // 下一自然日的零点。
    final DateTime end = start.add(const Duration(days: 1));
    // 指定自然日待办查询。
    final query = select(todoItems)
      ..where(
        (TodoItems table) =>
            table.scheduledDate.isBiggerOrEqualValue(start) &
            table.scheduledDate.isSmallerThanValue(end) &
            table.parentId.isNull() &
            table.deletedAt.isNull(),
      )
      ..orderBy(<OrderingTerm Function(TodoItems)>[
        (TodoItems table) => OrderingTerm.asc(table.isCompleted),
        (TodoItems table) => OrderingTerm.desc(table.priorityQuadrant),
        (TodoItems table) => OrderingTerm.asc(table.sortOrder),
        (TodoItems table) => OrderingTerm.asc(table.createdAt),
      ]);
    return query.watch();
  }

  /// 监听全部回收站待办。
  Stream<List<TodoRecord>> watchDeletedTodos() {
    // 回收站待办查询。
    final query = select(todoItems)
      ..where((TodoItems table) => table.deletedAt.isNotNull())
      ..orderBy(<OrderingTerm Function(TodoItems)>[
        (TodoItems table) => OrderingTerm.desc(table.deletedAt),
      ]);
    return query.watch();
  }

  /// 新增一条待办。
  Future<void> createTodo(TodoItemsCompanion companion) async {
    await into(todoItems).insert(companion);
  }

  /// 更新一条现有待办的可编辑字段。
  Future<void> updateTodo(String id, TodoItemsCompanion companion) async {
    await (update(
      todoItems,
    )..where((TodoItems table) => table.id.equals(id))).write(companion);
  }

  /// 切换待办完成状态。
  Future<void> setTodoCompleted(String id, bool completed) async {
    // 当前操作时间。
    final DateTime now = DateTime.now();
    await (update(
      todoItems,
    )..where((TodoItems table) => table.id.equals(id))).write(
      TodoItemsCompanion(
        isCompleted: Value<bool>(completed),
        completedAt: Value<DateTime?>(completed ? now : null),
        updatedAt: Value<DateTime>(now),
        syncState: const Value<String>('localSaved'),
      ),
    );
  }

  /// 将待办移入回收站。
  Future<void> softDeleteTodo(String id) async {
    // 当前删除时间。
    final DateTime now = DateTime.now();
    await (update(
      todoItems,
    )..where((TodoItems table) => table.id.equals(id))).write(
      TodoItemsCompanion(
        deletedAt: Value<DateTime>(now),
        updatedAt: Value<DateTime>(now),
        syncState: const Value<String>('localSaved'),
      ),
    );
  }

  /// 从回收站恢复待办。
  Future<void> restoreTodo(String id) async {
    // 当前恢复时间。
    final DateTime now = DateTime.now();
    await (update(
      todoItems,
    )..where((TodoItems table) => table.id.equals(id))).write(
      TodoItemsCompanion(
        deletedAt: const Value<DateTime?>(null),
        updatedAt: Value<DateTime>(now),
        syncState: const Value<String>('localSaved'),
      ),
    );
  }

  /// 永久删除一条待办。
  Future<void> permanentlyDeleteTodo(String id) async {
    await (delete(
      todoItems,
    )..where((TodoItems table) => table.id.equals(id))).go();
  }

  /// 返回指定自然日的稳定名言。
  Future<QuoteRecord?> quoteForDay(DateTime day) async {
    await _ensureDefaultQuotes();
    // 当日键值。
    final String dayKey = _dayKey(day);
    // 已保存的当日选择。
    final DailyQuoteSelectionRecord? selection =
        await (select(dailyQuoteSelections)..where(
              (DailyQuoteSelections table) => table.dayKey.equals(dayKey),
            ))
            .getSingleOrNull();
    if (selection?.quoteId != null) {
      // 已选择的名言。
      final QuoteRecord? selectedQuote =
          await (select(quotes)..where(
                (Quotes table) =>
                    table.id.equals(selection!.quoteId!) &
                    table.isEnabled.equals(true) &
                    table.deletedAt.isNull(),
              ))
              .getSingleOrNull();
      if (selectedQuote != null) {
        return selectedQuote;
      }
    }

    // 全部可用名言。
    final List<QuoteRecord> enabledQuotes =
        await (select(quotes)
              ..where(
                (Quotes table) =>
                    table.isEnabled.equals(true) & table.deletedAt.isNull(),
              )
              ..orderBy(<OrderingTerm Function(Quotes)>[
                (Quotes table) => OrderingTerm.asc(table.createdAt),
              ]))
            .get();
    if (enabledQuotes.isEmpty) {
      if (selection != null && selection.quoteId == null) {
        return null;
      }
      // 没有可选名言也保留每日身份，避免永久删除后重建同一墓碑记录。
      final DateTime now = DateTime.now();
      await into(dailyQuoteSelections).insertOnConflictUpdate(
        DailyQuoteSelectionsCompanion.insert(
          id:
              selection?.id ??
              stableBusinessId('daily-quote', <String>[dayKey]),
          dayKey: dayKey,
          quoteId: const Value<String?>(null),
          createdAt: selection?.createdAt ?? now,
          updatedAt: now,
        ),
      );
      return null;
    }
    // 基于日期字符的稳定索引。
    final int stableIndex =
        dayKey.codeUnits.fold<int>(0, (int sum, int value) => sum + value) %
        enabledQuotes.length;
    // 今日选中的名言。
    final QuoteRecord quote = enabledQuotes[stableIndex];
    // 当前写入时间。
    final DateTime now = DateTime.now();
    await into(dailyQuoteSelections).insertOnConflictUpdate(
      DailyQuoteSelectionsCompanion.insert(
        id: selection?.id ?? stableBusinessId('daily-quote', <String>[dayKey]),
        dayKey: dayKey,
        quoteId: Value<String?>(quote.id),
        createdAt: selection?.createdAt ?? now,
        updatedAt: now,
      ),
    );
    return quote;
  }

  /// 手动切换指定自然日的名言。
  Future<QuoteRecord?> changeQuoteForDay(DateTime day) async {
    await _ensureDefaultQuotes();
    // 当前名言。
    final QuoteRecord? current = await quoteForDay(day);
    if (current == null) {
      return null;
    }
    // 全部可用名言。
    final List<QuoteRecord> enabledQuotes =
        await (select(quotes)
              ..where(
                (Quotes table) =>
                    table.isEnabled.equals(true) & table.deletedAt.isNull(),
              )
              ..orderBy(<OrderingTerm Function(Quotes)>[
                (Quotes table) => OrderingTerm.asc(table.createdAt),
              ]))
            .get();
    // 当前名言索引。
    final int currentIndex = enabledQuotes.indexWhere(
      (QuoteRecord item) => item.id == current.id,
    );
    // 下一条名言。
    final QuoteRecord next =
        enabledQuotes[(currentIndex + 1) % enabledQuotes.length];
    // 当前更新时间。
    final DateTime now = DateTime.now();
    await (update(dailyQuoteSelections)..where(
          (DailyQuoteSelections table) => table.dayKey.equals(_dayKey(day)),
        ))
        .write(
          DailyQuoteSelectionsCompanion(
            quoteId: Value<String>(next.id),
            updatedAt: Value<DateTime>(now),
          ),
        );
    return next;
  }

  /// 仅为从未使用过名言的空库生成内置数据，不复活被删除的稳定身份。
  Future<void> _ensureDefaultQuotes() async {
    // 任意现存名言都表示已经初始化，包括停用和软删除记录。
    final int count =
        await (selectOnly(quotes)
              ..addColumns(<Expression<Object>>[quotes.id.count()]))
            .map((TypedResult row) => row.read(quotes.id.count()) ?? 0)
            .getSingle();
    if (count > 0) {
      return;
    }
    // 永久清空名言仍保留每日选择，防止重复创建云端已经墓碑化的内置身份。
    final List<DailyQuoteSelectionRecord> previousSelections = await (select(
      dailyQuoteSelections,
    )..limit(1)).get();
    if (previousSelections.isNotEmpty) {
      return;
    }
    // 内置名言创建时间。
    final DateTime now = DateTime.now();
    await into(quotes).insertOnConflictUpdate(
      QuotesCompanion.insert(
        id: stableBusinessId('builtin-quote', <String>['quiet']),
        content: '把今天过好，便是在为明天留出余地。',
        source: const Value<String>('Omni Butler'),
        isEnabled: const Value<bool>(true),
        deletedAt: const Value<DateTime?>(null),
        createdAt: now,
        updatedAt: now,
      ),
    );
    await into(quotes).insertOnConflictUpdate(
      QuotesCompanion.insert(
        id: stableBusinessId('builtin-quote', <String>['time']),
        content: '时间不是被填满的容器，而是被认真看见的生活。',
        source: const Value<String>('Omni Butler'),
        isEnabled: const Value<bool>(true),
        deletedAt: const Value<DateTime?>(null),
        createdAt: now.add(const Duration(milliseconds: 1)),
        updatedAt: now.add(const Duration(milliseconds: 1)),
      ),
    );
  }

  /// 将日期格式化为稳定自然日键。
  String _dayKey(DateTime day) {
    // 四位年份。
    final String year = day.year.toString().padLeft(4, '0');
    // 两位月份。
    final String month = day.month.toString().padLeft(2, '0');
    // 两位日期。
    final String date = day.day.toString().padLeft(2, '0');
    return '$year-$month-$date';
  }

  /// 将 v1/v2 数据库升级为可由 PowerSync 原生同步的字段结构。
  Future<void> _migrateToSyncCompatibleSchema() async {
    await customStatement('''
CREATE TABLE daily_quote_selections_v3 (
  id TEXT NOT NULL PRIMARY KEY,
  day_key TEXT NOT NULL UNIQUE,
  quote_id TEXT NOT NULL,
  is_manual INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
)
''');
    await customStatement('''
INSERT INTO daily_quote_selections_v3
  (id, day_key, quote_id, is_manual, created_at, updated_at)
SELECT
  lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' ||
  substr(lower(hex(randomblob(2))), 2) || '-' ||
  substr('89ab', abs(random()) % 4 + 1, 1) ||
  substr(lower(hex(randomblob(2))), 2) || '-' || lower(hex(randomblob(6))),
  day_key,
  quote_id,
  is_manual,
  CASE WHEN typeof(created_at) = 'integer'
    THEN strftime('%Y-%m-%dT%H:%M:%SZ', created_at, 'unixepoch')
    ELSE created_at END,
  CASE WHEN typeof(updated_at) = 'integer'
    THEN strftime('%Y-%m-%dT%H:%M:%SZ', updated_at, 'unixepoch')
    ELSE updated_at END
FROM daily_quote_selections
''');
    await customStatement('DROP TABLE daily_quote_selections');
    await customStatement(
      'ALTER TABLE daily_quote_selections_v3 RENAME TO daily_quote_selections',
    );
    await customStatement('''
CREATE TABLE banner_settings_v3 (
  id TEXT NOT NULL PRIMARY KEY,
  key TEXT NOT NULL UNIQUE,
  attachment_id TEXT,
  overlay_strength REAL NOT NULL DEFAULT 0.45,
  text_color_value INTEGER,
  updated_at TEXT NOT NULL
)
''');
    await customStatement('''
INSERT INTO banner_settings_v3
  (id, key, attachment_id, overlay_strength, text_color_value, updated_at)
SELECT
  lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' ||
  substr(lower(hex(randomblob(2))), 2) || '-' ||
  substr('89ab', abs(random()) % 4 + 1, 1) ||
  substr(lower(hex(randomblob(2))), 2) || '-' || lower(hex(randomblob(6))),
  key,
  attachment_id,
  overlay_strength,
  text_color_value,
  CASE WHEN typeof(updated_at) = 'integer'
    THEN strftime('%Y-%m-%dT%H:%M:%SZ', updated_at, 'unixepoch')
    ELSE updated_at END
FROM banner_settings
''');
    await customStatement('DROP TABLE banner_settings');
    await customStatement(
      'ALTER TABLE banner_settings_v3 RENAME TO banner_settings',
    );
    await _migrateLegacyBuiltInIds();
    await _convertLegacyDateColumns();
  }

  /// 将旧版内置非 UUID 标识转换为稳定 UUID，避免云端写入失败。
  Future<void> _migrateLegacyBuiltInIds() async {
    // 旧版名言与本机生成的新 UUID 映射。
    final Map<String, String> quoteIds = <String, String>{
      'builtin-quote-quiet': stableBusinessId('builtin-quote', <String>[
        'quiet',
      ]),
      'builtin-quote-time': stableBusinessId('builtin-quote', <String>['time']),
    };
    for (final MapEntry<String, String> entry in quoteIds.entries) {
      await customStatement(
        '''
INSERT OR IGNORE INTO quotes
  (id, content, source, is_enabled, created_at, updated_at, deleted_at)
SELECT ?, content, source, is_enabled, created_at, updated_at, deleted_at
FROM quotes WHERE id = ?
''',
        <Object?>[entry.value, entry.key],
      );
      await customStatement(
        'UPDATE daily_quote_selections SET quote_id = ? WHERE quote_id = ?',
        <Object?>[entry.value, entry.key],
      );
      await customStatement('DELETE FROM quotes WHERE id = ?', <Object?>[
        entry.key,
      ]);
    }
    for (int index = 0; index < 6; index += 1) {
      // 旧版时间类别标识。
      final String legacyId = 'builtin-time-category-$index';
      // 读取旧类别实际名称，以免重命名后丢失业务身份。
      final QueryRow? legacy = await customSelect(
        'SELECT module, kind, name FROM taxonomy_entries WHERE id = ?',
        variables: <Variable<Object>>[Variable<String>(legacyId)],
      ).getSingleOrNull();
      if (legacy == null) {
        continue;
      }
      // 新版时间类别 UUID 与新设备同名类别保持一致。
      final String uuid = stableBusinessId('taxonomy', <String>[
        legacy.read<String>('module'),
        legacy.read<String>('kind'),
        legacy.read<String>('name').trim().toLowerCase(),
      ]);
      await customStatement(
        '''
INSERT OR IGNORE INTO taxonomy_entries
  (id, module, kind, name, color_value,
   sort_order, is_enabled, created_at, updated_at, deleted_at)
SELECT ?, module, kind, name, color_value,
       sort_order, is_enabled, created_at, updated_at, deleted_at
FROM taxonomy_entries WHERE id = ?
''',
        <Object?>[uuid, legacyId],
      );
      await customStatement(
        'UPDATE record_taxonomy_links SET taxonomy_id = ? '
        'WHERE taxonomy_id = ?',
        <Object?>[uuid, legacyId],
      );
      await customStatement(
        'DELETE FROM taxonomy_entries WHERE id = ?',
        <Object?>[legacyId],
      );
    }
  }

  /// 将 Drift 旧版 Unix 秒日期迁移为带时区语义的 ISO-8601 文本。
  Future<void> _convertLegacyDateColumns() async {
    // 各业务表需要转换的日期列。
    const Map<String, List<String>> dateColumns = <String, List<String>>{
      'todo_items': <String>[
        'scheduled_date',
        'due_at',
        'completed_at',
        'reminder_at',
        'created_at',
        'updated_at',
        'deleted_at',
      ],
      'quotes': <String>['created_at', 'updated_at', 'deleted_at'],
      'attachments': <String>['created_at', 'updated_at', 'deleted_at'],
      'taxonomy_entries': <String>['created_at', 'updated_at', 'deleted_at'],
      'record_taxonomy_links': <String>['created_at', 'deleted_at'],
      'events': <String>[
        'last_completed_at',
        'archived_at',
        'created_at',
        'updated_at',
        'deleted_at',
      ],
      'event_completions': <String>['completed_at', 'created_at', 'deleted_at'],
      'inventory_items': <String>[
        'purchase_date',
        'warranty_expiration',
        'created_at',
        'updated_at',
        'deleted_at',
      ],
      'time_entries': <String>[
        'entry_date',
        'created_at',
        'updated_at',
        'deleted_at',
      ],
      'memberships': <String>[
        'purchase_date',
        'expiration_date',
        'renewal_date',
        'created_at',
        'updated_at',
        'deleted_at',
      ],
      'membership_payments': <String>[
        'paid_at',
        'valid_from',
        'valid_until',
        'created_at',
        'deleted_at',
      ],
    };
    for (final MapEntry<String, List<String>> table in dateColumns.entries) {
      for (final String column in table.value) {
        await customStatement('''
UPDATE "${table.key}"
SET "$column" = strftime(
  '%Y-%m-%dT%H:%M:%SZ', CAST("$column" AS INTEGER), 'unixepoch'
)
WHERE typeof("$column") = 'integer'
   OR (
     typeof("$column") = 'text'
     AND "$column" GLOB '[0-9]*'
     AND "$column" NOT GLOB '*[^0-9]*'
   )
''');
      }
    }
  }
}
