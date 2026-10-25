import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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
import 'package:omni_butler/shared/search/global_search_dialog.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 通过真实页面检查宽窄窗口与明暗主题中的按压、取消和业务隔离。
void main() {
  // 两个布局各取一种主题，避免重复全排列延长数据库回归。
  for (final (double, Brightness) configuration in <(double, Brightness)>[
    (1440, Brightness.light),
    (700, Brightness.dark),
  ]) {
    testWidgets(
      '${configuration.$1.toInt()} ${configuration.$2.name}真实Windows入口只缩放内容',
      (WidgetTester tester) =>
          _verifyEntrypoints(tester, configuration.$1, configuration.$2),
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }
}

/// 用真实仓储、导航壳与业务条目验证共享反馈接入，不接触本地数据。
Future<void> _verifyEntrypoints(
  WidgetTester tester,
  double width,
  Brightness brightness,
) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  // 每个用例单独创建内存数据库与应用依赖。
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  // 与生产每日待办筛选使用同一自然日，避免固定旧日期落入历史。
  final DateTime now = DateUtils.dateOnly(DateTime.now())
      .add(const Duration(hours: 12));
  // 生产仓储创建父子任务及进度任务。
  final TodoRepository todos = TodoRepository(database);
  // 初始化异常时仍能安全释放已经创建的容器。
  ProviderContainer? container;
  try {
    await todos.save(
      TodoDraft(
        title: '整理工作区',
        scheduledDate: now,
        priorityQuadrant: TodoPriorityQuadrant.urgentImportant,
      ),
    );
    // 首个普通父任务用于首页与待办页的展开行为。
    final TodoRecord parent = await database
        .select(database.todoItems)
        .getSingle();
    await todos.save(
      TodoDraft(title: '收纳桌面线缆', parentId: parent.id, scheduledDate: now),
    );
    // 子任务完成按钮用于验证嵌套热区不会同时缩放父行。
    final TodoRecord child = (await database.select(database.todoItems).get())
        .singleWhere((TodoRecord item) => item.parentId == parent.id);
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
        ],
      ),
    );
    // 独立进度任务的标题和加一按钮共享同一个业务记录。
    final TodoRecord progress =
        (await database.select(database.todoItems).get()).singleWhere(
          (TodoRecord item) => item.taskType == 'progress',
        );
    // 真实物品卡片的稳定标识。
    final String inventoryId = await InventoryRepository(database).save(
      InventoryDraft(
        name: '工作台灯',
        quantity: 1,
        purchasePriceCents: 25900,
        purchaseDate: now.subtract(const Duration(days: 30)),
        location: '书房',
      ),
    );
    // 真实会员卡片的稳定标识，关闭自动续费避免时间推进产生支付记录。
    final String membershipId = await MembershipRepository(database).save(
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
    // 当前用例独占的偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        appDatabaseProvider.overrideWithValue(database),
        nowProvider.overrideWithValue(now),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.build(brightness: brightness)
              .copyWith(platform: TargetPlatform.windows),
          routerConfig: container.read(appRouterProvider),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final String route in <String>['/home', '/todos']) {
      container.read(appRouterProvider).go(route);
      await tester.pumpAndSettle();
      // 两个真实页面使用不同标题组件，但都应在取消时保持展开状态。
      final Finder parentTitle = find.text(parent.title).hitTestable();
      expect(parentTitle, findsOneWidget);
      // 独立记录取消前的子任务可见状态，不能将取消误判成展开操作。
      final bool childWasVisible = find
          .text(child.title)
          .hitTestable()
          .evaluate()
          .isNotEmpty;
      await _verifyPressCycle(tester, parentTitle, scales: false);
      // 右键取消不打开菜单，右键释放沿用原菜单入口且只缩放一层内容。
      await _verifySecondaryPressCycle(tester, parentTitle, cancel: true);
      await _verifySecondaryPressCycle(tester, parentTitle, cancel: false);
      expect(
        find.text(child.title).hitTestable().evaluate().isNotEmpty,
        childWasVisible,
      );
      // 再用真实松手验证完成按压不追加90毫秒压下，并保留原展开操作。
      if (childWasVisible) {
        await tester.tap(parentTitle);
        await tester.pumpAndSettle();
      }
      await _verifyPressCycle(
        tester,
        parentTitle,
        cancel: false,
        scales: false,
      );
      expect(find.text(child.title).hitTestable(), findsOneWidget);

      if (route == '/todos') {
        // 待办子行原本保留悬停和空点击操作，取消不能完成子任务。
        await _verifyPressCycle(
          tester,
          find.byKey(ValueKey<String>('todo-title-${child.id}')).hitTestable(),
        );
      }
      // 首页子任务叶标题只读，验证其真正可点击的完成按钮。
      final Finder childCheckbox = find
          .byKey(
            ValueKey<String>(
              route == '/home'
                  ? 'home-todo-checkbox-action-${child.id}'
                  : 'todo-completion-checkbox-${child.id}',
            ),
          )
          .hitTestable();
      await _verifyPressCycle(tester, childCheckbox);
      // 打开步骤面板的标题及其内嵌加一操作都需独立反馈。
      await _verifyPressCycle(
        tester,
        find
            .byKey(ValueKey<String>('progress-title-${progress.id}'))
            .hitTestable(),
        fixedContainer: find.byKey(
          ValueKey<String>('progress-task-${progress.id}'),
        ),
      );
      await _verifyPressCycle(
        tester,
        find
            .byKey(ValueKey<String>('progress-update-${progress.id}'))
            .hitTestable(),
        fixedContainer: find.byKey(
          ValueKey<String>('progress-task-${progress.id}'),
        ),
      );
      expect(find.byType(Dialog), findsNothing);
    }

    container.read(appRouterProvider).go('/inventory');
    await tester.pumpAndSettle();
    // 点击卡片名称属于整张物品卡片；背景与完整卡片边界保持不动。
    final Finder inventoryCard = find.byKey(
      ValueKey<String>('inventory-card-$inventoryId'),
    );
    await _verifyPressCycle(
      tester,
      find.byKey(ValueKey<String>('inventory-name-$inventoryId')).hitTestable(),
      fixedContainer: inventoryCard,
    );
    expect(find.byType(Dialog), findsNothing);

    container.read(appRouterProvider).go('/memberships');
    await tester.pumpAndSettle();
    // 会员卡片标题原本只读，续费按钮是卡片内真实可点击入口。
    final Finder membershipCard = find.byKey(
      ValueKey<String>('membership-card-$membershipId'),
    );
    await _verifyPressCycle(
      tester,
      find
          .byKey(ValueKey<String>('membership-renew-$membershipId'))
          .hitTestable(),
      fixedContainer: membershipCard,
    );
    expect(find.byType(Dialog), findsNothing);

    container.read(appRouterProvider).go('/settings');
    await tester.pumpAndSettle();
    // 宽窗是侧栏，窄窗是ChoiceChip，使用共同的真实分类文字定位。
    final Finder appearance = find.text('外观与主题').hitTestable();
    await _verifyPressCycle(tester, appearance);
    expect(find.text('调整当前设备的显示模式与视觉体验。'), findsNothing);
    await tester.tap(appearance);
    await tester.pumpAndSettle();
    expect(find.text('调整当前设备的显示模式与视觉体验。'), findsOneWidget);

    // 导航取消不能更换路由；侧栏或图标轨的Material均保持固定。
    final Finder homeNavigation = find.byKey(
      const ValueKey<String>('navigation-/home'),
    );
    await _verifyPressCycle(
      tester,
      homeNavigation,
      fixedContainer: homeNavigation,
    );
    expect(
      container.read(appRouterProvider).routeInformationProvider.value.uri.path,
      '/settings',
    );
    await tester.tap(homeNavigation);
    await tester.pumpAndSettle();
    expect(
      container.read(appRouterProvider).routeInformationProvider.value.uri.path,
      '/home',
    );

    // 搜索触发器取消不打开弹窗，有效点击仍打开原搜索流程。
    final Finder search = find.text('搜索待办、事件、物品和会员').hitTestable();
    await _verifyPressCycle(tester, search);
    expect(find.byType(GlobalSearchDialog), findsNothing);
    await tester.tap(search);
    await tester.pumpAndSettle();
    expect(find.byType(GlobalSearchDialog), findsOneWidget);
    await tester.enterText(
      find.descendant(
        of: find.byType(GlobalSearchDialog),
        matching: find.byType(TextField),
      ),
      '工作台灯',
    );
    await tester.pumpAndSettle();
    // 搜索结果同样经过真实查询，其取消不跳转也不关闭搜索。
    final Finder searchResult = find.descendant(
      of: find.byType(GlobalSearchDialog),
      matching: find.byWidgetPredicate(
        (Widget widget) => widget is Text && widget.data == '工作台灯',
      ),
    );
    await _verifyPressCycle(tester, searchResult);
    expect(find.byType(GlobalSearchDialog), findsOneWidget);
    expect(
      container.read(appRouterProvider).routeInformationProvider.value.uri.path,
      '/home',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // 所有完成与加一操作都被取消，真实数据库不得出现业务变更。
    expect(
      (await database.select(database.todoItems).get()).every(
        (TodoRecord item) => !item.isCompleted,
      ),
      isTrue,
    );
    expect(
      (await database.select(database.todoProgressSteps).get()).every(
        (TodoProgressStepRecord item) => !item.isCompleted,
      ),
      isTrue,
    );
    expect(
      (await database.select(database.inventoryItems).get()).single.quantity,
      1,
    );
    expect(
      (await database.select(database.memberships).get()).single.priceCents,
      9900,
    );
    expect(tester.takeException(), isNull);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container?.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    // 让数据库流先释放订阅，再等待关闭结束。
    final Future<void> closing = database.close();
    await tester.pump(const Duration(seconds: 1));
    await closing;
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }
}

