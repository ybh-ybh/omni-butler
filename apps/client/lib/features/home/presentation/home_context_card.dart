import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/events/data/event_repository.dart';
import 'package:omni_butler/features/home/data/home_event_attention.dart';
import 'package:omni_butler/features/memberships/data/membership_repository.dart';
import 'package:omni_butler/features/memberships/presentation/memberships_page.dart';
import 'package:omni_butler/features/settings/data/feature_preferences.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 首页临近事件与会员到期提醒卡片。
class HomeTodayContextCard extends ConsumerWidget {
  /// 当前时间。
  final DateTime now;

  /// 创建今日脉络卡片。
  const HomeTodayContextCard({required this.now, super.key});

  /// 按功能开关构建日期清单。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前业务功能偏好。
    final FeaturePreference preference = ref.watch(featurePreferenceProvider);
    // 当前是否启用周期事件。
    final bool showEvents = preference.isEnabled(AppFeature.events);
    // 当前是否启用会员提醒。
    final bool showMemberships = preference.isEnabled(AppFeature.memberships);
    return OmniPanel(
      key: const ValueKey<String>('home-context-card'),
      padding: const EdgeInsets.all(OmniSpacing.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: colors.brandSoft,
                  borderRadius: BorderRadius.circular(OmniRadius.control),
                ),
                child: Icon(Icons.hub_outlined, color: colors.brand, size: 20),
              ),
              const SizedBox(width: OmniSpacing.xs),
              Expanded(
                child: Text(
                  '今日脉络',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Text(
                DateFormat('MM.dd').format(now),
                style: Theme.of(context).textTheme.labelMedium
                    ?.copyWith(color: colors.muted),
              ),
            ],
          ),
          const SizedBox(height: OmniSpacing.lg),
          if (showEvents)
            _EventContextRow(
              key: const ValueKey<String>('home-context-events'),
              now: now,
            ),
          if (showEvents && showMemberships)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: OmniSpacing.sm),
              child: Divider(height: 1, color: colors.line),
            ),
          if (showMemberships)
            _MembershipContextRow(
              key: const ValueKey<String>('home-context-memberships'),
              now: now,
            ),
        ],
      ),
    );
  }
}

/// 首页今日脉络中的周期事件分区。
class _EventContextRow extends ConsumerStatefulWidget {
  /// 当前时间。
  final DateTime now;

  /// 创建周期事件提醒分区。
  const _EventContextRow({required this.now, super.key});

  /// 创建周期事件提醒分区状态。
  @override
  ConsumerState<_EventContextRow> createState() => _EventContextRowState();
}

/// 周期事件提醒分区状态。
class _EventContextRowState extends ConsumerState<_EventContextRow> {
  /// 当前是否展开临近事件列表。
  bool _expanded = true;

  /// 正在记录的事件，防止重复点击写入多条完成历史。
  final Set<String> _recordingIds = <String>{};

  /// 当前记录成功后的撤销消息。
  OmniMessageHandle? _undoMessage;

  /// 直接记录现在完成，保持首页并提供与事件页一致的撤销入口。
  Future<void> _recordNow(EventRecord event) async {
    if (_recordingIds.contains(event.id)) {
      return;
    }
    // 在异步操作前捕获仓储，离开首页也不会中断已经提交的写入。
    final EventRepository repository = ref.read(eventRepositoryProvider);
    setState(() => _recordingIds.add(event.id));
    try {
      // 仅撤销本次完成历史的凭据。
      final EventCompletionUndo undo = await repository.recordNow(event);
      if (!mounted) {
        return;
      }
      _undoMessage?.dismiss();
      _undoMessage = showOmniMessage(
        context,
        message: '已记录“${event.name}”为现在完成',
        tone: OmniMessageTone.success,
        duration: const Duration(seconds: 6),
        actionLabel: '撤销',
        onAction: () => unawaited(_undoRecord(repository, undo)),
        onDismissed: () => _undoMessage = null,
      );
    } catch (_) {
      if (mounted) {
        showOmniMessage(
          context,
          message: '记录失败，请重试',
          tone: OmniMessageTone.error,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _recordingIds.remove(event.id));
      }
    }
  }

