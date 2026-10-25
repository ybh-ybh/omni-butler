import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/core/attachments/windows_clipboard_images.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/features/assistant/data/assistant_attachments.dart';
import 'package:omni_butler/features/assistant/data/assistant_cache.dart';
import 'package:omni_butler/features/assistant/data/assistant_chat_controller.dart';
import 'package:omni_butler/features/assistant/data/assistant_models.dart';
import 'package:omni_butler/features/assistant/data/assistant_repository.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_attachment_widgets.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// 让真实草稿复制和清理仅访问测试临时目录。
class _TestAttachmentPaths extends PathProviderPlatform {
  /// 当前测试专属根目录。
  final String root;

  /// 创建隔离路径提供器。
  _TestAttachmentPaths(this.root);

  /// 提供应用私有目录。
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

/// 所有网络请求留在内存，认证代次用于模拟换服。
class _Auth implements AuthRepository {
  /// 可手动变更的来源代次。
  int generation = 1;

  /// 当前来源代次。
  @override
  int get sessionGeneration => generation;

  /// 无网络的流取消令牌。
  @override
  CancelToken createSessionStreamToken(int generation) => CancelToken();

  /// 未使用的能力禁止隐式访问。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 上传和消息都使用实际控制器身份，接口只返回合成回执。
class _Repository extends AssistantRepository {
  /// 记录发送负载用于检查未知消息恢复。
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];

  /// 保留上传身份与私有文件路径。
  final List<({String id, String path, String name})> uploads = [];

  /// 传输失败发生在服务器已保存之后的场景。
  bool failUpload = false;

  /// 消息已保存但响应未知的场景。
  bool failSend = false;

  /// 可确定拒绝和结果未知分别使用真实仓储异常类型。
  AssistantApiFailure? sendFailure;

  /// 保留可受控晚到的上传响应。
  Completer<Map<String, dynamic>>? delayedUpload;

  /// 当前模型已验证能力。
  String imageInput = 'unknown';

  /// 图片输入只由配置开关决定，与旧探测结果独立。
  bool multimodal = false;

  /// 服务器附件能力开关。
  bool enabled = true;

  /// 解析状态。
  String attachmentStatus = 'processing';

  /// 模拟服务器清理过期未发送附件。
  bool expired = false;

  /// 非协议字段用于验证服务端回执不能覆写本地恢复身份。
  Map<String, dynamic> attachmentExtra = <String, dynamic>{};

  /// 上传前持久身份的时序断言。
  void Function()? beforeUpload;

  /// 创建合成仓储。
  _Repository(super.auth);

  /// 服务端公开的首版限制。
  Map<String, dynamic> get capabilities => <String, dynamic>{
    'enabled': enabled,
    'maxFiles': 5,
    'maxFileBytes': 20971520,
    'maxTotalBytes': 52428800,
    'extensions': <String>[
      'png',
      'jpg',
      'jpeg',
      'webp',
      'pdf',
      'txt',
      'md',
      'docx',
      'xlsx',
    ],
  };

  /// 上传必须已经存在可恢复的私有文件。
  @override
  Future<Map<String, dynamic>> uploadAttachment(
    String conversationId,
    String uploadId,
    String localPath,
    String name,
  ) async {
    uploads.add((id: uploadId, path: localPath, name: name));
    expect(await File(localPath).exists(), isTrue);
    beforeUpload?.call();
    if (delayedUpload != null) return delayedUpload!.future;
    if (failUpload) throw const ApiFailure('上传响应中断');
    return <String, dynamic>{
      'id': uploadId,
      'status': attachmentStatus,
      'name': name,
      'kind': 'document',
      'requiresVision': false,
      ...attachmentExtra,
    };
  }

