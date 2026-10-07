import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/app/theme/windows_theme_transition.dart';

/// 纯红旧画面便于独立检查渐变混色，而不受 Material 色阶影响。
const Color _initialColor = Color.fromARGB(255, 255, 0, 0);

/// 纯蓝新画面与旧画面的通道彼此独立。
const Color _firstColor = Color.fromARGB(255, 0, 0, 255);

/// 用实际渲染像素和保留状态的编辑页验证窗口主题过渡。
void main() {
  testWidgets('半程右上已更新、左下仍旧色、中心保留柔和混色', (WidgetTester tester) async {
    // 测试场景保持同一个主题过渡组件和活页面。
    final GlobalKey<_SceneState> scene = await _pumpScene(tester);
    _expectSolid(await _capture(tester, scene), _initialColor);
    scene.currentState!.change(themeKey: 1, color: _firstColor);
    await tester.pump();
    await tester.pump();
    await tester.pump(
      Duration(microseconds: OmniMotion.themeChange.inMicroseconds ~/ 2),
    );
    // 在同一中间帧采样三个区域，验证方向和软边，而非只检查最终颜色。
    final _PixelFrame middle = await _capture(tester, scene);
    _expectColor(middle.at(middle.width - 20, 20), _firstColor);
    _expectColor(middle.at(20, middle.height - 20), _initialColor);
    // 中心应由红色旧画面和蓝色新画面共同构成。
    final Color center = middle.at(middle.width ~/ 2, middle.height ~/ 2);
    expect(_red(center), inInclusiveRange(32, 223));
    expect(_blue(center), inInclusiveRange(32, 223));
    expect(_green(center), lessThanOrEqualTo(3));
    await _finishTransition(tester);
    _expectSolid(await _capture(tester, scene), _firstColor);
    expect(tester.takeException(), isNull);
  });

  testWidgets('快速续接捕获当前复合画面，零时间重建不跳变且最终为最新主题', (WidgetTester tester) async {
    // 当前主题可在前一次过渡尚未完成时再次变化。
    final GlobalKey<_SceneState> scene = await _pumpScene(tester);
    scene.currentState!.change(themeKey: 1, color: _firstColor);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    // 保存用户切换前真实看到的复合像素。
    final _PixelFrame before = await _capture(tester, scene);
    scene.currentState!.change(themeKey: 2, color: Colors.green);
    await tester.pump();
    // 不推进动画时间，新一轮首帧必须与先前画面连续。
    final _PixelFrame after = await _capture(tester, scene);
    expect(_maximumChannelDifference(before, after), lessThanOrEqualTo(3));
    await _finishTransition(tester);
    _expectSolid(await _capture(tester, scene), Colors.green);
    expect(tester.takeException(), isNull);
  });

  testWidgets('首次挂载和相同主题标识的普通重建直接显示当前页面', (WidgetTester tester) async {
    // 初次挂载没有旧画面，普通业务变更也不应被截图冻结。
    final GlobalKey<_SceneState> scene = await _pumpScene(tester);
    _expectSolid(await _capture(tester, scene), _initialColor);
    scene.currentState!.change(color: _firstColor);
    await tester.pump();
    _expectSolid(await _capture(tester, scene), _firstColor);
    expect(scene.currentState!.initializations, 1);
  });

  testWidgets('减少动画立即切换，过渡中启用也立即移除旧画面', (WidgetTester tester) async {
    // 系统减少动画既需要覆盖启动时，也需要覆盖运行中的偏好变化。
    final GlobalKey<_SceneState> scene = await _pumpScene(tester);
    scene.currentState!.change(
      themeKey: 1,
      color: _firstColor,
      reduceAnimations: true,
    );
    await tester.pump();
    _expectSolid(await _capture(tester, scene), _firstColor);
    scene.currentState!.change(reduceAnimations: false);
    await tester.pump();
    scene.currentState!.change(themeKey: 2, color: Colors.green);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    scene.currentState!.change(reduceAnimations: true);
    await tester.pump();
    _expectSolid(await _capture(tester, scene), Colors.green);
    await _finishTransition(tester);
    _expectSolid(await _capture(tester, scene), Colors.green);
  });

  // 尺寸与像素比例都可能在窗口移动、缩放和最大化期间变化。
  for (final bool changesPixelRatio in <bool>[false, true]) {
    testWidgets('${changesPixelRatio ? 'DPR' : '窗口尺寸'}变化清除过渡旧图', (
      WidgetTester tester,
    ) async {
      // 保持正在执行的主题动画，再改变窗口度量。
      final GlobalKey<_SceneState> scene = await _pumpScene(tester);
      scene.currentState!.change(themeKey: 1, color: _firstColor);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      scene.currentState!.change(
        size: changesPixelRatio ? null : const Size(360, 220),
        pixelRatio: changesPixelRatio ? 2 : null,
      );
      await tester.pump();
      _expectSolid(await _capture(tester, scene), _firstColor);
      await _finishTransition(tester);
      _expectSolid(await _capture(tester, scene), _firstColor);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('唯一活页面保留输入和焦点，动画覆盖层不阻断交互', (WidgetTester tester) async {
    // 真实输入控件与按钮位于持续存活的子页面中。
    final GlobalKey<_SceneState> scene = await _pumpScene(
      tester,
      interactive: true,
    );
    await tester.enterText(find.byType(TextField), '切换前草稿');
    await tester.pump();
    // 保存原输入焦点和文本控制器，后续必须仍为同一状态对象。
    final _LivePageState page = scene.currentState!.page.currentState!;
    expect(page.focus.hasFocus, isTrue);
    scene.currentState!.change(themeKey: 1, color: _firstColor);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(scene.currentState!.initializations, 1);
    expect(scene.currentState!.page.currentState, same(page));
    expect(page.controller.text, '切换前草稿');
    expect(page.focus.hasFocus, isTrue);
    await tester.enterText(find.byType(TextField), '动画中继续编辑');
    await tester.tap(find.byKey(const ValueKey<String>('live-action')));
    await tester.pump();
    expect(page.controller.text, '动画中继续编辑');
    expect(page.clicks, 1);
    await _finishTransition(tester);
    expect(scene.currentState!.initializations, 1);
    expect(scene.currentState!.page.currentState, same(page));
    expect(page.controller.text, '动画中继续编辑');
    expect(tester.takeException(), isNull);
  });

  testWidgets('超过四次未完成快切立即落到最新主题，旧回调不能重新覆盖', (WidgetTester tester) async {
    // 连续切换用于验证截图引用链有界，而不是无限堆积旧 GPU 画面。
    final GlobalKey<_SceneState> scene = await _pumpScene(tester);
    // 五次变化之间都没有留出动画完成时间。
    const List<Color> colors = <Color>[
      _firstColor,
      Colors.green,
      Colors.purple,
      Colors.orange,
      Colors.cyan,
    ];
    // 每次只推进一帧，保持前一轮旧图仍然存在。
    for (int index = 0; index < colors.length; index += 1) {
      scene.currentState!.change(themeKey: index + 1, color: colors[index]);
      await tester.pump();
      if (index < colors.length - 1) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }
    _expectSolid(await _capture(tester, scene), colors.last);
    await _finishTransition(tester);
    _expectSolid(await _capture(tester, scene), colors.last);
    expect(scene.currentState!.initializations, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('第五次快切清帧后，下次主题变化恢复完整方向过渡', (WidgetTester tester) async {
    // 先触发截图链上限，确保降级不会永久停用后续动画。
    final GlobalKey<_SceneState> scene = await _pumpScene(tester);
    // 最后一轮落回纯红，便于辨认重新开始的红蓝过渡。
    const List<Color> colors = <Color>[
      _firstColor,
      Colors.green,
      Colors.purple,
      Colors.orange,
      _initialColor,
    ];
    // 每一轮都在旧动画未完成时发起。
    for (int index = 0; index < colors.length; index += 1) {
      scene.currentState!.change(themeKey: index + 1, color: colors[index]);
      await tester.pump();
      if (index < colors.length - 1) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }
    await tester.pump();
    _expectSolid(await _capture(tester, scene), _initialColor);
    scene.currentState!.change(themeKey: 6, color: _firstColor);
    await tester.pump();
    _expectSolid(await _capture(tester, scene), _initialColor);
    await tester.pump();
    await tester.pump(
      Duration(microseconds: OmniMotion.themeChange.inMicroseconds ~/ 2),
    );
    // 恢复后的中途画面仍应从右上向左下揭示新主题。
    final _PixelFrame middle = await _capture(tester, scene);
    _expectColor(middle.at(middle.width - 20, 20), _firstColor);
    _expectColor(middle.at(20, middle.height - 20), _initialColor);
    await _finishTransition(tester);
    _expectSolid(await _capture(tester, scene), _firstColor);
    expect(scene.currentState!.initializations, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('动画中卸载后释放截图和 ticker，延迟帧不再访问旧资源', (WidgetTester tester) async {
    // 在仍持有旧画面并运行 ticker 时直接销毁整棵窗口组件。
    final GlobalKey<_SceneState> scene = await _pumpScene(tester);
    scene.currentState!.change(themeKey: 1, color: _firstColor);
    await tester.pump();
    await tester.pump();
    await tester.pump(
      Duration(microseconds: OmniMotion.themeChange.inMicroseconds ~/ 2),
    );
    // 先确认当前确实处于过渡中，避免测试在无动画状态下空过。
    final _PixelFrame middle = await _capture(tester, scene);
    _expectColor(middle.at(middle.width - 20, 20), _firstColor);
    _expectColor(middle.at(20, middle.height - 20), _initialColor);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(OmniMotion.themeChange + const Duration(seconds: 1));
    await tester.pump();
    expect(find.byType(WindowsThemeTransition), findsNothing);
    expect(scene.currentState, isNull);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });
}

/// 创建拥有可控主题和媒体度量的实际页面。
Future<GlobalKey<_SceneState>> _pumpScene(
  WidgetTester tester, {
  bool interactive = false,
}) async {
  // 直接操作场景状态，保持所有测试使用同一个组件身份。
  final GlobalKey<_SceneState> scene = GlobalKey<_SceneState>();
  await tester.pumpWidget(
    MaterialApp(
      home: _Scene(key: scene, interactive: interactive),
    ),
  );
  await tester.pump();
  return scene;
}

/// 推进超过主题过渡时长，并执行清理旧图的帧末回调。
Future<void> _finishTransition(WidgetTester tester) async {
  await tester.pump(OmniMotion.themeChange + const Duration(milliseconds: 40));
  await tester.pump();
}

/// 从真实外层画面读取 RGBA 像素，不依赖 golden 文件。
Future<_PixelFrame> _capture(
  WidgetTester tester,
  GlobalKey<_SceneState> scene,
) async {
  // 该边界位于过渡组件外侧，捕获新活页面与旧遮罩的实际合成结果。
  final RenderRepaintBoundary boundary =
      scene.currentState!.capture.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
  // 图像编码使用真实异步线程，避免假时钟阻止引擎返回像素。
  final _PixelFrame? frame = await tester.runAsync<_PixelFrame>(() async {
    // 以逻辑像素采样，避免设备比例改变采样坐标。
    final ui.Image image = await boundary.toImage(pixelRatio: 1);
    try {
      // RGBA 原始数据直接用于颜色和连续性断言。
      final ByteData? data = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (data == null) throw StateError('主题过渡像素读取失败');
      return _PixelFrame(
        image.width,
        image.height,
        Uint8List.fromList(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        ),
      );
    } finally {
      image.dispose();
    }
  });
  return frame!;
}

/// 检查四角与中心均为最终画面，避免仅通过某一已揭示区域。
void _expectSolid(_PixelFrame frame, Color expected) {
  // 采样点避开外沿一个像素的任何裁剪取整影响。
  final List<(int, int)> points = <(int, int)>[
    (2, 2),
    (frame.width - 3, 2),
    (2, frame.height - 3),
    (frame.width - 3, frame.height - 3),
    (frame.width ~/ 2, frame.height ~/ 2),
  ];
  // 每个区域都必须摆脱上一轮截图颜色。
  for (final (int x, int y) in points) {
    _expectColor(frame.at(x, y), expected);
  }
}

/// 为 GPU 颜色量化保留极小余量，不允许实际主题混色误通过。
void _expectColor(Color actual, Color expected) {
  expect((_red(actual) - _red(expected)).abs(), lessThanOrEqualTo(3));
  expect((_green(actual) - _green(expected)).abs(), lessThanOrEqualTo(3));
  expect((_blue(actual) - _blue(expected)).abs(), lessThanOrEqualTo(3));
  expect((actual.toARGB32() >> 24) & 0xff, 255);
}

/// 返回两幅完整画面最明显的通道变化，用于验证快切首帧无跳变。
int _maximumChannelDifference(_PixelFrame before, _PixelFrame after) {
  expect(after.width, before.width);
  expect(after.height, before.height);
  // 保留完整图像的最大变化，不能用平均值掩盖局部跳变。
  int maximum = 0;
  // 逐个 RGBA 通道检查相同位置。
  for (int index = 0; index < before.bytes.length; index += 1) {
    // 当前通道经过第二次截图后产生的量化或视觉差值。
    final int difference = (before.bytes[index] - after.bytes[index]).abs();
    if (difference > maximum) maximum = difference;
  }
  return maximum;
}

/// 读取颜色的八位红色通道。
int _red(Color color) => (color.toARGB32() >> 16) & 0xff;

/// 读取颜色的八位绿色通道。
int _green(Color color) => (color.toARGB32() >> 8) & 0xff;

/// 读取颜色的八位蓝色通道。
int _blue(Color color) => color.toARGB32() & 0xff;

/// 保存单帧像素，避免持有测试结束后仍需释放的引擎图像。
class _PixelFrame {
  /// 创建已脱离引擎图像生命周期的像素快照。
  const _PixelFrame(this.width, this.height, this.bytes);

  /// 快照的逻辑像素宽度。
  final int width;

  /// 快照的逻辑像素高度。
  final int height;

  /// 按行保存的 RGBA 字节。
  final Uint8List bytes;

  /// 返回指定逻辑像素的真实颜色。
  Color at(int x, int y) {
    // 每个像素占据连续四个通道。
    final int offset = (y * width + x) * 4;
    return Color.fromARGB(
      bytes[offset + 3],
      bytes[offset],
      bytes[offset + 1],
      bytes[offset + 2],
    );
  }
}

/// 维持活页面身份，同时允许测试改变主题标识和媒体度量。
class _Scene extends StatefulWidget {
  /// 创建纯色或可编辑的测试场景。
  const _Scene({super.key, required this.interactive});

  /// 是否需要真实输入与点击控件。
  final bool interactive;

  /// 创建独立场景状态。
  @override
  State<_Scene> createState() => _SceneState();
}

/// 测试通过此状态触发真实组件更新。
class _SceneState extends State<_Scene> {
  /// 完整复合画面的截图边界。
  final GlobalKey capture = GlobalKey();

  /// 持续存活的编辑页面状态。
  final GlobalKey<_LivePageState> page = GlobalKey<_LivePageState>();

  /// 活页面实际初始化次数。
  int initializations = 0;

  /// 传给主题过渡组件的外观标识。
  Object _themeKey = 0;

  /// 活页面当前实际绘制颜色。
  Color _color = _initialColor;

  /// 当前窗口逻辑尺寸。
  Size _size = const Size(320, 200);

  /// 当前窗口像素比例。
  double _pixelRatio = 1;

  /// 系统减少动画偏好。
  bool _reduceAnimations = false;

  /// 在同一个场景中改变待验证属性。
  void change({
    Object? themeKey,
    Color? color,
    Size? size,
    double? pixelRatio,
    bool? reduceAnimations,
  }) {
    setState(() {
      _themeKey = themeKey ?? _themeKey;
      _color = color ?? _color;
      _size = size ?? _size;
      _pixelRatio = pixelRatio ?? _pixelRatio;
      _reduceAnimations = reduceAnimations ?? _reduceAnimations;
    });
  }

  /// 构建带真实捕获边界和唯一活页面的固定尺寸窗口。
  @override
  Widget build(BuildContext context) {
    return MediaQuery(
      data: MediaQueryData(
        size: _size,
        devicePixelRatio: _pixelRatio,
        disableAnimations: _reduceAnimations,
      ),
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox.fromSize(
          size: _size,
          child: RepaintBoundary(
            key: capture,
            child: WindowsThemeTransition(
              themeKey: _themeKey,
              child: _LivePage(
                key: page,
                color: _color,
                interactive: widget.interactive,
                onInit: () => initializations += 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 提供可观察生命周期的活页面，捕获层不得克隆或替换它。
class _LivePage extends StatefulWidget {
  /// 创建保留输入状态的页面。
  const _LivePage({
    super.key,
    required this.color,
    required this.interactive,
    required this.onInit,
  });

  /// 页面当前主题背景色。
  final Color color;

  /// 是否展示编辑器和操作按钮。
  final bool interactive;

  /// 通知场景记录初始化次数。
  final VoidCallback onInit;

  /// 创建页面独立编辑状态。
  @override
  State<_LivePage> createState() => _LivePageState();
}

/// 保存用户草稿、焦点和操作计数。
class _LivePageState extends State<_LivePage> {
  /// 页面中的草稿文本。
  final TextEditingController controller = TextEditingController();

  /// 页面输入框的真实焦点节点。
  final FocusNode focus = FocusNode();

  /// 覆盖层存在期间实际收到的点击次数。
  int clicks = 0;

  /// 记录每次真实创建，检查主题切换是否复制了页面。
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  /// 随页面销毁释放用户输入对象。
  @override
  void dispose() {
    controller.dispose();
    focus.dispose();
    super.dispose();
  }

  /// 用纯色绘制像素测试，交互测试则加入真实编辑与按钮。
  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: widget.color,
      child: widget.interactive
          ? Material(
              color: Colors.transparent,
              child: Column(
                children: <Widget>[
                  TextField(controller: controller, focusNode: focus),
                  TextButton(
                    key: const ValueKey<String>('live-action'),
                    onPressed: () => setState(() => clicks += 1),
                    child: const Text('保留交互'),
                  ),
                ],
              ),
            )
          : const SizedBox.expand(),
    );
  }
}
