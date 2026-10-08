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
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/features/events/data/event_repository.dart';
import 'package:omni_butler/features/home/data/quote_repository.dart';
import 'package:omni_butler/features/memberships/data/membership_repository.dart';
import 'package:omni_butler/features/timeline/data/time_entry_repository.dart';
import 'package:omni_butler/features/todos/data/todo_priority_quadrant.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 启动可由 adb 操作的真实首页，全部业务数据和偏好均留在内存。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    debugPrintSynchronously(
      'HOME_PREVIEW_FAIL: ${details.exception}\n${details.stack}',
    );
  };
  ui.PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    debugPrintSynchronously('HOME_PREVIEW_FAIL: $error\n$stack');
    return true;
  };

  // 以当前验收日期固定业务时钟，重启后截图和近期提醒保持一致。
  final DateTime now = DateTime(2026, 10, 8, 12, 40);
  SharedPreferences.setMockInitialValues(<String, Object>{
    'appearance.theme_mode': 'light',
    'sync.enabled': false,
    'home.cards.order': <String>[
      'quote',
      'todos',
      'timeStatus',
      'todayContext',
    ],
  });
  // 内存偏好实现不会读取或写入正式 SharedPreferences。
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  // 唯一业务数据库不建立任何本地数据库文件。
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  await _seedHome(database, now);

  // 覆盖所有数据入口，禁止正式数据库、设备会话和同步运行时初始化。
  final ProviderContainer container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      appDatabaseProvider.overrideWithValue(database),
      nowProvider.overrideWithValue(now),
      syncRuntimeProvider.overrideWithValue(null),
      authControllerProvider.overrideWith(_HomePreviewAuthController.new),
      authRepositoryProvider.overrideWith((Ref ref) {
        throw StateError('首页隔离预览禁止访问设备会话和远端同步');
      }),
    ],
  );
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const _HomePreviewApp(),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((Duration _) {
    debugPrintSynchronously(
      'HOME_PREVIEW_READY: date=2026-10-08; memory DB/preferences; '
      '12 normal todos + 1 progress todo; 2 time categories; '
      '3 events; 2 memberships; sync=null; production home/router',
    );
  });
}

