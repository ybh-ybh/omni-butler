import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_theme_palette.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_providers.dart';
import 'package:omni_butler/core/sync/sync_connection_coordinator.dart';
import 'package:omni_butler/core/sync/sync_connection_providers.dart';
import 'package:omni_butler/features/settings/presentation/settings_page.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 固定测试会话，仅替换网络边界，不调用真实服务器。
class _LayoutAuthController extends AuthController {
  /// 当前场景的设备会话。
  final SyncSession? session;

  /// 创建固定会话控制器。
  _LayoutAuthController(this.session);

  /// 返回指定场景会话。
  @override
  Future<SyncSession?> build() async => session;
}

/// 仅提供布局依赖的协调器，不执行迁移与删除。
class _LayoutCoordinator implements SyncConnectionCoordinator {
  /// 当前维护状态始终为空闲。
  @override
  SyncConnectionState get state => const SyncConnectionState();

  /// 当前场景无后台状态变化。
  @override
  Stream<SyncConnectionState> get changes => const Stream.empty();

  /// 布局验证不得调用数据变更入口。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 当前设置页测试容器和真实渲染边界。
class _LayoutFixture {
  /// 页面使用的隔离依赖。
  final ProviderContainer container;

  /// 包含导航器与弹窗的截图边界。
  final GlobalKey captureKey;

  /// 创建设置页验证环境。
  _LayoutFixture(this.container, this.captureKey);

  /// 卸载所有页面并释放依赖。
  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.pump();
  }
}