  /// 撤销本次完成记录，首页清单随仓储订阅自动恢复。
  Future<void> _undoRecord(
    EventRepository repository,
    EventCompletionUndo undo,
  ) async {
    try {
      await repository.undoRecord(undo);
    } catch (_) {
      if (mounted) {
        _undoMessage = showOmniMessage(
          context,
          message: '撤销失败，请重试',
          tone: OmniMessageTone.error,
          actionLabel: '重试',
          onAction: () => unawaited(_undoRecord(repository, undo)),
          onDismissed: () => _undoMessage = null,
        );
      }
    }
  }

  /// 卸载分区时关闭属于首页的撤销浮层。
  @override
  void dispose() {
    _undoMessage?.dismiss();
    super.dispose();
  }

  /// 构建超期与未来七个自然日内的事件清单。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 有效周期事件异步状态。
    final AsyncValue<List<EventRecord>> eventsAsync = ref.watch(
      activeEventsProvider,
    );
    // 周期事件仓储。
    final EventRepository repository = ref.watch(eventRepositoryProvider);
    return eventsAsync.when(
      loading: () => _LoadingContextRow(
        icon: Icons.event_repeat_rounded,
        color: colors.event,
        title: '周期事件',
      ),
      error: (Object error, StackTrace stackTrace) => _ErrorContextRow(
        icon: Icons.event_repeat_rounded,
        color: colors.event,
        title: '周期事件',
        onTap: () => context.go('/events'),
      ),
      data: (List<EventRecord> events) {
        // 按应做时间排序的超期、近期与已进入自定义提醒窗口的事件。
        final List<EventRecord> attention = selectHomeAttentionEvents(
          events: events,
          repository: repository,
          now: widget.now,
        );
        // 缺少首次完成记录、无法计算下次日期的事件数量。
        final int unrecordedCount = events
            .where((EventRecord event) => repository.nextDueAt(event) == null)
            .length;
        // 没有临近事项时可展示的下一项已知安排。
        final EventRecord? nextEvent = events
            .where((EventRecord event) => repository.nextDueAt(event) != null)
            .firstOrNull;
        // 解释空态的文字，不将未记录误报为没有临近事项。
        final String emptyDetail = events.isEmpty
            ? '添加周期事件，按时照顾生活中的小事。'
            : unrecordedCount == events.length
            ? '先记录一次完成时间，即可计算下次日期。'
            : nextEvent == null
            ? '未来 7 天暂无临近事件。'
            : '下一项：${nextEvent.name} · ${_formatDate(repository.nextDueAt(nextEvent)!, widget.now)}';
        return _ExpandableContextSection(
          icon: Icons.event_repeat_rounded,
          color: colors.event,
          title: '周期事件',
          emptyTitle: events.isEmpty
              ? '还没有周期事件'
              : unrecordedCount == events.length
              ? '等待首次记录'
              : '近期暂无待处理事件',
          emptyDetail: emptyDetail,
          note: unrecordedCount > 0 && unrecordedCount < events.length
              ? '$unrecordedCount 项尚未记录完成时间，暂无法计算日期'
              : null,
          expanded: _expanded,
          onToggle: () => setState(() => _expanded = !_expanded),
          onOpen: () => context.go('/events'),
          detailRows: attention
              .map((EventRecord event) {
                // 当前事件下一次应做时间。
                final DateTime dueAt = repository.nextDueAt(event)!;
                // 当前事件是否已超过精确应做时间。
                final bool overdue =
                    repository.statusFor(event, widget.now) ==
                    EventDueStatus.overdue;
                return _ContextAttentionRow(
                  key: ValueKey<String>('home-context-event-item-${event.id}'),
                  date: dueAt,
                  now: widget.now,
                  color: overdue ? colors.danger : colors.event,
                  title: event.name,
                  detail: overdue ? '已超期' : '待完成',
                  badge: _relativeDate(dueAt, widget.now, overdue: overdue),
                  action: OmniButton(
                    key: ValueKey<String>('home-context-record-${event.id}'),
                    label: '记录',
                    variant: OmniButtonVariant.secondary,
                    loading: _recordingIds.contains(event.id),
                    onPressed: () => unawaited(_recordNow(event)),
                  ),
                );
              })
              .toList(growable: false),
        );
      },
    );
  }
}

/// 首页今日脉络中的会员到期分区。
class _MembershipContextRow extends ConsumerStatefulWidget {
  /// 当前时间。
  final DateTime now;

  /// 创建会员到期提醒分区。
  const _MembershipContextRow({required this.now, super.key});

  /// 创建会员到期提醒分区状态。
  @override
  ConsumerState<_MembershipContextRow> createState() =>
      _MembershipContextRowState();
}

