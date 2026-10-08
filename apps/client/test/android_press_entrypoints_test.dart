import 'dart:convert';
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
import 'package:omni_butler/features/inventory/data/inventory_repository.dart';
import 'package:omni_butler/features/memberships/data/membership_repository.dart';
import 'package:omni_butler/features/todos/data/todo_priority_quadrant.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 检查真实路由上的8类条目，按需输出中文按下过程截图。
void main() {
  setUpAll(() async {
    if (Platform.environment['OMNI_PRESS_PREVIEW'] == null) return;
    // 仅预览模式读取本机字体，常规测试不依赖Windows字体资源。
    final ByteData font = ByteData.sublistView(
      await File(
        Platform.environment['OMNI_UI_FONT'] ?? 'C:/Windows/Fonts/msyh.ttc',
      ).readAsBytes(),
    );
    // 与现有中文预览一致，覆盖生产和测试字体别名。
    for (final String family in <String>[
      'Roboto',
      'Ahem',
      'Noto Sans CJK SC',
      'Microsoft YaHei UI',
      'Microsoft YaHei',
    ]) {
      // 每个别名独立注册真实中文字形。
      final FontLoader loader = FontLoader(family)
        ..addFont(Future<ByteData>.value(font));
      await loader.load();
    }
    // 真实图标字形来自SDK，避免截图只有占位热区。
    final FontLoader icons = FontLoader('MaterialIcons')
      ..addFont(
        File(
          Platform.environment['OMNI_UI_ICONS'] ??
              'D:/program/code/flutter/bin/cache/artifacts/material_fonts/'
                  'materialicons-regular.otf',
        ).readAsBytes().then(ByteData.sublistView),
      );
    await icons.load();
  });

  // 紧凑布局覆盖8类项，宽屏覆盖仍保有长按的首页和待办6类项。
  for (final double width in <double>[390, 1000]) {
    for (final Brightness brightness in Brightness.values) {
      testWidgets('$width ${brightness.name}真实业务条目接入统一反馈', (
        WidgetTester tester,
      ) async {
        await _verifyPages(tester, width, brightness);
      }, variant: TargetPlatformVariant.only(TargetPlatform.android));
    }
  }
}

