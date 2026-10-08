import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_theme_palette.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 验证公共全屏结构的真实排版、主题与输入冻结契约。
void main() {
  testWidgets('全屏顶栏保持标题居中，加载不移动标题且冻结正文', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // 受控状态模拟业务发起提交。
    bool loading = false;
    // 统计冻结期间是否仍触发正文操作。
    int taps = 0;
    // 测试仅改变业务传入状态。
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light)
            .copyWith(platform: TargetPlatform.android),
        home: StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            update = setState;
            return OmniFullscreenFormScaffold(
              title: '新增物品',
              onPrimary: () {},
              onCancel: () {},
              loading: loading,
              child: Center(
                child: OmniButton(label: '正文操作', onPressed: () => taps += 1),
              ),
            );
          },
        ),
      ),
    );
    // 普通和加载状态都保持标题位于屏幕中线。
    final Rect title = tester.getRect(find.text('新增物品'));
    expect(title.center.dx, closeTo(195, 0.1));
    update(() => loading = true);
    await tester.pump();
    expect(tester.getRect(find.text('新增物品')), title);
    await tester.tap(find.text('正文操作'), warnIfMissed: false);
    expect(taps, 0);
  });

  testWidgets('极窄屏大字标题独占行，摘要和按钮文案完整可达', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 20);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.dark)
            .copyWith(platform: TargetPlatform.android),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: OmniFullscreenFormScaffold(
          title: '一键搬家',
          primaryLabel: '下一步',
          onPrimary: () {},
          onCancel: () {},
          subtitle: '已选 12 条记录，共 30 件',
          child: const SizedBox.expand(key: ValueKey<String>('safe-form-body')),
        ),
      ),
    );
    expect(
      tester.getRect(find.text('一键搬家')).bottom,
      lessThan(tester.getRect(find.text('下一步')).top),
    );
    expect(find.text('下一步').hitTestable(), findsOneWidget);
    expect(find.text('取消').hitTestable(), findsOneWidget);
    expect(find.text('已选 12 条记录，共 30 件'), findsOneWidget);
    expect(tester.getRect(find.text('一键搬家')).top, greaterThanOrEqualTo(24));
    expect(
      tester
          .getRect(find.byKey(const ValueKey<String>('safe-form-body')))
          .bottom,
      closeTo(620, 0.1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('六套配色明暗主题的主操作白字与实色对比度达标', (WidgetTester tester) async {
    // 验证主题派生色保持白字要求而不污染其他控件。
    for (final AppThemePalette palette in AppThemePalette.values) {
      // 明暗两种窗口都必须可读。
      for (final Brightness brightness in Brightness.values) {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.build(brightness: brightness, palette: palette),
            home: OmniFullscreenFormScaffold(
              title: '新增会员',
              onPrimary: () {},
              onCancel: () {},
              child: const SizedBox.shrink(),
            ),
          ),
        );
        // 实際 FilledButton 使用的最终语义状态颜色。
        final ButtonStyle style = tester
            .widget<FilledButton>(find.byType(FilledButton))
            .style!;
        // 交互反馈不能降低白字的可读性。
        for (final Set<WidgetState> states in <Set<WidgetState>>[
          <WidgetState>{},
          <WidgetState>{WidgetState.pressed},
          <WidgetState>{WidgetState.hovered},
        ]) {
          // 当前状态的实际背景。
          final Color fill = style.backgroundColor!.resolve(states)!;
          expect(style.foregroundColor!.resolve(states), Colors.white);
          expect(
            1.05 / (fill.computeLuminance() + 0.05),
            greaterThanOrEqualTo(4.5),
          );
        }
      }
    }
  });
}
