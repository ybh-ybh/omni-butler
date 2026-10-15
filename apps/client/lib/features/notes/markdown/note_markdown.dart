import 'package:flutter_quill/quill_delta.dart';

/// 笔记的一段可见文字及本功能支持的行内样式。
class NoteMarkdownRun {
  /// 创建不可变的文字片段。
  const NoteMarkdownRun(this.text, this.attributes);

  /// 不含 Markdown 标记的文字。
  final String text;

  /// 仅允许 bold、underline 与固定高亮背景。
  final Map<String, dynamic> attributes;
}

/// 一行笔记内容，列表身份放在换行上而不污染可见文字偏移。
class NoteMarkdownLine {
  /// 创建一行解析结果。
  const NoteMarkdownLine(this.runs, {this.list});

  /// 按原始顺序排列的行内片段。
  final List<NoteMarkdownRun> runs;

  /// bullet、ordered 或普通段落的 null。
  final String? list;

  /// 当前行的可见文字。
  String get text => runs.map((run) => run.text).join();
}

/// 只转换笔记明确支持的五种格式，未知语法始终作为普通文字。
abstract final class NoteMarkdown {
  /// 固定淡黄色与工具栏高亮属性保持一致。
  static const String highlight = '#fff59d';

  /// 只识别零缩进的一层列表，保留非列表前导空格。
  static final RegExp _listPrefix = RegExp(r'^(?:- |[0-9]+\. )');

  /// 解析正文，并附加 Quill 必需且不属于用户正文的末尾换行。
  static Delta toDelta(String source) {
    // 逐行插入保持空行和末尾换行的数量。
    final Delta delta = Delta();
    for (final NoteMarkdownLine line in lines(source)) {
      for (final NoteMarkdownRun run in line.runs) {
        if (run.text.isNotEmpty) {
          delta.insert(
            run.text,
            run.attributes.isEmpty ? null : run.attributes,
          );
        }
      }
      delta.insert('\n', line.list == null ? null : {'list': line.list});
    }
    return delta;
  }

  /// 将可视文档编码为受限 Markdown，只移除 Quill 的终止换行。
  static String fromDelta(Delta delta) {
    // 行内文本缓冲与行列表身份分别处理，避免格式跨段落泄漏。
    final List<String> output = [];
    // 当前正在处理的文档或行内缓冲。
    final StringBuffer current = StringBuffer();
    // 当前连续有序列表的序号。
    int orderedIndex = 0;
    for (final Operation operation in delta.toList()) {
      // 正文不允许内嵌对象；图片由独立附件关系保存。
      if (operation.data is! String) continue;
      // 当前可见文字，不含持久层格式标记。
      final String text = operation.data as String;
      // 当前文字或换行携带的格式属性。
      final Map<String, dynamic> attributes = operation.attributes ?? {};
      // 按换行拆开的文字，空片段也保留。
      final List<String> pieces = text.split('\n');
      for (int index = 0; index < pieces.length; index++) {
        current.write(_encodeInline(pieces[index], attributes));
        if (index == pieces.length - 1) continue;
        // 已收集完成的当前行内容。
        final String content = current.toString();
        current.clear();
        // 当前段落的列表类型。
        final String? list = attributes['list'] as String?;
        if (list == 'ordered') {
          orderedIndex++;
          output.add('$orderedIndex. $content');
        } else {
          orderedIndex = 0;
          output.add(list == 'bullet' ? '- $content' : _escapeList(content));
        }
      }
    }
    // 合法 Quill 文档以换行结束；不额外 trim 用户自己的空白。
    if (current.isNotEmpty) output.add(_escapeList(current.toString()));
    return output.join('\n');
  }

  /// 搜索和统计统一使用可见正文，列表序号及行内标记不计入。
  static String plainText(String source) =>
      lines(source).map((line) => line.text).join('\n');

  /// 首个非空行是列表时，历史卡片保留整段列表而不抽走首项。
  static bool startsWithList(String source) {
    for (final String line in source.split('\n')) {
      if (line.trim().isNotEmpty) return _listPrefix.hasMatch(line);
    }
    return false;
  }

  /// 逐行解析给编辑、只读渲染和文字测量复用。
  static List<NoteMarkdownLine> lines(String source) => [
    for (final String line in source.split('\n')) _parseLine(line),
  ];

  /// 列表符号仅在行首生效，内容中的减号和数字不转换。
  static NoteMarkdownLine _parseLine(String source) {
    // 当前行实际匹配到的列表前缀。
    final RegExpMatch? prefix = _listPrefix.firstMatch(source);
    // 按显示顺序保存的行内片段。
    final List<NoteMarkdownRun> runs = [];
    _parseInline(source.substring(prefix?.end ?? 0), const {}, runs);
    return NoteMarkdownLine(
      List.unmodifiable(runs),
      list: prefix == null
          ? null
          : source.startsWith('- ')
          ? 'bullet'
          : 'ordered',
    );
  }

