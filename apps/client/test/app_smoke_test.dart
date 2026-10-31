import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/omni_butler_app.dart';
import 'package:omni_butler/app/router/app_router.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_providers.dart';
import 'package:omni_butler/features/assistant/data/assistant_cache.dart';
import 'package:omni_butler/features/assistant/data/assistant_repository.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_android_view.dart';
import 'package:omni_butler/features/todos/presentation/todo_editor_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Supply an authenticated test identity without reading device credentials.
class _ShortcutAssistantIdentity extends AuthController {
  /// Keep the chat editable while all storage and requests remain isolated.
  @override
  Future<SyncSession?> build() async => const SyncSession(
    identity: SyncIdentity(id: 'shortcut-test-owner'),
    apiBaseUrl: 'https://assistant.invalid/api',
    isOffline: false,
  );
}

/// Return only the read endpoints needed to initialize an empty editable chat.
class _ShortcutAssistantRepository implements AssistantRepository {
  /// Keep the retained page bound to one synthetic server generation.
  @override
  int get generation => 1;

  /// This fixture does not switch accounts while a request is pending.
  @override
  bool get isCurrent => true;

  /// Avoid any actual network call or model execution in the keyboard test.
  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Object? data,
  }) async {
    if (method != 'GET') throw StateError('Unexpected write: $method $path');
    return <String, dynamic>{'items': <Object>[], 'enabled': false};
  }

  /// Fail explicitly if the fixture is used for streaming, files or speech.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 验证根应用、数据库和主题切换可以协同启动。
