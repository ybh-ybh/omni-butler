import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_chrome_colors.dart';
import 'package:omni_butler/app/theme/app_theme_palette.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

/// Omni Butler 扩展语义色。
@immutable
class OmniColors extends ThemeExtension<OmniColors> {
  /// 品牌主色。
  final Color brand;

  /// 品牌强调文字色。
  final Color brandStrong;

  /// 品牌柔和背景色。
  final Color brandSoft;

  /// 关键操作色。
  final Color accent;

  /// 关键操作前景色。
  final Color accentInk;

  /// 页面画布色。
  final Color canvas;

  /// 卡片表面色。
  final Color paper;

  /// 次级表面色。
  final Color paperSubtle;

  /// 主要文字色。
  final Color ink;

  /// 次要文字色。
  final Color muted;

  /// 边框色。
  final Color line;

  /// 弱背景色。
  final Color mist;

  /// 成功状态色。
  final Color success;

  /// 警告状态色。
  final Color warning;

  /// 危险状态色。
  final Color danger;

  /// 信息状态色。
  final Color info;

  /// 待办模块色。
  final Color todo;

  /// 事件模块色。
  final Color event;

  /// 物品模块色。
  final Color item;

  /// 时间模块色。
  final Color time;

  /// 会员模块色。
  final Color member;

  /// 名言横幅起始色。
  final Color heroStart;

  /// 名言横幅结束色。
  final Color heroEnd;

  /// 名言横幅文字色。
  final Color heroInk;

  /// 创建扩展语义色。
  const OmniColors({
    required this.brand,
    required this.brandStrong,
    required this.brandSoft,
    required this.accent,
    required this.accentInk,
    required this.canvas,
    required this.paper,
    required this.paperSubtle,
    required this.ink,
    required this.muted,
    required this.line,
    required this.mist,
    required this.success,
    required this.warning,
    required this.danger,
    required this.info,
    required this.todo,
    required this.event,
    required this.item,
    required this.time,
    required this.member,
    required this.heroStart,
    required this.heroEnd,
    required this.heroInk,
  });

  /// 从当前主题读取扩展语义色。
  static OmniColors of(BuildContext context) {
    // 当前主题中的扩展语义色。
    final OmniColors? colors = Theme.of(context).extension<OmniColors>();
    assert(colors != null, 'OmniColors 必须注册到 ThemeData');
    return colors!;
  }

  /// 复制并替换扩展语义色。
  @override
  OmniColors copyWith({
    Color? brand,
    Color? brandStrong,
    Color? brandSoft,
    Color? accent,
    Color? accentInk,
    Color? canvas,
    Color? paper,
    Color? paperSubtle,
    Color? ink,
    Color? muted,
    Color? line,
    Color? mist,
    Color? success,
    Color? warning,
    Color? danger,
    Color? info,
    Color? todo,
    Color? event,
    Color? item,
    Color? time,
    Color? member,
    Color? heroStart,
    Color? heroEnd,
    Color? heroInk,
  }) {
    return OmniColors(
      brand: brand ?? this.brand,
      brandStrong: brandStrong ?? this.brandStrong,
      brandSoft: brandSoft ?? this.brandSoft,
      accent: accent ?? this.accent,
      accentInk: accentInk ?? this.accentInk,
      canvas: canvas ?? this.canvas,
      paper: paper ?? this.paper,
      paperSubtle: paperSubtle ?? this.paperSubtle,
      ink: ink ?? this.ink,
      muted: muted ?? this.muted,
      line: line ?? this.line,
      mist: mist ?? this.mist,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
      info: info ?? this.info,
      todo: todo ?? this.todo,
      event: event ?? this.event,
      item: item ?? this.item,
      time: time ?? this.time,
      member: member ?? this.member,
      heroStart: heroStart ?? this.heroStart,
      heroEnd: heroEnd ?? this.heroEnd,
      heroInk: heroInk ?? this.heroInk,
    );
  }

