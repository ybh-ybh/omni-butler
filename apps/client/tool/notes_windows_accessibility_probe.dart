// ignore_for_file: implementation_imports, invalid_use_of_internal_member
import 'dart:async';
import 'dart:io';
import 'dart:ffi' as ffi;

import 'package:flutter/src/widgets/_window_win32.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/semantics.dart';
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
void editProbeHistoryNote() {
  // 当前生产面板提供的唯一编辑动作。
  VoidCallback? activate;
  // 仅在指定历史卡片内部寻找双击入口。
  void visit(Element element, {bool insideCard = false}) {
    // 卡片根现在保持为稳定KeyedSubtree，交互由内部OmniPanel承担。
    final bool inCard =
        insideCard ||
        element.widget.key == const ValueKey('note-card-probe-note');
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

/// 仅使用进程内存中的数据复现Windows语义重挂。
Future<void> main(List<String> arguments) async {
  if (!Platform.isWindows) {
    throw UnsupportedError('此探针仅用于Windows原生无障碍桥验证');
  }
  // 明确选择锚点对照或生产笔记场景。
  final bool anchorsOnly = arguments.contains('--anchors-only');
  // 统计专项只循环新浮层，默认完整场景也包含本轮新增交互。
  final bool statisticsOnly = arguments.contains('--statistics-only');
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
    const NoteDraft(
      id: 'probe-note',
      body: '测试标题\n第一行正文\n第二行正文\n第三行正文\n第四行正文\n第五行正文',
      dayKey: '2026-10-14',
      baseRevision: '',
    ),
  );
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
    size: const Size(1280, 720),
    title: 'Notes accessibility isolated probe',
  );
  runWidget(
    RegularWindow(
      controller: window,
      child: UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.build(brightness: Brightness.light),
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
    for (int round = 0; round < 20; round++) {
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
    exit(resultCode);
  }
}
