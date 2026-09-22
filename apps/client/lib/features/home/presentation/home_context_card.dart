import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/events/data/event_repository.dart';
import 'package:omni_butler/features/memberships/data/membership_repository.dart';
import 'package:omni_butler/features/settings/data/feature_preferences.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 首页临近事件与会员到期提醒卡片。
class HomeTodayContextCard extends ConsumerWidget {
  /// 当前时间。
  final DateTime now;

  /// 创建今日脉络卡片。
  const HomeTodayContextCard({required this.now, super.key});

  /// 按功能开关构建真实业务摘要行。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前业务功能偏好。
    final FeaturePreference featurePreference = ref.watch(
      featurePreferenceProvider,
    );
    // 当前启用功能对应的摘要行。
    final List<Widget> rows = <Widget>[
      if (featurePreference.isEnabled(AppFeature.events))
        KeyedSubtree(
          key: const ValueKey<String>('home-context-events'),
          child: _EventContextRow(now: now),
        ),
      if (featurePreference.isEnabled(AppFeature.memberships))
        KeyedSubtree(
          key: const ValueKey<String>('home-context-memberships'),
          child: _MembershipContextRow(now: now),
        ),
    ];
    // 插入分隔线后的摘要内容。
    final List<Widget> separatedRows = <Widget>[];
    for (int index = 0; index < rows.length; index += 1) {
      if (index > 0) {
        separatedRows.add(Divider(color: colors.line));
      }
      separatedRows.add(rows[index]);
    }

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
                child: Icon(
                  Icons.hub_outlined,
                  color: colors.brand,
                  size: OmniSize.navigationIcon,
                ),
              ),
              const SizedBox(width: OmniSpacing.xs),
              Expanded(
                child: Text(
                  '今日脉络',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: OmniSpacing.xs),
          Text(
            '集中查看临近事件与会员到期提醒。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: OmniSpacing.md),
          ...separatedRows,
        ],
      ),
    );
  }
}

/// 首页今日脉络中的可展开周期事件分区。
class _EventContextRow extends ConsumerStatefulWidget {
  /// 当前时间。
  final DateTime now;

  /// 创建周期事件提醒分区。
  const _EventContextRow({required this.now});

  /// 创建周期事件提醒分区状态。
  @override
  ConsumerState<_EventContextRow> createState() => _EventContextRowState();
}

/// 周期事件提醒分区状态。
class _EventContextRowState extends ConsumerState<_EventContextRow> {
  /// 当前是否展开临近事件列表。
  bool _expanded = true;

  /// 构建超期、即将到期和可展开的事件清单。
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
        // 已经超期的事件。
        final List<EventRecord> overdue = events
            .where(
              (EventRecord event) =>
                  repository.statusFor(event, widget.now) ==
                  EventDueStatus.overdue,
            )
            .toList();
        // 已经进入提醒窗口的事件。
        final List<EventRecord> upcoming = events
            .where(
              (EventRecord event) =>
                  repository.statusFor(event, widget.now) ==
                  EventDueStatus.upcoming,
            )
            .toList();
        // 按应做时间排序后的全部关注事件。
        final List<EventRecord> attention =
            <EventRecord>[...overdue, ...upcoming]
              ..sort((EventRecord left, EventRecord right) {
                return repository
                    .nextDueAt(left)!
                    .compareTo(repository.nextDueAt(right)!);
              });
        // 主摘要文字。
        final String detail = attention.isEmpty
            ? '${events.length} 项周期事件，暂无临近事项'
            : '${overdue.length} 项超期 · ${upcoming.length} 项即将到期';
        // 可展开的事件明细行。
        final List<Widget> detailRows = attention
            .map((EventRecord event) {
              // 当前事件状态。
              final EventDueStatus status = repository.statusFor(
                event,
                widget.now,
              );
              // 当前事件下一次应做时间。
              final DateTime dueAt = repository.nextDueAt(event)!;
              return _ContextAttentionRow(
                key: ValueKey<String>('home-context-event-item-${event.id}'),
                color: colors.event,
                title: event.name,
                detail: '${_eventStatusLabel(status)} · ${_formatDate(dueAt)}',
                onTap: () => context.go('/events'),
              );
            })
            .toList(growable: false);
        return _ExpandableContextSection(
          icon: Icons.event_repeat_rounded,
          color: colors.event,
          title: '周期事件',
          detail: detail,
          expanded: _expanded,
          detailRows: detailRows,
          onToggle: () => setState(() => _expanded = !_expanded),
        );
      },
    );
  }
}

