import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/router/app_router.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/sync/sync_providers.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/features/events/data/event_repository.dart';
import 'package:omni_butler/features/inventory/data/inventory_repository.dart';
import 'package:omni_butler/features/inventory/presentation/inventory_page.dart';
import 'package:omni_butler/features/memberships/data/membership_repository.dart';
import 'package:omni_butler/features/timeline/data/time_entry_repository.dart';
import 'package:omni_butler/features/todos/data/todo_priority_quadrant.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:omni_butler/shared/taxonomy/taxonomy_manager_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 需要人工审查的全部一级业务路由。
const List<String> _previewRoutes = <String>[
  '/home',
  '/todos',
  '/timeline',
  '/events',
  '/inventory',
  '/memberships',
  '/settings',
];

/// 让业务状态和日期在重复生成截图时保持一致。
final DateTime _previewNow = DateTime(2026, 10, 6, 10, 30);

/// 输出带中文字体的真实业务预览，不参与常规 test 目录的测试或 golden。
///
/// 在 apps/client 运行 flutter test tool/ui_pages_preview_test.dart。
/// OMNI_UI_FONT 和 OMNI_UI_ICONS 可覆盖本机中文字体及 Material 图标路径。
/// 四组平台与明暗模式共输出 48 张图片到仓库 output/ui-pages-preview。
/// 所有业务数据仅保存在内存，不启动应用入口的同步、通知或悬浮窗服务。
void main() {
  setUpAll(() async {
    // 允许其他开发机显式指定包含中文字符的字体文件。
    final String fontPath =
        Platform.environment['OMNI_UI_FONT'] ?? 'C:/Windows/Fonts/msyh.ttc';
    // 图标字体使用 Flutter SDK 附带资源，也可通过环境变量替换路径。
    final String iconPath =
        Platform.environment['OMNI_UI_ICONS'] ??
        'D:/program/code/flutter/bin/cache/artifacts/material_fonts/'
            'materialicons-regular.otf';
    // 一次读取中文字体供 Windows、Android 及测试默认字体共用。
    final ByteData fontBytes = await _readFont(fontPath, 'OMNI_UI_FONT');
    // 显式覆盖测试默认 Ahem，避免局部样式中出现方框占位字形。
    for (final String family in <String>[
      'Microsoft YaHei UI',
      'Microsoft YaHei',
      'Roboto',
      'Noto Sans CJK SC',
      'Ahem',
    ]) {
      // 注册真实主题使用的字体族。
      final FontLoader loader = FontLoader(family);
      loader.addFont(Future<ByteData>.value(fontBytes));
      await loader.load();
    }
    // 注册真实图标字形，避免截图只剩空白图标热区。
    final FontLoader icons = FontLoader('MaterialIcons');
    icons.addFont(_readFont(iconPath, 'OMNI_UI_ICONS'));
    await icons.load();
    await Directory('../../output/ui-pages-preview').create(recursive: true);
  });

  // 每个测试拥有独立数据库、配置和路由状态。
  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.windows,
    TargetPlatform.android,
  ]) {
    // 两种明暗模式均使用生产主题及同一份虚构示例数据。
    for (final Brightness brightness in Brightness.values) {
      testWidgets('真实中文业务预览 ${platform.name} ${brightness.name}', (
        WidgetTester tester,
      ) async {
        await _captureBusinessPages(tester, platform, brightness);
      }, variant: TargetPlatformVariant.only(platform));
    }
  }
}

/// 字体不存在时明确指出配置入口，避免产出无法人工审查的方框截图。
Future<ByteData> _readFont(String path, String environmentKey) async {
  // 指定的本地字体文件。
  final File file = File(path);
  if (!await file.exists()) {
    throw StateError('未找到预览字体：$path；请设置 $environmentKey。');
  }
  return ByteData.sublistView(await file.readAsBytes());
}

