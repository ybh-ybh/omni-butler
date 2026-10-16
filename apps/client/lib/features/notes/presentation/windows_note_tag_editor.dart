import 'dart:async';
import 'dart:math' as math;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/notes/data/note_tag_emoji_catalog.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 标签名称及图标编辑浮层的默认宽度。
const double _editorWidth = 320;

/// 表情选择器保留独立的内部滚动区域。
const double _pickerMaxHeight = 320;

/// 在当前窗口中锚定标签的更多按钮，不创建原生弹窗。
Future<void> showWindowsNoteTagEditor({
  required BuildContext context,
  required BuildContext anchorContext,
  TaxonomyEntry? tag,
  Future<void> Function(String name, String? emoji)? onCreate,
  bool startWithPicker = false,
}) {
  assert(tag != null || onCreate != null);
  // 只在入口仍挂载时读取渲染对象，关闭动画不再访问旧元素。
  final RenderObject? anchorObject = anchorContext.findRenderObject();
  // 定位坐标与弹窗使用同一个根导航覆盖层。
  final RenderObject? overlayObject = Navigator.of(
    context,
    rootNavigator: true,
  ).overlay?.context.findRenderObject();
  // 首次位置在锚点卸载时仍可作为安全回退。
  final Rect initialAnchor =
      anchorObject is RenderBox && overlayObject is RenderBox
      ? anchorObject.localToGlobal(Offset.zero, ancestor: overlayObject) &
            anchorObject.size
      : Rect.zero;
  return showOmniDialog<void>(
    context: context,
    barrierColor: Colors.transparent,
    barrierDismissible: false,
    useSafeArea: false,
    builder: (_) => _NoteTagAppearanceEditor(
      tag: tag,
      onCreate: onCreate,
      startWithPicker: startWithPicker,
      anchor: () {
        if (anchorObject is RenderBox &&
            overlayObject is RenderBox &&
            anchorObject.attached &&
            overlayObject.attached) {
          return anchorObject.localToGlobal(
                Offset.zero,
                ancestor: overlayObject,
              ) &
              anchorObject.size;
        }
        return initialAnchor;
      },
    ),
  );
}

/// 默认井号与自定义表情使用同一占位，侧栏不会因换图标移动文字。
class NoteTagIcon extends StatelessWidget {
  /// 指定标签的可选图标及所在行的原有视觉尺寸。
  const NoteTagIcon({
    required this.emoji,
    this.size = OmniSize.icon,
    this.color,
    super.key,
  });

  /// 完整的 Unicode 表情序列；空值保留井号。
  final String? emoji;

  /// 图标占位边长。
  final double size;

  /// 默认井号沿用正文或按钮的颜色。
  final Color? color;

  /// 表情使用 Windows 系统彩色字体并完整保留组合字符。
  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: emoji == null || emoji!.isEmpty
        ? Icon(Icons.tag, size: size, color: color)
        : ExcludeSemantics(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                emoji!,
                style: TextStyle(
                  fontFamily: 'Segoe UI Emoji',
                  fontFamilyFallback: const ['Noto Color Emoji'],
                  fontSize: size,
                  height: 1,
                ),
              ),
            ),
          ),
  );
}

/// 一个路由同时管理编辑面板和下方的表情面板，避免遮罩相互拦截。
class _NoteTagAppearanceEditor extends ConsumerStatefulWidget {
  /// 接收原标签快照和可随窗口变化重新计算的锚点。
  const _NoteTagAppearanceEditor({
    required this.tag,
    required this.anchor,
    required this.onCreate,
    required this.startWithPicker,
  });

  /// 打开时的标签值，用来判断哪些字段真正被用户修改。
  final TaxonomyEntry? tag;

  /// 管理器新增标签时复用同一名称与表情草稿。
  final Future<void> Function(String name, String? emoji)? onCreate;

  /// 点击管理器图标时直接展开表情选择器。
  final bool startWithPicker;

  /// 当前覆盖层坐标中的更多按钮位置。
  final Rect Function() anchor;

  /// 创建独立的表单草稿。
  @override
  ConsumerState<_NoteTagAppearanceEditor> createState() =>
      _NoteTagAppearanceEditorState();
}

