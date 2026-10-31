part of '../assistant_test.dart';

/// Exercise retained branches with the real assistant and isolated dependencies.
class _AssistantTabFixture extends _AndroidAssistantFixture {
  /// The shared router exposes the actual visible path during branch switches.
  late final GoRouter router;

  /// An outer recognizer detects accidental takeover of drawer gestures.
  int primaryDrags = 0;

  /// Mount three stateful tabs while preloading the hidden assistant branch.
  Future<void> mountTabs(
    WidgetTester tester,
    SharedPreferences preferences, {
    Map<String, dynamic>? snapshot,
  }) async {
    router = GoRouter(
      initialLocation: '/home',
      routes: <RouteBase>[
        StatefulShellRoute.indexedStack(
          builder: (context, state, navigationShell) => Scaffold(
            body: GestureDetector(
              onHorizontalDragEnd: (_) => primaryDrags++,
              child: SafeArea(child: navigationShell),
            ),
            bottomNavigationBar: Row(
              children: <Widget>[
                // Stable keys distinguish fixture navigation from page content.
                for (final (int index, String label) in <(int, String)>[
                  (0, 'home'),
                  (1, 'notes'),
                  (2, 'assistant'),
                ])
                  Expanded(
                    child: TextButton(
                      key: ValueKey<String>('assistant-test-tab-$label'),
                      onPressed: () => navigationShell.goBranch(index),
                      child: Text(label),
                    ),
                  ),
              ],
            ),
          ),
          branches: <StatefulShellBranch>[
            StatefulShellBranch(
              routes: <RouteBase>[
                GoRoute(
                  path: '/home',
                  builder: (context, state) => const Text('测试首页'),
                ),
              ],
            ),
            StatefulShellBranch(
              routes: <RouteBase>[
                GoRoute(
                  path: '/notes',
                  builder: (context, state) => const Text('测试笔记'),
                ),
              ],
            ),
            StatefulShellBranch(
              preload: true,
              routes: <RouteBase>[
                GoRoute(
                  path: '/assistant',
                  builder: (context, state) => const AssistantPage(),
                ),
              ],
            ),
          ],
        ),
      ],
    );
    // The base fixture unmounts before this router is disposed.
    addTearDown(() => router.dispose());
    await mount(tester, preferences, snapshot: snapshot, router: router);
  }

  /// Read retained widgets even when their navigator is offstage.
  AssistantAndroidView retainedView(WidgetTester tester) =>
      tester.widget<AssistantAndroidView>(
        find.byType(AssistantAndroidView, skipOffstage: false),
      );

  /// Use visible navigation controls instead of recreating the route tree.
  Future<void> selectTab(WidgetTester tester, String tab) async {
    await tester.tap(find.byKey(ValueKey<String>('assistant-test-tab-$tab')));
    await tester.pumpAndSettle();
  }
}

