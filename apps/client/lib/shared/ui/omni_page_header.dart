import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

/// 统一的页面标题与操作区。
class OmniPageHeader extends StatelessWidget {
  /// 页面标题。
  final String title;

  /// 可选页面说明。
  final String? description;

  /// 页面操作。
  final List<Widget> actions;

  /// 创建页面标题区。
  const OmniPageHeader({
    required this.title,
    this.description,
    this.actions = const <Widget>[],
    super.key,
  });

  /// 构建可在紧凑宽度自动换行的标题区。
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 当前是否运行在桌面端。
        final bool isDesktopPlatform = OmniBreakpoint.isDesktopPlatform(
          Theme.of(context).platform,
        );
        // 当前标题区域是否需要纵向排列。
        final bool stacked =
            !isDesktopPlatform &&
            constraints.maxWidth < 640 &&
            actions.isNotEmpty;
        // 桌面端窄窗口下是否保留页面说明。
        final bool showDescription =
            description != null &&
            (!isDesktopPlatform || constraints.maxWidth >= 520);
        // 桌面端窄窗口下是否有足够宽度保留页面操作。
        final bool showActions =
            actions.isNotEmpty &&
            (!isDesktopPlatform ||
                constraints.maxWidth >= (actions.length > 1 ? 760 : 560));
        // 标题与可见说明内容。
        final Widget heading = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(title, style: Theme.of(context).textTheme.headlineLarge),
            if (showDescription) ...<Widget>[
              const SizedBox(height: OmniSpacing.xxs),
              Text(description!, style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        );
        if (stacked) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              heading,
              const SizedBox(height: OmniSpacing.sm),
              if (showActions)
                Wrap(
                  spacing: OmniSpacing.xs,
                  runSpacing: OmniSpacing.xs,
                  children: actions,
                ),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Expanded(child: heading),
            if (showActions) ...<Widget>[
              const SizedBox(width: OmniSpacing.md),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  for (
                    int index = 0;
                    index < actions.length;
                    index++
                  ) ...<Widget>[
                    if (index > 0) const SizedBox(width: OmniSpacing.xs),
                    actions[index],
                  ],
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

/// 统一的页面工具栏。
class OmniToolbar extends StatelessWidget {
  /// 工具栏内容。
  final List<Widget> children;

  /// 工具栏对齐方式。
  final WrapAlignment alignment;

  /// 创建页面工具栏。
  const OmniToolbar({
    required this.children,
    this.alignment = WrapAlignment.start,
    super.key,
  });

  /// 构建可折行的紧凑工具栏。
  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: OmniSpacing.xs,
      runSpacing: OmniSpacing.xs,
      alignment: alignment,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
  }
}
