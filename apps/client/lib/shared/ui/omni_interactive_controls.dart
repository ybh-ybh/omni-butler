import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

import 'omni_press_feedback.dart';

/// 保留原生列表布局，Windows 的整行背景与内容按压分离。
class OmniListTile extends ListTile {
  /// 创建兼容现有列表参数的点击行。
  const OmniListTile({
    super.key,
    super.leading,
    super.title,
    super.subtitle,
    super.trailing,
    super.isThreeLine,
    super.dense,
    super.visualDensity,
    super.shape,
    super.style,
    super.selectedColor,
    super.iconColor,
    super.textColor,
    super.titleTextStyle,
    super.subtitleTextStyle,
    super.leadingAndTrailingTextStyle,
    super.contentPadding,
    super.enabled,
    super.onTap,
    super.onLongPress,
    super.onFocusChange,
    super.mouseCursor,
    super.selected,
    super.focusColor,
    super.hoverColor,
    super.splashColor,
    super.focusNode,
    super.autofocus,
    super.tileColor,
    super.selectedTileColor,
    super.enableFeedback,
    super.horizontalTitleGap,
    super.minVerticalPadding,
    super.minLeadingWidth,
    super.minTileHeight,
    super.titleAlignment,
    super.internalAddSemanticForOnTap,
    super.statesController,
  });

  /// 仅 Windows 替换交互宿主；Android 继续原生实现。
  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).platform != TargetPlatform.windows) {
      return super.build(context);
    }
    // 行背景继续使用原生主题的选中与普通表面。
    final ListTileThemeData tileTheme = ListTileTheme.of(context);
    // 背景与内容共享原来的轮廓。
    final ShapeBorder? effectiveShape = shape ?? tileTheme.shape;
    return Material(
      color: selected
          ? selectedTileColor ??
                tileTheme.selectedTileColor ??
                Colors.transparent
          : tileColor ?? tileTheme.tileColor ?? Colors.transparent,
      shape: effectiveShape,
      child: OmniInkWell(
        onTap: enabled ? onTap : null,
        onLongPress: enabled ? onLongPress : null,
        onFocusChange: onFocusChange,
        mouseCursor: mouseCursor,
        focusNode: focusNode,
        autofocus: autofocus,
        canRequestFocus: enabled && (onTap != null || onLongPress != null),
        focusColor: focusColor,
        hoverColor: hoverColor,
        splashColor: splashColor,
        customBorder: effectiveShape,
        enableFeedback: enableFeedback ?? tileTheme.enableFeedback ?? true,
        statesController: statesController,
        child: ListTile(
          leading: leading,
          title: title,
          subtitle: subtitle,
          trailing: trailing,
          isThreeLine: isThreeLine,
          dense: dense,
          visualDensity: visualDensity,
          shape: const Border(),
          style: style,
          selectedColor: selectedColor,
          iconColor: iconColor,
          textColor: textColor,
          titleTextStyle: titleTextStyle,
          subtitleTextStyle: subtitleTextStyle,
          leadingAndTrailingTextStyle: leadingAndTrailingTextStyle,
          contentPadding: contentPadding,
          enabled: enabled,
          selected: selected,
          tileColor: Colors.transparent,
          selectedTileColor: Colors.transparent,
          horizontalTitleGap: horizontalTitleGap,
          minVerticalPadding: minVerticalPadding,
          minLeadingWidth: minLeadingWidth,
          minTileHeight: minTileHeight,
          titleAlignment: titleAlignment,
          internalAddSemanticForOnTap: internalAddSemanticForOnTap,
        ),
      ),
    );
  }
}