  /// 模拟能力、解析、发送与消息恢复接口。
  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Object? data,
  }) async {
    if (path == '/attachments/capabilities') return capabilities;
    if (path == '/settings') {
      return <String, dynamic>{
        'profileId': 'profile',
        'profiles': <Object>[
          <String, dynamic>{
            'id': 'profile',
            'multimodal': multimodal,
            'capabilities': <String, dynamic>{'imageInput': imageInput},
          },
        ],
      };
    }
    if (path.startsWith('/attachments/')) {
      if (expired && method == 'GET') {
        throw const AssistantApiFailure('附件不存在', 404);
      }
      return <String, dynamic>{'status': attachmentStatus, ...attachmentExtra};
    }
    if (path == '/conversations') {
      return method == 'POST'
          ? <String, dynamic>{'id': 'conversation'}
          : <String, dynamic>{'items': <Object>[]};
    }
    if (path.endsWith('/messages') && method == 'POST') {
      sent.add(Map<String, dynamic>.from(data! as Map));
      if (sendFailure != null) throw sendFailure!;
      if (failSend) throw const ApiFailure('消息结果未知');
      return <String, dynamic>{'id': 'run', 'status': 'succeeded'};
    }
    if (path.endsWith('/messages')) {
      return <String, dynamic>{'items': <Object>[]};
    }
    return <String, dynamic>{};
  }

  /// 无真实模型事件。
  @override
  Stream<AssistantEvent> events(String runId, int after, CancelToken token) =>
      const Stream<AssistantEvent>.empty();
}

/// 合成只读附件，所有文件身份均来自测试。
Map<String, dynamic> _draft(
  String id, {
  bool vision = false,
  String status = 'ready',
}) => <String, dynamic>{
  'id': id,
  'name': '很长的附件名称用于验证窄屏换行-$id.pdf',
  'size': 100,
  'kind': vision ? 'image' : 'document',
  'status': status,
  'requiresVision': vision,
  'uploaded': true,
};

