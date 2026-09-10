import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/attachments/attachment_repository.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/features/inventory/data/inventory_repository.dart';
import 'package:omni_butler/features/inventory/presentation/inventory_move_dialog.dart';
import 'package:omni_butler/shared/taxonomy/taxonomy_manager_dialog.dart';
import 'package:omni_butler/shared/attachments/attachment_picker_dialog.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 物品网格列数的本机偏好键。
const String _inventoryColumnsPreferenceKey = 'inventory.layout_columns';

/// 物品管理页面。
class InventoryPage extends ConsumerStatefulWidget {
  /// 创建物品管理页面。
  const InventoryPage({super.key});

  /// 创建页面状态。
  @override
  ConsumerState<InventoryPage> createState() => _InventoryPageState();
}

/// 物品管理页面状态。
class _InventoryPageState extends ConsumerState<InventoryPage> {
  /// 当前搜索词。
  String _query = '';

  /// 当前物品网格列数。
  int _inventoryColumns = 6;

  /// 当前标签筛选；空值表示全部标签。
  String? _tagFilter;

  /// 当前位置筛选；空值表示全部位置。
  String? _locationFilter;

  /// 标签与位置筛选区是否展开。
  bool _filtersExpanded = false;

  /// 搜索控制器。
  final TextEditingController _searchController = TextEditingController();

  /// 初始化物品页并恢复本机布局偏好。
  @override
  void initState() {
    super.initState();
    // 读取本机保存的列数，仅接受当前支持的选项。
    final int? savedColumns = ref
        .read(sharedPreferencesProvider)
        .getInt(_inventoryColumnsPreferenceKey);
    if (savedColumns == 4 || savedColumns == 5 || savedColumns == 6) {
      _inventoryColumns = savedColumns!;
    }
  }

  /// 释放搜索控制器。
  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 更新标签筛选。
  void _selectTagFilter(String? value) {
    setState(() => _tagFilter = value);
  }

  /// 更新位置筛选。
  void _selectLocationFilter(String? value) {
    setState(() => _locationFilter = value);
  }

  /// 判断物品是否符合标签和位置筛选。
  bool _matchesTaxonomyFilters(
    InventoryRecord item,
    List<TaxonomyEntry> tags,
    List<TaxonomyEntry> locations,
    Map<String, Set<String>> taxonomyLinks,
  ) {
    // 当前物品关联的规范标签名称。
    final Set<String> linkedTagNames = <String>{};
    // 当前物品关联的规范位置名称。
    final Set<String> linkedLocationNames = <String>{};
    // 当前物品是否已有规范分类关联。
    bool hasCategoryLink = false;
    // 当前物品是否已有规范位置关联。
    bool hasLocationLink = false;
    for (final String id in taxonomyLinks[item.id] ?? const <String>{}) {
      for (final TaxonomyEntry entry in tags) {
        if (entry.id == id) {
          linkedTagNames.add(entry.name);
          if (entry.kind == TaxonomyKind.category.name) {
            hasCategoryLink = true;
          }
          break;
        }
      }
      for (final TaxonomyEntry entry in locations) {
        if (entry.id == id) {
          linkedLocationNames.add(entry.name);
          hasLocationLink = true;
          break;
        }
      }
    }
    // 兼容旧数据中的文本标签和位置字段。
    final Set<String> itemTags = (item.tags ?? '')
        .split(',')
        .map((String value) => value.trim())
        .where((String value) => value.isNotEmpty)
        .toSet();
    if (!hasCategoryLink && (item.category?.trim().isNotEmpty ?? false)) {
      itemTags.add(item.category!.trim());
    }
    // 当前物品的文本位置。
    final String itemLocation = hasLocationLink
        ? ''
        : item.location?.trim() ?? '';
    // 当前物品是否匹配标签条件。
    final bool matchesTag =
        _tagFilter == null ||
        itemTags.contains(_tagFilter) ||
        linkedTagNames.contains(_tagFilter);
    // 当前物品是否匹配位置条件。
    final bool matchesLocation =
        _locationFilter == null ||
        itemLocation == _locationFilter ||
        linkedLocationNames.contains(_locationFilter);
    return matchesTag && matchesLocation;
  }

  /// 打开物品编辑器。
  Future<void> _openEditor([InventoryRecord? item]) async {
    await showOmniSideSheet<void>(
      context,
      builder: (BuildContext context) => _InventoryEditorDialog(item: item),
    );
  }

