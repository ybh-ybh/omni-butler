import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

/// Omni Butler 统一的小尺寸开关。
class OmniSwitch extends StatelessWidget {
  /// 开关当前值。
  final bool value;

  /// 开关值变更回调。
  final ValueChanged<bool>? onChanged;

  /// 创建统一小尺寸开关。
  const OmniSwitch({required this.value, required this.onChanged, super.key});

  /// 构建保留完整点击区域的小尺寸开关。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 开关是否可以交互。
    final bool enabled = onChanged != null;

    return Semantics(
      toggled: value,
      enabled: enabled,
      button: true,
      child: SizedBox(
        width: OmniSize.switchTapWidth,
        height: OmniSize.controlLarge,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: const ValueKey<String>('omni-switch-interaction'),
            onTap: enabled ? () => onChanged!(!value) : null,
            mouseCursor: enabled
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            customBorder: const StadiumBorder(),
            overlayColor: WidgetStateProperty.resolveWith<Color?>((
              Set<WidgetState> states,
            ) {
              if (states.contains(WidgetState.focused) &&
                  !states.contains(WidgetState.hovered)) {
                return colors.brand.withValues(alpha: 0.14);
              }
              return Colors.transparent;
            }),
            child: Center(
              child: AnimatedOpacity(
                duration: OmniMotion.fast,
                opacity: enabled ? 1 : 0.46,
                child: _SwitchTrack(value: value),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 深色凹槽与立体滑块组成的开关轨道。
class _SwitchTrack extends StatelessWidget {
  /// 开关当前值。
  final bool value;

  /// 创建立体开关轨道。
  const _SwitchTrack({required this.value});

  /// 构建带状态环和双向滑动动画的轨道。
  @override
  Widget build(BuildContext context) {
    // 当前是否使用深色主题。
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    // 当前主题对应的开关配色。
    final _SwitchPalette palette = isDark
        ? _SwitchPalette.dark
        : _SwitchPalette.light;

    return Container(
      key: const ValueKey<String>('omni-switch-track'),
      width: OmniSize.switchTrackWidth,
      height: OmniSize.switchTrackHeight,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[palette.outerStart, palette.outerEnd],
        ),
        borderRadius: BorderRadius.circular(OmniRadius.pill),
        border: Border.all(color: palette.outerBorder),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: palette.outerShadow,
            offset: Offset(0, 3),
            blurRadius: 6,
            spreadRadius: -2,
          ),
          BoxShadow(
            color: palette.outerHighlight,
            offset: const Offset(0, -1),
            blurRadius: 2,
          ),
        ],
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: palette.track,
          borderRadius: BorderRadius.circular(OmniRadius.pill),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            _SwitchStatusIndicator(value: value, palette: palette),
            AnimatedAlign(
              key: const ValueKey<String>('omni-switch-thumb-position'),
              duration: OmniMotion.switchThumb,
              curve: Curves.easeIn,
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                key: const ValueKey<String>('omni-switch-thumb'),
                width: OmniSize.switchThumb,
                height: OmniSize.switchThumb,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[palette.thumbStart, palette.thumbEnd],
                  ),
                  border: Border.all(color: palette.thumbBorder),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: palette.thumbShadow,
                      offset: const Offset(0, 3),
                      blurRadius: 7,
                    ),
                    BoxShadow(
                      color: palette.thumbHighlight,
                      offset: const Offset(0, -1),
                      blurRadius: 2,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 带 CSS 同款一秒淡出节点的状态环。
class _SwitchStatusIndicator extends StatefulWidget {
  /// 开关当前值。
  final bool value;

  /// 当前主题开关配色。
  final _SwitchPalette palette;

  /// 创建状态环。
  const _SwitchStatusIndicator({required this.value, required this.palette});

  /// 创建状态环动画状态。
  @override
  State<_SwitchStatusIndicator> createState() => _SwitchStatusIndicatorState();
}

/// 状态环动画状态。
class _SwitchStatusIndicatorState extends State<_SwitchStatusIndicator>
    with SingleTickerProviderStateMixin {
  /// 状态环一秒动画控制器。
  late final AnimationController _controller;

  /// 先淡出再出现的不透明度动画。
  late final Animation<double> _opacity;

  /// 初始化与 CSS 关键帧一致的 30% 淡出节点。
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: OmniMotion.switchIndicator,
      value: 1,
    );
    _opacity = TweenSequence<double>(<TweenSequenceItem<double>>[
      TweenSequenceItem<double>(
        tween: Tween<double>(begin: 1, end: 0),
        weight: 30,
      ),
      TweenSequenceItem<double>(
        tween: Tween<double>(begin: 0, end: 1),
        weight: 70,
      ),
    ]).animate(_controller);
  }

  /// 开关状态变化时重新播放完整状态环动画。
  @override
  void didUpdateWidget(covariant _SwitchStatusIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _controller.forward(from: 0);
    }
  }

  /// 释放动画控制器。
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 构建移动、变色和淡出的状态环。
  @override
  Widget build(BuildContext context) {
    // 当前状态环颜色。
    final Color indicatorColor = widget.value
        ? widget.palette.indicatorOn
        : widget.palette.indicatorOff;
    return FadeTransition(
      key: const ValueKey<String>('omni-switch-indicator-fade'),
      opacity: _opacity,
      child: Padding(
        key: const ValueKey<String>('omni-switch-indicator-inset'),
        padding: const EdgeInsets.symmetric(
          horizontal: OmniSize.switchIndicatorInset,
        ),
        child: AnimatedAlign(
          key: const ValueKey<String>('omni-switch-indicator-position'),
          duration: OmniMotion.switchIndicator,
          curve: Curves.ease,
          alignment: widget.value
              ? Alignment.centerLeft
              : Alignment.centerRight,
          child: AnimatedContainer(
            key: const ValueKey<String>('omni-switch-indicator'),
            duration: OmniMotion.switchIndicator,
            width: OmniSize.switchIndicator,
            height: OmniSize.switchIndicator,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: indicatorColor, width: 2),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: indicatorColor.withValues(alpha: 0.18),
                  blurRadius: 4,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 立体开关在单个主题下使用的完整配色。
class _SwitchPalette {
  /// 外层凹槽顶部颜色。
  final Color outerStart;

  /// 外层凹槽底部颜色。
  final Color outerEnd;

  /// 外层边框颜色。
  final Color outerBorder;

  /// 内部轨道颜色。
  final Color track;

  /// 外层投影颜色。
  final Color outerShadow;

  /// 外层高光颜色。
  final Color outerHighlight;

  /// 滑块顶部颜色。
  final Color thumbStart;

  /// 滑块底部颜色。
  final Color thumbEnd;

  /// 滑块边框颜色。
  final Color thumbBorder;

  /// 滑块投影颜色。
  final Color thumbShadow;

  /// 滑块高光颜色。
  final Color thumbHighlight;

  /// 关闭状态环颜色。
  final Color indicatorOff;

  /// 开启状态环颜色。
  final Color indicatorOn;

  /// 创建一套立体开关配色。
  const _SwitchPalette({
    required this.outerStart,
    required this.outerEnd,
    required this.outerBorder,
    required this.track,
    required this.outerShadow,
    required this.outerHighlight,
    required this.thumbStart,
    required this.thumbEnd,
    required this.thumbBorder,
    required this.thumbShadow,
    required this.thumbHighlight,
    required this.indicatorOff,
    required this.indicatorOn,
  });

  /// 浅色主题配色。
  static const _SwitchPalette light = _SwitchPalette(
    outerStart: Color(0xFFC3CBD6),
    outerEnd: Color(0xFFE0E5EC),
    outerBorder: Color(0xFFB4BECC),
    track: Color(0xFFD3DAE4),
    outerShadow: Color(0x3D253143),
    outerHighlight: Color(0x99FFFFFF),
    thumbStart: Color(0xFFE7EBF1),
    thumbEnd: Color(0xFFC2CBD7),
    thumbBorder: Color(0xFFAAB6C5),
    thumbShadow: Color(0x4D283547),
    thumbHighlight: Color(0xB3FFFFFF),
    indicatorOff: Color(0xFFE0525B),
    indicatorOn: Color(0xFF2FA76F),
  );

  /// 深色主题配色。
  static const _SwitchPalette dark = _SwitchPalette(
    outerStart: Color(0xFF17161D),
    outerEnd: Color(0xFF302F3C),
    outerBorder: Color(0xFF32303E),
    track: Color(0xFF252532),
    outerShadow: Color(0x730F0E17),
    outerHighlight: Color(0x33403F4E),
    thumbStart: Color(0xFF424151),
    thumbEnd: Color(0xFF272733),
    thumbBorder: Color(0xFF4A495A),
    thumbShadow: Color(0xB30F0E17),
    thumbHighlight: Color(0x334C4B5D),
    indicatorOff: Color(0xFFEF565F),
    indicatorOn: Color(0xFF60D480),
  );
}

/// 带标题的统一小尺寸开关列表项。
class OmniSwitchListTile extends StatelessWidget {
  /// 开关当前值。
  final bool value;

  /// 开关值变更回调。
  final ValueChanged<bool>? onChanged;

  /// 列表项标题。
  final Widget title;

  /// 列表项内容边距。
  final EdgeInsetsGeometry? contentPadding;

  /// 创建带标题的小尺寸开关列表项。
  const OmniSwitchListTile({
    required this.value,
    required this.onChanged,
    required this.title,
    this.contentPadding = const EdgeInsets.symmetric(
      horizontal: OmniSpacing.sm,
      vertical: 2,
    ),
    super.key,
  });

  /// 构建整行可点击且语义完整的开关列表项。
  @override
  Widget build(BuildContext context) {
    return Semantics(
      toggled: value,
      enabled: onChanged != null,
      child: ListTile(
        contentPadding: contentPadding,
        title: title,
        onTap: onChanged == null ? null : () => onChanged!(!value),
        trailing: ExcludeSemantics(
          child: OmniSwitch(value: value, onChanged: onChanged),
        ),
      ),
    );
  }
}
