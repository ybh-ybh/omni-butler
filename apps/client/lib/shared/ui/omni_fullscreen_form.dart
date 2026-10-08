import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/shared/ui/omni_button.dart';

/// 分组自身提供背景和边界，输入仅保留原生编辑及校验能力。
const InputDecoration omniGroupedInputDecoration = InputDecoration(
  filled: false,
  contentPadding: EdgeInsets.symmetric(vertical: OmniSpacing.sm),
  border: InputBorder.none,
  enabledBorder: InputBorder.none,
  focusedBorder: InputBorder.none,
  disabledBorder: InputBorder.none,
  errorBorder: InputBorder.none,
  focusedErrorBorder: InputBorder.none,
);

/// 全屏表单的公共呈现，业务负责正文滚动、返回保护和提交。
class OmniFullscreenFormScaffold extends StatelessWidget {
  /// 居中的业务标题。
  final String title;

  /// 正文插槽，允许表单和列表分别管理滚动。
  final Widget child;

  /// 右侧主操作的完整文案。
  final String primaryLabel;

  /// 主操作不可用时为空。
  final VoidCallback? onPrimary;

  /// 左侧取消操作不可用时为空。
  final VoidCallback? onCancel;

  /// 提交期间显示加载状态并冻结正文。
  final bool loading;

  /// 业务确有统计意义时显示的灰色摘要。
  final String? subtitle;

  /// 主操作的稳定标识。
  final Key? primaryKey;

  /// 创建统一全屏结构。
  const OmniFullscreenFormScaffold({
    required this.title,
    required this.child,
    required this.onPrimary,
    required this.onCancel,
    this.primaryLabel = '保存',
    this.loading = false,
    this.subtitle,
    this.primaryKey,
    super.key,
  });

  /// 构建由 Dialog 统一避让键盘的安全区与固定顶栏。
  @override
  Widget build(BuildContext context) {
    // 当前主题的表面和文字语义色。
    final OmniColors colors = OmniColors.of(context);
    return Dialog.fullscreen(
      backgroundColor: colors.canvas,
      insetAnimationDuration: OmniMotion.duration(context, OmniMotion.normal),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.xs),
              child: LayoutBuilder(builder: _buildHeader),
            ),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  OmniSpacing.md,
                  0,
                  OmniSpacing.md,
                  OmniSpacing.xs,
                ),
                child: Text(
                  subtitle!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colors.muted),
                ),
              ),
            Expanded(
              child: AbsorbPointer(absorbing: loading, child: child),
            ),
          ],
        ),
      ),
    );
  }

  /// 测量真实文字宽度，使加载状态和大字号都不移动或挤掉标题。
  Widget _buildHeader(BuildContext context, BoxConstraints constraints) {
    // 当前按钮与标题采用的文字样式。
    final ThemeData theme = Theme.of(context);
    // 两侧操作预留加载图标的宽度，常态和加载态布局一致。
    final double actionWidth =
        math.max(
          _textWidth(
            context,
            '取消',
            theme.textTheme.labelLarge?.copyWith(fontSize: 14),
          ),
          _textWidth(
            context,
            primaryLabel,
            theme.textTheme.labelLarge?.copyWith(fontSize: 14),
          ),
        ) +
        OmniSpacing.md * 2 +
        OmniSpacing.xs +
        OmniSize.icon;
    // 标题空间不足时改为两行结构，不截断业务名称。
    final bool stacked =
        constraints.maxWidth <
        actionWidth * 2 +
            _textWidth(context, title, theme.textTheme.titleLarge) +
            OmniSpacing.xs;
    // 标题具有路由身份及标题语义。
    final Widget heading = Semantics(
      namesRoute: true,
      header: true,
      child: Text(
        title,
        textAlign: TextAlign.center,
        style: theme.textTheme.titleLarge,
      ),
    );
    // 取消沿用轻量文字按钮与移动端触控热区。
    final Widget cancel = OmniButton(
      label: '取消',
      variant: OmniButtonVariant.text,
      visualHeight: OmniSize.control,
      onPressed: loading ? null : onCancel,
    );
    // 浅主题色适度加深以保证白字可读，色相仍来自当前配色。
    final Color primary = _whiteReadableFill(theme.colorScheme.primary);
    // 白字要求只作用于此处主操作，不改变其他控件主题。
    final Widget submit = Theme(
      data: theme.copyWith(
        colorScheme: theme.colorScheme.copyWith(
          primary: primary,
          onPrimary: Colors.white,
        ),
      ),
      child: OmniButton(
        key: primaryKey,
        label: primaryLabel,
        variant: OmniButtonVariant.primary,
        visualHeight: OmniSize.control,
        loading: loading,
        onPressed: loading ? null : onPrimary,
      ),
    );
    if (stacked) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: OmniSpacing.xs),
            child: heading,
          ),
          Row(children: <Widget>[cancel, const Spacer(), submit]),
        ],
      );
    }
    return Row(
      children: <Widget>[
        SizedBox(
          width: actionWidth,
          child: Align(alignment: Alignment.centerLeft, child: cancel),
        ),
        Expanded(child: heading),
        SizedBox(
          width: actionWidth,
          child: Align(alignment: Alignment.centerRight, child: submit),
        ),
      ],
    );
  }

  /// 按当前文字缩放测量单行内容。
  double _textWidth(BuildContext context, String text, TextStyle? style) {
    // 测量器仅用于本次布局，完成后立即释放。
    final TextPainter painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: Directionality.of(context),
    )..layout();
    // 取整预留亚像素边缘空间。
    final double width = painter.width.ceilToDouble();
    painter.dispose();
    return width;
  }

  /// 保留品牌色相并保障主操作的白色正文对比度。
  Color _whiteReadableFill(Color fill) {
    // 达到普通文字对比度时沿用主题原色。
    if (1.05 / (fill.computeLuminance() + 0.05) >= 4.6) return fill;
    // 必要时逐步加深当前配色，避免浅品牌底色上白字不可读。
    for (int step = 1; step <= 20; step += 1) {
      // 当前候选背景色。
      final Color candidate = Color.lerp(fill, Colors.black, step / 20)!;
      if (1.05 / (candidate.computeLuminance() + 0.05) >= 4.6) return candidate;
    }
    return Colors.black;
  }
}

