// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/src/foundation/_features.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/src/widgets/_window_win32.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 本探针只写截图和轨迹，不初始化应用数据库、偏好、设备或网络服务。
const String _output = String.fromEnvironment(
  'OMNI_INTERACTION_PROBE_OUTPUT',
  defaultValue: 'build/windows-interaction-probe',
);

/// 禁用自动轨迹时保留独立窗口供人工观察。
const bool _autorun = bool.fromEnvironment(
  'OMNI_INTERACTION_PROBE_AUTORUN',
  defaultValue: true,
);

/// 自动轨迹结束后为录制保留的窗口时间。
const int _holdMilliseconds = int.fromEnvironment(
  'OMNI_INTERACTION_PROBE_HOLD_MS',
  defaultValue: 10000,
);

/// 明暗主题由编译参数指定，避免写入用户偏好。
const bool _dark = bool.fromEnvironment('OMNI_INTERACTION_PROBE_DARK');

/// 直接记录本窗口实际渲染帧，避免系统锁屏或其他窗口遮挡屏幕录制。
const bool _recordFrames = bool.fromEnvironment(
  'OMNI_INTERACTION_PROBE_RECORD',
  defaultValue: true,
);

/// 包含 Navigator 和操作菜单覆盖层的截图边界。
final GlobalKey _captureKey = GlobalKey(
  debugLabel: 'interaction-probe-capture',
);

/// 只读取探针自己的内存计数来核验输入轨迹。
final GlobalKey<_InteractionProbePageState> _pageKey =
    GlobalKey<_InteractionProbePageState>();

/// 保存框架异步错误，不能将窗口正常关闭误当成验证通过。
final List<String> _errors = <String>[];

/// 创建单独的原生 Flutter 窗口与生产组件演示。
Future<void> main() async {
  if (!Platform.isWindows) throw UnsupportedError('交互探针仅支持 Windows');
  isWindowingEnabled = true;
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (FlutterErrorDetails details) {
    _errors.add(details.exceptionAsString());
    FlutterError.presentError(details);
  };
  ui.PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    _errors.add('$error');
    stderr.writeln('PROBE_ASYNC_ERROR:$error\n$stack');
    return true;
  };
  // 本次探针拥有的唯一原生窗口。
  final RegularWindowController window = RegularWindowController(
    size: const Size(1080, 800),
    title: 'Omni Butler — Windows interaction isolated probe',
  );
  runWidget(
    RegularWindow(
      controller: window,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(
          brightness: _dark ? Brightness.dark : Brightness.light,
        ).copyWith(platform: TargetPlatform.windows),
        builder: (BuildContext context, Widget? child) =>
            RepaintBoundary(key: _captureKey, child: child!),
        home: _InteractionProbePage(key: _pageKey),
      ),
    ),
  );
  window.activate();
  stdout.writeln(
    'PROBE_WINDOW_HANDLE:${(window as WindowControllerWin32).windowHandle.address}',
  );
  await Future<void>.delayed(const Duration(milliseconds: 1200));
  _enableNativeAccessibility(window);
  stdout.writeln('PROBE_READY:output=${Directory(_output).absolute.path}');
  if (!_autorun) return;
  // 输入驱动只向此窗口自己的 Flutter View 发送事件。
  final _ProbeDriver driver = _ProbeDriver(window.rootView.viewId);
  // 只捕获此探针自己的图层，保留真实帧时间。
  final _ProbeFrameRecorder? recorder = _recordFrames
      ? _ProbeFrameRecorder()
      : null;
  await recorder?.start();
  // 任何断言或异步框架错误都使进程以失败状态退出。
  int exitCode = 0;
  try {
    await driver.run();
    if (_errors.isNotEmpty) throw StateError(_errors.join('\n'));
    stdout.writeln(
      'PROBE_COMPLETE:${jsonEncode(_pageKey.currentState!.snapshot)}',
    );
  } catch (error, stack) {
    exitCode = 1;
    _errors.add('$error');
    stderr.writeln('PROBE_FAILURE:$error\n$stack');
  } finally {
    await recorder?.stop();
    await driver.writeResults(exitCode == 0);
    await Future<void>.delayed(Duration(milliseconds: _holdMilliseconds));
    if (_errors.isNotEmpty) exitCode = 1;
    await driver.writeResults(exitCode == 0);
    window.destroy();
    exit(exitCode);
  }
}