/// Windows 单选气泡使用唯一原生按钮，其他平台保留 ChoiceChip。
class OmniChoiceChip extends ChoiceChip {
  /// 创建保留选中状态、标签与外观参数的单选气泡。
  const OmniChoiceChip({
    super.key,
    super.avatar,
    required super.label,
    super.labelStyle,
    super.labelPadding,
    super.onSelected,
    super.pressElevation,
    required super.selected,
    super.selectedColor,
    super.disabledColor,
    super.tooltip,
    super.side,
    super.shape,
    super.clipBehavior,
    super.focusNode,
    super.autofocus,
    super.color,
    super.backgroundColor,
    super.padding,
    super.visualDensity,
    super.materialTapTargetSize,
    super.elevation,
    super.shadowColor,
    super.surfaceTintColor,
    super.iconTheme,
    super.selectedShadowColor,
    super.showCheckmark,
    super.checkmarkColor,
    super.avatarBorder,
    super.avatarBoxConstraints,
    super.chipAnimationStyle,
    super.mouseCursor,
  });

  /// 复用统一气泡按钮，保持原生选择回调含义。
  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).platform != TargetPlatform.windows) {
      return super.build(context);
    }
    return _OmniChipButton(
      chip: RawChip(
        label: label,
        avatar: avatar,
        labelStyle:
            labelStyle ??
            (selected ? ChipTheme.of(context).secondaryLabelStyle : null),
        labelPadding: labelPadding,
        onSelected: onSelected,
        selected: selected,
        isEnabled: onSelected != null,
        selectedColor:
            selectedColor ?? ChipTheme.of(context).secondarySelectedColor,
        disabledColor: disabledColor,
        tooltip: tooltip,
        side: side,
        shape: shape,
        clipBehavior: clipBehavior,
        focusNode: focusNode,
        autofocus: autofocus,
        color: color,
        backgroundColor: backgroundColor,
        padding: padding,
        visualDensity: visualDensity,
        materialTapTargetSize: materialTapTargetSize,
        elevation: elevation,
        shadowColor: shadowColor,
        surfaceTintColor: surfaceTintColor,
        iconTheme: iconTheme,
        selectedShadowColor: selectedShadowColor,
        showCheckmark: showCheckmark ?? true,
        checkmarkColor: checkmarkColor,
        avatarBorder: avatarBorder,
        avatarBoxConstraints: avatarBoxConstraints,
        chipAnimationStyle: chipAnimationStyle,
        mouseCursor: mouseCursor,
      ),
    );
  }
}

/// Windows 多选气泡与单选气泡共用内容按压，其他平台保留 FilterChip。
class OmniFilterChip extends FilterChip {
  /// 创建保留多选与删除操作的气泡。
  const OmniFilterChip({
    super.key,
    super.avatar,
    required super.label,
    super.labelStyle,
    super.labelPadding,
    super.selected,
    required super.onSelected,
    super.deleteIcon,
    super.onDeleted,
    super.deleteIconColor,
    super.deleteButtonTooltipMessage,
    super.pressElevation,
    super.disabledColor,
    super.selectedColor,
    super.tooltip,
    super.side,
    super.shape,
    super.clipBehavior,
    super.focusNode,
    super.autofocus,
    super.color,
    super.backgroundColor,
    super.padding,
    super.visualDensity,
    super.materialTapTargetSize,
    super.elevation,
    super.shadowColor,
    super.surfaceTintColor,
    super.iconTheme,
    super.selectedShadowColor,
    super.showCheckmark,
    super.checkmarkColor,
    super.avatarBorder,
    super.avatarBoxConstraints,
    super.deleteIconBoxConstraints,
    super.chipAnimationStyle,
    super.mouseCursor,
  });

  /// Windows 将标签和选中标识作为一个内容整体缩放。
  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).platform != TargetPlatform.windows) {
      return super.build(context);
    }
    return _OmniChipButton(
      chip: RawChip(
        label: label,
        avatar: avatar,
        labelStyle: labelStyle,
        labelPadding: labelPadding,
        onSelected: onSelected,
        selected: selected,
        isEnabled: onSelected != null,
        deleteIcon: deleteIcon,
        onDeleted: onDeleted,
        deleteIconColor: deleteIconColor,
        deleteButtonTooltipMessage: deleteButtonTooltipMessage,
        selectedColor: selectedColor,
        disabledColor: disabledColor,
        tooltip: tooltip,
        side: side,
        shape: shape,
        clipBehavior: clipBehavior,
        focusNode: focusNode,
        autofocus: autofocus,
        color: color,
        backgroundColor: backgroundColor,
        padding: padding,
        visualDensity: visualDensity,
        materialTapTargetSize: materialTapTargetSize,
        elevation: elevation,
        shadowColor: shadowColor,
        surfaceTintColor: surfaceTintColor,
        iconTheme: iconTheme,
        selectedShadowColor: selectedShadowColor,
        showCheckmark: showCheckmark ?? true,
        checkmarkColor: checkmarkColor,
        avatarBorder: avatarBorder,
        avatarBoxConstraints: avatarBoxConstraints,
        deleteIconBoxConstraints: deleteIconBoxConstraints,
        chipAnimationStyle: chipAnimationStyle,
        mouseCursor: mouseCursor,
      ),
    );
  }
}

