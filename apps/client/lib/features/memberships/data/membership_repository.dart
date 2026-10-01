import 'package:drift/drift.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:uuid/uuid.dart';

/// 会员到期状态。
enum MembershipStatus {
  /// 永久有效。
  permanent,

  /// 试用中。
  trial,

  /// 正常有效。
  active,

  /// 已取消但可能仍在有效期内。
  cancelled,

  /// 用户标记需要续费。
  renewalDue,

  /// 即将到期。
  upcoming,

  /// 已过期。
  expired,
}

/// 会员基础状态。
enum MembershipBaseStatus {
  /// 试用中。
  trial,

  /// 使用中。
  active,

  /// 已取消。
  cancelled,
}

/// 会员计费周期。
enum BillingCycle {
  /// 每周。
  week,

  /// 每月。
  month,

  /// 每季度。
  quarter,

  /// 每半年。
  halfYear,

  /// 每年。
  year,

  /// 每两年。
  twoYears,

  /// 每三年。
  threeYears,

  /// 永久买断。
  permanent,

  /// 自定义周期。
  custom,
}

/// 支付记录删除结果。
class PaymentDeletionResult {
  /// 实际从会员有效期扣除的自然日数。
  final int deductedDays;

  /// 是否因删除自动续费记录而关闭了自动续费。
  final bool autoRenewDisabled;

  /// 删除的是否为新增会员时生成的首笔购买记录。
  final bool initialPurchase;

  /// 创建支付记录删除结果。
  const PaymentDeletionResult({
    required this.deductedDays,
    required this.autoRenewDisabled,
    required this.initialPurchase,
  });
}

/// 会员编辑草稿。
class MembershipDraft {
  /// 可选现有会员标识。
  final String? id;

  /// 会员名称。
  final String name;

  /// 可选服务提供方。
  final String? provider;

  /// 可选分类。
  final String? category;

  /// 可选会员说明。
  final String? description;

  /// 可选官方网站。
  final String? websiteUrl;

  /// 可选购买平台。
  final String? purchasePlatform;

  /// 价格分值。
  final int priceCents;

  /// 计费周期。
  final BillingCycle billingCycle;

  /// 基础状态。
  final MembershipBaseStatus baseStatus;

  /// 购买日期。
  final DateTime purchaseDate;

  /// 可选到期日期。
  final DateTime? expirationDate;

  /// 是否永久有效。
  final bool isPermanent;

  /// 是否自动续费。
  final bool autoRenew;

  /// 可选下次续费日期。
  final DateTime? renewalDate;

  /// 是否需要续费。
  final bool needsRenewal;

  /// 是否开启到期提醒。
  final bool expirationReminderEnabled;

  /// 到期提醒提前天数。
  final int expirationReminderDays;

  /// 是否开启续费提醒。
  final bool renewalReminderEnabled;

  /// 续费提醒提前天数。
  final int renewalReminderDays;

  /// 提醒时刻相对午夜的分钟数。
  final int reminderTimeMinutes;

  /// 已选择的会员分类标识。
  final Set<String> categoryIds;

  /// 已选择的会员标签标识。
  final Set<String> tagIds;

  /// 可选取消续费说明。
  final String? cancelGuide;

  /// 可选备注。
  final String? notes;

  /// 创建会员草稿。
  const MembershipDraft({
    this.id,
    required this.name,
    this.provider,
    this.category,
    this.description,
    this.websiteUrl,
    this.purchasePlatform,
    required this.priceCents,
    this.billingCycle = BillingCycle.year,
    this.baseStatus = MembershipBaseStatus.active,
    required this.purchaseDate,
    this.expirationDate,
    required this.isPermanent,
    required this.autoRenew,
    this.renewalDate,
    this.needsRenewal = false,
    this.expirationReminderEnabled = false,
    this.expirationReminderDays = 30,
    this.renewalReminderEnabled = false,
    this.renewalReminderDays = 7,
    this.reminderTimeMinutes = 540,
    this.categoryIds = const <String>{},
    this.tagIds = const <String>{},
    this.cancelGuide,
    this.notes,
  });
}