  /// 打开配套物品管理。
  Future<void> _openAccessories(InventoryRecord item) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => _AccessoriesDialog(parent: item),
    );
  }

  /// 打开物品批量搬家工作台。
  Future<void> _openMoveDialog() async {
    // 本次批量迁移结果。
    final InventoryMoveResult? result = await showInventoryMoveDialog(context);
    if (!mounted || result == null) {
      return;
    }
    // 成功迁移的主文案。
    final String message = result.affectedCount == 0
        ? '所选物品已经位于“${result.destinationName}”'
        : '已将 ${result.affectedCount} 项迁移到“${result.destinationName}”';
    // 被跳过记录的补充文案。
    final int skippedCount = result.unchangedCount + result.missingCount;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          skippedCount == 0 ? message : '$message，跳过 $skippedCount 项',
        ),
      ),
    );
  }

  /// 以短时卡牌翻转动效打开物品详情。
  Future<void> _openDetails(InventoryRecord item) async {
    // 详情卡关闭后需要继续执行的操作。
    final _InventoryDetailAction? action =
        await showGeneralDialog<_InventoryDetailAction>(
          context: context,
          barrierDismissible: true,
          barrierLabel: '关闭物品详情',
          barrierColor: Colors.black54,
          transitionDuration: OmniMotion.panel,
          pageBuilder:
              (
                BuildContext context,
                Animation<double> animation,
                Animation<double> secondaryAnimation,
              ) => _InventoryDetailDialog(
                item: item,
                onEdit: () =>
                    Navigator.of(context).pop(_InventoryDetailAction.edit),
                onAccessories: () =>
                    Navigator.of(context)
                        .pop(_InventoryDetailAction.accessories),
              ),
          transitionBuilder:
              (
                BuildContext context,
                Animation<double> animation,
                Animation<double> secondaryAnimation,
                Widget child,
              ) {
                // 尊重系统的减少动态效果设置，仅保留轻量淡入淡出。
                final bool disableAnimations = MediaQuery.of(context)
                    .disableAnimations;
                // 弹性较弱的缓动避免翻转显得拖沓。
                final Animation<double> curvedAnimation = CurvedAnimation(
                  parent: animation,
                  curve: OmniMotion.standardCurve,
                  reverseCurve: Curves.easeInCubic,
                );
                if (disableAnimations) {
                  return FadeTransition(opacity: curvedAnimation, child: child);
                }
                return AnimatedBuilder(
                  animation: curvedAnimation,
                  child: child,
                  builder: (BuildContext context, Widget? child) {
                    // 从略微侧转的位置翻到正面，兼顾卡牌感与内容可读性。
                    final double angle =
                        (1 - curvedAnimation.value) * -math.pi / 2;
                    if (curvedAnimation.status == AnimationStatus.completed) {
                      // 完成后移除透视变换层，避免静止文字继续被栅格化而发虚。
                      return child ?? const SizedBox.shrink();
                    }
                    // 透视矩阵让 Y 轴旋转具有真实卡牌厚度感。
                    final Matrix4 transform = Matrix4.identity()
                      ..setEntry(3, 2, 0.0015)
                      ..rotateY(angle);
                    return Opacity(
                      opacity: curvedAnimation.value.clamp(0.0, 1.0),
                      child: Transform(
                        key: const ValueKey<String>('inventory-detail-flip'),
                        alignment: Alignment.center,
                        transform: transform,
                        child: child,
                      ),
                    );
                  },
                );
              },
        );
    if (!mounted) {
      return;
    }
    if (action == _InventoryDetailAction.edit) {
      await _openEditor(item);
    } else if (action == _InventoryDetailAction.accessories) {
      await _openAccessories(item);
    }
  }

  /// 删除物品。
  Future<void> _delete(InventoryRecord item) async {
    await ref.read(inventoryRepositoryProvider).delete(item.id);
    ref.invalidate(recycleBinItemsProvider);
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('“${item.name}”已移入回收站')));
  }

  /// 更新物品网格列数。
  Future<void> _selectInventoryColumns(int? value) async {
    if (value == null || value == _inventoryColumns) {
      return;
    }
    setState(() => _inventoryColumns = value);
    // 将切换后的列数写入本机偏好，后续进入页面时继续使用。
    await ref
        .read(sharedPreferencesProvider)
        .setInt(_inventoryColumnsPreferenceKey, value);
  }

  /// 构建物品管理页面。
  @override
  Widget build(BuildContext context) {
    // 当前物品流。
    final AsyncValue<List<InventoryRecord>> items = ref.watch(
      inventoryItemsProvider(_query),
    );
    // 用于顶部统计的全部有效主物品流。
    final AsyncValue<List<InventoryRecord>> allItems = ref.watch(
      inventoryItemsProvider(''),
    );
    // 用于顶部配套物品统计的全量配套物品流。
    final AsyncValue<List<InventoryRecord>> allAccessories = ref.watch(
      inventoryAllAccessoriesProvider,
    );
    // 当前物品分类。
    final AsyncValue<List<TaxonomyEntry>> categories = ref.watch(
      taxonomyEntriesProvider((
        TaxonomyModule.inventory,
        TaxonomyKind.category,
      )),
    );
    // 当前规范物品标签。
    final List<TaxonomyEntry> explicitTags =
        ref
            .watch(
              taxonomyEntriesProvider((
                TaxonomyModule.inventory,
                TaxonomyKind.tag,
              )),
            )
            .asData
            ?.value ??
        const <TaxonomyEntry>[];
    // 标签筛选兼容现有物品分类和规范标签。
    final List<TaxonomyEntry> filterTags = <TaxonomyEntry>[
      ...categories.asData?.value ?? const <TaxonomyEntry>[],
      ...explicitTags,
    ];
    // 当前物品位置。
    final List<TaxonomyEntry> locations =
        ref
            .watch(
              taxonomyEntriesProvider((
                TaxonomyModule.inventory,
                TaxonomyKind.location,
              )),
            )
            .asData
            ?.value ??
        const <TaxonomyEntry>[];
    // 当前物品的规范分类关联。
    final Map<String, Set<String>> taxonomyLinks =
        ref.watch(inventoryTaxonomyLinksProvider).asData?.value ??
        const <String, Set<String>>{};
    // 当前是否为紧凑布局。
    final bool compact = OmniBreakpoint.isCompact(
      MediaQuery.sizeOf(context).width,
    );
    return Scaffold(
      body: Padding(
        padding: compact
            ? const EdgeInsets.fromLTRB(
                OmniSpacing.xs,
                OmniSpacing.xs,
                OmniSpacing.xs,
                OmniSpacing.md,
              )
            : const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: OmniSpacing.sm,
              ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            OmniPageHeader(
              title: '物品管理',
              actions: <Widget>[
                OmniButton(
                  label: '新增物品',
                  icon: Icons.add_rounded,
                  variant: OmniButtonVariant.pagePrimary,
                  onPressed: _openEditor,
                ),
              ],
            ),
            const SizedBox(height: OmniSpacing.xs),
            _InventoryStatistics(
              items: allItems,
              accessories: allAccessories,
              categories: categories.asData?.value ?? const <TaxonomyEntry>[],
            ),
            const SizedBox(height: OmniSpacing.xs),
            _InventoryToolbar(
              compact: compact,
              searchController: _searchController,
              searchQuery: _query,
              records: allItems.asData?.value ?? const <InventoryRecord>[],
              tags: filterTags,
              locations: locations,
              taxonomyLinks: taxonomyLinks,
              selectedTag: _tagFilter,
              selectedLocation: _locationFilter,
              filtersExpanded: _filtersExpanded,
              inventoryColumns: _inventoryColumns,
              onSearchChanged: (String value) => setState(() => _query = value),
              onClearSearch: () {
                _searchController.clear();
                setState(() => _query = '');
              },
              onTagChanged: _selectTagFilter,
              onLocationChanged: _selectLocationFilter,
              onFiltersToggled: () =>
                  setState(() => _filtersExpanded = !_filtersExpanded),
              onColumnsChanged: _selectInventoryColumns,
              onMove: _openMoveDialog,
            ),
            const SizedBox(height: OmniSpacing.xs),
            Expanded(
              child: items.when(
                data: (List<InventoryRecord> records) {
                  // 应用标签和位置筛选。
                  final List<InventoryRecord> filteredRecords = records
                      .where(
                        (InventoryRecord item) => _matchesTaxonomyFilters(
                          item,
                          filterTags,
                          locations,
                          taxonomyLinks,
                        ),
                      )
                      .toList(growable: false);
                  if (filteredRecords.isEmpty) {
                    return _InventoryEmpty(
                      searching:
                          _query.isNotEmpty ||
                          _tagFilter != null ||
                          _locationFilter != null,
                    );
                  }
                  return LayoutBuilder(
                    builder:
                        (BuildContext context, BoxConstraints constraints) {
                          // 根据用户选择和当前视口计算实际列数。
                          final int maxColumns = constraints.maxWidth >= 1200
                              ? 6
                              : constraints.maxWidth >= 900
                              ? 5
                              : constraints.maxWidth >= 660
                              ? 4
                              : 1;
                          final int columns = _inventoryColumns
                              .clamp(1, maxColumns)
                              .toInt();
                          return GridView.builder(
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: columns,
                                  crossAxisSpacing: OmniSpacing.xs,
                                  mainAxisSpacing: OmniSpacing.xs,
                                  mainAxisExtent: 300,
                                ),
                            itemCount: filteredRecords.length,
                            itemBuilder: (BuildContext context, int index) {
                              // 当前物品。
                              final InventoryRecord item =
                                  filteredRecords[index];
                              return _InventoryCard(
                                item: item,
                                onOpen: () => _openDetails(item),
                                onEdit: () => _openEditor(item),
                                onAccessories: () => _openAccessories(item),
                                onDelete: () => _delete(item),
                              );
                            },
                          );
                        },
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (Object error, StackTrace stackTrace) =>
                    Center(child: Text('物品读取失败：$error')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 物品列表上方的搜索与布局工具栏。
class _InventoryToolbar extends StatelessWidget {
  /// 当前是否为紧凑布局。
  final bool compact;

  /// 搜索输入控制器。
  final TextEditingController searchController;

  /// 当前搜索词。
  final String searchQuery;

  /// 当前全部物品，用于生成筛选项。
  final List<InventoryRecord> records;

  /// 可用标签。
  final List<TaxonomyEntry> tags;

  /// 可用位置。
  final List<TaxonomyEntry> locations;

  /// 物品与规范标签的关联。
  final Map<String, Set<String>> taxonomyLinks;

  /// 当前选中的标签。
  final String? selectedTag;

  /// 当前选中的位置。
  final String? selectedLocation;

  /// 标签与位置筛选区是否展开。
  final bool filtersExpanded;

  /// 当前物品网格列数。
  final int inventoryColumns;

  /// 搜索词变更回调。
  final ValueChanged<String> onSearchChanged;

  /// 清空搜索回调。
  final VoidCallback onClearSearch;

  /// 标签筛选变更回调。
  final ValueChanged<String?> onTagChanged;

  /// 位置筛选变更回调。
  final ValueChanged<String?> onLocationChanged;

  /// 筛选区展开状态切换回调。
  final VoidCallback onFiltersToggled;

  /// 列数变更回调。
  final ValueChanged<int?> onColumnsChanged;

  /// 打开批量搬家工作台回调。
  final VoidCallback onMove;

  /// 创建物品列表工具栏。
  const _InventoryToolbar({
    required this.compact,
    required this.searchController,
    required this.searchQuery,
    required this.records,
    required this.tags,
    required this.locations,
    required this.taxonomyLinks,
    required this.selectedTag,
    required this.selectedLocation,
    required this.filtersExpanded,
    required this.inventoryColumns,
    required this.onSearchChanged,
    required this.onClearSearch,
    required this.onTagChanged,
    required this.onLocationChanged,
    required this.onFiltersToggled,
    required this.onColumnsChanged,
    required this.onMove,
  });

  /// 构建搜索框与右侧操作。
  @override
  Widget build(BuildContext context) {
    // 搜索输入框，沿用会员管理的紧凑样式。
    final Widget searchField = _InventorySearchField(
      controller: searchController,
      query: searchQuery,
      width: compact ? 232 : 260,
      onChanged: onSearchChanged,
      onClear: onClearSearch,
    );
    // 当前已生效的筛选条件数量。
    final int activeFilterCount = <String?>[
      selectedTag,
      selectedLocation,
    ].where((String? value) => value != null).length;
    // 搜索框左侧的筛选切换按钮。
    final Widget filterButton = _InventoryFilterButton(
      expanded: filtersExpanded,
      activeCount: activeFilterCount,
      onPressed: onFiltersToggled,
    );
    // 筛选按钮与搜索输入始终作为同一组排列。
    final Widget searchGroup = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        filterButton,
        const SizedBox(width: OmniSpacing.xs),
        searchField,
      ],
    );
    // 管理与布局操作。
    final double actionHeight = compact ? OmniSize.touch : OmniSize.control;
    final Widget actions = Wrap(
      spacing: OmniSpacing.xs,
      children: <Widget>[
        SizedBox(
          height: actionHeight,
          child: OmniButton(
            key: const ValueKey<String>('inventory-move-button'),
            label: '一键搬家',
            icon: Icons.local_shipping_outlined,
            variant: OmniButtonVariant.secondary,
            onPressed: onMove,
          ),
        ),
        SizedBox(
          height: actionHeight,
          child: OmniButton(
            key: const ValueKey<String>('inventory-manage-category'),
            label: '管理分类',
            icon: Icons.category_outlined,
            variant: OmniButtonVariant.secondary,
            onPressed: () => TaxonomyManagerDialog.show(
              context,
              module: TaxonomyModule.inventory,
              kind: TaxonomyKind.category,
            ),
          ),
        ),
        SizedBox(
          height: actionHeight,
          child: OmniButton(
            key: const ValueKey<String>('inventory-manage-location'),
            label: '管理位置',
            icon: Icons.place_outlined,
            variant: OmniButtonVariant.secondary,
            onPressed: () => TaxonomyManagerDialog.show(
              context,
              module: TaxonomyModule.inventory,
              kind: TaxonomyKind.location,
            ),
          ),
        ),
        OmniDropdownButton<int>(
          key: const ValueKey<String>('inventory-layout-selector'),
          value: inventoryColumns,
          width: 104,
          height: actionHeight,
          items: <DropdownMenuItem<int>>[
            for (final int columns in <int>[4, 5, 6])
              DropdownMenuItem<int>(value: columns, child: Text('$columns列')),
          ],
          onChanged: onColumnsChanged,
        ),
      ],
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 宽屏将操作固定在搜索框右侧，窄屏自动换行。
        final Widget primaryToolbar = constraints.maxWidth >= 760
            ? Row(children: <Widget>[searchGroup, const Spacer(), actions])
            : Wrap(
                spacing: OmniSpacing.xs,
                runSpacing: OmniSpacing.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[searchGroup, actions],
              );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            primaryToolbar,
            AnimatedSwitcher(
              duration: OmniMotion.normal,
              reverseDuration: OmniMotion.fast,
              switchInCurve: OmniMotion.standardCurve,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (Widget child, Animation<double> animation) {
                // 同步高度与透明度，让筛选区自然展开和收起。
                return FadeTransition(
                  opacity: animation,
                  child: SizeTransition(
                    sizeFactor: animation,
                    alignment: Alignment.topCenter,
                    child: child,
                  ),
                );
              },
              child: filtersExpanded
                  ? Padding(
                      key: const ValueKey<String>('inventory-filter-panel'),
                      padding: const EdgeInsets.only(top: OmniSpacing.xs),
                      child: Column(
                        children: <Widget>[
                          _InventoryFilterRow(
                            key: const ValueKey<String>(
                              'inventory-tag-filters',
                            ),
                            label: '标签',
                            values: _tagNames(),
                            counts: _tagCounts(),
                            totalCount: records.length,
                            showCount: true,
                            selected: selectedTag,
                            onChanged: onTagChanged,
                          ),
                          const SizedBox(height: OmniSpacing.xxs),
                          _InventoryFilterRow(
                            key: const ValueKey<String>(
                              'inventory-location-filters',
                            ),
                            label: '位置',
                            values: _locationNames(),
                            selected: selectedLocation,
                            onChanged: onLocationChanged,
                          ),
                        ],
                      ),
                    )
                  : const SizedBox(
                      key: ValueKey<String>('inventory-filter-panel-collapsed'),
                    ),
            ),
          ],
        );
      },
    );
  }

  /// 生成去重后的标签名称。
  List<String> _tagNames() {
    // 当前物品实际使用的标签和分类名称集合。
    final Set<String> names = <String>{
      for (final InventoryRecord item in records)
        ...(item.tags ?? '')
            .split(',')
            .map((String value) => value.trim())
            .where((String value) => value.isNotEmpty),
    };
    // 规范关联也视为当前物品实际使用的筛选项。
    for (final InventoryRecord item in records) {
      // 当前物品是否已有规范分类关联。
      bool hasCategoryLink = false;
      for (final String id in taxonomyLinks[item.id] ?? const <String>{}) {
        for (final TaxonomyEntry entry in tags) {
          if (entry.id == id) {
            names.add(entry.name.trim());
            if (entry.kind == TaxonomyKind.category.name) {
              hasCategoryLink = true;
            }
            break;
          }
        }
      }
      if (!hasCategoryLink && (item.category?.trim().isNotEmpty ?? false)) {
        names.add(item.category!.trim());
      }
    }
    // 先按管理器中的 sortOrder 输出，未纳入管理器的旧文本值再稳定追加。
    final List<String> result = <String>[];
    final Set<String> remaining = Set<String>.of(names);
    for (final TaxonomyEntry entry in tags) {
      final String name = entry.name.trim();
      if (remaining.remove(name)) {
        result.add(name);
      }
    }
    final List<String> unmanaged = remaining.toList()..sort();
    result.addAll(unmanaged);
    if (selectedTag != null && !result.contains(selectedTag)) {
      result.add(selectedTag!);
    }
    return result;
  }

  /// 统计每个标签命中的物品数量。
  Map<String, int> _tagCounts() {
    // 以物品为单位去重后的标签计数。
    final Map<String, int> counts = <String, int>{};
    for (final String tag in _tagNames()) {
      counts[tag] = records.where((InventoryRecord item) {
        // 旧数据中的文本标签与分类。
        final Set<String> itemTags = (item.tags ?? '')
            .split(',')
            .map((String value) => value.trim())
            .where((String value) => value.isNotEmpty)
            .toSet();
        // 当前物品是否已有规范分类关联。
        final bool hasCategoryLink =
            (taxonomyLinks[item.id] ?? const <String>{}).any(
              (String id) => tags.any(
                (TaxonomyEntry entry) =>
                    entry.id == id && entry.kind == TaxonomyKind.category.name,
              ),
            );
        if (!hasCategoryLink && (item.category?.trim().isNotEmpty ?? false)) {
          itemTags.add(item.category!.trim());
        }
        if (itemTags.contains(tag)) {
          return true;
        }
        // 规范标签关联。
        return (taxonomyLinks[item.id] ?? const <String>{}).any(
          (String id) => tags.any(
            (TaxonomyEntry entry) => entry.id == id && entry.name == tag,
          ),
        );
      }).length;
    }
    return counts;
  }

  /// 生成去重后的位置名称。
  List<String> _locationNames() {
    // 当前物品实际使用的位置名称集合。
    final Set<String> names = <String>{
      for (final InventoryRecord item in records)
        if (!(taxonomyLinks[item.id] ?? const <String>{}).any(
              (String id) =>
                  locations.any((TaxonomyEntry entry) => entry.id == id),
            ) &&
            (item.location?.trim().isNotEmpty ?? false))
          item.location!.trim(),
    };
    // 规范位置关联也视为当前物品实际使用的位置。
    for (final InventoryRecord item in records) {
      for (final String id in taxonomyLinks[item.id] ?? const <String>{}) {
        for (final TaxonomyEntry entry in locations) {
          if (entry.id == id) {
            names.add(entry.name.trim());
            break;
          }
        }
      }
    }
    // 先按位置管理器顺序输出，未纳入管理器的旧文本值再稳定追加。
    final List<String> result = <String>[];
    final Set<String> remaining = Set<String>.of(names);
    for (final TaxonomyEntry entry in locations) {
      final String name = entry.name.trim();
      if (remaining.remove(name)) {
        result.add(name);
      }
    }
    final List<String> unmanaged = remaining.toList()..sort();
    result.addAll(unmanaged);
    if (selectedLocation != null && !result.contains(selectedLocation)) {
      result.add(selectedLocation!);
    }
    return result;
  }
}

/// 搜索框左侧的筛选展开按钮。
class _InventoryFilterButton extends StatelessWidget {
  /// 筛选区当前是否展开。
  final bool expanded;

  /// 当前生效的筛选条件数量。
  final int activeCount;

  /// 点击按钮后的回调。
  final VoidCallback onPressed;

  /// 创建筛选展开按钮。
  const _InventoryFilterButton({
    required this.expanded,
    required this.activeCount,
    required this.onPressed,
  });

  /// 构建具有选中反馈与筛选数量提示的按钮。
  @override
  Widget build(BuildContext context) {
    // 当前主题的物品与边框色。
    final OmniColors colors = OmniColors.of(context);
    // 移动端使用更大的触控尺寸。
    final bool compact = OmniBreakpoint.isCompact(
      MediaQuery.sizeOf(context).width,
    );
    // 与相邻搜索框匹配的按钮尺寸。
    final double size = compact ? OmniSize.touch : OmniSize.pageAction;
    return SizedBox.square(
      key: const ValueKey<String>('inventory-filter-toggle'),
      dimension: size,
      child: IconButton(
        tooltip: expanded ? '收起筛选' : '展开筛选',
        onPressed: onPressed,
        isSelected: expanded,
        icon: Badge(
          isLabelVisible: activeCount > 0,
          label: Text('$activeCount'),
          backgroundColor: colors.item,
          child: const Icon(Icons.filter_list_rounded),
        ),
        selectedIcon: Badge(
          isLabelVisible: activeCount > 0,
          label: Text('$activeCount'),
          backgroundColor: colors.item,
          child: const Icon(Icons.filter_list_off_rounded),
        ),
        color: colors.muted,
        style: IconButton.styleFrom(
          backgroundColor: expanded
              ? colors.item.withValues(alpha: 0.12)
              : colors.paper,
          foregroundColor: expanded ? colors.item : colors.muted,
          side: BorderSide(
            color: expanded ? colors.item.withValues(alpha: 0.42) : colors.line,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(OmniRadius.panel),
          ),
        ),
      ),
    );
  }
}

/// 物品工具栏中的紧凑搜索框。
class _InventorySearchField extends StatelessWidget {
  /// 搜索输入控制器。
  final TextEditingController controller;

  /// 当前搜索词。
  final String query;

  /// 搜索框宽度。
  final double width;

  /// 搜索词变更回调。
  final ValueChanged<String> onChanged;

  /// 清空搜索回调。
  final VoidCallback onClear;

  /// 创建物品搜索框。
  const _InventorySearchField({
    required this.controller,
    required this.query,
    required this.width,
    required this.onChanged,
    required this.onClear,
  });

  /// 构建带物品色搜索图标的输入框。
  @override
  Widget build(BuildContext context) {
    // 当前主题的物品与中性色。
    final OmniColors colors = OmniColors.of(context);
    return SizedBox(
      key: const ValueKey<String>('inventory-search-field'),
      width: width,
      height: OmniSize.pageAction,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        style: Theme.of(context).textTheme.bodyMedium,
        decoration: InputDecoration(
          hintText: '搜索名称、分类、位置或标签',
          fillColor: colors.paper,
          contentPadding: EdgeInsets.zero,
          prefixIconConstraints: const BoxConstraints(
            minWidth: 42,
            minHeight: OmniSize.pageAction,
          ),
          prefixIcon: Padding(
            padding: const EdgeInsets.all(OmniSpacing.xxs),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.item.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(OmniRadius.control),
              ),
              child: Icon(
                Icons.search_rounded,
                size: OmniSize.icon,
                color: colors.item,
              ),
            ),
          ),
          suffixIconConstraints: const BoxConstraints(
            minWidth: OmniSize.control,
            minHeight: OmniSize.control,
          ),
          suffixIcon: query.isEmpty
              ? null
              : IconButton(
                  tooltip: '清空搜索',
                  onPressed: onClear,
                  icon: const Icon(Icons.close_rounded),
                ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(OmniRadius.panel),
            borderSide: BorderSide(color: colors.line),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(OmniRadius.panel),
            borderSide: BorderSide(color: colors.item, width: 1.5),
          ),
        ),
      ),
    );
  }
}

