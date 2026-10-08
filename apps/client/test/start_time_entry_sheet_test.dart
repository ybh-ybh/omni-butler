import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/features/timeline/data/time_entry_repository.dart';
import 'package:omni_butler/features/timeline/presentation/timeline_page.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 固定当前时刻，验证开始时间保持原有五分钟取整。
final DateTime _now = DateTime(2026, 10, 8, 10, 23);

/// 顶部独立拖拽入口。
final Finder _handle = find.byKey(
  const ValueKey<String>('omni-expandable-sheet-handle'),
);

/// 当前实际面板表面。
final Finder _surface = find.byKey(
  const ValueKey<String>('omni-expandable-sheet-surface'),
);

/// 验证安卓开始记录的真实路由、输入、手势与持久化。
void main() {
  setUpAll(() async {
    if (Platform.environment['OMNI_START_PREVIEW_DIR'] == null) return;
    // 使用真实中文字体核对预览，不将字体资产加入仓库。
    final ByteData font = ByteData.sublistView(
      await File('C:/Windows/Fonts/msyh.ttc').readAsBytes(),
    );
    for (final String family in <String>[
      'Ahem',
      'Microsoft YaHei UI',
      'Microsoft YaHei',
      'Roboto',
    ]) {
      // 当前生产字体名称对应的中文测试字形。
      final FontLoader loader = FontLoader(family);
      loader.addFont(Future<ByteData>.value(font));
      await loader.load();
    }
    // 预览中的日期、时刻和下拉图标使用 SDK 正式字体。
    final FontLoader icons = FontLoader('MaterialIcons');
    icons.addFont(
      File(
        'D:/program/code/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
      ).readAsBytes().then(ByteData.sublistView),
    );
    await icons.load();
  });

  testWidgets('半屏只显示两个字段并能留空开始，操作固定在顶部', (WidgetTester tester) async {
    // 真实入口与隔离数据库。
    final _Fixture fixture = await _pumpStart(tester);
    try {
      expect(tester.getSize(_surface).height, closeTo(422, 0.1));
      expect(tester.getRect(_surface).bottom, closeTo(844, 0.1));
      expect(find.byType(Dialog), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('time-entry-activity')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('time-entry-category')),
        findsOneWidget,
      );
      expect(find.text('开始时间'), findsNothing);
      expect(
        tester
            .widget<InputDecorator>(
              find.descendant(
                of: find.byKey(const ValueKey<String>('time-entry-category')),
                matching: find.byType(InputDecorator),
              ),
            )
            .decoration
            .labelText,
        isNull,
      );
      expect(
        find.byKey(const ValueKey<String>('time-entry-notes')),
        findsNothing,
      );
      expect(tester.testTextInput.isVisible, isFalse);
      expect(tester.getSize(_handle).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(_submit).height, 48);
      expect(
        tester
            .getSize(
              find.descendant(of: _submit, matching: find.byType(Material)),
            )
            .height,
        32,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.descendant(of: _submit, matching: find.byType(FilledButton)),
            )
            .style!
            .textStyle!
            .resolve(<WidgetState>{})!
            .fontSize,
        14,
      );
      expect(
        tester.getCenter(find.text('取消')).dx,
        lessThan(tester.getCenter(_submit).dx),
      );
      expect(
        tester.getCenter(_submit).dy,
        lessThan(tester.getTopLeft(_activity).dy),
      );
      await _capture(tester, 'android-half');
      await tester.tap(_submit);
      await tester.pumpAndSettle();
      // 空活动仍保存为进行中记录，默认时刻不随呈现方式改变。
      final TimeEntryRecord saved = await fixture.record(tester);
      expect(saved.startedAt, DateTime(2026, 10, 8, 10, 20));
      expect(saved.endedAt, isNull);
      expect(saved.activity, isNull);
      expect(_surface, findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets('真实拖拽跟手展开和收回，所有字段值保持并保存', (WidgetTester tester) async {
    // 持有真实仓储和控制器的开始面板。
    final _Fixture fixture = await _pumpStart(tester);
    try {
      await tester.enterText(_activity, '阅读项目源码');
      await tester.tap(
        find.byKey(const ValueKey<String>('time-entry-category')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, '学习'));
      await tester.pumpAndSettle();
      // 在离手前检查实际高度，避免只验证最终状态。
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(_handle),
      );
      await gesture.moveBy(
        const Offset(0, -120),
        timeStamp: const Duration(milliseconds: 160),
      );
      await tester.pump();
      expect(tester.getSize(_surface).height, greaterThan(450));
      expect(find.text('开始时间'), findsNothing);
      await gesture.moveBy(
        const Offset(0, -120),
        timeStamp: const Duration(milliseconds: 240),
      );
      await gesture.up(timeStamp: const Duration(milliseconds: 280));
      await tester.pumpAndSettle();
      expect(tester.getSize(_surface).height, closeTo(820, 0.1));
      expect(find.text('开始时间'), findsOneWidget);
      expect(find.text('详细描述（可选）'), findsOneWidget);
      // 直接通过现有日期/时刻选择回调验证同一绝对时间状态。
      final OmniTimePickerButton clock = tester.widget<OmniTimePickerButton>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('time-entry-start-time')),
          matching: find.byType(OmniTimePickerButton),
        ),
      );
      clock.onChanged!(const TimeOfDay(hour: 10, minute: 5));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('time-entry-notes')),
        '整理面板交互与时间语义',
      );
      await _capture(tester, 'android-full');
      await tester.drag(_handle, const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(tester.getSize(_surface).height, closeTo(422, 0.1));
      expect(find.text('开始时间'), findsNothing);
      expect(_activityText(tester), '阅读项目源码');
      expect(find.text('学习'), findsOneWidget);
      await tester.tap(_handle);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<OmniTextField>(
              find.byKey(const ValueKey<String>('time-entry-notes')),
            )
            .controller!
            .text,
        '整理面板交互与时间语义',
      );
      expect(find.text('10:05'), findsOneWidget);
      // 回到半屏提交也必须保存之前修改的高级字段。
      await tester.tap(_handle);
      await tester.pumpAndSettle();
      await tester.tap(_submit);
      await tester.pumpAndSettle();
      // 仓储中实际落下的唯一记录。
      final TimeEntryRecord saved = await fixture.record(tester);
      expect(saved.activity, '阅读项目源码');
      expect(saved.category, '学习');
      expect(saved.notes, '整理面板交互与时间语义');
      expect(saved.startedAt, DateTime(2026, 10, 8, 10, 5));
      expect(saved.endedAt, isNull);
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets('吸附中可反向接管且继续下拉不会关闭', (WidgetTester tester) async {
    // 可被连续真实手势接管的面板。
    final _Fixture fixture = await _pumpStart(tester);
    try {
      await tester.tap(_handle);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));
      // 接管前的实际显示高度。
      final double height = tester.getSize(_surface).height;
      expect(height, greaterThan(422));
      expect(height, lessThan(820));
      // 从当前显示位置拖回半屏，而非从动画目标重置。
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(_handle),
      );
      await gesture.moveBy(
        const Offset(0, 50),
        timeStamp: const Duration(milliseconds: 80),
      );
      await tester.pump();
      expect(tester.getSize(_surface).height, lessThan(height));
      await gesture.moveBy(
        const Offset(0, 180),
        timeStamp: const Duration(milliseconds: 160),
      );
      await gesture.up(timeStamp: const Duration(milliseconds: 180));
      await tester.pumpAndSettle();
      expect(tester.getSize(_surface).height, closeTo(422, 0.1));
      expect(find.text('开始时间'), findsNothing);
      await tester.drag(_handle, const Offset(0, 260));
      await tester.pumpAndSettle();
      expect(_surface, findsOneWidget);
      expect(tester.getSize(_surface).height, closeTo(422, 0.1));
    } finally {
      await fixture.dispose(tester);
    }
  });

  for (final (Size, double, Brightness) scenario
      in <(Size, double, Brightness)>[
        (const Size(390, 844), 2, Brightness.light),
        (const Size(844, 390), 1, Brightness.dark),
      ]) {
    testWidgets('键盘和正文滚动不展开，支持 ${scenario.$1} 与 ${scenario.$2} 倍字号', (
      WidgetTester tester,
    ) async {
      // 以实际安全区和文字缩放构建面板。
      final _Fixture fixture = await _pumpStart(
        tester,
        size: scenario.$1,
        scale: scenario.$2,
        brightness: scenario.$3,
      );
      try {
        await tester.enterText(_activity, '键盘输入');
        fixture.media.value = fixture.media.value.copyWith(
          viewInsets: const EdgeInsets.only(bottom: 180),
        );
        await tester.pumpAndSettle();
        expect(find.text('开始时间'), findsNothing);
        expect(
          tester.getRect(_surface).bottom,
          closeTo(scenario.$1.height - 180, 0.1),
        );
        // 正文可以滚动而面板高度保持不变。
        final double height = tester.getSize(_surface).height;
        await tester.drag(
          find.byKey(const ValueKey<String>('omni-expandable-sheet-body')),
          const Offset(0, -120),
        );
        await tester.pumpAndSettle();
        expect(tester.getSize(_surface).height, closeTo(height, 0.1));
        expect(find.text('开始时间'), findsNothing);
        expect(
          tester.getRect(_submit).bottom,
          lessThan(scenario.$1.height - 180),
        );
        await _capture(
          tester,
          scenario.$3 == Brightness.dark
              ? 'android-landscape-keyboard-dark'
              : 'android-large-text-keyboard',
        );
        // 系统返回先解除输入焦点，不退出本次草稿。
        await tester.binding.handlePopRoute();
        await tester.pump();
        expect(_surface, findsOneWidget);
        expect(
          tester
              .widget<EditableText>(
                find.descendant(
                  of: _activity,
                  matching: find.byType(EditableText),
                ),
              )
              .focusNode
              .hasFocus,
          isFalse,
        );
        expect(_activityText(tester), '键盘输入');
        fixture.media.value = fixture.media.value.copyWith(
          viewInsets: EdgeInsets.zero,
        );
        await tester.pumpAndSettle();
        await tester.tap(_handle);
        await tester.pumpAndSettle();
        expect(find.text('开始时间'), findsOneWidget);
        fixture.media.value = fixture.media.value.copyWith(
          viewInsets: const EdgeInsets.only(bottom: 180),
        );
        await tester.pumpAndSettle();
        expect(find.text('开始时间'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    });
  }

  testWidgets('打开期间旋转保持全屏宽度、字段与输入状态', (WidgetTester tester) async {
    // 先以竖屏打开真实模态路由，再改变已打开面板的视口。
    final _Fixture fixture = await _pumpStart(tester);
    try {
      await tester.enterText(_activity, '旋转后保留');
      await tester.tap(_handle);
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(844, 390);
      fixture.media.value = fixture.media.value.copyWith(
        size: const Size(844, 390),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(_surface).width, closeTo(844, 0.1));
      expect(tester.getSize(_surface).height, closeTo(366, 0.1));
      expect(_activityText(tester), '旋转后保留');
      expect(find.text('开始时间'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets('减少动画和读屏语义支持立即展开收起', (WidgetTester tester) async {
    // 动画关闭时仍保留可操作的横线和输入。
    final _Fixture fixture = await _pumpStart(tester, reduceMotion: true);
    // 完整语义树用于验证读屏提供的替代操作。
    final SemanticsHandle semantics = tester.ensureSemantics();
    try {
      expect(find.bySemanticsLabel('展开开始记录面板'), findsOneWidget);
      await tester.tap(_handle);
      await tester.pump();
      expect(tester.getSize(_surface).height, closeTo(820, 0.1));
      expect(find.bySemanticsLabel('收起开始记录面板'), findsOneWidget);
      await tester.tap(_handle);
      await tester.pump();
      expect(find.text('开始时间'), findsNothing);
      expect(tester.getSize(_surface).height, closeTo(422, 0.1));
    } finally {
      semantics.dispose();
      await fixture.dispose(tester);
    }
  });

  testWidgets('提交期间锁定关闭与拖拽并防重，失败保留输入后可重试', (WidgetTester tester) async {
    // 控制真实持久化前的等待与一次失败。
    final _Fixture fixture = await _pumpStart(tester, controlledSave: true);
    try {
      await tester.enterText(_activity, '提交失败也保留');
      await tester.tap(_submit);
      await tester.pump();
      await tester.tap(_submit);
      await tester.pump();
      expect(fixture.repository.calls, 1);
      expect(tester.widget<OmniButton>(_submit).loading, isTrue);
      expect(find.text('开始'), findsOneWidget);
      await tester.tapAt(const Offset(20, 120));
      await tester.binding.handlePopRoute();
      await tester.drag(_handle, const Offset(0, -200));
      await tester.pump();
      expect(_surface, findsOneWidget);
      expect(find.text('开始时间'), findsNothing);
      fixture.repository.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('开始记录失败，请重试'), findsOneWidget);
      expect(_activityText(tester), '提交失败也保留');
      await tester.tap(_submit);
      await tester.pumpAndSettle();
      expect(fixture.repository.calls, 2);
      expect((await fixture.record(tester)).activity, '提交失败也保留');
      expect(_surface, findsNothing);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets('进行中冲突保留草稿且不写入重复记录', (WidgetTester tester) async {
    // 原有进行中记录由真实仓储写入。
    final _Fixture fixture = await _pumpStart(tester, ongoing: true);
    try {
      await tester.enterText(_activity, '冲突草稿');
      await tester.tap(_submit);
      await tester.pumpAndSettle();
      expect(_surface, findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('time-entry-save-error')),
        findsOneWidget,
      );
      expect(_activityText(tester), '冲突草稿');
      expect((await fixture.record(tester)).activity, '已有记录');
    } finally {
      await fixture.dispose(tester);
    }
  });

  for (final String close in <String>['取消', '遮罩', '返回']) {
    testWidgets('$close 关闭丢弃草稿，再次打开恢复初始半屏', (WidgetTester tester) async {
      // 每次关闭方式都使用同一公开入口和内存数据库。
      final _Fixture fixture = await _pumpStart(tester);
      try {
        await tester.enterText(_activity, '未保存草稿');
        await tester.tap(_handle);
        await tester.pumpAndSettle();
        if (close == '取消') {
          await tester.tap(find.text('取消'));
        } else if (close == '返回') {
          await tester.binding.handlePopRoute();
        } else {
          // 全屏无外部遮罩可点，收起后点面板外部。
          await tester.tap(_handle);
          await tester.pumpAndSettle();
          fixture.media.value = fixture.media.value.copyWith(
            viewInsets: const EdgeInsets.only(bottom: 180),
          );
          await tester.pumpAndSettle();
          await tester.tapAt(const Offset(20, 120));
        }
        await tester.pumpAndSettle();
        expect(_surface, findsNothing);
        expect(
          await tester.runAsync(
            () => fixture.database.select(fixture.database.timeEntries).get(),
          ),
          isEmpty,
        );
        fixture.media.value = fixture.media.value.copyWith(
          viewInsets: EdgeInsets.zero,
        );
        await tester.tap(find.text('打开开始'));
        await tester.pumpAndSettle();
        expect(tester.getSize(_surface).height, closeTo(422, 0.1));
        expect(_activityText(tester), isEmpty);
        expect(find.text('开始时间'), findsNothing);
      } finally {
        await fixture.dispose(tester);
      }
    });
  }

  testWidgets('Windows 开始记录保持居中完整表单和原操作名称', (WidgetTester tester) async {
    // 非安卓平台继续走原有 DialogRoute。
    final _Fixture fixture = await _pumpStart(
      tester,
      platform: TargetPlatform.windows,
    );
    try {
      expect(find.byType(Dialog), findsOneWidget);
      expect(_surface, findsNothing);
      expect(find.text('开始时间'), findsOneWidget);
      expect(find.text('详细描述（可选）'), findsOneWidget);
      expect(find.widgetWithText(OmniButton, '开始记录'), findsOneWidget);
      await tester.tap(find.widgetWithText(OmniButton, '开始记录'));
      await tester.pumpAndSettle();
      expect((await fixture.record(tester)).endedAt, isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });
}

/// 当前活动名称输入。
final Finder _activity = find.byKey(
  const ValueKey<String>('time-entry-activity'),
);

/// 面板右上角的提交操作。
final Finder _submit = find.byKey(
  const ValueKey<String>('time-entry-start-submit'),
);

/// 读取业务控制器的当前值，避免中文测试字体影响文本定位。
String _activityText(WidgetTester tester) =>
    tester.widget<OmniTextFormField>(_activity).controller!.text;

/// 使用正式表单和内存依赖打开指定平台的开始记录。
Future<_Fixture> _pumpStart(
  WidgetTester tester, {
  TargetPlatform platform = TargetPlatform.android,
  Size size = const Size(390, 844),
  double scale = 1,
  Brightness brightness = Brightness.light,
  bool reduceMotion = false,
  bool controlledSave = false,
  bool ongoing = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // 只写测试内存数据库。
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  // 保持生产保存行为，仅特定用例控制首次提交。
  final _SaveRepository repository = _SaveRepository(database, controlledSave);
  if (ongoing) {
    await tester.runAsync(
      () => TimeEntryRepository(database).save(
        TimeEntryDraft(startedAt: DateTime(2026, 10, 8, 9), activity: '已有记录'),
      ),
    );
  }
  await tester.runAsync(
    () =>
        TaxonomyRepository(database)
            .watch(module: TaxonomyModule.timeline, kind: TaxonomyKind.category)
            .first,
  );
  // 隔离生产同步、通知和宿主初始化。
  final ProviderContainer container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      nowProvider.overrideWithValue(_now),
      timeEntryRepositoryProvider.overrideWithValue(repository),
    ],
  );
  // 可动态改变的系统栏、键盘和字号参数。
  final ValueNotifier<MediaQueryData> media = ValueNotifier<MediaQueryData>(
    MediaQueryData(
      size: size,
      padding: const EdgeInsets.only(top: 24, bottom: 24),
      textScaler: TextScaler.linear(scale),
      disableAnimations: reduceMotion,
    ),
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: const ValueKey<String>('start-sheet-preview'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.build(brightness: brightness)
              .copyWith(platform: platform),
          builder: (BuildContext context, Widget? child) =>
              ValueListenableBuilder<MediaQueryData>(
                valueListenable: media,
                builder: (
                  BuildContext context,
                  MediaQueryData data,
                  Widget? _,
                ) => MediaQuery(data: data, child: child!),
              ),
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => Center(
                child: OmniButton(
                  label: '打开开始',
                  onPressed: () => showStartTimeEntryDialog(context, day: _now),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开开始'));
  await tester.pumpAndSettle();
  return _Fixture(database, container, media, repository);
}

/// 按需输出加载真实中文字体的整屏预览。
Future<void> _capture(WidgetTester tester, String name) async {
  // 显式开启预览时才生成本地图片。
  final String? directory = Platform.environment['OMNI_START_PREVIEW_DIR'];
  if (directory == null) return;
  await tester.pump();
  // 当前应用渲染边界。
  final RenderRepaintBoundary boundary = tester
      .renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey<String>('start-sheet-preview')),
      );
  await tester.runAsync(() async {
    // 捕获真实渲染结果，保存后及时释放像素。
    final ui.Image image = await boundary.toImage();
    // PNG 编码后的字节数据。
    final ByteData bytes = (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!;
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png').writeAsBytes(bytes.buffer.asUint8List());
    image.dispose();
  });
}

/// 控制一次延迟/失败，并复用真实数据库保存。
class _SaveRepository extends TimeEntryRepository {
  /// 第一次提交等待的闸门。
  final Completer<void>? gate;

  /// 实际收到的提交次数。
  int calls = 0;

  /// 创建仅改变指定测试时序的仓储。
  _SaveRepository(super.database, bool controlled)
    : gate = controlled ? Completer<void>() : null;

  /// 首次受控提交失败，之后按真实规则保存。
  @override
  Future<void> save(TimeEntryDraft draft) async {
    calls += 1;
    if (gate != null && calls == 1) {
      await gate!.future;
      throw StateError('测试持久化失败');
    }
    await super.save(draft);
  }
}

/// 一项用例所持有的隔离资源。
class _Fixture {
  /// 当前内存数据库。
  final AppDatabase database;

  /// 当前依赖容器。
  final ProviderContainer container;

  /// 可动态变化的系统媒体参数。
  final ValueNotifier<MediaQueryData> media;

  /// 可控制提交时序的真实仓储。
  final _SaveRepository repository;

  /// 组合测试所需的资源。
  const _Fixture(this.database, this.container, this.media, this.repository);

  /// 通过真实异步读取验证落库结果。
  Future<TimeEntryRecord> record(WidgetTester tester) async => (await tester
      .runAsync(() => database.select(database.timeEntries).getSingle()))!;

  /// 先卸载订阅者，再排空并关闭内存数据库。
  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    media.dispose();
    await tester.runAsync(database.close);
  }
}
