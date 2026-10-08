import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/omni_butler_app.dart';
import 'package:omni_butler/app/router/app_router.dart';
import 'package:omni_butler/app/theme/app_chrome_colors.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_theme_palette.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/settings/presentation/theme_palette_selector.dart';
import 'package:omni_butler/shared/ui/omni_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证真实设置入口、配色预览、全局主题更新及键盘操作。
void main() {
  // 桌面、常见手机和窄屏手机的实际设置入口。
  for (final (TargetPlatform platform, Size size) in <(TargetPlatform, Size)>[
    (TargetPlatform.windows, const Size(1200, 820)),
    (TargetPlatform.windows, const Size(960, 820)),
    (TargetPlatform.android, const Size(390, 844)),
    (TargetPlatform.android, const Size(320, 720)),
  ]) {
    testWidgets('${platform.name} ${size.width} 设置切换主题且保持当前页面', (
      WidgetTester tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues(<String, Object>{
        'appearance.theme_mode': 'light',
      });
      // 测试用本机偏好。
      final SharedPreferences preferences =
          await SharedPreferences.getInstance();
      // 测试用内存数据库。
      final AppDatabase database = AppDatabase.forTesting(
        NativeDatabase.memory(),
      );
      // 完整应用共享的依赖容器。
      final ProviderContainer container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          appDatabaseProvider.overrideWithValue(database),
        ],
      );
      // 避免测试结束后的清理回调重复释放依赖。
      bool disposed = false;
      // 在框架验证调试状态之前卸载应用。
      Future<void> disposeApp() async {
        if (disposed) return;
        disposed = true;
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        await tester.pump(const Duration(milliseconds: 100));
        await database.close();
        debugDefaultTargetPlatformOverride = null;
      }

      addTearDown(disposeApp);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const OmniButlerApp(),
        ),
      );
      await tester.pumpAndSettle();
      container.read(appRouterProvider).go('/settings');
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          ValueKey<String>(
            platform == TargetPlatform.android
                ? 'android-settings-category-appearance'
                : 'settings-category-appearance',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('主题色'), findsOneWidget);
      expect(find.text('明暗模式'), findsOneWidget);
      if (platform == TargetPlatform.android) {
        expect(find.byType(ThemePaletteSelector), findsNothing);
        expect(_option(AppThemePalette.classicBlue), findsNothing);
        await _openPalettePicker(tester);
      }
      // 六个入口的触控区域足够大，并且仍然只有一个选中项名称。
      for (final AppThemePalette palette in AppThemePalette.values) {
        expect(_option(palette), findsOneWidget);
        expect(
          tester.getSize(_option(palette)).width,
          greaterThanOrEqualTo(44),
        );
        expect(
          tester.getSize(_option(palette)).height,
          greaterThanOrEqualTo(44),
        );
      }
      if (size.width < 400) {
        expect(
          tester.getTopLeft(_option(AppThemePalette.slate)).dy,
          greaterThan(
            tester.getTopLeft(_option(AppThemePalette.classicBlue)).dy,
          ),
        );
      }
      if (platform == TargetPlatform.android) {
        await tester.tap(find.byTooltip('关闭'));
        await tester.pumpAndSettle();
        expect(preferences.getString('appearance.theme_palette'), isNull);
      }
      // 每款主题都验证当前页面、选中状态、实际主题和存储联动。
      for (final AppThemePalette palette in AppThemePalette.values) {
        if (platform == TargetPlatform.android) {
          await _openPalettePicker(tester);
        }
        await tester.ensureVisible(_option(palette));
        await tester.tap(_option(palette));
        await tester.pumpAndSettle();
        expect(container.read(themeControllerProvider).palette, palette);
        expect(preferences.getString('appearance.theme_palette'), palette.id);
        expect(find.text(palette.label), findsOneWidget);
        expect(
          container
              .read(appRouterProvider)
              .routeInformationProvider
              .value
              .uri
              .path,
          '/settings',
        );
        // 读取设置内容实际继承的主题，避免只验证控制器。
        final BuildContext context = tester.element(
          platform == TargetPlatform.android
              ? find.byKey(const ValueKey<String>('theme-palette-entry'))
              : find.byType(ThemePaletteSelector),
        );
        expect(
          Theme.of(context).colorScheme.primary,
          AppTheme.build(
            brightness: Brightness.light,
            palette: palette,
          ).colorScheme.primary,
        );
        expect(tester.takeException(), isNull);
        if (platform == TargetPlatform.windows) {
          _expectNavigationColors(tester);
        }
      }
      await container
          .read(themeControllerProvider.notifier)
          .setThemeMode(ThemeMode.dark);
      await tester.pumpAndSettle();
      expect(
        container.read(themeControllerProvider).palette,
        AppThemePalette.slate,
      );
      expect(find.text('黛蓝'), findsOneWidget);
      if (platform == TargetPlatform.windows) {
        _expectNavigationColors(tester);
      }
      // 深色预览与用户给定截图中的五个实际色值对应。
      const List<Color> darkColors = <Color>[
        Color(0xFF050505),
        Color(0xFF2A333C),
        Color(0xFF2E3242),
        Color(0xFF30435F),
        Color(0xFF373E4C),
      ];
      if (platform == TargetPlatform.android) {
        await _openPalettePicker(tester);
      }
      // 跳过保留的经典蓝，按截图顺序逐项检查实际渲染色块。
      for (int index = 0; index < darkColors.length; index += 1) {
        expect(
          _swatch(tester, AppThemePalette.values[index + 1]),
          darkColors[index],
        );
      }
      if (platform == TargetPlatform.android) {
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
      }
      // 切回跟随系统，使用系统亮度而非仅判断 ThemeMode.dark。
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await container
          .read(themeControllerProvider.notifier)
          .setThemeMode(ThemeMode.system);
      await tester.pumpAndSettle();
      if (platform == TargetPlatform.android) {
        await _openPalettePicker(tester);
      }
      expect(_swatch(tester, AppThemePalette.sky), const Color(0xFFDCE6F7));
      if (platform == TargetPlatform.android) {
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
      }
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      if (platform == TargetPlatform.android) {
        await _openPalettePicker(tester);
      }
      expect(_swatch(tester, AppThemePalette.sky), const Color(0xFF2E3242));
      expect(
        container.read(themeControllerProvider).palette,
        AppThemePalette.slate,
      );
      expect(tester.takeException(), isNull);
      if (platform == TargetPlatform.android) {
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
      }
      await disposeApp();
    });
  }

  testWidgets('主题色可通过键盘选择且提供读屏选中语义', (WidgetTester tester) async {
    // 当前测试界面选中的主题。
    AppThemePalette selected = AppThemePalette.classicBlue;
    // 启用测试树的无障碍语义。
    final SemanticsHandle semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) =>
                ThemePaletteSelector(
                  value: selected,
                  onChanged: (AppThemePalette palette) =>
                      setState(() => selected = palette),
                ),
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, AppThemePalette.cloud);
    expect(
      tester.getSemantics(_option(AppThemePalette.cloud)),
      matchesSemantics(
        label: '云雾',
        isButton: true,
        hasSelectedState: true,
        isSelected: true,
        isInMutuallyExclusiveGroup: true,
        isFocusable: true,
        isFocused: true,
        hasFocusAction: true,
        hasTapAction: true,
      ),
    );
    semantics.dispose();
  });

  testWidgets('深色主题的危险按钮仍使用独立错误前景色', (WidgetTester tester) async {
    // 主按钮使用深色文字的非默认主题。
    final ThemeData theme = AppTheme.build(
      brightness: Brightness.dark,
      palette: AppThemePalette.sky,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: OmniButton(
            label: '删除',
            variant: OmniButtonVariant.danger,
            onPressed: () {},
          ),
        ),
      ),
    );
    expect(theme.colorScheme.onPrimary, isNot(theme.colorScheme.onError));
    // 危险按钮上实际绘制的文字。
    final RichText text = tester.widget<RichText>(
      find.descendant(
        of: find.byType(FilledButton),
        matching: find.byType(RichText),
      ),
    );
    expect(text.text.style?.color, theme.colorScheme.onError);
  });
}