/// 仅承担 Windows 气泡布局与原生按钮适配，不实现另一套手势。
class _OmniChipButton extends StatelessWidget {
  /// 从原生气泡参数保留的全部视觉与业务设置。
  final RawChip chip;

  /// 创建由统一绑定驱动的气泡内容。
  const _OmniChipButton({required this.chip});

  /// 保留气泡底色、圆角和密度，只有前景参与缩放。
  @override
  Widget build(BuildContext context) {
    // 当前气泡主题。
    final ChipThemeData theme = ChipTheme.of(context);
    // 标签文字沿用气泡而非普通按钮字号。
    final TextStyle labelStyle =
        (theme.labelStyle ?? Theme.of(context).textTheme.labelLarge!).merge(
          chip.labelStyle,
        );
    // 选中和禁用状态参与原来的颜色解析。
    final Set<WidgetState> baseStates = <WidgetState>{
      if (chip.selected) WidgetState.selected,
      if (!chip.isEnabled) WidgetState.disabled,
    };
    // 外围及标签内边距分别保留，避免筛选气泡宽度改变。
    final EdgeInsetsGeometry padding =
        chip.padding ?? theme.padding ?? const EdgeInsets.all(4);
    // M3 默认标签留白按默认14像素标签样式和系统字号缩减。
    final double defaultFontSize = Theme.of(context).useMaterial3
        ? Theme.of(context).textTheme.labelLarge?.fontSize ?? 14
        : labelStyle.fontSize ?? 14;
    // Flutter 的默认标签边距从8逐步缩到4，显式主题边距不缩放。
    final EdgeInsets defaultLabelPadding = EdgeInsets.lerp(
      const EdgeInsets.symmetric(horizontal: 8),
      const EdgeInsets.symmetric(horizontal: 4),
      (MediaQuery.textScalerOf(context).scale(defaultFontSize) / 14 - 1).clamp(
        0,
        1,
      ),
    )!;
    // 标签默认左右留白与 Material 气泡一致。
    final EdgeInsetsGeometry labelPadding =
        chip.labelPadding ?? theme.labelPadding ?? defaultLabelPadding;
    // 紧凑视觉高度继续由原密度决定。
    final VisualDensity density =
        chip.visualDensity ?? Theme.of(context).visualDensity;
    // 原生气泡的绘制宽度不受水平密度影响，仅额外热区使用水平密度。
    final EdgeInsets resolvedPadding = padding.resolve(
      Directionality.of(context),
    );
    // 原生气泡为头像和勾选标记保留完整内容列宽。
    final double avatarWidth =
        chip.avatarBoxConstraints?.hasBoundedWidth == true
        ? chip.avatarBoxConstraints!.maxWidth
        : (32 -
              resolvedPadding.vertical +
              labelPadding.resolve(Directionality.of(context)).vertical);
    // 气泡轮廓保持原值，不随按压变换。
    final OutlinedBorder shape =
        chip.shape ?? theme.shape ?? const StadiumBorder();

    /// 原生Chip的Ink会把描边尺寸加入内边距，按钮本身不会自动加入。
    BorderSide resolveSide(Set<WidgetState> states) =>
        WidgetStateProperty.resolveAs<BorderSide?>(
          chip.side ?? theme.side,
          <WidgetState>{...baseStates, ...states},
        ) ??
        shape.side;

    /// 描边厚度随选中或禁用状态解析，保持内容和原生Ink的起点一致。
    EdgeInsetsGeometry borderPadding(Set<WidgetState> states) =>
        shape.copyWith(side: resolveSide(states)).dimensions;

    // 图标颜色与标签保持一致。
    final IconThemeData iconTheme = (theme.iconTheme ?? const IconThemeData())
        .merge(chip.iconTheme);
    return OmniPressBinding(
      enabled: chip.isEnabled,
      builder: (context, feedback) {
        // 标签、头像与勾选标记共用一个缩放中心。
        final Widget content = IconTheme.merge(
          data: iconTheme,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (chip.selected && chip.showCheckmark == true)
                SizedBox(
                  width: avatarWidth,
                  child: Icon(
                    Icons.check,
                    size: 18,
                    color: chip.checkmarkColor ?? theme.checkmarkColor,
                  ),
                )
              else if (chip.avatar != null)
                SizedBox(
                  width: avatarWidth,
                  child: Center(child: chip.avatar!),
                ),
              Flexible(
                child: Padding(padding: labelPadding, child: chip.label),
              ),
            ],
          ),
        );
        // 气泡选择使用原生按钮的焦点、键盘及读屏激活。
        final Widget button = TextButton(
          statesController: feedback.statesController,
          onPressed: chip.onSelected == null
              ? null
              : () {
                  feedback.activate();
                  chip.onSelected!(!chip.selected);
                },
          focusNode: chip.focusNode,
          autofocus: chip.autofocus,
          clipBehavior: chip.clipBehavior,
          style: ButtonStyle(
            foregroundBuilder: feedback.foregroundBuilder,
            minimumSize: WidgetStateProperty.resolveWith(
              (states) => Size(
                0,
                (32 +
                        labelPadding.vertical +
                        density.baseSizeAdjustment.dy / 2 +
                        borderPadding(states).vertical)
                    .clamp(0, double.infinity),
              ),
            ),
            padding: WidgetStateProperty.resolveWith(
              (states) => resolvedPadding.add(borderPadding(states)),
            ),
            visualDensity: VisualDensity.standard,
            tapTargetSize:
                chip.materialTapTargetSize ?? MaterialTapTargetSize.shrinkWrap,
            textStyle: WidgetStatePropertyAll(labelStyle),
            foregroundColor: WidgetStatePropertyAll(labelStyle.color),
            shape: WidgetStatePropertyAll(shape),
            side: WidgetStateProperty.resolveWith(resolveSide),
            backgroundColor: WidgetStateProperty.resolveWith(
              (states) =>
                  (chip.color ?? theme.color)?.resolve(<WidgetState>{
                    ...baseStates,
                    ...states,
                  }) ??
                  (!chip.isEnabled
                      ? chip.disabledColor ?? theme.disabledColor
                      : chip.selected
                      ? chip.selectedColor ?? theme.selectedColor
                      : chip.backgroundColor ?? theme.backgroundColor),
            ),
            mouseCursor: WidgetStatePropertyAll(
              chip.mouseCursor ??
                  (chip.isEnabled
                      ? SystemMouseCursors.click
                      : SystemMouseCursors.basic),
            ),
            animationDuration: OmniMotion.duration(context, OmniMotion.fast),
          ),
          child: content,
        );
        // 删除是独立按钮，避免同时选择气泡或压缩整项。
        final Widget actions = chip.onDeleted == null
            ? button
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  button,
                  OmniPressBinding(
                    builder: (context, deletion) => IconButton(
                      statesController: deletion.statesController,
                      style: ButtonStyle(
                        foregroundBuilder: deletion.foregroundBuilder,
                      ),
                      tooltip: chip.deleteButtonTooltipMessage,
                      icon: chip.deleteIcon,
                      color: chip.deleteIconColor,
                      onPressed: () {
                        deletion.activate();
                        chip.onDeleted!();
                      },
                    ),
                  ),
                ],
              );
        // 选中语义保留在原来的单个可操作节点上。
        final Widget semantic = Semantics(
          selected: chip.selected,
          child: actions,
        );
        return chip.tooltip == null
            ? semantic
            : Tooltip(message: chip.tooltip!, child: semantic);
      },
    );
  }
}
