import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/note_composer_style.dart';

import '../markdown/note_markdown.dart';

/// 与编辑器共用解析结果；列表使用独立标记列，换行后保持悬挂缩进。
class NoteMarkdownText extends StatelessWidget {
  /// 创建受限 Markdown 的只读正文。
  const NoteMarkdownText({
    super.key,
    required this.source,
    this.style,
    this.maxLines,
    this.overflow = TextOverflow.clip,
  });

  /// 原始持久正文。
  final String source;

  /// 与外部标题、摘要或全文一致的基准字体。
  final TextStyle? style;

  /// 整段最多显示的视觉行数，而不是每个列表项的行数。
  final int? maxLines;

  /// 到达行数限制时的最后一行处理。
  final TextOverflow overflow;

  /// 列表标记和正文之间的总缩进。
  static const double listIndent = 24;

  /// 构建行内 span，标题及非列表文本测量可以直接复用。
  static TextSpan span(String source, {TextStyle? style}) {
    // 同一份正文解析得到的所有逻辑行。
    final List<NoteMarkdownLine> lines = NoteMarkdown.lines(source);
    return TextSpan(
      style: style,
      children: [
        for (int index = 0; index < lines.length; index++) ...[
          if (index > 0) const TextSpan(text: '\n'),
          ..._spans(lines[index]),
        ],
      ],
    );
  }

  /// 用与渲染完全相同的行宽及文字样式测量折叠和展开高度。
  static double measureHeight(
    String source, {
    required double maxWidth,
    required TextStyle style,
    required TextDirection textDirection,
    TextScaler textScaler = TextScaler.noScaling,
    int? maxLines,
  }) {
    // 已测量的可见内容总高度。
    double height = 0;
    // 摘要尚可容纳的视觉行数。
    int remaining = maxLines ?? 0x7fffffff;
    // 当前连续有序列表的序号。
    int orderedIndex = 0;
    for (final NoteMarkdownLine line in NoteMarkdown.lines(source)) {
      if (remaining <= 0) break;
      orderedIndex = line.list == 'ordered' ? orderedIndex + 1 : 0;
      // 当前列表项实际需要的标记列宽度。
      final double indent = _indent(
        line,
        orderedIndex,
        style,
        textDirection,
        textScaler,
      );
      // 与实际正文使用相同字体和宽度的测量对象。
      final TextPainter painter = _measure(
        line,
        maxWidth,
        style,
        textDirection,
        textScaler,
        remaining,
        indent,
      );
      height += painter.height;
      remaining -= painter.computeLineMetrics().length;
      painter.dispose();
    }
    return height;
  }

  /// 行内格式仅改变字体，不解析链接或任意 HTML。
  static List<InlineSpan> _spans(NoteMarkdownLine line) => [
    for (final NoteMarkdownRun run in line.runs)
      TextSpan(
        text: run.text,
        style: TextStyle(
          fontWeight: run.attributes['bold'] == true ? FontWeight.bold : null,
          decoration: run.attributes['underline'] == true
              ? TextDecoration.underline
              : null,
          backgroundColor: run.attributes['background'] != null
              ? NoteComposerStyle.highlight
              : null,
          color: run.attributes['background'] != null
              ? NoteComposerStyle.highlightInk
              : null,
        ),
      ),
  ];

  /// 空行也占一行高度；列表的标记列不参与内容换行。
  static TextPainter _measure(
    NoteMarkdownLine line,
    double width,
    TextStyle style,
    TextDirection direction,
    TextScaler scaler,
    int maxLines,
    double indent,
  ) => TextPainter(
    text: TextSpan(
      style: style,
      children: line.runs.isEmpty ? const [TextSpan(text: ' ')] : _spans(line),
    ),
    textDirection: direction,
    textScaler: scaler,
    maxLines: maxLines,
  )..layout(maxWidth: (width - indent).clamp(1, double.infinity));

  /// 大字号和三位以上序号按实际字形扩展标记列，避免数字自己换行。
  static double _indent(
    NoteMarkdownLine line,
    int index,
    TextStyle style,
    TextDirection direction,
    TextScaler scaler,
  ) {
    if (line.list == null) return 0;
    if (line.list == 'bullet') return listIndent;
    // 当前标记的解析或测量结果。
    final TextPainter marker = TextPainter(
      text: TextSpan(text: '$index.', style: style),
      textDirection: direction,
      textScaler: scaler,
    )..layout();
    // 标记字形及间距需要的总宽度。
    final double width = (marker.width + 8).clamp(listIndent, double.infinity);
    marker.dispose();
    return width;
  }

  /// 逐段布局保留列表的悬挂缩进和全局的两行摘要限制。
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // 合并当前主题后的实际字体样式。
      final TextStyle effectiveStyle = DefaultTextStyle.of(context).style
          .merge(style);
      // 与实际正文一致的文字方向。
      final TextDirection direction = Directionality.of(context);
      // 当前系统字号缩放。
      final TextScaler scaler = MediaQuery.textScalerOf(context);
      // 同一份正文解析得到的所有逻辑行。
      final List<NoteMarkdownLine> lines = NoteMarkdown.lines(source);
      // 按逻辑行顺序生成的可见组件。
      final List<Widget> children = [];
      // 摘要尚可容纳的视觉行数。
      int remaining = maxLines ?? 0x7fffffff;
      // 当前连续有序列表的序号。
      int orderedIndex = 0;
      for (int index = 0; index < lines.length && remaining > 0; index++) {
        // 当前正在呈现的逻辑行。
        final NoteMarkdownLine line = lines[index];
        orderedIndex = line.list == 'ordered' ? orderedIndex + 1 : 0;
        // 当前列表项实际需要的标记列宽度。
        final double indent = _indent(
          line,
          orderedIndex,
          effectiveStyle,
          direction,
          scaler,
        );
        // 与实际正文使用相同字体和宽度的测量对象。
        final TextPainter painter = _measure(
          line,
          constraints.maxWidth,
          effectiveStyle,
          direction,
          scaler,
          remaining,
          indent,
        );
        // 当前逻辑行实际占用的视觉行数。
        final int visibleLines = painter.computeLineMetrics().length;
        // 当前行是否耗尽摘要行数。
        final bool lastVisible = visibleLines >= remaining;
        painter.dispose();
        // 当前可见文字，不含持久层格式标记。
        final Widget text = Text.rich(
          TextSpan(
            children: line.runs.isEmpty
                ? const [TextSpan(text: ' ')]
                : _spans(line),
          ),
          style: effectiveStyle,
          maxLines: remaining,
          overflow: lastVisible ? overflow : TextOverflow.clip,
        );
        children.add(
          line.list == null
              ? text
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: indent,
                      child: Text(
                        line.list == 'ordered' ? '$orderedIndex.' : '•',
                        style: effectiveStyle,
                        maxLines: 1,
                        softWrap: false,
                      ),
                    ),
                    Expanded(child: text),
                  ],
                ),
        );
        remaining -= visibleLines;
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: children,
      );
    },
  );
}
