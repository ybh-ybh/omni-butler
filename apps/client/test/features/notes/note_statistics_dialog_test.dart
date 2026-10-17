import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_theme_palette.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/notes/data/note_providers.dart';
import 'package:omni_butler/features/notes/presentation/windows_note_statistics_dialog.dart';
import 'package:omni_butler/features/notes/presentation/note_statistic_button.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

import 'note_statistics_test.dart' show statisticNote;

/// 隔离正式数据流，仍使用生产弹窗路由与控件。
Future<ProviderContainer> mountStatistics(
  WidgetTester tester,
  Stream<List<NoteEntryRecord>> Function() source, {
  Size size = const Size(1280, 900),
  double scale = 1,
  bool reduce = false,
  Brightness brightness = Brightness.light,
  AppThemePalette palette = AppThemePalette.classicBlue,
  ValueChanged<String?>? onResult,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  // 每次打开仍走同一份生产监听。
  final ProviderContainer container = ProviderContainer(
    overrides: [notesProvider.overrideWith((ref) => source())],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    container.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    RepaintBoundary(
      key: const ValueKey('statistics-test-boundary'),
      child: UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.build(
            brightness: brightness,
            palette: palette,
          ).copyWith(platform: TargetPlatform.windows),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: reduce,
            ),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => OmniButton(
                label: '打开统计',
                onPressed: () async {
                  // 先执行路由，再通知可选的测试观察者。
                  final String? result = await showNoteStatisticsDialog(
                    context,
                  );
                  onResult?.call(result);
                },
              ),
            ),
          ),
        ),
      ),
    ),
  );
  // 从键盘触发入口，关闭时应恢复实际调用入口的焦点。
  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  await tester.pump();
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pump();
  return container;
}

/// 构造当前月的稳定日期，不依赖今天是否为月初。
String currentDate(int day) {
  // 当前月份与生产默认选择一致。
  final DateTime now = DateTime.now();
  return '${now.year}-${now.month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
}

/// 读取已绘制像素，确认悬停底色的实际呈现而不只检查配置。
Future<Color> statisticsPixel(WidgetTester tester, Offset position) async {
  // 测试专用全窗口截图边界。
  final RenderRepaintBoundary boundary = tester.renderObject(
    find.byKey(const ValueKey('statistics-test-boundary')),
  );
  return (await tester.runAsync(() async {
    // 直接读取无损RGBA，采样点避开文字和圆角。
    final ui.Image image = await boundary.toImage();
    try {
      // 当前像素的四个颜色通道。
      final ByteData pixels = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      // 按截图宽度定位采样点。
      final int offset =
          (position.dy.floor() * image.width + position.dx.floor()) * 4;
      return Color.fromARGB(
        pixels.getUint8(offset + 3),
        pixels.getUint8(offset),
        pixels.getUint8(offset + 1),
        pixels.getUint8(offset + 2),
      );
    } finally {
      image.dispose();
    }
  }))!;
}