/// 从真实原生运行时图层连续取帧，不使用测试 Binding 或重建动画。
class _ProbeFrameRecorder {
  /// 本次录制的单调时钟。
  final Stopwatch _clock = Stopwatch();

  /// 已写入的实际渲染时间与帧文件。
  final List<(int, String)> _frames = <(int, String)>[];

  /// 固定采样节拍，编码忙时跳过而不堆积待处理帧。
  Timer? _timer;

  /// 正在执行的唯一帧编码与落盘。
  Future<void>? _pending;

  /// 预先创建隔离目录后开始约三十帧每秒的采样。
  Future<void> start() async {
    await Directory('$_output/frames').create(recursive: true);
    _clock.start();
    _timer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (_pending != null) return;
      _pending = _captureFrame().whenComplete(() => _pending = null);
    });
  }

  /// 获取当前已经提交的图层，异步 PNG 编码不阻塞业务动作。
  Future<void> _captureFrame() async {
    try {
      WidgetsBinding.instance.scheduleFrame();
      await WidgetsBinding.instance.endOfFrame;
      // 当前完整 Navigator 图层的真实渲染边界。
      final RenderRepaintBoundary boundary =
          _captureKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      // 截帧时刻用于精确重放，不假设所有采样间隔一致。
      final int timestamp = _clock.elapsedMicroseconds;
      // 本帧图像来自生产组件的原生图层。
      final ui.Image frame = await boundary.toImage(pixelRatio: 1);
      try {
        // 帧序号固定补齐，目录只属于此探针。
        final String path =
            '$_output/frames/${_frames.length.toString().padLeft(6, '0')}.png';
        // 真实 PNG 数据，仅写入任务构建目录。
        final ByteData? bytes = await frame.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (bytes == null) throw StateError('录制帧编码失败');
        await File(path).writeAsBytes(bytes.buffer.asUint8List());
        _frames.add((
          timestamp,
          File(path).absolute.path.replaceAll('\\', '/'),
        ));
      } finally {
        frame.dispose();
      }
    } catch (error, stack) {
      _errors.add('录制帧失败：$error');
      stderr.writeln('PROBE_FRAME_ERROR:$error\n$stack');
    }
  }

  /// 保留最后的恢复画面，并按实际帧间隔生成 FFmpeg concat 清单。
  Future<void> stop() async {
    await Future<void>.delayed(const Duration(milliseconds: 350));
    _timer?.cancel();
    await _pending;
    _clock.stop();
    if (_frames.isEmpty) {
      _errors.add('没有录制到探针渲染帧');
      return;
    }
    // 每段 duration 使用相邻真实截帧时间差。
    final StringBuffer manifest = StringBuffer('ffconcat version 1.0\n');
    // 每个实际帧只写一次，不用截图补造中间状态。
    for (int index = 0; index < _frames.length; index += 1) {
      // 当前已经落盘的帧及时间。
      final (int timestamp, String path) = _frames[index];
      // 最后一帧补足一个采样间隔，其余保留真实间隔。
      final double seconds = index + 1 < _frames.length
          ? (_frames[index + 1].$1 - timestamp) / 1000000
          : 0.033;
      manifest.writeln("file '$path'");
      manifest.writeln('duration ${seconds.toStringAsFixed(6)}');
    }
    manifest.writeln("file '${_frames.last.$2}'");
    await File('$_output/frames.ffconcat').writeAsString(manifest.toString());
    stdout.writeln('PROBE_RECORDED_FRAMES:${_frames.length}');
  }
}

