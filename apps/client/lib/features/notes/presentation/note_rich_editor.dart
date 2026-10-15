// Quill 11.6.0 已固定版本，以下公开配置钩子由组件回归覆盖。
// ignore_for_file: experimental_member_use

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_quill/quill_delta.dart';
import 'package:omni_butler/app/theme/note_composer_style.dart';

import '../markdown/note_markdown.dart';
import 'note_markdown_text.dart';

/// Windows 可视编辑会话；选区始终使用可见文字偏移而非 Markdown 偏移。
class NoteRichEditorController extends ChangeNotifier {
  /// 仅在加载时解析，未编辑的旧正文不会被重新编码。
  NoteRichEditorController({String source = ''}) : _markdown = source {
    _lastDelta = NoteMarkdown.toDelta(source);
    quillController = quill.QuillController(
      document: quill.Document.fromDelta(_lastDelta),
      selection: const TextSelection.collapsed(offset: 0),
      config: quill.QuillControllerConfig(
        clipboardConfig: quill.QuillClipboardConfig(
          enableExternalRichPaste: false,
          onClipboardPaste: _pasteText,
        ),
      ),
    )..addListener(_changed);
  }

  /// 富文本控制器只在此适配层和可视组件内使用。
  late final quill.QuillController quillController;

  /// 原生输入状态用于检测尚未完成的中文组词。
  final GlobalKey<quill.EditorState> editorKey = GlobalKey<quill.EditorState>();

  /// 最近一次正式同步或用户编辑产生的 Markdown。
  String _markdown;

  /// 比较内容变化时不把光标和选区变化当成编辑。
  late Delta _lastDelta;

  /// 草稿身份用于清除跨篇撤销和选区。
  String? _identity;

  /// 同步外部正文时抑制用户编辑通知。
  bool _syncing = false;

  /// 只对用户内容变更递增，外部加载不触发 onChanged。
  int _revision = 0;

  /// 编辑会话关闭后忽略迟到的剪贴板读取。
  bool _disposed = false;

  /// 外部持久层继续保存 Markdown。
  String get markdown => _markdown;

  /// 剥离 Quill 终止换行，保留用户自己的空行。
  String get plainText {
    // 当前可见文字，不含持久层格式标记。
    final String text = quillController.document.toPlainText();
    return text.endsWith('\n') ? text.substring(0, text.length - 1) : text;
  }

  /// 可见文字的选区，供转写插入和按钮状态读取。
  TextSelection get selection => quillController.selection;

  /// 显式选区设置支持工具栏恢复及测试真实快捷键。
  set selection(TextSelection value) => quillController.updateSelection(
    value.copyWith(
      baseOffset: value.baseOffset.clamp(0, plainText.length),
      extentOffset: value.extentOffset.clamp(0, plainText.length),
    ),
    quill.ChangeSource.local,
  );

  /// 当前选区全部为粗体时显示选中状态。
  bool get isBold => _attribute('bold') == true;

  /// 当前选区全部有下划线时显示选中状态。
  bool get isUnderline => _attribute('underline') == true;

  /// 高亮只有一种固定颜色。
  bool get isHighlight => _attribute('background') != null;

  /// 当前段落是有序列表。
  bool get isOrderedList => _listStyle == 'ordered';

  /// 当前段落是无序列表。
  bool get isBulletList => _listStyle == 'bullet';

  /// 列表身份取真实段落，避免 Quill 空段落继承上一行的工具栏样式。
  String? get _listStyle {
    // 选区起点所在的真实段落。
    quill.Line? line =
        quillController.document.queryChild(selection.start).node
            as quill.Line?;
    // 第一个段落的列表身份，用于检查跨段选区是否一致。
    String? selectedList;
    // 第一段也可能是普通段落，不能用 null 判断是否已经读取。
    bool first = true;
    while (line != null) {
      // 列表容器承载段落的块级样式。
      final quill.Node? parent = line.parent;
      // 当前段落的真实列表身份。
      final String? list =
          (line.style.attributes['list']?.value ??
                  (parent is quill.Block
                      ? parent.style.attributes['list']?.value
                      : null))
              as String?;
      if (!first && list != selectedList) return null;
      selectedList = list;
      first = false;
      if (selection.isCollapsed ||
          line.documentOffset + line.length >= selection.end) {
        break;
      }
      line = line.nextLine;
    }
    return selectedList;
  }

