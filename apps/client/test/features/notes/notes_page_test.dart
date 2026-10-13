import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';

import 'package:audioplayers/audioplayers.dart';
import 'package:drift/drift.dart' hide Column, isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/omni_butler_app.dart';
import 'package:omni_butler/app/router/app_router.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/app/theme/app_theme_palette.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/note_composer_style.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';
import 'package:omni_butler/shared/ui/omni_note_composer_button.dart';
import 'package:omni_butler/features/notes/presentation/notes_page.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/notes/audio/note_audio_player_service.dart';
import 'package:omni_butler/features/notes/audio/note_recorder_service.dart';
import 'package:omni_butler/features/notes/audio/note_wav.dart';
import 'package:omni_butler/features/notes/data/note_local_draft_repository.dart';
import 'package:omni_butler/features/notes/data/note_providers.dart';
import 'package:omni_butler/features/notes/data/note_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全应用路径回归：所有音频接口都由替身接管。
void main() {
  test('热力图八至十二周跨年保持每列七天及周一起点', () {
    // 跨年第二周，最后一列包含当前日之后的未来格。
    // 所有支持宽度均保持当前周在最右侧。
    for (int weeks = 8; weeks <= 12; weeks++) {
      // 当前宽度的完整自然周序列。
      final List<DateTime> dates = noteHeatmapDates(
        DateTime(2026, 1, 7),
        weeks: weeks,
      );
      expect(dates.length, weeks * 7);
      expect(dates.first, DateTime(2026, 1, 5 - (weeks - 1) * 7));
      expect(dates.last, DateTime(2026, 1, 11));
      // 每列均由周一至周日排列。
      for (int week = 0; week < weeks; week++) {
        expect(dates[week * 7].weekday, DateTime.monday);
        expect(dates[week * 7 + 6].weekday, DateTime.sunday);
      }
    }
  });

  setUpAll(() async {
    if (Platform.environment['OMNI_NOTES_PREVIEW'] == null) return;
    // 预览使用本机字体，常规回归不依赖Windows资源。
    final ByteData font = ByteData.sublistView(
      await File(
        Platform.environment['OMNI_UI_FONT'] ?? 'C:/Windows/Fonts/msyh.ttc',
      ).readAsBytes(),
    );
    // 所有生产字体别名都提供真实中文字形。
    for (final String family in <String>[
      'Roboto',
      'Ahem',
      'Noto Sans CJK SC',
      'Microsoft YaHei UI',
      'Microsoft YaHei',
    ]) {
      // 当前别名的字体装载器。
      final FontLoader loader = FontLoader(family)
        ..addFont(Future<ByteData>.value(font));
      await loader.load();
    }
    // 图标来自Flutter SDK，路径允许测试环境替换。
    final FontLoader icons = FontLoader('MaterialIcons')
      ..addFont(
        File(
          Platform.environment['OMNI_UI_ICONS'] ?? 'D:/program/code/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
        ).readAsBytes().then(ByteData.sublistView),
      );
    await icons.load();
  });
  testWidgets('Android六分支预载不录音，保存与历史及重新进入相互独立', (tester) async {
    // 完整生产路由环境。
    final _App app = await _mount(tester);
    expect(app.routerPath, '/home');
    expect(
      await tester.runAsync(
        () => app.database.select(app.database.noteEntries).get(),
      ),
      isEmpty,
    );
    expect(app.recorder.starts, 0);
    // 首次真正进入后使用实际编辑器自动保存。
    await _navigate(tester, app, '/notes');
    final String originalId = app.container.read(noteEditorProvider).draft.id;
    await tester.enterText(_body(), '今天完成笔记功能，明天继续验证。');
    await _settle(tester, elapsed: const Duration(milliseconds: 700));
    expect(
      (await tester.runAsync(
        () => NoteRepository(app.database).find(originalId),
      ))?.body,
      '今天完成笔记功能，明天继续验证。',
    );
    expect(find.text('已保存到本机'), findsOneWidget);
    // 生命周期恢复不能生成另一篇笔记。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await _settle(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _settle(tester);
    expect(app.container.read(noteEditorProvider).draft.id, originalId);
    await tester.tap(find.byTooltip('查看历史'));
    await _settle(tester);
    expect(find.text('今天完成笔记功能，明天继续验证。'), findsOneWidget);
    await tester.tap(find.text('今天完成笔记功能，明天继续验证。'));
    await _settle(tester);
    expect(app.container.read(noteEditorProvider).draft.id, originalId);
    expect(
      (await tester.runAsync(
        () => app.database.select(app.database.noteEntries).get(),
      ))!.length,
      1,
    );
    // 一级导航离开后返回，旧正文仍在库中，新入口为空。
    await _navigate(tester, app, '/home');
    await _navigate(tester, app, '/notes');
    expect(app.container.read(noteEditorProvider).draft.id, isNot(originalId));
    expect(tester.widget<TextField>(_body()).controller!.text, isEmpty);
    expect(
      (await tester.runAsync(
        () => NoteRepository(app.database).find(originalId),
      ))?.body,
      '今天完成笔记功能，明天继续验证。',
    );
    expect(
      (await tester.runAsync(
        () => app.database.select(app.database.noteEntries).get(),
      ))!.length,
      1,
    );
    expect(app.recorder.starts, 0);
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('历史按时间多标签与原始转写交集筛选', (tester) async {
    // 已有多天、多类别和多标签的真实数据库。
    final _App app = await _mount(tester, seed: true);
    await _navigate(tester, app, '/notes');
    await tester.tap(find.byTooltip('查看历史'));
    await _settle(tester);
    expect(find.text('今日日报目标'), findsOneWidget);
    expect(find.text('昨日日报'), findsOneWidget);
    // 正文没有关键词，搜索应命中原始转写。
    await tester.enterText(
      find.widgetWithText(TextField, '搜索笔记、标签或转写'),
      '语音验收',
    );
    await _settle(tester);
    expect(find.text('今日日报目标'), findsOneWidget);
    expect(find.text('昨日日报'), findsNothing);
    await tester.tap(find.text('全部时间'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('今天').last);
    await _settle(tester);
    await tester.tap(find.widgetWithText(FilterChip, '工作'));
    await tester.tap(find.widgetWithText(FilterChip, '复盘'));
    await _settle(tester);
    expect(find.text('今日日报目标'), findsOneWidget);
    expect(find.byType(ListTile), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, '搜索笔记、标签或转写'), '不存在');
    await _settle(tester);
    expect(find.text('没有符合条件的笔记'), findsOneWidget);
    await tester.tap(find.text('清除筛选'));
    await _settle(tester);
    expect(find.text('昨日日报'), findsOneWidget);
    expect(app.recorder.starts, 0);
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows 统计、热力图、标签与搜索仅使用正式笔记', (tester) async {
    // Windows 真正页面与本机数据库，不访问外部设备。
    final _App app = await _mount(
      tester,
      platform: TargetPlatform.windows,
      seed: true,
    );
    await _navigate(tester, app, '/notes');
    expect(find.byKey(const ValueKey('medium-navigation')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('note-count'))).data,
      '3',
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('tag-count'))).data,
      '3',
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('day-count'))).data,
      '2',
    );
    expect(find.byKey(const ValueKey('notes-sidebar')), findsOneWidget);
    expect(find.text('全部类别'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith('note-heatmap-'),
      ),
      findsNWidgets(63),
    );
    // 摘要仅是标题之后的正文，并按视觉行裁切。
    final Text preview = tester.widget<Text>(
      find.byKey(const ValueKey('note-preview-target')),
    );
    expect(
      find.byKey(const ValueKey('note-body-toggle-target')),
      findsOneWidget,
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('note-body-expansion-target')))
          .height,
      lessThan(
        tester
            .getSize(find.byKey(const ValueKey('note-preview-target')))
            .height,
      ),
    );
    expect(preview.data, isNot(contains('今日日报目标')));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '搜索笔记 · Ctrl+F'))
          .focusNode!
          .hasFocus,
      isTrue,
    );
    // 补记的 dayKey 不应替代卡片上真实创建日期。
    final NoteEntryRecord archived = (await tester.runAsync<NoteEntryRecord?>(
      () => NoteRepository(app.database).find('yesterday'),
    ))!;
    final String createdDay = businessDayKey(archived.createdAt.toLocal());
    expect(archived.dayKey, isNot(createdDay));
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('note-created-yesterday')))
          .data,
      startsWith(createdDay),
    );
    // 草稿落盘后仍不进入正式统计。
    await tester.enterText(_body(), '未发布的想法');
    await _settle(tester, elapsed: const Duration(milliseconds: 700));
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('note-count'))).data,
      '3',
    );
    // 日期格按 dayKey 过滤，清除筛选再验证转写检索。
    await tester.tap(
      find.byKey(
        ValueKey(
          'note-heatmap-${businessDayKey(DateTime.now().subtract(const Duration(days: 1)))}',
        ),
      ),
    );
    await _settle(tester);
    expect(find.byKey(const ValueKey('note-card-yesterday')), findsOneWidget);
    expect(find.byKey(const ValueKey('note-card-target')), findsNothing);
    await tester.tap(find.text('全部笔记').first);
    await _settle(tester);
    await tester.enterText(
      find.widgetWithText(TextField, '搜索笔记 · Ctrl+F'),
      '语音验收',
    );
    await _settle(tester);
    expect(find.byKey(const ValueKey('note-card-target')), findsOneWidget);
    expect(find.byKey(const ValueKey('note-card-yesterday')), findsNothing);
    // 日期、标签、搜索共同取交集；不改变全局统计。
    await tester.tap(
      find.byKey(ValueKey('note-heatmap-${businessDayKey(DateTime.now())}')),
    );
    await _settle(tester);
    await tester.tap(find.text('复盘').first);
    await _settle(tester);
    expect(find.byKey(const ValueKey('note-card-target')), findsOneWidget);
    expect(find.byKey(const ValueKey('note-card-weekly-note')), findsNothing);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('note-count'))).data,
      '3',
    );
    final Finder filteredCard = find.byKey(const ValueKey('note-card-target'));
    await tester.ensureVisible(filteredCard);
    await tester.tap(filteredCard);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(filteredCard);
    await _settle(tester);
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '搜索笔记 · Ctrl+F'))
          .controller!
          .text,
      '语音验收',
    );
    await tester.ensureVisible(find.text('写新笔记'));
    await tester.tap(find.text('写新笔记'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('note-card-target')), findsOneWidget);
    expect(find.byKey(const ValueKey('note-card-weekly-note')), findsNothing);
    // 保存同一筛选结果后仍保持日期、标签和搜索交集。
    await tester.ensureVisible(filteredCard);
    await tester.tap(filteredCard);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(filteredCard);
    await _settle(tester);
    await tester.enterText(_body(), '筛选内保存标题\n修改后的正文');
    await tester.ensureVisible(find.byKey(const ValueKey('note-commit')));
    await tester.tap(find.byKey(const ValueKey('note-commit')));
    await _settle(tester);
    expect(
      (await tester.runAsync(
        () => NoteRepository(app.database).find('target'),
      ))!.body,
      '筛选内保存标题\n修改后的正文',
    );
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '搜索笔记 · Ctrl+F'))
          .controller!
          .text,
      '语音验收',
    );
    expect(find.byKey(const ValueKey('note-card-target')), findsOneWidget);
    expect(find.byKey(const ValueKey('note-card-weekly-note')), findsNothing);
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows 标签悬停工具计数、标题折叠及搜索独立于笔记过滤', (tester) async {
    // 使用真实正式笔记和未使用标签验证悬停显示规则。
    final _App app = await _mount(
      tester,
      platform: TargetPlatform.windows,
      seed: true,
    );
    await _navigate(tester, app, '/notes');
    expect(find.byTooltip('搜索标签').hitTestable(), findsNothing);
    expect(
      find.byKey(const ValueKey('notes-tag-count-review')).hitTestable(),
      findsNothing,
    );
    // 移动到标签区才显示其他行的数量和标题工具。
    // 鼠标指针用于验证实际悬停命中。
    final TestGesture mouse = await tester.createGesture(
      kind: ui.PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('notes-tag-work'))),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('notes-tag-menu-work')), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('notes-tag-count-review')))
          .data,
      '2',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('notes-tag-count-unused')))
          .data,
      '0',
    );
    expect(find.byTooltip('搜索标签').hitTestable(), findsOneWidget);
    await _settle(tester);
    await _capture(tester, app, 'windows-tags-hover');
    // 标题行强调与折叠独立于整个区域的悬停。
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('notes-tags-toggle'))),
    );
    await tester.pump();
    expect(
      tester.widget<Text>(find.text('全部标签')).style!.color,
      OmniColors.of(tester.element(find.text('全部标签'))).ink,
    );
    expect(
      find.byKey(const ValueKey('notes-tags-collapse')).hitTestable(),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('notes-tag-count-work')))
          .data,
      '2',
    );
    await tester.tap(find.byKey(const ValueKey('notes-tags-toggle')));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('notes-tag-work')).hitTestable(),
      findsNothing,
    );
    expect(find.text('回收站'), findsOneWidget);
    // 搜索打开时自动展开列表，不影响主区草稿、筛选及正式统计。
    await tester.tap(find.byTooltip('搜索标签').hitTestable());
    await _settle(tester);
    await tester.enterText(_body(), '标签搜索期间未发布的正文');
    await tester.enterText(
      find.byKey(const ValueKey('notes-tags-search')),
      '复',
    );
    await _settle(tester);
    expect(find.byKey(const ValueKey('notes-tag-work')), findsNothing);
    expect(find.byKey(const ValueKey('notes-tag-review')), findsOneWidget);
    expect(find.byKey(const ValueKey('note-card-target')), findsOneWidget);
    expect(find.byKey(const ValueKey('note-card-yesterday')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('note-count'))).data,
      '3',
    );
    await _capture(tester, app, 'windows-tags-search');
    await tester.enterText(
      find.byKey(const ValueKey('notes-tags-search')),
      '不存在',
    );
    await _settle(tester);
    // 搜索无结果直接留空，不绘制提示文字或保留列表占位。
    expect(find.text('没有匹配的标签'), findsNothing);
    expect(find.text('还没有标签'), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('notes-tags-expansion'))).height,
      0,
    );
    // 鼠标离开标签区域后关闭搜索，不能残留标题行悬停样式。
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('note-card-target'))),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);
    expect(find.byKey(const ValueKey('notes-tags-search')), findsNothing);
    expect(
      tester.widget<Text>(find.text('全部标签')).style!.color,
      OmniColors.of(tester.element(find.text('全部标签'))).muted,
    );
    expect(
      find.byKey(const ValueKey('notes-tags-collapse')).hitTestable(),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('notes-tag-unused')), findsOneWidget);
    expect(tester.widget<TextField>(_body()).controller!.text, '标签搜索期间未发布的正文');
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('notes-tags-toggle'))),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('搜索标签').hitTestable());
    await _settle(tester);
    await tester.enterText(
      find.byKey(const ValueKey('notes-tags-search')),
      '灵',
    );
    await tester.tap(find.byTooltip('关闭标签搜索'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('notes-tag-work')), findsOneWidget);
    await mouse.removePointer();
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  // 同时验证正常动效与减少动画下的实际布局。
  for (final bool reduceMotion in [false, true]) {
    testWidgets('Windows 标签上下展开收起、反向连续及左对齐：减少动画$reduceMotion', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          FakeAccessibilityFeatures(disableAnimations: reduceMotion);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      // 直接启动笔记页，使用正式标签和独立回收站入口。
      final _App app = await _mount(
        tester,
        platform: TargetPlatform.windows,
        seed: true,
        initialLocation: '/notes',
      );
      // 动画占位与交互入口的稳定身份。
      final Finder expansion = find.byKey(
        const ValueKey('notes-tags-expansion'),
      );
      // 标题行始终保留并可反向切换。
      final Finder toggle = find.byKey(const ValueKey('notes-tags-toggle'));
      // 回收站所属行限定图标范围，避免误取笔记菜单图标。
      final Finder recycleRow = find.ancestor(
        of: find.text('回收站'),
        matching: find.byType(OmniListRow),
      );
      // 全部笔记、回收站和每个标签使用相同实际行高，菜单不会撑大行。
      final Finder allRow = find.ancestor(
        of: find.text('全部笔记'),
        matching: find.byType(OmniListRow),
      );
      expect(tester.getSize(recycleRow).height, tester.getSize(allRow).height);
      for (final String id in ['work', 'review', 'unused']) {
        expect(
          tester
              .getSize(
                find.descendant(
                  of: find.byKey(ValueKey('notes-tag-$id')),
                  matching: find.byType(OmniListRow),
                ),
              )
              .height,
          tester.getSize(allRow).height,
        );
      }
      // 实际可见图标字形而不是外层布局槽。
      final Finder recycleGlyph = find.descendant(
        of: find.descendant(of: recycleRow, matching: find.byType(Icon)),
        matching: find.byType(RichText),
      );
      expect(
        tester.getTopLeft(find.text('全部标签')).dx,
        closeTo(tester.getTopLeft(recycleGlyph).dx, 0.1),
      );
      // 回收站直接接在标签列表后，不留额外区块间距。
      expect(
        tester.getTopLeft(recycleRow).dy,
        closeTo(tester.getBottomLeft(expansion).dy, 0.1),
      );
      // 完全展开的高度和下方回收站位置作为基线。
      final double fullHeight = tester.getSize(expansion).height;
      // 回收站随标签列表的实际高度一起移动。
      final double recycleTop = tester.getTopLeft(recycleRow).dy;
      expect(fullHeight, greaterThan(0));
      await tester.tap(toggle);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('notes-tag-work')).hitTestable(),
        findsNothing,
      );
      if (reduceMotion) {
        await tester.pump();
        expect(tester.getSize(expansion).height, 0);
      } else {
        await tester.pump(const Duration(milliseconds: 60));
        // 中间帧必须向上收缩，并使回收站同步上移。
        final double closingHeight = tester.getSize(expansion).height;
        expect(closingHeight, allOf(greaterThan(0), lessThan(fullHeight)));
        expect(
          tester.getTopLeft(recycleRow).dy,
          closeTo(recycleTop - fullHeight + closingHeight, 0.1),
        );
        await _capture(tester, app, 'windows-tags-collapsing');
        await tester.tap(toggle);
        await tester.pump();
        expect(tester.getSize(expansion).height, closeTo(closingHeight, 0.1));
        await tester.pump(const Duration(milliseconds: 60));
        expect(tester.getSize(expansion).height, greaterThan(closingHeight));
        await _capture(tester, app, 'windows-tags-expanding');
        await _settle(tester);
        expect(tester.getSize(expansion).height, closeTo(fullHeight, 0.1));
        await tester.tap(toggle);
        await _settle(tester);
        expect(tester.getSize(expansion).height, 0);
      }
      expect(
        tester.getTopLeft(recycleRow).dy,
        closeTo(recycleTop - fullHeight, 0.1),
      );
      await _capture(tester, app, 'windows-tags-collapsed');
      await tester.tap(toggle);
      await _settle(tester);
      expect(tester.getSize(expansion).height, closeTo(fullHeight, 0.1));
      expect(
        find.byKey(const ValueKey('notes-tag-work')).hitTestable(),
        findsOneWidget,
      );
      await _dispose(tester, app);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Windows 标签标题无背景、浅灰圆角搜索及菜单字形居中', (tester) async {
    // 通过生产页面验证控件外观及实际字形位置。
    final _App app = await _mount(
      tester,
      platform: TargetPlatform.windows,
      seed: true,
    );
    await _navigate(tester, app, '/notes');
    // 同一指针在标题、标签行、按钮间切换。
    final TestGesture mouse = await tester.createGesture(
      kind: ui.PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('notes-tags-toggle'))),
    );
    await _settle(tester);
    // 标题可点击但不绘制灰色悬停、按下或水波纹背景。
    final InkWell heading = tester.widget<InkWell>(
      find.byKey(const ValueKey('notes-tags-toggle')),
    );
    expect(heading.hoverColor, Colors.transparent);
    expect(heading.highlightColor, Colors.transparent);
    expect(heading.splashColor, Colors.transparent);
    await _capture(tester, app, 'windows-tags-header-hover');
    await tester.tap(find.byTooltip('搜索标签').hitTestable());
    await _settle(tester);
    // 搜索外观必须覆盖主题默认焦点描边，关闭按钮嵌入输入框。
    final TextField search = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const ValueKey('notes-tags-search')),
        matching: find.byType(TextField),
      ),
    );
    expect(search.decoration!.filled, isTrue);
    expect(search.decoration!.fillColor!.a, 1);
    expect(search.decoration!.hoverColor, Colors.transparent);
    expect(
      (search.decoration!.enabledBorder! as OutlineInputBorder).borderSide,
      BorderSide.none,
    );
    expect(
      (search.decoration!.focusedBorder! as OutlineInputBorder).borderSide,
      BorderSide.none,
    );
    expect(
      (search.decoration!.focusedBorder! as OutlineInputBorder).borderRadius,
      BorderRadius.circular(OmniRadius.panel),
    );
    expect(search.decoration!.suffixIcon, isA<OmniIconButton>());
    expect(
      tester.getSize(find.byKey(const ValueKey('notes-tags-search'))).height,
      OmniSize.iconButton,
    );
    await _capture(tester, app, 'windows-tags-search-style');
    await tester.tap(find.byTooltip('关闭标签搜索'));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('notes-tag-work')));
    await _settle(tester);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('notes-tag-work'))),
    );
    await _settle(tester);
    // 标签菜单与所属行的可见内容垂直居中，字形与36dp背景同心。
    final Finder menu = find.byKey(const ValueKey('notes-tag-menu-work'));
    // 获取所属标签行的实际内容布局。
    final Finder row = find.descendant(
      of: find.byKey(const ValueKey('notes-tag-work')),
      matching: find.byType(OmniListRow),
    );
    // 检查绘制字形而非外层图标占位的中心。
    final Finder glyph = find.descendant(
      of: menu,
      matching: find.byType(RichText),
    );
    expect(tester.getSize(menu), const Size.square(OmniSize.iconButton));
    expect(tester.getCenter(menu).dy, tester.getCenter(row).dy);
    expect(tester.getCenter(glyph), tester.getCenter(menu));
    expect(
      (tester.widget<RichText>(glyph).text as TextSpan).style!.color,
      OmniColors.of(tester.element(menu)).muted,
    );
    await mouse.moveTo(tester.getCenter(menu));
    await _settle(tester);
    expect(
      (tester.widget<RichText>(glyph).text as TextSpan).style!.color,
      OmniColors.of(tester.element(menu)).ink,
    );
    await _capture(tester, app, 'windows-tag-menu-button-hover');
    for (final AnimatedOpacity fade in tester.widgetList<AnimatedOpacity>(
      find.descendant(
        of: find.byKey(const ValueKey('notes-sidebar-region')),
        matching: find.byType(AnimatedOpacity),
      ),
    )) {
      expect(fade.duration, OmniMotion.fast);
    }
    await mouse.removePointer();
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows 标签排序计数不受草稿、回收站和主区搜索影响', (tester) async {
    // 删除一篇正式记录后按活动笔记数量排序。
    final _App app = await _mount(
      tester,
      platform: TargetPlatform.windows,
      seed: true,
    );
    await _navigate(tester, app, '/notes');
    await tester.runAsync(
      () => NoteRepository(app.database).softDelete('yesterday'),
    );
    await tester.enterText(_body(), '未发布新笔记');
    await tester.enterText(
      find.widgetWithText(TextField, '搜索笔记 · Ctrl+F'),
      '不存在',
    );
    await _settle(tester);
    // 标题悬停显示全部计数，主区空结果不改变篇数。
    // 鼠标指针用于验证实际悬停命中。
    final TestGesture mouse = await tester.createGesture(
      kind: ui.PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('notes-tags-toggle'))),
    );
    await tester.pump();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('notes-tag-count-work')))
          .data,
      '1',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('notes-tag-count-review')))
          .data,
      '2',
    );
    await tester.tap(find.byTooltip('排序标签').hitTestable());
    await _settle(tester);
    await tester.tap(find.text('按笔记数量'));
    await _settle(tester);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('notes-tag-review'))).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const ValueKey('notes-tag-work'))).dy,
      ),
    );
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('notes-tags-toggle'))),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('排序标签').hitTestable());
    await _settle(tester);
    await tester.tap(find.text('按名称'));
    await _settle(tester);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('notes-tag-review'))).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const ValueKey('notes-tag-work'))).dy,
      ),
    );
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('notes-tags-toggle'))),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('排序标签').hitTestable());
    await _settle(tester);
    await tester.tap(find.text('默认顺序'));
    await _settle(tester);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('notes-tag-work'))).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const ValueKey('notes-tag-review'))).dy,
      ),
    );
    await mouse.removePointer();
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows 标签菜单改名及删除只改变标签和关联', (tester) async {
    // 保存原笔记事实，标签操作不能改写正文、版本或录音。
    final _App app = await _mount(
      tester,
      platform: TargetPlatform.windows,
      seed: true,
    );
    await _navigate(tester, app, '/notes');
    await tester.enterText(_body(), '标签操作期间保留的草稿');
    // 操作前正式正文及版本身份。
    final NoteEntryRecord original = (await tester.runAsync<NoteEntryRecord?>(
      () => NoteRepository(app.database).find('target'),
    ))!;
    // 标签修改不应产生正文历史版本。
    final int versions = (await tester.runAsync(
      () => app.database.select(app.database.noteVersions).get(),
    ))!.length;
    // 鼠标指针用于验证实际悬停命中。
    final TestGesture mouse = await tester.createGesture(
      kind: ui.PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('notes-tag-work'))),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('notes-tag-menu-work')));
    await _settle(tester);
    expect(find.text('删除标签'), findsOneWidget);
    expect(find.text('编辑名称'), findsOneWidget);
    expect(
      find.byWidgetPredicate((widget) => widget is PopupMenuItem<String>),
      findsNWidgets(2),
    );
    expect(find.text('置顶'), findsNothing);
    await _capture(tester, app, 'windows-tags-menu');
    await tester.tap(find.text('编辑名称'));
    await _settle(tester);
    expect(
      tester
          .widget<TextField>(
            find.descendant(
              of: find.byKey(const ValueKey('notes-tag-name')),
              matching: find.byType(TextField),
            ),
          )
          .controller!
          .text,
      '工作',
    );
    // 关闭编辑弹窗丢弃尚未保存的新名称。
    await tester.enterText(
      find.byKey(const ValueKey('notes-tag-name')),
      '未确认的名称',
    );
    await tester.tap(find.byTooltip('关闭').hitTestable());
    await _settle(tester);
    expect(find.text('工作'), findsOneWidget);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('notes-tag-work'))),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('notes-tag-menu-work')));
    await _settle(tester);
    await tester.tap(find.text('编辑名称'));
    await _settle(tester);
    await tester.enterText(find.byKey(const ValueKey('notes-tag-name')), '复盘');
    await tester.tap(find.text('保存'));
    await _settle(tester);
    expect(find.text('同一模块内不能使用重复名称'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('notes-tag-name')), '');
    await tester.tap(find.text('保存'));
    await _settle(tester);
    expect(find.text('名称不能为空'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('notes-tag-name')),
      '项目灵感',
    );
    await _settle(tester);
    await _capture(tester, app, 'windows-tags-rename');
    await tester.tap(find.text('保存'));
    await _settle(tester);
    expect(find.text('项目灵感'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('notes-tag-work')));
    await _settle(tester);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('notes-tag-work'))),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('notes-tag-menu-work')));
    await _settle(tester);
    await tester.tap(find.text('删除标签'));
    await _settle(tester);
    await tester.tap(find.text('取消').hitTestable());
    await _settle(tester);
    expect(find.byKey(const ValueKey('notes-tag-work')), findsOneWidget);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('notes-tag-work'))),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('notes-tag-menu-work')));
    await _settle(tester);
    await tester.tap(find.text('删除标签'));
    await _settle(tester);
    await tester.tap(find.text('删除').hitTestable());
    await _settle(tester);
    expect(find.byKey(const ValueKey('notes-tag-work')), findsNothing);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('tag-count'))).data,
      '2',
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('note-count'))).data,
      '3',
    );
    expect(find.byKey(const ValueKey('note-card-weekly-note')), findsOneWidget);
    expect(tester.widget<TextField>(_body()).controller!.text, '标签操作期间保留的草稿');
    // 操作后正式数据用于验证解除关联边界。
    final NoteEntryRecord after = (await tester.runAsync<NoteEntryRecord?>(
      () => NoteRepository(app.database).find('target'),
    ))!;
    expect(after.body, original.body);
    expect(after.revision, original.revision);
    expect(noteTagIds(after.tags), {'review'});
    expect(
      (await tester.runAsync(
        () => app.database.select(app.database.noteVersions).get(),
      ))!.length,
      versions,
    );
    expect(
      (await tester.runAsync(
        () => app.database.select(app.database.noteAudioSegments).get(),
      ))!.single.id,
      'audio-target',
    );
    await mouse.removePointer();
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows 纯录音正式笔记计入统计并可按转写搜索', (tester) async {
    // 只写虚构音频元信息，不创建录音文件或访问麦克风。
    final _App app = await _mount(tester, platform: TargetPlatform.windows);
    // 纯音频正文为空，仍属于有效正式笔记。
    final DateTime now = DateTime.now();
    await tester.runAsync(() async {
      await NoteRepository(app.database).save(
        NoteDraft(
          id: 'voice-only',
          body: '',
          dayKey: businessDayKey(now),
          baseRevision: '',
        ),
        hasAudio: true,
      );
      await app.database
          .into(app.database.noteAudioSegments)
          .insert(
            NoteAudioSegmentsCompanion.insert(
              id: 'voice-only-segment',
              noteId: 'voice-only',
              sortOrder: 0,
              durationMs: 4200,
              mime: 'audio/wav',
              sha256: '0' * 64,
              byteSize: 100,
              transcript: const Value('只在原音转写中的关键词'),
              createdAt: now,
              updatedAt: now,
            ),
          );
    });
    await _navigate(tester, app, '/notes');
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('note-count'))).data,
      '1',
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('day-count'))).data,
      '1',
    );
    expect(find.text('语音笔记'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, '搜索笔记 · Ctrl+F'),
      '原音转写',
    );
    await _settle(tester);
    expect(find.byKey(const ValueKey('note-card-voice-only')), findsOneWidget);
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows 输入卡片四种状态、无悬停底色和图标发布', (tester) async {
    // 使用生产根应用验证聚焦和实际底部布局。
    final _App app = await _mount(
      tester,
      platform: TargetPlatform.windows,
      initialLocation: '/notes',
    );
    // 卡片外观只由当前输入区域焦点决定。
    final Finder surface = find.byKey(const ValueKey('note-composer-surface'));
    // 标签与主操作在同一输入卡片中。
    final Finder tag = find.byKey(const ValueKey('note-composer-tag'));
    // 右下角始终只出现一个图标主操作。
    final Finder action = find.byKey(const ValueKey('note-commit'));
    expect(
      find.descendant(
        of: surface,
        matching: find.byType(OmniNoteComposerButton),
      ),
      findsNWidgets(2),
    );
    expect(
      find.descendant(of: surface, matching: find.byType(Divider)),
      findsNothing,
    );
    expect(find.text('取消'), findsNothing);
    expect(find.byTooltip('开始录音'), findsOneWidget);
    expect(find.byKey(const ValueKey('note-composer-count')), findsNothing);
    expect(
      (tester.widget<DecoratedBox>(surface).decoration as BoxDecoration)
          .border!
          .top
          .color,
      NoteComposerStyle.border,
    );
    expect(tester.getSize(surface).height, greaterThanOrEqualTo(240));
    expect(tester.getSize(action), NoteComposerStyle.actionSize);
    expect(
      _composerButton(tester, tag).style!.foregroundColor!.resolve({}),
      NoteComposerStyle.idleTool,
    );
    await _capture(tester, app, 'windows-composer-empty');
    // 鼠标进入正文不改变输入框填充，也不激活整个卡片。
    final TestGesture mouse = await tester.createGesture(
      kind: ui.PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(_body()));
    await _settle(tester);
    expect(tester.widget<TextField>(_body()).decoration!.filled, isFalse);
    expect(
      tester.widget<TextField>(_body()).decoration!.hoverColor,
      Colors.transparent,
    );
    expect(
      (tester.widget<DecoratedBox>(surface).decoration as BoxDecoration)
          .border!
          .top
          .color,
      NoteComposerStyle.border,
    );
    await _capture(tester, app, 'windows-composer-hover');
    await tester.tap(_body());
    await _settle(tester);
    expect(
      (tester.widget<DecoratedBox>(surface).decoration as BoxDecoration)
          .border!
          .top
          .color,
      OmniColors.of(tester.element(surface)).brand,
    );
    expect(find.text('0'), findsWidgets);
    expect(
      _composerButton(tester, tag).style!.foregroundColor!.resolve({}),
      NoteComposerStyle.muted,
    );
    expect(
      _composerButton(tester, action).style!.backgroundColor!.resolve({}),
      OmniColors.of(tester.element(surface)).brand,
    );
    await _capture(tester, app, 'windows-composer-focused-empty');
    await tester.enterText(_body(), '玩儿玩儿2');
    await _settle(tester);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('note-composer-count')))
          .data,
      '5',
    );
    expect(find.byTooltip('发布'), findsOneWidget);
    expect(find.text('发布'), findsNothing);
    expect(
      IconTheme.of(tester.element(find.byIcon(Icons.send))).color,
      Colors.white,
    );
    expect(
      tester.getSize(
        find.descendant(of: action, matching: find.byType(Material)).first,
      ),
      NoteComposerStyle.actionSize,
    );
    expect(
      _composerButton(tester, action).style!.backgroundColor!.resolve({}),
      OmniColors.of(tester.element(surface)).brand,
    );
    expect(tester.getCenter(tag).dy, tester.getCenter(action).dy);
    await _capture(tester, app, 'windows-composer-focused-text');
    // 点击卡片内工具不应被正文误判为外部点击。
    await tester.tap(tag);
    await _settle(tester);
    expect(tester.widget<TextField>(_body()).focusNode!.hasFocus, isTrue);
    expect(find.text('管理标签'), findsOneWidget);
    await tester.tap(tag);
    await _settle(tester);
    // 中文、组合字符和 emoji 按用户看到的字符计数。
    await tester.enterText(_body(), '中👨‍👩‍👧‍👦e\u0301');
    await _settle(tester);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('note-composer-count')))
          .data,
      '3',
    );
    await tester.enterText(_body(), '玩儿玩儿2');
    await tester.tap(find.widgetWithText(TextField, '搜索笔记 · Ctrl+F'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('note-composer-count')), findsNothing);
    expect(
      (tester.widget<DecoratedBox>(surface).decoration as BoxDecoration)
          .border!
          .top
          .color,
      NoteComposerStyle.border,
    );
    expect(
      _composerButton(
        tester,
        tag,
      ).style!.foregroundColor!.resolve({WidgetState.hovered}),
      NoteComposerStyle.idleTool,
    );
    expect(
      _composerButton(tester, action).style!.backgroundColor!.resolve({}),
      OmniColors.of(tester.element(surface)).brand,
    );
    await _capture(tester, app, 'windows-composer-blurred-text');
    await tester.tap(action);
    await _settle(tester);
    expect(tester.widget<TextField>(_body()).controller!.text, isEmpty);
    expect(
      (await tester.runAsync(
        () => app.database.select(app.database.noteEntries).get(),
      ))!.single.body,
      '玩儿玩儿2',
    );
    expect(app.recorder.starts, 0);
    await mouse.removePointer();
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows 空白主操作点击启动录音且禁止重复启动', (tester) async {
    // 采集全部发生在替身设备，不访问系统麦克风。
    final _App app = await _mount(
      tester,
      platform: TargetPlatform.windows,
      initialLocation: '/notes',
      allowRecording: true,
    );
    expect(app.recorder.starts, 0);
    await tester.tap(find.byTooltip('开始录音'));
    await _settle(tester);
    expect(app.recorder.starts, 1);
    expect(app.recorder.state.isActive, isTrue);
    expect(find.byTooltip('开始录音'), findsNothing);
    expect(find.text('结束录音'), findsOneWidget);
    expect(find.text('开启自动转文字'), findsOneWidget);
    expect(find.byTooltip('发布'), findsOneWidget);
    expect(
      (await tester.runAsync(
        () => app.database.select(app.database.noteEntries).get(),
      ))!,
      isEmpty,
    );
    await tester.tap(find.text('结束录音'));
    await _settle(tester);
    expect(app.recorder.state.isActive, isFalse);
    expect(find.byTooltip('开始录音'), findsOneWidget);
    expect(app.recorder.starts, 1);
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows 纯录音草稿正文为空时显示发布并提升原音', (tester) async {
    // 临时目录只存放本用例生成的一秒静音 WAV。
    final Directory directory = Directory.systemTemp.createTempSync(
      'omni-composer-audio-',
    );
    addTearDown(() => directory.delete(recursive: true));
    // 只有测试生成的原音参与完整性预检。
    final File audio = File('${directory.path}/voice.wav');
    await tester.runAsync(
      () => audio.writeAsBytes([
        ...NoteWav.header(NoteWav.bytesPerSecond),
        ...List.filled(NoteWav.bytesPerSecond, 0),
      ]),
    );
    // 挂载前通过真实仓储建好草稿，避免框架假时钟与Drift事务互相等待。
    final _App app = await _mount(
      tester,
      platform: TargetPlatform.windows,
      initialLocation: '/notes',
      prepareDatabase: (database) async {
        // 准备过程仍走原音摘要和草稿归属验证。
        final NoteLocalDraftRepository drafts = NoteLocalDraftRepository(
          NoteRepository(database),
        );
        // 测试专属身份，不读取任何真实笔记。
        final NoteDraft draft = NoteDraft(
          id: 'composer-audio-note',
          body: '',
          dayKey: businessDayKey(DateTime.now()),
          baseRevision: '',
        );
        await drafts.save(
          id: 'composer-audio-draft',
          draft: draft,
          isNew: true,
        );
        await drafts.stageAudio(
          NoteRecordingResult(
            id: 'composer-audio',
            noteId: draft.id,
            draftId: 'composer-audio-draft',
            path: audio.path,
            duration: const Duration(seconds: 1),
            startedAt: DateTime.now(),
          ),
          draftId: 'composer-audio-draft',
          consent: false,
        );
      },
    );
    expect(tester.widget<TextField>(_body()).controller!.text, isEmpty);
    expect(find.byTooltip('发布'), findsOneWidget);
    expect(find.byTooltip('开始录音'), findsNothing);
    expect(find.textContaining('草稿录音 ·'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('note-commit')));
    // 原音发布包含多轮文件读取，交替刷新假时钟和真实I/O直到提交结束。
    for (int attempt = 0; attempt < 50; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      if (!app.container.read(noteEditorProvider).committing) break;
    }
    expect(app.container.read(noteEditorProvider).committing, isFalse);
    await _settle(tester);
    expect(
      (await tester.runAsync(
        () => app.database.select(app.database.noteEntries).get(),
      ))!.single.body,
      isEmpty,
    );
    expect(
      (await tester.runAsync(
        () => app.database.select(app.database.noteAudioSegments).get(),
      ))!.single.id,
      'composer-audio',
    );
    expect(find.byTooltip('开始录音'), findsOneWidget);
    expect(app.recorder.starts, 0);
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows 历史菜单保留版本记录入口', (tester) async {
    // 精简输入工具不应失去已有正式版本。
    final _App app = await _mount(
      tester,
      platform: TargetPlatform.windows,
      seed: true,
      initialLocation: '/notes',
    );
    // 指定原篇，避免误选其他历史卡片的同名菜单。
    final Finder card = find.byKey(const ValueKey('note-card-target'));
    await tester.tap(
      find.descendant(
        of: card,
        matching: find.byType(OmniPopupMenuButton<String>),
      ),
    );
    await _settle(tester, elapsed: const Duration(milliseconds: 350));
    await tester.tap(find.text('版本记录'));
    await _settle(tester);
    expect(find.text('版本记录'), findsOneWidget);
    expect(find.byTooltip('复制此版本'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await _settle(tester);
    expect(find.byTooltip('保存'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows 发布、双击展开与切回新笔记保留正式正文', (tester) async {
    // 新建内容在显式发布前只进入草稿。
    final _App app = await _mount(
      tester,
      platform: TargetPlatform.windows,
      seed: true,
    );
    await _navigate(tester, app, '/notes');
    await tester.enterText(_body(), '新的标题\n正文第一行\n正文第二行\n正文第三行');
    await _settle(tester, elapsed: const Duration(milliseconds: 700));
    await tester.ensureVisible(find.byKey(const ValueKey('note-commit')));
    await tester.tap(find.byKey(const ValueKey('note-commit')));
    await _settle(tester);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('note-count'))).data,
      '4',
    );
    // 持久身份用于断言卡片编辑没有新建第二篇笔记。
    final List<NoteEntryRecord> records = (await tester.runAsync(
      () => app.database.select(app.database.noteEntries).get(),
    ))!;
    final NoteEntryRecord added = records.firstWhere(
      (note) => note.body.startsWith('新的标题'),
    );
    final Finder card = find.byKey(ValueKey('note-card-${added.id}'));
    await tester.ensureVisible(card);
    await tester.tap(card);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(card);
    await _settle(tester);
    expect(find.byKey(const ValueKey('notes-composer-entry')), findsOneWidget);
    expect(find.byTooltip('保存'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    await tester.enterText(_body(), '尚未确认的修改');
    await _settle(tester, elapsed: const Duration(milliseconds: 700));
    await _capture(tester, app, 'windows-expanded-edit');
    await tester.ensureVisible(find.text('写新笔记'));
    await tester.tap(find.text('写新笔记'));
    await _settle(tester);
    expect(
      (await tester.runAsync(
        () => NoteRepository(app.database).find(added.id),
      ))!.body,
      '新的标题\n正文第一行\n正文第二行\n正文第三行',
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('note-count'))).data,
      '4',
    );
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows 外部定位清除筛选且远端删除冻结当前草稿', (tester) async {
    // 外部定位复用原有路由，不新建正式笔记。
    final _App app = await _mount(
      tester,
      platform: TargetPlatform.windows,
      seed: true,
    );
    await _navigate(tester, app, '/notes');
    await tester.enterText(
      find.widgetWithText(TextField, '搜索笔记 · Ctrl+F'),
      '不存在',
    );
    await _settle(tester);
    app.container.read(appRouterProvider).go('/notes?id=target');
    await _settle(tester);
    expect(
      tester.widget<TextField>(_body()).controller!.text,
      startsWith('今日日报目标'),
    );
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '搜索笔记 · Ctrl+F'))
          .controller!
          .text,
      isEmpty,
    );
    app.container.read(appRouterProvider).go('/notes?id=yesterday');
    await _settle(tester);
    expect(tester.widget<TextField>(_body()).controller!.text, '昨日日报');
    app.container.read(appRouterProvider).go('/notes?id=target');
    await _settle(tester);
    // 在尚未发布的人工修改存在时，删除仍及时冻结且保留正文。
    await tester.enterText(_body(), '删除前尚未发布的修改');
    await tester.runAsync(
      () => NoteRepository(app.database).softDelete('target'),
    );
    await _settle(tester);
    expect(tester.widget<TextField>(_body()).readOnly, isTrue);
    expect(tester.widget<TextField>(_body()).controller!.text, '删除前尚未发布的修改');
    // 同篇恢复后继续编辑原草稿，不覆盖人工内容。
    await tester.runAsync(() => NoteRepository(app.database).restore('target'));
    await _settle(tester);
    expect(tester.widget<TextField>(_body()).readOnly, isFalse);
    expect(tester.widget<TextField>(_body()).controller!.text, '删除前尚未发布的修改');
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows 整个侧栏悬停显示隐藏入口且恢复保留草稿和筛选', (tester) async {
    // 隐藏侧栏不能改变应用级编辑器和当前查询。
    final _App app = await _mount(
      tester,
      platform: TargetPlatform.windows,
      seed: true,
    );
    await _navigate(tester, app, '/notes');
    await tester.enterText(_body(), '隐藏侧栏时仍保留的草稿');
    await tester.tap(find.text('复盘').first);
    await _settle(tester);
    // 导航区及底部空白都属于侧栏，均应显示隐藏入口。
    final TestGesture mouse = await tester.createGesture(
      kind: ui.PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('回收站')));
    await tester.pump();
    expect(find.byTooltip('隐藏侧边栏').hitTestable(), findsOneWidget);
    // 整个可滚动侧栏视口，包含内容之后的空白。
    final Rect sidebar = tester.getRect(
      find.byKey(const ValueKey('notes-sidebar-region')),
    );
    await mouse.moveTo(Offset(sidebar.center.dx, sidebar.bottom - 10));
    await _settle(tester);
    expect(find.byTooltip('隐藏侧边栏').hitTestable(), findsOneWidget);
    // 顶部区域的左右留白同样响应悬停。
    final Rect overview = tester.getRect(
      find.byKey(const ValueKey('notes-sidebar-overview')),
    );
    await mouse.moveTo(Offset(overview.left + 2, overview.center.dy));
    await tester.pump();
    expect(find.byTooltip('隐藏侧边栏').hitTestable(), findsOneWidget);
    await _settle(tester);
    await _capture(tester, app, 'windows-sidebar-hover');
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('notes-search'))),
    );
    await tester.pump();
    expect(find.byTooltip('隐藏侧边栏').hitTestable(), findsNothing);
    await mouse.moveTo(overview.center);
    await tester.pump();
    await tester.tap(find.byTooltip('隐藏侧边栏'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('notes-sidebar')), findsNothing);
    expect(find.byKey(const ValueKey('notes-sidebar-divider')), findsNothing);
    expect(find.byTooltip('显示侧边栏'), findsOneWidget);
    expect(find.text('# 复盘'), findsOneWidget);
    expect(tester.widget<TextField>(_body()).controller!.text, '隐藏侧栏时仍保留的草稿');
    await _capture(tester, app, 'windows-sidebar-hidden');
    await tester.tap(find.byTooltip('显示侧边栏'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('notes-sidebar-width')), findsOneWidget);
    expect(find.byTooltip('显示侧边栏'), findsNothing);
    expect(find.byKey(const ValueKey('note-card-target')), findsOneWidget);
    expect(find.byKey(const ValueKey('note-card-yesterday')), findsNothing);
    await mouse.removePointer();
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows 分隔条悬停灰色按下主题色且宽度对应八至十二列', (tester) async {
    // 宽度改变不能移除今天所在周或清空输入。
    final _App app = await _mount(
      tester,
      platform: TargetPlatform.windows,
      seed: true,
    );
    await _navigate(tester, app, '/notes');
    await tester.enterText(_body(), '调整侧栏宽度时保留输入');
    // 拖动入口与实际侧栏尺寸。
    final Finder divider = find.byKey(const ValueKey('notes-sidebar-divider'));
    // 热力图的日格，不包含月份标签。
    final Finder cells = find.byWidgetPredicate(
      (widget) =>
          widget is InkWell &&
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith('note-heatmap-'),
    );
    // 悬停使用灰色，按下即刻变为主题色。
    final TestGesture mouse = await tester.createGesture(
      kind: ui.PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: tester.getCenter(divider));
    await tester.pump();
    expect(find.byKey(const ValueKey('notes-sidebar-drag-line')), findsNothing);
    expect(
      find.byKey(const ValueKey('notes-sidebar-hover-line')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<ColoredBox>(
            find.byKey(const ValueKey('notes-sidebar-hover-line')),
          )
          .color,
      OmniColors.of(tester.element(divider)).line,
    );
    // 移到主区或侧栏任意内容后，浅灰线立即消失。
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('notes-search'))),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('notes-sidebar-hover-line')),
      findsNothing,
    );
    await mouse.moveTo(tester.getCenter(find.text('回收站')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('notes-sidebar-hover-line')),
      findsNothing,
    );
    await mouse.moveTo(tester.getCenter(divider));
    await tester.pump();
    await _capture(tester, app, 'windows-divider-hover');
    await mouse.down(tester.getCenter(divider));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('notes-sidebar-drag-line')),
      findsOneWidget,
    );
    // 指示线上下各保留项目间距。
    final Rect bounds = tester.getRect(divider);
    // 实际绘制指示线的边界。
    final Rect line = tester.getRect(
      find.byKey(const ValueKey('notes-sidebar-drag-line')),
    );
    expect(line.top - bounds.top, OmniSpacing.xl);
    expect(bounds.bottom - line.bottom, OmniSpacing.xl);
    await mouse.moveBy(const Offset(30, 0));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('notes-sidebar-drag-line')),
      findsOneWidget,
    );
    await mouse.moveBy(const Offset(1000, 0));
    await tester.pump();
    expect(
      tester.getSize(find.byKey(const ValueKey('notes-sidebar-width'))).width,
      340,
    );
    expect(cells, findsNWidgets(84));
    await _capture(tester, app, 'windows-sidebar-drag');
    await mouse.up();
    await _settle(tester);
    expect(find.byKey(const ValueKey('notes-sidebar-drag-line')), findsNothing);
    await _capture(tester, app, 'windows-sidebar-max');
    await mouse.down(tester.getCenter(divider));
    await mouse.moveBy(const Offset(-30, 0));
    await tester.pump();
    await mouse.moveBy(const Offset(-1000, 0));
    await tester.pump();
    expect(
      tester.getSize(find.byKey(const ValueKey('notes-sidebar-width'))).width,
      220,
    );
    expect(cells, findsNWidgets(56));
    await mouse.cancel();
    await _settle(tester);
    expect(find.byKey(const ValueKey('notes-sidebar-drag-line')), findsNothing);
    expect(
      find.byKey(ValueKey('note-heatmap-${businessDayKey(DateTime.now())}')),
      findsOneWidget,
    );
    expect(tester.widget<TextField>(_body()).controller!.text, '调整侧栏宽度时保留输入');
    await _capture(tester, app, 'windows-sidebar-min');
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    await _settle(tester);
    // 对齐新增左留白后，最小宽度与大字号也必须完整显示四字标题。
    expect(
      tester.renderObject<RenderParagraph>(find.text('全部标签')).didExceedMaxLines,
      isFalse,
    );
    await _capture(tester, app, 'windows-sidebar-min-large');
    expect(tester.takeException(), isNull);
    tester.platformDispatcher.textScaleFactorTestValue = 1;
    await _settle(tester);
    // 中间宽度逐级增加列数。
    // 用真实尺寸校准手势识别阈值，验证每个中间宽度。
    for (final (double, int) step in [
      (250.0, 9),
      (280.0, 10),
      (310.0, 11),
      (340.0, 12),
    ]) {
      // 新手势先跨过识别阈值，再调整到目标宽度。
      final TestGesture drag = await tester.startGesture(
        tester.getCenter(divider),
      );
      await drag.moveBy(const Offset(20, 0));
      await tester.pump();
      // 当前真实侧栏宽度。
      final double width = tester
          .getSize(find.byKey(const ValueKey('notes-sidebar-width')))
          .width;
      await drag.moveBy(Offset(step.$1 - width, 0));
      await tester.pump();
      await drag.up();
      await tester.pump();
      expect(cells, findsNWidgets(step.$2 * 7));
    }
    await mouse.removePointer();
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows 隐藏侧栏后窄窗抽屉仍可用且宽窗恢复原宽度', (tester) async {
    // 隐藏状态不会阻止窄窗导航访问。
    final _App app = await _mount(
      tester,
      platform: TargetPlatform.windows,
      seed: true,
    );
    await _navigate(tester, app, '/notes');
    // 先把侧栏拖到最大宽度，再收起。
    final Finder divider = find.byKey(const ValueKey('notes-sidebar-divider'));
    await tester.drag(divider, const Offset(300, 0));
    await _settle(tester);
    // 鼠标悬停触发收起按钮。
    final TestGesture mouse = await tester.createGesture(
      kind: ui.PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('notes-sidebar-overview'))),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('隐藏侧边栏'));
    await _settle(tester);
    tester.view.physicalSize = const Size(700, 480);
    await _settle(tester);
    expect(find.byTooltip('笔记导航'), findsOneWidget);
    await tester.tap(find.byTooltip('笔记导航'));
    await _settle(tester);
    // 窄窗抽屉中菜单保留36dp热区，各侧栏行高继续一致。
    final Finder allRow = find.ancestor(
      of: find.text('全部笔记'),
      matching: find.byType(OmniListRow),
    );
    final Finder recycleRow = find.ancestor(
      of: find.text('回收站'),
      matching: find.byType(OmniListRow),
    );
    expect(tester.getSize(recycleRow).height, tester.getSize(allRow).height);
    for (final String id in ['work', 'review', 'unused']) {
      expect(
        tester
            .getSize(
              find.descendant(
                of: find.byKey(ValueKey('notes-tag-$id')),
                matching: find.byType(OmniListRow),
              ),
            )
            .height,
        tester.getSize(allRow).height,
      );
    }
    expect(find.byKey(const ValueKey('notes-sidebar')), findsOneWidget);
    await tester.ensureVisible(find.text('复盘').first);
    await _settle(tester);
    await tester.tap(find.text('复盘').first);
    await _settle(tester);
    expect(find.text('# 复盘'), findsOneWidget);
    tester.view.physicalSize = const Size(1280, 900);
    await _settle(tester);
    expect(find.byKey(const ValueKey('notes-sidebar-width')), findsNothing);
    await tester.tap(find.byTooltip('显示侧边栏'));
    await _settle(tester);
    expect(
      tester.getSize(find.byKey(const ValueKey('notes-sidebar-width'))).width,
      340,
    );
    expect(find.byKey(const ValueKey('note-card-target')), findsOneWidget);
    expect(find.byKey(const ValueKey('note-card-yesterday')), findsNothing);
    await mouse.removePointer();
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows 侧栏收起展开连续移动且允许中途反向恢复', (tester) async {
    // 完整生产页面验证主区随侧栏同步移动，编辑器保持同一实例。
    final _App app = await _mount(
      tester,
      platform: TargetPlatform.windows,
      seed: true,
    );
    await _navigate(tester, app, '/notes');
    await tester.enterText(_body(), '侧栏动画中保留的正文');
    await _settle(tester);
    // 同一编辑控制器不能在过渡中被替换。
    final TextEditingController body = tester
        .widget<TextField>(_body())
        .controller!;
    // 主区的左右端点及动效占位。
    final Finder main = find.byKey(const ValueKey('notes-main-scroll'));
    // 完整侧栏占位包含拖动热区。
    final Finder transition = find.byKey(
      const ValueKey('notes-sidebar-transition'),
    );
    // 收起前主区起点。
    final double expandedLeft = tester.getTopLeft(main).dx;
    // 鼠标进入顶部以激活收起。
    final TestGesture mouse = await tester.createGesture(
      kind: ui.PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('notes-sidebar-overview'))),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('隐藏侧边栏'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    // 中间帧应保留非零占位且主区已向左移动。
    final double closingWidth = tester.getSize(transition).width;
    expect(closingWidth, greaterThan(0));
    expect(closingWidth, lessThan(264 + OmniSpacing.xs));
    expect(tester.getTopLeft(main).dx, lessThan(expandedLeft));
    await _capture(tester, app, 'windows-sidebar-closing');
    // 切换目标后保持当前呈现宽度，不跳回起点。
    await tester.tap(find.byTooltip('显示侧边栏'));
    await tester.pump();
    expect(tester.getSize(transition).width, closeTo(closingWidth, 0.01));
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.getSize(transition).width, greaterThan(closingWidth));
    await _capture(tester, app, 'windows-sidebar-reopening');
    await _settle(tester);
    expect(tester.getTopLeft(main).dx, expandedLeft);
    expect(tester.widget<TextField>(_body()).controller, same(body));
    expect(body.text, '侧栏动画中保留的正文');
    // 完整收起后内容立即不可聚焦或点击。
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('notes-sidebar-overview'))),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('隐藏侧边栏'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('notes-sidebar')), findsNothing);
    expect(tester.getTopLeft(main).dx, lessThan(expandedLeft));
    await mouse.removePointer();
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows 热图空日期只放大，有笔记日期提示并主题发光', (tester) async {
    // 热图互动始终以正式笔记日期为事实来源。
    final _App app = await _mount(
      tester,
      platform: TargetPlatform.windows,
      seed: true,
    );
    await _navigate(tester, app, '/notes');
    // 固定选取两周前的周一，保证邻格永远在同一列。
    final DateTime now = DateTime.now();
    // 没有笔记的过去日期，不依赖测试执行时的星期。
    final DateTime emptyDate = DateTime(
      now.year,
      now.month,
      now.day - now.weekday + 1 - 14,
    );
    // 空日期的稳定业务身份。
    final String emptyDay = businessDayKey(emptyDate);
    // 有两篇正式笔记的今天。
    final String filledDay = businessDayKey(DateTime.now());
    // 原始日期点击热区。
    final Finder empty = find.byKey(ValueKey('note-heatmap-$emptyDay'));
    // 鼠标使用真实桌面悬停路径。
    final TestGesture mouse = await tester.createGesture(
      kind: ui.PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(empty));
    await tester.pump();
    // 实际绘制的缩放随时间变化，不改变相邻格的布局。
    final Finder scale = find.byKey(ValueKey('note-day-scale-$emptyDay'));
    // 布局中的基础方块尺寸。
    final double size = tester.getSize(empty).width;
    expect(size, lessThan(20));
    // 紧邻的日期距当前日期至少有8dp间隔。
    final String neighborDay = businessDayKey(
      DateTime(emptyDate.year, emptyDate.month, emptyDate.day + 1),
    );
    final Rect emptyRect = tester.getRect(empty);
    final Rect neighborRect = tester.getRect(
      find.byKey(ValueKey('note-heatmap-$neighborDay')),
    );
    expect(neighborRect.top - emptyRect.bottom, closeTo(8, 0.01));
    await tester.pump(const Duration(milliseconds: 50));
    // 正在执行缩放的变换。
    final Transform intermediate = tester.widget<Transform>(
      find.descendant(of: scale, matching: find.byType(Transform)).first,
    );
    expect(intermediate.transform.storage[0], greaterThan(1));
    expect(intermediate.transform.storage[0], lessThan(1.2));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<AnimatedScale>(scale).scale, 1.2);
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.click,
    );
    expect(
      find.ancestor(of: empty, matching: find.byType(Tooltip)),
      findsNothing,
    );
    // 空格没有主题光晕，点击不改变筛选或历史集合。
    final BoxDecoration emptyFill =
        tester
                .widget<AnimatedContainer>(
                  find.byKey(ValueKey('note-day-fill-$emptyDay')),
                )
                .decoration!
            as BoxDecoration;
    expect(emptyFill.boxShadow, isEmpty);
    await tester.tap(empty);
    await _settle(tester);
    expect(find.byKey(const ValueKey('note-card-yesterday')), findsOneWidget);
    expect(find.byKey(const ValueKey('note-card-target')), findsOneWidget);
    await _capture(tester, app, 'windows-heatmap-empty-hover');
    await mouse.moveTo(
      tester.getCenter(find.byKey(ValueKey('note-heatmap-$filledDay'))),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    // 提示的出现计时完成后，再推进淡入与实际绘制动画。
    await tester.pump(const Duration(milliseconds: 200));
    // 有笔记日期的光晕及边框使用实际主题主色。
    final BoxDecoration filled =
        tester
                .widget<AnimatedContainer>(
                  find.byKey(ValueKey('note-day-fill-$filledDay')),
                )
                .decoration!
            as BoxDecoration;
    expect(filled.border, isNotNull);
    expect(filled.boxShadow, hasLength(1));
    expect(
      filled.boxShadow!.single.color.withValues(alpha: 1),
      filled.border!.top.color,
    );
    expect(find.text('$filledDay · 2 篇笔记'), findsOneWidget);
    // 检验当前绘制的光晕，而不只检查动画目标配置。
    final BoxDecoration painted =
        tester
                .widget<DecoratedBox>(
                  find
                      .descendant(
                        of: find.byKey(ValueKey('note-day-fill-$filledDay')),
                        matching: find.byType(DecoratedBox),
                      )
                      .first,
                )
                .decoration
            as BoxDecoration;
    expect(painted.boxShadow!.single.color.a, greaterThan(0));
    await _capture(tester, app, 'windows-heatmap-filled-hover');
    await tester.tap(find.byKey(ValueKey('note-heatmap-$filledDay')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('note-card-yesterday')), findsNothing);
    await mouse.moveTo(tester.getCenter(empty));
    await _settle(tester);
    await tester.tap(empty);
    await _settle(tester);
    expect(find.byKey(const ValueKey('note-card-yesterday')), findsNothing);
    expect(find.byKey(const ValueKey('note-card-target')), findsOneWidget);
    // 离开有效格后光晕收回，空点击不撤销已有筛选。
    expect(
      tester
          .widget<AnimatedScale>(
            find.byKey(ValueKey('note-day-scale-$filledDay')),
          )
          .scale,
      1,
    );
    expect(
      (tester
                  .widget<AnimatedContainer>(
                    find.byKey(ValueKey('note-day-fill-$filledDay')),
                  )
                  .decoration!
              as BoxDecoration)
          .boxShadow,
      isEmpty,
    );
    await mouse.removePointer();
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows 减少动画时侧栏即时收起且热图只保留颜色反馈', (tester) async {
    // 启动前设置减少动画，避免触发无关预载首页的动态动画问题。
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    // 冷启动生产笔记分支。
    final _App app = await _mount(
      tester,
      platform: TargetPlatform.windows,
      seed: true,
      initialLocation: '/notes',
    );
    // 有正式记录的业务日期。
    final String today = businessDayKey(DateTime.now());
    // 单个热图日期的鼠标。
    final TestGesture mouse = await tester.createGesture(
      kind: ui.PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.byKey(ValueKey('note-heatmap-$today'))),
    );
    await tester.pump();
    expect(
      tester
          .widget<AnimatedScale>(find.byKey(ValueKey('note-day-scale-$today')))
          .scale,
      1,
    );
    expect(
      (tester
                  .widget<AnimatedContainer>(
                    find.byKey(ValueKey('note-day-fill-$today')),
                  )
                  .decoration!
              as BoxDecoration)
          .boxShadow,
      isNotEmpty,
    );
    await tester.tap(find.byTooltip('隐藏侧边栏'));
    await tester.pump();
    expect(find.byKey(const ValueKey('notes-sidebar')), findsNothing);
    await tester.tap(find.byTooltip('显示侧边栏'));
    await tester.pump();
    expect(
      tester
          .getSize(find.byKey(const ValueKey('notes-sidebar-transition')))
          .width,
      264 + OmniSpacing.xs,
    );
    await mouse.removePointer();
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows 三项统计对齐及中文月份不显示说明文字', (tester) async {
    // 检验真实排版位置，而不只断言控件配置。
    final _App app = await _mount(
      tester,
      platform: TargetPlatform.windows,
      seed: true,
    );
    await _navigate(tester, app, '/notes');
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('note-count'))).dx,
      tester.getTopLeft(find.text('笔记').first).dx,
    );
    expect(
      tester.getCenter(find.byKey(const ValueKey('tag-count'))).dx,
      tester.getCenter(find.text('标签').first).dx,
    );
    expect(
      tester.getBottomRight(find.byKey(const ValueKey('day-count'))).dx,
      tester.getBottomRight(find.text('天')).dx,
    );
    expect(find.textContaining('近 13 周'), findsNothing);
    expect(find.textContaining(RegExp(r'^\d+月$')), findsNothing);
    expect(find.textContaining(RegExp(r'^[一二三四五六七八九十]+月$')), findsWidgets);
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows 短窄窗与放大文字保留导航和搜索且不溢出', (tester) async {
    // 真实桌面密度在窄窗仍保留图标轨与抽屉入口。
    final _App app = await _mount(
      tester,
      platform: TargetPlatform.windows,
      seed: true,
      prepareDatabase: (database) async {
        // 长名称不能因换行把标签行撑高。
        await (database.update(
          database.taxonomyEntries,
        )..where((table) => table.id.equals('unused'))).write(
          const TaxonomyEntriesCompanion(name: Value('这是一个需要在侧栏中省略显示的长标签名称')),
        );
      },
    );
    await _navigate(tester, app, '/notes');
    tester.view.physicalSize = const Size(700, 480);
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    await _settle(tester);
    expect(find.byTooltip('笔记导航'), findsOneWidget);
    expect(find.byKey(const ValueKey('notes-search')), findsOneWidget);
    await _capture(tester, app, 'windows-narrow-large');
    await tester.tap(find.byTooltip('笔记导航'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('notes-sidebar')), findsOneWidget);
    // 放大字号、长名称与菜单共同参与实际布局，全部笔记是行高基准。
    final List<OmniListRow> rows = tester
        .widgetList<OmniListRow>(
          find.descendant(
            of: find.byKey(const ValueKey('notes-sidebar')),
            matching: find.byType(OmniListRow),
          ),
        )
        .toList();
    // 首个列表项即全部笔记，其余标签和回收站须完全一致。
    final double height = tester.getSize(find.byWidget(rows.first)).height;
    for (final OmniListRow row in rows.skip(1)) {
      expect(tester.getSize(find.byWidget(row)).height, height);
    }
    await tester.ensureVisible(find.text('回收站'));
    await _settle(tester);
    await _capture(tester, app, 'windows-narrow-drawer');
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows 减少动画冷启动直接展开原位编辑器', (tester) async {
    // 系统偏好在应用启动前已生效，避免无关预载首页的动态动画重布局。
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    // 直接进入真实笔记分支，使用生产页面与应用主题。
    final _App app = await _mount(
      tester,
      platform: TargetPlatform.windows,
      seed: true,
      initialLocation: '/notes',
    );
    final Finder card = find.byKey(const ValueKey('note-card-target'));
    await tester.ensureVisible(card);
    await tester.tap(card);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(card);
    await _settle(tester);
    expect(find.byTooltip('保存'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('notes-main-scroll')),
        matching: find.byType(AnimatedSize),
      ),
      findsNothing,
    );
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  // 两端主题截图均来自实际生产根组件。
  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.android,
  ]) {
    for (final String theme in <String>['light', 'dark']) {
      testWidgets('${platform.name} $theme 生产笔记页截图', (tester) async {
        // 当前截图的主题和布局环境。
        final _App app = await _mount(
          tester,
          platform: platform,
          theme: theme,
          seed: true,
        );
        await _navigate(tester, app, '/notes');
        await tester.enterText(
          _body(),
          '记录此刻的想法\n\n今天完成了第一轮验证。把临时想法写下来，之后再整理成日报或周报。',
        );
        await _settle(tester, elapsed: const Duration(milliseconds: 700));
        await _capture(tester, app, '${platform.name}-$theme');
        expect(app.recorder.starts, 0);
        await _dispose(tester, app);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final AppThemePalette palette in AppThemePalette.values) {
    for (final String theme in <String>['light', 'dark']) {
      testWidgets('Windows ${palette.id} $theme 生产笔记页截图', (tester) async {
        // 生产主题与虚构数据覆盖全部明暗配色组合。
        final _App app = await _mount(
          tester,
          platform: TargetPlatform.windows,
          palette: palette,
          theme: theme,
          seed: true,
        );
        await _navigate(tester, app, '/notes');
        // 麦克风与发布都使用当前主题色及缩小后的真实尺寸。
        final Finder action = find.byKey(const ValueKey('note-commit'));
        final OmniColors colors = OmniColors.of(tester.element(action));
        expect(
          _composerButton(tester, action).style!.backgroundColor!.resolve({}),
          colors.brand,
        );
        expect(tester.getSize(action), const Size(48, 30));
        await tester.enterText(
          _body(),
          '记录此刻的想法\n\n今天完成了第一轮验证。把临时想法写下来，之后再整理成日报或周报。',
        );
        await _settle(tester, elapsed: const Duration(milliseconds: 700));
        expect(
          _composerButton(tester, action).style!.backgroundColor!.resolve({}),
          colors.brand,
        );
        expect(
          (tester
                      .widget<DecoratedBox>(
                        find.byKey(const ValueKey('note-composer-surface')),
                      )
                      .decoration
                  as BoxDecoration)
              .border!
              .top
              .color,
          colors.brand,
        );
        await _capture(tester, app, 'windows-${palette.id}-$theme');
        expect(app.recorder.starts, 0);
        await _dispose(tester, app);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('Windows 正文展开动画及唯一展开状态独立于编辑', (tester) async {
    // 两篇均超过两行，动画改变卡片真实高度。
    final _App app = await _mount(
      tester,
      platform: TargetPlatform.windows,
      seed: true,
      initialLocation: '/notes',
      prepareDatabase: (database) async {
        await (database.update(
          database.noteEntries,
        )..where((table) => table.id.equals('yesterday'))).write(
          const NoteEntriesCompanion(
            body: Value('昨日日报\n第一行\n第二行\n第三行\n第四行\n第五行'),
          ),
        );
      },
    );
    // 只读正文不创建历史输入框。
    final Finder toggle = find.byKey(const ValueKey('note-body-toggle-target'));
    final Finder expansion = find.byKey(
      const ValueKey('note-body-expansion-target'),
    );
    await tester.ensureVisible(toggle);
    await _settle(tester);
    final double closed = tester.getSize(expansion).height;
    final TextButton button = tester.widget(
      find.descendant(of: toggle, matching: find.byType(TextButton)),
    );
    final OmniColors colors = OmniColors.of(tester.element(toggle));
    expect(button.style!.foregroundColor!.resolve({}), NoteComposerStyle.muted);
    expect(
      button.style!.foregroundColor!.resolve({WidgetState.hovered}),
      colors.brand,
    );
    expect(
      button.style!.backgroundColor!.resolve({WidgetState.hovered}),
      Colors.transparent,
    );
    expect(button.style!.mouseCursor!.resolve({}), SystemMouseCursors.click);
    await _capture(tester, app, 'windows-body-collapsed');
    // 指针进入小号入口后只改变文字颜色。
    final TestGesture mouse = await tester.createGesture(
      kind: ui.PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(toggle));
    await _settle(tester);
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.click,
    );
    await _capture(tester, app, 'windows-body-hover');
    await mouse.removePointer();
    await tester.tap(toggle);
    // 单击识别窗口结束后，读取高度动画中间帧。
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 70));
    final double middle = tester.getSize(expansion).height;
    expect(middle, greaterThan(closed));
    await tester.pumpAndSettle();
    final double opened = tester.getSize(expansion).height;
    expect(opened, greaterThan(middle));
    expect(tester.widget<TextField>(_body()).controller!.text, isEmpty);
    await _capture(tester, app, 'windows-body-expanded');
    // 再次点击逐帧收起，而不是直接移除正文。
    await tester.tap(toggle);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 70));
    expect(tester.getSize(expansion).height, greaterThan(closed));
    expect(tester.getSize(expansion).height, lessThan(opened));
    await tester.pumpAndSettle();
    expect(tester.getSize(expansion).height, closed);
    await tester.tap(toggle);
    await _settle(tester, elapsed: const Duration(milliseconds: 350));
    final Finder other = find.byKey(
      const ValueKey('note-body-toggle-yesterday'),
    );
    await tester.ensureVisible(other);
    await tester.tap(other);
    await _settle(tester, elapsed: const Duration(milliseconds: 350));
    expect(tester.getSize(expansion).height, closed);
    expect(
      find.descendant(of: toggle, matching: find.text('展开')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: other, matching: find.text('收起')),
      findsOneWidget,
    );
    await _capture(tester, app, 'windows-body-switched');
    // 减少动画设置直接跳到最终高度。
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pump();
    expect(
      tester.widget<TweenAnimationBuilder<double>>(expansion).duration,
      Duration.zero,
    );
    await tester.tap(other);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(
      find.descendant(of: other, matching: find.text('展开')),
      findsOneWidget,
    );
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows 收缩笔记原音归属、灰色时间菜单及展开预览', (tester) async {
    // 使用真实测试 WAV，不读取用户录音。
    final Directory directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('notes-history-preview-'),
    ))!;
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    // 原音字节与测试数据库摘要保持一致。
    final List<int> bytes = [
      ...NoteWav.header(NoteWav.bytesPerSecond * 18),
      ...List.filled(NoteWav.bytesPerSecond * 18, 0),
    ];
    final File file = File('${directory.path}/original.wav');
    await tester.runAsync(() => file.writeAsBytes(bytes));
    // 必须挂载前准备Drift数据，避免假时钟阻塞异步文件检查。
    final _App app = await _mount(
      tester,
      platform: TargetPlatform.windows,
      seed: true,
      prepareDatabase: (database) async {
        await (database.update(
          database.noteAudioSegments,
        )..where((table) => table.id.equals('audio-target'))).write(
          NoteAudioSegmentsCompanion(
            sha256: Value(sha256.convert(bytes).toString()),
            transcript: const Value('我现在要测试一下，这段录音会保留原始文字。'),
          ),
        );
        await database
            .into(database.noteAudioLocalFiles)
            .insert(
              NoteAudioLocalFilesCompanion.insert(
                id: 'audio-target',
                localPath: Value(file.path),
              ),
            );
      },
    );
    await _navigate(tester, app, '/notes');
    await _settle(tester);
    // 音频归属历史笔记，而当前新建编辑器没有此片段。
    final Finder bar = find.byKey(
      const ValueKey('note-audio-bar-audio-target'),
    );
    expect(bar, findsOneWidget);
    // 收缩卡片保留圆角表面，实际Material轮廓不绘制描边。
    final Finder historyPanel = find.descendant(
      of: find.byKey(const ValueKey('note-card-target')),
      matching: find.byType(OmniPanel),
    );
    final Material historyMaterial = tester.widget(
      find.descendant(of: historyPanel, matching: find.byType(Material)).first,
    );
    expect(
      (historyMaterial.shape! as RoundedRectangleBorder).side,
      BorderSide.none,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('note-card-target')),
        matching: bar,
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('note-composer-surface')),
        matching: bar,
      ),
      findsNothing,
    );
    final Text timestamp = tester.widget(
      find.byKey(const ValueKey('note-created-target')),
    );
    expect(timestamp.style!.fontSize, 10);
    expect(timestamp.style!.color, NoteComposerStyle.muted);
    await tester.ensureVisible(bar);
    await _settle(tester);
    await _waitOriginalAudio(tester);
    await _capture(tester, app, 'windows-audio-collapsed');
    await tester.tap(
      find.byKey(const ValueKey('note-audio-expand-audio-target')),
    );
    // 历史卡片支持双击编辑，推进其单击识别窗口后验证内部操作。
    await _settle(tester, elapsed: const Duration(milliseconds: 350));
    expect(find.text('收起'), findsOneWidget);
    expect(find.text('重新识别').hitTestable(), findsOneWidget);
    await _capture(tester, app, 'windows-audio-expanded');
    // 只验证下载按钮的悬停外观，不打开真实文件保存窗口。
    final TestGesture mouse = await tester.createGesture(
      kind: ui.PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(
        find.byKey(const ValueKey('note-audio-download-audio-target')),
      ),
    );
    await _settle(tester);
    await _capture(tester, app, 'windows-audio-download-hover');
    // 更多菜单继承灰色至黑色的实际图标样式及手形指针。
    final Finder menu = find.descendant(
      of: find.byKey(const ValueKey('note-menu-target')),
      matching: find.byType(IconButton),
    );
    final IconButton button = tester.widget(menu);
    final OmniColors colors = OmniColors.of(tester.element(menu));
    expect(button.style!.foregroundColor!.resolve({}), colors.muted);
    expect(
      button.style!.foregroundColor!.resolve({WidgetState.hovered}),
      colors.ink,
    );
    await mouse.moveTo(tester.getCenter(menu));
    await _settle(tester);
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.click,
    );
    await mouse.removePointer();
    // 双击进入编辑后沿用同款音频条，保存旁增加取消。
    final Finder card = find.byKey(const ValueKey('note-card-target'));
    await tester.ensureVisible(card);
    await tester.tap(card);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(card);
    await _settle(tester);
    expect(tester.getSize(bar).height, 48);
    expect(find.byKey(const ValueKey('note-edit-cancel')), findsOneWidget);
    await _waitOriginalAudio(tester);
    await tester.tap(_body());
    await _settle(tester);
    await _capture(tester, app, 'windows-edit-audio-collapsed');
    await tester.ensureVisible(bar);
    await tester.tap(
      find.byKey(const ValueKey('note-audio-expand-audio-target')),
    );
    await _settle(tester);
    expect(find.text('插入正文').hitTestable(), findsOneWidget);
    expect(find.text('删除录音').hitTestable(), findsOneWidget);
    await tester.tap(_body());
    await _settle(tester);
    await _capture(tester, app, 'windows-edit-audio-expanded');
    // 正文插入仅修改本机草稿，取消不消费正式录音文字。
    final String original = app.container.read(noteEditorProvider).draft.body;
    await tester.tap(find.text('插入正文'));
    await _settle(tester);
    expect(
      app.container.read(noteEditorProvider).draft.body,
      contains('这段录音会保留原始文字'),
    );
    await tester.ensureVisible(find.byKey(const ValueKey('note-edit-cancel')));
    await tester.tap(find.byKey(const ValueKey('note-edit-cancel')));
    await _settle(tester);
    expect(
      (await tester.runAsync(
        () => NoteRepository(app.database).find('target'),
      ))!.body,
      original,
    );
    expect(find.byKey(const ValueKey('note-edit-cancel')), findsNothing);
    // 删除按钮立即隐藏草稿片段；取消重新显示正式原音。
    await tester.ensureVisible(card);
    await tester.tap(card);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(card);
    await _settle(tester);
    await tester.ensureVisible(bar);
    await tester.tap(
      find.byKey(const ValueKey('note-audio-expand-audio-target')),
    );
    await _settle(tester);
    await tester.tap(find.text('删除录音'));
    await _settle(tester);
    expect(bar, findsNothing);
    expect(
      (await tester.runAsync(
        () => app.database.select(app.database.noteAudioSegments).get(),
      ))!,
      hasLength(1),
    );
    await tester.ensureVisible(find.byKey(const ValueKey('note-edit-cancel')));
    await tester.tap(find.byKey(const ValueKey('note-edit-cancel')));
    await _settle(tester);
    expect(bar, findsOneWidget);
    await _waitOriginalAudio(tester);
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('320宽与1.6字号的编辑历史无溢出', (tester) async {
    // 保存框架处理器，打印完整溢出位置供修复定位。
    final FlutterExceptionHandler? previousErrorHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('RenderFlex overflowed')) {
        debugPrint(details.toString());
      }
      previousErrorHandler?.call(details);
    };
    addTearDown(() => FlutterError.onError = previousErrorHandler);
    // 最窄支持尺寸与放大字号。
    final _App app = await _mount(tester, seed: true);
    await _navigate(tester, app, '/notes');
    tester.view.physicalSize = const Size(320, 844);
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    await _settle(tester);
    await _capture(tester, app, 'android-320-large-editor');
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('查看历史'));
    await _settle(tester);
    await _capture(tester, app, 'android-320-large-history');
    FlutterError.onError = previousErrorHandler;
    await _dispose(tester, app);
    expect(tester.takeException(), isNull);
  });
}

