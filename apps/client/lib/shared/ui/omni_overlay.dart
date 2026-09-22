import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/shared/ui/omni_button.dart';

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
    transitionDuration: OmniMotion.panel,
    pageBuilder:
        (
          BuildContext dialogContext,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
        ) {
          // 业务提供的编辑器内容。
          final Widget content = builder(dialogContext);
          return Align(
            alignment: Alignment.centerRight,
            child: SizedBox(
              width: compact ? MediaQuery.sizeOf(context).width : desktopWidth,
              height: MediaQuery.sizeOf(context).height,
              child: Material(color: Colors.transparent, child: content),
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

  /// 创建侧滑编辑器结构。
  const OmniSideSheetScaffold({
    required this.title,
    required this.child,
    this.actions = const <Widget>[],
    this.canClose = true,
    super.key,
  });

  /// 构建固定标题、滚动主体和固定操作区。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Material(
      color: colors.paper,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Container(
              height: 56,
              padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.md),
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
                  IconButton(
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
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    for (
                      int index = 0;
                      index < actions.length;
                      index += 1
                    ) ...<Widget>[
                      if (index > 0) const SizedBox(width: OmniSpacing.xs),
                      actions[index],
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
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

  /// 创建标准弹窗。
  const OmniDialogScaffold({
    required this.title,
    required this.child,
    this.actions = const <Widget>[],
    this.width = 520,
    this.height,
    super.key,
  });

  /// 构建分区清晰的标准弹窗。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前视口尺寸。
    final Size viewport = MediaQuery.sizeOf(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: width,
          maxHeight: height ?? viewport.height - 48,
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
                  IconButton(
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
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    for (
                      int index = 0;
                      index < actions.length;
                      index += 1
                    ) ...<Widget>[
                      if (index > 0) const SizedBox(width: OmniSpacing.xs),
                      actions[index],
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
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
  final bool? confirmed = await showDialog<bool>(
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
      child: Text(message),
    ),
  );
  return confirmed ?? false;
}
