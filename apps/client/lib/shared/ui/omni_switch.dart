import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

/// Omni Butler 统一的语义开关。
class OmniSwitch extends StatelessWidget {
  /// 开关当前值。
  final bool value;

  /// 开关值变更回调。
  final ValueChanged<bool>? onChanged;

  /// 创建保持完整键盘与触控热区的开关。
  const OmniSwitch({required this.value, required this.onChanged, super.key});

  /// 构建品牌轨道与可中途反向的白色滑块。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 开关是否可以交互。
    final bool enabled = onChanged != null;
    // 视觉轨道保持紧凑，触控平台保留完整热区。
    final double height = OmniDensity.controlHeight(context, large: true);
    // 辅助技术与直接操作共享同一变更入口。
    final VoidCallback? toggle = enabled ? () => onChanged!(!value) : null;

    return Semantics(
      toggled: value,
      enabled: enabled,
      onTap: toggle,
      child: SizedBox(
        width: OmniSize.switchTapWidth,
        height: height,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: const ValueKey<String>('omni-switch-interaction'),
            onTap: toggle,
            excludeFromSemantics: true,
            canRequestFocus: enabled,
            mouseCursor: enabled
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            customBorder: const StadiumBorder(),
            overlayColor: WidgetStateProperty.resolveWith<Color?>((
              Set<WidgetState> states,
            ) {
              if (states.contains(WidgetState.focused)) {
                return colors.brand.withValues(alpha: 0.20);
              }
              if (states.contains(WidgetState.pressed)) {
                return colors.ink.withValues(alpha: 0.10);
              }
              if (states.contains(WidgetState.hovered)) {
                return colors.ink.withValues(alpha: 0.05);
              }
              return Colors.transparent;
            }),
            child: Center(
              child: AnimatedOpacity(
                duration: OmniMotion.duration(context, OmniMotion.fast),
                opacity: enabled ? 1 : 0.46,
                child: AnimatedContainer(
                  key: const ValueKey<String>('omni-switch-track'),
                  duration: OmniMotion.duration(
                    context,
                    OmniMotion.switchThumb,
                  ),
                  curve: OmniMotion.standardCurve,
                  width: OmniSize.switchTrackWidth,
                  height: OmniSize.switchTrackHeight,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: value ? colors.brand : colors.line,
                    borderRadius: BorderRadius.circular(OmniRadius.pill),
                  ),
                  child: AnimatedAlign(
                    key: const ValueKey<String>('omni-switch-thumb-position'),
                    duration: OmniMotion.duration(
                      context,
                      OmniMotion.switchThumb,
                    ),
                    curve: OmniMotion.standardCurve,
                    alignment: value
                        ? AlignmentDirectional.centerEnd
                        : AlignmentDirectional.centerStart,
                    child: Container(
                      key: const ValueKey<String>('omni-switch-thumb'),
                      width: OmniSize.switchThumb,
                      height: OmniSize.switchThumb,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.16),
                            offset: const Offset(0, 1),
                            blurRadius: 2,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 带标题的统一开关列表项。
class OmniSwitchListTile extends StatelessWidget {
  /// 开关当前值。
  final bool value;

  /// 开关值变更回调。
  final ValueChanged<bool>? onChanged;

  /// 列表项标题。
  final Widget title;

  /// 列表项内容边距。
  final EdgeInsetsGeometry? contentPadding;

  /// 创建带标题的开关列表项。
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

  /// 整行拥有唯一焦点和读屏节点，避免开关重复操作。
  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Semantics(
        toggled: value,
        enabled: onChanged != null,
        child: ListTile(
          contentPadding: contentPadding,
          minTileHeight: OmniDensity.controlHeight(context, large: true),
          title: title,
          onTap: onChanged == null ? null : () => onChanged!(!value),
          trailing: ExcludeFocus(
            child: ExcludeSemantics(
              child: IgnorePointer(
                child: OmniSwitch(value: value, onChanged: onChanged),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
