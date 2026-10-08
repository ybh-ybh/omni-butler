import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/events/data/event_repository.dart';
import 'package:omni_butler/features/events/presentation/events_page.dart';
import 'package:omni_butler/features/memberships/data/membership_repository.dart';
import 'package:omni_butler/features/memberships/presentation/memberships_page.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 当前测试创建的资源在测试体退出前释放，避免计时器跨越框架检查。
final List<_FormFixture> _activeForms = <_FormFixture>[];

/// 从真实页面入口验证安卓新增会员与事件表单的保存及导航行为。
void main() {
  _testFormWidgets('事件全屏覆盖根导航，补充信息折叠后仍保值并保存', (WidgetTester tester) async {
    // 页面与仓储使用独立内存数据。
    final _FormFixture fixture = await _pumpFormPage(tester);
    await _openCreate(tester, membership: false);
    expect(find.byType(OmniFullscreenFormScaffold), findsOneWidget);
    expect(fixture.rootNavigator.currentState!.canPop(), isTrue);
    expect(fixture.innerNavigator.currentState!.canPop(), isFalse);
    expect(find.text('测试底部导航').hitTestable(), findsNothing);
    expect(_key('event-create-description'), findsNothing);
    await _enter(tester, 'event-create-name', '检查滤芯');
    await _toggleSupplement(tester);
    await _enter(tester, 'event-create-description', '每月检查清洁情况');
    await _enter(tester, 'event-create-notes', '保存折叠内容');
    await _toggleSupplement(tester);
    expect(_key('event-create-notes'), findsNothing);
    await tester.tap(_key('event-create-save'));
    await tester.pumpAndSettle();
    // 真实数据库中的事件草稿与默认提醒。
    final EventRecord record = await fixture.database
        .select(fixture.database.events)
        .getSingle();
    expect(record.name, '检查滤芯');
    expect(record.description, '每月检查清洁情况');
    expect(record.notes, '保存折叠内容');
    expect(record.intervalValue, 1);
    expect(record.intervalUnit, 'month');
    expect(record.reminderEnabled, isTrue);
    expect(record.reminderDaysBefore, 1);
    expect(record.reminderTimeMinutes, 540);
    expect(find.byType(OmniFullscreenFormScaffold), findsNothing);
  });

  _testFormWidgets('事件必填和周期校验保留草稿，取消及返回不落库', (WidgetTester tester) async {
    // 独立事件页面用于验证失败不会写入。
    final _FormFixture fixture = await _pumpFormPage(tester);
    await _openCreate(tester, membership: false);
    await tester.tap(_key('event-create-save'));
    await tester.pumpAndSettle();
    expect(find.text('请输入事件名称'), findsWidgets);
    await _enter(tester, 'event-create-name', '保留的事件');
    await _enter(tester, 'event-create-interval', '0');
    await tester.tap(_key('event-create-save'));
    await tester.pumpAndSettle();
    expect(find.text('请输入正整数'), findsOneWidget);
    expect(_textValue(tester, 'event-create-name'), '保留的事件');
    expect(
      await fixture.database.select(fixture.database.events).get(),
      isEmpty,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await _openCreate(tester, membership: false);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(OmniFullscreenFormScaffold), findsNothing);
    expect(
      await fixture.database.select(fixture.database.events).get(),
      isEmpty,
    );
  });

  _testFormWidgets('会员完整校验折叠官网，展开定位后可修正并保存补充信息', (WidgetTester tester) async {
    // 会员页面使用真实支付与分类仓储。
    final _FormFixture fixture = await _pumpFormPage(tester, membership: true);
    await _openCreate(tester, membership: true);
    expect(_key('membership-create-website'), findsNothing);
    await tester.tap(_key('membership-create-save'));
    await tester.pumpAndSettle();
    expect(find.text('请输入会员名称'), findsWidgets);
    await _enter(tester, 'membership-create-name', '云盘会员');
    await _enter(tester, 'membership-create-price', '99.50');
    await _toggleSupplement(tester);
    await _enter(tester, 'membership-create-description', '照片备份');
    await _enter(tester, 'membership-create-platform', '官方网站');
    await _enter(tester, 'membership-create-website', 'ftp://example.com');
    await _toggleSupplement(tester);
    await tester.tap(_key('membership-create-save'));
    await tester.pumpAndSettle();
    expect(find.text('官方网站 必须使用 http 或 https').hitTestable(), findsOneWidget);
    expect(_key('membership-create-website').hitTestable(), findsOneWidget);
    expect(
      await fixture.database.select(fixture.database.memberships).get(),
      isEmpty,
    );
    await _enter(tester, 'membership-create-website', 'https://example.com');
    await _toggleSupplement(tester);
    await tester.tap(_key('membership-create-save'));
    await tester.pumpAndSettle();
    // 已保存的会员及自动创建的首笔支付。
    final MembershipRecord record = await fixture.database
        .select(fixture.database.memberships)
        .getSingle();
    expect(record.name, '云盘会员');
    expect(record.priceCents, 9950);
    expect(record.description, '照片备份');
    expect(record.purchasePlatform, '官方网站');
    expect(record.websiteUrl, 'https://example.com');
    expect(record.isPermanent, isFalse);
    expect(record.billingCycle, 'year');
    expect(record.expirationReminderEnabled, isFalse);
    expect(
      (await fixture.database
              .select(fixture.database.membershipPayments)
              .getSingle())
          .amountCents,
      9950,
    );
  });

  _testFormWidgets('会员永久开关联动保留原有到期及续费语义', (WidgetTester tester) async {
    // 永久会员的保存仍通过原会员仓储。
    final _FormFixture fixture = await _pumpFormPage(tester, membership: true);
    await _openCreate(tester, membership: true);
    await _enter(tester, 'membership-create-name', '永久工具');
    await _enter(tester, 'membership-create-price', '0');
    await tester.ensureVisible(_key('membership-create-permanent'));
    await tester.tap(_key('membership-create-permanent'));
    await tester.pumpAndSettle();
    expect(find.text('自动续费'), findsNothing);
    expect(find.text('到期提醒'), findsNothing);
    await tester.tap(_key('membership-create-save'));
    await tester.pumpAndSettle();
    // 永久会员无需到期日，也不自动创建零金额支付。
    final MembershipRecord record = await fixture.database
        .select(fixture.database.memberships)
        .getSingle();
    expect(record.isPermanent, isTrue);
    expect(record.expirationDate, isNull);
    expect(record.autoRenew, isFalse);
    expect(record.billingCycle, 'permanent');
    expect(
      await fixture.database.select(fixture.database.membershipPayments).get(),
      isEmpty,
    );
  });

  _testFormWidgets('关闭会员提醒后无效隐藏天数恢复默认且合法天数保留', (WidgetTester tester) async {
    // 两轮新增均写入同一隔离数据库，分别覆盖无效与有效草稿。
    final _FormFixture fixture = await _pumpFormPage(tester, membership: true);
    // 关闭提醒后应回退默认值或保留用户已输入的合法天数。
    for (final String days in <String>['', '8']) {
      await _openCreate(tester, membership: true);
      await _enter(tester, 'membership-create-name', '关闭提醒$days');
      await _enter(tester, 'membership-create-price', '0');
      await tester.ensureVisible(_key('membership-create-reminder-toggle'));
      await tester.tap(_key('membership-create-reminder-toggle'));
      await tester.pumpAndSettle();
      await _enter(tester, 'membership-create-reminder', days);
      await tester.ensureVisible(_key('membership-create-reminder-toggle'));
      await tester.tap(_key('membership-create-reminder-toggle'));
      await tester.pumpAndSettle();
      await tester.tap(_key('membership-create-save'));
      await tester.pumpAndSettle();
      expect(find.byType(OmniFullscreenFormScaffold), findsNothing);
    }
    // 验证失效隐藏草稿不阻止提交，也不会丢弃合法值。
    final List<MembershipRecord> records = await fixture.database
        .select(fixture.database.memberships)
        .get();
    expect(
      records.map((MembershipRecord record) => record.expirationReminderDays),
      unorderedEquals(<int>[3, 8]),
    );
    expect(
      records.every(
        (MembershipRecord record) => !record.expirationReminderEnabled,
      ),
      isTrue,
    );
  });

  // 会员与事件共享相同的保存保护及安卓兼容验证。
  for (final bool membership in <bool>[false, true]) {
    _testFormWidgets('${membership ? '会员' : '事件'}保存中防重与返回保护，异常后可原样重试', (
      WidgetTester tester,
    ) async {
      // 可控等待只拦截保存，读取仍使用真实内存仓储。
      final _FormFixture fixture = await _pumpFormPage(
        tester,
        membership: membership,
      );
      // 第一轮保存延后并模拟普通仓储异常。
      final Completer<void> gate = Completer<void>();
      if (membership) {
        fixture.memberships.gate = gate;
        fixture.memberships.fail = true;
      } else {
        fixture.events.gate = gate;
        fixture.events.fail = true;
      }
      // 当前模块的稳定测试标识前缀。
      final String prefix = membership ? 'membership' : 'event';
      await _openCreate(tester, membership: membership);
      await _enter(tester, '$prefix-create-name', '重试草稿');
      if (membership) {
        await _enter(tester, 'membership-create-price', '10');
      }
      // 同一帧连续调用真实保存回调，验证业务防重而非仅按钮禁用。
      final VoidCallback submit = tester
          .widget<OmniFullscreenFormScaffold>(
            find.byType(OmniFullscreenFormScaffold),
          )
          .onPrimary!;
      submit();
      submit();
      await tester.pump();
      expect(membership ? fixture.memberships.calls : fixture.events.calls, 1);
      expect(
        tester
            .widget<OmniFullscreenFormScaffold>(
              find.byType(OmniFullscreenFormScaffold),
            )
            .loading,
        isTrue,
      );
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(OmniFullscreenFormScaffold), findsOneWidget);
      gate.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('保存失败，请重试'), findsOneWidget);
      expect(_key('$prefix-create-save-error'), findsOneWidget);
      expect(_key('$prefix-create-save').hitTestable(), findsOneWidget);
      expect(_textValue(tester, '$prefix-create-name'), '重试草稿');
      expect(
        tester
            .widget<OmniFullscreenFormScaffold>(
              find.byType(OmniFullscreenFormScaffold),
            )
            .loading,
        isFalse,
      );
      fixture.memberships.fail = false;
      fixture.events.fail = false;
      await tester.tap(_key('$prefix-create-save'));
      await tester.pumpAndSettle();
      expect(find.byType(OmniFullscreenFormScaffold), findsNothing);
      if (membership) {
        expect(
          await fixture.database.select(fixture.database.memberships).get(),
          hasLength(1),
        );
      } else {
        expect(
          await fixture.database.select(fixture.database.events).get(),
          hasLength(1),
        );
      }
    });

    _testFormWidgets('${membership ? '会员' : '事件'}320 宽双倍字号和键盘下顶栏固定且无溢出', (
      WidgetTester tester,
    ) async {
      await _pumpFormPage(
        tester,
        membership: membership,
        size: const Size(320, 680),
        textScale: 2,
      );
      await _openCreate(tester, membership: membership);
      // 键盘改变可用正文高度，顶部操作必须保持原位。
      final String prefix = membership ? 'membership' : 'event';
      // 键盘出现前的保存按钮位置。
      final Rect saveBefore = tester.getRect(_key('$prefix-create-save'));
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      await tester.pumpAndSettle();
      await _toggleSupplement(tester);
      expect(tester.getRect(_key('$prefix-create-save')), saveBefore);
      expect(_key('$prefix-create-save').hitTestable(), findsOneWidget);
      expect(find.text('取消').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
    });

    _testFormWidgets('${membership ? '会员' : '事件'}安卓编辑保持原侧滑表单', (
      WidgetTester tester,
    ) async {
      // 先通过真实仓储生成已有记录。
      final _FormFixture fixture = await _pumpFormPage(
        tester,
        membership: membership,
      );
      if (membership) {
        await fixture.memberships.save(
          MembershipDraft(
            name: '原有会员',
            priceCents: 1200,
            purchaseDate: DateTime(2026, 10, 1),
            expirationDate: DateTime(2027, 10, 1),
            isPermanent: false,
            autoRenew: false,
          ),
        );
      } else {
        await fixture.events.save(
          const EventDraft(
            name: '原有事件',
            intervalValue: 1,
            intervalUnit: EventIntervalUnit.month,
          ),
        );
      }
      await tester.pumpAndSettle();
      if (membership) {
        await tester.longPress(find.text('原有会员'));
      } else {
        await tester.tap(find.byTooltip('更多操作'));
      }
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      expect(find.byType(OmniSideSheetScaffold), findsOneWidget);
      expect(find.byType(OmniFullscreenFormScaffold), findsNothing);
      expect(find.text(membership ? '编辑会员' : '编辑周期事件'), findsOneWidget);
    });
  }
}