/// 会员本地优先仓储。
class MembershipRepository {
  /// 本地数据库。
  final AppDatabase _database;

  /// UUID 生成器。
  final Uuid _uuid;

  /// 创建会员仓储。
  MembershipRepository(this._database, {this._uuid = const Uuid()});

  /// 监听会员与规范分类、标签之间的有效关联。
  Stream<Map<String, Set<String>>> watchTaxonomyLinks() {
    // 会员模块的有效关联查询。
    final query = _database.select(_database.recordTaxonomyLinks)
      ..where(
        (RecordTaxonomyLinks table) =>
            table.module.equals('membership') & table.deletedAt.isNull(),
      );
    return query.watch().map((List<RecordTaxonomyLink> links) {
      // 按会员标识聚合规范分类和标签标识。
      final Map<String, Set<String>> grouped = <String, Set<String>>{};
      for (final RecordTaxonomyLink link in links) {
        grouped
            .putIfAbsent(link.recordId, () => <String>{})
            .add(link.taxonomyId);
      }
      return grouped;
    });
  }

  /// 监听有效会员并按到期时间排序。
  Stream<List<MembershipRecord>> watchAll() {
    // 有效会员查询。
    final query = _database.select(_database.memberships)
      ..where((Memberships table) => table.deletedAt.isNull());
    return query.watch().map((List<MembershipRecord> records) {
      // 排序后的会员副本。
      final List<MembershipRecord> sorted = List<MembershipRecord>.of(records);
      sorted.sort((MembershipRecord left, MembershipRecord right) {
        if (left.isPermanent != right.isPermanent) {
          return left.isPermanent ? 1 : -1;
        }
        // 左侧到期日期。
        final DateTime? leftDate = left.expirationDate;
        // 右侧到期日期。
        final DateTime? rightDate = right.expirationDate;
        if (leftDate == null && rightDate == null) {
          return left.name.compareTo(right.name);
        }
        if (leftDate == null) {
          return 1;
        }
        if (rightDate == null) {
          return -1;
        }
        return leftDate.compareTo(rightDate);
      });
      return sorted;
    });
  }

  /// 监听指定会员的支付历史。
  Stream<List<MembershipPaymentRecord>> watchPayments(String membershipId) {
    // 支付历史查询。
    final query = _database.select(_database.membershipPayments)
      ..where(
        (MembershipPayments table) =>
            table.membershipId.equals(membershipId) & table.deletedAt.isNull(),
      )
      ..orderBy(<OrderingTerm Function(MembershipPayments)>[
        (MembershipPayments table) => OrderingTerm.desc(table.paidAt),
      ]);
    return query.watch().map(
      (List<MembershipPaymentRecord> records) =>
          records.map(_localizePaymentRecord).toList(growable: false),
    );
  }

  /// 监听全部有效会员的支付历史用于支出统计。
  Stream<List<MembershipPaymentRecord>> watchActivePayments() {
    // 支付历史与会员联表查询。
    final query =
        _database.select(_database.membershipPayments).join(<Join>[
          innerJoin(
            _database.memberships,
            _database.memberships.id.equalsExp(
              _database.membershipPayments.membershipId,
            ),
          ),
        ])..where(
          _database.membershipPayments.deletedAt.isNull() &
              _database.memberships.deletedAt.isNull(),
        );
    return query.watch().map(
      (List<TypedResult> rows) => rows
          .map(
            (TypedResult row) => _localizePaymentRecord(
              row.readTable(_database.membershipPayments),
            ),
          )
          .toList(growable: false),
    );
  }

