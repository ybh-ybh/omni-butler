import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/features/notes/data/note_search_history.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证笔记历史的归一化、提交顺序、持久化和失败隔离。
void main() {
  test('清空与提交串行持久化，旧写入不会复活历史', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 隔离存储和历史服务。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 当前测试容器模拟一次设备会话。
    final ProviderContainer container = _container(preferences);
    // 所有操作立即排队，验证清空不会被前面的提交覆盖。
    final NoteSearchHistory history = container.read(
      noteSearchHistoryProvider.notifier,
    );
    await Future.wait([
      history.record('旧词'),
      history.record('新词'),
      history.clear(),
    ]);
    expect(container.read(noteSearchHistoryProvider), isEmpty);
    expect(preferences.getStringList('notes.search.history'), isEmpty);
    // 新容器恢复时同样保持清空。
    final ProviderContainer restored = _container(preferences);
    expect(restored.read(noteSearchHistoryProvider), isEmpty);
    await Future.wait([
      history.record('先提交'),
      history.clear(),
      history.record('清空后提交'),
    ]);
    expect(container.read(noteSearchHistoryProvider), ['清空后提交']);
    expect(preferences.getStringList('notes.search.history'), ['清空后提交']);
  });

  test('清空持久化失败仍可继续提交历史', () async {
    // 写入失败不能打断后续队列。
    final _FailingPreferences preferences = _FailingPreferences(
      throwOnWrite: true,
    );
    // 当前测试持有的独立容器。
    final ProviderContainer container = _container(preferences);
    // 失败后仍可复用的历史控制器。
    final NoteSearchHistory history = container.read(
      noteSearchHistoryProvider.notifier,
    );
    await history.record('旧词');
    await expectLater(history.clear(), completes);
    expect(container.read(noteSearchHistoryProvider), isEmpty);
    await history.record('新词');
    expect(container.read(noteSearchHistoryProvider), ['新词']);
    expect(preferences.writeAttempts, 3);
  });

  test('空白搜索不产生历史和存储写入', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 当前设备的测试存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 显式注入测试存储的容器。
    final ProviderContainer container = _container(preferences);
    await container.read(noteSearchHistoryProvider.notifier).record(' \n\t ');
    expect(container.read(noteSearchHistoryProvider), isEmpty);
    expect(preferences.containsKey('notes.search.history'), isFalse);
  });

  test('恢复时清理空白和重复项并最多保留五条', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'notes.search.history': <String>[
        '  Alpha ',
        'alpha',
        ' ',
        'Beta',
        ' Gamma ',
        'Delta',
        'Epsilon',
        'Zeta',
      ],
    });
    // 当前设备的测试存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 显式注入测试存储的容器。
    final ProviderContainer container = _container(preferences);
    expect(container.read(noteSearchHistoryProvider), <String>[
      'Alpha',
      'Beta',
      'Gamma',
      'Delta',
      'Epsilon',
    ]);
  });

  test('提交时去掉首尾空白且重复搜索移动到首位', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 当前设备的测试存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 显式注入测试存储的容器。
    final ProviderContainer container = _container(preferences);
    // 笔记历史控制器。
    final NoteSearchHistory history = container.read(
      noteSearchHistoryProvider.notifier,
    );
    await history.record('  Alpha  ');
    await history.record('项目规划');
    await history.record(' ALPHA ');
    expect(container.read(noteSearchHistoryProvider), <String>[
      'ALPHA',
      '项目规划',
    ]);
    expect(preferences.getStringList('notes.search.history'), <String>[
      'ALPHA',
      '项目规划',
    ]);
    // 新容器模拟重新打开笔记页面后恢复历史。
    final ProviderContainer restored = _container(preferences);
    expect(
      restored.read(noteSearchHistoryProvider),
      container.read(noteSearchHistoryProvider),
    );
  });

  test('快速连续提交保留最近五条并持久化最后状态', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 当前设备的测试存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 显式注入测试存储的容器。
    final ProviderContainer container = _container(preferences);
    // 笔记历史控制器。
    final NoteSearchHistory history = container.read(
      noteSearchHistoryProvider.notifier,
    );
    await Future.wait(<Future<void>>[
      history.record('一'),
      history.record('二'),
      history.record('三'),
      history.record('四'),
      history.record('五'),
      history.record('六'),
    ]);
    expect(container.read(noteSearchHistoryProvider), <String>[
      '六',
      '五',
      '四',
      '三',
      '二',
    ]);
    expect(
      preferences.getStringList('notes.search.history'),
      container.read(noteSearchHistoryProvider),
    );
  });

  test('存储返回失败时仍保留本会话历史且搜索不抛异常', () async {
    // 模拟本机偏好写入失败的存储。
    final _FailingPreferences preferences = _FailingPreferences();
    // 显式注入失败存储的容器。
    final ProviderContainer container = _container(preferences);
    await expectLater(
      container.read(noteSearchHistoryProvider.notifier).record('项目规划'),
      completes,
    );
    expect(container.read(noteSearchHistoryProvider), <String>['项目规划']);
  });

  test('存储抛异常后继续记录搜索且队列不会失效', () async {
    // 模拟本机偏好写入抛异常的存储。
    final _FailingPreferences preferences = _FailingPreferences(
      throwOnWrite: true,
    );
    // 显式注入失败存储的容器。
    final ProviderContainer container = _container(preferences);
    // 笔记历史控制器。
    final NoteSearchHistory history = container.read(
      noteSearchHistoryProvider.notifier,
    );
    await expectLater(history.record('项目规划'), completes);
    await expectLater(history.record('会议纪要'), completes);
    expect(container.read(noteSearchHistoryProvider), <String>['会议纪要', '项目规划']);
    expect(preferences.writeAttempts, 2);
  });
}

/// 创建自动清理且只访问测试存储的依赖容器。
ProviderContainer _container(SharedPreferences preferences) {
  // 显式注入本机存储的 Riverpod 容器。
  final ProviderContainer container = ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
  );
  addTearDown(container.dispose);
  return container;
}

/// 隔离本机存储的两种失败行为，避免测试操作真实用户数据。
class _FailingPreferences extends Fake implements SharedPreferences {
  /// 是否通过异常报告写入失败。
  final bool throwOnWrite;

  /// 收到的历史持久化请求次数。
  int writeAttempts = 0;

  /// 创建按指定方式失败的存储。
  _FailingPreferences({this.throwOnWrite = false});

  /// 模拟尚未保存过搜索历史。
  @override
  List<String>? getStringList(String key) => null;

  /// 模拟插件返回失败或抛出异常。
  @override
  Future<bool> setStringList(String key, List<String> value) async {
    writeAttempts += 1;
    if (throwOnWrite) {
      throw StateError('测试模拟存储不可用');
    }
    return false;
  }
}