  /// 配对格式可组合；不完整标记和其他 HTML 保持字面值。
  static void _parseInline(
    String source,
    Map<String, dynamic> attributes,
    List<NoteMarkdownRun> runs,
  ) {
    // 尚未遇到格式边界的普通文字。
    final StringBuffer plain = StringBuffer();
    // 当前位置，按原始顺序处理内容。
    int index = 0;
    while (index < source.length) {
      // 只消费本方言的转义符，不破坏普通 Windows 路径。
      if (source[index] == r'\' &&
          index + 1 < source.length &&
          r'\*=<-.'.contains(source[index + 1])) {
        plain.write(source[index + 1]);
        index += 2;
        continue;
      }
      // 每种样式在自身内部不重复开启，限制解析深度。
      final (String, String, String, dynamic)? marker =
          source.startsWith('**', index) && attributes['bold'] != true
          ? ('**', '**', 'bold', true)
          : source.startsWith('<u>', index) && attributes['underline'] != true
          ? ('<u>', '</u>', 'underline', true)
          : source.startsWith('==', index) &&
                attributes['background'] != highlight
          ? ('==', '==', 'background', highlight)
          : null;
      // 未被转义的结束标记位置。
      final int closing = marker == null
          ? -1
          : _findClosing(source, marker.$2, index + marker.$1.length);
      if (marker != null && closing > index + marker.$1.length) {
        _appendRun(runs, plain.toString(), attributes);
        plain.clear();
        _parseInline(source.substring(index + marker.$1.length, closing), {
          ...attributes,
          marker.$3: marker.$4,
        }, runs);
        index = closing + marker.$2.length;
      } else {
        plain.write(source[index]);
        index++;
      }
    }
    _appendRun(runs, plain.toString(), attributes);
  }

  /// 跳过被奇数个反斜杠转义的结束标记。
  static int _findClosing(String source, String marker, int start) {
    // 下一个可能的标记位置。
    int candidate = source.indexOf(marker, start);
    while (candidate >= 0) {
      // 标记前连续转义符的个数。
      int slashes = 0;
      for (
        // 当前位置，按原始顺序处理内容。
        int index = candidate - 1;
        index >= 0 && source[index] == r'\';
        index--
      ) {
        slashes++;
      }
      if (slashes.isEven) return candidate;
      candidate = source.indexOf(marker, candidate + 1);
    }
    return -1;
  }

  /// 合并相邻同样式文字，避免逐字符建立大量节点。
  static void _appendRun(
    List<NoteMarkdownRun> runs,
    String text,
    Map<String, dynamic> attributes,
  ) {
    if (text.isEmpty) return;
    if (runs.isNotEmpty && _sameAttributes(runs.last.attributes, attributes)) {
      // 用于合并的上一个同样式片段。
      final NoteMarkdownRun previous = runs.removeLast();
      runs.add(NoteMarkdownRun(previous.text + text, previous.attributes));
    } else {
      runs.add(NoteMarkdownRun(text, Map.unmodifiable(attributes)));
    }
  }

  /// 本方言属性很少，无需引用编辑器或通用深比较依赖。
  static bool _sameAttributes(
    Map<String, dynamic> first,
    Map<String, dynamic> second,
  ) =>
      first.length == second.length &&
      first.entries.every((entry) => second[entry.key] == entry.value);

  /// 先保护字面标记，再以固定嵌套顺序写出样式。
  static String _encodeInline(String text, Map<String, dynamic> attributes) {
    if (text.isEmpty) return '';
    // 准备交给持久层的受限 Markdown。
    String encoded = text
        .replaceAll(r'\', r'\\')
        .replaceAll('*', r'\*')
        .replaceAll('=', r'\=')
        .replaceAll('<u>', r'\<u>')
        .replaceAll('</u>', r'\</u>');
    if (attributes['background'] != null) encoded = '==$encoded==';
    if (attributes['underline'] == true) encoded = '<u>$encoded</u>';
    if (attributes['bold'] == true) encoded = '**$encoded**';
    return encoded;
  }

  /// 普通段落恰好以列表语法开头时，保存为字面文字。
  static String _escapeList(String text) {
    if (text.startsWith('- ')) return r'\' + text;
    // 当前普通文字是否恰好匹配有序列表。
    final RegExpMatch? ordered = RegExp(r'^[0-9]+\. ').firstMatch(text);
    if (ordered == null) return text;
    return text.replaceRange(ordered.end - 2, ordered.end - 1, r'\.');
  }
}