  /// 保存新增或编辑后的会员。
  Future<String> save(MembershipDraft draft) async {
    // 清理后的会员名称。
    final String name = draft.name.trim();
    if (name.isEmpty) {
      throw const FormatException('会员名称不能为空');
    }
    if (draft.priceCents < 0) {
      throw const FormatException('会员价格不能为负数');
    }
    if (draft.isPermanent && draft.expirationDate != null) {
      throw const FormatException('永久会员不能同时设置到期日期');
    }
    if (!draft.isPermanent && draft.expirationDate == null) {
      throw const FormatException('周期会员必须设置到期日期');
    }
    if (draft.expirationReminderDays <= 0 || draft.renewalReminderDays <= 0) {
      throw const FormatException('提醒提前天数必须为正整数');
    }
    if (draft.reminderTimeMinutes < 0 || draft.reminderTimeMinutes >= 1440) {
      throw const FormatException('提醒时刻必须位于当天');
    }
    // 清理后的官方网站。
    final String? websiteUrl = _validateUrl(draft.websiteUrl, '官方网站');
    // 当前写入时间。
    final DateTime now = DateTime.now();
    // 可选现有会员标识。
    final String? existingId = draft.id;
    if (existingId == null) {
      // 新会员标识。
      final String id = _uuid.v7();
      await _database.transaction(() async {
        await _database
            .into(_database.memberships)
            .insert(
              MembershipsCompanion.insert(
                id: id,
                name: name,
                provider: Value<String?>(_cleanOptional(draft.provider)),
                category: Value<String?>(_cleanOptional(draft.category)),
                description: Value<String?>(_cleanOptional(draft.description)),
                websiteUrl: Value<String?>(websiteUrl),
                purchasePlatform: Value<String?>(
                  _cleanOptional(draft.purchasePlatform),
                ),
                priceCents: Value<int>(draft.priceCents),
                billingCycle: Value<String>(
                  draft.isPermanent
                      ? BillingCycle.permanent.name
                      : draft.billingCycle.name,
                ),
                baseStatus: Value<String>(draft.baseStatus.name),
                purchaseDate: draft.purchaseDate,
                expirationDate: Value<DateTime?>(draft.expirationDate),
                isPermanent: Value<bool>(draft.isPermanent),
                autoRenew: Value<bool>(draft.autoRenew),
                renewalDate: Value<DateTime?>(draft.renewalDate),
                needsRenewal: Value<bool>(draft.needsRenewal),
                expirationReminderEnabled: Value<bool>(
                  !draft.isPermanent && draft.expirationReminderEnabled,
                ),
                expirationReminderDays: Value<int>(
                  draft.expirationReminderDays,
                ),
                renewalReminderEnabled: Value<bool>(
                  !draft.isPermanent &&
                      draft.autoRenew &&
                      draft.renewalReminderEnabled,
                ),
                renewalReminderDays: Value<int>(draft.renewalReminderDays),
                reminderTimeMinutes: Value<int>(draft.reminderTimeMinutes),
                cancelGuide: Value<String?>(_cleanOptional(draft.cancelGuide)),
                notes: Value<String?>(_cleanOptional(draft.notes)),
                createdAt: now,
                updatedAt: now,
              ),
            );
        if (draft.priceCents > 0) {
          await _database
              .into(_database.membershipPayments)
              .insert(
                MembershipPaymentsCompanion.insert(
                  id: _uuid.v7(),
                  membershipId: id,
                  amountCents: draft.priceCents,
                  paidAt: draft.purchaseDate,
                  validFrom: Value<DateTime>(draft.purchaseDate),
                  validUntil: Value<DateTime?>(draft.expirationDate),
                  createdAt: now,
                ),
              );
        }
      });
      await _replaceTagLinks(id, _taxonomyIds(draft), now);
      return id;
    }
    await (_database.update(
      _database.memberships,
    )..where((Memberships table) => table.id.equals(existingId))).write(
      MembershipsCompanion(
        name: Value<String>(name),
        provider: Value<String?>(_cleanOptional(draft.provider)),
        category: Value<String?>(_cleanOptional(draft.category)),
        description: Value<String?>(_cleanOptional(draft.description)),
        websiteUrl: Value<String?>(websiteUrl),
        purchasePlatform: Value<String?>(
          _cleanOptional(draft.purchasePlatform),
        ),
        priceCents: Value<int>(draft.priceCents),
        billingCycle: Value<String>(
          draft.isPermanent
              ? BillingCycle.permanent.name
              : draft.billingCycle.name,
        ),
        baseStatus: Value<String>(draft.baseStatus.name),
        purchaseDate: Value<DateTime>(draft.purchaseDate),
        expirationDate: Value<DateTime?>(draft.expirationDate),
        isPermanent: Value<bool>(draft.isPermanent),
        autoRenew: Value<bool>(draft.autoRenew),
        renewalDate: Value<DateTime?>(draft.renewalDate),
        needsRenewal: Value<bool>(draft.needsRenewal),
        expirationReminderEnabled: Value<bool>(
          !draft.isPermanent && draft.expirationReminderEnabled,
        ),
        expirationReminderDays: Value<int>(draft.expirationReminderDays),
        renewalReminderEnabled: Value<bool>(
          !draft.isPermanent && draft.autoRenew && draft.renewalReminderEnabled,
        ),
        renewalReminderDays: Value<int>(draft.renewalReminderDays),
        reminderTimeMinutes: Value<int>(draft.reminderTimeMinutes),
        cancelGuide: Value<String?>(_cleanOptional(draft.cancelGuide)),
        notes: Value<String?>(_cleanOptional(draft.notes)),
        updatedAt: Value<DateTime>(now),
        syncState: const Value<String>('localSaved'),
      ),
    );
    await _replaceTagLinks(existingId, _taxonomyIds(draft), now);
    return existingId;
  }

