// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/src/foundation/_features.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:omni_butler/features/todos/presentation/todo_editor_dialog.dart';
import 'package:omni_butler/features/todos/presentation/todo_progress_widgets.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

/// 每次真实命中测试使用不同指针身份，避免与前一轮手势路由混淆。
int _nextPointerId = 1;

/// 使用单调时钟为合成指针事件提供真实经过时间。
final Stopwatch _pointerClock = Stopwatch()..start();

/// 只在真实运行时验证内存任务，不读取正式数据库、偏好、会话或同步服务。
Future<void> main() async {
  if (Platform.isWindows) isWindowingEnabled = true;
  WidgetsFlutterBinding.ensureInitialized();
  // 布局溢出和异步回调异常同样视为失败，不能仅凭业务断言报告通过。
  FlutterError.onError = (FlutterErrorDetails details) {
    _fail(details.exception, details.stack ?? StackTrace.current);
  };
  ui.PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    _fail(error, stack);
  };
  try {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 内存偏好，不访问真实用户配置。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 唯一的业务数据库完全驻留内存。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 生产组件与验证代码共用同一隔离容器。
    final ProviderContainer container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        appDatabaseProvider.overrideWithValue(database),
      ],
    );
    // 使用生产仓储建立真实任务和步骤。
    final TodoRepository repository = container.read(todoRepositoryProvider);
    await repository.save(
      TodoDraft(
        title: '真实运行时验证 · 阅读十二章',
        scheduledDate: DateTime(2026, 10, 7),
        taskType: TodoTaskType.progress,
        progressUnit: '章',
        progressSteps: List<TodoProgressStepDraft>.generate(
          12,
          (int index) => TodoProgressStepDraft(
            name: switch (index) {
              0 => '引言',
              2 => '基础概念',
              7 => '实践练习',
              _ => null,
            },
          ),
        ),
      ),
    );
    // 刚创建的唯一任务。
    final TodoRecord todo = await database
        .select(database.todoItems)
        .getSingle();
    // 可选真实截图只包含本测试窗口的渲染结果。
    final GlobalKey captureKey = GlobalKey(debugLabel: 'runtime-smoke-capture');
    // 生产进度组件使用独立应用，避免初始化托盘和正式应用协调器。
    final Widget app = UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: captureKey,
        child: _ProgressSmokeApp(todoId: todo.id),
      ),
    );
    if (Platform.isWindows) {
      runWidget(_ProgressSmokeWindow(child: app));
    } else {
      runApp(app);
    }
    await _verifyFlow(
      database,
      repository,
      todo.id,
      captureKey,
    ).timeout(const Duration(seconds: 90));
    _report(
      'PASS: todo_progress_runtime_smoke platform=${Platform.operatingSystem}; '
      'isolated memory DB/preferences; production tile/panel; named and unnamed '
      'steps; jump 1/3/8; next-step actions; 12/12 awaits confirmation; '
      'confirm; readonly completed steps; reopen preserves 12/12; '
      'rendered frames and pointer hit testing',
    );
    if (!Platform.isAndroid) await stdout.flush();
    // 留出平台日志转发时间，避免进程退出前丢失最后一条通过记录。
    await Future<void>.delayed(const Duration(milliseconds: 250));
    exit(0);
  } catch (error, stack) {
    _fail(error, stack);
  }
}

/// Android通过Flutter日志桥写入logcat，桌面保留标准输出供父进程采集。
void _report(String message) {
  if (Platform.isAndroid) {
    debugPrintSynchronously(message);
  } else {
    stdout.writeln(message);
  }
}

/// 统一输出可由父进程识别的失败日志及非零退出码。
Never _fail(Object error, StackTrace stack) {
  // 同一失败内容在Android走Flutter日志桥，桌面沿用标准错误输出。
  final String message = 'FAIL: todo_progress_runtime_smoke $error\n$stack';
  if (Platform.isAndroid) {
    _report(message);
    // 失败处理必须立即退出，短暂同步等待保证日志先交给平台。
    sleep(const Duration(milliseconds: 250));
  } else {
    stderr.writeln(message);
  }
  exit(1);
}

