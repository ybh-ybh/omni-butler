import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/shared/ui/omni_button.dart';

/// 验证页面主操作按钮的尺寸、配色与交互状态。
void main() {
  testWidgets('页面主操作使用浅蓝底与实蓝图标块', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light)
            .copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: Center(
            child: OmniButton(
              label: '新增会员',
              icon: Icons.add_rounded,
              variant: OmniButtonVariant.pagePrimary,
              onPressed: () {},
            ),
          ),
        ),
      ),
    );

    // 页面主操作对应的底层按钮。
    final FilledButton button = tester.widget<FilledButton>(
      find.byType(FilledButton),
    );
    // 页面主操作的默认文字样式。
    final TextStyle? defaultTextStyle = button.style?.textStyle?.resolve(
      const <WidgetState>{},
    );
    // 页面主操作的默认背景色。
    final Color? defaultBackground = button.style?.backgroundColor?.resolve(
      const <WidgetState>{},
    );
    // 页面主操作的悬停背景色。
    final Color? hoveredBackground = button.style?.backgroundColor?.resolve(
      const <WidgetState>{WidgetState.hovered},
    );
    // 页面主操作的按下背景色。
    final Color? pressedBackground = button.style?.backgroundColor?.resolve(
      const <WidgetState>{WidgetState.pressed},
    );
    // 页面主操作的键盘焦点边框。
    final BorderSide? focusedSide = button.style?.side?.resolve(
      const <WidgetState>{WidgetState.focused},
    );
    // 页面主操作的图标块。
    final Container iconTile = tester.widget<Container>(
      find.byKey(const ValueKey<String>('omni-page-primary-icon')),
    );
    // 页面主操作图标块的装饰。
    final BoxDecoration iconDecoration = iconTile.decoration! as BoxDecoration;

    expect(
      tester.getSize(find.byType(FilledButton)).height,
      OmniSize.pageAction,
    );
    expect(defaultBackground, const Color(0xFFEAF0FF));
    expect(hoveredBackground, isNot(defaultBackground));
    expect(pressedBackground, isNot(hoveredBackground));
    expect(focusedSide?.width, 2);
    expect(focusedSide?.color, const Color(0xFF3370FF).withValues(alpha: 0.30));
    expect(defaultTextStyle?.fontWeight, FontWeight.w400);
    expect(
      tester.getSize(
        find.byKey(const ValueKey<String>('omni-page-primary-icon')),
      ),
      const Size.square(24),
    );
    expect(iconDecoration.color, const Color(0xFF3370FF));
    expect(find.text('新增会员'), findsOneWidget);
  });

  testWidgets('不可用的页面主操作使用中性灰色', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light)
            .copyWith(platform: TargetPlatform.windows),
        home: const Scaffold(
          body: Center(
            child: OmniButton(
              label: '新增会员',
              icon: Icons.add_rounded,
              variant: OmniButtonVariant.pagePrimary,
              onPressed: null,
            ),
          ),
        ),
      ),
    );

    // 不可用页面主操作对应的底层按钮。
    final FilledButton button = tester.widget<FilledButton>(
      find.byType(FilledButton),
    );
    // 不可用页面主操作的背景色。
    final Color? disabledBackground = button.style?.backgroundColor?.resolve(
      const <WidgetState>{WidgetState.disabled},
    );
    // 不可用页面主操作的图标块。
    final Container iconTile = tester.widget<Container>(
      find.byKey(const ValueKey<String>('omni-page-primary-icon')),
    );
    // 不可用页面主操作图标块的装饰。
    final BoxDecoration iconDecoration = iconTile.decoration! as BoxDecoration;

    expect(disabledBackground, const Color(0xFFEFF0F1));
    expect(iconDecoration.color, const Color(0xFFDEE0E3));
  });
}
