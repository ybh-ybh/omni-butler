part of 'notes_page_test.dart';

/// 同一张生产卡片的指定入口，避免操作预载页面。
Finder _androidCardPart(String id, Finder matching) => find.descendant(
  of: find.byKey(ValueKey('android-note-card-$id')),
  matching: matching,
);

/// 两次物理点击验证手势竞争，不直接调用编辑回调。
Future<void> _androidDoubleTap(WidgetTester tester, Finder target) async {
  await tester.pump(const Duration(milliseconds: 350));
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await tester.pump(const Duration(milliseconds: 60));
  await tester.tap(target);
  await _settle(tester);
}

/// 真实三点菜单等待仓储查回，而不是测试构造的静态菜单。
Future<void> _androidCardMenu(
  WidgetTester tester, [
  String id = 'target',
]) async {
  if (_androidCardPart(id, find.byTooltip('笔记操作')).evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      _androidCardPart(id, find.byTooltip('笔记操作')),
      100,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('android-notes-list')),
            matching: find.byType(Scrollable),
          )
          .last,
    );
  }
  await tester.ensureVisible(_androidCardPart(id, find.byTooltip('笔记操作')));
  await tester.pump();
  await tester.tap(_androidCardPart(id, find.byTooltip('笔记操作')));
  await _settle(tester);
}

/// 显式观察平台剪贴板调用，测试运行器不提供真实系统剪贴板。
ValueNotifier<String?> _androidClipboard(WidgetTester tester) {
  // 本用例最后一次写入的完整可见正文。
  final ValueNotifier<String?> text = ValueNotifier(null);
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        text.value = (call.arguments as Map)['text'] as String?;
      }
      return null;
    },
  );
  addTearDown(() {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
    text.dispose();
  });
  return text;
}