  /// 记录一次实际续费支付。
  Future<void> recordPayment({
    required String membershipId,
    required int amountCents,
    required DateTime paidAt,
    BillingCycle? billingCycle,
    DateTime? validUntil,
    String? notes,
    bool isAutomatic = false,
  }) async {
    if (amountCents < 0) {
      throw const FormatException('支付金额不能为负数');
    }
    // 当前创建时间。
    final DateTime now = DateTime.now();
    await _database.transaction(() async {
      // 自动续费以会员和账期为业务身份；人工支付保留独立交易。
      final String paymentId = isAutomatic
          ? stableBusinessId('auto-renewal', <String>[
              membershipId,
              businessDayKey(paidAt),
            ])
          : _uuid.v7();
      if (isAutomatic) {
        // 已处理账期不再次记账或推进到期日。
        final MembershipPaymentRecord? existingPayment =
            await (_database.select(_database.membershipPayments)..where(
                  (MembershipPayments table) => table.id.equals(paymentId),
                ))
                .getSingleOrNull();
        if (existingPayment != null) {
          return;
        }
      }
      // 当前会员信息用于计算续费后的到期日。
      final MembershipRecord membership =
          await (_database.select(_database.memberships)
                ..where((Memberships table) => table.id.equals(membershipId)))
              .getSingle();
      // 未传入周期时沿用会员当前周期。
      final BillingCycle effectiveCycle = BillingCycle.values.firstWhere(
        (BillingCycle value) =>
            value.name == (billingCycle?.name ?? membership.billingCycle),
        orElse: () => BillingCycle.custom,
      );
      if (!membership.isPermanent &&
          effectiveCycle == BillingCycle.custom &&
          validUntil == null) {
        throw const FormatException('自定义周期必须设置结束时间');
      }
      // 支付记录的有效期按开始时间计算。
      final DateTime? paymentExpirationDate = membership.isPermanent
          ? null
          : effectiveCycle == BillingCycle.custom
          ? validUntil
          : _addBillingCycle(paidAt, effectiveCycle);
      // 标准周期从当前到期日继续叠加；自定义周期使用手工有效期。
      final DateTime? updatedExpirationDate = membership.isPermanent
          ? null
          : effectiveCycle == BillingCycle.custom
          ? validUntil
          : _addBillingCycle(
              membership.expirationDate ?? paidAt,
              effectiveCycle,
            );
      await _database
          .into(_database.membershipPayments)
          .insert(
            MembershipPaymentsCompanion.insert(
              id: paymentId,
              membershipId: membershipId,
              amountCents: amountCents,
              paidAt: paidAt,
              validFrom: Value<DateTime?>(paidAt),
              validUntil: Value<DateTime?>(paymentExpirationDate),
              notes: Value<String?>(_cleanOptional(notes)),
              createdAt: now,
            ),
          );
      if (!membership.isPermanent && updatedExpirationDate != null) {
        await (_database.update(
          _database.memberships,
        )..where((Memberships table) => table.id.equals(membershipId))).write(
          MembershipsCompanion(
            expirationDate: Value<DateTime?>(updatedExpirationDate),
            renewalDate: membership.autoRenew
                ? Value<DateTime?>(updatedExpirationDate)
                : const Value<DateTime?>.absent(),
            updatedAt: Value<DateTime>(now),
            syncState: const Value<String>('localSaved'),
          ),
        );
      }
    });
  }

