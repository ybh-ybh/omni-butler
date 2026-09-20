import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/settings/data/feature_preferences.dart';
import 'package:omni_butler/shared/search/global_search_repository.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 全局搜索弹窗。
class GlobalSearchDialog extends ConsumerStatefulWidget {
  /// 创建全局搜索弹窗。
  const GlobalSearchDialog({super.key});

  /// 显示全局搜索弹窗。
  static Future<void> show(BuildContext context) async {
    // 用户选择的模块路由。
    final String? route = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => const GlobalSearchDialog(),
    );
    if (route != null && context.mounted) {
      context.go(route);
    }
  }

  /// 创建弹窗状态。
  @override
  ConsumerState<GlobalSearchDialog> createState() => _GlobalSearchDialogState();
}

/// 全局搜索弹窗状态。
class _GlobalSearchDialogState extends ConsumerState<GlobalSearchDialog> {
  /// 搜索控制器。
  final TextEditingController _controller = TextEditingController();

  /// 当前异步搜索结果。
  Future<List<GlobalSearchResult>>? _results;

  /// 释放搜索控制器。
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 执行本地搜索。
  void _search(String value) {
    setState(() {
      _results = value.trim().isEmpty
          ? null
          : ref.read(globalSearchRepositoryProvider).search(value);
    });
  }

  /// 构建全局搜索弹窗。
  @override
  Widget build(BuildContext context) {
    // 当前搜索任务。
    final Future<List<GlobalSearchResult>>? results = _results;
    // 当前设备功能偏好。
    final FeaturePreference featurePreference = ref.watch(
      featurePreferenceProvider,
    );
    return OmniDialogScaffold(
      title: '搜索全部内容',
      width: 640,
      height: 560,
      child: Column(
        children: <Widget>[
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search_rounded),
              hintText: '搜索待办、事件、物品、时间记录、会员或名言',
            ),
            textInputAction: TextInputAction.search,
            onChanged: _search,
          ),
          const SizedBox(height: OmniSpacing.sm),
          Expanded(
            child: results == null
                ? const _SearchHint()
                : FutureBuilder<List<GlobalSearchResult>>(
                    future: results,
                    builder:
                        (
                          BuildContext context,
                          AsyncSnapshot<List<GlobalSearchResult>> snapshot,
                        ) {
                          if (snapshot.connectionState !=
                              ConnectionState.done) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }
                          if (snapshot.hasError) {
                            return Center(
                              child: Text('搜索失败：${snapshot.error}'),
                            );
                          }
                          // 当前搜索结果。
                          final List<GlobalSearchResult> items =
                              (snapshot.data ?? const <GlobalSearchResult>[])
                                  .where(
                                    (GlobalSearchResult item) =>
                                        _isResultEnabled(
                                          item.type,
                                          featurePreference,
                                        ),
                                  )
                                  .toList(growable: false);
                          if (items.isEmpty) {
                            return const Center(child: Text('没有找到匹配内容'));
                          }
                          return ListView.separated(
                            itemCount: items.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1),
                            itemBuilder: (BuildContext context, int index) {
                              // 当前搜索结果。
                              final GlobalSearchResult item = items[index];
                              return OmniListRow(
                                leading: Icon(
                                  _iconFor(item.type),
                                  size: OmniSize.navigationIcon,
                                  color: _colorFor(context, item.type),
                                ),
                                title: Text(
                                  item.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  '${_labelFor(item.type)} · ${item.subtitle}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: const Icon(
                                  Icons.arrow_forward_rounded,
                                  size: OmniSize.icon,
                                ),
                                onTap: () =>
                                    Navigator.of(context).pop(item.route),
                              );
                            },
                          );
                        },
                  ),
          ),
        ],
      ),
    );
  }

  /// 判断搜索结果所属功能当前是否启用。
  bool _isResultEnabled(GlobalSearchType type, FeaturePreference preference) {
    return switch (type) {
      GlobalSearchType.todo => preference.isEnabled(AppFeature.todos),
      GlobalSearchType.event => preference.isEnabled(AppFeature.events),
      GlobalSearchType.inventory => preference.isEnabled(AppFeature.inventory),
      GlobalSearchType.timeEntry => preference.isEnabled(AppFeature.timeline),
      GlobalSearchType.membership => preference.isEnabled(
        AppFeature.memberships,
      ),
      GlobalSearchType.quote => true,
    };
  }

  /// 返回搜索结果类型图标。
  IconData _iconFor(GlobalSearchType type) {
    return switch (type) {
      GlobalSearchType.todo => Icons.task_alt_rounded,
      GlobalSearchType.event => Icons.event_repeat_rounded,
      GlobalSearchType.inventory => Icons.inventory_2_outlined,
      GlobalSearchType.timeEntry => Icons.view_timeline_outlined,
      GlobalSearchType.membership => Icons.loyalty_outlined,
      GlobalSearchType.quote => Icons.format_quote_rounded,
    };
  }

  /// 返回搜索结果类型文案。
  String _labelFor(GlobalSearchType type) {
    return switch (type) {
      GlobalSearchType.todo => '待办',
      GlobalSearchType.event => '事件',
      GlobalSearchType.inventory => '物品',
      GlobalSearchType.timeEntry => '时间记录',
      GlobalSearchType.membership => '会员',
      GlobalSearchType.quote => '名言',
    };
  }

  /// 返回搜索结果类型颜色。
  Color _colorFor(BuildContext context, GlobalSearchType type) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return switch (type) {
      GlobalSearchType.todo => colors.todo,
      GlobalSearchType.event => colors.event,
      GlobalSearchType.inventory => colors.item,
      GlobalSearchType.timeEntry => colors.time,
      GlobalSearchType.membership => colors.member,
      GlobalSearchType.quote => colors.brand,
    };
  }
}

/// 搜索输入提示。
class _SearchHint extends StatelessWidget {
  /// 创建搜索输入提示。
  const _SearchHint();

  /// 构建搜索输入提示。
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.manage_search_rounded,
            size: 48,
            color: OmniColors.of(context).muted,
          ),
          const SizedBox(height: OmniSpacing.sm),
          Text(
            '输入关键词，在本机 SQLite 中搜索',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