/// 物品标签或位置筛选行。
class _InventoryFilterRow extends StatelessWidget {
  /// 行标识。
  final String label;

  /// 可选名称。
  final List<String> values;

  /// 各筛选项对应的数量。
  final Map<String, int> counts;

  /// 全部筛选项对应的数量。
  final int totalCount;

  /// 是否在气泡中显示数量。
  final bool showCount;

  /// 当前选中名称。
  final String? selected;

  /// 选中项变更回调。
  final ValueChanged<String?> onChanged;

  /// 创建筛选行。
  const _InventoryFilterRow({
    super.key,
    required this.label,
    required this.values,
    this.counts = const <String, int>{},
    this.totalCount = 0,
    this.showCount = false,
    required this.selected,
    required this.onChanged,
  });

  /// 构建保持单行且可横向滚动的筛选标签。
  @override
  Widget build(BuildContext context) {
    // 当前主题的物品与中性色。
    final OmniColors colors = OmniColors.of(context);
    return SizedBox(
      height: OmniSize.control,
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 32,
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: colors.muted, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: OmniSpacing.xs),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: values.length + 1,
              separatorBuilder: (BuildContext context, int index) =>
                  const SizedBox(width: OmniSpacing.xs),
              itemBuilder: (BuildContext context, int index) {
                // 首项代表不限制当前筛选。
                final String? value = index == 0 ? null : values[index - 1];
                // 当前筛选项是否选中。
                final bool isSelected = value == selected;
                // 当前气泡文案，标签行附带命中数量。
                final String chipLabel = value == null
                    ? '全部$label${showCount ? ' $totalCount' : ''}'
                    : '$value${showCount ? ' ${counts[value] ?? 0}' : ''}';
                return ChoiceChip(
                  key: ValueKey<String>(
                    'inventory-${label == '标签' ? 'tag' : 'location'}-${value ?? 'all'}',
                  ),
                  label: Text(chipLabel),
                  selected: isSelected,
                  showCheckmark: false,
                  onSelected: (bool selectedValue) =>
                      onChanged(selectedValue ? value : null),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: OmniSpacing.xs,
                  ),
                  backgroundColor: colors.paper,
                  selectedColor: colors.item.withValues(alpha: 0.12),
                  side: BorderSide(
                    color: isSelected
                        ? colors.item.withValues(alpha: 0.42)
                        : colors.line,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(OmniRadius.control),
                  ),
                  labelStyle: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: isSelected ? colors.item : colors.muted,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 物品顶部统计面板。
class _InventoryStatistics extends StatelessWidget {
  /// 全部有效主物品。
  final AsyncValue<List<InventoryRecord>> items;

  /// 全部有效配套物品。
  final AsyncValue<List<InventoryRecord>> accessories;

  /// 当前物品分类。
  final List<TaxonomyEntry> categories;

  /// 创建物品顶部统计面板。
  const _InventoryStatistics({
    required this.items,
    required this.accessories,
    required this.categories,
  });

  /// 构建物品顶部统计面板。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前物品记录。
    final List<InventoryRecord> records =
        items.asData?.value ?? const <InventoryRecord>[];
    // 状态统计。
    final Map<String, int> statusCounts = <String, int>{
      'inUse': records
          .where((InventoryRecord item) => item.status == 'inUse')
          .length,
      'idle': records
          .where((InventoryRecord item) => item.status == 'idle')
          .length,
      'lent': records
          .where((InventoryRecord item) => item.status == 'lent')
          .length,
    };
    // 仅统计三个当前状态的物品记录。
    final List<InventoryRecord> currentRecords = records
        .where((InventoryRecord item) => statusCounts.containsKey(item.status))
        .toList(growable: false);
    // 参与购入价值统计的主物品与配套物品集合。
    final List<InventoryRecord> accessoryRecords =
        accessories.asData?.value ?? const <InventoryRecord>[];
    final List<InventoryRecord> valueRecords = <InventoryRecord>[
      ...currentRecords,
      ...accessoryRecords,
    ];
    // 按分类汇总购入金额。
    final List<_InventoryCategoryStat> categoryStats = _buildCategoryStats(
      valueRecords,
      categories,
      colors,
    );
    // 三个状态统计指标。
    final List<_InventoryStatusMetric> statusMetrics = <_InventoryStatusMetric>[
      _InventoryStatusMetric(
        label: '在用',
        count: statusCounts['inUse'] ?? 0,
        color: colors.success,
      ),
      _InventoryStatusMetric(
        label: '闲置',
        count: statusCounts['idle'] ?? 0,
        color: colors.muted,
      ),
      _InventoryStatusMetric(
        label: '已借出',
        count: statusCounts['lent'] ?? 0,
        color: colors.warning,
      ),
    ];
    // 当前统计内容。
    final Widget statusPanel = _InventoryStatusPanel(
      total: currentRecords.length,
      metrics: statusMetrics,
      accessories: accessories,
      loading: items.isLoading && !items.hasValue,
    );
    // 当前分类价值内容。
    final Widget valuePanel = _InventoryValuePanel(
      stats: categoryStats,
      totalCents: valueRecords.fold<int>(
        0,
        (int total, InventoryRecord item) =>
            total + (item.purchasePriceCents ?? 0),
      ),
      loading: items.isLoading && !items.hasValue,
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 宽屏并排展示两个统计面板。
        final bool useRow = constraints.maxWidth >= 760;
        if (useRow) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(flex: 5, child: statusPanel),
              const SizedBox(width: OmniSpacing.xs),
              Expanded(flex: 7, child: valuePanel),
            ],
          );
        }
        // 窄屏纵向展示，保留图例右置布局。
        return Column(
          children: <Widget>[
            statusPanel,
            const SizedBox(height: OmniSpacing.xs),
            valuePanel,
          ],
        );
      },
    );
  }

  /// 按分类汇总购入金额。
  List<_InventoryCategoryStat> _buildCategoryStats(
    List<InventoryRecord> records,
    List<TaxonomyEntry> categories,
    OmniColors colors,
  ) {
    // 分类名称到颜色的映射。
    final Map<String, Color> categoryColors = <String, Color>{
      for (final TaxonomyEntry category in categories)
        category.name.trim(): Color(category.colorValue),
    };
    // 分类名称到金额的映射。
    final Map<String, int> values = <String, int>{};
    // 分类名称到记录数的映射。
    final Map<String, int> counts = <String, int>{};
    for (final InventoryRecord item in records) {
      // 未填写分类的记录统一放入未分类。
      final String name = item.category?.trim().isNotEmpty == true
          ? item.category!.trim()
          : '未分类';
      values[name] = (values[name] ?? 0) + (item.purchasePriceCents ?? 0);
      counts[name] = (counts[name] ?? 0) + 1;
    }
    // 分类统计结果，金额从高到低排列。
    final List<_InventoryCategoryStat> result =
        values.entries
            .map(
              (MapEntry<String, int> entry) => _InventoryCategoryStat(
                label: entry.key,
                valueCents: entry.value,
                recordCount: counts[entry.key] ?? 0,
                color:
                    categoryColors[entry.key] ??
                    _inventoryChartColors[values.keys.toList().indexOf(
                          entry.key,
                        ) %
                        _inventoryChartColors.length],
              ),
            )
            .where((_InventoryCategoryStat item) => item.valueCents > 0)
            .toList()
          ..sort(
            (_InventoryCategoryStat first, _InventoryCategoryStat second) =>
                second.valueCents.compareTo(first.valueCents),
          );
    return result;
  }
}