/// 通过生产组件的稳定键定位真实点击位置，并在数据库与画面两侧验证结果。
Future<void> _verifyFlow(
  AppDatabase database,
  TodoRepository repository,
  String todoId,
  GlobalKey captureKey,
) async {
  await _waitUntil('进度任务行加载', () async {
    return _buttonEnabled('progress-update-$todoId');
  });
  await _capture(captureKey, '01-list-empty');
  await _pressButton('progress-update-$todoId');
  await _waitUntil('步骤面板加载', () async {
    return _buttonEnabled('todo-progress-next');
  });
  // 仓储按实际显示顺序返回稳定步骤身份。
  final List<TodoProgressStepRecord> initial = await repository
      .watchProgressSteps(todoId)
      .first;
  if (initial.length != 12 ||
      initial[0].name != '引言' ||
      initial[1].name != null ||
      initial[7].name != '实践练习') {
    throw StateError('初始命名和空名称步骤不正确');
  }
  // 跳序点击真实步骤块，而不是直接调用仓储修改进度。
  int expected = 0;
  for (final int index in <int>[7, 0, 2]) {
    await _pressStep(initial[index].id);
    expected += 1;
    await _waitProgress(database, repository, todoId, expected);
    await _waitUntil('步骤提交结束', () async {
      return _buttonEnabled('todo-progress-next');
    });
  }
  // 核对点亮的确切身份，避免总数正确但错误点亮前三步。
  final List<TodoProgressStepRecord> jumped = await repository
      .watchProgressSteps(todoId)
      .first;
  for (int index = 0; index < jumped.length; index += 1) {
    if (jumped[index].isCompleted != <int>{0, 2, 7}.contains(index)) {
      throw StateError('跳序结果错误：步骤 ${index + 1}');
    }
  }
  _report('PROGRESS_RUNTIME: jump=3/12 indices=1,3,8 taskCompleted=false');
  await _capture(captureKey, '02-panel-jump-3-of-12');
  while (expected < 12) {
    await _pressButton('todo-progress-next');
    expected += 1;
    await _waitProgress(database, repository, todoId, expected);
    await _waitUntil('下一次步骤操作就绪', () async {
      return _buttonEnabled(
        expected == 12 ? 'todo-progress-confirm' : 'todo-progress-next',
      );
    });
  }
  _report('PROGRESS_RUNTIME: ready=12/12 taskCompleted=false');
  await _capture(captureKey, '03-panel-awaiting-confirmation');
  await _pressButton('todo-progress-confirm');
  await _waitUntil('确认完成', () async {
    // 真正持久化的任务确认结果。
    final TodoRecord current = await database
        .select(database.todoItems)
        .getSingle();
    return current.isCompleted &&
        current.completedAt != null &&
        _buttonEnabled('todo-progress-reopen');
  });
  for (final TodoProgressStepRecord step in initial) {
    if (_stepWidget(step.id).onTap != null) {
      throw StateError('已完成步骤仍可直接修改：${step.id}');
    }
  }
  _report('PROGRESS_RUNTIME: confirmed=12/12 taskCompleted=true readonly=true');
  await _capture(captureKey, '04-panel-confirmed');
  await _pressButton('todo-progress-reopen');
  await _waitProgress(database, repository, todoId, 12);
  await _waitUntil('重新打开后待确认', () async {
    return _buttonEnabled('todo-progress-confirm');
  });
  for (final TodoProgressStepRecord step in initial) {
    if (_stepWidget(step.id).onTap == null) {
      throw StateError('重新打开后步骤仍被禁用：${step.id}');
    }
  }
  _report('PROGRESS_RUNTIME: reopened=12/12 taskCompleted=false');
  await _capture(captureKey, '05-panel-reopened');
}

/// 等待当前进度保存，满进度同样要求任务尚未确认。
Future<void> _waitProgress(
  AppDatabase database,
  TodoRepository repository,
  String todoId,
  int completed,
) => _waitUntil('保存 $completed/12', () async {
  // 当前实时步骤状态。
  final List<TodoProgressStepRecord> steps = await repository
      .watchProgressSteps(todoId)
      .first;
  // 当前实时任务状态。
  final TodoRecord todo = await database.select(database.todoItems).getSingle();
  return steps.length == 12 &&
      steps.where((step) => step.isCompleted).length == completed &&
      !todo.isCompleted &&
      todo.completedAt == null;
});

/// 保持真实引擎运行并有界等待异步数据库订阅和重绘完成。
Future<void> _waitUntil(String stage, Future<bool> Function() ready) async {
  // 每个阶段单独设定超时，卡住时日志能定位具体操作。
  final Stopwatch deadline = Stopwatch()..start();
  while (deadline.elapsed < const Duration(seconds: 10)) {
    await Future<void>.delayed(const Duration(milliseconds: 40));
    WidgetsBinding.instance.scheduleFrame();
    await WidgetsBinding.instance.endOfFrame;
    if (await ready()) return;
  }
  throw TimeoutException('阶段超时：$stage');
}

