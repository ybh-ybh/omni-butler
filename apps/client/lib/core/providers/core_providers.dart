import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/core/attachments/attachment_repository.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/features/events/data/event_repository.dart';
import 'package:omni_butler/features/home/data/quote_repository.dart';
import 'package:omni_butler/features/inventory/data/inventory_repository.dart';
import 'package:omni_butler/features/memberships/data/membership_repository.dart';
import 'package:omni_butler/features/settings/data/recycle_bin_repository.dart';
import 'package:omni_butler/features/timeline/data/time_entry_repository.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:omni_butler/shared/search/global_search_repository.dart';

/// 会随系统分钟边界自动刷新的当前时间。
final Provider<DateTime> nowProvider = Provider<DateTime>((Ref ref) {
  // 当前系统时间。
  final DateTime now = DateTime.now();
  // 下一个整分钟时刻。
  final DateTime nextMinute = DateTime(
    now.year,
    now.month,
    now.day,
    now.hour,
    now.minute + 1,
  );
  // 到达下一分钟时让提供者重新读取系统时间。
  final Timer minuteTimer = Timer(
    nextMinute.difference(now),
    ref.invalidateSelf,
  );
  ref.onDispose(minuteTimer.cancel);
  return now;
});

/// 附件本地队列仓储提供者。
final Provider<AttachmentRepository> attachmentRepositoryProvider =
    Provider<AttachmentRepository>((Ref ref) {
      // 当前设备数据库。
      final AppDatabase database = ref.watch(appDatabaseProvider);
      return AttachmentRepository(database);
    });

/// 指定业务记录当前附件流提供者。
final currentAttachmentProvider =
    StreamProvider.family<Attachment?, (AttachmentBusinessType, String)>((
      Ref ref,
      (AttachmentBusinessType, String) key,
    ) {
      // 附件本地队列仓储。
      final AttachmentRepository repository = ref.watch(
        attachmentRepositoryProvider,
      );
      return repository.watchCurrent(businessType: key.$1, businessId: key.$2);
    });

/// 等待或失败附件上传队列提供者。
final StreamProvider<List<Attachment>> attachmentUploadQueueProvider =
    StreamProvider<List<Attachment>>((Ref ref) {
      // 附件本地队列仓储。
      final AttachmentRepository repository = ref.watch(
        attachmentRepositoryProvider,
      );
      return repository.watchUploadQueue();
    });

/// 全局本地搜索仓储提供者。
final Provider<GlobalSearchRepository> globalSearchRepositoryProvider =
    Provider<GlobalSearchRepository>((Ref ref) {
      // 当前设备数据库。
      final AppDatabase database = ref.watch(appDatabaseProvider);
      return GlobalSearchRepository(database);
    });

/// 分类标签仓储提供者。
final Provider<TaxonomyRepository> taxonomyRepositoryProvider =
    Provider<TaxonomyRepository>((Ref ref) {
      // 当前设备数据库。
      final AppDatabase database = ref.watch(appDatabaseProvider);
      return TaxonomyRepository(database);
    });

/// 指定模块与类型的分类标签流提供者。
final taxonomyEntriesProvider = StreamProvider.autoDispose
    .family<List<TaxonomyEntry>, (TaxonomyModule, TaxonomyKind)>((
      Ref ref,
      (TaxonomyModule, TaxonomyKind) key,
    ) {
      // 分类标签仓储。
      final TaxonomyRepository repository = ref.watch(
        taxonomyRepositoryProvider,
      );
      return repository.watch(module: key.$1, kind: key.$2);
    });

/// 应用数据库提供者。
final Provider<AppDatabase> appDatabaseProvider = Provider<AppDatabase>((
  Ref ref,
) {
  // 当前设备数据库。
  final AppDatabase database = AppDatabase();
  ref.onDispose(() {
    unawaited(database.close());
  });
  return database;
});

/// 待办仓储提供者。
final Provider<TodoRepository> todoRepositoryProvider =
    Provider<TodoRepository>((Ref ref) {
      // 当前设备数据库。
      final AppDatabase database = ref.watch(appDatabaseProvider);
      return TodoRepository(database);
    });

/// 指定自然日待办流提供者。
final todosForDayProvider = StreamProvider.family<List<TodoRecord>, DateTime>((
  Ref ref,
  DateTime day,
) {
  // 待办仓储。
  final TodoRepository repository = ref.watch(todoRepositoryProvider);
  return repository.watchForDay(day);
});