  /// 处理已到期且开启自动续费的会员。
  ///
  /// 每次调用会补齐所有已经错过的标准周期；重复调用不会重复生成记录，
  /// 因为会员到期日会在同一事务中向后推进。
  Future<int> processAutoRenewals(DateTime now) async {
    final List<MembershipRecord> memberships = await watchAll().first;
    int processedCount = 0;
    for (final MembershipRecord membership in memberships) {
      if (!membership.autoRenew ||
          membership.isPermanent ||
          membership.expirationDate == null) {
        continue;
      }
      while (true) {
        final MembershipRecord current = await _loadMembership(membership.id);
        final DateTime? expirationDate = current.expirationDate;
        if (!current.autoRenew ||
            current.isPermanent ||
            expirationDate == null ||
            expirationDate.isAfter(now)) {
          break;
        }
        final BillingCycle cycle = _billingCycleFromName(current.billingCycle);
        DateTime? customEndDate;
        if (cycle == BillingCycle.custom) {
          final MembershipPaymentRecord? latestPayment = await _latestPayment(
            current.id,
          );
          final DateTime? previousStart = latestPayment?.validFrom;
          final DateTime? previousEnd = latestPayment?.validUntil;
          if (previousStart == null || previousEnd == null) {
            break;
          }
          final Duration period = previousEnd.difference(previousStart);
          if (period <= Duration.zero) {
            break;
          }
          customEndDate = expirationDate.add(period);
        }
        await recordPayment(
          membershipId: current.id,
          amountCents: current.priceCents,
          paidAt: expirationDate,
          billingCycle: cycle,
          validUntil: customEndDate,
          notes: '自动续费',
          isAutomatic: true,
        );
        // 其他设备已上传同一账期时不在陈旧到期日上无限重试。
        final MembershipRecord updated = await _loadMembership(current.id);
        if (updated.expirationDate == current.expirationDate) {
          break;
        }
        processedCount += 1;
      }
    }
    return processedCount;
  }

