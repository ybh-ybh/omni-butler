import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/attachments/attachment_repository.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/features/memberships/data/membership_repository.dart';
import 'package:omni_butler/shared/attachments/attachment_picker_dialog.dart';
import 'package:omni_butler/shared/taxonomy/taxonomy_manager_dialog.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 会员管理页面。
class MembershipsPage extends ConsumerStatefulWidget {
  /// 创建会员管理页面。
  const MembershipsPage({super.key});

  /// 创建页面状态。
  @override
  ConsumerState<MembershipsPage> createState() => _MembershipsPageState();
}

/// 会员管理页面状态。
class _MembershipsPageState extends ConsumerState<MembershipsPage> {
  /// 搜索控制器。
  final TextEditingController _searchController = TextEditingController();

  /// 当前搜索词。
  String _query = '';

  /// 当前快捷筛选。
  _MembershipQuickFilter _quickFilter = _MembershipQuickFilter.all;

  /// 当前分类筛选；空值表示全部分类。
  String? _categoryFilter;

  /// 是否优先使用双列会员卡片布局。
  bool _useTwoColumns = true;

  /// 释放搜索控制器。
  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 打开会员编辑器。
  Future<void> _openEditor(
    BuildContext context, [
    MembershipRecord? membership,
  ]) async {
    await showOmniSideSheet<void>(
      context,
      builder: (BuildContext context) =>
          _MembershipEditorDialog(membership: membership),
    );
  }

