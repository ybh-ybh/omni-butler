import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 尚在接入数据层的模块占位页。
class ModulePlaceholder extends StatelessWidget {
  /// 模块名称。
  final String title;

  /// 模块目标说明。
  final String description;

  /// 模块图标。
  final IconData icon;

  /// 模块语义色。
  final Color Function(OmniColors colors) colorSelector;

  /// 首批能力名称。
  final List<String> capabilities;

  /// 创建模块占位页。
  const ModulePlaceholder({
    required this.title,
    required this.description,
    required this.icon,
    required this.colorSelector,
    required this.capabilities,
    super.key,
  });

  /// 构建明确说明开发状态的模块页。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前模块语义色。
    final Color moduleColor = colorSelector(colors);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 当前页面是否采用紧凑边距。
        final bool compact = OmniBreakpoint.isCompact(constraints.maxWidth);
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            compact ? OmniSpacing.md : OmniSpacing.xl,
            OmniSpacing.lg,
            compact ? OmniSpacing.md : OmniSpacing.xl,
            OmniSpacing.xxl,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 880),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  OmniPageHeader(title: title, description: description),
                  const SizedBox(height: OmniSpacing.lg),
                  OmniPanel(
                    padding: const EdgeInsets.all(OmniSpacing.xxl),
                    child: Column(
                      children: <Widget>[
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: moduleColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(
                              OmniRadius.panel,
                            ),
                          ),
                          child: Icon(icon, color: moduleColor, size: 28),
                        ),
                        const SizedBox(height: OmniSpacing.md),
                        Text(
                          '页面结构已就位，正在接入本地数据',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: OmniSpacing.xs),
                        Text(
                          '当前里程碑先验证主题、导航、首页和待办闭环；本模块会复用同一套离线、回收站和同步状态。',
                          style: Theme.of(context).textTheme.bodySmall,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: OmniSpacing.xl),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: OmniSpacing.xs,
                          runSpacing: OmniSpacing.xs,
                          children: <Widget>[
                            for (final String capability in capabilities)
                              OmniTag(label: capability, color: moduleColor),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
