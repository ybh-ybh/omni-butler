import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_providers.dart';
import 'package:omni_butler/features/settings/data/ai_settings_repository.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 桌面与 Android 共用的模型配置和笔记整理设置。
class AiSettingsSection extends ConsumerStatefulWidget {
  /// 创建独立 AI 设置区。
  const AiSettingsSection({super.key});

  /// 创建设置区状态。
  @override
  ConsumerState<AiSettingsSection> createState() => _AiSettingsSectionState();
}

/// 页面仅保留操作状态，不持久化模型密钥。
class _AiSettingsSectionState extends ConsumerState<AiSettingsSection> {
  /// 当前是否正在写入设置。
  bool _busy = false;

  /// 持续显示的操作失败原因。
  String? _error;

  /// 统一处理异步写入及错误反馈。
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is ApiFailure ? error.message : 'AI 设置操作失败，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 删除配置前确认操作影响。
  Future<bool> _confirm(
    String title,
    String message,
    String label, {
    bool danger = false,
  }) async =>
      await showOmniDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) => OmniDialogScaffold(
          title: title,
          actions: <Widget>[
            OmniButton(
              label: '取消',
              variant: OmniButtonVariant.secondary,
              onPressed: () => Navigator.of(dialogContext).pop(false),
            ),
            OmniButton(
              label: label,
              variant: danger
                  ? OmniButtonVariant.danger
                  : OmniButtonVariant.primary,
              onPressed: () => Navigator.of(dialogContext).pop(true),
            ),
          ],
          child: SingleChildScrollView(child: Text(message)),
        ),
      ) ??
      false;

  /// 打开独立草稿表单，关闭时销毁明文密钥控制器。
  Future<void> _edit(
    AiSettingsSnapshot snapshot, [
    AiModelProfile? profile,
  ]) async {
    await showOmniDialog<void>(
      context: context,
      barrierDismissible: false,
      useSafeArea: false,
      builder: (BuildContext dialogContext) =>
          _AiProfileEditor(snapshot: snapshot, profile: profile),
    );
  }

  /// 按当前修订号更新活动配置或整理开关。
  Future<void> _update(
    AiSettingsSnapshot snapshot, {
    String? activeProfileId,
    bool? enabled,
  }) => _run(
    () => ref
        .read(aiSettingsControllerProvider.notifier)
        .mutate(
          (AiSettingsRepository repository) => repository.updateSettings(
            revision: snapshot.revision,
            activeProfileId: activeProfileId ?? snapshot.activeProfileId,
            notePolishEnabled: enabled ?? snapshot.notePolishEnabled,
          ),
        ),
  );

  /// 删除配置前明确说明当前开关会受影响。
  Future<void> _delete(
    AiSettingsSnapshot snapshot,
    AiModelProfile profile,
  ) async {
    // 防止确认旧服务器的删除操作被提交到新服务器。
    final AiSettingsRepository repository = ref.read(
      aiSettingsRepositoryProvider,
    );
    if (!await _confirm(
          '删除模型配置',
          '确认删除“${profile.name}”及其密钥？${snapshot.activeProfileId == profile.id ? '当前配置删除后，笔记 AI 整理会关闭。' : ''}',
          '删除',
          danger: true,
        ) ||
        !mounted) {
      return;
    }
    if (repository.generation != repository.auth.sessionGeneration) return;
    await _run(
      () => ref
          .read(aiSettingsControllerProvider.notifier)
          .mutate(
            (AiSettingsRepository repository) => repository.deleteProfile(
              revision: snapshot.revision,
              id: profile.id,
            ),
          ),
    );
  }

  /// 每套配置独占一行，宽屏操作靠右，窄屏与大字号时在行内下方靠右换行。
  Widget _profileRow(AiSettingsSnapshot snapshot, AiModelProfile profile) {
    // 当前配置只展示无边框的禁用状态。
    final bool current = snapshot.activeProfileId == profile.id;
    // 模型详情保留完整地址和密钥掩码，不压成省略文字。
    final Widget details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(profile.name, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: OmniSpacing.xs),
        Text(
          '${profile.model}\n${profile.baseUrl}\n${profile.hasApiKey ? 'API Key 已配置 ${profile.maskedApiKey}' : 'API Key 未配置'}',
        ),
      ],
    );
    // 操作保持原有提交与确认流程，空间不足时在右侧自然换行。
    final Widget actions = Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: OmniSpacing.sm,
      runSpacing: OmniSpacing.xs,
      children: <Widget>[
        OmniButton(
          label: current ? '当前使用' : '设为当前',
          variant: current
              ? OmniButtonVariant.text
              : OmniButtonVariant.secondary,
          onPressed: _busy || current || !profile.isComplete
              ? null
              : () => _update(snapshot, activeProfileId: profile.id),
        ),
        OmniButton(
          label: '编辑',
          variant: OmniButtonVariant.secondary,
          onPressed: _busy ? null : () => _edit(snapshot, profile),
        ),
        OmniButton(
          label: '删除',
          variant: OmniButtonVariant.danger,
          onPressed: _busy ? null : () => _delete(snapshot, profile),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 随实际字号预留详情与操作空间，避免窄屏挤压或截断按钮。
        final bool inline =
            constraints.maxWidth >=
            600 * MediaQuery.textScalerOf(context).scale(14) / 14;
        if (inline) {
          return Row(
            children: <Widget>[
              Expanded(child: details),
              const SizedBox(width: OmniSpacing.lg),
              actions,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            details,
            const SizedBox(height: OmniSpacing.sm),
            actions,
          ],
        );
      },
    );
  }

  /// 构建连接、加载、错误或完整配置，读取失败不展示空白写表单。
  @override
  Widget build(BuildContext context) {
    // 当前认证状态，用于展示离线与未连接说明。
    final AsyncValue<SyncSession?> session = ref.watch(authControllerProvider);
    // 由后端返回的版本化快照。
    final AsyncValue<AiSettingsSnapshot?> settings = ref.watch(
      aiSettingsControllerProvider,
    );
    if (session.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (session.hasError || session.value == null) {
      return const OmniPanel(
        child: Text('请先在“设置 → 数据同步”连接服务器，再配置模型服务。模型配置由后端保存，连接后的设备共用。'),
      );
    }
    return settings.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, StackTrace stack) => OmniPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(error is ApiFailure ? error.message : '无法读取 AI 设置，请检查网络和服务器'),
            const SizedBox(height: OmniSpacing.md),
            OmniButton(
              label: '重试',
              onPressed: () => ref.invalidate(aiSettingsControllerProvider),
            ),
          ],
        ),
      ),
      data: (AiSettingsSnapshot? snapshot) {
        if (snapshot == null) return const Text('正在准备 AI 设置…');
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (session.value?.isOffline == true)
              const Padding(
                padding: EdgeInsets.only(bottom: OmniSpacing.md),
                child: Text('当前连接离线；修改设置和测试连接需要服务器可用。'),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: OmniSpacing.md),
                child: Text(
                  _error!,
                  style: TextStyle(color: OmniColors.of(context).danger),
                ),
              ),
            OmniPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          '模型服务',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      const SizedBox(width: OmniSpacing.sm),
                      OmniButton(
                        label: '新增模型配置',
                        icon: Icons.add,
                        onPressed: _busy ? null : () => _edit(snapshot),
                      ),
                    ],
                  ),
                  const SizedBox(height: OmniSpacing.md),
                  if (snapshot.profiles.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: OmniSpacing.md),
                      child: Text('尚未添加模型配置'),
                    ),
                  for (final AiModelProfile profile in snapshot.profiles)
                    Padding(
                      padding: const EdgeInsets.only(bottom: OmniSpacing.md),
                      child: _profileRow(snapshot, profile),
                    ),
                ],
              ),
            ),
            const SizedBox(height: OmniSpacing.lg),
            OmniPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  OmniListRow(
                    padding: EdgeInsets.zero,
                    title: const Text('笔记 AI 整理'),
                    subtitle: const Text('语音识别完成后，去除口语重复和语气词，整理成清晰的笔记'),
                    trailing: OmniSwitch(
                      key: const ValueKey<String>('ai-note-polish-switch'),
                      value: snapshot.notePolishEnabled,
                      onChanged:
                          _busy ||
                              (!snapshot.notePolishEnabled &&
                                  snapshot.activeProfile?.isComplete != true)
                          ? null
                          : (bool value) => _update(snapshot, enabled: value),
                    ),
                  ),
                  const SizedBox(height: OmniSpacing.sm),
                  Text(
                    snapshot.activeProfile?.isComplete == true
                        ? '当前使用：${snapshot.activeProfile!.name}。整理失败会保留原文，并可重试。'
                        : '请先添加完整的模型配置并设为当前，才能开启整理。',
                  ),
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.only(top: OmniSpacing.sm),
                      child: LinearProgressIndicator(),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 独立配置编辑器，桌面弹窗与 Android 全屏共用草稿行为。