/// 会员到期提醒分区状态。
class _MembershipContextRowState extends ConsumerState<_MembershipContextRow> {
  /// 当前是否展开会员到期列表。
  bool _expanded = true;

  /// 已打开续费表单的会员，避免重复叠加同一表单。
  final Set<String> _renewingIds = <String>{};

  /// 在首页上方打开既有续费表单，完成后保持当前路由。
  Future<void> _renew(MembershipRecord membership) async {
    if (_renewingIds.contains(membership.id)) {
      return;
    }
    setState(() => _renewingIds.add(membership.id));
    try {
      await showMembershipRenewalDialog(context, membership: membership);
    } finally {
      if (mounted) {
        setState(() => _renewingIds.remove(membership.id));
      }
    }
  }

  /// 构建会员到期清单，保留会员原有提醒规则。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 有效会员异步状态。
    final AsyncValue<List<MembershipRecord>> membershipsAsync = ref.watch(
      membershipsProvider,
    );
    // 会员仓储。
    final MembershipRepository repository = ref.watch(
      membershipRepositoryProvider,
    );
    return membershipsAsync.when(
      loading: () => _LoadingContextRow(
        icon: Icons.loyalty_outlined,
        color: colors.member,
        title: '会员提醒',
      ),
      error: (Object error, StackTrace stackTrace) => _ErrorContextRow(
        icon: Icons.loyalty_outlined,
        color: colors.member,
        title: '会员提醒',
        onTap: () => context.go('/memberships'),
      ),
      data: (List<MembershipRecord> memberships) {
        // 当前需要续费或到期关注的会员。
        final List<MembershipRecord> attention =
            memberships.where((MembershipRecord membership) {
              // 当前会员状态。
              final MembershipStatus status = repository.statusFor(
                membership,
                widget.now,
              );
              return status == MembershipStatus.expired ||
                  status == MembershipStatus.upcoming ||
                  status == MembershipStatus.renewalDue;
            }).toList()..sort((MembershipRecord left, MembershipRecord right) {
              // 排序日期与每一行实际展示的到期或续费日期保持一致。
              final DateTime leftDate =
                  _membershipAttentionDate(
                    left,
                    repository.statusFor(left, widget.now),
                  ) ??
                  left.createdAt;
              // 右侧会员实际需要关注的日期。
              final DateTime rightDate =
                  _membershipAttentionDate(
                    right,
                    repository.statusFor(right, widget.now),
                  ) ??
                  right.createdAt;
              return leftDate.compareTo(rightDate);
            });
        return _ExpandableContextSection(
          icon: Icons.loyalty_outlined,
          color: colors.member,
          title: '会员提醒',
          emptyTitle: memberships.isEmpty ? '还没有会员记录' : '暂无到期或续费提醒',
          emptyDetail: memberships.isEmpty
              ? '记录会员有效期，到期前在这里查看。'
              : '已记录的会员目前无需处理。',
          expanded: _expanded,
          onToggle: () => setState(() => _expanded = !_expanded),
          onOpen: () => context.go('/memberships'),
          detailRows: attention
              .map((MembershipRecord membership) {
                // 当前会员状态。
                final MembershipStatus status = repository.statusFor(
                  membership,
                  widget.now,
                );
                // 到期提示使用有效期日期，只有续费状态使用下次续费日期。
                final DateTime? date = _membershipAttentionDate(
                  membership,
                  status,
                );
                // 已过期会员使用危险状态色。
                final bool expired = status == MembershipStatus.expired;
                return _ContextAttentionRow(
                  key: ValueKey<String>(
                    'home-context-membership-item-${membership.id}',
                  ),
                  date: date,
                  now: widget.now,
                  color: expired ? colors.danger : colors.member,
                  title: membership.name,
                  detail: _membershipStatusLabel(status),
                  badge: date == null
                      ? '待续费'
                      : _relativeDate(date, widget.now, overdue: expired),
                  action: OmniButton(
                    key: ValueKey<String>(
                      'home-context-renew-${membership.id}',
                    ),
                    label: '续费',
                    variant: OmniButtonVariant.secondary,
                    onPressed: _renewingIds.contains(membership.id)
                        ? null
                        : () => unawaited(_renew(membership)),
                  ),
                );
              })
              .toList(growable: false),
        );
      },
    );
  }
}