/// 验证真实设置页的彩色入口、桌面卡片及各连接状态的操作层级。
void main() {
  // 可选中文预览输出，不改动任何既有视觉基线。
  final String? previewDirectory =
      Platform.environment['OMNI_SETTINGS_PREVIEW_DIR'];
  setUpAll(() async {
    if (previewDirectory == null) return;
    // 中文字体同时覆盖生产字体族和测试占位字体。
    final ByteData font = ByteData.sublistView(
      await File('C:/Windows/Fonts/msyh.ttc').readAsBytes(),
    );
    for (final String family in <String>[
      'Microsoft YaHei UI',
      'Microsoft YaHei',
      'Roboto',
      'Noto Sans CJK SC',
      'Ahem',
    ]) {
      // 当前待注册的字体族。
      final FontLoader loader = FontLoader(family)..addFont(Future.value(font));
      await loader.load();
    }
    // 使用真实 Material 图标检查入口颜色与对齐。
    final FontLoader icons = FontLoader('MaterialIcons')
      ..addFont(
        Future.value(
          ByteData.sublistView(
            await File(
              'D:/program/code/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
            ).readAsBytes(),
          ),
        ),
      );
    await icons.load();
    await Directory(previewDirectory).create(recursive: true);
  });

  for (final Brightness brightness in Brightness.values) {
    // 独立生产设置页验证手机弹窗及窄屏大字号，不受隐藏首页影响。
    for (final (double width, double scale) in <(double, double)>[
      (390, 1),
      (320, 2),
    ]) {
      testWidgets('安卓主题选择弹窗 $width/$scale ${brightness.name}', (
        WidgetTester tester,
      ) async {
        // 包含真实偏好与设置组件的测试宿主。
        final _LayoutFixture fixture = await _pumpSettings(
          tester,
          size: Size(width, 844),
          textScale: scale,
          brightness: brightness,
        );
        try {
          await tester.tap(_category(TargetPlatform.android, 'appearance'));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey<String>('theme-palette-classic_blue')),
            findsNothing,
          );
          await _capture(
            tester,
            fixture,
            previewDirectory,
            'android-appearance-${width.toInt()}-${brightness.name}',
          );
          await tester.tap(
            find.byKey(const ValueKey<String>('theme-palette-entry')),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey<String>('theme-palette-picker')),
            findsOneWidget,
          );
          for (final AppThemePalette palette in AppThemePalette.values) {
            expect(
              find.byKey(ValueKey<String>('theme-palette-${palette.id}')),
              findsOneWidget,
            );
          }
          expect(tester.takeException(), isNull);
          await _capture(
            tester,
            fixture,
            previewDirectory,
            'android-theme-picker-${width.toInt()}-${brightness.name}',
          );
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(
            fixture.container
                .read(sharedPreferencesProvider)
                .getString('appearance.theme_palette'),
            isNull,
          );
          await tester.tap(
            find.byKey(const ValueKey<String>('theme-palette-entry')),
          );
          await tester.pumpAndSettle();
          // 大字号可滚动到末项并实际保存，不只是检查控件存在。
          final Finder target = find.byKey(
            ValueKey<String>('theme-palette-${AppThemePalette.slate.id}'),
          );
          await tester.ensureVisible(target);
          await tester.tap(target);
          await tester.pumpAndSettle();
          expect(
            fixture.container
                .read(sharedPreferencesProvider)
                .getString('appearance.theme_palette'),
            AppThemePalette.slate.id,
          );
          expect(
            find.byKey(const ValueKey<String>('theme-palette-picker')),
            findsNothing,
          );
          expect(find.text(AppThemePalette.slate.label), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          await fixture.dispose(tester);
        }
      });
    }

    testWidgets('安卓六个设置入口具备不同颜色图标 ${brightness.name}', (
      WidgetTester tester,
    ) async {
      // 真实安卓分类页。
      final _LayoutFixture fixture = await _pumpSettings(
        tester,
        brightness: brightness,
      );
      try {
        // 各分类与业务图标的一一对应关系。
        const Map<String, IconData> icons = <String, IconData>{
          'home': Icons.dashboard_customize_outlined,
          'features': Icons.widgets_outlined,
          'appearance': Icons.palette_outlined,
          'notifications': Icons.notifications_outlined,
          'sync': Icons.cloud_sync_outlined,
          'storage': Icons.delete_outline_rounded,
        };
        // 去重后的入口图标色，避免随主题重建全部变为主题色。
        final Set<Color?> iconColors = <Color?>{};
        for (final MapEntry<String, IconData> entry in icons.entries) {
          // 当前入口及图标，箭头不计入颜色统计。
          final Finder row = _category(TargetPlatform.android, entry.key);
          final Finder icon = find.descendant(
            of: row,
            matching: find.byIcon(entry.value),
          );
          expect(icon, findsOneWidget);
          iconColors.add(tester.widget<Icon>(icon).color);
          expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
        }
        expect(iconColors.length, 6);
        expect(iconColors.contains(null), isFalse);
        expect(tester.takeException(), isNull);
        await _capture(
          tester,
          fixture,
          previewDirectory,
          'android-overview-${brightness.name}',
        );
        await tester.tap(_category(TargetPlatform.android, 'home'));
        await tester.pumpAndSettle();
        expect(find.textContaining(RegExp(r'^\d+$')), findsNothing);
        await _capture(
          tester,
          fixture,
          previewDirectory,
          'android-home-${brightness.name}',
        );
      } finally {
        await fixture.dispose(tester);
      }
    });

    testWidgets('Windows 首页设置完整卡片与真实拖动 ${brightness.name}', (
      WidgetTester tester,
    ) async {
      // 桌面使用真实设置页而非空态管理面板。
      final _LayoutFixture fixture = await _pumpSettings(
        tester,
        platform: TargetPlatform.windows,
        size: const Size(1200, 900),
        brightness: brightness,
      );
      try {
        await tester.tap(_category(TargetPlatform.windows, 'home'));
        await tester.pumpAndSettle();
        expect(find.textContaining('修改会立即保存到当前设备'), findsNothing);
        expect(
          find.byKey(const ValueKey<String>('home-settings-added-panel')),
          findsOneWidget,
        );
        expect(find.byType(ReorderableDragStartListener), findsNWidgets(5));
        await _capture(
          tester,
          fixture,
          previewDirectory,
          'windows-home-${brightness.name}',
        );
        // 在真实桌面分组卡片中拖动第一项，检查持久化结果。
        final Finder handle = find.byKey(
          const ValueKey<String>('home-card-reorder-每日名言-0'),
        );
        final Offset target = tester.getCenter(
          find.byKey(const ValueKey<String>('home-card-manager-timeStatus')),
        );
        final TestGesture gesture = await tester.startGesture(
          tester.getCenter(handle),
        );
        await tester.pump();
        await gesture.moveBy(const Offset(0, 24));
        await tester.pump();
        await gesture.moveTo(target);
        await tester.pump(const Duration(milliseconds: 400));
        await gesture.moveBy(const Offset(0, 12));
        await tester.pump(const Duration(milliseconds: 300));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(
          fixture.container
              .read(sharedPreferencesProvider)
              .getStringList('home.cards.order')!
              .first,
          isNot('quote'),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    });
  }

  // 桌面、手机及双倍字号窄屏分别覆盖所有连接状态。
  for (final (
        TargetPlatform platform,
        Size size,
        double scale,
        Brightness brightness,
      )
      in <(TargetPlatform, Size, double, Brightness)>[
        (TargetPlatform.windows, const Size(1200, 900), 1, Brightness.light),
        (TargetPlatform.windows, const Size(512, 800), 1, Brightness.light),
        (TargetPlatform.android, const Size(390, 844), 1, Brightness.light),
        (TargetPlatform.android, const Size(320, 900), 2, Brightness.light),
        (TargetPlatform.windows, const Size(1200, 900), 1, Brightness.dark),
        (TargetPlatform.android, const Size(390, 844), 1, Brightness.dark),
      ]) {
    for (final String state in <String>[
      'disabled',
      'unconnected',
      'connected',
      'offline',
    ]) {
      testWidgets(
        '${platform.name} ${size.width} ${brightness.name} 同步操作分组 $state',
        (WidgetTester tester) async {
          // 真实页面状态，网络与迁移入口替换为无副作用依赖。
          final _LayoutFixture fixture = await _pumpSettings(
            tester,
            platform: platform,
            size: size,
            textScale: scale,
            state: state,
            brightness: brightness,
          );
          try {
            // 窄桌面采用可滚动 ChoiceChip，安卓采用分类入口。
            final Finder category =
                platform == TargetPlatform.windows && size.width < 760
                ? find.widgetWithText(ChoiceChip, '数据同步')
                : _category(platform, 'sync');
            await tester.ensureVisible(category);
            await tester.tap(category);
            await tester.pumpAndSettle();
            expect(
              find.byKey(const ValueKey<String>('sync-backup-actions')),
              findsOneWidget,
            );
            expect(find.text('查看迁移备份'), findsOneWidget);
            expect(
              find.text('重试连接'),
              state == 'offline' ? findsOneWidget : findsNothing,
            );
            expect(
              find.text('连接服务器'),
              state == 'unconnected' ? findsOneWidget : findsNothing,
            );
            expect(
              find.text('更换服务器'),
              state == 'connected' || state == 'offline'
                  ? findsOneWidget
                  : findsNothing,
            );
            expect(
              find.text('断开服务器'),
              state == 'connected' || state == 'offline'
                  ? findsOneWidget
                  : findsNothing,
            );
            // 连接和备份操作位于独立区域，断开位于二者之后。
            if (state != 'disabled') {
              expect(
                tester
                    .getTopLeft(
                      find.byKey(const ValueKey<String>('sync-backup-actions')),
                    )
                    .dy,
                greaterThan(
                  tester
                      .getBottomLeft(
                        find.byKey(
                          const ValueKey<String>('sync-connection-actions'),
                        ),
                      )
                      .dy,
                ),
              );
            }
            if (state == 'connected' || state == 'offline') {
              expect(
                tester
                    .getTopLeft(
                      find.byKey(
                        const ValueKey<String>('sync-disconnect-panel'),
                      ),
                    )
                    .dy,
                greaterThan(
                  tester
                      .getBottomLeft(
                        find.byKey(
                          const ValueKey<String>('sync-backup-actions'),
                        ),
                      )
                      .dy,
                ),
              );
            }
            if (state == 'offline' && size.width < 760) {
              expect(
                tester.getTopLeft(find.text('更换服务器')).dy,
                greaterThan(tester.getTopLeft(find.text('重试连接')).dy),
              );
            }
            if (scale == 1) {
              // 视觉高度保持32px，安卓热区仍有48px。
              for (final Element element
                  in find.byType(OmniButton).evaluate()) {
                // 当前按钮及实际绘制的Material表面。
                final Finder button = find.byWidget(element.widget);
                final Finder surface = find
                    .descendant(of: button, matching: find.byType(Material))
                    .first;
                expect(tester.getSize(surface).height, 32);
                if (platform == TargetPlatform.android) {
                  expect(
                    tester.getSize(button).height,
                    greaterThanOrEqualTo(48),
                  );
                }
              }
              // 桌面操作在分组起点左对齐，不能收缩后居中。
              final Finder backup = find.byKey(
                const ValueKey<String>('sync-backup-actions'),
              );
              expect(
                tester.getTopLeft(find.widgetWithText(OmniButton, '查看迁移备份')).dx,
                closeTo(tester.getTopLeft(backup).dx, 0.1),
              );
            }
            expect(tester.takeException(), isNull);
            if (scale == 1 && size.width != 512) {
              // 保留既有浅色文件名，深色预览单独保存。
              final String suffix = brightness == Brightness.dark
                  ? '-dark'
                  : '';
              await _capture(
                tester,
                fixture,
                previewDirectory,
                '${platform.name}-sync-$state$suffix',
              );
              if (state == 'unconnected') {
                await tester.tap(find.text('连接服务器'));
                await tester.pumpAndSettle();
                await _capture(
                  tester,
                  fixture,
                  previewDirectory,
                  '${platform.name}-connection-form$suffix',
                );
                await tester.tap(find.text('取消'));
                await tester.pumpAndSettle();
                expect(tester.takeException(), isNull);
              }
            }
          } finally {
            await fixture.dispose(tester);
          }
        },
      );
    }
  }
}

