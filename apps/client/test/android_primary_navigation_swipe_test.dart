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

/// Verifies click-only primary navigation and independent local swipe surfaces.
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

  testWidgets('首页笔记和 AI 的真实左右滑动不切换一级页面', (WidgetTester tester) async {
    // Every gesture uses the production routing shell and real hit testing.
    final _PrimaryNavigationTestApp app = await _pumpPrimaryNavigationApp(
      tester,
    );
    // Each branch retains its stable route identity despite horizontal input.
    for (final String path in <String>['/home', '/notes', '/assistant']) {
      await tester.tap(find.byKey(ValueKey<String>('navigation-$path')));
      await tester.pumpAndSettle();
      expect(_currentPath(app.container), path);
      await _swipePrimary(tester, -250, velocity: -1200);
      expect(_currentPath(app.container), path);
      await _swipePrimary(tester, 250, velocity: 1200);
      expect(_currentPath(app.container), path);
      // Newly supported local sidebars close before another bottom-tab choice.
      if (find
          .byKey(const ValueKey('android-notes-sidebar'))
          .evaluate()
          .isNotEmpty) {
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
      }
      if (find
          .byKey(const ValueKey('assistant-sidebar-close'))
          .evaluate()
          .isNotEmpty) {
        await _tapVisible(
          tester,
          find.byKey(const ValueKey('assistant-sidebar-close')),
        );
        await tester.pumpAndSettle();
      }
      expect(_currentPath(app.container), path);
    }
    expect(
      find.byKey(const ValueKey('primary-navigation-swipe-surface')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await _disposePrimaryNavigationApp(tester, app);
  });

  testWidgets('底栏点击保持双向卡片动效及导航忙碌状态', (WidgetTester tester) async {
    // The shared coordinator exposes the complete transition ownership interval.
    final _PrimaryNavigationTestApp app = await _pumpPrimaryNavigationApp(
      tester,
    );
    // The mounted branch container owns both tab animation and exit protection.
    final PrimaryNavigationCoordinator coordinator = tester
        .widget<PrimaryNavigationBranchContainer>(
          find.byType(PrimaryNavigationBranchContainer),
        )
        .coordinator;
    expect(coordinator.isTransitioning, isFalse);
    await tester.tap(find.byKey(const ValueKey('navigation-/notes')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(coordinator.isTransitioning, isTrue);
    expect(_currentPath(app.container), '/home');
    expect(_primaryOffset(tester, 0), inExclusiveRange(-390, 0));
    // The transition still uses the original scale, corner and elevation treatment.
    final Transform scale = tester.widget<Transform>(
      find.byKey(const ValueKey('primary-navigation-scale-0')),
    );
    // This physical surface is the actual displayed source branch.
    final PhysicalModel card = tester.widget<PhysicalModel>(
      find.byKey(const ValueKey('primary-navigation-card-0')),
    );
    expect(scale.transform.storage[0], inExclusiveRange(.985, 1));
    expect(card.elevation, greaterThan(0));
    expect(card.borderRadius, isNot(BorderRadius.zero));
    await tester.pumpAndSettle();
    expect(_currentPath(app.container), '/notes');
    expect(coordinator.isTransitioning, isFalse);
    await tester.tap(find.byKey(const ValueKey('navigation-/home')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_primaryOffset(tester, 3), inExclusiveRange(0, 390));
    await tester.pumpAndSettle();
    expect(_currentPath(app.container), '/home');
    expect(coordinator.isTransitioning, isFalse);
    await _disposePrimaryNavigationApp(tester, app);
  });

  testWidgets('关闭可选功能后点击仍正常且快滑不会绕过底栏', (WidgetTester tester) async {
    // Disabling notes leaves home and AI as the available primary destinations.
    final _PrimaryNavigationTestApp app = await _pumpPrimaryNavigationApp(
      tester,
      preferences: <String, Object>{
        'appearance.theme_mode': 'light',
        'features.todos.enabled': false,
        'features.timeline.enabled': false,
        'features.notes.enabled': false,
      },
    );
    expect(find.byKey(const ValueKey('navigation-/notes')), findsNothing);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(accessibleNavigation: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pump();
    await _swipePrimary(tester, -250, velocity: -1500);
    expect(_currentPath(app.container), '/home');
    await tester.tap(find.byKey(const ValueKey('navigation-/assistant')));
    await tester.pumpAndSettle();
    expect(_currentPath(app.container), '/assistant');
    await _swipePrimary(tester, -250, velocity: -1500);
    expect(_currentPath(app.container), '/assistant');
    await tester.tap(find.byKey(const ValueKey('navigation-/home')));
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
    expect(_currentPath(app.container), '/home');
    await tester.tap(find.byKey(const ValueKey('navigation-/notes')));
    await tester.pumpAndSettle();
    expect(_currentPath(app.container), '/notes');
    await _disposePrimaryNavigationApp(tester, app);
  });

  testWidgets('笔记保存失败阻止底栏且真实横滑不能绕过保护', (WidgetTester tester) async {
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
    // Real horizontal movement must neither bypass the save nor start a transition.
    await _swipePrimary(tester, -300, velocity: -900);
    await _swipePrimary(tester, -20, velocity: -900);
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
    await _swipePrimary(tester, -250, velocity: -900);
    await tester.pump();
    expect(editor.attempts, 1);
    expect(_primaryCoordinator(tester).isTransitioning, isTrue);
    expect(_currentPath(app.container), '/notes');
    editor.gate!.complete();
    await tester.pumpAndSettle();
    expect(_primaryOffset(tester, 3), 0);
    expect(_primaryCoordinator(tester).isTransitioning, isFalse);
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
    expect(_primaryCoordinator(tester).isTransitioning, isTrue);
    expect(_currentPath(app.container), '/assistant');
    expect(_primaryOffset(tester, 6), 0);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey<String>('navigation-/notes')));
    await _swipePrimary(tester, -250, velocity: -900);
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

  testWidgets('AI 点击取消等待被外部导航接管后旧请求不能覆盖新页面', (WidgetTester tester) async {
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
    // The old click request finishes only after home starts its own transition.
    final Completer<void> cancellation = Completer<void>();
    lifecycle.register(owner, () => cancellation.future);
    addTearDown(() => lifecycle.unregister(owner));
    // A bottom-tab selection waits for the same assistant lifecycle as before.
    await tester.tap(find.byKey(const ValueKey('navigation-/notes')));
    await tester.pump();
    expect(_currentPath(app.container), '/assistant');
    expect(_primaryOffset(tester, 6), 0);
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

  testWidgets('AI 退出保存失败保持当前页且真实横滑不能绕过取消', (WidgetTester tester) async {
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
    // Repeated physical drags cannot create a second navigation path.
    await _swipePrimary(tester, -250, velocity: -900);
    await _swipePrimary(tester, -30, velocity: -900);
    expect(_currentPath(app.container), '/assistant');
    expect(_primaryOffset(tester, 6), 0);
    expect(tester.takeException(), isNull);
    lifecycle.unregister(owner);
    await _disposePrimaryNavigationApp(tester, app);
  });

  // Each origin owns a different retained branch and must survive secondary pushes.
  for (final ({String path, int index}) origin in <({String path, int index})>[
    (path: '/home', index: 0),
    (path: '/notes', index: 3),
    (path: '/assistant', index: 6),
  ]) {
    testWidgets('更多四项从 ${origin.path} 返回原页并保留 Navigator', (
      WidgetTester tester,
    ) async {
      // Real repositories and route guards remain in the isolated test app.
      final _PrimaryNavigationTestApp app = await _pumpPrimaryNavigationApp(
        tester,
      );
      app.container.read(appRouterProvider).go(origin.path);
      await tester.pumpAndSettle();
      // Remember the actual source branch navigator rather than only its location.
      final State sourceNavigator = tester.state(
        find
            .descendant(
              of: find.byKey(
                ValueKey('primary-navigation-card-${origin.index}'),
              ),
              matching: find.byType(Navigator),
            )
            .first,
      );
      // Each menu action continues to use its existing public feature route.
      for (final ({String id, String path}) destination
          in <({String id, String path})>[
            (id: 'todos', path: '/todos'),
            (id: 'timeline', path: '/timeline'),
            (id: 'management', path: '/inventory'),
            (id: 'settings', path: '/settings'),
          ]) {
        await _openMore(tester);
        await tester.tap(
          find.byKey(ValueKey('more-shortcut-${destination.id}')),
        );
        await tester.pumpAndSettle();
        expect(_currentPath(app.container), destination.path);
        expect(find.byKey(const ValueKey('android-more-panel')), findsNothing);
        expect(find.byKey(const ValueKey('compact-navigation')), findsNothing);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(_currentPath(app.container), origin.path);
        expect(find.byKey(const ValueKey('navigation-more')), findsOneWidget);
        expect(
          tester.state(
            find
                .descendant(
                  of: find.byKey(
                    ValueKey('primary-navigation-card-${origin.index}'),
                  ),
                  matching: find.byType(Navigator),
                )
                .first,
          ),
          same(sourceNavigator),
        );
      }
      expect(tester.takeException(), isNull);
      await _disposePrimaryNavigationApp(tester, app);
    });

    testWidgets('更多系统返回优先关闭面板并保留 ${origin.path}', (WidgetTester tester) async {
      // The real root route must advertise back handling while the menu is open.
      final _PrimaryNavigationTestApp app = await _pumpPrimaryNavigationApp(
        tester,
      );
      app.container.read(appRouterProvider).go(origin.path);
      await tester.pumpAndSettle();
      // This element is above all branch navigators and owns native back registration.
      final Finder rootScope = find.byKey(
        const ValueKey('android-root-back-scope'),
      );
      if (origin.path == '/home') {
        expect(
          ModalRoute.of(tester.element(rootScope))!.popDisposition,
          RoutePopDisposition.bubble,
        );
      }
      await _openMore(tester);
      expect(
        ModalRoute.of(tester.element(rootScope))!.popDisposition,
        RoutePopDisposition.doNotPop,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('android-more-panel')), findsNothing);
      expect(_currentPath(app.container), origin.path);
      if (origin.path == '/home') {
        expect(
          ModalRoute.of(tester.element(rootScope))!.popDisposition,
          RoutePopDisposition.bubble,
        );
      }
      expect(tester.takeException(), isNull);
      await _disposePrimaryNavigationApp(tester, app);
    });
  }

  // Both retained dirty state and thrown persistence errors must block More exits.
  for (final bool throws in <bool>[false, true]) {
    testWidgets('笔记更多保存失败不跳转：throws=$throws', (WidgetTester tester) async {
      // The controlled editor changes only the persistence result, not the UI flow.
      final _PrimaryNavigationTestApp app = await _pumpPrimaryNavigationApp(
        tester,
        controlledEditor: true,
      );
      app.container.read(appRouterProvider).go('/notes');
      await tester.pumpAndSettle();
      // Keep the same dirty editor throughout the menu and rejected exit.
      final _ControlledExitNoteEditor editor =
          app.container.read(noteEditorProvider) as _ControlledExitNoteEditor;
      editor.armed = true;
      editor.dirty = true;
      editor.throwOnFailure = throws;
      await _openMore(tester);
      await tester.tap(find.byKey(const ValueKey('more-shortcut-timeline')));
      await _pumpForSaveFailure(tester);
      expect(editor.attempts, 1);
      expect(editor.dirty, isTrue);
      expect(_currentPath(app.container), '/notes');
      expect(find.byKey(const ValueKey('android-more-panel')), findsNothing);
      expect(find.text('草稿未能保存，请检查后重试'), findsOneWidget);
      expect(app.container.read(noteEditorProvider), same(editor));
      expect(tester.takeException(), isNull);
      await _disposePrimaryNavigationApp(tester, app);
    });
  }

  testWidgets('AI 更多等待语音取消及草稿保存后仅打开一次', (WidgetTester tester) async {
    // A real retained assistant participates in the shared lifecycle operation.
    final _PrimaryNavigationTestApp app = await _pumpPrimaryNavigationApp(
      tester,
    );
    app.container.read(appRouterProvider).go('/assistant');
    await tester.pumpAndSettle();
    // An additional owner lets this test delay the operation without fake UI state.
    final VoiceInputLifecycle lifecycle = app.container.read(
      voiceInputLifecycleProvider,
    );
    // This owner never replaces the production assistant callback.
    final Object owner = Object();
    // Completion stays under test control until all visible assertions are checked.
    final Completer<void> cancellation = Completer<void>();
    // Repeated taps must share one cancellation request.
    int calls = 0;
    lifecycle.register(owner, () {
      calls++;
      return cancellation.future;
    });
    addTearDown(() => lifecycle.unregister(owner));
    await tester.tap(find.byKey(const ValueKey('navigation-more')));
    await tester.pump();
    expect(calls, 1);
    expect(find.byKey(const ValueKey('android-more-panel')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('navigation-more')));
    await tester.pump();
    expect(calls, 1);
    await tester.runAsync(() async {
      cancellation.complete();
      await lifecycle.cancelAll();
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('android-more-panel')), findsOneWidget);
    expect(_currentPath(app.container), '/assistant');
    expect(tester.takeException(), isNull);
    lifecycle.unregister(owner);
    await _disposePrimaryNavigationApp(tester, app);
  });

  testWidgets('AI 更多语音草稿保存失败不打开面板', (WidgetTester tester) async {
    // The failure comes from the existing cancellation-and-save seam.
    final _PrimaryNavigationTestApp app = await _pumpPrimaryNavigationApp(
      tester,
    );
    app.container.read(appRouterProvider).go('/assistant');
    await tester.pumpAndSettle();
    // Preserve the real assistant lifecycle registration alongside this failure.
    final VoiceInputLifecycle lifecycle = app.container.read(
      voiceInputLifecycleProvider,
    );
    // A separate owner simulates a persistence failure.
    final Object owner = Object();
    lifecycle.register(owner, () async => throw StateError('模拟草稿保存失败'));
    addTearDown(() => lifecycle.unregister(owner));
    await tester.tap(find.byKey(const ValueKey('navigation-more')));
    await _pumpForSaveFailure(tester);
    expect(_currentPath(app.container), '/assistant');
    expect(find.byKey(const ValueKey('android-more-panel')), findsNothing);
    expect(find.text('草稿未能保存，请检查后重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
    lifecycle.unregister(owner);
    await _disposePrimaryNavigationApp(tester, app);
  });

  // Both a new tab request and an external route must supersede a pending menu.
  for (final bool externalRoute in <bool>[false, true]) {
    testWidgets('AI 更多等待中换页不能迟到重开：external=$externalRoute', (
      WidgetTester tester,
    ) async {
      // Use the actual shell so close-before-tab ownership is exercised too.
      final _PrimaryNavigationTestApp app = await _pumpPrimaryNavigationApp(
        tester,
      );
      app.container.read(appRouterProvider).go('/assistant');
      await tester.pumpAndSettle();
      // Keep cancellation pending across the competing navigation intent.
      final VoiceInputLifecycle lifecycle = app.container.read(
        voiceInputLifecycleProvider,
      );
      // This controlled owner is independent of the production assistant owner.
      final Object owner = Object();
      // A late completion must never reveal the old menu over the new route.
      final Completer<void> cancellation = Completer<void>();
      lifecycle.register(owner, () => cancellation.future);
      addTearDown(() => lifecycle.unregister(owner));
      await tester.tap(find.byKey(const ValueKey('navigation-more')));
      await tester.pump();
      expect(find.byKey(const ValueKey('android-more-panel')), findsNothing);
      if (externalRoute) {
        app.container.read(appRouterProvider).go('/home');
      } else {
        await tester.tap(find.byKey(const ValueKey('navigation-/home')));
      }
      await tester.pump();
      await tester.runAsync(() async {
        cancellation.complete();
        await lifecycle.cancelAll();
      });
      await tester.pumpAndSettle();
      expect(_currentPath(app.container), '/home');
      expect(find.byKey(const ValueKey('android-more-panel')), findsNothing);
      expect(tester.takeException(), isNull);
      lifecycle.unregister(owner);
      await _disposePrimaryNavigationApp(tester, app);
    });
  }

  testWidgets('笔记更多保存等待时点击其他底栏不会被迟到功能跳转覆盖', (WidgetTester tester) async {
    // Let successful saves finish only after the user chooses a different tab.
    final _PrimaryNavigationTestApp app = await _pumpPrimaryNavigationApp(
      tester,
      controlledEditor: true,
    );
    app.container.read(appRouterProvider).go('/notes');
    await tester.pumpAndSettle();
    // The same editor receives the old feature exit and the replacement tab exit.
    final _ControlledExitNoteEditor editor =
        app.container.read(noteEditorProvider) as _ControlledExitNoteEditor;
    editor.armed = true;
    editor.dirty = true;
    editor.failFromAttempt = 1000;
    editor.gate = Completer<void>();
    await _openMore(tester);
    await tester.tap(find.byKey(const ValueKey('more-shortcut-timeline')));
    await tester.pumpAndSettle();
    expect(editor.attempts, 1);
    expect(_currentPath(app.container), '/notes');
    expect(find.byKey(const ValueKey('android-more-panel')), findsNothing);
    // A pending exit freezes the underlying composer without blocking the tabs.
    final Finder composer = find.byKey(
      const ValueKey('android-note-input-touch'),
    );
    expect(composer.hitTestable(), findsNothing);
    await tester.tapAt(tester.getCenter(composer));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('android-note-editor')), findsNothing);
    expect(editor.attempts, 1);
    await _swipePrimary(tester, 240, velocity: 1200);
    expect(find.byKey(const ValueKey('android-notes-sidebar')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('navigation-/home')));
    await tester.pump();
    expect(editor.attempts, 2);
    editor.gate!.complete();
    await tester.pumpAndSettle();
    expect(_currentPath(app.container), '/home');
    expect(find.byKey(const ValueKey('android-more-panel')), findsNothing);
    expect(tester.takeException(), isNull);
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

    // Home has no asynchronous voice gate, so one frame isolates menu motion.
    app.container.read(appRouterProvider).go('/home');
    await tester.pump();

    /// Reads the explicit selected state exposed by the actual bottom-tab item.
    bool selected(String key) => tester
        .widget<Semantics>(
          find.descendant(
            of: find.byKey(ValueKey(key)),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Semantics && widget.properties.selected != null,
            ),
          ),
        )
        .properties
        .selected!;

    await tester.tap(find.byKey(const ValueKey('navigation-more')));
    await tester.pump();
    // The entire panel is at its final position without advancing animation time.
    final Finder panel = find.byKey(const ValueKey('android-more-panel'));
    expect(panel.hitTestable(), findsOneWidget);
    expect(
      tester
          .widget<SlideTransition>(
            find
                .ancestor(of: panel, matching: find.byType(SlideTransition))
                .first,
          )
          .position
          .value,
      Offset.zero,
    );
    expect(selected('navigation-more'), isTrue);
    expect(selected('navigation-/home'), isFalse);
    await tester.tap(find.byKey(const ValueKey('navigation-more')));
    await tester.pump();
    expect(panel, findsNothing);
    expect(selected('navigation-more'), isFalse);
    expect(selected('navigation-/home'), isTrue);

    // Native back removes the reduced-motion panel on the next frame as well.
    await tester.tap(find.byKey(const ValueKey('navigation-more')));
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(panel, findsNothing);
    expect(selected('navigation-more'), isFalse);
    expect(selected('navigation-/home'), isTrue);
    expect(_currentPath(app.container), '/home');
    expect(tester.takeException(), isNull);

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

/// 读取指定一级页面真实绘制的横向位移。
double _primaryOffset(WidgetTester tester, int index) {
  return tester
      .widget<Transform>(
        find.byKey(ValueKey<String>('primary-navigation-translation-$index')),
      )
      .transform
      .storage[12];
}

/// Reads the same coordinator used by the production bottom navigation bar.
PrimaryNavigationCoordinator _primaryCoordinator(WidgetTester tester) {
  return tester
      .widget<PrimaryNavigationBranchContainer>(
        find.byType(PrimaryNavigationBranchContainer),
      )
      .coordinator;
}

/// Sends actual horizontal pointer input through the visible page hit-test tree.
Future<void> _swipePrimary(
  WidgetTester tester,
  double distance, {
  double velocity = 0,
}) async {
  // Mid-content coordinates avoid the bottom tabs and input controls.
  final Offset start = Offset(distance < 0 ? 330 : 60, 350);
  if (velocity == 0) {
    await tester.dragFrom(start, Offset(distance, 0));
  } else {
    await tester.flingFrom(start, Offset(distance, 0), velocity.abs());
  }
  await tester.pumpAndSettle();
}

/// Opens the real More control and waits for its presentation to settle.
Future<void> _openMore(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('navigation-more')));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('android-more-panel')), findsOneWidget);
}

/// Observes transient feedback before its four-second animated countdown expires.
Future<void> _pumpForSaveFailure(WidgetTester tester) async {
  // The production error overlay starts only after any menu-close/save work.
  final Finder message = find.text('草稿未能保存，请检查后重试');
  // Bound fake time to one second while allowing asynchronous cache I/O to finish.
  for (int frame = 0; frame < 40 && message.evaluate().isEmpty; frame++) {
    await tester.pump(const Duration(milliseconds: 25));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
  }
  expect(message, findsOneWidget);
}

/// Taps the visible part of a translated dismissal surface rather than its offscreen center.
Future<void> _tapVisible(WidgetTester tester, Finder target) async {
  // The fixture's logical viewport bounds clip a translated page's full rectangle.
  final Rect viewport =
      Offset.zero & (tester.view.physicalSize / tester.view.devicePixelRatio);
  await tester.tapAt(tester.getRect(target).intersect(viewport).center);
}

/// 返回当前路由路径。
String _currentPath(ProviderContainer container) {
  return container.read(appRouterProvider).state.uri.path;
}
