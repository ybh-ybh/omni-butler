// ignore_for_file: implementation_imports, invalid_use_of_internal_member
import 'dart:async';
import 'dart:io';
import 'dart:ffi' as ffi;
import 'dart:ui' as ui;

import 'package:flutter/src/widgets/_window_win32.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/src/foundation/_features.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/notes/audio/note_recorder_service.dart';
import 'package:omni_butler/features/notes/data/note_providers.dart';
import 'package:omni_butler/features/notes/data/note_repository.dart';
import 'package:omni_butler/features/notes/presentation/notes_page.dart';
import 'package:omni_butler/features/notes/presentation/note_rich_editor.dart';
import 'package:omni_butler/features/notes/data/note_editor_controller.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';
import 'package:omni_butler/shared/ui/omni_note_composer_button.dart';
import 'package:omni_butler/shared/ui/omni_note_audio_controls.dart';
import 'package:omni_butler/shared/ui/omni_windows_semantics_boundary.dart';
import 'package:omni_butler/shared/ui/omni_taxonomy_chip.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 空设备广播避免探针启动麦克风或读取用户原件。
class ProbeRecorder implements NoteRecorderService {
  /// 探针始终无设备占用。
  @override
  NoteRecordingState get state => const NoteRecordingState();

  /// 不分配原生状态订阅。
  @override
  Stream<NoteRecordingState> get states => const Stream.empty();

  /// 不产生任何录音原件。
  @override
  Stream<NoteRecordingResult> get completed => const Stream.empty();

  /// 不会请求切入真实录音会话。
  @override
  Stream<String> get returnRequests => const Stream.empty();

  /// 禁止读取用户恢复目录。
  @override
  Future<List<NoteRecordingResult>> recoverPending() async => [];

  /// 测试无原件，取消仍由真实内存仓储处理。
  @override
  Future<void> discardPendingForDraft(
    String draftId, {
    Set<String> protectedPaths = const {},
  }) async {}

  /// 内存测试身份没有历史永久删除标记。
  @override
  Future<bool> isPermanentlyDiscarded(String noteId) async => false;

