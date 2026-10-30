part of '../assistant_test.dart';

/// Real page fixture with isolated persistence, speech and server boundaries.
class _AndroidAssistantFixture {
  /// Private SQLite cache owned by this scenario.
  final AssistantCache cache = AssistantCache.forTesting(
    NativeDatabase.memory(),
  );

  /// Controlled endpoints also expose delayed search responses.
  final _AndroidAssistantRepository repository = _AndroidAssistantRepository(
    _Auth(),
  );

  /// Native capture substitute never requests a system microphone.
  final FakeVoiceRecorder recorder = FakeVoiceRecorder();

  /// Speech completion is explicitly delivered by each scenario.
  final FakeSpeechConnection speech = FakeSpeechConnection();

  /// Current mounted production view.
  AssistantAndroidView view(WidgetTester tester) =>
      tester.widget<AssistantAndroidView>(find.byType(AssistantAndroidView));

  /// Flush sequential stream cleanup and SQLite work across real event turns.
  Future<void> drain(WidgetTester tester) async {
    for (int turn = 0; turn < 4; turn++) {
      await tester.pump();
      await tester.runAsync(_settle);
    }
  }

  /// Mount with production theme, controllers, input and keyboard avoidance.
  Future<void> mount(
    WidgetTester tester,
    SharedPreferences preferences, {
    Size size = const Size(390, 844),
    double textScale = 1,
    Brightness brightness = Brightness.light,
    bool disableAnimations = false,
    Map<String, dynamic>? snapshot,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    if (snapshot != null) {
      await cache.save(
        AssistantCache.scopeFor('https://example.com/api', 'owner'),
        snapshot,
      );
    }
    repository.responses['/attachments/capabilities'] = <String, dynamic>{
      'enabled': true,
      'extensions': <String>['txt', 'png'],
    };
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await drain(tester);
      await cache.close();
      await recorder.audio.close();
      await speech.output.close();
      for (final StreamController<AssistantEvent> stream
          in repository.streams) {
        await stream.close();
      }
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          authControllerProvider.overrideWith(_AuthController.new),
          assistantRepositoryProvider.overrideWithValue(repository),
          assistantCacheProvider.overrideWithValue(cache),
          assistantSettingsProvider.overrideWith(
            (Ref ref) async => <String, dynamic>{
              'enabled': true,
              'revision': 4,
              'profileId': 'one',
              'memoryReadEnabled': true,
              'memoryWriteEnabled': true,
              'profiles': <Object>[
                <String, dynamic>{
                  'id': 'one',
                  'name': '日常模型',
                  'model': 'test-model',
                  'hasApiKey': true,
                },
                <String, dynamic>{
                  'id': 'two',
                  'name': '备用模型',
                  'model': 'test-model-2',
                  'hasApiKey': true,
                },
              ],
            },
          ),
          syncRuntimeProvider.overrideWithValue(_ClarificationSync()),
          noteRecorderProvider.overrideWithValue(_VoiceNoteRecorder()),
          assistantVoiceRecorderFactoryProvider.overrideWithValue(
            () => recorder,
          ),
          assistantSpeechConnectorProvider.overrideWithValue(
            (_, _) async => speech,
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.build(brightness: brightness)
              .copyWith(platform: TargetPlatform.android),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScale),
              disableAnimations: disableAnimations,
            ),
            child: child!,
          ),
          home: const RepaintBoundary(
            key: ValueKey<String>('android-assistant-preview'),
            child: Scaffold(body: SafeArea(child: AssistantPage())),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Enter speech mode and hold the actual pointer target.
  Future<TestGesture> hold(WidgetTester tester, {bool ready = true}) async {
    await tester.tap(
      find.byKey(const ValueKey<String>('assistant-voice-button')),
    );
    await tester.pumpAndSettle();
    // This pointer remains alive while transcripts rebuild the page.
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(
        find.byKey(const ValueKey<String>('assistant-voice-hold')),
      ),
    );
    await tester.pump();
    if (ready) {
      speech.output.add(<String, dynamic>{'type': 'ready'});
      await tester.pump();
      await tester.pump();
      expect(recorder.starts, 1);
    }
    return gesture;
  }

  /// Inspect actual message submissions without counting conversation creation.
  List<Map<String, dynamic>> get submissions => repository.calls
      .where((call) => call.method == 'POST' && call.path.endsWith('/messages'))
      .map((call) => Map<String, dynamic>.from(call.data! as Map))
      .toList();
}

