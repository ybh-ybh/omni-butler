import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/sync/sync_connection_coordinator.dart';
import 'package:omni_butler/core/sync/sync_connection_providers.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 显示自托管同步服务连接对话框。
Future<bool> showSyncConnectionDialog(BuildContext context) async {
  return await showOmniSideSheet<bool>(
        context,
        builder: (BuildContext context) => const _SyncConnectionDialog(),
      ) ??
      false;
}

/// 自托管同步服务连接对话框。
class _SyncConnectionDialog extends ConsumerStatefulWidget {
  /// 创建同步服务连接对话框。
  const _SyncConnectionDialog();

  /// 创建同步服务连接对话框状态。
  @override
  ConsumerState<_SyncConnectionDialog> createState() =>
      _SyncConnectionDialogState();
}

/// 自托管同步服务连接对话框状态。
class _SyncConnectionDialogState extends ConsumerState<_SyncConnectionDialog> {
  /// 表单状态键。
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  /// 服务器 IP 地址或域名控制器。
  final TextEditingController _serverController = TextEditingController(
    text: '127.0.0.1',
  );

  /// API 宿主机端口控制器。
  final TextEditingController _portController = TextEditingController(
    text: '3000',
  );

  /// 同步密钥控制器。
  final TextEditingController _syncKeyController = TextEditingController();

  /// 是否隐藏同步密钥。
  bool _obscureSyncKey = true;

  /// 只读预检得到的双方数据和身份。
  SyncConnectionPreview? _preview;

  /// 默认保留服务器数据，远端替换必须由用户主动选择。
  SyncConnectionStrategy _strategy = SyncConnectionStrategy.replaceLocal;

  /// 当前表单请求是否正在执行。
  bool _isLoading = false;

  /// 当前步骤可直接展示的失败原因。
  String? _error;

  /// 释放文本输入控制器。
  @override
  void dispose() {
    _serverController.dispose();
    _portController.dispose();
    _syncKeyController.dispose();
    super.dispose();
  }

  /// 根据已经确认的策略明确标注最终影响。
  String _confirmationLabel(SyncConnectionPreview preview) {
    if (preview.isReconnect) return '继续原服务器同步';
    return switch (_strategy) {
      SyncConnectionStrategy.mergeInitial => '合并本机与服务器数据',
      SyncConnectionStrategy.replaceServer => '以本机数据覆盖此服务器',
      SyncConnectionStrategy.replaceLocal => '使用服务器数据替换本机',
    };
  }

