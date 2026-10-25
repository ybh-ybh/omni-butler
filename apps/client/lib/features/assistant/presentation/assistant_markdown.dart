import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';
import 'package:url_launcher/url_launcher.dart';

/// 助手使用完整 Markdown 显示回答，原始正文继续用于缓存和保存笔记。
class AssistantMarkdown extends StatelessWidget {
  /// 未经修改的模型正文，流式更新时重新解析当前已接收内容。
  final String source;

  /// 两端各自的正文字体和颜色，保留用户字号缩放。
  final TextStyle? style;

  /// 创建可选择的回答正文，不接管外层会话滚动。
  const AssistantMarkdown({required this.source, this.style, super.key});

  /// 网页链接仅在用户主动点击时打开，不执行模型给出的其他协议。
  Future<void> _openLink(BuildContext context, String? href) async {
    // 解析失败和非网页地址不交给系统执行。
    final Uri? uri = href == null ? null : Uri.tryParse(href);
    if (uri == null ||
        !uri.hasAuthority ||
        !<String>{'https', 'http'}.contains(uri.scheme)) {
      return;
    }
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    } catch (_) {
      // 平台无法启动浏览器时统一反馈，不回显任意模型地址。
    }
    if (context.mounted) {
      showOmniMessage(
        context,
        message: '链接暂时无法打开',
        tone: OmniMessageTone.error,
      );
    }
  }

  /// Markdown 的表格与代码块各自横向滚动，正文使用会话已有纵向滚动。
  @override
  Widget build(BuildContext context) {
    // 使用当前主题补齐颜色和字体，不覆盖系统文本缩放。
    final TextStyle body = Theme.of(context).textTheme.bodyMedium!.merge(style);
    // 代码、表格和引用与明暗主题保持一致。
    final ColorScheme colors = Theme.of(context).colorScheme;
    // 标题按回答基准字号建立层级，避免桌面正文和标题比例脱节。
    final double fontSize = body.fontSize ?? 14;
    return SelectionArea(
      child: MarkdownBody(
        data: source,
        fitContent: false,
        styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
          p: body,
          h1: body.copyWith(
            fontSize: fontSize * 1.5,
            fontWeight: FontWeight.w600,
          ),
          h2: body.copyWith(
            fontSize: fontSize * 1.3,
            fontWeight: FontWeight.w600,
          ),
          h3: body.copyWith(
            fontSize: fontSize * 1.15,
            fontWeight: FontWeight.w600,
          ),
          h4: body.copyWith(fontWeight: FontWeight.w600),
          h5: body.copyWith(fontWeight: FontWeight.w600),
          h6: body.copyWith(fontWeight: FontWeight.w600),
          listBullet: body,
          blockquote: body,
          // 列表条目共用 Markdown 块间距，缩至 4dp 避免逐项出现大段留白。
          blockSpacing: OmniSpacing.xxs,
          code: body.copyWith(
            fontFamily: 'monospace',
            backgroundColor: colors.surfaceContainerHighest,
          ),
          codeblockDecoration: BoxDecoration(
            color: colors.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(OmniRadius.control),
          ),
          codeblockPadding: const EdgeInsets.all(OmniSpacing.sm),
          tableHead: body.copyWith(fontWeight: FontWeight.w600),
          tableBody: body,
          tableColumnWidth: const IntrinsicColumnWidth(),
          tableBorder: TableBorder.all(color: colors.outlineVariant),
          tableCellsPadding: const EdgeInsets.all(OmniSpacing.sm),
          tableHeadCellsDecoration: BoxDecoration(
            color: colors.surfaceContainerLow,
          ),
          blockquoteDecoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: colors.outlineVariant, width: 3),
            ),
          ),
        ),
        onTapLink: (_, href, _) => unawaited(_openLink(context, href)),
        // 附件图片由鉴权卡片展示；模型 Markdown 不能隐式读取本地文件或远程图片。
        imageBuilder: (_, _, alt) =>
            Text(alt?.isNotEmpty == true ? '[图片：$alt]' : '[图片]', style: body),
      ),
    );
  }
}
