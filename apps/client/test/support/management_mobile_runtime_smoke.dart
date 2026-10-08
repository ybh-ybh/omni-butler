import 'dart:async';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/omni_scroll_behavior.dart';
import 'package:omni_butler/app/router/app_router.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_providers.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/sync/sync_providers.dart';
import 'package:omni_butler/features/events/data/event_repository.dart';
import 'package:omni_butler/features/inventory/data/inventory_repository.dart';
import 'package:omni_butler/features/management/presentation/management_mobile_scaffold.dart';
import 'package:omni_butler/features/memberships/data/membership_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 运行真实管理页，数据库与偏好仅驻留内存，不启动正式后台协调器。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    debugPrintSynchronously(
      'MANAGEMENT_PREVIEW_FAIL: ${details.exception}\n${details.stack}',
    );
  };
  ui.PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    debugPrintSynchronously('MANAGEMENT_PREVIEW_FAIL: $error\n$stack');
    return true;
  };
  // 固定验收日期，使统计趋势与预设名称保持可复核。
  final DateTime now = DateTime(2026, 10, 8, 12, 40);
  SharedPreferences.setMockInitialValues(<String, Object>{
    'appearance.theme_mode': 'light',
    'sync.enabled': false,
  });
  // 不访问正式设备偏好的内存实现。
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  // 不产生文件的内存业务数据库。
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  await _seedManagement(database, now);
  // 屏蔽凭据恢复、同步与正式数据库入口。
  final ProviderContainer container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      appDatabaseProvider.overrideWithValue(database),
      nowProvider.overrideWithValue(now),
      syncRuntimeProvider.overrideWithValue(null),
      authControllerProvider.overrideWith(_ManagementPreviewAuthController.new),
      authRepositoryProvider.overrideWith((Ref ref) {
        throw StateError('管理隔离预览禁止访问设备会话和远端同步');
      }),
    ],
  );
  container.read(appRouterProvider).go('/inventory');
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const _ManagementPreviewApp(),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((Duration _) {
    debugPrintSynchronously(
      'MANAGEMENT_PREVIEW_READY: memory DB/preferences; 24 inventory + 1 accessory; 18 events; 12 memberships; sync=null',
    );
  });
  Timer.periodic(
    const Duration(seconds: 5),
    (Timer timer) => _recordManagementState(container),
  );
}

/// 创建覆盖滚动、搜索、筛选、金额与日期的虚构演示记录。
Future<void> _seedManagement(AppDatabase database, DateTime now) async {
  // 不携带时分秒的统计自然日。
  final DateTime today = DateUtils.dateOnly(now);
  // 正式物品仓储负责建立主配套关系。
  final InventoryRepository inventory = InventoryRepository(database);
  // 首件物品额外关联一条配套，验证搜索命中回溯。
  String? firstItemId;
  for (int index = 0; index < 24; index++) {
    // 本条记录的稳定演示序号。
    final String number = (index + 1).toString().padLeft(2, '0');
    // 主物品标识只用于本内存库中的配套关联。
    final String itemId = await inventory.save(
      InventoryDraft(
        name: index == 0 ? '旅行相机与备用镜头' : '演示物品 $number',
        category: <String>['数码', '书籍', '家居'][index % 3],
        location: index.isEven ? '书房' : '客厅',
        tags: <String>[index.isEven ? '常用' : '备用'],
        quantity: index == 0 ? 3 : 1,
        purchasePriceCents: 10000 + index * 1390,
        purchaseDate: today.subtract(Duration(days: index * 20 + 30)),
        status: <InventoryStatus>[
          InventoryStatus.inUse,
          InventoryStatus.idle,
          InventoryStatus.lent,
        ][index % 3],
        notes: '隔离内存演示数据',
      ),
    );
    firstItemId ??= itemId;
  }
  await inventory.save(
    InventoryDraft(
      name: '相机肩带',
      parentItemId: firstItemId,
      category: '数码',
      location: '书房',
      quantity: 1,
      purchasePriceCents: 5000,
    ),
  );
  // 正式事件仓储负责初始化历史完成时间和下一应做日期。
  final EventRepository events = EventRepository(database);
  for (int index = 0; index < 18; index++) {
    await events.save(
      EventDraft(
        name: '演示事件 ${(index + 1).toString().padLeft(2, '0')}',
        description: index.isEven ? '家庭维护与检查' : '学习资料整理',
        intervalValue: 7,
        intervalUnit: EventIntervalUnit.day,
        lastCompletedAt: today.subtract(Duration(days: 11 - index % 12)),
      ),
    );
  }
  // 正式会员仓储创建真实首笔支付记录，供全量趋势统计使用。
  final MembershipRepository memberships = MembershipRepository(database);
  for (int index = 0; index < 12; index++) {
    await memberships.save(
      MembershipDraft(
        name: '演示会员 ${(index + 1).toString().padLeft(2, '0')}',
        category: index.isEven ? '学习' : '工具',
        description: '隔离内存演示服务',
        priceCents: 1900 + index * 500,
        billingCycle: BillingCycle.month,
        purchaseDate: today.subtract(
          Duration(days: index == 0 ? 30 : index * 3),
        ),
        expirationDate: today.add(Duration(days: index - 2)),
        isPermanent: false,
        autoRenew: index.isEven,
        renewalDate: index.isEven ? today.add(Duration(days: index % 3)) : null,
      ),
    );
  }
}