/// 在框架校验不变量前释放 Riverpod 订阅与 Drift 的延迟取消任务。
void _testFormWidgets(String description, WidgetTesterCallback body) {
  testWidgets(description, (WidgetTester tester) async {
    try {
      await body(tester);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      // 当前测试的全部依赖先取消订阅，再推进 Drift 零延迟清理。
      for (final _FormFixture fixture in _activeForms) {
        fixture.container.dispose();
        await tester.pump(const Duration(milliseconds: 100));
        await fixture.database.close();
      }
      _activeForms.clear();
      await tester.pump(const Duration(milliseconds: 100));
    }
  });
}

/// 使用稳定键查找当前可见业务控件。
Finder _key(String value) => find.byKey(ValueKey<String>(value));

/// 查找分组字段内部的实际文本输入框。
Finder _input(String key) =>
    find.descendant(of: _key(key), matching: find.byType(TextField));

/// 滚动到真实字段并输入，避免依赖当前屏幕高度。
Future<void> _enter(WidgetTester tester, String key, String value) async {
  await tester.ensureVisible(_key(key));
  await tester.enterText(_input(key), value);
  await tester.pumpAndSettle();
}

/// 读取真实输入框草稿。
String _textValue(WidgetTester tester, String key) =>
    tester.widget<TextField>(_input(key)).controller!.text;

