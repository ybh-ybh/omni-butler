import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/shared/ui/omni_modal_bottom_sheet.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 按真实共享入口验证不同尺寸与位置的模态内容。
enum _ModalKind { centered, fullscreen, sheet, expandable, sideSheet }

/// 固定视口，便于确认起始位置已完全离屏。
const Size _viewport = Size(390, 844);

/// 不依赖pumpAndSettle跳过动画，逐帧核验正反向位置。
void main() {
  testWidgets('动效偏好只订阅减少动画，键盘和安全区变化不重建稳定子树', (tester) async {
    // Update only inherited media data while retaining the same child instance.
    final ValueNotifier<MediaQueryData> media = ValueNotifier(
      const MediaQueryData(
        size: _viewport,
        padding: EdgeInsets.only(bottom: 24),
        viewPadding: EdgeInsets.only(bottom: 24),
      ),
    );
    addTearDown(media.dispose);
    // Count builds of a consumer that only requests the motion preference.
    int builds = 0;
    // Record the observable duration returned to a production animation caller.
    Duration? duration;
    // Reusing this widget avoids parent rebuilds obscuring inherited dependencies.
    final Widget stableChild = Builder(
      builder: (context) {
        builds++;
        duration = OmniMotion.duration(context, OmniMotion.normal);
        return const SizedBox.shrink();
      },
    );
    await tester.pumpWidget(
      ValueListenableBuilder<MediaQueryData>(
        valueListenable: media,
        child: stableChild,
        builder: (context, data, child) =>
            MediaQuery(data: data, child: child!),
      ),
    );
    expect(builds, 1);
    expect(duration, OmniMotion.normal);
    // Every IME frame must leave motion-only consumers untouched.
    for (final double keyboard in [80, 180, 280, 180, 80, 0]) {
      media.value = media.value.copyWith(
        viewInsets: EdgeInsets.only(bottom: keyboard),
        padding: EdgeInsets.only(bottom: keyboard == 0 ? 24 : 0),
      );
      await tester.pump();
      expect(builds, 1);
      expect(duration, OmniMotion.normal);
    }
    media.value = media.value.copyWith(disableAnimations: true);
    await tester.pump();
    expect(builds, 2);
    expect(duration, Duration.zero);
    media.value = media.value.copyWith(disableAnimations: false);
    await tester.pump();
    expect(builds, 3);
    expect(duration, OmniMotion.normal);
  });

  // 当前需要逐帧验证的模态入口。
  for (final _ModalKind kind in _ModalKind.values) {
    testWidgets('${kind.name}逐帧从底部进入并完整向下退出', (tester) async {
      // 每个入口拥有独立宿主和返回结果。
      final _ModalHost host = await _pumpHost(tester);
      unawaited(host.open(kind));
      await tester.pump();
      // 路由既有布局下的真实内容表面。
      final Finder surface = _surface(kind);
      // 初始状态完整位于视口下方。
      final double initialTop = tester.getTopLeft(surface).dy;
      expect(initialTop, greaterThanOrEqualTo(_viewport.height));
      // 确认原生面板及自定义弹窗实际采用同一时长。
      final TransitionRoute<Object?> route = ModalRoute.of(
        tester.element(surface),
      )!;
      expect(route.transitionDuration, OmniMotion.androidModalEnter);
      expect(route.reverseTransitionDuration, OmniMotion.androidModalExit);
      await tester.pump(const Duration(milliseconds: 100));
      // 第一帧位移与最终布局位置明确不同。
      final double firstTop = tester.getTopLeft(surface).dy;
      await tester.pump(const Duration(milliseconds: 100));
      // 中途仍持续向上移动，没有直接跳到最终位置。
      final double secondTop = tester.getTopLeft(surface).dy;
      expect(firstTop, lessThan(initialTop));
      expect(secondTop, lessThan(firstTop));
      await tester.pump(const Duration(milliseconds: 100));
      // 动画结束后仍保持各入口原本的大小和最终位置。
      final Rect settled = tester.getRect(surface);
      expect(secondTop, greaterThan(settled.top));
      if (kind == _ModalKind.fullscreen || kind == _ModalKind.sideSheet) {
        expect(settled, Offset.zero & _viewport);
      } else if (kind == _ModalKind.centered) {
        expect(settled.center.dy, closeTo(_viewport.height / 2, 0.1));
      } else {
        expect(settled.bottom, closeTo(_viewport.height, 0.1));
      }
      host.navigator.currentState!.pop('saved');
      await tester.pump();
      expect(tester.getRect(surface), settled);
      await tester.pump(const Duration(milliseconds: 80));
      // 退出中内容仍挂载，表面已经向下移动。
      final double exitingTop = tester.getTopLeft(surface).dy;
      expect(exitingTop, greaterThan(settled.top));
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.getTopLeft(surface).dy, greaterThan(exitingTop));
      await tester.pump(const Duration(milliseconds: 61));
      await tester.pump();
      expect(surface, findsNothing);
      expect(host.results, <String?>['saved']);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('进入中关闭从当前帧反向，不跳回底部或重新开始', (tester) async {
    // 直接通过导航返回模拟快速取消。
    final _ModalHost host = await _pumpHost(tester);
    unawaited(host.open(_ModalKind.centered));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    // 关闭前尚未到达中间位置的表面坐标。
    final Offset before = tester.getTopLeft(_surface(_ModalKind.centered));
    host.navigator.currentState!.pop('cancel');
    await tester.pump();
    expect(tester.getTopLeft(_surface(_ModalKind.centered)), before);
    await tester.pump(const Duration(milliseconds: 30));
    expect(
      tester.getTopLeft(_surface(_ModalKind.centered)).dy,
      greaterThan(before.dy),
    );
    await tester.pumpAndSettle();
    expect(host.results, <String?>['cancel']);
  });

  testWidgets('进入中遮罩吸收入口连续点击，稳定后恢复点击关闭', (tester) async {
    // 模拟图片第一下打开预览后，第二下仍落在原缩略图坐标。
    final _ModalHost host = await _pumpHost(tester);
    unawaited(host.open(_ModalKind.centered));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(_surface(_ModalKind.centered), findsOneWidget);
    expect(host.results, isEmpty);
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(_surface(_ModalKind.centered), findsNothing);
    expect(host.results, <String?>[null]);
  });

  // 当前需要验证零时长进退的模态入口。
  for (final _ModalKind kind in _ModalKind.values) {
    testWidgets('${kind.name}系统禁用动画时进退均即时完成', (tester) async {
      // 减少动画必须传递到根导航路由，而非仅业务子树。
      final _ModalHost host = await _pumpHost(tester, reduce: true);
      unawaited(host.open(kind));
      await tester.pump();
      // 读取实际导航控制器时长，排除视觉静止但仍等待300ms。
      final TransitionRoute<Object?> route = ModalRoute.of(
        tester.element(_surface(kind)),
      )!;
      expect(route.transitionDuration, Duration.zero);
      expect(route.reverseTransitionDuration, Duration.zero);
      expect(tester.getTopLeft(_surface(kind)).dy, lessThan(_viewport.height));
      host.navigator.currentState!.pop();
      await tester.pump();
      await tester.pump();
      expect(_surface(kind), findsNothing);
    });
  }

  testWidgets('辅助服务导航不关闭动画，遮罩与表面同步进退', (tester) async {
    // 仅开启辅助服务导航，保留真实动画进度。
    final _ModalHost host = await _pumpHost(tester, accessible: true);
    unawaited(host.open(_ModalKind.centered));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // 直接读取独立遮罩颜色，确认没有随内容一起位移。
    final AnimatedModalBarrier barrier = tester.widget<AnimatedModalBarrier>(
      find.byType(AnimatedModalBarrier).last,
    );
    // 进入中遮罩透明度尚未达到最终值。
    final double partialAlpha = barrier.color.value!.a;
    await tester.pump(const Duration(milliseconds: 200));
    expect(barrier.color.value!.a, greaterThan(partialAlpha));
    // 当前表面位置与有动画的辅助导航路径一致。
    final double top = tester.getTopLeft(_surface(_ModalKind.centered)).dy;
    host.navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(barrier.color.value!.a, lessThan(0.42));
    expect(
      tester.getTopLeft(_surface(_ModalKind.centered)).dy,
      greaterThan(top),
    );
    await tester.pumpAndSettle();
  });

  // 当前场景是否允许遮罩和系统返回关闭弹窗。
  for (final bool barrierDismiss in <bool>[true, false]) {
    testWidgets('关闭权限=$barrierDismiss时遮罩与系统返回遵循原约定', (tester) async {
      // 模拟业务提交期间禁止系统返回和遮罩关闭。
      final _ModalHost host = await _pumpHost(tester);
      unawaited(host.open(_ModalKind.centered, canClose: barrierDismiss));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(4, 4));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      if (barrierDismiss) {
        expect(_surface(_ModalKind.centered), findsOneWidget);
        await tester.pumpAndSettle();
        expect(_surface(_ModalKind.centered), findsNothing);
        expect(host.results, <String?>[null]);
      } else {
        expect(_surface(_ModalKind.centered), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(_surface(_ModalKind.centered), findsOneWidget);
        expect(host.results, isEmpty);
        host.navigator.currentState!.pop();
        await tester.pumpAndSettle();
      }
    });
  }

  testWidgets('系统返回播放退出且叠加弹窗不改变底层输入', (tester) async {
    // 输入内容归属于底层页面，弹窗过渡不重建该页面。
    final _ModalHost host = await _pumpHost(tester);
    await tester.enterText(find.byType(TextField), '保留原输入');
    unawaited(host.open(_ModalKind.fullscreen));
    await tester.pumpAndSettle();
    unawaited(host.open(_ModalKind.centered));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(_surface(_ModalKind.centered), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(_surface(_ModalKind.fullscreen), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('保留原输入'), findsOneWidget);
    expect(host.results, <String?>[null, null]);
  });

  testWidgets('键盘占位下弹窗保留避让和取消结果', (tester) async {
    // 键盘已经打开，居中弹窗仍使用原生Dialog避让。
    final _ModalHost host = await _pumpHost(tester, keyboard: 280);
    unawaited(host.open(_ModalKind.centered));
    await tester.pumpAndSettle();
    expect(
      tester.getBottomLeft(_surface(_ModalKind.centered)).dy,
      lessThanOrEqualTo(_viewport.height - 280),
    );
    await tester.tap(find.text('取消弹窗'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_surface(_ModalKind.centered), findsOneWidget);
    await tester.pumpAndSettle();
    expect(host.results, <String?>['cancel']);
  });

  testWidgets('显式动画参数保留且非安卓仍采用原生DialogRoute', (tester) async {
    // 调用方既有动画覆盖不被统一默认值吞掉。
    final _ModalHost host = await _pumpHost(tester);
    unawaited(host.open(_ModalKind.centered, noAnimation: true));
    await tester.pump();
    expect(
      ModalRoute.of(tester.element(_surface(_ModalKind.centered)))!
          .transitionDuration,
      Duration.zero,
    );
    host.navigator.currentState!.pop();
    await tester.pumpAndSettle();
    // Windows继续走原来的原生弹窗及淡入逻辑。
    final _ModalHost desktop = await _pumpHost(
      tester,
      platform: TargetPlatform.windows,
    );
    unawaited(desktop.open(_ModalKind.centered));
    await tester.pumpAndSettle();
    expect(
      ModalRoute.of(tester.element(_surface(_ModalKind.centered))).runtimeType,
      DialogRoute<String>,
    );
    expect(find.byType(OmniModalSlideTransition), findsNothing);
    desktop.navigator.currentState!.pop();
    await tester.pumpAndSettle();
  });
}

/// 可展开面板使用生产表面，其余入口使用测试内容的稳定身份。
Finder _surface(_ModalKind kind) => kind == _ModalKind.expandable
    ? find.byKey(const ValueKey<String>('omni-expandable-sheet-surface'))
    : find.byKey(ValueKey<String>('modal-test-${kind.name}'));

/// 仅持有导航入口和结果，测试不会接管路由动画。
class _ModalHost {
  /// 根导航器用于验证返回值与系统返回。
  final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();

  /// 调用位置与导航覆盖层共享主题及系统偏好。
  late BuildContext context;

  /// 按关闭顺序记录各层返回结果。
  final List<String?> results = <String?>[];

  /// 通过真实组件入口打开不同形态的模态弹窗。
  Future<void> open(
    _ModalKind kind, {
    bool canClose = true,
    bool noAnimation = false,
  }) async {
    // 内容共享按钮与关闭权限，仅布局随弹窗类型变化。
    Widget content(BuildContext context) => PopScope<String>(
      canPop: canClose,
      child: Material(
        key: ValueKey<String>('modal-test-${kind.name}'),
        child: SizedBox(
          width: kind == _ModalKind.centered ? 280 : double.infinity,
          height: kind == _ModalKind.centered
              ? 180
              : kind == _ModalKind.sheet
              ? 260
              : double.infinity,
          child: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).pop('cancel'),
              child: const Text('取消弹窗'),
            ),
          ),
        ),
      ),
    );
    // 每种入口都使用业务实际依赖的共享路由。
    final String? result = await switch (kind) {
      _ModalKind.centered || _ModalKind.fullscreen => showOmniDialog<String>(
        context: context,
        useSafeArea: false,
        fullscreenDialog: kind == _ModalKind.fullscreen,
        barrierDismissible: canClose,
        animationStyle: noAnimation ? AnimationStyle.noAnimation : null,
        builder: (context) => kind == _ModalKind.centered
            ? Dialog(child: content(context))
            : content(context),
      ),
      _ModalKind.sheet => showOmniModalBottomSheet<String>(
        context: context,
        builder: content,
      ),
      _ModalKind.expandable => showOmniExpandableBottomSheet<String>(
        context: context,
        builder: (context) => OmniExpandableBottomSheetScaffold(
          leading: const Text('取消'),
          trailing: const Text('保存'),
          semanticsLabel: '测试面板',
          bodyBuilder: (context, expanded) => const Text('面板正文'),
        ),
      ),
      _ModalKind.sideSheet => showOmniSideSheet<String>(
        context,
        builder: content,
      ),
    };
    results.add(result);
  }
}

/// 将媒体偏好放到根导航之上，覆盖所有真实路由入口。
Future<_ModalHost> _pumpHost(
  WidgetTester tester, {
  bool reduce = false,
  bool accessible = false,
  double keyboard = 0,
  TargetPlatform platform = TargetPlatform.android,
}) async {
  tester.view.physicalSize = _viewport;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // 每次创建独立宿主，底层输入不参与模态内容构建。
  final _ModalHost host = _ModalHost();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: host.navigator,
      theme: AppTheme.build(brightness: Brightness.light)
          .copyWith(platform: platform),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: reduce,
          accessibleNavigation: accessible,
          viewInsets: EdgeInsets.only(bottom: keyboard),
        ),
        child: child!,
      ),
      home: Builder(
        builder: (context) {
          host.context = context;
          return const Scaffold(body: TextField());
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return host;
}