/// Guard focus, scroll position and voice ownership across retained-tab changes.
void _registerAssistantTabScenarios(SharedPreferences Function() preferences) {
  testWidgets('Android AI Tab 保留会话草稿和阅读位置，离开清除焦点并落盘', (
    WidgetTester tester,
  ) async {
    // Real messages make retained scroll state observable.
    final _AssistantTabFixture fixture = _AssistantTabFixture();
    fixture.repository.serverMessages = <Map<String, dynamic>>[
      // Enough distinct rows keep the reading position away from either edge.
      for (int index = 0; index < 36; index++)
        <String, dynamic>{
          'id': 'tab-message-$index',
          'role': 'user',
          'content': '用于检查切换后阅读位置的消息 $index',
          'createdAt': '2026-10-31T08:00:00Z',
        },
    ];
    await fixture.mountTabs(
      tester,
      preferences(),
      snapshot: <String, dynamic>{'conversationId': 'conversation'},
    );
    // Preloading must not acquire speech resources before the first visit.
    expect(fixture.recorderCreations, 0);
    expect(fixture.recorder.starts, 0);
    await fixture.selectTab(tester, 'assistant');
    // Retained controller identity proves the page was not recreated.
    final AssistantAndroidView original = fixture.view(tester);
    expect(original.canVoiceInput, isTrue);
    await tester.enterText(
      find.byKey(const ValueKey<String>('assistant-input')),
      '切换后接着写',
    );
    await tester.pump();
    original.scroll.jumpTo(120);
    await tester.pump();
    expect(original.inputFocus.hasFocus, isTrue);
    await fixture.selectTab(tester, 'notes');
    await fixture.drain(tester);
    expect(fixture.retainedView(tester).canVoiceInput, isFalse);
    expect(fixture.recorderCreations, 0);
    expect(original.inputFocus.hasFocus, isFalse);
    // Inspect actual SQLite persistence after the page becomes hidden.
    final Map<String, dynamic>? cached = await tester.runAsync(
      () => fixture.cache.readScope(
        AssistantCache.scopeFor('https://example.com/api', 'owner'),
      ),
    );
    expect(cached?['draft'], '切换后接着写');
    await fixture.selectTab(tester, 'assistant');
    // The original chat, draft and scroll controller stay attached.
    final AssistantAndroidView restored = fixture.view(tester);
    expect(restored.chat, same(original.chat));
    expect(restored.input, same(original.input));
    expect(restored.scroll, same(original.scroll));
    expect(restored.chat.conversationId, 'conversation');
    expect(restored.input.text, '切换后接着写');
    expect(restored.scroll.offset, closeTo(120, .1));
    expect(restored.inputFocus.hasFocus, isFalse);
    expect(restored.canVoiceInput, isTrue);
    expect(tester.takeException(), isNull);
  });

  // Both live capture and a released gesture must stop before hidden final events.
  for (final bool finishing in <bool>[false, true]) {
    testWidgets(
      'Android AI Tab ${finishing ? '等待 final' : '按住录音'}时切走取消且回来可再次录音',
      (WidgetTester tester) async {
        // Production controllers retain their original identity across tabs.
        final _AssistantTabFixture fixture = _AssistantTabFixture();
        await fixture.mountTabs(tester, preferences());
        await fixture.selectTab(tester, 'assistant');
        // Keep the original pointer alive until navigation has invalidated it.
        final TestGesture hold = await fixture.hold(tester);
        fixture.speech.text('切走前的文字');
        await tester.pump();
        if (finishing) {
          await hold.up();
          await fixture.drain(tester);
          expect(
            fixture.view(tester).voice.phase,
            AssistantVoicePhase.finishing,
          );
        }
        // Capture the controller before the branch becomes offstage.
        final AssistantVoiceController voice = fixture.view(tester).voice;
        await fixture.selectTab(tester, 'home');
        await fixture.drain(tester);
        expect(voice.phase, AssistantVoicePhase.idle);
        expect(fixture.recorder.disposals, 1);
        fixture.speech.complete('迟到结果不能发送');
        await fixture.drain(tester);
        if (!finishing) await hold.up();
        expect(fixture.submissions, isEmpty);
        expect(fixture.retainedView(tester).canVoiceInput, isFalse);
        await fixture.selectTab(tester, 'assistant');
        expect(fixture.view(tester).voice, same(voice));
        expect(fixture.view(tester).canVoiceInput, isTrue);
        expect(fixture.view(tester).input.text, '切走前的文字');
        await tester.tap(
          find.byKey(const ValueKey<String>('assistant-voice-button')),
        );
        await tester.pumpAndSettle();
        // A fresh gesture must be able to acquire the released microphone.
        final TestGesture next = await tester.startGesture(
          tester.getCenter(
            find.byKey(const ValueKey<String>('assistant-voice-hold')),
          ),
        );
        await tester.pump();
        fixture.speech.output.add(<String, dynamic>{'type': 'ready'});
        await fixture.drain(tester);
        expect(fixture.recorder.starts, 2);
        expect(voice.phase, AssistantVoicePhase.recording);
        await next.cancel();
        await fixture.drain(tester);
        expect(fixture.submissions, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Android AI Tab 侧栏手势优先，返回先处理焦点与侧栏再回首页', (
    WidgetTester tester,
  ) async {
    // The surrounding gesture detector represents the primary tab recognizer.
    final _AssistantTabFixture fixture = _AssistantTabFixture();
    await fixture.mountTabs(tester, preferences());
    await fixture.selectTab(tester, 'assistant');
    await tester.enterText(
      find.byKey(const ValueKey<String>('assistant-input')),
      '返回仍保留',
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(fixture.router.state.uri.path, '/assistant');
    expect(fixture.view(tester).inputFocus.hasFocus, isFalse);
    await tester.tap(
      find.byKey(const ValueKey<String>('assistant-history-button')),
    );
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(370, 160), const Offset(-180, 0));
    await tester.pumpAndSettle();
    expect(fixture.primaryDrags, 0);
    expect(fixture.router.state.uri.path, '/assistant');
    expect(
      find.byKey(const ValueKey<String>('assistant-history-search')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('assistant-history-button')),
    );
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(fixture.router.state.uri.path, '/assistant');
    expect(
      find.byKey(const ValueKey<String>('assistant-history-search')),
      findsNothing,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(fixture.router.state.uri.path, '/home');
    await fixture.selectTab(tester, 'assistant');
    expect(fixture.view(tester).input.text, '返回仍保留');
    expect(tester.takeException(), isNull);
  });
}
