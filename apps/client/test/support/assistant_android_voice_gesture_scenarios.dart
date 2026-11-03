part of '../assistant_test.dart';

/// Start production dictation without touching the microphone mode switch.
Future<TestGesture> _directAssistantHold(
  WidgetTester tester,
  _AndroidAssistantFixture fixture, {
  bool ready = true,
}) async {
  // The transparent target owns the gesture even after its text child changes.
  final TestGesture gesture = await tester.startGesture(
    tester.getCenter(
      find.byKey(const ValueKey<String>('assistant-input-voice-target')),
    ),
  );
  await tester.pump(const Duration(milliseconds: 501));
  await fixture.drain(tester);
  if (ready) {
    fixture.speech.output.add(<String, dynamic>{'type': 'ready'});
    await fixture.drain(tester);
    expect(fixture.view(tester).voice.phase, AssistantVoicePhase.recording);
  }
  return gesture;
}

/// Render the root overlay as well as the retained assistant workspace.
Future<void> _assistantVoiceOverlayPreview(
  WidgetTester tester,
  String name,
) async {
  if (!const bool.fromEnvironment('ASSISTANT_PREVIEW')) return;
  // The overlay lives above the page's existing preview boundary.
  final RenderRepaintBoundary boundary = tester.renderObject(
    find.byKey(const ValueKey<String>('android-assistant-root-preview')),
  );
  await tester.runAsync(() async {
    // Phone-density pixels preserve Chinese font rendering for visual review.
    final ui.Image image = await boundary.toImage(pixelRatio: 2);
    // Store lossless evidence without writing generated images into source files.
    final ByteData? bytes = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    await File('../../output/assistant-direct-voice-$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

/// Cover direct holding, native selection, visible partial text and cancellation.
void _registerAndroidVoiceGestureScenarios(
  SharedPreferences Function() preferences,
) {
  testWidgets('Android直接长按500ms才开始，短按输入和编辑长按选词', (WidgetTester tester) async {
    // Fresh capability and audio boundaries prevent real microphone acquisition.
    final _AndroidAssistantFixture fixture = _AndroidAssistantFixture();
    await fixture.mount(tester, preferences());
    // A short tap must open the normal text field without creating audio resources.
    final Finder target = find.byKey(
      const ValueKey<String>('assistant-input-voice-target'),
    );
    await tester.tap(target);
    await tester.pumpAndSettle();
    expect(fixture.view(tester).inputFocus.hasFocus, isTrue);
    expect(fixture.recorderCreations, 0);
    tester.testTextInput.hide();
    await tester.tap(target);
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.enterText(
      find.byKey(const ValueKey<String>('assistant-input')),
      'select these words',
    );
    await tester.pumpAndSettle();
    expect(target, findsNothing);
    await tester.longPressAt(
      tester.getTopLeft(find.byKey(const ValueKey<String>('assistant-input'))) +
          const Offset(24, 24),
    );
    await tester.pumpAndSettle();
    expect(fixture.recorderCreations, 0);
    expect(fixture.view(tester).input.selection.isCollapsed, isFalse);
    fixture.view(tester).input.clear();
    fixture.view(tester).inputFocus.unfocus();
    await tester.pumpAndSettle();
    // Recording must not begin during the pre-threshold part of a real gesture.
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(target),
    );
    await tester.pump(const Duration(milliseconds: 499));
    expect(fixture.recorderCreations, 0);
    await tester.pump(const Duration(milliseconds: 2));
    await fixture.drain(tester);
    expect(fixture.recorderCreations, 1);
    expect(fixture.view(tester).voice.phase, AssistantVoicePhase.preparing);
    await gesture.up();
    await fixture.drain(tester);
    expect(
      find.byKey(const ValueKey<String>('assistant-recording-bubble')),
      findsNothing,
    );
    expect(fixture.submissions, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android直接长按实时显示修订文字，松手final后原任务附件只发送一次', (
    WidgetTester tester,
  ) async {
    // Existing draft selection and attachments must survive the new entry point.
    final _AndroidAssistantFixture fixture = _AndroidAssistantFixture();
    await fixture.mount(
      tester,
      preferences(),
      snapshot: <String, dynamic>{
        'conversationId': 'conversation',
        'attachments': <Object>[
          <String, dynamic>{
            'id': 'document',
            'name': '资料.txt',
            'kind': 'document',
            'status': 'ready',
            'uploaded': true,
            'requiresVision': false,
            'size': 100,
          },
        ],
      },
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('assistant-input')),
      '前旧后',
    );
    fixture.view(tester).input.selection = const TextSelection(
      baseOffset: 1,
      extentOffset: 2,
    );
    fixture.view(tester).inputFocus.unfocus();
    await tester.pumpAndSettle();
    // Only the central text region is captured; accessory buttons stay separate.
    final Rect target = tester.getRect(
      find.byKey(const ValueKey<String>('assistant-input-voice-target')),
    );
    expect(
      target.left,
      greaterThanOrEqualTo(
        tester
            .getRect(
              find.byKey(const ValueKey<String>('assistant-attach-button')),
            )
            .right,
      ),
    );
    expect(
      target.right,
      lessThanOrEqualTo(
        tester
            .getRect(
              find.byKey(const ValueKey<String>('assistant-voice-button')),
            )
            .left,
      ),
    );
    // This pointer remains down while multiple partial transcripts rebuild the UI.
    final TestGesture gesture = await _directAssistantHold(tester, fixture);
    fixture.speech.text('临时文字');
    await fixture.drain(tester);
    expect(
      tester
          .widget<Text>(
            find.byKey(
              const ValueKey<String>('assistant-recording-transcript'),
            ),
          )
          .data,
      '前临时文字后',
    );
    fixture.speech.text('修订文字');
    await fixture.drain(tester);
    expect(
      tester
          .widget<Text>(
            find.byKey(
              const ValueKey<String>('assistant-recording-transcript'),
            ),
          )
          .data,
      '前修订文字后',
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(
              const ValueKey<String>('assistant-recording-transcript'),
            ),
          )
          .style
          ?.fontSize,
      16,
    );
    // The bounded bubble must sit above the actual composer rather than covering it.
    final Rect bubble = tester.getRect(
      find.byKey(const ValueKey<String>('assistant-recording-bubble')),
    );
    expect(
      bubble.bottom,
      closeTo(
        tester
                .getRect(
                  find.byKey(
                    const ValueKey<String>('assistant-android-composer'),
                  ),
                )
                .top -
            16,
        .1,
      ),
    );
    expect(bubble.left, greaterThanOrEqualTo(20));
    await _assistantVoiceOverlayPreview(tester, 'recording-light');
    // A second pointer hits the barrier and must not finish the first recording.
    final TestGesture second = await tester.startGesture(const Offset(10, 100));
    await second.up();
    expect(fixture.view(tester).voice.phase, AssistantVoicePhase.recording);
    await gesture.up();
    await fixture.drain(tester);
    expect(fixture.submissions, isEmpty);
    expect(
      find.byKey(const ValueKey<String>('assistant-recording-bubble')),
      findsOneWidget,
    );
    expect(find.text('正在完成转写…'), findsWidgets);
    fixture.speech.complete('最终文字');
    await fixture.drain(tester);
    fixture.speech.complete('迟到重复final');
    await fixture.drain(tester);
    expect(
      find.byKey(const ValueKey<String>('assistant-recording-bubble')),
      findsNothing,
    );
    expect(fixture.submissions, hasLength(1));
    expect(fixture.submissions.single['content'], '前最终文字后');
    expect(fixture.submissions.single['attachmentIds'], <String>['document']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android直接长按上滑取消与滑回保持同一手势及原选区', (WidgetTester tester) async {
    // Explicit cancellation restores the initial selection instead of partial speech.
    final _AndroidAssistantFixture fixture = _AndroidAssistantFixture();
    await fixture.mount(tester, preferences());
    await tester.enterText(
      find.byKey(const ValueKey<String>('assistant-input')),
      '保留原稿',
    );
    fixture.view(tester).input.selection = const TextSelection(
      baseOffset: 1,
      extentOffset: 3,
    );
    fixture.view(tester).inputFocus.unfocus();
    await tester.pumpAndSettle();
    // Use a real accepted long press rather than calling controller methods.
    final TestGesture gesture = await _directAssistantHold(tester, fixture);
    fixture.speech.text('取消这段');
    await fixture.drain(tester);
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump();
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey<String>('assistant-recording-status')),
          )
          .data,
      '松开取消',
    );
    await gesture.moveBy(const Offset(0, 80));
    await tester.pump();
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey<String>('assistant-recording-status')),
          )
          .data,
      '松开发送，上滑取消',
    );
    await gesture.moveBy(const Offset(0, -80));
    await gesture.up();
    await fixture.drain(tester);
    fixture.speech.complete('迟到final');
    await fixture.drain(tester);
    expect(fixture.view(tester).input.text, '保留原稿');
    expect(
      fixture.view(tester).input.selection,
      const TextSelection(baseOffset: 1, extentOffset: 3),
    );
    expect(fixture.submissions, isEmpty);
    expect(
      find.byKey(const ValueKey<String>('assistant-recording-bubble')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android直接长按首次权限等待松手不迟到开麦', (WidgetTester tester) async {
    // Native authorization may return after the gesture and overlay have ended.
    final _AndroidAssistantFixture fixture = _AndroidAssistantFixture();
    // A controlled permission future makes the dangerous ordering deterministic.
    final Completer<bool> permission = Completer<bool>();
    fixture.recorder.permission = permission.future;
    await fixture.mount(tester, preferences());
    // Only hold acceptance may create the pending recorder.
    final TestGesture gesture = await _directAssistantHold(
      tester,
      fixture,
      ready: false,
    );
    expect(
      find.byKey(const ValueKey<String>('assistant-recording-bubble')),
      findsOneWidget,
    );
    await gesture.up();
    await tester.pump();
    permission.complete(true);
    await fixture.drain(tester);
    expect(fixture.recorder.starts, 0);
    expect(fixture.recorder.disposals, 1);
    expect(fixture.view(tester).voice.busy, isFalse);
    expect(
      find.byKey(const ValueKey<String>('assistant-recording-bubble')),
      findsNothing,
    );
    expect(fixture.submissions, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android直接长按权限中断后旧手指松开不影响新录音', (WidgetTester tester) async {
    // Model a native dialog that interrupts the app before reporting permission.
    final _AndroidAssistantFixture fixture = _AndroidAssistantFixture();
    // First acquisition remains pending while the app loses foreground ownership.
    final Completer<bool> permission = Completer<bool>();
    fixture.recorder.permission = permission.future;
    await fixture.mount(tester, preferences());
    // Keep the old pointer down even after the route cancels its speech session.
    final TestGesture old = await _directAssistantHold(
      tester,
      fixture,
      ready: false,
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    permission.complete(true);
    await fixture.drain(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await fixture.drain(tester);
    expect(
      find.byKey(const ValueKey<String>('assistant-recording-bubble')),
      findsNothing,
    );
    expect(fixture.recorder.starts, 0);
    // A new pointer must be accepted even if the OS never cancelled the old one.
    final TestGesture fresh = await tester.startGesture(
      tester.getCenter(
        find.byKey(const ValueKey<String>('assistant-input-voice-target')),
      ),
    );
    await tester.pump(const Duration(milliseconds: 501));
    await fixture.drain(tester);
    fixture.speech.output.add(<String, dynamic>{'type': 'ready'});
    await fixture.drain(tester);
    expect(fixture.view(tester).voice.phase, AssistantVoicePhase.recording);
    await old.up();
    await tester.pump();
    expect(fixture.view(tester).voice.phase, AssistantVoicePhase.recording);
    await fresh.cancel();
    await fixture.drain(tester);
    expect(fixture.submissions, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final Brightness brightness in Brightness.values) {
    testWidgets('Android直接长按 ${brightness.name} 窄屏双倍字号键盘长文本可见且滚动', (
      WidgetTester tester,
    ) async {
      // Root overlay metrics must respect both safe areas and an already open IME.
      final _AndroidAssistantFixture fixture = _AndroidAssistantFixture();
      await fixture.mount(
        tester,
        preferences(),
        size: const Size(320, 640),
        textScale: 2,
        brightness: brightness,
        disableAnimations: true,
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      // Empty focused fields still support dictation while normal editing retains selection.
      final TestGesture gesture = await _directAssistantHold(tester, fixture);
      fixture.speech.text(List<String>.filled(40, '这是可修订的实时语音文字。').join('\n'));
      await fixture.drain(tester);
      await tester.pump();
      // Only the preview scrolls; the transcript's final lines stay in view.
      final Finder scroll = find.descendant(
        of: find.byKey(
          const ValueKey<String>('assistant-recording-transcript-scroll'),
        ),
        matching: find.byType(Scrollable),
      );
      // Read the actual render scroll extent, not an implementation padding constant.
      final ScrollPosition position = tester
          .state<ScrollableState>(scroll)
          .position;
      expect(position.maxScrollExtent, greaterThan(0));
      expect(position.pixels, closeTo(position.maxScrollExtent, .1));
      // The card must remain bounded and entirely above the live input surface.
      final Rect bubble = tester.getRect(
        find.byKey(const ValueKey<String>('assistant-recording-bubble')),
      );
      expect(bubble.height, lessThanOrEqualTo(240));
      expect(bubble.top, greaterThanOrEqualTo(12));
      expect(
        bubble.bottom,
        lessThanOrEqualTo(
          tester
                  .getRect(
                    find.byKey(
                      const ValueKey<String>('assistant-android-composer'),
                    ),
                  )
                  .top -
              16,
        ),
      );
      await _assistantVoiceOverlayPreview(tester, 'large-${brightness.name}');
      await gesture.cancel();
      await fixture.drain(tester);
      expect(
        find.byKey(const ValueKey<String>('assistant-recording-bubble')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Android直接长按系统返回先取消录音再返回首页', (WidgetTester tester) async {
    // The real tab router distinguishes closing the overlay from leaving AI.
    final _AssistantTabFixture fixture = _AssistantTabFixture();
    await fixture.mountTabs(tester, preferences());
    await fixture.selectTab(tester, 'assistant');
    // The original pointer must not submit after the system back action cancels it.
    final TestGesture gesture = await _directAssistantHold(tester, fixture);
    fixture.speech.text('返回取消');
    await tester.pump();
    await tester.binding.handlePopRoute();
    await fixture.drain(tester);
    expect(fixture.router.state.uri.path, '/assistant');
    expect(fixture.view(tester).voice.phase, AssistantVoicePhase.idle);
    expect(
      find.byKey(const ValueKey<String>('assistant-recording-bubble')),
      findsNothing,
    );
    await gesture.up();
    fixture.speech.complete('迟到完成');
    await fixture.drain(tester);
    expect(fixture.submissions, isEmpty);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(fixture.router.state.uri.path, '/home');
    expect(tester.takeException(), isNull);
  });
}
