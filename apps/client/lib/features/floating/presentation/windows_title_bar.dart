import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_chrome_colors.dart';

/// 不支持原生标题栏染色的 Windows 使用的独立标题栏。
class WindowsTitleBar extends StatelessWidget {
  /// 创建标题栏；窗口拖动与缩放仍由原生命中区域处理。
  const WindowsTitleBar({
    super.key,
    required this.colors,
    required this.maximized,
    required this.onMinimize,
    required this.onToggleMaximize,
    required this.onClose,
  });

  /// 标题栏逻辑高度，与原生命中区域保持一致。
  static const double height = 28;

  /// 每个窗口控制按钮的逻辑宽度。
  static const double buttonWidth = 46;

  /// 与桌面导航共享的标题栏颜色。
  final OmniChromeColors colors;

  /// 当前窗口是否已最大化。
  final bool maximized;

  /// 最小化当前窗口。
  final VoidCallback onMinimize;

  /// 切换最大化和还原状态。
  final VoidCallback onToggleMaximize;

  /// 请求关闭窗口，保留宿主现有的托盘处理逻辑。
  final VoidCallback onClose;

  /// 构建可独立放在应用路由外的标题栏。
  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey<String>('windows-title-bar'),
      color: colors.background,
      child: DefaultTextStyle(
        style: Theme.of(context).textTheme.labelSmall!.copyWith(
          color: colors.foreground,
          fontSize: 12,
          fontWeight: FontWeight.w400,
          height: 1,
        ),
        child: SizedBox(
          height: height,
          child: Row(
            children: <Widget>[
              const SizedBox(width: 8),
              Image.asset(
                'assets/icon/app_icon.png',
                width: 16,
                height: 16,
                filterQuality: FilterQuality.medium,
                excludeFromSemantics: true,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Omni Butler',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _CaptionButton(
                key: const ValueKey<String>('windows-title-bar-minimize'),
                label: '最小化',
                icon: Icons.remove,
                colors: colors,
                onPressed: onMinimize,
              ),
              _CaptionButton(
                key: const ValueKey<String>('windows-title-bar-maximize'),
                label: maximized ? '还原' : '最大化',
                icon: maximized ? Icons.filter_none : Icons.crop_square,
                colors: colors,
                onPressed: onToggleMaximize,
              ),
              _CaptionButton(
                key: const ValueKey<String>('windows-title-bar-close'),
                label: '关闭',
                icon: Icons.close,
                colors: colors,
                onPressed: onClose,
                isClose: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 固定大小的 Windows 窗口控制按钮。
class _CaptionButton extends StatefulWidget {
  /// 创建带独立语义标签的窗口按钮。
  const _CaptionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.colors,
    required this.onPressed,
    this.isClose = false,
  });

  /// 按钮的中文无障碍名称。
  final String label;

  /// 最小化、最大化、还原或关闭图标。
  final IconData icon;

  /// 标题栏当前配色。
  final OmniChromeColors colors;

  /// 激活按钮时的窗口操作。
  final VoidCallback onPressed;

  /// 关闭按钮使用 Windows 风格的红色交互反馈。
  final bool isClose;

  /// 创建窗口按钮交互状态。
  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

/// 管理窗口按钮的鼠标悬停与键盘焦点反馈。
class _CaptionButtonState extends State<_CaptionButton> {
  /// 鼠标当前是否位于按钮上。
  bool _hovered = false;

  /// 按钮是否持有键盘焦点。
  bool _focused = false;

  /// 构建不依赖 Overlay 或 MaterialApp 的窗口按钮。
  @override
  Widget build(BuildContext context) {
    // 鼠标与键盘使用一致的交互反馈。
    final bool highlighted = _hovered || _focused;
    // 关闭反馈沿用应用的危险色与可读前景色。
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    // 普通按钮显示清晰中性底色，关闭按钮沿用危险色反馈。
    final Color background = highlighted
        ? widget.isClose
              ? colorScheme.error
              : widget.colors.captionHoverBackground
        : widget.colors.background;
    // 关闭按钮沿用危险色前景，其余状态保留标题栏图标颜色。
    final Color foreground = highlighted && widget.isClose
        ? colorScheme.onError
        : widget.colors.foreground;
    // 按压叠层按按钮实际前景选择，避免浅色标题栏上的关闭红底被提亮。
    final Color pressedTint =
        foreground.computeLuminance() > background.computeLuminance()
        ? Colors.black
        : Colors.white;
    return Semantics(
      label: widget.label,
      tooltip: widget.label,
      button: true,
      onTap: widget.onPressed,
      child: Material(
        color: background,
        child: InkWell(
          onTap: widget.onPressed,
          onHover: (bool hovered) => setState(() => _hovered = hovered),
          onFocusChange: (bool focused) => setState(() => _focused = focused),
          excludeFromSemantics: true,
          hoverColor: Colors.transparent,
          focusColor: Colors.transparent,
          highlightColor: pressedTint.withValues(alpha: 0.08),
          splashFactory: NoSplash.splashFactory,
          child: SizedBox(
            width: WindowsTitleBar.buttonWidth,
            height: WindowsTitleBar.height,
            child: Center(
              child: ExcludeSemantics(
                child: Icon(widget.icon, size: 12, color: foreground),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
