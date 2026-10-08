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
import 'package:omni_butler/features/timeline/data/time_entry_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 使用真实中文字体和内存样例生成两端的时间页预览。
void main() {
  setUpAll(() async {
    // 本机中文字体只用于预览，不成为产品资产。
    final ByteData font = ByteData.sublistView(
      await File(
        Platform.environment['OMNI_UI_FONT'] ?? 'C:/Windows/Fonts/msyh.ttc',
      ).readAsBytes(),
    );
    for (final String family in <String>[
      'Microsoft YaHei UI',
      'Microsoft YaHei',
      'Roboto',
      'Noto Sans CJK SC',
      'Ahem',
    ]) {
      // 覆盖测试默认字体，确保真实中文排版。
      final FontLoader loader = FontLoader(family)
        ..addFont(Future<ByteData>.value(font));
      await loader.load();
    }
    // 注册实际Material图标字体。
    final FontLoader icons = FontLoader('MaterialIcons')
      ..addFont(
        File(
          Platform.environment['OMNI_UI_ICONS'] ?? 'D:/program/code/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
        ).readAsBytes().then(ByteData.sublistView),
      );
    await icons.load();
    await Directory('../../output/timeline-redesign-preview')
        .create(recursive: true);
  });

  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.windows,
    TargetPlatform.android,
  ]) {
    for (final Brightness brightness in Brightness.values) {
      testWidgets('时间页中文预览 ${platform.name} ${brightness.name}', (
        WidgetTester tester,
      ) async {
        // 代表桌面与手机实际阅读尺寸。
        final Size viewport = platform == TargetPlatform.windows
            ? const Size(1440, 900)
            : const Size(390, 844);
        tester.view.physicalSize = viewport;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        // 预览固定时刻，不使用本机实际业务数据。
        final DateTime now = DateTime(2026, 10, 8, 18, 30);
        // 本文件由 flutter test 显式运行，置于 tool/ 避免常规测试依赖本机字体。
        // ignore: invalid_use_of_visible_for_testing_member
        SharedPreferences.setMockInitialValues(<String, Object>{
          'appearance.theme_mode': brightness.name,
        });
        // 隔离偏好和业务数据库。
        final SharedPreferences preferences =
            await SharedPreferences.getInstance();
        // 本测试持有唯一内存数据库。
        final AppDatabase database = AppDatabase.forTesting(
          NativeDatabase.memory(),
        );
        // 用生产仓储准备复盘与明细样例。
        final TimeEntryRepository repository = TimeEntryRepository(database);
        // 预览显式配置类别颜色，模拟用户真实分类而非统一回退色。
        final TaxonomyRepository taxonomy = TaxonomyRepository(database);
        // 类别原色只属于这份内存样例。
        for (final (String, Color) category in <(String, Color)>[
          ('睡眠', const Color(0xFF646970)),
          ('开发', const Color(0xFFD8A505)),
          ('吃饭', const Color(0xFF9260DF)),
          ('娱乐', const Color(0xFF199DFF)),
          ('学习', const Color(0xFF5F66A5)),
        ]) {
          await taxonomy.save(
            TaxonomyDraft(
              module: TaxonomyModule.timeline,
              kind: TaxonomyKind.category,
              name: category.$1,
              colorValue: category.$2.toARGB32(),
            ),
          );
        }
        for (final int offset in <int>[0, 1, 2, 3]) {
          // 本周前四个自然日。
          final DateTime day = DateTime(2026, 10, 5 + offset);
          for (final (int, int, String, String) record
              in <(int, int, String, String)>[
                (0, 450, '睡眠', '睡眠'),
                (450, 485, '早餐与整理', '吃饭'),
                (500, 720, '开发知识库', '开发'),
                (720, 780, '午饭', '吃饭'),
                (810, 1035, '开发知识库', '开发'),
                (1080, 1150, '散步和听播客', '娱乐'),
              ]) {
            await repository.save(
              TimeEntryDraft(
                startedAt: day.add(Duration(minutes: record.$1)),
                endedAt: day.add(Duration(minutes: record.$2)),
                activity: record.$3,
                category: record.$4,
              ),
            );
          }
        }
        // 跨日样例验证明细提示与自然日投影。
        await repository.save(
          TimeEntryDraft(
            startedAt: DateTime(2026, 10, 7, 23),
            endedAt: DateTime(2026, 10, 8),
            activity: '阅读与学习',
            category: '学习',
          ),
        );
        // 所有生产依赖都限定在测试内存与固定时刻。
        final ProviderContainer container = ProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(preferences),
            appDatabaseProvider.overrideWithValue(database),
            nowProvider.overrideWithValue(now),
            syncRuntimeProvider.overrideWithValue(null),
          ],
        );
        // 完整应用与弹出菜单共用的截图边界。
        final GlobalKey captureKey = GlobalKey();
        // 清楚标明平台和明暗的文件前缀。
        final String prefix = '${platform.name}-${brightness.name}';
        container.read(appRouterProvider).go('/timeline');
        try {
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: RepaintBoundary(
                key: captureKey,
                child: MaterialApp.router(
                  debugShowCheckedModeBanner: false,
                  theme: AppTheme.build(brightness: brightness)
                      .copyWith(platform: platform),
                  routerConfig: container.read(appRouterProvider),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey<String>('timeline-week-fingerprint')),
            findsOneWidget,
          );
          await _capture(tester, captureKey, '$prefix-week');
          if (platform == TargetPlatform.android) {
            await tester.tap(
              find.byKey(const ValueKey<String>('timeline-period-menu')),
            );
            await tester.pumpAndSettle();
            await _capture(tester, captureKey, '$prefix-period-menu');
            await tester.tapAt(const Offset(8, 8));
            await tester.pumpAndSettle();
          }
          for (final (String, String) period in <(String, String)>[
            ('月', 'month'),
            ('日', 'day'),
          ]) {
            if (platform == TargetPlatform.android) {
              await tester.tap(
                find.byKey(const ValueKey<String>('timeline-period-menu')),
              );
              await tester.pumpAndSettle();
            }
            // 桌面周期标签限定在控件内，避免误点月历的星期日。
            final Finder periodOption = platform == TargetPlatform.android
                ? find.text(period.$1).last
                : find.descendant(
                    of: find.byKey(
                      const ValueKey<String>('timeline-period-control'),
                    ),
                    matching: find.text(period.$1),
                  );
            await tester.tap(periodOption);
            await tester.pumpAndSettle();
            expect(
              find.byKey(ValueKey<String>('timeline-${period.$2}-fingerprint')),
              findsOneWidget,
            );
            await _capture(tester, captureKey, '$prefix-${period.$2}');
          }
          await tester.tap(
            find.byKey(const ValueKey<String>('timeline-view-mode-details')),
          );
          await tester.pumpAndSettle();
          await _capture(tester, captureKey, '$prefix-details');
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          container.dispose();
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(database.close);
        }
      }, variant: TargetPlatformVariant.only(platform));
    }
  }
}

/// 编码和写盘放在真实异步区，避免Widget测试的虚拟时钟阻塞。
Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  await tester.runAsync(() async {
    // 已完成布局的完整应用边界。
    final RenderRepaintBoundary boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    // 逻辑像素截图方便对照Windows和Android排版。
    final ui.Image image = await boundary.toImage(pixelRatio: 1);
    try {
      // 保存可直接查看的PNG文件。
      final ByteData bytes = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!;
      await File('../../output/timeline-redesign-preview/$name.png')
          .writeAsBytes(bytes.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}
