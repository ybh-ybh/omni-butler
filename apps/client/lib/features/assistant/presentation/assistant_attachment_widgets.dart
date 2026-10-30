import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'assistant_image_preview.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/features/assistant/data/assistant_attachments.dart';
import 'package:omni_butler/features/assistant/data/assistant_models.dart';
import 'package:omni_butler/features/assistant/data/assistant_repository.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_windows_tokens.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 两端共用选择器，所有文件经过同一草稿和上传边界。
class AssistantAttachmentButton extends StatefulWidget {
  /// 当前会话附件管理器。
  final AssistantAttachments attachments;

  /// 页面设置及网络状态允许选择。
  final bool enabled;

  /// Platform-specific glyph without changing the picker lifecycle.
  final IconData icon;

  /// 创建附件选择入口。
  const AssistantAttachmentButton({
    required this.attachments,
    required this.enabled,
    this.icon = Icons.attach_file,
    super.key,
  });

  /// 原生文件选择器的在途状态只存在当前按钮。
  @override
  State<AssistantAttachmentButton> createState() =>
      _AssistantAttachmentButtonState();
}

/// 防止重复打开系统文件选择器。
class _AssistantAttachmentButtonState extends State<AssistantAttachmentButton> {
  /// 原生选择窗口是否打开。
  bool _picking = false;

  /// 把选择结果交给附件控制器，原文件只读。
  Future<void> _pick() async {
    // 系统选择器打开期间用户可能已切换聊天。
    final int draftToken = widget.attachments.draftToken;
    setState(() => _picking = true);
    try {
      // 原生过滤仅改善选择体验，控制器仍复验类型及大小。
      final List<PlatformFile> files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions:
            (widget.attachments.capabilities['extensions'] as List)
                .cast<String>(),
      );
      if (!mounted ||
          !widget.attachments.editable ||
          draftToken != widget.attachments.draftToken) {
        return;
      }
      // 路径可直接流式复制；无路径时才读取已受大小限制的内容。
      final List<AssistantPickedFile> picked = <AssistantPickedFile>[];
      for (final PlatformFile file in files) {
        if (await file.length() >
            ((widget.attachments.capabilities['maxFileBytes'] as num?)
                    ?.toInt() ??
                20 * 1024 * 1024)) {
          throw const ApiFailure('附件超过单文件大小限制');
        }
        picked.add(
          AssistantPickedFile(
            name: file.name,
            sourcePath: file.path,
            bytes: file.path == null ? await file.readAsBytes() : null,
          ),
        );
      }
      await widget.attachments.add(picked);
    } catch (failure) {
      if (mounted) {
        showOmniMessage(
          context,
          message: failure is ApiFailure ? failure.message : '无法选择附件，请重试',
          tone: OmniMessageTone.error,
        );
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// 旧服务端能力关闭时完全隐藏入口。
  @override
  Widget build(BuildContext context) => !widget.attachments.enabled
      ? const SizedBox.shrink()
      : OmniIconButton(
          key: const ValueKey<String>('assistant-attach-button'),
          tooltip: '添加图片或文档',
          icon: Icon(widget.icon),
          onPressed:
              widget.enabled &&
                  widget.attachments.editable &&
                  !widget.attachments.transferring &&
                  !_picking
              ? _pick
              : null,
        );
}

/// 可滚动的附件草稿卡片与解析状态；在窄屏大字号下按列换行。
class AssistantAttachmentDrafts extends StatelessWidget {
  /// 当前会话有序附件。
  final AssistantAttachments attachments;

  /// 当前真实模型能力。
  final Map<String, dynamic>? settings;

  /// Windows 输入区使用图片缩略图和紧凑文档预览，移动端保留触控列表。
  final bool desktopPreview;

  /// 创建上传状态区域。
  const AssistantAttachmentDrafts({
    required this.attachments,
    required this.settings,
    this.desktopPreview = false,
    super.key,
  });

  /// 构建能适应输入框剩余宽度的单列卡片。
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (desktopPreview && attachments.hasDrafts)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SizedBox(
              height:
                  144 +
                  math.max(0, MediaQuery.textScalerOf(context).scale(12) - 12) *
                      3,
              child: ListView.separated(
                key: const ValueKey<String>('assistant-draft-previews'),
                scrollDirection: Axis.horizontal,
                itemCount: attachments.drafts.length,
                separatorBuilder: (BuildContext context, int index) =>
                    const SizedBox(width: 12),
                itemBuilder: (BuildContext context, int index) =>
                    _AssistantDraftPreview(
                      key: ValueKey<String>(
                        'assistant-draft-${attachments.drafts[index]['id']}',
                      ),
                      item: attachments.drafts[index],
                      attachments: attachments,
                    ),
              ),
            ),
          )
        else
          for (final Map<String, dynamic> item in attachments.drafts)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: OmniColors.of(context).mist,
                  borderRadius: BorderRadius.circular(OmniRadius.control),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Icon(
                        item['kind'] == 'image'
                            ? Icons.image_outlined
                            : Icons.description_outlined,
                        size: 20,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              '${item['name']}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13),
                            ),
                            Text(
                              <String>[
                                assistantAttachmentSize(item),
                                assistantAttachmentStatus(item),
                              ].where((value) => value.isNotEmpty).join(' · '),
                              style: TextStyle(
                                fontSize: 12,
                                color: OmniColors.of(context).muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (item['status'] == 'failed' && item['expired'] != true)
                        OmniIconButton(
                          tooltip: '重试附件',
                          icon: const Icon(Icons.refresh, size: 18),
                          onPressed: attachments.canEdit(item['id'] as String)
                              ? () => unawaited(
                                  attachments.retry(item['id'] as String),
                                )
                              : null,
                        ),
                      OmniIconButton(
                        tooltip: '移除附件',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: attachments.canEdit(item['id'] as String)
                            ? () => unawaited(
                                attachments.remove(item['id'] as String),
                              )
                            : null,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        if (attachments.error != null)
          Text(
            attachments.error!,
            style: TextStyle(
              fontSize: 12,
              color: OmniColors.of(context).danger,
            ),
          ),
      ],
    );
  }
}

/// 桌面草稿预览卡：原图只从当前私有副本读取，文档不执行内容预览。
class _AssistantDraftPreview extends StatefulWidget {
  /// 当前附件元数据，重建时保留对应身份的悬停状态。
  final Map<String, dynamic> item;