class _AiProfileEditor extends ConsumerStatefulWidget {
  /// 打开时的版本化设置快照。
  final AiSettingsSnapshot snapshot;

  /// 编辑对象，空值为新增。
  final AiModelProfile? profile;

  /// 创建配置草稿表单。
  const _AiProfileEditor({required this.snapshot, this.profile});

  /// 创建表单状态。
  @override
  ConsumerState<_AiProfileEditor> createState() => _AiProfileEditorState();
}

/// 只在弹窗存活期间保留输入密钥。
class _AiProfileEditorState extends ConsumerState<_AiProfileEditor> {
  /// 打开编辑器时固定的服务器仓储，防止换服后提交旧草稿。
  late final AiSettingsRepository _repository;

  /// 草稿确认过的设置修订号；冲突后由用户再次明确保存。
  late int _revision;

  /// 完整表单校验边界。
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  /// 配置名称输入。
  late final TextEditingController _name;

  /// API 根地址输入。
  late final TextEditingController _url;

  /// 模型名称输入。
  late final TextEditingController _model;

  /// 临时密钥输入，不写本机偏好。
  final TextEditingController _key = TextEditingController();

  /// 当前供应商标识。
  late String _provider;

  /// 显式移除已有密钥。
  bool _removeKey = false;

  /// 当前请求是否正在进行。
  bool _busy = false;