/// 交替刷新真实文件读取和测试时钟，排空SHA流并释放Windows原件句柄。
Future<void> _waitOriginalAudio(WidgetTester tester) async {
  for (int attempt = 0; attempt < 50; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    if (find.byTooltip('正在检查原音').evaluate().isEmpty) break;
  }
  expect(find.byTooltip('正在检查原音'), findsNothing);
}

/// 定位正文，避免误输入应用的搜索框。
Finder _body() => find.byWidgetPredicate(
  (widget) =>
      widget is TextField &&
      (widget.decoration?.hintText?.startsWith('记下此刻') == true ||
          widget.decoration?.hintText == '现在的想法是...'),
);

/// 读取实际交给 Flutter 的按钮样式，避免只检查包装组件配置。
IconButton _composerButton(WidgetTester tester, Finder button) =>
    tester.widget<IconButton>(
      find.descendant(of: button, matching: find.byType(IconButton)),
    );

/// 将真实数据库异步事件与动画帧排空。
Future<void> _settle(
  WidgetTester tester, {
  Duration elapsed = Duration.zero,
}) async {
  await tester.pump(elapsed);
  // 每轮允许真实Drift异步工作完成，再刷新对应画面。
  for (int index = 0; index < 5; index++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

/// 通过生产一级导航进入目标分支。
Future<void> _navigate(WidgetTester tester, _App app, String path) async {
  await tester.tap(find.byKey(ValueKey<String>('navigation-$path')));
  await _settle(tester);
  expect(app.routerPath, path);
}

/// 测试持有的全部资源。
class _App {
  /// 当前数据库。
  final AppDatabase database;

  /// 当前生产依赖容器。
  final ProviderContainer container;

  /// 无原生设备的录音替身。
  final _Recorder recorder;

  /// 全页面截图边界。
  final GlobalKey boundary;

  /// 聚合测试资源。
  _App(this.database, this.container, this.recorder, this.boundary);

  /// 避免正常路径与失败兜底重复释放。
  bool disposed = false;

  /// 当前真实路由。
  String get routerPath =>
      container.read(appRouterProvider).routeInformationProvider.value.uri.path;
}

/// 构造两端生产应用，不替换数据库、编辑器或路由。
Future<_App> _mount(
  WidgetTester tester, {
  TargetPlatform platform = TargetPlatform.android,
  String theme = 'light',
  AppThemePalette palette = AppThemePalette.classicBlue,
  double width = 390,
  double scale = 1,
  bool seed = false,
  String initialLocation = '/home',
  bool allowRecording = false,
  Future<void> Function(AppDatabase)? prepareDatabase,
}) async {
  debugDefaultTargetPlatformOverride = platform;
  tester.view.physicalSize = Size(
    platform == TargetPlatform.windows ? 1280 : width,
    platform == TargetPlatform.windows ? 900 : 844,
  );
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  SharedPreferences.setMockInitialValues(<String, Object>{
    'appearance.theme_mode': theme,
    'appearance.theme_palette': palette.id,
    'sync.enabled': false,
  });
  // 不访问真实偏好存储。
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  // 实际Drift schema和事务。
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  if (seed) await tester.runAsync(() => _seed(database));
  if (prepareDatabase != null) {
    await tester.runAsync(() => prepareDatabase(database));
  }
  // 音频入口全部在无设备替身上执行。
  final _Recorder recorder = _Recorder()..allowRecording = allowRecording;
  // 生产应用容器。
  final ProviderContainer container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      appDatabaseProvider.overrideWithValue(database),
      noteRecorderProvider.overrideWithValue(recorder),
      noteAudioPlayerProvider.overrideWithValue(_Player()),
    ],
  );
  // 用于保存完整应用截图。
  final GlobalKey boundary = GlobalKey();
  final _App app = _App(database, container, recorder, boundary);
  addTearDown(() => _dispose(tester, app));
  if (initialLocation != '/home') {
    container.read(appRouterProvider).go(initialLocation);
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(key: boundary, child: const OmniButlerApp()),
    ),
  );
  await _settle(tester);
  return app;
}

