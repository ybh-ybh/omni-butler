import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_providers.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
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

  /// 可选的部署 API 路径，默认值与服务端一致。
  final TextEditingController _apiPrefixController = TextEditingController(
    text: 'api/v1',
  );

  /// 是否隐藏同步密钥。
  bool _obscureSyncKey = true;

  /// 释放文本输入控制器。
  @override
  void dispose() {
    _serverController.dispose();
    _portController.dispose();
    _syncKeyController.dispose();
    _apiPrefixController.dispose();
    super.dispose();
  }

  /// 构建同步服务连接表单。
  @override
  Widget build(BuildContext context) {
    // 当前设备会话异步状态。
    final AsyncValue<SyncSession?> sessionState = ref.watch(
      authControllerProvider,
    );
    // 是否正在提交。
    final bool isLoading = sessionState.isLoading;

    return OmniSideSheetScaffold(
      title: '连接自托管同步服务',
      canClose: !isLoading,
      actions: <Widget>[
        OmniButton(
          label: '稍后再说',
          variant: OmniButtonVariant.secondary,
          onPressed: isLoading ? null : () => Navigator.pop(context, false),
        ),
        OmniButton(label: '连接', loading: isLoading, onPressed: _submit),
      ],
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(OmniSpacing.xl),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                '填写服务器地址、端口和同步密钥；API 路径通常保持默认即可。',
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
              const SizedBox(height: OmniSpacing.md),
              TextFormField(
                controller: _apiPrefixController,
                enabled: !isLoading,
                decoration: const InputDecoration(
                  labelText: 'API 路径（可选）',
                  hintText: 'api/v1',
                  helperText: '与服务器 API_PREFIX 一致，不加首尾斜杠；留空使用默认值',
                ),
                validator: _validateApiPrefix,
                onFieldSubmitted: isLoading ? null : (_) => _submit(),
              ),
              if (sessionState.hasError) ...<Widget>[
                const SizedBox(height: OmniSpacing.md),
                Text(
                  sessionState.error.toString(),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
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

  /// 提交前复用认证仓储的路径校验，避免发送到错误端点。
  String? _validateApiPrefix(String? value) {
    try {
      AuthRepository.normalizeApiPrefix(value ?? '');
      return null;
    } on ApiFailure catch (error) {
      return error.toString();
    }
  }

  /// 提交同步服务连接表单。
  Future<void> _submit() async {
    if (_formKey.currentState?.validate() != true) {
      return;
    }
    await ref
        .read(authControllerProvider.notifier)
        .connect(
          apiBaseUrl:
              '${_serverController.text.trim()}:${_portController.text.trim()}',
          syncKey: _syncKeyController.text.trim(),
          apiPrefix: _apiPrefixController.text,
        );
    if (!mounted) {
      return;
    }
    // 成功建立的设备同步会话。
    final SyncSession? session = ref.read(authControllerProvider).value;
    if (session != null) {
      Navigator.pop(context, true);
    }
  }
}