/// 右键在原手势宿主中按下、取消或打开菜单，检查完整绘制矩阵与固定背景。
Future<void> _verifySecondaryPressCycle(
  WidgetTester tester,
  Finder target, {
  required bool cancel,
}) async {
  // 真正拥有右键识别器的原上下文表面。
  final Finder surface = _nearestAncestor(
    target,
    (Widget widget) => widget is OmniPressSurface,
  );
  // 背景与整行热区必须保持原来的屏幕矩形。
  final Rect original = tester.getRect(surface);
  // 读取文字到窗口的完整绘制变换，可发现父子重复缩放。
  final RenderBox content = tester.renderObject<RenderBox>(target);
  // 文字的布局尺寸始终不变。
  final Size layout = content.size;
  // 从现有右键手势发起真实按下，不直接调用业务函数。
  final TestGesture pointer = await tester.startGesture(
    tester.getCenter(target),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 150));
  await tester.pump(const Duration(milliseconds: 90));
  expect(content.getTransformTo(null).storage[0], closeTo(0.97, 0.00001));
  expect(content.size, layout);
  expect(tester.getRect(surface), original);
  expect(
    find.byKey(const ValueKey<String>('omni-windows-menu-surface')),
    findsNothing,
  );
  if (cancel) {
    await pointer.cancel();
  } else {
    await pointer.up();
  }
  await tester.pump();
  expect(
    find.byKey(const ValueKey<String>('omni-windows-menu-surface')),
    cancel ? findsNothing : findsOneWidget,
  );
  await tester.pump(const Duration(milliseconds: 80));
  expect(
    content.getTransformTo(null).storage[0],
    allOf(greaterThan(0.97), lessThan(1)),
  );
  await tester.pump(const Duration(milliseconds: 80));
  expect(content.getTransformTo(null).storage[0], closeTo(1, 0.00001));
  expect(tester.getRect(surface), original);
  if (!cancel) await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