/// 通过稳定键查找已挂载的生产元素，不依赖当前中文文案。
Element? _findElement(String key) {
  // 唯一匹配的生产组件。
  Element? found;

  /// 递归读取现有元素树，不创建额外UI状态。
  void visit(Element element) {
    if (found != null) return;
    if (element.widget.key == ValueKey<String>(key)) {
      found = element;
      return;
    }
    element.visitChildren(visit);
  }

  // Windows多窗口与Android均从本引擎根节点开始查找。
  final Element? root = WidgetsBinding.instance.rootElement;
  if (root != null) visit(root);
  return found;
}

/// 检查真实按钮已就绪，避免串行操作落在提交禁用期。
bool _buttonEnabled(String key) {
  // 当前渲染出的生产按钮。
  final Widget? widget = _findElement(key)?.widget;
  return widget is OmniButton && widget.onPressed != null && !widget.loading;
}

/// 点击生产按钮的实际渲染位置，缺失或禁用均立即报错。
Future<void> _pressButton(String key) async {
  // 当前生产按钮实例。
  final Widget? widget = _findElement(key)?.widget;
  if (widget is! OmniButton || widget.onPressed == null || widget.loading) {
    throw StateError('生产按钮不存在或不可用：$key');
  }
  await _tapElement(key);
}

/// 返回真实步骤点击区域，供操作及完成后的只读断言共用。
InkWell _stepWidget(String id) {
  // 当前稳定步骤身份对应的生产组件。
  final Widget? widget = _findElement('todo-progress-step-$id')?.widget;
  if (widget is! InkWell) throw StateError('步骤组件不存在：$id');
  return widget;
}

/// 点击步骤块的实际渲染位置，验证滚动、命中与生产手势连接。
Future<void> _pressStep(String id) async {
  // 当前步骤绑定的业务回调。
  final VoidCallback? callback = _stepWidget(id).onTap;
  if (callback == null) throw StateError('步骤组件不可用：$id');
  await _tapElement('todo-progress-step-$id');
}

/// 滚动到可见区域后，经引擎命中测试发送按下和抬起事件，不直接调用业务回调。
Future<void> _tapElement(String key) async {
  // 点击前已挂载的目标元素。
  final Element? beforeScroll = _findElement(key);
  if (beforeScroll == null || !beforeScroll.mounted) {
    throw StateError('点击目标不存在：$key');
  }
  // 等待侧栏入场动画结束，避免坐标计算后目标仍在移动。
  await Future<void>.delayed(const Duration(milliseconds: 350));
  await Scrollable.ensureVisible(
    beforeScroll,
    alignment: 0.5,
    duration: const Duration(milliseconds: 180),
    curve: Curves.easeOut,
  );
  WidgetsBinding.instance.scheduleFrame();
  await WidgetsBinding.instance.endOfFrame;
  // 滚动可能触发重建，因此从稳定键重新获取目标。
  final Element? target = _findElement(key);
  if (target == null || !target.mounted) {
    throw StateError('滚动后点击目标不存在：$key');
  }
  // 使用实际布局后的区域计算命中中心，不依赖屏幕尺寸或固定坐标。
  final RenderObject? object = target.findRenderObject();
  if (object is! RenderBox || !object.hasSize || object.size.isEmpty) {
    throw StateError('点击目标尚未完成布局：$key');
  }
  // 真实Flutter View中的逻辑坐标，与命中测试使用同一坐标空间。
  final Offset position = object.localToGlobal(object.size.center(Offset.zero));
  // Windows独立窗口与Android主视图均显式指定其所属View。
  final int viewId = View.of(target).viewId;
  // 本轮完整手势在按下和抬起之间使用同一个指针身份。
  final int pointer = _nextPointerId++;
  GestureBinding.instance.handlePointerEvent(
    PointerDownEvent(
      pointer: pointer,
      position: position,
      viewId: viewId,
      kind: ui.PointerDeviceKind.touch,
      buttons: kPrimaryButton,
      timeStamp: _pointerClock.elapsed,
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 40));
  GestureBinding.instance.handlePointerEvent(
    PointerUpEvent(
      pointer: pointer,
      position: position,
      viewId: viewId,
      kind: ui.PointerDeviceKind.touch,
      timeStamp: _pointerClock.elapsed,
    ),
  );
  WidgetsBinding.instance.scheduleFrame();
  await WidgetsBinding.instance.endOfFrame;
  _report('PROGRESS_RUNTIME_POINTER: key=$key view=$viewId at=$position');
}