/// 首页今日脉络中的可展开会员到期分区。
class _MembershipContextRow extends ConsumerStatefulWidget {
  /// 当前时间。
  final DateTime now;

  /// 创建会员到期提醒分区。
  const _MembershipContextRow({required this.now});

  /// 创建会员到期提醒分区状态。
  @override
  ConsumerState<_MembershipContextRow> createState() =>
      _MembershipContextRowState();
}

/// 会员到期提醒分区状态。
class _MembershipContextRowState extends ConsumerState<_MembershipContextRow> {
  /// 当前是否展开会员到期列表。
  bool _expanded = true;

  /// 构建续费、到期数量和可展开的会员清单。
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
        icon: Icons.loyalty_rounded,
        color: colors.member,
        title: '会员提醒',
      ),
      error: (Object error, StackTrace stackTrace) => _ErrorContextRow(
        icon: Icons.loyalty_rounded,
        color: colors.member,
        title: '会员提醒',
        onTap: () => context.go('/memberships'),
      ),
      data: (List<MembershipRecord> memberships) {
        // 当前需要续费或到期关注的会员。
        final List<MembershipRecord> attention = memberships.where((
          MembershipRecord membership,
        ) {
          // 当前会员状态。
          final MembershipStatus status = repository.statusFor(
            membership,
            widget.now,
          );
          return status == MembershipStatus.expired ||
              status == MembershipStatus.upcoming ||
              status == MembershipStatus.renewalDue;
        }).toList();
        attention.sort((MembershipRecord left, MembershipRecord right) {
          // 左侧会员的关注日期。
          final DateTime? leftDate = _membershipAttentionDate(left);
          // 右侧会员的关注日期。
          final DateTime? rightDate = _membershipAttentionDate(right);
          if (leftDate == null && rightDate == null) {
            return left.createdAt.compareTo(right.createdAt);
          }
          if (leftDate == null) {
            return 1;
          }
          if (rightDate == null) {
            return -1;
          }
          return leftDate.compareTo(rightDate);
        });
        // 主摘要文字。
        final String detail = attention.isEmpty
            ? '${memberships.length} 项会员，暂无近期续费'
            : '${attention.length} 项续费或到期需关注';
        // 可展开的会员提醒明细行。
        final List<Widget> detailRows = attention
            .map((MembershipRecord membership) {
              // 当前会员状态。
              final MembershipStatus status = repository.statusFor(
                membership,
                widget.now,
              );
              // 当前会员关注日期。
              final DateTime? attentionDate = _membershipAttentionDate(
                membership,
              );
              // 当前会员状态与日期说明。
              final String itemDetail = attentionDate == null
                  ? _membershipStatusLabel(status)
                  : '${_membershipStatusLabel(status)} · ${_formatDate(attentionDate)}';
              return _ContextAttentionRow(
                key: ValueKey<String>(
                  'home-context-membership-item-${membership.id}',
                ),
                color: colors.member,
                title: membership.name,
                detail: itemDetail,
                onTap: () => context.go('/memberships'),
              );
            })
            .toList(growable: false);
        return _ExpandableContextSection(
          icon: Icons.loyalty_rounded,
          color: colors.member,
          title: '会员提醒',
          detail: detail,
          expanded: _expanded,
          detailRows: detailRows,
          onToggle: () => setState(() => _expanded = !_expanded),
        );
      },
    );
  }
}

