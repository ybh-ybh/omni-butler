import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:omni_butler/features/notes/markdown/note_markdown.dart';

/// 核对持久正文与可视文档的边界，避免旧文字被通用 Markdown 改写。
void main() {
  test('普通正文保留空行、行首空格、末尾换行和Unicode', () {
    for (final String source in [
      '',
      '标题\n正文',
      '\n\n 空格 \n\n',
      '中👨‍👩‍👧‍👦e\u0301\n',
    ]) {
      expect(NoteMarkdown.fromDelta(NoteMarkdown.toDelta(source)), source);
      expect(NoteMarkdown.plainText(source), source);
    }
  });

  test('五种格式生成可见内容与独立属性，序号不计入字数', () {
    // 本用例的原始持久正文。
    const String source =
        '**加粗**\n<u>下划线</u>\n==高亮==\n- 项目甲\n- 项目乙\n1. 第一\n2. 第二';
    // 参与往返验证的富文本内容。
    final Delta delta = NoteMarkdown.toDelta(source);
    expect(NoteMarkdown.fromDelta(delta), source);
    expect(NoteMarkdown.plainText(source), '加粗\n下划线\n高亮\n项目甲\n项目乙\n第一\n第二');
    expect(delta.toList().first.attributes, {'bold': true});
    expect(NoteMarkdown.startsWithList('\n- 第一项'), isTrue);
    expect(NoteMarkdown.startsWithList('普通标题\n- 第一项'), isFalse);
  });

  test('嵌套样式与特殊字符边界能够往返', () {
    // 包含组合格式和边界字符的可视文档。
    final Delta original = Delta()
      ..insert('甲*=', {
        'bold': true,
        'underline': true,
        'background': NoteMarkdown.highlight,
      })
      ..insert('普通** == <u> 原文')
      ..insert('\n');
    expect(NoteMarkdown.toDelta(NoteMarkdown.fromDelta(original)), original);
  });

  test('未闭合标记与非目标Markdown HTML均保持字面内容', () {
    for (final String source in [
      '# 标题\n> 引用\n`代码`',
      '**未闭合',
      '<b>普通</b>',
      '==',
      '  - 非列表',
      r'C:\notes\test',
    ]) {
      expect(NoteMarkdown.plainText(source), source);
      expect(
        NoteMarkdown.plainText(
          NoteMarkdown.fromDelta(NoteMarkdown.toDelta(source)),
        ),
        source,
      );
    }
  });

  test('普通段落中的列表字面值不会在再次加载时变成列表', () {
    // 必须保持为普通段落的列表字面值。
    final Delta literal = Delta()..insert('- 普通\n1. 普通\n');
    expect(NoteMarkdown.toDelta(NoteMarkdown.fromDelta(literal)), literal);
  });

  test('多个相邻及重叠样式片段保持相同可见文档', () {
    // 本用例的原始持久正文。
    final Delta source = Delta()
      ..insert('甲', {'bold': true})
      ..insert('乙', {'bold': true, 'underline': true})
      ..insert('丙', {'underline': true, 'background': NoteMarkdown.highlight})
      ..insert('丁', {'background': NoteMarkdown.highlight})
      ..insert('\n', {'list': 'ordered'})
      ..insert('\n');
    expect(NoteMarkdown.toDelta(NoteMarkdown.fromDelta(source)), source);
  });
}