/// 实底圆角分组，行间统一使用主题分隔线。
class OmniFormGroup extends StatelessWidget {
  /// 按业务顺序排列的表单行。
  final List<Widget> children;

  /// 创建分组卡片。
  const OmniFormGroup({required this.children, super.key});

  /// 构建无阴影、无外框的共享表面。
  @override
  Widget build(BuildContext context) {
    return Material(
      color: OmniColors.of(context).paper,
      borderRadius: BorderRadius.circular(OmniRadius.panel),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // 分隔仅位于实际显示的业务行之间。
            for (
              int index = 0;
              index < children.length;
              index += 1
            ) ...<Widget>[
              if (index > 0) const Divider(height: 1),
              children[index],
            ],
          ],
        ),
      ),
    );
  }
}

/// 外置标签的表单行，窄屏和大字号下改为上下布局。
class OmniFormRow extends StatelessWidget {
  /// 字段所属的完整标签。
  final String label;

  /// 原生表单字段或日期、开关等共享控件。
  final Widget child;

  /// 创建自适应表单行。
  const OmniFormRow({required this.label, required this.child, super.key});

  /// 在空间不足时保留标签和输入的完整可读宽度。
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 窄屏及放大文字时使用单列，避免两个输入框相互挤压。
        final bool stacked =
            constraints.maxWidth < 300 ||
            MediaQuery.textScalerOf(context).scale(14) > 21;
        // 字段名称沿用正文文字与主题颜色。
        final Widget heading = Text(
          label,
          style: Theme.of(context).textTheme.bodyMedium,
        );
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: OmniSpacing.xxs),
          child: stacked
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.only(top: OmniSpacing.xs),
                      child: heading,
                    ),
                    child,
                  ],
                )
              : Row(
                  children: <Widget>[
                    SizedBox(width: OmniSpacing.xxl * 3, child: heading),
                    const SizedBox(width: OmniSpacing.sm),
                    Expanded(child: child),
                  ],
                ),
        );
      },
    );
  }
}

/// 默认折叠的补充信息，保留字段状态与 Form 校验注册。
class OmniFormSupplement extends StatelessWidget {
  /// 是否展示可选字段。
  final bool expanded;

  /// 由业务持有展开状态，提交期间为空。
  final VoidCallback? onToggle;

  /// 可选字段的完整子树。
  final Widget child;

  /// 创建补充信息分组。
  const OmniFormSupplement({
    required this.expanded,
    required this.onToggle,
    required this.child,
    super.key,
  });

  /// 收起仅隐藏呈现，不清空输入或卸载校验字段。
  @override
  Widget build(BuildContext context) {
    return OmniFormGroup(
      children: <Widget>[
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Semantics(
              expanded: expanded,
              child: OmniButton(
                label: expanded ? '收起补充信息' : '补充信息（可选）',
                icon: expanded
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded,
                variant: OmniButtonVariant.text,
                onPressed: onToggle == null
                    ? null
                    : () {
                        FocusScope.of(context).unfocus();
                        onToggle!();
                      },
              ),
            ),
            if (expanded) const Divider(height: 1),
            Visibility(visible: expanded, maintainState: true, child: child),
          ],
        ),
      ],
    );
  }
}

/// 校验包括折叠字段在内的完整 Form，并返回需要定位的错误字段。
Set<FormFieldState<Object?>> omniValidateForm(GlobalKey<FormState> formKey) {
  return formKey.currentState!.validateGranularly();
}

/// 待错误区域展开和布局完成后，将首个错误滚入可见范围。
void omniRevealFirstError(Set<FormFieldState<Object?>> errors) {
  if (errors.isEmpty) return;
  // Form 按注册顺序返回错误，通常对应用户从上到下的输入顺序。
  final FormFieldState<Object?> field = errors.first;
  WidgetsBinding.instance.addPostFrameCallback((Duration timestamp) {
    if (!field.mounted) return;
    Scrollable.ensureVisible(field.context, alignment: 0.1);
  });
}