  /// 软删除支付记录，并同步回退续费增加的会员有效期。
  Future<PaymentDeletionResult> deletePayment({
    required String membershipId,
    required String paymentId,
  }) async {
    return _database.transaction(() async {
      // 当前会员记录。
      final MembershipRecord membership = await _loadMembership(membershipId);
      // 待删除的有效支付记录。
      final MembershipPaymentRecord? payment =
          await (_database.select(_database.membershipPayments)..where(
                (MembershipPayments table) =>
                    table.id.equals(paymentId) &
                    table.membershipId.equals(membershipId) &
                    table.deletedAt.isNull(),
              ))
              .getSingleOrNull();
      if (payment == null) {
        throw StateError('支付记录不存在或已删除');
      }
      // 包含已删除记录的完整支付历史，用于稳定识别最初购买记录。
      final List<MembershipPaymentRecord> paymentHistory =
          await (_database.select(_database.membershipPayments)..where(
                (MembershipPayments table) =>
                    table.membershipId.equals(membershipId),
              ))
              .get();
      paymentHistory.sort((
        MembershipPaymentRecord left,
        MembershipPaymentRecord right,
      ) {
        // 创建时间比较结果。
        final int createdComparison = left.createdAt.compareTo(right.createdAt);
        return createdComparison != 0
            ? createdComparison
            : left.id.compareTo(right.id);
      });
      // 最早创建的支付记录。
      final MembershipPaymentRecord earliestPayment = paymentHistory.first;
      // 当前记录是否为新增会员时生成的首笔购买记录。
      final bool initialPurchase =
          earliestPayment.id == payment.id &&
          _isSameCalendarDay(paymentDateFor(payment), membership.purchaseDate);
      // 当前记录是否由系统自动续费生成。
      final bool automaticRenewal = _isAutomaticRenewalPayment(payment);
      // 实际需要扣除的续费自然日数。
      int deductedDays = 0;
      // 删除续费后新的会员到期日。
      DateTime? updatedExpirationDate;
      if (!initialPurchase && !membership.isPermanent) {
        // 本次续费有效期开始日期。
        final DateTime? validFrom = payment.validFrom;
        // 本次续费有效期结束日期。
        final DateTime? validUntil = payment.validUntil;
        if (validFrom == null || validUntil == null) {
          throw const FormatException('续费记录缺少有效期，无法安全回退会员到期日');
        }
        deductedDays = _calendarDayDifference(validFrom, validUntil);
        if (deductedDays <= 0) {
          throw const FormatException('续费记录的结束日期必须晚于开始日期');
        }
        // 删除前的会员到期日。
        final DateTime? expirationDate = membership.expirationDate;
        if (expirationDate == null) {
          throw const FormatException('会员缺少到期日，无法安全删除续费记录');
        }
        updatedExpirationDate = _subtractCalendarDays(
          expirationDate,
          deductedDays,
        );
        if (_calendarDay(updatedExpirationDate)
            .isBefore(_calendarDay(membership.purchaseDate))) {
          throw const FormatException('删除后到期日将早于购买日期，已取消删除');
        }
      }
      // 当前删除时间。
      final DateTime now = DateTime.now();
      await (_database.update(_database.membershipPayments)..where(
            (MembershipPayments table) =>
                table.id.equals(paymentId) &
                table.membershipId.equals(membershipId) &
                table.deletedAt.isNull(),
          ))
          .write(MembershipPaymentsCompanion(deletedAt: Value<DateTime>(now)));
      if (updatedExpirationDate != null || automaticRenewal) {
        await (_database.update(
          _database.memberships,
        )..where((Memberships table) => table.id.equals(membershipId))).write(
          MembershipsCompanion(
            expirationDate: updatedExpirationDate == null
                ? const Value<DateTime?>.absent()
                : Value<DateTime?>(updatedExpirationDate),
            autoRenew: automaticRenewal
                ? const Value<bool>(false)
                : const Value<bool>.absent(),
            renewalDate: automaticRenewal
                ? const Value<DateTime?>(null)
                : membership.autoRenew && updatedExpirationDate != null
                ? Value<DateTime?>(updatedExpirationDate)
                : const Value<DateTime?>.absent(),
            renewalReminderEnabled: automaticRenewal
                ? const Value<bool>(false)
                : const Value<bool>.absent(),
            updatedAt: Value<DateTime>(now),
            syncState: const Value<String>('localSaved'),
          ),
        );
      }
      return PaymentDeletionResult(
        deductedDays: deductedDays,
        autoRenewDisabled: automaticRenewal,
        initialPurchase: initialPurchase,
      );
    });
  }

