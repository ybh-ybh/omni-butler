import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// Distinct values catch accidental coupling between visual order and results.
enum _Scope { single, future }

/// The reference phone viewport uses logical pixels.
const Size _phone = Size(390, 844);

/// Match the production surface without depending on its internal widget tree.
Finder get _surface =>
    find.byKey(const ValueKey<String>('omni-action-sheet-surface'));

/// Match the dedicated cancel row independently of business labels.
Finder get _cancel =>
    find.byKey(const ValueKey<String>('omni-action-sheet-cancel'));

/// Verify the shared confirmation contract and export opt-in Chinese previews.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Local previews are opt-in so routine tests never require host fonts.
  final String? previewDirectory =
      Platform.environment['OMNI_ACTION_SHEET_PREVIEW_DIR'];

  setUpAll(() async {
    if (previewDirectory == null) return;
    // Reuse one locally supplied font for all theme fallback family names.
    final ByteData font = ByteData.sublistView(
      await File(
        Platform.environment['OMNI_UI_FONT'] ?? 'C:/Windows/Fonts/msyh.ttc',
      ).readAsBytes(),
    );
    // Register every family used by Android and the widget-test default.
    for (final String family in <String>[
      'Roboto',
      'Ahem',
      'Noto Sans CJK SC',
      'Microsoft YaHei UI',
      'Microsoft YaHei',
    ]) {
      // Each loader owns one named font family.
      final FontLoader loader = FontLoader(family)
        ..addFont(Future<ByteData>.value(font));
      await loader.load();
    }
  });

  testWidgets('安卓确认贴底通栏，操作纵排且标题只用于无障碍', (tester) async {
    // Production route and shared bool helper are exercised together.
    final _Host host = await _pumpHost(tester);
    // Only an explicit confirm may resolve this future to true.
    final Future<bool> result = host.confirm();
    await tester.pumpAndSettle();
    // The sheet reaches both viewport edges and includes the bottom safe area.
    final Rect bounds = tester.getRect(_surface);
    expect(bounds.left, 0);
    expect(bounds.right, _phone.width);
    expect(bounds.bottom, _phone.height);
    expect(find.text('删除对话'), findsNothing);
    expect(find.byTooltip('关闭'), findsNothing);
    expect(find.byType(DraggableScrollableSheet), findsNothing);
    expect(
      tester.getTopLeft(_cancel).dy,
      greaterThan(tester.getBottomLeft(find.text('确认删除')).dy),
    );
    expect(tester.getSize(_cancel).height, greaterThanOrEqualTo(56));
    expect(
      tester.getBottomLeft(_cancel).dy,
      lessThanOrEqualTo(_phone.height - 24),
    );
    // Visual assertions compare the rendered surface and text, not theme declarations.
    final Material surface = tester.widget<Material>(_surface);
    expect(surface.color, Colors.white);
    expect(
      surface.borderRadius,
      const BorderRadius.vertical(top: Radius.circular(12)),
    );
    // The explanatory text remains subordinate to the action rows.
    final TextStyle description = _renderedStyle(
      tester,
      '删除本次聊天记录，停止尚未执行的计划。已保存的业务记录会保留。',
    );
    expect(description.fontSize, 13);
    expect(description.color, OmniColors.of(host.context).muted);
    // Destructive action text uses red without inheriting a filled button.
    final TextStyle action = _renderedStyle(tester, '确认删除');
    expect(action.fontSize, 16);
    expect(action.color, Theme.of(host.context).colorScheme.error);
    // Cancel remains readable neutral text at the same action size.
    final TextStyle cancel = _renderedStyle(tester, '取消');
    expect(cancel.fontSize, 16);
    expect(cancel.color, OmniColors.of(host.context).ink);
    // Enabling semantics verifies the operation remains discoverable without a title bar.
    final SemanticsHandle semantics = tester.ensureSemantics();
    try {
      expect(find.bySemanticsLabel('删除对话'), findsOneWidget);
    } finally {
      semantics.dispose();
    }
    await tester.tap(find.text('确认删除'));
    await tester.pumpAndSettle();
    expect(await result, isTrue);
    expect(_surface, findsNothing);
  });

  // All passive dismissal paths must produce the same safe bool result.
  for (final String dismissal in <String>['cancel', 'barrier', 'back']) {
    testWidgets('$dismissal 关闭确认框不会授权操作', (tester) async {
      // Each test receives an isolated navigator and pending confirmation.
      final _Host host = await _pumpHost(tester);
      // Capture the helper result rather than inferring it from disappearance.
      final Future<bool> result = host.confirm();
      await tester.pumpAndSettle();
      switch (dismissal) {
        case 'cancel':
          await tester.tap(_cancel);
        case 'barrier':
          await tester.tapAt(const Offset(8, 40));
        case 'back':
          await tester.binding.handlePopRoute();
      }
      await tester.pumpAndSettle();
      expect(await result, isFalse);
      expect(_surface, findsNothing);
    });
  }

  // Verify every enum branch; presentation must not map both rows to one value.
  for (final _Scope scope in _Scope.values) {
    testWidgets('多选确认保留 ${scope.name} 的实际返回值', (tester) async {
      // The enum values model existing repeating-task scope choices.
      final _Host host = await _pumpHost(tester);
      // The shared component returns the original typed value.
      final Future<_Scope?> result = host.choose();
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('仅本次')).dy,
        lessThan(tester.getTopLeft(find.text('本次及以后')).dy),
      );
      expect(
        tester.getTopLeft(find.text('本次及以后')).dy,
        lessThan(tester.getTopLeft(_cancel).dy),
      );
      await tester.tap(find.text(scope == _Scope.single ? '仅本次' : '本次及以后'));
      await tester.pumpAndSettle();
      expect(await result, scope);
    });
  }

  testWidgets('多选确认取消返回 null，普通确认也使用底部面板', (tester) async {
    // Reuse a navigator to test both generic and bool result contracts.
    final _Host host = await _pumpHost(tester);
    // A dismissed choice must not silently select a default enum value.
    final Future<_Scope?> choice = host.choose();
    await tester.pumpAndSettle();
    await tester.tap(_cancel);
    await tester.pumpAndSettle();
    expect(await choice, isNull);
    // Non-destructive confirmations have the same presentation and explicit result.
    final Future<bool> ordinary = host.confirm(danger: false);
    await tester.pumpAndSettle();
    expect(_surface, findsOneWidget);
    expect(
      _renderedStyle(tester, '开启').color,
      OmniColors.of(host.context).brandStrong,
    );
    await tester.tap(find.text('开启'));
    await tester.pumpAndSettle();
    expect(await ordinary, isTrue);
  });

  // Small and constrained displays must keep choices accessible without overflow.
  for (final ({String name, Size size, double scale, double keyboard}) scenario
      in <({String name, Size size, double scale, double keyboard})>[
        (name: '窄屏大字', size: Size(320, 640), scale: 2, keyboard: 0),
        (name: '横屏', size: Size(844, 390), scale: 1, keyboard: 0),
        (name: '键盘', size: _phone, scale: 1.3, keyboard: 280),
      ]) {
    testWidgets('${scenario.name} 长说明可滚动且确认与取消可点击', (tester) async {
      // Vary inherited media data above the navigator, as on a real device.
      final _Host host = await _pumpHost(
        tester,
        size: scenario.size,
        textScale: scenario.scale,
        keyboard: scenario.keyboard,
      );
      // Reuse the same long warning for an explicit choice and cancellation.
      final String message = List<String>.filled(
        35,
        '本次选择将影响重复待办，请核对处理范围。',
      ).join('\n');
      // A long warning must not force actions outside the usable viewport.
      final Future<_Scope?> result = host.choose(message: message);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.getBottomLeft(_surface).dy,
        lessThanOrEqualTo(scenario.size.height - scenario.keyboard),
      );
      expect(find.byType(Scrollable), findsWidgets);
      await tester.ensureVisible(find.text('本次及以后'));
      expect(find.text('本次及以后').hitTestable(), findsOneWidget);
      await tester.tap(find.text('本次及以后'));
      await tester.pumpAndSettle();
      expect(await result, _Scope.future);
      // Reopening also verifies that cancellation stays reachable after a long warning.
      final Future<_Scope?> canceled = host.choose(message: message);
      await tester.pumpAndSettle();
      await tester.ensureVisible(_cancel);
      await tester.tap(_cancel);
      await tester.pumpAndSettle();
      expect(await canceled, isNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('深色主题仍保留操作文字和可关闭行为', (tester) async {
    // The shared sheet reads the same theme extension as the rest of the app.
    final _Host host = await _pumpHost(tester, brightness: Brightness.dark);
    // Keep the future to verify dark mode does not alter confirmation semantics.
    final Future<bool> result = host.confirm();
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(_surface)).brightness, Brightness.dark);
    expect(find.text('确认删除'), findsOneWidget);
    // Dark mode uses a readable semantic red rather than the darker filled-button red.
    final TextStyle action = _renderedStyle(tester, '确认删除');
    expect(action.color, OmniColors.of(host.context).danger);
    expect(action.fontSize, 16);
    // Contrast is measured against the actual painted sheet background.
    final Material surface = tester.widget<Material>(_surface);
    expect(surface.color, OmniColors.of(host.context).paper);
    expect(
      _contrastRatio(action.color!, surface.color!),
      greaterThanOrEqualTo(4.5),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(_cancel);
    await tester.pumpAndSettle();
    expect(await result, isFalse);
  });

  testWidgets('沿用安卓进出时长，进入中遮罩防连点且退出向下', (tester) async {
    // Open through the real route to check its barrier and transition controller.
    final _Host host = await _pumpHost(tester);
    // Hold the result until the exit finishes.
    final Future<bool> result = host.confirm();
    await tester.pump();
    // The initial surface must start below the screen.
    final double initialTop = tester.getTopLeft(_surface).dy;
    expect(initialTop, greaterThanOrEqualTo(_phone.height));
    // Durations come from the route, not a second local animation controller.
    final TransitionRoute<Object?> route = ModalRoute.of(
      tester.element(_surface),
    )!;
    expect(route.transitionDuration, OmniMotion.androidModalEnter);
    expect(route.reverseTransitionDuration, OmniMotion.androidModalExit);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getTopLeft(_surface).dy, lessThan(initialTop));
    await tester.tapAt(const Offset(8, 40));
    await tester.pumpAndSettle();
    expect(_surface, findsOneWidget);
    // The settled location is the start of the independent exit transition.
    final double settledTop = tester.getTopLeft(_surface).dy;
    await tester.tap(_cancel);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.getTopLeft(_surface).dy, greaterThan(settledTop));
    await tester.pumpAndSettle();
    expect(await result, isFalse);
  });

  testWidgets('进入中系统返回从当前位置向下退出', (tester) async {
    // Returning early must preserve the current animation progress.
    final _Host host = await _pumpHost(tester);
    // Cancellation is still represented as false when the entry is incomplete.
    final Future<bool> result = host.confirm();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    // Record the last visible entry frame before the route reverses.
    final double before = tester.getTopLeft(_surface).dy;
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(tester.getTopLeft(_surface).dy, closeTo(before, 0.1));
    await tester.pump(const Duration(milliseconds: 30));
    expect(tester.getTopLeft(_surface).dy, greaterThan(before));
    await tester.pumpAndSettle();
    expect(await result, isFalse);
  });

  testWidgets('连续双点确认只关闭当前面板，不误关底层详情路由', (tester) async {
    // An additional route makes an accidental second pop observable.
    final _Host host = await _pumpHost(tester);
    // Keep the parent route open until the test explicitly dismisses it.
    final NavigatorState navigator = Navigator.of(host.context);
    // This future must remain pending while the confirmation closes.
    final Future<void> details = navigator.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Center(child: Text('父级详情'))),
      ),
    );
    await tester.pumpAndSettle();
    // A confirmed result authorizes only the current confirmation action.
    final Future<bool> result = host.confirm();
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认删除'));
    // No intervening frame: both taps hit the still-mounted outgoing row.
    await tester.tap(find.text('确认删除'));
    await tester.pumpAndSettle();
    expect(await result, isTrue);
    expect(_surface, findsNothing);
    expect(find.text('父级详情'), findsOneWidget);
    expect(navigator.canPop(), isTrue);
    navigator.pop();
    await tester.pumpAndSettle();
    await details;
    expect(find.text('AI'), findsOneWidget);
  });

  testWidgets('减少动画时即时打开和关闭', (tester) async {
    // MediaQuery sits above the root navigator to reach dialog routes.
    final _Host host = await _pumpHost(tester, reduceMotion: true);
    // The bool result must not wait for the normal transition duration.
    final Future<bool> result = host.confirm();
    await tester.pump();
    // Both route directions honour the reduced-motion preference.
    final TransitionRoute<Object?> route = ModalRoute.of(
      tester.element(_surface),
    )!;
    expect(route.transitionDuration, Duration.zero);
    expect(route.reverseTransitionDuration, Duration.zero);
    expect(tester.getBottomLeft(_surface).dy, _phone.height);
    await tester.tap(_cancel);
    await tester.pump();
    await tester.pump();
    expect(_surface, findsNothing);
    expect(await result, isFalse);
  });

  testWidgets('Windows 确认继续显示居中标题栏和原操作按钮', (tester) async {
    // The public bool helper remains platform-adaptive.
    final _Host host = await _pumpHost(
      tester,
      platform: TargetPlatform.windows,
    );
    // Preserve the existing desktop result contract.
    final Future<bool> result = host.confirm();
    await tester.pumpAndSettle();
    expect(_surface, findsNothing);
    expect(find.byType(OmniDialogScaffold), findsOneWidget);
    expect(find.text('删除对话'), findsOneWidget);
    expect(find.byTooltip('关闭'), findsOneWidget);
    expect(find.byType(Dialog), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await result, isFalse);
  });

  // Export real-font previews separately from portable widget assertions.
  for (final bool multiple in <bool>[false, true]) {
    testWidgets('中文预览 ${multiple ? '多选确认' : '删除对话'}', (tester) async {
      // A simple page provides contrast for the actual production overlay.
      final _Host host = await _pumpHost(tester);
      // Keep the future alive through rendering, then dismiss normally.
      final Future<Object?> result = multiple ? host.choose() : host.confirm();
      await tester.pumpAndSettle();
      await _writePreview(
        tester,
        '$previewDirectory/android_confirm_${multiple ? 'multiple' : 'delete'}.png',
      );
      await tester.tap(_cancel);
      await tester.pumpAndSettle();
      await result;
    }, skip: previewDirectory == null);
  }
}

