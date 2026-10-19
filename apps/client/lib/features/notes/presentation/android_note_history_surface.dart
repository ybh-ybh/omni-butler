part of 'android_notes_view.dart';

/// 历史编辑与新建面板统一从底部进出，保留原有全屏布局。
class _AndroidHistoryRoute extends PageRouteBuilder<void> {
  /// 路由只提供表面，业务会话由编辑器持有。
  _AndroidHistoryRoute({
    required WidgetBuilder builder,
    required bool reducedMotion,
  }) : super(
         transitionDuration: reducedMotion
             ? Duration.zero
             : OmniMotion.androidModalEnter,
         reverseTransitionDuration: reducedMotion
             ? Duration.zero
             : OmniMotion.androidModalExit,
         pageBuilder: (context, _, _) => builder(context),
         transitionsBuilder: (context, animation, _, child) =>
             OmniMotion.reduce(context)
             ? child
             : OmniModalSlideTransition(animation: animation, child: child),
       );
}

/// 全屏只替换编辑呈现，正文、工具和草稿会话与紧凑表面共用。
class _AndroidHistorySurface extends StatelessWidget {
  /// 正文及附件使用自己的滚动区。
  final Widget body;

  /// 键盘上沿固定工具栏。
  final Widget toolbar;

  /// 浮于工具栏上方的列表或更多胶囊。
  final Widget? popup;

  /// 用户可编辑的完整记录日期时间。
  final String dateLabel;

  /// 待保存修改决定左上角使用勾号还是返回箭头。
  final bool hasChanges;

  /// 返回经过正式保存门禁。
  final VoidCallback? onBack;

  /// 顶部菜单只管理当前草稿。
  final ValueChanged<BuildContext>? onMenu;

  /// 打开独立日期时间面板，确认后仅更新当前草稿。
  final VoidCallback? onDate;

  /// 创建历史编辑专用表面。
  const _AndroidHistorySurface({
    required this.body,
    required this.toolbar,
    required this.popup,
    required this.dateLabel,
    required this.hasChanges,
    required this.onBack,
    required this.onMenu,
    required this.onDate,
  });

  /// 按钮视觉缩小到40dp并保留48dp热区，阴影不随内部圆形裁剪消失。
  Widget _circle(
    BuildContext context,
    String id,
    String label,
    IconData icon,
    VoidCallback? action,
  ) => SizedBox(
    key: ValueKey('android-note-history-$id'),
    width: OmniSize.touch,
    height: OmniSize.touch,
    child: Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        IgnorePointer(
          child: Container(
            key: ValueKey('android-note-history-$id-visual'),
            width: OmniSize.controlLarge,
            height: OmniSize.controlLarge,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: OmniColors.of(context).line),
              color: OmniColors.of(context).paper,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(
                    alpha: Theme.of(context).brightness == Brightness.dark
                        ? .18
                        : .06,
                  ),
                  blurRadius: OmniSpacing.sm,
                  offset: const Offset(0, OmniSpacing.xxs / 2),
                ),
              ],
            ),
          ),
        ),
        OmniIconButton(
          tooltip: label,
          icon: Icon(icon, size: OmniSpacing.lg),
          onPressed: action,
          constraints: const BoxConstraints.tightFor(
            width: OmniSize.touch,
            height: OmniSize.touch,
          ),
          style: const ButtonStyle(
            shape: WidgetStatePropertyAll(CircleBorder()),
            side: WidgetStatePropertyAll(BorderSide.none),
            backgroundColor: WidgetStatePropertyAll(Colors.transparent),
          ),
        ),
      ],
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
                  _circle(
                    context,
                    'back',
                    hasChanges ? '保存' : '返回笔记列表',
                    hasChanges ? Icons.check : Icons.chevron_left,
                    onBack,
                  ),
                  const SizedBox(width: OmniSpacing.xs),
                  Expanded(
                    // 标题和日期共用48dp入口，将两行视觉间距压缩而不缩小点击区域。
                    child: OmniTextButton(
                      key: const ValueKey('android-note-record-time'),
                      onPressed: onDate,
                      style: ButtonStyle(
                        minimumSize: const WidgetStatePropertyAll(
                          Size(OmniSize.touch, OmniSize.touch),
                        ),
                        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
                        side: const WidgetStatePropertyAll(BorderSide.none),
                        foregroundColor: WidgetStatePropertyAll(
                          OmniColors.of(context).muted,
                        ),
                        textStyle: WidgetStatePropertyAll(
                          Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Semantics(
                            header: true,
                            namesRoute: true,
                            child: Text(
                              '编辑',
                              key: const ValueKey('android-note-history-title'),
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          const SizedBox(height: OmniSpacing.xxs / 2),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  dateLabel,
                                  key: const ValueKey(
                                    'android-note-history-date-label',
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                              const Icon(
                                Icons.keyboard_arrow_down,
                                size: OmniSpacing.md,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: OmniSpacing.xs),
                  Builder(
                    builder: (anchor) => _circle(
                      context,
                      'more',
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
