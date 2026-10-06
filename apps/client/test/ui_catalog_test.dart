import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme_palette.dart';
import 'package:omni_butler/dev/ui_catalog.dart';

/// 验证组件展示页的主题矩阵，并可选择生成真实中文预览。
void main() {
  // 设置环境变量时输出预览，不改变日常测试及旧截图的字体环境。
  final String? previewDirectory = Platform.environment['OMNI_UI_PREVIEW_DIR'];
  setUpAll(() async {
    if (previewDirectory == null) return;
    // 用于中文预览的系统字体路径，也可由其他系统显式指定。
    final String fontPath =
        Platform.environment['OMNI_UI_FONT'] ?? 'C:/Windows/Fonts/msyh.ttc';
    for (final String family in <String>[
      'Microsoft YaHei UI',
      'Roboto',
      'Ahem',
    ]) {
      // 覆盖测试字体，避免中文方框影响人工验收。
      final FontLoader loader = FontLoader(family);
      loader.addFont(File(fontPath).readAsBytes().then(ByteData.sublistView));
      await loader.load();
    }
    // 当前 SDK 内置图标字体。
    final String iconPath =
        Platform.environment['OMNI_UI_ICONS'] ??
        'D:/program/code/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf';
    // 预览中真实图标的字体加载器。
    final FontLoader icons = FontLoader('MaterialIcons');
    icons.addFont(File(iconPath).readAsBytes().then(ByteData.sublistView));
    await icons.load();
    Directory(previewDirectory).createSync(recursive: true);
  });

  for (final AppThemePalette palette in AppThemePalette.values) {
    for (final Brightness brightness in Brightness.values) {
      testWidgets('组件展示 ${palette.id} ${brightness.name} 桌面与触控无溢出', (
        WidgetTester tester,
      ) async {
        // 捕获组件真实渲染结果。
        final GlobalKey boundaryKey = GlobalKey();
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        for (final (Size size, TargetPlatform platform)
            in <(Size, TargetPlatform)>[
              (const Size(1440, 1100), TargetPlatform.windows),
              (const Size(640, 900), TargetPlatform.windows),
              (const Size(390, 844), TargetPlatform.android),
            ]) {
          tester.view.physicalSize = size;
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundaryKey,
              child: OmniUiCatalogApp(
                key: ValueKey<String>(
                  '${palette.id}-${brightness.name}-${size.width}',
                ),
                initialPalette: palette,
                initialBrightness: brightness,
                platform: platform,
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 500));
          expect(tester.takeException(), isNull);
          if (previewDirectory != null && size.width != 640) {
            await _capture(
              tester,
              boundaryKey,
              '$previewDirectory/${palette.id}-${brightness.name}-${size.width.toInt()}.png',
            );
          }
          await tester.tap(find.text('放大文字'));
          await tester.pump(const Duration(milliseconds: 500));
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        }
      });
    }
  }

  testWidgets('展示页表单校验与编辑弹窗可实际操作', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const OmniUiCatalogApp(platform: TargetPlatform.windows),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('验证表单'));
    await tester.pump();
    expect(find.text('请填写内容后再保存'), findsOneWidget);
    await tester.tap(find.text('打开编辑器'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('编辑事项'), findsOneWidget);
    await tester.tap(find.text('保存修改'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('编辑事项'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

/// 将当前界面保存为供人工审查的 PNG，不覆盖测试基线。
Future<void> _capture(WidgetTester tester, GlobalKey key, String path) async {
  // 当前绘制边界。
  final RenderRepaintBoundary boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    // 当前界面的像素数据。
    final ui.Image image = await boundary.toImage();
    // 编码后的 PNG 数据。
    final ByteData data = (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!;
    await File(path).writeAsBytes(data.buffer.asUint8List());
    image.dispose();
  });
}