/// Delayed queries prove that an older response cannot replace a newer result.
class _AndroidAssistantRepository extends _Repository {
  /// Requests waiting for an explicit response.
  final Map<String, Completer<Map<String, dynamic>>> queries = {};

  /// Reuse the established synthetic authenticated protocol.
  _AndroidAssistantRepository(super.auth);

  /// Intercept only configured searches; other paths retain realistic behavior.
  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Object? data,
  }) {
    // A queued response allows genuine out-of-order network completion.
    final Completer<Map<String, dynamic>>? pending = queries[path];
    if (pending != null) {
      calls.add((method: method, path: path, data: data));
      return pending.future;
    }
    if (method == 'PATCH' && path.startsWith('/conversations/')) {
      calls.add((method: method, path: path, data: data));
      return Future<Map<String, dynamic>>.value(<String, dynamic>{
        'id': path.split('/').last,
        ...Map<String, dynamic>.from(data! as Map),
      });
    }
    return super.request(method, path, data: data);
  }
}

/// Save optional Chinese previews outside tracked source files.
Future<void> _androidAssistantPreview(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('ASSISTANT_PREVIEW')) return;
  // Asset decoding needs a real event turn before the first dark preview.
  await tester.runAsync(
    () => precacheImage(
      const AssetImage('assets/icon/app_icon.png'),
      tester.element(
        find.byKey(const ValueKey<String>('android-assistant-preview')),
      ),
    ),
  );
  // Capture exactly the production surface rendered by this scenario.
  final RenderRepaintBoundary boundary = tester
      .renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey<String>('android-assistant-preview')),
      );
  // Restore the test binding's debug flags before it checks invariants.
  final bool previousShadows = debugDisableShadows;
  try {
    debugDisableShadows = false;
    boundary.reassemble();
    await tester.pump();
    await tester.runAsync(() async {
      // Keep physical resolution equal to the test device for comparison.
      final ui.Image rendered = await boundary.toImage();
      // PNG encoding and disk I/O complete outside the fake event clock.
      final ByteData? bytes = await rendered.toByteData(
        format: ui.ImageByteFormat.png,
      );
      // The output directory contains synthetic UI evidence only.
      final Directory directory = Directory(
        '../../output/assistant-android-20261029',
      );
      await directory.create(recursive: true);
      await File('${directory.path}/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      rendered.dispose();
    });
  } finally {
    debugDisableShadows = previousShadows;
    boundary.reassemble();
    await tester.pump();
  }
}