/// 提供展开控制、独立模块入口和明确空态的提醒分区。
class _ExpandableContextSection extends StatelessWidget {
  /// 模块图标。
  final IconData icon;

  /// 模块颜色。
  final Color color;

  /// 模块标题。
  final String title;

  /// 空态标题。
  final String emptyTitle;

  /// 空态说明。
  final String emptyDetail;

  /// 可选的数据不完整提示。
  final String? note;

  /// 当前是否展开。
  final bool expanded;

  /// 展开后显示的提醒明细。
  final List<Widget> detailRows;

  /// 展开或收起回调。
  final VoidCallback onToggle;

  /// 打开完整模块回调。
  final VoidCallback onOpen;

  /// 创建提醒分区。
  const _ExpandableContextSection({
    required this.icon,
    required this.color,
    required this.title,
    required this.emptyTitle,
    required this.emptyDetail,
    required this.expanded,
    required this.detailRows,
    required this.onToggle,
    required this.onOpen,
    this.note,
  });

  /// 构建不使用深层缩进的日期清单。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前是否存在可展开明细。
    final bool expandable = detailRows.isNotEmpty;
    // 尊重系统减少动画偏好。
    final bool reduceMotion = OmniMotion.reduce(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Semantics(
                expanded: expandable ? expanded : null,
                child: OmniListRow(
                  onTap: expandable ? onToggle : null,
                  borderRadius: BorderRadius.circular(OmniRadius.control),
                  padding: const EdgeInsets.symmetric(
                    horizontal: OmniSpacing.sm,
                    vertical: OmniSpacing.xs,
                  ),
                  leadingGap: OmniSpacing.xs,
                  leading: Icon(icon, color: color, size: 20),
                  title: Wrap(
                    spacing: OmniSpacing.xs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: <Widget>[
                      Text(
                        title,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      if (expandable)
                        OmniTag(
                          key: ValueKey<String>('home-context-count-$title'),
                          label: '${detailRows.length}',
                          color: color,
                        ),
                    ],
                  ),
                  trailing: expandable
                      ? Icon(
                          expanded
                              ? Icons.expand_more_rounded
                              : Icons.chevron_right_rounded,
                          color: colors.muted,
                          size: 18,
                        )
                      : null,
                ),
              ),
            ),
            const SizedBox(width: OmniSpacing.xs),
            TextButton(
              key: ValueKey<String>('home-context-open-$title'),
              onPressed: onOpen,
              style: TextButton.styleFrom(
                foregroundColor: colors.muted,
                textStyle: Theme.of(context).textTheme.bodySmall,
                minimumSize: const Size(44, 44),
                padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.xs),
              ),
              child: const Text('全部'),
            ),
          ],
        ),
        const SizedBox(height: OmniSpacing.sm),
        if (!expandable)
          Container(
            padding: const EdgeInsets.all(OmniSpacing.md),
            decoration: BoxDecoration(
              color: colors.paperSubtle,
              borderRadius: BorderRadius.circular(OmniRadius.control),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(emptyTitle, style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: OmniSpacing.xxs),
                Text(
                  emptyDetail,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          )
        else
          AnimatedSize(
            alignment: Alignment.topCenter,
            duration: reduceMotion ? Duration.zero : OmniMotion.normal,
            curve: OmniMotion.standardCurve,
            child: expanded
                ? Column(
                    key: ValueKey<String>('context-details-expanded-$title'),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: detailRows,
                  )
                : const SizedBox.shrink(),
          ),
        if (note != null) ...<Widget>[
          const SizedBox(height: OmniSpacing.xs),
          Text(
            note!,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.warning),
          ),
        ],
      ],
    );
  }
}

/// 使用日历刻度、名称和相对日期呈现一条提醒。
class _ContextAttentionRow extends StatelessWidget {
  /// 关注日期，缺失时显示占位。
  final DateTime? date;

  /// 当前时间，用于跨年日期标注。
  final DateTime now;

  /// 状态颜色。
  final Color color;

  /// 提醒标题。
  final String title;

  /// 状态说明。
  final String detail;

  /// 剩余或超期时间。
  final String badge;

  /// 只在行尾触发的记录或续费操作。
  final Widget action;

  /// 创建单条提醒明细。
  const _ContextAttentionRow({
    required this.date,
    required this.now,
    required this.color,
    required this.title,
    required this.detail,
    required this.badge,
    required this.action,
    super.key,
  });

