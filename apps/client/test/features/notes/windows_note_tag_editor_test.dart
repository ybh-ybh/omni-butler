import 'dart:async';

import 'package:drift/drift.dart' hide Column, isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_theme_palette.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/features/notes/data/note_tag_emoji_catalog.dart';
import 'package:omni_butler/features/notes/presentation/windows_note_tag_editor.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 真实仓储与可控制的提交边界共同验证异步表单行为。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('emoji选择、随机和移除只改变草稿，名称及图标统一保存', (tester) async {
    // 默认无图标的真实标签。
    final _EditorFixture fixture = await _mountEditor(tester);
    await _openPicker(tester);
    expect(
      tester
          .widget<OmniButton>(
            find.byKey(const ValueKey('notes-tag-emoji-remove')),
          )
          .onPressed,
      isNull,
    );
    await tester.enterText(
      find.byKey(const ValueKey('notes-tag-emoji-search')),
      'grinning face',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('notes-tag-emoji-😀')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('notes-tag-emoji-search')),
      '猫',
    );
    await tester.pumpAndSettle();
    expect(find.text('没有找到表情'), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('notes-tag-emoji-search')),
      '没有这种表情关键词',
    );
    await tester.pumpAndSettle();
    expect(find.text('没有找到表情'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('notes-tag-emoji-random')));
    await tester.pumpAndSettle();
    expect(_preview(tester), isNotNull);
    // 随机不受空搜索结果影响，而且连续抽取不返回当前值。
    final String? previous = _preview(tester);
    await tester.tap(find.byKey(const ValueKey('notes-tag-emoji-random')));
    await tester.pumpAndSettle();
    expect(_preview(tester), isNot(previous));
    expect(
      find.byKey(const ValueKey('notes-tag-emoji-picker')),
      findsOneWidget,
    );
    expect((await _record(tester, fixture)).iconEmoji, isNull);
    await tester.tap(find.byKey(const ValueKey('notes-tag-emoji-remove')));
    await tester.pumpAndSettle();
    expect(_preview(tester), isNull);
    expect(find.byKey(const ValueKey('notes-tag-emoji-picker')), findsNothing);
    await _openPicker(tester);
    await tester.enterText(
      find.byKey(const ValueKey('notes-tag-emoji-search')),
      '😀',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notes-tag-emoji-😀')));
    await tester.pumpAndSettle();
    expect(_preview(tester), '😀');
    expect(find.byKey(const ValueKey('notes-tag-emoji-picker')), findsNothing);
    expect((await _record(tester, fixture)).iconEmoji, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('notes-tag-name')),
      '项目灵感',
    );
    await tester.tap(find.byKey(const ValueKey('notes-tag-save')));
    await _settleEditor(tester);
    // 名称与完整表情在同一事务中保存。
    final TaxonomyEntry saved = await _record(tester, fixture);
    expect(saved.name, '项目灵感');
    expect(saved.iconEmoji, '😀');
    expect(saved.isPinned, isTrue);
    expect(find.byKey(const ValueKey('notes-tag-editor')), findsNothing);
  });

  testWidgets('Esc逐层返回、外部取消及搜索Enter都不提交，焦点恢复入口', (tester) async {
    // 原始图标在取消后必须保留。
    final _EditorFixture fixture = await _mountEditor(tester, emoji: '🐱');
    await _openPicker(tester);
    await tester.enterText(
      find.byKey(const ValueKey('notes-tag-emoji-search')),
      'cat',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settleEditor(tester);
    expect(fixture.repository.calls, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('notes-tag-emoji-picker')), findsNothing);
    expect(find.byKey(const ValueKey('notes-tag-editor')), findsOneWidget);
    await _openPicker(tester);
    await tester.tap(find.byKey(const ValueKey('notes-tag-emoji-remove')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('notes-tag-name')),
      '未保存名称',
    );
    await tester.tapAt(const Offset(12, 12));
    await _settleEditor(tester);
    expect(find.byKey(const ValueKey('notes-tag-editor')), findsNothing);
    expect((await _record(tester, fixture)).name, '工作');
    expect((await _record(tester, fixture)).iconEmoji, '🐱');
    expect(fixture.triggerFocus.hasFocus, isTrue);
  });

  testWidgets('中文组合输入不误提交，错误保留输入且可通过名称Enter重试', (tester) async {
    // 首次提交模拟失败，确认面板不会丢失未提交图标。
    final _EditorFixture fixture = await _mountEditor(tester);
    await tester.enterText(find.byKey(const ValueKey('notes-tag-name')), '新名称');
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '新名称',
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange(start: 0, end: 3),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settleEditor(tester);
    expect(fixture.repository.calls, 0);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settleEditor(tester);
    expect(fixture.repository.calls, 0);
    // 输入法确认结束后，独立的保存操作才能提交。
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '新名称',
        selection: TextSelection.collapsed(offset: 3),
      ),
    );
    fixture.repository.failNext = true;
    await tester.tap(find.byKey(const ValueKey('notes-tag-save')));
    await _settleEditor(tester);
    expect(find.text('模拟保存失败'), findsOneWidget);
    expect(find.byKey(const ValueKey('notes-tag-name')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('notes-tag-name')));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settleEditor(tester);
    expect((await _record(tester, fixture)).name, '新名称');
    expect(fixture.repository.calls, 2);
    expect(find.byKey(const ValueKey('notes-tag-editor')), findsNothing);
  });

  testWidgets('保存期间阻止重复提交、Esc及外部关闭，完成后退出', (tester) async {
    // 可控延迟位于真正仓储事务之前，重现慢磁盘或锁等待。
    final _EditorFixture fixture = await _mountEditor(tester);
    // 本次提交的释放信号。
    final Completer<void> gate = Completer<void>();
    fixture.repository.gate = gate.future;
    await tester.enterText(
      find.byKey(const ValueKey('notes-tag-name')),
      '慢速保存',
    );
    await tester.tap(find.byKey(const ValueKey('notes-tag-save')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.tapAt(const Offset(12, 12));
    await tester.tap(find.byKey(const ValueKey('notes-tag-save')));
    await tester.pump(const Duration(milliseconds: 250));
    expect(fixture.repository.calls, 1);
    expect(find.byKey(const ValueKey('notes-tag-editor')), findsOneWidget);
    gate.complete();
    await _settleEditor(tester);
    expect((await _record(tester, fixture)).name, '慢速保存');
    expect(find.byKey(const ValueKey('notes-tag-editor')), findsNothing);
  });

  testWidgets('目录加载失败仍能移除图标，恢复资源后可重试', (tester) async {
    await _mountEditor(tester, emoji: '🐱');
    NoteTagEmojiCatalog.resetCacheForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (_) async => null);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler('flutter/assets', null);
      NoteTagEmojiCatalog.resetCacheForTesting();
    });
    await _openPicker(tester);
    expect(find.text('表情加载失败'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('notes-tag-emoji-remove')));
    await tester.pumpAndSettle();
    expect(_preview(tester), isNull);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
    await _openPicker(tester);
    await tester.tap(find.text('重试'));
    await _settleEditor(tester);
    expect(find.text('表情加载失败'), findsNothing);
    expect(find.byKey(const ValueKey('notes-tag-emoji-list')), findsOneWidget);
  });

  testWidgets('浮层打开后缩放窗口会重新避让边缘，放大后回到锚点', (tester) async {
    await _mountEditor(tester);
    await _openPicker(tester);
    tester.view.physicalSize = const Size(360, 300);
    await _settleEditor(tester);
    // 当前窗口中的编辑面板与选择器边界。
    final Rect editor = tester.getRect(
      find.byKey(const ValueKey('notes-tag-editor')),
    );
    // 选择器仍位于名称面板下方，不会被底边裁切。
    final Rect picker = tester.getRect(
      find.byKey(const ValueKey('notes-tag-emoji-picker')),
    );
    expect(editor.left, greaterThanOrEqualTo(8));
    expect(editor.right, lessThanOrEqualTo(352));
    expect(editor.top, greaterThanOrEqualTo(8));
    expect(picker.bottom, lessThanOrEqualTo(292));
    expect(picker.top - editor.bottom, 8);
    tester.view.physicalSize = const Size(900, 700);
    await _settleEditor(tester);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('notes-tag-editor'))),
      const Offset(120, 120),
    );
    expect(tester.takeException(), isNull);
  });

  for (final AppThemePalette palette in AppThemePalette.values) {
    for (final Brightness brightness in Brightness.values) {
      testWidgets('窄窗大字号及右下锚点保持双面板在窗口内：${palette.id}/$brightness', (
        tester,
      ) async {
        // 每种主题使用同一真实表单及完整表情目录。
        await _mountEditor(
          tester,
          size: const Size(360, 500),
          scale: 1.8,
          brightness: brightness,
          palette: palette,
          anchor: const Offset(310, 420),
        );
        await _openPicker(tester);
        // 真实布局边界必须包含两块独立面板及其间距。
        final Rect editor = tester.getRect(
          find.byKey(const ValueKey('notes-tag-editor')),
        );
        // 选择器拥有独立滚动视口，不越过底部边界。
        final Rect picker = tester.getRect(
          find.byKey(const ValueKey('notes-tag-emoji-picker')),
        );
        expect(editor.width, 320);
        expect(editor.left, greaterThanOrEqualTo(8));
        expect(editor.right, lessThanOrEqualTo(352));
        expect(editor.top, greaterThanOrEqualTo(8));
        expect(picker.top - editor.bottom, 8);
        expect(picker.height, lessThanOrEqualTo(320));
        expect(picker.bottom, lessThanOrEqualTo(492));
        expect(
          find.byKey(const ValueKey('notes-tag-emoji-list')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
}

/// 浮层真实依赖及可恢复的入口焦点。
class _EditorFixture {
  /// 集中保存当前测试需要读取的资源。
  const _EditorFixture(
    this.database,
    this.repository,
    this.id,
    this.triggerFocus,
  );

  /// 完整本地 schema 的内存数据库。
  final AppDatabase database;

  /// 仅控制失败和等待，其他校验及写入均使用生产代码。
  final _ControlledRepository repository;

  /// 当前被编辑标签的稳定身份。
  final String id;

  /// 关闭路由后应恢复的键盘入口。
  final FocusNode triggerFocus;
}

/// 可控提交边界避免通过计时猜测慢保存行为。
class _ControlledRepository extends TaxonomyRepository {
  /// 复用真实仓储及事务。
  _ControlledRepository(super.database);

  /// 记录实际进入仓储的提交次数。
  int calls = 0;

  /// 仅下一次提交模拟可恢复错误。
  bool failNext = false;

  /// 可选的提交暂停信号。
  Future<void>? gate;

  /// 在生产事务外提供确定性的等待和失败控制。
  @override
  Future<void> updateNoteTagAppearance(
    String id, {
    Value<String> name = const Value.absent(),
    Value<String?> iconEmoji = const Value.absent(),
  }) async {
    calls++;
    await gate;
    if (failNext) {
      failNext = false;
      throw const FormatException('模拟保存失败');
    }
    await super.updateNoteTagAppearance(id, name: name, iconEmoji: iconEmoji);
  }
}

/// 构造带真实主题和入口锚点的隔离窗口。
Future<_EditorFixture> _mountEditor(
  WidgetTester tester, {
  String? emoji,
  Size size = const Size(800, 600),
  double scale = 1,
  Offset anchor = const Offset(120, 120),
  Brightness brightness = Brightness.light,
  AppThemePalette palette = AppThemePalette.classicBlue,
}) async {
  NoteTagEmojiCatalog.resetCacheForTesting();
  await tester.runAsync(() => NoteTagEmojiCatalog.load());
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // 资源仅在测试期间存在，不接触正式偏好或同步。
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  // 保留真实的保存行为。
  final _ControlledRepository repository = _ControlledRepository(database);
  // 当前测试的稳定标签。
  final TaxonomyEntry tag = (await tester.runAsync(() async {
    await repository.save(
      const TaxonomyDraft(
        module: TaxonomyModule.notes,
        kind: TaxonomyKind.tag,
        name: '工作',
        colorValue: 42,
      ),
    );
    // 查询精确数据，不触发默认标签初始化。
    final TaxonomyEntry created =
        (await database.select(database.taxonomyEntries).get()).single;
    await repository.setPinned(created.id, true);
    await repository.updateNoteTagAppearance(
      created.id,
      iconEmoji: Value(emoji),
    );
    return (await database.select(database.taxonomyEntries).get()).single;
  }))!;
  repository.calls = 0;
  // 根ProviderScope传递到应用内DialogRoute。
  final ProviderContainer container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      taxonomyRepositoryProvider.overrideWithValue(repository),
    ],
  );
  // 键盘入口确保可验证关闭时焦点恢复。
  final FocusNode triggerFocus = FocusNode();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    triggerFocus.dispose();
    await database.close();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.build(
          brightness: brightness,
          palette: palette,
        ).copyWith(platform: TargetPlatform.windows),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: Stack(
            children: [
              Positioned(
                left: anchor.dx,
                top: anchor.dy,
                child: Builder(
                  builder: (context) => OmniIconButton(
                    key: const ValueKey('open-tag-editor'),
                    tooltip: '标签操作',
                    focusNode: triggerFocus,
                    icon: const Icon(Icons.more_horiz),
                    onPressed: () => unawaited(
                      showWindowsNoteTagEditor(
                        context: context,
                        anchorContext: context,
                        tag: tag,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  triggerFocus.requestFocus();
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('open-tag-editor')));
  await _settleEditor(tester);
  return _EditorFixture(database, repository, tag.id, triggerFocus);
}

/// 刷新真实Drift事件，不在提交等待中使用pumpAndSettle。
Future<void> _settleEditor(WidgetTester tester) async {
  await tester.pump();
  // 资源读取和大JSON的后台解码之间也需要刷新fake async微任务。
  for (int index = 0; index < 5; index++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

/// 打开预先加载的离线表情目录。
Future<void> _openPicker(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('notes-tag-icon-button')));
  await _settleEditor(tester);
}

/// 读取编辑面板内的当前草稿图标，不把其他网格候选算入。
String? _preview(WidgetTester tester) => tester
    .widget<NoteTagIcon>(
      find.descendant(
        of: find.byKey(const ValueKey('notes-tag-icon-button')),
        matching: find.byType(NoteTagIcon),
      ),
    )
    .emoji;

/// 直接读取真实数据以区分草稿预览与持久化结果。
Future<TaxonomyEntry> _record(
  WidgetTester tester,
  _EditorFixture fixture,
) async => (await tester.runAsync(
  () => (fixture.database.select(
    fixture.database.taxonomyEntries,
  )..where((table) => table.id.equals(fixture.id))).getSingle(),
))!;
