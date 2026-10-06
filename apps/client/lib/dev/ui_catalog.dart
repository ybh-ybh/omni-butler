import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_theme_palette.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 与真实业务数据隔离的组件展示应用，供设计与回归验收。
class OmniUiCatalogApp extends StatefulWidget {
  /// 预览初始配色。
  final AppThemePalette initialPalette;

  /// 预览初始明暗。
  final Brightness initialBrightness;

  /// 可选的平台覆盖，便于同一窗口检视桌面和触控热区。
  final TargetPlatform? platform;

  /// 创建可独立启动的展示应用。
  const OmniUiCatalogApp({
    this.initialPalette = AppThemePalette.classicBlue,
    this.initialBrightness = Brightness.light,
    this.platform,
    super.key,
  });

  /// 创建展示设置状态。
  @override
  State<OmniUiCatalogApp> createState() => _OmniUiCatalogAppState();
}

/// 只在内存保存展示设置。
class _OmniUiCatalogAppState extends State<OmniUiCatalogApp> {
  /// 当前配色。
  late AppThemePalette _palette = widget.initialPalette;

  /// 当前明暗模式。
  late Brightness _brightness = widget.initialBrightness;

  /// 是否关闭非必要动效。
  bool _reduceMotion = false;

  /// 预览的文字倍率。
  double _textScale = 1;

