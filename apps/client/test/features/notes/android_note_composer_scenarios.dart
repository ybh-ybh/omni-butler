part of 'notes_page_test.dart';

/// 新版文字面板通过遮罩执行可靠暂存，不依赖已移除的文字收起按钮。
Future<void> _closeAndroidComposer(WidgetTester tester) async {
  if (find
      .byKey(const ValueKey('android-note-history-back'))
      .evaluate()
      .isNotEmpty) {
    await tester.tap(find.byKey(const ValueKey('android-note-history-back')));
  } else {
    await tester.tapAt(const Offset(8, 8));
  }
  await _settle(tester);
}

/// 低频管理能力统一从更多工具进入，主工具栏不再堆叠所有字段。
Future<void> _androidComposerOptions(WidgetTester tester) async {
  await tester.tap(find.byTooltip('更多笔记工具'));
  await _settle(tester);
  await tester.tap(find.byTooltip('笔记选项'));
  await _settle(tester);
}

/// 等待真实临时原音完成哈希和本机草稿登记，再操作确认。
Future<void> _stopAndroidRecording(WidgetTester tester) async {
  await tester.tap(find.byTooltip('停止录音'));
  // 真文件I/O需在真实事件区间有界等待，不能只推进假时钟。
  for (int attempt = 0; attempt < 150; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 16));
    if (find
        .byWidgetPredicate(
          (widget) =>
              widget is OmniIconButton &&
              widget.tooltip == '确认录音' &&
              widget.onPressed != null,
        )
        .evaluate()
        .isNotEmpty) {
      break;
    }
  }
  await _settle(tester);
  expect(
    find.byWidgetPredicate(
      (widget) =>
          widget is OmniIconButton &&
          widget.tooltip == '确认录音' &&
          widget.onPressed != null,
    ),
    findsOneWidget,
  );
}

/// 提交包含真实WAV校验，等待事务结束而不是只排空界面动画。
Future<void> _waitAndroidCommit(WidgetTester tester, _App app) async {
  // 有界等待真实磁盘与SQLite事务，退出动画也随每帧推进。
  for (int attempt = 0; attempt < 150; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    if (!app.container.read(noteEditorProvider).committing &&
        find
            .byKey(const ValueKey('android-recording-card'))
            .evaluate()
            .isEmpty &&
        find.byKey(const ValueKey('android-note-editor')).evaluate().isEmpty &&
        find
            .byKey(const ValueKey('android-note-history-editor'))
            .evaluate()
            .isEmpty) {
      break;
    }
  }
  await _settle(tester);
}

/// Wait for the production editor without advancing its route animation.
Future<ModalRoute<Object?>> _waitAndroidEditorRoute(WidgetTester tester) async {
  // Real database work must finish before the route can be observed.
  for (int attempt = 0; attempt < 100; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    if (find.byType(NoteRichEditor).evaluate().isNotEmpty) {
      return ModalRoute.of(tester.element(find.byType(NoteRichEditor)))!;
    }
  }
  throw StateError('Android editor did not open');
}

/// Wait for durable saving while checking the still-visible editor document.
Future<void> _waitAndroidEditorExit(
  WidgetTester tester,
  ModalRoute<Object?> route,
  NoteRichEditorController controller,
  Object document,
  String body,
  TextSelection selection,
) async {
  // Keep the fake animation clock at its first exit frame.
  for (int attempt = 0; attempt < 100; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    expect(controller.quillController.document, same(document));
    expect(controller.plainText, body);
    expect(controller.selection, selection);
    if (route.animation!.status == AnimationStatus.reverse) return;
  }
  throw StateError('Android editor did not begin its exit');
}

/// 图片系统替身保留真实文件导入，测试不打开设备相机或图库。
class _ComposerImagePicker extends Fake implements ImagePicker {
  /// 本次用户选择的原件。
  final List<File> files;

  /// 可观察的系统调用次数。
  int calls = 0;

  /// 最近一次是否请求相机。
  bool camera = false;

  /// 创建可取消或交付图片的系统选择器。
  _ComposerImagePicker(this.files);

  /// 相册返回多张原件。
  @override
  Future<List<XFile>> pickMultiImage({
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    int? limit,
    bool requestFullMetadata = true,
  }) async {
    calls++;
    return files.map((file) => XFile(file.path)).toList();
  }