  /// 删除会员。
  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    MembershipRecord membership,
  ) async {
    await ref.read(membershipRepositoryProvider).delete(membership.id);
    ref.invalidate(recycleBinItemsProvider);
    if (!context.mounted) {
      return;
    }
    showOmniMessage(
      context,
      message: '“${membership.name}”已移入回收站',
      tone: OmniMessageTone.success,
    );
  }

  /// 更新快捷筛选。
  void _selectQuickFilter(_MembershipQuickFilter value) {
    setState(() => _quickFilter = value);
  }

  /// 更新分类筛选。
  void _selectCategoryFilter(String? value) {
    setState(() => _categoryFilter = value);
  }

  /// 更新搜索词并保留其他筛选条件。
  void _updateSearchQuery(String value) {
    setState(() => _query = value);
  }

  /// 清空当前搜索词。
  void _clearSearchQuery() {
    _searchController.clear();
    setState(() => _query = '');
  }

  /// 判断会员是否符合当前快捷筛选。
  bool _matchesQuickFilter(
    MembershipRecord membership,
    MembershipStatus status,
  ) {
    return switch (_quickFilter) {
      _MembershipQuickFilter.all => true,
      _MembershipQuickFilter.upcoming =>
        status == MembershipStatus.upcoming ||
            status == MembershipStatus.renewalDue,
      _MembershipQuickFilter.autoRenew => membership.autoRenew,
    };
  }

  /// 返回会员当前有效的分类名称，优先使用 taxonomy ID 关联。
  Set<String> _categoryNamesForMembership(
    MembershipRecord membership,
    List<TaxonomyEntry> categoryEntries,
    Map<String, Set<String>> taxonomyLinks,
  ) {
    // 当前会员通过 ID 关联的分类名称。
    final Set<String> linkedNames = <String>{};
    for (final String taxonomyId
        in taxonomyLinks[membership.id] ?? const <String>{}) {
      for (final TaxonomyEntry entry in categoryEntries) {
        if (entry.id == taxonomyId) {
          linkedNames.add(entry.name.trim());
          break;
        }
      }
    }
    if (linkedNames.isNotEmpty) {
      return linkedNames;
    }
    // 兼容尚未建立 taxonomy ID 关联的历史会员。
    final String legacyName = membership.category?.trim() ?? '';
    return legacyName.isEmpty ? const <String>{} : <String>{legacyName};
  }

  /// 返回会员卡片应展示的分类名称。
  String _categoryLabelForMembership(
    MembershipRecord membership,
    List<TaxonomyEntry> categoryEntries,
    Map<String, Set<String>> taxonomyLinks,
  ) {
    // 当前会员的分类名称集合。
    final Set<String> names = _categoryNamesForMembership(
      membership,
      categoryEntries,
      taxonomyLinks,
    );
    return names.isEmpty ? '未分类' : names.first;
  }

  /// 构建会员管理页面。
  @override
  Widget build(BuildContext context) {
    // 当前会员流。
    final AsyncValue<List<MembershipRecord>> memberships = ref.watch(
      membershipsProvider,
    );
    // 全部有效支付历史。
    final AsyncValue<List<MembershipPaymentRecord>> payments = ref.watch(
      activeMembershipPaymentsProvider,
    );
    // 会员仓储。
    final MembershipRepository repository = ref.watch(
      membershipRepositoryProvider,
    );
    // 当前日期。
    final DateTime now = ref.watch(nowProvider);
    // 当前会员分类管理器条目，用于保持筛选顺序一致。
    final List<TaxonomyEntry> membershipCategories =
        ref
            .watch(
              taxonomyEntriesProvider((
                TaxonomyModule.membership,
                TaxonomyKind.category,
              )),
            )
            .asData
            ?.value ??
        const <TaxonomyEntry>[];
    // 当前会员的规范分类和标签关联。
    final Map<String, Set<String>> membershipTaxonomyLinks =
        ref.watch(membershipTaxonomyLinksProvider).asData?.value ??
        const <String, Set<String>>{};
    // 当前是否为紧凑布局。
    final bool compact = OmniBreakpoint.isCompact(
      MediaQuery.sizeOf(context).width,
    );
    return Scaffold(
      body: Padding(
        padding: compact
            ? const EdgeInsets.fromLTRB(
                OmniSpacing.xs,
                OmniSpacing.xs,
                OmniSpacing.xs,
                OmniSpacing.md,
              )
            : const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: OmniSpacing.sm,
              ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            OmniPageHeader(
              title: '会员管理',
              actions: <Widget>[
                OmniButton(
                  label: '新增会员',
                  icon: Icons.add_rounded,
                  variant: OmniButtonVariant.pagePrimary,
                  onPressed: () => _openEditor(context),
                ),
              ],
            ),
            const SizedBox(height: OmniSpacing.xs),
            _MembershipSpendingSummary(
              memberships: memberships,
              payments: payments,
              now: now,
            ),
            const SizedBox(height: OmniSpacing.xs),
            _MembershipToolbar(
              memberships:
                  memberships.asData?.value ?? const <MembershipRecord>[],
              repository: repository,
              now: now,
              quickFilter: _quickFilter,
              categoryFilter: _categoryFilter,
              categoryEntries: membershipCategories,
              taxonomyLinks: membershipTaxonomyLinks,
              searchController: _searchController,
              searchQuery: _query,
              useTwoColumns: _useTwoColumns,
              onQuickFilterChanged: _selectQuickFilter,
              onCategoryFilterChanged: _selectCategoryFilter,
              onSearchChanged: _updateSearchQuery,
              onClearSearch: _clearSearchQuery,
              onToggleLayout: () =>
                  setState(() => _useTwoColumns = !_useTwoColumns),
            ),
            const SizedBox(height: OmniSpacing.xs),
            Expanded(
              child: memberships.when(
                data: (List<MembershipRecord> records) {
                  // 当前过滤结果。
                  final List<MembershipRecord> filtered = records
                      .where((MembershipRecord item) {
                        // 可搜索文本。
                        // 当前会员分类名称，优先使用 ID 关联后的名称。
                        final Set<String> categoryNames =
                            _categoryNamesForMembership(
                              item,
                              membershipCategories,
                              membershipTaxonomyLinks,
                            );
                        final String searchable = <String>[
                          item.name,
                          item.provider ?? '',
                          ...categoryNames,
                          item.description ?? '',
                        ].join(' ').toLowerCase();
                        // 当前搜索词。
                        final String keyword = _query.trim().toLowerCase();
                        return (keyword.isEmpty ||
                                searchable.contains(keyword)) &&
                            (_categoryFilter == null ||
                                categoryNames.contains(_categoryFilter)) &&
                            _matchesQuickFilter(
                              item,
                              repository.statusFor(item, now),
                            );
                      })
                      .toList(growable: false);
                  if (filtered.isEmpty) {
                    return const _MembershipEmpty();
                  }
                  return _MembershipCardGrid(
                    memberships: filtered,
                    payments:
                        payments.asData?.value ??
                        const <MembershipPaymentRecord>[],
                    useTwoColumns: _useTwoColumns,
                    categoryLabels: <String, String>{
                      for (final MembershipRecord item in records)
                        item.id: _categoryLabelForMembership(
                          item,
                          membershipCategories,
                          membershipTaxonomyLinks,
                        ),
                    },
                    onEdit: (MembershipRecord membership) =>
                        _openEditor(context, membership),
                    onDelete: (MembershipRecord membership) =>
                        _delete(context, ref, membership),
                    onHistory: (MembershipRecord membership) =>
                        showDialog<void>(
                          context: context,
                          builder: (BuildContext context) =>
                              _PaymentHistoryDialog(membership: membership),
                        ),
                    onRenew: (MembershipRecord membership) => showDialog<void>(
                      context: context,
                      builder: (BuildContext context) =>
                          _PaymentEditorDialog(membership: membership),
                    ),
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (Object error, StackTrace stackTrace) =>
                    Center(child: Text('会员读取失败：$error')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 会员快捷筛选类型。
enum _MembershipQuickFilter {
  /// 展示全部会员。
  all,

  /// 展示即将到期或待续费会员。
  upcoming,

  /// 展示自动续费会员。
  autoRenew,
}

/// 返回会员卡片使用的精简计费周期文案。
String _membershipBillingCycleLabel(String billingCycle) {
  return switch (billingCycle) {
    'week' => '周',
    'month' => '月',
    'quarter' => '季',
    'halfYear' => '半年',
    'year' => '年',
    'twoYears' => '2 年',
    'threeYears' => '3 年',
    'permanent' => '买断',
    _ => '自定义',
  };
}

/// 会员支出摘要。
class _MembershipSpendingSummary extends ConsumerWidget {
  /// 当前会员流。
  final AsyncValue<List<MembershipRecord>> memberships;

  /// 全部有效支付历史。
  final AsyncValue<List<MembershipPaymentRecord>> payments;

  /// 当前日期。
  final DateTime now;

  /// 创建会员支出摘要。
  const _MembershipSpendingSummary({
    required this.memberships,
    required this.payments,
    required this.now,
  });

  /// 按自然周汇总本月支付金额。
  List<int> _monthWeeklySpending(List<MembershipPaymentRecord> records) {
    // 本月最多五个自然周桶。
    final List<int> weeklyCents = List<int>.filled(5, 0);
    for (final MembershipPaymentRecord payment in records) {
      if (payment.paidAt.year != now.year ||
          payment.paidAt.month != now.month) {
        continue;
      }
      // 当前支付记录所属的周序号。
      final int weekIndex = (payment.paidAt.day - 1) ~/ 7;
      // 月末不足一周的日期并入第五个周桶。
      final int safeIndex = weekIndex > 4 ? 4 : weekIndex;
      weeklyCents[safeIndex] += payment.amountCents;
    }
    return weeklyCents;
  }

  /// 按月份汇总本年度支付金额。
  List<int> _yearMonthlySpending(
    MembershipRepository repository,
    List<MembershipPaymentRecord> records,
  ) {
    return List<int>.generate(
      12,
      (int index) => repository.summarizeSpending(
        records,
        year: now.year,
        month: index + 1,
      ),
    );
  }

  /// 按日期汇总未来三天自动续费会员数量。
  List<int> _upcomingRenewalsByDay(List<MembershipRecord> memberships) {
    // 今天的日期部分。
    final DateTime today = DateUtils.dateOnly(now);
    return List<int>.generate(3, (int index) {
      // 当前统计日期。
      final DateTime targetDay = today.add(Duration(days: index));
      return memberships.where((MembershipRecord membership) {
        // 当前会员续费日期。
        final DateTime? renewalDate = membership.renewalDate;
        return membership.autoRenew &&
            renewalDate != null &&
            DateUtils.isSameDay(renewalDate, targetDay);
      }).length;
    });
  }

  /// 构建本月、本年与未来续费摘要。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 会员仓储。
    final MembershipRepository repository = ref.watch(
      membershipRepositoryProvider,
    );
    // 支付历史。
    final List<MembershipPaymentRecord> records =
        payments.asData?.value ?? const <MembershipPaymentRecord>[];
    // 本月支出分值。
    final int monthCents = repository.summarizeSpending(
      records,
      year: now.year,
      month: now.month,
    );
    // 本年支出分值。
    final int yearCents = repository.summarizeSpending(records, year: now.year);
    // 上个月日期锚点。
    final DateTime previousMonth = DateTime(now.year, now.month - 1);
    // 上月支出分值。
    final int previousMonthCents = repository.summarizeSpending(
      records,
      year: previousMonth.year,
      month: previousMonth.month,
    );
    // 本月与上月支出差额。
    final int monthDifference = monthCents - previousMonthCents;
    // 本月支付记录数量。
    final int monthPaymentCount = records
        .where(
          (MembershipPaymentRecord payment) =>
              payment.paidAt.year == now.year &&
              payment.paidAt.month == now.month,
        )
        .length;
    // 今天的日期部分。
    final DateTime today = DateUtils.dateOnly(now);
    // 三天统计窗口的结束日期，不包含该日期。
    final DateTime renewalWindowEnd = today.add(const Duration(days: 3));
    // 未来三天内将自动续费的会员数量。
    final int upcomingRenewalCount =
        (memberships.asData?.value ?? const <MembershipRecord>[]).where((
          MembershipRecord membership,
        ) {
          // 当前会员的续费日期。
          final DateTime? renewalDate = membership.renewalDate;
          if (!membership.autoRenew || renewalDate == null) {
            return false;
          }
          // 仅比较自然日。
          final DateTime renewalDay = DateUtils.dateOnly(renewalDate);
          return !renewalDay.isBefore(today) &&
              renewalDay.isBefore(renewalWindowEnd);
        }).length;
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 月度环比金额的绝对值文案。
    final String monthDifferenceAmount =
        '¥ ${(monthDifference.abs() / 100).toStringAsFixed(2)}';
    // 月度环比自然语言文案，不使用容易误读的正负号。
    final String monthComparison = monthDifference == 0
        ? '本月与上月持平'
        : monthDifference > 0
        ? '本月比上月多 $monthDifferenceAmount'
        : '本月比上月少 $monthDifferenceAmount';
    // 月度环比语义色；支出增加提醒，支出减少表示改善。
    final Color monthComparisonColor = monthDifference == 0
        ? colors.muted
        : monthDifference > 0
        ? colors.warning
        : colors.success;
    // 全部会员记录。
    final List<MembershipRecord> membershipRecords =
        memberships.asData?.value ?? const <MembershipRecord>[];
    // 三张摘要卡片。
    final List<Widget> cards = <Widget>[
      _MembershipMetricCard(
        label: '本月支出',
        value: '¥ ${(monthCents / 100).toStringAsFixed(2)}',
        hint: '$monthPaymentCount 笔支付',
        badge: '当前月份',
        icon: Icons.account_balance_wallet_outlined,
        accent: colors.member,
        badgeAccent: colors.member,
        chartValues: _monthWeeklySpending(records),
      ),
      _MembershipMetricCard(
        label: '年度累计',
        value: '¥ ${(yearCents / 100).toStringAsFixed(2)}',
        hint: '累计会员支出',
        badge: monthComparison,
        icon: Icons.trending_up_rounded,
        accent: colors.brand,
        badgeAccent: monthComparisonColor,
        chartValues: _yearMonthlySpending(repository, records),
      ),
      _MembershipMetricCard(
        label: '即将续费',
        value: '$upcomingRenewalCount 项',
        hint: '未来 3 天',
        badge: upcomingRenewalCount > 0 ? '请及时处理' : '暂无待处理',
        icon: Icons.notifications_none_rounded,
        accent: upcomingRenewalCount > 0 ? colors.warning : colors.success,
        badgeAccent: upcomingRenewalCount > 0 ? colors.warning : colors.success,
        chartValues: _upcomingRenewalsByDay(membershipRecords),
      ),
    ];
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 摘要卡片是否横向完整展示。
        final bool showCompleteRow = constraints.maxWidth >= 720;
        if (!showCompleteRow) {
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                for (
                  int index = 0;
                  index < cards.length;
                  index += 1
                ) ...<Widget>[
                  if (index > 0) const SizedBox(width: OmniSpacing.xs),
                  SizedBox(width: 260, child: cards[index]),
                ],
              ],
            ),
          );
        }
        return Row(
          children: <Widget>[
            for (int index = 0; index < cards.length; index += 1) ...<Widget>[
              if (index > 0) const SizedBox(width: OmniSpacing.xs),
              Expanded(child: cards[index]),
            ],
          ],
        );
      },
    );
  }
}

/// 会员摘要指标卡片。
class _MembershipMetricCard extends StatelessWidget {
  /// 指标名称。
  final String label;

  /// 指标值。
  final String value;

  /// 指标辅助说明。
  final String hint;

  /// 指标状态标签。
  final String badge;

  /// 指标图标。
  final IconData icon;

  /// 指标强调色。
  final Color accent;

  /// 状态标签语义色。
  final Color badgeAccent;

  /// 迷你柱状图数据。
  final List<int> chartValues;

  /// 创建会员摘要指标卡片。
  const _MembershipMetricCard({
    required this.label,
    required this.value,
    required this.hint,
    required this.badge,
    required this.icon,
    required this.accent,
    required this.badgeAccent,
    required this.chartValues,
  });

  /// 构建固定高度的摘要卡片。
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: ValueKey<String>('membership-metric-$label'),
      height: 160,
      child: OmniPanel(
        padding: const EdgeInsets.all(OmniSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: OmniSize.control,
                  height: OmniSize.control,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(OmniRadius.panel),
                  ),
                  alignment: Alignment.center,
                  child: Icon(icon, size: OmniSize.icon, color: accent),
                ),
                const SizedBox(width: OmniSpacing.xs),
                Text(label, style: Theme.of(context).textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: OmniSpacing.xs),
            Text(value, style: Theme.of(context).textTheme.displaySmall),
            const Spacer(),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const SizedBox(width: OmniSpacing.xs),
                Flexible(
                  flex: 2,
                  child: Tooltip(
                    message: badge,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: OmniSpacing.xs,
                        vertical: OmniSpacing.xxs,
                      ),
                      decoration: BoxDecoration(
                        color: badgeAccent.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(OmniRadius.pill),
                      ),
                      child: Text(
                        badge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: badgeAccent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: OmniSpacing.xs),
            _MembershipMiniBarChart(
              key: ValueKey<String>('membership-metric-chart-$label'),
              values: chartValues,
              color: accent,
            ),
          ],
        ),
      ),
    );
  }
}