/// 已有笔记菜单、完整编辑、版本及隔离归属回归。
void androidNoteActionTests() {
  testWidgets('Android已有笔记 菜单结构、复制正式可见全文、详情不切草稿', (tester) async {
    // 捕获真实复制入口交付的平台内容。
    final ValueNotifier<String?> clipboard = _androidClipboard(tester);
    // 读操作不能替换当前未发布内容。
    final _App app = await _mount(
      tester,
      seed: true,
      initialLocation: '/notes',
    );
    await tester.tap(find.byKey(const ValueKey('android-note-input')));
    await _settle(tester);
    await _enterBody(tester, '另一份草稿');
    await _closeAndroidComposer(tester);
    // 只读操作前固定当前编辑身份。
    final NoteEditorController editor = app.container.read(noteEditorProvider);
    // 正式格式文本与独立标签应分别处理。
    final NoteEntryRecord original = (await tester.runAsync<NoteEntryRecord?>(
      () => NoteRepository(app.database).find('target'),
    ))!;
    await tester.runAsync(
      () => NoteRepository(app.database).save(
        NoteDraft(
          id: original.id,
          body: '**完整加粗**\n<u>下划线</u>\n最后一行',
          dayKey: original.dayKey,
          baseRevision: original.revision,
          tags: {'work'},
        ),
      ),
    );
    await _settle(tester);
    // 本机草稿归属不会被复制和详情改变。
    final String? owner = editor.draftId;
    await _androidCardMenu(tester);
    for (final String label in ['编辑', '复制', '置顶', '查看详情', '历史版本', '删除']) {
      expect(find.text(label).hitTestable(), findsOneWidget);
    }
    for (final String label in ['分享', '加入浮窗', 'AI 洞察', '相关笔记', '复制链接', '批注']) {
      expect(find.text(label), findsNothing);
    }
    expect(find.textContaining('字数统计：'), findsOneWidget);
    expect(find.textContaining('创建时间：'), findsOneWidget);
    expect(find.textContaining('最后编辑：'), findsOneWidget);
    await tester.tap(find.text('复制'));
    await _settle(tester);
    expect(clipboard.value, '完整加粗\n下划线\n最后一行');
    expect(editor.draftId, owner);
    await _androidCardMenu(tester);
    await tester.tap(find.text('查看详情'));
    await _settle(tester);
    expect(find.text('笔记详情'), findsOneWidget);
    expect(find.text('标签：# 工作'), findsOneWidget);
    expect(find.text('图片：0 张'), findsOneWidget);
    expect(find.text('语音：1 段 · 00:18'), findsOneWidget);
    expect(editor.draftId, owner);
    expect(editor.draft.body, '另一份草稿');
    await tester.tap(find.byTooltip('关闭笔记详情'));
    await _settle(tester);
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android已有笔记 单击阅读、双击时间正文标签全屏、空保存不新增版本', (tester) async {
    // 时间、正文和标签分别拥有双击热区，媒体不在父级双击域。
    final _App app = await _mount(
      tester,
      seed: true,
      initialLocation: '/notes',
    );
    // 正式版本数量用于验证无修改保存不会写入新版本。
    final int versions = (await tester.runAsync(
      () => app.database.select(app.database.noteVersions).get(),
    ))!.length;
    await tester.tap(
      _androidCardPart('target', find.byType(NoteMarkdownText)).first,
    );
    await _settle(tester);
    expect(find.byType(NoteRichEditor), findsNothing);
    await tester.tap(
      _androidCardPart('target', find.widgetWithText(OmniButton, '展开')),
    );
    await _settle(tester);
    expect(find.byType(NoteRichEditor), findsNothing);
    expect(_androidCardPart('target', find.text('收起')), findsOneWidget);
    // 各种阅读内容均可双击，返回后仍保留展开状态。
    for (final Finder target in [
      _androidCardPart('target', find.byType(NoteMarkdownText)).first,
      _androidCardPart('target', find.byType(OmniTag)).first,
      _androidCardPart('target', find.byType(Text)).first,
    ]) {
      await _androidDoubleTap(tester, target);
      expect(
        find.byKey(const ValueKey('android-note-history-editor')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('android-note-editor')), findsNothing);
      expect(find.byTooltip('返回笔记列表'), findsOneWidget);
      expect(find.byKey(const ValueKey('android-note-publish')), findsNothing);
      expect(
        tester
            .widget<NoteRichEditor>(find.byType(NoteRichEditor))
            .focusNode
            .hasFocus,
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('android-note-history-back')));
      await _settle(tester);
      expect(find.byType(NoteRichEditor), findsNothing);
      expect(_androidCardPart('target', find.text('收起')), findsOneWidget);
    }
    expect(
      (await tester.runAsync(
        () => app.database.select(app.database.noteVersions).get(),
      ))!.length,
      versions,
    );
    // 上一轮聚焦正文可保留内部滚动位置，先确保外缘实际露出再测试背景命中。
    await tester.ensureVisible(
      find.byKey(const ValueKey('android-note-card-target')),
    );
    await _settle(tester);
    // 卡片外缘留白也能进入编辑，背景命中不包裹媒体手势。
    final Rect cardBounds = tester.getRect(
      find.byKey(const ValueKey('android-note-card-target')),
    );
    await tester.tapAt(Offset(cardBounds.left + 6, cardBounds.top + 6));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(Offset(cardBounds.left + 6, cardBounds.top + 6));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('android-note-history-editor')),
      findsOneWidget,
    );
    await _closeAndroidComposer(tester);
    // 音频更多连续点击响应自己，不触发笔记正文编辑。
    await tester.ensureVisible(
      find.byKey(const ValueKey('note-audio-expand-audio-target')),
    );
    await tester.pump();
    // 使用固定屏幕坐标，第二下不能改为点击动画后的另一控件。
    final Offset audioPoint = tester.getCenter(
      find.byKey(const ValueKey('note-audio-expand-audio-target')),
    );
    await tester.tapAt(audioPoint);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(audioPoint);
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('android-note-history-editor')),
      findsNothing,
    );
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  // 同一生产页面分别验证明暗主题，保留系统返回与真实事务。
  for (final String theme in ['light', 'dark']) {
    testWidgets('Android已有笔记 紧凑阴影顶栏、暂存后勾号和系统退出默认保存 $theme', (tester) async {
      // 生产全屏入口覆盖初始干净状态及真实键盘返回层级。
      final _App app = await _mount(
        tester,
        seed: true,
        theme: theme,
        initialLocation: '/notes?id=target',
      );
      // 两侧视觉圆40dp、点击热区48dp，图标20dp且阴影存在。
      for (final String id in ['back', 'more']) {
        // 完整触控区域。
        final Finder button = find.byKey(ValueKey('android-note-history-$id'));
        // 独立视觉圆形，不包含热区留白。
        final Finder visual = find.byKey(
          ValueKey('android-note-history-$id-visual'),
        );
        expect(tester.getSize(button), const Size(48, 48));
        expect(tester.getSize(visual), const Size(40, 40));
        // 实际绘制的背景与阴影。
        final BoxDecoration decoration =
            tester.widget<Container>(visual).decoration! as BoxDecoration;
        expect(decoration.boxShadow, isNotEmpty);
        expect(decoration.boxShadow!.first.blurRadius, greaterThan(0));
        expect(
          tester
              .widget<Icon>(
                find.descendant(of: button, matching: find.byType(Icon)),
              )
              .size,
          20,
        );
      }
      // 日期与标题仅保留2dp视觉间距，整组日期入口仍至少48dp。
      final Rect title = tester.getRect(
        find.byKey(const ValueKey('android-note-history-title')),
      );
      // 日期实际排版范围。
      final Rect date = tester.getRect(
        find.byKey(const ValueKey('android-note-history-date-label')),
      );
      expect(date.top - title.bottom, inInclusiveRange(0, 4));
      expect(
        tester
            .getSize(find.byKey(const ValueKey('android-note-record-time')))
            .height,
        greaterThanOrEqualTo(48),
      );
      expect(find.byTooltip('返回笔记列表'), findsOneWidget);
      expect(find.byKey(const ValueKey('android-note-publish')), findsNothing);
      await _capture(tester, app, 'history-header-$theme-clean');
      // 原始记录与版本数量用于验证仅真实修改才正式提交。
      final NoteEntryRecord before = (await tester.runAsync<NoteEntryRecord?>(
        () => NoteRepository(app.database).find('target'),
      ))!;
      // 编辑前的正式正文版本数量。
      final int versions = (await tester.runAsync(
        () => app.database.select(app.database.noteVersions).get(),
      ))!.length;
      await _enterBody(tester, '退出即保存的正文');
      await _settle(tester, elapsed: const Duration(milliseconds: 700));
      // 真实暂存状态，用于区分dirty与未提交修改。
      final NoteEditorController editor = app.container.read(
        noteEditorProvider,
      );
      expect(editor.dirty, isFalse);
      expect(editor.hasPendingChanges, isTrue);
      expect(find.byTooltip('保存'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('android-note-history-back')),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
      expect(
        (await tester.runAsync<NoteEntryRecord?>(
          () => NoteRepository(app.database).find('target'),
        ))!.body,
        before.body,
      );
      await _capture(tester, app, 'history-header-$theme-modified');
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      await tester.pump();
      if (theme == 'dark') {
        // 左上勾号即使键盘展开也一次保存并退出，不需要先手动收键盘。
        await tester.tap(find.byTooltip('保存'));
        await _settle(tester);
        tester.view.resetViewInsets();
      } else {
        // 第一次系统返回仅关闭键盘，此时还没有离开编辑页。
        await tester.binding.handlePopRoute();
        await _settle(tester);
        expect(
          find.byKey(const ValueKey('android-note-history-editor')),
          findsOneWidget,
        );
        expect(
          (await tester.runAsync<NoteEntryRecord?>(
            () => NoteRepository(app.database).find('target'),
          ))!.body,
          before.body,
        );
        tester.view.resetViewInsets();
        await _settle(tester);
        await tester.binding.handlePopRoute();
        await _settle(tester);
      }
      expect(find.byType(NoteRichEditor), findsNothing);
      expect(
        (await tester.runAsync<NoteEntryRecord?>(
          () => NoteRepository(app.database).find('target'),
        ))!.body,
        '退出即保存的正文',
      );
      expect(
        (await tester.runAsync(
          () => app.database.select(app.database.noteVersions).get(),
        ))!.length,
        versions + 1,
      );
      await _dispose(tester, app);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Android已有笔记 清空纯文字后退出保存空正文而不删除原篇', (tester) async {
    // 没有媒体的已有笔记仍允许清空，不依赖旧底部按钮的content门禁。
    final _App app = await _mount(
      tester,
      seed: true,
      initialLocation: '/notes?id=weekly-note',
    );
    await _enterBody(tester, '');
    await tester.tap(find.byTooltip('保存'));
    await _settle(tester);
    // 清空是编辑，不是回收站删除，也不会产生第二篇笔记。
    final NoteEntryRecord? saved = await tester.runAsync<NoteEntryRecord?>(
      () => NoteRepository(app.database).find('weekly-note'),
    );
    expect(saved, isNotNull);
    expect(saved!.body, isEmpty);
    expect(saved.deletedAt, isNull);
    expect(find.byType(NoteRichEditor), findsNothing);
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android已有笔记 退出遇到正文冲突保留本页修改和远端正文', (tester) async {
    // 本机已有未提交修改时模拟另一设备保存更新版本。
    final _App app = await _mount(
      tester,
      seed: true,
      initialLocation: '/notes?id=target',
    );
    // 使用真实仓储模拟其他设备的落库结果。
    final NoteRepository repository = NoteRepository(app.database);
    // 编辑前的正式版本与时间事实。
    final NoteEntryRecord before = (await tester.runAsync<NoteEntryRecord?>(
      () => repository.find('target'),
    ))!;
    await _enterBody(tester, '本机未提交的正文');
    await tester.runAsync(
      () => repository.save(
        NoteDraft(
          id: before.id,
          body: '另一端保存的正文',
          dayKey: before.dayKey,
          baseRevision: before.revision,
          tags: noteTagIds(before.tags),
          originalTags: noteTagIds(before.tags),
          createdAt: before.createdAt,
          creationTimezone: before.creationTimezone,
        ),
      ),
    );
    await _settle(tester);
    await tester.binding.handlePopRoute();
    await _settle(tester);
    // 冲突不能伪装保存成功并关闭，也不能覆盖另一端的正式版本。
    expect(
      find.byKey(const ValueKey('android-note-history-editor')),
      findsOneWidget,
    );
    expect(_bodyText(tester), '本机未提交的正文');
    expect(app.container.read(noteEditorProvider).conflicted, isTrue);
    expect(
      (await tester.runAsync<NoteEntryRecord?>(
        () => repository.find('target'),
      ))!.body,
      '另一端保存的正文',
    );
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android已有笔记 全屏返回默认保存、保存失败重试、复制当前稿', (tester) async {
    // 当前草稿复制通过同一平台入口验证。
    final ValueNotifier<String?> clipboard = _androidClipboard(tester);
    // 外部定位必须进入全屏，同一草稿重开不能丢失修改。
    final _App app = await _mount(
      tester,
      seed: true,
      initialLocation: '/notes?id=target',
    );
    // 创建时间不能被编辑或归档日替换。
    final NoteEntryRecord original = (await tester.runAsync<NoteEntryRecord?>(
      () => NoteRepository(app.database).find('target'),
    ))!;
    await _enterBody(tester, '未保存的全屏正文');
    await tester.tap(find.byTooltip('编辑笔记操作'));
    await _settle(tester);
    await tester.tap(find.text('复制全文'));
    await _settle(tester);
    expect(clipboard.value, '未保存的全屏正文');
    await _closeAndroidComposer(tester);
    expect(
      (await tester.runAsync(
        () => NoteRepository(app.database).find('target'),
      ))!.body,
      '未保存的全屏正文',
    );
    await _androidCardMenu(tester);
    await tester.tap(find.text('编辑'));
    await _settle(tester);
    expect(_bodyText(tester), '未保存的全屏正文');
    await _enterBody(tester, '失败后重试保存的正文');
    await tester.runAsync(
      () => app.database.customStatement(
        "CREATE TRIGGER fail_history_save BEFORE UPDATE ON note_entries BEGIN SELECT RAISE(FAIL, '模拟保存失败'); END",
      ),
    );
    // 系统返回也走正式提交，失败必须停留当前页。
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('android-note-history-editor')),
      findsOneWidget,
    );
    expect(_bodyText(tester), '失败后重试保存的正文');
    await tester.runAsync(
      () => app.database.customStatement('DROP TRIGGER fail_history_save'),
    );
    await tester.tap(find.byTooltip('保存'));
    await _settle(tester);
    expect(find.byType(NoteRichEditor), findsNothing);
    // 保存只改变正文及修改时间，不改变创建事实。
    final NoteEntryRecord saved = (await tester.runAsync<NoteEntryRecord?>(
      () => NoteRepository(app.database).find('target'),
    ))!;
    expect(saved.body, '失败后重试保存的正文');
    expect(saved.createdAt, original.createdAt);
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android已有笔记 版本取消不换草稿、恢复只改正文且等待保存', (tester) async {
    // 修改正式篇生成真实版本，不手工伪造版本模型。
    final _App app = await _mount(
      tester,
      seed: true,
      initialLocation: '/notes',
    );
    // 上一版本的完整正文需可读，并保留原篇标签与原音。
    final NoteEntryRecord original = (await tester.runAsync<NoteEntryRecord?>(
      () => NoteRepository(app.database).find('target'),
    ))!;
    await tester.runAsync(
      () => NoteRepository(app.database).save(
        NoteDraft(
          id: 'target',
          body: '正式新版本正文',
          dayKey: original.dayKey,
          baseRevision: original.revision,
          tags: {'work', 'review'},
        ),
      ),
    );
    await _settle(tester);
    // 只读版本列表不会先抢占当前草稿。
    final String? owner = app.container.read(noteEditorProvider).draftId;
    await _androidCardMenu(tester);
    await tester.tap(find.text('历史版本'));
    await _settle(tester);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is NoteMarkdownText && widget.source == original.body,
      ),
      findsOneWidget,
    );
    expect(app.container.read(noteEditorProvider).draftId, owner);
    await tester.tap(find.byTooltip('关闭历史版本'));
    await _settle(tester);
    expect(app.container.read(noteEditorProvider).draftId, owner);
    await _androidCardMenu(tester);
    await tester.tap(find.text('历史版本'));
    await _settle(tester);
    await tester.ensureVisible(find.text('恢复此版本').last);
    await tester.tap(find.text('恢复此版本').last);
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('android-note-history-editor')),
      findsOneWidget,
    );
    expect(_bodyText(tester), original.body);
    expect(app.container.read(noteEditorProvider).draft.tags, {
      'work',
      'review',
    });
    expect(
      (await tester.runAsync(
        () => NoteRepository(app.database).find('target'),
      ))!.body,
      '正式新版本正文',
    );
    expect(
      (await tester.runAsync(
        () => app.database.select(app.database.noteAudioSegments).get(),
      ))!.length,
      1,
    );
    await tester.tap(find.byTooltip('保存'));
    await _settle(tester);
    expect(
      (await tester.runAsync(
        () => NoteRepository(app.database).find('target'),
      ))!.body,
      original.body,
    );
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android已有笔记 删除取消失败保留页面、成功冻结原稿不删其他笔记', (tester) async {
    // 删除事务通过真实SQLite触发器模拟失败。
    final _App app = await _mount(
      tester,
      seed: true,
      initialLocation: '/notes?id=target',
    );
    await _enterBody(tester, '删除前未发布修改');
    await tester.tap(find.byTooltip('编辑笔记操作'));
    await _settle(tester);
    await tester.tap(find.text('删除'));
    await _settle(tester);
    await tester.tap(find.widgetWithText(OmniButton, '取消'));
    await _settle(tester);
    expect(_bodyText(tester), '删除前未发布修改');
    await tester.runAsync(
      () => app.database.customStatement(
        "CREATE TRIGGER fail_history_delete BEFORE UPDATE ON note_entries BEGIN SELECT RAISE(FAIL, '模拟删除失败'); END",
      ),
    );
    await tester.tap(find.byTooltip('编辑笔记操作'));
    await _settle(tester);
    await tester.tap(find.text('删除'));
    await _settle(tester);
    await tester.tap(find.widgetWithText(OmniButton, '移入回收站'));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('android-note-history-editor')),
      findsOneWidget,
    );
    await tester.runAsync(
      () => app.database.customStatement('DROP TRIGGER fail_history_delete'),
    );
    await tester.tap(find.byTooltip('编辑笔记操作'));
    await _settle(tester);
    await tester.tap(find.text('删除'));
    await _settle(tester);
    await tester.tap(find.widgetWithText(OmniButton, '移入回收站'));
    await _settle(tester);
    expect(find.byType(NoteRichEditor), findsNothing);
    expect(
      (await tester.runAsync(
        () => NoteRepository(app.database).find('target'),
      ))!.deletedAt,
      isNotNull,
    );
    expect(
      (await tester.runAsync(
        () => NoteRepository(app.database).find('yesterday'),
      ))!.deletedAt,
      isNull,
    );
    // 冻结草稿保留修改，不对其他草稿做取消。
    final List<NoteLocalDraftRecord> drafts = (await tester.runAsync(
      app.container.read(noteEditorProvider).listLocalDrafts,
    ))!;
    expect(
      drafts.any((item) => item.noteId == 'target' && item.body == '删除前未发布修改'),
      isTrue,
    );
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android已有笔记 搜索编辑不重交查询、返回保留展开及滚动位置', (tester) async {
    // 正式列表足够长，可观察打开编辑前后的滚动。
    final _App app = await _mount(
      tester,
      seed: true,
      initialLocation: '/notes',
    );
    await tester.tap(find.byKey(const ValueKey('android-notes-search')));
    await _settle(tester);
    await tester.enterText(_androidSearchInput(), '日报');
    await _settle(tester);
    await tester.tap(
      _androidCardPart('target', find.widgetWithText(OmniButton, '展开')),
    );
    await _settle(tester);
    // 搜索结果列表控制器由生产搜索页持有。
    final ScrollController scroll = tester
        .widget<ListView>(find.byKey(const ValueKey('android-notes-list')).last)
        .controller!;
    scroll.jumpTo(30.clamp(0, scroll.position.maxScrollExtent).toDouble());
    await tester.pump();
    // 原偏移保留到全屏返回。
    final double offset = scroll.offset;
    await _androidDoubleTap(
      tester,
      _androidCardPart('target', find.byType(NoteMarkdownText)).first,
    );
    expect(app.container.read(noteSearchHistoryProvider), ['日报']);
    await _closeAndroidComposer(tester);
    expect(
      tester.widget<TextField>(_androidSearchInput()).controller!.text,
      '日报',
    );
    expect(_androidCardPart('target', find.text('收起')), findsOneWidget);
    expect(scroll.offset, offset);
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android已有笔记 暂存失败不退出、不切换菜单目标，重试后恢复', (tester) async {
    // 暂存门禁必须在返回和切篇两条路径都生效。
    final _App app = await _mount(
      tester,
      seed: true,
      initialLocation: '/notes?id=target',
    );
    await tester.runAsync(
      () => app.database.customStatement(
        "CREATE TRIGGER fail_history_draft BEFORE INSERT ON note_local_drafts BEGIN SELECT RAISE(FAIL, '模拟草稿写入失败'); END",
      ),
    );
    await _enterBody(tester, '失败时仍留在本篇');
    await _closeAndroidComposer(tester);
    expect(
      find.byKey(const ValueKey('android-note-history-editor')),
      findsOneWidget,
    );
    expect(_bodyText(tester), '失败时仍留在本篇');
    expect(app.container.read(noteEditorProvider).dirty, isTrue);
    await tester.runAsync(
      () => app.database.customStatement('DROP TRIGGER fail_history_draft'),
    );
    await _closeAndroidComposer(tester);
    expect(find.byType(NoteRichEditor), findsNothing);
    await _androidDoubleTap(
      tester,
      _androidCardPart('target', find.byType(NoteMarkdownText)).first,
    );
    expect(_bodyText(tester), '失败时仍留在本篇');
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android已有笔记 远端删除后菜单停止，编辑会话替换关闭所有本页覆盖', (tester) async {
    // 菜单打开时的正文快照不能绕过后续身份核验。
    final _App app = await _mount(
      tester,
      seed: true,
      initialLocation: '/notes',
    );
    await _androidCardMenu(tester);
    await tester.runAsync(
      () => NoteRepository(app.database).softDelete('target'),
    );
    await _settle(tester);
    await tester.tap(find.text('编辑'));
    await _settle(tester);
    expect(find.byType(NoteRichEditor), findsNothing);
    await _androidDoubleTap(
      tester,
      _androidCardPart('weekly-note', find.byType(NoteMarkdownText)).first,
    );
    await tester.tap(find.byTooltip('编辑笔记操作'));
    await _settle(tester);
    app.container.invalidate(noteEditorProvider);
    await _settle(tester);
    expect(find.text('复制全文'), findsNothing);
    expect(
      find.byKey(const ValueKey('android-note-history-editor')),
      findsNothing,
    );
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android已有笔记 另一篇录音不被接管、返回原录音先退出历史页', (tester) async {
    // 原音在A草稿采集，B页只能操作自己的正文。
    final _App app = await _mount(
      tester,
      seed: true,
      allowRecording: true,
      initialLocation: '/notes',
    );
    // 固定应用级同一控制器与原录音代次。
    final NoteEditorController editor = app.container.read(noteEditorProvider);
    await tester.runAsync(() async {
      await editor.open('yesterday');
      await editor.startRecording();
    });
    await _settle(tester);
    // 活动录音身份不能随B页的菜单而改变。
    final String? recordingOwner = app.recorder.state.draftId;
    await _androidDoubleTap(
      tester,
      _androidCardPart('target', find.byType(NoteMarkdownText)).first,
    );
    await _androidComposerOptions(tester);
    await tester.tap(find.widgetWithText(OmniButton, '开始录音'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('android-recording-card')), findsNothing);
    expect(editor.draft.id, 'target');
    expect(app.recorder.starts, 1);
    expect(app.recorder.state.draftId, recordingOwner);
    await _enterBody(tester, '返回另一篇录音时保存本篇修改');
    await _androidComposerOptions(tester);
    await tester.ensureVisible(find.widgetWithText(OmniButton, '返回正在录音的笔记'));
    await tester.pump();
    await tester.tap(find.widgetWithText(OmniButton, '返回正在录音的笔记'));
    await _settle(tester);
    expect(
      (await tester.runAsync<NoteEntryRecord?>(
        () => NoteRepository(app.database).find('target'),
      ))!.body,
      '返回另一篇录音时保存本篇修改',
    );
    expect(editor.draft.id, 'yesterday');
    expect(editor.draftId, recordingOwner);
    expect(
      find.byKey(const ValueKey('android-recording-card')),
      findsOneWidget,
    );
    expect(app.recorder.starts, 1);
    await _stopAndroidRecording(tester);
    await tester.tap(find.byTooltip('确认录音'));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('android-note-history-editor')),
      findsOneWidget,
    );
    expect(
      (await tester.runAsync(
        () => NoteRepository(app.database).find('yesterday'),
      ))!.body,
      '昨日日报',
    );
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android已有笔记 全屏图片录音与归档日期保存，媒体双击不进入编辑', (tester) async {
    // 图片复制仅使用用例私有目录，原音继续使用真实临时WAV。
    final Directory directory = Directory.systemTemp.createTempSync(
      'android-history-media-',
    );
    // 已知像素便于判断生产缩略图是否实际解码。
    final File source = File('${directory.path}/image.png')
      ..writeAsBytesSync(
        img.encodePng(
          img.fill(
            img.Image(width: 64, height: 48),
            color: img.ColorRgb8(130, 175, 220),
          ),
        ),
      );
    addTearDown(
      () async => tester.runAsync(() => directory.delete(recursive: true)),
    );
    // 相机相册边界替换，附件仓储和正式提交不替换。
    final _App app = await _mount(
      tester,
      seed: true,
      allowRecording: true,
      initialLocation: '/notes?id=target',
      imageDirectory: () async => directory,
      systemImagePicker: _ComposerImagePicker([source]),
      prepareDatabase: (database) => NoteRepository(database).updateRecordTime(
        'target',
        const NoteRecordTime('2024-03-29', 45296, 480),
      ),
    );
    // 修改归档日不能改原始创建时间。
    final NoteEditorController editor = app.container.read(noteEditorProvider);
    // 持久创建时间独立于归档日期。
    final DateTime created = editor.draft.createdAt!;
    await tester.tap(find.byKey(const ValueKey('android-note-record-time')));
    await _settle(tester);
    expect(find.text('设定日期'), findsOneWidget);
    expect(find.byType(ListWheelScrollView), findsNWidgets(6));
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(find.text('设定日期'), findsNothing);
    expect(editor.draft.recordTime.label, '2024-03-29 12:34:56');
    expect(
      find.byKey(const ValueKey('android-note-history-editor')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('android-note-record-time')));
    await _settle(tester);
    // 操作真实滚动控制器驱动吸附及生产选中通知，不直接调用日期回调。
    for (final (int, int) selection in [(1, 1), (3, 8), (4, 9), (5, 10)]) {
      // 当前列仍使用生产ListWheelScrollView及其状态。
      final ListWheelScrollView wheel = tester.widget(
        find.byKey(ValueKey('note-record-time-wheel-${selection.$1}')),
      );
      (wheel.controller! as FixedExtentScrollController).jumpToItem(
        selection.$2,
      );
      await tester.pumpAndSettle();
    }
    expect(find.text('2024年02月29日 星期四'), findsOneWidget);
    await _capture(tester, app, 'android-record-time-picker');
    await tester.tap(find.byKey(const ValueKey('note-record-time-confirm')));
    await _settle(tester);
    expect(editor.draft.recordTime.label, '2024-02-29 08:09:10');
    expect(editor.draft.dateEdited, isTrue);
    // 面板确定只改变编辑草稿，点击页面保存以前正式时间保持原值。
    expect(
      (await tester.runAsync(
        () => NoteRepository(app.database).find('target'),
      ))!.recordTime.label,
      '2024-03-29 12:34:56',
    );
    await tester.tap(find.byTooltip('添加图片'));
    for (int attempt = 0; attempt < 100 && !editor.hasImages; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await _settle(tester);
    expect(editor.hasImages, isTrue);
    // 真图解码后再保存视觉证据。
    final Finder thumbnail = find.descendant(
      of: find.byKey(const ValueKey('android-note-history-editor')),
      matching: find.byType(Image),
    );
    await tester.runAsync(
      () => precacheImage(
        tester.widget<Image>(thumbnail).image,
        tester.element(thumbnail),
      ).timeout(const Duration(seconds: 10)),
    );
    await tester.pump();
    await _capture(tester, app, 'existing-media-editor');
    await _androidComposerOptions(tester);
    await tester.ensureVisible(find.widgetWithText(OmniButton, '开始录音'));
    await tester.pump();
    await tester.tap(find.widgetWithText(OmniButton, '开始录音'));
    await _settle(tester);
    expect(app.recorder.state.noteId, 'target');
    await _capture(tester, app, 'existing-media-recording');
    await tester.tap(find.byTooltip('暂停录音'));
    await _settle(tester);
    await _capture(tester, app, 'existing-media-paused');
    await _stopAndroidRecording(tester);
    await _capture(tester, app, 'existing-media-review');
    await tester.tap(find.byTooltip('确认录音'));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('android-note-history-editor')),
      findsOneWidget,
    );
    expect(
      (await tester.runAsync(
        () => app.database.select(app.database.noteAudioSegments).get(),
      ))!.length,
      1,
    );
    await tester.tap(find.byTooltip('保存'));
    await _waitAndroidCommit(tester, app);
    expect(find.byType(NoteRichEditor), findsNothing);
    expect(
      (await tester.runAsync(
        () => NoteRepository(app.database).find('target'),
      ))!.dayKey,
      '2024-02-29',
    );
    expect(
      (await tester.runAsync(
        () => NoteRepository(app.database).find('target'),
      ))!.recordTime.clockLabel,
      '08:09:10',
    );
    expect(
      (await tester.runAsync(
        () => NoteRepository(app.database).find('target'),
      ))!.createdAt,
      created,
    );
    expect(
      (await tester.runAsync(
        () => app.database.select(app.database.noteImages).get(),
      ))!.length,
      1,
    );
    expect(
      (await tester.runAsync(
        () => app.database.select(app.database.noteAudioSegments).get(),
      ))!.length,
      2,
    );
    // 滚动找到因改归档日而移动的目标篇，双击图片只执行预览。
    await _androidCardMenu(tester);
    await tester.binding.handlePopRoute();
    await _settle(tester);
    await tester.scrollUntilVisible(
      _androidCardPart('target', find.byType(Image)),
      100,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('android-notes-list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.ensureVisible(_androidCardPart('target', find.byType(Image)));
    await tester.pump();
    // 图片第一下就打开预览，第二下继续投递同一坐标给预览自己的手势。
    final Offset imagePoint = tester.getCenter(
      _androidCardPart('target', find.byType(Image)),
    );
    await tester.tapAt(imagePoint);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(imagePoint);
    await _settle(tester);
    expect(find.text('查看图片'), findsOneWidget);
    expect(find.byType(NoteRichEditor), findsNothing);
    await tester.binding.handlePopRoute();
    await _settle(tester);
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android已有笔记 卡片删除不停止其他篇录音和草稿', (tester) async {
    // 非当前篇删除只冻结目标篇，不取消另一个录音代次。
    final _App app = await _mount(
      tester,
      seed: true,
      allowRecording: true,
      initialLocation: '/notes',
    );
    // 原录音会话始终保持归属。
    final NoteEditorController editor = app.container.read(noteEditorProvider);
    await tester.runAsync(() async {
      await editor.open('yesterday');
      await editor.startRecording();
    });
    await _settle(tester);
    // 删前的原音身份必须保持不变。
    final String? owner = app.recorder.state.draftId;
    await _androidCardMenu(tester);
    await tester.tap(find.text('删除'));
    await _settle(tester);
    await tester.tap(find.widgetWithText(OmniButton, '移入回收站'));
    await _settle(tester);
    expect(app.recorder.state.isActive, isTrue);
    expect(app.recorder.state.draftId, owner);
    expect(editor.draft.id, 'yesterday');
    expect(
      (await tester.runAsync(
        () => NoteRepository(app.database).find('target'),
      ))!.deletedAt,
      isNotNull,
    );
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  // 实际全屏组件逐页及过渡帧，兼顾窄屏、键盘、深色与减少动画。
  for (final (String, Size, double, String, bool) viewport in [
    ('phone', const Size(390, 844), 1.0, 'light', false),
    ('narrow', const Size(320, 640), 1.6, 'dark', false),
    ('short', const Size(390, 360), 1.6, 'light', false),
    ('landscape', const Size(760, 390), 1.0, 'dark', false),
    ('tablet', const Size(1024, 768), 1.0, 'light', false),
    ('reduced', const Size(390, 844), 1.0, 'light', true),
  ]) {
    testWidgets('Android已有笔记 生产预览 ${viewport.$1}', (tester) async {
      // 新页面挂载在标准路由下，避免预载首页的既有窄屏布局。
      final _App app = await _mount(
        tester,
        seed: true,
        theme: viewport.$4,
        initialLocation: '/notes',
      );
      tester.view.physicalSize = viewport.$2;
      tester.platformDispatcher.textScaleFactorTestValue = viewport.$3;
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          FakeAccessibilityFeatures(disableAnimations: viewport.$5);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await _settle(tester);
      await _androidCardMenu(tester);
      await _capture(tester, app, 'existing-${viewport.$1}-menu');
      // 短屏菜单可滚动，底部统计仍可读。
      await tester.ensureVisible(find.textContaining('最后编辑：'));
      await _capture(tester, app, 'existing-${viewport.$1}-menu-footer');
      await tester.binding.handlePopRoute();
      await _settle(tester);
      await _androidCardMenu(tester);
      await tester.tap(find.text('查看详情'));
      await _settle(tester);
      await _capture(tester, app, 'existing-${viewport.$1}-details');
      await tester.tap(find.byTooltip('关闭笔记详情'));
      await _settle(tester);
      await _androidCardMenu(tester);
      await tester.tap(find.text('编辑'));
      for (
        int attempt = 0;
        attempt < 50 &&
            find
                .byKey(const ValueKey('android-note-history-editor'))
                .evaluate()
                .isEmpty;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      // 真实历史编辑的横坐标固定，纵坐标从视口底部连续进入。
      final Finder historySurface = find.byKey(
        const ValueKey('android-note-history-editor'),
      );
      // 生产路由使用统一时长，减少动画时两端均归零。
      final ModalRoute<Object?> historyRoute = ModalRoute.of(
        tester.element(historySurface),
      )!;
      expect(
        historyRoute.transitionDuration,
        viewport.$5 ? Duration.zero : OmniMotion.androidModalEnter,
      );
      expect(
        historyRoute.reverseTransitionDuration,
        viewport.$5 ? Duration.zero : OmniMotion.androidModalExit,
      );
      // 连续帧保存前一位置，捕捉错误的横向进入或直接跳到终点。
      double previousTop = tester.getTopLeft(historySurface).dy;
      for (final int frame in [100, 200, 300]) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.getTopLeft(historySurface).dx, closeTo(0, .01));
        if (!viewport.$5) {
          expect(tester.getTopLeft(historySurface).dy, lessThan(previousTop));
        }
        previousTop = tester.getTopLeft(historySurface).dy;
        await _capture(tester, app, 'existing-${viewport.$1}-enter-${frame}ms');
      }
      await _settle(tester);
      await _capture(tester, app, 'existing-${viewport.$1}-editor');
      tester.view.viewInsets = FakeViewPadding(
        bottom: viewport.$2.height > 500 ? 260 : 150,
      );
      await _settle(tester);
      await tester.tap(find.byTooltip('更多笔记工具'));
      await _settle(tester);
      await _capture(tester, app, 'existing-${viewport.$1}-keyboard-tools');
      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('android-note-history-editor')),
        findsOneWidget,
      );
      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('android-note-history-editor')),
        findsOneWidget,
      );
      tester.view.resetViewInsets();
      await _settle(tester);
      await tester.tap(find.byTooltip('编辑笔记操作'));
      await _settle(tester);
      await _capture(tester, app, 'existing-${viewport.$1}-editor-menu');
      await tester.binding.handlePopRoute();
      await _settle(tester);
      if (viewport.$5) {
        await _closeAndroidComposer(tester);
      } else {
        await tester.tap(find.byTooltip('返回笔记列表'));
        // 暂存可能需要真实文件I/O；不推进动画时钟，等待业务允许返回。
        for (
          int attempt = 0;
          attempt < 50 &&
              historyRoute.animation!.status != AnimationStatus.reverse;
          attempt++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(historyRoute.animation!.status, AnimationStatus.reverse);
        // 先建立退出动画的首帧时基，再按固定间隔检查位移。
        await tester.pump();
        previousTop = tester.getTopLeft(historySurface).dy;
        for (final int frame in [60, 120, 180]) {
          await tester.pump(const Duration(milliseconds: 60));
          expect(historySurface, findsOneWidget);
          expect(tester.getTopLeft(historySurface).dx, closeTo(0, .01));
          expect(
            tester.getTopLeft(historySurface).dy,
            greaterThan(previousTop),
          );
          previousTop = tester.getTopLeft(historySurface).dy;
          await _capture(
            tester,
            app,
            'existing-${viewport.$1}-exit-${frame}ms',
          );
        }
        await _settle(tester);
      }
      expect(find.byType(NoteRichEditor), findsNothing);
      expect(tester.takeException(), isNull);
      await _dispose(tester, app);
    });
  }
}