/// 展开或收起正文末尾的补充信息。
Future<void> _toggleSupplement(WidgetTester tester) async {
  // 按钮文案会随展开状态变化，统一按其稳定语义片段查找。
  final Finder toggle = find.textContaining('补充信息');
  await tester.ensureVisible(toggle);
  await tester.tap(toggle);
  await tester.pumpAndSettle();
}

/// 从生产页面的浮动操作区打开新增表单。
Future<void> _openCreate(
  WidgetTester tester, {
  required bool membership,
}) async {
  await tester.tap(
    _key(membership ? 'membership-mobile-create' : 'event-mobile-create'),
  );
  await tester.pumpAndSettle();
}

/// 保存测试需要的数据库、导航器与可控仓储。
class _FormFixture {
  /// 测试内存数据库。
  final AppDatabase database;

  /// 显式释放页面监听器的依赖容器。
  final ProviderContainer container;

  /// 保存事件的真实仓储。
  final _ControlledEvents events;

  /// 保存会员的真实仓储。
  final _ControlledMemberships memberships;

  /// 模态表单应使用的根导航器。
  final GlobalKey<NavigatorState> rootNavigator;

  /// 模拟管理页面所在的嵌套导航器。
  final GlobalKey<NavigatorState> innerNavigator;

  /// 创建页面测试依赖。
  const _FormFixture({
    required this.database,
    required this.container,
    required this.events,
    required this.memberships,
    required this.rootNavigator,
    required this.innerNavigator,
  });
}