/// 测试正常结束前释放全应用，失败时由tearDown补偿。
Future<void> _dispose(WidgetTester tester, _App app) async {
  if (app.disposed) return;
  app.disposed = true;
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  app.container.dispose();
  await app.recorder.dispose();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.runAsync(app.database.close);
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
  tester.platformDispatcher.clearTextScaleFactorTestValue();
  debugDefaultTargetPlatformOverride = null;
}

/// 真实仓储插入有效分类与记录，覆盖筛选维度。
Future<void> _seed(AppDatabase database) async {
  // 日期使用页面相同的本机自然日规则。
  final DateTime now = DateTime.now();
  // 分类与标签的测试身份。
  for (final (String, String, String) item in <(String, String, String)>[
    ('work', 'tag', '工作'),
    ('review', 'tag', '复盘'),
    ('unused', 'tag', '灵感'),
  ]) {
    await database
        .into(database.taxonomyEntries)
        .insert(
          TaxonomyEntriesCompanion.insert(
            id: item.$1,
            module: 'notes',
            kind: item.$2,
            name: item.$3,
            colorValue: 0xff6280ff,
            createdAt: now,
            updatedAt: now,
          ),
        );
  }
  // 每一篇记录都经过生产保存约束。
  for (final (String, String, DateTime, String, Set<String>) item
      in <(String, String, DateTime, String, Set<String>)>[
        (
          'target',
          '今日日报目标\n把笔记入口收拢到一个连续的工作区，随时记下文字或录音。\n今天完成布局，明天继续验证细节。\n这一行在收起的卡片中应当隐藏。',
          now,
          'daily',
          <String>{'work', 'review'},
        ),
        (
          'yesterday',
          '昨日日报',
          now.subtract(const Duration(days: 1)),
          'daily',
          <String>{'work'},
        ),
        (
          'weekly-note',
          '今日周报\n这周保留三个值得继续追踪的想法。\n先记录，再整理。',
          now,
          'weekly',
          <String>{'review'},
        ),
      ]) {
    await NoteRepository(database).save(
      NoteDraft(
        id: item.$1,
        body: item.$2,
        dayKey: businessDayKey(item.$3),
        baseRevision: '',
        tags: item.$5,
      ),
    );
  }
  await database
      .into(database.noteAudioSegments)
      .insert(
        NoteAudioSegmentsCompanion.insert(
          id: 'audio-target',
          noteId: 'target',
          sortOrder: 0,
          durationMs: 18000,
          mime: 'audio/wav',
          sha256: '0' * 64,
          byteSize: 576044,
          transcript: const Value('语音验收通过'),
          createdAt: now,
          updatedAt: now,
        ),
      );
}

