import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 验证统一日期与时间浮层的关键交互和视觉基线。
void main() {
  testWidgets('日期选择器从按钮下方展开且不创建模态弹窗', (WidgetTester tester) async {
    // 测试过程中当前选中的日期。
    DateTime selectedDate = DateTime(2026, 9, 2);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(brightness: Brightness.light),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(32),
            child: StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) {
                return Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 184,
                    child: OmniDatePickerButton(
                      value: selectedDate,
                      initialDate: selectedDate,
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                      currentDate: DateTime(2026, 9, 6),
                      label: '2026/09/02',
                      icon: null,
                      onChanged: (DateTime value) {
                        setState(() => selectedDate = value);
                      },
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('2026/09/02'));
    await tester.pumpAndSettle();

    expect(find.text('2026年9月'), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);

    // 日期网格内的六行按钮都必须完整落在网格边界内。
    final Finder dayGrid = find.byType(GridView);
    // 日期网格的实际边界。
    final Rect dayGridRect = tester.getRect(dayGrid);
    // 网格中的全部日期按钮。
    final Finder dayButtons = find.descendant(
      of: dayGrid,
      matching: find.byType(TextButton),
    );
    expect(dayButtons, findsNWidgets(42));
    for (final TextButton button in tester.widgetList<TextButton>(dayButtons)) {
      // 当前日期按钮的实际边界。
      final Rect buttonRect = tester.getRect(find.byWidget(button));
      expect(buttonRect.top, greaterThanOrEqualTo(dayGridRect.top));
      expect(buttonRect.bottom, lessThanOrEqualTo(dayGridRect.bottom));
    }

    await tester.tap(find.text('2026年9月'));
    await tester.pumpAndSettle();
    expect(find.text('1 月'), findsOneWidget);
    expect(find.text('12 月'), findsOneWidget);

    await tester.tap(find.text('10 月'));
    await tester.pumpAndSettle();
    expect(find.text('2026年10月'), findsOneWidget);

    await tester.tap(find.byTooltip('上个月'));
    await tester.pumpAndSettle();
    expect(find.text('2026年9月'), findsOneWidget);

    await tester.tap(find.text('14'));
    await tester.pumpAndSettle();

    expect(selectedDate, DateTime(2026, 9, 14));
    expect(find.text('2026年9月'), findsNothing);
  });

  testWidgets('时间选择器按半小时展示并保留已有分钟值', (WidgetTester tester) async {
    // 测试过程中当前选中的时间。
    TimeOfDay selectedTime = const TimeOfDay(hour: 17, minute: 55);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(brightness: Brightness.light),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(32),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 108,
                child: StatefulBuilder(
                  builder: (BuildContext context, StateSetter setState) {
                    return OmniTimePickerButton(
                      value: selectedTime,
                      label:
                          '${selectedTime.hour.toString().padLeft(2, '0')}:'
                          '${selectedTime.minute.toString().padLeft(2, '0')}',
                      icon: null,
                      onChanged: (TimeOfDay value) {
                        setState(() => selectedTime = value);
                      },
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('17:55'));
    await tester.pumpAndSettle();

    expect(find.text('17:55'), findsNWidgets(2));
    expect(find.text('18:00'), findsOneWidget);
    expect(find.text('18:30'), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);

    await tester.tap(find.text('18:30'));
    await tester.pumpAndSettle();

    expect(selectedTime, const TimeOfDay(hour: 18, minute: 30));
  });

  testWidgets('日期浮层视觉基线', (WidgetTester tester) async {
    // 视觉基线使用的固定视口。
    const Size viewport = Size(420, 420);
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(brightness: Brightness.light),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(32),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 184,
                child: OmniDatePickerButton(
                  value: DateTime(2026, 9, 2),
                  initialDate: DateTime(2026, 9, 2),
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                  currentDate: DateTime(2026, 9, 6),
                  label: '2026/09/02',
                  icon: null,
                  onChanged: (DateTime value) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('2026/09/02'));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/omni_date_picker_feishu_light.png'),
    );
  });

  testWidgets('时间浮层视觉基线', (WidgetTester tester) async {
    // 视觉基线使用的固定视口。
    const Size viewport = Size(260, 360);
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(brightness: Brightness.light),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(32),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 108,
                child: OmniTimePickerButton(
                  value: const TimeOfDay(hour: 18, minute: 0),
                  label: '18:00',
                  icon: null,
                  onChanged: (TimeOfDay value) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('18:00'));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/omni_time_picker_feishu_light.png'),
    );
  });
}