/// 定位两端真实设置分类入口。
Finder _category(TargetPlatform platform, String category) => find.byKey(
  ValueKey<String>(
    platform == TargetPlatform.android
        ? category == 'home'
              ? 'android-settings-home'
              : 'android-settings-category-$category'
        : 'settings-category-$category',
  ),
);

/// 创建真实设置页，保留偏好存储、响应式布局及控件行为。
Future<_LayoutFixture> _pumpSettings(
  WidgetTester tester, {
  TargetPlatform platform = TargetPlatform.android,
  Size size = const Size(390, 844),
  Brightness brightness = Brightness.light,
  double textScale = 1,
  String state = 'disabled',
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues(<String, Object>{
    'sync.enabled': state != 'disabled',
  });
  // 本机偏好与模拟设备会话。
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  final SyncSession? session = state == 'connected' || state == 'offline'
      ? SyncSession(
          identity: const SyncIdentity(id: 'settings-preview-owner'),
          apiBaseUrl: 'https://sync.example.com/omni-butler/api/v1/',
          isOffline: state == 'offline',
        )
      : null;
  // 独立容器复用生产偏好与状态组合。
  final ProviderContainer container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      authControllerProvider.overrideWith(() => _LayoutAuthController(session)),
      syncConnectionCoordinatorProvider.overrideWithValue(_LayoutCoordinator()),
    ],
  );
  // 包含弹窗路由的完整截图边界。
  final GlobalKey captureKey = GlobalKey();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          theme: AppTheme.build(brightness: brightness)
              .copyWith(platform: platform),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const Scaffold(body: SettingsPage()),
          debugShowCheckedModeBanner: false,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _LayoutFixture(container, captureKey);
}

/// 保存真实界面渲染，预览功能默认关闭。
Future<void> _capture(
  WidgetTester tester,
  _LayoutFixture fixture,
  String? directory,
  String name,
) async {
  if (directory == null) return;
  // 当前设置页的真实绘制边界。
  final RenderRepaintBoundary boundary =
      fixture.captureKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
  await tester.runAsync(() async {
    // PNG 导出完成后释放图像。
    final ui.Image image = await boundary.toImage();
    try {
      // 完整编码的预览像素。
      final ByteData bytes = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!;
      await File('$directory/$name.png').writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
    } finally {
      image.dispose();
    }
  });
}