/// 在单个平台和主题下遍历生产路由，并捕获真实编辑和分类管理入口。
Future<void> _captureBusinessPages(
  WidgetTester tester,
  TargetPlatform platform,
  Brightness brightness,
) async {
  // 桌面和触控布局使用各自代表性逻辑尺寸。
  final Size viewport = platform == TargetPlatform.windows
      ? const Size(1440, 900)
      : const Size(390, 844);
  // 保存测试框架的阴影开关，截图保留生产界面的真实层级。
  final bool previousDisableShadows = debugDisableShadows;
  debugDisableShadows = false;
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // 此文件通过 flutter test 显式运行，位于 tool/ 以免常规测试依赖本机字体。
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues(<String, Object>{
    'appearance.theme_mode': brightness.name,
    'appearance.theme_palette': 'classic_blue',
    if (platform == TargetPlatform.android)
      'home.cards.order': <String>[
        'quote',
        'todos',
        'timeStatus',
        'todayContext',
      ],
  });
  // 仅在本测试进程内生效的设备配置。
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  // 仅使用内存数据库，绝不读取本机业务数据库。
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  // 通过生产 Provider 接口注入隔离的数据与时间。
  final ProviderContainer container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      appDatabaseProvider.overrideWithValue(database),
      nowProvider.overrideWithValue(_previewNow),
      syncRuntimeProvider.overrideWithValue(null),
    ],
  );
  // 截图边界包围 MaterialApp，包含其 Navigator 产生的浮层。
  final GlobalKey captureKey = GlobalKey();
  // 文件名清楚标明平台、主题和逻辑宽度。
  final String prefix =
      '${platform.name}-${brightness.name}-${viewport.width.toInt()}';
  try {
    await _seedPreviewData(database);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: captureKey,
          child: MaterialApp.router(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.build(brightness: brightness),
            routerConfig: container.read(appRouterProvider),
          ),
        ),
      ),
    );
    // 使用真实路由和导航壳，不以孤立页面替代实际布局。
    for (final String route in _previewRoutes) {
      container.read(appRouterProvider).go(route);
      await tester.pumpAndSettle();
      if (route == '/events') {
        expect(find.text('预览 · 更换滤芯'), findsOneWidget);
        expect(find.text('预览 · 整理证件'), findsOneWidget);
      } else if (route == '/todos') {
        expect(find.text('预览 · 整理本周计划'), findsOneWidget);
      }
      await _capture(tester, captureKey, '$prefix-${route.substring(1)}');
      if (route == '/todos' && platform == TargetPlatform.android) {
        // 历史与进行中使用相同平铺表面，分别捕获真实二级页与分类页。
        await tester.tap(
          find.byKey(const ValueKey<String>('todo-mobile-history-open')),
        );
        await tester.pumpAndSettle();
        await _capture(tester, captureKey, '$prefix-todos-history');
        await tester.tap(
          find.byKey(const ValueKey<String>('todo-mobile-history-back')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey<String>('todo-mobile-quadrant-3')),
        );
        await tester.pumpAndSettle();
        await _capture(tester, captureKey, '$prefix-todos-focused');
      }
      if (route == '/home' && platform == TargetPlatform.android) {
        // 对首页各个平铺内容页和独立设置面板分别进行真实中文审查。
        for (final String module in <String>[
          'timeStatus',
          'todayContext',
          'todos',
        ]) {
          await tester.tap(
            find.byKey(ValueKey<String>('home-mobile-tab-$module')),
          );
          await tester.pumpAndSettle();
          await _capture(tester, captureKey, '$prefix-home-$module');
        }
      }
      if (route == '/settings' && platform == TargetPlatform.android) {
        // 首页设置从一级设置页进入，截图包含同一个持久化配置面板。
        await tester.tap(
          find.byKey(const ValueKey<String>('android-settings-home')),
        );
        await tester.pumpAndSettle();
        await _capture(tester, captureKey, '$prefix-home-settings');
        await tester.tap(find.byTooltip('关闭').last);
        await tester.pumpAndSettle();
      }
    }

    container.read(appRouterProvider).go('/events');
    await tester.pumpAndSettle();
    await tester.tap(find.text('新增事件'));
    await tester.pumpAndSettle();
    await _capture(tester, captureKey, '$prefix-event-editor');
    await tester.tap(find.byTooltip('关闭').last);
    await tester.pumpAndSettle();

    container.read(appRouterProvider).go('/inventory');
    await tester.pumpAndSettle();
    // 从真实物品页上下文调用正式弹窗入口，保留平台浮层和焦点行为。
    final Future<void> taxonomyClosed = TaxonomyManagerDialog.show(
      tester.element(find.byType(InventoryPage)),
      module: TaxonomyModule.inventory,
      kind: TaxonomyKind.category,
    );
    unawaited(taxonomyClosed);
    await tester.pumpAndSettle();
    await _capture(tester, captureKey, '$prefix-taxonomy-manager');
    await tester.tap(find.byTooltip('关闭').last);
    await tester.pumpAndSettle();
    await taxonomyClosed;
  } finally {
    // 先卸载订阅者和浮层，再释放容器与数据库，避免残留后台任务。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.read(appRouterProvider).dispose();
    container.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
    debugDisableShadows = previousDisableShadows;
  }
}