/// 覆盖真实鼠标、键盘、实时数据和窄窗。
void main() {
  // 明暗主题都覆盖年份无底色与未选中分段的实际悬停填充。
  for (final Brightness brightness in Brightness.values) {
    testWidgets('统计年份无悬停底色，月年手形与未选中灰底 ${brightness.name}', (tester) async {
      await mountStatistics(
        tester,
        () => Stream.value([statisticNote('a', currentDate(1), '正文')]),
        brightness: brightness,
      );
      await tester.pumpAndSettle();
      // 年份入口底部留白可观察原来的灰色悬停层。
      final Finder yearMenu = find.byKey(
        const ValueKey('notes-statistics-year-menu'),
      );
      // 留白采样避开年份字形和下拉箭头。
      final Offset menuSample =
          tester.getBottomLeft(yearMenu) + const Offset(2, -2);
      // 进入前的实际背景用于对照透明悬停层。
      final Color before = await statisticsPixel(tester, menuSample);
      // 用真实MouseTracker验证每个入口的手形指针。
      final TestGesture mouse = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(yearMenu));
      await tester.pumpAndSettle();
      expect(await statisticsPixel(tester, menuSample), before);
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.click,
      );
      // 分段的外侧空白位于圆角以内且不含文字。
      final Finder year = find.byKey(
        const ValueKey('notes-statistics-year-view'),
      );
      // 当前已选月份的独立热区。
      final Finder month = find.byKey(
        const ValueKey('notes-statistics-month-view'),
      );
      // 专用深灰色由当前主题生成，深色模式也保持可见。
      final OmniColors colors = OmniColors.of(tester.element(year));
      // 与截图一致的未选中悬停底色。
      final Color hover = Color.alphaBlend(
        colors.ink.withValues(alpha: 0.12),
        colors.mist,
      );
      await mouse.moveTo(tester.getCenter(year));
      await tester.pumpAndSettle();
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.click,
      );
      expect(
        await statisticsPixel(
          tester,
          tester.getTopLeft(year) + const Offset(12, 12),
        ),
        Color(hover.toARGB32()),
      );
      await mouse.moveTo(tester.getCenter(month));
      await tester.pumpAndSettle();
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.click,
      );
      expect(
        await statisticsPixel(
          tester,
          tester.getTopLeft(month) + const Offset(12, 12),
        ),
        Color(colors.paper.toARGB32()),
      );
      // 切到年度后，未选中月份应获得同样的深灰底。
      await mouse.moveTo(tester.getCenter(year));
      await mouse.down(tester.getCenter(year));
      await mouse.up();
      await tester.pumpAndSettle();
      // 点击后鼠标保持原位，选中项不能保留旧Ink层的不透明黑色。
      expect(
        await statisticsPixel(
          tester,
          tester.getTopLeft(year) + const Offset(12, 12),
        ),
        Color(colors.paper.toARGB32()),
      );
      await mouse.moveTo(tester.getCenter(month));
      await tester.pumpAndSettle();
      expect(
        await statisticsPixel(
          tester,
          tester.getTopLeft(month) + const Offset(12, 12),
        ),
        Color(hover.toARGB32()),
      );
      await mouse.moveTo(tester.getCenter(year));
      await tester.pumpAndSettle();
      expect(
        await statisticsPixel(
          tester,
          tester.getTopLeft(year) + const Offset(12, 12),
        ),
        Color(colors.paper.toARGB32()),
      );
      await mouse.moveTo(Offset.zero);
      await tester.pumpAndSettle();
      expect(
        await statisticsPixel(
          tester,
          tester.getTopLeft(month) + const Offset(12, 12),
        ),
        Color(colors.mist.toARGB32()),
      );
      // 反向切回月视图，点击后停留也必须立即恢复正确选中表面。
      await mouse.moveTo(tester.getCenter(month));
      await mouse.down(tester.getCenter(month));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(
        await statisticsPixel(
          tester,
          tester.getTopLeft(month) + const Offset(12, 12),
        ),
        Color(colors.paper.toARGB32()),
      );
      await mouse.removePointer();
    });
  }

  // 鼠标菜单还原原焦点，键盘菜单回到入口，两种路径均不得残留底色。
  for (final Brightness brightness in Brightness.values) {
    testWidgets('年份菜单按输入来源恢复焦点且无底色 ${brightness.name}', (tester) async {
      await mountStatistics(
        tester,
        () => Stream.value([statisticNote('a', currentDate(1), '正文')]),
        brightness: brightness,
      );
      await tester.pumpAndSettle();
      // 真实年份触发器与下方留白采样点。
      final Finder yearMenu = find.byKey(
        const ValueKey('notes-statistics-year-menu'),
      );
      // 避开字形和箭头，观察焦点及按下叠加色。
      final Offset sample =
          tester.getBottomLeft(yearMenu) + const Offset(2, -2);
      // 点击前的画布颜色作为无底色基准。
      final Color before = await statisticsPixel(tester, sample);
      // 鼠标打开不应强制聚焦年份，关闭时恢复打开前的实际节点。
      final FocusNode? focusBeforeMenu = FocusManager.instance.primaryFocus;
      // 点击并停留的鼠标与用户轨迹一致。
      final TestGesture mouse = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(yearMenu));
      await mouse.down(tester.getCenter(yearMenu));
      await tester.pump(const Duration(milliseconds: 120));
      expect(await statisticsPixel(tester, sample), before);
      await mouse.up();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('notes-statistics-dialog')),
        findsOneWidget,
      );
      expect(await statisticsPixel(tester, sample), before);
      expect(FocusManager.instance.primaryFocus, same(focusBeforeMenu));
      // 再打开并选择当前年份，关闭后同样不得残留焦点底色。
      await mouse.down(tester.getCenter(yearMenu));
      await mouse.up();
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey('notes-statistics-option-${DateTime.now().year}')),
      );
      await tester.pumpAndSettle();
      expect(await statisticsPixel(tester, sample), before);
      expect(FocusManager.instance.primaryFocus, same(focusBeforeMenu));
      await mouse.removePointer();
      // 使用真实Tab遍历到年份入口，确认键盘关闭菜单后仍可继续操作。
      final FocusNode yearFocus = Focus.of(
        tester.element(
          find.byKey(const ValueKey('notes-statistics-selected-year')),
        ),
      );
      // 遍历有界，避免入口意外失去键盘可达性时测试永久等待。
      for (int attempt = 0; attempt < 12 && !yearFocus.hasFocus; attempt++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(yearFocus.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('notes-statistics-option-${DateTime.now().year}')),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(yearFocus.hasFocus, isTrue);
      expect(await statisticsPixel(tester, sample), before);
    });
  }

  testWidgets('统计入口支持Tab及Enter和Space，减少动画即时显示箭头', (tester) async {
    // 业务只观察激活次数，不依赖弹窗或数据库。
    int activations = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light)
            .copyWith(platform: TargetPlatform.windows),
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 80,
                child: NoteStatisticButton(
                  count: '3',
                  label: '笔记',
                  countKey: 'keyboard-count',
                  alignment: CrossAxisAlignment.start,
                  onTap: () => activations++,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(
      tester
          .widget<Opacity>(
            find.byKey(const ValueKey('notes-statistic-arrow-keyboard-count')),
          )
          .opacity,
      1,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(activations, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(activations, 2);
  });

  testWidgets('有效日期有可访问语义并能用Space选日，关闭后恢复入口焦点', (tester) async {
    // 启用Dart语义检查日期说明与激活行为。
    final SemanticsHandle semantics = tester.ensureSemantics();
    // 弹窗的选择结果应和鼠标完全一致。
    String? selected;
    await mountStatistics(
      tester,
      () => Stream.value([statisticNote('a', currentDate(1), '正文')]),
      onResult: (value) => selected = value,
    );
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('${currentDate(1)}，1篇笔记，2字'), findsOneWidget);
    // 聚焦日期自身的真实InkWell焦点节点，再发送系统按键。
    final Finder day = find.byKey(
      ValueKey('notes-statistics-day-${currentDate(1)}'),
    );
    final Finder focus = find
        .descendant(of: day, matching: find.byType(Focus))
        .first;
    Focus.of(
      tester.element(
        find.descendant(of: focus, matching: find.byType(MouseRegion)).first,
      ),
    ).requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(selected, currentDate(1));
    expect(find.text('记录统计'), findsNothing);
    expect(Focus.of(tester.element(find.text('打开统计'))).hasFocus, isTrue);
    semantics.dispose();
  });

  testWidgets('月历空日只描边，有记录日提示并返回准确归档日期', (tester) async {
    // 可观察关闭弹窗后的返回结果。
    String? selected;
    await mountStatistics(
      tester,
      () => Stream.value([
        statisticNote('a', currentDate(1), '正文'),
        statisticNote('b', currentDate(1), '更多'),
      ]),
      onResult: (value) => selected = value,
    );
    await tester.pumpAndSettle();
    expect(find.text('记录统计'), findsOneWidget);
    expect(find.text('更多'), findsNothing);
    // 实际鼠标经过空日期只改变轮廓。
    final Finder empty = find.byKey(
      ValueKey('notes-statistics-day-${currentDate(2)}'),
    );
    final TestGesture mouse = await tester.createGesture(
      kind: ui.PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(empty));
    await tester.pumpAndSettle();
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.basic,
    );
    expect(
      find.ancestor(of: empty, matching: find.byType(Tooltip)),
      findsNothing,
    );
    // 检查动画实际绘制后的边框颜色。
    final DecoratedBox fill = tester.widget<DecoratedBox>(
      find.descendant(of: empty, matching: find.byType(DecoratedBox)).first,
    );
    expect(
      (fill.decoration as BoxDecoration).border!.top.color,
      OmniColors.of(tester.element(empty)).brand,
    );
    await tester.tap(empty);
    await tester.pumpAndSettle();
    expect(find.text('记录统计'), findsOneWidget);
    // 有记录日可操作，提示汇总同一天两篇正文的字数。
    final Finder filled = find.byKey(
      ValueKey('notes-statistics-day-${currentDate(1)}'),
    );
    await mouse.moveTo(tester.getCenter(filled));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.click,
    );
    expect(find.text('2笔记·4字'), findsOneWidget);
    await tester.tap(filled);
    await tester.pumpAndSettle();
    expect(find.text('记录统计'), findsNothing);
    expect(selected, currentDate(1));
    await mouse.removePointer();
  });

  testWidgets('只列有效年份，闰日月历和年度十二个月一致并实时回退年份', (tester) async {
    // 同一弹窗收到多轮同步快照。
    final StreamController<List<NoteEntryRecord>> source = StreamController();
    addTearDown(source.close);
    await mountStatistics(tester, () => source.stream, onResult: (_) {});
    source.add([
      statisticNote('leap', '2024-02-29', '闰日'),
      statisticNote('new', currentDate(1), '本月'),
    ]);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notes-statistics-year-menu')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('notes-statistics-option-2024')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('notes-statistics-option-2025')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey('notes-statistics-option-2024')),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('notes-statistics-day-2024-02-29')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('notes-statistics-day-2024-02-30')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('notes-statistics-year-view')));
    await tester.pumpAndSettle();
    expect(find.text('1 条笔记'), findsOneWidget);
    expect(find.text('2 字'), findsOneWidget);
    expect(find.text('1 天'), findsOneWidget);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('notes-statistics-bar-0-1')))
          .height,
      0,
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('notes-statistics-bar-0-2')))
          .height,
      greaterThan(0),
    );
    expect(find.text('12'), findsNWidgets(3));
    source.add([statisticNote('new', currentDate(1), '更新后的正文')]);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('notes-statistics-selected-year')),
          )
          .data,
      '${DateTime.now().year}',
    );
    expect(find.text('6 字'), findsOneWidget);
    source.add([]);
    await tester.pumpAndSettle();
    expect(find.text('暂无笔记记录'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('notes-statistics-year-menu')),
      findsNothing,
    );
  });

  testWidgets('首次加载和失败不伪装空态，重试后恢复统计', (tester) async {
    // 首次请求保持加载，失败后下一次订阅成功。
    final StreamController<List<NoteEntryRecord>> pending = StreamController();
    addTearDown(pending.close);
    // 订阅次数控制可重复的重试场景。
    int subscriptions = 0;
    await mountStatistics(
      tester,
      () => subscriptions++ == 0
          ? pending.stream
          : Stream.value([statisticNote('a', currentDate(1), '恢复')]),
      onResult: (_) {},
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('暂无笔记记录'), findsNothing);
    pending.addError(StateError('测试加载失败'));
    await tester.pumpAndSettle();
    expect(find.text('笔记统计加载失败'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('笔记统计加载失败'), findsNothing);
    expect(
      find.byKey(const ValueKey('notes-statistics-year-menu')),
      findsOneWidget,
    );
  });

  for (final AppThemePalette palette in AppThemePalette.values) {
    for (final Brightness brightness in Brightness.values) {
      testWidgets('统计适配 ${palette.id} ${brightness.name} 512窗和1.6字号及减少动画', (
        tester,
      ) async {
        await mountStatistics(
          tester,
          () => Stream.value([statisticNote('a', currentDate(1), '窄窗')]),
          size: const Size(512, 512),
          scale: 1.6,
          reduce: true,
          palette: palette,
          brightness: brightness,
          onResult: (_) {},
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(
          find.byKey(const ValueKey('notes-statistics-year-view')),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('记录统计'), findsNothing);
      });
    }
  }
}
