import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:omni_butler/features/notes/presentation/note_markdown_text.dart';
import 'package:omni_butler/features/notes/presentation/note_rich_editor.dart';

/// 使用真实 Quill 文档和输入连接验证选区，而不是伪造富文本截图。
void main() {
  test('同篇同步与选区变化保留正文，换篇清除选区和撤销', () {
    // 本测试或当前组件的真实编辑控制器。
    final NoteRichEditorController controller = NoteRichEditorController(
      source: '甲乙丙',
    );
    addTearDown(controller.dispose);
    controller.syncMarkdown('甲乙丙', identity: 'a');
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 2);
    controller.toggleBold();
    expect(controller.markdown, '**甲乙**丙');
    expect(
      controller.selection,
      const TextSelection(baseOffset: 0, extentOffset: 2),
    );
    controller.syncMarkdown(controller.markdown, identity: 'a');
    expect(controller.selection.end, 2);
    controller.toggleBold();
    expect(controller.markdown, '甲乙丙');
    controller.syncMarkdown('甲乙丙', identity: 'b');
    expect(controller.selection.end, 0);
    expect(controller.quillController.hasUndo, isFalse);
  });

  test('无选区设置后续样式、混合选区统一添加', () {
    // 本测试或当前组件的真实编辑控制器。
    final NoteRichEditorController controller = NoteRichEditorController(
      source: '甲乙',
    );
    addTearDown(controller.dispose);
    controller.selection = const TextSelection.collapsed(offset: 2);
    controller.toggleUnderline();
    expect(controller.markdown, '甲乙');
    controller.insertText('丙');
    expect(controller.markdown, '甲乙<u>丙</u>');
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 3);
    controller.toggleHighlight();
    expect(controller.isHighlight, isTrue);
    expect(controller.markdown, '==甲乙==<u>==丙==</u>');
  });

  test('格式操作的撤销与重做恢复完整正文和样式', () {
    // 每次格式操作都使用原生文档撤销事务。
    final NoteRichEditorController controller = NoteRichEditorController(
      source: '甲乙',
    );
    addTearDown(controller.dispose);
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 2);
    controller.toggleBold();
    expect(controller.markdown, '**甲乙**');
    controller.quillController.undo();
    expect(controller.markdown, '甲乙');
    controller.quillController.redo();
    expect(controller.markdown, '**甲乙**');
  });

  testWidgets('Ctrl+B/U只修改可见选区，选区及外部加载不触发内容回调', (tester) async {
    // 本测试或当前组件的真实编辑控制器。
    final NoteRichEditorController controller = NoteRichEditorController(
      source: '甲乙丙',
    );
    // 真实编辑输入焦点。
    final FocusNode focus = FocusNode();
    // 收集实际内容回调，排除选区通知。
    final List<String> changes = [];
    await _mount(tester, controller, focus, changes.add);
    focus.requestFocus();
    await tester.pump();
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 2);
    await tester.pump();
    expect(changes, isEmpty);
    await _control(tester, LogicalKeyboardKey.keyB);
    expect(controller.markdown, '**甲乙**丙');
    await _control(tester, LogicalKeyboardKey.keyU);
    expect(controller.markdown, '**<u>甲乙</u>**丙');
    expect(controller.selection.end, 2);
    controller.syncMarkdown('载入正文', identity: 'b');
    await tester.pump();
    expect(changes.length, 2);
    await tester.tap(find.byKey(const ValueKey('outside')));
    await tester.pump();
    await _control(tester, LogicalKeyboardKey.keyB);
    expect(controller.markdown, '载入正文');
    expect(focus.hasFocus, isFalse);
    await _dispose(tester, controller, focus);
  });

  testWidgets('真实文字连接输入与中文组词不重建文档', (tester) async {
    // 本测试或当前组件的真实编辑控制器。
    final NoteRichEditorController controller = NoteRichEditorController();
    // 真实编辑输入焦点。
    final FocusNode focus = FocusNode();
    await _mount(tester, controller, focus, (_) {});
    focus.requestFocus();
    await tester.pump();
    // 输入前固定的文档身份。
    final quill.Document document = controller.quillController.document;
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '拼\n',
        selection: TextSelection.collapsed(offset: 1),
        composing: TextRange(start: 0, end: 1),
      ),
    );
    await tester.pump();
    controller.toggleBold();
    expect(controller.isBold, isFalse);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '拼音\n',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump();
    expect(controller.plainText, '拼音');
    expect(controller.quillController.document, same(document));
    expect(tester.takeException(), isNull);
    await _dispose(tester, controller, focus);
  });

  testWidgets('键入Markdown列表、续行、空项退出与Backspace退列表', (tester) async {
    // 本测试或当前组件的真实编辑控制器。
    final NoteRichEditorController controller = NoteRichEditorController(
      source: '-',
    );
    // 真实编辑输入焦点。
    final FocusNode focus = FocusNode();
    await _mount(tester, controller, focus, (_) {});
    focus.requestFocus();
    controller.selection = const TextSelection.collapsed(offset: 1);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space, character: ' ');
    await tester.pump();
    expect(controller.isBulletList, isTrue);
    controller.insertText('第一项');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(controller.isBulletList, isTrue);
    // 空项退出前记录可见偏移，失败时提供真实文档证据。
    final String beforeExit =
        '${controller.quillController.document.toDelta()} ${controller.selection}';
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(
      controller.isBulletList,
      isFalse,
      reason:
          '$beforeExit → ${controller.quillController.document.toDelta()} ${controller.selection} ${controller.quillController.toggledStyle}',
    );
    controller.toggleList(true);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(controller.isOrderedList, isFalse);
    controller.insertText('退出后的正文');
    expect(controller.markdown, '- 第一项\n退出后的正文');
    await _dispose(tester, controller, focus);
  });

  testWidgets('键入三个配对标记即时转换并保留可见光标', (tester) async {
    for (final (String, LogicalKeyboardKey, String) sample in [
      ('**文字*', LogicalKeyboardKey.digit8, '*'),
      ('==文字=', LogicalKeyboardKey.equal, '='),
      ('<u>文字</u', LogicalKeyboardKey.period, '>'),
    ]) {
      // 本测试或当前组件的真实编辑控制器。
      final NoteRichEditorController controller = NoteRichEditorController();
      // 真实编辑输入焦点。
      final FocusNode focus = FocusNode();
      await _mount(tester, controller, focus, (_) {});
      focus.requestFocus();
      await tester.pump();
      controller.insertText(sample.$1);
      await tester.sendKeyEvent(sample.$2, character: sample.$3);
      await tester.pump();
      expect(controller.plainText, '文字');
      expect(controller.selection.extentOffset, 2);
      await _dispose(tester, controller, focus);
    }
  });

  testWidgets('大字号与系统缩放下三位列表编号保持单行并与正文留白', (tester) async {
    // 连续一百项产生真实三位编号，不能仅伪造一个静态标记。
    final String source = List.generate(
      100,
      (index) => '${index + 1}. 第${index + 1}项',
    ).join('\n');
    // 使用生产编辑器布局验证标记与可编辑正文的相对位置。
    final NoteRichEditorController controller = NoteRichEditorController(
      source: source,
    );
    // 本用例的真实输入焦点。
    final FocusNode focus = FocusNode();
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: NoteRichEditor(
                controller: controller,
                focusNode: focus,
                onChanged: (_) {},
                minHeight: 0,
                style: const TextStyle(fontSize: 32, height: 1.5),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // 最后一项序号对应的实际段落渲染对象。
    final Finder marker = find.byWidgetPredicate(
      (widget) => widget is RichText && widget.text.toPlainText() == '100.',
    );
    // 最后一项可编辑正文对应的实际段落渲染对象。
    final Finder content = find.byWidgetPredicate(
      (widget) => widget is RichText && widget.text.toPlainText() == '第100项',
    );
    expect(marker, findsOneWidget);
    expect(content, findsOneWidget);
    // 字形选择框可以识别标记在窄列中折成两行的错误。
    final RenderParagraph markerParagraph = tester.renderObject(marker);
    expect(
      markerParagraph.getBoxesForSelection(
        const TextSelection(baseOffset: 0, extentOffset: 4),
      ),
      hasLength(1),
    );
    expect(
      tester.getRect(content).left - tester.getRect(marker).right,
      greaterThanOrEqualTo(7.99),
    );
    expect(controller.markdown, source);
    expect(tester.takeException(), isNull);
    await _dispose(tester, controller, focus);
  });

  testWidgets('列表全文及两行高度与实际布局一致，窄窗保持悬挂缩进', (tester) async {
    // 本用例的原始持久正文。
    const String source = '- **长列表内容长列表内容长列表内容**\n1. <u>下一项</u>\n==高亮==';
    // 与原笔记卡片一致的正文样式。
    const TextStyle style = TextStyle(fontSize: 14, height: 1.5);
    for (final int? lines in [null, 2]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 120,
              child: NoteMarkdownText(
                source: source,
                style: style,
                maxLines: lines,
              ),
            ),
          ),
        ),
      );
      // 使用生产测量入口计算的期望高度。
      final double expected = NoteMarkdownText.measureHeight(
        source,
        maxWidth: 120,
        style: DefaultTextStyle.of(
          tester.element(find.byType(NoteMarkdownText)),
        ).style.merge(style),
        textDirection: TextDirection.ltr,
        maxLines: lines,
      );
      expect(
        tester.getSize(find.byType(NoteMarkdownText)).height,
        closeTo(expected, 0.01),
      );
      expect(tester.takeException(), isNull);
    }
  });
}

/// 挂载组件并保留一个外部输入框作为焦点边界。
Future<void> _mount(
  WidgetTester tester,
  NoteRichEditorController controller,
  FocusNode focus,
  ValueChanged<String> onChanged,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            NoteRichEditor(
              controller: controller,
              focusNode: focus,
              onChanged: onChanged,
            ),
            const TextField(key: ValueKey('outside')),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
}

/// 发送完整的物理Ctrl组合键。
Future<void> _control(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

/// 先卸载输入连接，再释放外部持有的状态。
Future<void> _dispose(
  WidgetTester tester,
  NoteRichEditorController controller,
  FocusNode focus,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  controller.dispose();
  focus.dispose();
  await tester.pump();
}