/// Read the final merged text style that Flutter paints for a visible label.
TextStyle _renderedStyle(WidgetTester tester, String label) {
  // RichText receives inherited and local styling after Text resolves both.
  final RichText text = tester.widget<RichText>(
    find.descendant(of: find.text(label), matching: find.byType(RichText)),
  );
  return text.text.style!;
}

/// Measure WCAG contrast for the actual foreground and opaque surface colors.
double _contrastRatio(Color foreground, Color background) {
  // Resolve relative luminance after compositing any foreground transparency.
  final double first = Color.alphaBlend(
    foreground,
    background,
  ).computeLuminance();
  // The painted surface is opaque in both supported themes.
  final double second = background.computeLuminance();
  return first > second
      ? (first + 0.05) / (second + 0.05)
      : (second + 0.05) / (first + 0.05);
}

/// Hold the builder context without introducing a second route implementation.
class _Host {
  /// The trigger context inherits the same theme as production callers.
  late BuildContext context;

  /// Open the existing bool convenience API for both semantic tones.
  Future<bool> confirm({bool danger = true}) => showOmniConfirmDialog(
    context,
    title: danger ? '删除对话' : '开启语音转文字',
    message: danger
        ? '删除本次聊天记录，停止尚未执行的计划。已保存的业务记录会保留。'
        : '之后的新录音将通过已连接的服务器提交给语音识别服务。',
    confirmLabel: danger ? '确认删除' : '开启',
    danger: danger,
  );