/// 构建真实单模块页面，避免与本次无关的预载首页布局影响断言。
Future<_FormFixture> _pumpFormPage(
  WidgetTester tester, {
  bool membership = false,
  Size size = const Size(390, 844),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  // 数据读写完全隔离于用户数据库。
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  // 仅提交时支持测试控制，其他事件仓储功能保持真实。
  final _ControlledEvents events = _ControlledEvents(database);
  // 仅提交时支持测试控制，其他会员仓储功能保持真实。
  final _ControlledMemberships memberships = _ControlledMemberships(database);
  // 页面及弹窗共用的依赖容器。
  final ProviderContainer container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      nowProvider.overrideWithValue(DateTime(2026, 10, 8, 10)),
      eventRepositoryProvider.overrideWithValue(events),
      membershipRepositoryProvider.overrideWithValue(memberships),
    ],
  );
  // 应承载新增路由的根导航器。
  final GlobalKey<NavigatorState> rootNavigator = GlobalKey<NavigatorState>();
  // 生产页面所在的嵌套导航器。
  final GlobalKey<NavigatorState> innerNavigator = GlobalKey<NavigatorState>();
  // 渲染前登记资源，即使后续页面构建失败也能在测试体内清理。
  final _FormFixture fixture = _FormFixture(
    database: database,
    container: container,
    events: events,
    memberships: memberships,
    rootNavigator: rootNavigator,
    innerNavigator: innerNavigator,
  );
  _activeForms.add(fixture);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        navigatorKey: rootNavigator,
        theme: AppTheme.build(brightness: Brightness.light)
            .copyWith(platform: TargetPlatform.android),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Navigator(
            key: innerNavigator,
            onGenerateRoute: (RouteSettings settings) =>
                MaterialPageRoute<void>(
                  builder: (BuildContext context) => membership
                      ? const MembershipsPage(embeddedInManagement: true)
                      : const EventsPage(embeddedInManagement: true),
                ),
          ),
          bottomNavigationBar: const SizedBox(
            height: 48,
            child: Center(child: Text('测试底部导航')),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fixture;
}

/// 保留真实数据写入的可控事件仓储。
class _ControlledEvents extends EventRepository {
  /// 可选保存等待点。
  Completer<void>? gate;

  /// 当前是否模拟普通持久化失败。
  bool fail = false;

  /// 真实保存入口调用次数。
  int calls = 0;

  /// 创建测试事件仓储。
  _ControlledEvents(super.database);

  /// 在实际保存前模拟等待或失败。
  @override
  Future<void> save(EventDraft draft) async {
    calls += 1;
    await gate?.future;
    if (fail) throw StateError('测试事件写入失败');
    await super.save(draft);
  }
}

/// 保留真实数据写入的可控会员仓储。
class _ControlledMemberships extends MembershipRepository {
  /// 可选保存等待点。
  Completer<void>? gate;

  /// 当前是否模拟普通持久化失败。
  bool fail = false;

  /// 真实保存入口调用次数。
  int calls = 0;

  /// 创建测试会员仓储。
  _ControlledMemberships(super.database);

  /// 在实际保存前模拟等待或失败。
  @override
  Future<String> save(MembershipDraft draft) async {
    calls += 1;
    await gate?.future;
    if (fail) throw StateError('测试会员写入失败');
    return super.save(draft);
  }
}
