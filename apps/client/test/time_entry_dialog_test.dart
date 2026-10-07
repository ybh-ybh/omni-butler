import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show BooleanExpressionOperators;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/features/timeline/data/time_entry_repository.dart';
import 'package:omni_butler/features/timeline/presentation/time_entry_time_picker.dart';
import 'package:omni_butler/features/timeline/presentation/timeline_page.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 固定当前时刻，使默认区间和日期在回归中稳定。
final DateTime _now = DateTime(2026, 10, 7, 10, 20);

/// 验证补记真实弹窗的两端交互、类别颜色、精确时间和响应式布局。
void main() {
  setUpAll(() async {
    if (Platform.environment['OMNI_BACKFILL_PREVIEW_DIR'] == null) return;
    // 中文预览用系统字体，不将字体资产加入仓库。
    final ByteData font = ByteData.sublistView(
      await File('C:/Windows/Fonts/msyh.ttc').readAsBytes(),
    );
    for (final String family in <String>[
      'Ahem',
      'Microsoft YaHei UI',
      'Microsoft YaHei',
      'Roboto',
      'Noto Sans CJK SC',
    ]) {
      // 注册生产主题及默认测试字形。
      final FontLoader loader = FontLoader(family);
      loader.addFont(Future<ByteData>.value(font));
      await loader.load();
    }
    // 同时保留生产 Material 图标。
    final FontLoader icons = FontLoader('MaterialIcons');
    icons.addFont(
      Future<ByteData>.value(
        ByteData.sublistView(
          await File(
            'D:/program/code/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
          ).readAsBytes(),
        ),
      ),
    );
    await icons.load();
  });

  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.android,
    TargetPlatform.windows,
  ]) {
    testWidgets('${platform.name} 类别菜单逐项保留左侧配置色与右侧选中标记', (
      WidgetTester tester,
    ) async {
      // 真实数据库与已打开的补记弹窗。
      final _DialogFixture fixture = await _pumpDialog(
        tester,
        platform: platform,
      );
      try {
        expect(find.textContaining('跨天记录'), findsNothing);
        expect(
          find.byKey(const ValueKey<String>('time-range-duration')),
          findsOneWidget,
        );
        expect(
          find.byType(RangeSlider),
          platform == TargetPlatform.android ? findsNothing : findsOneWidget,
        );
        expect(
          find.byType(TimeEntryWheelPicker),
          platform == TargetPlatform.android ? findsOneWidget : findsNothing,
        );
        expect(
          tester
              .getTopLeft(
                find.byKey(const ValueKey<String>('time-start-display')),
              )
              .dy,
          lessThan(
            tester
                .getTopLeft(
                  find.byKey(const ValueKey<String>('time-entry-activity')),
                )
                .dy,
          ),
        );
        // 首次打开仅聚焦模态范围，不自动唤起文本键盘。
        expect(tester.testTextInput.isVisible, isFalse);
        await _capture(tester, '${platform.name}-light');
        await tester.ensureVisible(
          find.byKey(const ValueKey<String>('time-entry-category')),
        );
        await tester.tap(
          find.byKey(const ValueKey<String>('time-entry-category')),
        );
        await tester.pumpAndSettle();
        // 从配置表逐项验证实际弹出菜单，避免只检查关闭时的选中值。
        final List<TaxonomyEntry> categories =
            await (fixture.database.select(fixture.database.taxonomyEntries)
                  ..where(
                    (TaxonomyEntries table) =>
                        table.module.equals('timeline') &
                        table.kind.equals('category'),
                  ))
                .get();
        expect(categories, hasLength(7));
        for (final TaxonomyEntry category in categories) {
          // 当前类别的真实弹出菜单行。
          final Finder item = find.ancestor(
            of: find.byKey(
              ValueKey<String>('time-category-color-${category.name}'),
            ),
            matching: find.byType(MenuItemButton),
          );
          expect(item, findsOneWidget);
          // 左侧颜色圆点及同一行的类别名称。
          final Finder dot = find.descendant(
            of: item,
            matching: find.byKey(
              ValueKey<String>('time-category-color-${category.name}'),
            ),
          );
          // 配置颜色完整保留，且色点在名称左侧。
          final Container marker = tester.widget<Container>(dot);
          expect(
            (marker.decoration! as BoxDecoration).color,
            Color(category.colorValue),
          );
          expect(
            tester.getTopLeft(dot).dx,
            lessThan(
              tester
                  .getTopLeft(
                    find.descendant(
                      of: item,
                      matching: find.text(category.name),
                    ),
                  )
                  .dx,
            ),
          );
        }
        await _capture(tester, '${platform.name}-category-menu');
        await tester.tap(
          find.ancestor(
            of: find.text('专项类别'),
            matching: find.byType(MenuItemButton),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey<String>('time-entry-category')),
        );
        await tester.pumpAndSettle();
        // 已选菜单行的勾选位于内容右侧，不挤走类别颜色。
        final MenuItemButton selected = tester.widget<MenuItemButton>(
          find.ancestor(
            of: find.text('专项类别'),
            matching: find.byType(MenuItemButton),
          ),
        );
        expect(selected.leadingIcon, isNull);
        expect(selected.trailingIcon, isNotNull);
        await tester.tap(
          find.ancestor(
            of: find.text('专项类别'),
            matching: find.byType(MenuItemButton),
          ),
        );
        await tester.pumpAndSettle();
        await _enterActivity(tester, '类别色点回归');
        await tester.tap(find.text('保存记录'));
        await tester.pumpAndSettle();
        expect(
          (await fixture.database
                  .select(fixture.database.timeEntries)
                  .getSingle())
              .category,
          '专项类别',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    });

    testWidgets('${platform.name} 编辑保留原有分钟、类别与展开的备注', (
      WidgetTester tester,
    ) async {
      // 从页面真实记录行进入共用编辑弹窗。
      final _DialogFixture fixture = await _pumpDialog(
        tester,
        platform: platform,
        size: const Size(1440, 900),
        editing: true,
        seed: TimeEntryDraft(
          startedAt: DateTime(2026, 10, 7, 9, 1),
          endedAt: DateTime(2026, 10, 7, 9, 3),
          activity: '原有记录',
          category: '学习',
          notes: '原有备注',
        ),
      );
      try {
        expect(find.text('编辑时间记录'), findsOneWidget);
        expect(_saveButton(tester).onPressed, isNotNull);
        expect(_dateButton(tester, 'start').value, DateTime(2026, 10, 7, 9, 1));
        expect(_dateButton(tester, 'end').value, DateTime(2026, 10, 7, 9, 3));
        expect(
          find.byKey(const ValueKey<String>('time-entry-notes')),
          findsOneWidget,
        );
        expect(
          tester
              .widget<OmniTextField>(
                find.byKey(const ValueKey<String>('time-entry-notes')),
              )
              .controller!
              .text,
          '原有备注',
        );
        expect(
          find.byKey(const ValueKey<String>('time-category-color-学习')),
          findsOneWidget,
        );
        await tester.tap(find.text('保存记录'));
        await tester.pumpAndSettle();
        // 不调整时间时不会取整两端，也不会新建重复记录。
        final TimeEntryRecord saved = (await tester.runAsync(
          () =>
              fixture.database.select(fixture.database.timeEntries).getSingle(),
        ))!;
        expect(saved.startedAt, DateTime(2026, 10, 7, 9, 1));
        expect(saved.endedAt, DateTime(2026, 10, 7, 9, 3));
        expect(saved.category, '学习');
        expect(saved.notes, '原有备注');
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    });

    // 默认空闲段覆盖缩短、当前占用、连续占用、跨日及秒级边界。
    for (final (String, List<TimeEntryDraft>, DateTime, DateTime, DateTime)
        scenario
        in <(String, List<TimeEntryDraft>, DateTime, DateTime, DateTime)>[
          (
            '最近记录结束后缩短默认一小时',
            <TimeEntryDraft>[
              TimeEntryDraft(
                startedAt: DateTime(2026, 10, 7, 9),
                endedAt: DateTime(2026, 10, 7, 9, 43),
                activity: '最近记录',
              ),
            ],
            _now,
            DateTime(2026, 10, 7, 9, 43),
            _now,
          ),
          (
            '当前被占用时取之前最近空闲段',
            <TimeEntryDraft>[
              TimeEntryDraft(
                startedAt: DateTime(2026, 10, 7, 9, 30),
                endedAt: DateTime(2026, 10, 7, 9, 40),
                activity: '前段记录',
              ),
              TimeEntryDraft(
                startedAt: DateTime(2026, 10, 7, 9, 50),
                endedAt: DateTime(2026, 10, 7, 10, 40),
                activity: '当前占用',
              ),
            ],
            _now,
            DateTime(2026, 10, 7, 9, 40),
            DateTime(2026, 10, 7, 9, 50),
          ),
          (
            '进行中之前的相邻记录连续回溯',
            <TimeEntryDraft>[
              TimeEntryDraft(
                startedAt: DateTime(2026, 10, 7, 8, 30),
                endedAt: DateTime(2026, 10, 7, 9, 30),
                activity: '前段记录',
              ),
              TimeEntryDraft(
                startedAt: DateTime(2026, 10, 7, 9, 30),
                activity: '进行中',
              ),
            ],
            _now,
            DateTime(2026, 10, 7, 7, 30),
            DateTime(2026, 10, 7, 8, 30),
          ),
          (
            '凌晨默认段避开跨日记录',
            <TimeEntryDraft>[
              TimeEntryDraft(
                startedAt: DateTime(2026, 10, 6, 23, 30),
                endedAt: DateTime(2026, 10, 7, 0, 10),
                activity: '跨日记录',
              ),
            ],
            DateTime(2026, 10, 7, 0, 20),
            DateTime(2026, 10, 7, 0, 10),
            DateTime(2026, 10, 7, 0, 20),
          ),
          (
            '秒级记录末尾向上取分钟避免重叠',
            <TimeEntryDraft>[
              TimeEntryDraft(
                startedAt: DateTime(2026, 10, 7, 9),
                endedAt: DateTime(2026, 10, 7, 9, 43, 12),
                activity: '带秒记录',
              ),
            ],
            _now,
            DateTime(2026, 10, 7, 9, 44),
            _now,
          ),
        ]) {
      testWidgets('${platform.name} ${scenario.$1}', (
        WidgetTester tester,
      ) async {
        // 多条真实记录参与默认区间计算，保存仍由正式仓储验证。
        final _DialogFixture fixture = await _pumpDialog(
          tester,
          platform: platform,
          seeds: scenario.$2,
          now: scenario.$3,
        );
        try {
          expect(_dateButton(tester, 'start').value, scenario.$4);
          expect(_dateButton(tester, 'end').value, scenario.$5);
          expect(
            find.byKey(const ValueKey<String>('time-conflict-message')),
            findsNothing,
          );
          expect(_saveButton(tester).onPressed, isNotNull);
          await _enterActivity(tester, '自动空闲补记');
          await tester.tap(find.text('保存记录'));
          await tester.pumpAndSettle();
          // 确认计算后的区间真实落库，无冲突异常。
          final List<TimeEntryRecord> saved = await fixture.database
              .select(fixture.database.timeEntries)
              .get();
          // 新记录由活动名称唯一识别。
          final TimeEntryRecord added = saved.singleWhere(
            (TimeEntryRecord record) => record.activity == '自动空闲补记',
          );
          expect(added.startedAt, scenario.$4);
          expect(added.endedAt, scenario.$5);
          expect(tester.takeException(), isNull);
        } finally {
          await fixture.dispose(tester);
        }
      });
    }

    testWidgets('${platform.name} 进行中记录持续占用未来时段且阻止保存', (
      WidgetTester tester,
    ) async {
      // 已有一条尚未结束的记录。
      final _DialogFixture fixture = await _pumpDialog(
        tester,
        platform: platform,
        seed: TimeEntryDraft(
          startedAt: DateTime(2026, 10, 7, 9, 30),
          activity: '正在学习',
        ),
      );
      try {
        if (platform == TargetPlatform.android) {
          await _wheelTo(tester, hour: 12, minute: 15);
          await tester.tap(
            find.byKey(const ValueKey<String>('time-end-select')),
          );
          await tester.pumpAndSettle();
          await _wheelTo(tester, hour: 13, minute: 0);
        } else {
          await _enterClock(tester, 'start', '12:15');
          await _enterClock(tester, 'end', '13:00');
        }
        expect(find.textContaining('正在学习'), findsOneWidget);
        expect(find.textContaining('进行中'), findsWidgets);
        expect(_saveButton(tester).onPressed, isNull);
        expect(
          await fixture.database.select(fixture.database.timeEntries).get(),
          hasLength(1),
        );
        await _capture(tester, '${platform.name}-conflict');
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    });
  }

  testWidgets('安卓滚轮逐分钟调整并显式选择跨天日期，起止切换保留值', (WidgetTester tester) async {
    // 未使用业务导航壳的真实补记弹窗。
    final _DialogFixture fixture = await _pumpDialog(
      tester,
      platform: TargetPlatform.android,
    );
    try {
      await _wheelTo(tester, hour: 23, minute: 57);
      await tester.tap(find.byKey(const ValueKey<String>('time-end-select')));
      await tester.pumpAndSettle();
      await _wheelTo(tester, hour: 0, minute: 2);
      expect(find.text('结束时间必须晚于开始时间'), findsOneWidget);
      expect(_saveButton(tester).onPressed, isNull);
      expect(
        DateUtils.dateOnly(_dateButton(tester, 'end').value!),
        DateUtils.dateOnly(_now),
      );
      _dateButton(tester, 'end').onChanged!(DateTime(2026, 10, 8));
      await tester.pumpAndSettle();
      expect(find.text('结束 · 次日'), findsOneWidget);
      expect(find.text('共 5 分钟'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('time-start-select')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TimeEntryWheelPicker>(find.byType(TimeEntryWheelPicker))
            .value,
        const TimeOfDay(hour: 23, minute: 57),
      );
      await _capture(tester, 'android-cross-day');
      await _enterActivity(tester, '跨天精确补记');
      await tester.tap(find.text('保存记录'));
      await tester.pumpAndSettle();
      // 保存同一条绝对时间记录，不被五分钟步长取整。
      final TimeEntryRecord saved = await fixture.database
          .select(fixture.database.timeEntries)
          .getSingle();
      expect(saved.startedAt, DateTime(2026, 10, 7, 23, 57));
      expect(saved.endedAt, DateTime(2026, 10, 8, 0, 2));
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets('安卓真实拖动吸附到分钟刻度且快速切换不串改另一端', (WidgetTester tester) async {
    // 真实触控滚轮，不用按钮代替滑动。
    final _DialogFixture fixture = await _pumpDialog(
      tester,
      platform: TargetPlatform.android,
    );
    try {
      await tester.timedDrag(
        find.byKey(const ValueKey<String>('time-wheel-minute')),
        const Offset(0, -55),
        const Duration(milliseconds: 500),
      );
      await tester.pumpAndSettle();
      // 实际吸附位置和表单中显示的开始时刻。
      final ListWheelScrollView wheel = tester.widget<ListWheelScrollView>(
        find.byKey(const ValueKey<String>('time-wheel-minute')),
      );
      // 不依赖设备速度的实际分钟位置。
      final int minute =
          (wheel.controller! as FixedExtentScrollController).selectedItem % 60;
      expect(minute, isNot(20));
      expect(
        tester
            .widget<TimeEntryWheelPicker>(find.byType(TimeEntryWheelPicker))
            .value
            .minute,
        minute,
      );
      await tester.tap(find.byKey(const ValueKey<String>('time-end-select')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TimeEntryWheelPicker>(find.byType(TimeEntryWheelPicker))
            .value,
        const TimeOfDay(hour: 10, minute: 20),
      );
      await tester.tap(find.byKey(const ValueKey<String>('time-start-select')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TimeEntryWheelPicker>(find.byType(TimeEntryWheelPicker))
            .value
            .minute,
        minute,
      );
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets('默认区间读取完成前禁用保存，完成后只初始化一次', (WidgetTester tester) async {
    // 可控等待仍使用真实数据库和正式仓储查询。
    final Completer<void> gate = Completer<void>();
    // 已有记录会截短默认区间。
    final _DialogFixture fixture = await _pumpDialog(
      tester,
      platform: TargetPlatform.windows,
      defaultLoadGate: gate,
      seed: TimeEntryDraft(
        startedAt: DateTime(2026, 10, 7, 9),
        endedAt: DateTime(2026, 10, 7, 9, 43),
        activity: '初始化占用',
      ),
    );
    try {
      expect(find.text('正在计算空闲时间…'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('time-start-input')),
        findsNothing,
      );
      expect(_saveButton(tester).onPressed, isNull);
      gate.complete();
      await tester.pumpAndSettle();
      expect(_clockText(tester, 'start'), '09:43');
      expect(_saveButton(tester).onPressed, isNotNull);
      await _enterClock(tester, 'start', '10:05');
      await tester.runAsync(
        () => TimeEntryRepository(fixture.database).save(
          TimeEntryDraft(
            startedAt: DateTime(2026, 10, 7, 8),
            endedAt: DateTime(2026, 10, 7, 8, 30),
            activity: '之后新增的记录',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_clockText(tester, 'start'), '10:05');
      expect(_clockText(tester, 'end'), '10:20');
      expect(tester.takeException(), isNull);
    } finally {
      if (!gate.isCompleted) gate.complete();
      await fixture.dispose(tester);
    }
  });

  testWidgets('默认区间读取失败可取消或重试，成功后避开占用', (WidgetTester tester) async {
    // 首次失败不会放行可能重叠的一小时默认值。
    final _DialogFixture fixture = await _pumpDialog(
      tester,
      platform: TargetPlatform.windows,
      failFirstDefaultLoad: true,
      seed: TimeEntryDraft(
        startedAt: DateTime(2026, 10, 7, 9),
        endedAt: DateTime(2026, 10, 7, 9, 43),
        activity: '初始化占用',
      ),
    );
    try {
      expect(find.text('读取已有记录失败，请重试'), findsOneWidget);
      expect(_saveButton(tester).onPressed, isNull);
      expect(find.text('取消'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(_clockText(tester, 'start'), '09:43');
      expect(_clockText(tester, 'end'), '10:20');
      expect(_saveButton(tester).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets('Windows 左侧阻挡停在非五分钟边界并回弹，反向移动立即恢复', (WidgetTester tester) async {
    // 昨日和非整五分钟的记录末尾都必须作为真实障碍。
    final _DialogFixture fixture = await _pumpDialog(
      tester,
      platform: TargetPlatform.windows,
      seed: TimeEntryDraft(
        startedAt: DateTime(2026, 10, 7, 9),
        endedAt: DateTime(2026, 10, 7, 9, 43),
        activity: '左侧障碍',
      ),
    );
    try {
      await _enterClock(tester, 'start', '10:01');
      await _enterClock(tester, 'end', '10:21');
      // 一次大幅跳跃试图越过整个已有区间。
      final RangeSlider slider = tester.widget<RangeSlider>(
        find.byType(RangeSlider),
      );
      slider.onChanged!(RangeValues(500, slider.values.end));
      await tester.pump();
      expect(_dateButton(tester, 'start').value, DateTime(2026, 10, 7, 9, 43));
      expect(_dateButton(tester, 'end').value, DateTime(2026, 10, 7, 10, 21));
      expect(_blockValue(tester), greaterThan(0));
      expect(
        find.byKey(const ValueKey<String>('time-conflict-message')),
        findsNothing,
      );
      expect(_saveButton(tester).onPressed, isNotNull);
      await tester.pumpAndSettle();
      expect(_blockValue(tester), closeTo(0, 0.01));
      // 再次碰撞后，不等待回弹完成就向空闲侧移动。
      final RangeSlider stopped = tester.widget<RangeSlider>(
        find.byType(RangeSlider),
      );
      stopped.onChanged!(RangeValues(500, stopped.values.end));
      await tester.pump();
      expect(_blockValue(tester), greaterThan(0));
      final RangeSlider bouncing = tester.widget<RangeSlider>(
        find.byType(RangeSlider),
      );
      bouncing.onChanged!(RangeValues(600, bouncing.values.end));
      await tester.pump();
      expect(_clockText(tester, 'start'), '10:00');
      expect(_clockText(tester, 'end'), '10:21');
      expect(_blockValue(tester), 0);
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets('Windows 真实鼠标不能越过右侧记录，回弹期间可立即回退并保存', (WidgetTester tester) async {
    // 右侧障碍使用非五分钟开始边界，默认一小时仍保持空闲。
    final _DialogFixture fixture = await _pumpDialog(
      tester,
      platform: TargetPlatform.windows,
      seed: TimeEntryDraft(
        startedAt: DateTime(2026, 10, 7, 12, 3),
        endedAt: DateTime(2026, 10, 7, 13),
        activity: '右侧障碍',
      ),
    );
    try {
      await _enterClock(tester, 'start', '10:01');
      await _enterClock(tester, 'end', '10:21');
      // 由生产滑轨几何计算鼠标位置。
      final Rect track = _sliderTrack(tester);
      // 拖动前的可见窗口。
      final RangeSlider initial = tester.widget<RangeSlider>(
        find.byType(RangeSlider),
      );
      // 当前结束手柄位置。
      final double endX =
          track.left +
          track.width *
              (initial.values.end - initial.min) /
              (initial.max - initial.min);
      // 同一次真实鼠标按下，用快速长距离移动跨过整段记录。
      final TestGesture gesture = await tester.startGesture(
        Offset(endX, track.center.dy),
        kind: ui.PointerDeviceKind.mouse,
      );
      await gesture.moveTo(
        Offset(
          track.left +
              track.width * (810 - initial.min) / (initial.max - initial.min),
          track.center.dy,
        ),
      );
      await tester.pump();
      expect(_clockText(tester, 'end'), '12:03');
      expect(_clockText(tester, 'start'), '10:01');
      // 帧后同步的精确输入也完成绘制，仍在阻挡回弹期间核对界面。
      await tester.pump(const Duration(milliseconds: 16));
      expect(_blockValue(tester), greaterThan(0));
      expect(_saveButton(tester).onPressed, isNotNull);
      await _capture(tester, 'windows-right-blocked');
      // 回弹进行中直接反向拖回 11:00，值必须立即跟随。
      await gesture.moveTo(
        Offset(
          track.left +
              track.width * (660 - initial.min) / (initial.max - initial.min),
          track.center.dy,
        ),
      );
      await tester.pump();
      expect(_clockText(tester, 'end'), '11:00');
      expect(_clockText(tester, 'start'), '10:01');
      expect(_blockValue(tester), 0);
      await gesture.up();
      await tester.pumpAndSettle();
      await _enterActivity(tester, '鼠标阻挡回退');
      await tester.tap(find.text('保存记录'));
      await tester.pumpAndSettle();
      // 实际保存没有覆盖已有障碍记录。
      final List<TimeEntryRecord> records = await fixture.database
          .select(fixture.database.timeEntries)
          .get();
      final TimeEntryRecord added = records.singleWhere(
        (TimeEntryRecord record) => record.activity == '鼠标阻挡回退',
      );
      expect(added.startedAt, DateTime(2026, 10, 7, 10, 1));
      expect(added.endedAt, DateTime(2026, 10, 7, 11));
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets('Windows 减少动画时仍阻挡进行中记录且没有位移回弹', (WidgetTester tester) async {
    // 未来已开始的进行中区间向右持续占用。
    final _DialogFixture fixture = await _pumpDialog(
      tester,
      platform: TargetPlatform.windows,
      seed: TimeEntryDraft(
        startedAt: DateTime(2026, 10, 7, 13, 17),
        activity: '未来进行中',
      ),
    );
    try {
      fixture.media.value = fixture.media.value.copyWith(
        disableAnimations: true,
      );
      await tester.pump();
      // 禁用动画不改变阻挡规则，且不把边界吸附成 13:15 或 13:20。
      final RangeSlider slider = tester.widget<RangeSlider>(
        find.byType(RangeSlider),
      );
      slider.onChanged!(RangeValues(slider.values.start, 850));
      await tester.pumpAndSettle();
      expect(_clockText(tester, 'end'), '13:17');
      expect(_blockValue(tester), 0);
      expect(
        find.byKey(const ValueKey<String>('time-conflict-message')),
        findsNothing,
      );
      expect(_saveButton(tester).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets('Windows 编辑带秒的相邻记录时，阻挡保留原始起止值并排除自身', (WidgetTester tester) async {
    // 原记录与前段记录仅有十秒间隔，分钟投影也不能放行穿越。
    final _DialogFixture fixture = await _pumpDialog(
      tester,
      platform: TargetPlatform.windows,
      editing: true,
      seed: TimeEntryDraft(
        startedAt: DateTime(2026, 10, 7, 9, 43, 20),
        endedAt: DateTime(2026, 10, 7, 10, 1, 3),
        activity: '原有记录',
      ),
      seeds: <TimeEntryDraft>[
        TimeEntryDraft(
          startedAt: DateTime(2026, 10, 7, 9),
          endedAt: DateTime(2026, 10, 7, 9, 43, 10),
          activity: '前段记录',
        ),
      ],
    );
    try {
      // 本记录只作编辑对象，不参与自身冲突拦截。
      final RangeSlider slider = tester.widget<RangeSlider>(
        find.byType(RangeSlider),
      );
      slider.onChanged!(RangeValues(540, slider.values.end));
      await tester.pump();
      expect(_blockValue(tester), greaterThan(0));
      expect(
        _dateButton(tester, 'start').value,
        DateTime(2026, 10, 7, 9, 43, 20),
      );
      expect(_dateButton(tester, 'end').value, DateTime(2026, 10, 7, 10, 1, 3));
      expect(_saveButton(tester).onPressed, isNotNull);
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存记录'));
      await tester.pumpAndSettle();
      // 反向阻挡不会把已有秒数取整或新增另一条记录。
      final List<TimeEntryRecord> records = (await tester.runAsync(
        () => fixture.database.select(fixture.database.timeEntries).get(),
      ))!;
      final TimeEntryRecord saved = records.singleWhere(
        (TimeEntryRecord record) => record.activity == '原有记录',
      );
      expect(records, hasLength(2));
      expect(saved.startedAt, DateTime(2026, 10, 7, 9, 43, 20));
      expect(saved.endedAt, DateTime(2026, 10, 7, 10, 1, 3));
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets('Windows 精确输入与短区间保持一致，拖动只吸附一端，备注折叠保留内容', (
    WidgetTester tester,
  ) async {
    // Windows 补记真实控件及保存仓储。
    final _DialogFixture fixture = await _pumpDialog(
      tester,
      platform: TargetPlatform.windows,
    );
    try {
      await _enterClock(tester, 'start', '10:01');
      await _enterClock(tester, 'end', '10:03');
      expect(find.text('共 2 分钟'), findsOneWidget);
      // 不足五分钟也不夹成五分钟，摘要和滑轨一致。
      final RangeSlider slider = tester.widget<RangeSlider>(
        find.byType(RangeSlider),
      );
      expect(slider.values, const RangeValues(601, 603));
      slider.onChanged!(const RangeValues(601, 607));
      await tester.pumpAndSettle();
      expect(
        tester.widget<RangeSlider>(find.byType(RangeSlider)).values,
        const RangeValues(601, 605),
      );
      expect(_clockText(tester, 'start'), '10:01');
      expect(_clockText(tester, 'end'), '10:05');
      await _enterClock(tester, 'end', '25:70');
      expect(_saveButton(tester).onPressed, isNull);
      expect(find.text('请输入有效时刻（HH:mm）'), findsOneWidget);
      await _enterClock(tester, 'end', '10:07');
      await tester.tap(find.text('添加备注（可选）'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('time-entry-notes')),
        '备注内容',
      );
      await tester.tap(find.text('收起备注'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('time-entry-notes')),
        findsNothing,
      );
      await tester.tap(find.text('添加备注（可选）'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<OmniTextField>(
              find.byKey(const ValueKey<String>('time-entry-notes')),
            )
            .controller!
            .text,
        '备注内容',
      );
      await _enterActivity(tester, '逐分钟记录');
      await tester.tap(find.text('保存记录'));
      await tester.pumpAndSettle();
      // 真实存储保留一端非整五分钟，以及展开/折叠后的备注。
      final TimeEntryRecord saved = await fixture.database
          .select(fixture.database.timeEntries)
          .getSingle();
      expect(saved.startedAt, DateTime(2026, 10, 7, 10, 1));
      expect(saved.endedAt, DateTime(2026, 10, 7, 10, 7));
      expect(saved.notes, '备注内容');
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets('Windows 左扩展跨过零点到昨日且保留结束时刻并正确保存', (WidgetTester tester) async {
    // 使用真实补记入口验证边缘扩展与绝对日期保存。
    final _DialogFixture fixture = await _pumpDialog(
      tester,
      platform: TargetPlatform.windows,
    );
    try {
      await _enterClock(tester, 'end', '10:21');
      // 保留控件身份，跨日不能重建正在拖动的滑轨。
      final Element originalSlider = tester.element(find.byType(RangeSlider));
      for (int attempt = 0; attempt < 5; attempt += 1) {
        // 每次把开始端移到当前窗口左边缘，继续扩展。
        final RangeSlider slider = tester.widget<RangeSlider>(
          find.byType(RangeSlider),
        );
        if (slider.min < 0) break;
        slider.onChanged!(RangeValues(slider.min, slider.values.end));
        await tester.pumpAndSettle();
      }
      // 当天零点左侧必须有可选时间。
      final RangeSlider expanded = tester.widget<RangeSlider>(
        find.byType(RangeSlider),
      );
      expect(expanded.min, lessThan(0));
      expanded.onChanged!(RangeValues(-60, expanded.values.end));
      await tester.pumpAndSettle();
      expect(tester.element(find.byType(RangeSlider)), same(originalSlider));
      expect(_dateButton(tester, 'start').value, DateTime(2026, 10, 6, 23));
      expect(_dateButton(tester, 'end').value, DateTime(2026, 10, 7, 10, 21));
      expect(_clockText(tester, 'start'), '23:00');
      expect(_clockText(tester, 'end'), '10:21');
      expect(find.textContaining('昨日'), findsWidgets);
      await _enterActivity(tester, '昨日补记');
      await _capture(tester, 'windows-left-yesterday');
      await tester.tap(find.text('保存记录'));
      await tester.pumpAndSettle();
      // 保存为真实昨日开始、今日结束的一条记录。
      final TimeEntryRecord saved = await fixture.database
          .select(fixture.database.timeEntries)
          .getSingle();
      expect(saved.startedAt, DateTime(2026, 10, 6, 23));
      expect(saved.endedAt, DateTime(2026, 10, 7, 10, 21));
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets('Windows 同一次鼠标拖动可跨到昨日、前日并返回今日', (WidgetTester tester) async {
    // 让开始时间靠近零点，以真实指针覆盖跨日连续拖动。
    final _DialogFixture fixture = await _pumpDialog(
      tester,
      platform: TargetPlatform.windows,
    );
    try {
      await _enterClock(tester, 'start', '00:30');
      await _enterClock(tester, 'end', '01:31');
      // 真实滑轨和主题决定手柄位置，避免依赖外层控件的内边距。
      final Finder sliderFinder = find.byType(RangeSlider);
      // 跨日后的原滑轨必须保持同一个挂载实例。
      final Element original = tester.element(sliderFinder);
      // 当前滑轨绘制尺寸。
      final Rect track = _sliderTrack(tester);
      // 当前区间和窗口用于定位开始手柄。
      final RangeSlider initial = tester.widget<RangeSlider>(sliderFinder);
      // 开始手柄的真实横坐标。
      final double startX =
          track.left +
          track.width *
              (initial.values.start - initial.min) /
              (initial.max - initial.min);
      // 单次按下，直到返回今日后才释放鼠标。
      final TestGesture gesture = await tester.startGesture(
        Offset(startX, track.center.dy),
        kind: ui.PointerDeviceKind.mouse,
      );
      await gesture.moveTo(Offset(track.left - 2, track.center.dy));
      await tester.pumpAndSettle();
      await gesture.moveTo(Offset(track.left - 4, track.center.dy));
      await tester.pumpAndSettle();
      expect(
        _dateButton(tester, 'start').value!.isBefore(DateTime(2026, 10, 7)),
        isTrue,
      );
      expect(tester.element(sliderFinder), same(original));
      for (int attempt = 0; attempt < 5; attempt += 1) {
        await gesture.moveTo(
          Offset(track.left - 6 - attempt * 2, track.center.dy),
        );
        await tester.pumpAndSettle();
      }
      expect(
        _dateButton(tester, 'start').value!.isBefore(DateTime(2026, 10, 6)),
        isTrue,
      );
      expect(find.textContaining('-2 天'), findsWidgets);
      // 在同一次手势内回到今日零点附近，不能因跨日重建而丢失拖动。
      final RangeSlider expanded = tester.widget<RangeSlider>(sliderFinder);
      // 当前窗口内今日 00:15 的真实鼠标位置。
      final double returnX =
          track.left +
          track.width * (15 - expanded.min) / (expanded.max - expanded.min);
      await gesture.moveTo(Offset(returnX, track.center.dy));
      await tester.pump(const Duration(milliseconds: 700));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(_dateButton(tester, 'start').value, DateTime(2026, 10, 7, 0, 15));
      expect(_dateButton(tester, 'end').value, DateTime(2026, 10, 7, 1, 31));
      expect(tester.element(sliderFinder), same(original));
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets('Windows 左扩展展示昨日占用且阻止重叠保存', (WidgetTester tester) async {
    // 昨日已结束的记录不能在今日补记左扩展时漏掉。
    final _DialogFixture fixture = await _pumpDialog(
      tester,
      platform: TargetPlatform.windows,
      seed: TimeEntryDraft(
        startedAt: DateTime(2026, 10, 6, 22),
        endedAt: DateTime(2026, 10, 6, 23, 30),
        activity: '昨日已有记录',
      ),
    );
    try {
      for (int attempt = 0; attempt < 5; attempt += 1) {
        // 将开始端逐步拖到左侧，查询必须覆盖新窗口中的昨日记录。
        final RangeSlider slider = tester.widget<RangeSlider>(
          find.byType(RangeSlider),
        );
        if (slider.min < -120) break;
        slider.onChanged!(RangeValues(slider.min, slider.values.end));
        await tester.pumpAndSettle();
      }
      expect(find.text('已记录'), findsOneWidget);
      // 试图进入昨日 23:00 时，必须被挡在已有记录末尾。
      final RangeSlider expanded = tester.widget<RangeSlider>(
        find.byType(RangeSlider),
      );
      expanded.onChanged!(RangeValues(-60, expanded.values.end));
      await tester.pumpAndSettle();
      expect(_dateButton(tester, 'start').value, DateTime(2026, 10, 6, 23, 30));
      expect(_saveButton(tester).onPressed, isNotNull);
      expect(
        find.byKey(const ValueKey<String>('time-conflict-message')),
        findsNothing,
      );
      // 精确输入仍保留原冲突提示与保存拦截。
      await _enterClock(tester, 'start', '23:00');
      expect(find.textContaining('昨日已有记录'), findsOneWidget);
      expect(_saveButton(tester).onPressed, isNull);
      // 昨日 23:30 的相邻边界不重叠，可以保存。
      final RangeSlider conflicted = tester.widget<RangeSlider>(
        find.byType(RangeSlider),
      );
      conflicted.onChanged!(RangeValues(-30, conflicted.values.end));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('time-conflict-message')),
        findsNothing,
      );
      expect(_saveButton(tester).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets('Windows 超过两天的补记不被滑轨裁切', (WidgetTester tester) async {
    // 独立结束日期允许真实多天记录。
    final _DialogFixture fixture = await _pumpDialog(
      tester,
      platform: TargetPlatform.windows,
    );
    try {
      _dateButton(tester, 'end').onChanged!(DateTime(2026, 10, 10));
      await tester.pumpAndSettle();
      // 原 48 小时窗口外的结束分钟数。
      final int expectedEnd = DateTime(
        2026,
        10,
        10,
        10,
        20,
      ).difference(DateTime(2026, 10, 7)).inMinutes;
      expect(
        tester.widget<RangeSlider>(find.byType(RangeSlider)).values.end,
        expectedEnd,
      );
      expect(
        tester.widget<RangeSlider>(find.byType(RangeSlider)).max,
        greaterThanOrEqualTo(expectedEnd),
      );
      await _enterActivity(tester, '多天补记');
      await tester.tap(find.text('保存记录'));
      await tester.pumpAndSettle();
      expect(
        (await fixture.database
                .select(fixture.database.timeEntries)
                .getSingle())
            .endedAt,
        DateTime(2026, 10, 10, 10, 20),
      );
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });

  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.android,
    TargetPlatform.windows,
  ]) {
    testWidgets('${platform.name} 宽窄布局、大字号和软键盘保持平台输入及保存可达', (
      WidgetTester tester,
    ) async {
      // 同时覆盖安卓宽屏和窄桌面，不按屏宽切换选时控件。
      final _DialogFixture fixture = await _pumpDialog(
        tester,
        platform: platform,
        size: platform == TargetPlatform.android
            ? const Size(1200, 900)
            : const Size(512, 700),
      );
      try {
        expect(
          find.byType(RangeSlider),
          platform == TargetPlatform.windows ? findsOneWidget : findsNothing,
        );
        expect(
          find.byType(TimeEntryWheelPicker),
          platform == TargetPlatform.android ? findsOneWidget : findsNothing,
        );
        tester.view.physicalSize = const Size(360, 800);
        fixture.media.value = const MediaQueryData(
          size: Size(360, 800),
          textScaler: TextScaler.linear(2),
          viewInsets: EdgeInsets.only(bottom: 260),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        // 固定保存区仍完整位于键盘上方。
        final Rect saveRect = tester.getRect(find.text('保存记录'));
        expect(saveRect.bottom, lessThanOrEqualTo(540));
        await tester.ensureVisible(
          find.byKey(const ValueKey<String>('time-entry-activity')),
        );
        await tester.enterText(
          find.byKey(const ValueKey<String>('time-entry-activity')),
          '窄屏录入',
        );
        await tester.pumpAndSettle();
        expect(_saveButton(tester).onPressed, isNotNull);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    });

    testWidgets('${platform.name} 深色补记界面使用主题色且正常保存', (
      WidgetTester tester,
    ) async {
      // 深色方案使用生产主题，不重建固定配色。
      final _DialogFixture fixture = await _pumpDialog(
        tester,
        platform: platform,
        brightness: Brightness.dark,
      );
      try {
        await _capture(tester, '${platform.name}-dark');
        await _enterActivity(tester, '深色补记');
        await tester.tap(find.text('保存记录'));
        await tester.pumpAndSettle();
        expect(
          await fixture.database.select(fixture.database.timeEntries).get(),
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    });
  }
}

/// 创建使用真实主题、内存数据库和公开补记入口的隔离测试。
Future<_DialogFixture> _pumpDialog(
  WidgetTester tester, {
  required TargetPlatform platform,
  Brightness brightness = Brightness.light,
  TimeEntryDraft? seed,
  List<TimeEntryDraft> seeds = const <TimeEntryDraft>[],
  DateTime? now,
  Size? size,
  bool editing = false,
  Completer<void>? defaultLoadGate,
  bool failFirstDefaultLoad = false,
}) async {
  // 当前平台的代表性窗口尺寸。
  final Size viewport =
      size ??
      (platform == TargetPlatform.android
          ? const Size(390, 844)
          : const Size(1440, 900));
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // 全部业务输入只写入测试内存数据库。
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  if (seed != null) {
    await tester.runAsync(() => TimeEntryRepository(database).save(seed));
  }
  for (final TimeEntryDraft draft in seeds) {
    await tester.runAsync(() => TimeEntryRepository(database).save(draft));
  }
  // 可覆盖凌晨场景的稳定当前时刻。
  final DateTime effectiveNow = now ?? _now;
  await tester.runAsync(
    () =>
        TaxonomyRepository(database)
            .watch(module: TaxonomyModule.timeline, kind: TaxonomyKind.category)
            .first,
  );
  await TaxonomyRepository(database).save(
    const TaxonomyDraft(
      module: TaxonomyModule.timeline,
      kind: TaxonomyKind.category,
      name: '专项类别',
      colorValue: 0xFFB25DA6,
    ),
  );
  // 可控依赖容器，绕过生产同步和宿主窗口初始化。
  final ProviderContainer container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      nowProvider.overrideWithValue(effectiveNow),
      if (defaultLoadGate != null || failFirstDefaultLoad)
        timeEntryRepositoryProvider.overrideWithValue(
          _DefaultRangeTestRepository(
            database,
            gate: defaultLoadGate,
            failFirst: failFirstDefaultLoad,
          ),
        ),
    ],
  );
  // 显式媒体状态支持大字号及键盘缩小可用高度。
  final ValueNotifier<MediaQueryData> media = ValueNotifier<MediaQueryData>(
    MediaQueryData(size: viewport),
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: const ValueKey<String>('backfill-preview'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.build(brightness: brightness)
              .copyWith(platform: platform),
          builder: (BuildContext context, Widget? child) =>
              ValueListenableBuilder<MediaQueryData>(
                valueListenable: media,
                builder: (
                  BuildContext context,
                  MediaQueryData data,
                  Widget? _,
                ) => MediaQuery(data: data, child: child!),
              ),
          home: Scaffold(
            body: editing
                ? const TimelinePage()
                : Builder(
                    builder: (BuildContext context) => Center(
                      child: OmniButton(
                        label: '打开补记',
                        onPressed: () => showBackfillTimeEntryDialog(
                          context,
                          day: effectiveNow,
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    ),
  );
  if (editing) {
    await tester.pumpAndSettle();
    await tester.tap(find.text('记录明细'));
    await tester.pumpAndSettle();
    // 明细行是实际编辑入口，避免点击时间轴的重复活动标签。
    final Finder row = find.ancestor(
      of: find.text('原有记录'),
      matching: find.byType(OmniListRow),
    );
    await tester.ensureVisible(row);
    await tester.tap(row);
  } else {
    await tester.tap(find.text('打开补记'));
  }
  if (defaultLoadGate != null && !defaultLoadGate.isCompleted) {
    await tester.pump(const Duration(milliseconds: 240));
  } else {
    await tester.pumpAndSettle();
  }
  return _DialogFixture(database: database, container: container, media: media);
}

/// 保留弹窗实际布局与操作区的中文截图，普通回归不写图片。
Future<void> _capture(WidgetTester tester, String name) async {
  // 当前显式请求的预览目录。
  final String? directory = Platform.environment['OMNI_BACKFILL_PREVIEW_DIR'];
  if (directory == null) return;
  // 包含真实对话框及菜单的整窗渲染边界。
  final RenderRepaintBoundary boundary = tester
      .renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey<String>('backfill-preview')),
      );
  await tester.runAsync(() async {
    // 实际 Flutter 绘制产生的图片。
    final ui.Image image = await boundary.toImage();
    // 无损 PNG 编码。
    final ByteData bytes = (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!;
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png').writeAsBytes(bytes.buffer.asUint8List());
    image.dispose();
  });
}

/// 输入活动时滚入可见区域，覆盖键盘避让后的真实输入。
Future<void> _enterActivity(WidgetTester tester, String value) async {
  await tester.ensureVisible(
    find.byKey(const ValueKey<String>('time-entry-activity')),
  );
  await tester.enterText(
    find.byKey(const ValueKey<String>('time-entry-activity')),
    value,
  );
  await tester.pumpAndSettle();
}

/// 修改精确时分并等待摘要和滑轨同步。
Future<void> _enterClock(
  WidgetTester tester,
  String endpoint,
  String value,
) async {
  await tester.enterText(
    find.byKey(ValueKey<String>('time-$endpoint-input')),
    value,
  );
  await tester.pumpAndSettle();
}

/// 将两列真实滚动控制器定位到指定时分，触发正式选择回调。
Future<void> _wheelTo(
  WidgetTester tester, {
  required int hour,
  required int minute,
}) async {
  // 当前小时列。
  final ListWheelScrollView hourWheel = tester.widget<ListWheelScrollView>(
    find.byKey(const ValueKey<String>('time-wheel-hour')),
  );
  (hourWheel.controller! as FixedExtentScrollController).jumpToItem(hour);
  await tester.pumpAndSettle();
  // 当前分钟列。
  final ListWheelScrollView minuteWheel = tester.widget<ListWheelScrollView>(
    find.byKey(const ValueKey<String>('time-wheel-minute')),
  );
  (minuteWheel.controller! as FixedExtentScrollController).jumpToItem(minute);
  await tester.pumpAndSettle();
}

/// 返回实际回弹时钟的位移，用于验证触碰反馈与即时中断。
double _blockValue(WidgetTester tester) =>
    (tester
                .widget<AnimatedBuilder>(
                  find.byKey(
                    const ValueKey<String>('time-range-block-animation'),
                  ),
                )
                .animation
            as Animation<double>)
        .value;

/// 计算生产滑轨的真实绘制边界，供鼠标拖动回归使用。
Rect _sliderTrack(WidgetTester tester) {
  // 当前滑块及其父级业务主题。
  final Finder finder = find.byType(RangeSlider);
  // 生产主题中的轨道形状和手柄尺寸。
  final SliderThemeData theme = SliderTheme.of(tester.element(finder));
  return theme.rangeTrackShape!.getPreferredRect(
    parentBox: tester.renderObject<RenderBox>(finder),
    offset: tester.getTopLeft(finder),
    sliderTheme: theme,
    isEnabled: true,
    isDiscrete: false,
  );
}

/// 返回完整保存按钮状态。
OmniButton _saveButton(WidgetTester tester) =>
    tester.widget<OmniButton>(find.widgetWithText(OmniButton, '保存记录'));

/// 返回某一端的日期控件。
OmniDatePickerButton _dateButton(WidgetTester tester, String endpoint) =>
    tester.widget<OmniDatePickerButton>(
      find.byKey(ValueKey<String>('time-$endpoint-date')),
    );

/// 返回桌面时刻字段实际文本。
String _clockText(WidgetTester tester, String endpoint) => tester
    .widget<OmniTextFormField>(
      find.byKey(ValueKey<String>('time-$endpoint-input')),
    )
    .controller!
    .text;

/// 控制初始化时机和一次失败，仍使用正式数据库查询。
class _DefaultRangeTestRepository extends TimeEntryRepository {
  /// 一次加载等待，不影响实时占用监听。
  final Completer<void>? gate;

  /// 是否让首次加载失败。
  final bool failFirst;

  /// 默认快照实际读取次数。
  int _loads = 0;

  /// 创建保留生产查询行为的测试仓储。
  _DefaultRangeTestRepository(
    super.database, {
    this.gate,
    this.failFirst = false,
  });

  /// 只控制初始化读取的等待和一次失败。
  @override
  Future<List<TimeEntryRecord>> loadForRange(
    DateTime start,
    DateTime end,
  ) async {
    _loads += 1;
    if (gate != null) await gate!.future;
    if (failFirst && _loads == 1) throw StateError('测试首次读取失败');
    return super.loadForRange(start, end);
  }
}

/// 单项测试持有的隔离资源。
class _DialogFixture {
  /// 测试内存数据库。
  final AppDatabase database;

  /// 显式依赖容器。
  final ProviderContainer container;

  /// 当前测试媒体参数。
  final ValueNotifier<MediaQueryData> media;

  /// 创建测试资源集合。
  const _DialogFixture({
    required this.database,
    required this.container,
    required this.media,
  });

  /// 卸载弹窗并排空查询订阅，再关闭数据库。
  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    media.dispose();
    await tester.runAsync(database.close);
  }
}