/// Register Android behavior independently of Windows click-to-record tests.
void _registerAndroidAssistantScenarios(
  SharedPreferences Function() preferences,
) {
  for (final Brightness brightness in Brightness.values) {
    testWidgets('Android改版 ${brightness.name} 原位键盘、草稿和侧栏关闭', (
      WidgetTester tester,
    ) async {
      // A private fixture exercises the real AssistantPage branch.
      final _AndroidAssistantFixture fixture = _AndroidAssistantFixture();
      await fixture.mount(tester, preferences(), brightness: brightness);
      expect(find.text('今天有什么可以帮到你？'), findsOneWidget);
      expect(find.text('帮我做本周总结'), findsNothing);
      expect(find.text('深度思考'), findsNothing);
      expect(find.text('智能搜索'), findsNothing);
      await _androidAssistantPreview(tester, 'welcome-${brightness.name}');
      // Focus and composition stay attached while the scaffold resizes.
      final TextEditingController input = fixture.view(tester).input;
      await tester.enterText(
        find.byKey(const ValueKey<String>('assistant-input')),
        '原位输入\n第二行',
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(identical(input, fixture.view(tester).input), isTrue);
      expect(find.byType(OmniDialogScaffold), findsNothing);
      expect(
        tester
            .getBottomLeft(
              find.byKey(const ValueKey<String>('assistant-android-composer')),
            )
            .dy,
        lessThanOrEqualTo(544),
      );
      expect(
        find.byKey(const ValueKey<String>('assistant-send-button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('assistant-voice-button')),
        findsOneWidget,
      );
      await _androidAssistantPreview(tester, 'keyboard-${brightness.name}');
      tester.view.resetViewInsets();
      await tester.tap(
        find.byKey(const ValueKey<String>('assistant-history-button')),
      );
      await tester.pumpAndSettle();
      expect(fixture.view(tester).inputFocus.hasFocus, isFalse);
      expect(
        find.byKey(const ValueKey<String>('assistant-history-search')),
        findsOneWidget,
      );
      await _androidAssistantPreview(tester, 'sidebar-${brightness.name}');
      await tester.tapAt(Offset(tester.view.physicalSize.width - 20, 100));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('assistant-history-search')),
        findsNothing,
      );
      expect(input.text, '原位输入\n第二行');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Android改版 松手只在final后合并文字附件发送一次，忽略自动发送偏好', (
    WidgetTester tester,
  ) async {
    // A false desktop preference must not override the deliberate hold gesture.
    final _AndroidAssistantFixture fixture = _AndroidAssistantFixture();
    await preferences().setBool(assistantVoiceAutoSendKey, false);
    await fixture.mount(
      tester,
      preferences(),
      snapshot: <String, dynamic>{
        'conversationId': 'conversation',
        'attachments': <Object>[
          <String, dynamic>{
            'id': 'existing-document',
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
    // Keep the target mounted through multiple real transcript callbacks.
    final TestGesture gesture = await fixture.hold(tester);
    fixture.speech.text('新文字');
    await tester.pump();
    expect(fixture.view(tester).input.text, '前新文字后');
    expect(
      find.byKey(const ValueKey<String>('assistant-voice-hold')),
      findsOneWidget,
    );
    expect(fixture.submissions, isEmpty);
    await gesture.up();
    await fixture.drain(tester);
    expect(fixture.speech.endings, <bool>[true]);
    expect(fixture.submissions, isEmpty);
    fixture.speech.complete('新文字。');
    await fixture.drain(tester);
    fixture.speech.complete('重复final');
    await fixture.drain(tester);
    expect(fixture.submissions, hasLength(1));
    expect(fixture.submissions.single['content'], '前新文字。后');
    expect(fixture.submissions.single['attachmentIds'], <String>[
      'existing-document',
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android改版 上滑取消还原草稿选区，迟到final不覆盖', (WidgetTester tester) async {
    // This scenario protects a pre-existing selection from discarded dictation.
    final _AndroidAssistantFixture fixture = _AndroidAssistantFixture();
    await fixture.mount(tester, preferences());
    await tester.enterText(
      find.byKey(const ValueKey<String>('assistant-input')),
      '前原文后',
    );
    fixture.view(tester).input.selection = const TextSelection(
      baseOffset: 1,
      extentOffset: 3,
    );
    // The pointer starts within the production hold surface.
    final TestGesture gesture = await fixture.hold(tester);
    fixture.speech.text('临时转写');
    await tester.pump();
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump();
    expect(find.textContaining('松开取消'), findsWidgets);
    await gesture.up();
    await fixture.drain(tester);
    fixture.speech.text('迟到文字');
    fixture.speech.complete('迟到完成');
    await fixture.drain(tester);
    expect(fixture.view(tester).input.text, '前原文后');
    expect(
      fixture.view(tester).input.selection,
      const TextSelection(baseOffset: 1, extentOffset: 3),
    );
    expect(fixture.submissions, isEmpty);
    expect(fixture.recorder.disposals, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android改版 上滑再滑回可发送，第二个触点不结束原录音', (WidgetTester tester) async {
    // Only the initiating pointer owns the completion decision.
    final _AndroidAssistantFixture fixture = _AndroidAssistantFixture();
    await fixture.mount(tester, preferences());
    // The first pointer survives secondary touch and transcript rebuilds.
    final TestGesture gesture = await fixture.hold(tester);
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 80));
    await tester.pump();
    // An unrelated contact cannot release the microphone owner's gesture.
    final TestGesture second = await tester.startGesture(
      tester.getCenter(
        find.byKey(const ValueKey<String>('assistant-voice-hold')),
      ),
      pointer: 9,
    );
    await second.up();
    await tester.pump();
    expect(fixture.view(tester).voice.phase, AssistantVoicePhase.recording);
    fixture.speech.text('完成');
    await tester.pump();
    await gesture.up();
    await fixture.drain(tester);
    fixture.speech.complete('完成');
    await fixture.drain(tester);
    expect(fixture.submissions, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android改版 权限返回前松手不迟到开麦', (WidgetTester tester) async {
    // Permission remains unresolved until after the user has released.
    final _AndroidAssistantFixture fixture = _AndroidAssistantFixture();
    // The pending native response simulates a first-use permission prompt.
    final Completer<bool> permission = Completer<bool>();
    fixture.recorder.permission = permission.future;
    await fixture.mount(tester, preferences());
    // Do not deliver handshake readiness while permission is still pending.
    final TestGesture gesture = await fixture.hold(tester, ready: false);
    expect(fixture.view(tester).voice.phase, AssistantVoicePhase.preparing);
    await gesture.up();
    await tester.pump();
    permission.complete(true);
    await fixture.drain(tester);
    expect(fixture.recorder.starts, 0);
    expect(fixture.recorder.disposals, 1);
    expect(fixture.submissions, isEmpty);
    expect(fixture.view(tester).voice.busy, isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final bool empty in <bool>[true, false]) {
    testWidgets('Android改版 ${empty ? '空识别' : '网络失败'}保留可检查草稿且不自动发送', (
      WidgetTester tester,
    ) async {
      // Failures must expose text instead of hiding it behind the hold button.
      final _AndroidAssistantFixture fixture = _AndroidAssistantFixture();
      await fixture.mount(tester, preferences());
      await tester.enterText(
        find.byKey(const ValueKey<String>('assistant-input')),
        '旧草稿',
      );
      // Begin the same gesture used for successful recording.
      final TestGesture gesture = await fixture.hold(tester);
      fixture.speech.text('临时文字');
      await tester.pump();
      if (empty) {
        await gesture.up();
        await fixture.drain(tester);
        fixture.speech.complete('');
      } else {
        fixture.speech.output.add(<String, dynamic>{
          'type': 'error',
          'code': 'ASSISTANT_SPEECH_TIMEOUT',
        });
      }
      await fixture.drain(tester);
      if (!empty) await gesture.up();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('assistant-input')),
        findsOneWidget,
      );
      expect(fixture.view(tester).input.text, empty ? '旧草稿' : '旧草稿临时文字');
      expect(fixture.submissions, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Android改版 等待最终转写时切换会话不会发送到新会话', (WidgetTester tester) async {
    // Final results must retain their starting conversation identity.
    final _AndroidAssistantFixture fixture = _AndroidAssistantFixture();
    await fixture.mount(tester, preferences());
    // Hold once, then wait in finishing while navigation takes ownership.
    final TestGesture gesture = await fixture.hold(tester);
    fixture.speech.text('未发送的内容');
    await tester.pump();
    await gesture.up();
    await fixture.drain(tester);
    // Selecting through the real controller invokes its cancellation boundary.
    final Future<void> selection = fixture
        .view(tester)
        .chat
        .select('conversation');
    await fixture.drain(tester);
    await selection;
    fixture.speech.complete('迟到最终内容');
    await fixture.drain(tester);
    expect(fixture.view(tester).chat.conversationId, 'conversation');
    expect(fixture.view(tester).input.text, isEmpty);
    expect(fixture.submissions, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android改版 侧栏日期分组、全文搜索乱序和新对话草稿', (WidgetTester tester) async {
    // Use local wall dates so the grouping remains valid in later runs.
    final _AndroidAssistantFixture fixture = _AndroidAssistantFixture();
    // Current date defines calendar buckets independently of execution time.
    final DateTime now = DateTime.now();
    fixture.repository.responses['/conversations'] = <String, dynamic>{
      'items': <Object>[
        <String, dynamic>{
          'id': 'pin',
          'title': '置顶会话',
          'isPinned': true,
          'updatedAt': now.toIso8601String(),
        },
        <String, dynamic>{
          'id': 'today',
          'title': '今日会话',
          'updatedAt': now.toIso8601String(),
        },
        <String, dynamic>{
          'id': 'yesterday',
          'title': '昨日会话',
          'updatedAt': now.subtract(const Duration(days: 1)).toIso8601String(),
        },
        <String, dynamic>{
          'id': 'week',
          'title': '本周会话',
          'updatedAt': now.subtract(const Duration(days: 3)).toIso8601String(),
        },
        <String, dynamic>{'id': 'old', 'title': '旧会话'},
      ],
    };
    fixture.repository.queries['/conversations?query=old'] =
        Completer<Map<String, dynamic>>();
    fixture.repository.queries['/conversations?query=new'] =
        Completer<Map<String, dynamic>>();
    await fixture.mount(tester, preferences());
    await tester.enterText(
      find.byKey(const ValueKey<String>('assistant-input')),
      '保留的新草稿',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('assistant-history-button')),
    );
    await tester.pumpAndSettle();
    for (final String group in <String>['置顶', '今天', '昨天', '7天内', '更早']) {
      expect(find.text(group), findsOneWidget);
    }
    expect(find.text('置顶会话'), findsOneWidget);
    // Debounce requests complete out of order, with an old result arriving last.
    final Finder search = find.byKey(
      const ValueKey<String>('assistant-history-search'),
    );
    await tester.enterText(search, 'old');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(search, 'new');
    await tester.pump(const Duration(milliseconds: 300));
    fixture.repository.queries['/conversations?query=new']!.complete(
      <String, dynamic>{
        'items': <Object>[
          <String, String>{'id': 'new-result', 'title': '最新全文结果'},
        ],
      },
    );
    await tester.pumpAndSettle();
    fixture.repository.queries['/conversations?query=old']!.complete(
      <String, dynamic>{
        'items': <Object>[
          <String, String>{'id': 'old-result', 'title': '过时结果'},
        ],
      },
    );
    await tester.pumpAndSettle();
    expect(find.text('最新全文结果'), findsOneWidget);
    expect(find.text('过时结果'), findsNothing);
    await tester.tapAt(Offset(tester.view.physicalSize.width - 20, 100));
    await tester.pumpAndSettle();
    expect(fixture.view(tester).input.text, '保留的新草稿');
    await tester.tap(
      find.byKey(const ValueKey<String>('assistant-new-conversation-button')),
    );
    await tester.pumpAndSettle();
    expect(
      fixture.repository.calls.where((call) => call.method == 'POST'),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android改版 最终转写后发送门禁失效仍显示可检查的草稿', (WidgetTester tester) async {
    // A late offline state fails before chat.send can publish an error.
    final _AndroidAssistantFixture fixture = _AndroidAssistantFixture();
    await fixture.mount(tester, preferences());
    // The gesture ends successfully while the final transcript remains pending.
    final TestGesture gesture = await fixture.hold(tester);
    fixture.speech.text('检查后发送');
    await tester.pump();
    await gesture.up();
    await fixture.drain(tester);
    fixture.view(tester).chat.offline = true;
    fixture.speech.complete('检查后发送');
    await fixture.drain(tester);
    expect(
      find.byKey(const ValueKey<String>('assistant-input')),
      findsOneWidget,
    );
    expect(fixture.view(tester).input.text, '检查后发送');
    expect(fixture.submissions, isEmpty);
    expect(find.text('当前离线，草稿已保留，请联网后发送'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android改版 减少动画即时展开且消息保留正文与保存操作', (WidgetTester tester) async {
    // Synthetic messages verify the production answer layout without AI calls.
    final _AndroidAssistantFixture fixture = _AndroidAssistantFixture();
    fixture.repository.serverMessages = <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'question',
        'role': 'user',
        'content': '帮我整理今天的安排',
        'createdAt': '2026-10-29T08:00:00Z',
      },
      <String, dynamic>{
        'id': 'reply',
        'role': 'assistant',
        'content': '可以先按优先级安排：\n\n1. 完成今天最重要的一件事\n2. 留出时间处理临时事项\n3. 晚上简单回顾完成情况',
        'createdAt': '2026-10-29T08:00:01Z',
      },
    ];
    await fixture.mount(
      tester,
      preferences(),
      disableAnimations: true,
      snapshot: <String, dynamic>{'conversationId': 'conversation'},
    );
    expect(find.text('帮我整理今天的安排'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('assistant-answer-actions-row-reply')),
      findsOneWidget,
    );
    await _androidAssistantPreview(tester, 'conversation-light');
    await tester.tap(
      find.byKey(const ValueKey<String>('assistant-history-button')),
    );
    await tester.pump();
    expect(
      find
          .byKey(const ValueKey<String>('assistant-history-search'))
          .hitTestable(),
      findsOneWidget,
    );
    expect(fixture.view(tester).inputFocus.hasFocus, isFalse);
    expect(
      find
          .byKey(const ValueKey<String>('assistant-new-conversation-button'))
          .hitTestable(),
      findsNothing,
    );
    await tester.tapAt(const Offset(370, 100));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('assistant-history-search')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android改版 Android设置隐藏桌面自动发送偏好', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences()),
          assistantSettingsProvider.overrideWith((Ref ref) async => null),
        ],
        child: MaterialApp(
          theme: AppTheme.build(brightness: Brightness.light)
              .copyWith(platform: TargetPlatform.android),
          home: const Scaffold(
            body: SingleChildScrollView(child: AssistantSettingsSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('assistant-voice-auto-send-switch')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
