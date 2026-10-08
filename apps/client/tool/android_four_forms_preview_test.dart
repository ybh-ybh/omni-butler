import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/features/events/presentation/events_page.dart';
import 'package:omni_butler/features/inventory/data/inventory_repository.dart';
import 'package:omni_butler/features/inventory/presentation/inventory_move_dialog.dart';
import 'package:omni_butler/features/inventory/presentation/inventory_page.dart';
import 'package:omni_butler/features/memberships/presentation/memberships_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 使用生产页面和隔离内存数据生成中文预览，不更新任何 Golden。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    // 仅供本机预览的真实中文字形，不成为产品资源。
    final ByteData font = ByteData.sublistView(
      await File(
        Platform.environment['OMNI_UI_FONT'] ?? 'C:/Windows/Fonts/msyh.ttc',
      ).readAsBytes(),
    );
    // 覆盖测试字体，使截图与真实中文阅读接近。
    for (final String family in <String>[
      'Roboto',
      'Ahem',
      'Noto Sans CJK SC',
      'Microsoft YaHei UI',
      'Microsoft YaHei',
    ]) {
      // 每个字体别名独立注册同一份真实字体。
      final FontLoader loader = FontLoader(family)
        ..addFont(Future<ByteData>.value(font));
      await loader.load();
    }
    // 图标使用 SDK 自带资源，不修改应用资产。
    final FontLoader icons = FontLoader('MaterialIcons')
      ..addFont(
        File(
          Platform.environment['OMNI_UI_ICONS'] ?? 'D:/program/code/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
        ).readAsBytes().then(ByteData.sublistView),
      );
    await icons.load();
    await Directory('../../output/android-four-forms-preview')
        .create(recursive: true);
  });

  // 明暗两种主题各检查四个目标弹窗。
  for (final Brightness brightness in Brightness.values) {
    // 业务标识用于稳定截图文件名和生产字段定位。
    for (final String form in <String>[
      'membership',
      'inventory',
      'event',
      'move',
    ]) {
      testWidgets('$form ${brightness.name} 中文与双倍字号预览', (
        WidgetTester tester,
      ) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        // 数据和偏好完全隔离于用户环境。
        // 此文件通过 flutter test 执行，仅在预览测试中替换偏好存储。
        // ignore: invalid_use_of_visible_for_testing_member
        SharedPreferences.setMockInitialValues(<String, Object>{});
        // 新增物品读取原有布局偏好。
        final SharedPreferences preferences =
            await SharedPreferences.getInstance();
        // 预览的唯一内存数据库。
        final AppDatabase database = AppDatabase.forTesting(
          NativeDatabase.memory(),
        );
        // 位置数据由原 taxonomy 仓储创建。
        final TaxonomyRepository taxonomy = TaxonomyRepository(database);
        await taxonomy.save(
          const TaxonomyDraft(
            module: TaxonomyModule.inventory,
            kind: TaxonomyKind.location,
            name: '书房',
            colorValue: 0xFF4285F4,
          ),
        );
        await taxonomy.save(
          const TaxonomyDraft(
            module: TaxonomyModule.inventory,
            kind: TaxonomyKind.location,
            name: '客厅',
            colorValue: 0xFF4285F4,
            sortOrder: 1,
          ),
        );
        // 仓储新增时生成真实标识，不能把不存在的更新标识当作新增。
        final List<TaxonomyEntry> locations = await database
            .select(database.taxonomyEntries)
            .get();
        // 搬家主物品使用真实来源位置关联。
        final String studyId = locations
            .singleWhere((TaxonomyEntry entry) => entry.name == '书房')
            .id;
        // 搬家使用有数量和继承位置配件的真实样例。
        final InventoryRepository inventory = InventoryRepository(database);
        // 用于搬家勾选的主物品标识。
        final String monitor = await inventory.save(
          InventoryDraft(
            name: '书桌显示器',
            quantity: 1,
            location: '书房',
            locationIds: <String>{studyId},
          ),
        );
        await inventory.save(
          InventoryDraft(name: '连接数据线', quantity: 2, parentItemId: monitor),
        );
        // 固定时间并隔离页面依赖。
        final ProviderContainer container = ProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(preferences),
            appDatabaseProvider.overrideWithValue(database),
            nowProvider.overrideWithValue(DateTime(2026, 10, 8, 12)),
          ],
        );
        // 放大文字时保留同一个业务编辑器和所有控制器。
        final ValueNotifier<double> scale = ValueNotifier<double>(1);
        // 截图包含完整导航覆盖层及正文。
        final GlobalKey boundary = GlobalKey();
        try {
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: RepaintBoundary(
                key: boundary,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: AppTheme.build(brightness: brightness)
                      .copyWith(platform: TargetPlatform.android),
                  builder: (BuildContext context, Widget? child) =>
                      ValueListenableBuilder<double>(
                        valueListenable: scale,
                        child: child,
                        builder:
                            (
                              BuildContext context,
                              double value,
                              Widget? stableChild,
                            ) => MediaQuery(
                              data: MediaQuery.of(
                                context,
                              ).copyWith(textScaler: TextScaler.linear(value)),
                              child: stableChild!,
                            ),
                      ),
                  home: Scaffold(
                    body: form == 'membership'
                        ? const MembershipsPage(embeddedInManagement: true)
                        : form == 'event'
                        ? const EventsPage(embeddedInManagement: true)
                        : form == 'inventory'
                        ? const InventoryPage(embeddedInManagement: true)
                        : Builder(
                            builder: (BuildContext context) => Center(
                              child: TextButton(
                                onPressed: () =>
                                    showInventoryMoveDialog(context),
                                child: const Text('打开搬家'),
                              ),
                            ),
                          ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            form == 'move'
                ? find.text('打开搬家')
                : find.byKey(
                    ValueKey<String>(
                      '${form == 'membership'
                          ? 'membership'
                          : form == 'event'
                          ? 'event'
                          : 'inventory'}-mobile-create',
                    ),
                  ),
          );
          await tester.pumpAndSettle();
          await _capturePreview(
            tester,
            boundary,
            '$form-${brightness.name}.png',
          );
          if (form == 'move') {
            await tester.tap(
              find.byKey(ValueKey<String>('inventory-move-item-$monitor')),
            );
            await tester.pumpAndSettle();
            await tester.tap(
              find.byKey(const ValueKey<String>('inventory-move-next')),
            );
            await tester.pumpAndSettle();
            await tester.tap(
              find.byKey(const ValueKey<String>('inventory-move-destination')),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.text('客厅').last);
            await tester.pumpAndSettle();
          } else {
            // 补充区域经生产展开按钮打开，验证长表单的真实呈现。
            final Finder toggle = find.textContaining('补充信息');
            await tester.ensureVisible(toggle);
            await tester.pumpAndSettle();
            await tester.tap(toggle);
            await tester.pumpAndSettle();
            // 展开预览直接展示补充字段，避免截图仅重复默认区域。
            await tester.ensureVisible(
              find.byKey(
                ValueKey<String>(
                  '$form-create-${form == 'membership' ? 'website' : 'notes'}',
                ),
              ),
            );
            await tester.pumpAndSettle();
          }
          await _capturePreview(
            tester,
            boundary,
            '$form-${brightness.name}-expanded.png',
          );
          if (form != 'move') {
            await tester.ensureVisible(
              find.byKey(ValueKey<String>('$form-create-name')),
            );
            await tester.pumpAndSettle();
          }
          tester.view.physicalSize = const Size(320, 640);
          scale.value = 2;
          tester.view.viewInsets = const FakeViewPadding(bottom: 220);
          await tester.pumpAndSettle();
          await _capturePreview(
            tester,
            boundary,
            '$form-${brightness.name}-large-keyboard.png',
          );
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          container.dispose();
          await tester.pump(const Duration(milliseconds: 100));
          await database.close();
          scale.dispose();
        }
      });
    }
  }
}

/// 将生产界面的真实渲染结果保存为可查看的 PNG。
Future<void> _capturePreview(
  WidgetTester tester,
  GlobalKey key,
  String filename,
) async {
  await tester.pump();
  await tester.runAsync(() async {
    // 整个应用和模态路由的像素边界。
    final RenderRepaintBoundary boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    // 使用逻辑像素保持截图清晰且方便尺寸对比。
    final ui.Image pixels = await boundary.toImage(pixelRatio: 1);
    // PNG 编码只用于交付证据。
    final ByteData png = (await pixels.toByteData(
      format: ui.ImageByteFormat.png,
    ))!;
    await File('../../output/android-four-forms-preview/$filename')
        .writeAsBytes(png.buffer.asUint8List());
    pixels.dispose();
  });
}