/// 点击真实安卓入口打开配色弹窗，关闭后仍停留在外观设置。
Future<void> _openPalettePicker(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey<String>('theme-palette-entry')));
  await tester.pumpAndSettle();
  expect(
    find.byKey(const ValueKey<String>('theme-palette-picker')),
    findsOneWidget,
  );
}

/// 根据稳定标识定位主题选项。
Finder _option(AppThemePalette palette) =>
    find.byKey(ValueKey<String>('theme-palette-${palette.id}'));

/// 读取实际色块填充，排除外环装饰。
Color? _swatch(WidgetTester tester, AppThemePalette palette) {
  // 当前选项中的所有装饰盒。
  final Iterable<DecoratedBox> decorations = tester.widgetList<DecoratedBox>(
    find.descendant(of: _option(palette), matching: find.byType(DecoratedBox)),
  );
  return decorations
      .map((DecoratedBox box) => box.decoration)
      .whereType<BoxDecoration>()
      .singleWhere((BoxDecoration decoration) => decoration.color != null)
      .color;
}

/// 验证真实展开侧栏或导航轨已采用独立窗口配色，且选中项仍可读。
void _expectNavigationColors(WidgetTester tester) {
  // 页面实际继承的窗口/导航语义色。
  final OmniChromeColors chrome = OmniChromeColors.of(
    tester.element(find.byType(ThemePaletteSelector)),
  );
  // 当前宽度下实际呈现的侧栏或导航轨。
  final Finder navigation = find.byWidgetPredicate(
    (Widget widget) =>
        widget.key == const ValueKey<String>('expanded-sidebar') ||
        widget.key == const ValueKey<String>('medium-navigation'),
  );
  expect(
    (tester.widget<Container>(navigation).decoration! as BoxDecoration).color,
    chrome.background,
  );
  // 设置入口在两种导航布局下均保持选中。
  final Finder selected = find.byKey(
    const ValueKey<String>('navigation-/settings'),
  );
  // 设置入口实际绘制的图标颜色。
  final Icon icon = tester.widget<Icon>(
    find.descendant(of: selected, matching: find.byType(Icon)),
  );
  expect(icon.color, chrome.selectedForeground);
  if (find
      .byKey(const ValueKey<String>('expanded-sidebar'))
      .evaluate()
      .isNotEmpty) {
    expect(tester.widget<Material>(selected).color, chrome.selectedBackground);
    expect(
      tester.widget<Text>(find.text('Omni Butler')).style?.color,
      chrome.foreground,
    );
  }
}
