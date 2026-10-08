import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/inventory/data/inventory_repository.dart';
import 'package:omni_butler/features/inventory/presentation/inventory_page.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证真实新增物品入口的全屏呈现、草稿校验及持久化保护。
void main() {
  testWidgets('物品新增覆盖根导航，折叠补充信息仍保存完整草稿', (WidgetTester tester) async {
    // 单模块真实页面隔离于已知预载首页的小屏问题。
    final _InventoryFixture fixture = await _pumpInventory(tester);
    await _openInventoryCreate(tester);
    expect(find.byType(OmniFullscreenFormScaffold), findsOneWidget);
    expect(fixture.root.currentState!.canPop(), isTrue);
    expect(fixture.inner.currentState!.canPop(), isFalse);
    expect(find.text('测试底栏').hitTestable(), findsNothing);
    expect(_key('inventory-create-url'), findsNothing);
    expect(tester.testTextInput.isVisible, isFalse);
    await _enterInventory(tester, 'inventory-create-name', '书桌台灯');
    await _enterInventory(tester, 'inventory-create-quantity', '2');
    await _enterInventory(tester, 'inventory-create-price', '89.90');
    await _toggleInventorySupplement(tester);
    await _enterInventory(tester, 'inventory-create-platform', '线下门店');
    await _enterInventory(
      tester,
      'inventory-create-url',
      'https://example.com/lamp',
    );
    await _enterInventory(tester, 'inventory-create-notes', '暖白灯光');
    await _toggleInventorySupplement(tester);
    expect(_key('inventory-create-notes'), findsNothing);
    await tester.tap(_key('inventory-create-submit'));
    await tester.pumpAndSettle();
    // 保存结果直接读取内存库，避免仅检查界面关闭。
    final InventoryRecord saved = await fixture.database
        .select(fixture.database.inventoryItems)
        .getSingle();
    expect(saved.name, '书桌台灯');
    expect(saved.quantity, 2);
    expect(saved.status, InventoryStatus.inUse.name);
    expect(saved.purchasePriceCents, 8990);
    expect(saved.purchasePlatform, '线下门店');
    expect(saved.purchaseUrl, 'https://example.com/lamp');
    expect(saved.notes, '暖白灯光');
    expect(find.byType(OmniFullscreenFormScaffold), findsNothing);
  });

  testWidgets('物品必填数量金额及隐藏链接校验定位，修正后可保存', (WidgetTester tester) async {
    // 无效输入始终留在同一份草稿中。
    final _InventoryFixture fixture = await _pumpInventory(tester);
    await _openInventoryCreate(tester);
    await tester.tap(_key('inventory-create-submit'));
    await tester.pumpAndSettle();
    expect(find.text('请输入物品名称').hitTestable(), findsOneWidget);
    await _enterInventory(tester, 'inventory-create-name', '保留的草稿');
    await _enterInventory(tester, 'inventory-create-quantity', '0');
    await tester.tap(_key('inventory-create-submit'));
    await tester.pumpAndSettle();
    expect(find.text('请输入正整数').hitTestable(), findsOneWidget);
    await _enterInventory(tester, 'inventory-create-quantity', '1');
    await _enterInventory(tester, 'inventory-create-price', '-10');
    await tester.tap(_key('inventory-create-submit'));
    await tester.pumpAndSettle();
    expect(find.text('请输入有效金额').hitTestable(), findsOneWidget);
    await _enterInventory(tester, 'inventory-create-price', '');
    await _toggleInventorySupplement(tester);
    await _enterInventory(tester, 'inventory-create-url', 'ftp://example.com');
    await _toggleInventorySupplement(tester);
    await tester.tap(_key('inventory-create-submit'));
    await tester.pumpAndSettle();
    expect(find.text('购买链接必须使用 http 或 https').hitTestable(), findsOneWidget);
    expect(_key('inventory-create-url').hitTestable(), findsOneWidget);
    expect(
      await fixture.database.select(fixture.database.inventoryItems).get(),
      isEmpty,
    );
    await _enterInventory(
      tester,
      'inventory-create-url',
      'https://example.com',
    );
    await _toggleInventorySupplement(tester);
    await tester.tap(_key('inventory-create-submit'));
    await tester.pumpAndSettle();
    expect(
      (await fixture.database
              .select(fixture.database.inventoryItems)
              .getSingle())
          .name,
      '保留的草稿',
    );
  });

  testWidgets('物品取消及系统返回不写入，返回原入口', (WidgetTester tester) async {
    // 两种退出都只关闭根导航上的当前表单。
    final _InventoryFixture fixture = await _pumpInventory(tester);
    await _openInventoryCreate(tester);
    await _enterInventory(tester, 'inventory-create-name', '取消的物品');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(OmniFullscreenFormScaffold), findsNothing);
    await _openInventoryCreate(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(OmniFullscreenFormScaffold), findsNothing);
    expect(fixture.inner.currentState!.canPop(), isFalse);
    expect(
      await fixture.database.select(fixture.database.inventoryItems).get(),
      isEmpty,
    );
  });

  testWidgets('物品保存期间防重和返回保护，失败保留草稿可重试', (WidgetTester tester) async {
    // 可控等待点仅替换提交，查询与真正写入保持生产行为。
    final _InventoryFixture fixture = await _pumpInventory(
      tester,
      size: const Size(320, 640),
      scale: 2,
    );
    await _openInventoryCreate(tester);
    await _enterInventory(tester, 'inventory-create-name', '重试的物品');
    fixture.repository.gate = Completer<void>();
    fixture.repository.fail = true;
    await tester.tap(_key('inventory-create-submit'));
    await tester.pump();
    await tester.tap(_key('inventory-create-submit'));
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(fixture.repository.calls, 1);
    expect(find.byType(OmniFullscreenFormScaffold), findsOneWidget);
    expect(tester.testTextInput.isVisible, isFalse);
    fixture.repository.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('保存失败，请重试').hitTestable(), findsOneWidget);
    expect(_input(tester, 'inventory-create-name').controller!.text, '重试的物品');
    fixture.repository.gate = null;
    fixture.repository.fail = false;
    await tester.tap(_key('inventory-create-submit'));
    await tester.pumpAndSettle();
    expect(fixture.repository.calls, 2);
    expect(
      await fixture.database.select(fixture.database.inventoryItems).get(),
      hasLength(1),
    );
    expect(find.byType(OmniFullscreenFormScaffold), findsNothing);
    expect(fixture.inner.currentState!.canPop(), isFalse);
  });

  // 窄屏、标准手机和安卓宽屏均使用同一全屏结构。
  for (final (Size, double, Brightness) sample in <(Size, double, Brightness)>[
    (const Size(320, 640), 2, Brightness.light),
    (const Size(390, 844), 1, Brightness.dark),
    (const Size(900, 1000), 2, Brightness.light),
  ]) {
    testWidgets('物品 ${sample.$1.width} 宽 ${sample.$2} 倍字键盘下顶栏固定', (
      WidgetTester tester,
    ) async {
      await _pumpInventory(
        tester,
        size: sample.$1,
        scale: sample.$2,
        brightness: sample.$3,
      );
      await _openInventoryCreate(tester);
      // 键盘和滚动只改变正文可用高度，顶部操作仍可触达。
      final Rect header = tester.getRect(find.text('新增物品'));
      await _enterInventory(tester, 'inventory-create-name', '布局检查');
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      await tester.pumpAndSettle();
      expect(tester.getRect(find.text('新增物品')), header);
      expect(_key('inventory-create-submit').hitTestable(), findsOneWidget);
      expect(find.text('取消').hitTestable(), findsOneWidget);
      await _toggleInventorySupplement(tester);
      await _enterInventory(tester, 'inventory-create-notes', '键盘下编辑备注');
      expect(_key('inventory-create-submit').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('安卓物品编辑与新增配套沿用原表单', (WidgetTester tester) async {
    // 先创建真实主物品，通过原列表菜单进入两个非目标流程。
    final _InventoryFixture fixture = await _pumpInventory(tester);
    await fixture.repository.save(
      const InventoryDraft(name: '已有台灯', quantity: 1),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.text('已有台灯'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(find.byType(OmniFullscreenFormScaffold), findsNothing);
    expect(find.byType(OmniSideSheetScaffold), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('已有台灯'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('配套物品'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加配套物品'));
    await tester.pumpAndSettle();
    expect(find.byType(OmniFullscreenFormScaffold), findsNothing);
    expect(
      find.descendant(
        of: find.byType(OmniSideSheetScaffold),
        matching: find.text('添加配套物品'),
      ),
      findsOneWidget,
    );
  });
}

/// 按稳定业务标识寻找控件。
Finder _key(String value) => find.byKey(ValueKey<String>(value));

/// 取共享输入下的原生字段，读取真实控制器状态。
TextFormField _input(WidgetTester tester, String key) =>
    tester.widget<TextFormField>(
      find.descendant(of: _key(key), matching: find.byType(TextFormField)),
    );

/// 打开页面实际提供的新增入口。
Future<void> _openInventoryCreate(WidgetTester tester) async {
  await tester.tap(_key('inventory-mobile-create'));
  await tester.pumpAndSettle();
}

/// 先滚入可见区域再输入，模拟长表单里的字段可访问性。
Future<void> _enterInventory(
  WidgetTester tester,
  String key,
  String value,
) async {
  await tester.ensureVisible(_key(key));
  await tester.pumpAndSettle();
  await tester.enterText(_key(key), value);
  await tester.pump();
}

/// 切换补充区域时由同一个生产按钮管理焦点与草稿。
Future<void> _toggleInventorySupplement(WidgetTester tester) async {
  // 仅当前表单的切换按钮包含补充信息文案。
  final Finder toggle = find.textContaining('补充信息');
  await tester.ensureVisible(toggle);
  await tester.pumpAndSettle();
  await tester.tap(toggle);
  await tester.pumpAndSettle();
}

/// 持有数据库、仓储及两层导航器的测试资源。
class _InventoryFixture {
  /// 内存业务库。
  final AppDatabase database;

  /// 带测试等待点的真实仓储。
  final _ControlledInventory repository;

  /// 全屏弹窗所在的根导航器。
  final GlobalKey<NavigatorState> root;

  /// 原管理页所在的嵌套导航器。
  final GlobalKey<NavigatorState> inner;

  /// 创建测试资源。
  const _InventoryFixture(
    this.database,
    this.repository,
    this.root,
    this.inner,
  );
}

/// 单挂真实生产页面，以验证表单而不预载其他业务页。
Future<_InventoryFixture> _pumpInventory(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double scale = 1,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  // 布局偏好与用户真实偏好隔离。
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  // 每个用例独立建库，不写真实数据。
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  // 查询与存储都沿用原仓储。
  final _ControlledInventory repository = _ControlledInventory(database);
  // 页面共用的可覆写依赖。
  final ProviderContainer container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      appDatabaseProvider.overrideWithValue(database),
      inventoryRepositoryProvider.overrideWithValue(repository),
      nowProvider.overrideWithValue(DateTime(2026, 10, 8, 12)),
    ],
  );
  // 显式根导航器验证表单覆盖完整应用。
  final GlobalKey<NavigatorState> root = GlobalKey<NavigatorState>();
  // 内部导航器验证取消不会退出管理页面。
  final GlobalKey<NavigatorState> inner = GlobalKey<NavigatorState>();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.pump();
    await database.close();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        navigatorKey: root,
        theme: AppTheme.build(brightness: brightness)
            .copyWith(platform: TargetPlatform.android),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: Navigator(
            key: inner,
            onGenerateRoute: (RouteSettings settings) =>
                MaterialPageRoute<void>(
                  builder: (BuildContext context) =>
                      const InventoryPage(embeddedInManagement: true),
                ),
          ),
          bottomNavigationBar: const SizedBox(
            height: 48,
            child: Center(child: Text('测试底栏')),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _InventoryFixture(database, repository, root, inner);
}

/// 仅提交可等待或失败，最终仍执行生产持久化。
class _ControlledInventory extends InventoryRepository {
  /// 模拟仓储异步等待。
  Completer<void>? gate;

  /// 模拟普通持久化异常。
  bool fail = false;

  /// 统计用户操作触发的调用次数。
  int calls = 0;

  /// 创建受控仓储。
  _ControlledInventory(super.database);

  /// 成功分支复用原仓储的全部校验和写入。
  @override
  Future<String> save(InventoryDraft draft) async {
    calls += 1;
    await gate?.future;
    if (fail) throw StateError('测试保存失败');
    return super.save(draft);
  }
}
