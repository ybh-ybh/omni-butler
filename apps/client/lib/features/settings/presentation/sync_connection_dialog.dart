import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_providers.dart';
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

  /// API 根地址控制器。
  final TextEditingController _serverController = TextEditingController(
    text: 'http://127.0.0.1:3000/api/v1',
  );

  /// 同步密钥控制器。
  final TextEditingController _syncKeyController = TextEditingController();

  /// 是否隐藏同步密钥。
  bool _obscureSyncKey = true;

  /// 释放文本输入控制器。
  @override
  void dispose() {
    _serverController.dispose();
    _syncKeyController.dispose();
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
                '无需注册账号。填写服务器地址和部署时设置的同步密钥即可连接。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: OmniSpacing.lg),
              TextFormField(
                controller: _serverController,
                enabled: !isLoading,
                decoration: const InputDecoration(
                  labelText: '服务器 URL',
                  hintText: 'https://api.example.com/api/v1',
                ),
                keyboardType: TextInputType.url,
                validator: _required,
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

  /// 校验必填文本。
  String? _required(String? value) {
    return value == null || value.trim().isEmpty ? '此项不能为空' : null;
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
    if (_formKey.currentState?.validate() != true) {
      return;
    }
    await ref
        .read(authControllerProvider.notifier)
        .connect(
          apiBaseUrl: _serverController.text,
          syncKey: _syncKeyController.text.trim(),
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
