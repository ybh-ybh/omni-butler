part of 'notes_page_test.dart';

/// Android 页面使用真实根路由、数据库及可验证的设备替身。
void androidNoteTests() {
  testWidgets('Android减少动画与键盘返回保留编辑草稿', (tester) async {
    // 系统减少动画不改变保存、返回和录音的业务行为。
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    // 冷启动直接进入笔记，避免无关首页的历史零时长动画问题。
    final _App app = await _mount(tester, initialLocation: '/notes');
    await tester.tap(find.byKey(const ValueKey('android-notes-search')));
    await _settle(tester);
    expect(find.text('快捷搜索'), findsOneWidget);
    await tester.tap(find.widgetWithText(OmniButton, '取消'));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('android-note-input')));
    await _settle(tester);
    await _enterBody(tester, '减少动画下保留草稿');
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    await _settle(tester);
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(find.byType(NoteRichEditor), findsOneWidget);
    expect(_bodyHasFocus(tester), isFalse);
    tester.view.resetViewInsets();
    await _settle(tester);
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(find.byType(NoteRichEditor), findsNothing);
    expect(
      (await tester.runAsync(
        app.container.read(noteEditorProvider).listLocalDrafts,
      ))!.single.body,
      '减少动画下保留草稿',
    );
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Android统计窄屏大字号选日返回列表且保留草稿', (tester) async {
    // 统计使用正式数据，未发布正文不能计入数量。
    final _App app = await _mount(
      tester,
      seed: true,
      initialLocation: '/notes',
    );
    await tester.tap(find.byKey(const ValueKey('android-note-input')));
    await _settle(tester);
    await _enterBody(tester, '统计操作不丢草稿');
    await _closeAndroidComposer(tester);
    await _settle(tester);
    tester.view.physicalSize = const Size(320, 640);
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('android-notes-menu')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('android-note-stat-笔记')));
    await _settle(tester);
    await _capture(tester, app, 'android-narrow-statistics');
    expect(
      find.byKey(const ValueKey('notes-statistics-dialog')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    // 实际点击有效日期，统计和抽屉应一起退出并筛选主列表。
    final Finder today = find.byKey(
      ValueKey('notes-statistics-day-${businessDayKey(DateTime.now())}'),
    );
    await tester.ensureVisible(today);
    // 窄屏月份滚动后先完成布局，避免按滚动前的日期坐标点击。
    await _settle(tester);
    await tester.tap(today);
    await _settle(tester);
    expect(find.byKey(const ValueKey('notes-statistics-dialog')), findsNothing);
    expect(find.byKey(const ValueKey('android-notes-sidebar')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('android-note-input')));
    await _settle(tester);
    expect(_bodyText(tester), '统计操作不丢草稿');
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Android暂存失败拒绝关闭、提交失败保留草稿并可重试', (tester) async {
    // SQLite 真实失败覆盖业务门禁，不通过替换控制器伪造结果。
    final _App app = await _mount(tester, initialLocation: '/notes');
    await tester.tap(find.byKey(const ValueKey('android-note-input')));
    await _settle(tester);
    await tester.runAsync(
      () => app.database.customStatement(
        "CREATE TRIGGER fail_android_draft BEFORE INSERT ON note_local_drafts BEGIN SELECT RAISE(ABORT, 'draft failure'); END",
      ),
    );
    await _enterBody(tester, '失败仍保留的正文');
    await _settle(tester, elapsed: const Duration(milliseconds: 700));
    await _closeAndroidComposer(tester);
    await _settle(tester);
    expect(find.byType(NoteRichEditor), findsOneWidget);
    expect(_bodyText(tester), '失败仍保留的正文');
    await tester.runAsync(
      () => app.database.customStatement('DROP TRIGGER fail_android_draft'),
    );
    await _closeAndroidComposer(tester);
    await _settle(tester);
    expect(find.byType(NoteRichEditor), findsNothing);
    await tester.tap(find.byKey(const ValueKey('android-note-input')));
    await _settle(tester);
    await tester.runAsync(
      () => app.database.customStatement(
        "CREATE TRIGGER fail_android_publish BEFORE INSERT ON note_entries BEGIN SELECT RAISE(ABORT, 'publish failure'); END",
      ),
    );
    await tester.tap(find.byKey(const ValueKey('android-note-publish')));
    await _settle(tester);
    expect(find.byType(NoteRichEditor), findsOneWidget);
    expect(_bodyText(tester), '失败仍保留的正文');
    expect(
      (await tester.runAsync(
        app.container.read(noteEditorProvider).listLocalDrafts,
      ))!.length,
      1,
    );
    await tester.runAsync(
      () => app.database.customStatement('DROP TRIGGER fail_android_publish'),
    );
    await tester.tap(find.byKey(const ValueKey('android-note-publish')));
    await _settle(tester);
    expect(find.byType(NoteRichEditor), findsNothing);
    expect(
      (await tester.runAsync(
        () => app.database.select(app.database.noteEntries).get(),
      ))!.single.body,
      '失败仍保留的正文',
    );
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android纯图片暂存发布、卡片预览和图片搜索', (tester) async {
    // 原件和私有副本均位于测试临时目录，不访问用户附件。
    final Directory directory = Directory.systemTemp.createTempSync(
      'android-note-image-',
    );
    // 仅在测试临时目录创建的真实图片原件。
    final File source = File('${directory.path}/image.png')
      ..writeAsBytesSync(
        img.encodePng(
          img.fill(
            img.Image(width: 12, height: 12),
            color: img.ColorRgb8(120, 180, 220),
          ),
        ),
      );
    // 测试结束后恢复的原有全局边界。
    final FilePickerPlatform previous = FilePickerPlatform.instance;
    // 可观察的系统图片选择替身。
    final _ComposerImagePicker picker = _ComposerImagePicker([source]);
    addTearDown(() async {
      FilePickerPlatform.instance = previous;
      await tester.runAsync(() => directory.delete(recursive: true));
    });
    // 当前测试拥有的完整生产路由和依赖。
    final _App app = await _mount(
      tester,
      initialLocation: '/notes',
      imageDirectory: () async => directory,
      systemImagePicker: picker,
    );
    await tester.tap(find.byTooltip('添加图片或录音'));
    await _settle(tester);
    await tester.tap(find.text('选择图片'));
    // 图片格式校验与复制需要真实 I/O，交替刷新事件和画面。
    for (int attempt = 0; attempt < 100; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      if (app.container.read(noteEditorProvider).hasImages &&
          !app.container.read(noteEditorProvider).imageAdding) {
        break;
      }
    }
    await _settle(tester);
    expect(picker.calls, 1);
    expect(app.container.read(noteEditorProvider).hasImages, isTrue);
    // 等待真实图片解码，不能把空白占位当成完成的附件视觉证据。
    final Finder thumbnail = find.descendant(
      of: find.byKey(const ValueKey('android-note-editor')),
      matching: find.byType(Image),
    );
    await tester.runAsync(
      () => precacheImage(
        tester.widget<Image>(thumbnail).image,
        tester.element(thumbnail),
      ),
    );
    await tester.pump();
    // 系统导入后缩略图中心必须在紧凑面板首屏中，不能只剩可用的发送按钮。
    expect(
      tester
          .getRect(find.byKey(const ValueKey('android-composer-body')))
          .contains(tester.getRect(thumbnail).center),
      isTrue,
    );
    await _capture(tester, app, 'composer-phone-image-import');
    expect(
      await tester.runAsync(
        () => app.database.select(app.database.noteEntries).get(),
      ),
      isEmpty,
    );
    await tester.tap(find.byKey(const ValueKey('android-note-publish')));
    for (
      // 真实文件操作的有界等待次数。
      int attempt = 0;
      attempt < 100 && find.byType(NoteRichEditor).evaluate().isNotEmpty;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await _settle(tester);
    expect(find.byType(NoteRichEditor), findsNothing);
    expect(
      (await tester.runAsync(
        () => app.database.select(app.database.noteImages).get(),
      ))!.length,
      1,
    );
    await tester.tap(find.byType(Image).hitTestable().first);
    await _settle(tester);
    expect(find.text('查看图片'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('android-notes-search')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('android-quick-image')));
    await _settle(tester);
    expect(find.text('图片笔记', findRichText: true), findsOneWidget);
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Android遮罩、返回和下滑关闭均保留草稿，明确放弃才删除', (tester) async {
    // 根覆盖层的三个关闭入口必须经过同一暂存流程。
    final _App app = await _mount(tester, initialLocation: '/notes');
    await tester.tap(find.byKey(const ValueKey('android-note-input')));
    await _settle(tester);
    await _enterBody(tester, '关闭仍应保留');
    await tester.tapAt(const Offset(10, 10));
    await _settle(tester);
    expect(find.byType(NoteRichEditor), findsNothing);
    await tester.tap(find.byKey(const ValueKey('android-note-input')));
    await _settle(tester);
    expect(_bodyText(tester), '关闭仍应保留');
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(find.byType(NoteRichEditor), findsNothing);
    await tester.tap(find.byKey(const ValueKey('android-note-input')));
    await _settle(tester);
    await tester.drag(
      find.byKey(const ValueKey('android-composer-handle')),
      const Offset(0, 110),
    );
    await _settle(tester);
    expect(find.byType(NoteRichEditor), findsNothing);
    await tester.tap(find.byKey(const ValueKey('android-note-input')));
    await _settle(tester);
    await _androidComposerOptions(tester);
    await tester.scrollUntilVisible(
      find.text('放弃更改'),
      200,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('omni-expandable-sheet-body')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.widgetWithText(OmniButton, '放弃更改'));
    await _settle(tester);
    await tester.tap(find.widgetWithText(OmniButton, '放弃更改').last);
    await _settle(tester);
    expect(find.byType(NoteRichEditor), findsNothing);
    expect(
      await tester.runAsync(
        app.container.read(noteEditorProvider).listLocalDrafts,
      ),
      isEmpty,
    );
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android历史菜单编辑退出保存，外部定位不新增正式记录', (tester) async {
    // 初始定位使用真实 /notes?id 参数。
    final _App app = await _mount(
      tester,
      seed: true,
      initialLocation: '/notes?id=target',
    );
    expect(find.byType(NoteRichEditor), findsOneWidget);
    expect(app.container.read(noteEditorProvider).draft.id, 'target');
    await _enterBody(tester, '修改后的历史正文');
    await _closeAndroidComposer(tester);
    await _settle(tester);
    expect(
      (await tester.runAsync(
        () => NoteRepository(app.database).find('target'),
      ))!.body,
      '修改后的历史正文',
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('android-note-card-target')),
        matching: find.byTooltip('笔记操作'),
      ),
    );
    await _settle(tester);
    await tester.tap(find.text('编辑'));
    await _settle(tester);
    expect(_bodyText(tester), '修改后的历史正文');
    await tester.tap(find.byKey(const ValueKey('android-note-history-back')));
    await _settle(tester);
    expect(
      (await tester.runAsync(
        () => NoteRepository(app.database).find('target'),
      ))!.body,
      '修改后的历史正文',
    );
    expect(
      (await tester.runAsync(
        () => app.database.select(app.database.noteEntries).get(),
      ))!.length,
      3,
    );
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  for (final (String, Size, double, String) viewport in [
    ('phone', const Size(390, 844), 1.0, 'light'),
    ('narrow', const Size(320, 640), 1.6, 'dark'),
    ('short', const Size(390, 360), 1.6, 'light'),
    ('landscape', const Size(760, 390), 1.0, 'dark'),
    ('tablet', const Size(1024, 768), 1.0, 'light'),
  ]) {
    testWidgets('Android布局预览 ${viewport.$1} 主界面侧栏搜索编辑', (tester) async {
      // 保留完整异常位置，区分当前笔记与预载分支的布局错误。
      final FlutterExceptionHandler? previous = FlutterError.onError;
      FlutterError.onError = (details) {
        if (details.exceptionAsString().contains('overflowed')) {
          debugPrint(details.toString());
        }
        previous?.call(details);
      };
      addTearDown(() => FlutterError.onError = previous);
      // 从标准宽度进入笔记后再调整视口，避开无关首页的既有最窄布局问题。
      final _App app = await _mount(tester, seed: true, theme: viewport.$4);
      await _navigate(tester, app, '/notes');
      tester.view.physicalSize = viewport.$2;
      tester.platformDispatcher.textScaleFactorTestValue = viewport.$3;
      await _settle(tester);
      await _capture(tester, app, 'android-${viewport.$1}-main');
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('android-notes-menu')));
      await _settle(tester);
      await _capture(tester, app, 'android-${viewport.$1}-sidebar');
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('关闭笔记侧栏'));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('android-notes-search')));
      await _settle(tester);
      await _capture(tester, app, 'android-${viewport.$1}-search');
      expect(
        find.byKey(const ValueKey('android-quick-anniversary')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('筛选笔记'));
      await _settle(tester);
      await _capture(tester, app, 'android-${viewport.$1}-filters');
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('收起筛选'));
      await _settle(tester);
      await tester.tap(find.widgetWithText(OmniButton, '取消'));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('android-note-input')));
      await _settle(tester);
      await _enterBody(tester, '记录此刻的想法\n今天先完成一小步，再继续。');
      await _settle(tester, elapsed: const Duration(milliseconds: 700));
      await _capture(tester, app, 'android-${viewport.$1}-editor');
      expect(tester.takeException(), isNull);
      // 模拟键盘占用，面板正文应可滚动而非溢出。
      tester.view.viewInsets = const FakeViewPadding(bottom: 180);
      await _settle(tester);
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await _dispose(tester, app);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('Android列表默认入口、显式发布和收起后草稿恢复', (tester) async {
    // 预载六个分支不应产生记录或申请录音。
    final _App app = await _mount(tester);
    expect(app.recorder.starts, 0);
    await _navigate(tester, app, '/notes');
    expect(find.byType(NoteRichEditor), findsNothing);
    expect(
      find.byKey(const ValueKey('navigation-/home')).hitTestable(),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('android-note-input')));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('navigation-/home')).hitTestable(),
      findsNothing,
    );
    await _enterBody(tester, '新的记录\n正文只保存在本机草稿');
    await _settle(tester, elapsed: const Duration(milliseconds: 700));
    // 本机暂存和正式记录分离。
    final NoteEditorController editor = app.container.read(noteEditorProvider);
    // 本次操作固定的笔记身份。
    final String id = editor.draft.id;
    expect(
      await tester.runAsync(() => NoteRepository(app.database).find(id)),
      isNull,
    );
    expect(
      (await tester.runAsync(editor.listLocalDrafts))!.single.body,
      contains('新的记录'),
    );
    await _closeAndroidComposer(tester);
    await _settle(tester);
    expect(find.byType(NoteRichEditor), findsNothing);
    await _navigate(tester, app, '/home');
    await _navigate(tester, app, '/notes');
    expect(editor.draft.id, id);
    await tester.tap(find.byKey(const ValueKey('android-note-input')));
    await _settle(tester);
    expect(_bodyText(tester), '新的记录\n正文只保存在本机草稿');
    await tester.tap(find.byKey(const ValueKey('android-note-publish')));
    await _settle(tester);
    expect(find.byType(NoteRichEditor), findsNothing);
    expect(
      (await tester.runAsync(() => NoteRepository(app.database).find(id)))!
          .body,
      '新的记录\n正文只保存在本机草稿',
    );
    expect(find.byKey(ValueKey('android-note-card-$id')), findsOneWidget);
    expect(app.recorder.starts, 0);
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android独立搜索、内容转写交集及取消恢复主列表', (tester) async {
    // 种子包含三篇笔记，只有目标篇带原始转写。
    final _App app = await _mount(tester, seed: true);
    await _navigate(tester, app, '/notes');
    await tester.tap(find.byKey(const ValueKey('android-notes-search')));
    await _settle(tester);
    expect(find.text('快捷搜索'), findsOneWidget);
    expect(find.byType(NoteRichEditor), findsNothing);
    expect(
      find.byKey(const ValueKey('navigation-/home')).hitTestable(),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('android-quick-audio')));
    await _settle(tester);
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('android-note-search-input')),
        matching: find.byType(TextField),
      ),
      '语音验收',
    );
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('android-note-card-target')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('android-note-card-yesterday')),
      findsNothing,
    );
    await tester.tap(find.widgetWithText(OmniButton, '取消'));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('android-note-search-page')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('android-note-card-yesterday')),
      findsOneWidget,
    );
    expect(app.recorder.starts, 0);
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android侧栏触屏标签、统计及回收站入口', (tester) async {
    // 正式笔记数量不受侧栏筛选影响。
    final _App app = await _mount(tester, seed: true);
    await _navigate(tester, app, '/notes');
    await tester.tap(find.byKey(const ValueKey('android-notes-menu')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('android-notes-sidebar')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('navigation-/home')).hitTestable(),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('notes-tag-menu-work')).hitTestable(),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('notes-tag-work')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('android-notes-sidebar')), findsNothing);
    expect(
      find.byKey(const ValueKey('android-note-card-target')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('android-notes-menu')));
    await _settle(tester);
    await tester.tap(find.text('全部笔记').hitTestable());
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('android-note-card-yesterday')),
      findsOneWidget,
    );
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android搜索筛选取消不提交，应用后与快捷条件组合', (tester) async {
    // 使用生产筛选面板，标签查询不修改正文关键词。
    final _App app = await _mount(tester, seed: true);
    await _navigate(tester, app, '/notes');
    await tester.tap(find.byKey(const ValueKey('android-notes-search')));
    await _settle(tester);
    await tester.tap(find.byTooltip('筛选笔记'));
    await _settle(tester);
    await _androidFilterOption(tester, '标签范围', 'none');
    await tester.tap(find.byTooltip('收起筛选'));
    await _settle(tester);
    expect(find.text('清除筛选'), findsNothing);
    await tester.tap(find.byTooltip('筛选笔记'));
    await _settle(tester);
    await _androidFilterOption(tester, '标签范围', 'include');
    await tester.tap(find.byKey(const ValueKey('android-filter-tags')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('android-filter-tag-work')));
    await _settle(tester);
    await tester.tap(find.byTooltip('确认标签'));
    await _settle(tester);
    await tester.tap(find.byTooltip('应用筛选'));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('android-note-card-target')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('android-quick-audio')));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('android-note-card-target')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('android-note-card-yesterday')),
      findsNothing,
    );
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });
}
