import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 笔记搜索历史的本机存储键。
const String _noteSearchHistoryPreferenceKey = 'notes.search.history';

/// 搜索历史最多保留的条数。
const int _noteSearchHistoryLimit = 5;

/// 保存当前设备最近提交的笔记搜索词。
class NoteSearchHistory extends Notifier<List<String>> {
  /// 按提交顺序排队写入，避免旧请求覆盖最新历史。
  Future<void> _pendingWrite = Future<void>.value();

  /// 恢复并规范化当前设备的搜索历史。
  @override
  List<String> build() {
    // 当前设备的偏好存储。
    final SharedPreferences preferences = ref.watch(sharedPreferencesProvider);
    return _normalizeHistory(
      preferences.getStringList(_noteSearchHistoryPreferenceKey) ??
          const <String>[],
    );
  }

  /// 记录一次已提交的有效搜索，并将最近使用的搜索词放在首位。
  Future<void> record(String query) async {
    // 去除首尾空白后的搜索词。
    final String trimmedQuery = query.trim();
    if (trimmedQuery.isEmpty) {
      return;
    }
    state = _normalizeHistory(<String>[trimmedQuery, ...state]);
    // 本次提交时的不可变历史快照。
    final List<String> history = state;
    // 在异步写入前获取存储，避免销毁后再读取依赖。
    final SharedPreferences preferences = ref.read(sharedPreferencesProvider);
    _pendingWrite = _pendingWrite.then((_) async {
      try {
        await preferences.setStringList(
          _noteSearchHistoryPreferenceKey,
          history,
        );
      } catch (_) {
        // 存储不可用时保留本会话历史，搜索本身不依赖持久化成功。
      }
    });
    await _pendingWrite;
  }
}

/// 去除空项与大小写重复项，按原始顺序保留最近五条。
List<String> _normalizeHistory(Iterable<String> queries) {
  // 已出现过的大小写无关搜索词。
  final Set<String> seen = <String>{};
  // 按最近使用顺序排列的有效搜索词。
  final List<String> normalized = <String>[];
  // 逐项清理历史，优先保留靠前的拼写形式。
  for (final String query in queries) {
    // 去除首尾空白后的候选项。
    final String trimmedQuery = query.trim();
    if (trimmedQuery.isEmpty || !seen.add(trimmedQuery.toLowerCase())) {
      continue;
    }
    normalized.add(trimmedQuery);
    if (normalized.length == _noteSearchHistoryLimit) {
      break;
    }
  }
  return List<String>.unmodifiable(normalized);
}

/// 笔记搜索历史状态提供者。
final NotifierProvider<NoteSearchHistory, List<String>>
noteSearchHistoryProvider = NotifierProvider<NoteSearchHistory, List<String>>(
  NoteSearchHistory.new,
);
