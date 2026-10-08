import 'dart:math' as math;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_theme_palette.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/features/timeline/presentation/timeline_review.dart';

/// 验证轻量指纹仍忠实表达时间，且短段与文字缩放保持可用。
void main() {
  testWidgets('指纹保留横向时间坐标，视觉内缩区仍打开编辑，空白打开当日', (WidgetTester tester) async {
    // 使用同一天的连续短段和午夜边界作为几何样本。
    final DateTime day = DateTime(2026, 10, 5);
    // 相邻记录不人为增加水平空隙。
    final List<TimeEntryRecord> records = <TimeEntryRecord>[
      _record(day, 'short', 360, 361),
      _record(day, 'next', 361, 720),
      _record(day, 'midnight', 1380, 1440),
    ];
    // 捕获编辑与打开当日，避免视觉间隙将操作错误路由。
    final List<String> edited = <String>[];
    // 当前空白位置打开的日期。
    DateTime? opened;
    await _pumpReview(
      tester,
      records: records,
      onEdit: (TimeEntryRecord record) => edited.add(record.id),
      onOpenDay: (DateTime day) => opened = day,
    );
    // 真实时间投影使用轨道宽度，而不是圆角色段的装饰宽度。
    final Finder short = find.byKey(
      const ValueKey<String>('fingerprint-record-short'),
    );
    // 对应的完整24小时轨道。
    final Rect track = tester.getRect(
      find.ancestor(of: short, matching: find.byType(Material)).first,
    );
    // 第一个一分钟短段的完整命中框。
    final Rect shortRect = tester.getRect(short);
    // 下一段的起点必须精确对应第361分钟。
    final Rect nextRect = tester.getRect(
      find.byKey(const ValueKey<String>('fingerprint-record-next')),
    );
    // 午夜前最后一段的右边缘。
    final Rect midnightRect = tester.getRect(
      find.byKey(const ValueKey<String>('fingerprint-record-midnight')),
    );
    expect(
      shortRect.left - track.left,
      closeTo(track.width * 360 / 1440, 0.01),
    );
    expect(nextRect.left - track.left, closeTo(track.width * 361 / 1440, 0.01));
    expect(midnightRect.right, closeTo(track.right, 0.01));
    expect(shortRect.width, closeTo(math.max(2, track.width / 1440), 0.01));
    await tester.tapAt(
      Offset(shortRect.left + track.width / 1440 / 2, shortRect.top + 1),
    );
    await tester.pump();
    expect(edited, <String>['short']);
    expect(opened, isNull);
    await tester.tapAt(Offset(track.left + track.width * 0.1, track.center.dy));
    await tester.pump();
    expect(opened, day);
    expect(edited, <String>['short']);
    expect(
      find.byKey(const ValueKey<String>('timeline-metrics')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏双倍字号与空记录覆盖率不溢出', (WidgetTester tester) async {
    // 两倍字号下刻度必须主动降低密度。
    await _pumpReview(
      tester,
      records: const <TimeEntryRecord>[],
      viewport: const Size(320, 844),
      scale: 2,
    );
    expect(find.text('覆盖率 0%'), findsOneWidget);
    expect(find.text('00'), findsOneWidget);
    expect(find.text('24'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final AppThemePalette palette in AppThemePalette.values) {
    for (final Brightness brightness in Brightness.values) {
      testWidgets('${palette.name} ${brightness.name} 指纹保持类别原色且标签对比度达标', (
        WidgetTester tester,
      ) async {
        // 高亮和深色分类同时验证，避免固定白色文字失去可读性。
        final DateTime day = DateTime(2026, 10, 5);
        // 两段宽记录提供足够空间显示真实类别标签。
        final List<TimeEntryRecord> records = <TimeEntryRecord>[
          _record(day, 'light', 0, 720, category: '浅色'),
          _record(day, 'dark', 720, 1440, category: '深色'),
        ];
        await _pumpReview(
          tester,
          records: records,
          palette: palette,
          brightness: brightness,
        );
        for (final (String, String, Color) sample in <(String, String, Color)>[
          ('light', '浅色', const Color(0xFFFFE699)),
          ('dark', '深色', const Color(0xFF303030)),
        ]) {
          // 当前业务色段与其文字标签。
          final Finder segment = find.byKey(
            ValueKey<String>('fingerprint-record-${sample.$1}'),
          );
          // 色段的实际绘制背景。
          final BoxDecoration decoration =
              tester
                      .widget<Ink>(
                        find.descendant(
                          of: segment,
                          matching: find.byType(Ink),
                        ),
                      )
                      .decoration!
                  as BoxDecoration;
          // 读取实际呈现的文字前景色。
          final Color foreground = tester
              .widget<Text>(
                find.descendant(of: segment, matching: find.text(sample.$2)),
              )
              .style!
              .color!;
          expect(decoration.color, sample.$3);
          expect(_contrast(foreground, sample.$3), greaterThanOrEqualTo(4.5));
        }
        expect(find.text('覆盖率 14%'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}

/// 使用生产主题挂载复盘，分类通过隔离流注入，不访问业务数据库。
Future<void> _pumpReview(
  WidgetTester tester, {
  required List<TimeEntryRecord> records,
  Size viewport = const Size(1440, 900),
  double scale = 1,
  AppThemePalette palette = AppThemePalette.classicBlue,
  Brightness brightness = Brightness.light,
  ValueChanged<TimeEntryRecord>? onEdit,
  ValueChanged<DateTime>? onOpenDay,
}) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // 固定周一起点，覆盖率始终按完整七天计算。
  final DateTime day = DateTime(2026, 10, 5);
  // 分类汇总仓储也显式限定为内存，避免构造生产数据库。
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(database.close);
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        taxonomyEntriesProvider((
          TaxonomyModule.timeline,
          TaxonomyKind.category,
        )).overrideWith(
          (Ref ref) => Stream<List<TaxonomyEntry>>.value(<TaxonomyEntry>[
            _category(day, '浅色', const Color(0xFFFFE699)),
            _category(day, '深色', const Color(0xFF303030)),
          ]),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.build(brightness: brightness, palette: palette),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: TimelineReviewContent(
            records: records,
            previousRecords: const <TimeEntryRecord>[],
            rangeStart: day,
            rangeEnd: day.add(const Duration(days: 7)),
            period: TimelineStatsPeriod.week,
            onOpenDay: onOpenDay ?? (DateTime _) {},
            onEdit: onEdit ?? (TimeEntryRecord _) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 创建指定自然日起止分钟的内存记录。
TimeEntryRecord _record(
  DateTime day,
  String id,
  int start,
  int end, {
  String category = '测试',
}) => TimeEntryRecord(
  id: id,
  entryDate: day,
  startMinute: start,
  endMinute: end,
  startedAt: day.add(Duration(minutes: start)),
  endedAt: day.add(Duration(minutes: end)),
  activity: '测试活动',
  category: category,
  syncState: 'localSaved',
  createdAt: day,
  updatedAt: day,
);

/// 创建只用于图表颜色验证的分类，不向仓储写入。
TaxonomyEntry _category(DateTime day, String name, Color color) =>
    TaxonomyEntry(
      id: name,
      module: 'timeline',
      kind: 'category',
      name: name,
      colorValue: color.toARGB32(),
      sortOrder: 0,
      isEnabled: true,
      createdAt: day,
      updatedAt: day,
    );

/// 用标准相对亮度计算实际文字与背景对比度。
double _contrast(Color foreground, Color background) {
  // 前景的相对亮度。
  final double front = foreground.computeLuminance();
  // 背景的相对亮度。
  final double back = background.computeLuminance();
  return (math.max(front, back) + 0.05) / (math.min(front, back) + 0.05);
}