  /// 格式命令不能打断中文输入法尚未提交的组词。
  bool get _composing {
    // 当前真实富文本输入状态。
    final quill.EditorState? state = editorKey.currentState;
    if (state is! quill.QuillRawEditorState) return false;
    // 输入法尚未提交的组词范围。
    final TextRange range = state.composingRange.value;
    return range.isValid && !range.isCollapsed;
  }

  /// 未提交组词、冻结和保存期间不接受格式操作。
  bool get _editable => !quillController.readOnly && !_composing;

  /// 读取覆盖整个选区的公共属性，混合选区默认统一添加。
  dynamic _attribute(String key) =>
      quillController.getSelectionStyle().attributes[key]?.value;

  /// 加载正文不会触发内容回调，同篇同步保留合法选区。
  void syncMarkdown(String source, {String? identity}) {
    // 此次同步是否仍属于当前草稿。
    final bool sameIdentity = identity == null || identity == _identity;
    if (source == _markdown && sameIdentity) return;
    // 同步前的可见文字选区。
    final TextSelection previousSelection = selection;
    // 即将被替换并释放的旧文档。
    final quill.Document previousDocument = quillController.document;
    _syncing = true;
    _identity = identity ?? _identity;
    _markdown = source;
    _lastDelta = NoteMarkdown.toDelta(source);
    quillController.document = quill.Document.fromDelta(_lastDelta);
    quillController.forceToggledStyle(const quill.Style());
    selection = sameIdentity
        ? previousSelection
        : const TextSelection.collapsed(offset: 0);
    _syncing = false;
    previousDocument.close();
    notifyListeners();
  }

  /// 重复执行取消粗体；没有选区时设置后续输入样式。
  void toggleBold() => _toggle(quill.Attribute.bold, isBold);

  /// 下划线遵循与粗体相同的选区规则。
  void toggleUnderline() => _toggle(quill.Attribute.underline, isUnderline);

  /// 固定高亮不提供额外调色板。
  void toggleHighlight() => _toggle(
    const quill.BackgroundAttribute(NoteMarkdown.highlight),
    isHighlight,
  );

  /// 列表作用于选区覆盖的段落，重复点击恢复普通段落。
  void toggleList(bool ordered) => _toggle(
    ordered ? quill.Attribute.ol : quill.Attribute.ul,
    ordered ? isOrderedList : isBulletList,
  );

  /// 以 Quill 原生事务应用样式，保留选区与撤销记录。
  void _toggle(quill.Attribute attribute, bool active) {
    if (!_editable) return;
    quillController.formatSelection(
      active ? quill.Attribute.clone(attribute, null) : attribute,
    );
  }

  /// 转写与普通文字插入以可见选区替换，不使用原始 Markdown 下标。
  void insertText(String text) {
    if (!_editable) return;
    // 操作开始时固定的可见文字选区。
    final TextSelection selected = selection;
    if (text == '\n' &&
        selected.isCollapsed &&
        (isOrderedList || isBulletList)) {
      // 包含用户换行的可见正文。
      final String visible = plainText;
      // 光标所在行的起始偏移。
      final int lineStart = selected.start == 0
          ? 0
          : visible.lastIndexOf('\n', selected.start - 1) + 1;
      // 光标后第一个用户换行位置。
      final int nextBreak = visible.indexOf('\n', selected.start);
      // 光标所在行的结束偏移。
      final int lineEnd = nextBreak < 0 ? visible.length : nextBreak;
      if (lineStart == lineEnd) {
        quillController.formatSelection(const quill.ListAttribute(null));
        quillController.forceToggledStyle(const quill.Style());
        return;
      }
    }
    quillController.replaceText(
      selected.start,
      selected.end - selected.start,
      text,
      TextSelection.collapsed(offset: selected.start + text.length),
    );
  }