/// 使用生产仓储建立能覆盖首页全部模块的隔离演示数据。
Future<void> _seedHome(AppDatabase database, DateTime now) async {
  // 所有演示事项共享的业务自然日。
  final DateTime today = DateUtils.dateOnly(now);
  await QuoteRepository(database)
      .save(const QuoteDraft(content: '求上得中，求中得下，求下无所得', source: '未署名'));

  // 三个父任务及九个子任务共十二条普通待办。
  const List<(String, TodoPriorityQuadrant, List<String>)> taskGroups =
      <(String, TodoPriorityQuadrant, List<String>)>[
        (
          '整理简历与项目经历',
          TodoPriorityQuadrant.urgentImportant,
          <String>['补充项目职责', '核对关键成果', '导出并检查 PDF'],
        ),
        (
          '双端功能更新',
          TodoPriorityQuadrant.importantNotUrgent,
          <String>['安卓首页交互验收', 'Windows 功能回归', '整理发布记录'],
        ),
        (
          '本周日常安排',
          TodoPriorityQuadrant.urgentNotImportant,
          <String>['确认快递时间', '整理采购清单', '预约设备清洁'],
        ),
      ];
  // 生产任务仓储负责生成合法父子关系及默认排序。
  final TodoRepository todos = TodoRepository(database);
  // 逐组建立父任务，再将子任务关联到其真实数据库身份。
  for (final (String, TodoPriorityQuadrant, List<String>) group in taskGroups) {
    await todos.save(
      TodoDraft(
        title: group.$1,
        scheduledDate: today,
        priorityQuadrant: group.$2,
      ),
    );
    // 刚创建父任务的稳定身份。
    final TodoRecord parent = await (database.select(
      database.todoItems,
    )..where((TodoItems table) => table.title.equals(group.$1))).getSingle();
    // 当前父任务需要展示的三个子任务。
    for (final String title in group.$3) {
      await todos.save(
        TodoDraft(
          title: title,
          parentId: parent.id,
          scheduledDate: today,
          priorityQuadrant: group.$2,
        ),
      );
    }
  }
  await todos.save(
    TodoDraft(
      title: '学习 CC 源码',
      scheduledDate: today,
      priorityQuadrant: TodoPriorityQuadrant.urgentImportant,
      taskType: TodoTaskType.progress,
      progressUnit: '章',
      progressSteps: List<TodoProgressStepDraft>.generate(
        12,
        (int index) => TodoProgressStepDraft(name: '第 ${index + 1} 章'),
      ),
    ),
  );
  // 已创建的唯一进度任务，用于展示真实的 2/12 进度。
  final TodoRecord progress = await (database.select(
    database.todoItems,
  )..where((TodoItems table) => table.taskType.equals('progress'))).getSingle();
  // 仓储返回的步骤身份用于生产进度更新接口。
  final List<TodoProgressStepRecord> steps = await todos
      .watchProgressSteps(progress.id)
      .first;
  await todos.setProgressStepsCompleted(
    progress.id,
    steps.take(2).map((TodoProgressStepRecord step) => step.id).toList(),
    true,
  );

  // 两种分类采用生产分类仓储，图例筛选和颜色均可交互验证。
  final TaxonomyRepository taxonomy = TaxonomyRepository(database);
  await taxonomy.save(
    const TaxonomyDraft(
      module: TaxonomyModule.timeline,
      kind: TaxonomyKind.category,
      name: '工作',
      colorValue: 0xFF3478F6,
    ),
  );
  await taxonomy.save(
    const TaxonomyDraft(
      module: TaxonomyModule.timeline,
      kind: TaxonomyKind.category,
      name: '学习',
      colorValue: 0xFF9270D9,
      sortOrder: 1,
    ),
  );
  // 时间记录全部完成，允许从首页 FAB 测试开始与结束流程。
  final TimeEntryRepository timeEntries = TimeEntryRepository(database);
  await timeEntries.save(
    TimeEntryDraft(
      activity: '安卓首页交互设计',
      category: '工作',
      startedAt: today.add(const Duration(hours: 9)),
      endedAt: today.add(const Duration(hours: 10, minutes: 30)),
    ),
  );
  await timeEntries.save(
    TimeEntryDraft(
      activity: '阅读 CC 核心源码',
      category: '学习',
      startedAt: today.add(const Duration(hours: 10, minutes: 45)),
      endedAt: today.add(const Duration(hours: 11, minutes: 30)),
    ),
  );

  // 三个事件分别在今天、两天后和六天后进入处理日期。
  final EventRepository events = EventRepository(database);
  // 名称与距离今天的应做天数。
  for (final (String, int) event in <(String, int)>[
    ('备份学习资料', 0),
    ('理发', 2),
    ('更换净水滤芯', 6),
  ]) {
    await events.save(
      EventDraft(
        name: event.$1,
        intervalValue: 7,
        intervalUnit: EventIntervalUnit.day,
        lastCompletedAt: today.subtract(Duration(days: 7 - event.$2)),
      ),
    );
  }

  // 两个会员都在近期到期，不开启自动续费或系统提醒。
  final MembershipRepository memberships = MembershipRepository(database);
  // 名称、剩余有效天数与价格分值。
  for (final (String, int, int) membership in <(String, int, int)>[
    ('学习资料会员', 3, 2900),
    ('云存储会员', 6, 1800),
  ]) {
    await memberships.save(
      MembershipDraft(
        name: membership.$1,
        priceCents: membership.$3,
        billingCycle: BillingCycle.month,
        purchaseDate: today.subtract(const Duration(days: 27)),
        expirationDate: today.add(Duration(days: membership.$2)),
        isPermanent: false,
        autoRenew: false,
      ),
    );
  }
}

/// 同步会话始终为空，不恢复任何设备凭据。
class _HomePreviewAuthController extends AuthController {
  /// 直接返回隔离的未登录状态，不读取认证仓储。
  @override
  Future<SyncSession?> build() async => null;
}

/// 仅组装生产主题和路由，不启动正式根应用的后台协调器。
class _HomePreviewApp extends ConsumerWidget {
  /// 创建隔离预览应用。
  const _HomePreviewApp();

  /// 保留生产首页、底栏和路由，同时使用内存主题偏好。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 当前演示会话的主题偏好。
    final ThemePreference preference = ref.watch(themeControllerProvider);
    return MaterialApp.router(
      title: 'Omni Butler · 首页隔离预览',
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