/// 会员统计卡底部的迷你柱状图。
class _MembershipMiniBarChart extends StatelessWidget {
  /// 各时间段的统计值。
  final List<int> values;

  /// 柱状图强调色。
  final Color color;

  /// 创建迷你柱状图。
  const _MembershipMiniBarChart({
    required this.values,
    required this.color,
    super.key,
  });

  /// 构建占据独立高度且不与卡片信息重叠的柱状图。
  @override
  Widget build(BuildContext context) {
    // 所有时间段中的最大值。
    int maxValue = 0;
    for (final int value in values) {
      if (value > maxValue) {
        maxValue = value;
      }
    }
    return Container(
      height: 18,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: color.withValues(alpha: 0.2))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          for (int index = 0; index < values.length; index += 1) ...<Widget>[
            if (index > 0) const SizedBox(width: OmniSpacing.xxs),
            Expanded(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  width: 6,
                  height: maxValue == 0
                      ? 2
                      : 2 + (values[index] / maxValue) * 14,
                  decoration: BoxDecoration(
                    color: color.withValues(
                      alpha: values[index] == 0 ? 0.14 : 0.68,
                    ),
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(OmniRadius.tiny),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 会员列表上方的快捷筛选与布局工具栏。
class _MembershipToolbar extends StatelessWidget {
  /// 全部会员。
  final List<MembershipRecord> memberships;

  /// 会员仓储。
  final MembershipRepository repository;

  /// 当前日期。
  final DateTime now;

  /// 当前快捷筛选。
  final _MembershipQuickFilter quickFilter;

  /// 当前分类筛选。
  final String? categoryFilter;

  /// 会员分类管理器条目。
  final List<TaxonomyEntry> categoryEntries;

  /// 会员与规范分类、标签的关联标识。
  final Map<String, Set<String>> taxonomyLinks;

  /// 搜索输入控制器。
  final TextEditingController searchController;

  /// 当前搜索词。
  final String searchQuery;

  /// 是否优先使用双列布局。
  final bool useTwoColumns;

  /// 快捷筛选变更回调。
  final ValueChanged<_MembershipQuickFilter> onQuickFilterChanged;

  /// 分类筛选变更回调。
  final ValueChanged<String?> onCategoryFilterChanged;

  /// 搜索词变更回调。
  final ValueChanged<String> onSearchChanged;

  /// 清空搜索回调。
  final VoidCallback onClearSearch;

  /// 布局切换回调。
  final VoidCallback onToggleLayout;

  /// 创建会员工具栏。
  const _MembershipToolbar({
    required this.memberships,
    required this.repository,
    required this.now,
    required this.quickFilter,
    required this.categoryFilter,
    required this.categoryEntries,
    required this.taxonomyLinks,
    required this.searchController,
    required this.searchQuery,
    required this.useTwoColumns,
    required this.onQuickFilterChanged,
    required this.onCategoryFilterChanged,
    required this.onSearchChanged,
    required this.onClearSearch,
    required this.onToggleLayout,
  });

  /// 构建快捷筛选与右侧操作。
  @override
  Widget build(BuildContext context) {
    // 即将到期或待续费会员数量。
    final int upcomingCount = memberships.where((MembershipRecord membership) {
      // 当前会员状态。
      final MembershipStatus status = repository.statusFor(membership, now);
      return status == MembershipStatus.upcoming ||
          status == MembershipStatus.renewalDue;
    }).length;
    // 自动续费会员数量。
    final int autoRenewCount = memberships
        .where((MembershipRecord membership) => membership.autoRenew)
        .length;
    // 会员分类名称与数量。
    final Map<String, int> categoryCounts = <String, int>{};
    for (final MembershipRecord membership in memberships) {
      // 当前会员的分类标识优先解析为 taxonomy 名称。
      final Set<String> categoriesForMembership = <String>{};
      for (final String taxonomyId
          in taxonomyLinks[membership.id] ?? const <String>{}) {
        for (final TaxonomyEntry entry in categoryEntries) {
          if (entry.id == taxonomyId) {
            categoriesForMembership.add(entry.name.trim());
            break;
          }
        }
      }
      if (categoriesForMembership.isEmpty &&
          (membership.category?.trim().isNotEmpty ?? false)) {
        categoriesForMembership.add(membership.category!.trim());
      }
      for (final String category in categoriesForMembership) {
        categoryCounts.update(
          category,
          (int count) => count + 1,
          ifAbsent: () => 1,
        );
      }
    }
    // 按分类管理器 sortOrder 排列，未纳入管理器的旧分类再稳定追加。
    final List<String> categories = <String>[];
    final Set<String> remainingCategories = categoryCounts.keys.toSet();
    for (final TaxonomyEntry entry in categoryEntries) {
      final String category = entry.name.trim();
      if (remainingCategories.remove(category)) {
        categories.add(category);
      }
    }
    final List<String> unmanagedCategories = remainingCategories.toList()
      ..sort();
    categories.addAll(unmanagedCategories);
    if (categoryFilter != null && !categories.contains(categoryFilter)) {
      categories.add(categoryFilter!);
      categoryCounts[categoryFilter!] = 0;
    }
    // 快捷筛选控件。
    final Widget quickFilters = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: _MembershipQuickFilters(
        selected: quickFilter,
        counts: <_MembershipQuickFilter, int>{
          _MembershipQuickFilter.all: memberships.length,
          _MembershipQuickFilter.upcoming: upcomingCount,
          _MembershipQuickFilter.autoRenew: autoRenewCount,
        },
        onChanged: onQuickFilterChanged,
      ),
    );
    // 常驻在快捷筛选右侧的会员搜索框。
    final Widget searchField = _MembershipSearchField(
      controller: searchController,
      query: searchQuery,
      onChanged: onSearchChanged,
      onClear: onClearSearch,
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 当前宽度是否允许双列会员卡片。
        final bool canUseTwoColumns = constraints.maxWidth >= 780;
        // 右侧工具栏操作。
        final Widget actions = Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            OmniButton(
              key: const ValueKey<String>('membership-layout-toggle'),
              label: canUseTwoColumns
                  ? useTwoColumns
                        ? '单列'
                        : '双列'
                  : '单列',
              icon: useTwoColumns && canUseTwoColumns
                  ? Icons.view_agenda_outlined
                  : Icons.grid_view_outlined,
              variant: OmniButtonVariant.secondary,
              onPressed: canUseTwoColumns ? onToggleLayout : null,
            ),
            const SizedBox(width: OmniSpacing.xs),
            OmniButton(
              label: '管理分类',
              icon: Icons.category_outlined,
              variant: OmniButtonVariant.secondary,
              onPressed: () => TaxonomyManagerDialog.show(
                context,
                module: TaxonomyModule.membership,
                kind: TaxonomyKind.category,
              ),
            ),
          ],
        );
        // 根据可用宽度组合快捷筛选、搜索和操作按钮。
        final Widget primaryToolbar;
        if (constraints.maxWidth < 700) {
          primaryToolbar = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              quickFilters,
              const SizedBox(height: OmniSpacing.xs),
              searchField,
              const SizedBox(height: OmniSpacing.xs),
              actions,
            ],
          );
        } else if (constraints.maxWidth < 900) {
          primaryToolbar = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  quickFilters,
                  const SizedBox(width: OmniSpacing.xs),
                  searchField,
                ],
              ),
              const SizedBox(height: OmniSpacing.xs),
              actions,
            ],
          );
        } else {
          primaryToolbar = Row(
            children: <Widget>[
              quickFilters,
              const SizedBox(width: OmniSpacing.xs),
              searchField,
              const Spacer(),
              const SizedBox(width: OmniSpacing.xs),
              actions,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            primaryToolbar,
            const SizedBox(height: OmniSpacing.xs),
            _MembershipCategoryFilters(
              categories: categories,
              categoryCounts: categoryCounts,
              membershipsCount: memberships.length,
              selectedCategory: categoryFilter,
              onChanged: onCategoryFilterChanged,
            ),
          ],
        );
      },
    );
  }
}