/// 物品状态统计指标。
class _InventoryStatusMetric {
  /// 状态名称。
  final String label;

  /// 状态记录数。
  final int count;

  /// 状态颜色。
  final Color color;

  /// 创建物品状态统计指标。
  const _InventoryStatusMetric({
    required this.label,
    required this.count,
    required this.color,
  });
}

/// 物品分类价值统计。
class _InventoryCategoryStat {
  /// 分类名称。
  final String label;

  /// 分类购入金额，单位为分。
  final int valueCents;

  /// 分类下的物品记录数。
  final int recordCount;

  /// 分类图表颜色。
  final Color color;

  /// 创建物品分类价值统计。
  const _InventoryCategoryStat({
    required this.label,
    required this.valueCents,
    required this.recordCount,
    required this.color,
  });
}

/// 物品状态统计面板。
class _InventoryStatusPanel extends StatelessWidget {
  /// 当前物品总记录数。
  final int total;

  /// 三个状态统计指标。
  final List<_InventoryStatusMetric> metrics;

  /// 当前全部配套物品。
  final AsyncValue<List<InventoryRecord>> accessories;

  /// 是否正在加载数据。
  final bool loading;

  /// 创建物品状态统计面板。
  const _InventoryStatusPanel({
    required this.total,
    required this.metrics,
    required this.accessories,
    required this.loading,
  });

