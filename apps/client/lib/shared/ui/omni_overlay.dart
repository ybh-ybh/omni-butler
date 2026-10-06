import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/shared/ui/omni_button.dart';
import 'package:omni_butler/shared/ui/omni_icon_button.dart';
import 'package:omni_butler/shared/ui/omni_windows_enter_submit.dart';

/// 显示桌面右侧面板或移动端全屏编辑器。
Future<T?> showOmniSideSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  double desktopWidth = OmniSize.sideSheet,
}) {
  // 当前视口是否为紧凑布局。
  final bool compact = OmniBreakpoint.isCompact(
    MediaQuery.sizeOf(context).width,
  );
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.42),
    transitionDuration: OmniMotion.duration(context, OmniMotion.panel),
    pageBuilder:
        (
          BuildContext dialogContext,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
        ) {
          // 业务提供的编辑器内容。
          final Widget content = builder(dialogContext);
          return FocusTraversalGroup(
            child: Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
                width: compact
                    ? MediaQuery.sizeOf(context).width
                    : desktopWidth,
                height: MediaQuery.sizeOf(context).height,
                child: Material(color: Colors.transparent, child: content),
              ),
            ),
          );
        },
    transitionBuilder:
        (
          BuildContext dialogContext,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
          Widget child,
        ) {
          if (OmniMotion.reduce(dialogContext)) {
            return child;
          }
          // 从右侧进入的位移动画。
          final Animation<Offset> slide =
              Tween<Offset>(
                begin: const Offset(0.08, 0),
                end: Offset.zero,
              ).animate(
                CurvedAnimation(
                  parent: animation,
                  curve: OmniMotion.standardCurve,
                ),
              );
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(position: slide, child: child),
          );
        },
  );
}

/// 在当前应用窗口内显示模态弹窗。
///
/// Windows 使用实验性多窗口能力时，Flutter 的 [showDialog] 会把弹窗提升为
/// 独立原生窗口；应用内确认框需要直接推入 [DialogRoute]，以保留遮罩、主题和尺寸。
Future<T?> showOmniDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useSafeArea = true,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  Offset? anchorPoint,
  TraversalEdgeBehavior? traversalEdgeBehavior,
  bool fullscreenDialog = false,
  bool? requestFocus,
  AnimationStyle? animationStyle,
}) {
  // 承载应用内弹窗的导航器。
  final NavigatorState navigator = Navigator.of(
    context,
    rootNavigator: useRootNavigator,
  );
  // 从调用位置传递到导航器覆盖层的继承主题。
  final CapturedThemes themes = InheritedTheme.capture(
    from: context,
    to: navigator.context,
  );
  // 为模态任务提供统一且克制的背景遮罩。
  final Color resolvedBarrierColor =
      barrierColor ??
      DialogTheme.of(context).barrierColor ??
      Theme.of(context).dialogTheme.barrierColor ??
      Colors.black.withValues(alpha: 0.42);

  return navigator.push<T>(
    DialogRoute<T>(
      context: context,
      builder: builder,
      themes: themes,
      barrierColor: resolvedBarrierColor,
      barrierDismissible: barrierDismissible,
      barrierLabel: barrierLabel,
      useSafeArea: useSafeArea,
      settings: routeSettings,
      anchorPoint: anchorPoint,
      traversalEdgeBehavior:
          traversalEdgeBehavior ?? TraversalEdgeBehavior.closedLoop,
      fullscreenDialog: fullscreenDialog,
      requestFocus: requestFocus,
      animationStyle: OmniMotion.reduce(context)
          ? AnimationStyle.noAnimation
          : animationStyle ??
                const AnimationStyle(
                  duration: OmniMotion.panel,
                  reverseDuration: OmniMotion.normal,
                  curve: OmniMotion.standardCurve,
                  reverseCurve: Curves.easeInCubic,
                ),
    ),
  );
}

/// 侧滑编辑器统一结构。
class OmniSideSheetScaffold extends StatelessWidget {
  /// 面板标题。
  final String title;

  /// 面板主体。
  final Widget child;

  /// 底部操作。
  final List<Widget> actions;

  /// 是否允许关闭。
  final bool canClose;

  /// Windows 端按下 Enter 时执行的回调。
  final VoidCallback? onWindowsEnter;

  /// 创建侧滑编辑器结构。
  const OmniSideSheetScaffold({
    required this.title,
    required this.child,
    this.actions = const <Widget>[],
    this.canClose = true,
    this.onWindowsEnter,
    super.key,
  });