/// 上传、恢复、能力门禁和两端布局的隔离验证。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final bool fail in <bool>[false, true]) {
    test('附件上传等待时消息先进入对话，${fail ? '失败恢复原草稿' : '成功按身份接管'}', () async {
      // 路径与缓存均为本测试独占。
      final Directory directory = await Directory.systemTemp.createTemp(
        'assistant-send-display',
      );
      // 恢复全局插件，避免干扰其他文件测试。
      final PathProviderPlatform originalPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _TestAttachmentPaths(directory.path);
      // 上传门闩固定测试时序，不靠网络或长等待。
      final Completer<void> uploading = Completer<void>();
      final _Repository repository = _Repository(_Auth())
        ..delayedUpload = Completer<Map<String, dynamic>>()
        ..beforeUpload = () => uploading.complete();
      final AssistantCache cache = AssistantCache.forTesting(
        NativeDatabase.memory(),
      );
      final AssistantChatController chat = AssistantChatController(
        repository: repository,
        cache: cache,
        scope: 'display',
        catchUp: () async {},
      );
      addTearDown(() async {
        chat.dispose();
        await cache.close();
        PathProviderPlatform.instance = originalPaths;
        await directory.delete(recursive: true);
      });
      await chat.initialize();
      await chat.attachments.add(<AssistantPickedFile>[
        AssistantPickedFile(
          name: '说明.txt',
          bytes: Uint8List.fromList(<int>[65]),
        ),
      ]);
      chat.setDraft('概括这个文件');
      // 暂停在上传中：计时可见时必须已有对应用户消息，输入草稿只隐藏不丢失。
      final Future<void> sending = chat.send();
      await uploading.future;
      expect(chat.submitting, isTrue);
      expect(chat.liveElapsedMs, isNotNull);
      expect(chat.hideComposerDraft, isTrue);
      expect(chat.displayMessages.single['content'], '概括这个文件');
      expect(
        assistantMessageAttachments(chat.displayMessages.single).single['name'],
        '说明.txt',
      );
      expect(chat.draft, '概括这个文件');
      expect(chat.messages, isEmpty);
      expect(repository.sent, isEmpty);
      if (fail) {
        repository.delayedUpload!.completeError(const ApiFailure('上传失败'));
      } else {
        repository.delayedUpload!.complete(<String, dynamic>{
          'id': chat.attachments.ids.single,
          'status': 'ready',
          'kind': 'document',
          'requiresVision': false,
          'name': '说明.txt',
        });
      }
      await sending;
      expect(chat.hideComposerDraft, isFalse);
      expect(chat.submitting, isFalse);
      if (fail) {
        expect(chat.displayMessages, isEmpty);
        expect(chat.draft, '概括这个文件');
        expect(chat.attachments.hasDrafts, isTrue);
        expect(repository.sent, isEmpty);
      } else {
        expect(chat.draft, isEmpty);
        expect(chat.attachments.hasDrafts, isFalse);
        // 服务端刷新接管同一身份后仍只能显示一次。
        chat.messages = <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'saved-user',
            'role': 'user',
            ...repository.sent.single,
          },
        ];
        expect(chat.displayMessages, hasLength(1));
        expect(chat.displayMessages.single['id'], 'saved-user');
      }
    });
  }

  test('新聊天附件仅保存本地，恢复后首次发送才上传，移除本地附件不访问服务器', () async {
    // 文件副本只写本测试临时目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'assistant-local-draft',
    );
    // 发送阶段直接返回已就绪，避免测试依赖轮询时钟。
    final _Repository repository = _Repository(_Auth())
      ..attachmentStatus = 'ready';
    // 尚无服务端会话时管理器只允许生成本地草稿。
    final AssistantAttachments manager = AssistantAttachments(
      repository: repository,
      scope: 'local',
      ensureConversation: () async => null,
      changed: () {},
      frozen: () => false,
      persist: () async {},
      directoryProvider: () async => directory,
    );
    addTearDown(() async {
      manager.dispose();
      await directory.delete(recursive: true);
    });
    await manager.initialize();
    await manager.add(<AssistantPickedFile>[
      AssistantPickedFile(
        name: 'first.txt',
        bytes: Uint8List.fromList(<int>[65]),
      ),
    ]);
    expect(repository.uploads, isEmpty);
    expect(manager.drafts.single['status'], 'local');
    expect(manager.drafts.single['conversationId'], isNull);
    expect(manager.blockReason(<String, dynamic>{}), isNull);
    // 重启恢复不会误报上传中断，也不会自动上传。
    final List<Map<String, dynamic>> saved = manager.snapshot;
    manager.restore(saved);
    expect(manager.drafts.single['status'], 'local');
    expect(
      await File(manager.drafts.single['localPath'] as String).exists(),
      isTrue,
    );
    await manager.prepareForSend('first-message-chat');
    expect(repository.uploads.single.id, saved.single['id']);
    expect(manager.drafts.single['conversationId'], 'first-message-chat');
    expect(manager.drafts.single['status'], 'ready');
    await manager.clearAccepted();
    await manager.add(<AssistantPickedFile>[
      AssistantPickedFile(
        name: 'remove.txt',
        bytes: Uint8List.fromList(<int>[66]),
      ),
    ]);
    await manager.remove(manager.ids.single);
    expect(manager.drafts, isEmpty);
    expect(repository.uploads, hasLength(1));
  });

  test('图片本地草稿可上传就绪，模型能力限制与文件传输分别判断', () async {
    // 使用真正 PNG 文件及隔离私有目录，不能只用卡片占位证明上传成功。
    final Directory directory = await Directory.systemTemp.createTemp(
      'assistant-image-send-test',
    );
    // 模拟服务器完成图片归一化后的公开元数据。
    final _Repository repository = _Repository(_Auth())
      ..attachmentStatus = 'ready'
      ..attachmentExtra = <String, dynamic>{
        'kind': 'image',
        'requiresVision': true,
      };
    // 新聊天仅复制草稿，发送时才提供会话身份。
    final AssistantAttachments manager = AssistantAttachments(
      repository: repository,
      scope: 'image-test',
      ensureConversation: () async => null,
      changed: () {},
      frozen: () => false,
      persist: () async {},
      directoryProvider: () async => directory,
    );
    addTearDown(() async {
      manager.dispose();
      await directory.delete(recursive: true);
    });
    await manager.initialize();
    await manager.add(<AssistantPickedFile>[
      AssistantPickedFile(
        name: '截图.png',
        sourcePath: File('assets/icon/app_icon.png').absolute.path,
      ),
    ]);
    // 未验证视觉能力不能误报成附件上传失败，发送按钮仍可进入显式校验。
    final Map<String, dynamic> settings = await repository.request(
      'GET',
      '/settings',
    );
    expect(manager.drafts.single['status'], 'local');
    expect(repository.uploads, isEmpty);
    expect(manager.blockReason(settings, includeVision: false), isNull);
    expect(manager.blockReason(settings), contains('未开启多模态'));
    repository.multimodal = true;
    await manager.prepareForSend('conversation');
    expect(repository.uploads, hasLength(1));
    expect(repository.uploads.single.id, manager.ids.single);
    expect(
      await File(repository.uploads.single.path).readAsBytes(),
      await File('assets/icon/app_icon.png').readAsBytes(),
    );
    expect(manager.drafts.single['status'], 'ready');
    expect(manager.drafts.single['requiresVision'], isTrue);
    expect(
      manager.blockReason(await repository.request('GET', '/settings')),
      isNull,
    );
    // 已上传的图片再次准备不会重复出站。
    await manager.prepareForSend('conversation');
    expect(repository.uploads, hasLength(1));
  });

  test('上传前复制并持久化；响应未知以原 UUID 和同一副本重放', () async {
    // 文件只写隔离临时目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'assistant-attachment-test',
    );
    // 固定仓储模拟第一次响应中断。
    final _Repository repository = _Repository(_Auth())..failUpload = true;
    // 每次网络请求前的快照必须已包含恢复身份。
    List<Map<String, dynamic>> persisted = [];
    // 被测真实附件管理器。
    late final AssistantAttachments manager;
    manager = AssistantAttachments(
      repository: repository,
      scope: 'server-a-owner-a',
      ensureConversation: () async => 'conversation',
      changed: () {},
      frozen: () => false,
      persist: () async {
        persisted = manager.snapshot;
      },
      directoryProvider: () async => directory,
    );
    repository.beforeUpload = () =>
        expect(persisted.single['id'], manager.ids.single);
    addTearDown(() async {
      manager.dispose();
      await directory.delete(recursive: true);
    });
    await manager.initialize();
    await manager.add(<AssistantPickedFile>[
      AssistantPickedFile(
        name: '草稿.txt',
        bytes: Uint8List.fromList(<int>[65, 66]),
      ),
    ]);
    expect(manager.drafts.single['status'], 'failed');
    expect(persisted.single['id'], repository.uploads.single.id);
    expect(repository.uploads.single.path, startsWith(directory.path));
    // 成功回执仍恢复原上传身份。
    repository.failUpload = false;
    await manager.retry(manager.ids.single);
    expect(repository.uploads[1].id, repository.uploads[0].id);
    expect(repository.uploads[1].path, repository.uploads[0].path);
    repository.attachmentStatus = 'ready';
    await manager.pollNow();
    expect(manager.drafts.single['status'], 'ready');
    // 服务器确认删除后才移除私有副本。
    final String localPath =
        repository.uploads.singleOrNull?.path ?? repository.uploads.first.path;
    await manager.remove(manager.ids.single);
    expect(manager.drafts, isEmpty);
    expect(await File(localPath).exists(), isFalse);
  });

  test('切换来源后晚到上传不更新旧草稿，也不进入新来源', () async {
    // 所有本机内容限于隔离目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'assistant-source-test',
    );
    // 控制认证代次和上传响应。
    final _Auth auth = _Auth();
    // 上传响应由测试推进。
    final _Repository repository = _Repository(auth)
      ..delayedUpload = Completer<Map<String, dynamic>>();
    // 真实附件草稿管理器。
    final AssistantAttachments manager = AssistantAttachments(
      repository: repository,
      scope: 'server-a-owner-a',
      ensureConversation: () async => 'conversation',
      changed: () {},
      frozen: () => false,
      persist: () async {},
      directoryProvider: () async => directory,
    );
    addTearDown(() async {
      manager.dispose();
      await directory.delete(recursive: true);
    });
    await manager.initialize();
    // 发出上传但不等待网络回执。
    final Future<void> adding = manager.add(<AssistantPickedFile>[
      AssistantPickedFile(name: '来源.txt', bytes: Uint8List.fromList(<int>[1])),
    ]);
    while (repository.uploads.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    auth.generation++;
    repository.delayedUpload!.complete(<String, dynamic>{'status': 'ready'});
    await adding;
    expect(manager.drafts.single['status'], 'uploading');
    expect(manager.editable, isFalse);
  });

  test('元数据不能改写上传身份；恢复缓存越界或相对路径不上传', () async {
    // 外部候选和应用私有目录都位于可回收的测试根目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'assistant-path-test',
    );
    // 该文件不在任何 scope 的附件私有目录内。
    final File outside = await File('${directory.path}/outside.txt')
        .writeAsString('不能上传的文件');
    // 故意混入本地字段的回执仍只能更新展示元数据。
    final _Repository repository = _Repository(_Auth())
      ..attachmentExtra = <String, dynamic>{
        'id': 'other-id',
        'localPath': outside.path,
        'conversationId': 'other-conversation',
        'uploaded': false,
      };
    // 正式管理器使用隔离的私有目录。
    final AssistantAttachments manager = AssistantAttachments(
      repository: repository,
      scope: 'source-owner',
      ensureConversation: () async => 'conversation',
      changed: () {},
      frozen: () => false,
      persist: () async {},
      directoryProvider: () async => directory,
    );
    addTearDown(() async {
      manager.dispose();
      await directory.delete(recursive: true);
    });
    await manager.initialize();
    await manager.add(<AssistantPickedFile>[
      AssistantPickedFile(name: '安全.txt', bytes: Uint8List.fromList(<int>[65])),
    ]);
    expect(manager.ids.single, repository.uploads.single.id);
    expect(manager.drafts.single['localPath'], repository.uploads.single.path);
    expect(manager.drafts.single['conversationId'], 'conversation');
    expect(manager.drafts.single['uploaded'], isTrue);
    await manager.pollNow();
    await manager.retry(manager.ids.single);
    expect(manager.ids.single, repository.uploads.single.id);
    expect(manager.drafts.single['localPath'], repository.uploads.single.path);
    for (final String localPath in <String>[outside.path, 'relative.txt']) {
      manager.restore(<Object>[
        <String, dynamic>{
          ..._draft('restore', status: 'failed'),
          'uploaded': false,
          'conversationId': 'conversation',
          'localPath': localPath,
        },
      ]);
      await manager.retry('restore');
      expect(repository.uploads, hasLength(1));
      expect(manager.drafts.single['localError'], contains('本地副本无效'));
    }
    expect(await outside.readAsString(), '不能上传的文件');
  });

  test('未知消息冻结正文和附件 IDs；重启恢复原请求，成功后才清草稿', () async {
    // 缓存以独立来源隔离。
    final AssistantCache cache = AssistantCache.forTesting(
      NativeDatabase.memory(),
    );
    // 第一次响应中断，后续显式恢复。
    final _Repository repository = _Repository(_Auth())..failSend = true;
    // 真实聊天控制器覆盖原有 pending 保存路径。
    final AssistantChatController chat = AssistantChatController(
      repository: repository,
      cache: cache,
      scope: 'a',
      catchUp: () async {},
    );
    await chat.initialize();
    chat.attachments.restore(<Object>[_draft('first'), _draft('second')]);
    await chat.send();
    expect(repository.sent.single['content'], '请概括附件内容');
    expect(repository.sent.single['attachmentIds'], <String>[
      'first',
      'second',
    ]);
    chat.setDraft('不能替换未知结果的正文');
    await chat.attachments.remove('first');
    expect(chat.draft, isEmpty);
    expect(chat.attachments.ids, <String>['first', 'second']);
    // 已持久化的请求在重建控制器后不自动提交。
    final Map<String, dynamic> pending = Map<String, dynamic>.from(
      chat.pending!,
    );
    chat.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final AssistantChatController restored = AssistantChatController(
      repository: repository,
      cache: cache,
      scope: 'a',
      catchUp: () async {},
    );
    await restored.initialize();
    expect(restored.pending, pending);
    expect(repository.sent, hasLength(1));
    repository.failSend = false;
    await restored.send();
    expect(repository.sent[1], repository.sent[0]);
    expect(restored.pending, isNull);
    expect(restored.attachments.drafts, isEmpty);
    restored.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    // 新服务器不读取旧来源草稿。
    expect(await cache.readScope('other-source'), isEmpty);
    await cache.close();
  });

  test('附件未就绪或未开启多模态时控制器拒绝提交', () async {
    // 完整聊天控制器验证不能绕过 UI 直接发送。
    final AssistantCache cache = AssistantCache.forTesting(
      NativeDatabase.memory(),
    );
    // 当前配置没有已验证视觉能力。
    final _Repository repository = _Repository(_Auth());
    // 同源真实聊天控制器。
    final AssistantChatController chat = AssistantChatController(
      repository: repository,
      cache: cache,
      scope: 'a',
      catchUp: () async {},
    );
    await chat.initialize();
    chat.setDraft('这张图片是什么？');
    chat.attachments.restore(<Object>[_draft('image', vision: true)]);
    await chat.send();
    expect(chat.error, contains('未开启多模态'));
    expect(repository.sent, isEmpty);
    expect(chat.conversationId, isNull);
    expect(chat.draft, '这张图片是什么？');
    repository.imageInput = 'unsupported';
    await chat.send();
    expect(chat.error, contains('未开启多模态'));
    expect(repository.sent, isEmpty);
    expect(chat.conversationId, isNull);
    repository.multimodal = true;
    chat.attachments.restore(<Object>[
      _draft('image', vision: true, status: 'processing'),
    ]);
    await chat.send();
    expect(chat.error, contains('全部附件就绪'));
    expect(repository.sent, isEmpty);
    chat.attachments.restore(<Object>[_draft('image', vision: true)]);
    await chat.send();
    expect(repository.sent, hasLength(1));
    chat.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await cache.close();
  });

  test('过期解析不永久轮询，显示可移除状态；批次不接受旧版 Office', () async {
    // 只在测试目录复制文件。
    final Directory directory = await Directory.systemTemp.createTemp(
      'assistant-expired-test',
    );
    // 元数据请求返回明确 404。
    final _Repository repository = _Repository(_Auth())..expired = true;
    // 真实管理器验证解析状态与本地清理。
    final AssistantAttachments manager = AssistantAttachments(
      repository: repository,
      scope: 'test',
      ensureConversation: () async => 'conversation',
      changed: () {},
      frozen: () => false,
      persist: () async {},
      directoryProvider: () async => directory,
    );
    addTearDown(() async {
      manager.dispose();
      await directory.delete(recursive: true);
    });
    await manager.initialize();
    manager.restore(<Object>[_draft('expired', status: 'processing')]);
    await manager.pollNow();
    expect(manager.drafts.single['status'], 'failed');
    expect(manager.drafts.single['expired'], isTrue);
    await manager.remove('expired');
    await manager.add(<AssistantPickedFile>[
      AssistantPickedFile(name: '有效.txt', bytes: Uint8List.fromList(<int>[1])),
      AssistantPickedFile(name: '旧文档.doc', bytes: Uint8List.fromList(<int>[2])),
    ]);
    expect(manager.drafts, isEmpty);
    expect(repository.uploads, isEmpty);
    expect(
      await directory
          .list(recursive: true)
          .where((item) => item is File)
          .toList(),
      isEmpty,
    );
  });

  test('明确附件输入拒绝允许修改；泛化400和408、409、5xx保留原请求', () async {
    for (final ({int status, String? code, bool editable}) response
        in <({int status, String? code, bool editable})>[
          (status: 400, code: 'ATTACHMENT_NOT_READY', editable: true),
          (status: 422, code: 'AI_IMAGE_INPUT_UNSUPPORTED', editable: true),
          (status: 413, code: null, editable: true),
          (status: 400, code: null, editable: false),
          (status: 408, code: 'ATTACHMENT_NOT_READY', editable: false),
          (status: 409, code: 'ATTACHMENT_NOT_READY', editable: false),
          (
            status: 503,
            code: 'ATTACHMENT_STORAGE_UNAVAILABLE',
            editable: false,
          ),
        ]) {
      // 每个错误使用独立缓存，防止前一请求状态污染。
      final AssistantCache cache = AssistantCache.forTesting(
        NativeDatabase.memory(),
      );
      // 固定 HTTP 与业务码组合。
      final _Repository repository = _Repository(_Auth())
        ..sendFailure = AssistantApiFailure(
          '输入未接受',
          response.status,
          code: response.code,
        );
      // 正式控制器执行持久请求与异常恢复。
      final AssistantChatController chat = AssistantChatController(
        repository: repository,
        cache: cache,
        scope: 'test',
        catchUp: () async {},
      );
      await chat.initialize();
      chat.setDraft('原正文');
      chat.attachments.restore(<Object>[_draft('document')]);
      await chat.send();
      expect(
        chat.pending == null,
        response.editable,
        reason: '${response.status}/${response.code}',
      );
      expect(chat.attachments.ids, <String>['document']);
      expect(chat.draft, '原正文');
      chat.setDraft('修改正文');
      expect(chat.draft, response.editable ? '修改正文' : '原正文');
      chat.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await cache.close();
    }
  });

  test('DIB 行方向、BGR 通道和截断边界正确，不复制未知内存', () {
    // 两行单像素 24 位 BMP 行跨度为四字节。
    final Uint8List bytes = Uint8List(48);
    // 构造标准 BITMAPINFOHEADER，不访问真实剪贴板。
    final ByteData header = ByteData.sublistView(bytes);
    header.setUint32(0, 40, Endian.little);
    header.setInt32(4, 1, Endian.little);
    header.setInt32(8, 2, Endian.little);
    header.setUint16(12, 1, Endian.little);
    header.setUint16(14, 24, Endian.little);
    bytes.setRange(40, 48, <int>[255, 0, 0, 0, 0, 0, 255, 0]);
    expect(decodeClipboardDib(bytes).rgba, <int>[
      255,
      0,
      0,
      255,
      0,
      0,
      255,
      255,
    ]);
    expect(
      () => decodeClipboardDib(Uint8List.sublistView(bytes, 0, 47)),
      throwsA(isA<ApiFailure>()),
    );
    header.setInt32(4, 100000, Endian.little);
    expect(() => decodeClipboardDib(bytes), throwsA(isA<ApiFailure>()));
  });

  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.windows,
    TargetPlatform.android,
  ]) {
    testWidgets('$platform 320dp 双倍字号显示失败卡、视觉提示和移除入口', (
      WidgetTester tester,
    ) async {
      // 不访问真实认证来源。
      final _Repository repository = _Repository(_Auth());
      // 状态卡在两端使用同一组件及权限门禁。
      final AssistantAttachments manager = AssistantAttachments(
        repository: repository,
        scope: 'test',
        ensureConversation: () async => 'conversation',
        changed: () {},
        frozen: () => false,
        persist: () async {},
      );
      await manager.initialize();
      manager.restore(<Object>[
        _draft('image', vision: true),
        _draft('failed', status: 'failed'),
      ]);
      addTearDown(manager.dispose);
      tester.view.resetPhysicalSize();
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(brightness: Brightness.light)
              .copyWith(platform: platform),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 700),
              textScaler: TextScaler.linear(2),
            ),
            child: Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: <Widget>[
                      AssistantAttachmentDrafts(
                        attachments: manager,
                        settings: const <String, dynamic>{},
                      ),
                      AssistantAttachmentButton(
                        attachments: manager,
                        enabled: true,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('100 B · 解析失败，可重试或移除'), findsOneWidget);
      expect(find.text('100 B · 已就绪 · 需要视觉模型'), findsOneWidget);
      expect(find.text('当前模型无法读取图片附件'), findsNothing);
      expect(find.textContaining('请手动选择并测试'), findsNothing);
      expect(find.textContaining('请等待全部附件就绪'), findsNothing);
      expect(find.byTooltip('移除附件'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      manager.restore(<Object>[_draft('image', vision: true)]);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
