import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/core/sync/omni_sync_runtime.dart';
import 'package:omni_butler/features/notes/audio/note_audio_player_service.dart';
import 'package:omni_butler/features/notes/audio/note_recorder_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'clear_note_test_data.dart';

/// 维护入口必须显式选择实际路径，默认仅预览；不创建产品清空按钮。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('一次性清理已授权的本机测试笔记（默认dryrun）', () async {
    // 显式opt-in后才允许创建备份并清理。
    const bool execute = bool.fromEnvironment('NOTE_TEST_CLEANUP_EXECUTE');
    // Resume only the explicitly selected post-commit backup operation.
    const String resumePath = String.fromEnvironment(
      'NOTE_TEST_CLEANUP_RESUME',
    );
    if (resumePath.isNotEmpty && !execute) {
      throw StateError('续跑必须显式提供NOTE_TEST_CLEANUP_EXECUTE=true');
    }
    // Documents默认为系统KnownFolder，可显式覆盖以选定运行用户。
    const String documentsOverride = String.fromEnvironment(
      'NOTE_TEST_CLEANUP_DOCUMENTS',
    );
    // Flutter测试宿主不能推断安装版应用的Support身份，实际执行必须显式提供。
    const String supportOverride = String.fromEnvironment(
      'NOTE_TEST_CLEANUP_SUPPORT',
    );
    if (execute && supportOverride.isEmpty) {
      throw StateError('执行必须显式提供NOTE_TEST_CLEANUP_SUPPORT');
    }
    // 本次明确选择的应用文档目录。
    final Directory documents = documentsOverride.isEmpty
        ? await getApplicationDocumentsDirectory()
        : Directory(documentsOverride);
    // 与安装应用一致的支持目录。
    final Directory support = supportOverride.isEmpty
        ? await getApplicationSupportDirectory()
        : Directory(supportOverride);
    // 已经确认归属的数据库路径。
    final String databasePath = await locateNoteCleanupDatabase(documents);
    // 完全复用产品数据源录音目录身份，不读取旧source目录或历史迁移备份。
    final String sourceKey = sha256
        .convert(utf8.encode(databasePath))
        .toString();
    // 仅当前数据源与兼容旧版本的恢复目录。
    final List<Directory> recordingDirectories = [
      Directory(p.join(support.path, 'notes', 'recordings', sourceKey)),
      Directory(p.join(support.path, 'notes', 'audio')),
    ];
    // 没有启动原生音源的播放器实例。
    final List<NoteAudioPlayerService> players = [
      // 当前目录或播放器在固定列表中的序号。
      for (int index = 0; index < recordingDirectories.length; index++)
        NoteAudioPlayerService(),
    ];
    // 逐个录音目录与删除标记服务的固定绑定。
    final List<NoteCleanupRecordingScope> scopes = [
      // 当前目录或播放器在固定列表中的序号。
      for (int index = 0; index < recordingDirectories.length; index++)
        NoteCleanupRecordingScope(
          recordingDirectories[index],
          NoteRecorderService(
            player: players[index],
            directoryResolver: () async => recordingDirectories[index],
          ),
        ),
    ];
    // 不连接网络、不初始化上传的真实运行时。
    final OmniSyncRuntime runtime = await OmniSyncRuntime.openAtPath(
      AuthRepository(const FlutterSecureStorage()),
      databasePath,
      initializeUpload: false,
    );
    try {
      // 只输出路径与计数，不输出正文和连接凭据。
      stdout.writeln(
        jsonEncode({
          'databasePath': databasePath,
          'supportPath': support.path,
          'recordingPaths': recordingDirectories
              .map((directory) => directory.path)
              .toList(),
        }),
      );
      // 只有完整完成后才返回的维护结果。
      final NoteTestCleanupReport result = await clearNoteTestData(
        runtime: runtime,
        recordings: scopes,
        audioRoots: [
          Directory(p.join(support.path, 'notes')),
          Directory(p.join(p.dirname(databasePath), 'note_audio_live')),
        ],
        backupParent: Directory(
          p.join(documents.path, 'note-test-cleanup-backups'),
        ),
        execute: execute,
        resumeFrom: resumePath.isEmpty ? null : Directory(resumePath),
      );
      stdout.writeln(jsonEncode(result.toJson()));
    } finally {
      await runtime.close();
      // 当前录音目录及其专属删除服务。
      for (final NoteCleanupRecordingScope scope in scopes) {
        await scope.recorder.dispose();
      }
      // 不会启动音频硬件的测试播放器。
      for (final NoteAudioPlayerService player in players) {
        await player.dispose();
      }
    }
  });
}
