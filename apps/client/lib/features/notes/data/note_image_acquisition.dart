import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'note_editor_controller.dart';

/// 相机与相册返回结果先保存归属，进程回收后按原请求幂等导入。
class NoteImageAcquisition extends ChangeNotifier {
  /// 当前数据源对应的唯一编辑会话。
  final NoteEditorController editor;

  /// 隔离数据源的稳定身份。
  final String sourceKey;

  /// 本机请求清单，不参与同步。
  final SharedPreferences preferences;

  /// 可替换系统取图入口以验证取消、失败和进程恢复。
  final ImagePicker picker;

  /// 数据源被替换后异步结果仍可保存，但不通知已销毁的界面。
  bool _disposed = false;

  /// 释放界面通知，系统返回仍按原请求归属持久处理。
  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// 取图请求只允许一个在途任务。
  bool busy = false;

  /// 恢复失败保留请求并向界面提供重试说明。
  String? error;

  /// 全设备只有一个系统取图回调，清单内再校验数据源。
  static const String _key = 'notes.media.pending';

  /// 创建数据源专属的取图服务。
  NoteImageAcquisition({
    required this.editor,
    required this.sourceKey,
    required this.preferences,
    ImagePicker? picker,
  }) : picker = picker ?? ImagePicker();

  /// 持久保存完整请求，写入失败时不启动外部界面。
  Future<void> _save(Map<String, dynamic> request) async {
    if (!await preferences.setString(_key, jsonEncode(request))) {
      throw StateError('图片请求暂存失败，请重试');
    }
  }

  /// 读取本机请求，损坏时保守拒绝覆盖。
  Map<String, dynamic>? _read() {
    // 原始清单只由本服务生成，不接受外部文件路径指令。
    final String? raw = preferences.getString(_key);
    return raw == null
        ? null
        : Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  /// 启动相机或多选相册，取消不会提交正式笔记。
  Future<bool> acquire({required bool camera}) async {
    if (busy) return false;
    busy = true;
    error = null;
    if (!_disposed) notifyListeners();
    try {
      if (_read() != null) {
        throw StateError('有图片等待恢复，请先重试导入或返回原数据源');
      }
      await editor.prepareMediaDraft();
      // 外部界面打开之前固定身份，返回不依赖当前可见的笔记。
      final Map<String, dynamic> request = {
        'source': sourceKey,
        'draftId': editor.draftId,
        'noteId': editor.draft.id,
        'requestId': const Uuid().v4(),
        'paths': <String>[],
      };
      await _save(request);
      // 拍照单张、相册多张，系统取消统一为空集合。
      final List<XFile> files = camera
          ? [await picker.pickImage(source: ImageSource.camera)]
                .whereType<XFile>()
                .toList()
          : await picker.pickMultiImage();
      if (files.isEmpty) {
        await preferences.remove(_key);
        return false;
      }
      request['paths'] = files.map((file) => file.path).toList();
      await _save(request);
      return await _import(request);
    } catch (failure) {
      error = '$failure';
      rethrow;
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// 冷启动先取回系统丢失结果，再检查原数据源与草稿是否仍有效。
  Future<bool> recover() async {
    if (busy) return false;
    busy = true;
    error = null;
    try {
      // 系统只保存一批结果，先回写清单，再执行数据库导入。
      final LostDataResponse lost = await picker.retrieveLostData();
      // 请求的原始归属不会因当前数据源变化而改写。
      final Map<String, dynamic>? request = _read();
      if (request == null) return false;
      if (lost.files?.isNotEmpty == true) {
        request['paths'] = lost.files!.map((file) => file.path).toList();
        await _save(request);
      }
      if (lost.exception != null) throw lost.exception!;
      if ((request['paths'] as List).isEmpty) {
        await preferences.remove(_key);
        return false;
      }
      return await _import(request);
    } catch (failure) {
      error = '图片待恢复：$failure';
      return false;
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// 原草稿取消后丢弃迟到结果，其他数据源的结果留待原源恢复。
  Future<bool> _import(Map<String, dynamic> request) async {
    if (_disposed || request['source'] != sourceKey) {
      error = '图片保留在原数据源，切回后可恢复';
      return false;
    }
    // 查询持久草稿事实，不能依据当前输入框身份推断归属。
    final String draftId = request['draftId'] as String;
    // 取消或提交后的旧请求不得新建替代草稿。
    final local = await editor.localDrafts.find(draftId);
    if (local == null || local.discarded || local.noteId != request['noteId']) {
      await preferences.remove(_key);
      return false;
    }
    // 路径只用于系统交付的图片导入，原件校验由图片仓储完成。
    final List<String> paths = (request['paths'] as List).cast<String>();
    if (editor.draftId == draftId) {
      if (editor.imageAdding ||
          editor.committing ||
          editor.frozen ||
          editor.conflicted) {
        throw StateError('当前草稿暂不可导入图片，结果已保留，可稍后重试');
      }
      await editor.addImages(paths, requestId: request['requestId'] as String);
    } else {
      // UI已切换时直接导入原草稿，不覆盖当前正在编辑的内容。
      for (int index = 0; index < paths.length; index++) {
        await editor.images.stage(
          draftId,
          local.noteId,
          paths[index],
          imageId: const Uuid().v5(
            Namespace.url.value,
            'notes-media:${request['requestId']}:$index',
          ),
        );
      }
    }
    await preferences.remove(_key);
    return true;
  }
}