/// 只读记录当前管理分区的搜索与滚动，不触发业务动作或语义树滚动。
void _recordManagementState(ProviderContainer container) {
  // 本次采样的诊断文本。
  final List<String> values = <String>[
    'route=${container.read(appRouterProvider).routeInformationProvider.value.uri.path}',
  ];
  // Flutter 已存在的根元素。
  final Element? root = WidgetsBinding.instance.rootElement;
  if (root == null) return;

  /// 逐层读取活动管理页的公开控件状态。
  void visit(Element element) {
    // 当前控件的公开实例。
    final Widget widget = element.widget;
    // 控件所属管理分区当前是否可见。
    final bool active =
        element
            .findAncestorWidgetOfExactType<ManagementMobileScope>()
            ?.active ??
        false;
    if (active && widget is TextField) {
      values.add('query=${widget.controller?.text}');
    }
    if (active &&
        element is StatefulElement &&
        element.state is ScrollableState) {
      // 已布局的滚动位置，仅做诊断读取。
      final ScrollPosition position =
          (element.state as ScrollableState).position;
      if (position.hasPixels && position.hasContentDimensions) {
        values.add(
          '${position.axis.name}=${position.pixels.toStringAsFixed(1)}/${position.maxScrollExtent.toStringAsFixed(1)}',
        );
      }
    }
    if (widget is PageView &&
        widget.key ==
            const ValueKey<String>('android-management-swipe-surface')) {
      // 当前管理分页控制器，尚未布局时不读取 page。
      final PageController? controller = widget.controller;
      if (controller?.hasClients == true &&
          controller!.position.hasContentDimensions) {
        values.add('page=${controller.page}');
      }
    }
    element.visitChildElements(visit);
  }

  visit(root);
  debugPrintSynchronously('MANAGEMENT_PREVIEW_STATE: ${values.join(' | ')}');
}

/// 内存预览永远保持未登录，不恢复正式设备凭据。
class _ManagementPreviewAuthController extends AuthController {
  /// 直接提供空会话，避开认证仓储。
  @override
  Future<SyncSession?> build() async => null;
}

/// 复用生产主题、管理页、路由和底栏，不复制业务界面。
class _ManagementPreviewApp extends ConsumerWidget {
  /// 创建内存管理预览。
  const _ManagementPreviewApp();

  /// 仅启用前台应用所需的生产组件。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 当前仅存在内存中的主题偏好。
    final ThemePreference preference = ref.watch(themeControllerProvider);
    return MaterialApp.router(
      title: 'Omni Butler · 管理隔离预览',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(
        brightness: Brightness.light,
        palette: preference.palette,
      ),
      darkTheme: AppTheme.build(
        brightness: Brightness.dark,
        palette: preference.palette,
      ),
      themeMode: preference.mode,
      scrollBehavior: const OmniScrollBehavior(),
      routerConfig: ref.watch(appRouterProvider),
    );
  }
}