/// 为真实卡片提供明确标注为预览的虚构数据，避免依赖本机记录。
Future<void> _seedPreviewData(AppDatabase database) async {
  await EventRepository(database).save(
    EventDraft(
      name: '预览 · 更换滤芯',
      category: '居家维护',
      description: '仅用于界面预览的示例事件',
      intervalValue: 3,
      intervalUnit: EventIntervalUnit.month,
      lastCompletedAt: DateTime(2026, 7, 12, 9),
    ),
  );
  await EventRepository(database).save(
    EventDraft(
      name: '预览 · 整理证件',
      category: '生活整理',
      intervalValue: 1,
      intervalUnit: EventIntervalUnit.month,
      lastCompletedAt: DateTime(2026, 9, 1, 10),
      notes: '示例内容，不会写入本机数据库',
    ),
  );
  await TodoRepository(database).save(
    TodoDraft(
      title: '预览 · 整理本周计划',
      description: '确认优先事项，并留出休息时间',
      scheduledDate: DateUtils.dateOnly(_previewNow),
      dueAt: DateTime(2026, 10, 6, 18),
      priorityQuadrant: TodoPriorityQuadrant.urgentImportant,
    ),
  );
  await TimeEntryRepository(database).save(
    TimeEntryDraft(
      startedAt: DateTime(2026, 10, 6, 9),
      endedAt: DateTime(2026, 10, 6, 10),
      activity: '预览 · 阅读与笔记',
      category: '学习',
      notes: '固定结束时间，不创建运行中的计时任务',
    ),
  );
  await TaxonomyRepository(database).save(
    const TaxonomyDraft(
      module: TaxonomyModule.inventory,
      kind: TaxonomyKind.category,
      name: '预览电子设备',
      colorValue: 0xFF3370FF,
    ),
  );
  await TaxonomyRepository(database).save(
    const TaxonomyDraft(
      module: TaxonomyModule.inventory,
      kind: TaxonomyKind.category,
      name: '预览生活用品',
      colorValue: 0xFF1EA7A1,
      sortOrder: 1,
    ),
  );
  await InventoryRepository(database).save(
    InventoryDraft(
      name: '预览 · 阅读台灯',
      category: '预览电子设备',
      quantity: 1,
      purchasePriceCents: 18900,
      purchaseDate: DateTime(2026, 8, 12),
      location: '预览书桌',
      notes: '仅用于检查真实物品卡片',
    ),
  );
  await MembershipRepository(database).save(
    MembershipDraft(
      name: '预览 · 阅读会员',
      priceCents: 16800,
      purchaseDate: DateTime(2026, 1, 1),
      expirationDate: DateTime(2026, 12, 31),
      isPermanent: false,
      autoRenew: false,
      notes: '仅用于检查真实会员卡片',
    ),
  );
}

/// 保存当前真实绘制帧，并让布局和框架错误直接导致工具失败。
Future<void> _capture(
  WidgetTester tester,
  GlobalKey captureKey,
  String name,
) async {
  expect(tester.takeException(), isNull, reason: '$name 出现框架异常');
  // 已绘制完成的根渲染边界。
  final RenderRepaintBoundary boundary =
      captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    // 保持一倍逻辑像素，便于不同机器直接对照布局。
    final ui.Image image = await boundary.toImage();
    try {
      // 用 PNG 保存无损中文文字和组件边缘。
      final ByteData bytes = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!;
      await File('../../output/ui-pages-preview/$name.png').writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
    } finally {
      image.dispose();
    }
  });
}
