import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_markdown.dart';

/// Markdown 夹具包含截图表格，以及常见块级与行内格式。
const String _source = '''
## 未完成任务

共有 **6 条任务**，包含 *重要事项* 和 ~~旧名称~~。

| 任务 | 计划日期 | 进度 |
| --- | --- | --- |
| 学习源码 | 2026-10-07 | 4/12 步 |
| 准备面试 | 2026-10-09 | 未开始 |

- 阅读文档
  - 整理笔记

> 计划日期与截止日期不同。

使用 `list_todos` 查询。

```dart
print('你好');
```
''';

/// 在真实主题、缩放和会话纵向滚动中构建回答。
Future<void> _pump(
  WidgetTester tester,
  String source,
  TargetPlatform platform, {
  double width = 800,
  double textScale = 1,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(brightness: brightness)
          .copyWith(platform: platform),
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 900),
          textScaler: TextScaler.linear(textScale),
        ),
        child: RepaintBoundary(
          key: const ValueKey<String>('assistant-markdown-preview'),
          child: Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: AssistantMarkdown(source: source),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 预览只写忽略的构建目录，使用与断言同一份渲染结果。
Future<void> _preview(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('ASSISTANT_PREVIEW')) return;
  await tester.runAsync(() async {
    // 获取当前真实页面的边界而不是另外生成简化示意图。
    final RenderRepaintBoundary boundary = tester.renderObject(
      find.byKey(const ValueKey<String>('assistant-markdown-preview')),
    );
    // 图片保持实际尺寸，便于查看横向表格视口。
    final ui.Image image = await boundary.toImage(pixelRatio: 1);
    try {
      // 无损编码方便核对中文文字与边框。
      final ByteData bytes = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!;
      await Directory('build/assistant_previews').create(recursive: true);
      await File('build/assistant_previews/markdown_$name.png')
          .writeAsBytes(bytes.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

/// 列表行包含符号和完整正文高度，避免测试替代字体的符号基线影响间距断言。
Rect _listRowRect(WidgetTester tester, String text) => tester.getRect(
  find
      .ancestor(
        of: find.text(text, findRichText: true),
        matching: find.byType(Row),
      )
      .first,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (const bool.fromEnvironment('ASSISTANT_PREVIEW')) {
    setUpAll(() async {
      // 中文预览使用本机字体，正常golden测试继续使用便携字体。
      final ByteData font = ByteData.sublistView(
        await File(
          Platform.environment['OMNI_UI_FONT'] ?? 'C:/Windows/Fonts/msyh.ttc',
        ).readAsBytes(),
      );
      for (final String family in <String>[
        'Microsoft YaHei UI',
        'Microsoft YaHei',
        'Roboto',
        'Noto Sans CJK SC',
        'Ahem',
      ]) {
        // 主题和默认字体均映射到同一实际中文字形。
        final FontLoader loader = FontLoader(family)
          ..addFont(Future<ByteData>.value(font));
        await loader.load();
      }
      // 代码块单独使用真实等宽字体，避免测试默认字体画成方块。
      final ByteData codeFont = ByteData.sublistView(
        await File('C:/Windows/Fonts/consola.ttf').readAsBytes(),
      );
      await (FontLoader(
        'monospace',
      )..addFont(Future<ByteData>.value(codeFont))).load();
    });
  }
  // 两端共用同一渲染组件，同时检查主题和交互平台。
  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.windows,
    TargetPlatform.android,
  ]) {
    testWidgets('${platform.name} 有序无序列表条目紧凑，嵌套及换行不重叠', (
      WidgetTester tester,
    ) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pump(tester, '''
已修复：

- 页面顶部打开菜单，导航背景仍保持透明。
- 菜单开合不再隐藏装饰，透明度随滚动变化。

1. 验证手机端布局。
2. 类型检查和构建通过。
   - 保留嵌套说明。
   - 保留第二项说明。

验证完成。
''', platform);
      // 使用完整列表行矩形核对条目间距，不只断言样式参数。
      final Rect first = _listRowRect(tester, '页面顶部打开菜单，导航背景仍保持透明。');
      // 第二条无序列表的位置。
      final Rect second = _listRowRect(tester, '菜单开合不再隐藏装饰，透明度随滚动变化。');
      // 两条有序列表均需使用同一间距。
      final Rect orderedFirst = _listRowRect(tester, '验证手机端布局。');
      // 带嵌套列表的第二项依旧从正常间距开始。
      final Rect orderedSecond = _listRowRect(tester, '类型检查和构建通过。');
      expect(second.top - first.bottom, closeTo(4, .1));
      expect(orderedSecond.top - orderedFirst.bottom, closeTo(4, .1));
      expect(find.text('保留嵌套说明。', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _preview(tester, '${platform.name}_compact_lists');
      await _pump(
        tester,
        '- 这是一项需要在窄屏换成多行的说明，保留完整内容且不压缩文字高度。\n- 下一项仍需留出清晰间距。\n\n1. 编号列表也允许长文字自然换行，并且保持完整显示。\n2. 第二项编号。',
        platform,
        width: 320,
        textScale: 2,
      );
      // 换行条目的全部高度保留，下一条仍只增加固定的小间距。
      final Rect multiline = _listRowRect(
        tester,
        '这是一项需要在窄屏换成多行的说明，保留完整内容且不压缩文字高度。',
      );
      // 后续条目的位置不可覆盖上一项的任何一行。
      final Rect following = _listRowRect(tester, '下一项仍需留出清晰间距。');
      expect(following.top - multiline.bottom, closeTo(4, .1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('${platform.name} 回答渲染 GFM 表格、列表和代码，正文可选择', (
      WidgetTester tester,
    ) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pump(tester, _source, platform);
      expect(find.byType(Table), findsOneWidget);
      expect(find.text('任务', findRichText: true), findsOneWidget);
      expect(find.text('学习源码', findRichText: true), findsOneWidget);
      expect(find.text('4/12 步', findRichText: true), findsOneWidget);
      expect(find.textContaining('| --- |', findRichText: true), findsNothing);
      expect(find.textContaining('## 未完成', findRichText: true), findsNothing);
      expect(find.textContaining('print(', findRichText: true), findsOneWidget);
      expect(find.byType(SelectionArea), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _preview(tester, platform.name);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('${platform.name} 窄屏大字号下表格和长代码各自横向滚动', (
      WidgetTester tester,
    ) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pump(
        tester,
        '|任务|计划日期|进度|\n|---|---|---|\n|长标题任务需要保持清晰可读|2026-10-24|4/12 步|\n\n```\n${'long_code_'.padRight(200, 'x')}\n```',
        platform,
        width: 320,
        textScale: 2,
        brightness: Brightness.dark,
      );
      // 表格与代码拥有自己的水平视口，不扩大聊天正文宽度。
      final Finder horizontal = find.byWidgetPredicate(
        (Widget widget) =>
            widget is SingleChildScrollView &&
            widget.scrollDirection == Axis.horizontal,
      );
      expect(horizontal, findsNWidgets(2));
      // 拖动真实表格视口，检查横向空间可抵达。
      final ScrollableState tableScroll = tester.state<ScrollableState>(
        find
            .descendant(of: horizontal.first, matching: find.byType(Scrollable))
            .first,
      );
      expect(tableScroll.position.maxScrollExtent, greaterThan(0));
      await tester.drag(horizontal.first, const Offset(-100, 0));
      await tester.pumpAndSettle();
      expect(tableScroll.position.pixels, greaterThan(0));
      expect(tester.takeException(), isNull);
      // 截图从首列开始，同时保留上方真实拖动验证。
      tableScroll.position.jumpTo(0);
      await tester.pump();
      await _preview(tester, '${platform.name}_narrow');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('流式未闭合标记可连续更新为完整表格与代码', (WidgetTester tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // 模拟 SSE 逐步补全格式，而不是等到终态才显示。
    for (final String source in <String>[
      '## 未完',
      '## 未完成\n\n|任务|',
      '|任务|日期|\n|---|---|\n|准备面试|2026-10-24|\n\n```dart\nprint(',
      _source,
    ]) {
      await _pump(tester, source, TargetPlatform.windows);
      expect(tester.takeException(), isNull);
    }
    expect(find.byType(Table), findsOneWidget);
    expect(find.text('准备面试', findRichText: true), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Markdown 图片只显示说明，非网页链接不启动任何执行', (WidgetTester tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pump(
      tester,
      '[非网页链接](javascript:alert)\n\n![本地图片](file:///C:/private.png)\n\n![远程图片](https://example.com/image.png)',
      TargetPlatform.windows,
    );
    expect(find.byType(Image), findsNothing);
    expect(find.text('[图片：本地图片]'), findsOneWidget);
    expect(find.text('[图片：远程图片]'), findsOneWidget);
    await tester.tap(find.text('非网页链接', findRichText: true));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
