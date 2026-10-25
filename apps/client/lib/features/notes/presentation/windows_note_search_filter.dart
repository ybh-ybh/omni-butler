import 'dart:math' as math;

import '../data/note_search_filter.dart';

import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 保留 Windows 调用方名称，条件模型由两端共用。
typedef WindowsNoteSearchFilter = NoteSearchFilter;

/// 在当前窗口的过滤按钮下方显示菜单，取消时不提交草稿。
Future<WindowsNoteSearchFilter?> showWindowsNoteSearchFilter({
  required BuildContext context,
  required GlobalKey anchorKey,
  required WindowsNoteSearchFilter value,
  required List<TaxonomyEntry> tags,
}) async {
  // 菜单锚点必须仍在当前窗口中挂载。
  final RenderObject? anchorObject = anchorKey.currentContext
      ?.findRenderObject();
  // 与统一菜单路由一致的当前窗口坐标系。
  final RenderObject? overlayObject = Navigator.of(context).overlay?.context
      .findRenderObject();
  if (anchorObject is! RenderBox ||
      !anchorObject.attached ||
      overlayObject is! RenderBox) {
    return null;
  }
  // 起点位于按钮下方，右边缘与触发按钮对齐。
  final Offset origin = anchorObject.localToGlobal(
    Offset.zero,
    ancestor: overlayObject,
  );
  // 窄窗口保留菜单安全边距，正常窗口使用参考面板宽度。
  final double width = math.min(
    320,
    math.max(0, overlayObject.size.width - OmniSpacing.md * 2),
  );
  return showOmniMenu<WindowsNoteSearchFilter>(
    context: context,
    position: RelativeRect.fromRect(
      Rect.fromLTWH(
        origin.dx + anchorObject.size.width - width,
        origin.dy + anchorObject.size.height + OmniSpacing.xs,
        width,
        0,
      ),
      Offset.zero & overlayObject.size,
    ),
    constraints: BoxConstraints.tightFor(width: width),
    menuPadding: const EdgeInsets.all(OmniSpacing.xs),
    requestFocus: true,
    items: <PopupMenuEntry<WindowsNoteSearchFilter>>[
      _SearchFilterEntry(value: value, tags: tags),
    ],
  );
}

/// 将可编辑过滤表单放入统一菜单路由，保留外部点击及 Escape 关闭。
class _SearchFilterEntry extends PopupMenuEntry<WindowsNoteSearchFilter> {
  /// 本次打开时的已应用值。
  final WindowsNoteSearchFilter value;

  /// 调用方提供的当前可见标签名单。
  final List<TaxonomyEntry> tags;

  /// 创建包含全部过滤组的单一条目。
  const _SearchFilterEntry({required this.value, required this.tags});

  /// 时间始终展开，其他分组展开后由菜单实际布局测量。
  @override
  double get height =>
      OmniMenuMetrics.itemHeight * 4 + OmniSize.control * 2 + OmniSpacing.md;

  /// 表单由底部搜索按钮统一提交，不对应单个菜单选中值。
  @override
  bool represents(WindowsNoteSearchFilter? value) => false;

  /// 每次打开创建独立的过滤草稿。
  @override
  State<_SearchFilterEntry> createState() => _SearchFilterEntryState();
}

/// 折叠、日期和选择状态均局限于本次菜单会话。
class _SearchFilterEntryState extends State<_SearchFilterEntry> {
  /// 标签输入独立于笔记正文搜索。
  final TextEditingController _tagSearch = TextEditingController();

  /// 当前草稿的时间预设。
  late String _range;

  /// 当前草稿的自定义起始日期，未完成时保持空值。
  DateTime? _customStart;

  /// 当前草稿的自定义结束日期，未完成时保持空值。
  DateTime? _customEnd;

  /// 当前草稿的标签关系。
  late String _tagMode;

  /// 菜单内独立编辑的标签身份集合。
  late Set<String> _tagIds;

  /// 菜单内独立编辑的内容类型集合。
  late Set<String> _contents;

  /// 时间标题没有折叠操作，但仍保留视频中的文字悬停反馈。
  bool _timeTitleHovered = false;

