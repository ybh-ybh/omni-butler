import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/features/assistant/data/assistant_cache.dart';
import 'package:omni_butler/features/assistant/data/assistant_chat_controller.dart';
import 'package:omni_butler/features/assistant/data/assistant_repository.dart';

/// 可撤销的合成认证边界，不读取设备凭据。
class _Auth implements AuthRepository {
  /// 推进此代次模拟换账号或服务器。
  int generation = 1;

  /// 当前会话代次。
  @override
  int get sessionGeneration => generation;

  /// 其他认证操作不属于本测试。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 网络边界记录业务保存，不把请求改写为AI对话。
class _Repository extends AssistantRepository {
  /// 所有实际请求及固定正文。
  final List<({String method, String path, Object? data})> calls = [];

  /// 模拟服务器已经提交但响应丢失。
  bool loseResponse = false;

  /// 明确拒绝或旧路由错误。
  AssistantApiFailure? failure;

  /// 受控迟到响应。
  Completer<Map<String, dynamic>>? delayed;

  /// 同一消息的首次保存回执。
  final Map<String, dynamic> receipt = <String, dynamic>{
    'noteId': 'saved-note',
    'savedAt': '2026-10-25T02:00:00Z',
  };

  /// 创建固定来源仓储。
  _Repository(super.auth);

  /// 只模拟业务接口和恢复初始化使用的只读接口。
  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Object? data,
  }) async {
    calls.add((method: method, path: path, data: data));
    if (path.endsWith('/note')) {
      if (failure != null) throw failure!;
      if (delayed != null) return delayed!.future;
      if (loseResponse) throw const AssistantApiFailure('连接中断', null);
      return receipt;
    }
    if (path == '/conversations') return <String, dynamic>{'items': <Object>[]};
    return <String, dynamic>{};
  }
}

/// 合成回答含完整Markdown，不依赖本机业务数据库。
const Map<String, dynamic> _answer = <String, dynamic>{
  'id': 'answer',
  'role': 'assistant',
  'content': '**重点**\n\n- 完成网站\n- 复核排版',
  'createdAt': '2026-10-25T01:00:00Z',
};

/// 测试清理等待控制器的顺序缓存写入完成。
Future<void> _close(AssistantChatController chat, AssistantCache cache) async {
  chat.dispose();
  await Future<void>.delayed(const Duration(milliseconds: 40));
  await cache.close();
}