  /// 统一移除、重试及冻结门禁。
  final AssistantAttachments attachments;

  /// 创建独立附件预览。
  const _AssistantDraftPreview({
    required this.item,
    required this.attachments,
    super.key,
  });

  /// 保存鼠标与键盘反馈。
  @override
  State<_AssistantDraftPreview> createState() => _AssistantDraftPreviewState();
}

/// 悬停变暗并显示关闭；键盘焦点采用相同可见反馈。
class _AssistantDraftPreviewState extends State<_AssistantDraftPreview> {
  /// 鼠标位于整张卡片内。
  bool _hovered = false;

  /// 键盘已进入卡片操作。
  bool _focused = false;

  /// 本地缩略图不可读时回退图标，避免恢复草稿出现异常。
  Widget _imageFallback(
    BuildContext context,
    Object error,
    StackTrace? stack,
  ) => const Center(child: Icon(Icons.image_outlined, size: 32));

  /// 根据文件后缀展示识别符，不把服务端 MIME 作为可执行内容。
  String get _extension =>
      '${widget.item['name']}'.split('.').last.toUpperCase();

  /// 绘制缩略图、文档底栏及悬停操作。
  @override
  Widget build(BuildContext context) {
    // 当前附件稳定身份。
    final String id = widget.item['id'] as String;
    // 当前主题的中性表面及文字。
    final AssistantWindowsPalette colors = AssistantWindowsPalette.of(context);
    // 图片使用方形卡片，文档预留更宽的文件名。
    final bool image = widget.item['kind'] == 'image';
    // 只有真实本机副本可用作草稿预览，不读取远程 URL。
    final String? localPath = widget.item['localPath'] as String?;
    // 状态保留真实上传、解析、就绪与失败信息。
    final String status = assistantAttachmentStatus(widget.item);
    // 完整文件信息保留在无障碍描述中，不显示悬停浮层。
    final String description = <String>[
      '${widget.item['name']}',
      assistantAttachmentSize(widget.item),
      status,
    ].where((String value) => value.isNotEmpty).join(' · ');
    // 未知消息和正在传输的附件不允许移除或重试。
    final bool editable = widget.attachments.canEdit(id);
    // 鼠标与键盘共用操作显现状态，关闭按钮始终参与键盘导航。
    final bool active = _hovered || _focused;
    // 图片传输或解析失败时保留可见状态条。
    final bool imageStatus =
        image &&
        widget.item['status'] != 'ready' &&
        widget.item['status'] != 'local';
    return MouseRegion(
      key: ValueKey<String>('assistant-draft-hover-$id'),
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        canRequestFocus: false,
        onFocusChange: (bool focused) => setState(() => _focused = focused),
        child: Semantics(
          label: description,
          child: TooltipVisibility(
            visible: false,
            child: SizedBox(
              width: image ? 144 : 192,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(
                  AssistantWindowsMetrics.rowRadius,
                ),
                child: Container(
                  color: colors.soft,
                  foregroundDecoration: BoxDecoration(
                    border: Border.all(color: colors.line),
                    borderRadius: BorderRadius.circular(
                      AssistantWindowsMetrics.rowRadius,
                    ),
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      if (image && localPath != null)
                        Image.file(
                          File(localPath),
                          key: ValueKey<String>('assistant-draft-image-$id'),
                          fit: BoxFit.cover,
                          cacheWidth: 400,
                          errorBuilder: _imageFallback,
                        )
                      else if (image)
                        const Center(
                          child: Icon(Icons.image_outlined, size: 32),
                        )
                      else
                        Column(
                          children: <Widget>[
                            Expanded(
                              child: Center(
                                child: Icon(
                                  Icons.insert_drive_file_outlined,
                                  size: 30,
                                  color: colors.muted,
                                ),
                              ),
                            ),
                            Container(
                              width: double.infinity,
                              color: colors.canvas,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 7,
                              ),
                              child: Row(
                                children: <Widget>[
                                  Text(
                                    _extension,
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: _extension == 'PDF'
                                          ? OmniColors.of(context).danger
                                          : colors.muted,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: <Widget>[
                                        Text(
                                          '${widget.item['name']}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 13,
                                            color: colors.ink,
                                          ),
                                        ),
                                        Text(
                                          status,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: colors.muted,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      if (imageStatus)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: ColoredBox(
                            color: colors.canvas.withValues(alpha: .9),
                            child: Padding(
                              padding: const EdgeInsets.all(6),
                              child: Text(
                                status,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: colors.ink,
                                ),
                              ),
                            ),
                          ),
                        ),
                      IgnorePointer(
                        child: AnimatedOpacity(
                          key: ValueKey<String>('assistant-draft-mask-$id'),
                          opacity: active ? 1 : 0,
                          duration: OmniMotion.duration(
                            context,
                            OmniMotion.fast,
                          ),
                          child: ColoredBox(
                            color: Colors.black.withValues(alpha: .12),
                          ),
                        ),
                      ),
                      Positioned(
                        top: 4,
                        right: 4,
                        child: AnimatedOpacity(
                          opacity: active ? 1 : 0,
                          duration: OmniMotion.duration(
                            context,
                            OmniMotion.fast,
                          ),
                          alwaysIncludeSemantics: true,
                          child: IgnorePointer(
                            ignoring: !active,
                            child: Semantics(
                              label: '移除附件 ${widget.item['name']}',
                              child: ClipOval(
                                child: OmniIconButton(
                                  key: ValueKey<String>(
                                    'assistant-draft-remove-$id',
                                  ),
                                  tooltip: '移除附件 ${widget.item['name']}',
                                  icon: const Icon(Icons.close, size: 16),
                                  color: colors.canvas,
                                  constraints: const BoxConstraints.tightFor(
                                    width: 28,
                                    height: 28,
                                  ),
                                  style: IconButton.styleFrom(
                                    backgroundColor: colors.ink,
                                    foregroundColor: colors.canvas,
                                    shape: const CircleBorder(),
                                  ),
                                  onPressed: editable
                                      ? () => unawaited(
                                          widget.attachments.remove(id),
                                        )
                                      : null,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (widget.item['status'] == 'failed' &&
                          widget.item['expired'] != true)
                        Positioned(
                          left: 4,
                          top: 4,
                          child: Semantics(
                            label: '重试附件 ${widget.item['name']}',
                            child: OmniIconButton(
                              key: ValueKey<String>(
                                'assistant-draft-retry-$id',
                              ),
                              tooltip: '重试附件',
                              icon: const Icon(Icons.refresh, size: 18),
                              onPressed: editable
                                  ? () =>
                                        unawaited(widget.attachments.retry(id))
                                  : null,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 两端草稿和历史共用可读大小，不把缺失大小显示为零字节。
String assistantAttachmentSize(Map<String, dynamic> item) {
  // 字节数由实际上传文件或服务端元数据提供。
  final Object? value = item['size'];
  if (value is! num || value <= 0) return '';
  if (value < 1024) return '${value.toInt()} B';
  // 以二进制换算展示常用文件单位。
  final num divisor = value < 1048576 ? 1024 : 1048576;
  // 保留一位小数；整数大小不显示无意义的 .0。
  final String amount = (value / divisor).toStringAsFixed(
    value % divisor == 0 ? 0 : 1,
  );
  return '$amount ${value < 1048576 ? 'KB' : 'MB'}';
}

/// 状态信息避免向用户暴露服务端内部错误细节。
String assistantAttachmentStatus(Map<String, dynamic> item) =>
    item['localError'] is String
    ? item['localError'] as String
    : switch (item['status']) {
        'local' => '待发送',
        'uploading' => '正在上传…',
        'processing' => '正在解析…',
        'ready' => item['requiresVision'] == true ? '已就绪 · 需要视觉模型' : '已就绪',
        'failed' => switch (item['errorCode']) {
          'ATTACHMENT_ENCRYPTED' => '文件已加密，请先解除密码',
          'ATTACHMENT_TEXT_LIMIT' => '文档内容过长，请缩小范围后重新添加',
          _ => '解析失败，可重试或移除',
        },
        _ => '等待处理',
      };

/// 兼容明确附件字段和旧版附件卡片，防止重复显示。
List<Map<String, dynamic>> assistantMessageAttachments(
  Map<String, dynamic> message,
) {
  // 按身份保留服务端排序，现代字段优先。
  final Map<String, Map<String, dynamic>> byId =
      <String, Map<String, dynamic>>{};
  for (final Map<String, dynamic> item in <Map<String, dynamic>>[
    ...assistantItems(message['attachments']),
    ...assistantItems(message['cards'])
        .where((item) => item['type'] == 'attachment'),
  ]) {
    if (item['id'] is String) {
      byId.putIfAbsent(item['id'] as String, () => item);
    }
  }
  return byId.values.toList();
}

/// 历史附件通过私有接口预览和下载，离线时不尝试跨源读取。
class AssistantHistoryAttachments extends StatelessWidget {
  /// 当前消息的有序附件。
  final List<Map<String, dynamic>> items;

  /// 所属服务器认证仓储。
  final AssistantRepository? repository;

  /// 只有当前来源在线时允许网络读取。
  final bool enabled;

  /// 仅当前发送快照允许使用本机草稿图片，历史消息始终走鉴权接口。
  final bool localPreview;

  /// 创建历史附件列表。
  const AssistantHistoryAttachments({
    required this.items,
    required this.repository,
    required this.enabled,
    this.localPreview = false,
    super.key,
  });

  /// 每个卡片独立维护下载请求，消息流增量不会重复拉图。
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.end,
    children: <Widget>[
      if (items.any((item) => item['kind'] == 'image'))
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: SingleChildScrollView(
            key: const ValueKey<String>('assistant-history-images'),
            scrollDirection: Axis.horizontal,
            reverse: true,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (final Map<String, dynamic> item in items.where(
                  (item) => item['kind'] == 'image',
                ))
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: _HistoryAttachment(
                      key: ValueKey<String>('history-attachment-${item['id']}'),
                      item: item,
                      repository: repository,
                      enabled: enabled,
                      localPreview: localPreview,
                    ),
                  ),
              ],
            ),
          ),
        ),
      for (final Map<String, dynamic> item in items.where(
        (item) => item['kind'] != 'image',
      ))
        _HistoryAttachment(
          key: ValueKey<String>('history-attachment-${item['id']}'),
          item: item,
          repository: repository,
          enabled: enabled,
          localPreview: localPreview,
        ),
    ],
  );
}

/// 图片直接展示缩略图，文档以独立的文件名条目展示。
class _HistoryAttachment extends StatefulWidget {
  /// 已发送不可变附件。
  final Map<String, dynamic> item;

  /// 当前来源仓储。
  final AssistantRepository? repository;

  /// 网络操作可用状态。
  final bool enabled;

  /// 草稿副本仅用于发送中的临时缩略图。
  final bool localPreview;

  /// 创建私有预览卡片。
  const _HistoryAttachment({
    required this.item,
    required this.repository,
    required this.enabled,
    required this.localPreview,
    super.key,
  });

  /// 创建局部下载状态。
  @override
  State<_HistoryAttachment> createState() => _HistoryAttachmentState();
}

/// 附件内容只在当前预览中持有，不写进消息缓存。
class _HistoryAttachmentState extends State<_HistoryAttachment> {
  /// 禁止重复发出下载请求。
  bool _loading = false;

  /// 图片字节只在当前组件内存中持有，不进入持久缓存。
  Uint8List? _preview;

  /// 请求代次隔离迟到回执与切换后的身份。
  int _previewGeneration = 0;

  /// 首次出现时加载当前来源的图片缩略图。
  @override
  void initState() {
    super.initState();
    unawaited(_loadPreview());
  }

  /// 草稿转为历史消息、重连或换服时重新核对来源。
  @override
  void didUpdateWidget(covariant _HistoryAttachment oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository ||
        oldWidget.enabled != widget.enabled ||
        oldWidget.localPreview != widget.localPreview ||
        oldWidget.item['id'] != widget.item['id']) {
      _preview = null;
      unawaited(_loadPreview());
    }
  }

  /// 下载失败保留图片占位，用户仍可点击重试打开。
  Future<void> _loadPreview() async {
    // 每次更新即失效此前请求，包括切换到离线状态。
    final int generation = ++_previewGeneration;
    if (widget.item['kind'] != 'image' ||
        widget.localPreview ||
        !widget.enabled ||
        widget.repository?.isCurrent != true) {
      return;
    }
    try {
      // 私有原图仍经服务端归属校验，解码尺寸由缩略图限制。
      final Uint8List bytes = await widget.repository!.attachmentBytes(
        widget.item['id'] as String,
      );
      if (!mounted ||
          generation != _previewGeneration ||
          !widget.enabled ||
          widget.repository?.isCurrent != true) {
        return;
      }
      setState(() => _preview = bytes);
    } catch (_) {
      // 缩略图失败不打断聊天，打开操作会展示具体读取错误。
    }
  }

  /// 读取图片预览或经系统保存文档。
  Future<void> _open() async {
    // 固定本次点击的来源与身份，迟到下载不能在另一张附件上打开。
    final AssistantRepository? repository = widget.repository;
    // 固定附件身份，避免同一位置切换文件时误用下载结果。
    final String id = widget.item['id'] as String;
    setState(() => _loading = true);
    try {
      // 内容始终由设备认证接口获取。
      final Uint8List bytes =
          _preview ??
          await widget.repository!.attachmentBytes(widget.item['id'] as String);
      if (!mounted ||
          widget.repository != repository ||
          widget.item['id'] != id ||
          widget.repository?.isCurrent != true ||
          !widget.enabled) {
        return;
      }
      if (widget.item['kind'] == 'image') {
        await showOmniDialog<void>(
          context: context,
          builder: (BuildContext context) =>
              AssistantImagePreview(bytes: bytes),
        );
      } else {
        await FilePicker.saveFile(
          fileName: '${widget.item['name']}'.split(RegExp(r'[/\\]')).last,
          bytes: bytes,
          mimeType:
              widget.item['mimeType'] as String? ?? 'application/octet-stream',
        );
      }
    } catch (failure) {
      if (mounted) {
        showOmniMessage(
          context,
          message: failure is ApiFailure ? failure.message : '附件无法打开，请稍后重试',
          tone: OmniMessageTone.error,
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 图片横排缩略图；文档单独成行，长名称省略且不挤出消息宽度。
  @override
  Widget build(BuildContext context) {
    if (widget.item['kind'] == 'image') {
      return Semantics(
        label: '${widget.item['name']}',
        button: true,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(OmniRadius.panel),
          child: Material(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: InkWell(
              onTap:
                  !widget.localPreview &&
                      widget.enabled &&
                      widget.repository?.isCurrent == true &&
                      !_loading
                  ? _open
                  : null,
              child: SizedBox(
                width: 118,
                height: 118,
                child: widget.localPreview && widget.item['localPath'] is String
                    ? Image.file(
                        File(widget.item['localPath'] as String),
                        fit: BoxFit.cover,
                        cacheWidth: 360,
                        errorBuilder: (_, _, _) =>
                            const Icon(Icons.image_outlined),
                      )
                    : _preview != null
                    ? Image.memory(
                        _preview!,
                        fit: BoxFit.cover,
                        cacheWidth: 360,
                        errorBuilder: (_, _, _) =>
                            const Icon(Icons.broken_image_outlined),
                      )
                    : const Center(child: Icon(Icons.image_outlined)),
              ),
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: OmniTextButton(
        style: TextButton.styleFrom(
          foregroundColor: Theme.of(context).colorScheme.onSurface,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(OmniRadius.pill),
            side: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        ),
        onPressed:
            widget.enabled && widget.repository?.isCurrent == true && !_loading
            ? _open
            : null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.insert_drive_file_outlined, size: 18),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                _loading ? '正在读取…' : '${widget.item['name']}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