/// 会员快捷筛选的连续轨道控件。
class _MembershipQuickFilters extends StatelessWidget {
  /// 当前选中的快捷筛选。
  final _MembershipQuickFilter selected;

  /// 各快捷筛选对应的数量。
  final Map<_MembershipQuickFilter, int> counts;

  /// 快捷筛选变更回调。
  final ValueChanged<_MembershipQuickFilter> onChanged;

  /// 创建会员快捷筛选轨道。
  const _MembershipQuickFilters({
    required this.selected,
    required this.counts,
    required this.onChanged,
  });

  /// 构建带滑块动画的快捷筛选控件。
  @override
  Widget build(BuildContext context) {
    // 快捷筛选的固定顺序。
    const List<_MembershipQuickFilter> options = <_MembershipQuickFilter>[
      _MembershipQuickFilter.all,
      _MembershipQuickFilter.upcoming,
      _MembershipQuickFilter.autoRenew,
    ];
    // 快捷筛选标签文案。
    String labelFor(_MembershipQuickFilter option) {
      return switch (option) {
        _MembershipQuickFilter.all => '全部',
        _MembershipQuickFilter.upcoming => '即将到期',
        _MembershipQuickFilter.autoRenew => '自动续费',
      };
    }

    return OmniSlidingSegmentedControl<_MembershipQuickFilter>(
      key: const ValueKey<String>('membership-quick-filters'),
      options: options,
      selected: selected,
      width: 306,
      labelBuilder: labelFor,
      itemKeyBuilder: (_MembershipQuickFilter option) =>
          ValueKey<String>('membership-quick-${option.name}'),
      onChanged: onChanged,
    );
  }
}

/// 会员分类标签筛选行。
class _MembershipCategoryFilters extends StatelessWidget {
  /// 全部会员数量。
  final int membershipsCount;

  /// 可选分类名称。
  final List<String> categories;

  /// 各分类会员数量。
  final Map<String, int> categoryCounts;

  /// 当前选中的分类。
  final String? selectedCategory;

  /// 分类变更回调。
  final ValueChanged<String?> onChanged;

  /// 创建会员分类标签筛选行。
  const _MembershipCategoryFilters({
    required this.membershipsCount,
    required this.categories,
    required this.categoryCounts,
    required this.selectedCategory,
    required this.onChanged,
  });