/// 今日脉络中的可展开提醒分区。
class _ExpandableContextSection extends StatelessWidget {
  /// 父项展开控制尺寸。
  static const double _treeControlSize = 28;

  /// 父项模块图标尺寸。
  static const double _parentIconSize = 34;

  /// 子项相对卡片左侧的缩进。
  static const double _childIndent = 68;

  /// 模块图标。
  final IconData icon;

  /// 模块颜色。
  final Color color;

  /// 模块标题。
  final String title;

  /// 主摘要文字。
  final String detail;

  /// 当前是否展开。
  final bool expanded;

  /// 展开后显示的提醒明细。
  final List<Widget> detailRows;

  /// 展开或收起回调。
  final VoidCallback onToggle;

  /// 创建可展开提醒分区。
  const _ExpandableContextSection({
    required this.icon,
    required this.color,
    required this.title,
    required this.detail,
    required this.expanded,
    required this.detailRows,
    required this.onToggle,
  });

  /// 构建父项、树形支线与提醒子项。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前是否减少展开动画。
    final bool reduceMotion =
        MediaQuery.of(context).disableAnimations ||
        MediaQuery.of(context).accessibleNavigation;
    // 展开和收起使用的动画时长。
    final Duration duration = reduceMotion ? Duration.zero : OmniMotion.normal;
    // 当前是否存在可展开明细。
    final bool expandable = detailRows.isNotEmpty;
    // 父项模块图标中心对应的树形主干横坐标。
    const double treeTrunkX =
        _treeControlSize + OmniSpacing.xxs + _parentIconSize / 2;
    // 子项状态点中心对应的支线终点横坐标。
    const double branchEndX = _childIndent + 3.5;
    // 父项左侧的展开控制与模块图标。
    final Widget parentLeading = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox.square(
          dimension: _treeControlSize,
          child: IconButton(
            tooltip: expandable
                ? expanded
                      ? '收起提醒'
                      : '展开提醒'
                : null,
            onPressed: expandable ? onToggle : null,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(
              width: _treeControlSize,
              height: _treeControlSize,
            ),
            icon: Icon(
              expandable && expanded
                  ? Icons.expand_more_rounded
                  : Icons.chevron_right_rounded,
              color: colors.muted,
              size: 18,
            ),
          ),
        ),
        const SizedBox(width: OmniSpacing.xxs),
        Container(
          width: _parentIconSize,
          height: _parentIconSize,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(OmniRadius.control),
          ),
          child: Icon(icon, color: color, size: OmniSize.navigationIcon),
        ),
      ],
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        OmniListRow(
          onTap: expandable ? onToggle : null,
          borderRadius: BorderRadius.circular(OmniRadius.control),
          padding: const EdgeInsets.symmetric(vertical: OmniSpacing.sm),
          leadingGap: OmniSpacing.xs,
          leading: parentLeading,
          title: Row(
            children: <Widget>[
              Text(title),
              if (expandable) ...<Widget>[
                const SizedBox(width: OmniSpacing.xs),
                OmniTag(
                  key: ValueKey<String>('home-context-count-$title'),
                  label: '${detailRows.length}',
                  color: color,
                ),
              ],
            ],
          ),
          subtitle: Text(detail),
        ),
        AnimatedSize(
          alignment: Alignment.topCenter,
          duration: duration,
          curve: OmniMotion.standardCurve,
          child: expanded && expandable
              ? Column(
                  key: const ValueKey<String>('context-details-expanded'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (int index = 0; index < detailRows.length; index += 1)
                      CustomPaint(
                        key: ValueKey<String>(
                          'context-tree-branch-$title-$index',
                        ),
                        painter: _ContextTreeBranchPainter(
                          lineColor: color.withValues(alpha: 0.32),
                          trunkX: treeTrunkX,
                          branchEndX: branchEndX,
                          isLast: index == detailRows.length - 1,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.only(left: _childIndent),
                          child: detailRows[index],
                        ),
                      ),
                  ],
                )
              : const SizedBox.shrink(
                  key: ValueKey<String>('context-details-collapsed'),
                ),
        ),
      ],
    );
  }
}