void main() {
  testWidgets('显示首页并使用统一品牌主题', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 测试用主题偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          appDatabaseProvider.overrideWithValue(database),
        ],
        child: const OmniButlerApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('今天，慢一点也没关系'), findsNothing);
    expect(find.text('今日刻度'), findsOneWidget);
    expect(find.textContaining('星期'), findsOneWidget);
    expect(find.text('今日待办'), findsOneWidget);
    expect(find.text('海盐'), findsNothing);
    expect(find.text('石墨'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('primary-navigation-swipe-surface')),
      findsNothing,
    );

    // 根组件下的 Provider 容器。
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(OmniButlerApp)),
    );
    expect(container.read(themeControllerProvider).mode, ThemeMode.system);

    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });

  // Cover both compact navigation and the tablet assistant's existing behavior.
  for (final double width in <double>[390, 1000]) {
    testWidgets('Android ${width.toInt()} 根路由注册返回且内部侧栏优先处理', (
      WidgetTester tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      try {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues(<String, Object>{
          'sync.enabled': false,
        });
        // Keep all business data and assistant drafts isolated from user storage.
        final SharedPreferences preferences =
            await SharedPreferences.getInstance();
        // Business pages retain their normal database behavior in memory.
        final AppDatabase database = AppDatabase.forTesting(
          NativeDatabase.memory(),
        );
        // Open SQLite outside fake async before the first AI page is mounted.
        final AssistantCache cache = AssistantCache.forTesting(
          NativeDatabase.memory(),
        );
        await tester.runAsync(() => cache.readScope(null));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(preferences),
              appDatabaseProvider.overrideWithValue(database),
              assistantCacheProvider.overrideWithValue(cache),
              authControllerProvider.overrideWith(
                _ShortcutAssistantIdentity.new,
              ),
              assistantRepositoryProvider.overrideWithValue(
                _ShortcutAssistantRepository(),
              ),
              assistantSettingsProvider.overrideWith(
                (Ref ref) async => <String, dynamic>{'enabled': true},
              ),
            ],
            child: const OmniButlerApp(),
          ),
        );
        await tester.pumpAndSettle();
        // This element is above every branch Navigator and belongs to the root route.
        final Finder rootScope = find.byKey(
          const ValueKey<String>('android-root-back-scope'),
        );
        expect(
          ModalRoute.of(tester.element(rootScope))!.popDisposition,
          RoutePopDisposition.bubble,
        );
        // Route directly so both phone and tablet exercise the same real shell.
        final ProviderContainer container = ProviderScope.containerOf(
          tester.element(find.byType(OmniButlerApp)),
        );
        container.read(appRouterProvider).go('/assistant');
        await tester.pumpAndSettle();
        expect(
          ModalRoute.of(tester.element(rootScope))!.popDisposition,
          RoutePopDisposition.doNotPop,
        );
        await tester.tap(
          find.byKey(const ValueKey<String>('assistant-history-button')),
        );
        await tester.pumpAndSettle();
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(container.read(appRouterProvider).state.uri.path, '/assistant');
        expect(
          ModalRoute.of(tester.element(rootScope))!.popDisposition,
          RoutePopDisposition.doNotPop,
        );
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(container.read(appRouterProvider).state.uri.path, '/home');
        expect(
          ModalRoute.of(tester.element(rootScope))!.popDisposition,
          RoutePopDisposition.bubble,
        );
        // Direct secondary links need root back ownership only on compact Android.
        container.read(appRouterProvider).go('/timeline');
        await tester.pumpAndSettle();
        expect(
          ModalRoute.of(tester.element(rootScope))!.popDisposition,
          width < 600
              ? RoutePopDisposition.doNotPop
              : RoutePopDisposition.bubble,
        );
        if (width < 600) {
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(container.read(appRouterProvider).state.uri.path, '/home');
          container.read(appRouterProvider).go('/notes');
          await tester.pumpAndSettle();
          expect(
            ModalRoute.of(tester.element(rootScope))!.popDisposition,
            RoutePopDisposition.doNotPop,
          );
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(container.read(appRouterProvider).state.uri.path, '/home');
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await cache.close();
        await database.close();
      } finally {
        // Restore foundation state before testWidgets checks its invariants.
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('紧凑布局只展示首页笔记AI三个底部入口', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues(<String, Object>{
      'sync.enabled': false,
    });
    // 测试用主题偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // The retained assistant must never open the user's on-disk cache in tests.
    final AssistantCache cache = AssistantCache.forTesting(
      NativeDatabase.memory(),
    );
    // Home startup must not initialize the retained chat's cache.
    int assistantCacheLoads = 0;
    // 紧凑布局窗口尺寸。
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          appDatabaseProvider.overrideWithValue(database),
          assistantCacheProvider.overrideWith((ref) {
            assistantCacheLoads++;
            return cache;
          }),
          authControllerProvider.overrideWith(_ShortcutAssistantIdentity.new),
          assistantRepositoryProvider.overrideWithValue(
            _ShortcutAssistantRepository(),
          ),
          assistantSettingsProvider.overrideWith(
            (Ref ref) async => <String, dynamic>{'enabled': true},
          ),
        ],
        child: const OmniButlerApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsNothing);
    // 仅检查一级导航标签，首页模块也有同名的待办和时间标签。
    for (final (String, String) destination in <(String, String)>[
      ('/home', '首页'),
      ('/notes', '笔记'),
      ('/assistant', 'AI'),
    ]) {
      expect(
        find.descendant(
          of: find.byKey(ValueKey<String>('navigation-${destination.$1}')),
          matching: find.text(destination.$2),
        ),
        findsOneWidget,
      );
    }
    expect(find.text('更多'), findsNothing);
    // Secondary features remain reachable from the home shortcuts.
    for (final String id in <String>[
      'todos',
      'timeline',
      'management',
      'settings',
    ]) {
      expect(find.byKey(ValueKey<String>('home-shortcut-$id')), findsOneWidget);
    }
    for (final String path in <String>[
      '/todos',
      '/timeline',
      '/inventory',
      '/settings',
    ]) {
      expect(find.byKey(ValueKey<String>('navigation-$path')), findsNothing);
    }
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
    expect(assistantCacheLoads, 0);

    // Use the real shell to verify keyboard chrome and retained AI identity.
    await tester.tap(
      find.byKey(const ValueKey<String>('navigation-/assistant')),
    );
    await tester.pumpAndSettle();
    expect(assistantCacheLoads, 1);
    // The actual view state must survive a trip through the notes branch.
    final State<StatefulWidget> assistantState = tester.state(
      find.byType(AssistantAndroidView),
    );
    // Raw key delivery must not invoke the shell's global create-todo action.
    await tester.tap(find.byKey(const ValueKey<String>('assistant-input')));
    await tester.pumpAndSettle();
    // Inspect production focus rather than relying on synthetic text injection.
    final AssistantAndroidView assistant = tester.widget<AssistantAndroidView>(
      find.byType(AssistantAndroidView),
    );
    expect(assistant.inputFocus.hasFocus, isTrue);
    expect(
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN, character: 'n'),
      isFalse,
    );
    await tester.pumpAndSettle();
    expect(find.byType(TodoEditorDialog), findsNothing);
    expect(assistant.inputFocus.hasFocus, isTrue);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('compact-navigation')),
      findsNothing,
    );
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('navigation-/notes')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('navigation-/assistant')),
    );
    await tester.pumpAndSettle();
    expect(
      tester.state(find.byType(AssistantAndroidView)),
      same(assistantState),
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      ProviderScope.containerOf(tester.element(find.byType(OmniButlerApp)))
          .read(appRouterProvider)
          .state
          .uri
          .path,
      '/home',
    );
    // The same raw shortcut still opens the existing todo form outside AI.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN, character: 'n');
    await tester.pumpAndSettle();
    expect(find.byType(TodoEditorDialog), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
    await cache.close();
    debugDefaultTargetPlatformOverride = null;
  });
}