  /// 标签输入框的悬停只绘制中性细边框。
  bool _tagSearchHovered = false;

  /// 输入和已选标签共用焦点，选择结果后可以继续搜索。
  final FocusNode _tagSearchFocus = FocusNode();

  /// 标签组只在点击或已有条件时展开。
  late bool _tagsExpanded;

  /// 内容组只在点击或已有条件时展开。
  late bool _contentExpanded;

  /// 自定义日期校验错误保留在日期输入附近。
  String? _dateError;

  /// 从已应用值复制草稿，避免取消时修改页面过滤条件。
  @override
  void initState() {
    super.initState();
    _range = widget.value.range;
    _customStart = widget.value.customRange?.start;
    _customEnd = widget.value.customRange?.end;
    _tagMode = widget.value.tagMode;
    _tagIds = Set<String>.of(widget.value.tagIds);
    _contents = Set<String>.of(widget.value.contents);
    _tagsExpanded = _tagMode == 'none' || _tagIds.isNotEmpty;
    _contentExpanded = _contents.isNotEmpty;
  }

  /// 菜单关闭后释放局部输入状态。
  @override
  void dispose() {
    _tagSearch.dispose();
    _tagSearchFocus.dispose();
    super.dispose();
  }

  /// 清空全部草稿但保持菜单和当前展开组，允许继续选择。
  void _reset() {
    setState(() {
      _range = 'all';
      _customStart = null;
      _customEnd = null;
      _tagMode = 'include';
      _tagIds.clear();
      _contents.clear();
      _dateError = null;
      _tagSearch.clear();
    });
  }

  /// 校验完整日期后一次性返回过滤值，取消路线始终返回空。
  void _apply() {
    if (_range == 'custom' &&
        (_customStart == null ||
            _customEnd == null ||
            _customEnd!.isBefore(_customStart!))) {
      setState(() {
        _dateError = _customStart == null || _customEnd == null
            ? '请选择开始和结束日期'
            : '结束日期不能早于开始日期';
      });
      return;
    }
    Navigator.of(context).pop(
      WindowsNoteSearchFilter(
        range: _range,
        customRange: _range == 'custom'
            ? DateTimeRange(start: _customStart!, end: _customEnd!)
            : null,
        tagMode: _tagMode,
        tagIds: _tagMode == 'none' ? const <String>{} : _tagIds,
        contents: _contents,
      ),
    );
  }

  /// 切换任意多选项，已选项目再次点击即取消。
  void _toggle(Set<String> selection, String value) {
    setState(() {
      if (!selection.remove(value)) selection.add(value);
    });
  }

