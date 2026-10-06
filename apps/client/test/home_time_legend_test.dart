import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
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
      expect(find.text('1小时30分'), findsOneWidget);
      expect(find.text('1小时40分'), findsOneWidget);
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
      expect(find.text('0分钟'), findsNWidgets(2));
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
}

/// 挂载独立时间卡片，用真实统计方法和受控异步数据验证图例。
Future<void> _pumpTimeCard(
  WidgetTester tester, {
  required DateTime now,
  double width = 520,
  List<TimeEntryRecord> todayRecords = const <TimeEntryRecord>[],
  List<TimeEntryRecord> weekRecords = const <TimeEntryRecord>[],
  Map<String, Color> categoryColors = const <String, Color>{},
}) async {
  tester.view.physicalSize = Size(width, 900);
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
            .copyWith(platform: TargetPlatform.windows),
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
  // 页面上该周期的真实圆环绘制器。
  final CustomPaint donut = tester.widget<CustomPaint>(
    find.byKey(ValueKey<String>('home-time-donut-$label')),
  );
  // 图像读取使用真实异步调度，避免测试虚拟时间阻塞像素回传。
  final Set<int>? colors = await tester.runAsync(() async {
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
    // 收集实色笔画内部的 ARGB 颜色。
    final Set<int> paintedColors = <int>{};
    // 每四字节读取一个像素，忽略边缘抗锯齿产生的半透明色。
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
    image.dispose();
    picture.dispose();
    return paintedColors;
  });
  return colors!;
}