  /// 构建无整行点击行为的日期行，长名称最多展示两行。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OmniSpacing.xxs),
      child: OmniListRow(
        borderRadius: BorderRadius.circular(OmniRadius.control),
        padding: const EdgeInsets.symmetric(
          horizontal: OmniSpacing.xs,
          vertical: OmniSpacing.sm,
        ),
        leadingGap: OmniSpacing.sm,
        leading: Container(
          width: 48,
          padding: const EdgeInsets.only(right: OmniSpacing.sm),
          decoration: BoxDecoration(
            border: Border(right: BorderSide(color: colors.line)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                date == null ? '—' : '${date!.day}'.padLeft(2, '0'),
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w600, height: 1.1),
              ),
              const SizedBox(height: OmniSpacing.xxs),
              Text(
                date == null ? '待定' : '${date!.month}月',
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: colors.muted),
              ),
            ],
          ),
        ),
        title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: action,
        subtitle: Wrap(
          spacing: OmniSpacing.xs,
          runSpacing: OmniSpacing.xxs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            Text(
              badge,
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: color),
            ),
            Text(
              date != null && date!.year != now.year
                  ? '${date!.year}年 · $detail'
                  : detail,
            ),
          ],
        ),
      ),
    );
  }
}

/// 今日脉络异步加载行。
class _LoadingContextRow extends StatelessWidget {
  /// 模块图标。
  final IconData icon;

  /// 模块颜色。
  final Color color;

  /// 模块标题。
  final String title;

  /// 创建异步加载行。
  const _LoadingContextRow({
    required this.icon,
    required this.color,
    required this.title,
  });

  /// 构建加载状态。
  @override
  Widget build(BuildContext context) {
    return OmniListRow(
      leading: Icon(icon, color: color, size: OmniSize.navigationIcon),
      title: Text(title),
      subtitle: const Text('正在读取'),
      trailing: const SizedBox.square(
        dimension: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }
}

/// 今日脉络读取失败行。
class _ErrorContextRow extends StatelessWidget {
  /// 模块图标。
  final IconData icon;

  /// 模块颜色。
  final Color color;

  /// 模块标题。
  final String title;

  /// 打开模块回调。
  final VoidCallback onTap;

  /// 创建读取失败行。
  const _ErrorContextRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.onTap,
  });

  /// 构建可跳转处理的失败状态。
  @override
  Widget build(BuildContext context) {
    return OmniListRow(
      onTap: onTap,
      borderRadius: BorderRadius.circular(OmniRadius.control),
      leading: Icon(icon, color: color, size: OmniSize.navigationIcon),
      title: Text(title),
      subtitle: const Text('暂时无法读取，打开功能页查看'),
      trailing: const Icon(Icons.chevron_right_rounded, size: OmniSize.icon),
    );
  }
}

/// 按自然日计算距离，避免当天的事项显示为剩余零天。
String _relativeDate(DateTime date, DateTime now, {required bool overdue}) {
  // 目标日期的自然日序号。
  final DateTime targetDay = DateTime.utc(date.year, date.month, date.day);
  // 当前日期的自然日序号。
  final DateTime today = DateTime.utc(now.year, now.month, now.day);
  // 自然日差，不受夏令时切换影响。
  final int days = targetDay.difference(today).inDays;
  if (days < 0) {
    return '已过 ${-days} 天';
  }
  if (days == 0) {
    return overdue ? '今天已到期' : '今天';
  }
  return days == 1 ? '明天' : '$days 天后';
}

/// 返回与会员当前提示状态相匹配的日期。
DateTime? _membershipAttentionDate(
  MembershipRecord membership,
  MembershipStatus status,
) {
  return status == MembershipStatus.renewalDue
      ? membership.renewalDate ?? membership.expirationDate
      : membership.expirationDate;
}

/// 返回会员关注状态文案。
String _membershipStatusLabel(MembershipStatus status) {
  return switch (status) {
    MembershipStatus.expired => '已到期',
    MembershipStatus.upcoming => '即将到期',
    MembershipStatus.renewalDue => '需要续费',
    MembershipStatus.permanent => '永久有效',
    MembershipStatus.trial => '试用中',
    MembershipStatus.active => '使用中',
    MembershipStatus.cancelled => '已取消',
  };
}

/// 格式化摘要日期，跨年时保留年份。
String _formatDate(DateTime date, DateTime now) =>
    DateFormat(date.year == now.year ? 'M月d日' : 'yyyy年M月d日').format(date);