  /// 判断支付记录是否为系统自动续费生成的稳定业务记录。
  bool _isAutomaticRenewalPayment(MembershipPaymentRecord payment) {
    // 自动续费业务身份使用的账期日期。
    final DateTime identityDate = paymentDateFor(payment);
    // 根据会员和账期推导出的自动续费稳定标识。
    final String automaticId = stableBusinessId('auto-renewal', <String>[
      payment.membershipId,
      businessDayKey(identityDate),
    ]);
    return payment.id == automaticId;
  }

  /// 判断两个时间是否位于同一个自然日。
  bool _isSameCalendarDay(DateTime left, DateTime right) {
    return left.year == right.year &&
        left.month == right.month &&
        left.day == right.day;
  }

  /// 将时间规范为只用于自然日运算的 UTC 日期。
  DateTime _calendarDay(DateTime value) {
    return DateTime.utc(value.year, value.month, value.day);
  }

  /// 计算两个日期之间的自然日数。
  int _calendarDayDifference(DateTime from, DateTime until) {
    return _calendarDay(until).difference(_calendarDay(from)).inDays;
  }

  /// 从日期中扣除指定自然日数，并保留原时间的 UTC 属性。
  DateTime _subtractCalendarDays(DateTime value, int days) {
    // 扣减后的 UTC 自然日。
    final DateTime result = _calendarDay(value).subtract(Duration(days: days));
    return value.isUtc
        ? DateTime.utc(result.year, result.month, result.day)
        : DateTime(result.year, result.month, result.day);
  }

  /// 将会员移入回收站。
  Future<void> delete(String id) async {
    // 当前删除时间。
    final DateTime now = DateTime.now();
    await (_database.update(
      _database.memberships,
    )..where((Memberships table) => table.id.equals(id))).write(
      MembershipsCompanion(
        deletedAt: Value<DateTime>(now),
        updatedAt: Value<DateTime>(now),
        syncState: const Value<String>('localSaved'),
      ),
    );
  }

  /// 读取单个会员。
  Future<MembershipRecord> _loadMembership(String id) {
    return (_database.select(
      _database.memberships,
    )..where((Memberships table) => table.id.equals(id))).getSingle();
  }

  /// 读取最新支付记录。
  Future<MembershipPaymentRecord?> _latestPayment(String membershipId) async {
    final List<MembershipPaymentRecord> payments =
        await (_database.select(_database.membershipPayments)..where(
              (MembershipPayments table) =>
                  table.membershipId.equals(membershipId) &
                  table.deletedAt.isNull(),
            ))
            .get();
    if (payments.isEmpty) {
      return null;
    }
    payments.sort(
      (MembershipPaymentRecord left, MembershipPaymentRecord right) =>
          right.paidAt.compareTo(left.paidAt),
    );
    return payments.first;
  }

  /// 将数据库中的计费周期名称转换为枚举。
  BillingCycle _billingCycleFromName(String value) {
    return BillingCycle.values.firstWhere(
      (BillingCycle cycle) => cycle.name == value,
      orElse: () => BillingCycle.custom,
    );
  }

  /// 计算会员当前状态。
  MembershipStatus statusFor(MembershipRecord membership, DateTime now) {
    if (membership.isPermanent) {
      return MembershipStatus.permanent;
    }
    // 会员到期日期。
    final DateTime? expiration = membership.expirationDate;
    if (expiration == null) {
      return MembershipStatus.active;
    }
    if (now.isAfter(expiration)) {
      return MembershipStatus.expired;
    }
    if (!now.isBefore(
      expiration.subtract(Duration(days: membership.expirationReminderDays)),
    )) {
      return MembershipStatus.upcoming;
    }
    if (membership.needsRenewal) {
      return MembershipStatus.renewalDue;
    }
    return switch (membership.baseStatus) {
      'trial' => MembershipStatus.trial,
      'cancelled' => MembershipStatus.cancelled,
      _ => MembershipStatus.active,
    };
  }