/// 仅启用当前探针宿主及子视图的真实 Windows 无障碍桥。
void _enableNativeAccessibility(RegularWindowController window) {
  // 本进程只调用 Windows 消息和子窗口枚举，不定位其他应用。
  final ffi.DynamicLibrary user32 = ffi.DynamicLibrary.open('user32.dll');
  // WM_GETOBJECT 查询会启用原生 MSAA 桥。
  final int Function(ffi.Pointer<ffi.Void>, int, int, int) sendMessage = user32
      .lookupFunction<
        ffi.IntPtr Function(
          ffi.Pointer<ffi.Void>,
          ffi.Uint32,
          ffi.UintPtr,
          ffi.IntPtr,
        ),
        int Function(ffi.Pointer<ffi.Void>, int, int, int)
      >('SendMessageW');
  // 按当前宿主关系枚举本窗口的孩子。
  final ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, int) getWindow =
      user32.lookupFunction<
        ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, ffi.Uint32),
        ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, int)
      >('GetWindow');
  // 递归只经过此探针窗口已有的所属子窗口。
  void activate(ffi.Pointer<ffi.Void> handle) {
    sendMessage(handle, 0x003D, 0, -4);
    for (
      ffi.Pointer<ffi.Void> child = getWindow(handle, 5);
      child.address != 0;
      child = getWindow(child, 2)
    ) {
      activate(child);
    }
  }

  activate((window as WindowControllerWin32).windowHandle.cast());
  stdout.writeln(
    'PROBE_NATIVE_AX_ACTIVE:${SemanticsBinding.instance.semanticsEnabled}',
  );
}

/// 生产控件只更改此页面的内存状态。
class _InteractionProbePage extends StatefulWidget {
  /// 创建可供轨迹读取计数的隔离页面。
  const _InteractionProbePage({super.key});

  /// 保存当前演示状态。
  @override
  State<_InteractionProbePage> createState() => _InteractionProbePageState();
}

/// 不连接仓储，所有计数与选择均随进程结束丢弃。
class _InteractionProbePageState extends State<_InteractionProbePage> {
  /// 普通按钮执行次数。
  int _buttonCount = 0;

  /// 导航行执行次数。
  int _navigationCount = 0;

  /// 行内按钮执行次数。
  int _inlineCount = 0;

  /// 笔记式卡片双击次数。
  int _doubleCount = 0;

  /// 已提交的菜单动作。
  final List<String> _menuActions = <String>[];

  /// 复选框内存状态。
  bool _checked = false;

  /// 开关内存状态。
  bool _switched = false;

  /// 气泡内存状态。
  bool _chip = false;

  /// 单选组内存状态。
  String _radio = 'a';

  /// 只读结果提供给自动轨迹，不直接驱动业务回调。
  Map<String, Object?> get snapshot => <String, Object?>{
    'button': _buttonCount,
    'navigation': _navigationCount,
    'inline': _inlineCount,
    'doubleTap': _doubleCount,
    'checked': _checked,
    'switched': _switched,
    'chip': _chip,
    'radio': _radio,
    'menuActions': List<String>.of(_menuActions),
  };

