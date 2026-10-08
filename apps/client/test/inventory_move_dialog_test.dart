import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/omni_butler_app.dart';
import 'package:omni_butler/app/router/app_router.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/features/inventory/data/inventory_repository.dart';
import 'package:omni_butler/features/inventory/presentation/inventory_move_dialog.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/golden_test_support.dart';

/// 验证物品搬家工作台的选择、预览和响应式迁移流程。
void main() {
  testWidgets('桌面端从位置树选择主物品并连同继承位置配件迁移', (WidgetTester tester) async {
    // 固定桌面测试视口。
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'appearance.theme_mode': 'light',
    });
    // 测试用主题偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    addTearDown(database.close);
    // 测试 taxonomy 仓储。
    final TaxonomyRepository taxonomyRepository = TaxonomyRepository(database);
    // 书房位置。
    final TaxonomyEntry study = await _createLocation(
      database,
      taxonomyRepository,
      '书房',
      0,
    );
    // 储物间位置。
    final TaxonomyEntry storage = await _createLocation(
      database,
      taxonomyRepository,
      '储物间',
      1,
    );
    // 测试物品仓储。
    final InventoryRepository repository = InventoryRepository(database);
    // 测试主物品标识。
    final String cameraId = await repository.save(
      InventoryDraft(
        name: '相机',
        quantity: 1,
        location: study.name,
        locationIds: <String>{study.id},
      ),
    );
    // 随主物品存放的配件标识。
    final String strapId = await repository.save(
      InventoryDraft(name: '相机肩带', quantity: 1, parentItemId: cameraId),
    );
    // 独立位于储物间的测试物品。
    await repository.save(
      InventoryDraft(
        name: '电钻',
        quantity: 2,
        location: storage.name,
        locationIds: <String>{storage.id},
      ),
    );
    // 测试依赖容器。
    final ProviderContainer container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        appDatabaseProvider.overrideWithValue(database),
        nowProvider.overrideWithValue(DateTime(2026, 9, 24, 10)),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const OmniButlerApp(),
      ),
    );
    await tester.pumpAndSettle();
    container.read(appRouterProvider).go('/inventory');
    await tester.pumpAndSettle();

    // 物品页工具栏提供一键搬家入口。
    final Finder moveButton = find.byKey(
      const ValueKey<String>('inventory-move-button'),
    );
    expect(moveButton, findsOneWidget);
    await tester.tap(moveButton);
    await tester.pumpAndSettle();

    // 桌面端同时展示来源树、搬运方向和迁移目标区域。
    expect(
      find.byKey(const ValueKey<String>('inventory-move-dialog')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('inventory-move-source-panel')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('inventory-move-target-panel')),
      findsOneWidget,
    );
    expect(find.text('书房'), findsWidgets);
    expect(find.text('储物间'), findsWidgets);
    // 固化桌面双栏搬家工作台的视觉基线。
    await prepareBrandImageForGolden(tester);
    await expectLater(
      find.byType(OmniButlerApp),
      matchesGoldenFile('goldens/inventory_move_light_1440x900.png'),
    );

    // 搜索配套物品时保留其同组主物品上下文。
    await tester.enterText(
      find.byKey(const ValueKey<String>('inventory-move-search')),
      '相机肩带',
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey<String>('inventory-move-item-$cameraId')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey<String>('inventory-move-item-$strapId')),
      findsOneWidget,
    );
    // 清空搜索恢复完整位置树。
    await tester.enterText(
      find.byKey(const ValueKey<String>('inventory-move-search')),
      '',
    );
    await tester.pumpAndSettle();

    // 选择主物品后，继承位置配件自动出现在右侧且不能单独移除。
    await tester.tap(
      find.byKey(ValueKey<String>('inventory-move-item-$cameraId')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey<String>('inventory-move-selected-$cameraId')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey<String>('inventory-move-selected-$strapId')),
      findsOneWidget,
    );
    expect(find.textContaining('随主物品自动迁移'), findsWidgets);
    expect(find.text('已选 2 条记录，共 2 件'), findsOneWidget);

    // 选择目标位置并执行迁移。
    await tester.tap(
      find.byKey(const ValueKey<String>('inventory-move-destination')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('储物间').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('inventory-move-submit')),
    );
    await tester.pump();
    // 等待迁移弹窗关闭与浮动消息出现，但不推进到四秒自动关闭。
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('已将 2 项迁移到“储物间”'), findsOneWidget);

    // 主物品写入新位置，继承位置配件继续保持空位置。
    final InventoryRecord movedCamera = await (database.select(
      database.inventoryItems,
    )..where((InventoryItems table) => table.id.equals(cameraId))).getSingle();
    // 迁移后的继承位置配件。
    final InventoryRecord movedStrap = await (database.select(
      database.inventoryItems,
    )..where((InventoryItems table) => table.id.equals(strapId))).getSingle();
    expect(movedCamera.location, storage.name);
    expect(movedStrap.location, isNull);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('移动端使用选择和确认两步流程迁移物品', (WidgetTester tester) async {
    // 固定移动端测试视口。
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'appearance.theme_mode': 'light',
    });
    // 测试用主题偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    addTearDown(database.close);
    // 测试 taxonomy 仓储。
    final TaxonomyRepository taxonomyRepository = TaxonomyRepository(database);
    // 客厅位置。
    final TaxonomyEntry livingRoom = await _createLocation(
      database,
      taxonomyRepository,
      '客厅',
      0,
    );
    // 卧室位置。
    final TaxonomyEntry bedroom = await _createLocation(
      database,
      taxonomyRepository,
      '卧室',
      1,
    );
    // 测试物品仓储。
    final InventoryRepository repository = InventoryRepository(database);
    // 测试物品标识。
    final String speakerId = await repository.save(
      InventoryDraft(
        name: '蓝牙音箱',
        quantity: 1,
        location: livingRoom.name,
        locationIds: <String>{livingRoom.id},
      ),
    );
    // 测试依赖容器。
    final ProviderContainer container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        appDatabaseProvider.overrideWithValue(database),
        nowProvider.overrideWithValue(DateTime(2026, 9, 24, 10)),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const OmniButlerApp(),
      ),
    );
    await tester.pumpAndSettle();
    container.read(appRouterProvider).go('/inventory');
    await tester.pumpAndSettle();
    // 移动端从右下角拆分按钮的次要操作菜单进入一键搬家。
    await tester.tap(
      find.byKey(const ValueKey<String>('inventory-mobile-more-actions')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('一键搬家'));
    await tester.pumpAndSettle();

    // 第一步只显示物品选择区域。
    expect(find.text('1/2 · 选择物品'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('inventory-move-source-panel')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('inventory-move-target-panel')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(ValueKey<String>('inventory-move-item-$speakerId')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    // 第二步显示目标位置和迁移预览。
    expect(find.text('2/2 · 确认迁移'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('inventory-move-source-panel')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('inventory-move-target-panel')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('inventory-move-destination')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('卧室').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('inventory-move-submit')),
    );
    await tester.pumpAndSettle();

    // 移动端迁移结果正确且没有布局异常。
    final InventoryRecord movedSpeaker = await (database.select(
      database.inventoryItems,
    )..where((InventoryItems table) => table.id.equals(speakerId))).getSingle();
    expect(movedSpeaker.location, bedroom.name);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Windows 窄窗口仍保持双栏且没有横向溢出', (WidgetTester tester) async {
    // 固定 Windows 窄窗口测试视口。
    tester.view.physicalSize = const Size(700, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDatabaseProvider.overrideWithValue(database)],
        child: MaterialApp(
          theme: AppTheme.build(brightness: Brightness.light),
          home: const Scaffold(body: InventoryMoveDialog()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 桌面窄窗口不会降级成移动端分步流程。
    expect(
      find.byKey(const ValueKey<String>('inventory-move-source-panel')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('inventory-move-target-panel')),
      findsOneWidget,
    );
    expect(find.textContaining('/2 ·'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });

  // 安卓全屏布局覆盖手机窄屏、常规屏和大字号平板。
  for (final (Size, double) viewport in <(Size, double)>[
    (const Size(320, 640), 1),
    (const Size(390, 844), 1),
    (const Size(900, 700), 2),
  ]) {
    testWidgets('安卓搬家 ${viewport.$1.width} 宽 ${viewport.$2} 倍字顶栏固定并避让键盘', (
      WidgetTester tester,
    ) async {
      // 多条物品使正文真正需要滚动。
      final _AndroidMoveFixture fixture = await _pumpAndroidMove(
        tester,
        size: viewport.$1,
        textScale: viewport.$2,
        extraItems: 15,
        brightness: viewport.$2 == 2 ? Brightness.dark : Brightness.light,
      );
      // 固定标题和主操作在正文滚动前的位置。
      final Rect titleRect = tester.getRect(find.text('一键搬家'));
      // 第一步主操作用于确认全宽安卓仍采用两步。
      final Finder next = _moveKey('inventory-move-next');
      expect(find.text('1/2 · 选择物品'), findsOneWidget);
      expect(_moveKey('inventory-move-target-panel'), findsNothing);
      expect(titleRect.center.dx, closeTo(viewport.$1.width / 2, 1));
      expect(tester.widget<OmniButton>(next).onPressed, isNull);
      await tester.drag(
        _moveKey('inventory-move-source-panel'),
        const Offset(0, -400),
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(find.text('一键搬家')), titleRect);
      await tester.drag(
        _moveKey('inventory-move-source-panel'),
        const Offset(0, 1600),
      );
      await tester.pumpAndSettle();
      await tester.tap(_moveKey('inventory-move-search'));
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(tester.getRect(find.text('一键搬家')), titleRect);
      expect(tester.getRect(next).bottom, lessThan(viewport.$1.height - 260));
      expect(tester.takeException(), isNull);
      await fixture.dispose(tester);
    });
  }

  testWidgets('安卓搬家统计自动配件，系统返回保留目标，取消直接退出', (WidgetTester tester) async {
    // 夹具包含数量 2 的主物品和数量 3 的继承配件。
    final _AndroidMoveFixture fixture = await _pumpAndroidMove(tester);
    await _selectMoveParent(tester, fixture);
    expect(find.text('已选 2 条记录，共 5 件'), findsOneWidget);
    await tester.tap(_moveKey('inventory-move-next'));
    await tester.pumpAndSettle();
    await _selectMoveDestination(tester);
    expect(
      _moveKey('inventory-move-selected-${fixture.accessoryId}'),
      findsOneWidget,
    );
    // 返回只切换步骤，已选物品及目标仍保留。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('1/2 · 选择物品'), findsOneWidget);
    expect(find.text('已选 2 条记录，共 5 件'), findsOneWidget);
    await tester.tap(_moveKey('inventory-move-next'));
    await tester.pumpAndSettle();
    expect(find.text('目标位置'), findsOneWidget);
    expect(
      tester.widget<OmniButton>(_moveKey('inventory-move-submit')).onPressed,
      isNotNull,
    );
    // 顶栏取消不受第二步系统返回规则影响。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(_moveKey('inventory-move-dialog'), findsNothing);
    expect(fixture.repository.moveCalls, 0);
    expect(tester.takeException(), isNull);
    await fixture.dispose(tester);
  });

  testWidgets('安卓搬家空列表仍保留顶栏，第一步系统返回可退出', (WidgetTester tester) async {
    // 删除夹具中的全部物品以触发真实流的空状态。
    final _AndroidMoveFixture fixture = await _pumpAndroidMove(tester);
    await fixture.database
        .update(fixture.database.inventoryItems)
        .write(
          InventoryItemsCompanion(
            deletedAt: Value<DateTime>(DateTime(2026, 10, 8)),
          ),
        );
    await tester.pumpAndSettle();
    expect(find.text('还没有可迁移的物品'), findsOneWidget);
    expect(find.text('一键搬家'), findsOneWidget);
    expect(find.text('已选 0 条记录，共 0 件'), findsOneWidget);
    expect(
      tester.widget<OmniButton>(_moveKey('inventory-move-next')).onPressed,
      isNull,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_moveKey('inventory-move-dialog'), findsNothing);
    expect(find.text('打开搬家'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await fixture.dispose(tester);
  });

  testWidgets('安卓搬家目标被停用或选择变空时禁用迁移', (WidgetTester tester) async {
    // 真实数据库流用于验证目标失效后的即时刷新。
    final _AndroidMoveFixture fixture = await _pumpAndroidMove(tester);
    await _selectMoveParent(tester, fixture);
    await tester.tap(_moveKey('inventory-move-next'));
    await tester.pumpAndSettle();
    await _selectMoveDestination(tester);
    await (fixture.database.update(fixture.database.taxonomyEntries)..where(
          (TaxonomyEntries table) => table.id.equals(fixture.destination.id),
        ))
        .write(const TaxonomyEntriesCompanion(isEnabled: Value<bool>(false)));
    await tester.pumpAndSettle();
    expect(
      tester.widget<OmniButton>(_moveKey('inventory-move-submit')).onPressed,
      isNull,
    );
    expect(find.text('选择目标位置'), findsOneWidget);
    // 移除主物品同时移除自动跟随配件，不能提交空列表。
    await tester.tap(
      find.descendant(
        of: _moveKey('inventory-move-selected-${fixture.parentId}'),
        matching: find.byType(OmniIconButton),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已选 0 条记录，共 0 件'), findsOneWidget);
    expect(find.text('暂无待迁移物品，请返回上一步选择'), findsOneWidget);
    expect(
      tester.widget<OmniButton>(_moveKey('inventory-move-submit')).onPressed,
      isNull,
    );
    expect(fixture.repository.moveCalls, 0);
    expect(tester.takeException(), isNull);
    await fixture.dispose(tester);
  });

  testWidgets('安卓搬家数据失败可重试并保留步骤选择，加载时可取消', (WidgetTester tester) async {
    // 可控读取失败从已选状态进入，验证重试不会重置业务状态。
    final _AndroidMoveFixture fixture = await _pumpAndroidMove(tester);
    await _selectMoveParent(tester, fixture);
    await tester.tap(_moveKey('inventory-move-next'));
    await tester.pumpAndSettle();
    await _selectMoveDestination(tester);
    fixture.repository.failReads = true;
    fixture.container.invalidate(inventoryItemsProvider(''));
    await tester.pumpAndSettle();
    expect(find.textContaining('物品读取失败'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('已选 2 条记录，共 5 件'), findsOneWidget);
    expect(
      tester.widget<OmniButton>(_moveKey('inventory-move-submit')).onPressed,
      isNull,
    );
    fixture.repository.failReads = false;
    await tester.tap(_moveKey('inventory-move-retry'));
    await tester.pumpAndSettle();
    expect(find.text('2/2 · 确认迁移'), findsOneWidget);
    expect(find.text('目标位置'), findsOneWidget);
    expect(find.text('已选 2 条记录，共 5 件'), findsOneWidget);
    // 读取尚未完成时保留可退出的顶栏。
    fixture.repository.pendingRead = Completer<List<InventoryRecord>>();
    fixture.container.invalidate(inventoryItemsProvider(''));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester.widget<OmniButton>(_moveKey('inventory-move-submit')).onPressed,
      isNull,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(_moveKey('inventory-move-dialog'), findsNothing);
    fixture.repository.pendingRead!.complete(<InventoryRecord>[]);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await fixture.dispose(tester);
  });

  testWidgets('安卓搬家提交锁拦截防重和返回，失败保留输入，成功只关闭工作台', (WidgetTester tester) async {
    // 通过仓储完成器确定提交中的观察窗口。
    final _AndroidMoveFixture fixture = await _pumpAndroidMove(tester);
    await _selectMoveParent(tester, fixture);
    await tester.tap(_moveKey('inventory-move-next'));
    await tester.pumpAndSettle();
    await _selectMoveDestination(tester);
    fixture.repository.pendingMove = Completer<InventoryMoveResult>();
    // 保留提交回调验证即使同帧重复触发也只有一次仓储调用。
    final VoidCallback submit = tester
        .widget<OmniButton>(_moveKey('inventory-move-submit'))
        .onPressed!;
    submit();
    submit();
    await tester.pump();
    expect(fixture.repository.moveCalls, 1);
    expect(
      tester.widget<OmniButton>(_moveKey('inventory-move-submit')).onPressed,
      isNull,
    );
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('2/2 · 确认迁移'), findsOneWidget);
    // 位置管理属于正文，同样被提交锁冻结。
    expect(
      find.ancestor(
        of: _moveKey('inventory-move-manage-location'),
        matching: find.byWidgetPredicate(
          (Widget widget) => widget is AbsorbPointer && widget.absorbing,
        ),
      ),
      findsOneWidget,
    );
    fixture.repository.pendingMove!.completeError(StateError('测试迁移失败'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('物品迁移失败').hitTestable(), findsOneWidget);
    expect(_moveKey('inventory-move-error').hitTestable(), findsOneWidget);
    expect(_moveKey('inventory-move-submit').hitTestable(), findsOneWidget);
    expect(find.text('目标位置'), findsOneWidget);
    expect(find.text('已选 2 条记录，共 5 件'), findsOneWidget);
    // 行内错误不遮挡主操作，无需等待浮层倒计时即可立即重试。
    fixture.repository.pendingMove = null;
    await tester.tap(_moveKey('inventory-move-submit'));
    await tester.pumpAndSettle();
    expect(fixture.repository.moveCalls, 2);
    expect(_moveKey('inventory-move-dialog'), findsNothing);
    expect(find.text('打开搬家'), findsOneWidget);
    // 真实重试成功同时保留配件的位置继承。
    final InventoryRecord movedParent =
        await (fixture.database.select(fixture.database.inventoryItems)..where(
              (InventoryItems table) => table.id.equals(fixture.parentId),
            ))
            .getSingle();
    expect(movedParent.location, fixture.destination.name);
    expect(tester.takeException(), isNull);
    await fixture.dispose(tester);
  });
}

/// 查找搬家专项测试的稳定业务标识。
Finder _moveKey(String value) => find.byKey(ValueKey<String>(value));

/// 选择主物品并等待自动配件纳入选择。
Future<void> _selectMoveParent(
  WidgetTester tester,
  _AndroidMoveFixture fixture,
) async {
  await tester.tap(_moveKey('inventory-move-item-${fixture.parentId}'));
  await tester.pumpAndSettle();
}

/// 选择夹具中的目标位置。
Future<void> _selectMoveDestination(WidgetTester tester) async {
  await tester.tap(_moveKey('inventory-move-destination'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('目标位置').last);
  await tester.pumpAndSettle();
}

/// 安卓路由测试持有的数据库和可控依赖。
class _AndroidMoveFixture {
  /// 保证测试正文和失败兜底只清理资源一次。
  bool _disposed = false;

  /// 当前内存数据库。
  final AppDatabase database;

  /// 独立测试依赖容器。
  final ProviderContainer container;

  /// 用于延迟和失败注入的真实仓储子类。
  final _ControlledMoveRepository repository;

  /// 主物品标识。
  final String parentId;

  /// 继承位置配件标识。
  final String accessoryId;

  /// 可被停用的目标位置。
  final TaxonomyEntry destination;

  /// 保存安卓搬家夹具资源。
  _AndroidMoveFixture({
    required this.database,
    required this.container,
    required this.repository,
    required this.parentId,
    required this.accessoryId,
    required this.destination,
  });

  /// 在测试不变量检查前取消数据流并推进 Drift 的延迟清理。
  Future<void> dispose(WidgetTester tester) async {
    if (_disposed) return;
    _disposed = true;
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
  }
}

/// 保留真实业务行为，只控制读取和迁移的异步边界。
class _ControlledMoveRepository extends InventoryRepository {
  /// 是否让下次订阅读取失败。
  bool failReads = false;

  /// 可选的延迟读取结果。
  Completer<List<InventoryRecord>>? pendingRead;

  /// 可选的延迟迁移结果。
  Completer<InventoryMoveResult>? pendingMove;

  /// 已接收的迁移调用次数。
  int moveCalls = 0;

  /// 使用同一内存库构造可控仓储。
  _ControlledMoveRepository(super.database);

  /// 为数据加载错误和重试提供确定性的测试流。
  @override
  Stream<List<InventoryRecord>> watchAll({String query = ''}) {
    if (failReads) {
      return Stream<List<InventoryRecord>>.error(StateError('测试读取失败'));
    }
    // 本次订阅捕获固定的延迟结果，避免后续设置改变旧订阅。
    final Completer<List<InventoryRecord>>? pending = pendingRead;
    return pending == null
        ? super.watchAll(query: query)
        : pending.future.asStream();
  }

  /// 在真实迁移前暴露提交窗口并记录调用次数。
  @override
  Future<InventoryMoveResult> moveItems({
    required Set<String> itemIds,
    required String destinationLocationId,
  }) {
    moveCalls += 1;
    return pendingMove?.future ??
        super.moveItems(
          itemIds: itemIds,
          destinationLocationId: destinationLocationId,
        );
  }
}

/// 在独立根导航器中打开安卓全屏搬家路由。
Future<_AndroidMoveFixture> _pumpAndroidMove(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double textScale = 1,
  int extraItems = 0,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // 每个场景使用独立内存数据库。
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  // 规范位置仓储用于生成有效目标。
  final TaxonomyRepository taxonomy = TaxonomyRepository(database);
  // 来源位置。
  final TaxonomyEntry source = await _createLocation(
    database,
    taxonomy,
    '原位置',
    0,
  );
  // 目标位置。
  final TaxonomyEntry destination = await _createLocation(
    database,
    taxonomy,
    '目标位置',
    1,
  );
  // 可控制读取、提交结果但保留真实迁移的仓储。
  final _ControlledMoveRepository repository = _ControlledMoveRepository(
    database,
  );
  // 主物品的数量用于区分记录数和物品件数。
  final String parentId = await repository.save(
    InventoryDraft(
      name: '测试主物品',
      quantity: 2,
      location: source.name,
      locationIds: <String>{source.id},
    ),
  );
  // 配件无独立位置，应跟随主物品自动迁移。
  final String accessoryId = await repository.save(
    InventoryDraft(name: '随附配件', quantity: 3, parentItemId: parentId),
  );
  // 可选的更多物品保证布局测试具备真实滚动范围。
  for (int index = 0; index < extraItems; index += 1) {
    await repository.save(
      InventoryDraft(
        name: '滚动物品 $index',
        quantity: 1,
        location: source.name,
        locationIds: <String>{source.id},
      ),
    );
  }
  // 测试容器仅覆盖本功能所需的数据库和仓储。
  final ProviderContainer container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      inventoryRepositoryProvider.overrideWithValue(repository),
    ],
  );
  // 正文主动清理，失败路径仍通过幂等兜底释放数据库。
  final _AndroidMoveFixture fixture = _AndroidMoveFixture(
    database: database,
    container: container,
    repository: repository,
    parentId: parentId,
    accessoryId: accessoryId,
    destination: destination,
  );
  addTearDown(() => fixture.dispose(tester));
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.build(brightness: brightness)
            .copyWith(platform: TargetPlatform.android),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showInventoryMoveDialog(context),
                child: const Text('打开搬家'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开搬家'));
  await tester.pumpAndSettle();
  return fixture;
}

/// 创建并返回指定名称的测试位置。
Future<TaxonomyEntry> _createLocation(
  AppDatabase database,
  TaxonomyRepository repository,
  String name,
  int sortOrder,
) async {
  await repository.save(
    TaxonomyDraft(
      module: TaxonomyModule.inventory,
      kind: TaxonomyKind.location,
      name: name,
      colorValue: 0xFF1EA7A1,
      sortOrder: sortOrder,
    ),
  );
  return (database.select(database.taxonomyEntries)..where(
        (TaxonomyEntries table) =>
            table.module.equals(TaxonomyModule.inventory.name) &
            table.kind.equals(TaxonomyKind.location.name) &
            table.name.equals(name) &
            table.deletedAt.isNull(),
      ))
      .getSingle();
}