/// 开启环境变量才导出截图，普通回归不写产物。
Future<void> _capture(WidgetTester tester, _App app, String name) async {
  // 可复现截图输出开关。
  final String? output = Platform.environment['OMNI_NOTES_PREVIEW'];
  if (output == null) return;
  // 当前生产应用完整渲染边界。
  final RenderRepaintBoundary boundary =
      app.boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    // 无损当前页面像素。
    final ui.Image image = await boundary.toImage();
    try {
      // PNG像素内容。
      final ByteData? bytes = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      await Directory(output).create(recursive: true);
      await File('$output/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

/// 永不触碰系统麦克风的替身。
class _Recorder implements NoteRecorderService {
  /// 检测意外自动录音。
  int starts = 0;

  /// 只有明确验证录音交互的用例允许启动替身。
  bool allowRecording = false;

  /// 无设备录音状态，由测试入口驱动。
  NoteRecordingState _state = const NoteRecordingState();

  /// 让生产页面收到替身设备的状态变化。
  final StreamController<NoteRecordingState> _states =
      StreamController.broadcast();

  /// 默认空闲，只有明确的测试点击才进入模拟采集。
  @override
  NoteRecordingState get state => _state;

  /// 广播模拟采集状态供生产页面订阅。
  @override
  Stream<NoteRecordingState> get states => _states.stream;

  /// 无原音完成事件。
  @override
  Stream<NoteRecordingResult> get completed => const Stream.empty();

  /// 无通知导航事件。
  @override
  Stream<String> get returnRequests => const Stream.empty();

  /// 默认阻止意外启动，录音专项用例只启动替身。
  @override
  Future<void> start(
    String noteId, {
    Duration remaining = const Duration(minutes: 60),
    String? draftId,
  }) async {
    starts++;
    if (!allowRecording) throw StateError('页面测试不允许启动录音');
    _state = NoteRecordingState(
      phase: NoteRecordingPhase.recording,
      noteId: noteId,
      draftId: draftId,
    );
    _states.add(_state);
  }

  /// 初始化不需要平台通道。
  @override
  Future<void> initialize() async {}

  /// 没有未恢复原件。
  @override
  Future<List<NoteRecordingResult>> recoverPending() async =>
      <NoteRecordingResult>[];

  /// 页面测试没有永久删除恢复候选。
  @override
  Future<bool> isPermanentlyDiscarded(String noteId) async => false;

  /// 没有设备需要停止。
  @override
  Future<NoteRecordingResult?> stop({String? reason}) async {
    _state = const NoteRecordingState();
    _states.add(_state);
    return null;
  }

  /// 页面替身没有采集原件，取消仅由真实仓储处理草稿引用。
  @override
  Future<void> discardPendingForDraft(
    String draftId, {
    Set<String> protectedPaths = const {},
  }) async {}

  /// 释放替身的事件流，避免用例之间残留订阅。
  @override
  Future<void> dispose() => _states.close();

  /// 捕获未预期接口调用。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 无音频设备的页面播放器。
class _Player implements NoteAudioPlayerService {
  /// 未选择音源。
  @override
  String? get currentPath => null;

  /// 无音源变化。
  @override
  Stream<String?> get currentPaths => const Stream.empty();

  /// 未播放。
  @override
  PlayerState get state => PlayerState.stopped;

  /// 无状态事件。
  @override
  Stream<PlayerState> get states => const Stream.empty();

  /// 无位置事件。
  @override
  Stream<Duration> get positions => const Stream.empty();

  /// 无时长事件。
  @override
  Stream<Duration> get durations => const Stream.empty();

  /// 无播放完成事件。
  @override
  Stream<void> get completions => const Stream.empty();

  /// 捕获未预期设备调用。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