  /// 当前操作是否为连接测试。
  bool _testing = false;

  /// 持续显示的表单失败信息。
  String? _error;

  /// 持续显示的连接测试结果。
  String? _testResult;

  /// 从已有配置或默认智谱预设初始化草稿。
  @override
  void initState() {
    super.initState();
    _repository = ref.read(aiSettingsRepositoryProvider);
    _revision = widget.snapshot.revision;
    _provider = widget.profile?.provider ?? 'zhipu';
    _name = TextEditingController(text: widget.profile?.name ?? '智谱');
    _url = TextEditingController(
      text: widget.profile?.baseUrl ?? aiProviderPresets.first.baseUrl,
    );
    _model = TextEditingController(
      text: widget.profile?.model ?? aiProviderPresets.first.model,
    );
  }

  /// 关闭时销毁所有草稿，尤其是不将密钥带入后续表单。
  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _model.dispose();
    _key.dispose();
    super.dispose();
  }

  /// 切换预设仅替换空值或上一预设值，保留用户自定义内容。
  void _selectProvider(String? value) {
    if (value == null) return;
    // 上一个供应商的标准值。
    final AiProviderPreset old = aiProviderPresets.firstWhere(
      (AiProviderPreset preset) => preset.provider == _provider,
      orElse: () => aiProviderPresets.last,
    );
    // 新供应商的标准值。
    final AiProviderPreset next = aiProviderPresets.firstWhere(
      (AiProviderPreset preset) => preset.provider == value,
    );
    setState(() {
      if (_name.text.isEmpty || _name.text == old.name) _name.text = next.name;
      if (_url.text.isEmpty || _url.text == old.baseUrl) {
        _url.text = next.baseUrl;
      }
      if (_model.text.isEmpty || _model.text == old.model) {
        _model.text = next.model;
      }
      _provider = value;
      _testResult = null;
    });
  }

  /// 校验必填文本，保留输入上下文。
  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? '请填写此项' : null;

  /// 校验首期仅支持的公网 HTTPS 地址格式，公网解析由服务器验证。
  String? _validateUrl(String? value) {
    // 不对用户路径前缀进行重写。
    final Uri? uri = Uri.tryParse(value?.trim() ?? '');
    return uri == null ||
            uri.scheme != 'https' ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty ||
            uri.hasQuery ||
            uri.hasFragment
        ? '请填写不含凭据、查询参数及片段的 HTTPS Base URL'
        : null;
  }

  /// 测试和保存共用草稿校验，保存时允许明确移除已有密钥。
  bool _validate({required bool testing}) {
    if (_repository.generation != _repository.auth.sessionGeneration) {
      setState(() => _error = '服务器连接已变更，请关闭后重新打开配置');
      return false;
    }
    if (_formKey.currentState?.validate() != true) return false;
    if (_key.text.trim().isEmpty &&
        (widget.profile?.hasApiKey != true || (testing && _removeKey))) {
      setState(() => _error = '请填写 API Key');
      return false;
    }
    return true;
  }

  /// 提交草稿，成功才关闭，失败保留所有输入。
  Future<void> _save() async {
    if (_busy || !_validate(testing: false)) return;
    setState(() {
      _busy = true;
      _testing = false;
      _error = null;
    });
    try {
      await ref
          .read(aiSettingsControllerProvider.notifier)
          .mutate(
            (AiSettingsRepository repository) => repository.saveProfile(
              revision: _revision,
              id: widget.profile?.id,
              name: _name.text,
              provider: _provider,
              baseUrl: _url.text,
              model: _model.text,
              apiKey: _key.text,
              removeApiKey: _removeKey,
            ),
          );
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (error is AiSettingsConflict && mounted) {
        _revision =
            ref.read(aiSettingsControllerProvider).value?.revision ?? _revision;
      }
      if (mounted) {
        setState(
          () => _error = error is ApiFailure ? error.message : '保存失败，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 使用固定测试文本验证当前草稿，不自动保存。
  Future<void> _test() async {
    if (_busy || !_validate(testing: true)) return;
    setState(() {
      _busy = true;
      _testing = true;
      _error = null;
      _testResult = null;
    });
    try {
      // 仓储与测试请求均绑定开始时的服务器。
      final String message = await _repository.testConnection(
        profileId: widget.profile?.id,
        provider: _provider,
        baseUrl: _url.text,
        model: _model.text,
        apiKey: _key.text,
      );
      if (mounted) setState(() => _testResult = message);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is ApiFailure ? error.message : '连接测试失败，请检查配置',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 构建可滚动表单，长地址和大字号不会挤压操作区。
  Widget _buildFields() => Form(
    key: _formKey,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: OmniSpacing.md),
            child: Text(
              _error!,
              style: TextStyle(color: OmniColors.of(context).danger),
            ),
          ),
        if (_testResult != null)
          Padding(
            padding: const EdgeInsets.only(bottom: OmniSpacing.md),
            child: Text(
              _testResult!,
              style: TextStyle(color: OmniColors.of(context).success),
            ),
          ),
        OmniDropdownButtonFormField<String>(
          initialValue: _provider,
          decoration: const InputDecoration(labelText: '供应商'),
          items: <DropdownMenuItem<String>>[
            for (final AiProviderPreset preset in aiProviderPresets)
              DropdownMenuItem<String>(
                value: preset.provider,
                child: Text(preset.name, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: _busy ? null : _selectProvider,
        ),
        const SizedBox(height: OmniSpacing.md),
        OmniTextFormField(
          controller: _name,
          enabled: !_busy,
          decoration: const InputDecoration(labelText: '配置名称'),
          validator: _required,
        ),
        const SizedBox(height: OmniSpacing.md),
        OmniTextFormField(
          controller: _url,
          enabled: !_busy,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'API Base URL',
            helperText: '填写 Responses API 基址，保留服务商提供的路径前缀',
          ),
          validator: _validateUrl,
        ),
        const SizedBox(height: OmniSpacing.md),
        OmniTextFormField(
          controller: _model,
          enabled: !_busy,
          autocorrect: false,
          decoration: const InputDecoration(labelText: '模型名称'),
          validator: _required,
        ),
        const SizedBox(height: OmniSpacing.md),
        OmniTextFormField(
          controller: _key,
          enabled: !_busy && !_removeKey,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'API Key',
            helperText: widget.profile?.hasApiKey == true
                ? '已配置 ${widget.profile!.maskedApiKey}；留空保留，填写后替换'
                : '仅向当前服务器提交并加密保存',
          ),
        ),
        if (widget.profile?.hasApiKey == true)
          OmniListRow(
            padding: EdgeInsets.zero,
            title: const Text('移除已保存的 API Key'),
            trailing: OmniSwitch(
              value: _removeKey,
              onChanged: _busy
                  ? null
                  : (bool value) => setState(() {
                      _removeKey = value;
                      if (value) _key.clear();
                    }),
            ),
          ),
        const SizedBox(height: OmniSpacing.md),
        Align(
          alignment: Alignment.centerLeft,
          child: OmniButton(
            label: '测试连接',
            variant: OmniButtonVariant.secondary,
            loading: _busy && _testing,
            onPressed: _busy ? null : _test,
          ),
        ),
      ],
    ),
  );

  /// Android 使用既有全屏结构，桌面使用窗口内标准弹窗。
  @override
  Widget build(BuildContext context) {
    // 编辑器标题。
    final String title = widget.profile == null ? '新增模型配置' : '编辑模型配置';
    // 提交时禁止所有返回路径关闭草稿。
    final Widget content = Theme.of(context).platform == TargetPlatform.android
        ? OmniFullscreenFormScaffold(
            title: title,
            loading: _busy,
            onCancel: _busy ? null : () => Navigator.of(context).pop(),
            onPrimary: _busy ? null : _save,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(OmniSpacing.md),
              child: OmniPanel(child: _buildFields()),
            ),
          )
        : OmniDialogScaffold(
            title: title,
            onWindowsEnter: _busy ? null : _save,
            actions: <Widget>[
              OmniButton(
                label: '取消',
                variant: OmniButtonVariant.secondary,
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
              ),
              OmniButton(
                label: '保存',
                loading: _busy && !_testing,
                onPressed: _busy ? null : _save,
              ),
            ],
            child: SingleChildScrollView(child: _buildFields()),
          );
    return PopScope(canPop: !_busy, child: content);
  }
}