/// Windows可选截图只写入显式提供的绝对目录，Android不写文件。
Future<void> _capture(GlobalKey key, String name) async {
  if (!Platform.isWindows) return;
  // 父进程显式授权的截图输出目录。
  final String? destination =
      Platform.environment['OMNI_PROGRESS_RUNTIME_CAPTURE'];
  if (destination == null || destination.isEmpty) return;
  if (!path.isAbsolute(destination)) {
    throw ArgumentError('OMNI_PROGRESS_RUNTIME_CAPTURE 必须是绝对路径');
  }
  await Future<void>.delayed(const Duration(milliseconds: 400));
  WidgetsBinding.instance.scheduleFrame();
  await WidgetsBinding.instance.endOfFrame;
  // 当前测试窗口的真实合成图层。
  final RenderObject? object = key.currentContext?.findRenderObject();
  if (object is! RenderRepaintBoundary) throw StateError('缺少截图重绘边界');
  // 完成栅格化的实际窗口图像。
  final ui.Image image = await object.toImage(pixelRatio: 1);
  try {
    // 编码后的PNG内容。
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) throw StateError('PNG编码失败');
    await Directory(destination).create(recursive: true);
    await File(path.join(destination, '$name.png')).writeAsBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      flush: true,
    );
    _report('PROGRESS_RUNTIME_CAPTURE: ${path.join(destination, '$name.png')}');
  } finally {
    image.dispose();
  }
}

/// 独立测试应用只渲染生产任务行和其打开的生产步骤面板。
class _ProgressSmokeApp extends ConsumerWidget {
  /// 当前内存任务身份。
  final String todoId;

  /// 创建隔离应用。
  const _ProgressSmokeApp({required this.todoId});

  /// 在标准Material应用中使用实际Provider订阅。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(brightness: Brightness.light),
      home: Scaffold(
        appBar: AppBar(title: const Text('进度任务 · 隔离运行时验证')),
        body: Consumer(
          builder: (BuildContext context, WidgetRef ref, Widget? child) {
            // 当前任务状态只由生产仓储的数据库订阅驱动。
            final TodoRecord? todo = ref
                .watch(todoByIdProvider(todoId))
                .asData
                ?.value;
            if (todo == null) {
              return const Center(child: CircularProgressIndicator());
            }
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: TodoProgressTaskTile(
                    todo: todo,
                    onEdit: () => TodoEditorDialog.show(context, record: todo),
                    onDelete: () =>
                        _fail(StateError('本smoke不应触发删除'), StackTrace.current),
                    onConfirm: () => unawaited(
                      ref
                          .read(todoRepositoryProvider)
                          .confirmProgressTask(todo.id),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Windows runner只创建引擎，因此测试入口必须自行创建唯一原生窗口。
class _ProgressSmokeWindow extends StatefulWidget {
  /// 当前隔离应用。
  final Widget child;

  /// 创建独立测试窗口。
  const _ProgressSmokeWindow({required this.child});

  /// 创建窗口生命周期状态。
  @override
  State<_ProgressSmokeWindow> createState() => _ProgressSmokeWindowState();
}

/// 只管理本smoke的原生窗口，不初始化正式托盘或悬浮窗。
class _ProgressSmokeWindowState extends State<_ProgressSmokeWindow> {
  /// 仅属于本测试进程的窗口控制器。
  late final RegularWindowController _controller;

  /// 创建并激活真实Windows窗口以驱动实际渲染。
  @override
  void initState() {
    super.initState();
    _controller = RegularWindowController(
      title: 'Omni Progress Runtime Smoke',
      size: const Size(860, 780),
      constraints: const BoxConstraints(minWidth: 360, minHeight: 480),
      delegate: _ProgressSmokeWindowDelegate(),
    );
    _controller.activate();
  }

  /// 释放独立窗口控制器。
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 为独立应用提供真实Flutter View和窗口管理上下文。
  @override
  Widget build(BuildContext context) => RegularWindow(
    controller: _controller,
    child: WindowManager(child: widget.child),
  );
}

/// 在验证提前被关闭时返回失败，不能伪装已通过。
class _ProgressSmokeWindowDelegate with RegularWindowControllerDelegate {
  /// 关闭请求只销毁本测试窗口。
  @override
  void onWindowCloseRequested(RegularWindowController controller) {
    controller.destroy();
  }

  /// 唯一窗口提前销毁时明确报告未完成验证。
  @override
  void onWindowDestroyed() => _fail(StateError('验证窗口提前关闭'), StackTrace.current);
}
