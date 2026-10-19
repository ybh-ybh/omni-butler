part of 'notes_page_test.dart';

/// 两端使用各自真实三点菜单，不直接调用界面回调。
Future<void> _openPinMenu(
  WidgetTester tester,
  TargetPlatform platform,
  String id,
) async {
  if (platform == TargetPlatform.android) {
    await _androidCardMenu(tester, id);
    return;
  }
  // 桌面卡片的双击识别需等待单击菜单真正赢得手势竞争。
  final Finder menu = find.byKey(ValueKey('note-menu-$id'));
  await tester.ensureVisible(menu);
  await _settle(tester);
  await tester.tap(menu);
  await _settle(tester, elapsed: const Duration(milliseconds: 350));
}

/// 置顶重新排序后回到列表顶部，检查实际卡片而非仓储结果替身。
Future<void> _pinListTop(WidgetTester tester, TargetPlatform platform) async {
  if (platform == TargetPlatform.android) {
    tester
        .widget<ListView>(find.byKey(const ValueKey('android-notes-list')))
        .controller!
        .jumpTo(0);
  } else {
    tester
        .widget<SingleChildScrollView>(
          find.byKey(const ValueKey('notes-main-scroll')),
        )
        .controller!
        .jumpTo(0);
  }
  await _settle(tester);
}

