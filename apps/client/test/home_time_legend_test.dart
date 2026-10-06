import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/features/home/presentation/home_time_status_card.dart';
import 'package:omni_butler/features/timeline/data/time_entry_repository.dart';

/// 验证双圆环共用真实类别图例并保留完整辅助功能信息。
void main() {
  testWidgets('共同与独有类别合并去重，图例色块与两个圆环实际颜色一致', (WidgetTester tester) async {
    // 挂载前启用语义树，验证去除可见摘要后读屏信息仍完整。
    final SemanticsHandle semantics = tester.ensureSemantics();
    try {
      // 固定在周二，允许本周图独有昨天的类别。
      final DateTime now = DateTime(2026, 10, 6, 14);
      // 用户实际定义的类别颜色。
      const Map<String, Color> categoryColors = <String, Color>{
        '工作': Color(0xFFE14B56),
        '学习': Color(0xFF367CE1),
        '运动': Color(0xFF289779),
      };
      // 今日与本周共同出现的类别记录。
      final TimeEntryRecord sharedEntry = _entry(
        id: 'shared',
        startedAt: DateTime(2026, 10, 6, 9),
        minutes: 60,
        category: '工作',
      );
      await _pumpTimeCard(
        tester,
        now: now,
        categoryColors: categoryColors,
        todayRecords: <TimeEntryRecord>[
          sharedEntry,
          _entry(
            id: 'today-only',
            startedAt: DateTime(2026, 10, 6, 11),
            minutes: 30,
            category: '学习',
          ),
        ],
        // 两条异步数据流可在刷新时暂不完全重合，图例仍必须覆盖并集。
        weekRecords: <TimeEntryRecord>[
          sharedEntry,
          _entry(
            id: 'week-only',
            startedAt: DateTime(2026, 10, 5, 9),
            minutes: 40,
            category: '运动',
          ),
        ],
      );
      // 共用图例的查找范围。
      final Finder legend = find.byKey(
        const ValueKey<String>('home-time-category-legend'),
      );
      expect(legend, findsOneWidget);
      // 每个真实类别只生成一个色块和一个图例名称。
      for (final MapEntry<String, Color> category in categoryColors.entries) {
        expect(
          find.descendant(of: legend, matching: find.text(category.key)),
          findsOneWidget,
        );
        expect(_legendColor(tester, category.key), category.value);
      }
      // 今日圆环真实绘制出的不透明颜色。
      final Set<int> todayColors = await _paintedDonutColors(tester, '今日');
      // 本周圆环真实绘制出的不透明颜色。
      final Set<int> weekColors = await _paintedDonutColors(tester, '本周');
      expect(
        todayColors,
        containsAll(<int>[
          categoryColors['工作']!.toARGB32(),
          categoryColors['学习']!.toARGB32(),
        ]),
      );
      expect(
        weekColors,
        containsAll(<int>[
          categoryColors['工作']!.toARGB32(),
          categoryColors['运动']!.toARGB32(),
        ]),
      );
      expect(find.text('按已记录时间查看类别分布'), findsNothing);
      expect(find.textContaining('主要用于'), findsNothing);
      expect(find.text('工作 1小时 · 学习 30分钟'), findsNothing);
      expect(find.text('工作 1小时 · 运动 40分钟'), findsNothing);
      expect(find.text('1h30m'), findsOneWidget);
      expect(find.text('1h40m'), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          RegExp(RegExp.escape('今日记录1小时30分，主要用于工作 67%；工作 1小时 · 学习 30分钟')),
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(
          RegExp(RegExp.escape('本周记录1小时40分，主要用于工作 60%；工作 1小时 · 运动 40分钟')),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      // 隐藏共同类别后，两图都移除该颜色并重新计算中心总时长。
      await tester.tap(
        find.byKey(const ValueKey<String>('home-time-legend-item-工作')),
      );
      await tester.pumpAndSettle();
      expect(
        await _paintedDonutColors(tester, '今日'),
        isNot(contains(categoryColors['工作']!.toARGB32())),
      );
      expect(
        await _paintedDonutColors(tester, '本周'),
        isNot(contains(categoryColors['工作']!.toARGB32())),
      );
      expect(find.text('1h30m'), findsNothing);
      expect(find.text('1h40m'), findsNothing);
      // 未选中色块使用主题灰色，并保留选项及原始记录。
      final OmniColors colors = OmniColors.of(
        tester.element(find.byType(HomeTimeStatusCard)),
      );
      expect(_legendColor(tester, '工作'), colors.line);
      expect(
        tester
            .widget<Semantics>(
              find.byKey(const ValueKey<String>('home-time-legend-item-工作')),
            )
            .properties
            .selected,
        isFalse,
      );
      expect(find.text('09:00–10:00 · 工作'), findsOneWidget);
      // 全部取消后显示零时长，仍能通过保留的图例恢复。
      for (final String category in <String>['学习', '运动']) {
        await tester.tap(
          find.byKey(ValueKey<String>('home-time-legend-item-$category')),
        );
        await tester.pumpAndSettle();
      }
      expect(find.text('0h0m'), findsNWidgets(2));
      expect(find.bySemanticsLabel(RegExp('今日所选类别暂无时间记录')), findsOneWidget);
      for (final String category in categoryColors.keys) {
        await tester.tap(
          find.byKey(ValueKey<String>('home-time-legend-item-$category')),
        );
        await tester.pumpAndSettle();
      }
      expect(find.text('1h30m'), findsOneWidget);
      expect(find.text('1h40m'), findsOneWidget);
      expect(_legendColor(tester, '工作'), categoryColors['工作']);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('未分类记录使用圆环相同的回退色，未使用的类别不进入图例', (WidgetTester tester) async {
    // 实际没有分类的时间记录。
    final TimeEntryRecord record = _entry(
      id: 'uncategorized',
      startedAt: DateTime(2026, 10, 6, 9),
      minutes: 30,
    );
    await _pumpTimeCard(
      tester,
      now: DateTime(2026, 10, 6, 14),
      todayRecords: <TimeEntryRecord>[record],
      weekRecords: <TimeEntryRecord>[record],
      categoryColors: const <String, Color>{'未使用类别': Colors.red},
    );
    // 应用主题定义的时间模块回退色。
    final Color fallbackColor = OmniColors.of(
      tester.element(find.byType(HomeTimeStatusCard)),
    ).time;
    expect(_legendColor(tester, '未分类'), fallbackColor);
    expect(
      await _paintedDonutColors(tester, '今日'),
      contains(fallbackColor.toARGB32()),
    );
    expect(
      find.byKey(const ValueKey<String>('home-time-legend-item-未使用类别')),
      findsNothing,
    );
    expect(find.text('未分类'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有记录时保留零时长与空态，不生成虚构图例', (WidgetTester tester) async {
    // 空圆环也保留按周期区分的读屏说明。
    final SemanticsHandle semantics = tester.ensureSemantics();
    try {
      await _pumpTimeCard(
        tester,
        now: DateTime(2026, 10, 6, 14),
        categoryColors: const <String, Color>{'工作': Colors.blue},
      );

      expect(
        find.byKey(const ValueKey<String>('home-time-category-legend')),
        findsNothing,
      );
      expect(find.text('0h0m'), findsNWidgets(2));
      expect(find.text('今天还没有时间记录'), findsOneWidget);
      expect(find.text('还没有时间记录'), findsNothing);
      expect(find.bySemanticsLabel(RegExp('今日还没有时间记录')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('本周还没有时间记录')), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('320 像素宽度下长类别自动换行且不溢出卡片', (WidgetTester tester) async {
    // 超出单行可用宽度的真实类别名。
    const String longCategory = '阅读学习与个人知识体系整理以及下一阶段长期计划复盘';
    // 短类别用于确认图例在长名称之后自动换行。
    const String shortCategory = '生活记录';
    // 今日时间记录。
    final List<TimeEntryRecord> records = <TimeEntryRecord>[
      _entry(
        id: 'long-category',
        startedAt: DateTime(2026, 10, 6, 9),
        minutes: 60,
        category: longCategory,
      ),
      _entry(
        id: 'short-category',
        startedAt: DateTime(2026, 10, 6, 11),
        minutes: 30,
        category: shortCategory,
      ),
    ];
    await _pumpTimeCard(
      tester,
      width: 320,
      now: DateTime(2026, 10, 6, 14),
      todayRecords: records,
      weekRecords: records,
      categoryColors: const <String, Color>{
        longCategory: Color(0xFF7956BD),
        shortCategory: Color(0xFF318F87),
      },
    );
    // 卡片内容范围。
    final Rect cardRect = tester.getRect(
      find.byKey(const ValueKey<String>('home-time-status-card')),
    );
    // 长类别图例项的实际范围。
    final Rect longItemRect = tester.getRect(
      find.byKey(const ValueKey<String>('home-time-legend-item-$longCategory')),
    );
    // 第二个类别图例项的实际范围。
    final Rect shortItemRect = tester.getRect(
      find.byKey(
        const ValueKey<String>('home-time-legend-item-$shortCategory'),
      ),
    );
    expect(longItemRect.left, greaterThan(cardRect.left));
    expect(longItemRect.right, lessThan(cardRect.right));
    expect(shortItemRect.top, greaterThanOrEqualTo(longItemRect.bottom));
    expect(find.text(longCategory), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('类别隐藏的中间帧连续变化，反向点击从当前画面恢复', (WidgetTester tester) async {
    // 用明显不同的扇区比例验证真实像素，而非只检查动画控件存在。
    final List<TimeEntryRecord> records = [
      _entry(
        id: 'work',
        startedAt: DateTime(2026, 10, 6, 9),
        minutes: 90,
        category: '工作',
      ),
      _entry(
        id: 'study',
        startedAt: DateTime(2026, 10, 6, 11),
        minutes: 30,
        category: '学习',
      ),
    ];
    await _pumpTimeCard(
      tester,
      now: DateTime(2026, 10, 6, 14),
      todayRecords: records,
      weekRecords: records,
      categoryColors: const {'工作': Colors.blue, '学习': Colors.orange},
    );
    // 点击前的两个真实圆环像素。
    final ByteData todayBefore = await _donutPixels(tester, '今日');
    // 本周圆环也必须参与同一次过渡。
    final ByteData weekBefore = await _donutPixels(tester, '本周');
    // 可反复激活的图例项。
    final Finder work = find.byKey(
      const ValueKey<String>('home-time-legend-item-工作'),
    );
    await tester.tap(work);
    await tester.pump();
    expect(
      (await _donutPixels(tester, '今日')).buffer.asUint8List(),
      todayBefore.buffer.asUint8List(),
    );
    await tester.pump(const Duration(milliseconds: 120));
    // 尚未到终点的呈现帧。
    final ByteData middle = await _donutPixels(tester, '今日');
    expect(
      middle.buffer.asUint8List(),
      isNot(todayBefore.buffer.asUint8List()),
    );
    expect(
      (await _donutPixels(tester, '本周')).buffer.asUint8List(),
      isNot(weekBefore.buffer.asUint8List()),
    );
    await tester.tap(work);
    await tester.pump();
    expect(
      (await _donutPixels(tester, '今日')).buffer.asUint8List(),
      middle.buffer.asUint8List(),
    );
    await tester.pumpAndSettle();
    expect(
      (await _donutPixels(tester, '今日')).buffer.asUint8List(),
      todayBefore.buffer.asUint8List(),
    );
    await tester.tap(work);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    // 再次隐藏时仍有真实的中间画面。
    final ByteData hiding = await _donutPixels(tester, '今日');
    await tester.pumpAndSettle();
    expect(
      (await _donutPixels(tester, '今日')).buffer.asUint8List(),
      isNot(hiding.buffer.asUint8List()),
    );
    expect(
      await _paintedDonutColors(tester, '今日'),
      isNot(contains(Colors.blue.toARGB32())),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('系统减少动画时类别切换立即完成', (WidgetTester tester) async {
    // 单一类别同时覆盖全部隐藏与恢复的空圆环边界。
    final TimeEntryRecord record = _entry(
      id: 'work',
      startedAt: DateTime(2026, 10, 6, 9),
      minutes: 60,
      category: '工作',
    );
    await _pumpTimeCard(
      tester,
      now: DateTime(2026, 10, 6, 14),
      todayRecords: [record],
      weekRecords: [record],
      categoryColors: const {'工作': Colors.blue},
      disableAnimations: true,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('home-time-legend-item-工作')),
    );
    await tester.pump();
    expect(
      await _paintedDonutColors(tester, '今日'),
      isNot(contains(Colors.blue.toARGB32())),
    );
    expect(find.text('0h0m'), findsNWidgets(2));
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.tap(
      find.byKey(const ValueKey<String>('home-time-legend-item-工作')),
    );
    await tester.pump();
    expect(
      await _paintedDonutColors(tester, '今日'),
      contains(Colors.blue.toARGB32()),
    );
  });

  for (final TargetPlatform platform in [
    TargetPlatform.windows,
    TargetPlatform.android,
  ]) {
    testWidgets('${platform.name} 全部今日记录可滚到最后，标题固定且滚动条贴卡片边缘', (
      WidgetTester tester,
    ) async {
      // 二十条不同时间的记录，覆盖旧版五条截断及真实视口溢出。
      final List<TimeEntryRecord> records = [
        for (int index = 0; index < 20; index++)
          _entry(
            id: 'record-$index',
            startedAt: DateTime(2026, 10, 6, 0, index * 30),
            minutes: 20,
            category: '工作',
          ),
      ];
      await _pumpTimeCard(
        tester,
        now: DateTime(2026, 10, 6, 21),
        width: platform == TargetPlatform.android ? 390 : 520,
        height: 650,
        platform: platform,
        todayRecords: records,
        weekRecords: records,
      );
      // 真实卡片内的专用滚动条与视口。
      final Finder scrollbar = find.descendant(
        of: find.byType(HomeTimeStatusCard),
        matching: find.byType(Scrollbar),
      );
      // 固定标题的滚动前位置。
      final Rect headerBefore = tester.getRect(
        find.byKey(const ValueKey<String>('home-time-header')),
      );
      // 内容最底部对应最早的记录。
      final Finder last = find.text('测试活动 record-0');
      expect(find.textContaining('查看全部'), findsNothing);
      expect(find.text('测试活动 record-19'), findsOneWidget);
      expect(last, findsOneWidget);
      expect(
        tester
            .widget<Scrollbar>(scrollbar)
            .controller!
            .position
            .maxScrollExtent,
        greaterThan(0),
      );
      await tester.drag(scrollbar, const Offset(0, -3000));
      await tester.pumpAndSettle();
      expect(last.hitTestable(), findsOneWidget);
      expect(
        tester.getRect(find.byKey(const ValueKey<String>('home-time-header'))),
        headerBefore,
      );
      expect(
        tester.getRect(scrollbar).right,
        tester
            .getRect(
              find.byKey(const ValueKey<String>('home-time-status-card')),
            )
            .right,
      );
      expect(ScrollbarTheme.of(tester.element(scrollbar)).crossAxisMargin, 2);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('安卓图例相邻行保持紧凑，悬浮背景两侧有留白', (WidgetTester tester) async {
    // 六类记录在手机宽度下必须换行。
    const List<String> categories = ['睡眠', '开发', '学习', '吃饭', '娱乐', '其他'];
    // 让类别顺序稳定且每个图例都有真实数据。
    final List<TimeEntryRecord> records = [
      for (int index = 0; index < categories.length; index++)
        _entry(
          id: 'category-$index',
          startedAt: DateTime(2026, 10, 6, index),
          minutes: 30,
          category: categories[index],
        ),
    ];
    await _pumpTimeCard(
      tester,
      now: DateTime(2026, 10, 6, 14),
      width: 390,
      platform: TargetPlatform.android,
      todayRecords: records,
      weekRecords: records,
    );
    // 每行文字的真实中心位置，直接验证上下间距。
    final Set<double> rowCenters = {
      for (final String category in categories)
        tester.getCenter(find.text(category)).dy,
    };
    expect(rowCenters.length, 2);
    expect(rowCenters.last - rowCenters.first, lessThanOrEqualTo(32));
    // 图例色块距离悬浮区域的左右边缘。
    final Finder item = find.byKey(
      const ValueKey<String>('home-time-legend-item-开发'),
    );
    // 整个图例的可点击悬浮背景。
    final Finder ink = find.descendant(
      of: item,
      matching: find.byType(InkWell),
    );
    expect(
      tester
              .getRect(
                find.byKey(const ValueKey<String>('home-time-legend-color-开发')),
              )
              .left -
          tester.getRect(ink).left,
      8,
    );
    expect(
      tester.getRect(ink).right - tester.getRect(find.text('开发')).right,
      8,
    );
    // 鼠标进入时不会改变换行或图例大小。
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(ink));
    await tester.pumpAndSettle();
    expect(tester.getSize(item).height, 32);
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
  });
}

/// 挂载独立时间卡片，用真实统计方法和受控异步数据验证图例。
Future<void> _pumpTimeCard(
  WidgetTester tester, {
  required DateTime now,
  double width = 520,
  double height = 900,
  TargetPlatform platform = TargetPlatform.windows,
  bool disableAnimations = false,
  List<TimeEntryRecord> todayRecords = const <TimeEntryRecord>[],
  List<TimeEntryRecord> weekRecords = const <TimeEntryRecord>[],
  Map<String, Color> categoryColors = const <String, Color>{},
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // 只供真实仓储统计函数持有，不写入任何业务数据。
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  // 今日自然日和本周范围，与生产卡片使用同一业务日期。
  final DateTime today = DateUtils.dateOnly(now);
  // 本周周一起点。
  final DateTime weekStart = today.subtract(
    Duration(days: today.weekday - DateTime.monday),
  );
  // 下周周一起点。
  final DateTime weekEnd = weekStart.add(const Duration(days: 7));
  // 用用户实际类别名及颜色建立分类记录。
  final List<TaxonomyEntry> categories = categoryColors.entries
      .map(
        (MapEntry<String, Color> entry) => TaxonomyEntry(
          id: entry.key,
          module: TaxonomyModule.timeline.name,
          kind: TaxonomyKind.category.name,
          name: entry.key,
          colorValue: entry.value.toARGB32(),
          sortOrder: 0,
          isEnabled: true,
          createdAt: today,
          updatedAt: today,
        ),
      )
      .toList(growable: false);
  // 数据源独立覆盖，以验证刷新时两个图类别暂不重合的并集逻辑。
  final ProviderContainer container = ProviderContainer(
    overrides: [
      timeEntryRepositoryProvider.overrideWithValue(
        TimeEntryRepository(database),
      ),
      timeEntriesForDayProvider(today).overrideWith(
        (Ref ref) => Stream<List<TimeEntryRecord>>.value(todayRecords),
      ),
      timeEntriesForRangeProvider((weekStart, weekEnd)).overrideWith(
        (Ref ref) => Stream<List<TimeEntryRecord>>.value(weekRecords),
      ),
      taxonomyEntriesProvider((TaxonomyModule.timeline, TaxonomyKind.category))
          .overrideWith(
            (Ref ref) => Stream<List<TaxonomyEntry>>.value(categories),
          ),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await database.close();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light)
            .copyWith(platform: platform),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(disableAnimations: disableAnimations),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(child: HomeTimeStatusCard(now: now)),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 创建无需持久化的完成时间记录。
TimeEntryRecord _entry({
  required String id,
  required DateTime startedAt,
  required int minutes,
  String? category,
}) {
  // 当前记录所在自然日。
  final DateTime day = DateUtils.dateOnly(startedAt);
  // 记录开始时刻相对当天午夜的分钟数。
  final int startMinute = startedAt.difference(day).inMinutes;
  return TimeEntryRecord(
    id: id,
    entryDate: day,
    startMinute: startMinute,
    endMinute: startMinute + minutes,
    startedAt: startedAt,
    endedAt: startedAt.add(Duration(minutes: minutes)),
    activity: '测试活动 $id',
    category: category,
    syncState: 'localSaved',
    createdAt: startedAt,
    updatedAt: startedAt,
  );
}

/// 读取实际呈现的图例色块颜色。
Color _legendColor(WidgetTester tester, String category) {
  // 带稳定类别键的图例色块。
  final Container swatch = tester.widget<Container>(
    find.byKey(ValueKey<String>('home-time-legend-color-$category')),
  );
  return (swatch.decoration! as BoxDecoration).color!;
}

/// 执行真实圆环绘制并提取不透明颜色，避免依赖私有分段实现。
Future<Set<int>> _paintedDonutColors(WidgetTester tester, String label) async {
  // 每四字节读取一个像素，忽略边缘抗锯齿产生的半透明色。
  final ByteData pixels = await _donutPixels(tester, label);
  // 收集实色笔画内部的 ARGB 颜色。
  final Set<int> paintedColors = <int>{};
  for (int offset = 0; offset < pixels.lengthInBytes; offset += 4) {
    if (pixels.getUint8(offset + 3) == 255) {
      paintedColors.add(
        0xFF000000 |
            pixels.getUint8(offset) << 16 |
            pixels.getUint8(offset + 1) << 8 |
            pixels.getUint8(offset + 2),
      );
    }
  }
  return paintedColors;
}

/// 读取动画当前帧的真实圆环像素。
Future<ByteData> _donutPixels(WidgetTester tester, String label) async {
  // 页面上该周期的真实圆环绘制器。
  final CustomPaint donut = tester.widget<CustomPaint>(
    find.byKey(ValueKey<String>('home-time-donut-$label')),
  );
  // 图像读取使用真实异步调度，避免测试虚拟时间阻塞像素回传。
  final ByteData? result = await tester.runAsync(() async {
    // 用与圆环相同的尺寸记录真实绘制命令。
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    donut.painter!.paint(Canvas(recorder), const Size.square(104));
    // 绘制命令对应的临时图片。
    final ui.Picture picture = recorder.endRecording();
    // 光栅化后的圆环图片。
    final ui.Image image = await picture.toImage(104, 104);
    // 原始 RGBA 像素数据。
    final ByteData pixels = (await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!;
    image.dispose();
    picture.dispose();
    return pixels;
  });
  return result!;
}