/// 绘制今日脉络父项与提醒子项之间的树形支线。
class _ContextTreeBranchPainter extends CustomPainter {
  /// 树线颜色。
  final Color lineColor;

  /// 父项图标中心对应的主干横坐标。
  final double trunkX;

  /// 子项状态点中心对应的支线终点横坐标。
  final double branchEndX;

  /// 当前子项是否为最后一项。
  final bool isLast;

  /// 创建今日脉络树形支线绘制器。
  const _ContextTreeBranchPainter({
    required this.lineColor,
    required this.trunkX,
    required this.branchEndX,
    required this.isLast,
  });

  /// 绘制连续主干以及最后一项的圆角弯折。
  @override
  void paint(Canvas canvas, Size size) {
    // 当前子项行的垂直中心。
    final double branchY = size.height / 2;
    // 树形连接线画笔。
    final Paint linePaint = Paint()
      ..color = lineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.25
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (!isLast) {
      canvas
        ..drawLine(Offset(trunkX, 0), Offset(trunkX, size.height), linePaint)
        ..drawLine(
          Offset(trunkX, branchY),
          Offset(branchEndX, branchY),
          linePaint,
        );
      return;
    }
    // 最后一条支线使用的圆角半径。
    final double cornerRadius = branchY < OmniSpacing.xs
        ? branchY
        : OmniSpacing.xs;
    // 从主干自然弯向最后一个子项的路径。
    final Path branchPath = Path()
      ..moveTo(trunkX, 0)
      ..lineTo(trunkX, branchY - cornerRadius)
      ..quadraticBezierTo(trunkX, branchY, trunkX + cornerRadius, branchY)
      ..lineTo(branchEndX, branchY);
    canvas.drawPath(branchPath, linePaint);
  }

  /// 仅在树线几何或颜色变化时重新绘制。
  @override
  bool shouldRepaint(covariant _ContextTreeBranchPainter oldDelegate) {
    return lineColor != oldDelegate.lineColor ||
        trunkX != oldDelegate.trunkX ||
        branchEndX != oldDelegate.branchEndX ||
        isLast != oldDelegate.isLast;
  }
}

/// 今日脉络展开区中的单条提醒。
class _ContextAttentionRow extends StatelessWidget {
  /// 模块颜色。
  final Color color;

  /// 提醒标题。
  final String title;

  /// 状态与日期说明。
  final String detail;

  /// 打开对应功能回调。
  final VoidCallback onTap;

  /// 创建单条提醒明细。
  const _ContextAttentionRow({
    required this.color,
    required this.title,
    required this.detail,
    required this.onTap,
    super.key,
  });

  /// 构建带状态色点、名称和日期的提醒行。
  @override
  Widget build(BuildContext context) {
    return OmniListRow(
      onTap: onTap,
      borderRadius: BorderRadius.circular(OmniRadius.control),
      padding: const EdgeInsets.symmetric(vertical: OmniSpacing.xs),
      leadingGap: OmniSpacing.xs,
      leading: Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(detail),
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

/// 返回会员最值得关注的日期。
DateTime? _membershipAttentionDate(MembershipRecord membership) {
  if (membership.autoRenew && membership.renewalDate != null) {
    return membership.renewalDate;
  }
  return membership.expirationDate;
}

/// 返回周期事件关注状态文案。
String _eventStatusLabel(EventDueStatus status) {
  return switch (status) {
    EventDueStatus.overdue => '已超期',
    EventDueStatus.upcoming => '即将到期',
    EventDueStatus.unrecorded => '尚未记录',
    EventDueStatus.normal => '状态正常',
  };
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

/// 格式化首页摘要日期。
String _formatDate(DateTime date) => DateFormat('M月d日').format(date);