  /// 构建与正式产品相同的主题和组件。
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Omni UI · 组件展示',
      theme: AppTheme.build(
        brightness: _brightness,
        palette: _palette,
      ).copyWith(platform: widget.platform),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: _reduceMotion,
          textScaler: TextScaler.linear(_textScale),
        ),
        child: child!,
      ),
      home: Scaffold(
        body: SafeArea(
          child: Builder(
            builder: (BuildContext context) => SingleChildScrollView(
              padding: const EdgeInsets.all(OmniSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Omni UI',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: OmniSpacing.xs),
                  Text(
                    '统一组件 · 六套配色 · 桌面与触控',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: OmniSpacing.lg),
                  Wrap(
                    spacing: OmniSpacing.md,
                    runSpacing: OmniSpacing.sm,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: <Widget>[
                      OmniDropdownButton<AppThemePalette>(
                        value: _palette,
                        items: <DropdownMenuItem<AppThemePalette>>[
                          for (final AppThemePalette palette
                              in AppThemePalette.values)
                            DropdownMenuItem(
                              value: palette,
                              child: Text(palette.label),
                            ),
                        ],
                        onChanged: (AppThemePalette? value) =>
                            setState(() => _palette = value!),
                      ),
                      OmniButton(
                        label: _brightness == Brightness.light
                            ? '切换深色'
                            : '切换浅色',
                        variant: OmniButtonVariant.secondary,
                        onPressed: () => setState(() {
                          _brightness = _brightness == Brightness.light
                              ? Brightness.dark
                              : Brightness.light;
                        }),
                      ),
                      OmniButton(
                        label: _textScale == 1 ? '放大文字' : '正常文字',
                        variant: OmniButtonVariant.secondary,
                        onPressed: () => setState(
                          () => _textScale = _textScale == 1 ? 1.6 : 1,
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          const Text('减少动效'),
                          const SizedBox(width: OmniSpacing.xs),
                          OmniSwitch(
                            value: _reduceMotion,
                            onChanged: (bool value) =>
                                setState(() => _reduceMotion = value),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: OmniSpacing.lg),
                  const _CatalogExamples(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 展示控件的真实输入、选择与校验状态。
class _CatalogExamples extends StatefulWidget {
  /// 创建组件样例。
  const _CatalogExamples();

  /// 创建演示交互状态。
  @override
  State<_CatalogExamples> createState() => _CatalogExamplesState();
}

/// 样例状态不触及业务仓储。
class _CatalogExamplesState extends State<_CatalogExamples> {
  /// 校验表单键。
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  /// 示例复选状态。
  bool _checked = true;

  /// 示例开关状态。
  bool _enabled = true;

  /// 示例单选值。
  String _choice = 'local';

  /// 示例下拉值。
  String _category = '生活';

  /// 示例日期。
  DateTime _date = DateTime(2026, 10, 6);

  /// 示例分段值。
  String _segment = '进行中';

  /// 构建自适应换行的组件分组。
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 当前视口可容纳的分组列数。
        final int columns = constraints.maxWidth >= 1000
            ? 3
            : constraints.maxWidth >= 680
            ? 2
            : 1;
        // 每组占用的宽度包含组间固定留白。
        final double width =
            (constraints.maxWidth - (columns - 1) * OmniSpacing.md) / columns;
        return Wrap(
          spacing: OmniSpacing.md,
          runSpacing: OmniSpacing.md,
          children: <Widget>[
            _section(context, width, '操作与反馈', <Widget>[
              Wrap(
                spacing: OmniSpacing.xs,
                runSpacing: OmniSpacing.xs,
                children: <Widget>[
                  OmniButton(
                    label: '保存',
                    icon: Icons.check_rounded,
                    onPressed: () => showOmniMessage(
                      context,
                      message: '保存成功',
                      tone: OmniMessageTone.success,
                    ),
                  ),
                  OmniButton(
                    label: '取消',
                    variant: OmniButtonVariant.secondary,
                    onPressed: () {},
                  ),
                  OmniButton(
                    label: '删除',
                    variant: OmniButtonVariant.danger,
                    onPressed: () => showOmniConfirmDialog(
                      context,
                      title: '删除示例',
                      message: '此处仅演示确认弹窗，不会删除业务数据。',
                      confirmLabel: '删除',
                      danger: true,
                    ),
                  ),
                  const OmniButton(label: '不可用', onPressed: null),
                  OmniButton(label: '正在保存', loading: true, onPressed: () {}),
                  OmniIconButton(
                    tooltip: '更多操作',
                    icon: const Icon(Icons.more_horiz),
                    onPressed: () {},
                  ),
                ],
              ),
              Wrap(
                spacing: OmniSpacing.xs,
                runSpacing: OmniSpacing.xs,
                children: <Widget>[
                  OmniButton(
                    label: '打开编辑器',
                    variant: OmniButtonVariant.secondary,
                    onPressed: () => showOmniDialog<void>(
                      context: context,
                      builder: (BuildContext dialogContext) =>
                          OmniDialogScaffold(
                            title: '编辑事项',
                            actions: <Widget>[
                              OmniButton(
                                label: '取消',
                                variant: OmniButtonVariant.secondary,
                                onPressed: () =>
                                    Navigator.of(dialogContext).pop(),
                              ),
                              OmniButton(
                                label: '保存修改',
                                onPressed: () =>
                                    Navigator.of(dialogContext).pop(),
                              ),
                            ],
                            child: const OmniTextField(
                              decoration: InputDecoration(
                                labelText: '事项名称',
                                hintText: '输入一个名称',
                              ),
                            ),
                          ),
                    ),
                  ),
                  OmniButton(
                    label: '错误提示',
                    variant: OmniButtonVariant.text,
                    onPressed: () => showOmniMessage(
                      context,
                      message: '暂时无法保存，请重试。',
                      tone: OmniMessageTone.error,
                    ),
                  ),
                ],
              ),
            ]),
            _section(context, width, '输入与校验', <Widget>[
              const OmniTextField(
                decoration: InputDecoration(
                  labelText: '名称',
                  hintText: '输入事项名称',
                ),
              ),
              const OmniTextField(
                decoration: InputDecoration(
                  hintText: '搜索内容',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
              ),
              const OmniTextField(
                enabled: false,
                decoration: InputDecoration(
                  labelText: '禁用字段',
                  hintText: '当前不可编辑',
                ),
              ),
              const OmniTextField(
                readOnly: true,
                decoration: InputDecoration(
                  labelText: '只读字段',
                  hintText: '允许阅读和选择',
                ),
              ),
              const OmniTextField(
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: '说明',
                  helperText: '支持中文输入法与多行输入',
                ),
              ),
              Form(
                key: _formKey,
                child: OmniTextFormField(
                  decoration: const InputDecoration(labelText: '必填内容'),
                  validator: (String? value) =>
                      value == null || value.trim().isEmpty
                      ? '请填写内容后再保存'
                      : null,
                ),
              ),
              OmniButton(
                label: '验证表单',
                onPressed: () => _formKey.currentState!.validate(),
              ),
            ]),
            _section(context, width, '选择与设置', <Widget>[
              Wrap(
                spacing: OmniSpacing.md,
                runSpacing: OmniSpacing.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  OmniCheckbox(
                    value: _checked,
                    semanticLabel: '选中示例',
                    onChanged: (bool? value) =>
                        setState(() => _checked = value!),
                  ),
                  const OmniCheckbox(
                    value: null,
                    tristate: true,
                    onChanged: null,
                    semanticLabel: '禁用未确定状态',
                  ),
                  OmniSwitch(
                    value: _enabled,
                    onChanged: (bool value) => setState(() => _enabled = value),
                  ),
                  const OmniSwitch(value: false, onChanged: null),
                ],
              ),
              RadioGroup<String>(
                groupValue: _choice,
                onChanged: (String? value) => setState(() => _choice = value!),
                child: const Column(
                  children: <Widget>[
                    OmniRadioListTile(value: 'local', title: Text('仅本机')),
                    OmniRadioListTile(value: 'sync', title: Text('开启同步')),
                  ],
                ),
              ),
              OmniDropdownButtonFormField<String>(
                initialValue: _category,
                decoration: const InputDecoration(labelText: '分类'),
                items: const <DropdownMenuItem<String>>[
                  DropdownMenuItem(value: '生活', child: Text('生活')),
                  DropdownMenuItem(value: '工作', child: Text('工作')),
                ],
                onChanged: (String? value) =>
                    setState(() => _category = value!),
              ),
              OmniDatePickerButton(
                value: _date,
                initialDate: _date,
                firstDate: DateTime(2020),
                lastDate: DateTime(2040),
                label: '${_date.year}/${_date.month}/${_date.day}',
                onChanged: (DateTime value) => setState(() => _date = value),
              ),
              LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) =>
                    OmniSlidingSegmentedControl<String>(
                      options: const <String>['进行中', '已完成'],
                      selected: _segment,
                      width: constraints.maxWidth,
                      height: OmniDensity.controlHeight(context, large: true),
                      labelBuilder: (String value) => value,
                      onChanged: (String value) =>
                          setState(() => _segment = value),
                    ),
              ),
            ]),
          ],
        );
      },
    );
  }

  /// 构建有固定留白和文字层级的样例面板。
  Widget _section(
    BuildContext context,
    double width,
    String title,
    List<Widget> children,
  ) {
    return SizedBox(
      width: width,
      child: OmniPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            for (final Widget child in children) ...<Widget>[
              const SizedBox(height: OmniSpacing.md),
              child,
            ],
          ],
        ),
      ),
    );
  }
}
