import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// 检查实际字形行框与搜索表面中心，不能只比较输入控件的外边界。
void expectSearchTextCentered(
  WidgetTester tester, {
  required Finder field,
  required Finder surface,
  required String hint,
}) {
  // 编辑器提供当前真实文字和插入光标位置。
  final RenderEditable editable = tester
      .state<EditableTextState>(
        find.descendant(of: field, matching: find.byType(EditableText)),
      )
      .renderEditable;
  // 外层灰色搜索表面的垂直中心。
  final double center = tester.getCenter(surface).dy;
  // 未输入时核对提示行，输入后核对实际编辑文字。
  final String text = editable.text!.toPlainText();
  // 真实字形行框相对所属渲染对象的位置。
  final Rect bounds;
  // 字形所属渲染对象，负责转换到屏幕坐标。
  final RenderBox owner;
  if (text.isEmpty) {
    // 提示文字由 InputDecorator 中的独立段落绘制。
    final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(of: field, matching: find.text(hint)),
    );
    owner = paragraph;
    bounds = paragraph
        .getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: hint.length),
        )
        .first
        .toRect();
  } else {
    owner = editable;
    bounds = editable
        .getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: text.length),
        )
        .first
        .toRect();
  }
  // 字体升降部差异随字号增长，插入光标的行中心仍须严格居中。
  final double glyphTolerance = MediaQuery.textScalerOf(tester.element(field))
      .scale(2);
  expect(
    owner.localToGlobal(bounds.center).dy,
    closeTo(center, glyphTolerance),
  );
  expect(
    editable
        .localToGlobal(
          editable.getLocalRectForCaret(const TextPosition(offset: 0)).center,
        )
        .dy,
    closeTo(center, 1),
  );
}