/// 使用真实仓储和路由验证共享按下组件的覆盖范围。
Future<void> _verifyPages(
  WidgetTester tester,
  double width,
  Brightness brightness,
) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  // 每种布局独占内存数据，不读取用户本机数据库。
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  // 固定业务时钟以稳定标题和相对日期。
  final DateTime now = DateTime(2026, 10, 9, 12);
  // 生产任务仓储负责创建普通父子任务和进度任务。
  final TodoRepository todos = TodoRepository(database);
  // 可在初始化失败后安全清理的依赖容器。
  ProviderContainer? container;
  try {
    await todos.save(
      TodoDraft(
        title: '整理工作区',
        scheduledDate: now,
        priorityQuadrant: TodoPriorityQuadrant.urgentImportant,
      ),
    );
    // 当前普通根任务。
    final TodoRecord root = await database
        .select(database.todoItems)
        .getSingle();
    await todos.save(
      TodoDraft(title: '收纳桌面线缆', parentId: root.id, scheduledDate: now),
    );
    await todos.save(
      TodoDraft(
        title: '阅读设计书',
        scheduledDate: now,
        priorityQuadrant: TodoPriorityQuadrant.urgentImportant,
        taskType: TodoTaskType.progress,
        progressUnit: '章',
        progressSteps: const <TodoProgressStepDraft>[
          TodoProgressStepDraft(name: '第一章'),
          TodoProgressStepDraft(name: '第二章'),
          TodoProgressStepDraft(name: '第三章'),
        ],
      ),
    );
    await InventoryRepository(database).save(
      InventoryDraft(
        name: '工作台灯',
        quantity: 1,
        purchasePriceCents: 25900,
        purchaseDate: now.subtract(const Duration(days: 30)),
        location: '书房',
      ),
    );
    await MembershipRepository(database).save(
      MembershipDraft(
        name: '设计工具会员',
        priceCents: 9900,
        purchaseDate: now.subtract(const Duration(days: 10)),
        expirationDate: now.add(const Duration(days: 20)),
        billingCycle: BillingCycle.month,
        isPermanent: false,
        autoRenew: false,
      ),
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      'appearance.theme_mode': brightness.name,
      'home.cards.order': <String>['todos'],
    });
    // 本测试独立的偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        appDatabaseProvider.overrideWithValue(database),
        nowProvider.overrideWithValue(now),
      ],
    );
    // 包围真实导航层的完整截图边界。
    final GlobalKey boundary = GlobalKey();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: boundary,
          child: MaterialApp.router(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.build(brightness: brightness)
                .copyWith(platform: TargetPlatform.android),
            routerConfig: container.read(appRouterProvider),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 文件名前缀标识尺寸和主题。
    final String prefix = '${width.toInt()}-${brightness.name}';
    for (final String route in <String>['/home', '/todos']) {
      container.read(appRouterProvider).go(route);
      await tester.pumpAndSettle();
      // 当前页面的普通父任务标题。
      final Finder parent = find.text('整理工作区').hitTestable();
      expect(parent, findsOneWidget);
      await _checkPress(
        tester,
        boundary,
        parent,
        '$prefix-${route.substring(1)}-root',
      );
      // 两页共享树展开状态；先收起已展开项，再验证短按只展开子任务。
      if (find.text('收纳桌面线缆').hitTestable().evaluate().isNotEmpty) {
        await tester.tap(parent);
        await tester.pumpAndSettle();
        expect(find.text('收纳桌面线缆').hitTestable(), findsNothing);
      }
      await tester.tap(parent);
      await tester.pumpAndSettle();
      expect(find.text('收纳桌面线缆').hitTestable(), findsOneWidget);
      await _checkPress(
        tester,
        boundary,
        find.text('收纳桌面线缆').hitTestable(),
        '$prefix-${route.substring(1)}-child',
      );
      await _checkPress(
        tester,
        boundary,
        find.text('阅读设计书').hitTestable(),
        '$prefix-${route.substring(1)}-progress',
      );
      // 原长按菜单不能兼触发点击或完成。
      await tester.longPress(parent);
      await tester.pumpAndSettle();
      expect(
        find.text(route == '/home' ? '编辑任务' : '编辑').hitTestable(),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('收纳桌面线缆').hitTestable(), findsOneWidget);
    }
    if (width < 720) {
      container.read(appRouterProvider).go('/inventory');
      await tester.pumpAndSettle();
      await _checkPress(
        tester,
        boundary,
        find.text('工作台灯').hitTestable(),
        '$prefix-inventory',
      );
      await tester.longPress(find.text('工作台灯').hitTestable());
      await tester.pumpAndSettle();
      expect(find.text('编辑').hitTestable(), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      container.read(appRouterProvider).go('/memberships');
      await tester.pumpAndSettle();
      await _checkPress(
        tester,
        boundary,
        find.text('设计工具会员').hitTestable(),
        '$prefix-membership',
      );
      await tester.longPress(find.text('设计工具会员').hitTestable());
      await tester.pumpAndSettle();
      expect(find.text('支付记录').hitTestable(), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    }
    // 按下和取消以及菜单浏览均不改变任何任务完成状态。
    expect(
      (await database.select(database.todoItems).get()).every(
        (TodoRecord todo) => !todo.isCompleted,
      ),
      isTrue,
    );
    expect(
      (await database.select(database.todoProgressSteps).get()).every(
        (TodoProgressStepRecord step) => !step.isCompleted,
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container?.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    // 推进流缓存清理所需的假时钟后等待数据库关闭。
    final Future<void> closing = database.close();
    await tester.pump(const Duration(seconds: 1));
    await closing;
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }
}

/// 从真实标题追踪到交互表面，验证三个采样阶段和取消后的恢复。
Future<void> _checkPress(
  WidgetTester tester,
  GlobalKey boundary,
  Finder title,
  String name,
) async {
  expect(title, findsOneWidget);
  // 可见标题所在的共享交互表面。
  final Finder surface = find
      .ancestor(of: title, matching: find.byType(OmniPressSurface))
      .first;
  expect(surface, findsOneWidget);
  // 固定的布局尺寸不会随视觉缩放变化。
  final Rect bounds = tester.getRect(surface);
  // 标题旁的非中心触点，避开行内按钮和隐藏滚动区域。
  final Offset touch = tester.getRect(title).centerLeft + const Offset(8, 0);
  await _capture(tester, boundary, '$name-idle', bounds, touch);
  // 先检查原始按下而不让手势达到长按阈值。
  final TestGesture gesture = await tester.startGesture(touch);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 60));
  expect(_scale(tester, surface), allOf(lessThan(1), greaterThan(0.98)));
  await _capture(tester, boundary, '$name-060ms', bounds, touch);
  await tester.pump(const Duration(milliseconds: 60));
  expect(_scale(tester, surface), closeTo(0.98, 0.00001));
  await tester.pump(const Duration(milliseconds: 160));
  expect(tester.getRect(surface), bounds);
  await _capture(tester, boundary, '$name-280ms', bounds, touch);
  // PointerCancel必须恢复，不通过点击修改业务状态。
  await gesture.cancel();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 180));
  expect(_scale(tester, surface), 1);
  await _capture(tester, boundary, '$name-released', bounds, touch);
}

/// 当前条目最外侧可见缩放。
double _scale(WidgetTester tester, Finder surface) => tester
    .widget<Transform>(
      find.descendant(of: surface, matching: find.byType(Transform)).first,
    )
    .transform
    .storage[0];

/// 显式预览开关下保存生产页面的当前帧，常规回归不写截图。
Future<void> _capture(
  WidgetTester tester,
  GlobalKey key,
  String name,
  Rect bounds,
  Offset touch,
) async {
  // 可选输出目录；宽屏也保留完整页面证据。
  final String? output = Platform.environment['OMNI_PRESS_PREVIEW'];
  if (output == null) return;
  // 捕获当前帧，不能pumpAndSettle而丢失正在按下的中间状态。
  final RenderRepaintBoundary boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    // 当前完整页面像素。
    final ui.Image image = await boundary.toImage();
    try {
      // 无损图片与原条目坐标，供审查时并排查看各阶段。
      final ByteData bytes = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!;
      await Directory(output).create(recursive: true);
      await File('$output/$name.png').writeAsBytes(bytes.buffer.asUint8List());
      await File('$output/$name.json').writeAsString(
        jsonEncode(<String, Object>{
          'bounds': <double>[
            bounds.left,
            bounds.top,
            bounds.right,
            bounds.bottom,
          ],
          'touch': <double>[touch.dx, touch.dy],
        }),
      );
    } finally {
      image.dispose();
    }
  });
}