  /// 构建物品状态统计面板。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前配套物品条目数。
    final int accessoryCount = accessories.asData?.value.length ?? 0;
    return SizedBox(
      key: const ValueKey<String>('inventory-status-statistics'),
      height: 144,
      child: OmniPanel(
        padding: const EdgeInsets.all(OmniSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Container(
                      width: OmniSize.control,
                      height: OmniSize.control,
                      decoration: BoxDecoration(
                        color: colors.item.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(OmniRadius.panel),
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.inventory_2_outlined,
                        size: OmniSize.icon,
                        color: colors.item,
                      ),
                    ),
                    const SizedBox(width: OmniSpacing.xs),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '物品状态',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        Text(
                          '当前主物品记录',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ],
                ),
                Wrap(
                  spacing: OmniSpacing.xxs,
                  children: <Widget>[
                    _InventoryCountBadge(
                      label: '总物品数',
                      value: loading ? '...' : '$total 条',
                      valueKey: const ValueKey<String>('inventory-total-count'),
                      color: colors.item,
                    ),
                    _InventoryCountBadge(
                      label: '配套物品数',
                      value: accessories.isLoading && !accessories.hasValue
                          ? '...'
                          : '$accessoryCount 条',
                      valueKey: const ValueKey<String>(
                        'inventory-accessory-count',
                      ),
                      color: colors.item,
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: OmniSpacing.sm),
            Row(
              children: <Widget>[
                for (
                  int index = 0;
                  index < metrics.length;
                  index += 1
                ) ...<Widget>[
                  if (index > 0) const SizedBox(width: OmniSpacing.xs),
                  Expanded(
                    child: _InventoryStatusMetricView(
                      metric: metrics[index],
                      total: total,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 物品统计面板右上角的数量徽标。
class _InventoryCountBadge extends StatelessWidget {
  /// 徽标标题。
  final String label;

  /// 徽标数值。
  final String value;

  /// 数值测试标识。
  final Key valueKey;

  /// 徽标主题色。
  final Color color;

  /// 创建数量徽标。
  const _InventoryCountBadge({
    required this.label,
    required this.value,
    required this.valueKey,
    required this.color,
  });

  /// 构建数量徽标。
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: OmniSpacing.xs,
        vertical: OmniSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(OmniRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(width: OmniSpacing.xxs),
          Text(
            value,
            key: valueKey,
            style: Theme.of(context).textTheme.labelMedium
                ?.copyWith(color: color, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

/// 单个物品状态指标视图。
class _InventoryStatusMetricView extends StatelessWidget {
  /// 当前状态指标。
  final _InventoryStatusMetric metric;

  /// 三种状态的记录总数。
  final int total;

  /// 创建单个物品状态指标视图。
  const _InventoryStatusMetricView({required this.metric, required this.total});

  /// 构建单个物品状态指标视图。
  @override
  Widget build(BuildContext context) {
    // 当前主题文本样式。
    final TextTheme textTheme = Theme.of(context).textTheme;
    // 当前状态占全部物品的比例。
    final double ratio = total == 0 ? 0 : metric.count / total;
    return Column(
      key: ValueKey<String>('inventory-status-metric-${metric.label}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: metric.color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: OmniSpacing.xxs),
            Flexible(child: Text(metric.label, style: textTheme.bodySmall)),
            const SizedBox(width: OmniSpacing.xxs),
            Text(
              '${(ratio * 100).toStringAsFixed(0)}%',
              style: textTheme.labelSmall,
            ),
          ],
        ),
        const SizedBox(height: OmniSpacing.xxs),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            Text('${metric.count}', style: textTheme.titleMedium),
            const SizedBox(width: OmniSpacing.xxs),
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text('条', style: textTheme.labelSmall),
            ),
          ],
        ),
        const SizedBox(height: OmniSpacing.xxs),
        ClipRRect(
          borderRadius: BorderRadius.circular(OmniRadius.pill),
          child: LinearProgressIndicator(
            minHeight: 4,
            value: ratio,
            backgroundColor: metric.color.withValues(alpha: 0.12),
            valueColor: AlwaysStoppedAnimation<Color>(metric.color),
          ),
        ),
      ],
    );
  }
}

/// 物品购入价值统计面板。
class _InventoryValuePanel extends StatelessWidget {
  /// 分类价值统计。
  final List<_InventoryCategoryStat> stats;

  /// 当前购入总值，单位为分。
  final int totalCents;

  /// 是否正在加载数据。
  final bool loading;

  /// 创建物品购入价值统计面板。
  const _InventoryValuePanel({
    required this.stats,
    required this.totalCents,
    required this.loading,
  });

  /// 构建物品购入价值统计面板。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 图表中心金额文案。
    final String totalLabel = loading
        ? '...'
        : totalCents > 0
        ? _formatInventoryCompactK(totalCents)
        : '暂无金额';
    return SizedBox(
      key: const ValueKey<String>('inventory-value-statistics'),
      height: 144,
      child: OmniPanel(
        padding: const EdgeInsets.all(OmniSpacing.sm),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 120,
              height: 120,
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  CustomPaint(
                    key: const ValueKey<String>('inventory-value-donut'),
                    size: const Size.square(112),
                    painter: _InventoryDonutPainter(
                      stats: stats,
                      colors: colors,
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        '购入总值',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        totalLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: OmniSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('按分类分布', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: OmniSpacing.xxs),
                  Expanded(
                    child: stats.isEmpty
                        ? Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              loading ? '正在读取统计' : '暂无已记录金额',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          )
                        : ListView.separated(
                            padding: EdgeInsets.zero,
                            itemCount: stats.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 2),
                            itemBuilder: (BuildContext context, int index) {
                              // 当前分类统计。
                              final _InventoryCategoryStat stat = stats[index];
                              // 当前分类占比。
                              final double ratio = totalCents == 0
                                  ? 0
                                  : stat.valueCents / totalCents;
                              return KeyedSubtree(
                                key: ValueKey<String>(
                                  'inventory-category-legend-${stat.label}',
                                ),
                                child: _InventoryCategoryLegend(
                                  stat: stat,
                                  ratio: ratio,
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 物品分类图例。
class _InventoryCategoryLegend extends StatelessWidget {
  /// 当前分类统计。
  final _InventoryCategoryStat stat;

  /// 当前分类占比。
  final double ratio;

  /// 创建物品分类图例。
  const _InventoryCategoryLegend({required this.stat, required this.ratio});

  /// 构建物品分类图例。
  @override
  Widget build(BuildContext context) {
    // 当前主题文本样式。
    final TextTheme textTheme = Theme.of(context).textTheme;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 窄面板降低统计列宽度，给分类名称保留可读空间。
        final double detailWidth = (constraints.maxWidth * 0.52)
            .clamp(104.0, 148.0)
            .toDouble();
        return Row(
          children: <Widget>[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: stat.color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: OmniSpacing.xxs),
            Expanded(
              child: Text(
                stat.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodySmall,
              ),
            ),
            const SizedBox(width: OmniSpacing.sm),
            SizedBox(
              width: detailWidth,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          '${(ratio * 100).toStringAsFixed(1)}%',
                          textAlign: TextAlign.right,
                          style: textTheme.labelSmall,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: OmniSpacing.sm),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          _formatInventoryCny(stat.valueCents),
                          textAlign: TextAlign.right,
                          style: textTheme.labelMedium,
                        ),
                      ),
                    ),
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

/// 物品分类环形图绘制器。
class _InventoryDonutPainter extends CustomPainter {
  /// 分类价值统计。
  final List<_InventoryCategoryStat> stats;

  /// 当前主题语义色。
  final OmniColors colors;

  /// 创建物品分类环形图绘制器。
  _InventoryDonutPainter({required this.stats, required this.colors});

  /// 绘制分类环形图。
  @override
  void paint(Canvas canvas, Size size) {
    // 环形图绘制区域。
    final Rect rect = Offset.zero & size;
    // 环形图中心点。
    final Offset center = rect.center;
    // 环形图线宽，使用较细圆环保留更多中心留白。
    const double strokeWidth = 12;
    // 环形图半径。
    final double radius = size.shortestSide / 2 - strokeWidth / 2;
    // 环形图画笔。
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.butt;
    // 无金额时绘制空环。
    final int totalCents = stats.fold<int>(
      0,
      (int total, _InventoryCategoryStat stat) => total + stat.valueCents,
    );
    if (totalCents == 0) {
      paint.color = colors.mist;
      canvas.drawCircle(center, radius, paint);
      return;
    }
    // 当前扇区起始角度。
    double startAngle = -3.141592653589793 / 2;
    // 扇区之间的留白角度，形成截图中的分隔效果。
    final double gapAngle = stats.length > 1 ? 0.045 : 0;
    for (final _InventoryCategoryStat stat in stats) {
      // 当前扇区角度。
      final double sweepAngle =
          stat.valueCents / totalCents * 3.141592653589793 * 2;
      // 当前扇区实际绘制角度。
      final double visibleSweep = (sweepAngle - gapAngle)
          .clamp(0.0, sweepAngle)
          .toDouble();
      paint.color = stat.color;
      canvas.drawArc(
        rect.deflate(strokeWidth / 2),
        startAngle + gapAngle / 2,
        visibleSweep,
        false,
        paint,
      );
      startAngle += sweepAngle;
    }
  }

  /// 判断分类数据变化后是否需要重绘。
  @override
  bool shouldRepaint(covariant _InventoryDonutPainter oldDelegate) => true;
}

/// 物品统计图表备用颜色。
const List<Color> _inventoryChartColors = <Color>[
  Color(0xFF3370FF),
  Color(0xFF1EA7A1),
  Color(0xFFD97904),
  Color(0xFF8E5CD9),
  Color(0xFFF54A45),
  Color(0xFF5B8FF9),
];

/// 格式化物品统计金额。
String _formatInventoryCny(int cents) {
  // 带千位分隔的金额文本。
  final String amount = (cents / 100).toStringAsFixed(2);
  final List<String> parts = amount.split('.');
  final String integer = parts.first.replaceAllMapped(
    RegExp(r'(?<=\d)(?=(\d{3})+$)'),
    (Match match) => ',',
  );
  return '¥ $integer.${parts.last}';
}

/// 格式化物品卡片中的整元金额。
String _formatInventoryCardPrice(int cents) {
  // 按现有卡片规则将金额四舍五入到整元。
  final int roundedYuan = (cents / 100).round();
  // 带千位分隔的整元文本。
  final String amount = NumberFormat('#,##0').format(roundedYuan);
  return '¥ $amount';
}

/// 格式化环形图中心的千元金额。
String _formatInventoryCompactK(int cents) {
  // 购入金额转换为千元并保留最多一位小数。
  final double thousands = cents / 100000;
  final String value = thousands >= 10
      ? thousands.toStringAsFixed(0)
      : thousands.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');
  return '¥${value}k';
}

/// 物品卡片。
class _InventoryCard extends ConsumerWidget {
  /// 当前物品。
  final InventoryRecord item;

  /// 打开物品详情回调。
  final VoidCallback onOpen;

  /// 编辑回调。
  final VoidCallback onEdit;

  /// 配套物品回调。
  final VoidCallback onAccessories;

  /// 删除回调。
  final VoidCallback onDelete;

  /// 创建物品卡片。
  const _InventoryCard({
    required this.item,
    required this.onOpen,
    required this.onEdit,
    required this.onAccessories,
    required this.onDelete,
  });

  /// 构建物品卡片。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前界面的文字主题。
    final ThemeData theme = Theme.of(context);
    // 当前主物品的配套物品流。
    final AsyncValue<List<InventoryRecord>> accessories = ref.watch(
      inventoryAccessoriesProvider(item.id),
    );
    // 当前主物品的配套物品条目数。
    final int accessoryCount = accessories.asData?.value.length ?? 0;
    // 当前物品的价格展示文案。
    final String price = item.purchasePriceCents == null
        ? '未记录金额'
        : _formatInventoryCardPrice(item.purchasePriceCents!);
    // 当前物品的已使用时长文案。
    final String usageDuration = _usageDuration(item.purchaseDate);
    return OmniPanel(
      key: ValueKey<String>('inventory-card-${item.id}'),
      onTap: onOpen,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[_InventoryImage(item: item, colors: colors)],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              OmniSpacing.md,
              14,
              OmniSpacing.md,
              OmniSpacing.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  key: ValueKey<String>('inventory-status-row-${item.id}'),
                  children: <Widget>[
                    OmniTag(
                      label: _statusLabel(item.status),
                      color: _statusColor(colors, item.status),
                    ),
                    const SizedBox(width: OmniSpacing.xs),
                    Expanded(
                      child: Text(
                        item.category ?? '未分类',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.muted,
                        ),
                      ),
                    ),
                    if (accessoryCount > 0) ...<Widget>[
                      IconButton(
                        key: ValueKey<String>(
                          'inventory-accessories-button-${item.id}',
                        ),
                        tooltip: '查看配套物品',
                        onPressed: onAccessories,
                        icon: const Icon(Icons.inventory_2_outlined),
                        color: colors.item,
                        visualDensity: VisualDensity.compact,
                      ),
                      const SizedBox(width: OmniSpacing.xxs),
                    ],
                    OmniPopupMenuButton<String>(
                      key: ValueKey<String>('inventory-more-button-${item.id}'),
                      tooltip: '更多操作',
                      onSelected: (String value) {
                        if (value == 'edit') {
                          onEdit();
                        } else if (value == 'accessories') {
                          onAccessories();
                        } else if (value == 'image') {
                          AttachmentPickerDialog.show(
                            context,
                            businessType: AttachmentBusinessType.inventoryImage,
                            businessId: item.id,
                            title: '${item.name} · 主图',
                          );
                        } else {
                          onDelete();
                        }
                      },
                      itemBuilder: (_) => <PopupMenuEntry<String>>[
                        OmniPopupMenuItem<String>(
                          value: 'edit',
                          label: '编辑',
                          icon: Icons.edit_outlined,
                        ),
                        OmniPopupMenuItem<String>(
                          value: 'accessories',
                          label: '配套物品',
                          icon: Icons.inventory_2_outlined,
                        ),
                        OmniPopupMenuItem<String>(
                          value: 'image',
                          label: '更换图片',
                          icon: Icons.add_photo_alternate_outlined,
                        ),
                        OmniPopupMenuItem<String>(
                          value: 'delete',
                          label: '移入回收站',
                          icon: Icons.delete_outline_rounded,
                          danger: true,
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: OmniSpacing.xxs),
                Text(
                  item.name,
                  key: ValueKey<String>('inventory-name-${item.id}'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: OmniSpacing.xxs),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        item.location ?? '未记录位置',
                        key: ValueKey<String>('inventory-location-${item.id}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.muted,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    const SizedBox(width: OmniSpacing.xxs),
                    Text(
                      '数量 ${item.quantity}',
                      key: ValueKey<String>('inventory-quantity-${item.id}'),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.muted,
                        fontSize: 12,
                      ),
                    ),
                    if (accessoryCount > 0) ...<Widget>[
                      const SizedBox(width: OmniSpacing.xxs),
                      Text(
                        '· 配套 $accessoryCount',
                        key: ValueKey<String>(
                          'inventory-accessory-count-${item.id}',
                        ),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.muted,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 10),
                Divider(
                  key: ValueKey<String>('inventory-meta-divider-${item.id}'),
                  height: 1,
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        usageDuration,
                        key: ValueKey<String>('inventory-usage-${item.id}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.muted,
                          fontSize: 10,
                        ),
                      ),
                    ),
                    const SizedBox(width: OmniSpacing.xs),
                    Text(
                      price,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 根据购买日期返回适合展示的已使用时长。
  String _usageDuration(DateTime? purchaseDate) {
    if (purchaseDate == null) {
      return '使用时间未知';
    }
    // 当前本地日期。
    final DateTime today = DateTime.now();
    // 移除购买日期中可能存在的时分秒。
    final DateTime start = DateTime(
      purchaseDate.year,
      purchaseDate.month,
      purchaseDate.day,
    );
    // 移除当前日期中的时分秒。
    final DateTime end = DateTime(today.year, today.month, today.day);
    if (start.isAfter(end)) {
      return '已使用 0 日';
    }
    // 从购买日起实际经过的天数。
    final int totalDays = end.difference(start).inDays;
    if (totalDays < 30) {
      return '已使用 $totalDays 日';
    }
    // 截至当前日期已完整经过的月数。
    int totalMonths = (end.year - start.year) * 12 + end.month - start.month;
    if (end.day < start.day) {
      totalMonths -= 1;
    }
    if (totalMonths <= 12) {
      return '已使用 $totalMonths 月';
    }
    // 完整使用年数。
    final int years = totalMonths ~/ 12;
    // 扣除完整年后的剩余月数。
    final int months = totalMonths % 12;
    return months == 0 ? '已使用 $years 年' : '已使用 $years 年 $months 月';
  }

  /// 返回物品状态文案。
  String _statusLabel(String status) {
    return switch (status) {
      'idle' => '闲置',
      'lent' => '已借出',
      'sold' => '已售出',
      'discarded' => '已丢弃',
      _ => '在用',
    };
  }

  /// 返回物品状态语义色。
  Color _statusColor(OmniColors colors, String status) {
    return switch (status) {
      'idle' => colors.muted,
      'lent' => colors.warning,
      'sold' => colors.info,
      'discarded' => colors.danger,
      _ => colors.success,
    };
  }
}

/// 物品详情卡关闭后可继续执行的操作。
enum _InventoryDetailAction {
  /// 打开物品编辑器。
  edit,

  /// 打开配套物品管理。
  accessories,
}

/// 以卡牌形式展示的物品详情弹窗。
class _InventoryDetailDialog extends ConsumerWidget {
  /// 当前物品。
  final InventoryRecord item;

  /// 编辑物品回调。
  final VoidCallback onEdit;

  /// 查看配套物品回调。
  final VoidCallback onAccessories;

  /// 创建物品详情弹窗。
  const _InventoryDetailDialog({
    required this.item,
    required this.onEdit,
    required this.onAccessories,
  });

  /// 构建响应式物品详情卡片。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前主题文字样式。
    final ThemeData theme = Theme.of(context);
    // 当前视口尺寸。
    final Size viewport = MediaQuery.sizeOf(context);
    // 详情卡适配当前视口后的宽度。
    final double dialogWidth = math.min(680, viewport.width - 24);
    // 详情卡适配当前视口后的高度。
    final double dialogHeight = math.min(700, viewport.height - 24);
    // 当前主物品的配套物品流。
    final AsyncValue<List<InventoryRecord>> accessories = ref.watch(
      inventoryAccessoriesProvider(item.id),
    );
    // 当前主物品的配套物品条目数。
    final int accessoryCount = accessories.asData?.value.length ?? 0;
    return SafeArea(
      child: Center(
        child: Semantics(
          namesRoute: true,
          label: '${item.name}物品详情',
          child: Material(
            key: const ValueKey<String>('inventory-detail-card'),
            color: colors.paper,
            elevation: 20,
            shadowColor: Colors.black.withValues(alpha: 0.22),
            borderRadius: BorderRadius.circular(OmniRadius.dialog),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: dialogWidth,
              height: dialogHeight,
              child: Column(
                children: <Widget>[
                  Padding(
                    key: const ValueKey<String>('inventory-detail-header'),
                    padding: const EdgeInsets.fromLTRB(
                      OmniSpacing.lg,
                      OmniSpacing.sm,
                      OmniSpacing.xs,
                      OmniSpacing.xxs,
                    ),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                '物品详情',
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: colors.item,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: OmniSpacing.xxs),
                              SelectableText(
                                item.name,
                                minLines: 1,
                                maxLines: 2,
                                style: theme.textTheme.headlineSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭',
                          onPressed: () => Navigator.of(context).pop(),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: 40,
                            height: 40,
                          ),
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                  ),
                  Divider(height: 1, color: colors.line),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(
                        OmniSpacing.lg,
                        OmniSpacing.sm,
                        OmniSpacing.lg,
                        OmniSpacing.lg,
                      ),
                      child: SelectionArea(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            ClipRRect(
                              key: const ValueKey<String>(
                                'inventory-detail-image',
                              ),
                              borderRadius: BorderRadius.circular(
                                OmniRadius.panel,
                              ),
                              child: SizedBox(
                                height: viewport.width < 520 ? 150 : 190,
                                width: double.infinity,
                                child: _InventoryImage(
                                  item: item,
                                  colors: colors,
                                ),
                              ),
                            ),
                            const SizedBox(height: OmniSpacing.lg),
                            Row(
                              children: <Widget>[
                                OmniTag(
                                  label: _statusLabel(item.status),
                                  color: _statusColor(colors, item.status),
                                ),
                                const SizedBox(width: OmniSpacing.xs),
                                Text(
                                  item.category?.trim().isNotEmpty == true
                                      ? item.category!.trim()
                                      : '未分类',
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    color: colors.muted,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (accessoryCount > 0) ...<Widget>[
                                  const Spacer(),
                                  Icon(
                                    Icons.inventory_2_outlined,
                                    size: OmniSize.icon,
                                    color: colors.item,
                                  ),
                                  const SizedBox(width: OmniSpacing.xxs),
                                  Text(
                                    '$accessoryCount 件配套物品',
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: colors.item,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: OmniSpacing.md),
                            _InventoryDetailGrid(item: item),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Divider(height: 1, color: colors.line),
                  Padding(
                    padding: const EdgeInsets.all(OmniSpacing.md),
                    child: LayoutBuilder(
                      builder:
                          (BuildContext context, BoxConstraints constraints) {
                            // 查看配套物品操作。
                            final Widget? accessoryAction = accessoryCount > 0
                                ? SizedBox(
                                    height: OmniSize.controlLarge,
                                    child: OmniButton(
                                      label: '查看配套物品',
                                      icon: Icons.inventory_2_outlined,
                                      variant: OmniButtonVariant.secondary,
                                      large: true,
                                      onPressed: onAccessories,
                                    ),
                                  )
                                : null;
                            // 关闭详情操作。
                            final Widget closeAction = SizedBox(
                              key: const ValueKey<String>(
                                'inventory-detail-close-button',
                              ),
                              height: OmniSize.controlLarge,
                              child: OmniButton(
                                label: '关闭',
                                variant: OmniButtonVariant.secondary,
                                large: true,
                                onPressed: () => Navigator.of(context).pop(),
                              ),
                            );
                            // 进入编辑器操作。
                            final Widget editAction = SizedBox(
                              key: const ValueKey<String>(
                                'inventory-detail-edit-button',
                              ),
                              height: OmniSize.controlLarge,
                              child: OmniButton(
                                label: '编辑物品',
                                icon: Icons.edit_outlined,
                                variant: OmniButtonVariant.primary,
                                large: true,
                                onPressed: onEdit,
                              ),
                            );
                            if (constraints.maxWidth < 520) {
                              return Wrap(
                                alignment: WrapAlignment.end,
                                spacing: OmniSpacing.xs,
                                runSpacing: OmniSpacing.xs,
                                children: <Widget>[
                                  ?accessoryAction,
                                  closeAction,
                                  editAction,
                                ],
                              );
                            }
                            return Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: <Widget>[
                                if (accessoryAction != null) ...<Widget>[
                                  accessoryAction,
                                  const Spacer(),
                                ],
                                closeAction,
                                const SizedBox(width: OmniSpacing.xs),
                                editAction,
                              ],
                            );
                          },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 返回物品状态文案。
  String _statusLabel(String status) {
    return switch (status) {
      'idle' => '闲置',
      'lent' => '已借出',
      'sold' => '已售出',
      'discarded' => '已丢弃',
      _ => '在用',
    };
  }

  /// 返回物品状态语义色。
  Color _statusColor(OmniColors colors, String status) {
    return switch (status) {
      'idle' => colors.muted,
      'lent' => colors.warning,
      'sold' => colors.info,
      'discarded' => colors.danger,
      _ => colors.success,
    };
  }
}

/// 物品详情卡中的字段网格。
class _InventoryDetailGrid extends StatelessWidget {
  /// 当前物品。
  final InventoryRecord item;

  /// 创建物品详情字段网格。
  const _InventoryDetailGrid({required this.item});

  /// 构建随卡片宽度切换单双列的字段区。
  @override
  Widget build(BuildContext context) {
    // 购买金额展示文案。
    final String priceText = item.purchasePriceCents == null
        ? '未记录'
        : _formatInventoryCny(item.purchasePriceCents!);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 详情区是否具备双列展示空间。
        final bool twoColumns = constraints.maxWidth >= 520;
        // 单个详情字段的宽度。
        final double fieldWidth = twoColumns
            ? (constraints.maxWidth - OmniSpacing.md) / 2
            : constraints.maxWidth;
        // 需要展示的常规详情字段。
        final List<(String, String)> fields = <(String, String)>[
          ('存放位置', _textOrFallback(item.location)),
          ('数量', '${item.quantity}'),
          ('购买金额', priceText),
          ('购买日期', _formatDate(item.purchaseDate)),
          ('购买平台', _textOrFallback(item.purchasePlatform)),
          if (item.warrantyExpiration != null)
            ('保修到期', _formatDate(item.warrantyExpiration)),
          if (item.purchaseUrl?.trim().isNotEmpty ?? false)
            ('购买链接', item.purchaseUrl!.trim()),
        ];
        return Wrap(
          spacing: OmniSpacing.md,
          runSpacing: OmniSpacing.md,
          children: <Widget>[
            for (final (String, String) field in fields)
              SizedBox(
                width: fieldWidth,
                child: _InventoryDetailField(label: field.$1, value: field.$2),
              ),
            SizedBox(
              width: constraints.maxWidth,
              child: _InventoryDetailField(
                key: const ValueKey<String>('inventory-detail-notes'),
                label: '备注',
                value: _textOrFallback(item.notes),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 清理文本并为缺失内容提供统一占位。
  String _textOrFallback(String? value) {
    // 去除首尾空白后的字段值。
    final String normalized = value?.trim() ?? '';
    return normalized.isEmpty ? '未记录' : normalized;
  }

  /// 格式化仅包含日期的字段。
  String _formatDate(DateTime? value) {
    return value == null ? '未记录' : DateFormat('yyyy-MM-dd').format(value);
  }
}

/// 物品详情卡中的单个字段。
class _InventoryDetailField extends StatelessWidget {
  /// 字段名称。
  final String label;

  /// 字段值。
  final String value;

  /// 创建详情字段。
  const _InventoryDetailField({
    super.key,
    required this.label,
    required this.value,
  });

  /// 构建清晰区分标签和值的详情块。
  @override
  Widget build(BuildContext context) {
    // 当前主题文字样式。
    final ThemeData theme = Theme.of(context);
    // 当前主题中性色。
    final OmniColors colors = OmniColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: 13,
            color: colors.muted,
            fontWeight: FontWeight.w600,
            height: 1.3,
          ),
        ),
        const SizedBox(height: OmniSpacing.xxs),
        Text(
          value,
          style: theme.textTheme.bodyLarge?.copyWith(
            fontSize: 16,
            fontWeight: FontWeight.w500,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

/// 物品卡片顶部图片区域。
class _InventoryImage extends StatelessWidget {
  /// 当前物品。
  final InventoryRecord item;

  /// 当前主题语义色。
  final OmniColors colors;

  /// 创建图片区域。
  const _InventoryImage({required this.item, required this.colors});

  @override
  Widget build(BuildContext context) {
    if (item.imageLocalPath != null) {
      return Image.file(
        File(item.imageLocalPath!),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _PlaceholderImage(colors: colors),
      );
    }
    return _PlaceholderImage(colors: colors);
  }
}

/// 没有本地图片时使用的物品占位图。
class _PlaceholderImage extends StatelessWidget {
  /// 当前主题语义色。
  final OmniColors colors;

  /// 创建占位图。
  const _PlaceholderImage({required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: <Color>[
            colors.brand.withValues(alpha: 0.9),
            colors.item.withValues(alpha: 0.72),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            Container(
              width: 150,
              height: 150,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withValues(alpha: 0.4)),
              ),
            ),
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withValues(alpha: 0.45)),
              ),
            ),
            Text(
              'ITEM',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Colors.white,
                letterSpacing: 3,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 物品空状态。
class _InventoryEmpty extends StatelessWidget {
  /// 当前是否正在搜索。
  final bool searching;

  /// 创建物品空状态。
  const _InventoryEmpty({required this.searching});

  /// 构建物品空状态。
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.inventory_2_outlined, size: 48),
          const SizedBox(height: 14),
          Text(searching ? '没有找到匹配的物品' : '从最常找不到的那件物品开始记录'),
        ],
      ),
    );
  }
}

/// 物品编辑弹窗。
class _InventoryEditorDialog extends ConsumerStatefulWidget {
  /// 可选待编辑物品。
  final InventoryRecord? item;

  /// 可选主物品标识；存在时创建配套物品。
  final String? parentItemId;

  /// 创建物品编辑弹窗。
  const _InventoryEditorDialog({this.item, this.parentItemId});

  /// 创建弹窗状态。
  @override
  ConsumerState<_InventoryEditorDialog> createState() =>
      _InventoryEditorDialogState();
}

/// 物品编辑弹窗状态。
class _InventoryEditorDialogState
    extends ConsumerState<_InventoryEditorDialog> {
  /// 表单键。
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  /// 名称控制器。
  late final TextEditingController _nameController;

  /// 数量控制器。
  late final TextEditingController _quantityController;

  /// 金额控制器。
  late final TextEditingController _priceController;

  /// 位置控制器。
  late final TextEditingController _locationController;

  /// 购买链接控制器。
  late final TextEditingController _urlController;

  /// 分类控制器。
  late final TextEditingController _categoryController;

  /// 购买平台控制器。
  late final TextEditingController _platformController;

  /// 备注控制器。
  late final TextEditingController _notesController;

  /// 购买日期。
  DateTime? _purchaseDate;

  /// 保修到期日。
  DateTime? _warrantyExpiration;

  /// 物品状态。
  late InventoryStatus _status;

  /// 最近一次构建得到的可用分类。
  List<TaxonomyEntry> _availableCategories = const <TaxonomyEntry>[];

  /// 最近一次构建得到的可用位置。
  List<TaxonomyEntry> _availableLocations = const <TaxonomyEntry>[];

  /// 是否正在保存。
  bool _saving = false;

  /// 初始化编辑表单。
  @override
  void initState() {
    super.initState();
    // 待编辑物品。
    final InventoryRecord? item = widget.item;
    _nameController = TextEditingController(text: item?.name ?? '');
    _categoryController = TextEditingController(text: item?.category ?? '');
    _quantityController = TextEditingController(text: '${item?.quantity ?? 1}');
    _priceController = TextEditingController(
      text: item?.purchasePriceCents == null
          ? ''
          : (item!.purchasePriceCents! / 100).toStringAsFixed(2),
    );
    _locationController = TextEditingController(text: item?.location ?? '');
    _urlController = TextEditingController(text: item?.purchaseUrl ?? '');
    _platformController = TextEditingController(
      text: item?.purchasePlatform ?? '',
    );
    _notesController = TextEditingController(text: item?.notes ?? '');
    _purchaseDate = item?.purchaseDate;
    _warrantyExpiration = item?.warrantyExpiration;
    _status = InventoryStatus.values.firstWhere(
      (InventoryStatus value) => value.name == item?.status,
      orElse: () => InventoryStatus.inUse,
    );
    // 侧边栏中物品状态支持在用、闲置和借出。
    if (_status != InventoryStatus.inUse &&
        _status != InventoryStatus.idle &&
        _status != InventoryStatus.lent) {
      _status = InventoryStatus.inUse;
    }
    Future<void>.microtask(_loadCategory);
    Future<void>.microtask(_loadLocation);
  }

  /// 释放文本控制器。
  @override
  void dispose() {
    _nameController.dispose();
    _categoryController.dispose();
    _quantityController.dispose();
    _priceController.dispose();
    _locationController.dispose();
    _urlController.dispose();
    _platformController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  /// 保存物品。
  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    // 元格式金额。
    final double? priceYuan = _priceController.text.trim().isEmpty
        ? null
        : double.parse(_priceController.text);
    setState(() => _saving = true);
    try {
      await ref
          .read(inventoryRepositoryProvider)
          .save(
            InventoryDraft(
              id: widget.item?.id,
              name: _nameController.text,
              quantity: int.parse(_quantityController.text),
              purchasePriceCents: priceYuan == null
                  ? null
                  : (priceYuan * 100).round(),
              purchaseDate: _purchaseDate,
              purchaseUrl: _urlController.text,
              purchasePlatform: _platformController.text,
              location: _locationController.text,
              status: _status,
              warrantyExpiration: _warrantyExpiration,
              category: _categoryController.text,
              categoryIds: _availableCategories
                  .where(
                    (TaxonomyEntry entry) =>
                        entry.name == _categoryController.text.trim(),
                  )
                  .map((TaxonomyEntry entry) => entry.id)
                  .toSet(),
              locationIds: _availableLocations
                  .where(
                    (TaxonomyEntry entry) =>
                        entry.name == _locationController.text.trim(),
                  )
                  .map((TaxonomyEntry entry) => entry.id)
                  .toSet(),
              parentItemId: widget.item?.parentItemId ?? widget.parentItemId,
              notes: _notesController.text,
            ),
          );
      if (mounted) {
        Navigator.of(context).pop();
      }
    } on FormatException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  /// 读取现有物品分类关系。
  Future<void> _loadCategory() async {
    final String? itemId = widget.item?.id;
    if (itemId == null) return;
    final List<TaxonomyEntry> categories = await ref
        .read(taxonomyRepositoryProvider)
        .loadRecordTags(
          module: TaxonomyModule.inventory,
          recordId: itemId,
          kind: TaxonomyKind.category,
        );
    if (mounted && categories.isNotEmpty) {
      setState(() => _categoryController.text = categories.first.name);
    }
  }

  /// 读取现有物品位置关系。
  Future<void> _loadLocation() async {
    final String? itemId = widget.item?.id;
    if (itemId == null) return;
    final List<TaxonomyEntry> locations = await ref
        .read(taxonomyRepositoryProvider)
        .loadRecordTags(
          module: TaxonomyModule.inventory,
          recordId: itemId,
          kind: TaxonomyKind.location,
        );
    if (mounted && locations.isNotEmpty) {
      setState(() => _locationController.text = locations.first.name);
    }
  }

  /// 构建物品编辑表单。
  @override
  Widget build(BuildContext context) {
    // 当前物品分类。
    final List<TaxonomyEntry> categories =
        ref
            .watch(
              taxonomyEntriesProvider((
                TaxonomyModule.inventory,
                TaxonomyKind.category,
              )),
            )
            .asData
            ?.value
            .toList(growable: false) ??
        const <TaxonomyEntry>[];
    final List<TaxonomyEntry> locations =
        ref
            .watch(
              taxonomyEntriesProvider((
                TaxonomyModule.inventory,
                TaxonomyKind.location,
              )),
            )
            .asData
            ?.value
            .toList(growable: false) ??
        const <TaxonomyEntry>[];
    _availableCategories = categories;
    _availableLocations = locations;
    final List<String> categoryNames = <String>{
      if (_categoryController.text.trim().isNotEmpty)
        _categoryController.text.trim(),
      ...categories.map((TaxonomyEntry entry) => entry.name),
    }.toList(growable: false);
    final List<String> locationNames = <String>{
      if (_locationController.text.trim().isNotEmpty)
        _locationController.text.trim(),
      ...locations.map((TaxonomyEntry entry) => entry.name),
    }.toList(growable: false);
    return OmniSideSheetScaffold(
      title: widget.item != null
          ? '编辑物品'
          : widget.parentItemId == null
          ? '添加物品'
          : '添加配套物品',
      canClose: !_saving,
      actions: <Widget>[
        OmniButton(
          label: '取消',
          variant: OmniButtonVariant.secondary,
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
        ),
        OmniButton(
          label: '保存',
          onPressed: _saving ? null : _save,
          loading: _saving,
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.all(OmniSpacing.lg),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextFormField(
                  controller: _nameController,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: '物品名称 *'),
                  validator: (String? value) =>
                      value == null || value.trim().isEmpty ? '请输入物品名称' : null,
                ),
                const SizedBox(height: 14),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: TextFormField(
                        controller: _quantityController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: '数量 *'),
                        validator: (String? value) {
                          // 解析后的数量。
                          final int? parsed = int.tryParse(value ?? '');
                          return parsed == null || parsed <= 0
                              ? '请输入正整数'
                              : null;
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OmniDropdownButtonFormField<InventoryStatus>(
                        initialValue: _status,
                        decoration: const InputDecoration(labelText: '物品状态'),
                        items:
                            <InventoryStatus>[
                                  InventoryStatus.inUse,
                                  InventoryStatus.idle,
                                  InventoryStatus.lent,
                                ]
                                .map(
                                  (InventoryStatus value) =>
                                      DropdownMenuItem<InventoryStatus>(
                                        value: value,
                                        child: Text(_statusLabel(value)),
                                      ),
                                )
                                .toList(growable: false),
                        onChanged: (InventoryStatus? value) {
                          if (value != null) {
                            setState(() => _status = value);
                          }
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: OmniDropdownButtonFormField<String>(
                        initialValue: _categoryController.text.trim().isEmpty
                            ? null
                            : _categoryController.text.trim(),
                        decoration: const InputDecoration(labelText: '分类'),
                        items: categoryNames
                            .map(
                              (String value) => DropdownMenuItem<String>(
                                value: value,
                                child: Text(value),
                              ),
                            )
                            .toList(growable: false),
                        onChanged: (String? value) => setState(
                          () => _categoryController.text = value ?? '',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OmniDropdownButtonFormField<String>(
                        initialValue: _locationController.text.trim().isEmpty
                            ? null
                            : _locationController.text.trim(),
                        decoration: InputDecoration(
                          labelText: '存放位置',
                          helperText:
                              widget.parentItemId == null &&
                                  widget.item?.parentItemId == null
                              ? null
                              : '留空时随主物品存放',
                        ),
                        items: locationNames
                            .map(
                              (String value) => DropdownMenuItem<String>(
                                value: value,
                                child: Text(value),
                              ),
                            )
                            .toList(growable: false),
                        onChanged: (String? value) => setState(
                          () => _locationController.text = value ?? '',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: TextFormField(
                        controller: _priceController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(labelText: '购买金额（元）'),
                        validator: (String? value) {
                          if (value == null || value.trim().isEmpty) {
                            return null;
                          }
                          // 解析后的金额。
                          final double? parsed = double.tryParse(value);
                          return parsed == null || parsed < 0
                              ? '请输入有效金额'
                              : null;
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OmniDatePickerButton(
                        value: _purchaseDate,
                        initialDate: _purchaseDate ?? DateTime.now(),
                        firstDate: DateTime(1970),
                        lastDate: DateTime(2100),
                        label: _purchaseDate == null
                            ? '选择购买日期'
                            : DateFormat('yyyy-MM-dd').format(_purchaseDate!),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(double.infinity, 48),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                        ),
                        onChanged: (DateTime selected) {
                          setState(() => _purchaseDate = selected);
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        controller: _platformController,
                        decoration: const InputDecoration(labelText: '购买平台'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _urlController,
                        decoration: const InputDecoration(
                          labelText: '购买链接',
                          hintText: 'https://',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OmniDatePickerButton(
                    value: _warrantyExpiration,
                    initialDate: _warrantyExpiration ?? DateTime.now(),
                    firstDate: DateTime(1970),
                    lastDate: DateTime(2100),
                    label: _warrantyExpiration == null
                        ? '选择保修到期日'
                        : '保修至 ${DateFormat('yyyy-MM-dd').format(_warrantyExpiration!)}',
                    icon: Icons.verified_user_outlined,
                    onChanged: (DateTime selected) {
                      setState(() => _warrantyExpiration = selected);
                    },
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _notesController,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: '备注'),
                ),
                const SizedBox(height: 10),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 返回物品状态文案。
  String _statusLabel(InventoryStatus status) {
    return switch (status) {
      InventoryStatus.inUse => '在用',
      InventoryStatus.idle => '闲置',
      InventoryStatus.lent => '已借出',
      InventoryStatus.sold => '已售出',
      InventoryStatus.discarded => '已丢弃',
    };
  }
}

/// 配套物品管理弹窗。
class _AccessoriesDialog extends ConsumerWidget {
  /// 当前主物品。
  final InventoryRecord parent;

  /// 创建配套物品管理弹窗。
  const _AccessoriesDialog({required this.parent});

  /// 打开配套物品编辑器。
  Future<void> _edit(BuildContext context, [InventoryRecord? item]) async {
    await showOmniSideSheet<void>(
      context,
      builder: (BuildContext context) =>
          _InventoryEditorDialog(item: item, parentItemId: parent.id),
    );
  }

  /// 删除配套物品。
  Future<void> _delete(WidgetRef ref, InventoryRecord item) async {
    await ref.read(inventoryRepositoryProvider).delete(item.id);
  }

  /// 构建配套物品管理弹窗。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 当前配套物品流。
    final AsyncValue<List<InventoryRecord>> accessories = ref.watch(
      inventoryAccessoriesProvider(parent.id),
    );
    return OmniDialogScaffold(
      title: '${parent.name} · 配套物品',
      width: 720,
      height: 640,
      actions: <Widget>[
        OmniButton(
          label: '添加配套物品',
          icon: Icons.add_rounded,
          variant: OmniButtonVariant.secondary,
          onPressed: () => _edit(context),
        ),
        OmniButton(label: '完成', onPressed: () => Navigator.of(context).pop()),
      ],
      child: accessories.when(
        data: (List<InventoryRecord> records) {
          // 配套物品已记录金额合计。
          final int totalCents = records.fold<int>(
            0,
            (int total, InventoryRecord item) =>
                total + (item.purchasePriceCents ?? 0),
          );
          // 配套物品总件数。
          final int totalQuantity = records.fold<int>(
            0,
            (int total, InventoryRecord item) => total + item.quantity,
          );
          // 配套物品未记录金额的条目数。
          final int unpricedCount = records
              .where((InventoryRecord item) => item.purchasePriceCents == null)
              .length;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _AccessorySummary(
                key: const ValueKey<String>('inventory-accessory-summary'),
                recordCount: records.length,
                totalQuantity: totalQuantity,
                totalCents: totalCents,
                unpricedCount: unpricedCount,
              ),
              const SizedBox(height: OmniSpacing.sm),
              Expanded(
                child: records.isEmpty
                    ? const _AccessoryEmptyState()
                    : ListView.separated(
                        itemCount: records.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(height: OmniSpacing.xxs),
                        itemBuilder: (BuildContext context, int index) {
                          // 当前配套物品。
                          final InventoryRecord item = records[index];
                          return _AccessoryListItem(
                            item: item,
                            parent: parent,
                            onTap: () => _edit(context, item),
                            onDelete: () => _delete(ref, item),
                          );
                        },
                      ),
              ),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, StackTrace stackTrace) =>
            Center(child: Text('配套物品读取失败：$error')),
      ),
    );
  }
}

/// 配套物品摘要指标区。
class _AccessorySummary extends StatelessWidget {
  /// 配套物品条目数。
  final int recordCount;

  /// 配套物品总件数。
  final int totalQuantity;

  /// 已记录金额合计，单位为分。
  final int totalCents;

  /// 未计价条目数。
  final int unpricedCount;

  /// 创建配套物品摘要指标区。
  const _AccessorySummary({
    super.key,
    required this.recordCount,
    required this.totalQuantity,
    required this.totalCents,
    required this.unpricedCount,
  });

  /// 构建配套物品摘要指标区。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 宽度不足时让指标自动换行，避免金额文案被截断。
        final double itemWidth = constraints.maxWidth < 560
            ? (constraints.maxWidth - OmniSpacing.xs) / 2
            : (constraints.maxWidth - OmniSpacing.xs * 3) / 4;
        return Wrap(
          spacing: OmniSpacing.xs,
          runSpacing: OmniSpacing.xs,
          children: <Widget>[
            _AccessoryMetric(
              width: itemWidth,
              label: '配套条目',
              value: '$recordCount 条',
              icon: Icons.extension_outlined,
              color: colors.item,
            ),
            _AccessoryMetric(
              width: itemWidth,
              label: '总件数',
              value: '$totalQuantity 件',
              icon: Icons.inventory_2_outlined,
              color: colors.success,
            ),
            _AccessoryMetric(
              width: itemWidth,
              label: '已计价金额',
              value: _formatInventoryCny(totalCents),
              icon: Icons.payments_outlined,
              color: colors.warning,
            ),
            _AccessoryMetric(
              width: itemWidth,
              label: '待补金额',
              value: '$unpricedCount 条',
              icon: Icons.help_outline_rounded,
              color: unpricedCount == 0 ? colors.success : colors.danger,
            ),
          ],
        );
      },
    );
  }
}

/// 配套物品摘要中的单项指标。
class _AccessoryMetric extends StatelessWidget {
  /// 指标宽度。
  final double width;

  /// 指标标题。
  final String label;

  /// 指标数值。
  final String value;

  /// 指标图标。
  final IconData icon;

  /// 指标语义色。
  final Color color;

  /// 创建配套物品指标。
  const _AccessoryMetric({
    required this.width,
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  /// 构建配套物品指标。
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: OmniPanel(
        padding: const EdgeInsets.all(OmniSpacing.xs),
        child: Row(
          children: <Widget>[
            Icon(icon, size: OmniSize.icon, color: color),
            const SizedBox(width: OmniSpacing.xs),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(label, style: Theme.of(context).textTheme.labelSmall),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall
                        ?.copyWith(color: color, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 配套物品明细为空时的引导状态。
class _AccessoryEmptyState extends StatelessWidget {
  /// 创建空状态。
  const _AccessoryEmptyState();

  /// 构建空状态。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.extension_outlined, size: 32, color: colors.muted),
          const SizedBox(height: OmniSpacing.xs),
          const Text('还没有配套物品'),
          const SizedBox(height: OmniSpacing.xxs),
          Text(
            '点击右上角“添加配套物品”开始记录',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.muted),
          ),
        ],
      ),
    );
  }
}

/// 配套物品明细行。
class _AccessoryListItem extends StatelessWidget {
  /// 当前配套物品。
  final InventoryRecord item;

  /// 当前主物品。
  final InventoryRecord parent;

  /// 查看或编辑回调。
  final VoidCallback onTap;

  /// 删除回调。
  final VoidCallback onDelete;

  /// 创建配套物品明细行。
  const _AccessoryListItem({
    required this.item,
    required this.parent,
    required this.onTap,
    required this.onDelete,
  });

  /// 构建配套物品明细行。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 配套物品的位置展示文案。
    final String location = item.location?.trim().isNotEmpty == true
        ? '独立存放 · ${item.location}'
        : '随主物品存放 · ${parent.location ?? '主物品未记录位置'}';
    // 配套物品金额展示文案。
    final String price = item.purchasePriceCents == null
        ? '未记录金额'
        : _formatInventoryCny(item.purchasePriceCents!);
    // 配套物品购买日期展示文案。
    final String purchaseDate = item.purchaseDate == null
        ? '未记录购买日期'
        : DateFormat('yyyy-MM-dd').format(item.purchaseDate!);
    return OmniPanel(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(
        horizontal: OmniSpacing.sm,
        vertical: OmniSpacing.xs,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: colors.item.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(OmniRadius.control),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.extension_outlined, color: colors.item),
          ),
          const SizedBox(width: OmniSpacing.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    Text(
                      '× ${item.quantity}',
                      style: Theme.of(context).textTheme.labelMedium
                          ?.copyWith(color: colors.muted),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '$location · $purchaseDate',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colors.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: OmniSpacing.xs),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Text(
                price,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: item.purchasePriceCents == null
                      ? colors.muted
                      : colors.ink,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                _statusLabel(item.status),
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: colors.muted),
              ),
            ],
          ),
          IconButton(
            tooltip: '删除配套物品',
            onPressed: onDelete,
            icon: Icon(Icons.delete_outline_rounded, color: colors.danger),
          ),
        ],
      ),
    );
  }

  /// 返回物品状态文案。
  String _statusLabel(String status) {
    return switch (status) {
      'inUse' => '在用',
      'idle' => '闲置',
      'lent' => '已借出',
      'sold' => '已售出',
      'discarded' => '已丢弃',
      _ => '未标记',
    };
  }
}
