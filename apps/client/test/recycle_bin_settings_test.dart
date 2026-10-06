import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/settings/data/recycle_bin_repository.dart';
import 'package:omni_butler/features/settings/presentation/settings_page.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:omni_butler/shared/ui/omni_button.dart';
import 'package:omni_butler/shared/ui/omni_tag.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/recycle_bin_fixture.dart';

/// 验证真实设置页入口、分组、异步刷新与两端按钮尺寸。
void main() {
  // 可选真实中文预览目录；常规测试不写入视觉基线。
  final String? previewDirectory =
      Platform.environment['OMNI_RECYCLE_PREVIEW_DIR'];
  setUpAll(() async {
    if (previewDirectory == null) return;
    // 中文字体只在人工视觉预览时注册。
    final ByteData font = ByteData.sublistView(
      await File('C:/Windows/Fonts/msyh.ttc').readAsBytes(),
    );
    for (final String family in [
      'Microsoft YaHei UI',
      'Microsoft YaHei',
      'Roboto',
      'Noto Sans CJK SC',
      'Ahem',
    ]) {
      // 覆盖生产字体族与测试占位字体。
      final FontLoader loader = FontLoader(family)..addFont(Future.value(font));
      await loader.load();
    }
    // 真正的Material图标也参与截图。
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

  // 桌面、常见手机和320px窄屏均覆盖浅深主题。
  for (final (TargetPlatform platform, Size viewport) in [
    (TargetPlatform.windows, const Size(1200, 900)),
    (TargetPlatform.android, const Size(390, 844)),
    (TargetPlatform.android, const Size(320, 720)),
  ]) {
    for (final Brightness brightness in Brightness.values) {
      testWidgets(
        '${platform.name} ${viewport.width} ${brightness.name} 业务分组与清空确认',
        (WidgetTester tester) async {
          // 实际设置入口及数据库环境。
          final _SettingsFixture fixture = await _openSettings(
            tester,
            platform,
            viewport,
            brightness,
          );
          try {
            expect(find.text('数据与存储'), findsNothing);
            expect(
              find.byIcon(Icons.delete_outline_rounded, skipOffstage: false),
              findsWidgets,
            );
            expect(find.text('删除的数据保留 30 天，超过保留期自动永久删除'), findsOneWidget);
            // 分组标题顺序与业务固定顺序一致。
            double previousTop = -1;
            for (final RecycleEntityType type in RecycleEntityType.values) {
              // 分组键对应真实独立卡片。
              final Finder group = find.byKey(
                ValueKey<String>('recycle-group-${type.name}'),
              );
              expect(group, findsOneWidget);
              expect(tester.getTopLeft(group).dy, greaterThan(previousTop));
              previousTop = tester.getTopLeft(group).dy;
              expect(
                tester
                    .widget<OmniTag>(
                      find.descendant(
                        of: group,
                        matching: find.byType(OmniTag),
                      ),
                    )
                    .label,
                '1',
              );
            }
            // 首个永久删除按钮必须是紧凑外观，手机热区单独保留。
            final Finder delete = find.byKey(
              const ValueKey<String>('recycle-delete-todo-todo'),
            );
            // 按钮实际绘制表面，区分手机触控层和可视高度。
            final Finder paintedButton = find
                .descendant(of: delete, matching: find.byType(Material))
                .first;
            expect(tester.getSize(paintedButton).height, 28);
            if (platform == TargetPlatform.android) {
              expect(tester.getSize(delete).height, greaterThanOrEqualTo(48));
            }
            expect(tester.getSize(paintedButton).width, lessThanOrEqualTo(80));
            expect(tester.takeException(), isNull);
            if (previewDirectory != null) {
              await _capture(
                tester,
                fixture.captureKey,
                '$previewDirectory/${platform.name}-${viewport.width.toInt()}-${brightness.name}.png',
              );
            }

            await tester.tap(
              find.byKey(const ValueKey<String>('recycle-empty')),
            );
            await tester.pumpAndSettle();
            expect(find.text('清空回收站？'), findsOneWidget);
            // 确认期间全局和单行按钮都不可重复提交。
            expect(
              tester
                  .widget<OmniButton>(
                    find.byKey(const ValueKey<String>('recycle-empty')),
                  )
                  .onPressed,
              isNull,
            );
            await tester.tap(find.text('取消'));
            await tester.pumpAndSettle();
            expect(
              await fixture.container
                  .read(recycleBinRepositoryProvider)
                  .loadItems(),
              hasLength(6),
            );
            await tester.tap(
              find.byKey(const ValueKey<String>('recycle-empty')),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.text('清空回收站'));
            await tester.pumpAndSettle();
            expect(find.text('回收站为空'), findsOneWidget);
            expect(
              tester
                  .widget<OmniButton>(
                    find.byKey(const ValueKey<String>('recycle-empty')),
                  )
                  .onPressed,
              isNull,
            );
            expect(
              await fixture.container
                  .read(recycleBinRepositoryProvider)
                  .loadItems(),
              isEmpty,
            );
            expect(tester.takeException(), isNull);
          } finally {
            await fixture.dispose(tester);
          }
        },
      );
    }
  }

  testWidgets('恢复和永久删除自动刷新分组，组内删除时间倒序', (WidgetTester tester) async {
    // 使用桌面界面方便直接检查行位置和恢复操作。
    final _SettingsFixture fixture = await _openSettings(
      tester,
      TargetPlatform.windows,
      const Size(1200, 900),
      Brightness.light,
    );
    try {
      await seedRecycleRecord(
        fixture.database,
        RecycleEntityType.todo,
        '较新待办',
        DateTime.now(),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('较新待办')).dy,
        lessThan(
          tester
              .getTopLeft(
                find.byKey(const ValueKey<String>('recycle-item-todo-todo')),
              )
              .dy,
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('recycle-restore-todo-较新待办')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('recycle-item-todo-较新待办')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('recycle-delete-todo-todo')),
      );
      await tester.pumpAndSettle();
      expect(find.text('永久删除？'), findsOneWidget);
      await tester.tap(find.widgetWithText(OmniButton, '永久删除').last);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('recycle-group-todo')),
        findsNothing,
      );
      expect(
        await fixture.database.select(fixture.database.todoItems).get(),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets('清空失败保持记录并显示错误，解除故障后可以重试', (WidgetTester tester) async {
    // 真实SQL错误验证事务回滚和界面状态恢复。
    final _SettingsFixture fixture = await _openSettings(
      tester,
      TargetPlatform.windows,
      const Size(1200, 900),
      Brightness.dark,
    );
    try {
      await fixture.database.customStatement(
        "CREATE TRIGGER fail_delete BEFORE DELETE ON quotes BEGIN SELECT RAISE(ABORT, 'injected'); END",
      );
      await tester.tap(find.byKey(const ValueKey<String>('recycle-empty')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空回收站'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('recycle-operation-error')),
        findsOneWidget,
      );
      expect(
        await fixture.container.read(recycleBinRepositoryProvider).loadItems(),
        hasLength(6),
      );
      expect(
        tester
            .widget<OmniButton>(
              find.byKey(const ValueKey<String>('recycle-empty')),
            )
            .onPressed,
        isNotNull,
      );
      await fixture.database.customStatement('DROP TRIGGER fail_delete');
      await tester.tap(find.byKey(const ValueKey<String>('recycle-empty')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空回收站'));
      await tester.pumpAndSettle();
      expect(find.text('回收站为空'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('recycle-operation-error')),
        findsNothing,
      );
    } finally {
      await fixture.dispose(tester);
    }
  });
  testWidgets('清空处理中显示进度且所有操作阻止重复提交', (WidgetTester tester) async {
    // 显式暂停清空事务以观察提交中的真实界面。
    final Completer<void> gate = Completer<void>();
    // 使用延迟仓储的实际设置页。
    final _SettingsFixture fixture = await _openSettings(
      tester,
      TargetPlatform.windows,
      const Size(1200, 900),
      Brightness.light,
      clearGate: gate,
    );
    try {
      await tester.tap(find.byKey(const ValueKey<String>('recycle-empty')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空回收站'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // 操作仍保留名称，显示加载状态并禁用新请求。
      final OmniButton clear = tester.widget(
        find.byKey(const ValueKey<String>('recycle-empty')),
      );
      expect(clear.loading, isTrue);
      expect(clear.onPressed, isNull);
      expect(
        tester
            .widget<OmniButton>(
              find.byKey(const ValueKey<String>('recycle-restore-todo-todo')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey<String>('recycle-empty')));
      expect(
        (fixture.container.read(
          recycleBinRepositoryProvider,
        ) as _DelayedRecycleRepository).calls,
        1,
      );
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('回收站为空'), findsOneWidget);
    } finally {
      if (!gate.isCompleted) gate.complete();
      await fixture.dispose(tester);
    }
  });
}

/// 延迟提交仍复用正式仓储的原子清空路径。
class _DelayedRecycleRepository extends RecycleBinRepository {
  /// 允许测试观察处理中界面的闸门。
  final Completer<void> gate;

  /// 实际收到的清空请求次数。
  int calls = 0;

  /// 持有测试数据库和可控闸门。
  _DelayedRecycleRepository(AppDatabase database, this.gate)
    : super(database, TodoRepository(database));

  /// 等闸门放行后执行真实删除。
  @override
  Future<int> empty() async {
    calls++;
    await gate.future;
    return super.empty();
  }
}

/// 当前测试的依赖容器与渲染边界。
class _SettingsFixture {
  /// 独立的本机数据库。
  final AppDatabase database;

  /// 设置页依赖容器。
  final ProviderContainer container;

  /// 真实绘制预览边界。
  final GlobalKey captureKey;

  /// 创建测试环境。
  _SettingsFixture(this.database, this.container, this.captureKey);

  /// 先卸载流订阅，再关闭数据库，避免异步清理挂起。
  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  }
}

/// 使用正式设置页和Omni主题，业务数据仅保存到内存。
Future<_SettingsFixture> _openSettings(
  WidgetTester tester,
  TargetPlatform platform,
  Size viewport,
  Brightness brightness, {
  Completer<void>? clearGate,
}) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1;
  debugDefaultTargetPlatformOverride = platform;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  SharedPreferences.setMockInitialValues({});
  // 设置页功能偏好所需的本机存储。
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  // 独立测试数据库与六类近期删除记录。
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  for (final RecycleEntityType type in RecycleEntityType.values) {
    await seedRecycleRecord(
      database,
      type,
      type.name,
      DateTime.now().subtract(const Duration(days: 1)),
      title: switch (type) {
        RecycleEntityType.todo => '准备周末采购清单',
        RecycleEntityType.event => '更换净水器滤芯',
        RecycleEntityType.inventory => '备用机械键盘',
        RecycleEntityType.timeEntry => '阅读与学习',
        RecycleEntityType.membership => '云盘年度会员',
        RecycleEntityType.quote => '时间不是被填满的容器，而是被认真看见的生活。',
      },
    );
  }
  // 注入真实仓储依赖，避免用静态列表替代响应式刷新。
  final ProviderContainer container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      appDatabaseProvider.overrideWithValue(database),
      if (clearGate != null)
        recycleBinRepositoryProvider.overrideWithValue(
          _DelayedRecycleRepository(database, clearGate),
        ),
    ],
  );
  // 渲染边界用于可选的真实中文预览。
  final GlobalKey captureKey = GlobalKey();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.build(brightness: brightness)
              .copyWith(platform: platform),
          home: const Scaffold(body: SettingsPage()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(
    find.byKey(
      ValueKey<String>(
        platform == TargetPlatform.android
            ? 'android-settings-category-storage'
            : 'settings-category-storage',
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _SettingsFixture(database, container, captureKey);
}

/// 输出无损预览供人工审查，不自动写入golden基线。
Future<void> _capture(WidgetTester tester, GlobalKey key, String path) async {
  // 当前完整页面的绘制边界。
  final RenderRepaintBoundary boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    // 本次渲染图像，保存完成后释放GPU资源。
    final ui.Image image = await boundary.toImage();
    try {
      // PNG编码后的像素数据。
      final ByteData bytes = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!;
      await File(path).writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
    } finally {
      image.dispose();
    }
  });
}
