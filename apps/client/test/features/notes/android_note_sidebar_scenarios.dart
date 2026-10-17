part of 'notes_page_test.dart';

/// 从生产入口打开抽屉，不替换路由或仓储。
Future<void> _sidebarOpen(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('android-notes-menu')));
  await _settle(tester);
}

/// 抽屉整体滚动后再点实际入口，避免坐标停留在旧帧。
Future<void> _sidebarTap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await _settle(tester);
}

/// 标签菜单的一级与删除子页由生产组件处理。
Future<void> _sidebarTagMenu(WidgetTester tester, [String row = 'work']) =>
    _sidebarTap(tester, find.byKey(ValueKey('notes-tag-menu-$row')));

/// 数据查询先排空但不推进动画时钟，再记录真实过渡关键帧。
Future<void> _sidebarFrames(WidgetTester tester, _App app, String name) async {
  for (int index = 0; index < 5; index++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  for (final int milliseconds in [100, 200, 300]) {
    await tester.pump(const Duration(milliseconds: 100));
    await _capture(tester, app, 'sidebar-phone-$name-enter-${milliseconds}ms');
  }
  await _settle(tester);
}

/// 只读查询真实当前标签事实。
Future<TaxonomyEntry> _sidebarTag(
  WidgetTester tester,
  _App app,
  String id,
) async => (await tester.runAsync(
  () => (app.database.select(
    app.database.taxonomyEntries,
  )..where((table) => table.id.equals(id))).getSingle(),
))!;

/// 五处安卓呈现与标签事务的生产路径回归。
void androidSidebarTests() {
  testWidgets('Android侧栏改版 置顶与点选来源、删除子页、关闭保留滚动', (tester) async {
    // 未发布正文不能被侧栏导航或标签操作抢占。
    final _App app = await _mount(
      tester,
      seed: true,
      initialLocation: '/notes',
    );
    await tester.tap(find.byKey(const ValueKey('android-note-input')));
    await _settle(tester);
    await _enterBody(tester, '侧栏保留草稿');
    await _closeAndroidComposer(tester);
    // 当前草稿身份在置顶与只读导航前后保持一致。
    final String? owner = app.container.read(noteEditorProvider).draftId;
    await _sidebarOpen(tester);
    await _sidebarTagMenu(tester);
    expect(find.text('编辑名称和图标'), findsOneWidget);
    await tester.tap(find.text('置顶'));
    await _settle(tester);
    expect((await _sidebarTag(tester, app, 'work')).isPinned, isTrue);
    await _sidebarTap(
      tester,
      find.byKey(const ValueKey('notes-tag-pinned-work')),
    );
    await _sidebarOpen(tester);
    // 同一标签只在实际点选的置顶行显示主色表面。
    final Finder pinned = find.byKey(const ValueKey('notes-tag-pinned-work'));
    // 全部标签中的同名入口不重复高亮。
    final Finder all = find.byKey(const ValueKey('notes-tag-work'));
    expect(
      tester
          .widget<Material>(
            find.descendant(of: pinned, matching: find.byType(Material)).first,
          )
          .color,
      OmniColors.of(tester.element(pinned)).brand,
    );
    expect(
      tester
          .widget<Material>(
            find.descendant(of: all, matching: find.byType(Material)).first,
          )
          .color,
      Colors.transparent,
    );
    await _sidebarTagMenu(tester, 'pinned-work');
    await tester.tap(find.text('删除标签'));
    await _settle(tester);
    expect(find.text('仅移除标签'), findsOneWidget);
    expect(find.text('删除标签和笔记'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(find.text('取消置顶'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await _settle(tester);
    await tester.runAsync(
      () => app.container
          .read(taxonomyRepositoryProvider)
          .setPinned('work', false),
    );
    await _settle(tester);
    await tester.runAsync(
      () => app.container
          .read(taxonomyRepositoryProvider)
          .setPinned('work', true),
    );
    await _settle(tester);
    expect(
      tester
          .widget<Material>(
            find.descendant(of: all, matching: find.byType(Material)).first,
          )
          .color,
      OmniColors.of(tester.element(all)).brand,
    );
    expect(
      tester
          .widget<Material>(
            find.descendant(of: pinned, matching: find.byType(Material)).first,
          )
          .color,
      Colors.transparent,
    );
    await _sidebarTagMenu(tester, 'pinned-work');
    await tester.tap(find.text('取消置顶'));
    await _settle(tester);
    expect(
      tester
          .widget<Material>(
            find.descendant(of: all, matching: find.byType(Material)).first,
          )
          .color,
      OmniColors.of(tester.element(all)).brand,
    );
    await tester.runAsync(
      () => app.container
          .read(taxonomyRepositoryProvider)
          .setPinned('work', true),
    );
    await _settle(tester);
    await _sidebarTap(tester, find.text('回收站'));
    await _sidebarOpen(tester);
    // 列表关闭重建后，真实ScrollController仍恢复上次末端位置。
    final ScrollController scroll = tester
        .widget<SingleChildScrollView>(
          find.byKey(const ValueKey('android-sidebar-scroll')),
        )
        .controller!;
    expect(scroll.offset, greaterThan(0));
    expect(app.container.read(noteEditorProvider).draftId, owner);
    expect(app.container.read(noteEditorProvider).draft.body, '侧栏保留草稿');
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android侧栏改版 排序拖动仅草稿、取消与SQL失败重试、远端增删协调', (tester) async {
    // 原仓储顺序先保留为断言基线。
    final _App app = await _mount(
      tester,
      seed: true,
      initialLocation: '/notes',
    );
    // 已有有效顺序来自真实查询。
    final List<String> before = app.container
        .read(noteTaxonomiesProvider)
        .value!
        .map((tag) => tag.id)
        .toList();
    await _sidebarOpen(tester);
    await _sidebarTap(tester, find.byKey(const ValueKey('android-tags-sort')));
    expect(find.text('恢复默认'), findsNothing);
    expect(find.text('反馈'), findsNothing);
    // 从第一项手柄真实拖到末项后，不能立即更新数据库。
    final Offset start = tester.getCenter(
      find.descendant(
        of: find.byKey(const ValueKey('android-tag-order-work')),
        matching: find.byType(ReorderableDragStartListener),
      ),
    );
    await tester.dragFrom(start, const Offset(0, 140));
    await _settle(tester);
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('android-tag-order-work')))
          .dy,
      greaterThan(
        tester
            .getTopLeft(find.byKey(const ValueKey('android-tag-order-review')))
            .dy,
      ),
    );
    expect(
      app.container.read(noteTaxonomiesProvider).value!.map((tag) => tag.id),
      before,
    );
    await tester.tap(find.byTooltip('返回标签列表'));
    await _settle(tester);
    await _sidebarTap(tester, find.byKey(const ValueKey('android-tags-sort')));
    // 排序列表取消后重新打开，恢复正式顺序。
    final ReorderableListView list = tester.widget(
      find.descendant(
        of: find.byKey(const ValueKey('android-tag-order-list')),
        matching: find.byType(ReorderableListView),
      ),
    );
    list.onReorderItem!(0, 2);
    await _settle(tester);
    await tester.runAsync(
      () => app.database.customStatement(
        "CREATE TRIGGER fail_android_tag_order BEFORE UPDATE ON taxonomy_entries BEGIN SELECT RAISE(FAIL, '模拟排序失败'); END",
      ),
    );
    await tester.tap(find.byKey(const ValueKey('android-tag-order-save')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('android-tag-sort-page')), findsOneWidget);
    expect(
      app.container.read(noteTaxonomiesProvider).value!.map((tag) => tag.id),
      before,
    );
    await tester.runAsync(
      () => app.database.customStatement('DROP TRIGGER fail_android_tag_order'),
    );
    // 同期删除一个标签、新增一个标签，排序页不能复活墓碑。
    await tester.runAsync(
      () => app.container.read(taxonomyRepositoryProvider).delete('unused'),
    );
    await _settle(tester);
    await tester.runAsync(
      () => app.container
          .read(taxonomyRepositoryProvider)
          .save(
            const TaxonomyDraft(
              module: TaxonomyModule.notes,
              kind: TaxonomyKind.tag,
              name: '新到标签',
              sortOrder: 9,
            ),
          ),
    );
    await _settle(tester);
    expect(find.text('灵感'), findsNothing);
    expect(find.text('新到标签'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('android-tag-order-save')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('android-tag-sort-page')), findsNothing);
    expect(
      app.container
          .read(noteTaxonomiesProvider)
          .value!
          .where((tag) => tag.deletedAt == null)
          .map((tag) => tag.name),
      ['复盘', '工作', '新到标签'],
    );
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android侧栏改版 排序松手立即保存等待落位且防连点', (tester) async {
    // 用真实手柄及未结束的落位动画复现模拟器上立即保存丢失顺序。
    final _App app = await _mount(
      tester,
      seed: true,
      initialLocation: '/notes',
    );
    await _sidebarOpen(tester);
    await _sidebarTap(tester, find.byKey(const ValueKey('android-tags-sort')));
    // 拖动开始时抓取真实手柄位置。
    final TestGesture drag = await tester.startGesture(
      tester.getCenter(
        find.descendant(
          of: find.byKey(const ValueKey('android-tag-order-work')),
          matching: find.byType(ReorderableDragStartListener),
        ),
      ),
    );
    await drag.moveBy(const Offset(0, 200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await drag.up();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.tap(find.byKey(const ValueKey('android-tag-order-save')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('android-tag-order-save')));
    expect(find.byKey(const ValueKey('android-tag-sort-page')), findsOneWidget);
    expect((await _sidebarTag(tester, app, 'work')).sortOrder, 0);
    await _settle(tester, elapsed: const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('android-tag-sort-page')), findsNothing);
    expect(
      app.container.read(noteTaxonomiesProvider).value!.map((tag) => tag.id),
      ['review', 'unused', 'work'],
    );
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android侧栏改版 排序取消拖动及远端删项不遗留保存等待', (tester) async {
    // 取消手势、同步改变集合都必须解除落位门禁。
    final _App app = await _mount(
      tester,
      seed: true,
      initialLocation: '/notes',
    );
    await _sidebarOpen(tester);
    await _sidebarTap(tester, find.byKey(const ValueKey('android-tags-sort')));
    // 第一次真实指针取消，不产生重排回调。
    final TestGesture cancelled = await tester.startGesture(
      const Offset(24, 100),
    );
    await cancelled.moveBy(const Offset(0, 140));
    await tester.pump(const Duration(milliseconds: 100));
    await cancelled.cancel();
    await tester.tap(find.byKey(const ValueKey('android-tag-order-save')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('android-tag-sort-page')), findsNothing);
    await _sidebarTap(tester, find.byKey(const ValueKey('android-tags-sort')));
    // 第二次拖动中远端删掉其他项，内部列表取消旧代理后仍可提交。
    final TestGesture remote = await tester.startGesture(const Offset(24, 100));
    await remote.moveBy(const Offset(0, 140));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => app.container.read(taxonomyRepositoryProvider).delete('review'),
    );
    await _settle(tester);
    await remote.up();
    await tester.tap(find.byKey(const ValueKey('android-tag-order-save')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('android-tag-sort-page')), findsNothing);
    expect((await _sidebarTag(tester, app, 'review')).deletedAt, isNotNull);
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android侧栏改版 名称图标取消不写、重复校验、原子保存与键盘返回', (tester) async {
    // 名称与emoji写入使用生产差量事务。
    final _App app = await _mount(
      tester,
      seed: true,
      initialLocation: '/notes',
    );
    await _sidebarOpen(tester);
    await _sidebarTagMenu(tester);
    await tester.tap(find.text('编辑名称和图标'));
    await _settle(tester);
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.enterText(
      find.byKey(const ValueKey('android-tag-name')),
      '取消的新名称',
    );
    await tester.tap(find.byTooltip('取消名称和图标编辑'));
    await _settle(tester);
    expect((await _sidebarTag(tester, app, 'work')).name, '工作');
    await _sidebarTagMenu(tester);
    await tester.tap(find.text('编辑名称和图标'));
    await _settle(tester);
    await tester.enterText(
      find.byKey(const ValueKey('android-tag-name')),
      '  ',
    );
    await tester.tap(find.byKey(const ValueKey('android-tag-appearance-save')));
    await _settle(tester);
    expect(find.textContaining('名称不能为空'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('android-tag-name')),
      '复盘',
    );
    await tester.tap(find.byKey(const ValueKey('android-tag-appearance-save')));
    await _settle(tester);
    expect(find.textContaining('重复名称'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('android-tag-name')),
      '  已改工作  ',
    );
    await tester.enterText(
      find.byKey(const ValueKey('android-tag-icon-search')),
      '😀',
    );
    await _settle(tester);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('android-tag-icon-😀')),
      180,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('android-tag-appearance-page')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await _sidebarTap(
      tester,
      find.byKey(const ValueKey('android-tag-icon-😀')),
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    await _settle(tester);
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('android-tag-appearance-page')),
      findsOneWidget,
    );
    tester.view.resetViewInsets();
    await _settle(tester);
    await tester.runAsync(
      () => app.database.customStatement(
        "CREATE TRIGGER fail_android_tag_appearance BEFORE UPDATE ON taxonomy_entries WHEN OLD.id='work' BEGIN SELECT RAISE(FAIL, '模拟图标保存失败'); END",
      ),
    );
    await tester.tap(find.byKey(const ValueKey('android-tag-appearance-save')));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('android-tag-appearance-page')),
      findsOneWidget,
    );
    expect((await _sidebarTag(tester, app, 'work')).name, '工作');
    expect((await _sidebarTag(tester, app, 'work')).iconEmoji, isNull);
    await tester.runAsync(
      () => app.database.customStatement(
        'DROP TRIGGER fail_android_tag_appearance',
      ),
    );
    await tester.tap(find.byKey(const ValueKey('android-tag-appearance-save')));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('android-tag-appearance-page')),
      findsNothing,
    );
    // 两个字段一起提交，原排序及置顶不受影响。
    final TaxonomyEntry changed = await _sidebarTag(tester, app, 'work');
    expect(changed.name, '已改工作');
    expect(changed.iconEmoji, '😀');
    expect(changed.sortOrder, 0);
    expect(changed.isPinned, isFalse);
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android侧栏改版 仅移除标签保留正式篇和草稿、删除当前筛选后回全部', (tester) async {
    // 选中过的标签删除后不能留下无效列表过滤。
    final _App app = await _mount(
      tester,
      seed: true,
      initialLocation: '/notes',
    );
    await _sidebarOpen(tester);
    await _sidebarTap(tester, find.byKey(const ValueKey('notes-tag-work')));
    await _sidebarOpen(tester);
    await _sidebarTagMenu(tester);
    await tester.tap(find.text('删除标签'));
    await _settle(tester);
    await tester.tap(find.text('仅移除标签'));
    await _settle(tester);
    await tester.tap(find.widgetWithText(OmniButton, '取消'));
    await _settle(tester);
    expect((await _sidebarTag(tester, app, 'work')).deletedAt, isNull);
    await _sidebarTagMenu(tester);
    await tester.tap(find.text('删除标签'));
    await _settle(tester);
    await tester.tap(find.text('仅移除标签'));
    await _settle(tester);
    await tester.tap(find.widgetWithText(OmniButton, '仅移除标签'));
    await _settle(tester);
    expect((await _sidebarTag(tester, app, 'work')).deletedAt, isNotNull);
    expect(
      (await tester.runAsync(
        () => NoteRepository(app.database).find('target'),
      ))!.deletedAt,
      isNull,
    );
    await _sidebarTap(tester, find.byTooltip('关闭笔记侧栏'));
    expect(
      find.byKey(const ValueKey('android-note-card-weekly-note')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('android-note-card-yesterday')),
      findsOneWidget,
    );
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android侧栏改版 删除标签和笔记保护冻结修改，不停止其他篇录音', (tester) async {
    // 标签批量回收保护目标修改，其他篇的采集继续。
    final _App app = await _mount(
      tester,
      seed: true,
      allowRecording: true,
      initialLocation: '/notes?id=target',
    );
    await _enterBody(tester, '标签回收前的未发布修改');
    await _closeAndroidComposer(tester);
    // 周报无工作标签，其录音不得被工作标签删除停止。
    final NoteEditorController editor = app.container.read(noteEditorProvider);
    await tester.runAsync(() async {
      await editor.open('weekly-note');
      await editor.startRecording();
    });
    await _settle(tester);
    await _sidebarOpen(tester);
    await _sidebarTagMenu(tester);
    await tester.tap(find.text('删除标签'));
    await _settle(tester);
    await tester.tap(find.text('删除标签和笔记'));
    await _settle(tester);
    await tester.tap(find.widgetWithText(OmniButton, '删除标签并移入回收站'));
    await _settle(tester);
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
      isNotNull,
    );
    expect(
      (await tester.runAsync(
        () => NoteRepository(app.database).find('weekly-note'),
      ))!.deletedAt,
      isNull,
    );
    expect(app.recorder.state.isActive, isTrue);
    expect(app.recorder.state.noteId, 'weekly-note');
    expect(
      (await tester.runAsync(editor.listLocalDrafts))!.any(
        (draft) => draft.noteId == 'target' && draft.body == '标签回收前的未发布修改',
      ),
      isTrue,
    );
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android侧栏改版 统计仅有记录月份、跨年闰日、月年位置与选日', (tester) async {
    // 月统计从正式归档键聚合，不从创建时间或侧栏筛选推导。
    final _App app = await _mount(
      tester,
      seed: true,
      initialLocation: '/notes',
      prepareDatabase: (database) async {
        for (final String day in ['2026-01-03', '2026-07-08', '2024-02-29']) {
          await NoteRepository(database).save(
            NoteDraft(
              id: day,
              body: '月份统计正文',
              dayKey: day,
              dateEdited: true,
              baseRevision: '',
            ),
          );
        }
      },
    );
    await _sidebarOpen(tester);
    await tester.tap(find.byKey(const ValueKey('android-note-stat-笔记')));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('android-statistics-month-2026-10')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('android-statistics-month-2026-09')),
      findsNothing,
    );
    // 统计页自己的真实滚动位置。
    final ScrollController months = tester
        .widget<ListView>(
          find.byKey(const PageStorageKey('android-statistics-months')),
        )
        .controller!;
    months.jumpTo(100);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('notes-statistics-year-view')));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('android-statistics-annual-0')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('notes-statistics-month-view')));
    await _settle(tester);
    expect(months.offset, 100);
    await tester.tap(
      find.byKey(const ValueKey('android-statistics-year-menu')),
    );
    await _settle(tester);
    await tester.tap(find.text('2024'));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('android-statistics-month-2024-02')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<OmniInkWell>(
            find.byKey(const ValueKey('notes-statistics-day-2024-02-28')),
          )
          .onTap,
      isNull,
    );
    await _sidebarTap(
      tester,
      find.byKey(const ValueKey('notes-statistics-day-2024-02-29')),
    );
    expect(find.byKey(const ValueKey('android-notes-sidebar')), findsNothing);
    expect(find.byKey(const ValueKey('notes-statistics-dialog')), findsNothing);
    expect(
      find.byKey(const ValueKey('android-note-card-2024-02-29')),
      findsOneWidget,
    );
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android侧栏改版 新增标签与远端删除后的改名停止', (tester) async {
    // 新增仍使用同一名称图标页，不移除已有能力。
    final _App app = await _mount(
      tester,
      seed: true,
      initialLocation: '/notes',
    );
    await _sidebarOpen(tester);
    await _sidebarTap(tester, find.byTooltip('新建标签'));
    await tester.enterText(
      find.byKey(const ValueKey('android-tag-name')),
      '安卓新增',
    );
    await tester.tap(find.byKey(const ValueKey('android-tag-appearance-save')));
    await _settle(tester);
    expect(
      app.container
          .read(noteTaxonomiesProvider)
          .value!
          .any((tag) => tag.name == '安卓新增'),
      isTrue,
    );
    await _sidebarTagMenu(tester);
    await tester.tap(find.text('编辑名称和图标'));
    await _settle(tester);
    await tester.enterText(
      find.byKey(const ValueKey('android-tag-name')),
      '迟到的修改',
    );
    await tester.runAsync(
      () => app.container.read(taxonomyRepositoryProvider).delete('work'),
    );
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('android-tag-appearance-save')));
    await _settle(tester);
    expect(find.textContaining('标签已删除或不可用'), findsOneWidget);
    expect((await _sidebarTag(tester, app, 'work')).deletedAt, isNotNull);
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android侧栏改版 空统计切换和关闭不访问未挂载分页', (tester) async {
    // 无正式篇仍可正常打开并退出统计。
    final _App app = await _mount(tester, initialLocation: '/notes');
    await _sidebarOpen(tester);
    await tester.tap(find.byKey(const ValueKey('android-note-stat-笔记')));
    await _settle(tester);
    expect(find.text('还没有记录，写下第一篇笔记吧'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('notes-statistics-year-view')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('notes-statistics-month-view')));
    await tester.pump();
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(find.byKey(const ValueKey('android-notes-sidebar')), findsOneWidget);
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android侧栏改版 远端删除清筛选、恢复不重选、抽屉拖动不穿透', (tester) async {
    // 同一标签删除后恢复，不能重新激活已经失效的旧筛选。
    final _App app = await _mount(
      tester,
      seed: true,
      initialLocation: '/notes',
    );
    await _sidebarOpen(tester);
    await _sidebarTap(tester, find.byKey(const ValueKey('notes-tag-work')));
    expect(
      find.byKey(const ValueKey('android-note-card-weekly-note')),
      findsNothing,
    );
    await tester.runAsync(
      () => app.container.read(taxonomyRepositoryProvider).delete('work'),
    );
    await _settle(tester);
    await tester.runAsync(
      () => app.container.read(taxonomyRepositoryProvider).restore('work'),
    );
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('android-note-card-weekly-note')),
      findsOneWidget,
    );
    await _sidebarOpen(tester);
    // 跟手后反向回弹，仍在同一笔记路由。
    final TestGesture gesture = await tester.startGesture(
      const Offset(220, 160),
    );
    await gesture.moveBy(const Offset(-50, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(50, 0));
    await gesture.up();
    await _settle(tester);
    expect(find.byKey(const ValueKey('android-notes-sidebar')), findsOneWidget);
    await tester.dragFrom(const Offset(200, 160), const Offset(-250, 0));
    await _settle(tester);
    expect(find.byKey(const ValueKey('android-notes-sidebar')), findsNothing);
    expect(app.routerPath, '/notes');
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  for (final String surface in ['rename', 'sort', 'menu']) {
    testWidgets('Android侧栏改版 数据源切换关闭全部覆盖层 $surface', (tester) async {
      // 两个隔离库故意使用同一标签ID，检验异步操作不能串库。
      final _App app = await _mount(
        tester,
        seed: true,
        initialLocation: '/notes',
      );
      // 新库在切换之前准备完成，不使用真实用户数据。
      final AppDatabase replacement = AppDatabase.forTesting(
        NativeDatabase.memory(),
      );
      await tester.runAsync(() => _seed(replacement));
      // 保留其他原始覆写，Riverpod更新只替换当前资料库。
      final SharedPreferences preferences = app.container.read(
        sharedPreferencesProvider,
      );
      // 音频播放器不随换库创建新的测试身份。
      final NoteAudioPlayerService player = app.container.read(
        noteAudioPlayerProvider,
      );
      await _sidebarOpen(tester);
      if (surface == 'sort') {
        await _sidebarTap(
          tester,
          find.byKey(const ValueKey('android-tags-sort')),
        );
        // 保存尚在等待落位时换库，也必须退出并释放原任务。
        final TestGesture waiting = await tester.startGesture(
          const Offset(24, 100),
        );
        await waiting.moveBy(const Offset(0, 200));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        await waiting.up();
        await tester.pump(const Duration(milliseconds: 16));
        await tester.tap(find.byKey(const ValueKey('android-tag-order-save')));
        await tester.pump();
      } else {
        await _sidebarTagMenu(tester);
        if (surface == 'rename') {
          await tester.tap(find.text('编辑名称和图标'));
          await _settle(tester);
          await tester.enterText(
            find.byKey(const ValueKey('android-tag-name')),
            '不能串库',
          );
        }
      }
      app.container.updateOverrides([
        sharedPreferencesProvider.overrideWithValue(preferences),
        appDatabaseProvider.overrideWithValue(replacement),
        noteRecorderProvider.overrideWithValue(app.recorder),
        noteAudioPlayerProvider.overrideWithValue(player),
      ]);
      await _settle(tester);
      expect(find.byKey(const ValueKey('android-notes-sidebar')), findsNothing);
      expect(find.byKey(const ValueKey('android-tag-sort-page')), findsNothing);
      expect(
        find.byKey(const ValueKey('android-tag-appearance-page')),
        findsNothing,
      );
      expect(find.text('编辑名称和图标'), findsNothing);
      expect(
        (await tester.runAsync(
          () => (replacement.select(
            replacement.taxonomyEntries,
          )..where((table) => table.id.equals('work'))).getSingle(),
        ))!.name,
        '工作',
      );
      if (surface == 'sort') {
        expect((await _sidebarTag(tester, app, 'work')).sortOrder, 0);
      }
      await _dispose(tester, app);
      await tester.runAsync(replacement.close);
      expect(tester.takeException(), isNull);
    });
  }

  // 真实生产组件逐页预览，覆盖所有五处布局以及菜单二级和键盘。
  for (final (String, Size, double, String, bool) viewport in [
    ('phone', const Size(390, 844), 1.0, 'light', false),
    ('narrow', const Size(320, 640), 1.6, 'dark', false),
    ('short', const Size(390, 360), 1.6, 'light', false),
    ('landscape', const Size(760, 390), 1.0, 'dark', false),
    ('tablet', const Size(1024, 768), 1.0, 'light', false),
    ('reduced', const Size(390, 844), 1.0, 'light', true),
  ]) {
    testWidgets('Android侧栏改版 生产预览 ${viewport.$1}', (tester) async {
      // 从笔记冷启动，避免预载首页的无关窄屏布局。
      final _App app = await _mount(
        tester,
        seed: true,
        initialLocation: '/notes',
        theme: viewport.$4,
      );
      tester.view.physicalSize = viewport.$2;
      tester.platformDispatcher.textScaleFactorTestValue = viewport.$3;
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          FakeAccessibilityFeatures(disableAnimations: viewport.$5);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('android-notes-menu')));
      await tester.pump();
      for (final int ms in [100, 200, 300]) {
        await tester.pump(const Duration(milliseconds: 100));
        await _capture(tester, app, 'sidebar-${viewport.$1}-enter-${ms}ms');
      }
      await _settle(tester);
      await _capture(tester, app, 'sidebar-${viewport.$1}-main');
      await tester.ensureVisible(
        find.byKey(const ValueKey('notes-tag-menu-work')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('notes-tag-menu-work')));
      if (viewport.$1 == 'phone') {
        await _sidebarFrames(tester, app, 'tag-menu');
      } else {
        await _settle(tester);
      }
      await _capture(tester, app, 'sidebar-${viewport.$1}-tag-menu');
      await tester.tap(find.text('删除标签'));
      if (viewport.$1 == 'phone') {
        await _sidebarFrames(tester, app, 'delete-menu');
      } else {
        await _settle(tester);
      }
      await _capture(tester, app, 'sidebar-${viewport.$1}-delete-menu');
      await tester.binding.handlePopRoute();
      await _settle(tester);
      await tester.binding.handlePopRoute();
      await _settle(tester);
      await _sidebarTagMenu(tester);
      await tester.tap(find.text('编辑名称和图标'));
      if (viewport.$1 == 'phone') {
        await _sidebarFrames(tester, app, 'rename');
      } else {
        await _settle(tester);
      }
      await _capture(tester, app, 'sidebar-${viewport.$1}-rename');
      await tester.enterText(
        find.byKey(const ValueKey('android-tag-icon-search')),
        'smile',
      );
      tester.view.viewInsets = FakeViewPadding(
        bottom: viewport.$2.height > 500 ? 240 : 130,
      );
      await _settle(tester);
      await _capture(tester, app, 'sidebar-${viewport.$1}-rename-keyboard');
      if (viewport.$1 == 'short' || viewport.$1 == 'narrow') {
        // 极短正文仍能滚动到实际候选并操作，不以裁剪后的搜索框冒充可用。
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('android-tag-icon-default')),
          120,
          scrollable: find
              .descendant(
                of: find.byKey(const ValueKey('android-tag-appearance-page')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('android-tag-icon-default')).hitTestable(),
          findsOneWidget,
        );
        await _capture(
          tester,
          app,
          'sidebar-${viewport.$1}-rename-keyboard-candidates',
        );
      }
      tester.view.resetViewInsets();
      await tester.tap(find.byTooltip('取消名称和图标编辑'));
      await _settle(tester);
      await tester.ensureVisible(
        find.byKey(const ValueKey('android-tags-sort')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('android-tags-sort')));
      if (viewport.$1 == 'phone') {
        await _sidebarFrames(tester, app, 'sort');
      } else {
        await _settle(tester);
      }
      await _capture(tester, app, 'sidebar-${viewport.$1}-sort');
      await tester.tap(find.byTooltip('返回标签列表'));
      await _settle(tester);
      await tester.ensureVisible(
        find.byKey(const ValueKey('android-note-stat-笔记')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('android-note-stat-笔记')));
      if (viewport.$1 == 'phone') {
        await _sidebarFrames(tester, app, 'statistics');
      } else {
        await _settle(tester);
      }
      await _capture(tester, app, 'sidebar-${viewport.$1}-statistics-month');
      await tester.tap(
        find.byKey(const ValueKey('notes-statistics-year-view')),
      );
      await _settle(tester);
      await _capture(tester, app, 'sidebar-${viewport.$1}-statistics-year');
      await tester.tap(find.byKey(const ValueKey('notes-statistics-close')));
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('android-notes-sidebar')),
        findsOneWidget,
      );
      await _sidebarTap(tester, find.byTooltip('关闭笔记侧栏'));
      expect(find.byKey(const ValueKey('android-notes-sidebar')), findsNothing);
      await _dispose(tester, app);
      expect(tester.takeException(), isNull);
    });
  }
}
