import 'package:flutter/material.dart';
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
  /// 根据明暗模式构建统一的飞书式主题。
  static ThemeData build({required Brightness brightness}) {
    // 当前明暗模式的扩展语义色。
    final OmniColors colors = _colorsFor(brightness);
    // Material 语义色方案。
    final ColorScheme scheme =
        ColorScheme.fromSeed(
          seedColor: colors.brand,
          brightness: brightness,
        ).copyWith(
          primary: colors.brand,
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
          error: colors.danger,
          onError: colors.accentInk,
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

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: colors.canvas,
      canvasColor: colors.canvas,
      fontFamily: 'Inter',
      fontFamilyFallback: const <String>[
        'Segoe UI',
        'PingFang SC',
        'Microsoft YaHei UI',
        'Microsoft YaHei',
        'Noto Sans CJK SC',
        'Segoe UI Emoji',
        'sans-serif',
      ],
      extensions: <ThemeExtension<dynamic>>[colors],
      textTheme: _textTheme(colors),
      dividerColor: colors.line,
      disabledColor: colors.muted.withValues(alpha: 0.45),
      hoverColor: colors.ink.withValues(alpha: 0.08),
      highlightColor: colors.brand.withValues(alpha: 0.08),
      focusColor: colors.brand.withValues(alpha: 0.16),
      splashFactory: NoSplash.splashFactory,
      visualDensity: VisualDensity.compact,
      dividerTheme: DividerThemeData(
        color: colors.line,
        thickness: 1,
        space: 1,
      ),
      cardTheme: CardThemeData(
        color: colors.paper,
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
        labelStyle: TextStyle(color: colors.muted, fontSize: 14),
        floatingLabelStyle: TextStyle(color: colors.brand, fontSize: 13),
        hintStyle: TextStyle(color: colors.muted, fontSize: 14),
        helperStyle: TextStyle(color: colors.muted, fontSize: 12),
        errorStyle: TextStyle(color: colors.danger, fontSize: 12),
        prefixIconColor: colors.muted,
        suffixIconColor: colors.muted,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll<Size>(
            Size(0, OmniSize.control),
          ),
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
              return colors.brandStrong;
            }
            if (states.contains(WidgetState.hovered)) {
              return colors.brand.withValues(alpha: 0.88);
            }
            return colors.brand;
          }),
          foregroundColor: WidgetStateProperty.resolveWith<Color?>(
            (Set<WidgetState> states) => states.contains(WidgetState.disabled)
                ? colors.muted
                : colors.accentInk,
          ),
          textStyle: const WidgetStatePropertyAll<TextStyle>(
            TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          shape: WidgetStatePropertyAll<OutlinedBorder>(controlShape),
          elevation: const WidgetStatePropertyAll<double>(0),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll<Size>(
            Size(0, OmniSize.control),
          ),
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
          textStyle: const WidgetStatePropertyAll<TextStyle>(
            TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          shape: WidgetStatePropertyAll<OutlinedBorder>(controlShape),
          elevation: const WidgetStatePropertyAll<double>(0),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll<Size>(
            Size(0, OmniSize.control),
          ),
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
          textStyle: const WidgetStatePropertyAll<TextStyle>(
            TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll<Size>(
            Size.square(OmniSize.control),
          ),
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
        visualDensity: VisualDensity.compact,
        side: BorderSide(color: colors.muted),
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
            return colors.brand;
          }
          return Colors.transparent;
        }),
      ),
      radioTheme: RadioThemeData(
        visualDensity: VisualDensity.compact,
        fillColor: WidgetStateProperty.resolveWith<Color?>(
          (Set<WidgetState> states) => states.contains(WidgetState.disabled)
              ? colors.muted.withValues(alpha: 0.45)
              : colors.brand,
        ),
      ),
      switchTheme: SwitchThemeData(
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: EdgeInsets.zero,
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
              : colors.paper,
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: colors.paperSubtle,
        selectedColor: colors.brandSoft,
        disabledColor: colors.mist,
        labelStyle: TextStyle(color: colors.ink, fontSize: 12),
        secondaryLabelStyle: TextStyle(color: colors.brandStrong, fontSize: 12),
        side: BorderSide.none,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(OmniRadius.control),
        ),
      ),
      listTileTheme: ListTileThemeData(
        minTileHeight: 44,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        iconColor: colors.muted,
        textColor: colors.ink,
        titleTextStyle: TextStyle(
          color: colors.ink,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
        subtitleTextStyle: TextStyle(
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
          minimumSize: const WidgetStatePropertyAll<Size>(
            Size(0, OmniSize.control),
          ),
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
          textStyle: const WidgetStatePropertyAll<TextStyle>(
            TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
        ),
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
        titleTextStyle: TextStyle(
          color: colors.ink,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
        contentTextStyle: TextStyle(
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
        textStyle: TextStyle(
          color: colors.ink,
          fontSize: 14,
          fontWeight: FontWeight.w400,
        ),
        labelTextStyle: WidgetStateProperty.resolveWith<TextStyle?>((
          Set<WidgetState> states,
        ) {
          return TextStyle(
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
        selectedLabelTextStyle: TextStyle(
          color: colors.brand,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelTextStyle: TextStyle(color: colors.muted, fontSize: 11),
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
          (Set<WidgetState> states) => TextStyle(
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
          TextStyle(color: colors.ink, fontSize: 14),
        ),
        hintStyle: WidgetStatePropertyAll<TextStyle>(
          TextStyle(color: colors.muted, fontSize: 14),
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
        contentTextStyle: TextStyle(
          color: brightness == Brightness.dark
              ? const Color(0xFF1F2329)
              : const Color(0xFFFFFFFF),
          fontSize: 14,
        ),
        actionTextColor: brightness == Brightness.dark
            ? const Color(0xFF245BDB)
            : const Color(0xFF82A7FC),
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
        textStyle: TextStyle(color: colors.canvas, fontSize: 12),
      ),
    );
  }

  /// 构建界面文字层级。
  static TextTheme _textTheme(OmniColors colors) {
    return TextTheme(
      displaySmall: TextStyle(
        color: colors.ink,
        fontSize: 24,
        height: 1.35,
        fontWeight: FontWeight.w600,
      ),
      headlineLarge: TextStyle(
        color: colors.ink,
        fontSize: 22,
        height: 1.4,
        fontWeight: FontWeight.w600,
      ),
      headlineMedium: TextStyle(
        color: colors.ink,
        fontSize: 20,
        height: 1.4,
        fontWeight: FontWeight.w600,
      ),
      headlineSmall: TextStyle(
        color: colors.ink,
        fontSize: 18,
        height: 1.45,
        fontWeight: FontWeight.w600,
      ),
      titleLarge: TextStyle(
        color: colors.ink,
        fontSize: 18,
        height: 1.45,
        fontWeight: FontWeight.w600,
      ),
      titleMedium: TextStyle(
        color: colors.ink,
        fontSize: 16,
        height: 1.5,
        fontWeight: FontWeight.w600,
      ),
      titleSmall: TextStyle(
        color: colors.ink,
        fontSize: 14,
        height: 1.5,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: TextStyle(color: colors.ink, fontSize: 16, height: 1.5),
      bodyMedium: TextStyle(color: colors.ink, fontSize: 14, height: 1.55),
      bodySmall: TextStyle(color: colors.muted, fontSize: 12, height: 1.5),
      labelLarge: TextStyle(
        color: colors.ink,
        fontSize: 14,
        fontWeight: FontWeight.w500,
      ),
      labelMedium: TextStyle(
        color: colors.ink,
        fontSize: 12,
        fontWeight: FontWeight.w500,
      ),
      labelSmall: TextStyle(color: colors.muted, fontSize: 11),
    );
  }

  /// 返回指定明暗模式的扩展语义色。
  static OmniColors _colorsFor(Brightness brightness) {
    // 当前是否使用暗色模式。
    final bool isDark = brightness == Brightness.dark;
    return isDark ? _feishuDark : _feishuLight;
  }

  /// 飞书式浅色语义色。
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

  /// 飞书式深色语义色。
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