/// 创建离线业务数据独立的真实控制器。
AssistantChatController _chat(_Repository repository, AssistantCache cache) =>
    AssistantChatController(
        repository: repository,
        cache: cache,
        scope: 'fixed-scope',
        catchUp: () async {},
      )
      ..conversationId = 'conversation'
      ..messages = <Map<String, dynamic>>[Map<String, dynamic>.of(_answer)]
      ..draft = '未发送的草稿'
      ..run = <String, dynamic>{
        'id': 'run',
        'status': 'succeeded',
        'elapsedMs': 9000,
      };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('直接保存消息身份，保持正文草稿任务及计时并拒绝重复点击', () async {
    // 保存中的服务端响应主动挂起。
    final _Repository repository = _Repository(_Auth())
      ..delayed = Completer<Map<String, dynamic>>();
    // 缓存只使用内存。
    final AssistantCache cache = AssistantCache.forTesting(
      NativeDatabase.memory(),
    );
    // 页面状态由真实控制器维护。
    final AssistantChatController chat = _chat(repository, cache);
    addTearDown(() => _close(chat, cache));
    // 同一按键连点不能并发提交。
    final Future<void> first = chat.saveNote('answer');
    await chat.saveNote('answer');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(chat.savingNote('answer'), isTrue);
    expect(repository.calls, hasLength(1));
    expect(repository.calls.single.path, '/messages/answer/note');
    expect(repository.calls.single.data, isNull);
    expect(chat.draft, '未发送的草稿');
    expect(chat.pending, isNull);
    expect(chat.busy, isFalse);
    expect(chat.run?['elapsedMs'], 9000);
    repository.delayed!.complete(repository.receipt);
    await first;
    expect(chat.savedNote('answer')?['noteId'], 'saved-note');
    await chat.saveNote('answer');
    expect(repository.calls, hasLength(1));
    expect(chat.messages.single['content'], _answer['content']);
  });

  test('未知结果与重启恢复始终重试相同消息接口，成功状态持久化', () async {
    // 模拟后端提交成功但客户端未获得回执。
    final _Repository repository = _Repository(_Auth())..loseResponse = true;
    // 多个控制器共用该数据源缓存，模拟重启。
    final AssistantCache cache = AssistantCache.forTesting(
      NativeDatabase.memory(),
    );
    // 第一次保存保留消息身份而不创建AI任务。
    final AssistantChatController first = _chat(repository, cache);
    await first.saveNote('answer');
    expect(first.noteSaveError('answer'), contains('尚未确认'));
    first.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    // 恢复时先读取缓存，不允许自动再发起保存。
    final AssistantChatController restored = AssistantChatController(
      repository: null,
      cache: cache,
      scope: 'fixed-scope',
      catchUp: () async {},
    );
    await restored.initialize();
    expect(restored.noteSaveError('answer'), contains('尚未确认'));
    expect(
      repository.calls.where((call) => call.path.endsWith('/note')),
      hasLength(1),
    );
    restored.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    repository.loseResponse = false;
    // 用户恢复连接后显式确认同一保存。
    final AssistantChatController next = _chat(repository, cache);
    await next.saveNote('answer');
    expect(next.savedNote('answer')?['noteId'], 'saved-note');
    next.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    // 成功回执作为显示事实保留。
    final AssistantChatController saved = AssistantChatController(
      repository: null,
      cache: cache,
      scope: 'fixed-scope',
      catchUp: () async {},
    );
    await saved.initialize();
    expect(saved.savedNote('answer')?['noteId'], 'saved-note');
    expect(saved.noteSaveError('answer'), isNull);
    expect(
      repository.calls.map((call) => call.path),
      everyElement('/messages/answer/note'),
    );
    await _close(saved, cache);
  });

  test('另一设备保存的历史消息恢复已保存标记，不再次写入', () async {
    // 服务器消息携带正式保存事实。
    final _Repository repository = _Repository(_Auth());
    // 独立内存缓存。
    final AssistantCache cache = AssistantCache.forTesting(
      NativeDatabase.memory(),
    );
    // 只有服务器事实才能形成已保存展示。
    final AssistantChatController chat = _chat(repository, cache)
      ..messages = <Map<String, dynamic>>[
        <String, dynamic>{..._answer, 'savedNote': repository.receipt},
      ];
    addTearDown(() => _close(chat, cache));
    await chat.saveNote('answer');
    expect(chat.savedNote('answer')?['noteId'], 'saved-note');
    expect(repository.calls, isEmpty);
  });

  test('旧服务器明确提示升级，不生成AI消息或更改草稿', () async {
    // Nest旧接口的默认404形状。
    final _Repository repository = _Repository(_Auth())
      ..failure = const AssistantApiFailure(
        'Cannot POST /assistant/messages/answer/note',
        404,
      );
    // 测试缓存不落到用户目录。
    final AssistantCache cache = AssistantCache.forTesting(
      NativeDatabase.memory(),
    );
    // 失败不进入聊天pending。
    final AssistantChatController chat = _chat(repository, cache);
    addTearDown(() => _close(chat, cache));
    await chat.saveNote('answer');
    expect(chat.noteSaveError('answer'), contains('更新服务器'));
    expect(chat.draft, '未发送的草稿');
    expect(chat.pending, isNull);
    expect(repository.calls.single.path, '/messages/answer/note');
  });

  test('换服务器后的迟到响应不产生本机保存标记', () async {
    // 来源可在请求过程中失效。
    final _Auth auth = _Auth();
    // 故意延迟响应。
    final _Repository repository = _Repository(auth)
      ..delayed = Completer<Map<String, dynamic>>();
    // 缓存仅属于原来源。
    final AssistantCache cache = AssistantCache.forTesting(
      NativeDatabase.memory(),
    );
    // 当前控制器只绑定原身份。
    final AssistantChatController chat = _chat(repository, cache);
    addTearDown(() => _close(chat, cache));
    // 等待请求真正出站后换源。
    final Future<void> request = chat.saveNote('answer');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    auth.generation++;
    repository.delayed!.complete(repository.receipt);
    await request;
    expect(chat.savedNote('answer'), isNull);
    expect(chat.draft, '未发送的草稿');
  });

  test('生成中和用户消息不能保存，超限明确提示且不截断', () async {
    // 不应访问网络的仓储。
    final _Repository repository = _Repository(_Auth());
    // 独立缓存。
    final AssistantCache cache = AssistantCache.forTesting(
      NativeDatabase.memory(),
    );
    // 相同消息身份依次覆盖边界状态。
    final AssistantChatController chat = _chat(repository, cache);
    addTearDown(() => _close(chat, cache));
    chat.messages = <Map<String, dynamic>>[
      <String, dynamic>{..._answer, '_streaming': true},
    ];
    await chat.saveNote('answer');
    chat.messages = <Map<String, dynamic>>[
      <String, dynamic>{..._answer, 'role': 'user'},
    ];
    await chat.saveNote('answer');
    chat.messages = <Map<String, dynamic>>[
      <String, dynamic>{..._answer, 'content': '中' * 20001},
    ];
    await chat.saveNote('answer');
    expect(chat.noteSaveError('answer'), contains('20,000'));
    expect(repository.calls, isEmpty);
    chat.messages = <Map<String, dynamic>>[
      <String, dynamic>{..._answer, 'content': '中' * 20000},
    ];
    await chat.saveNote('answer');
    expect(chat.savedNote('answer'), isNotNull);
  });

  test('旧回答的撤销回调不能误撤销后来出现的新任务', () async {
    // 新旧任务在页面重绘前交错到达。
    final _Repository repository = _Repository(_Auth());
    // 不连接用户的本机数据库。
    final AssistantCache cache = AssistantCache.forTesting(
      NativeDatabase.memory(),
    );
    // 回调仍持有旧任务，而当前任务已经不同。
    final AssistantChatController chat = _chat(repository, cache)
      ..run = <String, dynamic>{
        'id': 'new-run',
        'status': 'succeeded',
        'canUndo': true,
      };
    addTearDown(() => _close(chat, cache));
    await chat.undo(runId: 'run');
    expect(repository.calls, isEmpty);
    expect(chat.error, contains('任务状态已更新'));
  });
}