  /// 剪贴板只读纯文字，避免带入无法保存的颜色、链接或内嵌对象。
  Future<bool> _pasteText() async {
    // 异步操作启动时固定的草稿身份。
    final String? identity = _identity;
    // 操作开始时固定的可见文字选区。
    final TextSelection selected = selection;
    // 系统剪贴板返回的纯文字。
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    if (_disposed ||
        !_editable ||
        identity != _identity ||
        selected != selection) {
      return true;
    }
    if (data?.text != null) insertText(data!.text!);
    return true;
  }

  /// 只比较内容 Delta，按钮当前状态仍可随选区通知外层更新。
  void _changed() {
    if (_syncing || _disposed) return;
    // 当前正在处理的文档或行内缓冲。
    final Delta current = quillController.document.toDelta();
    if (current != _lastDelta) {
      _lastDelta = current;
      // 准备交给持久层的受限 Markdown。
      final String encoded = NoteMarkdown.fromDelta(current);
      if (_markdown != encoded) {
        _markdown = encoded;
        _revision++;
      }
    }
    notifyListeners();
  }

  /// 使用即将输入的结尾标记转换当前行，不重建整篇文档。
  bool _completeInline(
    String opening,
    String closing,
    quill.Attribute attribute,
  ) {
    if (!_editable || !selection.isCollapsed) return false;
    // 可见文档中的当前光标位置。
    final int caret = selection.extentOffset;
    // 光标之前的可见文字。
    final String before = plainText.substring(0, caret);
    // 包含当前将输入字符的候选内容。
    final String pending = before + closing[closing.length - 1];
    if (!pending.endsWith(closing)) return false;
    // 结束标记之前的内容边界。
    final int end = pending.length - closing.length;
    // 配对开始标记的位置。
    final int start = pending.lastIndexOf(opening, end - 1);
    if (start < 0 || end <= start + opening.length) return false;
    if (pending.substring(start, end).contains('\n')) return false;
    if (start > 0 && pending[start - 1] == r'\') return false;
    // 配对标记内实际文字的长度。
    final int contentLength = end - start - opening.length;
    // 只覆盖目标范围的原生编辑事务。
    final Delta change = Delta()
      ..retain(start)
      ..delete(opening.length)
      ..retain(contentLength, {attribute.key: attribute.value})
      ..delete(closing.length - 1);
    quillController.compose(change, selection, quill.ChangeSource.local);
    selection = TextSelection.collapsed(offset: start + contentLength);
    return true;
  }

  /// 当前行单独输入列表前缀加空格时切为相应列表。
  bool _completeList() {
    if (!_editable || !selection.isCollapsed) return false;
    // 可见文档中的当前光标位置。
    final int caret = selection.extentOffset;
    // 光标之前的可见文字。
    final String before = plainText.substring(0, caret);
    // 光标所在行的起始偏移。
    final int lineStart = before.lastIndexOf('\n') + 1;
    // 当前行实际匹配到的列表前缀。
    final String prefix = before.substring(lineStart);
    if (prefix != '-' && !RegExp(r'^[0-9]+\.$').hasMatch(prefix)) return false;
    quillController.replaceText(
      lineStart,
      prefix.length,
      '',
      TextSelection.collapsed(offset: lineStart),
    );
    quillController.formatSelection(
      prefix == '-' ? quill.Attribute.ul : quill.Attribute.ol,
    );
    return true;
  }

  /// 释放文档及控制器监听，异步粘贴不再写入。
  @override
  void dispose() {
    _disposed = true;
    quillController.removeListener(_changed);
    quillController.dispose();
    super.dispose();
  }
}

/// 仅正文输入区域具有富文本快捷键，搜索框与其他页面不受影响。
class NoteRichEditor extends StatefulWidget {
  /// 与原输入卡片共用外部焦点、草稿和布局。
  const NoteRichEditor({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    this.enabled = true,
    this.readOnly = false,
    this.minHeight = 160,
    this.style,
    this.placeholder = '现在的想法是...',
  });

  /// 本篇可视编辑控制器。
  final NoteRichEditorController controller;

  /// 与卡片聚焦边框和失焦暂存共用的焦点。
  final FocusNode focusNode;

  /// 只在用户实际修改内容时提交 Markdown。
  final ValueChanged<String> onChanged;

  /// 正在提交时禁用编辑操作。
  final bool enabled;