  /// 两种菜单入口共享同一组真实操作条目。
  List<PopupMenuEntry<String>> _items(BuildContext context) =>
      <PopupMenuEntry<String>>[
        OmniPopupMenuItem<String>(
          key: const ValueKey<String>('probe-menu-edit'),
          value: 'edit',
          label: '编辑内容',
          icon: Icons.edit_outlined,
        ),
        OmniPopupMenuItem<String>(
          key: const ValueKey<String>('probe-menu-delete'),
          value: 'delete',
          label: '移入回收站',
          icon: Icons.delete_outline,
          danger: true,
        ),
        OmniPopupMenuItem<String>(
          key: const ValueKey<String>('probe-menu-disabled'),
          value: 'disabled',
          label: '暂不可用',
          icon: Icons.block,
          enabled: false,
        ),
        const OmniPopupMenuItem<String>.custom(
          key: ValueKey<String>('probe-menu-custom'),
          value: 'custom',
          height: 64,
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('切换管理分区'),
              Text('保留多行说明与选中内容', style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
      ];

  /// 菜单只更新内存结果，不进行真实删除或导航。
  void _select(String action) => setState(() => _menuActions.add(action));

  /// 用生产入口在当前窗口的右键坐标展开上下文菜单。
  Future<void> _contextMenu(TapUpDetails details) async {
    // 当前窗口菜单覆盖层。
    final RenderBox overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    // 将指针转换到覆盖层坐标。
    final Offset point = overlay.globalToLocal(details.globalPosition);
    // 只接受本次菜单返回的显式操作。
    final String? action = await showOmniMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        point & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: _items(context),
    );
    if (mounted && action != null) _select(action);
  }

  /// 展示全部代表性生产控件，尺寸只属于独立演示窗口。
  @override
  Widget build(BuildContext context) {
    // 沿用应用的中文字体、表面与语义配色。
    final OmniColors colors = OmniColors.of(context);
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Windows 交互验收',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      const Text('独立内存演示 · 统一菜单与内容按压 · 不连接个人数据'),
                    ],
                  ),
                ),
                OmniPopupMenuButton<String>(
                  key: const ValueKey<String>('probe-menu'),
                  tooltip: '展示操作菜单',
                  itemBuilder: _items,
                  onSelected: _select,
                ),
              ],
            ),
            const SizedBox(height: 28),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                OmniButton(
                  key: const ValueKey<String>('probe-button'),
                  label: '主要操作',
                  icon: Icons.add_rounded,
                  onPressed: () => setState(() => _buttonCount += 1),
                ),
                OmniButton(
                  label: '次要操作',
                  variant: OmniButtonVariant.secondary,
                  onPressed: () {},
                ),
                const OmniButton(label: '禁用操作', onPressed: null),
                Text(
                  '已执行 $_buttonCount 次',
                  style: TextStyle(color: colors.muted),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: OmniPanel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '导航与行内操作',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        OmniListTile(
                          key: const ValueKey<String>('probe-navigation'),
                          leading: const Icon(Icons.today_outlined),
                          title: const Text(
                            '今日待办',
                            key: ValueKey<String>('probe-navigation-label'),
                          ),
                          subtitle: Text(
                            '导航 $_navigationCount 次 · 行内操作 $_inlineCount 次',
                          ),
                          onTap: () => setState(() => _navigationCount += 1),
                          trailing: OmniIconButton(
                            key: const ValueKey<String>('probe-inline'),
                            tooltip: '行内添加',
                            icon: const Icon(Icons.add_rounded),
                            onPressed: () => setState(() => _inlineCount += 1),
                          ),
                        ),
                        const OmniListTile(
                          leading: Icon(Icons.inventory_2_outlined),
                          title: Text('物品管理'),
                          enabled: false,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: OmniPanel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '选择控件',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 12,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: <Widget>[
                            OmniCheckbox(
                              key: const ValueKey<String>('probe-checkbox'),
                              value: _checked,
                              semanticLabel: '完成事项',
                              onChanged: (bool? value) =>
                                  setState(() => _checked = value ?? false),
                            ),
                            const Text('完成'),
                            OmniSwitch(
                              key: const ValueKey<String>('probe-switch'),
                              value: _switched,
                              onChanged: (bool value) =>
                                  setState(() => _switched = value),
                            ),
                            OmniChoiceChip(
                              key: const ValueKey<String>('probe-chip'),
                              label: const Text('工作'),
                              selected: _chip,
                              onSelected: (bool value) =>
                                  setState(() => _chip = value),
                            ),
                          ],
                        ),
                        RadioGroup<String>(
                          groupValue: _radio,
                          onChanged: (String? value) =>
                              setState(() => _radio = value ?? 'a'),
                          child: const Column(
                            children: <Widget>[
                              OmniRadioListTile<String>(
                                value: 'a',
                                title: Text('按创建时间'),
                              ),
                              OmniRadioListTile<String>(
                                key: ValueKey<String>('probe-radio-b'),
                                value: 'b',
                                title: Text('按更新时间'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Semantics(
              container: true,
              explicitChildNodes: true,
              child: OmniPanel(
                key: const ValueKey<String>('probe-note'),
                onDoubleTap: () => setState(() => _doubleCount += 1),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '双击进入编辑的笔记卡片',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    const Text('单击只有内容按压反馈；双击沿用原有手势并只执行一次。'),
                    const SizedBox(height: 8),
                    Text(
                      '已双击 $_doubleCount 次',
                      style: TextStyle(color: colors.muted),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Material(
              color: colors.paperSubtle,
              borderRadius: BorderRadius.circular(12),
              child: OmniPressSurface(
                key: const ValueKey<String>('probe-context'),
                onSecondaryTapUp: _contextMenu,
                borderRadius: BorderRadius.circular(12),
                child: OmniInkWell(
                  onTap: () {},
                  borderRadius: BorderRadius.circular(12),
                  child: const Padding(
                    padding: EdgeInsets.all(18),
                    child: Text('在此处右键，展示同一套上下文菜单'),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              '菜单结果：${_menuActions.isEmpty ? '尚未选择' : _menuActions.join(' → ')}',
              style: TextStyle(color: colors.muted),
            ),
          ],
        ),
      ),
    );
  }
}

/// 使用正常运行时 Binding，经真实命中测试执行鼠标与键盘轨迹。
class _ProbeDriver {
  /// 本次独立原生窗口的 Flutter View。
  final int viewId;

  /// 轨迹采用真实单调时钟。
  final Stopwatch _clock = Stopwatch()..start();

  /// 已发出的输入与截图记录。
  final List<Map<String, Object?>> _trace = <Map<String, Object?>>[];

  /// 同一设备中的连续指针身份。
  int _pointer = 1;

  /// 专属合成鼠标设备，避免与真实鼠标混淆。
  static const int _device = 7301;

  /// 创建只作用于指定窗口的轨迹驱动。
  _ProbeDriver(this.viewId);

  /// 从当前探针元素树按稳定键找控件，不调用业务回调。
  Element? _findElement(String key) {
    // 找到的目标元素。
    Element? found;
    // 只遍历此探针进程的 Flutter 树。
    void visit(Element element) {
      if (element.widget.key == ValueKey<String>(key)) found = element;
      element.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement!.visitChildren(visit);
    return found;
  }

  /// 输入目标必须已经挂载，缺失时让本次验收明确失败。
  Element _element(String key) {
    // 当前仍然显示的目标元素。
    final Element? found = _findElement(key);
    if (found == null) throw StateError('未找到轨迹目标：$key');
    return found;
  }

  /// 从真实元素树判断菜单路由是否仍然显示。
  bool get _menuVisible => _findElement('omni-windows-menu-surface') != null;

  /// 记录焦点实际停靠位置，区别输入未分发和控件焦点错误。
  Map<String, Object?> _focusSnapshot() {
    // Flutter 当前唯一主焦点。
    final FocusNode? focus = FocusManager.instance.primaryFocus;
    // 焦点元素所属的生产控件稳定键。
    final List<String> keys = <String>[];
    focus?.context?.visitAncestorElements((Element ancestor) {
      if (ancestor.widget.key != null) keys.add('${ancestor.widget.key}');
      return keys.length < 8;
    });
    return <String, Object?>{
      'menuVisible': _menuVisible,
      'focus': focus?.debugLabel ?? focus?.runtimeType.toString(),
      'focusWidget': focus?.context?.widget.runtimeType.toString(),
      'focusAncestors': keys,
      'pressedKeys': HardwareKeyboard.instance.logicalKeysPressed
          .map((LogicalKeyboardKey key) => key.keyLabel)
          .toList(),
    };
  }

  /// 读取真实布局中心作为输入坐标。
  Offset _center(String key) {
    // 当前目标所属的渲染区域。
    final RenderBox box = _element(key).findRenderObject()! as RenderBox;
    return box.localToGlobal(box.size.center(Offset.zero));
  }

  /// 写出可复查的时间与动作记录。
  void _record(
    String action, [
    Map<String, Object?> details = const <String, Object?>{},
  ]) {
    // 本次步骤的完整轨迹。
    final Map<String, Object?> event = <String, Object?>{
      'milliseconds': _clock.elapsedMilliseconds,
      'action': action,
      ...details,
    };
    _trace.add(event);
    stdout.writeln('PROBE_TRACE:${jsonEncode(event)}');
  }

  /// 在自己的窗口中移动鼠标，触发生产 hover 与焦点行为。
  Future<void> hover(String key, {int settle = 130}) async {
    GestureBinding.instance.handlePointerEvent(
      PointerHoverEvent(
        device: _device,
        viewId: viewId,
        position: _center(key),
        timeStamp: _clock.elapsed,
        kind: ui.PointerDeviceKind.mouse,
      ),
    );
    _record('hover', <String, Object?>{'key': key});
    await Future<void>.delayed(Duration(milliseconds: settle));
  }

  /// 发送实际鼠标按下与抬起，可在按住期间捕获缩放。
  Future<void> tap(
    String key, {
    int buttons = kPrimaryButton,
    int hold = 25,
    int settle = 230,
    String? pressedFrame,
    bool cancel = false,
  }) async {
    // 本次完整手势固定使用同一个逻辑坐标。
    final Offset position = _center(key);
    // 本次手势固定使用同一个指针编号。
    final int pointer = _pointer++;
    GestureBinding.instance.handlePointerEvent(
      PointerDownEvent(
        device: _device,
        pointer: pointer,
        viewId: viewId,
        position: position,
        kind: ui.PointerDeviceKind.mouse,
        buttons: buttons,
        timeStamp: _clock.elapsed,
      ),
    );
    await Future<void>.delayed(Duration(milliseconds: hold));
    if (pressedFrame != null) await capture(pressedFrame);
    GestureBinding.instance.handlePointerEvent(
      cancel
          ? PointerCancelEvent(
              device: _device,
              pointer: pointer,
              viewId: viewId,
              position: position,
              kind: ui.PointerDeviceKind.mouse,
              timeStamp: _clock.elapsed,
            )
          : PointerUpEvent(
              device: _device,
              pointer: pointer,
              viewId: viewId,
              position: position,
              kind: ui.PointerDeviceKind.mouse,
              timeStamp: _clock.elapsed,
            ),
    );
    _record(
      cancel
          ? 'cancel'
          : buttons == kSecondaryButton
          ? 'right-click'
          : 'click',
      <String, Object?>{'key': key},
    );
    if (settle > 0) await Future<void>.delayed(Duration(milliseconds: settle));
  }

  /// 从引擎键盘入口送入按键，保留 HardwareKeyboard 与 KeyMessage 焦点分发。
  Future<void> key(
    PhysicalKeyboardKey physical,
    LogicalKeyboardKey logical,
  ) async {
    _record('keyboard-before', <String, Object?>{
      'key': logical.keyLabel,
      ..._focusSnapshot(),
    });
    // 当前 SDK 的 FocusManager 仍订阅 KeyMessage，不能只调用 HardwareKeyboard。
    // synthesized 让正常引擎绑定即时派发 KeyMessage，不等待原生 raw 配套消息。
    final ui.KeyDataCallback? dispatch =
        ui.PlatformDispatcher.instance.onKeyData;
    if (dispatch == null) throw StateError('引擎键盘绑定尚未初始化');
    dispatch(
      ui.KeyData(
        type: ui.KeyEventType.down,
        physical: physical.usbHidUsage,
        logical: logical.keyId,
        character: null,
        timeStamp: _clock.elapsed,
        synthesized: true,
      ),
    );
    dispatch(
      ui.KeyData(
        type: ui.KeyEventType.up,
        physical: physical.usbHidUsage,
        logical: logical.keyId,
        character: null,
        timeStamp: _clock.elapsed,
        synthesized: true,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 230));
    _record('keyboard-after', <String, Object?>{
      'key': logical.keyLabel,
      ..._focusSnapshot(),
    });
  }

  /// 捕获实际引擎图层，包括菜单覆盖层，不使用测试 Binding。
  Future<void> capture(String name) async {
    WidgetsBinding.instance.scheduleFrame();
    await WidgetsBinding.instance.endOfFrame;
    // 页面外层边界包含完整 Navigator 合成内容。
    final RenderRepaintBoundary boundary =
        _captureKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    // 当前窗口已经绘制出的实际像素。
    final ui.Image image = await boundary.toImage(pixelRatio: 1);
    try {
      // PNG 编码结果仅写入探针输出目录。
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw StateError('PNG 编码失败');
      await Directory(_output).create(recursive: true);
      await File('$_output/$name.png')
          .writeAsBytes(bytes.buffer.asUint8List(), flush: true);
      _record('capture', <String, Object?>{'file': '$name.png'});
    } finally {
      image.dispose();
    }
  }

  /// 用可读失败说明核验生产回调执行次数与语义。
  void _expect(bool condition, String message) {
    if (!condition) throw StateError(message);
    _record('assertion-passed', <String, Object?>{'check': message});
  }

  /// 连贯执行按压、嵌套点击、选择、双击、菜单与键盘验收。
  Future<void> run() async {
    GestureBinding.instance.handlePointerEvent(
      PointerAddedEvent(
        device: _device,
        viewId: viewId,
        position: const Offset(16, 16),
        kind: ui.PointerDeviceKind.mouse,
        timeStamp: _clock.elapsed,
      ),
    );
    await capture('00-initial');
    await tap(
      'probe-button',
      hold: 95,
      settle: 0,
      pressedFrame: '01-button-pressed',
    );
    await Future<void>.delayed(const Duration(milliseconds: 55));
    await capture('02-button-releasing');
    await Future<void>.delayed(const Duration(milliseconds: 230));
    await capture('03-button-restored');
    _expect(_pageKey.currentState!._buttonCount == 1, '按压动画没有重复执行按钮业务');
    await tap(
      'probe-button',
      hold: 140,
      cancel: true,
      pressedFrame: '03a-button-cancel-pressed',
    );
    _expect(_pageKey.currentState!._buttonCount == 1, '取消手势只恢复内容，不执行业务');
    await tap('probe-button', settle: 30);
    await tap('probe-button');
    _expect(_pageKey.currentState!._buttonCount == 3, '连续快速点击各执行一次并从当前尺寸接续');
    await capture('03b-button-rapid-restored');
    await tap('probe-navigation-label');
    await tap('probe-inline', hold: 95, pressedFrame: '04-inline-pressed');
    _expect(
      _pageKey.currentState!._navigationCount == 1 &&
          _pageKey.currentState!._inlineCount == 1,
      '行内操作没有重复触发父导航',
    );
    await tap('probe-checkbox');
    await tap('probe-switch');
    await tap('probe-chip');
    await tap('probe-radio-b');
    _expect(
      _pageKey.currentState!._checked &&
          _pageKey.currentState!._switched &&
          _pageKey.currentState!._chip &&
          _pageKey.currentState!._radio == 'b',
      '复选框、开关、气泡和单选组各自只提交一次',
    );
    await capture('05-controls-selected');
    await tap('probe-note', settle: 400);
    _expect(_pageKey.currentState!._doubleCount == 0, '笔记卡片单击不触发双击编辑');
    await tap('probe-note', settle: 80);
    await tap('probe-note', settle: 400);
    _expect(_pageKey.currentState!._doubleCount == 1, '笔记卡片双击只触发一次');
    await tap('probe-menu', settle: 0);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await capture('06-menu-entering');
    await Future<void>.delayed(const Duration(milliseconds: 170));
    await hover('probe-menu-edit');
    await capture('07-menu-normal-hover');
    await hover('probe-menu-delete');
    await capture('08-menu-danger-hover');
    _record('hover-stress-start');
    // 在上一次渐变尚未结束时反向，复现用户视频中的连续跨行悬停。
    for (int move = 0; move < 14; move += 1) {
      await hover(
        move.isEven ? 'probe-menu-edit' : 'probe-menu-delete',
        settle: move.isEven ? 45 : 110,
      );
    }
    _record('hover-stress-end');
    await tap(
      'probe-menu-edit',
      buttons: kSecondaryButton,
      hold: 220,
      pressedFrame: '08a-menu-right-pressed',
    );
    _expect(
      _menuVisible && _pageKey.currentState!._menuActions.isEmpty,
      '菜单项右键有按压反馈，但不执行左键选择或关闭菜单',
    );
    await tap('probe-menu-disabled');
    _expect(_pageKey.currentState!._menuActions.isEmpty, '禁用菜单项没有提交');
    await capture('09-menu-disabled');
    await key(PhysicalKeyboardKey.escape, LogicalKeyboardKey.escape);
    _expect(!_menuVisible, 'Escape 已通过实际焦点树关闭菜单');
    await capture('09a-menu-escaped');
    await key(PhysicalKeyboardKey.enter, LogicalKeyboardKey.enter);
    _expect(_menuVisible, '恢复到触发器的焦点可用 Enter 重新打开菜单');
    await capture('09b-menu-keyboard-opened');
    await key(PhysicalKeyboardKey.arrowDown, LogicalKeyboardKey.arrowDown);
    await key(PhysicalKeyboardKey.enter, LogicalKeyboardKey.enter);
    _expect(
      _pageKey.currentState!._menuActions.join(',') == 'delete',
      'Escape恢复触发器焦点且方向键选择危险操作',
    );
    await tap('probe-menu');
    await tap('probe-menu-custom');
    await tap(
      'probe-context',
      buttons: kSecondaryButton,
      hold: 220,
      pressedFrame: '10a-context-right-pressed',
    );
    await capture('10-context-menu');
    await tap('probe-menu-edit');
    _expect(
      _pageKey.currentState!._menuActions.join(',') == 'delete,custom,edit',
      '多行菜单与右键菜单保留原返回值',
    );
    await capture('11-complete');
    GestureBinding.instance.handlePointerEvent(
      PointerRemovedEvent(
        device: _device,
        viewId: viewId,
        kind: ui.PointerDeviceKind.mouse,
        timeStamp: _clock.elapsed,
      ),
    );
  }

  /// 在结束前保存所有步骤、当前状态与错误，便于失败时复核。
  Future<void> writeResults(bool passed) async {
    await Directory(_output).create(recursive: true);
    await File('$_output/results.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'passed': passed,
        'viewId': viewId,
        'nativeAccessibility': SemanticsBinding.instance.semanticsEnabled,
        'theme': _dark ? 'dark' : 'light',
        'state': _pageKey.currentState?.snapshot,
        'errors': List<String>.of(_errors),
        'trace': _trace,
      }),
      flush: true,
    );
  }
}