  /// 构建固定标题、滚动主体和固定操作区。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // showGeneralDialog 不会自动避让软键盘，由侧栏结构统一保留可用高度。
    final double keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    // 侧滑编辑器的完整内容。
    final Widget content = Material(
      color: colors.paper,
      child: AnimatedPadding(
        padding: EdgeInsets.only(bottom: keyboardInset),
        duration: OmniMotion.duration(context, OmniMotion.normal),
        curve: OmniMotion.standardCurve,
        child: MediaQuery.removeViewInsets(
          context: context,
          removeBottom: true,
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Container(
                  constraints: const BoxConstraints(minHeight: 56),
                  padding: const EdgeInsets.symmetric(
                    horizontal: OmniSpacing.md,
                  ),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: colors.line)),
                  ),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          title,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      OmniIconButton(
                        tooltip: '关闭',
                        onPressed: canClose
                            ? () => Navigator.of(context).maybePop()
                            : null,
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                Expanded(child: child),
                if (actions.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.all(OmniSpacing.md),
                    decoration: BoxDecoration(
                      color: colors.paper,
                      border: Border(top: BorderSide(color: colors.line)),
                    ),
                    child: _OmniDialogActions(actions: actions),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    return onWindowsEnter == null
        ? content
        : OmniWindowsEnterSubmit(onSubmit: onWindowsEnter, child: content);
  }
}

/// 统一标准弹窗结构。
class OmniDialogScaffold extends StatelessWidget {
  /// 弹窗标题。
  final String title;

  /// 弹窗主体。
  final Widget child;

  /// 底部操作。
  final List<Widget> actions;

  /// 弹窗宽度。
  final double width;

  /// 可选弹窗高度。
  final double? height;

  /// Windows 端按下 Enter 时执行的回调。
  final VoidCallback? onWindowsEnter;

  /// 创建标准弹窗。
  const OmniDialogScaffold({
    required this.title,
    required this.child,
    this.actions = const <Widget>[],
    this.width = 520,
    this.height,
    this.onWindowsEnter,
    super.key,
  });

  /// 构建分区清晰的标准弹窗。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前视口尺寸。
    final Size viewport = MediaQuery.sizeOf(context);
    // 标准弹窗的完整内容。
    final Widget content = Dialog(
      insetPadding: const EdgeInsets.all(OmniSpacing.xl),
      insetAnimationDuration: OmniMotion.duration(context, OmniMotion.normal),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: width,
          maxHeight: (height ?? viewport.height - OmniSpacing.xl * 2)
              .clamp(0, viewport.height)
              .toDouble(),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  OmniIconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Divider(color: colors.line),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.all(OmniSpacing.lg),
                child: child,
              ),
            ),
            if (actions.isNotEmpty) ...<Widget>[
              Divider(color: colors.line),
              Padding(
                padding: const EdgeInsets.all(OmniSpacing.md),
                child: _OmniDialogActions(actions: actions),
              ),
            ],
          ],
        ),
      ),
    );
    return onWindowsEnter == null
        ? content
        : OmniWindowsEnterSubmit(onSubmit: onWindowsEnter, child: content);
  }
}

/// 弹窗和侧栏共用的可换行操作区。
class _OmniDialogActions extends StatelessWidget {
  /// 按业务优先级排列的操作。
  final List<Widget> actions;

  /// 创建统一操作区。
  const _OmniDialogActions({required this.actions});

  /// 保留操作顺序，并在窄屏或大字号下换行。
  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: OmniSpacing.xs,
      runSpacing: OmniSpacing.xs,
      children: actions,
    );
  }
}

/// 显示统一的短确认弹窗。
Future<bool> showOmniConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = '确认',
  bool danger = false,
}) async {
  // 用户最终确认结果。
  final bool? confirmed = await showOmniDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => OmniDialogScaffold(
      title: title,
      width: 420,
      actions: <Widget>[
        OmniButton(
          label: '取消',
          variant: OmniButtonVariant.secondary,
          onPressed: () => Navigator.of(dialogContext).pop(false),
        ),
        OmniButton(
          label: confirmLabel,
          variant: danger
              ? OmniButtonVariant.danger
              : OmniButtonVariant.primary,
          onPressed: () => Navigator.of(dialogContext).pop(true),
        ),
      ],
      child: SingleChildScrollView(child: Text(message)),
    ),
  );
  return confirmed ?? false;
}
