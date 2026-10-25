import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_theme_palette.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/notes/data/note_search_history.dart';
import 'package:omni_butler/features/notes/presentation/windows_note_search_bar.dart';
import 'package:omni_butler/features/notes/presentation/windows_note_search_filter.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/search_text_alignment.dart';

/// 使用真实生产搜索组件验证键鼠交互、独立过滤草稿和尺寸边界。
void main() {
  filterRefinementTests();
  setUpAll(() async {
    // 普通回归使用 SDK 真实字体，避免 Ahem 占位字形影响基线测量。
    final File configFile = File('.dart_tool/package_config.json').absolute;
    // 包配置用于定位当前机器的 Flutter，不依赖固定安装目录。
    final Map<String, dynamic> config =
        jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
    // 当前 Flutter 包的实际根目录。
    final Map<String, dynamic> flutterPackage =
        (config['packages'] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .singleWhere((entry) => entry['name'] == 'flutter');
    // SDK 自带文本与图标字体目录。
    final Uri fonts = Directory.fromUri(
      configFile.uri.resolve(flutterPackage['rootUri'] as String),
    ).parent.parent.uri.resolve('bin/cache/artifacts/material_fonts/');
    // 仅显式中文预览依赖 Windows 字体文件。
    final File fontFile =
        Platform.environment['OMNI_NOTES_SEARCH_PREVIEW'] == null
        ? File.fromUri(fonts.resolve('roboto-regular.ttf'))
        : File('C:/Windows/Fonts/msyh.ttc');
    // 所有候选字体家族共用同一真实字体以保证基线断言可重复。
    final ByteData font = ByteData.sublistView(await fontFile.readAsBytes());
    // 覆盖生产与测试框架可能使用的字体别名。
    for (final String family in <String>[
      'Roboto',
      'Ahem',
      'Noto Sans CJK SC',
      'Microsoft YaHei UI',
      'Microsoft YaHei',
    ]) {
      // 当前字体别名的装载器。
      final FontLoader loader = FontLoader(family)
        ..addFont(Future<ByteData>.value(font));
      await loader.load();
    }
    // 图标与生产应用使用相同的 Material 字形。
    final FontLoader icons = FontLoader('MaterialIcons')
      ..addFont(
        File.fromUri(fonts.resolve('materialicons-regular.otf'))
            .readAsBytes()
            .then(ByteData.sublistView),
      );
    await icons.load();
  });

  for (final double scale in <double>[1, 1.5, 2]) {
    testWidgets('搜索提示和输入文字保持垂直居中 $scale', (tester) async {
      // 使用真实生产控件与系统文字缩放，覆盖未聚焦和聚焦状态。
      final _SearchFixture fixture = await _mount(tester, scale: scale);
      expectSearchTextCentered(
        tester,
        field: _key('notes-search'),
        surface: _key('notes-search-surface'),
        hint: '搜索笔记 · Ctrl+F',
      );
      await tester.tap(_key('notes-search'));
      await tester.pumpAndSettle();
      expectSearchTextCentered(
        tester,
        field: _key('notes-search'),
        surface: _key('notes-search-surface'),
        hint: '搜索笔记 · Ctrl+F',
      );
      await tester.enterText(_key('notes-search'), '搜索居中 Flutter');
      await tester.pumpAndSettle();
      expectSearchTextCentered(
        tester,
        field: _key('notes-search'),
        surface: _key('notes-search-surface'),
        hint: '搜索笔记 · Ctrl+F',
      );
      await _capture(tester, fixture, 'alignment-$scale');
      await _dispose(tester, fixture);
    });
  }

  testWidgets('搜索框鼠标悬停边框、焦点展开及最近五条历史支持鼠标和键盘', (tester) async {
    // 六条历史用于验证实际展示上限及最新顺序。
    final _SearchFixture fixture = await _mount(
      tester,
      history: <String>['设计复盘', '本周计划', '产品灵感', '会议记录', '阅读笔记', '旧词条'],
    );
    expect(tester.getSize(_key('notes-search-surface')), const Size(260, 43.2));
    expect(_surface(tester).color, _colors(tester).mist);
    expect(_borderAlpha(tester), 0);
    await _capture(tester, fixture, 'idle');
    // 真实鼠标事件必须改变最终绘制装饰，不能只检查静态回调。
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(_key('notes-search-surface')));
    await tester.pumpAndSettle();
    expect(_borderAlpha(tester), greaterThan(0));
    await _capture(tester, fixture, 'hover');
    await tester.tap(_key('notes-search'));
    await tester.pumpAndSettle();
    expect(tester.getSize(_key('notes-search-surface')), const Size(400, 43.2));
    expect(_surface(tester).color, Colors.white);
    expect(_key('notes-search-history'), findsOneWidget);
    expect(_key('notes-search-history-4'), findsOneWidget);
    expect(_key('notes-search-history-5'), findsNothing);
    expect(find.text('旧词条'), findsNothing);
    await _capture(tester, fixture, 'focused-history');
    await tester.tap(_key('notes-search-history-1'));
    await tester.pumpAndSettle();
    expect(fixture.controller.text, '本周计划');
    expect(fixture.changes.last, '本周计划');
    expect(fixture.container.read(noteSearchHistoryProvider).first, '本周计划');
    expect(_key('notes-search-history'), findsNothing);
    await tester.tap(_key('notes-search'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(fixture.controller.text, '设计复盘');
    await tester.tap(_key('notes-search'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(fixture.controller.text, '阅读笔记');
    await tester.tap(_key('notes-search'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(_key('notes-search-history'), findsNothing);
    expect(fixture.focus.hasFocus, isFalse);
    await tester.tap(_key('notes-search'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(30, 350));
    await tester.pumpAndSettle();
    expect(_key('notes-search-history'), findsNothing);
    expect(fixture.focus.hasFocus, isFalse);
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
    await _dispose(tester, fixture);
  });

  testWidgets('输入中的词条不保存，提交后持久化并按大小写去重', (tester) async {
    // 偏好替身与生产 provider 完整连通，不写入真实用户历史。
    final _SearchFixture fixture = await _mount(tester);
    await tester.enterText(_key('notes-search'), '  Flutter  ');
    await tester.pumpAndSettle();
    expect(fixture.container.read(noteSearchHistoryProvider), isEmpty);
    expect(fixture.preferences.getStringList('notes.search.history'), isNull);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(fixture.controller.text, 'Flutter');
    expect(fixture.preferences.getStringList('notes.search.history'), <String>[
      'Flutter',
    ]);
    await tester.enterText(_key('notes-search'), 'flutter');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(fixture.preferences.getStringList('notes.search.history'), <String>[
      'flutter',
    ]);
    await tester.enterText(_key('notes-search'), '   ');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(fixture.preferences.getStringList('notes.search.history'), <String>[
      'flutter',
    ]);
    expect(tester.takeException(), isNull);
    await _dispose(tester, fixture);
  });

  testWidgets('中文组合输入不会提前记录，点击历史仍可替换预编辑文字', (tester) async {
    // 历史与输入法预编辑使用相同的真实输入框。
    final _SearchFixture fixture = await _mount(tester, history: ['已完成的查询']);
    await tester.tap(_key('notes-search'));
    await tester.pumpAndSettle();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'zhong',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 0, end: 5),
      ),
    );
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(fixture.container.read(noteSearchHistoryProvider), ['已完成的查询']);
    expect(
      fixture.controller.value.composing,
      const TextRange(start: 0, end: 5),
    );
    expect(fixture.focus.hasFocus, isTrue);
    await tester.tap(_key('notes-search-history-0'));
    await tester.pumpAndSettle();
    expect(fixture.controller.text, '已完成的查询');
    expect(fixture.controller.value.composing, TextRange.empty);
    await _dispose(tester, fixture);
    expect(tester.takeException(), isNull);
  });

  testWidgets('过滤标题仅悬停变深，点击展开，取消隔离草稿，搜索应用和重置可用', (tester) async {
    // 每次提交均记录真实回传值，以区分草稿与已应用条件。
    final _SearchFixture fixture = await _mount(tester);
    await tester.tap(_key('notes-search-filter'));
    await tester.pumpAndSettle();
    expect(_key('notes-search-filter-panel'), findsOneWidget);
    expect(_textColor(tester, '时间范围'), _colors(tester).muted);
    expect(_textColor(tester, '标签'), _colors(tester).muted);
    expect(_textColor(tester, '包含内容'), _colors(tester).muted);
    expect(_key('notes-filter-range-last7'), findsOneWidget);
    await _capture(tester, fixture, 'filter');
    // 时间选项常驻，悬停只改变标题文字。
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(_key('notes-filter-section-time')));
    await tester.pumpAndSettle();
    expect(_textColor(tester, '时间范围'), _colors(tester).ink);
    expect(_key('notes-filter-range-last7'), findsOneWidget);
    await tester.tap(_key('notes-filter-range-last7'));
    await mouse.moveTo(const Offset(20, 500));
    await tester.pumpAndSettle();
    expect(_textColor(tester, '时间范围'), _colors(tester).ink);
    expect(fixture.applied, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(fixture.applied, isEmpty);
    await tester.tap(_key('notes-search-filter'));
    await tester.pumpAndSettle();
    expect(_key('notes-filter-range-last7'), findsOneWidget);
    await tester.tap(_key('notes-filter-range-last7'));
    await tester.tap(_key('notes-filter-section-tags'));
    await tester.pumpAndSettle();
    await tester.tap(_key('notes-filter-tag-mode-exclude'));
    await tester.enterText(_key('notes-filter-tag-search'), '工');
    await tester.pumpAndSettle();
    await tester.tap(_key('notes-filter-tag-work'));
    await tester.ensureVisible(_key('notes-filter-section-content'));
    await tester.tap(_key('notes-filter-section-content'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(_key('notes-filter-content-image'));
    await tester.tap(_key('notes-filter-content-image'));
    await tester.ensureVisible(_key('notes-filter-apply'));
    await tester.pumpAndSettle();
    await _capture(tester, fixture, 'filter-selected');
    await tester.tap(_key('notes-filter-apply'));
    await tester.pumpAndSettle();
    expect(fixture.applied, hasLength(1));
    expect(fixture.applied.single.range, 'last7');
    expect(fixture.applied.single.tagMode, 'exclude');
    expect(fixture.applied.single.tagIds, <String>{'work'});
    expect(fixture.applied.single.contents, <String>{'image'});
    await tester.tap(_key('notes-search-filter'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(_key('notes-filter-reset'));
    await tester.tap(_key('notes-filter-reset'));
    await tester.pumpAndSettle();
    expect(fixture.applied, hasLength(1));
    await tester.ensureVisible(_key('notes-filter-apply'));
    await tester.tap(_key('notes-filter-apply'));
    await tester.pumpAndSettle();
    expect(fixture.applied, hasLength(2));
    expect(fixture.applied.last.isActive, isFalse);
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
    await _dispose(tester, fixture);
  });

  testWidgets('自定义日期在过滤菜单内可选择、校验并逐层取消', (tester) async {
    // 真实日期浮层嵌套在过滤菜单中，不绕过日期按钮回调。
    final _SearchFixture fixture = await _mount(tester);
    await tester.tap(_key('notes-search-filter'));
    await tester.pumpAndSettle();
    await tester.tap(_key('notes-filter-range-custom'));
    await tester.pumpAndSettle();
    await tester.tap(_key('notes-filter-apply'));
    await tester.pumpAndSettle();
    expect(find.text('请选择开始和结束日期'), findsOneWidget);
    await tester.tap(_key('notes-filter-date-start'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(GridView), matching: find.text('15')),
    );
    await tester.pumpAndSettle();
    await tester.tap(_key('notes-filter-date-end'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(GridView), matching: find.text('14')),
    );
    await tester.pumpAndSettle();
    await tester.tap(_key('notes-filter-apply'));
    await tester.pumpAndSettle();
    expect(find.text('结束日期不能早于开始日期'), findsOneWidget);
    await tester.tap(_key('notes-filter-date-end'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(GridView), findsNothing);
    expect(_key('notes-search-filter-panel'), findsOneWidget);
    await tester.tap(_key('notes-filter-date-end'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(GridView), matching: find.text('16')),
    );
    await tester.pumpAndSettle();
    await tester.tap(_key('notes-filter-apply'));
    await tester.pumpAndSettle();
    // 日历默认定位当前月份，提交的自然日保持实际所选首尾。
    final DateTime now = DateTime.now();
    expect(
      fixture.applied.single.customRange,
      DateTimeRange(
        start: DateTime(now.year, now.month, 15),
        end: DateTime(now.year, now.month, 16),
      ),
    );
    await _dispose(tester, fixture);
    expect(tester.takeException(), isNull);
  });

  testWidgets('深色320窄窗和1.6字号搜索历史及全部过滤仍可操作', (tester) async {
    // 大字号在最窄桌面宽度下验证实际可点击边界。
    final _SearchFixture fixture = await _mount(
      tester,
      width: 320,
      scale: 1.6,
      brightness: Brightness.dark,
      history: <String>['项目复盘', '最近笔记', '阅读计划', '本周会议', '待办整理'],
    );
    await tester.tap(_key('notes-search'));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(_key('notes-search-surface')).width,
      lessThanOrEqualTo(288),
    );
    expect(_key('notes-search-history-4'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tap(_key('notes-search-filter'));
    await tester.pumpAndSettle();
    await tester.tap(_key('notes-filter-range-last30'));
    await tester.ensureVisible(_key('notes-filter-section-tags'));
    await tester.tap(_key('notes-filter-section-tags'));
    await tester.pumpAndSettle();
    await tester.enterText(_key('notes-filter-tag-search'), '工');
    await tester.pumpAndSettle();
    await tester.tap(_key('notes-filter-tag-work'));
    await tester.ensureVisible(_key('notes-filter-section-content'));
    await tester.tap(_key('notes-filter-section-content'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(_key('notes-filter-content-audio'));
    await tester.tap(_key('notes-filter-content-audio'));
    await tester.ensureVisible(_key('notes-filter-apply'));
    await tester.pumpAndSettle();
    await _capture(tester, fixture, 'dark-narrow');
    expect(tester.takeException(), isNull);
    await tester.tap(_key('notes-filter-apply'));
    await tester.pumpAndSettle();
    expect(fixture.applied.single.contents, <String>{'audio'});
    expect(tester.takeException(), isNull);
    await _dispose(tester, fixture);
  });
}

/// 四项界面修正通过真实指针、最终像素、选择结果和配色矩阵验证。
void filterRefinementTests() {
  for (final Brightness brightness in Brightness.values) {
    testWidgets('标题悬停只改变文字箭头且时间永久展开：${brightness.name}', (tester) async {
      // 真实渲染同时检查浅色及深色表面，避免主题默认底色漏出。
      final _SearchFixture fixture = await _mount(
        tester,
        brightness: brightness,
      );
      await tester.tap(_key('notes-search-filter'));
      await tester.pumpAndSettle();
      expect(_key('notes-filter-range-last7'), findsOneWidget);
      expect(
        find.descendant(
          of: _key('notes-filter-section-time'),
          matching: find.byType(Icon),
        ),
        findsNothing,
      );
      await tester.tapAt(tester.getCenter(_key('notes-filter-section-time')));
      await tester.pumpAndSettle();
      expect(_key('notes-filter-range-last7'), findsOneWidget);
      // 同一鼠标跨三组标题检查实际绘制背景与文字颜色。
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: const Offset(20, 700));
      // 三组标题使用同一反馈约定，时间不产生折叠动作。
      for (final (String, String) section in [
        ('time', '时间范围'),
        ('tags', '标签'),
        ('content', '包含内容'),
      ]) {
        // 不覆盖文字和箭头的行内像素，用于检测整行底色。
        final Rect rect = tester.getRect(
          _key('notes-filter-section-${section.$1}'),
        );
        // 两侧内边距在hover前后都应保持菜单表面色。
        final List<Offset> points = [
          Offset(rect.left + 3, rect.center.dy),
          Offset(rect.right - 3, rect.center.dy),
        ];
        expect(_textColor(tester, section.$2), _colors(tester).muted);
        _expectPixels(
          await _pixels(tester, fixture, points),
          _colors(tester).paper,
        );
        await mouse.moveTo(rect.center);
        await tester.pumpAndSettle();
        expect(_textColor(tester, section.$2), _colors(tester).ink);
        _expectPixels(
          await _pixels(tester, fixture, points),
          _colors(tester).paper,
        );
        await _capture(
          tester,
          fixture,
          'header-hover-${section.$1}-${brightness.name}',
        );
        await mouse.moveTo(const Offset(20, 700));
        await tester.pumpAndSettle();
        expect(_textColor(tester, section.$2), _colors(tester).muted);
        _expectPixels(
          await _pixels(tester, fixture, points),
          _colors(tester).paper,
        );
      }
      await tester.tap(_key('notes-filter-range-last7'));
      await tester.pumpAndSettle();
      expect(_textColor(tester, '时间范围'), _colors(tester).ink);
      await tester.tap(_key('notes-filter-section-content'));
      await tester.pumpAndSettle();
      await tester.tap(_key('notes-filter-content-image'));
      await tester.pumpAndSettle();
      await tester.tap(_key('notes-filter-section-content'));
      await tester.pumpAndSettle();
      expect(_textColor(tester, '包含内容'), _colors(tester).ink);
      await tester.tap(_key('notes-filter-reset'));
      await tester.pumpAndSettle();
      expect(_key('notes-filter-range-last7'), findsOneWidget);
      await mouse.removePointer();
      await _dispose(tester, fixture);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('标签空查询不列候选，搜索匹配后才能添加且已选项可移除', (tester) async {
    // 两个匹配项与一个不匹配项验证真实筛选，操作不依赖固定列表。
    final _SearchFixture fixture = await _mount(tester);
    await tester.tap(_key('notes-search-filter'));
    await tester.pumpAndSettle();
    await tester.tap(_key('notes-filter-section-tags'));
    await tester.pumpAndSettle();
    expect(_key('notes-filter-tag-results'), findsNothing);
    expect(_key('notes-filter-tag-work'), findsNothing);
    expect(find.text('暂无标签'), findsNothing);
    await _capture(tester, fixture, 'tags-empty-query');
    await tester.enterText(_key('notes-filter-tag-search'), '   ');
    await tester.pumpAndSettle();
    expect(_key('notes-filter-tag-results'), findsNothing);
    await tester.enterText(_key('notes-filter-tag-search'), '工');
    await tester.pumpAndSettle();
    expect(_key('notes-filter-tag-work'), findsOneWidget);
    expect(_key('notes-filter-tag-plan'), findsOneWidget);
    expect(_key('notes-filter-tag-study'), findsNothing);
    expect(find.text('#工作'), findsOneWidget);
    expect(
      find.descendant(
        of: _key('notes-filter-tag-work'),
        matching: find.byType(Icon),
      ),
      findsNothing,
    );
    await _capture(tester, fixture, 'tags-search-results');
    await tester.tap(_key('notes-filter-tag-work'));
    await tester.pumpAndSettle();
    expect(_key('notes-filter-tag-results'), findsNothing);
    expect(_key('notes-filter-selected-tag-work'), findsOneWidget);
    expect(
      tester
          .widget<OmniTextField>(_key('notes-filter-tag-search'))
          .controller!
          .text,
      isEmpty,
    );
    expect(_textColor(tester, '标签'), _colors(tester).ink);
    await _capture(tester, fixture, 'tags-selected');
    await tester.tap(_key('notes-filter-selected-tag-work'));
    await tester.pumpAndSettle();
    expect(_key('notes-filter-selected-tag-work'), findsNothing);
    expect(_key('notes-filter-tag-results'), findsNothing);
    await tester.enterText(_key('notes-filter-tag-search'), '工');
    await tester.pumpAndSettle();
    await tester.tap(_key('notes-filter-tag-work'));
    await tester.pumpAndSettle();
    await tester.enterText(_key('notes-filter-tag-search'), '学');
    await tester.pumpAndSettle();
    await tester.tap(_key('notes-filter-tag-study'));
    await tester.pumpAndSettle();
    await tester.tap(_key('notes-filter-tag-mode-none'));
    await tester.pumpAndSettle();
    expect(_key('notes-filter-tag-search'), findsNothing);
    expect(_key('notes-filter-tag-results'), findsNothing);
    await tester.tap(_key('notes-filter-tag-mode-include'));
    await tester.pumpAndSettle();
    expect(_key('notes-filter-selected-tag-work'), findsOneWidget);
    expect(_key('notes-filter-selected-tag-study'), findsOneWidget);
    await tester.tap(_key('notes-filter-tag-mode-exclude'));
    await tester.pumpAndSettle();
    expect(_key('notes-filter-selected-tag-work'), findsOneWidget);
    expect(_key('notes-filter-selected-tag-study'), findsOneWidget);
    await tester.tap(_key('notes-filter-apply'));
    await tester.pumpAndSettle();
    expect(fixture.applied.single.tagIds, {'work', 'study'});
    expect(fixture.applied.single.tagMode, 'exclude');
    await tester.tap(_key('notes-search-filter'));
    await tester.pumpAndSettle();
    expect(_key('notes-filter-tag-results'), findsNothing);
    expect(_key('notes-filter-selected-tag-work'), findsOneWidget);
    await tester.tap(_key('notes-filter-reset'));
    await tester.pumpAndSettle();
    expect(_key('notes-filter-selected-tag-work'), findsNothing);
    expect(_key('notes-filter-tag-results'), findsNothing);
    expect(_key('notes-filter-range-last7'), findsOneWidget);
    await _dispose(tester, fixture);
    expect(tester.takeException(), isNull);
  });

  // 主题色替换须覆盖现有六套配色和两种明暗状态。
  for (final AppThemePalette palette in AppThemePalette.values) {
    for (final Brightness brightness in Brightness.values) {
      testWidgets('过滤按钮细描边和主题选中色不增添图标：${palette.id}/${brightness.name}', (
        tester,
      ) async {
        // 配色直接由生产主题构造，不能只验证固定经典蓝。
        final _SearchFixture fixture = await _mount(
          tester,
          brightness: brightness,
          palette: palette,
        );
        await tester.tap(_key('notes-search-filter'));
        await tester.pumpAndSettle();
        // 选择前后的文字占位必须一致。
        final Finder text = find.descendant(
          of: _key('notes-filter-range-month'),
          matching: find.text('本月'),
        );
        // 实际居中位置与非选中像素作为对照。
        final Offset center = tester.getCenter(text);
        // 字形以外的按钮底色采样点。
        final Offset point =
            tester.getTopLeft(_key('notes-filter-range-month')) +
            const Offset(9, 9);
        // 操作前的真实绘制背景。
        final Color neutral = (await _pixels(tester, fixture, [point])).single;
        expect(
          _button(
            tester,
            'notes-filter-range-month',
          ).style!.side!.resolve({})!.width,
          1,
        );
        await tester.tap(_key('notes-filter-range-month'));
        await tester.pumpAndSettle();
        expect(tester.getCenter(text), center);
        expect(
          find.descendant(
            of: _key('notes-filter-range-month'),
            matching: find.byType(Icon),
          ),
          findsNothing,
        );
        expect(
          _button(
            tester,
            'notes-filter-range-month',
          ).style!.foregroundColor!.resolve({}),
          _colors(tester).brand,
        );
        expect(
          _button(
            tester,
            'notes-filter-range-lastMonth',
          ).style!.foregroundColor!.resolve({}),
          _colors(tester).ink,
        );
        // 选中描边保留主题RGB，以透明度表达截图中的浅边框。
        final Color stroke = _button(
          tester,
          'notes-filter-range-month',
        ).style!.side!.resolve({})!.color;
        expect(stroke.withValues(alpha: 1), _colors(tester).brand);
        expect(stroke.a, inExclusiveRange(0, 1));
        expect(
          (await _pixels(tester, fixture, [point])).single,
          isNot(neutral),
        );
        await _capture(
          tester,
          fixture,
          'buttons-${palette.id}-${brightness.name}',
        );
        await _dispose(tester, fixture);
        expect(tester.takeException(), isNull);
      });
    }
  }
}

/// 读取统一按钮实际构建的原生样式，不直接调用生产私有样式函数。
TextButton _button(WidgetTester tester, String key) =>
    tester.widget<TextButton>(
      find.descendant(of: _key(key), matching: find.byType(TextButton)),
    );

/// 采样根图层的真实像素，验证hover没有残留的整行品牌色背景。
Future<List<Color>> _pixels(
  WidgetTester tester,
  _SearchFixture fixture,
  List<Offset> points,
) async {
  // 根边界包含上下文菜单，坐标与屏幕坐标一致。
  final RenderRepaintBoundary boundary =
      fixture.boundary.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
  return (await tester.runAsync(() async {
    // GPU回调使用真实异步时钟。
    final ui.Image image = await boundary.toImage(pixelRatio: 1);
    try {
      // 无损RGBA用于比较最终合成颜色。
      final ByteData bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      return [
        // 每个指定点均位于控件内，取该像素的完整RGBA。
        for (final Offset point in points)
          Color.fromARGB(
            bytes.getUint8(
              (point.dy.floor() * image.width + point.dx.floor()) * 4 + 3,
            ),
            bytes.getUint8(
              (point.dy.floor() * image.width + point.dx.floor()) * 4,
            ),
            bytes.getUint8(
              (point.dy.floor() * image.width + point.dx.floor()) * 4 + 1,
            ),
            bytes.getUint8(
              (point.dy.floor() * image.width + point.dx.floor()) * 4 + 2,
            ),
          ),
      ];
    } finally {
      image.dispose();
    }
  }))!;
}

/// 允许8位RGBA量化的一阶误差，不允许蓝色或灰色hover填充。
void _expectPixels(List<Color> pixels, Color expected) {
  // 逐个采样点比较三色通道。
  for (final Color pixel in pixels) {
    expect(pixel.r, closeTo(expected.r, 1 / 255));
    expect(pixel.g, closeTo(expected.g, 1 / 255));
    expect(pixel.b, closeTo(expected.b, 1 / 255));
  }
}

/// 统一查找生产组件稳定身份，避免测试复制其结构。
Finder _key(String value) => find.byKey(ValueKey<String>(value));

/// 当前实际动画目标的背景和边框。
BoxDecoration _surface(WidgetTester tester) =>
    tester.widget<AnimatedContainer>(_key('notes-search-surface')).decoration!
        as BoxDecoration;

/// 已绘制边框的透明度表达无边框状态。
double _borderAlpha(WidgetTester tester) =>
    (_surface(tester).border! as Border).top.color.a;

/// 从搜索框实际主题读取语义色。
OmniColors _colors(WidgetTester tester) =>
    OmniColors.of(tester.element(_key('notes-search')));

/// 读取 Text 最终继承颜色，覆盖按钮内部动画后的实际文字状态。
Color? _textColor(WidgetTester tester, String label) {
  // 当前标签的真实元素和可选显式样式。
  final Element element = tester.element(find.text(label));
  // 标签的样式与 DefaultTextStyle 合并结果。
  final Text text = element.widget as Text;
  return DefaultTextStyle.of(element).style.merge(text.style).color;
}

/// 单次测试资源与观察结果，不连接数据库或系统录音。
class _SearchFixture {
  /// 隔离的偏好存储与状态容器。
  final SharedPreferences preferences;

  /// 隔离的 Riverpod 状态容器。
  final ProviderContainer container;

  /// 复用生产搜索框接收的文字控制器。
  final TextEditingController controller = TextEditingController();

  /// 搜索框自身不拥有的页面焦点。
  final FocusNode focus = FocusNode();

  /// 完整含浮层的截图边界。
  final GlobalKey boundary = GlobalKey();

  /// 实时搜索词观察结果。
  final List<String> changes = <String>[];

  /// 用户明确应用的过滤值。
  final List<WindowsNoteSearchFilter> applied = <WindowsNoteSearchFilter>[];

  /// 当前已应用值供下一次菜单恢复。
  WindowsNoteSearchFilter filter = const WindowsNoteSearchFilter.empty();

  /// 避免正常路径与失败清理重复释放。
  bool disposed = false;

  /// 截图临时启用阴影，必须在测试主体结束前恢复。
  final bool previousShadows = debugDisableShadows;

  /// 桌面主题必须按真实Windows密度构造，再于结束时恢复测试平台。
  final TargetPlatform? previousPlatform = debugDefaultTargetPlatformOverride;

  /// 创建只含测试资源的容器。
  _SearchFixture(this.preferences, this.container);
}

/// 挂载独立生产搜索框，提供可控窗口、字体和本机偏好。
Future<_SearchFixture> _mount(
  WidgetTester tester, {
  List<String>? history,
  double width = 800,
  double scale = 1,
  Brightness brightness = Brightness.light,
  AppThemePalette palette = AppThemePalette.classicBlue,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  SharedPreferences.setMockInitialValues(<String, Object>{
    'notes.search.history': ?history,
  });
  // 预置数据只进入 mock store。
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  // 生产 provider 使用同一隔离存储。
  final ProviderContainer container = ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
  );
  // 捕获当前测试所有受控资源。
  final _SearchFixture fixture = _SearchFixture(preferences, container);
  addTearDown(() => _dispose(tester, fixture));
  debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  // 预览需要真实阴影，其余测试沿用 Flutter 的默认行为。
  if (Platform.environment['OMNI_NOTES_SEARCH_PREVIEW'] != null) {
    debugDisableShadows = false;
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: fixture.boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.build(
            brightness: brightness,
            palette: palette,
          ).copyWith(platform: TargetPlatform.windows),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: StatefulBuilder(
                builder: (context, setState) => Align(
                  alignment: Alignment.topRight,
                  child: WindowsNoteSearchBar(
                    controller: fixture.controller,
                    focusNode: fixture.focus,
                    tags: <TaxonomyEntry>[
                      TaxonomyEntry(
                        id: 'work',
                        module: 'notes',
                        kind: 'tag',
                        name: '工作',
                        colorValue: 0,
                        sortOrder: 0,
                        isPinned: false,
                        isEnabled: true,
                        createdAt: DateTime(2026),
                        updatedAt: DateTime(2026),
                      ),
                      TaxonomyEntry(
                        id: 'study',
                        module: 'notes',
                        kind: 'tag',
                        name: '学习',
                        colorValue: 0,
                        sortOrder: 1,
                        isPinned: false,
                        isEnabled: true,
                        createdAt: DateTime(2026),
                        updatedAt: DateTime(2026),
                      ),
                      TaxonomyEntry(
                        id: 'plan',
                        module: 'notes',
                        kind: 'tag',
                        name: '工作计划',
                        colorValue: 0,
                        sortOrder: 2,
                        isPinned: false,
                        isEnabled: true,
                        createdAt: DateTime(2026),
                        updatedAt: DateTime(2026),
                      ),
                    ],
                    filter: fixture.filter,
                    onChanged: fixture.changes.add,
                    onFilterChanged: (value) => setState(() {
                      fixture.filter = value;
                      fixture.applied.add(value);
                    }),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fixture;
}

/// 卸载浮层与组件后释放控制器，避免异步焦点回调访问已释放资源。
Future<void> _dispose(WidgetTester tester, _SearchFixture fixture) async {
  if (fixture.disposed) return;
  fixture.disposed = true;
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  fixture.container.dispose();
  fixture.controller.dispose();
  fixture.focus.dispose();
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
  tester.platformDispatcher.clearTextScaleFactorTestValue();
  debugDisableShadows = fixture.previousShadows;
  debugDefaultTargetPlatformOverride = fixture.previousPlatform;
}

/// 可选输出带真实中文和图标的独立搜索组件截图。
Future<void> _capture(
  WidgetTester tester,
  _SearchFixture fixture,
  String name,
) async {
  // 输出路径由专用环境变量显式开启。
  final String? directory = Platform.environment['OMNI_NOTES_SEARCH_PREVIEW'];
  if (directory == null) return;
  await tester.pumpAndSettle();
  // 根边界包含 OverlayPortal 与菜单路由。
  final RenderRepaintBoundary boundary =
      fixture.boundary.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
  await tester.runAsync(() async {
    // 图层导出使用真实异步时钟，防止假时钟等待 GPU 回调停滞。
    final ui.Image image = await boundary.toImage(pixelRatio: 1);
    try {
      // 无损 PNG 便于检查细线和中文文字。
      final ByteData bytes = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!;
      await Directory(directory).create(recursive: true);
      await File('$directory/$name.png')
          .writeAsBytes(bytes.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}