  /// 冲突或冻结状态保留阅读和选择能力。
  final bool readOnly;

  /// 新建编辑器保留原有最小正文高度。
  final double minHeight;

  /// 原卡片传入的正文样式。
  final TextStyle? style;

  /// 空文档提示。
  final String placeholder;

  /// 维护滚动和内容回调，不重建正文控制器。
  @override
  State<NoteRichEditor> createState() => _NoteRichEditorState();
}

/// 控制器的选区通知与正文持久通知分别处理。
class _NoteRichEditorState extends State<NoteRichEditor> {
  /// Quill 内部需要滚动控制器，正文仍交由外层页面滚动。
  final ScrollController _scroll = ScrollController();

  /// 最近已提交的用户内容版本。
  late int _revision;

  /// 安装内容监听。
  @override
  void initState() {
    super.initState();
    _revision = widget.controller._revision;
    widget.controller.addListener(_changed);
  }

  /// 外部换控制器时只更新监听，不发送原始加载正文。
  @override
  void didUpdateWidget(NoteRichEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      _revision = widget.controller._revision;
      widget.controller.addListener(_changed);
    }
  }

  /// 选区变化只更新可视状态，内容版本变化才触发 onChanged。
  void _changed() {
    if (!mounted) return;
    if (_revision != widget.controller._revision) {
      _revision = widget.controller._revision;
      widget.onChanged(widget.controller.markdown);
    }
  }

