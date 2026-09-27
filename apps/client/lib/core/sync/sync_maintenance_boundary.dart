import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/core/sync/sync_connection_coordinator.dart';
import 'package:omni_butler/core/sync/sync_connection_providers.dart';

/// 主窗口和悬浮窗共同使用的维护遮罩，阻止键盘和指针继续修改旧数据。
class SyncMaintenanceBoundary extends ConsumerWidget {
  /// 创建维护遮罩，悬浮窗仅展示简短提示。
  const SyncMaintenanceBoundary({
    super.key,
    required this.child,
    this.compact = false,
  });

  /// 原应用内容保留挂载，避免异步弹窗调用已销毁的 Navigator。
  final Widget child;

  /// 是否显示适合悬浮小窗的提示。
  final bool compact;

  /// 构建覆盖全部页面和弹窗的维护状态。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 当前协调器；测试和纯本机模式允许不提供。
    final SyncConnectionCoordinator? coordinator = ref.watch(
      syncConnectionCoordinatorProvider,
    );
    // 第一帧也采用持久恢复出的维护状态。
    final SyncConnectionState state =
        ref.watch(syncConnectionStateProvider).value ??
        coordinator?.state ??
        const SyncConnectionState();
    ref.listen(
      syncConnectionStateProvider.select((value) => value.value?.generation),
      (previous, next) {
        if (previous == next || coordinator == null) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(coordinator.releaseRetired());
        });
      },
    );
    if (coordinator == null && !state.maintenance) return child;
    return Stack(
      children: [
        ExcludeFocus(
          excluding: state.maintenance,
          child: AbsorbPointer(absorbing: state.maintenance, child: child),
        ),
        if (state.maintenance)
          Positioned.fill(
            child: Material(
              color: Theme.of(context).colorScheme.surface,
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (state.busy) const CircularProgressIndicator(),
                        const SizedBox(height: 16),
                        Text(
                          compact ? '正在迁移，请在主窗口继续' : state.message,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        if (!compact) ...[
                          const SizedBox(height: 12),
                          const Text(
                            '原本机数据已保留。迁移期间暂停编辑，完成后自动恢复。',
                            textAlign: TextAlign.center,
                          ),
                          if (state.error != null) ...[
                            const SizedBox(height: 12),
                            SelectableText(
                              state.error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ],
                          if (!state.busy && coordinator != null) ...[
                            const SizedBox(height: 20),
                            Wrap(
                              spacing: 12,
                              runSpacing: 8,
                              children: [
                                FilledButton(
                                  onPressed: () async {
                                    try {
                                      await coordinator.resume();
                                    } catch (_) {
                                      /* 错误已持久反映在维护状态。 */
                                    }
                                  },
                                  child: const Text('继续迁移'),
                                ),
                                if (state.canCancel)
                                  TextButton(
                                    onPressed: () async {
                                      try {
                                        await coordinator.cancel();
                                      } catch (_) {
                                        /* 保持维护门禁。 */
                                      }
                                    },
                                    child: const Text('取消，保留本机数据'),
                                  ),
                              ],
                            ),
                          ],
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
