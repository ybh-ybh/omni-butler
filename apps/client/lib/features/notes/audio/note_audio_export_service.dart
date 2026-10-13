import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:omni_butler/core/database/app_database.dart';

/// 可替换系统保存窗口，测试不打开真实桌面弹窗。
typedef NoteAudioSaveFile = Future<Uri?> Function({
  required String fileName,
  required Uint8List bytes,
  required String mimeType,
});

/// 保存原音副本，取消或失败不会移动、删除或改写录音原件。
class NoteAudioExportService {
  /// 使用现有文件选择器，允许测试替换保存边界。
  const NoteAudioExportService({this.saveFile = _saveFile});

  /// 用户选择保存位置及实际写入的系统边界。
  final NoteAudioSaveFile saveFile;

  /// 读取并验证本机原音，再交给用户选择的保存位置。
  Future<Uri?> export(
    NoteAudioSegmentRecord segment,
    NoteAudioLocalFileRecord? local,
  ) async {
    // 当前片段的本机缓存必须已就绪。
    final String? path = local?.localPath;
    if (path == null) throw StateError('本机原音尚未下载，请连接同步服务后重试');
    // 导出字节必须与不可变片段的长度和摘要完全一致。
    final Uint8List bytes = await File(path).readAsBytes();
    if (bytes.length <= 44 ||
        bytes.length != segment.byteSize ||
        sha256.convert(bytes).toString() != segment.sha256) {
      throw StateError('原音校验失败，请从同步服务重新下载或恢复备份');
    }
    // 文件名以录音创建时间和段序号区分，保持原始 WAV 格式。
    final String timestamp = segment.createdAt
        .toLocal()
        .toIso8601String()
        .split('.')
        .first
        .replaceAll(':', '-');
    return saveFile(
      fileName: '笔记录音-$timestamp-${segment.sortOrder + 1}.wav',
      bytes: bytes,
      mimeType: segment.mime,
    );
  }

  /// 复用项目已安装的系统文件选择器，保存原音字节而非链接。
  static Future<Uri?> _saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
  }) => FilePicker.saveFile(
    dialogTitle: '下载音频文件',
    fileName: fileName,
    bytes: bytes,
    mimeType: mimeType,
  );
}
