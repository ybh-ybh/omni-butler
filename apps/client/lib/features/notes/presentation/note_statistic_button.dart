import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 统计入口独立维护悬停，保持数字与标签的既有对齐位置。
class NoteStatisticButton extends StatefulWidget {
  /// 创建可键盘激活的统计入口。
  const NoteStatisticButton({
    required this.count,
    required this.label,
    required this.countKey,
    required this.alignment,
    required this.onTap,
    super.key,
  });

  /// 当前显示的数量。
  final String count;

  /// 数量对应的名称。
  final String label;

  /// 保留原有数字节点身份。
  final String countKey;

  /// 左、中、右三种统计对齐。
  final CrossAxisAlignment alignment;

  /// 打开记录统计的唯一动作。
  final VoidCallback onTap;

  /// 创建局部交互状态。
  @override
  State<NoteStatisticButton> createState() => _NoteStatisticButtonState();
}

/// 箭头不参与布局，避免悬停时推动统计数字。
class _NoteStatisticButtonState extends State<NoteStatisticButton> {
  /// 当前鼠标悬停状态。
  bool _hovered = false;

  /// 键盘焦点也显示可激活提示。
  bool _focused = false;

  /// 构建具有统一按压反馈的无底色入口。
  @override
  Widget build(BuildContext context) {
    // 主题文字与次要文字颜色。
    final OmniColors colors = OmniColors.of(context);
    // 焦点和悬停共享一条连续动画。
    final bool active = _hovered || _focused;
    return Semantics(
      button: true,
      child: OmniInkWell(
        key: ValueKey('notes-statistic-${widget.countKey}'),
        onTap: widget.onTap,
        onHover: (value) => setState(() => _hovered = value),
        onFocusChange: (value) => setState(() => _focused = value),
        mouseCursor: SystemMouseCursors.click,
        hoverColor: Colors.transparent,
        highlightColor: Colors.transparent,
        splashColor: Colors.transparent,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: active ? 1 : 0),
          duration: OmniMotion.duration(context, OmniMotion.fast),
          curve: OmniMotion.standardCurve,
          builder: (context, progress, child) {
            // 数字和名称同步变深，深色模式变为可读的亮色。
            final Color foreground = Color.lerp(
              colors.muted,
              colors.ink,
              progress,
            )!;
            return Column(
              crossAxisAlignment: widget.alignment,
              children: [
                Text(
                  widget.count,
                  key: ValueKey(widget.countKey),
                  style: Theme.of(context).textTheme.headlineSmall
                      ?.copyWith(color: foreground),
                ),
                const SizedBox(height: OmniSpacing.xxs),
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Text(
                      widget.label,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: foreground),
                    ),
                    Positioned(
                      right: -16,
                      top: 0,
                      bottom: 0,
                      child: ExcludeSemantics(
                        child: Opacity(
                          key: ValueKey(
                            'notes-statistic-arrow-${widget.countKey}',
                          ),
                          opacity: progress,
                          child: Transform.translate(
                            offset: Offset(-3 * (1 - progress), 0),
                            child: Icon(
                              Icons.chevron_right,
                              size: 14,
                              color: foreground,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
