import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/core/auth/auth_providers.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/sync/sync_connection_providers.dart';
import 'package:omni_butler/core/sync/sync_preferences.dart';
import 'package:omni_butler/core/sync/sync_providers.dart';
import 'package:omni_butler/features/notes/audio/note_audio_player_service.dart';
import 'package:omni_butler/features/notes/audio/note_recorder_service.dart';
import 'package:omni_butler/features/notes/data/note_audio_transfer_service.dart';
import 'package:omni_butler/features/notes/data/note_editor_controller.dart';
import 'package:omni_butler/features/notes/data/note_repository.dart';

/// 笔记仓储绑定当前实际数据源。
final noteRepositoryProvider = Provider<NoteRepository>(
  (ref) => NoteRepository(ref.watch(appDatabaseProvider)),
);

/// 应用内唯一原音播放器。
final noteAudioPlayerProvider = Provider<NoteAudioPlayerService>((ref) {
  // 独立于页面生命周期，播放和录音互斥。
  final NoteAudioPlayerService player = NoteAudioPlayerService();
  ref.onDispose(() => unawaited(player.dispose()));
  return player;
});

/// 应用内唯一采集器。
final noteRecorderProvider = Provider<NoteRecorderService>((ref) {
  // 采集器不持有数据库，迁移门禁需先结束录音。
  final runtime = ref.watch(syncRuntimeProvider);
  // 每个本机数据源有独立的录音恢复目录，旧清单不能串到新数据库。
  final String sourceKey = sha256
      .convert(utf8.encode(runtime?.databasePath ?? 'standalone'))
      .toString();
  final NoteRecorderService recorder = NoteRecorderService(
    player: ref.watch(noteAudioPlayerProvider),
    directoryResolver: () async => Directory(
      p.join(
        (await getApplicationSupportDirectory()).path,
        'notes',
        'recordings',
        sourceKey,
      ),
    ),
  );
  ref.onDispose(() => unawaited(recorder.dispose()));
  return recorder;
});

/// 编辑会话不自动释放，切换页面仍保留未完成录音上下文。
final noteEditorProvider = Provider<NoteEditorController>((ref) {
  // 这一代编辑器与录音器绑定。
  final NoteEditorController editor = NoteEditorController(
    ref.watch(noteRepositoryProvider),
    ref.watch(noteRecorderProvider),
  );
  ref.onDispose(editor.dispose);
  return editor;
});

/// 按日期归档的笔记流。
final notesProvider = StreamProvider<List<NoteEntryRecord>>(
  (ref) => ref.watch(noteRepositoryProvider).watchAll(),
);

/// 当前编辑器读取包含墓碑的记录，远端删除不依赖正文revision变化。
final noteByIdProvider = StreamProvider.family<NoteEntryRecord?, String>((
  ref,
  id,
) {
  final AppDatabase database = ref.watch(appDatabaseProvider);
  return (database.select(
    database.noteEntries,
  )..where((table) => table.id.equals(id))).watchSingleOrNull();
});

/// 指定笔记的原音流。
final noteAudioProvider =
    StreamProvider.family<List<NoteAudioSegmentRecord>, String>(
      (ref, id) => ref.watch(noteRepositoryProvider).watchAudio(id),
    );

/// 指定笔记的版本候选流。
final noteVersionsProvider =
    StreamProvider.family<List<NoteVersionRecord>, String>(
      (ref, id) => ref.watch(noteRepositoryProvider).watchVersions(id),
    );

/// 本机文件传输状态。
final noteLocalAudioProvider = StreamProvider<List<NoteAudioLocalFileRecord>>(
  (ref) => ref
      .watch(appDatabaseProvider)
      .select(ref.watch(appDatabaseProvider).noteAudioLocalFiles)
      .watch(),
);

/// 录音状态广播，不申请权限。
final noteRecordingProvider = StreamProvider<NoteRecordingState>((ref) async* {
  // 页面首帧取得当前状态，再接收后续事件。
  final NoteRecorderService recorder = ref.watch(noteRecorderProvider);
  yield recorder.state;
  yield* recorder.states;
});

/// 全局生命周期只在生产运行时接入，测试可分别注入服务。
final noteInfrastructureProvider = Provider<void>((ref) {
  if (ref.watch(syncRuntimeProvider) == null) return;
  // 开始本地孤儿清理，与网络开关无关。
  final NoteRepository repository = ref.watch(noteRepositoryProvider);
  // 主应用与迁移共享的编辑会话。
  final NoteEditorController editor = ref.watch(noteEditorProvider);
  // 真实退出和迁移必须排空录音与正文。
  final unregister = ref
      .watch(syncConnectionCoordinatorProvider)
      ?.registerBackgroundStop(editor.shutdown);
  // 外围事务提交后再清物理文件，不在永久删除事务内删原件。
  final Timer timer = Timer.periodic(const Duration(minutes: 1), (_) {
    if (!ref.read(syncMaintenanceProvider)) {
      unawaited(repository.purgeOrphanFiles());
    }
  });
  ref.onDispose(() {
    timer.cancel();
    unregister?.call();
  });
});

/// 原音传输与语音任务跟随设备会话、同步开关及维护门禁。
final noteAudioTransferProvider = Provider<NoteAudioTransferService?>((ref) {
  if (ref.watch(syncMaintenanceProvider) ||
      !ref.watch(syncPreferenceProvider) ||
      ref.watch(syncRuntimeProvider) == null ||
      ref.watch(authControllerProvider).value == null ||
      ref.watch(syncControllerProvider).hasError) {
    return null;
  }
  // 固定这一代连接实例。
  final NoteAudioTransferService transfer = NoteAudioTransferService(
    ref.watch(appDatabaseProvider),
    ref.watch(authRepositoryProvider),
    hasUnpersistedEdits: (id) {
      // 编辑器正文与供应商响应互相独立，未保存内容不会被覆盖。
      final NoteEditorController editor = ref.read(noteEditorProvider);
      return editor.draft.id == id && (editor.dirty || editor.conflicted);
    },
  );
  // 数据迁移等待在途音频请求结束。
  final unregister = ref
      .watch(syncConnectionCoordinatorProvider)
      ?.registerBackgroundStop(transfer.stop);
  ref.onDispose(
    () => unawaited(transfer.stop().whenComplete(() => unregister?.call())),
  );
  transfer.start();
  return transfer;
});