/// 回收站待办流提供者。
final StreamProvider<List<TodoRecord>> deletedTodosProvider =
    StreamProvider<List<TodoRecord>>((Ref ref) {
      // 待办仓储。
      final TodoRepository repository = ref.watch(todoRepositoryProvider);
      return repository.watchDeleted();
    });

/// 指定自然日名言提供者。
final quoteForDayProvider = FutureProvider.family<QuoteRecord, DateTime>((
  Ref ref,
  DateTime day,
) {
  // 当前设备数据库。
  final AppDatabase database = ref.watch(appDatabaseProvider);
  return database.quoteForDay(day);
});

/// 名言库仓储提供者。
final Provider<QuoteRepository> quoteRepositoryProvider =
    Provider<QuoteRepository>((Ref ref) {
      // 当前设备数据库。
      final AppDatabase database = ref.watch(appDatabaseProvider);
      return QuoteRepository(database);
    });

/// 全部有效名言流提供者。
final StreamProvider<List<QuoteRecord>> quotesProvider =
    StreamProvider<List<QuoteRecord>>((Ref ref) {
      // 名言库仓储。
      final QuoteRepository repository = ref.watch(quoteRepositoryProvider);
      return repository.watchAll();
    });

/// 周期事件仓储提供者。
final Provider<EventRepository> eventRepositoryProvider =
    Provider<EventRepository>((Ref ref) {
      // 当前设备数据库。
      final AppDatabase database = ref.watch(appDatabaseProvider);
      return EventRepository(database);
    });

/// 有效周期事件流提供者。
final StreamProvider<List<EventRecord>> activeEventsProvider =
    StreamProvider<List<EventRecord>>((Ref ref) {
      // 周期事件仓储。
      final EventRepository repository = ref.watch(eventRepositoryProvider);
      return repository.watchActive();
    });

/// 归档周期事件流提供者。
final StreamProvider<List<EventRecord>> archivedEventsProvider =
    StreamProvider<List<EventRecord>>((Ref ref) {
      // 周期事件仓储。
      final EventRepository repository = ref.watch(eventRepositoryProvider);
      return repository.watchArchived();
    });

/// 全部未删除事件的有效完成历史流，用于事件顶部统计。
final StreamProvider<List<EventCompletionRecord>>
activeEventCompletionsProvider = StreamProvider<List<EventCompletionRecord>>((
  Ref ref,
) {
  // 周期事件仓储。
  final EventRepository repository = ref.watch(eventRepositoryProvider);
  return repository.watchActiveHistory();
});

/// 指定事件完成历史流提供者。
final eventHistoryProvider =
    StreamProvider.family<List<EventCompletionRecord>, String>((
      Ref ref,
      String eventId,
    ) {
      // 周期事件仓储。
      final EventRepository repository = ref.watch(eventRepositoryProvider);
      return repository.watchHistory(eventId);
    });

/// 物品仓储提供者。
final Provider<InventoryRepository> inventoryRepositoryProvider =
    Provider<InventoryRepository>((Ref ref) {
      // 当前设备数据库。
      final AppDatabase database = ref.watch(appDatabaseProvider);
      return InventoryRepository(database);
    });

/// 指定搜索词的物品流提供者。
final inventoryItemsProvider =
    StreamProvider.family<List<InventoryRecord>, String>((
      Ref ref,
      String query,
    ) {
      // 物品仓储。
      final InventoryRepository repository = ref.watch(
        inventoryRepositoryProvider,
      );
      return repository.watchAll(query: query);
    });

/// 物品与规范分类、标签、位置关联的流提供者。
final inventoryTaxonomyLinksProvider = StreamProvider<Map<String, Set<String>>>(
  (Ref ref) {
    // 物品仓储。
    final InventoryRepository repository = ref.watch(
      inventoryRepositoryProvider,
    );
    return repository.watchTaxonomyLinks();
  },
);

/// 指定主物品的配套物品流提供者。
final inventoryAccessoriesProvider =
    StreamProvider.family<List<InventoryRecord>, String>((
      Ref ref,
      String parentItemId,
    ) {
      // 物品仓储。
      final InventoryRepository repository = ref.watch(
        inventoryRepositoryProvider,
      );
      return repository.watchAccessories(parentItemId);
    });

