part of 'notes_page_test.dart';

/// 选择生产浮层中的一项，明确覆盖菜单打开与自动关闭。
Future<void> _androidFilterOption(
  WidgetTester tester,
  String name,
  String value,
) async {
  await tester.tap(find.byKey(ValueKey('android-filter-$name')));
  await _settle(tester);
  await tester.tap(find.byKey(ValueKey('android-filter-option-$name-$value')));
  await _settle(tester);
  expect(
    find.byKey(ValueKey('android-filter-option-$name-$value')),
    findsNothing,
  );
}

/// 定位搜索页的真实输入框，排除标签搜索与底层编辑器。
Finder _androidSearchInput() => find.descendant(
  of: find.byKey(const ValueKey('android-note-search-input')),
  matching: find.byType(TextField),
);

/// 读取有无启用确认，避免把禁用入口当作可应用的筛选。
OmniIconButton _androidFilterConfirm(WidgetTester tester) => tester.widget(
  find.byWidgetPredicate(
    (widget) => widget is OmniIconButton && widget.tooltip == '应用筛选',
  ),
);

/// 安卓搜索细化使用真实根路由和正式数据流。
void androidSearchTests() {
  testWidgets('Android搜索历史仅记录完整提交，中文组词与取消不记录', (tester) async {
    // 正式生产页面和隔离设备存储。
    final _App app = await _mount(
      tester,
      seed: true,
      initialLocation: '/notes',
    );
    await tester.tap(find.byKey(const ValueKey('android-notes-search')));
    await _settle(tester);
    expect(find.text('最近搜索'), findsNothing);
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.enterText(_androidSearchInput(), '  项目 完整词  ');
    await _settle(tester);
    expect(app.container.read(noteSearchHistoryProvider), isEmpty);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await _settle(tester);
    expect(app.container.read(noteSearchHistoryProvider), ['项目 完整词']);
    expect(
      tester.widget<TextField>(_androidSearchInput()).controller!.text,
      '项目 完整词',
    );
    await tester.tap(_androidSearchInput());
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '中文候选',
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange(start: 0, end: 4),
      ),
    );
    await tester.pump();
    // 原生输入法组合区尚未提交时，搜索动作也不能记录半成品。
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await _settle(tester);
    expect(app.container.read(noteSearchHistoryProvider), ['项目 完整词']);
    await tester.enterText(_androidSearchInput(), '退出不记');
    await tester.tap(find.widgetWithText(OmniButton, '取消'));
    await _settle(tester);
    expect(app.container.read(noteSearchHistoryProvider), ['项目 完整词']);
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android历史点击复用当前过滤，清空不改变当前结果', (tester) async {
    // 两个历史词条便于验证点击后的去重排序。
    final _App app = await _mount(
      tester,
      seed: true,
      initialLocation: '/notes',
    );
    await tester.runAsync(() async {
      await app.container.read(noteSearchHistoryProvider.notifier).record('日报');
      await app.container.read(noteSearchHistoryProvider.notifier).record('周报');
    });
    await tester.tap(find.byKey(const ValueKey('android-notes-search')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('android-quick-audio')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('android-search-history-日报')));
    await _settle(tester);
    expect(
      tester.widget<TextField>(_androidSearchInput()).controller!.text,
      '日报',
    );
    expect(app.container.read(noteSearchHistoryProvider), ['日报', '周报']);
    expect(
      find.byKey(const ValueKey('android-note-card-target')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('android-note-card-yesterday')),
      findsNothing,
    );
    await tester.enterText(_androidSearchInput(), '');
    await _settle(tester);
    await tester.tap(find.byTooltip('清空最近搜索'));
    await _settle(tester);
    expect(find.text('最近搜索'), findsNothing);
    expect(app.container.read(noteSearchHistoryProvider), isEmpty);
    expect(
      tester.widget<TextField>(_androidSearchInput()).controller!.text,
      '',
    );
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

  testWidgets('Android应用筛选及打开结果记录关键词，输入过程不记录', (tester) async {
    // 目标篇有多行正文，可通过真实展开入口打开结果。
    final _App app = await _mount(
      tester,
      seed: true,
      initialLocation: '/notes',
    );
    await tester.tap(find.byKey(const ValueKey('android-notes-search')));
    await _settle(tester);
    await tester.enterText(_androidSearchInput(), '日报');
    await _settle(tester);
    expect(app.container.read(noteSearchHistoryProvider), isEmpty);
    await tester.tap(find.widgetWithText(OmniButton, '展开').first);
    await _settle(tester);
    expect(app.container.read(noteSearchHistoryProvider), ['日报']);
    await tester.enterText(_androidSearchInput(), '语音验收');
    await tester.tap(find.byTooltip('筛选笔记'));
    await _settle(tester);
    await _androidFilterOption(tester, '内容范围', 'audio');
    await tester.tap(find.byTooltip('应用筛选'));
    await _settle(tester);
    expect(app.container.read(noteSearchHistoryProvider), ['语音验收', '日报']);
    expect(
      find.byKey(const ValueKey('android-note-card-target')),
      findsOneWidget,
    );
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android过滤多选菜单、重置草稿与所有取消路径', (tester) async {
    // 取消不应将任何临时条件带回搜索页。
    final _App app = await _mount(
      tester,
      seed: true,
      initialLocation: '/notes',
    );
    await tester.tap(find.byKey(const ValueKey('android-notes-search')));
    await _settle(tester);
    // 每个关闭路径单独重新打开，覆盖根导航遮罩和返回。
    for (final String close in ['arrow', 'barrier', 'drag', 'back']) {
      await tester.tap(find.byTooltip('筛选笔记'));
      await _settle(tester);
      expect(find.byTooltip('重置筛选'), findsNothing);
      await _androidFilterOption(tester, '内容范围', 'image');
      await _androidFilterOption(tester, '内容范围', 'link');
      expect(find.text('已选 2 项'), findsOneWidget);
      if (close == 'arrow') {
        await _androidFilterOption(tester, '内容范围', 'image');
        expect(find.text('有链接').hitTestable(), findsOneWidget);
        await _androidFilterOption(tester, '内容范围', 'image');
      }
      await tester.tap(find.byKey(const ValueKey('android-filter-内容范围')));
      await _settle(tester);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('android-filter-option-内容范围-image')),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
      await tester.binding.handlePopRoute();
      await _settle(tester);
      if (close == 'arrow') {
        await tester.tap(find.byTooltip('收起筛选'));
      } else if (close == 'barrier') {
        await tester.tapAt(const Offset(8, 80));
      } else if (close == 'drag') {
        await tester.drag(
          find.byKey(const ValueKey('android-filter-日期范围')),
          const Offset(0, 100),
        );
      } else {
        await tester.binding.handlePopRoute();
      }
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('android-note-filter-sheet')),
        findsNothing,
      );
      expect(find.text('清除筛选'), findsNothing);
    }
    await tester.tap(find.byTooltip('筛选笔记'));
    await _settle(tester);
    await _androidFilterOption(tester, '内容范围', 'audio');
    await tester.tap(find.byTooltip('应用筛选'));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('android-note-card-target')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('android-note-card-yesterday')),
      findsNothing,
    );
    await tester.tap(find.byTooltip('筛选笔记'));
    await _settle(tester);
    await tester.tap(find.byTooltip('重置筛选'));
    await _settle(tester);
    expect(find.byTooltip('重置筛选'), findsNothing);
    await tester.tap(find.byTooltip('收起筛选'));
    await _settle(tester);
    expect(find.text('清除筛选'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('android-note-card-yesterday')),
      findsNothing,
    );
    await tester.tap(find.byTooltip('筛选笔记'));
    await _settle(tester);
    await _androidFilterOption(tester, '内容范围', 'all');
    await tester.tap(find.byTooltip('应用筛选'));
    await _settle(tester);
    expect(find.text('清除筛选'), findsNothing);
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android标签子草稿确认取消、搜索保留选择与键盘返回', (tester) async {
    // 搜索隐藏已选项时，选中集合必须继续保留。
    final _App app = await _mount(
      tester,
      seed: true,
      initialLocation: '/notes',
    );
    await tester.tap(find.byKey(const ValueKey('android-notes-search')));
    await _settle(tester);
    await tester.tap(find.byTooltip('筛选笔记'));
    await _settle(tester);
    await _androidFilterOption(tester, '标签范围', 'include');
    expect(_androidFilterConfirm(tester).onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('android-filter-tags')));
    await _settle(tester);
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.tap(find.byKey(const ValueKey('android-filter-tag-work')));
    await tester.enterText(
      find.byKey(const ValueKey('android-filter-tag-search')),
      '复盘',
    );
    await _settle(tester);
    expect(find.byKey(const ValueKey('android-filter-tag-work')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('android-filter-tag-review')));
    await tester.tap(find.byTooltip('清空标签搜索'));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('android-filter-tag-work')),
      findsOneWidget,
    );
    await _settle(tester);
    await tester.tap(find.byTooltip('确认标签'));
    await _settle(tester);
    expect(find.textContaining('等 2 个'), findsOneWidget);
    expect(_androidFilterConfirm(tester).onPressed, isNotNull);
    await tester.tap(find.byKey(const ValueKey('android-filter-tags')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('android-filter-tag-work')));
    await tester.tap(find.byTooltip('取消标签选择'));
    await _settle(tester);
    expect(find.textContaining('等 2 个'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('android-filter-tags')));
    await _settle(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    await _settle(tester);
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('android-filter-tag-picker')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<OmniTextField>(
            find.byKey(const ValueKey('android-filter-tag-search')),
          )
          .focusNode!
          .hasFocus,
      isFalse,
    );
    tester.view.resetViewInsets();
    await _settle(tester);
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('android-filter-tag-picker')),
      findsNothing,
    );
    expect(find.textContaining('等 2 个'), findsOneWidget);
    await tester.tap(find.byTooltip('应用筛选'));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('android-note-card-target')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('android-note-card-yesterday')),
      findsNothing,
    );
    await tester.tap(find.byTooltip('筛选笔记'));
    await _settle(tester);
    await _androidFilterOption(tester, '标签范围', 'exclude');
    await tester.tap(find.byTooltip('应用筛选'));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('android-note-card-target')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('android-note-card-yesterday')),
      findsNothing,
    );
    await tester.tap(find.byTooltip('筛选笔记'));
    await _settle(tester);
    await _androidFilterOption(tester, '标签范围', 'none');
    expect(find.byKey(const ValueKey('android-filter-tags')), findsNothing);
    await _androidFilterOption(tester, '标签范围', 'include');
    expect(_androidFilterConfirm(tester).onPressed, isNull);
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android日期菜单替换那年今日，自定义校验与有效标签删除', (tester) async {
    // 以正式标签删除流验证确认门禁，而非只构造一个无效输入。
    final _App app = await _mount(
      tester,
      seed: true,
      initialLocation: '/notes',
    );
    await tester.tap(find.byKey(const ValueKey('android-notes-search')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('android-quick-anniversary')));
    await _settle(tester);
    await tester.tap(find.byTooltip('筛选笔记'));
    await _settle(tester);
    expect(find.text('那年今日').hitTestable(), findsOneWidget);
    await _androidFilterOption(tester, '日期范围', 'week');
    expect(find.text('本周'), findsOneWidget);
    await _androidFilterOption(tester, '日期范围', 'month');
    await _androidFilterOption(tester, '日期范围', 'custom');
    expect(find.byType(OmniDatePickerButton), findsNWidgets(2));
    // 日期控件复用既有实现，验证它回传后的面板合法性。
    final DateTime today = DateUtils.dateOnly(DateTime.now());
    tester
        .widget<OmniDatePickerButton>(find.byType(OmniDatePickerButton).first)
        .onChanged!(today);
    tester
        .widget<OmniDatePickerButton>(find.byType(OmniDatePickerButton).last)
        .onChanged!(today.subtract(const Duration(days: 1)));
    await _settle(tester);
    expect(_androidFilterConfirm(tester).onPressed, isNull);
    expect(find.text('结束日期不能早于开始日期'), findsOneWidget);
    tester
        .widget<OmniDatePickerButton>(find.byType(OmniDatePickerButton).last)
        .onChanged!(today);
    await _settle(tester);
    expect(_androidFilterConfirm(tester).onPressed, isNotNull);
    await _androidFilterOption(tester, '日期范围', 'all');
    await _androidFilterOption(tester, '标签范围', 'include');
    await tester.tap(find.byKey(const ValueKey('android-filter-tags')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('android-filter-tag-work')));
    await _settle(tester);
    await tester.tap(find.byTooltip('确认标签'));
    await _settle(tester);
    await tester.runAsync(() async {
      await (app.database.update(app.database.taxonomyEntries)
            ..where((row) => row.id.equals('work')))
          .write(TaxonomyEntriesCompanion(deletedAt: Value(DateTime.now())));
    });
    await _settle(tester);
    expect(_androidFilterConfirm(tester).onPressed, isNull);
    await _androidFilterOption(tester, '标签范围', 'all');
    expect(_androidFilterConfirm(tester).onPressed, isNotNull);
    await tester.tap(find.byTooltip('应用筛选'));
    await _settle(tester);
    expect(find.text('清除筛选'), findsNothing);
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  // 用生产组件逐页检查与视频对应的默认过滤、下拉、标签搜索及历史。
  for (final (String, Size, double, String, bool) viewport in [
    ('phone', const Size(390, 844), 1.0, 'light', false),
    ('narrow', const Size(320, 640), 1.6, 'dark', false),
    ('short', const Size(390, 360), 1.6, 'light', false),
    ('landscape', const Size(760, 390), 1.0, 'dark', false),
    ('reduced', const Size(390, 844), 1.0, 'light', true),
  ]) {
    testWidgets('Android搜索细化预览 ${viewport.$1}', (tester) async {
      // 每个视口使用隔离根应用，避免上个用例残留焦点和条件。
      final _App app = await _mount(
        tester,
        seed: true,
        theme: viewport.$4,
        initialLocation: '/notes',
      );
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          FakeAccessibilityFeatures(disableAnimations: viewport.$5);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      tester.view.physicalSize = viewport.$2;
      tester.platformDispatcher.textScaleFactorTestValue = viewport.$3;
      await tester.runAsync(() async {
        await app.container
            .read(noteSearchHistoryProvider.notifier)
            .record('今天的学习记录');
        await app.container
            .read(noteSearchHistoryProvider.notifier)
            .record('项目规划');
      });
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('android-notes-search')));
      await _settle(tester);
      await _capture(tester, app, 'search-${viewport.$1}-history');
      if (viewport.$1 == 'short') {
        await tester.ensureVisible(
          find.byKey(const ValueKey('android-search-history-项目规划')),
        );
        await _settle(tester);
        await _capture(tester, app, 'search-${viewport.$1}-history-scrolled');
        expect(find.byTooltip('清空最近搜索').hitTestable(), findsOneWidget);
      }
      expect(
        tester.getSize(find.byKey(const ValueKey('android-quick-none'))).height,
        greaterThanOrEqualTo(48),
      );
      await tester.tap(find.byTooltip('筛选笔记'));
      await _settle(tester);
      await _capture(tester, app, 'search-${viewport.$1}-default');
      // 每行展开箭头靠右，不因摘要长度停在行中间。
      final Finder arrows = find.descendant(
        of: find.byKey(const ValueKey('android-note-filter-sheet')),
        matching: find.byIcon(Icons.unfold_more),
      );
      expect(arrows, findsNWidgets(3));
      // 三行都使用同一右侧内边距。
      for (final Element arrow in arrows.evaluate()) {
        expect(
          tester.getBottomRight(find.byWidget(arrow.widget)).dx,
          closeTo(
            tester
                    .getBottomRight(
                      find.byKey(const ValueKey('android-note-filter-sheet')),
                    )
                    .dx -
                OmniSpacing.md,
            .1,
          ),
        );
      }
      // 默认面板只由48dp顶栏、三个56dp条件行和底部安全区组成。
      expect(
        tester
            .getSize(find.byKey(const ValueKey('android-note-filter-sheet')))
            .height,
        lessThan(viewport.$2.height * .85),
      );
      for (final String menu in ['日期范围', '标签范围', '内容范围']) {
        await tester.tap(find.byKey(ValueKey('android-filter-$menu')));
        await _settle(tester);
        await _capture(tester, app, 'search-${viewport.$1}-$menu');
        // 紧凑菜单右缘跟随行箭头，短屏向上翻转并保持屏内。
        final Finder option = find.byKey(
          ValueKey('android-filter-option-$menu-all'),
        );
        expect(
          tester.getBottomRight(option).dx,
          greaterThan(viewport.$2.width * .5),
        );
        expect(tester.getTopLeft(option).dx, greaterThanOrEqualTo(0));
        expect(tester.getTopLeft(option).dy, greaterThanOrEqualTo(0));
        expect(tester.takeException(), isNull);
        await tester.binding.handlePopRoute();
        await _settle(tester);
      }
      await _androidFilterOption(tester, '标签范围', 'include');
      await tester.tap(find.byKey(const ValueKey('android-filter-tags')));
      await _settle(tester);
      await tester.enterText(
        find.byKey(const ValueKey('android-filter-tag-search')),
        '复',
      );
      tester.view.viewInsets = FakeViewPadding(
        bottom: viewport.$2.height > 500 ? 260 : 150,
      );
      await _settle(tester);
      await _capture(tester, app, 'search-${viewport.$1}-tags');
      expect(find.byTooltip('确认标签').hitTestable(), findsOneWidget);
      expect(
        find.byKey(const ValueKey('android-filter-tag-review')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await _dispose(tester, app);
      expect(tester.takeException(), isNull);
    });
  }
}
