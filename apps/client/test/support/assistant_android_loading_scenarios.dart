part of '../assistant_test.dart';

/// Exercise centered connection recovery without submitting messages.
void _registerAndroidLoadingScenarios(
  SharedPreferences Function() preferences,
) {
  for (final bool compact in <bool>[false, true]) {
    testWidgets('Android页面连接加载居中与错误下置 compact=$compact', (
      WidgetTester tester,
    ) async {
      // A delayed real repository boundary holds the initialization spinner open.
      final _AndroidAssistantFixture fixture = _AndroidAssistantFixture();
      // The fixture controls each completion without real network traffic.
      final Completer<Map<String, dynamic>> request =
          Completer<Map<String, dynamic>>();
      fixture.repository.queries['/conversations'] = request;
      await fixture.mount(
        tester,
        preferences(),
        settle: false,
        size: compact ? const Size(320, 640) : const Size(390, 844),
        textScale: compact ? 2 : 1,
        disableAnimations: compact,
      );
      expect(
        find.byKey(const ValueKey<String>('assistant-connection-spinner')),
        findsOneWidget,
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('assistant-android-welcome')),
        findsNothing,
      );
      if (!compact) {
        // The animation center must use the complete workspace bounds.
        final Rect workspace = tester.getRect(
          find.byType(AssistantAndroidView),
        );
        // The spinner remains fixed when error text appears beneath it.
        final Rect spinner = tester.getRect(
          find.byKey(const ValueKey<String>('assistant-connection-spinner')),
        );
        expect(spinner.center.dx, closeTo(workspace.center.dx, .1));
        expect(spinner.center.dy, closeTo(workspace.center.dy, .1));
      }
      request.completeError(const ApiFailure('连接失败，请重试'));
      await fixture.drain(tester);
      await tester.pumpAndSettle();
      expect(find.text('连接失败，请重试'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('连接失败，请重试')).dy,
        greaterThan(
          tester
              .getBottomLeft(
                find.byKey(
                  const ValueKey<String>('assistant-connection-spinner'),
                ),
              )
              .dy,
        ),
      );
      expect(tester.takeException(), isNull);
      await _androidAssistantPreview(
        tester,
        compact ? 'connection-error-large' : 'connection-error',
      );
      if (compact) {
        tester.view.viewInsets = const FakeViewPadding(bottom: 350);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      // A manual retry reads state once and never creates a billable message.
      final Completer<Map<String, dynamic>> retry =
          Completer<Map<String, dynamic>>();
      fixture.repository.queries['/conversations'] = retry;
      await tester.ensureVisible(find.text('刷新状态'));
      await tester.tap(find.text('刷新状态'));
      await fixture.drain(tester);
      expect(
        find.byKey(const ValueKey<String>('assistant-connection-spinner')),
        findsOneWidget,
      );
      await tester.tap(find.text('刷新状态'));
      expect(
        fixture.repository.calls.where((call) => call.path == '/conversations'),
        hasLength(2),
      );
      retry.complete(<String, dynamic>{'items': <Object>[]});
      await fixture.drain(tester);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('assistant-connection-spinner')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('assistant-android-welcome')),
        findsOneWidget,
      );
      expect(fixture.submissions, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('Android重新连接保留本机聊天内容', (WidgetTester tester) async {
    // Cached messages remain readable while the original server is unavailable.
    final _AndroidAssistantFixture fixture = _AndroidAssistantFixture();
    // Hold initialization so restored data is visible before the request settles.
    final Completer<Map<String, dynamic>> request =
        Completer<Map<String, dynamic>>();
    fixture.repository.queries['/conversations'] = request;
    await fixture.mount(
      tester,
      preferences(),
      settle: false,
      snapshot: <String, dynamic>{
        'conversationId': 'conversation',
        'messages': <Object>[
          <String, dynamic>{
            'id': 'cached',
            'role': 'user',
            'content': '缓存内容仍然可读',
          },
        ],
      },
    );
    expect(find.text('缓存内容仍然可读'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('assistant-connection-spinner')),
      findsNothing,
    );
    request.completeError(const ApiFailure('连接失败，请重试'));
    await fixture.drain(tester);
    await tester.pumpAndSettle();
    expect(find.text('缓存内容仍然可读'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