  /// 非预期设备操作必须显式失败。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 查找探针树中的生产操作。
Widget? findProbeWidget(Key key) {
  // 当前匹配控件。
  Widget? found;
  // 遍历当前探针自己的元素树。
  void visit(Element element) {
    if (element.widget.key == key) found = element.widget;
    element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return found;
}

/// 在稳定卡片语义边界内找到实际面板双击入口，不依赖外层手势类型。
void editProbeHistoryNote([String id = 'probe-note']) {
  // 当前生产面板提供的唯一编辑动作。
  VoidCallback? activate;
  // 仅在指定历史卡片内部寻找双击入口。
  void visit(Element element, {bool insideCard = false}) {
    // 卡片根现在保持为稳定KeyedSubtree，交互由内部OmniPanel承担。
    final bool inCard =
        insideCard || element.widget.key == ValueKey('note-card-$id');
    // 当前元素可能是负责双击的面板。
    final Widget widget = element.widget;
    if (inCard && widget is OmniPanel && widget.onDoubleTap != null) {
      activate = widget.onDoubleTap;
      return;
    }
    element.visitChildren((Element child) => visit(child, insideCard: inCard));
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  if (activate == null) throw StateError('探针未找到历史笔记的生产双击入口');
  activate!();
}

/// 在输入聚焦时展示真实Tooltip窗口，并改变标签关联。
void activateProbeInput() {
  // 遍历当前探针自己的元素树。
  void visit(Element element) {
    // 当前叶节点的公开控件配置。
    final Widget widget = element.widget;
    if (widget is NoteRichEditor) widget.focusNode.requestFocus();
    if (widget is TextField && widget.decoration?.hintText == '现在的想法是...') {
      widget.focusNode?.requestFocus();
    }
    if (widget is Tooltip &&
        widget.message == '选择标签' &&
        element is StatefulElement) {
      (element.state as TooltipState).ensureTooltipVisible();
    }
    element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
}

/// 单独重现上游相邻Tooltip锚点在索引列表中合并的原生错误。
class ProbeTooltipAnchors extends StatelessWidget {
  /// 未隔离模式只用于比较上游故障，不用于生产。
  const ProbeTooltipAnchors({super.key, required this.guarded});

  /// 是否应用项目Windows语义隔离。
  final bool guarded;

  /// 两个提示锚点位于同一列表项，正是上游的合并触发结构。
  @override
  Widget build(BuildContext context) => Scaffold(
    body: ListView(
      children: [
        Row(
          children: [
            for (final String name in ['A', 'B']) _anchor(name),
          ],
        ),
      ],
    ),
  );

  /// 固定尺寸只属于隔离探针，不改变生产控件。
  Widget _anchor(String name) {
    // 保留真实Tooltip的浮层挂接路径。
    final Widget tooltip = Tooltip(
      message: '原生锚点$name',
      child: SizedBox(
        width: 140,
        height: 100,
        child: Center(child: Text(name)),
      ),
    );
    return guarded ? OmniWindowsSemanticsBoundary(child: tooltip) : tooltip;
  }
}

/// 真实显示某个Tooltip，不用静态树代替浮层更新。
void activateProbeTooltip(String message) {
  // 遍历当前探针自己的元素树。
  void visit(Element element) {
    if (element.widget is Tooltip &&
        (element.widget as Tooltip).message == message &&
        element is StatefulElement) {
      (element.state as TooltipState).ensureTooltipVisible();
    }
    element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
}

/// 真实时钟驱动原生语义与动画帧。
Future<void> pauseProbe([int milliseconds = 280]) =>
    Future.delayed(Duration(milliseconds: milliseconds));

/// 以真实鼠标双击覆盖不同音频／标签组合的卡片替换与视口裁剪。
Future<void> runHistoryProbeRound(int round, int viewId) async {
  // 四组数据轮换，确保纯文字和带音频的差异可从原生日志对照。
  final String id = 'probe-history-${round % 4}';
  // 正式卡片在原生产滚动视图中定位，不能直接调用编辑回调替代双击。
  final Element card = statisticsProbeElement(ValueKey('note-card-$id'));
  await Scrollable.ensureVisible(card, alignment: 0.1);
  await pauseProbe(120);
  // 时间行远离右侧菜单和音频内嵌按钮。
  final RenderBox box = card.findRenderObject()! as RenderBox;
  // 统一按原布局坐标向当前窗口发送鼠标事件。
  final Offset point = box.localToGlobal(const Offset(80, 22));
  // 每轮两个点击使用不同指针，鼠标设备保持一致。
  for (int click = 0; click < 2; click++) {
    GestureBinding.instance.handlePointerEvent(
      PointerDownEvent(
        viewId: viewId,
        device: 71,
        pointer: round * 2 + click + 1,
        kind: ui.PointerDeviceKind.mouse,
        buttons: kPrimaryMouseButton,
        position: point,
      ),
    );
    await pauseProbe(25);
    GestureBinding.instance.handlePointerEvent(
      PointerUpEvent(
        viewId: viewId,
        device: 71,
        pointer: round * 2 + click + 1,
        kind: ui.PointerDeviceKind.mouse,
        position: point,
      ),
    );
    await pauseProbe(65);
  }
  await pauseProbe(360);
  if (findProbeWidget(const ValueKey('note-edit-cancel')) == null) {
    throw StateError('双击没有打开历史笔记$id');
  }
  activateProbeInput();
  await pauseProbe(80);
  (findProbeWidget(
    const ValueKey('note-composer-tag'),
  ) as OmniNoteComposerButton).onPressed!();
  await pauseProbe(100);
  Tooltip.dismissAllToolTips();
  (findProbeWidget(
    const ValueKey('note-edit-cancel'),
  ) as OmniNoteAudioLink).onPressed!();
  await pauseProbe(360);
  stdout.writeln('PROBE_HISTORY:$round:$id');
}

/// 从探针自身元素树获取稳定业务锚点，不访问用户窗口。
Element statisticsProbeElement(Key key) {
  // 本次查找的确切元素。
  Element? found;
  // 只遍历当前进程挂载的生产页面。
  void visit(Element element) {
    if (element.widget.key == key) found = element;
    element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  if (found == null) throw StateError('统计探针未找到$key');
  return found!;
}

/// 激活锚点内已有的生产手势，不添加探针专用业务路径。
void activateStatisticsProbe(Key key) {
  // 目标锚点以内的首个有效点击动作。
  VoidCallback? action;
  // 统一控件内部仍保留原有唯一InkWell识别器。
  void visit(Element element) {
    if (action != null) return;
    // 当前控件可能直接暴露点击回调。
    final Widget widget = element.widget;
    if (widget is InkWell && widget.onTap != null) action = widget.onTap;
    if (widget is OmniIconButton) action = widget.onPressed;
    element.visitChildren(visit);
  }

  visit(statisticsProbeElement(key));
  if (action == null) throw StateError('统计探针锚点没有点击动作$key');
  action!();
}

/// 原生AX启用时反复覆盖提示、年份菜单、两种图表和选日返回。
Future<void> runStatisticsProbeRound(int round) async {
  activateStatisticsProbe(const ValueKey('notes-statistic-note-count'));
  await pauseProbe();
  // 年份和日期使用探针自己的固定正式数据。
  final Element menu = statisticsProbeElement(
    const ValueKey('notes-statistics-year-menu'),
  );
  // 月历日期锚点外的提示会创建独立浮层。
  void showTooltip(Element element) {
    if (element.widget case Tooltip(message: final String message)
        when message.contains('笔记·') && element is StatefulElement) {
      (element.state as TooltipState).ensureTooltipVisible();
    }
    element.visitChildren(showTooltip);
  }

  statisticsProbeElement(const ValueKey('notes-statistics-dialog'))
      .visitChildren(showTooltip);
  await pauseProbe(90);
  Tooltip.dismissAllToolTips();
  activateStatisticsProbe(const ValueKey('notes-statistics-year-menu'));
  await pauseProbe(180);
  Navigator.of(menu).pop(2026);
  await pauseProbe(180);
  activateStatisticsProbe(const ValueKey('notes-statistics-year-view'));
  await pauseProbe();
  activateStatisticsProbe(const ValueKey('notes-statistics-month-view'));
  await pauseProbe();
  if (round.isEven) {
    activateStatisticsProbe(const ValueKey('notes-statistics-day-2026-10-14'));
  } else {
    activateStatisticsProbe(const ValueKey('notes-statistics-close'));
  }
  await pauseProbe();
}

/// 使用引擎键盘入口走真实焦点树，不能只修改HardwareKeyboard按键集合。
void sendEditorProbeKey(
  LogicalKeyboardKey logical,
  PhysicalKeyboardKey physical,
  ui.KeyEventType type,
) {
  WidgetsBinding.instance.platformDispatcher.onKeyData?.call(
    ui.KeyData(
      timeStamp: Duration.zero,
      type: type,
      physical: physical.usbHidUsage,
      logical: logical.keyId,
      character: null,
      synthesized: true,
    ),
  );
}

/// 标签专项的鼠标点击使用独立指针身份，避免与历史双击探针互相污染。
int _tagProbePointer = 9000;

/// 取得可见生产控件中心，所有点击与悬停都经过真实命中测试。
Offset tagProbePoint(Key key) {
  // 当前挂载控件的实际布局盒。
  final RenderBox box =
      statisticsProbeElement(key).findRenderObject()! as RenderBox;
  return box.localToGlobal(box.size.center(Offset.zero));
}

/// 原生窗口内发送鼠标移动，保留父菜单到子菜单的真实跨面板路径。
Future<void> hoverTagProbe(Offset point, int viewId) async {
  GestureBinding.instance.handlePointerEvent(
    PointerHoverEvent(
      viewId: viewId,
      device: 73,
      kind: ui.PointerDeviceKind.mouse,
      position: point,
    ),
  );
  await pauseProbe(180);
}

/// 点击生产菜单或确认按钮，不直接调用其业务回调。
Future<void> clickTagProbe(Offset point, int viewId) async {
  await hoverTagProbe(point, viewId);
  // 当前点击的稳定指针标识。
  final int pointer = _tagProbePointer++;
  GestureBinding.instance.handlePointerEvent(
    PointerDownEvent(
      viewId: viewId,
      device: 73,
      pointer: pointer,
      kind: ui.PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
      position: point,
    ),
  );
  await pauseProbe(25);
  GestureBinding.instance.handlePointerEvent(
    PointerUpEvent(
      viewId: viewId,
      device: 73,
      pointer: pointer,
      kind: ui.PointerDeviceKind.mouse,
      position: point,
    ),
  );
  await pauseProbe(260);
}

/// 窄窗使用生产抽屉，探针只打开自己窗口内的侧栏。
Future<void> openTagProbeDrawer() async {
  // 当前页面可用的生产抽屉状态。
  ScaffoldState? drawer;
  // 只寻找带有抽屉的脚手架，忽略正文内部的其他面板。
  void visit(Element element) {
    if (element.widget case Scaffold(drawer: final Widget? widget)
        when widget != null && element is StatefulElement) {
      drawer = element.state as ScaffoldState;
    }
    element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  if (drawer != null && !drawer!.isDrawerOpen) {
    drawer!.openDrawer();
    await pauseProbe(320);
  }
}

/// 确认对话框内通过按钮文字定位取消操作，避免引入探针专用业务接口。
Offset tagProbeCancelPoint() {
  // 当前确认框中唯一的取消文字元素。
  Element? cancel;
  // 页面未处于笔记编辑态，只有确认对话框包含此操作。
  void visit(Element element) {
    if (element.widget case Text(data: '取消')) cancel = element;
    element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  if (cancel == null) throw StateError('标签删除未展示可取消的确认框');
  // 文字中心同样位于生产按钮的命中范围内。
  final RenderBox box = cancel!.findRenderObject()! as RenderBox;
  return box.localToGlobal(box.size.center(Offset.zero));
}

/// 每个键位完整按下并释放，走平台入口与生产菜单的焦点快捷键。
Future<void> pressTagProbeKey(
  LogicalKeyboardKey logical,
  PhysicalKeyboardKey physical,
) async {
  sendEditorProbeKey(logical, physical, ui.KeyEventType.down);
  sendEditorProbeKey(logical, physical, ui.KeyEventType.up);
  await pauseProbe(180);
}

/// 二十轮覆盖置顶双分区、真实跨面板鼠标移动、取消确认和键盘两级退出。
Future<void> runTagsProbeRound(
  AppDatabase database,
  int round,
  int viewId,
) async {
  await openTagProbeDrawer();
  // 每轮先交替从全部标签与置顶标签入口切换状态。
  final String initialRowId = round.isEven
      ? 'probe-tag-0'
      : 'pinned-probe-tag-0';
  await hoverTagProbe(
    tagProbePoint(ValueKey('notes-tag-$initialRowId')),
    viewId,
  );
  await clickTagProbe(
    tagProbePoint(ValueKey('notes-tag-menu-$initialRowId')),
    viewId,
  );
  await clickTagProbe(
    tagProbePoint(ValueKey('notes-tag-pin-menu-$initialRowId')),
    viewId,
  );
  // 不依赖文案推测结果，直接核对探针自己的真实数据库。
  final TaxonomyEntry tag = await (database.select(
    database.taxonomyEntries,
  )..where((table) => table.id.equals('probe-tag-0'))).getSingle();
  if (tag.isPinned != round.isEven) throw StateError('标签置顶切换未持久化');
  // 置顶完成后使用另一分区入口，确保两份同身份行的交互互不串联。
  final String rowId = round.isEven ? 'pinned-probe-tag-0' : 'probe-tag-0';
  await hoverTagProbe(tagProbePoint(ValueKey('notes-tag-$rowId')), viewId);
  await clickTagProbe(tagProbePoint(ValueKey('notes-tag-menu-$rowId')), viewId);
  // 真正悬停删除父行展开二级面板。
  final Offset parentPoint = tagProbePoint(
    ValueKey('notes-tag-delete-menu-$rowId'),
  );
  await hoverTagProbe(parentPoint, viewId);
  // 两种删除交替出现确认，全部取消以保留下一轮的稳定数据。
  final Key childKey = ValueKey(
    round.isEven ? 'notes-tag-delete-only' : 'notes-tag-delete-notes',
  );
  // 经过两个面板边缘间隙再进入目标子行，覆盖子菜单错误收起的窗口。
  final Offset childPoint = tagProbePoint(childKey);
  await hoverTagProbe(
    Offset((parentPoint.dx + childPoint.dx) / 2, parentPoint.dy),
    viewId,
  );
  await hoverTagProbe(childPoint, viewId);
  if (findProbeWidget(childKey) == null) throw StateError('鼠标跨面板时子菜单意外关闭');
  await clickTagProbe(childPoint, viewId);
  await clickTagProbe(tagProbeCancelPoint(), viewId);
  // 确认取消后标签与两篇正式笔记都应继续可用。
  final List<NoteEntryRecord> notes = await (database.select(
    database.noteEntries,
  )..where((table) => table.id.isIn(['probe-note', 'probe-tags-multi']))).get();
  if (notes.length != 2 || notes.any((note) => note.deletedAt != null)) {
    throw StateError('取消标签删除意外改变正式笔记');
  }
  await hoverTagProbe(tagProbePoint(ValueKey('notes-tag-$rowId')), viewId);
  await clickTagProbe(tagProbePoint(ValueKey('notes-tag-menu-$rowId')), viewId);
  // 根菜单首项为置顶，跳过编辑名称与分隔线后到达删除父项。
  await pressTagProbeKey(
    LogicalKeyboardKey.arrowDown,
    PhysicalKeyboardKey.arrowDown,
  );
  await pressTagProbeKey(
    LogicalKeyboardKey.arrowDown,
    PhysicalKeyboardKey.arrowDown,
  );
  await pressTagProbeKey(
    LogicalKeyboardKey.arrowRight,
    PhysicalKeyboardKey.arrowRight,
  );
  if (findProbeWidget(const ValueKey('notes-tag-delete-only')) == null) {
    throw StateError('方向键未展开标签二级菜单');
  }
  await pressTagProbeKey(
    LogicalKeyboardKey.arrowDown,
    PhysicalKeyboardKey.arrowDown,
  );
  await pressTagProbeKey(
    LogicalKeyboardKey.arrowLeft,
    PhysicalKeyboardKey.arrowLeft,
  );
  await pressTagProbeKey(
    LogicalKeyboardKey.arrowRight,
    PhysicalKeyboardKey.arrowRight,
  );
  await pressTagProbeKey(LogicalKeyboardKey.escape, PhysicalKeyboardKey.escape);
  if (findProbeWidget(const ValueKey('notes-tag-delete-only')) != null ||
      findProbeWidget(ValueKey('notes-tag-delete-menu-$rowId')) == null) {
    throw StateError('第一次Escape未仅关闭二级菜单');
  }
  await pressTagProbeKey(LogicalKeyboardKey.escape, PhysicalKeyboardKey.escape);
  if (findProbeWidget(ValueKey('notes-tag-delete-menu-$rowId')) != null) {
    throw StateError('第二次Escape未关闭标签主菜单');
  }
  stdout.writeln('PROBE_TAGS:$round');
}

/// 原生窗口内重复格式、选区、菜单和列表，保持辅助功能桥真实启用。
Future<void> runEditorProbeRound(NoteEditorController editor, int round) async {
  editor.edit(body: '中文选区格式与高亮\n第一项\n第二项');
  await pauseProbe(100);
  // 本轮真实生产编辑器与可见选区。
  final NoteRichEditor field =
      findProbeWidget(const ValueKey('note-rich-editor'))! as NoteRichEditor;
  field.focusNode.requestFocus();
  field.controller.selection = const TextSelection(
    baseOffset: 0,
    extentOffset: 2,
  );
  await pauseProbe(60);
  sendEditorProbeKey(
    LogicalKeyboardKey.controlLeft,
    PhysicalKeyboardKey.controlLeft,
    ui.KeyEventType.down,
  );
  sendEditorProbeKey(
    LogicalKeyboardKey.keyB,
    PhysicalKeyboardKey.keyB,
    ui.KeyEventType.down,
  );
  sendEditorProbeKey(
    LogicalKeyboardKey.keyB,
    PhysicalKeyboardKey.keyB,
    ui.KeyEventType.up,
  );
  sendEditorProbeKey(
    LogicalKeyboardKey.controlLeft,
    PhysicalKeyboardKey.controlLeft,
    ui.KeyEventType.up,
  );
  await pauseProbe(80);
  if (!editor.draft.body.startsWith('**中文**')) {
    throw StateError('原生Ctrl+B未格式化选区');
  }
  field.controller.selection = const TextSelection(
    baseOffset: 2,
    extentOffset: 4,
  );
  sendEditorProbeKey(
    LogicalKeyboardKey.controlLeft,
    PhysicalKeyboardKey.controlLeft,
    ui.KeyEventType.down,
  );
  sendEditorProbeKey(
    LogicalKeyboardKey.keyU,
    PhysicalKeyboardKey.keyU,
    ui.KeyEventType.down,
  );
  sendEditorProbeKey(
    LogicalKeyboardKey.keyU,
    PhysicalKeyboardKey.keyU,
    ui.KeyEventType.up,
  );
  sendEditorProbeKey(
    LogicalKeyboardKey.controlLeft,
    PhysicalKeyboardKey.controlLeft,
    ui.KeyEventType.up,
  );
  await pauseProbe(80);
  if (!editor.draft.body.contains('<u>选区</u>')) {
    throw StateError('原生Ctrl+U未格式化选区');
  }
  // 菜单通过真实生产按钮打开，选择高亮后返回正文。
  OmniNoteComposerButton? formatButton;
  void findFormat(Element element) {
    if (element.widget case final OmniNoteComposerButton button
        when button.tooltip == '文本格式') {
      formatButton = button;
    }
    element.visitChildren(findFormat);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(findFormat);
  field.controller.selection = const TextSelection(
    baseOffset: 4,
    extentOffset: 6,
  );
  formatButton!.onPressed!();
  await pauseProbe(180);
  (findProbeWidget(
    const ValueKey('note-format-highlight'),
  ) as OmniNoteComposerButton).onPressed!();
  await pauseProbe(180);
  if (!editor.draft.body.contains('==格式==') || !field.focusNode.hasFocus) {
    throw StateError('原生格式弹层丢失选区或焦点');
  }
  field.controller.selection = TextSelection(
    baseOffset: 10,
    extentOffset: field.controller.plainText.length,
  );
  (findProbeWidget(
    const ValueKey('note-composer-ordered-list'),
  ) as OmniNoteComposerButton).onPressed!();
  await pauseProbe(80);
  (findProbeWidget(
    const ValueKey('note-composer-bullet-list'),
  ) as OmniNoteComposerButton).onPressed!();
  await pauseProbe(80);
  stdout.writeln('PROBE_EDITOR:$round:${editor.draft.body.contains('- 第一项')}');
}

/// 仅使用进程内存中的数据复现Windows语义重挂。
Future<void> main(List<String> arguments) async {
  if (!Platform.isWindows) {
    throw UnsupportedError('此探针仅用于Windows原生无障碍桥验证');
  }
  // 明确选择锚点对照或生产笔记场景。
  final bool anchorsOnly = arguments.contains('--anchors-only');
  // 统计专项只循环新浮层，默认完整场景也包含本轮新增交互。
  final bool statisticsOnly = arguments.contains('--statistics-only');
  // 编辑专项只操作隔离的生产正文，避免旧统计流程稀释验收证据。
  final bool editorOnly = arguments.contains('--editor-only');
  // 历史专项使用四种附件／标签组合和真正的鼠标双击。
  final bool historyOnly = arguments.contains('--history-only');
  // 标签专项仅循环新双层菜单，避免其他浮层稀释原生无障碍证据。
  final bool tagsOnly = arguments.contains('--tags-only');
  // 历史回归可切换深色窄窗，增加音频位于视口裁剪边缘的覆盖。
  final bool dark = arguments.contains('--dark');
  // 窄窗启用抽屉布局，保持默认探针窗口尺寸不变。
  final bool narrow = arguments.contains('--narrow');
  // 实际框架异常必须计入进程退出状态。
  int frameworkErrors = 0;
  FlutterError.onError = (details) {
    frameworkErrors++;
    stderr.writeln('PROBE_FRAMEWORK_ERROR:$details');
  };
  final bool unguarded = arguments.contains('--unguarded');
  isWindowingEnabled = true;
  WidgetsFlutterBinding.ensureInitialized();
  // 原生回归也必须隔离偏好，显式使用测试后端避免接触用户设置。
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues({});
  // 私有偏好替身及内存数据库。
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  final DateTime now = DateTime.now();
  for (int index = 0; index < 4; index++) {
    await database
        .into(database.taxonomyEntries)
        .insert(
          TaxonomyEntriesCompanion.insert(
            id: 'probe-tag-$index',
            module: 'notes',
            kind: 'tag',
            name: '探针标签$index',
            colorValue: 0xff6280ff,
            createdAt: now,
            updatedAt: now,
          ),
        );
  }
  await NoteRepository(database).save(
    NoteDraft(
      id: 'probe-note',
      body: '测试标题\n第一行正文\n第二行正文\n第三行正文\n第四行正文\n第五行正文',
      dayKey: '2026-10-14',
      baseRevision: '',
      tags: tagsOnly ? {'probe-tag-0'} : {},
    ),
  );
  if (tagsOnly) {
    await NoteRepository(database).save(
      const NoteDraft(
        id: 'probe-tags-multi',
        body: '标签专项多标签正式笔记',
        dayKey: '2026-10-14',
        baseRevision: '',
        tags: {'probe-tag-0', 'probe-tag-1'},
      ),
    );
  }
  // 多篇长文跨越视口，覆盖节点被裁剪后再进入树的场景。
  for (int index = 0; index < 12; index++) {
    await NoteRepository(database).save(
      NoteDraft(
        id: 'probe-long-$index',
        body: '长文$index\n${List.filled(20, '正文行，验证滚动与弹出动画').join('\n')}',
        dayKey: '2026-10-13',
        baseRevision: '',
      ),
    );
  }
  if (historyOnly) {
    // 只在隔离内存库中构造纯文字、标签、音频和两者都有的对照。
    for (int index = 0; index < 4; index++) {
      await NoteRepository(database).save(
        NoteDraft(
          id: 'probe-history-$index',
          body: '对照笔记$index\n第一行正文\n第二行正文\n第三行正文',
          dayKey: '2026-10-15',
          baseRevision: '',
          tags: index.isOdd ? {'probe-tag-0', 'probe-tag-1'} : {},
        ),
      );
      if (index < 2) continue;
      // 多个进度条覆盖同时移除、重新创建与动画边缘裁剪。
      for (int audio = 0; audio < 2; audio++) {
        await database
            .into(database.noteAudioSegments)
            .insert(
              NoteAudioSegmentsCompanion.insert(
                id: 'probe-history-audio-$index-$audio',
                noteId: 'probe-history-$index',
                sortOrder: audio,
                durationMs: 12000,
                mime: 'audio/wav',
                sha256: '0' * 64,
                byteSize: 64,
                createdAt: now,
                updatedAt: now,
              ),
            );
      }
    }
  }
  // 编辑和页面沿用生产逻辑。
  final ProviderContainer container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      appDatabaseProvider.overrideWithValue(database),
      noteRecorderProvider.overrideWithValue(ProbeRecorder()),
    ],
  );
  await container.read(noteEditorProvider).openComposer();
  // 单窗口开启真实原生辅助功能桥。
  final RegularWindowController window = RegularWindowController(
    size: narrow ? const Size(780, 900) : const Size(1280, 720),
    title: 'Notes accessibility isolated probe',
  );
  runWidget(
    RegularWindow(
      controller: window,
      child: UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.build(
            brightness: dark ? Brightness.dark : Brightness.light,
          ),
          home: anchorsOnly
              ? ProbeTooltipAnchors(guarded: !unguarded)
              : const NotesPage(),
        ),
      ),
    ),
  );
  await pauseProbe(1200);
  // WM_GETOBJECT真正启用Windows辅助功能桥，单独ensureSemantics只启用Dart树。
  final ffi.DynamicLibrary user32 = ffi.DynamicLibrary.open('user32.dll');
  // 此窗口的MSAA查询入口，不依赖系统读屏器开关。
  final send = user32
      .lookupFunction<
        ffi.IntPtr Function(
          ffi.Pointer<ffi.Void>,
          ffi.Uint32,
          ffi.UintPtr,
          ffi.IntPtr,
        ),
        int Function(ffi.Pointer<ffi.Void>, int, int, int)
      >('SendMessageW');
  // 同一探针窗口内的原生孩子枚举。
  final getWindow = user32
      .lookupFunction<
        ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, ffi.Uint32),
        ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, int)
      >('GetWindow');
  // 使用已创建窗口的确切句柄，不操作前台用户窗口。
  final ffi.Pointer<ffi.Void> hwnd = (window as WindowControllerWin32)
      .windowHandle
      .cast();
  // 为宿主及所属视图打开原生辅助功能。
  void activate(ffi.Pointer<ffi.Void> handle) {
    send(handle, 0x003D, 0, -4);
    for (
      ffi.Pointer<ffi.Void> child = getWindow(handle, 5);
      child.address != 0;
      child = getWindow(child, 2)
    ) {
      activate(child);
    }
  }

  activate(hwnd);
  await pauseProbe(500);
  stdout.writeln(
    'PROBE_NATIVE_AX_ACTIVE:${SemanticsBinding.instance.semanticsEnabled}',
  );
  // 回归失败必须返回非零状态，不能只凭窗口退出认定通过。
  int resultCode = 0;
  try {
    if (tagsOnly) {
      GestureBinding.instance.handlePointerEvent(
        PointerAddedEvent(
          viewId: window.rootView.viewId,
          device: 73,
          kind: ui.PointerDeviceKind.mouse,
          position: const Offset(1, 1),
        ),
      );
    }
    for (int round = 0; round < 20; round++) {
      if (tagsOnly) {
        await runTagsProbeRound(database, round, window.rootView.viewId);
        continue;
      }
      if (historyOnly) {
        await runHistoryProbeRound(round, window.rootView.viewId);
        continue;
      }
      if (editorOnly) {
        await runEditorProbeRound(container.read(noteEditorProvider), round);
        continue;
      }
      if (anchorsOnly) {
        stdout.writeln('PROBE_ANCHORS:$round:guarded=${!unguarded}');
        activateProbeTooltip('原生锚点A');
        await pauseProbe(90);
        activateProbeTooltip('原生锚点B');
        await pauseProbe(90);
        Tooltip.dismissAllToolTips();
        await pauseProbe(120);
        continue;
      }
      stdout.writeln('PROBE_ROUND:$round');
      await runStatisticsProbeRound(round);
      if (statisticsOnly) continue;
      activateProbeInput();
      await pauseProbe(60);
      // 模拟真实侧栏悬停，引入菜单、计数与提示浮层。
      (findProbeWidget(
        const ValueKey('notes-tags-section'),
      ) as MouseRegion).onEnter!(const PointerEnterEvent());
      (findProbeWidget(
        const ValueKey('notes-tag-probe-tag-0'),
      ) as MouseRegion).onEnter!(const PointerEnterEvent());
      await pauseProbe(60);
      for (int step = 0; step < 2; step++) {
        (findProbeWidget(
          const ValueKey('note-composer-tag'),
        ) as OmniNoteComposerButton).onPressed!();
        await pauseProbe(60);
        if (step == 0) {
          // 选中与中途取消触发同一行移位，检查原生语义节点保持连接。
          (findProbeWidget(
            const ValueKey('note-available-tag-probe-tag-2'),
          ) as OmniTaxonomyChip).onSelected!(true);
          await pauseProbe(70);
          (findProbeWidget(
            const ValueKey('note-selected-tag-probe-tag-2'),
          ) as OmniTaxonomyChip).onSelected!(false);
          await pauseProbe(70);
        }
        (findProbeWidget(
          const ValueKey('note-body-toggle-probe-note'),
        ) as OmniNoteAudioLink).onPressed!();
        await pauseProbe();
      }
      // 双击原地编辑和取消同样属于用户的展开／收缩操作。
      editProbeHistoryNote();
      await pauseProbe();
      activateProbeInput();
      await pauseProbe(60);
      (findProbeWidget(
        const ValueKey('note-composer-tag'),
      ) as OmniNoteComposerButton).onPressed!();
      await pauseProbe(60);
      (findProbeWidget(
        const ValueKey('note-edit-cancel'),
      ) as OmniNoteAudioLink).onPressed!();
      await pauseProbe();
      // 侧栏折叠、选中与视口裁剪一并覆盖。
      final header =
          findProbeWidget(const ValueKey('notes-tags-toggle')) as InkWell;
      header.onTap!();
      await pauseProbe(60);
      final SingleChildScrollView scroll = findProbeWidget(
        const ValueKey('notes-main-scroll'),
      ) as SingleChildScrollView;
      scroll.controller!.jumpTo(round.isEven ? 190 : 0);
      await pauseProbe(120);
      Tooltip.dismissAllToolTips();
      await pauseProbe(60);
    }
    stdout.writeln('PROBE_COMPLETE');
  } catch (error, stack) {
    resultCode = 1;
    stderr.writeln('PROBE_FAILURE:$error\n$stack');
  } finally {
    window.destroy();
    container.dispose();
    await database.close();
    exit(frameworkErrors == 0 ? resultCode : 1);
  }
}
