import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_theme_palette.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

/// 设置页中可换行、支持键盘与读屏的主题色选择器。
class ThemePaletteSelector extends StatelessWidget {
  /// 当前选择的配色。
  final AppThemePalette value;

  /// 用户选择新的配色时通知设置页。
  final ValueChanged<AppThemePalette> onChanged;

  /// 创建主题色选择器。
  const ThemePaletteSelector({
    required this.value,
    required this.onChanged,
    super.key,
  });

  /// 按截图的圆形色块布局，窄屏自动换行。
  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: OmniSpacing.sm,
      runSpacing: OmniSpacing.sm,
      children: <Widget>[
        // 每个主题的预览入口。
        for (final AppThemePalette palette in AppThemePalette.values)
          _PaletteOption(
            palette: palette,
            selected: palette == value,
            onTap: () => onChanged(palette),
          ),
      ],
    );
  }
}

/// 带选中外环和固定名称区域的单个色块。
class _PaletteOption extends StatelessWidget {
  /// 当前选项对应的配色。
  final AppThemePalette palette;

  /// 当前选项是否选中。
  final bool selected;

  /// 激活选项的回调。
  final VoidCallback onTap;

  /// 创建色块选项。
  const _PaletteOption({
    required this.palette,
    required this.selected,
    required this.onTap,
  });

  /// 构建至少 44×44 的可聚焦选项，名称预留空间避免选中后跳动。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Semantics(
      key: ValueKey<String>('theme-palette-${palette.id}'),
      label: palette.label,
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: Tooltip(
        message: palette.label,
        excludeFromSemantics: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(OmniRadius.control),
          child: SizedBox(
            width: 56,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  width: 50,
                  height: 50,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: selected ? colors.brand : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: palette.previewColorFor(
                        Theme.of(context).brightness,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: OmniSpacing.xxs),
                ExcludeSemantics(
                  child: SizedBox(
                    height: 24,
                    child: selected
                        ? Text(
                            palette.label,
                            style: Theme.of(context).textTheme.bodySmall,
                          )
                        : null,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
