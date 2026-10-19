import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/features/notes/presentation/note_record_time_picker.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 创建只有选择入口的测试页面，明确指定平台和明暗主题。
Widget _host({
  required TargetPlatform platform,
  required VoidCallback Function(BuildContext context) onOpen,
  Brightness brightness = Brightness.light,
  bool reducedMotion = false,
  double textScale = 1,
}) => RepaintBoundary(
  key: const ValueKey<String>('note-record-time-preview'),
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        disableAnimations: reducedMotion,
        textScaler: TextScaler.linear(textScale),
      ),
      child: child!,
    ),
    theme: AppTheme.build(brightness: brightness).copyWith(platform: platform),
    home: Scaffold(
      body: Builder(
        builder: (BuildContext context) => Align(
          alignment: Alignment.topLeft,
          child: TextButton(
            onPressed: onOpen(context),
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  ),
);

/// 阴影调试开关变化后重新绘制全部图层，不重装或重建业务状态。
void _repaint(RenderObject object) {
  object.markNeedsPaint();
  object.visitChildren(_repaint);
}

/// 保存包含真实中文与完整浮层的预览；普通测试不执行图片编码。
Future<void> _capturePicker(
  WidgetTester tester,
  String name,
  String directory,
) async {
  if (!const bool.fromEnvironment('NOTE_RECORD_TIME_SCREENSHOTS')) return;
  // 预览使用实际柔和阴影；测试框架默认以硬边替代阴影，不能据此验收。
  final bool previousShadows = debugDisableShadows;
  debugDisableShadows = false;
  // 根边界同时包含导航覆盖层。
  final RenderRepaintBoundary boundary = tester.renderObject(
    find.byKey(const ValueKey<String>('note-record-time-preview')),
  );
  _repaint(boundary);
  await tester.pumpAndSettle();
  try {
    await tester.runAsync(() async {
      // 图片导出使用真实异步时钟。
      final ui.Image image = await boundary.toImage(pixelRatio: 1);
      try {
        // 无损编码保留文字、细线和实色。
        final ByteData bytes = (await image.toByteData(
          format: ui.ImageByteFormat.png,
        ))!;
        await Directory('build/$directory').create(recursive: true);
        await File('build/$directory/$name.png')
            .writeAsBytes(bytes.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  } finally {
    debugDisableShadows = previousShadows;
    _repaint(boundary);
    await tester.pumpAndSettle();
  }
}

/// 验证两端选择的取消、精确时间、边界和保存失败恢复。
void main() {
  setUpAll(() async {
    if (!const bool.fromEnvironment('NOTE_RECORD_TIME_SCREENSHOTS')) return;
    // 截图采用真实中文字体，普通回归不依赖本机字体文件。
    final ByteData font = ByteData.sublistView(
      await File(
        Platform.environment['OMNI_UI_FONT'] ?? 'C:/Windows/Fonts/msyh.ttc',
      ).readAsBytes(),
    );
    for (final String family in <String>[
      'Roboto',
      'Ahem',
      'Noto Sans CJK SC',
      'Microsoft YaHei UI',
      'Microsoft YaHei',
    ]) {
      // 覆盖各平台及测试框架可能采用的默认字体别名。
      final FontLoader loader = FontLoader(family)
        ..addFont(Future<ByteData>.value(font));
      await loader.load();
    }
    // 图标与应用使用相同的 Material 字形。
    final FontLoader icons = FontLoader('MaterialIcons')
      ..addFont(
        File(
          Platform.environment['OMNI_UI_ICONS'] ?? 'D:/program/code/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
        ).readAsBytes().then(ByteData.sublistView),
      );
    await icons.load();
  });

  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.android,
    TargetPlatform.windows,
  ]) {
    for (final Brightness brightness in Brightness.values) {
      testWidgets('记录日期中文预览 ${platform.name} ${brightness.name}', (
        WidgetTester tester,
      ) async {
        // 手机竖屏与桌面实际尺寸均覆盖中文明暗主题。
        tester.view.physicalSize = platform == TargetPlatform.android
            ? const Size(390, 844)
            : const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          _host(
            platform: platform,
            brightness: brightness,
            onOpen: (BuildContext context) => () async {
              if (platform == TargetPlatform.android) {
                await showAndroidNoteRecordTimePicker(
                  context,
                  initialValue: DateTime.utc(2026, 10, 18, 12, 34, 56),
                  now: DateTime.utc(2026, 10, 19, 16),
                );
              } else {
                await showWindowsNoteRecordTimePicker(
                  context,
                  anchor: const Rect.fromLTWH(440, 160, 40, 24),
                  initialValue: DateTime.utc(2026, 10, 18, 12, 34, 56),
                  now: DateTime.utc(2026, 10, 19, 16),
                  onConfirm: (DateTime value) async {},
                );
              }
            },
          ),
        );
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (!const bool.fromEnvironment('NOTE_RECORD_TIME_SCREENSHOTS')) return;
        await _capturePicker(
          tester,
          '${platform.name}_${brightness.name}',
          'note-record-time-preview',
        );
      });
    }
  }

  testWidgets('安卓窄屏双倍字号滚轮读屏增减尊重减少动画', (WidgetTester tester) async {
    // 窄屏保留横向滚动与放大后的刻度高度。
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // 显式保持语义树以验证真正的读屏增减入口。
    final SemanticsHandle handle = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        _host(
          platform: TargetPlatform.android,
          reducedMotion: true,
          textScale: 2,
          onOpen: (context) =>
              () => showAndroidNoteRecordTimePicker(
                context,
                initialValue: DateTime.utc(2024, 2, 29, 12, 34, 56),
                now: DateTime.utc(2026, 10, 19, 16),
              ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      // 读屏动作应即时跳转，不能以零时长animateTo触发框架断言。
      final SemanticsNode node = tester.getSemantics(
        find.bySemanticsLabel('记录时间分'),
      );
      node.owner!.performAction(node.id, ui.SemanticsAction.increase);
      await tester.pumpAndSettle();
      expect(
        tester
            .getSemantics(find.bySemanticsLabel('记录时间分'))
            .getSemanticsData()
            .value,
        '35',
      );
      expect(tester.takeException(), isNull);
    } finally {
      handle.dispose();
    }
  });

  testWidgets('安卓关闭不应用选择，确认返回完整年月日时分秒', (WidgetTester tester) async {
    // 最近一次关闭结果；非空初值用于确认取消确实返回空值。
    DateTime? result = DateTime.utc(2000);
    await tester.pumpWidget(
      _host(
        platform: TargetPlatform.android,
        onOpen: (BuildContext context) => () async {
          result = await showAndroidNoteRecordTimePicker(
            context,
            initialValue: DateTime.utc(2024, 2, 29, 12, 34, 56),
            now: DateTime.utc(2026, 10, 19, 16),
          );
        },
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('2024年02月29日 星期四'), findsOneWidget);
    expect(find.byType(ListWheelScrollView), findsNWidgets(6));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isNull);

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(result, DateTime.utc(2024, 2, 29, 12, 34, 56));
  });

  testWidgets('安卓闰日切到下一年收敛为二月最后一天', (WidgetTester tester) async {
    // 年份滚轮切换后的确认结果。
    DateTime? result;
    await tester.pumpWidget(
      _host(
        platform: TargetPlatform.android,
        brightness: Brightness.dark,
        onOpen: (BuildContext context) => () async {
          result = await showAndroidNoteRecordTimePicker(
            context,
            initialValue: DateTime.utc(2024, 2, 29, 12, 34, 56),
            now: DateTime.utc(2026, 10, 19, 16),
          );
        },
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    // 通过滚轮控制器模拟吸附至下一年，避免像素惯性影响测试。
    final ListWheelScrollView yearWheel = tester.widget(
      find.byKey(const ValueKey<String>('note-record-time-wheel-0')),
    );
    (yearWheel.controller! as FixedExtentScrollController).jumpToItem(
      2025 - 1970,
    );
    await tester.pumpAndSettle();
    expect(find.text('2025年02月28日 星期五'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(result, DateTime.utc(2025, 2, 28, 12, 34, 56));
    expect(tester.takeException(), isNull);
  });

  testWidgets('越界历史初值保持原样显示，确认禁用直到用户修正', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        platform: TargetPlatform.android,
        onOpen: (BuildContext context) => () async {
          await showAndroidNoteRecordTimePicker(
            context,
            initialValue: DateTime.utc(1969, 12, 31, 23, 59, 59),
            now: DateTime.utc(2026, 10, 19, 16),
          );
        },
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('1969年12月31日 星期三'), findsOneWidget);
    expect(
      tester
          .widget<OmniButton>(
            find.byKey(const ValueKey<String>('note-record-time-confirm')),
          )
          .onPressed,
      isNull,
    );
    // 保留初始越界年份，用户仍能通过滚轮修正到最早合法年份。
    final ListWheelScrollView yearWheel = tester.widget(
      find.byKey(const ValueKey<String>('note-record-time-wheel-0')),
    );
    (yearWheel.controller! as FixedExtentScrollController).jumpToItem(1);
    await tester.pumpAndSettle();
    expect(find.text('1970年12月31日 星期四'), findsOneWidget);
    expect(
      tester
          .widget<OmniButton>(
            find.byKey(const ValueKey<String>('note-record-time-confirm')),
          )
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  for (final Brightness brightness in Brightness.values) {
    testWidgets('Windows视频布局与三列时间浮层 ${brightness.name}', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(392, 444);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // 整个日期浮层只有主确定会触发正式保存。
      DateTime? saved;
      await tester.pumpWidget(
        _host(
          platform: TargetPlatform.windows,
          brightness: brightness,
          onOpen: (BuildContext context) =>
              () => showWindowsNoteRecordTimePicker(
                context,
                anchor: const Rect.fromLTWH(46, 0, 0, 23),
                initialValue: DateTime.utc(2026, 10, 15, 19, 47, 11),
                now: DateTime.utc(2026, 10, 19, 20),
                onConfirm: (DateTime value) async => saved = value,
              ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      // 主面板与视频同尺寸，底栏只有一枚主确认。
      final Finder panel = find.byKey(
        const ValueKey<String>('windows-note-record-time-panel'),
      );
      expect(tester.getSize(panel), const Size(324, 390));
      expect(find.text('设定日期'), findsNothing);
      expect(find.text('取消'), findsNothing);
      expect(find.text('确定'), findsOneWidget);
      expect(
        tester.getCenter(find.text('日')).dx,
        lessThan(tester.getCenter(find.text('一')).dx),
      );
      expect(
        find.byWidgetPredicate(
          (Widget widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(
                'note-record-time-day-',
              ),
        ),
        findsNWidgets(42),
      );
      expect(
        tester
            .widget<OmniTextButton>(
              find.byKey(
                const ValueKey<String>('note-record-time-day-2026-10-20'),
              ),
            )
            .onPressed,
        isNull,
      );
      await _capturePicker(
        tester,
        '${brightness.name}-calendar',
        'windows-record-time-video-preview',
      );
      // 年/月分开导航；未来月份可浏览但日期不可选择。
      await tester.tap(find.byTooltip('下个月'));
      await tester.pumpAndSettle();
      expect(find.text('2026 年 11 月'), findsOneWidget);
      expect(
        tester
            .widget<OmniTextButton>(
              find.byKey(
                const ValueKey<String>('note-record-time-day-2026-11-01'),
              ),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byTooltip('上个月'));
      await tester.tap(find.byTooltip('上一年'));
      await tester.pumpAndSettle();
      expect(find.text('2025 年 10 月'), findsOneWidget);
      await tester.tap(find.byTooltip('下一年'));
      await tester.pumpAndSettle();
      // 时间子面板覆盖月历，主面板仍保持390高度。
      final Finder input = find.byKey(
        const ValueKey<String>('note-record-time-input'),
      );
      await tester.tap(input);
      await tester.pumpAndSettle();
      final Finder clock = find.byKey(
        const ValueKey<String>('note-record-time-clock-panel'),
      );
      expect(tester.getSize(clock), const Size(180, 228));
      expect(tester.getRect(clock).bottom, tester.getRect(panel).bottom - 60);
      expect(tester.getRect(clock).left, tester.getRect(panel).left + 14);
      expect(find.byType(ListWheelScrollView), findsNWidgets(3));
      // 真实鼠标滚轮先改变时，再逐列定位视频中的时分秒。
      final Finder hour = find.byKey(
        const ValueKey<String>('note-record-time-clock-0'),
      );
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(hour),
          scrollDelta: const Offset(0, 32),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        (tester.widget<ListWheelScrollView>(hour).controller!
                as FixedExtentScrollController)
            .selectedItem,
        20,
      );
      for (int column = 0; column < 3; column++) {
        // 单独控制三列，不能滚动一列时覆盖其他列。
        final ListWheelScrollView wheel = tester.widget(
          find.byKey(ValueKey<String>('note-record-time-clock-$column')),
        );
        (wheel.controller! as FixedExtentScrollController).jumpToItem(
          <int>[14, 48, 23][column],
        );
        await tester.pumpAndSettle();
      }
      expect(find.text('14:48:23'), findsOneWidget);
      expect(saved, isNull);
      await _capturePicker(
        tester,
        '${brightness.name}-clock',
        'windows-record-time-video-preview',
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('note-record-time-clock-cancel')),
      );
      await tester.pumpAndSettle();
      expect(find.text('19:47:11'), findsOneWidget);
      expect(clock, findsNothing);
      // 子面板确定只应用时钟草稿，主面板确定才正式保存。
      await tester.tap(input);
      await tester.pumpAndSettle();
      await tester.enterText(input, '14:48:23');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        (tester.widget<ListWheelScrollView>(hour).controller!
                as FixedExtentScrollController)
            .selectedItem,
        14,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('note-record-time-clock-confirm')),
      );
      await tester.pumpAndSettle();
      expect(clock, findsNothing);
      expect(saved, isNull);
      await tester.tap(
        find.byKey(const ValueKey<String>('note-record-time-confirm')),
      );
      await tester.pumpAndSettle();
      expect(saved, DateTime.utc(2026, 10, 15, 14, 48, 23));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Windows窄窗口双倍字号时间浮层完整可用', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _host(
        platform: TargetPlatform.windows,
        textScale: 2,
        reducedMotion: true,
        onOpen: (BuildContext context) =>
            () => showWindowsNoteRecordTimePicker(
              context,
              anchor: const Rect.fromLTWH(20, 0, 0, 0),
              initialValue: DateTime.utc(2024, 2, 29, 12, 34, 56),
              now: DateTime.utc(2026, 10, 19),
              onConfirm: (_) async {},
            ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('note-record-time-input')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('note-record-time-input')),
    );
    await tester.pumpAndSettle();
    // 放大时间浮层仍限制在主面板内，三列与操作入口保持可见。
    final Rect panel = tester.getRect(
      find.byKey(const ValueKey<String>('windows-note-record-time-panel')),
    );
    // 子浮层真实边界用于检查右侧不被裁切。
    final Rect clock = tester.getRect(
      find.byKey(const ValueKey<String>('note-record-time-clock-panel')),
    );
    expect(clock.right, lessThanOrEqualTo(panel.right));
    expect(
      find
          .byKey(const ValueKey<String>('note-record-time-clock-confirm'))
          .hitTestable(),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('note-record-time-clock-cancel')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('note-record-time-clock-panel')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows Escape先取消时间子面板，再关闭日期且不保存', (WidgetTester tester) async {
    // 两层取消不能触发正式保存。
    int calls = 0;
    await tester.pumpWidget(
      _host(
        platform: TargetPlatform.windows,
        onOpen: (BuildContext context) =>
            () => showWindowsNoteRecordTimePicker(
              context,
              anchor: const Rect.fromLTWH(32, 32, 0, 0),
              initialValue: DateTime.utc(2024, 2, 29, 12, 34, 56),
              now: DateTime.utc(2026, 10, 19),
              onConfirm: (_) async => calls++,
            ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('note-record-time-input')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('note-record-time-input')),
      '01:02:03',
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('note-record-time-clock-panel')),
      findsNothing,
    );
    expect(find.text('12:34:56'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('windows-note-record-time-panel')),
      findsNothing,
    );
    expect(calls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面精确输入必须确认才保存，未来时刻不能确认', (WidgetTester tester) async {
    // 保存回调收到的完整墙钟值。
    DateTime? saved;
    await tester.pumpWidget(
      _host(
        platform: TargetPlatform.windows,
        onOpen: (BuildContext context) => () async {
          await showWindowsNoteRecordTimePicker(
            context,
            anchor: const Rect.fromLTWH(32, 32, 40, 24),
            initialValue: DateTime.utc(2026, 10, 19, 12, 34, 56),
            now: DateTime.utc(2026, 10, 19, 16),
            onConfirm: (DateTime value) async => saved = value,
          );
        },
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('windows-note-record-time-panel')),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('note-record-time-input')),
      '17:00:00',
    );
    await tester.pumpAndSettle();
    expect(saved, isNull);
    expect(
      tester
          .widget<OmniTextButton>(
            find.byKey(const ValueKey<String>('note-record-time-confirm')),
          )
          .onPressed,
      isNull,
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('note-record-time-input')),
      '15:02:03',
    );
    await tester.pumpAndSettle();
    expect(saved, isNull);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(saved, DateTime.utc(2026, 10, 19, 15, 2, 3));
    expect(
      find.byKey(const ValueKey<String>('windows-note-record-time-panel')),
      findsNothing,
    );
  });

  testWidgets('桌面无效文本禁止提交，保存失败保留输入并可重试', (WidgetTester tester) async {
    // 保存调用次数，第一次模拟数据源写入失败。
    int calls = 0;
    // 成功关闭后返回的状态。
    bool? result;
    await tester.pumpWidget(
      _host(
        platform: TargetPlatform.windows,
        brightness: Brightness.dark,
        onOpen: (BuildContext context) => () async {
          result = await showWindowsNoteRecordTimePicker(
            context,
            anchor: const Rect.fromLTWH(32, 32, 40, 24),
            initialValue: DateTime.utc(1970, 1, 1),
            now: DateTime.utc(2026, 10, 19, 16),
            onConfirm: (DateTime value) async {
              calls++;
              if (calls == 1) throw StateError('write failed');
            },
          );
        },
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('note-record-time-input')),
      '25:02:03',
    );
    await tester.pumpAndSettle();
    expect(find.text('请输入 HH:mm:ss'), findsOneWidget);
    expect(
      tester
          .widget<OmniTextButton>(
            find.byKey(const ValueKey<String>('note-record-time-confirm')),
          )
          .onPressed,
      isNull,
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('note-record-time-input')),
      '01:02:03',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('修改日期失败，请重试'), findsOneWidget);
    expect(find.text('01:02:03'), findsOneWidget);
    expect(result, isNull);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(result, isTrue);
  });

  testWidgets('桌面保存中阻止 Escape 和重复提交，成功后关闭', (WidgetTester tester) async {
    // 受控异步写入，用于验证保存中的返回拦截。
    final Completer<void> pending = Completer<void>();
    // 本次保存回调调用次数。
    int calls = 0;
    await tester.pumpWidget(
      _host(
        platform: TargetPlatform.windows,
        onOpen: (BuildContext context) => () async {
          await showWindowsNoteRecordTimePicker(
            context,
            anchor: const Rect.fromLTWH(32, 32, 40, 24),
            initialValue: DateTime.utc(2026, 10, 18, 12, 34, 56),
            now: DateTime.utc(2026, 10, 19, 16),
            onConfirm: (DateTime value) {
              calls++;
              return pending.future;
            },
          );
        },
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(calls, 1);
    expect(
      find.byKey(const ValueKey<String>('windows-note-record-time-panel')),
      findsOneWidget,
    );
    pending.complete();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('windows-note-record-time-panel')),
      findsNothing,
    );
  });
}