  /// Open enum-valued choices without duplicating business execution callbacks.
  Future<_Scope?> choose({String? message}) => showOmniActionSheet<_Scope>(
    context: context,
    title: '移入回收站？',
    message: message ?? '“每周整理笔记”会进入回收站，请选择本次删除的范围。',
    actions: const <OmniActionSheetAction<_Scope>>[
      OmniActionSheetAction<_Scope>(
        label: '仅本次',
        value: _Scope.single,
        danger: true,
      ),
      OmniActionSheetAction<_Scope>(
        label: '本次及以后',
        value: _Scope.future,
        danger: true,
      ),
    ],
  );
}

/// Install media preferences above the navigator so modal routes receive them.
Future<_Host> _pumpHost(
  WidgetTester tester, {
  Size size = _phone,
  double textScale = 1,
  double keyboard = 0,
  bool reduceMotion = false,
  Brightness brightness = Brightness.light,
  TargetPlatform platform = TargetPlatform.android,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // This object only keeps the production trigger context.
  final _Host host = _Host();
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(brightness: brightness)
          .copyWith(platform: platform),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: reduceMotion,
          padding: EdgeInsets.only(top: 24, bottom: keyboard == 0 ? 24 : 0),
          viewPadding: const EdgeInsets.only(top: 24, bottom: 24),
          viewInsets: EdgeInsets.only(bottom: keyboard),
        ),
        child: RepaintBoundary(
          key: const ValueKey<String>('action-sheet-preview'),
          child: child!,
        ),
      ),
      home: Builder(
        builder: (context) {
          host.context = context;
          return Scaffold(
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      'AI',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 32),
                    const Text('7 天内'),
                    const SizedBox(height: 24),
                    const Text('你好'),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return host;
}

/// Write a review artifact without updating portable golden expectations.
Future<void> _writePreview(WidgetTester tester, String path) async {
  await tester.runAsync(() async {
    // Capture the navigator and its barrier together at phone resolution.
    final RenderRepaintBoundary boundary = tester
        .renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey<String>('action-sheet-preview')),
        );
    // Raster output is restricted to the opt-in artifact directory.
    final ui.Image image = await boundary.toImage(pixelRatio: 2);
    try {
      // PNG encoding preserves the exact rendered text and surface geometry.
      final ByteData bytes = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!;
      // Create only the requested preview file's parent directory.
      final File file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}