  /// 相机返回一张原件，空集合表示用户取消。
  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async {
    calls++;
    camera = source == ImageSource.camera;
    return files.isEmpty ? null : XFile(files.first.path);
  }

  /// 默认没有操作系统遗留结果。
  @override
  Future<LostDataResponse> retrieveLostData() async => LostDataResponse.empty();
}

/// 视频对应的生产交互与录音归属回归。
void androidComposerTests() {
  testWidgets('Android笔记动效 键盘只影响根覆盖页且一级分支保持状态', (tester) async {
    // Seed enough actual rows to observe retained scrolling across tab changes.
    final _App app = await _mount(
      tester,
      initialLocation: '/notes',
      prepareDatabase: (database) async {
        // Stable records make the initial list scrollable without long text.
        for (int index = 0; index < 20; index++) {
          await NoteRepository(database).save(
            NoteDraft(
              id: 'ime-background-$index',
              body: '键盘背景验收 $index\n保留列表滚动位置',
              dayKey: businessDayKey(DateTime.now()),
              baseRevision: '',
              tags: {},
            ),
          );
        }
      },
    );
    tester.view.viewPadding = const FakeViewPadding(bottom: 24);
    tester.view.padding = const FakeViewPadding(bottom: 24);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();
    // The same scroll position must survive overlays and the boundary toggle.
    final ScrollableState notesScroll = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('android-notes-list')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(notesScroll.position.maxScrollExtent, greaterThan(180));
    notesScroll.position.jumpTo(180);
    await tester.pump();
    // The retained timeline is offstage but still owns a real scaffold layout.
    final Finder inactiveTimeline = find.byKey(
      const ValueKey('primary-navigation-inactive-2'),
      skipOffstage: false,
    );
    // Observe the branch's inherited metrics before any keyboard is visible.
    final MediaQueryData backgroundMedia = MediaQuery.of(
      tester.element(inactiveTimeline),
    );
    // Capture a laid-out descendant rather than the zero-sized Offstage wrapper.
    final Finder timelineScaffold = find
        .descendant(
          of: inactiveTimeline,
          matching: find.byType(Scaffold, skipOffstage: false),
          skipOffstage: false,
        )
        .first;
    // The inactive page must keep the same layout during every IME frame.
    final Size timelineSize = tester.getSize(timelineScaffold);
    // Retain navigator identity across active/offstage transitions.
    final Finder timelineNavigator = find
        .descendant(
          of: inactiveTimeline,
          matching: find.byType(Navigator, skipOffstage: false),
          skipOffstage: false,
        )
        .first;
    // A stable navigator key lets the assertion follow the active branch later.
    final Key timelineNavigatorKey = tester
        .widget<Navigator>(timelineNavigator)
        .key!;
    // The actual element must survive the keyboard boundary becoming disabled.
    final Element timelineNavigatorElement = tester.element(timelineNavigator);
    // Only the outer shell receives raw insets on non-note tabs.
    final Finder shell = find
        .ancestor(
          of: find.byKey(const ValueKey('compact-navigation')),
          matching: find.byType(Scaffold),
        )
        .first;
    // Preserve navigation ancestry instead of rebuilding it on each tab switch.
    final Element shellElement = tester.element(shell);

    // Verify all retained background geometry, not only the visible notes list.
    void expectStableBackground() {
      expect(MediaQuery.of(tester.element(inactiveTimeline)), backgroundMedia);
      expect(tester.getSize(timelineScaffold), timelineSize);
      expect(
        tester.element(find.byKey(timelineNavigatorKey, skipOffstage: false)),
        same(timelineNavigatorElement),
      );
      expect(notesScroll.position.pixels, 180);
    }

    await tester.tap(find.byKey(const ValueKey('android-note-input')));
    await _settle(tester);
    // Root editor overlays must receive the actual animated keyboard insets.
    for (final double inset in [80, 180, 260, 180, 80, 0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      tester.view.padding = FakeViewPadding(bottom: inset == 0 ? 24 : 0);
      await tester.pump(const Duration(milliseconds: 16));
      expectStableBackground();
      expect(
        MediaQuery.viewInsetsOf(tester.element(find.byType(NoteRichEditor)))
            .bottom,
        inset,
      );
    }
    await _closeAndroidComposer(tester);
    await tester.tap(find.byKey(const ValueKey('android-notes-search')));
    await _settle(tester);
    await tester.tap(_androidSearchInput());
    // Opaque root search pages must also retain unmodified platform metrics.
    for (final double inset in [80, 180, 260, 180, 80, 0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      tester.view.padding = FakeViewPadding(bottom: inset == 0 ? 24 : 0);
      await tester.pump(const Duration(milliseconds: 16));
      expectStableBackground();
      expect(
        MediaQuery.viewInsetsOf(
          tester.element(
            find.byKey(const ValueKey('android-note-search-page')),
          ),
        ).bottom,
        inset,
      );
    }
    await tester.tap(find.widgetWithText(OmniButton, '取消'));
    await _settle(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 180);
    tester.view.padding = FakeViewPadding.zero;
    await tester.pump();
    await _navigate(tester, app, '/timeline');
    expect(
      tester.element(find.byKey(timelineNavigatorKey, skipOffstage: false)),
      same(timelineNavigatorElement),
    );
    expect(tester.element(shell), same(shellElement));
    expect(MediaQuery.viewInsetsOf(shellElement).bottom, 180);
    tester.view.resetViewInsets();
    tester.view.padding = const FakeViewPadding(bottom: 24);
    await tester.pump();
    await _navigate(tester, app, '/notes');
    expect(
      tester.state<ScrollableState>(
        find.descendant(
          of: find.byKey(const ValueKey('android-notes-list')),
          matching: find.byType(Scrollable),
        ),
      ),
      same(notesScroll),
    );
    expectStableBackground();
    expect(tester.takeException(), isNull);
    await _dispose(tester, app);
  });

  // Both motion preferences must request keyboard focus exactly once.
  for (final bool reducedMotion in [false, true]) {
    testWidgets('Android笔记动效 入场完成后才自动聚焦 reduced=$reducedMotion', (
      tester,
    ) async {
      // The production navigator starts with no active editor.
      final _App app = await _mount(tester, initialLocation: '/notes');
      tester.view.viewPadding = const FakeViewPadding(bottom: 24);
      tester.view.padding = const FakeViewPadding(bottom: 24);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.view.resetPadding);
      await tester.pump();
      // The background navigation must keep its physical safe-area anchor.
      final Rect navigation = tester.getRect(
        find.byKey(const ValueKey('compact-navigation')),
      );
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          FakeAccessibilityFeatures(disableAnimations: reducedMotion);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pump();
      tester.testTextInput.log.clear();
      await tester.tap(find.byKey(const ValueKey('android-note-input')));
      // Opening the route must not settle its entrance animation.
      final ModalRoute<Object?> route = await _waitAndroidEditorRoute(tester);
      // Start the ticker's time base before advancing its elapsed duration.
      await tester.pump();
      if (!reducedMotion) {
        expect(route.animation!.status, AnimationStatus.forward);
        expect(_bodyHasFocus(tester), isFalse);
        expect(tester.testTextInput.isVisible, isFalse);
        await tester.pump(const Duration(milliseconds: 140));
        expect(_bodyHasFocus(tester), isFalse);
        await tester.pump(const Duration(milliseconds: 140));
        expect(_bodyHasFocus(tester), isFalse);
        await tester.pump(const Duration(milliseconds: 40));
      }
      await tester.pump();
      expect(route.animation!.status, AnimationStatus.completed);
      expect(_bodyHasFocus(tester), isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      // Subsequent rebuilds must not request another keyboard presentation.
      final int presentations = tester.testTextInput.log
          .where((call) => call.method == 'TextInput.show')
          .length;
      expect(presentations, greaterThan(0));
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      tester.view.padding = FakeViewPadding.zero;
      addTearDown(tester.view.resetViewInsets);
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester.getRect(find.byKey(const ValueKey('compact-navigation'))),
        navigation,
      );
      expect(
        tester.testTextInput.log
            .where((call) => call.method == 'TextInput.show')
            .length,
        presentations,
      );
      await _dispose(tester, app);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Android笔记动效 入场中收起不会迟到弹出键盘', (tester) async {
    // Empty drafts still exercise the real asynchronous close gate.
    final _App app = await _mount(tester, initialLocation: '/notes');
    tester.testTextInput.log.clear();
    await tester.tap(find.byKey(const ValueKey('android-note-input')));
    await _waitAndroidEditorRoute(tester);
    await tester.pump(const Duration(milliseconds: 80));
    expect(_bodyHasFocus(tester), isFalse);
    await tester.tapAt(const Offset(8, 8));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(NoteRichEditor), findsNothing);
    expect(tester.testTextInput.isVisible, isFalse);
    expect(
      tester.testTextInput.log.where((call) => call.method == 'TextInput.show'),
      isEmpty,
    );
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android笔记动效 下拉收起成功后不会反向弹回', (tester) async {
    // The live popup route owns both the drag and dismissal transitions.
    final _App app = await _mount(tester, initialLocation: '/notes');
    await tester.tap(find.byKey(const ValueKey('android-note-input')));
    await _settle(tester);
    await _enterBody(tester, '下拉收起保留这份草稿');
    // A real IME inset keeps the dragged handle above the bottom edge.
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();
    // Keep observing the same document while asynchronous draft saving runs.
    final NoteRichEditor rich = tester.widget<NoteRichEditor>(
      find.byType(NoteRichEditor),
    );
    // The persistent draft does not create a formal note when dismissed.
    final String draftId = app.container.read(noteEditorProvider).draftId!;
    // The popup route must reverse instead of restarting its expansion spring.
    final ModalRoute<Object?> route = ModalRoute.of(
      tester.element(find.byType(NoteRichEditor)),
    )!;
    // Track the already-dragged surface rather than its resting position.
    final Finder surface = find.byKey(const ValueKey('android-note-editor'));
    // Pointer movement crosses the close threshold through the real recognizer.
    final TestGesture drag = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('android-composer-handle'))),
    );
    await drag.moveBy(const Offset(0, 20));
    await drag.moveBy(const Offset(0, 100));
    await tester.pump();
    // The first exit frame cannot jump back toward the resting position.
    double previousTop = tester.getTopLeft(surface).dy;
    await drag.up();
    await _waitAndroidEditorExit(
      tester,
      route,
      rich.controller,
      rich.controller.quillController.document,
      rich.controller.plainText,
      rich.controller.selection,
    );
    await tester.pump();
    // Short samples catch the old spring immediately after the route pop.
    for (int frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
      expect(tester.getTopLeft(surface).dy, greaterThanOrEqualTo(previousTop));
      previousTop = tester.getTopLeft(surface).dy;
    }
    await _settle(tester);
    expect(find.byType(NoteRichEditor), findsNothing);
    expect(
      (await tester.runAsync<NoteLocalDraftRecord?>(
        () => app.container.read(noteEditorProvider).localDrafts.find(draftId),
      ))!.body,
      '下拉收起保留这份草稿',
    );
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  // New-note publishing and existing-note saving both preserve exit pixels.
  for (final bool history in [false, true]) {
    testWidgets('Android笔记动效 保存退场保持正文选区且键盘不重开 history=$history', (
      tester,
    ) async {
      // Existing notes use the same production route as a card double tap.
      final _App app = await _mount(
        tester,
        seed: history,
        initialLocation: history ? '/notes?id=target' : '/notes',
      );
      if (!history) {
        await tester.tap(find.byKey(const ValueKey('android-note-input')));
        await _settle(tester);
      }
      // Multiple paragraphs expose document replacement and selection resets.
      const String body = '退出期间保留正文\n第二段保持选区与文档\n第三段不会提前清空';
      await _enterBody(tester, body);
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump();
      // Keep references to the actual document displayed before submission.
      final NoteRichEditor rich = tester.widget<NoteRichEditor>(
        find.byType(NoteRichEditor),
      );
      // A nonzero cursor position must survive every visible exit frame.
      const TextSelection selection = TextSelection.collapsed(offset: 7);
      rich.controller.selection = selection;
      await tester.pump();
      // The controller may reset its draft after saving; the UI must not.
      final Object document = rich.controller.quillController.document;
      // Capture the saved identity before the new-note controller becomes blank.
      final String noteId = app.container.read(noteEditorProvider).draft.id;
      // Observe the real route while the save gate is awaiting SQLite.
      final ModalRoute<Object?> route = ModalRoute.of(
        tester.element(find.byType(NoteRichEditor)),
      )!;
      // The moving surface must continue downwards as the IME inset shrinks.
      final Finder surface = find.byKey(
        ValueKey(
          history ? 'android-note-history-editor' : 'android-note-editor',
        ),
      );
      // The toolbar must travel with its surface instead of following the IME.
      final double toolbarOffset =
          tester.getTopLeft(find.byTooltip('加粗')).dy -
          tester.getTopLeft(surface).dy;
      tester.testTextInput.log.clear();
      await tester.tap(
        history
            ? find.byTooltip('保存')
            : find.byKey(const ValueKey('android-note-publish')),
      );
      await _waitAndroidEditorExit(
        tester,
        route,
        rich.controller,
        document,
        body,
        selection,
      );
      // Establish the exit clock without consuming a visible animation frame.
      await tester.pump();
      // Track the on-screen position, not only the controller's progress.
      double previousTop = tester.getTopLeft(surface).dy;
      // Simulate actual IME motion during, rather than before, route dismissal.
      for (final double inset in [240, 200, 140, 60, 0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pump(const Duration(milliseconds: 30));
        expect(surface, findsOneWidget);
        expect(rich.controller.quillController.document, same(document));
        expect(rich.controller.plainText, body);
        expect(rich.controller.selection, selection);
        expect(rich.controller.quillController.readOnly, isTrue);
        expect(rich.focusNode.hasFocus, isFalse);
        expect(
          tester.getTopLeft(surface).dy,
          greaterThanOrEqualTo(previousTop),
        );
        expect(
          tester.getTopLeft(find.byTooltip('加粗')).dy -
              tester.getTopLeft(surface).dy,
          closeTo(toolbarOffset, .01),
        );
        previousTop = tester.getTopLeft(surface).dy;
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.show',
          ),
          isEmpty,
        );
      }
      await _settle(tester);
      expect(find.byType(NoteRichEditor), findsNothing);
      expect(
        (await tester.runAsync<NoteEntryRecord?>(
          () => NoteRepository(app.database).find(noteId),
        ))!.body,
        body,
      );
      await _dispose(tester, app);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Android输入改版 缩高15%、单击文字、空发送禁用及横条展开', (tester) async {
    // 使用真实根路由和主题，几何断言不依赖静态样稿。
    final _App app = await _mount(tester, initialLocation: '/notes');
    expect(
      tester
          .getSize(find.byKey(const ValueKey('android-note-input-surface')))
          .height,
      closeTo(56 * .85, .01),
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('android-note-input-touch')))
          .height,
      greaterThanOrEqualTo(48),
    );
    await _capture(tester, app, 'composer-phone-input');
    await tester.tap(find.byKey(const ValueKey('android-note-input')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('android-note-editor')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('android-note-editor'))).height,
      closeTo(200, 1),
    );
    // 下拉先平移整块表面，正文不随手势压缩，未过关闭阈值则吸附回原位。
    final double restingTop = tester
        .getTopLeft(find.byKey(const ValueKey('android-note-editor')))
        .dy;
    // 手势越过识别阈值后继续拖动四十像素。
    final TestGesture drag = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('android-composer-handle'))),
    );
    await drag.moveBy(const Offset(0, 20));
    await drag.moveBy(const Offset(0, 40));
    await tester.pump();
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('android-note-editor'))).dy,
      greaterThan(restingTop + 30),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('android-note-editor'))).height,
      closeTo(200, 1),
    );
    await _capture(tester, app, 'composer-phone-drag');
    await drag.up();
    await _settle(tester);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('android-note-editor'))).dy,
      closeTo(restingTop, 1),
    );
    expect(
      tester
          .widget<OmniIconButton>(
            find.byKey(const ValueKey('android-note-publish')),
          )
          .onPressed,
      isNull,
    );
    expect(app.recorder.starts, 0);
    await _capture(tester, app, 'composer-phone-empty');
    await tester.tap(find.byKey(const ValueKey('android-composer-handle')));
    await _settle(tester);
    expect(
      tester.getSize(find.byKey(const ValueKey('android-note-editor'))).height,
      greaterThan(700),
    );
    await _capture(tester, app, 'composer-phone-expanded');
    await tester.tap(find.byKey(const ValueKey('android-composer-handle')));
    await _settle(tester);
    expect(
      tester.getSize(find.byKey(const ValueKey('android-note-editor'))).height,
      closeTo(200, 1),
    );
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android输入改版 长按松手继续、主页语音直接发布并恢复旧文字草稿', (tester) async {
    // 先暂存正文，主页录音必须分配独立草稿。
    final _App app = await _mount(
      tester,
      initialLocation: '/notes',
      allowRecording: true,
    );
    await tester.tap(find.byKey(const ValueKey('android-note-input')));
    await _settle(tester);
    await _enterBody(tester, '尚未发布的文字草稿');
    await _closeAndroidComposer(tester);
    // 之前的编辑归属在录音确认后必须恢复。
    final String? previous = app.container.read(noteEditorProvider).draftId;
    await tester.longPress(
      find.byKey(const ValueKey('android-note-input-touch')),
    );
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('android-recording-card')),
      findsOneWidget,
    );
    expect(find.byType(NoteRichEditor), findsNothing);
    expect(app.recorder.starts, 1);
    expect(app.recorder.state.isActive, isTrue);
    expect(app.container.read(noteEditorProvider).draftId, isNot(previous));
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(find.text('确定退出吗？录音将被清除'), findsOneWidget);
    await tester.tap(find.widgetWithText(OmniButton, '继续'));
    await _settle(tester);
    expect(app.recorder.state.isActive, isTrue);
    expect(app.recorder.starts, 1);
    await _stopAndroidRecording(tester);
    await tester.tap(find.byTooltip('确认录音'));
    await _waitAndroidCommit(tester, app);
    // 发布只包含当前语音，原正文仍是本机草稿。
    final List<NoteEntryRecord> notes = (await tester.runAsync(
      () => app.database.select(app.database.noteEntries).get(),
    ))!;
    expect(notes, hasLength(1));
    expect(notes.single.body, isEmpty);
    expect(
      (await tester.runAsync(
        () => app.database.select(app.database.noteAudioSegments).get(),
      ))!,
      hasLength(1),
    );
    expect(app.container.read(noteEditorProvider).draftId, previous);
    expect(app.container.read(noteEditorProvider).draft.body, '尚未发布的文字草稿');
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android输入改版 麦克风暂停继续与取消只移除本次语音', (tester) async {
    // 编辑器内录音不能提交正文，也不能清空之前的编辑。
    final _App app = await _mount(
      tester,
      initialLocation: '/notes',
      allowRecording: true,
    );
    await tester.tap(find.byKey(const ValueKey('android-note-input')));
    await _settle(tester);
    await _enterBody(tester, '录音附加到这段文字');
    await _androidComposerOptions(tester);
    await tester.tap(find.widgetWithText(OmniButton, '开始录音'));
    await _settle(tester);
    // 片段身份在暂停与继续后仍保持。
    final String? id = app.recorder.state.recordingId;
    await tester.tap(find.byTooltip('暂停录音'));
    await _settle(tester);
    expect(app.recorder.state.phase, NoteRecordingPhase.paused);
    await tester.tap(find.byTooltip('继续录音'));
    await _settle(tester);
    expect(app.recorder.state.recordingId, id);
    await _stopAndroidRecording(tester);
    await tester.tap(find.byTooltip('取消录音'));
    await _settle(tester);
    await tester.tap(find.widgetWithText(OmniButton, '退出'));
    await _settle(tester);
    expect(_bodyText(tester), '录音附加到这段文字');
    expect(app.container.read(noteEditorProvider).isAudioRemoved(id!), isTrue);
    expect(
      (await tester.runAsync(
        () => app.database.select(app.database.noteEntries).get(),
      ))!,
      isEmpty,
    );
    await _androidComposerOptions(tester);
    await tester.tap(find.widgetWithText(OmniButton, '开始录音'));
    await _settle(tester);
    await _stopAndroidRecording(tester);
    await tester.tap(find.byTooltip('确认录音'));
    await _settle(tester);
    expect(_bodyText(tester), '录音附加到这段文字');
    expect(
      (await tester.runAsync(
        () => app.database.select(app.database.noteEntries).get(),
      ))!,
      isEmpty,
    );
    await tester.tap(find.byKey(const ValueKey('android-note-publish')));
    await _waitAndroidCommit(tester, app);
    expect(
      (await tester.runAsync(
        () => app.database.select(app.database.noteEntries).get(),
      ))!.single.body,
      '录音附加到这段文字',
    );
    expect(
      (await tester.runAsync(
        () => app.database.select(app.database.noteAudioSegments).get(),
      ))!,
      hasLength(1),
    );
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android输入改版 录音权限失败可重试与确认退出', (tester) async {
    // 权限拒绝不能生成正式笔记，原卡片保留重试入口。
    final _App app = await _mount(tester, initialLocation: '/notes');
    await tester.tap(find.byKey(const ValueKey('android-note-microphone')));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('android-recording-card')),
      findsOneWidget,
    );
    expect(find.text('重试录音'), findsOneWidget);
    app.recorder.allowRecording = true;
    await tester.tap(find.widgetWithText(OmniButton, '重试录音'));
    await _settle(tester);
    expect(app.recorder.state.isActive, isTrue);
    await tester.tapAt(const Offset(8, 8));
    await _settle(tester);
    await tester.tap(find.widgetWithText(OmniButton, '退出'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('android-recording-card')), findsNothing);
    expect(
      (await tester.runAsync(
        () => app.database.select(app.database.noteEntries).get(),
      ))!,
      isEmpty,
    );
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android输入改版 语音发布失败保留原音，重试及连点只发布一次', (tester) async {
    // 真实数据库拒绝提交，卡片不能因停止成功而提前关闭。
    final _App app = await _mount(
      tester,
      initialLocation: '/notes',
      allowRecording: true,
    );
    app.recorder.deferCompletion = true;
    await tester.tap(find.byKey(const ValueKey('android-note-microphone')));
    await _settle(tester);
    await _stopAndroidRecording(tester);
    await tester.runAsync(
      () => app.database.customStatement(
        "CREATE TRIGGER fail_voice_publish BEFORE INSERT ON note_entries BEGIN SELECT RAISE(FAIL, '模拟提交失败'); END",
      ),
    );
    await tester.tap(find.byTooltip('确认录音'));
    await _waitAndroidCommit(tester, app);
    expect(
      find.byKey(const ValueKey('android-recording-card')),
      findsOneWidget,
    );
    expect(
      (await tester.runAsync(
        () => app.database.select(app.database.noteEntries).get(),
      ))!,
      isEmpty,
    );
    expect(
      (await tester.runAsync(
        () => app.database.select(app.database.noteDraftAudioSegments).get(),
      ))!,
      hasLength(1),
    );
    await tester.runAsync(
      () => app.database.customStatement('DROP TRIGGER fail_voice_publish'),
    );
    await tester.tap(find.byTooltip('确认录音'));
    await tester.tap(find.byTooltip('确认录音'));
    await _waitAndroidCommit(tester, app);
    expect(
      (await tester.runAsync(
        () => app.database.select(app.database.noteEntries).get(),
      ))!,
      hasLength(1),
    );
    expect(
      (await tester.runAsync(
        () => app.database.select(app.database.noteAudioSegments).get(),
      ))!,
      hasLength(1),
    );
    // 正式发布后才到达的完成事件仍必须幂等，不能恢复出第二份草稿。
    app.recorder._completed.add(app.recorder.deferred!);
    await _settle(tester);
    expect(
      (await tester.runAsync(
        () => app.database.select(app.database.noteEntries).get(),
      ))!,
      hasLength(1),
    );
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android输入改版 加号取消不打开编辑器，拍照返回原草稿', (tester) async {
    // 系统取消路径无需任何设备能力。
    final _ComposerImagePicker picker = _ComposerImagePicker([]);
    // 拍照与相册调用统一由可观察的系统接口接管。
    final _App app = await _mount(
      tester,
      initialLocation: '/notes',
      systemImagePicker: picker,
    );
    await tester.tap(find.byTooltip('添加图片或录音'));
    await _settle(tester);
    await _capture(tester, app, 'composer-phone-add');
    expect(find.text('拍照'), findsOneWidget);
    expect(find.text('选择图片'), findsOneWidget);
    await tester.tap(find.text('拍照'));
    await _settle(tester);
    expect(picker.calls, 1);
    expect(picker.camera, isTrue);
    expect(find.byKey(const ValueKey('android-note-editor')), findsNothing);
    expect(
      (await tester.runAsync(
        () => app.database.select(app.database.noteEntries).get(),
      ))!,
      isEmpty,
    );
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  // 生产覆盖层逐页截图，检查编辑、工具、录音各阶段与退出提示。
  for (final (String, Size, double, String, bool) viewport in [
    ('phone', const Size(390, 844), 1.0, 'light', false),
    ('narrow', const Size(320, 640), 1.6, 'dark', false),
    ('short', const Size(390, 360), 1.6, 'light', false),
    ('landscape', const Size(760, 390), 1.0, 'dark', false),
    ('tablet', const Size(1024, 768), 1.0, 'light', false),
    ('reduced', const Size(390, 844), 1.0, 'light', true),
  ]) {
    testWidgets('Android输入改版 生产预览 ${viewport.$1}', (tester) async {
      // 冷启动笔记避免隐藏首页的无关窄屏布局问题。
      final _App app = await _mount(
        tester,
        initialLocation: '/notes',
        seed: true,
        theme: viewport.$4,
        allowRecording: true,
      );
      tester.view.physicalSize = viewport.$2;
      tester.platformDispatcher.textScaleFactorTestValue = viewport.$3;
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          FakeAccessibilityFeatures(disableAnimations: viewport.$5);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('android-note-input')));
      // 等待异步草稿恢复完成，动画计时从覆盖层首帧开始。
      for (
        int attempt = 0;
        attempt < 50 &&
            find
                .byKey(const ValueKey('android-note-editor'))
                .evaluate()
                .isEmpty;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 100));
      await _capture(tester, app, 'composer-${viewport.$1}-enter-100ms');
      await tester.pump(const Duration(milliseconds: 100));
      await _capture(tester, app, 'composer-${viewport.$1}-enter-200ms');
      await tester.pump(const Duration(milliseconds: 100));
      await _capture(tester, app, 'composer-${viewport.$1}-enter-300ms');
      await _settle(tester);
      await _enterBody(tester, '记录此刻的想法\n每次只完成一小步。');
      await _settle(tester);
      await _capture(tester, app, 'composer-${viewport.$1}-text');
      tester.view.viewInsets = FakeViewPadding(
        bottom: viewport.$2.height > 500 ? 260 : 150,
      );
      await _settle(tester);
      await tester.tap(find.byTooltip('选择标签'));
      await _settle(tester);
      await _capture(tester, app, 'composer-${viewport.$1}-tags-keyboard');
      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('android-filter-tag-picker')),
        findsOneWidget,
      );
      tester.view.resetViewInsets();
      await _settle(tester);
      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('android-filter-tag-picker')),
        findsNothing,
      );
      tester.view.viewInsets = FakeViewPadding(
        bottom: viewport.$2.height > 500 ? 260 : 150,
      );
      await _settle(tester);
      await tester.tap(find.byTooltip('更多笔记工具'));
      await _settle(tester);
      await _capture(tester, app, 'composer-${viewport.$1}-tools-keyboard');
      await tester.tap(find.byTooltip('列表格式'));
      await _settle(tester);
      await _capture(tester, app, 'composer-${viewport.$1}-list-keyboard');
      expect(tester.takeException(), isNull);
      // 第一次返回只关闭浮层，第二次关闭键盘，再次返回可靠暂存。
      await tester.binding.handlePopRoute();
      await _settle(tester);
      await tester.binding.handlePopRoute();
      await _settle(tester);
      tester.view.resetViewInsets();
      await _settle(tester);
      await _closeAndroidComposer(tester);
      await tester.tap(find.byKey(const ValueKey('android-note-microphone')));
      await _settle(tester);
      // 注入独立音量流，验证真实生产波形的滚动及暂停冻结。
      for (int sample = 0; sample < 48; sample++) {
        app.recorder.meter(
          .12 + (sample * 13 % 17) / 20,
          Duration(milliseconds: sample * 50),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      await _settle(tester);
      await _capture(tester, app, 'composer-${viewport.$1}-recording');
      await tester.tap(find.byTooltip('暂停录音'));
      await _settle(tester);
      await _capture(tester, app, 'composer-${viewport.$1}-paused');
      await _stopAndroidRecording(tester);
      await _capture(tester, app, 'composer-${viewport.$1}-review');
      await tester.tap(find.byTooltip('取消录音'));
      await _settle(tester);
      await _capture(tester, app, 'composer-${viewport.$1}-exit');
      await tester.tap(find.widgetWithText(OmniButton, '退出'));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      await _dispose(tester, app);
    });
  }
}