  /// 构建保持单行且可横向滚动的分类标签。
  @override
  Widget build(BuildContext context) {
    // 当前主题的会员与中性色。
    final OmniColors colors = OmniColors.of(context);
    return SizedBox(
      key: const ValueKey<String>('membership-category-filters'),
      height: OmniSize.control,
      child: Row(
        children: <Widget>[
          Text(
            '分类',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: colors.muted,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(width: OmniSpacing.xs),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: categories.length + 1,
              separatorBuilder: (BuildContext context, int index) =>
                  const SizedBox(width: OmniSpacing.xs),
              itemBuilder: (BuildContext context, int index) {
                // 当前标签对应的分类；首项为空代表全部分类。
                final String? category = index == 0
                    ? null
                    : categories[index - 1];
                // 当前标签是否处于选中状态。
                final bool selected = category == selectedCategory;
                return ChoiceChip(
                  key: ValueKey<String>(
                    'membership-category-${category ?? 'all'}',
                  ),
                  label: Text(
                    '${category ?? '全部分类'} ${category == null ? membershipsCount : categoryCounts[category] ?? 0}',
                  ),
                  selected: selected,
                  showCheckmark: false,
                  onSelected: (bool value) =>
                      onChanged(value ? category : null),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: OmniSpacing.xs,
                  ),
                  backgroundColor: colors.paper,
                  selectedColor: colors.member.withValues(alpha: 0.12),
                  side: BorderSide(
                    color: selected
                        ? colors.member.withValues(alpha: 0.42)
                        : colors.line,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(OmniRadius.control),
                  ),
                  labelStyle: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: selected ? colors.member : colors.muted,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 会员工具栏中的紧凑搜索框。
class _MembershipSearchField extends StatelessWidget {
  /// 搜索输入控制器。
  final TextEditingController controller;

  /// 当前搜索词。
  final String query;

  /// 搜索词变更回调。
  final ValueChanged<String> onChanged;

  /// 清空搜索回调。
  final VoidCallback onClear;

  /// 创建会员搜索框。
  const _MembershipSearchField({
    required this.controller,
    required this.query,
    required this.onChanged,
    required this.onClear,
  });

  /// 构建带会员色搜索图标的紧凑输入框。
  @override
  Widget build(BuildContext context) {
    // 当前主题的会员与中性色。
    final OmniColors colors = OmniColors.of(context);
    return SizedBox(
      key: const ValueKey<String>('membership-search-field'),
      width: 260,
      height: OmniSize.pageAction,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        style: Theme.of(context).textTheme.bodyMedium,
        decoration: InputDecoration(
          hintText: '搜索会员、服务商或分类',
          fillColor: colors.paper,
          contentPadding: EdgeInsets.zero,
          prefixIconConstraints: const BoxConstraints(
            minWidth: 42,
            minHeight: OmniSize.pageAction,
          ),
          prefixIcon: Padding(
            padding: const EdgeInsets.all(OmniSpacing.xxs),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.member.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(OmniRadius.control),
              ),
              child: Icon(
                Icons.search_rounded,
                size: OmniSize.icon,
                color: colors.member,
              ),
            ),
          ),
          suffixIconConstraints: const BoxConstraints(
            minWidth: OmniSize.control,
            minHeight: OmniSize.control,
          ),
          suffixIcon: query.isEmpty
              ? null
              : IconButton(
                  tooltip: '清空搜索',
                  onPressed: onClear,
                  icon: const Icon(Icons.close_rounded),
                ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(OmniRadius.panel),
            borderSide: BorderSide(color: colors.line),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(OmniRadius.panel),
            borderSide: BorderSide(color: colors.member, width: 1.5),
          ),
        ),
      ),
    );
  }
}

/// 自适应单双列会员卡片区域。
class _MembershipCardGrid extends StatelessWidget {
  /// 当前过滤后的会员。
  final List<MembershipRecord> memberships;

  /// 全部有效会员支付记录。
  final List<MembershipPaymentRecord> payments;

  /// 每个会员当前分类名称。
  final Map<String, String> categoryLabels;

  /// 是否优先使用双列布局。
  final bool useTwoColumns;

  /// 编辑会员回调。
  final ValueChanged<MembershipRecord> onEdit;

  /// 删除会员回调。
  final ValueChanged<MembershipRecord> onDelete;

  /// 查看支付记录回调。
  final ValueChanged<MembershipRecord> onHistory;

  /// 续费回调。
  final ValueChanged<MembershipRecord> onRenew;

  /// 创建会员卡片区域。
  const _MembershipCardGrid({
    required this.memberships,
    required this.payments,
    required this.categoryLabels,
    required this.useTwoColumns,
    required this.onEdit,
    required this.onDelete,
    required this.onHistory,
    required this.onRenew,
  });

  /// 构建可滚动的会员卡片流。
  @override
  Widget build(BuildContext context) {
    // 每个会员最近一笔支付或续费记录。
    final Map<String, MembershipPaymentRecord> latestPayments =
        <String, MembershipPaymentRecord>{};
    for (final MembershipPaymentRecord payment in payments) {
      // 当前会员已经找到的最近支付记录。
      final MembershipPaymentRecord? current =
          latestPayments[payment.membershipId];
      if (current == null || payment.paidAt.isAfter(current.paidAt)) {
        latestPayments[payment.membershipId] = payment;
      }
    }
    return ListView(
      children: <Widget>[
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            // 当前宽度下是否实际使用双列布局。
            final bool showTwoColumns =
                useTwoColumns && constraints.maxWidth >= 780;
            // 单张会员卡片宽度。
            final double cardWidth = showTwoColumns
                ? (constraints.maxWidth - OmniSpacing.sm) / 2
                : constraints.maxWidth;
            return Wrap(
              spacing: OmniSpacing.xs,
              runSpacing: OmniSpacing.xs,
              children: memberships
                  .map((MembershipRecord membership) {
                    return SizedBox(
                      width: cardWidth,
                      child: _MembershipCard(
                        key: ValueKey<String>(
                          'membership-card-${membership.id}',
                        ),
                        membership: membership,
                        categoryLabel: categoryLabels[membership.id] ?? '未分类',
                        latestPayment: latestPayments[membership.id],
                        onEdit: () => onEdit(membership),
                        onDelete: () => onDelete(membership),
                        onHistory: () => onHistory(membership),
                        onRenew: () => onRenew(membership),
                      ),
                    );
                  })
                  .toList(growable: false),
            );
          },
        ),
      ],
    );
  }
}

/// 会员卡片。
class _MembershipCard extends ConsumerWidget {
  /// 当前会员。
  final MembershipRecord membership;

  /// 当前会员分类名称。
  final String categoryLabel;

  /// 最近一笔支付或续费记录。
  final MembershipPaymentRecord? latestPayment;

  /// 编辑回调。
  final VoidCallback onEdit;

  /// 删除回调。
  final VoidCallback onDelete;

  /// 支付历史回调。
  final VoidCallback onHistory;

  /// 续费回调。
  final VoidCallback onRenew;

  /// 创建会员卡片。
  const _MembershipCard({
    required this.membership,
    required this.categoryLabel,
    required this.latestPayment,
    required this.onEdit,
    required this.onDelete,
    required this.onHistory,
    required this.onRenew,
    super.key,
  });

  /// 构建会员卡片。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 会员仓储。
    final MembershipRepository repository = ref.watch(
      membershipRepositoryProvider,
    );
    // 当前状态。
    final MembershipStatus status = repository.statusFor(
      membership,
      ref.watch(nowProvider),
    );
    // 当前日期。
    final DateTime now = ref.watch(nowProvider);
    // 主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 状态展示信息。
    final (String, Color) statusView = switch (status) {
      MembershipStatus.permanent => ('永久有效', colors.info),
      MembershipStatus.trial => ('试用中', colors.info),
      MembershipStatus.active => ('有效', colors.success),
      MembershipStatus.cancelled => ('已取消', colors.muted),
      MembershipStatus.renewalDue => ('待续费', colors.warning),
      MembershipStatus.upcoming => ('即将到期', colors.warning),
      MembershipStatus.expired => ('已过期', colors.danger),
    };
    // 分类与描述组成的次级信息。
    final String detail = <String>[
      categoryLabel,
      if (membership.description?.trim().isNotEmpty ?? false)
        membership.description!.trim(),
    ].join(' · ');
    // 当前计费周期文案。
    final String billingCycleLabel = _membershipBillingCycleLabel(
      membership.billingCycle,
    );
    // 时间条使用的最近购买或续费日期。
    final DateTime timelineStartDate =
        latestPayment?.paidAt ?? membership.purchaseDate;
    // 时间条是否从续费日期开始。
    final bool timelineStartsFromRenewal = DateUtils.dateOnly(timelineStartDate)
        .isAfter(DateUtils.dateOnly(membership.purchaseDate));
    return OmniPanel(
      padding: const EdgeInsets.all(OmniSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: colors.member.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(OmniRadius.control),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: membership.imageLocalPath == null
                          ? Icon(Icons.loyalty_rounded, color: colors.member)
                          : Image.file(
                              File(membership.imageLocalPath!),
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => Icon(
                                Icons.broken_image_outlined,
                                color: colors.muted,
                              ),
                            ),
                    ),
                    const SizedBox(width: OmniSpacing.xs),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Wrap(
                            spacing: OmniSpacing.xs,
                            runSpacing: OmniSpacing.xxs,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: <Widget>[
                              Text(
                                membership.name,
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              OmniTag(
                                label: statusView.$1,
                                color: statusView.$2,
                              ),
                            ],
                          ),
                          const SizedBox(height: OmniSpacing.xxs),
                          Text(
                            detail,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: OmniSpacing.xs),
                _MembershipExpirationTimeline(
                  key: ValueKey<String>('membership-timeline-${membership.id}'),
                  membership: membership,
                  startDate: timelineStartDate,
                  startsFromRenewal: timelineStartsFromRenewal,
                  now: now,
                  progressColor: colors.member,
                  statusColor: statusView.$2,
                ),
              ],
            ),
          ),
          const SizedBox(width: OmniSpacing.xs),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Text.rich(
                key: ValueKey<String>('membership-price-${membership.id}'),
                TextSpan(
                  text: '¥ ${(membership.priceCents / 100).toStringAsFixed(2)}',
                  children: <InlineSpan>[
                    TextSpan(
                      text:
                          '${membership.isPermanent ? ' · ' : ' / '}$billingCycleLabel',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: OmniSpacing.xs),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (!membership.autoRenew &&
                      !membership.isPermanent) ...<Widget>[
                    OmniButton(
                      key: ValueKey<String>(
                        'membership-renew-${membership.id}',
                      ),
                      label: '续费',
                      variant: OmniButtonVariant.text,
                      onPressed: onRenew,
                    ),
                    const SizedBox(width: OmniSpacing.xxs),
                  ],
                  OmniPopupMenuButton<String>(
                    tooltip: '更多操作',
                    menuConstraints: BoxConstraints(
                      minWidth: OmniDropdownMetrics.actionMenuMinWidth * 0.85,
                      maxWidth: OmniDropdownMetrics.actionMenuMaxWidth * 0.85,
                    ),
                    onSelected: (String value) {
                      if (value == 'history') {
                        onHistory();
                      } else if (value == 'edit') {
                        onEdit();
                      } else if (value == 'image') {
                        AttachmentPickerDialog.show(
                          context,
                          businessType: AttachmentBusinessType.membershipImage,
                          businessId: membership.id,
                          title: '${membership.name} · 主图',
                        );
                      } else {
                        onDelete();
                      }
                    },
                    itemBuilder: (_) => <PopupMenuEntry<String>>[
                      OmniPopupMenuItem<String>(
                        value: 'history',
                        label: '支付记录',
                        icon: Icons.receipt_long_outlined,
                      ),
                      OmniPopupMenuItem<String>(
                        value: 'edit',
                        label: '编辑',
                        icon: Icons.edit_outlined,
                      ),
                      OmniPopupMenuItem<String>(
                        value: 'image',
                        label: '更换图片',
                        icon: Icons.add_photo_alternate_outlined,
                      ),
                      OmniPopupMenuItem<String>(
                        value: 'delete',
                        label: '移入回收站',
                        icon: Icons.delete_outline_rounded,
                        danger: true,
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 会员购买日至到期日的时间进度条。
class _MembershipExpirationTimeline extends StatelessWidget {
  /// 当前会员。
  final MembershipRecord membership;

  /// 当前周期的起始日期。
  final DateTime startDate;

  /// 当前周期是否由续费开始。
  final bool startsFromRenewal;

  /// 当前日期。
  final DateTime now;

  /// 时间条进度色。
  final Color progressColor;

  /// 剩余状态文字色。
  final Color statusColor;

  /// 创建会员到期时间条。
  const _MembershipExpirationTimeline({
    required this.membership,
    required this.startDate,
    required this.startsFromRenewal,
    required this.now,
    required this.progressColor,
    required this.statusColor,
    super.key,
  });

  /// 构建到期进度与三段日期说明。
  @override
  Widget build(BuildContext context) {
    // 主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前周期的起始日期。
    final DateTime periodStartDay = DateUtils.dateOnly(startDate);
    // 当前日期。
    final DateTime today = DateUtils.dateOnly(now);
    // 可选到期日期。
    final DateTime? expirationDay = membership.expirationDate == null
        ? null
        : DateUtils.dateOnly(membership.expirationDate!);
    // 会员有效期总天数。
    final int totalDays = expirationDay?.difference(periodStartDay).inDays ?? 1;
    // 已经过的有效期天数。
    final int elapsedDays = today.difference(periodStartDay).inDays;
    // 当前有效期进度。
    final double progress = membership.isPermanent
        ? 1
        : totalDays <= 0
        ? 1
        : (elapsedDays / totalDays).clamp(0.0, 1.0).toDouble();
    // 剩余状态文案。
    final String remainingLabel;
    if (membership.isPermanent || expirationDay == null) {
      remainingLabel = '永久有效';
    } else {
      // 距离到期的自然日数量。
      final int remainingDays = expirationDay.difference(today).inDays;
      remainingLabel = remainingDays > 0
          ? '剩余 $remainingDays 天'
          : remainingDays == 0
          ? '今天到期'
          : '已过期 ${remainingDays.abs()} 天';
    }
    // 到期端文案。
    final String expirationLabel = expirationDay == null
        ? '无到期日'
        : '到期 ${DateFormat('yyyy-MM-dd').format(expirationDay)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          height: 10,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              // 当前进度点的水平位置。
              final double progressLeft = (constraints.maxWidth - 8) * progress;
              return Stack(
                alignment: Alignment.centerLeft,
                children: <Widget>[
                  Positioned.fill(
                    top: 3,
                    bottom: 3,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.mist,
                        borderRadius: BorderRadius.circular(OmniRadius.pill),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    top: 3,
                    bottom: 3,
                    width: constraints.maxWidth * progress,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: progressColor,
                        borderRadius: BorderRadius.circular(OmniRadius.pill),
                      ),
                    ),
                  ),
                  Positioned(
                    left: progressLeft,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: progressColor,
                        shape: BoxShape.circle,
                        border: Border.all(color: colors.paper, width: 2),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 0,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: progress >= 1 ? progressColor : colors.mist,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: OmniSpacing.xxs),
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '${startsFromRenewal ? '续费' : '购买'} '
                '${DateFormat('yyyy-MM-dd').format(periodStartDay)}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
            Expanded(
              child: Text(
                remainingLabel,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: statusColor, fontWeight: FontWeight.w400),
              ),
            ),
            Expanded(
              child: Text(
                expirationLabel,
                textAlign: TextAlign.end,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 会员空状态。
class _MembershipEmpty extends StatelessWidget {
  /// 创建会员空状态。
  const _MembershipEmpty();

  /// 构建会员空状态。
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.loyalty_outlined, size: 48),
          SizedBox(height: 14),
          Text('从下一笔可能自动续费的会员开始记录'),
        ],
      ),
    );
  }
}

/// 会员编辑弹窗。
class _MembershipEditorDialog extends ConsumerStatefulWidget {
  /// 可选待编辑会员。
  final MembershipRecord? membership;

  /// 创建会员编辑弹窗。
  const _MembershipEditorDialog({this.membership});

  /// 创建弹窗状态。
  @override
  ConsumerState<_MembershipEditorDialog> createState() =>
      _MembershipEditorDialogState();
}

/// 会员编辑弹窗状态。
class _MembershipEditorDialogState
    extends ConsumerState<_MembershipEditorDialog> {
  /// 表单键。
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  /// 名称控制器。
  late final TextEditingController _nameController;

  /// 服务商控制器。
  late final TextEditingController _providerController;

  /// 分类控制器。
  late final TextEditingController _categoryController;

  /// 会员说明控制器。
  late final TextEditingController _descriptionController;

  /// 官网链接控制器。
  late final TextEditingController _websiteController;

  /// 购买平台控制器。
  late final TextEditingController _platformController;

  /// 支付方式控制器。
  late final TextEditingController _paymentMethodController;

  /// 金额控制器。
  late final TextEditingController _priceController;

  /// 取消说明控制器。
  late final TextEditingController _cancelController;

  /// 备注控制器。
  late final TextEditingController _notesController;

  /// 到期提醒提前天数控制器。
  late final TextEditingController _expirationReminderDaysController;

  /// 续费提醒提前天数控制器。
  late final TextEditingController _renewalReminderDaysController;

  /// 购买日期。
  late DateTime _purchaseDate;

  /// 到期日期。
  DateTime? _expirationDate;

  /// 续费日期。
  DateTime? _renewalDate;

  /// 是否永久有效。
  late bool _isPermanent;

  /// 是否自动续费。
  late bool _autoRenew;

  /// 计费周期。
  late BillingCycle _billingCycle;

  /// 会员基础状态。
  late MembershipBaseStatus _baseStatus;

  /// 是否常用。
  late bool _isFavorite;

  /// 是否需要续费。
  late bool _needsRenewal;

  /// 是否开启到期提醒。
  late bool _expirationReminderEnabled;

  /// 是否开启续费提醒。
  late bool _renewalReminderEnabled;

  /// 提醒时刻相对午夜的分钟数。
  late int _reminderTimeMinutes;

  /// 已选择的会员标签标识。
  Set<String> _selectedTagIds = <String>{};

  /// 是否正在保存。
  bool _saving = false;

  /// 初始化会员表单。
  @override
  void initState() {
    super.initState();
    // 待编辑会员。
    final MembershipRecord? membership = widget.membership;
    _nameController = TextEditingController(text: membership?.name ?? '');
    _providerController = TextEditingController(
      text: membership?.provider ?? '',
    );
    _categoryController = TextEditingController(
      text: membership?.category ?? '',
    );
    _descriptionController = TextEditingController(
      text: membership?.description ?? '',
    );
    _websiteController = TextEditingController(
      text: membership?.websiteUrl ?? '',
    );
    _platformController = TextEditingController(
      text: membership?.purchasePlatform ?? '',
    );
    _paymentMethodController = TextEditingController(
      text: membership?.paymentMethod ?? '',
    );
    _priceController = TextEditingController(
      text: membership == null
          ? ''
          : (membership.priceCents / 100).toStringAsFixed(2),
    );
    _cancelController = TextEditingController(
      text: membership?.cancelGuide ?? '',
    );
    _notesController = TextEditingController(text: membership?.notes ?? '');
    _expirationReminderDaysController = TextEditingController(
      text: '${membership?.expirationReminderDays ?? 3}',
    );
    _renewalReminderDaysController = TextEditingController(
      text: '${membership?.renewalReminderDays ?? 7}',
    );
    _purchaseDate =
        membership?.purchaseDate ?? DateUtils.dateOnly(DateTime.now());
    _expirationDate =
        membership?.expirationDate ??
        DateUtils.dateOnly(DateTime.now()).add(const Duration(days: 365));
    _renewalDate = membership?.renewalDate;
    _isPermanent = membership?.isPermanent ?? false;
    _autoRenew = membership?.autoRenew ?? false;
    _billingCycle = BillingCycle.values.firstWhere(
      (BillingCycle value) => value.name == membership?.billingCycle,
      orElse: () => BillingCycle.year,
    );
    _baseStatus = MembershipBaseStatus.values.firstWhere(
      (MembershipBaseStatus value) => value.name == membership?.baseStatus,
      orElse: () => MembershipBaseStatus.active,
    );
    _isFavorite = membership?.isFavorite ?? false;
    _needsRenewal = membership?.needsRenewal ?? false;
    _expirationReminderEnabled = membership?.expirationReminderEnabled ?? false;
    _renewalReminderEnabled = membership?.renewalReminderEnabled ?? false;
    _reminderTimeMinutes = membership?.reminderTimeMinutes ?? 540;
    Future<void>.microtask(_loadTags);
    Future<void>.microtask(_loadCategory);
  }

  /// 读取现有会员标签关系。
  Future<void> _loadTags() async {
    // 待编辑会员标识。
    final String? membershipId = widget.membership?.id;
    if (membershipId == null) {
      return;
    }
    // 当前关联标签。
    final List<TaxonomyEntry> tags = await ref
        .read(taxonomyRepositoryProvider)
        .loadRecordTags(
          module: TaxonomyModule.membership,
          recordId: membershipId,
          kind: TaxonomyKind.tag,
        );
    if (mounted) {
      setState(
        () => _selectedTagIds = tags
            .map((TaxonomyEntry entry) => entry.id)
            .toSet(),
      );
    }
  }

  /// 读取现有会员分类关系并同步当前名称。
  Future<void> _loadCategory() async {
    // 待编辑会员标识。
    final String? membershipId = widget.membership?.id;
    if (membershipId == null) {
      return;
    }
    // 当前会员关联的分类条目。
    final List<TaxonomyEntry> categories = await ref
        .read(taxonomyRepositoryProvider)
        .loadRecordTags(
          module: TaxonomyModule.membership,
          recordId: membershipId,
          kind: TaxonomyKind.category,
        );
    if (mounted && categories.isNotEmpty) {
      setState(() => _categoryController.text = categories.first.name);
    }
  }

  /// 释放文本控制器。
  @override
  void dispose() {
    _nameController.dispose();
    _providerController.dispose();
    _categoryController.dispose();
    _descriptionController.dispose();
    _websiteController.dispose();
    _platformController.dispose();
    _paymentMethodController.dispose();
    _priceController.dispose();
    _cancelController.dispose();
    _notesController.dispose();
    _expirationReminderDaysController.dispose();
    _renewalReminderDaysController.dispose();
    super.dispose();
  }

  /// 保存会员。
  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    setState(() => _saving = true);
    try {
      // 当前分类名称对应的 taxonomy 标识。
      final List<TaxonomyEntry> categoryEntries =
          ref
              .read(
                taxonomyEntriesProvider((
                  TaxonomyModule.membership,
                  TaxonomyKind.category,
                )),
              )
              .asData
              ?.value ??
          const <TaxonomyEntry>[];
      // 兼容旧文本分类，并为后续重命名建立 ID 关联。
      final Set<String> categoryIds = categoryEntries
          .where(
            (TaxonomyEntry entry) =>
                entry.name == _categoryController.text.trim(),
          )
          .map((TaxonomyEntry entry) => entry.id)
          .toSet();
      await ref
          .read(membershipRepositoryProvider)
          .save(
            MembershipDraft(
              id: widget.membership?.id,
              name: _nameController.text,
              provider: _providerController.text,
              category: _categoryController.text,
              description: _descriptionController.text,
              websiteUrl: _websiteController.text,
              purchasePlatform: _platformController.text,
              paymentMethod: _paymentMethodController.text,
              priceCents: (double.parse(_priceController.text) * 100).round(),
              billingCycle: _billingCycle,
              baseStatus: _baseStatus,
              purchaseDate: _purchaseDate,
              expirationDate: _isPermanent ? null : _expirationDate,
              isPermanent: _isPermanent,
              autoRenew: !_isPermanent && _autoRenew,
              renewalDate: !_isPermanent && _autoRenew ? _renewalDate : null,
              isFavorite: _isFavorite,
              needsRenewal: _needsRenewal,
              expirationReminderEnabled:
                  !_isPermanent && _expirationReminderEnabled,
              expirationReminderDays: int.parse(
                _expirationReminderDaysController.text,
              ),
              renewalReminderEnabled:
                  !_isPermanent && _autoRenew && _renewalReminderEnabled,
              renewalReminderDays: int.parse(
                _renewalReminderDaysController.text,
              ),
              reminderTimeMinutes: _reminderTimeMinutes,
              categoryIds: categoryIds,
              tagIds: _selectedTagIds,
              cancelGuide: _cancelController.text,
              notes: _notesController.text,
            ),
          );
      if (mounted) {
        Navigator.of(context).pop();
      }
    } on FormatException catch (error) {
      if (mounted) {
        showOmniMessage(
          context,
          message: error.message,
          tone: OmniMessageTone.error,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  /// 构建会员编辑表单。
  @override
  Widget build(BuildContext context) {
    // 当前会员分类。
    final List<TaxonomyEntry> categories =
        ref
            .watch(
              taxonomyEntriesProvider((
                TaxonomyModule.membership,
                TaxonomyKind.category,
              )),
            )
            .asData
            ?.value
            .toList(growable: false) ??
        const <TaxonomyEntry>[];
    // 当前分类文本。
    final String currentCategory = _categoryController.text;
    // 可选分类名称。
    final List<String> categoryNames = <String>{
      if (currentCategory.isNotEmpty) currentCategory,
      ...categories.map((TaxonomyEntry entry) => entry.name),
    }.toList(growable: false);
    return OmniSideSheetScaffold(
      title: widget.membership == null ? '添加会员' : '编辑会员',
      canClose: !_saving,
      actions: <Widget>[
        OmniButton(
          label: '取消',
          variant: OmniButtonVariant.secondary,
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
        ),
        OmniButton(
          label: '保存',
          onPressed: _saving ? null : _save,
          loading: _saving,
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.all(OmniSpacing.lg),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextFormField(
                  controller: _nameController,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: '会员名称 *'),
                  validator: (String? value) =>
                      value == null || value.trim().isEmpty ? '请输入会员名称' : null,
                ),
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: OmniDropdownButtonFormField<String>(
                        initialValue: currentCategory.isEmpty
                            ? null
                            : currentCategory,
                        decoration: const InputDecoration(labelText: '分类'),
                        items: categoryNames
                            .map(
                              (String value) => DropdownMenuItem<String>(
                                value: value,
                                child: Text(value),
                              ),
                            )
                            .toList(growable: false),
                        onChanged: (String? value) {
                          _categoryController.text = value ?? '';
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OmniDropdownButtonFormField<BillingCycle>(
                        initialValue: _billingCycle,
                        decoration: const InputDecoration(labelText: '计费周期'),
                        items: BillingCycle.values
                            .where(
                              (BillingCycle value) =>
                                  value != BillingCycle.permanent,
                            )
                            .map(
                              (BillingCycle value) =>
                                  DropdownMenuItem<BillingCycle>(
                                    value: value,
                                    child: Text(_billingCycleLabel(value)),
                                  ),
                            )
                            .toList(growable: false),
                        onChanged: _isPermanent
                            ? null
                            : (BillingCycle? value) {
                                if (value != null) {
                                  setState(() {
                                    _billingCycle = value;
                                    if (value != BillingCycle.custom) {
                                      _expirationDate = _purchaseDate.add(
                                        Duration(
                                          days: _billingCycleDays(value),
                                        ),
                                      );
                                    }
                                  });
                                }
                              },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _descriptionController,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: '描述'),
                ),
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        controller: _platformController,
                        decoration: const InputDecoration(labelText: '购买平台'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _websiteController,
                        decoration: const InputDecoration(
                          labelText: '官方网站',
                          hintText: 'https://',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _priceController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(labelText: '本次价格（元）*'),
                  validator: (String? value) {
                    // 解析后的金额。
                    final double? parsed = double.tryParse(value ?? '');
                    return parsed == null || parsed < 0 ? '请输入有效金额' : null;
                  },
                ),
                const SizedBox(height: 10),
                OmniSwitchListTile(
                  value: _isPermanent,
                  title: const Text('永久会员 / 一次买断'),
                  onChanged: (bool value) =>
                      setState(() => _isPermanent = value),
                ),
                if (!_isPermanent)
                  OmniSwitchListTile(
                    value: _autoRenew,
                    title: const Text('自动续费'),
                    onChanged: (bool value) =>
                        setState(() => _autoRenew = value),
                  ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: <Widget>[
                    OmniDatePickerButton(
                      value: _purchaseDate,
                      initialDate: _purchaseDate,
                      firstDate: DateTime(1970),
                      lastDate: DateTime(2100),
                      label:
                          '购买 ${DateFormat('yyyy-MM-dd').format(_purchaseDate)}',
                      icon: Icons.shopping_bag_outlined,
                      onChanged: (DateTime selected) {
                        setState(() {
                          _purchaseDate = selected;
                          if (!_isPermanent &&
                              _billingCycle != BillingCycle.custom) {
                            _expirationDate = selected.add(
                              Duration(days: _billingCycleDays(_billingCycle)),
                            );
                          }
                        });
                      },
                    ),
                    if (!_isPermanent && _billingCycle == BillingCycle.custom)
                      OmniDatePickerButton(
                        value: _expirationDate,
                        initialDate: _expirationDate ?? DateTime.now(),
                        firstDate: DateTime(1970),
                        lastDate: DateTime(2100),
                        label: _expirationDate == null
                            ? '选择到期日期'
                            : '到期 ${DateFormat('yyyy-MM-dd').format(_expirationDate!)}',
                        icon: Icons.event_busy_outlined,
                        onChanged: (DateTime selected) {
                          setState(() => _expirationDate = selected);
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                if (!_isPermanent) ...<Widget>[
                  OmniSwitchListTile(
                    value: _expirationReminderEnabled,
                    title: const Text('到期提醒'),
                    onChanged: (bool value) =>
                        setState(() => _expirationReminderEnabled = value),
                  ),
                  if (_expirationReminderEnabled) ...<Widget>[
                    const SizedBox(height: OmniSpacing.sm),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: TextFormField(
                            controller: _expirationReminderDaysController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: '提前天数',
                            ),
                            validator: _positiveIntegerValidator,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OmniDropdownButtonFormField<int>(
                            initialValue: _reminderTimeMinutes,
                            decoration: const InputDecoration(
                              labelText: '提醒时刻',
                            ),
                            items:
                                List<int>.generate(
                                      48,
                                      (int index) => index * 30,
                                    )
                                    .map(
                                      (int minute) => DropdownMenuItem<int>(
                                        value: minute,
                                        child: Text(_minuteLabel(minute)),
                                      ),
                                    )
                                    .toList(growable: false),
                            onChanged: (int? value) {
                              if (value != null) {
                                setState(() => _reminderTimeMinutes = value);
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 14),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 校验正整数表单值。
  String? _positiveIntegerValidator(String? value) {
    // 解析后的正整数。
    final int? parsed = int.tryParse(value ?? '');
    return parsed == null || parsed <= 0 ? '请输入正整数' : null;
  }

  /// 返回计费周期文案。
  String _billingCycleLabel(BillingCycle cycle) {
    return switch (cycle) {
      BillingCycle.week => '周',
      BillingCycle.month => '月',
      BillingCycle.quarter => '季',
      BillingCycle.halfYear => '半年',
      BillingCycle.year => '年',
      BillingCycle.twoYears => '2 年',
      BillingCycle.threeYears => '3 年',
      BillingCycle.permanent => '永久',
      BillingCycle.custom => '自定义',
    };
  }

  /// 返回计费周期对应的天数；自定义与永久返回 0。
  int _billingCycleDays(BillingCycle cycle) {
    return switch (cycle) {
      BillingCycle.week => 7,
      BillingCycle.month => 30,
      BillingCycle.quarter => 90,
      BillingCycle.halfYear => 180,
      BillingCycle.year => 365,
      BillingCycle.twoYears => 730,
      BillingCycle.threeYears => 1095,
      BillingCycle.permanent => 0,
      BillingCycle.custom => 0,
    };
  }

  /// 将午夜分钟数格式化为时间。
  String _minuteLabel(int minute) {
    return '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';
  }
}

/// 支付历史弹窗。
class _PaymentHistoryDialog extends ConsumerWidget {
  /// 当前会员。
  final MembershipRecord membership;

  /// 创建支付历史弹窗。
  const _PaymentHistoryDialog({required this.membership});

  /// 打开新增支付记录弹窗。
  Future<void> _recordPayment(BuildContext context, WidgetRef ref) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) =>
          _PaymentEditorDialog(membership: membership),
    );
  }

  /// 构建支付历史弹窗。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 支付记录流。
    final AsyncValue<List<MembershipPaymentRecord>> payments = ref.watch(
      membershipPaymentsProvider(membership.id),
    );
    return OmniDialogScaffold(
      title: '${membership.name} · 支付记录',
      width: 500,
      height: 480,
      actions: <Widget>[
        OmniButton(
          label: '新增支付',
          variant: OmniButtonVariant.secondary,
          onPressed: () => _recordPayment(context, ref),
        ),
        OmniButton(label: '完成', onPressed: () => Navigator.of(context).pop()),
      ],
      child: SizedBox(
        height: 360,
        child: payments.when(
          data: (List<MembershipPaymentRecord> records) {
            if (records.isEmpty) {
              return const Center(child: Text('还没有支付记录'));
            }
            return ListView.separated(
              itemCount: records.length,
              separatorBuilder: (_, _) => const Divider(),
              itemBuilder: (BuildContext context, int index) {
                // 当前支付记录。
                final MembershipPaymentRecord payment = records[index];
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.receipt_long_outlined),
                  title: Text(
                    '¥ ${(payment.amountCents / 100).toStringAsFixed(2)}',
                  ),
                  subtitle: Text(
                    DateFormat('yyyy-MM-dd')
                        .format(payment.validFrom ?? payment.paidAt),
                  ),
                  trailing: payment.notes == null ? null : Text(payment.notes!),
                );
              },
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (Object error, StackTrace stackTrace) =>
              Center(child: Text('支付记录读取失败：$error')),
        ),
      ),
    );
  }
}

/// 新增支付记录弹窗。
class _PaymentEditorDialog extends ConsumerStatefulWidget {
  /// 所属会员。
  final MembershipRecord membership;

  /// 创建新增支付记录弹窗。
  const _PaymentEditorDialog({required this.membership});

  /// 创建弹窗状态。
  @override
  ConsumerState<_PaymentEditorDialog> createState() =>
      _PaymentEditorDialogState();
}

/// 新增支付记录弹窗状态。
class _PaymentEditorDialogState extends ConsumerState<_PaymentEditorDialog> {
  /// 金额控制器。
  late final TextEditingController _amountController;

  /// 备注控制器。
  final TextEditingController _notesController = TextEditingController();

  /// 支付日期。
  DateTime _startDate = DateUtils.dateOnly(DateTime.now());

  /// 本次计费周期。
  late BillingCycle _billingCycle;

  /// 本次有效期开始日。
  /// 本次有效期结束日。
  DateTime? _validUntil;

  /// 是否正在保存。
  bool _saving = false;

  /// 初始化支付表单。
  @override
  void initState() {
    super.initState();
    _amountController = TextEditingController(
      text: (widget.membership.priceCents / 100).toStringAsFixed(2),
    );
    _billingCycle = BillingCycle.values.firstWhere(
      (BillingCycle value) => value.name == widget.membership.billingCycle,
      orElse: () => BillingCycle.year,
    );
    _validUntil = _billingCycle == BillingCycle.custom
        ? widget.membership.expirationDate
        : _calculateExpirationDate();
  }

  /// 释放文本控制器。
  @override
  void dispose() {
    _amountController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  /// 保存支付记录。
  Future<void> _save() async {
    // 解析后的金额。
    final double? amount = double.tryParse(_amountController.text);
    if (amount == null || amount < 0) {
      showOmniMessage(context, message: '请输入有效金额', tone: OmniMessageTone.error);
      return;
    }
    setState(() => _saving = true);
    await ref
        .read(membershipRepositoryProvider)
        .recordPayment(
          membershipId: widget.membership.id,
          amountCents: (amount * 100).round(),
          startDate: _startDate,
          billingCycle: _billingCycle,
          validUntil: _validUntil,
          notes: _notesController.text,
        );
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  /// 构建新增支付记录表单。
  @override
  Widget build(BuildContext context) {
    return OmniDialogScaffold(
      title: '新增支付记录',
      width: 420,
      actions: <Widget>[
        OmniButton(
          label: '取消',
          variant: OmniButtonVariant.secondary,
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
        ),
        OmniButton(
          label: '保存',
          onPressed: _saving ? null : _save,
          loading: _saving,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _amountController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(labelText: '金额（元）'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OmniDropdownButtonFormField<BillingCycle>(
                  initialValue: _billingCycle,
                  decoration: const InputDecoration(labelText: '计费周期'),
                  items: BillingCycle.values
                      .map(
                        (BillingCycle value) => DropdownMenuItem<BillingCycle>(
                          value: value,
                          child: Text(_billingCycleLabel(value)),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: (BillingCycle? value) {
                    if (value != null) {
                      setState(() {
                        _billingCycle = value;
                        _validUntil = _calculateExpirationDate();
                      });
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          OmniDatePickerButton(
            value: _startDate,
            initialDate: _startDate,
            firstDate: DateTime(1970),
            lastDate: DateTime(2100),
            label: '开始 ${DateFormat('yyyy-MM-dd').format(_startDate)}',
            onChanged: (DateTime selected) {
              setState(() {
                _startDate = selected;
                _validUntil = _calculateExpirationDate();
              });
            },
          ),
          if (_billingCycle == BillingCycle.custom) ...<Widget>[
            const SizedBox(height: 14),
            OmniDatePickerButton(
              value: _validUntil,
              initialDate: _validUntil ?? _startDate,
              firstDate: DateTime(1970),
              lastDate: DateTime(2100),
              label: _validUntil == null
                  ? '选择结束时间'
                  : '结束 ${DateFormat('yyyy-MM-dd').format(_validUntil!)}',
              onChanged: (DateTime selected) {
                setState(() => _validUntil = selected);
              },
            ),
          ],
          const SizedBox(height: 14),
          TextField(
            controller: _notesController,
            decoration: const InputDecoration(labelText: '备注'),
          ),
        ],
      ),
    );
  }

  /// 返回支付计费周期文案。
  String _billingCycleLabel(BillingCycle cycle) {
    return switch (cycle) {
      BillingCycle.week => '周',
      BillingCycle.month => '月',
      BillingCycle.quarter => '季',
      BillingCycle.halfYear => '半年',
      BillingCycle.year => '年',
      BillingCycle.twoYears => '2 年',
      BillingCycle.threeYears => '3 年',
      BillingCycle.permanent => '永久',
      BillingCycle.custom => '自定义',
    };
  }

  /// 按本次开始时间计算标准周期结束时间。
  DateTime? _calculateExpirationDate() {
    if (_billingCycle == BillingCycle.custom) {
      return _validUntil;
    }
    final int months = switch (_billingCycle) {
      BillingCycle.month => 1,
      BillingCycle.quarter => 3,
      BillingCycle.halfYear => 6,
      BillingCycle.year => 12,
      BillingCycle.twoYears => 24,
      BillingCycle.threeYears => 36,
      BillingCycle.week || BillingCycle.permanent || BillingCycle.custom => 0,
    };
    if (_billingCycle == BillingCycle.week) {
      return _startDate.add(const Duration(days: 7));
    }
    if (months == 0) {
      return null;
    }
    final DateTime targetMonth = DateTime(
      _startDate.year,
      _startDate.month + months,
      1,
    );
    final int lastDay = DateTime(
      targetMonth.year,
      targetMonth.month + 1,
      0,
    ).day;
    return DateTime(
      targetMonth.year,
      targetMonth.month,
      _startDate.day > lastDay ? lastDay : _startDate.day,
    );
  }
}