/// 全部有效配套物品流提供者。
final inventoryAllAccessoriesProvider = StreamProvider<List<InventoryRecord>>((
  Ref ref,
) {
  // 物品仓储。
  final InventoryRepository repository = ref.watch(inventoryRepositoryProvider);
  return repository.watchAllAccessories();
});

/// 时间记录仓储提供者。
final Provider<TimeEntryRepository> timeEntryRepositoryProvider =
    Provider<TimeEntryRepository>((Ref ref) {
      // 当前设备数据库。
      final AppDatabase database = ref.watch(appDatabaseProvider);
      return TimeEntryRepository(database);
    });

/// 指定自然日的时间记录流提供者。
final timeEntriesForDayProvider =
    StreamProvider.family<List<TimeEntryRecord>, DateTime>((
      Ref ref,
      DateTime day,
    ) {
      // 时间记录仓储。
      final TimeEntryRepository repository = ref.watch(
        timeEntryRepositoryProvider,
      );
      return repository.watchForDay(day);
    });

/// 指定左闭右开日期范围的时间记录流提供者。
final timeEntriesForRangeProvider =
    StreamProvider.family<List<TimeEntryRecord>, (DateTime, DateTime)>((
      Ref ref,
      (DateTime, DateTime) range,
    ) {
      // 时间记录仓储。
      final TimeEntryRepository repository = ref.watch(
        timeEntryRepositoryProvider,
      );
      return repository.watchForRange(range.$1, range.$2);
    });

/// 全部进行中时间记录流提供者。
final StreamProvider<List<TimeEntryRecord>> ongoingTimeEntriesProvider =
    StreamProvider<List<TimeEntryRecord>>((Ref ref) {
      // 时间记录仓储。
      final TimeEntryRepository repository = ref.watch(
        timeEntryRepositoryProvider,
      );
      return repository.watchOngoing();
    });

/// 会员仓储提供者。
final Provider<MembershipRepository> membershipRepositoryProvider =
    Provider<MembershipRepository>((Ref ref) {
      // 当前设备数据库。
      final AppDatabase database = ref.watch(appDatabaseProvider);
      return MembershipRepository(database);
    });

/// 有效会员流提供者。
final StreamProvider<List<MembershipRecord>> membershipsProvider =
    StreamProvider<List<MembershipRecord>>((Ref ref) {
      // 会员仓储。
      final MembershipRepository repository = ref.watch(
        membershipRepositoryProvider,
      );
      return repository.watchAll();
    });

/// 会员与规范分类、标签关联的流提供者。
final membershipTaxonomyLinksProvider =
    StreamProvider<Map<String, Set<String>>>((Ref ref) {
      // 会员仓储。
      final MembershipRepository repository = ref.watch(
        membershipRepositoryProvider,
      );
      return repository.watchTaxonomyLinks();
    });

/// 指定会员支付历史流提供者。
final membershipPaymentsProvider =
    StreamProvider.family<List<MembershipPaymentRecord>, String>((
      Ref ref,
      String membershipId,
    ) {
      // 会员仓储。
      final MembershipRepository repository = ref.watch(
        membershipRepositoryProvider,
      );
      return repository.watchPayments(membershipId);
    });

/// 全部有效会员支付历史流提供者。
final StreamProvider<List<MembershipPaymentRecord>>
activeMembershipPaymentsProvider =
    StreamProvider<List<MembershipPaymentRecord>>((Ref ref) {
      // 会员仓储。
      final MembershipRepository repository = ref.watch(
        membershipRepositoryProvider,
      );
      return repository.watchActivePayments();
    });

/// 统一回收站仓储提供者。
final Provider<RecycleBinRepository> recycleBinRepositoryProvider =
    Provider<RecycleBinRepository>((Ref ref) {
      // 当前设备数据库。
      final AppDatabase database = ref.watch(appDatabaseProvider);
      return RecycleBinRepository(database);
    });

/// 统一回收站记录提供者。
final FutureProvider<List<RecycleBinItem>> recycleBinItemsProvider =
    FutureProvider<List<RecycleBinItem>>((Ref ref) async {
      // 统一回收站仓储。
      final RecycleBinRepository repository = ref.watch(
        recycleBinRepositoryProvider,
      );
      await repository.purgeExpired();
      return repository.loadItems();
    });