  /// 标题无条件时呈浅灰色，悬停、键盘焦点及已选条件使用正文色。
  Widget _section({
    required String id,
    required String title,
    required bool expanded,
    required bool active,
    VoidCallback? onPressed,
    required Widget child,
  }) {
    // 标题与分隔线沿用当前主题的明暗颜色。
    final OmniColors colors = OmniColors.of(context);
    // 鼠标打开菜单时首项虽获得焦点，只有键盘导航才显示焦点文字色。
    final bool keyboardNavigation = OmniMenuNavigation.keyboardOf(context);
    // 时间标题没有折叠箭头，其他标题沿用同一对齐位置。
    final Widget label = Row(
      children: [
        Expanded(child: Text(title)),
        if (onPressed != null) ...[
          const SizedBox(width: OmniSpacing.xs),
          Icon(
            expanded ? Icons.expand_less : Icons.expand_more,
            size: OmniSize.icon,
          ),
        ],
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (onPressed == null)
          MouseRegion(
            key: ValueKey<String>('notes-filter-section-$id'),
            onEnter: (_) => setState(() => _timeTitleHovered = true),
            onExit: (_) => setState(() => _timeTitleHovered = false),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: OmniMenuMetrics.itemHeight,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.xs),
                child: AnimatedDefaultTextStyle(
                  duration: OmniMotion.duration(context, OmniMotion.fast),
                  style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                    fontWeight: FontWeight.w400,
                    color: active || _timeTitleHovered
                        ? colors.ink
                        : colors.muted,
                  ),
                  child: Semantics(header: true, child: label),
                ),
              ),
            ),
          )
        else
          OmniDisclosureToggle(
            expanded: expanded,
            child: OmniTextButton(
              key: ValueKey<String>('notes-filter-section-$id'),
              onPressed: onPressed,
              style: ButtonStyle(
                alignment: Alignment.centerLeft,
                padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
                  EdgeInsets.symmetric(horizontal: OmniSpacing.xs),
                ),
                minimumSize: const WidgetStatePropertyAll<Size>(
                  Size(0, OmniMenuMetrics.itemHeight),
                ),
                foregroundColor: WidgetStateProperty.resolveWith<Color>((
                  Set<WidgetState> states,
                ) {
                  return active ||
                          states.contains(WidgetState.hovered) ||
                          keyboardNavigation &&
                              states.contains(WidgetState.focused)
                      ? colors.ink
                      : colors.muted;
                }),
                backgroundColor: const WidgetStatePropertyAll<Color>(
                  Colors.transparent,
                ),
                overlayColor: const WidgetStatePropertyAll<Color>(
                  Colors.transparent,
                ),
                side: const WidgetStatePropertyAll<BorderSide>(BorderSide.none),
                textStyle: WidgetStatePropertyAll<TextStyle?>(
                  Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w400),
                ),
              ),
              child: label,
            ),
          ),
        OmniDisclosure(
          expanded: expanded,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              OmniSpacing.xs,
              OmniSpacing.xxs,
              OmniSpacing.xs,
              OmniSpacing.sm,
            ),
            child: child,
          ),
        ),
      ],
    );
  }

  /// 按截图统一选项的细描边、浅灰底和浅主题色选中底。
  ButtonStyle _choiceStyle({required bool selected}) {
    // 截图中的绿色统一映射为当前主题色。
    final OmniColors colors = OmniColors.of(context);
    // 鼠标打开菜单产生的默认焦点不覆盖选中或非选中外观。
    final bool keyboardNavigation = OmniMenuNavigation.keyboardOf(context);
    return TextButton.styleFrom(
      foregroundColor: selected ? colors.brand : colors.ink,
      minimumSize: const Size(0, OmniSize.control),
      padding: const EdgeInsets.symmetric(
        horizontal: OmniSpacing.xs,
        vertical: OmniSpacing.xxs,
      ),
      alignment: Alignment.center,
      textStyle: Theme.of(context).textTheme.bodySmall
          ?.copyWith(fontSize: 13, fontWeight: FontWeight.w400),
      animationDuration: OmniMotion.duration(context, OmniMotion.fast),
    ).copyWith(
      overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
      backgroundColor: WidgetStateProperty.resolveWith<Color>((states) {
        // 悬停及按下加深同一颜色，不引入默认品牌水波纹。
        final bool emphasized =
            states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.pressed);
        return Color.alphaBlend(
          (selected ? colors.brand : colors.ink).withValues(
            alpha: selected
                ? (emphasized ? 0.22 : 0.16)
                : (emphasized ? 0.09 : 0.055),
          ),
          colors.paper,
        );
      }),
      side: WidgetStateProperty.resolveWith<BorderSide>(
        (states) => BorderSide(
          color: keyboardNavigation && states.contains(WidgetState.focused)
              ? colors.ink.withValues(alpha: 0.55)
              : selected
              ? colors.brand.withValues(alpha: 0.32)
              : colors.line.withValues(alpha: 0.55),
        ),
      ),
    );
  }

  /// 选中只改变颜色和边框，文字位置保持居中且不出现额外勾选图标。
  Widget _choice({
    required String id,
    required String label,
    required bool selected,
    required VoidCallback onPressed,
  }) {
    return Semantics(
      selected: selected,
      child: OmniTextButton(
        key: ValueKey<String>('notes-filter-$id'),
        onPressed: onPressed,
        style: _choiceStyle(selected: selected),
        child: Text(label, textAlign: TextAlign.center),
      ),
    );
  }

  /// 常规字号使用参考视频中的三列等宽选择，大字号降为两列。
  Widget _choices(List<Widget> choices) => LayoutBuilder(
    builder: (context, constraints) {
      // 文字放大时多留一列空间，按钮内容可以自然换行。
      final int columns = MediaQuery.textScalerOf(context).scale(13) > 18
          ? 2
          : 3;
      // 每一列扣除相邻间距后公平分配可用宽度。
      final double width =
          (constraints.maxWidth - OmniSpacing.xs * (columns - 1)) / columns;
      return Wrap(
        spacing: OmniSpacing.xs,
        runSpacing: OmniSpacing.xs,
        children: [
          // 同一组的所有选项使用相同宽度。
          for (final Widget choice in choices)
            SizedBox(width: width, child: choice),
        ],
      );
    },
  );

  /// 时间范围始终展开，自定义日期沿用现有校验和窗口内日历。
  Widget _timeOptions() {
    // 固定预设与业务匹配层约定相同的身份。
    const Map<String, String> ranges = <String, String>{
      'month': '本月',
      'lastMonth': '上月',
      'last7': '近 7 天',
      'last30': '近 30 天',
      'custom': '自定义',
      'all': '不限',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _choices(<Widget>[
          // 时间预设不同时生效，点击后只更新本地草稿。
          for (final MapEntry<String, String> range in ranges.entries)
            _choice(
              id: 'range-${range.key}',
              label: range.value,
              selected: _range == range.key,
              onPressed: () => setState(() {
                _range = range.key;
                _dateError = null;
              }),
            ),
        ]),
        if (_range == 'custom') ...<Widget>[
          const SizedBox(height: OmniSpacing.sm),
          _dateButton(start: true),
          const SizedBox(height: OmniSpacing.xs),
          _dateButton(start: false),
          if (_dateError != null) ...<Widget>[
            const SizedBox(height: OmniSpacing.xs),
            Text(
              _dateError!,
              key: const ValueKey<String>('notes-filter-date-error'),
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ],
    );
  }

  /// 自定义起止日使用现有应用内日历，保留真实未完成状态。
  Widget _dateButton({required bool start}) {
    // 对应端点的当前日期。
    final DateTime? value = start ? _customStart : _customEnd;
    // 日期缺省只定位今天，不自动填入未选择的端点。
    final DateTime today = DateUtils.dateOnly(DateTime.now());
    // 当前端点在按钮中提供完整的日期含义。
    final String name = start ? '开始日期' : '结束日期';
    return OmniDatePickerButton(
      key: ValueKey<String>('notes-filter-date-${start ? 'start' : 'end'}'),
      value: value,
      initialDate: value ?? today,
      firstDate: DateTime(1900),
      lastDate: DateTime(9999, 12, 31),
      label: value == null
          ? name
          : '$name · ${MaterialLocalizations.of(context).formatCompactDate(value)}',
      icon: null,
      style: _choiceStyle(selected: value != null).copyWith(
        foregroundColor: WidgetStatePropertyAll(
          value == null
              ? OmniColors.of(context).muted
              : OmniColors.of(context).brand,
        ),
      ),
      onChanged: (DateTime date) => setState(() {
        if (start) {
          _customStart = DateUtils.dateOnly(date);
        } else {
          _customEnd = DateUtils.dateOnly(date);
        }
        _dateError = null;
      }),
    );
  }

  /// 标签仅在输入查询后展示匹配建议，选中项保留在输入框内。
  Widget _tagOptions() {
    // 空白查询不枚举任何标签。
    final String query = _tagSearch.text.trim().toLowerCase();
    // 已选标签已有独立移除入口，不重复列入搜索建议。
    final List<TaxonomyEntry> visibleTags = query.isEmpty
        ? const []
        : widget.tags
              .where(
                (tag) =>
                    !_tagIds.contains(tag.id) &&
                    tag.name.toLowerCase().contains(query),
              )
              .toList();
    // 标签关系保留与调用方一致的身份。
    const Map<String, String> modes = {
      'include': '包含',
      'exclude': '不包含',
      'none': '无标签',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _choices([
          // 标签关系互斥，切换时保留未提交的已选标签。
          for (final MapEntry<String, String> mode in modes.entries)
            _choice(
              id: 'tag-mode-${mode.key}',
              label: mode.value,
              selected: _tagMode == mode.key,
              onPressed: () => setState(() {
                _tagMode = mode.key;
                _tagSearchHovered = false;
              }),
            ),
        ]),
        if (_tagMode != 'none') ...[
          const SizedBox(height: OmniSpacing.xs),
          _tagSearchBox(),
          if (query.isNotEmpty) ...[
            const SizedBox(height: OmniSpacing.xs),
            if (visibleTags.isEmpty)
              Text(
                '没有匹配的标签',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: OmniColors.of(context).muted),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 180),
                child: SingleChildScrollView(
                  primary: false,
                  child: Wrap(
                    key: const ValueKey('notes-filter-tag-results'),
                    spacing: OmniSpacing.xs,
                    runSpacing: OmniSpacing.xs,
                    children: [
                      // 搜索结果使用截图中的灰底井号小按钮。
                      for (final TaxonomyEntry tag in visibleTags)
                        _choice(
                          id: 'tag-${tag.id}',
                          label: '#${tag.name}',
                          selected: false,
                          onPressed: () {
                            setState(() {
                              _tagIds.add(tag.id);
                              _tagSearch.clear();
                            });
                            _tagSearchFocus.requestFocus();
                          },
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ],
    );
  }

  /// 灰底搜索输入与已选小标签共用一行，选择后可继续添加。
  Widget _tagSearchBox() {
    // 搜索区域与主题的中性表面保持一致。
    final OmniColors colors = OmniColors.of(context);
    // 只显示真实存在且经搜索选中的标签。
    final List<TaxonomyEntry> selectedTags = widget.tags
        .where((tag) => _tagIds.contains(tag.id))
        .toList();
    return Focus(
      canRequestFocus: false,
      onFocusChange: (_) {
        if (mounted) setState(() {});
      },
      child: MouseRegion(
        onEnter: (_) => setState(() => _tagSearchHovered = true),
        onExit: (_) => setState(() => _tagSearchHovered = false),
        child: AnimatedContainer(
          key: const ValueKey('notes-filter-tag-search-surface'),
          duration: OmniMotion.duration(context, OmniMotion.fast),
          constraints: const BoxConstraints(minHeight: OmniSize.controlLarge),
          padding: const EdgeInsets.symmetric(
            horizontal: OmniSpacing.xs,
            vertical: OmniSpacing.xxs,
          ),
          decoration: BoxDecoration(
            color: Color.alphaBlend(
              colors.ink.withValues(alpha: 0.055),
              colors.paper,
            ),
            borderRadius: BorderRadius.circular(OmniRadius.control),
            border: Border.all(
              color: _tagSearchHovered || _tagSearchFocus.hasFocus
                  ? colors.line
                  : colors.line.withValues(alpha: 0),
            ),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) => Row(
              children: [
                if (selectedTags.isNotEmpty) ...[
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: constraints.maxWidth * 0.65,
                    ),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 已选标签始终能独立移除，无须重新输入相同查询。
                          for (final TaxonomyEntry tag in selectedTags)
                            Padding(
                              padding: const EdgeInsets.only(
                                right: OmniSpacing.xxs,
                              ),
                              child: OmniTextButton(
                                key: ValueKey(
                                  'notes-filter-selected-tag-${tag.id}',
                                ),
                                style: _choiceStyle(selected: true).copyWith(
                                  minimumSize: const WidgetStatePropertyAll(
                                    Size(0, 24),
                                  ),
                                  padding: const WidgetStatePropertyAll(
                                    EdgeInsets.symmetric(
                                      horizontal: OmniSpacing.xxs,
                                    ),
                                  ),
                                  textStyle: WidgetStatePropertyAll(
                                    Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(fontSize: 11),
                                  ),
                                ),
                                onPressed: () {
                                  _toggle(_tagIds, tag.id);
                                  _tagSearchFocus.requestFocus();
                                },
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text('#${tag.name}'),
                                    const SizedBox(width: OmniSpacing.xxs),
                                    const Icon(Icons.close, size: 12),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: OmniSpacing.xxs),
                ],
                Expanded(
                  child: OmniTextField(
                    key: const ValueKey('notes-filter-tag-search'),
                    controller: _tagSearch,
                    focusNode: _tagSearchFocus,
                    style: Theme.of(context).textTheme.bodySmall,
                    decoration: InputDecoration(
                      hintText: selectedTags.isEmpty ? '输入标签名搜索' : '继续添加标签',
                      filled: false,
                      isDense: true,
                      isCollapsed: true,
                      contentPadding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 已支持的数据类型使用多选条件，不展示尚无数据字段的来源选项。
  Widget _contentOptions() => _choices(<Widget>[
    _choice(
      id: 'content-image',
      label: '图片',
      selected: _contents.contains('image'),
      onPressed: () => _toggle(_contents, 'image'),
    ),
    _choice(
      id: 'content-link',
      label: '链接',
      selected: _contents.contains('link'),
      onPressed: () => _toggle(_contents, 'link'),
    ),
    _choice(
      id: 'content-audio',
      label: '语音',
      selected: _contents.contains('audio'),
      onPressed: () => _toggle(_contents, 'audio'),
    ),
  ]);

  /// 整张菜单由统一路由滚动，窄窗口和大字号均保留底部操作。
  @override
  Widget build(BuildContext context) => Column(
    key: const ValueKey<String>('notes-search-filter-panel'),
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      _section(
        id: 'time',
        title: '时间范围',
        expanded: true,
        active: _range != 'all',
        child: _timeOptions(),
      ),
      _section(
        id: 'tags',
        title: '标签',
        expanded: _tagsExpanded,
        active: _tagMode == 'none' || _tagIds.isNotEmpty,
        onPressed: () => setState(() => _tagsExpanded = !_tagsExpanded),
        child: _tagOptions(),
      ),
      _section(
        id: 'content',
        title: '包含内容',
        expanded: _contentExpanded,
        active: _contents.isNotEmpty,
        onPressed: () => setState(() => _contentExpanded = !_contentExpanded),
        child: _contentOptions(),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(
          OmniSpacing.xs,
          OmniSpacing.sm,
          OmniSpacing.xs,
          OmniSpacing.xs,
        ),
        child: Wrap(
          alignment: WrapAlignment.start,
          spacing: OmniSpacing.xs,
          runSpacing: OmniSpacing.xs,
          children: <Widget>[
            OmniFilledButton(
              key: const ValueKey<String>('notes-filter-apply'),
              onPressed: _apply,
              style: FilledButton.styleFrom(
                minimumSize: const Size(68, OmniSize.control),
                padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.md),
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
                textStyle: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(fontSize: 13, fontWeight: FontWeight.w400),
              ),
              child: const Text('搜索'),
            ),
            OmniTextButton(
              key: const ValueKey<String>('notes-filter-reset'),
              onPressed: _reset,
              style:
                  TextButton.styleFrom(
                    foregroundColor: OmniColors.of(context).muted,
                    minimumSize: const Size(0, OmniSize.control),
                    textStyle: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(fontSize: 13, fontWeight: FontWeight.w400),
                    padding: const EdgeInsets.symmetric(
                      horizontal: OmniSpacing.sm,
                    ),
                  ).copyWith(
                    backgroundColor: const WidgetStatePropertyAll(
                      Colors.transparent,
                    ),
                    overlayColor: const WidgetStatePropertyAll(
                      Colors.transparent,
                    ),
                    foregroundColor: WidgetStateProperty.resolveWith(
                      (states) =>
                          states.contains(WidgetState.hovered) ||
                              states.contains(WidgetState.focused)
                          ? OmniColors.of(context).ink
                          : OmniColors.of(context).muted,
                    ),
                  ),
              child: const Text('重置'),
            ),
          ],
        ),
      ),
    ],
  );
}
