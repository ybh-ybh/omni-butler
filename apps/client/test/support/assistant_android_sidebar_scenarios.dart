part of '../assistant_test.dart';

/// Opens the production sidebar through its actual header action.
Future<void> _openAndroidSidebar(WidgetTester tester) async {
  await tester.tap(
    find.byKey(const ValueKey<String>('assistant-history-button')),
  );
  await tester.pumpAndSettle();
  expect(
    find.byKey(const ValueKey<String>('assistant-android-sidebar')),
    findsOneWidget,
  );
}

/// Registers sidebar behavior against the existing isolated Android fixture.
void _registerAndroidSidebarScenarios(
  SharedPreferences Function() preferences,
) {
  testWidgets('Android侧栏 长按非当前会话的置顶重命名删除绑定真实ID', (WidgetTester tester) async {
    // The current chat differs from the row targeted by all three operations.
    final _AndroidAssistantFixture fixture = _AndroidAssistantFixture();
    fixture.repository.responses['/conversations'] = <String, dynamic>{
      'items': <Object>[
        <String, dynamic>{'id': 'conversation', 'title': '当前对话'},
        <String, dynamic>{'id': 'other', 'title': '其他对话'},
      ],
    };
    await fixture.mount(
      tester,
      preferences(),
      snapshot: <String, dynamic>{'conversationId': 'conversation'},
    );
    await _openAndroidSidebar(tester);
    await tester.longPress(
      find.byKey(const ValueKey<String>('assistant-history-row-other')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('置顶').last);
    await fixture.drain(tester);
    await tester.pumpAndSettle();
    expect(
      fixture.repository.calls.where(
        (call) =>
            call.method == 'PATCH' &&
            call.path == '/conversations/other' &&
            (call.data! as Map)['isPinned'] == true,
      ),
      hasLength(1),
    );
    expect(fixture.view(tester).chat.conversationId, 'conversation');
    expect(
      fixture
          .view(tester)
          .chat
          .conversations
          .singleWhere((item) => item['id'] == 'other')['isPinned'],
      isTrue,
    );
    await tester.longPress(
      find.byKey(const ValueKey<String>('assistant-history-row-other')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(OmniDialogScaffold),
        matching: find.byType(OmniTextField),
      ),
      '修改其他对话',
    );
    await tester.tap(find.widgetWithText(OmniButton, '保存'));
    await fixture.drain(tester);
    await tester.pumpAndSettle();
    expect(
      fixture.repository.calls.where(
        (call) =>
            call.method == 'PATCH' &&
            call.path == '/conversations/other' &&
            (call.data! as Map)['title'] == '修改其他对话',
      ),
      hasLength(1),
    );
    await tester.longPress(
      find.byKey(const ValueKey<String>('assistant-history-row-other')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除聊天'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OmniButton, '删除'));
    await fixture.drain(tester);
    await tester.pumpAndSettle();
    expect(
      fixture.repository.calls.where(
        (call) =>
            call.method == 'DELETE' && call.path == '/conversations/other',
      ),
      hasLength(1),
    );
    expect(fixture.view(tester).chat.conversationId, 'conversation');
    expect(
      fixture.repository.calls.where(
        (call) =>
            <String>{'PATCH', 'DELETE'}.contains(call.method) &&
            call.path == '/conversations/conversation',
      ),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android侧栏 模型保存使用打开时revision并在侧栏关闭后刷新设置', (
    WidgetTester tester,
  ) async {
    // A delayed settings write outlives the sidebar that initiated it.
    final _AndroidAssistantFixture fixture = _AndroidAssistantFixture();
    await fixture.mount(tester, preferences());
    // The provider scope remains mounted after the drawer disappears.
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(AssistantAndroidView)),
      listen: false,
    );
    // Extend only this fixture's synthetic settings with selectable profiles.
    final Map<String, dynamic> settings = container
        .read(assistantSettingsProvider)
        .requireValue!;
    settings['profiles'] = <Map<String, dynamic>>[
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
      <String, dynamic>{
        'id': 'missing-key',
        'model': '尚未配置密钥',
        'hasApiKey': false,
      },
    ];
    settings['memoryReadEnabled'] = false;
    settings['timeZone'] = 'Europe/Berlin';
    // Complete the request only after the sidebar state has been disposed.
    final Completer<Map<String, dynamic>> saved =
        Completer<Map<String, dynamic>>();
    fixture.repository.queries['/settings'] = saved;
    await _openAndroidSidebar(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('assistant-model-button')),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<OmniPopupMenuItem<String>>(
            find.byKey(
              const ValueKey<String>('assistant-android-model-missing-key'),
            ),
          )
          .enabled,
      isFalse,
    );
    // Simulate a later settings refresh while the menu still shows revision four.
    settings['revision'] = 99;
    await tester.tap(
      find.byKey(const ValueKey<String>('assistant-android-model-two')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await fixture.drain(tester);
    // Inspect the actual request rather than a copied implementation helper.
    final Map<String, dynamic> payload = Map<String, dynamic>.from(
      fixture.repository.calls
              .singleWhere(
                (call) => call.method == 'PUT' && call.path == '/settings',
              )
              .data!
          as Map,
    );
    expect(payload, <String, dynamic>{
      'revision': 4,
      'enabled': true,
      'profileId': 'two',
      'memoryReadEnabled': false,
      'memoryWriteEnabled': true,
      'timeZone': 'Europe/Berlin',
    });
    await tester.tapAt(const Offset(370, 100));
    // Establish the reverse ticker before advancing its elapsed duration.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('assistant-android-sidebar')),
      findsNothing,
    );
    saved.complete(<String, dynamic>{});
    await fixture.drain(tester);
    await tester.pumpAndSettle();
    expect(
      identical(
        container.read(assistantSettingsProvider).requireValue,
        settings,
      ),
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android侧栏 320宽两倍字号键盘短窗保留搜索更多和系统返回', (WidgetTester tester) async {
    // Large text and a keyboard leave less height than the normal fixed chrome.
    final _AndroidAssistantFixture fixture = _AndroidAssistantFixture();
    await fixture.mount(
      tester,
      preferences(),
      size: const Size(320, 640),
      textScale: 2,
    );
    await _openAndroidSidebar(tester);
    await tester.enterText(
      find.byKey(const ValueKey<String>('assistant-history-search')),
      '找不到的对话',
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 400);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // The short-layout list must make bottom actions reachable by scrolling.
    final Finder more = find.byKey(
      const ValueKey<String>('assistant-sidebar-more'),
    );
    await tester.ensureVisible(more);
    await tester.pumpAndSettle();
    expect(more.hitTestable(), findsOneWidget);
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.text('AI 设置'), findsOneWidget);
    expect(find.text('助手记忆'), findsOneWidget);
    expect(find.text('返回首页'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // The first back dismisses the menu without navigating the application.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    tester.view.resetViewInsets();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('assistant-android-sidebar')),
      findsNothing,
    );
    await _openAndroidSidebar(tester);
    expect(
      find
          .byKey(const ValueKey<String>('assistant-history-search'))
          .hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android侧栏 搜索分页去重并在重复游标时停止请求', (WidgetTester tester) async {
    // Repeated identities and a looping cursor model a malformed second page.
    final _AndroidAssistantFixture fixture = _AndroidAssistantFixture();
    fixture.repository.responses['/conversations?query=page'] =
        <String, dynamic>{
          'items': <Object>[
            <String, String>{'id': 'first', 'title': '第一页'},
            <String, String>{'id': 'first', 'title': '重复第一页'},
          ],
          'nextCursor': 'again',
        };
    fixture.repository.responses['/conversations?query=page&cursor=again'] =
        <String, dynamic>{
          'items': <Object>[
            <String, String>{'id': 'first', 'title': '跨页重复'},
            <String, String>{'id': 'second', 'title': '第二页'},
          ],
          'nextCursor': 'again',
        };
    await fixture.mount(tester, preferences());
    await _openAndroidSidebar(tester);
    await tester.enterText(
      find.byKey(const ValueKey<String>('assistant-history-search')),
      'page',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('assistant-history-row-first')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('assistant-history-row-second')),
      findsOneWidget,
    );
    expect(find.text('搜索分页异常，请重新搜索'), findsOneWidget);
    // More frames must not retry a cursor without a new explicit user action.
    await tester.pump(const Duration(seconds: 1));
    expect(
      fixture.repository.calls.where(
        (call) => call.path.startsWith('/conversations?query=page'),
      ),
      hasLength(2),
    );
    expect(tester.takeException(), isNull);
  });
}
