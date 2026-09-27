import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/core/sync/sync_connection_coordinator.dart';
import 'package:omni_butler/core/sync/sync_connection_providers.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 查看迁移保留的本机备份及其确切位置。
Future<void> showSyncBackupDialog(BuildContext context) => showOmniDialog<void>(
  context: context,
  builder: (BuildContext context) => const _SyncBackupDialog(),
);

/// 本机迁移备份列表与明确的单份清理操作。
class _SyncBackupDialog extends ConsumerStatefulWidget {
  /// 创建备份管理界面。
  const _SyncBackupDialog();

  /// 创建只管理自身异步请求的状态。
  @override
  ConsumerState<_SyncBackupDialog> createState() => _SyncBackupDialogState();
}

/// 备份列表状态。
class _SyncBackupDialogState extends ConsumerState<_SyncBackupDialog> {
  /// 正在加载或清理时禁止重复操作。
  bool _busy = true;

  /// 当前已登记备份。
  List<Map<String, dynamic>> _backups = [];

  /// 可见的操作失败说明。
  String? _error;

  /// 进入界面即读取独立控制库。
  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 重新读取备份，取消不触碰任何文件。
  Future<void> _load() async {
    try {
      // 生产迁移协调器。
      final SyncConnectionCoordinator? coordinator = ref.read(
        syncConnectionCoordinatorProvider,
      );
      // 最新备份索引。
      final List<Map<String, dynamic>> backups =
          await coordinator?.store.backups() ?? [];
      if (mounted) {
        setState(() {
          _backups = backups;
          _busy = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _busy = false;
        });
      }
    }
  }

  /// 用户确认后只清理指定旧库及快照，共享图片文件始终保留。
  Future<void> _delete(Map<String, dynamic> backup) async {
    // 二次确认清理范围。
    final bool? confirmed = await showOmniDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => OmniDialogScaffold(
        title: '删除这份迁移备份？',
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('将删除这份旧数据库和迁移快照，无法撤销。当前数据库、服务器数据和本机图片文件不会删除。'),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: [
                OmniButton(
                  label: '取消',
                  variant: OmniButtonVariant.secondary,
                  onPressed: () => Navigator.pop(dialogContext, false),
                ),
                OmniButton(
                  label: '删除备份',
                  variant: OmniButtonVariant.danger,
                  onPressed: () => Navigator.pop(dialogContext, true),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(syncConnectionCoordinatorProvider)!
          .deleteBackup(backup['id'] as String);
      await _load();
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error.toString();
        });
      }
    }
  }

  /// 展示可复制的位置和逐份清理按钮。
  @override
  Widget build(BuildContext context) => OmniDialogScaffold(
    title: '本机迁移备份',
    width: 640,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 480),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('迁移成功后，原数据库作为备份保留。图片文件仍在本机，清理备份不会删除共享图片。'),
            const SizedBox(height: 12),
            if (_busy) const LinearProgressIndicator(),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (!_busy && _backups.isEmpty) const Text('暂无迁移备份'),
            for (final Map<String, dynamic> backup in _backups)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('迁移时间：${backup['createdAt']}'),
                    const SizedBox(height: 4),
                    SelectableText(
                      '数据库：${backup['databasePath']}\n快照：${backup['snapshotPath']}',
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: OmniButton(
                        label: '清理这份备份',
                        variant: OmniButtonVariant.text,
                        onPressed: _busy ? null : () => _delete(backup),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
