part of 'android_notes_view.dart';

/// 历史编辑从右侧进入，新建仍使用原有底部覆盖层。
class _AndroidHistoryRoute extends PageRouteBuilder<void> {
  /// 路由只提供表面，业务会话由编辑器持有。
  _AndroidHistoryRoute({
    required WidgetBuilder builder,
    required bool reducedMotion,
  }) : super(
         transitionDuration: reducedMotion
             ? Duration.zero
             : const Duration(milliseconds: 300),
         reverseTransitionDuration: reducedMotion
             ? Duration.zero
             : const Duration(milliseconds: 220),
         pageBuilder: (context, _, _) => builder(context),
         transitionsBuilder: (context, animation, _, child) =>
             OmniMotion.reduce(context)
             ? child
             : SlideTransition(
                 position:
                     Tween<Offset>(
                       begin: const Offset(1, 0),
                       end: Offset.zero,
                     ).animate(
                       CurvedAnimation(
                         parent: animation,
                         curve: Curves.easeOutCubic,
                         reverseCurve: Curves.easeInCubic,
                       ),
                     ),
                 child: child,
               ),
       );
}

/// 全屏只替换编辑呈现，正文、工具和草稿会话与紧凑表面共用。
class _AndroidHistorySurface extends StatelessWidget {
  /// 外部返回门禁持有日历开闭状态。
  final MenuController dateMenu;

  /// 正文及附件使用自己的滚动区。
  final Widget body;

  /// 键盘上沿固定工具栏。
  final Widget toolbar;

  /// 浮于工具栏上方的列表或更多胶囊。
  final Widget? popup;

  /// 归档日与原始创建时分秒。
  final String dateLabel;

  /// 当前归档日作为现有日历的选择事实。
  final DateTime day;

  /// 返回经过草稿可靠暂存门禁。
  final VoidCallback? onBack;

  /// 顶部菜单只管理当前草稿。
  final ValueChanged<BuildContext>? onMenu;

  /// 日期只修改归档自然日。
  final ValueChanged<DateTime>? onDate;

  /// 创建历史编辑专用表面。
  const _AndroidHistorySurface({
    required this.dateMenu,
    required this.body,
    required this.toolbar,
    required this.popup,
    required this.dateLabel,
    required this.day,
    required this.onBack,
    required this.onMenu,
    required this.onDate,
  });

  /// 顶部圆形按钮在不改共享控件的前提下保持视频外观。
  Widget _circle(
    BuildContext context,
    String label,
    IconData icon,
    VoidCallback? action,
  ) => ClipOval(
    child: DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: OmniColors.of(context).line),
        color: OmniColors.of(context).paper,
      ),
      child: OmniIconButton(
        tooltip: label,
        icon: Icon(icon, size: OmniSpacing.xl),
        onPressed: action,
        constraints: const BoxConstraints.tightFor(
          width: OmniSize.touch,
          height: OmniSize.touch,
        ),
        style: ButtonStyle(
          side: const WidgetStatePropertyAll(BorderSide.none),
          backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
        ),
      ),
    ),
  );

  /// 安全区和系统inset只有一处处理，不叠加键盘动画。
  @override
  Widget build(BuildContext context) => Scaffold(
    key: const ValueKey('android-note-history-editor'),
    resizeToAvoidBottomInset: false,
    backgroundColor: OmniColors.of(context).paper,
    body: Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: OmniSpacing.md,
                vertical: OmniSpacing.xs,
              ),
              child: Row(
                children: [
                  _circle(context, '返回笔记列表', Icons.chevron_left, onBack),
                  const SizedBox(width: OmniSpacing.xs),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Semantics(
                          header: true,
                          namesRoute: true,
                          child: Text(
                            '编辑',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        OmniDatePickerButton(
                          controller: dateMenu,
                          wrapLabel: true,
                          value: day,
                          initialDate: day,
                          firstDate: DateTime(2000),
                          lastDate: DateTime.now().add(
                            const Duration(days: 3650),
                          ),
                          label: dateLabel,
                          icon: Icons.keyboard_arrow_down,
                          onChanged: onDate,
                          style: ButtonStyle(
                            minimumSize: const WidgetStatePropertyAll(
                              Size(OmniSize.touch, OmniSize.touch),
                            ),
                            padding: const WidgetStatePropertyAll(
                              EdgeInsets.zero,
                            ),
                            side: const WidgetStatePropertyAll(BorderSide.none),
                            textStyle: WidgetStatePropertyAll(
                              Theme.of(context).textTheme.bodySmall,
                            ),
                            foregroundColor: WidgetStatePropertyAll(
                              OmniColors.of(context).muted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: OmniSpacing.xs),
                  Builder(
                    builder: (anchor) => _circle(
                      context,
                      '编辑笔记操作',
                      Icons.more_horiz,
                      onMenu == null ? null : () => onMenu!(anchor),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  body,
                  Positioned(
                    left: OmniSpacing.md,
                    right: OmniSpacing.md,
                    bottom: OmniSpacing.xs,
                    child: AnimatedSwitcher(
                      duration: OmniMotion.duration(
                        context,
                        const Duration(milliseconds: 160),
                      ),
                      child: popup ?? const SizedBox.shrink(),
                    ),
                  ),
                ],
              ),
            ),
            toolbar,
          ],
        ),
      ),
    ),
  );
}

/// 历史页内录音共用卡片，单独动画自己的模糊层，不模糊底层主列表。
class _AndroidHistoryVoiceCover extends StatefulWidget {
  /// 当前历史篇的同一张录音卡片。
  final Widget child;

  /// 所有显式退出继续走本段确认。
  final VoidCallback onClose;

  /// 创建历史页内的录音覆盖。
  const _AndroidHistoryVoiceCover({required this.child, required this.onClose});

  /// 模糊与位移共用进入进度。
  @override
  State<_AndroidHistoryVoiceCover> createState() =>
      _AndroidHistoryVoiceCoverState();
}

/// 退出透明度由外层切换器控制，采集器始终绑定原草稿。
class _AndroidHistoryVoiceCoverState extends State<_AndroidHistoryVoiceCover>
    with SingleTickerProviderStateMixin {
  /// 卡片进入和背景模糊使用同一时钟。
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );

  /// 初始绘制后尊重系统减少动画偏好。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (OmniMotion.reduce(context)) {
      _animation.value = 1;
    } else {
      unawaited(_animation.forward());
    }
  }

  /// 不销毁业务录音，只释放呈现时钟。
  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  /// 历史正文仍挂载在下层，原选区与撤销栈不会重建。
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _animation,
    child: widget.child,
    builder: (context, child) {
      // 与视频相同的下方进入及单层模糊。
      final double progress = Curves.easeOutCubic.transform(_animation.value);
      return Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onClose,
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(
                sigmaX: 10 * progress,
                sigmaY: 10 * progress,
              ),
              child: ColoredBox(
                color: OmniColors.of(context).canvas
                    .withValues(alpha: .42 * progress),
              ),
            ),
          ),
          Transform.translate(
            offset: Offset(
              0,
              MediaQuery.sizeOf(context).height * (1 - progress),
            ),
            child: child,
          ),
        ],
      );
    },
  );
}