  /// 处理本功能快捷键并阻止未支持的格式和列表缩进。
  KeyEventResult? _key(KeyEvent event, quill.Node? node) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return null;
    // 本测试或当前组件的真实编辑控制器。
    final NoteRichEditorController controller = widget.controller;
    // 当前物理键盘是否按住 Ctrl。
    final bool control = HardwareKeyboard.instance.isControlPressed;
    if (control && !HardwareKeyboard.instance.isAltPressed) {
      if (event.logicalKey == LogicalKeyboardKey.keyB) {
        if (!HardwareKeyboard.instance.isShiftPressed) controller.toggleBold();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyU) {
        controller.toggleUnderline();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyI ||
          event.logicalKey == LogicalKeyboardKey.keyK ||
          event.logicalKey == LogicalKeyboardKey.keyM ||
          event.logicalKey == LogicalKeyboardKey.backquote ||
          event.logicalKey == LogicalKeyboardKey.tilde ||
          (HardwareKeyboard.instance.isShiftPressed &&
              (event.logicalKey == LogicalKeyboardKey.keyS ||
                  event.logicalKey == LogicalKeyboardKey.keyC))) {
        return KeyEventResult.handled;
      }
    }
    if (!controller._editable) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      controller.insertText('\n');
      return KeyEventResult.handled;
    }
    if (controller.selection.isCollapsed) {
      if (event.logicalKey == LogicalKeyboardKey.space &&
          controller._completeList()) {
        return KeyEventResult.handled;
      }
      if (event.character == '*' &&
          controller._completeInline('**', '**', quill.Attribute.bold)) {
        return KeyEventResult.handled;
      }
      if (event.character == '=' &&
          controller._completeInline(
            '==',
            '==',
            const quill.BackgroundAttribute(NoteMarkdown.highlight),
          )) {
        return KeyEventResult.handled;
      }
      if (event.character == '>' &&
          controller._completeInline(
            '<u>',
            '</u>',
            quill.Attribute.underline,
          )) {
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.backspace &&
          (controller.isBulletList || controller.isOrderedList)) {
        // 可见文档中的当前光标位置。
        final int caret = controller.selection.extentOffset;
        // 当前可见文字，不含持久层格式标记。
        final String text = controller.plainText;
        if (caret == 0 || text[caret - 1] == '\n') {
          controller.quillController.formatSelection(
            const quill.ListAttribute(null),
          );
          return KeyEventResult.handled;
        }
      }
    }
    return null;
  }

  /// 测量当前字体下最宽的同位数序号，整组列表共用列宽和八像素留白。
  double _listColumnWidth(
    TextStyle style,
    TextScaler scaler,
    TextDirection direction,
    int digits,
  ) {
    // 比较十个数字，避免比例数字字体中的 111 比 888 更窄。
    double width = 0;
    for (int digit = 0; digit <= 9; digit++) {
      // 每种候选只测量字形，留白和最小缩进最后统一追加。
      final TextPainter painter = TextPainter(
        text: TextSpan(text: '${'$digit' * digits}.', style: style),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      if (painter.width > width) width = painter.width;
      painter.dispose();
    }
    return (width + 8).ceilToDouble().clamp(
      NoteMarkdownText.listIndent,
      double.infinity,
    );
  }

  /// 统一标记字体与固定留白，避免 Quill 默认字号比例内边距挤压三位编号。
  Widget? _buildListMarker(quill.Node node, quill.LeadingConfig config) {
    if (config.attribute != quill.Attribute.ol &&
        config.attribute != quill.Attribute.ul) {
      return null;
    }
    return Container(
      width: config.width,
      alignment: AlignmentDirectional.topEnd,
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: Text(
        config.attribute == quill.Attribute.ol
            ? '${config.getIndexNumberByIndent}.'
            : '•',
        style: config.style,
        maxLines: 1,
        softWrap: false,
      ),
    );
  }

  /// 限定字体、行高和列表缩进，默认 Quill 工具栏不进入页面。
  @override
  Widget build(BuildContext context) {
    // 与原笔记卡片一致的正文样式。
    final TextStyle style = Theme.of(context).textTheme.bodyLarge!
        .merge(widget.style);
    // 数字标记和正文使用相同的系统字号缩放与文字方向。
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    // 标记测量与实际布局共享阅读方向。
    final TextDirection direction = Directionality.of(context);
    // 同次构建中同字号和位数只测量一次，避免长列表逐项重复测量。
    final Map<(double, int), double> columnWidths = {};
    // Quill 的正文缩进与序号容器必须引用同一个列宽计算。
    double markerWidth(double fontSize, int count) => columnWidths.putIfAbsent(
      (fontSize, count.toString().length),
      () => _listColumnWidth(
        style.copyWith(fontSize: fontSize),
        scaler,
        direction,
        count.toString().length,
      ),
    );
    // 普通段落的行高与间距配置。
    final quill.DefaultTextBlockStyle paragraph = quill.DefaultTextBlockStyle(
      style,
      quill.HorizontalSpacing.zero,
      quill.VerticalSpacing.zero,
      quill.VerticalSpacing.zero,
      null,
    );
    widget.controller.quillController.readOnly =
        !widget.enabled || widget.readOnly;
    return Localizations.override(
      context: context,
      delegates: const [quill.FlutterQuillLocalizations.delegate],
      child: quill.QuillEditor(
        controller: widget.controller.quillController,
        focusNode: widget.focusNode,
        scrollController: _scroll,
        config: quill.QuillEditorConfig(
          editorKey: widget.controller.editorKey,
          scrollable: false,
          minHeight: widget.minHeight,
          placeholder: widget.placeholder,
          padding: EdgeInsets.zero,
          onKeyPressed: _key,
          customLeadingBlockBuilder: _buildListMarker,
          customStyleBuilder: (attribute) => attribute.key == 'background'
              ? const TextStyle(color: NoteComposerStyle.highlightInk)
              : const TextStyle(),
          customStyles: quill.DefaultStyles(
            paragraph: paragraph,
            leading: paragraph,
            placeHolder: paragraph.copyWith(
              style: style.copyWith(color: Theme.of(context).hintColor),
            ),
            lists: quill.DefaultListBlockStyle(
              style,
              quill.HorizontalSpacing.zero,
              quill.VerticalSpacing.zero,
              quill.VerticalSpacing.zero,
              null,
              null,
              numberPointWidthBuilder: markerWidth,
              indentWidthBuilder: (block, _, count, width) =>
                  quill.HorizontalSpacing(
                    width(
                      style.fontSize ?? 16,
                      block.style.attributes['list'] == quill.Attribute.ol
                          ? count
                          : 1,
                    ),
                    0,
                  ),
            ),
          ),
        ),
      ),
    );
  }

  /// 控制器由页面释放，此处仅清理组件资源。
  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _scroll.dispose();
    super.dispose();
  }
}