/// 所有选择先写本次草稿，仓储成功后才退出编辑。
class _NoteTagAppearanceEditorState
    extends ConsumerState<_NoteTagAppearanceEditor> {
  /// 标签名称的未提交输入。
  late final TextEditingController _name = TextEditingController(
    text: widget.tag?.name ?? '',
  );

  /// 表情检索与侧栏筛选、笔记搜索互相独立。
  final TextEditingController _search = TextEditingController();

  /// 从选择器返回后恢复名称输入位置。
  final FocusNode _nameFocus = FocusNode();

  /// 搜索框单独接收焦点，避免 Enter 冒泡为保存。
  final FocusNode _searchFocus = FocusNode();

  /// 选择器收起后可将焦点交回图标入口。
  final FocusNode _iconFocus = FocusNode();

  /// 当前草稿图标，null 代表默认井号。
  late String? _emoji = widget.tag?.iconEmoji;

  /// 选择器的显隐不改变名称及已选表情。
  bool _pickerOpen = false;

  /// 首次打开选择器时加载离线资产，不阻塞名称编辑。
  Future<NoteTagEmojiCatalog>? _catalog;

  /// 提交期间冻结操作与关闭。
  bool _saving = false;

  /// 保存错误保持在名称面板内，允许修正或重试。
  String? _error;

  /// 管理器的图标入口可直接显示既有表情面板。
  @override
  void initState() {
    super.initState();
    if (widget.startWithPicker) {
      _pickerOpen = true;
      _catalog = NoteTagEmojiCatalog.load();
      _catalog!.ignore();
    }
  }

  /// 释放本浮层持有的输入和焦点。
  @override
  void dispose() {
    _name.dispose();
    _search.dispose();
    _nameFocus.dispose();
    _searchFocus.dispose();
    _iconFocus.dispose();
    super.dispose();
  }

  /// 打开选择器时恢复完整分类，不遗留上次检索条件。
  void _togglePicker() {
    if (_saving) return;
    setState(() {
      _pickerOpen = !_pickerOpen;
      if (_pickerOpen) {
        _catalog ??= NoteTagEmojiCatalog.load();
        // 事件回调后下一帧才挂载FutureBuilder，先接住可能立即失败的资源请求。
        _catalog!.ignore();
        _search.clear();
      }
    });
    if (!_pickerOpen) _iconFocus.requestFocus();
  }

  /// 普通选择和移除收起面板，随机允许连续比较图标。
  void _selectEmoji(String? value, {bool close = true}) {
    if (_saving) return;
    setState(() {
      _emoji = value;
      if (close) _pickerOpen = false;
    });
    if (close) _iconFocus.requestFocus();
  }

  /// 无提交进行时，外部点击放弃整个草稿。
  void _dismiss() {
    if (!_saving) Navigator.of(context).pop();
  }

  /// Esc 逐层返回，名称 Enter 只在没有输入法组合文字时提交。
  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (!_saving && _pickerOpen) {
        setState(() => _pickerOpen = false);
        _iconFocus.requestFocus();
      } else {
        _dismiss();
      }
      return KeyEventResult.handled;
    }
    if (_nameFocus.hasFocus &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter) &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isAltPressed &&
        !HardwareKeyboard.instance.isMetaPressed &&
        !HardwareKeyboard.instance.isShiftPressed &&
        _name.value.composing.isCollapsed) {
      unawaited(_save());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 仅把用户实际改动的字段交给原子仓储接口。
  Future<void> _save() async {
    if (_saving || !_name.value.composing.isCollapsed) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (widget.tag == null) {
        await widget.onCreate!(_name.text, _emoji);
      } else {
        await ref
            .read(taxonomyRepositoryProvider)
            .updateNoteTagAppearance(
              widget.tag!.id,
              name: _name.text.trim() == widget.tag!.name
                  ? const Value.absent()
                  : Value(_name.text),
              iconEmoji: _emoji == widget.tag!.iconEmoji
                  ? const Value.absent()
                  : Value(_emoji),
            );
      }
      if (mounted) Navigator.of(context).pop();
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _error = error is FormatException
              ? error.message
              : error is StateError
              ? error.message
              : '保存失败：$error';
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 两块面板共享焦点范围与透明外部关闭区域。
  @override
  Widget build(BuildContext context) {
    // 安全区及软键盘参与浮层可用边界。
    final MediaQueryData media = MediaQuery.of(context);
    return PopScope(
      canPop: !_saving,
      child: Focus(
        onKeyEvent: _handleKey,
        child: Stack(
          children: [
            Positioned.fill(
              child: Semantics(
                label: '关闭标签编辑',
                button: true,
                child: GestureDetector(
                  key: const ValueKey('notes-tag-editor-dismiss'),
                  behavior: HitTestBehavior.opaque,
                  onTap: _saving ? null : _dismiss,
                ),
              ),
            ),
            CustomSingleChildLayout(
              delegate: _NoteTagEditorPosition(
                anchor: widget.anchor(),
                insets: EdgeInsets.fromLTRB(
                  media.padding.left + OmniSpacing.xs,
                  media.padding.top + OmniSpacing.xs,
                  media.padding.right + OmniSpacing.xs,
                  math.max(media.padding.bottom, media.viewInsets.bottom) +
                      OmniSpacing.xs,
                ),
              ),
              child: Semantics(
                scopesRoute: true,
                namesRoute: true,
                label: '编辑名称/图标',
                explicitChildNodes: true,
                child: FocusTraversalGroup(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _editor(),
                      if (_pickerOpen) ...[
                        const SizedBox(height: OmniSpacing.xs),
                        Flexible(fit: FlexFit.loose, child: _picker()),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 窄窗口与大字号时把名称输入放到下一行，避免截断按钮。
  Widget _editor() => OmniPanel(
    key: const ValueKey('notes-tag-editor'),
    padding: const EdgeInsets.all(OmniSpacing.sm),
    child: LayoutBuilder(
      builder: (context, constraints) {
        // 文本缩放后的按钮与输入框决定能否同排。
        final bool stacked =
            constraints.maxWidth < 260 ||
            MediaQuery.textScalerOf(context).scale(14) > 20;
        // 图标按钮保留与侧栏一致的默认井号。
        final Widget icon = OmniIconButton(
          key: const ValueKey('notes-tag-icon-button'),
          tooltip: '选择标签图标',
          focusNode: _iconFocus,
          isSelected: _pickerOpen,
          onPressed: _saving ? null : _togglePicker,
          icon: NoteTagIcon(emoji: _emoji),
        );
        // 保存按钮只提交本浮层的名称与图标。
        final Widget save = OmniButton(
          key: const ValueKey('notes-tag-save'),
          label: '保存',
          loading: _saving,
          onPressed: _saving ? null : () => unawaited(_save()),
        );
        // 错误行独立于输入框，窄栏中可以完整换行。
        final Widget name = OmniTextField(
          key: const ValueKey('notes-tag-name'),
          controller: _name,
          focusNode: _nameFocus,
          autofocus: true,
          enabled: !_saving,
          textInputAction: TextInputAction.done,
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          // 保留输入法组合区，让提交校验区分候选确认与真正的保存动作。
          onEditingComplete: () {},
          onSubmitted: (_) => unawaited(_save()),
          decoration: const InputDecoration(hintText: '标签名称'),
        );
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (stacked) ...[
              Row(children: [icon, const Spacer(), save]),
              const SizedBox(height: OmniSpacing.xs),
              name,
            ] else
              Row(
                children: [
                  icon,
                  const SizedBox(width: OmniSpacing.xs),
                  Expanded(child: name),
                  const SizedBox(width: OmniSpacing.xs),
                  save,
                ],
              ),
            if (_error != null) ...[
              const SizedBox(height: OmniSpacing.xs),
              Text(
                _error!,
                key: const ValueKey('notes-tag-editor-error'),
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        );
      },
    ),
  );

  /// 选择器读取离线目录，加载失败时可原地重试。
  Widget _picker() => ConstrainedBox(
    constraints: const BoxConstraints(maxHeight: _pickerMaxHeight),
    child: OmniPanel(
      key: const ValueKey('notes-tag-emoji-picker'),
      padding: const EdgeInsets.all(OmniSpacing.sm),
      child: FutureBuilder<NoteTagEmojiCatalog>(
        future: _catalog,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _pickerTools(null),
                const SizedBox(height: OmniSpacing.xs),
                const Text('表情加载失败'),
                OmniButton(
                  label: '重试',
                  variant: OmniButtonVariant.text,
                  onPressed: _saving
                      ? null
                      : () => setState(() {
                          _catalog = NoteTagEmojiCatalog.load();
                          _catalog!.ignore();
                        }),
                ),
              ],
            );
          }
          // 载入期间仍允许移除图标或返回编辑。
          final NoteTagEmojiCatalog? catalog = snapshot.data;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _pickerTools(catalog),
              const SizedBox(height: OmniSpacing.xs),
              Flexible(
                fit: FlexFit.loose,
                child: catalog == null
                    ? const Padding(
                        padding: EdgeInsets.all(OmniSpacing.sm),
                        child: Text('正在加载表情…'),
                      )
                    : _emojiList(catalog),
              ),
            ],
          );
        },
      ),
    ),
  );

  /// 随机从完整目录选择，不受当前搜索条件影响。
  Widget _pickerTools(NoteTagEmojiCatalog? catalog) => LayoutBuilder(
    builder: (context, constraints) {
      // 大字号下将搜索框移到独立一行。
      final bool stacked =
          constraints.maxWidth < 260 ||
          MediaQuery.textScalerOf(context).scale(14) > 20;
      // 随机按钮允许连续生成不同的候选图标。
      final Widget random = OmniIconButton(
        key: const ValueKey('notes-tag-emoji-random'),
        tooltip: '随机图标',
        icon: const Icon(Icons.shuffle),
        onPressed: catalog == null || _saving
            ? null
            : () => _selectEmoji(
                catalog.random(excluding: _emoji).emoji,
                close: false,
              ),
      );
      // 移除只改变草稿，统一点击保存后生效。
      final Widget remove = OmniButton(
        key: const ValueKey('notes-tag-emoji-remove'),
        label: '移除',
        compact: true,
        variant: OmniButtonVariant.secondary,
        onPressed: _emoji == null || _saving ? null : () => _selectEmoji(null),
      );
      // 搜索 Enter 不关联名称提交。
      final Widget search = OmniTextField(
        key: const ValueKey('notes-tag-emoji-search'),
        controller: _search,
        focusNode: _searchFocus,
        enabled: !_saving,
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _searchFocus.requestFocus(),
        decoration: const InputDecoration(
          hintText: '搜索表情',
          prefixIcon: Icon(Icons.search, size: OmniSize.icon),
          prefixIconConstraints: BoxConstraints.tightFor(
            width: OmniSize.iconButton,
            height: OmniSize.iconButton,
          ),
        ),
      );
      return stacked
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(children: [random, const Spacer(), remove]),
                const SizedBox(height: OmniSpacing.xs),
                search,
              ],
            )
          : Row(
              children: [
                random,
                const SizedBox(width: OmniSpacing.xs),
                Expanded(child: search),
                const SizedBox(width: OmniSpacing.xs),
                remove,
              ],
            );
    },
  );

  /// 分类标题和网格均在同一个滚动视口中，避免构建全部表情按钮。
  Widget _emojiList(NoteTagEmojiCatalog catalog) {
    // 中英文关键词检索复用目录的唯一索引。
    final List<NoteTagEmoji> matches = catalog.search(_search.text);
    if (matches.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(OmniSpacing.sm),
        child: Text('没有找到表情'),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // 图标热区始终不小于统一桌面按钮尺寸。
        final int columns = math.max(
          1,
          (constraints.maxWidth / OmniSize.iconButton).floor(),
        );
        return CustomScrollView(
          key: const ValueKey('notes-tag-emoji-list'),
          primary: false,
          shrinkWrap: true,
          slivers: [
            for (final MapEntry<String, String> category
                in NoteTagEmojiCatalog.categoryLabels.entries)
              if (matches.any((emoji) => emoji.category == category.key)) ...[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: OmniSpacing.xs,
                    ),
                    child: Text(
                      category.value,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
                _categoryGrid(
                  matches
                      .where((emoji) => emoji.category == category.key)
                      .toList(growable: false),
                  columns,
                ),
              ],
          ],
        );
      },
    );
  }

  /// 每个表情保留名称、选中语义、键盘焦点和统一按压反馈。
  Widget _categoryGrid(List<NoteTagEmoji> entries, int columns) => SliverGrid(
    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columns,
      mainAxisExtent: OmniSize.iconButton,
    ),
    delegate: SliverChildBuilderDelegate((context, index) {
      // 当前格子的完整表情序列及中文关键词。
      final NoteTagEmoji emoji = entries[index];
      return Center(
        child: Semantics(
          selected: _emoji == emoji.emoji,
          child: OmniIconButton(
            key: ValueKey('notes-tag-emoji-${emoji.emoji}'),
            tooltip: emoji.label,
            isSelected: _emoji == emoji.emoji,
            icon: NoteTagIcon(emoji: emoji.emoji, size: OmniSpacing.xl),
            onPressed: _saving ? null : () => _selectEmoji(emoji.emoji),
          ),
        ),
      );
    }, childCount: entries.length),
  );
}

/// 浮层使用实际布局高度整体避让边缘，选择器仍保持在名称面板下方。
class _NoteTagEditorPosition extends SingleChildLayoutDelegate {
  /// 固定本帧锚点及安全边界。
  const _NoteTagEditorPosition({required this.anchor, required this.insets});

  /// 更多按钮在当前覆盖层中的位置。
  final Rect anchor;

  /// 安全区、键盘与窗口边缘的保留空间。
  final EdgeInsets insets;

  /// 编辑浮层默认紧凑宽度，窄窗只缩到当前可用空间。
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        minWidth: math.min(
          _editorWidth,
          math.max(0, constraints.maxWidth - insets.horizontal),
        ),
        maxWidth: math.min(
          _editorWidth,
          math.max(0, constraints.maxWidth - insets.horizontal),
        ),
        maxHeight: math.max(0, constraints.maxHeight - insets.vertical),
      );

  /// 尽量与入口左上对齐，实际高度超出时向上回收位置。
  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    anchor.left.clamp(
      insets.left,
      math.max(insets.left, size.width - insets.right - childSize.width),
    ),
    anchor.top.clamp(
      insets.top,
      math.max(insets.top, size.height - insets.bottom - childSize.height),
    ),
  );

  /// 窗口、锚点或键盘变化后重新布局。
  @override
  bool shouldRelayout(_NoteTagEditorPosition oldDelegate) =>
      anchor != oldDelegate.anchor || insets != oldDelegate.insets;
}