  /// 在两套扩展语义色之间插值。
  @override
  OmniColors lerp(covariant OmniColors? other, double t) {
    if (other == null) {
      return this;
    }
    return OmniColors(
      brand: Color.lerp(brand, other.brand, t)!,
      brandStrong: Color.lerp(brandStrong, other.brandStrong, t)!,
      brandSoft: Color.lerp(brandSoft, other.brandSoft, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentInk: Color.lerp(accentInk, other.accentInk, t)!,
      canvas: Color.lerp(canvas, other.canvas, t)!,
      paper: Color.lerp(paper, other.paper, t)!,
      paperSubtle: Color.lerp(paperSubtle, other.paperSubtle, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      line: Color.lerp(line, other.line, t)!,
      mist: Color.lerp(mist, other.mist, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      info: Color.lerp(info, other.info, t)!,
      todo: Color.lerp(todo, other.todo, t)!,
      event: Color.lerp(event, other.event, t)!,
      item: Color.lerp(item, other.item, t)!,
      time: Color.lerp(time, other.time, t)!,
      member: Color.lerp(member, other.member, t)!,
      heroStart: Color.lerp(heroStart, other.heroStart, t)!,
      heroEnd: Color.lerp(heroEnd, other.heroEnd, t)!,
      heroInk: Color.lerp(heroInk, other.heroInk, t)!,
    );
  }
}

/// 应用主题工厂。
abstract final class AppTheme {
  /// 根据设备配色和明暗模式构建共享的克制主题。
  static ThemeData build({
    required Brightness brightness,
    AppThemePalette palette = AppThemePalette.classicBlue,
  }) {
    // 当前明暗模式的扩展语义色。
    final OmniColors colors = _colorsFor(brightness, palette);
    // Windows 使用选定主题的导航底色，其余平台与经典蓝保留既有外观。
    final OmniChromeColors chromeColors =
        defaultTargetPlatform == TargetPlatform.windows &&
            palette != AppThemePalette.classicBlue
        ? OmniChromeColors.fromBackground(palette.previewColorFor(brightness))
        : OmniChromeColors(
            background: colors.paper,
            foreground: colors.ink,
            muted: colors.muted,
            selectedBackground: colors.brandSoft,
            selectedForeground: colors.brand,
            border: colors.line,
          );
    // Material 语义色方案。
    final ColorScheme scheme =
        (palette == AppThemePalette.classicBlue
                ? ColorScheme.fromSeed(
                    seedColor: colors.brand,
                    brightness: brightness,
                  )
                : palette.colorScheme(brightness))
            .copyWith(
              primary: _readableFill(colors.brand, colors.accentInk),
              onPrimary: colors.accentInk,
              primaryContainer: colors.brandSoft,
              onPrimaryContainer: colors.brandStrong,
              secondary: colors.accent,
              onSecondary: colors.accentInk,
              surface: colors.paper,
              onSurface: colors.ink,
              onSurfaceVariant: colors.muted,
              outline: colors.line,
              outlineVariant: colors.mist,
              surfaceContainerHighest: colors.paperSubtle,
              error: _readableFill(colors.danger, Colors.white),
              onError: Colors.white,
            );
    // 控件统一圆角。
    final RoundedRectangleBorder controlShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(OmniRadius.control),
    );
    // 面板统一圆角。
    final RoundedRectangleBorder panelShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(OmniRadius.panel),
      side: BorderSide(color: colors.line),
    );
    // 输入框统一边框。
    final OutlineInputBorder inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(OmniRadius.control),
      borderSide: BorderSide(color: colors.line),
    );
    // 平台决定默认热区，窄桌面窗口仍保留桌面密度。
    final bool desktop = OmniBreakpoint.isDesktopPlatform(
      defaultTargetPlatform,
    );
    // 原生后备控件也使用相同的最小尺寸。
    final double controlHeight = desktop ? OmniSize.control : OmniSize.touch;
    // 所有基础控件共享标准触控或紧凑桌面密度。
    final VisualDensity density = desktop
        ? VisualDensity.compact
        : VisualDensity.standard;
    // 交互时向远离文字亮度的方向变化，保持深浅文字色对均可读。
    final Color primaryStateTint =
        scheme.onPrimary.computeLuminance() > scheme.primary.computeLuminance()
        ? Colors.black
        : Colors.white;

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: colors.canvas,
      canvasColor: colors.canvas,
      fontFamily: _fontFamily,
      fontFamilyFallback: _fontFamilyFallback,
      extensions: <ThemeExtension<dynamic>>[colors, chromeColors],
      textTheme: _textTheme(colors),
      dividerColor: colors.line,
      disabledColor: colors.muted.withValues(alpha: 0.45),
      hoverColor: colors.ink.withValues(alpha: 0.05),
      highlightColor: colors.brand.withValues(alpha: 0.08),
      focusColor: colors.brand.withValues(alpha: 0.16),
      splashFactory: NoSplash.splashFactory,
      visualDensity: density,
      materialTapTargetSize: desktop
          ? MaterialTapTargetSize.shrinkWrap
          : MaterialTapTargetSize.padded,
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll<double>(4),
        radius: const Radius.circular(999),
        thumbColor: WidgetStateProperty.resolveWith<Color?>((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.dragged)) {
            return colors.muted.withValues(alpha: 0.72);
          }
          if (states.contains(WidgetState.hovered)) {
            return colors.muted.withValues(alpha: 0.56);
          }
          return colors.muted.withValues(alpha: 0.38);
        }),
        trackVisibility: const WidgetStatePropertyAll<bool>(false),
        crossAxisMargin: 2,
        mainAxisMargin: 4,
        minThumbLength: 48,
        interactive: true,
      ),
      dividerTheme: DividerThemeData(
        color: colors.line,
        thickness: 1,
        space: 1,
      ),
      cardTheme: CardThemeData(
        color: colors.paper,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: panelShape,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        isDense: true,
        fillColor: WidgetStateColor.resolveWith((Set<WidgetState> states) {
          if (states.contains(WidgetState.disabled)) {
            return colors.paperSubtle;
          }
          return colors.paper;
        }),
        hoverColor: colors.brand.withValues(alpha: 0.03),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        border: inputBorder,
        enabledBorder: inputBorder,
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(OmniRadius.control),
          borderSide: BorderSide(color: colors.brand, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(OmniRadius.control),
          borderSide: BorderSide(color: colors.danger),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(OmniRadius.control),
          borderSide: BorderSide(color: colors.danger, width: 1.5),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(OmniRadius.control),
          borderSide: BorderSide(color: colors.mist),
        ),
        labelStyle: _textStyle(color: colors.muted, fontSize: 14),
        floatingLabelStyle: _textStyle(color: colors.brand, fontSize: 13),
        hintStyle: _textStyle(color: colors.muted, fontSize: 14),
        helperStyle: _textStyle(color: colors.muted, fontSize: 12),
        errorStyle: _textStyle(color: colors.danger, fontSize: 12),
        errorMaxLines: 3,
        prefixIconColor: colors.muted,
        suffixIconColor: colors.muted,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          visualDensity: VisualDensity.standard,
          minimumSize: WidgetStatePropertyAll<Size>(Size(0, controlHeight)),
          padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
            EdgeInsets.symmetric(horizontal: 16),
          ),
          backgroundColor: WidgetStateProperty.resolveWith<Color?>((
            Set<WidgetState> states,
          ) {
            if (states.contains(WidgetState.disabled)) {
              return colors.mist;
            }
            if (states.contains(WidgetState.pressed)) {
              return Color.alphaBlend(
                primaryStateTint.withValues(alpha: 0.14),
                scheme.primary,
              );
            }
            if (states.contains(WidgetState.hovered)) {
              return Color.alphaBlend(
                primaryStateTint.withValues(alpha: 0.06),
                scheme.primary,
              );
            }
            return scheme.primary;
          }),
          foregroundColor: WidgetStateProperty.resolveWith<Color?>(
            (Set<WidgetState> states) => states.contains(WidgetState.disabled)
                ? colors.muted
                : scheme.onPrimary,
          ),
          overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
          side: WidgetStateProperty.resolveWith<BorderSide>(
            (Set<WidgetState> states) => states.contains(WidgetState.focused)
                ? BorderSide(color: colors.ink.withValues(alpha: 0.7), width: 2)
                : const BorderSide(color: Colors.transparent),
          ),
          textStyle: WidgetStatePropertyAll<TextStyle>(
            _textStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          shape: WidgetStatePropertyAll<OutlinedBorder>(controlShape),
          elevation: const WidgetStatePropertyAll<double>(0),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          visualDensity: VisualDensity.standard,
          minimumSize: WidgetStatePropertyAll<Size>(Size(0, controlHeight)),
          padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
            EdgeInsets.symmetric(horizontal: 14),
          ),
          foregroundColor: WidgetStateProperty.resolveWith<Color?>(
            (Set<WidgetState> states) => states.contains(WidgetState.disabled)
                ? colors.muted
                : colors.ink,
          ),
          backgroundColor: WidgetStateProperty.resolveWith<Color?>((
            Set<WidgetState> states,
          ) {
            if (states.contains(WidgetState.pressed)) {
              return colors.mist;
            }
            if (states.contains(WidgetState.hovered)) {
              return colors.ink.withValues(alpha: 0.06);
            }
            return colors.paper;
          }),
          side: WidgetStateProperty.resolveWith<BorderSide?>(
            (Set<WidgetState> states) => BorderSide(
              color: states.contains(WidgetState.disabled)
                  ? colors.mist
                  : colors.line,
            ),
          ),
          textStyle: WidgetStatePropertyAll<TextStyle>(
            _textStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          shape: WidgetStatePropertyAll<OutlinedBorder>(controlShape),
          elevation: const WidgetStatePropertyAll<double>(0),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          visualDensity: VisualDensity.standard,
          minimumSize: WidgetStatePropertyAll<Size>(Size(0, controlHeight)),
          padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
            EdgeInsets.symmetric(horizontal: 10),
          ),
          foregroundColor: WidgetStateProperty.resolveWith<Color?>(
            (Set<WidgetState> states) => states.contains(WidgetState.disabled)
                ? colors.muted
                : colors.brand,
          ),
          backgroundColor: WidgetStateProperty.resolveWith<Color?>(
            (Set<WidgetState> states) => states.contains(WidgetState.hovered)
                ? colors.brandSoft
                : Colors.transparent,
          ),
          shape: WidgetStatePropertyAll<OutlinedBorder>(controlShape),
          textStyle: WidgetStatePropertyAll<TextStyle>(
            _textStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          visualDensity: VisualDensity.standard,
          minimumSize: WidgetStatePropertyAll<Size>(Size.square(controlHeight)),
          iconSize: const WidgetStatePropertyAll<double>(OmniSize.icon),
          foregroundColor: WidgetStateProperty.resolveWith<Color?>(
            (Set<WidgetState> states) => states.contains(WidgetState.disabled)
                ? colors.muted.withValues(alpha: 0.45)
                : colors.muted,
          ),
          backgroundColor: WidgetStateProperty.resolveWith<Color?>((
            Set<WidgetState> states,
          ) {
            if (states.contains(WidgetState.pressed)) {
              return colors.mist;
            }
            if (states.contains(WidgetState.hovered)) {
              return colors.ink.withValues(alpha: 0.08);
            }
            return Colors.transparent;
          }),
          shape: WidgetStatePropertyAll<OutlinedBorder>(controlShape),
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        visualDensity: density,
        checkColor: WidgetStateProperty.resolveWith<Color?>((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.disabled)) {
            return colors.muted.withValues(alpha: 0.45);
          }
          if (states.contains(WidgetState.error)) {
            return scheme.onError;
          }
          return colors.accentInk;
        }),
        side: WidgetStateBorderSide.resolveWith((Set<WidgetState> states) {
          if (states.contains(WidgetState.disabled)) {
            return BorderSide(
              color: states.contains(WidgetState.selected)
                  ? Colors.transparent
                  : colors.muted.withValues(alpha: 0.45),
              width: 1.5,
            );
          }
          if (states.contains(WidgetState.error)) {
            return BorderSide(color: scheme.error, width: 1.5);
          }
          return BorderSide(
            color: states.contains(WidgetState.selected)
                ? Colors.transparent
                : colors.muted,
            width: 1.5,
          );
        }),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(OmniRadius.tiny),
        ),
        fillColor: WidgetStateProperty.resolveWith<Color?>((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.disabled)) {
            return colors.mist;
          }
          if (states.contains(WidgetState.selected)) {
            return states.contains(WidgetState.error)
                ? scheme.error
                : colors.brand;
          }
          return Colors.transparent;
        }),
      ),
      radioTheme: RadioThemeData(
        visualDensity: density,
        fillColor: WidgetStateProperty.resolveWith<Color?>(
          (Set<WidgetState> states) => states.contains(WidgetState.disabled)
              ? colors.muted.withValues(alpha: 0.45)
              : colors.brand,
        ),
      ),
      switchTheme: SwitchThemeData(
        materialTapTargetSize: desktop
            ? MaterialTapTargetSize.shrinkWrap
            : MaterialTapTargetSize.padded,
        padding: EdgeInsets.zero,
        trackOutlineColor: const WidgetStatePropertyAll<Color>(
          Colors.transparent,
        ),
        overlayColor: WidgetStateProperty.resolveWith<Color?>((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.hovered)) {
            return Colors.transparent;
          }
          if (states.contains(WidgetState.focused)) {
            return colors.brand.withValues(alpha: 0.12);
          }
          return Colors.transparent;
        }),
        trackColor: WidgetStateProperty.resolveWith<Color?>((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.disabled)) {
            return colors.mist;
          }
          return states.contains(WidgetState.selected)
              ? colors.brand
              : colors.line;
        }),
        thumbColor: WidgetStateProperty.resolveWith<Color?>(
          (Set<WidgetState> states) => states.contains(WidgetState.disabled)
              ? colors.paperSubtle
              : Colors.white,
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: colors.paperSubtle,
        selectedColor: colors.brandSoft,
        disabledColor: colors.mist,
        labelStyle: _textStyle(
          color: colors.ink,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
        secondaryLabelStyle: _textStyle(
          color: colors.brandStrong,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
        side: BorderSide.none,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(OmniRadius.control),
        ),
      ),
      listTileTheme: ListTileThemeData(
        minTileHeight: desktop ? OmniSize.controlLarge : OmniSize.touch,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        iconColor: colors.muted,
        textColor: colors.ink,
        titleTextStyle: _textStyle(
          color: colors.ink,
          fontSize: 14,
          fontWeight: FontWeight.w400,
        ),
        subtitleTextStyle: _textStyle(
          color: colors.muted,
          fontSize: 12,
          height: 1.45,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(OmniRadius.control),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          visualDensity: VisualDensity.standard,
          minimumSize: WidgetStatePropertyAll<Size>(Size(0, controlHeight)),
          padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
            EdgeInsets.symmetric(horizontal: 12),
          ),
          backgroundColor: WidgetStateProperty.resolveWith<Color?>(
            (Set<WidgetState> states) => states.contains(WidgetState.selected)
                ? colors.brandSoft
                : colors.paper,
          ),
          foregroundColor: WidgetStateProperty.resolveWith<Color?>(
            (Set<WidgetState> states) => states.contains(WidgetState.selected)
                ? colors.brandStrong
                : colors.muted,
          ),
          side: WidgetStatePropertyAll<BorderSide>(
            BorderSide(color: colors.line),
          ),
          shape: WidgetStatePropertyAll<OutlinedBorder>(controlShape),
          textStyle: WidgetStatePropertyAll<TextStyle>(
            _textStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: colors.brand,
        inactiveTrackColor: colors.mist,
        thumbColor: colors.brand,
        overlayColor: colors.brand.withValues(alpha: 0.12),
        disabledActiveTrackColor: colors.line,
        disabledInactiveTrackColor: colors.mist,
        disabledThumbColor: colors.muted,
        valueIndicatorColor: colors.ink,
        valueIndicatorTextStyle: _textStyle(color: colors.paper, fontSize: 12),
        trackHeight: 4,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colors.brand,
        circularTrackColor: colors.mist,
        linearTrackColor: colors.mist,
        linearMinHeight: 4,
        borderRadius: BorderRadius.circular(OmniRadius.pill),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colors.paper,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.all(24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(OmniRadius.dialog),
          side: BorderSide(color: colors.line),
        ),
        titleTextStyle: _textStyle(
          color: colors.ink,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
        contentTextStyle: _textStyle(
          color: colors.ink,
          fontSize: 14,
          height: 1.5,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.paper,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: colors.paper,
        modalBarrierColor: Colors.black.withValues(alpha: 0.42),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(OmniRadius.dialog),
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: colors.paper,
        surfaceTintColor: Colors.transparent,
        elevation: 6,
        shadowColor: Colors.black.withValues(alpha: 0.12),
        menuPadding: const EdgeInsets.all(OmniSpacing.xxs),
        position: PopupMenuPosition.under,
        textStyle: _textStyle(
          color: colors.ink,
          fontSize: 14,
          fontWeight: FontWeight.w400,
        ),
        labelTextStyle: WidgetStateProperty.resolveWith<TextStyle?>((
          Set<WidgetState> states,
        ) {
          return _textStyle(
            color: states.contains(WidgetState.disabled)
                ? colors.muted.withValues(alpha: 0.45)
                : colors.ink,
            fontSize: 14,
            fontWeight: FontWeight.w400,
          );
        }),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(OmniRadius.panel),
          side: BorderSide(color: colors.line),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: colors.paper,
        minWidth: OmniSize.navigationRail,
        indicatorColor: colors.brandSoft,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(OmniRadius.control),
        ),
        selectedIconTheme: IconThemeData(
          color: colors.brand,
          size: OmniSize.navigationIcon,
        ),
        unselectedIconTheme: IconThemeData(
          color: colors.muted,
          size: OmniSize.navigationIcon,
        ),
        selectedLabelTextStyle: _textStyle(
          color: colors.brand,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelTextStyle: _textStyle(color: colors.muted, fontSize: 11),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 64,
        backgroundColor: colors.paper,
        surfaceTintColor: Colors.transparent,
        indicatorColor: colors.brandSoft,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(OmniRadius.control),
        ),
        iconTheme: WidgetStateProperty.resolveWith<IconThemeData?>(
          (Set<WidgetState> states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? colors.brand
                : colors.muted,
            size: OmniSize.navigationIcon,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith<TextStyle?>(
          (Set<WidgetState> states) => _textStyle(
            color: states.contains(WidgetState.selected)
                ? colors.brand
                : colors.muted,
            fontSize: 11,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
          ),
        ),
      ),
      searchBarTheme: SearchBarThemeData(
        backgroundColor: WidgetStatePropertyAll<Color>(colors.paperSubtle),
        surfaceTintColor: const WidgetStatePropertyAll<Color>(
          Colors.transparent,
        ),
        overlayColor: WidgetStateProperty.resolveWith<Color?>(
          (Set<WidgetState> states) => states.contains(WidgetState.hovered)
              ? colors.ink.withValues(alpha: 0.06)
              : Colors.transparent,
        ),
        elevation: const WidgetStatePropertyAll<double>(0),
        shape: WidgetStatePropertyAll<OutlinedBorder>(controlShape),
        side: WidgetStatePropertyAll<BorderSide>(
          BorderSide(color: colors.line),
        ),
        textStyle: WidgetStatePropertyAll<TextStyle>(
          _textStyle(color: colors.ink, fontSize: 14),
        ),
        hintStyle: WidgetStatePropertyAll<TextStyle>(
          _textStyle(color: colors.muted, fontSize: 14),
        ),
        padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
          EdgeInsets.symmetric(horizontal: 12),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: brightness == Brightness.dark
            ? const Color(0xFFF5F6F7)
            : const Color(0xFF1F2329),
        contentTextStyle: _textStyle(
          color: brightness == Brightness.dark
              ? const Color(0xFF1F2329)
              : const Color(0xFFFFFFFF),
          fontSize: 14,
        ),
        actionTextColor: palette == AppThemePalette.classicBlue
            ? (brightness == Brightness.dark
                  ? const Color(0xFF245BDB)
                  : const Color(0xFF82A7FC))
            : palette
                  .colorScheme(
                    brightness == Brightness.dark
                        ? Brightness.light
                        : Brightness.dark,
                  )
                  .primary,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(OmniRadius.panel),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 450),
        decoration: BoxDecoration(
          color: colors.ink,
          borderRadius: BorderRadius.circular(OmniRadius.control),
        ),
        textStyle: _textStyle(color: colors.canvas, fontSize: 12),
      ),
    );
  }

  /// 用最小亮度调整获得可读实色填色，品牌与业务状态语义色保持不变。
  static Color _readableFill(Color semanticColor, Color foreground) {
    // 比普通文字最低对比度略高，给颜色量化保留余量。
    const double contrastTarget = 4.6;
    // 当前文字亮度决定可读填色的调整方向。
    final double foregroundLuminance = foreground.computeLuminance();
    // 计算候选背景与固定文字的实际对比度。
    double contrastFor(Color background) {
      // 候选背景的线性亮度。
      final double backgroundLuminance = background.computeLuminance();
      return foregroundLuminance > backgroundLuminance
          ? (foregroundLuminance + 0.05) / (backgroundLuminance + 0.05)
          : (backgroundLuminance + 0.05) / (foregroundLuminance + 0.05);
    }

    if (contrastFor(semanticColor) >= contrastTarget) {
      return semanticColor;
    }
    // 非经典深色主题使用深色文字，必要时须提亮而非加深背景。
    final Color tint = contrastFor(Colors.black) > contrastFor(Colors.white)
        ? Colors.black
        : Colors.white;
    // 混合比例的不可读下界。
    double lower = 0;
    // 混合比例的可读上界。
    double upper = 1;
    // 二分逼近保留原有色相的最小调整量。
    for (int iteration = 0; iteration < 16; iteration += 1) {
      // 本轮候选混合比例。
      final double blend = (lower + upper) / 2;
      // 当前候选的实色背景。
      final Color candidate = Color.alphaBlend(
        tint.withValues(alpha: blend),
        semanticColor,
      );
      if (contrastFor(candidate) >= contrastTarget) {
        upper = blend;
      } else {
        lower = blend;
      }
    }
    return Color.alphaBlend(tint.withValues(alpha: upper), semanticColor);
  }

  /// 根据平台选择生产环境已有的系统字体。
  static String get _fontFamily => switch (defaultTargetPlatform) {
    TargetPlatform.windows => 'Microsoft YaHei UI',
    TargetPlatform.iOS || TargetPlatform.macOS => '.SF UI Text',
    TargetPlatform.android ||
    TargetPlatform.linux ||
    TargetPlatform.fuchsia => 'Roboto',
  };

  /// 中文和表情使用系统回退字体，不依赖开发机上的测试字体资源。
  static List<String> get _fontFamilyFallback =>
      defaultTargetPlatform == TargetPlatform.windows
      ? const <String>['Microsoft YaHei', 'Segoe UI Emoji', 'sans-serif']
      : const <String>[
          'Noto Sans CJK SC',
          'Noto Sans SC',
          'PingFang SC',
          'Microsoft YaHei UI',
          'Microsoft YaHei',
          'Segoe UI Emoji',
          'sans-serif',
        ];

  /// 组件局部文字样式与正文共用字体，避免局部样式丢失中文字体回退。
  static TextStyle _textStyle({
    Color? color,
    double? fontSize,
    double? height,
    double? letterSpacing,
    FontWeight? fontWeight,
  }) {
    return TextStyle(
      fontFamily: _fontFamily,
      fontFamilyFallback: _fontFamilyFallback,
      color: color,
      fontSize: fontSize,
      height: height,
      letterSpacing: letterSpacing,
      fontWeight: fontWeight,
    );
  }

  /// 构建界面文字层级。
  static TextTheme _textTheme(OmniColors colors) {
    return TextTheme(
      displaySmall: _textStyle(
        color: colors.ink,
        fontSize: 24,
        height: 1.3,
        letterSpacing: -0.4,
        fontWeight: FontWeight.w600,
      ),
      headlineLarge: _textStyle(
        color: colors.ink,
        fontSize: 22,
        height: 1.3,
        letterSpacing: -0.3,
        fontWeight: FontWeight.w600,
      ),
      headlineMedium: _textStyle(
        color: colors.ink,
        fontSize: 20,
        height: 1.35,
        letterSpacing: -0.2,
        fontWeight: FontWeight.w600,
      ),
      headlineSmall: _textStyle(
        color: colors.ink,
        fontSize: 18,
        height: 1.4,
        fontWeight: FontWeight.w600,
      ),
      titleLarge: _textStyle(
        color: colors.ink,
        fontSize: 18,
        height: 1.4,
        fontWeight: FontWeight.w600,
      ),
      titleMedium: _textStyle(
        color: colors.ink,
        fontSize: 16,
        height: 1.5,
        fontWeight: FontWeight.w600,
      ),
      titleSmall: _textStyle(
        color: colors.ink,
        fontSize: 14,
        height: 1.5,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: _textStyle(color: colors.ink, fontSize: 16, height: 1.5),
      bodyMedium: _textStyle(color: colors.ink, fontSize: 14, height: 1.55),
      bodySmall: _textStyle(color: colors.muted, fontSize: 12, height: 1.5),
      labelLarge: _textStyle(
        color: colors.ink,
        fontSize: 14,
        fontWeight: FontWeight.w500,
      ),
      labelMedium: _textStyle(
        color: colors.ink,
        fontSize: 12,
        fontWeight: FontWeight.w400,
      ),
      labelSmall: _textStyle(
        color: colors.muted,
        fontSize: 11,
        letterSpacing: 0.1,
      ),
    );
  }

  /// 生成配色对应的表面、品牌和横幅色，保留业务状态与模块颜色。
  static OmniColors _colorsFor(Brightness brightness, AppThemePalette palette) {
    // 当前是否使用暗色模式。
    final bool isDark = brightness == Brightness.dark;
    // 原有语义色作为业务状态与兼容默认值。
    final OmniColors base = isDark ? _feishuDark : _feishuLight;
    if (palette == AppThemePalette.classicBlue) return base;
    // 当前配色的 Material 明暗色对。
    final ColorScheme scheme = palette.colorScheme(brightness);
    return base.copyWith(
      brand: scheme.primary,
      brandStrong: scheme.onPrimaryContainer,
      brandSoft: scheme.primaryContainer,
      accent: scheme.primary,
      accentInk: scheme.onPrimary,
      canvas: scheme.surfaceContainerLow,
      paper: scheme.surface,
      paperSubtle: scheme.surfaceContainer,
      ink: scheme.onSurface,
      muted: scheme.onSurfaceVariant,
      line: scheme.outlineVariant,
      mist: scheme.surfaceContainerHighest,
      heroStart: scheme.primaryContainer,
      heroEnd: scheme.secondaryContainer,
      heroInk: scheme.onPrimaryContainer,
    );
  }

  /// 经典蓝浅色语义色，保留品牌和业务状态颜色。
  static const OmniColors _feishuLight = OmniColors(
    brand: Color(0xFF3370FF),
    brandStrong: Color(0xFF245BDB),
    brandSoft: Color(0xFFEAF0FF),
    accent: Color(0xFF3370FF),
    accentInk: Color(0xFFFFFFFF),
    canvas: Color(0xFFF5F6F7),
    paper: Color(0xFFFFFFFF),
    paperSubtle: Color(0xFFF5F6F7),
    ink: Color(0xFF1F2329),
    muted: Color(0xFF646A73),
    line: Color(0xFFDEE0E3),
    mist: Color(0xFFEFF0F1),
    success: Color(0xFF2EA121),
    warning: Color(0xFFD97904),
    danger: Color(0xFFE94444),
    info: Color(0xFF3370FF),
    todo: Color(0xFF7B67EE),
    event: Color(0xFFF54A45),
    item: Color(0xFF1EA7A1),
    time: Color(0xFF3370FF),
    member: Color(0xFF8E5CD9),
    heroStart: Color(0xFF245BDB),
    heroEnd: Color(0xFF5B8FF9),
    heroInk: Color(0xFFFFFFFF),
  );

  /// 经典蓝深色语义色，保留品牌和业务状态颜色。
  static const OmniColors _feishuDark = OmniColors(
    brand: Color(0xFF4C88FF),
    brandStrong: Color(0xFF82A7FC),
    brandSoft: Color(0xFF20345D),
    accent: Color(0xFF4C88FF),
    accentInk: Color(0xFFFFFFFF),
    canvas: Color(0xFF17181A),
    paper: Color(0xFF242529),
    paperSubtle: Color(0xFF2B2D31),
    ink: Color(0xFFF5F6F7),
    muted: Color(0xFFA2A7B0),
    line: Color(0xFF3A3C43),
    mist: Color(0xFF303238),
    success: Color(0xFF5CC452),
    warning: Color(0xFFF0A020),
    danger: Color(0xFFFF6B68),
    info: Color(0xFF4C88FF),
    todo: Color(0xFFA597FF),
    event: Color(0xFFFF7D79),
    item: Color(0xFF52C9C3),
    time: Color(0xFF82A7FC),
    member: Color(0xFFB68AF2),
    heroStart: Color(0xFF1C3F78),
    heroEnd: Color(0xFF315D9A),
    heroInk: Color(0xFFF6F8FB),
  );
}