/// 用实际鼠标事件采样内容矩阵，验证背景、热区及父内容不随之缩放。
Future<void> _verifyPressCycle(
  WidgetTester tester,
  Finder target, {
  Finder? fixedContainer,
  bool cancel = true,
  // 展开入口不再使用按压缩放。
  bool scales = true,
}) async {
  expect(target, findsOneWidget);
  // 标题从最近的内容祖先定位；按钮、导航等外层入口从后代定位。
  final Finder content = _pressContent(target);
  expect(content, findsOneWidget);
  // Material在Transform之外，检查其实际屏幕矩形而非仅检查配置尺寸。
  final Finder material = _nearestAncestor(
    content,
    (Widget widget) => widget is Material,
  );
  // 额外业务容器用于发现整行或整卡被错误缩放。
  final Finder fixed = fixedContainer ?? material;
  // 按下前完整的背景边界。
  final Rect materialBounds = tester.getRect(material);
  // 按下前业务容器边界。
  final Rect fixedBounds = tester.getRect(fixed);
  // 最近的可视内容必须处于原始状态。
  expect(_contentScale(tester, content), 1);
  // 选择标题左侧的安全内点，避免名称居中时触碰行末按钮。
  final Rect targetBounds = tester.getRect(target);
  // 鼠标沿用Windows实际命中与手势仲裁。
  final TestGesture gesture = await tester.startGesture(
    targetBounds.centerLeft +
        Offset(targetBounds.width > 16 ? 8 : targetBounds.width / 2, 0),
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump();
  // 原生InkWell可能等待点击候选，逐帧推进但不接近长按阈值。
  double sampledScale = _contentScale(tester, content);
  for (int frame = 0; frame < 12 && sampledScale == 1; frame++) {
    await tester.pump(const Duration(milliseconds: 15));
    sampledScale = _contentScale(tester, content);
  }
  expect(sampledScale, scales ? allOf(greaterThan(0.97), lessThan(1)) : 1);
  expect(tester.getRect(material), materialBounds);
  expect(tester.getRect(fixed), fixedBounds);
  await tester.pump(const Duration(milliseconds: 90));
  expect(_contentScale(tester, content), closeTo(scales ? 0.97 : 1, 0.00001));
  expect(tester.getRect(material), materialBounds);
  expect(tester.getRect(fixed), fixedBounds);
  // 子按钮按下不应让任何外层内容同时缩小。
  for (final Element ancestor
      in find
          .ancestor(of: content, matching: find.byType(OmniPressContent))
          .evaluate()) {
    expect(
      _contentScale(
        tester,
        find.byElementPredicate(
          (Element element) => identical(element, ancestor),
        ),
      ),
      1,
    );
  }
  if (cancel) {
    await gesture.cancel();
  } else {
    await gesture.up();
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 80));
  expect(
    _contentScale(tester, content),
    scales ? allOf(greaterThan(0.97), lessThan(1)) : 1,
  );
  await tester.pump(const Duration(milliseconds: 80));
  expect(_contentScale(tester, content), 1);
  expect(tester.getRect(material), materialBounds);
  expect(tester.getRect(fixed), fixedBounds);
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

/// 找到实际接收当前入口按压的最近内容层，排除兄弟按钮的Transform。
Finder _pressContent(Finder target) {
  // 按钮入口可能嵌在父行中，先选择自己拥有的内容层。
  final Finder ownContent = find.descendant(
    of: target,
    matching: find.byType(OmniPressContent),
  );
  if (ownContent.evaluate().isNotEmpty) return ownContent.first;
  // 文字入口位于内容层内部，再选择最近祖先。
  Element? content;
  target.evaluate().single.visitAncestorElements((Element element) {
    if (element.widget is OmniPressContent) {
      content = element;
      return false;
    }
    return true;
  });
  expect(content, isNotNull);
  return find.byElementPredicate(
    (Element element) => identical(element, content),
  );
}

/// 从内容层向外选择第一个满足类型要求的稳定绘制宿主。
Finder _nearestAncestor(Finder child, bool Function(Widget) predicate) {
  // 通过Element身份固定宿主，避免嵌套Material定位到其他按钮。
  Element? match;
  child.evaluate().single.visitAncestorElements((Element element) {
    if (predicate(element.widget)) {
      match = element;
      return false;
    }
    return true;
  });
  expect(match, isNotNull);
  return find.byElementPredicate(
    (Element element) => identical(element, match),
  );
}

/// 仅读取指定OmniPressContent直接绘制的矩阵，避开图标及原生组件变换。
double _contentScale(WidgetTester tester, Finder content) => tester
    .widget<Transform>(
      find.descendant(of: content, matching: find.byType(Transform)).first,
    )
    .transform
    .storage[0];
