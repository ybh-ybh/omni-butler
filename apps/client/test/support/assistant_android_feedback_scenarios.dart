part of '../assistant_test.dart';

/// Verify failure placement and the original retry boundary on the real page.
void _registerAndroidFeedbackScenarios(
  SharedPreferences Function() preferences,
) {
  testWidgets('Android输入框加号在附件未就绪和离线时常驻禁用', (WidgetTester tester) async {
    // Use the real composer with isolated capabilities and connectivity.
    final _AndroidAssistantFixture fixture = _AndroidAssistantFixture();
    await fixture.mount(tester, preferences());
    // The persistent entry must remain to the left of the editable message text.
    final Finder attach = find.byKey(
      const ValueKey<String>('assistant-attach-button'),
    );
    expect(tester.widget<OmniIconButton>(attach).onPressed, isNotNull);
    expect(
      tester.getRect(attach).right,
      lessThanOrEqualTo(
        tester
            .getRect(find.byKey(const ValueKey<String>('assistant-input')))
            .left,
      ),
    );
    expect(tester.getRect(attach).height, greaterThanOrEqualTo(48));
    // Missing server capabilities must disable the picker without hiding the plus.
    fixture.view(tester).chat.attachments.capabilities = <String, dynamic>{};
    fixture.view(tester).chat.notifyListeners();
    await tester.pumpAndSettle();
    expect(attach, findsOneWidget);
    expect(tester.widget<OmniIconButton>(attach).onPressed, isNull);
    // The same geometry remains visible while the connection is offline.
    fixture.view(tester).chat.offline = true;
    fixture.view(tester).chat.notifyListeners();
    await tester.pumpAndSettle();
    expect(attach, findsOneWidget);
    expect(tester.widget<OmniIconButton>(attach).onPressed, isNull);
    expect(
      tester
          .widget<Icon>(
            find.descendant(of: attach, matching: find.byType(Icon)),
          )
          .icon,
      Icons.add,
    );
    expect(tester.takeException(), isNull);
  });
  for (final String placement in <String>['user', 'answer', 'legacy']) {
    testWidgets('Android短错误归并 $placement', (WidgetTester tester) async {
      // Full diagnostics remain available in the original run data.
      const String raw = '助手执行未完成（诊断编号：test-diagnostic）';
      // Each scenario owns its repository and persistence.
      final _AndroidAssistantFixture fixture = _AndroidAssistantFixture();
      fixture.repository.serverRun = <String, dynamic>{
        'id': 'run',
        'conversationId': 'conversation',
        'taskId': 'task',
        'answerMessageId': 'answer',
        'status': 'failed',
        'errorMessage': raw,
        'elapsedMs': 1000,
      };
      fixture.repository.serverMessages = <Map<String, dynamic>>[
        if (placement != 'legacy')
          <String, dynamic>{
            'id': 'user',
            'role': 'user',
            'taskId': 'task',
            'conversationId': 'conversation',
            'content': '你好',
          },
        if (placement == 'answer')
          <String, dynamic>{
            'id': 'answer',
            'role': 'assistant',
            'taskId': 'task',
            'conversationId': 'conversation',
            'content': '已获取的部分回答',
          },
      ];
      await fixture.mount(
        tester,
        preferences(),
        brightness: placement == 'answer' ? Brightness.dark : Brightness.light,
        size: placement == 'legacy'
            ? const Size(320, 640)
            : const Size(390, 844),
        textScale: placement == 'legacy' ? 2 : 1,
        snapshot: <String, dynamic>{'conversationId': 'conversation'},
      );
      fixture.view(tester).chat.error = raw;
      fixture.view(tester).chat.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('处理失败，请重试'), findsOneWidget);
      expect(find.text(raw), findsNothing);
      expect(find.text('处理失败'), findsNothing);
      expect(find.byTooltip('重试任务'), findsOneWidget);
      expect(fixture.view(tester).chat.run?['errorMessage'], raw);
      if (placement != 'legacy') {
        // Retry belongs to the user bubble even when a partial answer exists.
        final Rect bubble = tester.getRect(
          find.byKey(const ValueKey<String>('assistant-user-bubble-user')),
        );
        // The visible yellow disc sits inside this full touch target.
        final Rect retry = tester.getRect(find.byTooltip('重试任务'));
        // The neutral caption stays close to and right-aligned with the bubble.
        final Rect failure = tester.getRect(
          find.byKey(const ValueKey<String>('assistant-android-failure-run')),
        );
        expect(retry.right, lessThanOrEqualTo(bubble.left));
        expect(retry.center.dy, closeTo(bubble.center.dy, .1));
        expect(retry.height, greaterThanOrEqualTo(48));
        expect(failure.right, closeTo(bubble.right, .1));
        expect(failure.top - bubble.bottom, inInclusiveRange(6, 14));
        if (placement == 'user') {
          expect(
            tester.widget<Text>(find.text('处理失败，请重试')).style?.color,
            Colors.grey.shade500,
          );
        }
        // Inspect the painted disc independently from its transparent tap area.
        final Finder disc = find.descendant(
          of: find.byKey(const ValueKey<String>('assistant-android-retry-run')),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is DecoratedBox &&
                widget.decoration is BoxDecoration &&
                (widget.decoration as BoxDecoration).shape == BoxShape.circle,
          ),
        );
        expect(disc, findsOneWidget);
        expect(
          (tester.widget<DecoratedBox>(disc).decoration as BoxDecoration).color,
          Colors.amber.shade700,
        );
      }
      if (Platform.environment['OMNI_FEEDBACK_SCREENSHOTS'] == '1') {
        // Capture the real page with isolated data for visual review.
        final RenderRepaintBoundary boundary = tester.renderObject(
          find.byKey(const ValueKey<String>('android-assistant-preview')),
        );
        await tester.runAsync(() async {
          // Render at phone density while keeping the original layout bounds.
          final ui.Image preview = await boundary.toImage(pixelRatio: 2);
          // Encode the rendered page without altering the source image.
          final ByteData? bytes = await preview.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await File('../../output/android-assistant-feedback-$placement.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          preview.dispose();
        });
      }
      // Independent operation errors must not disappear with the run error.
      fixture.view(tester).chat.error = '本机缓存未能保存';
      fixture.view(tester).chat.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('本机缓存未能保存'), findsOneWidget);
      expect(find.text('处理失败，请重试'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('Android流错误先到不闪长提示且重试保留身份门禁', (WidgetTester tester) async {
    // Keep the authoritative run running until its final event is delivered.
    final _AndroidAssistantFixture fixture = _AndroidAssistantFixture();
    fixture.repository.serverRun = <String, dynamic>{
      'id': 'run',
      'conversationId': 'conversation',
      'status': 'running',
    };
    await fixture.mount(
      tester,
      preferences(),
      snapshot: <String, dynamic>{'conversationId': 'conversation'},
    );
    // Exercise the production event listener in server event order.
    final StreamController<AssistantEvent> events =
        fixture.repository.streams.last;
    events.add(
      const AssistantEvent(
        seq: 1,
        type: 'error',
        runId: 'run',
        data: <String, dynamic>{
          'message': '长错误（诊断编号：private-id）',
          'code': 'AI_SUBMISSION_UNKNOWN',
        },
      ),
    );
    await fixture.drain(tester);
    expect(find.text('结果待确认'), findsOneWidget);
    expect(find.textContaining('private-id'), findsNothing);
    await tester.tap(find.byTooltip('重试任务'));
    expect(
      fixture.repository.calls.where((call) => call.path.endsWith('/retry')),
      isEmpty,
    );
    fixture.repository.serverRun = <String, dynamic>{
      ...fixture.repository.serverRun!,
      'status': 'submissionUnknown',
      'errorMessage': '长错误（诊断编号：private-id）',
    };
    events.add(
      AssistantEvent(
        seq: 2,
        type: 'run.updated',
        runId: 'run',
        data: <String, dynamic>{'run': fixture.repository.serverRun},
      ),
    );
    await fixture.drain(tester);
    expect(find.text('结果待确认'), findsOneWidget);
    fixture.view(tester).chat.pending = <String, dynamic>{
      'clientMessageId': 'pending',
    };
    fixture.view(tester).chat.notifyListeners();
    await tester.pump();
    await tester.tap(find.byTooltip('重试任务'));
    expect(
      fixture.repository.calls.where((call) => call.path.endsWith('/retry')),
      isEmpty,
    );
    fixture.view(tester).chat.pending = null;
    fixture.view(tester).chat.notifyListeners();
    await tester.pump();
    await tester.tap(find.byTooltip('重试任务'));
    await fixture.drain(tester);
    expect(
      fixture.repository.calls.where((call) => call.path == '/runs/run/retry'),
      hasLength(1),
    );
    await fixture.view(tester).chat.create();
    await fixture.drain(tester);
    expect(find.text('结果待确认'), findsNothing);
    expect(fixture.view(tester).chat.streamFailure, isNull);
    expect(tester.takeException(), isNull);
  });
}
