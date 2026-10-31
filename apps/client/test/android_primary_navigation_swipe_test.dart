import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/omni_butler_app.dart';
import 'package:omni_butler/app/router/app_router.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/audio/microphone_coordinator.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_providers.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/assistant/data/assistant_cache.dart';
import 'package:omni_butler/features/notes/data/note_editor_controller.dart';
import 'package:omni_butler/features/notes/data/note_providers.dart';
import 'package:omni_butler/shared/layout/primary_navigation_swipe.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证 Android 紧凑布局的全局卡片式横滑导航。
void main() {
  test('分页吸附要求慢拖越过半页且快速滑动方向一致', () {
    expect(
      OmniPageSwipePhysics.shouldCommit(
        distance: -194,
        velocity: 0,
        viewportWidth: 390,
        targetDirection: 1,
      ),
      isFalse,
    );
    expect(
      OmniPageSwipePhysics.shouldCommit(
        distance: -195,
        velocity: 0,
        viewportWidth: 390,
        targetDirection: 1,
      ),
      isTrue,
    );
    expect(
      OmniPageSwipePhysics.shouldCommit(
        distance: -20,
        velocity: 600,
        viewportWidth: 390,
        targetDirection: 1,
      ),
      isFalse,
    );
    expect(
      OmniPageSwipePhysics.shouldCommit(
        distance: -20,
        velocity: -600,
        viewportWidth: 390,
        targetDirection: 1,
      ),
      isTrue,
    );
  });

  testWidgets('三个一级页面双向切换且拖动时展示真实卡片动效', (WidgetTester tester) async {
    // 当前测试使用的应用环境。
    final _PrimaryNavigationTestApp app = await _pumpPrimaryNavigationApp(
      tester,
    );
    expect(_currentPath(app.container), '/home');

    // Only the three core destinations occupy the Android navigation bar.
    for (final String path in <String>['home', 'notes', 'assistant']) {
      expect(find.byKey(ValueKey<String>('navigation-/$path')), findsOneWidget);
    }
    for (final String path in <String>[
      'todos',
      'timeline',
      'inventory',
      'settings',
    ]) {
      expect(find.byKey(ValueKey<String>('navigation-/$path')), findsNothing);
    }
    // Inspect the shared controller used by real primary gesture surfaces.
    final PrimaryNavigationSwipeController controller = _primaryController(
      tester,
    );
    controller.beginPrimarySwipe();
    controller.updatePrimarySwipe(-96);
    await tester.pump();

    // 当前时间卡片的缩放变换。
    final Transform currentScale = tester.widget<Transform>(
      find.byKey(const ValueKey<String>('primary-navigation-scale-0')),
    );
    // 正在进入的笔记卡片缩放变换。
    final Transform targetScale = tester.widget<Transform>(
      find.byKey(const ValueKey<String>('primary-navigation-scale-3')),
    );
    // 当前时间卡片的物理外观。
    final PhysicalModel currentCard = tester.widget<PhysicalModel>(
      find.byKey(const ValueKey<String>('primary-navigation-card-0')),
    );
    expect(currentScale.transform.storage[0], lessThan(1));
    expect(currentScale.transform.storage[0], greaterThan(0.985));
    expect(targetScale.transform.storage[0], greaterThan(0.985));
    expect(currentCard.elevation, greaterThan(0));
    expect(currentCard.borderRadius, isNot(BorderRadius.zero));
    expect(_currentPath(app.container), '/home');

    controller.updatePrimarySwipe(-256);
    controller.endPrimarySwipe(0);
    await tester.pumpAndSettle();
    expect(_currentPath(app.container), '/notes');
    await _swipePrimary(tester, -220);
    expect(_currentPath(app.container), '/assistant');
    // The assistant is the final destination and does not wrap to home.
    await _swipePrimary(tester, -220);
    expect(_currentPath(app.container), '/assistant');

    // Reverse navigation visits only the two remaining primary destinations.
    for (final String expectedPath in <String>['/notes', '/home']) {
      await _swipePrimary(tester, 220);
      expect(_currentPath(app.container), expectedPath);
    }
    // 首页到达首端后不会循环到更多页。
    await _swipePrimary(tester, 220);
    expect(_currentPath(app.container), '/home');

    await _disposePrimaryNavigationApp(tester, app);
  });

  testWidgets('短拖回弹、底栏同款动画并跳过已关闭入口', (WidgetTester tester) async {
    // Disabling notes leaves home and the assistant as primary destinations.
    final _PrimaryNavigationTestApp app = await _pumpPrimaryNavigationApp(
      tester,
      preferences: <String, Object>{
        'appearance.theme_mode': 'light',
        'features.todos.enabled': false,
        'features.timeline.enabled': false,
        'features.notes.enabled': false,
      },
    );

    await _swipePrimary(tester, -20);
    expect(_currentPath(app.container), '/home');
    await _swipePrimary(tester, -10, velocity: -600);
    expect(_currentPath(app.container), '/assistant');

    await tester.tap(find.byKey(const ValueKey<String>('navigation-/home')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.byKey(const ValueKey<String>('primary-navigation-scale-6')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('primary-navigation-scale-0')),
      findsOneWidget,
    );
    expect(_currentPath(app.container), '/assistant');
    await tester.pumpAndSettle();
    expect(_currentPath(app.container), '/home');

    await _disposePrimaryNavigationApp(tester, app);
  });

  testWidgets('一级页面吸附逐帧匹配原生分页且连续拖动不跳回', (WidgetTester tester) async {
    // 当前测试使用的完整 Android 应用。
    final _PrimaryNavigationTestApp app = await _pumpPrimaryNavigationApp(
      tester,
    );
    // 页面真实手势使用的一级横滑控制器。
    final PrimaryNavigationSwipeController controller = _primaryController(
      tester,
    );
    // 统计卡片原生分页在同样距离和离手速度下的参考轨迹。
    final Simulation reference = const PageScrollPhysics()
        .createBallisticSimulation(
          FixedScrollMetrics(
            minScrollExtent: 0,
            maxScrollExtent: 390,
            pixels: 120,
            viewportDimension: 390,
            axisDirection: AxisDirection.right,
            devicePixelRatio: 1,
          ),
          900,
        )!;
    controller.beginPrimarySwipe();
    controller.updatePrimarySwipe(-120);
    controller.endPrimarySwipe(-900);
    await tester.pump();

    // 逐帧累计时间，用于与原生弹簧的秒数对齐。
    int elapsedMilliseconds = 0;
    // 松手后早期、中段和接近落位的采样间隔。
    for (final int deltaMilliseconds in <int>[16, 84, 200]) {
      elapsedMilliseconds += deltaMilliseconds;
      await tester.pump(Duration(milliseconds: deltaMilliseconds));
      expect(
        _primaryOffset(tester, 0),
        closeTo(-reference.x(elapsedMilliseconds / 1000), 0.01),
      );
    }
    expect(_currentPath(app.container), '/home');

    // 尚未结束的弹簧位置应成为下一次拖动起点。
    final double interruptedOffset = _primaryOffset(tester, 0);
    controller.beginPrimarySwipe();
    await tester.pump();
    expect(_primaryOffset(tester, 0), closeTo(interruptedOffset, 0.01));
    controller.updatePrimarySwipe(12);
    await tester.pump();
    expect(_primaryOffset(tester, 0), closeTo(interruptedOffset + 12, 0.01));
    controller.endPrimarySwipe(900);
    await tester.pumpAndSettle();
    expect(_currentPath(app.container), '/home');
    expect(_primaryOffset(tester, 0), 0);

    // 临近终点高速甩动不能越界露白，也不能留下未完成的路由切换。
    controller.beginPrimarySwipe();
    controller.updatePrimarySwipe(-380);
    controller.endPrimarySwipe(-8000);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(_currentPath(app.container), '/notes');
    expect(_primaryOffset(tester, 3), 0);
    await tester.pumpAndSettle();

    // 反向拖过半页后向原页甩回，原生落点应取消提交。
    await _swipePrimary(tester, 220, velocity: -900);
    expect(_currentPath(app.container), '/notes');
    await _swipePrimary(tester, 120, velocity: 900);
    expect(_currentPath(app.container), '/home');

    // 已经完整到位时，即便离手反向也应原地提交，不能先退回再吸附。
    controller.beginPrimarySwipe();
    controller.updatePrimarySwipe(-390);
    controller.endPrimarySwipe(600);
    await tester.pump();
    expect(_currentPath(app.container), '/notes');
    expect(_primaryOffset(tester, 3), 0);
    await _disposePrimaryNavigationApp(tester, app);
  });

  testWidgets('辅助服务开启时连续快滑可接手吸附并跨过多个一级页面', (WidgetTester tester) async {
    // 开启辅助导航但没有要求禁用动画的完整 Android 应用。
    final _PrimaryNavigationTestApp app = await _pumpPrimaryNavigationApp(
      tester,
    );
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(accessibleNavigation: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pump();
    // Continue primary gestures before the previous spring reaches its end.
    for (final int targetIndex in <int>[3, 6]) {
      _primaryController(tester).beginPrimarySwipe();
      _primaryController(tester).updatePrimarySwipe(-230);
      _primaryController(tester).endPrimarySwipe(-900);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.hasRunningAnimations, isTrue);
      expect(_primaryOffset(tester, targetIndex), inExclusiveRange(0, 195));
    }
    await tester.pumpAndSettle();
    expect(_currentPath(app.container), '/assistant');
    expect(_primaryOffset(tester, 6), 0);
    // 反向也可在旧动画结束前连续接手，且不会被旧回调跳回。
    for (final int targetIndex in <int>[3, 0]) {
      _primaryController(tester).beginPrimarySwipe();
      _primaryController(tester).updatePrimarySwipe(230);
      _primaryController(tester).endPrimarySwipe(900);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(_primaryOffset(tester, targetIndex), inExclusiveRange(-195, 0));
    }
    await tester.pumpAndSettle();
    expect(_currentPath(app.container), '/home');
    expect(tester.takeException(), isNull);
    await _disposePrimaryNavigationApp(tester, app);
  });

  testWidgets('管理连续真实快滑保持顶部固定且首尾不接力一级导航', (WidgetTester tester) async {
    // 管理使用独立原生分页，手势不会越过分区边界。
    final _PrimaryNavigationTestApp app = await _pumpPrimaryNavigationApp(
      tester,
    );
    app.container.read(appRouterProvider).go('/events');
    await tester.pumpAndSettle();
    // 管理顶部也不能随内容页切换而移动。
    final Rect managementHeader = tester.getRect(
      find.byKey(const ValueKey<String>('management-section-control')),
    );
    // 两次真实快速滑动在前一吸附尚未完成时接续执行。
    for (final int index in <int>[1, 2]) {
      await _dragNestedPage(
        tester,
        'android-management-swipe-surface',
        -250,
        1500,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester.getRect(
          find.byKey(const ValueKey<String>('management-section-control')),
        ),
        managementHeader,
      );
      // 当前分页已越过下一页中点，不依赖任何旧手势回调。
      final PageView pages = tester.widget<PageView>(
        find.byKey(const ValueKey<String>('android-management-swipe-surface')),
      );
      expect(pages.controller!.page, greaterThan(index - 0.5));
    }
    await tester.pumpAndSettle();
    expect(_currentPath(app.container), '/inventory');
    await _dragNestedPage(
      tester,
      'android-management-swipe-surface',
      -250,
      1500,
    );
    await tester.pumpAndSettle();
    expect(_currentPath(app.container), '/inventory');
    // 反向快速连续切回事件，再从首项右滑仍停留事件。
    for (final int index in <int>[1, 0]) {
      await _dragNestedPage(
        tester,
        'android-management-swipe-surface',
        250,
        1500,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // 反向分页也应跨过对应分区的中点。
      final PageView pages = tester.widget<PageView>(
        find.byKey(const ValueKey<String>('android-management-swipe-surface')),
      );
      expect(pages.controller!.page, lessThan(index + 0.5));
      expect(
        tester.getRect(
          find.byKey(const ValueKey<String>('management-section-control')),
        ),
        managementHeader,
      );
    }
    await tester.pumpAndSettle();
    expect(_currentPath(app.container), '/events');
    await _dragNestedPage(
      tester,
      'android-management-swipe-surface',
      250,
      1500,
    );
    await tester.pumpAndSettle();
    expect(_currentPath(app.container), '/events');
    expect(tester.takeException(), isNull);
    await _disposePrimaryNavigationApp(tester, app);
  });

  testWidgets('次级页面禁用一级横滑且返回保留首页 Navigator', (WidgetTester tester) async {
    // The secondary route shares the retained home navigator.
    final _PrimaryNavigationTestApp app = await _pumpPrimaryNavigationApp(
      tester,
    );
    // The same shell state must survive the push and subsequent pop.
    final Object shellState = tester.state(
      find.byType(PrimaryNavigationBranchContainer),
    );
    unawaited(app.container.read(appRouterProvider).push<void>('/todos'));
    await tester.pumpAndSettle();
    expect(_currentPath(app.container), '/todos');
    expect(
      find.byKey(const ValueKey<String>('compact-navigation')),
      findsNothing,
    );
    await _swipePrimary(tester, -250, velocity: -1000);
    expect(_currentPath(app.container), '/todos');
    expect(_primaryOffset(tester, 0), 0);
    app.container.read(appRouterProvider).pop();
    await tester.pumpAndSettle();
    expect(_currentPath(app.container), '/home');
    expect(
      tester.state(find.byType(PrimaryNavigationBranchContainer)),
      same(shellState),
    );
    await _swipePrimary(tester, -250);
    expect(_currentPath(app.container), '/notes');
    await _disposePrimaryNavigationApp(tester, app);
  });

  testWidgets('笔记保存失败阻止底栏与横滑并可安全打断回弹', (WidgetTester tester) async {
    // A controlled editor retains the production page and router lifecycle.
    final _PrimaryNavigationTestApp app = await _pumpPrimaryNavigationApp(
      tester,
      controlledEditor: true,
    );
    app.container.read(appRouterProvider).go('/notes');
    await tester.pumpAndSettle();
    // Fail the persistence seam without discarding the actual editor draft.
    final _ControlledExitNoteEditor editor =
        app.container.read(noteEditorProvider) as _ControlledExitNoteEditor;
    editor.armed = true;
    editor.dirty = true;
    await tester.tap(
      find.byKey(const ValueKey<String>('navigation-/assistant')),
    );
    await tester.pumpAndSettle();
    expect(_currentPath(app.container), '/notes');
    expect(_primaryOffset(tester, 3), 0);
    // Reject a committed drag and grab the failing bounce before its midpoint.
    final PrimaryNavigationSwipeController controller = _primaryController(
      tester,
    );
    controller.beginPrimarySwipe();
    controller.updatePrimarySwipe(-300);
    controller.endPrimarySwipe(-900);
    await tester.pump();
    controller.beginPrimarySwipe();
    controller.updatePrimarySwipe(-20);
    controller.endPrimarySwipe(-900);
    await tester.pumpAndSettle();
    expect(_currentPath(app.container), '/notes');
    expect(_primaryOffset(tester, 3), 0);
    expect(editor.dirty, isTrue);
    // Exceptions from the same save boundary also preserve the visible note.
    editor.throwOnFailure = true;
    await tester.tap(find.byKey(const ValueKey<String>('navigation-/home')));
    await tester.pumpAndSettle();
    expect(_currentPath(app.container), '/notes');
    expect(_primaryOffset(tester, 3), 0);
    expect(tester.takeException(), isNull);
    await _disposePrimaryNavigationApp(tester, app);
  });

  testWidgets('笔记保存等待期间合并重复导航且路由最终拒绝恢复视觉', (WidgetTester tester) async {
    // Delay the first save to exercise overlapping bottom-tab and swipe input.
    final _PrimaryNavigationTestApp app = await _pumpPrimaryNavigationApp(
      tester,
      controlledEditor: true,
    );
    app.container.read(appRouterProvider).go('/notes');
    await tester.pumpAndSettle();
    // The save gate has no timers and resolves only when this test releases it.
    final _ControlledExitNoteEditor editor =
        app.container.read(noteEditorProvider) as _ControlledExitNoteEditor;
    editor.armed = true;
    editor.dirty = true;
    editor.gate = Completer<void>();
    await tester.tap(
      find.byKey(const ValueKey<String>('navigation-/assistant')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('navigation-/home')));
    _primaryController(tester).beginPrimarySwipe();
    _primaryController(tester).updatePrimarySwipe(300);
    _primaryController(tester).endPrimarySwipe(900);
    await tester.pump();
    expect(editor.attempts, 1);
    expect(_currentPath(app.container), '/notes');
    editor.gate!.complete();
    await tester.pumpAndSettle();
    expect(_primaryOffset(tester, 3), 0);
    // The preflight succeeds but the router's final onExit rejects its save.
    editor.gate = null;
    editor.attempts = 0;
    editor.callSites.clear();
    editor.failFromAttempt = 2;
    await tester.tap(
      find.byKey(const ValueKey<String>('navigation-/assistant')),
    );
    await tester.pumpAndSettle();
    // The workspace's existing route listener also flushes before onExit runs.
    expect(editor.callSites, hasLength(3), reason: editor.callSites.join('\n'));
    expect(
      editor.callSites.where((site) => site.contains('_prepareBranchChange')),
      hasLength(1),
    );
    expect(
      editor.callSites.where((site) => site.contains('_routeChanged')),
      hasLength(1),
    );
    expect(
      editor.callSites.where((site) => site.contains('app_router.dart')),
      hasLength(1),
    );
    expect(_currentPath(app.container), '/notes');
    expect(_primaryOffset(tester, 3), 0);
    expect(
      find.byKey(const ValueKey<String>('primary-navigation-card-6')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await _disposePrimaryNavigationApp(tester, app);
  });

  testWidgets('AI 离开立即取消语音并等待草稿保存后才开始切页', (WidgetTester tester) async {
    // The real assistant page registers its normal cancellation callback.
    final _PrimaryNavigationTestApp app = await _pumpPrimaryNavigationApp(
      tester,
    );
    app.container.read(appRouterProvider).go('/assistant');
    await tester.pumpAndSettle();
    // A second owner exposes the exact lifecycle completion boundary.
    final VoiceInputLifecycle lifecycle = app.container.read(
      voiceInputLifecycleProvider,
    );
    // Only this test owns the delayed cancellation callback.
    final Object owner = Object();
    // Cleanup stays pending until the user-visible navigation checks finish.
    final Completer<void> cancellation = Completer<void>();
    // Count callback starts to detect repeated navigation during cancellation.
    int cancellationCalls = 0;
    lifecycle.register(owner, () {
      cancellationCalls++;
      return cancellation.future;
    });
    addTearDown(() => lifecycle.unregister(owner));
    await tester.tap(find.byKey(const ValueKey<String>('navigation-/home')));
    expect(cancellationCalls, 1);
    expect(_currentPath(app.container), '/assistant');
    expect(_primaryOffset(tester, 6), 0);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey<String>('navigation-/notes')));
    _primaryController(tester).beginPrimarySwipe();
    _primaryController(tester).updatePrimarySwipe(300);
    _primaryController(tester).endPrimarySwipe(900);
    await tester.pump(const Duration(milliseconds: 100));
    expect(cancellationCalls, 1);
    expect(_currentPath(app.container), '/assistant');
    expect(_primaryOffset(tester, 6), 0);
    // Wait for both the controlled owner and the real SQLite draft flush.
    await tester.runAsync(() async {
      cancellation.complete();
      await lifecycle.cancelAll();
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_currentPath(app.container), '/assistant');
    expect(_primaryOffset(tester, 6), greaterThan(0));
    await tester.pumpAndSettle();
    expect(_currentPath(app.container), '/home');
    lifecycle.unregister(owner);
    await _disposePrimaryNavigationApp(tester, app);
  });

  testWidgets('AI 横滑取消等待被外部导航接管后旧等待不能触发回弹', (WidgetTester tester) async {
    // Exercise actual shell routing while the assistant lifecycle is pending.
    final _PrimaryNavigationTestApp app = await _pumpPrimaryNavigationApp(
      tester,
    );
    app.container.read(appRouterProvider).go('/assistant');
    await tester.pumpAndSettle();
    // Keep one registered cancellation pending across the external route change.
    final VoiceInputLifecycle lifecycle = app.container.read(
      voiceInputLifecycleProvider,
    );
    // This owner is removed independently from the assistant's real callback.
    final Object owner = Object();
    // The old gesture can finish only after home has started its own transition.
    final Completer<void> cancellation = Completer<void>();
    lifecycle.register(owner, () => cancellation.future);
    addTearDown(() => lifecycle.unregister(owner));
    // A rightward AI swipe would normally commit the adjacent notes branch.
    final PrimaryNavigationSwipeController controller = _primaryController(
      tester,
    );
    controller.beginPrimarySwipe();
    controller.updatePrimarySwipe(300);
    controller.endPrimarySwipe(900);
    await tester.pump();
    expect(_currentPath(app.container), '/assistant');
    expect(_primaryOffset(tester, 6), 300);
    app.container.read(appRouterProvider).go('/home');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(_currentPath(app.container), '/home');
    expect(_primaryOffset(tester, 6), inExclusiveRange(0, 390));
    // Complete real SQLite work without advancing the replacement animation.
    await tester.runAsync(() async {
      cancellation.complete();
      await lifecycle.cancelAll();
    });
    await tester.pumpAndSettle();
    expect(_currentPath(app.container), '/home');
    expect(_primaryOffset(tester, 0), 0);
    expect(
      find.byKey(const ValueKey<String>('primary-navigation-card-6')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    lifecycle.unregister(owner);
    await _disposePrimaryNavigationApp(tester, app);
  });

  testWidgets('AI 退出保存失败保持当前页且反向接手不能绕过取消', (WidgetTester tester) async {
    // Use the normal branch stack so visibility and route checks stay real.
    final _PrimaryNavigationTestApp app = await _pumpPrimaryNavigationApp(
      tester,
    );
    app.container.read(appRouterProvider).go('/assistant');
    await tester.pumpAndSettle();
    // This registered callback simulates a local draft persistence failure.
    final VoiceInputLifecycle lifecycle = app.container.read(
      voiceInputLifecycleProvider,
    );
    // An independent owner avoids replacing the assistant's own callback.
    final Object owner = Object();
    lifecycle.register(owner, () async {
      throw StateError('模拟草稿保存失败');
    });
    addTearDown(() => lifecycle.unregister(owner));
    await tester.tap(find.byKey(const ValueKey<String>('navigation-/home')));
    await tester.pumpAndSettle();
    expect(_currentPath(app.container), '/assistant');
    expect(_primaryOffset(tester, 6), 0);
    expect(find.text('草稿未能保存，请检查后重试'), findsOneWidget);
    // Interrupt a rejected swipe while its card is still beyond half a page.
    final PrimaryNavigationSwipeController controller = _primaryController(
      tester,
    );
    controller.beginPrimarySwipe();
    controller.updatePrimarySwipe(300);
    controller.endPrimarySwipe(900);
    await tester.pump();
    controller.beginPrimarySwipe();
    controller.updatePrimarySwipe(20);
    controller.endPrimarySwipe(900);
    await tester.pumpAndSettle();
    expect(_currentPath(app.container), '/assistant');
    expect(_primaryOffset(tester, 6), 0);
    expect(tester.takeException(), isNull);
    lifecycle.unregister(owner);
    await _disposePrimaryNavigationApp(tester, app);
  });

  testWidgets('系统减少动态效果时立即切页且不保留卡片装饰', (WidgetTester tester) async {
    // 当前测试使用的应用环境。
    final _PrimaryNavigationTestApp app = await _pumpPrimaryNavigationApp(
      tester,
    );
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pump();

    app.container.read(appRouterProvider).go('/assistant');
    await tester.pump();

    // 减弱动效后的完整目标卡片。
    final PhysicalModel card = tester.widget<PhysicalModel>(
      find.byKey(const ValueKey<String>('primary-navigation-card-6')),
    );
    // 减弱动效后的目标缩放变换。
    final Transform scale = tester.widget<Transform>(
      find.byKey(const ValueKey<String>('primary-navigation-scale-6')),
    );
    expect(_currentPath(app.container), '/assistant');
    expect(scale.transform.storage[0], 1);
    expect(card.elevation, 0);
    expect(card.borderRadius, BorderRadius.zero);
    expect(
      find.byKey(const ValueKey<String>('primary-navigation-scale-0')),
      findsNothing,
    );

    await _disposePrimaryNavigationApp(tester, app);
  });
}

/// 从列表下部真实甩动，避免直接调用内部手势回调绕开竞争。
Future<void> _dragNestedPage(
  WidgetTester tester,
  String surfaceKey,
  double distance,
  double speed,
) async {
  // 独立管理分页的实际边界。
  final Rect bounds = tester.getRect(find.byKey(ValueKey<String>(surfaceKey)));
  // 选择避开摘要、搜索栏和新增按钮的内容区域。
  final Offset start = Offset(
    distance < 0 ? bounds.right - 60 : bounds.left + 60,
    bounds.bottom - 180,
  );
  await tester.flingFrom(start, Offset(distance, 0), speed);
}

/// 单个全局导航测试持有的依赖容器与内存数据库。
class _PrimaryNavigationTestApp {
  /// 当前应用的依赖容器。
  final ProviderContainer container;

  /// 当前应用的内存数据库。
  final AppDatabase database;

  /// Each navigation scenario owns an isolated in-memory assistant cache.
  final AssistantCache assistantCache;

  /// 当前测试环境是否已经完成释放。
  bool disposed = false;

  /// 创建全局导航测试环境。
  _PrimaryNavigationTestApp({
    required this.container,
    required this.database,
    required this.assistantCache,
  });
}

/// Resolve authentication immediately without platform secure-storage calls.
class _LocalNavigationAuth extends AuthController {
  /// Navigation coverage needs an explicit local-only authentication state.
  @override
  Future<SyncSession?> build() async => null;
}

/// Control save outcomes while retaining the actual note controller and page.
class _ControlledExitNoteEditor extends NoteEditorController {
  /// Construct an editor with the same explicit-commit behavior as Android.
  _ControlledExitNoteEditor(super.repository, super.recorder)
    : super(explicitCommit: true);

  /// Normal initialization uses production persistence until the test arms it.
  bool armed = false;

  /// Number of armed persistence attempts.
  int attempts = 0;

  /// Direct callers distinguish navigation guards from existing page saves.
  final List<String> callSites = <String>[];

  /// Reject this attempt and all later attempts.
  int failFromAttempt = 1;

  /// Exercise an exceptional failure in addition to a retained dirty draft.
  bool throwOnFailure = false;

  /// Optional asynchronous save boundary controlled by the test.
  Completer<void>? gate;

  /// Preserve dirty state on failure without touching unrelated dependencies.
  @override
  Future<void> flush() async {
    if (!armed) return super.flush();
    attempts++;
    callSites.add(StackTrace.current.toString().split('\n')[1]);
    await gate?.future;
    if (attempts >= failFromAttempt) {
      dirty = true;
      error = '模拟写入失败';
      if (throwOnFailure) throw StateError(error!);
      return;
    }
    dirty = false;
  }
}

/// 启动使用 Android 紧凑视口的完整应用。
Future<_PrimaryNavigationTestApp> _pumpPrimaryNavigationApp(
  WidgetTester tester, {
  bool controlledEditor = false,
  Map<String, Object> preferences = const <String, Object>{
    'appearance.theme_mode': 'light',
  },
}) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues(preferences);
  // 测试用主题与功能偏好存储。
  final SharedPreferences sharedPreferences =
      await SharedPreferences.getInstance();
  // 测试用内存数据库。
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  // Pre-open the assistant cache outside fake async before mounting AI.
  final AssistantCache assistantCache = AssistantCache.forTesting(
    NativeDatabase.memory(),
  );
  await tester.runAsync(() => assistantCache.readScope(null));
  // 显式管理的应用依赖容器。
  final ProviderContainer container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(sharedPreferences),
      appDatabaseProvider.overrideWithValue(database),
      authControllerProvider.overrideWith(_LocalNavigationAuth.new),
      assistantCacheProvider.overrideWithValue(assistantCache),
      nowProvider.overrideWithValue(DateTime(2026, 10, 1, 10)),
      if (controlledEditor)
        noteEditorProvider.overrideWith((ref) {
          // Share the normal repository and native-recorder test boundaries.
          final _ControlledExitNoteEditor editor = _ControlledExitNoteEditor(
            ref.watch(noteRepositoryProvider),
            ref.watch(noteRecorderProvider),
          );
          ref.onDispose(editor.dispose);
          return editor;
        }),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const OmniButlerApp(),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  // 已经启动完成的测试环境。
  final _PrimaryNavigationTestApp app = _PrimaryNavigationTestApp(
    container: container,
    database: database,
    assistantCache: assistantCache,
  );
  addTearDown(() => _disposePrimaryNavigationApp(tester, app));
  return app;
}

/// 释放预载页面订阅、依赖容器和内存数据库。
Future<void> _disposePrimaryNavigationApp(
  WidgetTester tester,
  _PrimaryNavigationTestApp app,
) async {
  if (app.disposed) {
    return;
  }
  app.disposed = true;
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  app.container.dispose();
  await tester.pump(const Duration(milliseconds: 100));
  await app.assistantCache.close();
  await app.database.close();
  debugDefaultTargetPlatformOverride = null;
}

/// 返回当前页面树中的一级横滑协调器。
PrimaryNavigationSwipeController _primaryController(WidgetTester tester) {
  // 当前一级横滑作用域。
  final PrimaryNavigationSwipeScope scope = tester
      .widget<PrimaryNavigationSwipeScope>(
        find.byType(PrimaryNavigationSwipeScope),
      );
  return scope.controller;
}

/// 读取指定一级页面真实绘制的横向位移。
double _primaryOffset(WidgetTester tester, int index) {
  return tester
      .widget<Transform>(
        find.byKey(ValueKey<String>('primary-navigation-translation-$index')),
      )
      .transform
      .storage[12];
}

/// 使用累计距离执行一次一级页面横滑并等待落位。
Future<void> _swipePrimary(
  WidgetTester tester,
  double distance, {
  double velocity = 0,
}) async {
  // 本次横滑使用的一级导航协调器。
  final PrimaryNavigationSwipeController controller = _primaryController(
    tester,
  );
  controller.beginPrimarySwipe();
  controller.updatePrimarySwipe(distance);
  controller.endPrimarySwipe(velocity);
  await tester.pumpAndSettle();
}

/// 返回当前路由路径。
String _currentPath(ProviderContainer container) {
  return container.read(appRouterProvider).state.uri.path;
}
