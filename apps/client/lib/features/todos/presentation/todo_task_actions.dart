import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 将任务行操作统一为添加子任务的尺寸，触屏保留完整点击区域。
ButtonStyle todoTaskActionButtonStyle(BuildContext context, Color color) {
  return OmniDensity.isTouch(context)
      ? IconButton.styleFrom(
          foregroundColor: color,
          fixedSize: const Size.square(OmniSize.touch),
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        )
      : IconButton.styleFrom(foregroundColor: color);
}

/// 用右键、长按和键盘菜单键打开原任务操作菜单。
class TodoTaskContextMenu extends StatefulWidget {
  /// 当前任务行。
  final Widget child;

  /// 编辑当前任务。
  final VoidCallback onEdit;

  /// 删除当前任务。
  final VoidCallback onDelete;

  /// 主任务可移动到其他象限，子任务没有此入口。
  final VoidCallback? onMove;

  /// 提交或离场时禁用菜单。
  final bool enabled;

  /// 创建没有可见更多按钮的任务菜单容器。
  const TodoTaskContextMenu({
    required this.child,
    required this.onEdit,
    required this.onDelete,
    this.onMove,
    this.enabled = true,
    super.key,
  });

  /// 创建菜单交互状态。
  @override
  State<TodoTaskContextMenu> createState() => _TodoTaskContextMenuState();
}

/// 统一路由指针菜单和键盘菜单请求。
class _TodoTaskMenuIntent extends Intent {
  /// 创建打开任务菜单的意图。
  const _TodoTaskMenuIntent();
}

/// 管理指针定位和菜单防重入。
class _TodoTaskContextMenuState extends State<TodoTaskContextMenu> {
  /// 当前是否已打开菜单。
  bool _menuOpen = false;

  /// 在当前导航覆盖层中按指针位置显示原有菜单。
  Future<void> _showContextMenu(Offset globalPosition) async {
    if (!widget.enabled || _menuOpen) return;
    _menuOpen = true;
    try {
      // 当前窗口的导航覆盖层，兼容嵌套滚动与多窗口。
      final RenderBox overlay =
          Navigator.of(context).overlay!.context.findRenderObject()!
              as RenderBox;
      // 指针在覆盖层中的实际位置。
      final Offset position = overlay.globalToLocal(globalPosition);
      // 用户选择的动作，取消菜单时为空。
      final String? action = await showMenu<String>(
        context: context,
        position: RelativeRect.fromRect(
          position & Size.zero,
          Offset.zero & overlay.size,
        ),
        menuPadding: const EdgeInsets.all(OmniSpacing.xxs),
        constraints: const BoxConstraints(
          minWidth: OmniDropdownMetrics.actionMenuMinWidth,
          maxWidth: OmniDropdownMetrics.actionMenuMaxWidth,
        ),
        popUpAnimationStyle: OmniMotion.reduce(context)
            ? AnimationStyle.noAnimation
            : const AnimationStyle(
                duration: OmniMotion.fast,
                reverseDuration: OmniMotion.fast,
                curve: OmniMotion.standardCurve,
                reverseCurve: Curves.easeInCubic,
              ),
        items: <PopupMenuEntry<String>>[
          OmniPopupMenuItem<String>(
            value: 'edit',
            label: '编辑',
            icon: Icons.edit_outlined,
          ),
          if (widget.onMove != null)
            OmniPopupMenuItem<String>(
              value: 'move',
              label: '移动象限',
              icon: Icons.drive_file_move_outline,
            ),
          OmniPopupMenuItem<String>(
            value: 'delete',
            label: '移入回收站',
            icon: Icons.delete_outline_rounded,
            danger: true,
          ),
        ],
      );
      if (!mounted || !widget.enabled) return;
      if (action == 'edit') widget.onEdit();
      if (action == 'move') widget.onMove?.call();
      if (action == 'delete') widget.onDelete();
    } finally {
      _menuOpen = false;
    }
  }

  /// 键盘菜单定位到当前任务行，不依赖最后一次鼠标位置。
  void _showKeyboardMenu() {
    // 当前任务行的渲染区域。
    final RenderBox box = context.findRenderObject()! as RenderBox;
    unawaited(
      _showContextMenu(box.localToGlobal(box.size.center(Offset.zero))),
    );
  }

  /// 保留子按钮的点击行为，右键和长按仅打开任务菜单。
  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.contextMenu): _TodoTaskMenuIntent(),
        SingleActivator(LogicalKeyboardKey.f10, shift: true):
            _TodoTaskMenuIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _TodoTaskMenuIntent: CallbackAction<_TodoTaskMenuIntent>(
            onInvoke: (_) {
              _showKeyboardMenu();
              return null;
            },
          ),
        },
        child: OmniPressSurface(
          enabled: widget.enabled,
          borderRadius: BorderRadius.circular(OmniRadius.control),
          onSecondaryTapUp: widget.enabled
              ? (details) => unawaited(_showContextMenu(details.globalPosition))
              : null,
          onLongPressStart: widget.enabled
              ? (details) => unawaited(_showContextMenu(details.globalPosition))
              : null,
          child: widget.child,
        ),
      ),
    );
  }
}