  /// 按实际支付日期汇总指定年月支出。
  int summarizeSpending(
    List<MembershipPaymentRecord> payments, {
    required int year,
    int? month,
  }) {
    return payments
        .where((MembershipPaymentRecord payment) {
          // 用户输入的付费自然日，避免带时区时间跨月后被归入上个月。
          final DateTime paymentDate = paymentDateFor(payment);
          return paymentDate.year == year &&
              (month == null || paymentDate.month == month);
        })
        .fold<int>(
          0,
          (int total, MembershipPaymentRecord payment) =>
              total + payment.amountCents,
        );
  }

  /// 返回支付记录用于业务统计的付费自然日。
  DateTime paymentDateFor(MembershipPaymentRecord payment) {
    return payment.validFrom ?? payment.paidAt.toLocal();
  }

  /// 将支付记录中的真实时间点转换为当前设备本地时间。
  MembershipPaymentRecord _localizePaymentRecord(
    MembershipPaymentRecord record,
  ) {
    return record.copyWith(
      paidAt: record.paidAt.toLocal(),
      createdAt: record.createdAt.toLocal(),
      deletedAt: Value<DateTime?>(record.deletedAt?.toLocal()),
    );
  }

  /// 校验并清理可选 HTTP(S) 链接。
  String? _validateUrl(String? value, String fieldName) {
    // 清理后的链接。
    final String? normalized = _cleanOptional(value);
    if (normalized == null) {
      return null;
    }
    // 解析后的链接。
    final Uri? uri = Uri.tryParse(normalized);
    if (uri == null ||
        !<String>{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw FormatException('$fieldName 必须使用 http 或 https');
    }
    return normalized;
  }

  /// 替换一条会员的规范标签关系。
  Future<void> _replaceTagLinks(
    String recordId,
    Set<String> tagIds,
    DateTime now,
  ) async {
    await _database.transaction(() async {
      await (_database.update(_database.recordTaxonomyLinks)..where(
            (RecordTaxonomyLinks table) =>
                table.module.equals('membership') &
                table.recordId.equals(recordId) &
                table.deletedAt.isNull(),
          ))
          .write(RecordTaxonomyLinksCompanion(deletedAt: Value<DateTime>(now)));
      for (final String taxonomyId in tagIds) {
        await _database
            .into(_database.recordTaxonomyLinks)
            .insert(
              RecordTaxonomyLinksCompanion.insert(
                id: _uuid.v7(),
                module: 'membership',
                recordId: recordId,
                taxonomyId: taxonomyId,
                createdAt: now,
              ),
            );
      }
    });
  }

  /// 合并会员分类和标签的规范标识。
  Set<String> _taxonomyIds(MembershipDraft draft) {
    // 当前会员需要保存的规范标识集合。
    return <String>{...draft.categoryIds, ...draft.tagIds};
  }

  /// 清理可选文本。
  String? _cleanOptional(String? value) {
    // 清理后的文本。
    final String? normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  /// 按日历周期计算新的日期，并将月底日期限制在目标月份最后一天。
  DateTime _addBillingCycle(DateTime date, BillingCycle cycle) {
    final int months = switch (cycle) {
      BillingCycle.week => 0,
      BillingCycle.month => 1,
      BillingCycle.quarter => 3,
      BillingCycle.halfYear => 6,
      BillingCycle.year => 12,
      BillingCycle.twoYears => 24,
      BillingCycle.threeYears => 36,
      BillingCycle.permanent || BillingCycle.custom => 0,
    };
    if (cycle == BillingCycle.week) {
      return date.add(const Duration(days: 7));
    }
    if (months == 0) {
      return date;
    }
    final DateTime targetMonth = DateTime(date.year, date.month + months, 1);
    final int lastDay = DateTime(
      targetMonth.year,
      targetMonth.month + 1,
      0,
    ).day;
    return DateTime(
      targetMonth.year,
      targetMonth.month,
      date.day > lastDay ? lastDay : date.day,
      date.hour,
      date.minute,
      date.second,
      date.millisecond,
      date.microsecond,
    );
  }
}