  /// 显示来源、目标、数量和不可误解的数据替换方向。
  List<Widget> _buildConfirmation(SyncConnectionPreview preview) {
    return <Widget>[
      Text(
        '本机来源：${preview.sourceAddress ?? (preview.localOwnerId == null ? '从未连接服务器' : '历史服务器（未保存地址）')}',
      ),
      const SizedBox(height: OmniSpacing.sm),
      Text('目标服务器：${preview.serverAddress}'),
      const SizedBox(height: OmniSpacing.lg),
      Text('本机：${preview.localTotal} 条记录 · 回收站 ${preview.localDeletedCount} 条'),
      Text(
        '服务器：${preview.remoteTotal} 条记录 · 回收站 ${preview.remoteDeletedCount} 条',
      ),
      Text('本机尚未上传：${preview.queuedOperations} 项操作'),
      const SizedBox(height: OmniSpacing.lg),
      if (preview.isReconnect)
        const Text('服务器身份与本机数据来源相同，将继续原有同步，不替换任一侧数据。')
      else if (preview.localOwnerId == null)
        const Text(
          '首次连接会合并双方数据；相同 ID 使用服务器已有记录。应用设置保留在本机，物品和会员图片在目标开启图片同步后自动补传。',
        )
      else ...<Widget>[
        RadioGroup<SyncConnectionStrategy>(
          groupValue: _strategy,
          onChanged: (SyncConnectionStrategy? value) {
            if (!_isLoading && value != null) setState(() => _strategy = value);
          },
          child: Column(
            children: <Widget>[
              RadioListTile<SyncConnectionStrategy>(
                value: SyncConnectionStrategy.replaceLocal,
                title: const Text('保留服务器数据'),
                subtitle: const Text('替换本机业务数据及待上传修改；保留应用设置，匹配记录恢复本机图片。'),
                enabled: !_isLoading,
                contentPadding: EdgeInsets.zero,
              ),
              RadioListTile<SyncConnectionStrategy>(
                value: SyncConnectionStrategy.replaceServer,
                title: const Text('保留本机数据'),
                subtitle: const Text('完整替换目标服务器的业务数据；本机图片和应用设置全部保留。'),
                enabled: !_isLoading,
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
        ),
        const SizedBox(height: OmniSpacing.sm),
        const Text('旧本机数据库会保留为迁移备份。'),
        if (_strategy == SyncConnectionStrategy.replaceServer &&
            preview.localTotal == 0 &&
            preview.remoteTotal > 0) ...<Widget>[
          const SizedBox(height: OmniSpacing.md),
          Text(
            '本机没有业务记录：将清空服务器全部业务记录。',
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ],
      if (!preview.isReconnect &&
          _strategy != SyncConnectionStrategy.replaceLocal &&
          preview.missingImages.isNotEmpty) ...<Widget>[
        const SizedBox(height: OmniSpacing.md),
        Text('有 ${preview.missingImages.length} 张图片在本机没有文件，将继续迁移业务数据：'),
        for (final String image in preview.missingImages) Text(image),
      ],
    ];
  }

  /// 构建同步服务连接表单。
  @override
  Widget build(BuildContext context) {
    // 是否正在提交。
    final bool isLoading = _isLoading;
    // 当前两步流程所处的确认阶段。
    final SyncConnectionPreview? preview = _preview;

    return PopScope<bool>(
      canPop: !isLoading,
      child: OmniSideSheetScaffold(
        title: preview == null ? '连接自托管同步服务' : '确认数据处理方式',
        canClose: !isLoading,
        actions: <Widget>[
          Expanded(
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: OmniSpacing.xs,
              runSpacing: OmniSpacing.xs,
              children: <Widget>[
                OmniButton(
                  label: '取消',
                  variant: OmniButtonVariant.secondary,
                  onPressed: isLoading
                      ? null
                      : () => Navigator.pop(context, false),
                ),
                if (preview != null)
                  OmniButton(
                    label: '返回修改',
                    variant: OmniButtonVariant.text,
                    onPressed: isLoading
                        ? null
                        : () => setState(() {
                            _preview = null;
                            _error = null;
                          }),
                  ),
                OmniButton(
                  label: preview == null
                      ? '检查服务器'
                      : _confirmationLabel(preview),
                  variant:
                      preview != null &&
                          !preview.isReconnect &&
                          _strategy != SyncConnectionStrategy.mergeInitial
                      ? OmniButtonVariant.danger
                      : OmniButtonVariant.primary,
                  loading: isLoading,
                  onPressed: isLoading
                      ? null
                      : (preview == null ? _submit : _confirm),
                ),
              ],
            ),
          ),
        ],
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(OmniSpacing.xl),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (preview != null) ..._buildConfirmation(preview),
                if (preview == null) ...<Widget>[
                  Text(
                    '填写服务器地址、端口和同步密钥。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: OmniSpacing.lg),
                  TextFormField(
                    controller: _serverController,
                    enabled: !isLoading,
                    decoration: const InputDecoration(
                      labelText: '服务器地址',
                      hintText: '192.168.1.10 或 api.example.com',
                      helperText: '局域网 IP 默认使用 HTTP，公网地址默认使用 HTTPS',
                    ),
                    keyboardType: TextInputType.url,
                    validator: _validateServerAddress,
                  ),
                  const SizedBox(height: OmniSpacing.md),
                  TextFormField(
                    controller: _portController,
                    enabled: !isLoading,
                    decoration: const InputDecoration(
                      labelText: '端口',
                      hintText: '3000',
                    ),
                    keyboardType: TextInputType.number,
                    validator: _validatePort,
                  ),
                  const SizedBox(height: OmniSpacing.md),
                  TextFormField(
                    controller: _syncKeyController,
                    enabled: !isLoading,
                    obscureText: _obscureSyncKey,
                    decoration: InputDecoration(
                      labelText: '同步密钥',
                      helperText: '与服务器 SYNC_SECRET 配置保持一致，至少 16 个字符',
                      suffixIcon: IconButton(
                        onPressed: isLoading
                            ? null
                            : () => setState(
                                () => _obscureSyncKey = !_obscureSyncKey,
                              ),
                        icon: Icon(
                          _obscureSyncKey
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                    ),
                    autofillHints: const <String>[AutofillHints.password],
                    onFieldSubmitted: isLoading ? null : (_) => _submit(),
                    validator: _validateSyncKey,
                  ),
                ],
                if (_error != null) ...<Widget>[
                  const SizedBox(height: OmniSpacing.md),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 校验独立的主机输入，避免端口或路径与单独的端口栏混用。
  String? _validateServerAddress(String? value) {
    // 清理误输入空格后的服务器地址。
    final String address = value?.trim() ?? '';
    if (address.isEmpty) return '请输入服务器 IP 地址或域名';
    // 允许为 HTTPS 局域网服务显式指定协议。
    final Uri? uri = Uri.tryParse(
      address.contains('://') ? address : 'http://$address',
    );
    if (uri == null ||
        uri.host.isEmpty ||
        uri.host.contains(RegExp(r'\s')) ||
        uri.hasPort ||
        RegExp(r':\d+$').hasMatch(address) ||
        uri.path.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty) {
      return '请只填写 IP 地址或域名，端口在下方填写';
    }
    return null;
  }

  /// 校验宿主机端口范围。
  String? _validatePort(String? value) {
    // 去除空格后的端口文本。
    final String text = value?.trim() ?? '';
    // 解析得到的端口数值。
    final int? port = int.tryParse(text);
    return !RegExp(r'^\d+$').hasMatch(text) ||
            port == null ||
            port < 1 ||
            port > 65535
        ? '端口必须是 1 到 65535 之间的整数'
        : null;
  }

  /// 校验同步密钥长度。
  String? _validateSyncKey(String? value) {
    // 去除误输入空格后的同步密钥。
    final String syncKey = value?.trim() ?? '';
    if (syncKey.length < 16) {
      return '同步密钥至少需要 16 个字符';
    }
    return null;
  }

  /// 提交同步服务连接表单。
  Future<void> _submit() async {
    if (_isLoading || _formKey.currentState?.validate() != true) {
      return;
    }
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      // 只有协调器可以建立连接，缺失时不绕过身份和快照检查。
      final SyncConnectionCoordinator? coordinator = ref.read(
        syncConnectionCoordinatorProvider,
      );
      if (coordinator == null) throw StateError('同步连接尚未就绪，请重启应用后重试');
      // 预检不创建会话、不修改本机或目标服务器数据。
      final SyncConnectionPreview preview = await coordinator.preview(
        serverAddress:
            '${_serverController.text.trim()}:${_portController.text.trim()}',
        syncKey: _syncKeyController.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _strategy = preview.localOwnerId == null
            ? SyncConnectionStrategy.mergeInitial
            : SyncConnectionStrategy.replaceLocal;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// 用户确认具体影响后才执行连接或数据迁移。
  Future<void> _confirm() async {
    // 固定当前已经展示给用户的数据来源预览。
    final SyncConnectionPreview? preview = _preview;
    if (_isLoading || preview == null) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      // 统一协调器负责维护锁、断点恢复及成功验证。
      final SyncConnectionCoordinator? coordinator = ref.read(
        syncConnectionCoordinatorProvider,
      );
      if (coordinator == null) throw StateError('同步连接尚未就绪，请重启应用后重试');
      if (preview.isReconnect) {
        await coordinator.reconnect(
          preview: preview,
          syncKey: _syncKeyController.text.trim(),
        );
      } else {
        await coordinator.start(
          preview: preview,
          syncKey: _syncKeyController.text.trim(),
          strategy: _strategy,
        );
      }
      if (mounted) Navigator.pop(context, true);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }
}
