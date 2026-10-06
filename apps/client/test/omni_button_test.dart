import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_theme_palette.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/shared/ui/omni_button.dart';

/// 验证按钮统一外观、平台密度与可操作性。
void main() {
  testWidgets('六套配色明暗主按钮各状态均可读且与原生实色按钮一致', (WidgetTester tester) async {
    // 所有配色都覆盖浅色和深色文字前景。
    for (final AppThemePalette palette in AppThemePalette.values) {
      // 明暗模式共享主按钮契约。
      for (final Brightness brightness in Brightness.values) {
        // 当前配色主题。
        final ThemeData theme = AppTheme.build(
          brightness: brightness,
          palette: palette,
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Column(
                children: <Widget>[
                  OmniButton(label: '保存', onPressed: () {}),
                  OmniButton(
                    label: '新建记录',
                    variant: OmniButtonVariant.pagePrimary,
                    onPressed: () {},
                  ),
                  OmniButton(label: '正在保存', loading: true, onPressed: () {}),
                ],
              ),
            ),
          ),
        );
        // 加载进度条持续转动，有限推进即可完成主题切换。
        await tester.pump(const Duration(milliseconds: 300));
        // 三种主操作的最终状态样式。
        final List<ButtonStyle> styles = tester
            .widgetList<FilledButton>(find.byType(FilledButton))
            .map((FilledButton button) => button.style!)
            .toList(growable: false);
        // 原生兜底样式应与两个语义主按钮保持一致。
        final ButtonStyle nativeStyle = theme.filledButtonTheme.style!;
        // 普通、悬停、焦点和按下等组合均不能损失可读性。
        for (final Set<WidgetState> states in <Set<WidgetState>>[
          <WidgetState>{},
          <WidgetState>{WidgetState.hovered},
          <WidgetState>{WidgetState.focused},
          <WidgetState>{WidgetState.pressed},
          <WidgetState>{WidgetState.hovered, WidgetState.focused},
          <WidgetState>{WidgetState.hovered, WidgetState.pressed},
          <WidgetState>{WidgetState.focused, WidgetState.pressed},
        ]) {
          // 每个操作按钮均使用同一可读填色和前景色。
          for (final ButtonStyle style in styles) {
            // 当前状态背景色。
            final Color background = style.backgroundColor!.resolve(states)!;
            // 当前状态文字色。
            final Color foreground = style.foregroundColor!.resolve(states)!;
            expect(background, nativeStyle.backgroundColor!.resolve(states));
            expect(foreground, nativeStyle.foregroundColor!.resolve(states));
            expect(
              _contrast(foreground, background),
              greaterThanOrEqualTo(4.6),
              reason: '${palette.label} ${brightness.name} $states',
            );
          }
        }
        expect(
          _contrast(
            styles.last.foregroundColor!.resolve(<WidgetState>{
              WidgetState.disabled,
            })!,
            styles.last.backgroundColor!.resolve(<WidgetState>{
              WidgetState.disabled,
            })!,
          ),
          greaterThanOrEqualTo(4.6),
          reason: '加载状态只阻止重复操作，仍保留可读的标签',
        );
      }
    }
  });

  testWidgets('六套配色明暗危险按钮在普通悬停焦点和按下时均可读', (WidgetTester tester) async {
    // 每套配色都使用同一语义按钮契约。
    for (final AppThemePalette palette in AppThemePalette.values) {
      // 同时验证浅色和深色窗口。
      for (final Brightness brightness in Brightness.values) {
        // 当前配色与明暗主题。
        final ThemeData theme = AppTheme.build(
          brightness: brightness,
          palette: palette,
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: OmniButton(
                label: '删除记录',
                variant: OmniButtonVariant.danger,
                onPressed: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        // 当前按钮最终采用的语义状态样式。
        final ButtonStyle style = tester
            .widget<FilledButton>(find.byType(FilledButton))
            .style!;
        expect(
          style.backgroundColor!.resolve(<WidgetState>{}),
          theme.colorScheme.error,
        );
        // 用户可操作状态都应保持普通文字对比度。
        for (final Set<WidgetState> states in <Set<WidgetState>>[
          <WidgetState>{},
          <WidgetState>{WidgetState.hovered},
          <WidgetState>{WidgetState.focused},
          <WidgetState>{WidgetState.pressed},
          <WidgetState>{WidgetState.hovered, WidgetState.pressed},
        ]) {
          // 当前状态使用的危险背景色。
          final Color background = style.backgroundColor!.resolve(states)!;
          // 当前状态使用的文字色。
          final Color foreground = style.foregroundColor!.resolve(states)!;
          expect(foreground, Colors.white);
          expect(
            (foreground.computeLuminance() + 0.05) /
                (background.computeLuminance() + 0.05),
            greaterThanOrEqualTo(4.6),
            reason: '${palette.label} ${brightness.name} $states',
          );
        }
      }
    }
  });

  testWidgets('页面主操作与主按钮使用相同实色并移除图标色块', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light)
            .copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: Column(
            children: <Widget>[
              OmniButton(label: '保存', onPressed: () {}),
              OmniButton(
                label: '新增会员',
                icon: Icons.add_rounded,
                variant: OmniButtonVariant.pagePrimary,
                onPressed: () {},
              ),
            ],
          ),
        ),
      ),
    );
    // 两种主操作的底层按钮。
    final List<FilledButton> buttons = tester
        .widgetList<FilledButton>(find.byType(FilledButton))
        .toList();
    // 当前主题的可读主操作色对。
    final ColorScheme scheme = Theme.of(
      tester.element(find.byType(OmniButton).first),
    ).colorScheme;
    // 页面主操作的状态样式。
    final ButtonStyle style = buttons.last.style!;
    expect(style.backgroundColor?.resolve(<WidgetState>{}), scheme.primary);
    expect(
      style.backgroundColor?.resolve(<WidgetState>{}),
      buttons.first.style?.backgroundColor?.resolve(<WidgetState>{}),
    );
    expect(
      style.backgroundColor?.resolve(<WidgetState>{WidgetState.hovered}),
      isNot(scheme.primary),
    );
    expect(
      style.backgroundColor?.resolve(<WidgetState>{WidgetState.pressed}),
      isNot(scheme.primary),
    );
    expect(style.side?.resolve(<WidgetState>{WidgetState.focused})?.width, 2);
    expect(
      tester.getSize(find.byType(FilledButton).first).height,
      OmniSize.control,
    );
    expect(
      tester.getSize(find.byType(FilledButton).last).height,
      OmniSize.controlLarge,
    );
    expect(
      find.byKey(const ValueKey<String>('omni-page-primary-icon')),
      findsNothing,
    );
    expect(find.text('新增会员'), findsOneWidget);
  });

  testWidgets('加载保持标签和实色且阻止重复提交', (WidgetTester tester) async {
    // 接收的提交次数。
    int submitCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light),
        home: Scaffold(
          body: OmniButton(
            label: '保存修改',
            loading: true,
            onPressed: () => submitCount += 1,
          ),
        ),
      ),
    );
    // 正在加载的底层按钮。
    final FilledButton button = tester.widget<FilledButton>(
      find.byType(FilledButton),
    );
    // 当前主题的可读主操作色对。
    final ColorScheme scheme = Theme.of(tester.element(find.byType(OmniButton)))
        .colorScheme;
    expect(button.onPressed, isNull);
    expect(
      button.style?.foregroundColor?.resolve(<WidgetState>{
        WidgetState.disabled,
      }),
      scheme.onPrimary,
    );
    expect(
      button.style?.backgroundColor?.resolve(<WidgetState>{
        WidgetState.disabled,
      }),
      scheme.primary,
    );
    expect(find.text('保存修改'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.text('保存修改'));
    await tester.pump();
    expect(submitCount, 0);
  });

  testWidgets('禁用状态使用中性色且不触发操作', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light),
        home: const Scaffold(
          body: OmniButton(
            label: '删除',
            variant: OmniButtonVariant.danger,
            onPressed: null,
          ),
        ),
      ),
    );
    // 当前禁用按钮。
    final FilledButton button = tester.widget<FilledButton>(
      find.byType(FilledButton),
    );
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(
      tester.element(find.byType(OmniButton)),
    );
    expect(
      button.style?.backgroundColor?.resolve(<WidgetState>{
        WidgetState.disabled,
      }),
      colors.mist,
    );
    expect(
      button.style?.foregroundColor?.resolve(<WidgetState>{
        WidgetState.disabled,
      }),
      colors.muted,
    );
  });

  testWidgets('平台密度独立于窗口宽度且键盘可以激活', (WidgetTester tester) async {
    // 累计键盘激活次数。
    int submitCount = 0;
    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light)
            .copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: OmniButton(label: '保存', onPressed: () => submitCount += 1),
        ),
      ),
    );
    expect(tester.getSize(find.byType(FilledButton)).height, OmniSize.control);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(submitCount, 1);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light)
            .copyWith(platform: TargetPlatform.android),
        home: Scaffold(
          body: OmniButton(label: '保存', onPressed: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(FilledButton)).height, OmniSize.touch);
  });
}

/// 验证浅色或深色文字与实色背景之间的实际对比度。
double _contrast(Color foreground, Color background) {
  // 文字的线性亮度。
  final double foregroundLuminance = foreground.computeLuminance();
  // 背景的线性亮度。
  final double backgroundLuminance = background.computeLuminance();
  return foregroundLuminance > backgroundLuminance
      ? (foregroundLuminance + 0.05) / (backgroundLuminance + 0.05)
      : (backgroundLuminance + 0.05) / (foregroundLuminance + 0.05);
}