/// 主列表、编辑页及失败恢复均验证正式状态与正文草稿分离。
void notePinningTests() {
  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.android,
    TargetPlatform.windows,
  ]) {
    for (final String theme in <String>['light', 'dark']) {
      testWidgets('${platform.name}笔记置顶 菜单、排序、主题标记与取消 $theme', (
        WidgetTester tester,
      ) async {
        // 明暗主题均使用完整应用与真实数据库。
        final _App app = await _mount(
          tester,
          platform: platform,
          theme: theme,
          seed: true,
          initialLocation: '/notes',
        );
        if (platform == TargetPlatform.android) {
          await tester.tap(find.byKey(const ValueKey('android-note-input')));
          await _settle(tester);
        }
        await _enterBody(tester, '置顶时不能发布的另一份正文');
        await _settle(tester, elapsed: const Duration(milliseconds: 700));
        if (platform == TargetPlatform.android) {
          await _closeAndroidComposer(tester);
        }
        // 新建草稿身份与内容应在置顶后保持。
        final NoteEditorController editor = app.container.read(
          noteEditorProvider,
        );
        // 当前未发布草稿不能因卡片操作切换。
        final String draftId = editor.draft.id;
        // 昨天的笔记原本排在今天之后，置顶不得修改其日期或正文。
        final NoteEntryRecord before = (await tester.runAsync<NoteEntryRecord?>(
          () => NoteRepository(app.database).find('yesterday'),
        ))!;
        // 置顶不会产生正文版本。
        final int versions = (await tester.runAsync(
          () => app.database.select(app.database.noteVersions).get(),
        ))!.length;
        await _openPinMenu(tester, platform, 'yesterday');
        expect(find.text('置顶').hitTestable(), findsOneWidget);
        expect(find.text('取消置顶'), findsNothing);
        await tester.tap(find.text('置顶'));
        await _settle(tester);
        await _pinListTop(tester, platform);
        // 流更新后图标与原时间同排，并位于时间左侧。
        final Finder marker = find.byKey(const ValueKey('note-pin-yesterday'));
        // 两端时间控件分别保留稳定身份。
        final Finder timestamp = find.byKey(
          ValueKey(
            platform == TargetPlatform.android
                ? 'android-note-created-yesterday'
                : 'note-created-yesterday',
          ),
        );
        expect(marker, findsOneWidget);
        expect(
          tester.widget<Icon>(marker).color,
          OmniColors.of(tester.element(marker)).brand,
        );
        expect(
          tester.getRect(marker).right,
          lessThan(tester.getRect(timestamp).left),
        );
        expect(
          tester.getCenter(marker).dy,
          closeTo(tester.getCenter(timestamp).dy, 1),
        );
        // 旧日期被提升到正式列表第一项，未置顶笔记仍按原顺序。
        final Finder pinnedCard = find.byKey(
          ValueKey(
            platform == TargetPlatform.android
                ? 'android-note-card-yesterday'
                : 'note-card-yesterday',
          ),
        );
        // 今天的目标篇应位于置顶篇下方。
        final Finder otherCard = find.byKey(
          ValueKey(
            platform == TargetPlatform.android
                ? 'android-note-card-target'
                : 'note-card-target',
          ),
        );
        expect(
          tester.getTopLeft(pinnedCard).dy,
          lessThan(tester.getTopLeft(otherCard).dy),
        );
        expect(editor.draft.id, draftId);
        expect(editor.draft.body, '置顶时不能发布的另一份正文');
        // 只有置顶元数据变化，创建时间、正文与正文版本均保持。
        final NoteEntryRecord pinned = (await tester.runAsync<NoteEntryRecord?>(
          () => NoteRepository(app.database).find('yesterday'),
        ))!;
        expect(pinned.isPinned, isTrue);
        expect(pinned.body, before.body);
        expect(pinned.dayKey, before.dayKey);
        expect(pinned.recordTime.label, before.recordTime.label);
        expect(pinned.createdAt, before.createdAt);
        expect(pinned.revision, before.revision);
        await _capture(tester, app, '${platform.name}-note-pin-$theme-list');
        await _openPinMenu(tester, platform, 'yesterday');
        expect(find.text('取消置顶').hitTestable(), findsOneWidget);
        expect(find.text('置顶'), findsNothing);
        await _capture(tester, app, '${platform.name}-note-pin-$theme-menu');
        await tester.tap(find.text('取消置顶'));
        await _settle(tester);
        expect(find.byKey(const ValueKey('note-pin-yesterday')), findsNothing);
        expect(
          (await tester.runAsync<NoteEntryRecord?>(
            () => NoteRepository(app.database).find('yesterday'),
          ))!.isPinned,
          isFalse,
        );
        expect(
          (await tester.runAsync(
            () => app.database.select(app.database.noteVersions).get(),
          ))!.length,
          versions,
        );
        expect(
          await tester.runAsync(
            () => NoteRepository(app.database).find(draftId),
          ),
          isNull,
        );
        await _dispose(tester, app);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('${platform.name}笔记置顶 旧菜单意图、保存失败重试与远端删除', (
      WidgetTester tester,
    ) async {
      // 菜单打开时与点击时可能收到其他设备的置顶更新。
      final _App app = await _mount(
        tester,
        platform: platform,
        seed: true,
        initialLocation: '/notes',
      );
      await _openPinMenu(tester, platform, 'yesterday');
      await tester.runAsync(
        () => NoteRepository(app.database).setPinned('yesterday', true),
      );
      await _settle(tester);
      await tester.tap(find.text('置顶'));
      await _settle(tester);
      expect(
        (await tester.runAsync<NoteEntryRecord?>(
          () => NoteRepository(app.database).find('yesterday'),
        ))!.isPinned,
        isTrue,
      );
      await tester.runAsync(
        () => app.database.customStatement(
          "CREATE TRIGGER fail_note_pin BEFORE UPDATE OF is_pinned ON note_entries BEGIN SELECT RAISE(FAIL, '模拟置顶写入失败'); END",
        ),
      );
      await _openPinMenu(tester, platform, 'yesterday');
      await tester.tap(find.text('取消置顶'));
      await _settle(tester);
      expect(
        (await tester.runAsync<NoteEntryRecord?>(
          () => NoteRepository(app.database).find('yesterday'),
        ))!.isPinned,
        isTrue,
      );
      await tester.runAsync(
        () => app.database.customStatement('DROP TRIGGER fail_note_pin'),
      );
      await _openPinMenu(tester, platform, 'yesterday');
      await tester.tap(find.text('取消置顶'));
      await _settle(tester);
      expect(
        (await tester.runAsync<NoteEntryRecord?>(
          () => NoteRepository(app.database).find('yesterday'),
        ))!.isPinned,
        isFalse,
      );
      await _openPinMenu(tester, platform, 'yesterday');
      await tester.runAsync(
        () => NoteRepository(app.database).softDelete('yesterday'),
      );
      await _settle(tester);
      await tester.tap(find.text('置顶'));
      await _settle(tester);
      expect(
        (await tester.runAsync<NoteEntryRecord?>(
          () => NoteRepository(app.database).find('yesterday'),
        ))!.isPinned,
        isFalse,
      );
      await _dispose(tester, app);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Android笔记置顶 编辑页立即保存且退出正文保存不覆盖置顶', (WidgetTester tester) async {
    // 同一篇正式笔记与尚未提交的正文必须独立保存。
    final _App app = await _mount(
      tester,
      seed: true,
      initialLocation: '/notes?id=target',
    );
    // 正式正文不会因为点击置顶被一起提交。
    final NoteEntryRecord before = (await tester.runAsync<NoteEntryRecord?>(
      () => NoteRepository(app.database).find('target'),
    ))!;
    await _enterBody(tester, '置顶前仍未保存的修改');
    await _settle(tester, elapsed: const Duration(milliseconds: 700));
    await tester.tap(find.byTooltip('编辑笔记操作'));
    await _settle(tester);
    await tester.tap(find.text('置顶'));
    await _settle(tester);
    expect(_bodyText(tester), '置顶前仍未保存的修改');
    // 记录已置顶，正文保持正式旧值，编辑页继续保留勾号。
    final NoteEntryRecord pinned = (await tester.runAsync<NoteEntryRecord?>(
      () => NoteRepository(app.database).find('target'),
    ))!;
    expect(pinned.isPinned, isTrue);
    expect(pinned.body, before.body);
    expect(pinned.revision, before.revision);
    expect(find.byTooltip('保存'), findsOneWidget);
    await tester.tap(find.byTooltip('编辑笔记操作'));
    await _settle(tester);
    expect(find.text('取消置顶'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('android-note-history-back')));
    await _settle(tester);
    // 退出默认保存正文，不能用旧草稿重置即时置顶状态。
    final NoteEntryRecord saved = (await tester.runAsync<NoteEntryRecord?>(
      () => NoteRepository(app.database).find('target'),
    ))!;
    expect(saved.body, '置顶前仍未保存的修改');
    expect(saved.isPinned, isTrue);
    expect(find.byKey(const ValueKey('note-pin-target')), findsOneWidget);
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });
}
