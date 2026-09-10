import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/features/inventory/data/inventory_repository.dart';
import 'package:omni_butler/shared/taxonomy/taxonomy_manager_dialog.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 显示物品批量搬家工作台。
Future<InventoryMoveResult?> showInventoryMoveDialog(
  BuildContext context,
) async {
  return showDialog<InventoryMoveResult>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext dialogContext) => const InventoryMoveDialog(),
  );
}

/// 物品批量搬家工作台。
class InventoryMoveDialog extends ConsumerStatefulWidget {
  /// 创建物品批量搬家工作台。
  const InventoryMoveDialog({super.key});

  /// 创建物品批量搬家工作台状态。
  @override
  ConsumerState<InventoryMoveDialog> createState() =>
      _InventoryMoveDialogState();
}

/// 物品批量搬家工作台状态。
class _InventoryMoveDialogState extends ConsumerState<InventoryMoveDialog> {
  /// 左侧搜索控制器。
  final TextEditingController _searchController = TextEditingController();

  /// 用户直接选择的物品标识。
  final Set<String> _selectedIds = <String>{};

  /// 当前搜索词。
  String _query = '';

  /// 当前目标位置标识。
  String? _destinationLocationId;

  /// 移动端当前步骤，0 为选择物品，1 为确认迁移。
  int _mobileStep = 0;

  /// 当前是否正在迁移。
  bool _moving = false;

  /// 释放搜索控制器。
  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 切换一条物品的直接选择状态。
  void _toggleItem(InventoryRecord record, _InventoryMoveData data) {
    // 当前记录是否由已选主物品自动带走。
    final bool autoIncluded = data
        .autoIncludedIds(_selectedIds)
        .contains(record.id);
    if (autoIncluded) {
      return;
    }
    setState(() {
      if (!_selectedIds.remove(record.id)) {
        _selectedIds.add(record.id);
      }
      _normalizeSelection(data);
    });
  }

  /// 切换一个位置分组中的全部物品。
  void _toggleGroup(_InventoryMoveGroup group, _InventoryMoveData data) {
    // 当前所有直接或自动纳入迁移的物品标识。
    final Set<String> migrationIds = data.migrationIds(_selectedIds);
    // 当前分组是否已经全部选中。
    final bool allSelected = group.records.every(
      (InventoryRecord record) => migrationIds.contains(record.id),
    );
    setState(() {
      if (allSelected) {
        for (final InventoryRecord record in group.records) {
          _selectedIds.remove(record.id);
          if (record.parentItemId == null) {
            // 当前主物品自动带入的配件标识。
            final Iterable<String> childIds = data.records
                .where(
                  (InventoryRecord child) =>
                      child.parentItemId == record.id &&
                      data.isInherited(child),
                )
                .map((InventoryRecord child) => child.id);
            _selectedIds.removeAll(childIds);
          }
        }
      } else {
        _selectedIds.addAll(
          group.records.map((InventoryRecord record) => record.id),
        );
      }
      _normalizeSelection(data);
    });
  }

  /// 移除因已选主物品而重复直接选择的继承位置配件。
  void _normalizeSelection(_InventoryMoveData data) {
    _selectedIds.removeWhere((String id) => !data.recordsById.containsKey(id));
    // 已选择的全部主物品标识。
    final Set<String> selectedParentIds = _selectedIds
        .where((String id) => data.recordsById[id]?.parentItemId == null)
        .toSet();
    // 已经由主物品自动带走的配件标识。
    final Set<String> redundantChildIds = data.records
        .where(
          (InventoryRecord record) =>
              record.parentItemId != null &&
              selectedParentIds.contains(record.parentItemId) &&
              data.isInherited(record),
        )
        .map((InventoryRecord record) => record.id)
        .toSet();
    _selectedIds.removeAll(redundantChildIds);
  }

  /// 执行批量迁移并返回页面。
  Future<void> _move(_InventoryMoveData data) async {
    // 当前选择的目标位置标识。
    final String? destinationLocationId = _destinationLocationId;
    if (destinationLocationId == null || _moving) {
      return;
    }
    // 当前仍然有效的直接选择物品标识。
    final Set<String> validSelectedIds = _selectedIds
        .where(data.recordsById.containsKey)
        .toSet();
    // 直接选择和自动跟随物品组成的最终迁移集合。
    final Set<String> migrationIds = data.migrationIds(validSelectedIds);
    if (migrationIds.isEmpty) {
      return;
    }
    setState(() => _moving = true);
    try {
      // 仓储返回的批量迁移结果。
      final InventoryMoveResult result = await ref
          .read(inventoryRepositoryProvider)
          .moveItems(
            itemIds: migrationIds,
            destinationLocationId: destinationLocationId,
          );
      if (mounted) {
        Navigator.of(context).pop(result);
      }
    } on FormatException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('物品迁移失败：$error')));
      }
    } finally {
      if (mounted) {
        setState(() => _moving = false);
      }
    }
  }

  /// 构建物品搬家工作台。
  @override
  Widget build(BuildContext context) {
    // 当前全部主物品。
    final AsyncValue<List<InventoryRecord>> parentItems = ref.watch(
      inventoryItemsProvider(''),
    );
    // 当前全部配套物品。
    final AsyncValue<List<InventoryRecord>> accessories = ref.watch(
      inventoryAllAccessoriesProvider,
    );
    // 当前全部规范位置。
    final AsyncValue<List<TaxonomyEntry>> locations = ref.watch(
      taxonomyEntriesProvider((
        TaxonomyModule.inventory,
        TaxonomyKind.location,
      )),
    );
    // 当前物品 taxonomy 关联。
    final AsyncValue<Map<String, Set<String>>> taxonomyLinks = ref.watch(
      inventoryTaxonomyLinksProvider,
    );
    // 当前视口尺寸。
    final Size viewport = MediaQuery.sizeOf(context);
    // 当前是否运行在移动平台紧凑宽度。
    final bool compact =
        !OmniBreakpoint.isDesktopPlatform(Theme.of(context).platform) &&
        OmniBreakpoint.isCompact(viewport.width);
    // 任一数据源的读取错误。
    final Object? error = <AsyncValue<Object?>>[
      parentItems,
      accessories,
      locations,
      taxonomyLinks,
    ].where((AsyncValue<Object?> value) => value.hasError).firstOrNull?.error;
    // 当前是否仍有数据源正在加载。
    final bool loading =
        parentItems.isLoading ||
        accessories.isLoading ||
        locations.isLoading ||
        taxonomyLinks.isLoading;
    // 弹窗目标宽度。
    final double dialogWidth = compact
        ? viewport.width
        : math.min(1100, math.max(620, viewport.width - 64));
    // 弹窗目标高度。
    final double dialogHeight = compact
        ? viewport.height
        : math.min(760, math.max(560, viewport.height - 64));
    return Dialog(
      key: const ValueKey<String>('inventory-move-dialog'),
      insetPadding: compact ? EdgeInsets.zero : const EdgeInsets.all(32),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: error != null
            ? _InventoryMoveFailure(error: error)
            : loading
            ? const Center(child: CircularProgressIndicator())
            : _buildLoaded(
                context,
                compact: compact,
                parents: parentItems.value ?? const <InventoryRecord>[],
                accessories: accessories.value ?? const <InventoryRecord>[],
                locations: locations.value ?? const <TaxonomyEntry>[],
                taxonomyLinks:
                    taxonomyLinks.value ?? const <String, Set<String>>{},
              ),
      ),
    );
  }

  /// 构建数据读取完成后的搬家工作台。
  Widget _buildLoaded(
    BuildContext context, {
    required bool compact,
    required List<InventoryRecord> parents,
    required List<InventoryRecord> accessories,
    required List<TaxonomyEntry> locations,
    required Map<String, Set<String>> taxonomyLinks,
  }) {
    // 合并后的全部有效物品。
    final List<InventoryRecord> records = <InventoryRecord>[
      ...parents,
      ...accessories,
    ];
    // 当前搬家展示数据。
    final _InventoryMoveData data = _InventoryMoveData(
      records: records,
      locations: locations,
      taxonomyLinks: taxonomyLinks,
    );
    // 当前仍然存在的直接选择物品标识。
    final Set<String> validSelectedIds = _selectedIds
        .where(data.recordsById.containsKey)
        .toSet();
    // 当前全部直接或自动纳入迁移的物品标识。
    final Set<String> migrationIds = data.migrationIds(validSelectedIds);
    // 当前由主物品自动带走的配件标识。
    final Set<String> autoIncludedIds = data.autoIncludedIds(validSelectedIds);
    // 当前仍然可用的目标位置标识。
    final String? effectiveDestinationLocationId =
        locations.any(
          (TaxonomyEntry location) => location.id == _destinationLocationId,
        )
        ? _destinationLocationId
        : null;
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 工作台主体内容。
    final Widget content = compact
        ? (_mobileStep == 0
              ? _InventoryMoveSourcePanel(
                  data: data,
                  query: _query,
                  searchController: _searchController,
                  selectedIds: migrationIds,
                  autoIncludedIds: autoIncludedIds,
                  onSearchChanged: (String value) =>
                      setState(() => _query = value),
                  onToggleItem: (InventoryRecord record) =>
                      _toggleItem(record, data),
                  onToggleGroup: (_InventoryMoveGroup group) =>
                      _toggleGroup(group, data),
                )
              : _InventoryMoveTargetPanel(
                  data: data,
                  directSelectedIds: validSelectedIds,
                  migrationIds: migrationIds,
                  autoIncludedIds: autoIncludedIds,
                  destinationLocationId: effectiveDestinationLocationId,
                  onDestinationChanged: (String? value) =>
                      setState(() => _destinationLocationId = value),
                  onRemove: (String id) => setState(() {
                    _selectedIds.remove(id);
                    _normalizeSelection(data);
                  }),
                ))
        : Row(
            children: <Widget>[
              Expanded(
                flex: 11,
                child: _InventoryMoveSourcePanel(
                  data: data,
                  query: _query,
                  searchController: _searchController,
                  selectedIds: migrationIds,
                  autoIncludedIds: autoIncludedIds,
                  onSearchChanged: (String value) =>
                      setState(() => _query = value),
                  onToggleItem: (InventoryRecord record) =>
                      _toggleItem(record, data),
                  onToggleGroup: (_InventoryMoveGroup group) =>
                      _toggleGroup(group, data),
                ),
              ),
              _InventoryMoveRail(selectedCount: migrationIds.length),
              Expanded(
                flex: 9,
                child: _InventoryMoveTargetPanel(
                  data: data,
                  directSelectedIds: validSelectedIds,
                  migrationIds: migrationIds,
                  autoIncludedIds: autoIncludedIds,
                  destinationLocationId: effectiveDestinationLocationId,
                  onDestinationChanged: (String? value) =>
                      setState(() => _destinationLocationId = value),
                  onRemove: (String id) => setState(() {
                    _selectedIds.remove(id);
                    _normalizeSelection(data);
                  }),
                ),
              ),
            ],
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _InventoryMoveHeader(
          compact: compact,
          mobileStep: _mobileStep,
          onClose: _moving ? null : () => Navigator.of(context).pop(),
        ),
        Divider(height: 1, color: colors.line),
        Expanded(child: content),
        Divider(height: 1, color: colors.line),
        _InventoryMoveFooter(
          compact: compact,
          mobileStep: _mobileStep,
          selectedRecordCount: migrationIds.length,
          selectedQuantity: data.quantityOf(migrationIds),
          destinationSelected: effectiveDestinationLocationId != null,
          moving: _moving,
          onCancel: () => Navigator.of(context).pop(),
          onBack: () => setState(() => _mobileStep = 0),
          onNext: migrationIds.isEmpty
              ? null
              : () => setState(() => _mobileStep = 1),
          onMove: migrationIds.isEmpty || effectiveDestinationLocationId == null
              ? null
              : () => _move(data),
        ),
      ],
    );
  }
}

/// 搬家工作台标题区。
class _InventoryMoveHeader extends StatelessWidget {
  /// 是否为移动端紧凑布局。
  final bool compact;

  /// 移动端当前步骤。
  final int mobileStep;

  /// 关闭回调。
  final VoidCallback? onClose;

  /// 创建搬家工作台标题区。
  const _InventoryMoveHeader({
    required this.compact,
    required this.mobileStep,
    required this.onClose,
  });

  /// 构建标题、说明和关闭操作。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 12, 14),
      child: Row(
        children: <Widget>[
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: colors.brandSoft,
              borderRadius: BorderRadius.circular(OmniRadius.control),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.local_shipping_outlined, color: colors.brand),
          ),
          const SizedBox(width: OmniSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text('物品搬家', style: Theme.of(context).textTheme.titleLarge),
                Text(
                  compact
                      ? '${mobileStep + 1}/2 · ${mobileStep == 0 ? '选择物品' : '确认迁移'}'
                      : '从现有位置选择物品，再统一迁移到新位置',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '关闭',
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }
}

/// 左侧物品来源树。
class _InventoryMoveSourcePanel extends StatelessWidget {
  /// 搬家展示数据。
  final _InventoryMoveData data;

  /// 当前搜索词。
  final String query;

  /// 搜索控制器。
  final TextEditingController searchController;

  /// 当前直接或自动选中的标识。
  final Set<String> selectedIds;

  /// 当前自动跟随的标识。
  final Set<String> autoIncludedIds;

  /// 搜索词变化回调。
  final ValueChanged<String> onSearchChanged;

  /// 单条物品选择回调。
  final ValueChanged<InventoryRecord> onToggleItem;

  /// 位置分组选择回调。
  final ValueChanged<_InventoryMoveGroup> onToggleGroup;

  /// 创建左侧物品来源树。
  const _InventoryMoveSourcePanel({
    required this.data,
    required this.query,
    required this.searchController,
    required this.selectedIds,
    required this.autoIncludedIds,
    required this.onSearchChanged,
    required this.onToggleItem,
    required this.onToggleGroup,
  });

  /// 构建搜索框与位置分组树。
  @override
  Widget build(BuildContext context) {
    // 当前搜索结果分组。
    final List<_InventoryMoveGroup> groups = data.groups(query);
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Container(
      key: const ValueKey<String>('inventory-move-source-panel'),
      color: colors.paper,
      padding: const EdgeInsets.all(OmniSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('从现有位置选择', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: OmniSpacing.xs),
          TextField(
            key: const ValueKey<String>('inventory-move-search'),
            controller: searchController,
            onChanged: onSearchChanged,
            decoration: InputDecoration(
              hintText: '搜索物品或位置',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清空搜索',
                      onPressed: () {
                        searchController.clear();
                        onSearchChanged('');
                      },
                      icon: const Icon(Icons.close_rounded),
                    ),
            ),
          ),
          const SizedBox(height: OmniSpacing.xs),
          Expanded(
            child: data.records.isEmpty
                ? const _InventoryMoveEmpty(
                    icon: Icons.inventory_2_outlined,
                    message: '还没有可迁移的物品',
                  )
                : groups.isEmpty
                ? const _InventoryMoveEmpty(
                    icon: Icons.search_off_rounded,
                    message: '没有找到匹配的物品或位置',
                  )
                : ListView.separated(
                    itemCount: groups.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: OmniSpacing.xxs),
                    itemBuilder: (BuildContext context, int index) {
                      // 当前位置分组。
                      final _InventoryMoveGroup group = groups[index];
                      return _InventoryMoveLocationGroup(
                        group: group,
                        data: data,
                        selectedIds: selectedIds,
                        autoIncludedIds: autoIncludedIds,
                        onToggleItem: onToggleItem,
                        onToggleGroup: () => onToggleGroup(group),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// 单个位置树分组。
class _InventoryMoveLocationGroup extends StatelessWidget {
  /// 当前位置分组。
  final _InventoryMoveGroup group;

  /// 搬家展示数据。
  final _InventoryMoveData data;

  /// 当前直接或自动选中的标识。
  final Set<String> selectedIds;

  /// 当前自动跟随的标识。
  final Set<String> autoIncludedIds;

  /// 单条物品选择回调。
  final ValueChanged<InventoryRecord> onToggleItem;

  /// 整组选择回调。
  final VoidCallback onToggleGroup;

  /// 创建单个位置树分组。
  const _InventoryMoveLocationGroup({
    required this.group,
    required this.data,
    required this.selectedIds,
    required this.autoIncludedIds,
    required this.onToggleItem,
    required this.onToggleGroup,
  });

  /// 构建可展开的位置节点与物品子节点。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前分组已选物品数。
    final int selectedCount = group.records
        .where((InventoryRecord record) => selectedIds.contains(record.id))
        .length;
    // 当前分组是否全部选中。
    final bool allSelected = selectedCount == group.records.length;
    // 当前分组是否部分选中。
    final bool partiallySelected = selectedCount > 0 && !allSelected;
    return Container(
      key: ValueKey<String>('inventory-move-location-${group.name}'),
      decoration: BoxDecoration(
        color: colors.paperSubtle,
        borderRadius: BorderRadius.circular(OmniRadius.panel),
        border: Border.all(color: colors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: true,
        tilePadding: const EdgeInsets.only(left: 4, right: OmniSpacing.xs),
        childrenPadding: const EdgeInsets.only(bottom: OmniSpacing.xxs),
        shape: const Border(),
        collapsedShape: const Border(),
        leading: Checkbox(
          tristate: true,
          value: allSelected
              ? true
              : partiallySelected
              ? null
              : false,
          onChanged: (_) => onToggleGroup(),
        ),
        title: Text(group.name),
        subtitle: Text('${group.records.length} 项'),
        children: <Widget>[
          for (final InventoryRecord record in group.orderedRecords(data))
            _InventoryMoveSourceRow(
              record: record,
              data: data,
              selected: selectedIds.contains(record.id),
              autoIncluded: autoIncludedIds.contains(record.id),
              onToggle: () => onToggleItem(record),
            ),
        ],
      ),
    );
  }
}

/// 左侧树中的单条物品。
class _InventoryMoveSourceRow extends StatelessWidget {
  /// 当前物品。
  final InventoryRecord record;

  /// 搬家展示数据。
  final _InventoryMoveData data;

  /// 当前是否选中。
  final bool selected;

  /// 当前是否由主物品自动带走。
  final bool autoIncluded;

  /// 切换选择回调。
  final VoidCallback onToggle;

  /// 创建左侧树中的单条物品。
  const _InventoryMoveSourceRow({
    required this.record,
    required this.data,
    required this.selected,
    required this.autoIncluded,
    required this.onToggle,
  });

  /// 构建物品选择行。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前记录是否为配套物品。
    final bool accessory = record.parentItemId != null;
    // 当前配套物品是否继承主物品位置。
    final bool inherited = data.isInherited(record);
    // 当前配套物品所属主物品。
    final InventoryRecord? parent = data.recordsById[record.parentItemId];
    // 当前物品辅助说明。
    final String subtitle = accessory
        ? inherited
              ? '随主物品${parent == null ? '' : ' · ${parent.name}'}'
              : '配套于 ${parent?.name ?? '未知主物品'}'
        : '${record.quantity} 件';
    return Padding(
      padding: EdgeInsets.only(left: accessory && inherited ? 28 : 8, right: 8),
      child: InkWell(
        key: ValueKey<String>('inventory-move-item-${record.id}'),
        onTap: autoIncluded ? null : onToggle,
        borderRadius: BorderRadius.circular(OmniRadius.control),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: <Widget>[
              Checkbox(
                value: selected,
                onChanged: autoIncluded ? null : (_) => onToggle(),
              ),
              Icon(
                accessory
                    ? Icons.extension_outlined
                    : Icons.inventory_2_outlined,
                size: 18,
                color: accessory ? colors.item : colors.brand,
              ),
              const SizedBox(width: OmniSpacing.xs),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      record.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      autoIncluded ? '将随主物品自动迁移' : subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: autoIncluded ? colors.brand : colors.muted,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                '×${record.quantity}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 左右区域之间的搬运方向通道。
class _InventoryMoveRail extends StatelessWidget {
  /// 当前待迁移物品数。
  final int selectedCount;

  /// 创建搬运方向通道。
  const _InventoryMoveRail({required this.selectedCount});

  /// 构建方向箭头与数量标记。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return SizedBox(
      width: 64,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Container(width: 1, height: 36, color: colors.line),
          const SizedBox(height: OmniSpacing.xs),
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: selectedCount == 0 ? colors.mist : colors.brandSoft,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.arrow_forward_rounded,
              color: selectedCount == 0 ? colors.muted : colors.brand,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '$selectedCount 项',
            style: Theme.of(context).textTheme.labelSmall,
          ),
          const SizedBox(height: OmniSpacing.xs),
          Container(width: 1, height: 36, color: colors.line),
        ],
      ),
    );
  }
}

/// 右侧迁移目标与待迁移清单。
class _InventoryMoveTargetPanel extends StatelessWidget {
  /// 搬家展示数据。
  final _InventoryMoveData data;

  /// 用户直接选择的物品标识。
  final Set<String> directSelectedIds;

  /// 当前直接或自动纳入迁移的物品标识。
  final Set<String> migrationIds;

  /// 当前自动跟随的物品标识。
  final Set<String> autoIncludedIds;

  /// 当前目标位置标识。
  final String? destinationLocationId;

  /// 目标位置变化回调。
  final ValueChanged<String?> onDestinationChanged;

  /// 从清单移除回调。
  final ValueChanged<String> onRemove;

  /// 创建右侧迁移目标与待迁移清单。
  const _InventoryMoveTargetPanel({
    required this.data,
    required this.directSelectedIds,
    required this.migrationIds,
    required this.autoIncludedIds,
    required this.destinationLocationId,
    required this.onDestinationChanged,
    required this.onRemove,
  });

  /// 构建目标位置和迁移预览。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 按名称排序的待迁移物品。
    final List<InventoryRecord> selectedRecords =
        data.records
            .where((InventoryRecord record) => migrationIds.contains(record.id))
            .toList()
          ..sort(
            (InventoryRecord left, InventoryRecord right) =>
                left.name.compareTo(right.name),
          );
    return Container(
      key: const ValueKey<String>('inventory-move-target-panel'),
      color: colors.paper,
      padding: const EdgeInsets.all(OmniSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '待迁移物品 ${migrationIds.length} 项',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              TextButton.icon(
                onPressed: () => TaxonomyManagerDialog.show(
                  context,
                  module: TaxonomyModule.inventory,
                  kind: TaxonomyKind.location,
                ),
                icon: const Icon(Icons.settings_outlined, size: 16),
                label: const Text('管理位置'),
              ),
            ],
          ),
          const SizedBox(height: OmniSpacing.xs),
          Row(
            children: <Widget>[
              Text('搬到', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(width: OmniSpacing.xs),
              Expanded(
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    return OmniDropdownButton<String>(
                      key: const ValueKey<String>('inventory-move-destination'),
                      value: destinationLocationId,
                      width: constraints.maxWidth,
                      hint: const Text('选择目标位置'),
                      items: <DropdownMenuItem<String>>[
                        for (final TaxonomyEntry location in data.locations)
                          DropdownMenuItem<String>(
                            value: location.id,
                            child: Text(location.name),
                          ),
                      ],
                      onChanged: data.locations.isEmpty
                          ? null
                          : onDestinationChanged,
                    );
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: OmniSpacing.sm),
          Expanded(
            child: selectedRecords.isEmpty
                ? const _InventoryMoveEmpty(
                    icon: Icons.move_to_inbox_outlined,
                    message: '点击左侧物品，将它加入待迁移清单',
                  )
                : ListView.separated(
                    itemCount: selectedRecords.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: OmniSpacing.xxs),
                    itemBuilder: (BuildContext context, int index) {
                      // 当前待迁移物品。
                      final InventoryRecord record = selectedRecords[index];
                      return _InventoryMoveTargetRow(
                        record: record,
                        data: data,
                        autoIncluded: autoIncludedIds.contains(record.id),
                        onRemove: directSelectedIds.contains(record.id)
                            ? () => onRemove(record.id)
                            : null,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// 右侧待迁移清单中的单条物品。
class _InventoryMoveTargetRow extends StatelessWidget {
  /// 当前物品。
  final InventoryRecord record;

  /// 搬家展示数据。
  final _InventoryMoveData data;

  /// 当前是否由主物品自动带走。
  final bool autoIncluded;

  /// 可选移除回调。
  final VoidCallback? onRemove;

  /// 创建右侧待迁移物品行。
  const _InventoryMoveTargetRow({
    required this.record,
    required this.data,
    required this.autoIncluded,
    required this.onRemove,
  });

  /// 构建迁移物品摘要和移除操作。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前有效位置名称。
    final String currentLocation = data.effectiveLocationName(record);
    // 当前记录是否为配套物品。
    final bool accessory = record.parentItemId != null;
    return Container(
      key: ValueKey<String>('inventory-move-selected-${record.id}'),
      padding: const EdgeInsets.symmetric(
        horizontal: OmniSpacing.sm,
        vertical: OmniSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: autoIncluded ? colors.brandSoft : colors.paperSubtle,
        borderRadius: BorderRadius.circular(OmniRadius.control),
        border: Border.all(
          color: autoIncluded
              ? colors.brand.withValues(alpha: 0.22)
              : colors.line,
        ),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            accessory ? Icons.extension_outlined : Icons.inventory_2_outlined,
            size: 18,
            color: accessory ? colors.item : colors.brand,
          ),
          const SizedBox(width: OmniSpacing.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(record.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(
                  autoIncluded
                      ? '随主物品自动迁移 · $currentLocation'
                      : '$currentLocation · ${record.quantity} 件',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (onRemove != null)
            IconButton(
              tooltip: '移除',
              onPressed: onRemove,
              icon: const Icon(Icons.close_rounded, size: 18),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                '自动',
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: colors.brand),
              ),
            ),
        ],
      ),
    );
  }
}

/// 搬家工作台底部统计与操作区。
class _InventoryMoveFooter extends StatelessWidget {
  /// 是否为移动端紧凑布局。
  final bool compact;

  /// 移动端当前步骤。
  final int mobileStep;

  /// 当前选择记录数。
  final int selectedRecordCount;

  /// 当前选择件数。
  final int selectedQuantity;

  /// 是否已经选择目标位置。
  final bool destinationSelected;

  /// 当前是否正在迁移。
  final bool moving;

  /// 取消回调。
  final VoidCallback onCancel;

  /// 返回上一步回调。
  final VoidCallback onBack;

  /// 进入下一步回调。
  final VoidCallback? onNext;

  /// 执行迁移回调。
  final VoidCallback? onMove;

  /// 创建搬家工作台底部操作区。
  const _InventoryMoveFooter({
    required this.compact,
    required this.mobileStep,
    required this.selectedRecordCount,
    required this.selectedQuantity,
    required this.destinationSelected,
    required this.moving,
    required this.onCancel,
    required this.onBack,
    required this.onNext,
    required this.onMove,
  });

  /// 构建选择摘要与响应式操作。
  @override
  Widget build(BuildContext context) {
    // 当前操作按钮。
    final List<Widget> actions = compact
        ? mobileStep == 0
              ? <Widget>[
                  OmniButton(
                    label: '取消',
                    variant: OmniButtonVariant.secondary,
                    onPressed: moving ? null : onCancel,
                  ),
                  OmniButton(label: '下一步', onPressed: onNext),
                ]
              : <Widget>[
                  OmniButton(
                    label: '上一步',
                    variant: OmniButtonVariant.secondary,
                    onPressed: moving ? null : onBack,
                  ),
                  OmniButton(
                    key: const ValueKey<String>('inventory-move-submit'),
                    label: '迁移 $selectedRecordCount 项',
                    loading: moving,
                    onPressed: destinationSelected ? onMove : null,
                  ),
                ]
        : <Widget>[
            OmniButton(
              label: '取消',
              variant: OmniButtonVariant.secondary,
              onPressed: moving ? null : onCancel,
            ),
            OmniButton(
              key: const ValueKey<String>('inventory-move-submit'),
              label: '迁移 $selectedRecordCount 项',
              loading: moving,
              onPressed: destinationSelected ? onMove : null,
            ),
          ];
    return Padding(
      padding: const EdgeInsets.all(OmniSpacing.md),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '已选 $selectedRecordCount 条记录，共 $selectedQuantity 件',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          for (int index = 0; index < actions.length; index += 1) ...<Widget>[
            if (index > 0) const SizedBox(width: OmniSpacing.xs),
            actions[index],
          ],
        ],
      ),
    );
  }
}

/// 搬家工作台空状态。
class _InventoryMoveEmpty extends StatelessWidget {
  /// 空状态图标。
  final IconData icon;

  /// 空状态说明。
  final String message;

  /// 创建搬家工作台空状态。
  const _InventoryMoveEmpty({required this.icon, required this.message});

  /// 构建空状态提示。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 40, color: colors.muted),
          const SizedBox(height: OmniSpacing.xs),
          Text(message, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// 搬家工作台数据读取失败状态。
class _InventoryMoveFailure extends StatelessWidget {
  /// 读取错误。
  final Object error;

  /// 创建搬家工作台数据读取失败状态。
  const _InventoryMoveFailure({required this.error});

  /// 构建错误说明与关闭操作。
  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        const Spacer(),
        const Icon(Icons.error_outline_rounded, size: 48),
        const SizedBox(height: OmniSpacing.sm),
        Text('物品读取失败：$error'),
        const SizedBox(height: OmniSpacing.md),
        OmniButton(label: '关闭', onPressed: () => Navigator.of(context).pop()),
        const Spacer(),
      ],
    );
  }
}

/// 单个位置下的物品分组。
class _InventoryMoveGroup {
  /// 位置名称。
  final String name;

  /// 该位置下的全部物品。
  final List<InventoryRecord> records;

  /// 创建单个位置下的物品分组。
  const _InventoryMoveGroup({required this.name, required this.records});

  /// 返回主物品优先、继承位置配件紧随主物品的稳定顺序。
  List<InventoryRecord> orderedRecords(_InventoryMoveData data) {
    // 当前分组主物品。
    final List<InventoryRecord> parents =
        records
            .where((InventoryRecord record) => record.parentItemId == null)
            .toList()
          ..sort(
            (InventoryRecord left, InventoryRecord right) =>
                left.name.compareTo(right.name),
          );
    // 已加入结果的记录标识。
    final Set<String> appendedIds = <String>{};
    // 最终稳定顺序。
    final List<InventoryRecord> ordered = <InventoryRecord>[];
    for (final InventoryRecord parent in parents) {
      ordered.add(parent);
      appendedIds.add(parent.id);
      // 当前主物品继承位置的配件。
      final List<InventoryRecord> inheritedChildren =
          records
              .where(
                (InventoryRecord record) =>
                    record.parentItemId == parent.id &&
                    data.isInherited(record),
              )
              .toList()
            ..sort(
              (InventoryRecord left, InventoryRecord right) =>
                  left.name.compareTo(right.name),
            );
      ordered.addAll(inheritedChildren);
      appendedIds.addAll(
        inheritedChildren.map((InventoryRecord record) => record.id),
      );
    }
    // 独立存放配件或搜索时没有同组主物品的剩余记录。
    final List<InventoryRecord> remaining =
        records
            .where((InventoryRecord record) => !appendedIds.contains(record.id))
            .toList()
          ..sort(
            (InventoryRecord left, InventoryRecord right) =>
                left.name.compareTo(right.name),
          );
    ordered.addAll(remaining);
    return ordered;
  }
}

/// 搬家界面的派生数据与位置解析规则。
class _InventoryMoveData {
  /// 全部有效物品。
  final List<InventoryRecord> records;

  /// 全部有效规范位置。
  final List<TaxonomyEntry> locations;

  /// 物品 taxonomy 关联。
  final Map<String, Set<String>> taxonomyLinks;

  /// 按标识索引的全部物品。
  late final Map<String, InventoryRecord> recordsById =
      <String, InventoryRecord>{
        for (final InventoryRecord record in records) record.id: record,
      };

  /// 创建搬家界面的派生数据。
  _InventoryMoveData({
    required this.records,
    required this.locations,
    required this.taxonomyLinks,
  });

  /// 判断配套物品是否继承主物品位置。
  bool isInherited(InventoryRecord record) {
    return record.parentItemId != null && directLocationName(record) == null;
  }

  /// 返回物品自身直接设置的位置名称。
  String? directLocationName(InventoryRecord record) {
    // 当前物品关联的规范位置。
    for (final TaxonomyEntry location in locations) {
      if ((taxonomyLinks[record.id] ?? const <String>{}).contains(
        location.id,
      )) {
        return location.name;
      }
    }
    // 当前物品的旧文本位置。
    final String? textLocation = record.location?.trim();
    return textLocation == null || textLocation.isEmpty ? null : textLocation;
  }

  /// 返回物品最终展示的有效位置名称。
  String effectiveLocationName(InventoryRecord record) {
    // 当前物品直接设置的位置。
    final String? directLocation = directLocationName(record);
    if (directLocation != null) {
      return directLocation;
    }
    // 当前配套物品所属主物品。
    final InventoryRecord? parent = recordsById[record.parentItemId];
    if (parent != null) {
      return directLocationName(parent) ?? '未设置位置';
    }
    return '未设置位置';
  }

  /// 返回按有效位置聚合并应用搜索后的分组。
  List<_InventoryMoveGroup> groups(String query) {
    // 清理后的搜索词。
    final String keyword = query.trim().toLowerCase();
    // 全量位置分组。
    final Map<String, List<InventoryRecord>> grouped =
        <String, List<InventoryRecord>>{};
    for (final InventoryRecord record in records) {
      grouped
          .putIfAbsent(effectiveLocationName(record), () => <InventoryRecord>[])
          .add(record);
    }
    // 管理位置的稳定排序下标。
    final Map<String, int> managedOrder = <String, int>{
      for (int index = 0; index < locations.length; index += 1)
        locations[index].name: index,
    };
    // 搜索并排序后的分组。
    final List<_InventoryMoveGroup> result = <_InventoryMoveGroup>[];
    for (final MapEntry<String, List<InventoryRecord>> entry
        in grouped.entries) {
      // 位置名称是否命中搜索。
      final bool locationMatches = entry.key.toLowerCase().contains(keyword);
      // 当前搜索命中的物品标识。
      final Set<String> matchedIds = <String>{};
      for (final InventoryRecord record in entry.value) {
        // 当前物品所属主物品名称。
        final String parentName = recordsById[record.parentItemId]?.name ?? '';
        // 当前物品可搜索内容。
        final String searchable = <String>[
          record.name,
          parentName,
          record.category ?? '',
          record.notes ?? '',
        ].join(' ').toLowerCase();
        if (keyword.isEmpty ||
            locationMatches ||
            searchable.contains(keyword)) {
          matchedIds.add(record.id);
          if (isInherited(record) && record.parentItemId != null) {
            matchedIds.add(record.parentItemId!);
          }
        }
      }
      // 当前分组过滤后的物品。
      final List<InventoryRecord> filtered = entry.value
          .where((InventoryRecord record) => matchedIds.contains(record.id))
          .toList(growable: false);
      if (filtered.isNotEmpty) {
        result.add(_InventoryMoveGroup(name: entry.key, records: filtered));
      }
    }
    result.sort((_InventoryMoveGroup left, _InventoryMoveGroup right) {
      if (left.name == '未设置位置') {
        return 1;
      }
      if (right.name == '未设置位置') {
        return -1;
      }
      // 左侧位置的管理排序。
      final int? leftOrder = managedOrder[left.name];
      // 右侧位置的管理排序。
      final int? rightOrder = managedOrder[right.name];
      if (leftOrder != null || rightOrder != null) {
        return (leftOrder ?? 1 << 20).compareTo(rightOrder ?? 1 << 20);
      }
      return left.name.compareTo(right.name);
    });
    return result;
  }

  /// 返回已选主物品自动带走的继承位置配件。
  Set<String> autoIncludedIds(Set<String> selectedIds) {
    // 当前已选主物品标识。
    final Set<String> selectedParentIds = selectedIds
        .where((String id) => recordsById[id]?.parentItemId == null)
        .toSet();
    return records
        .where(
          (InventoryRecord record) =>
              record.parentItemId != null &&
              selectedParentIds.contains(record.parentItemId) &&
              isInherited(record),
        )
        .map((InventoryRecord record) => record.id)
        .toSet();
  }

  /// 返回直接选择和自动跟随组成的完整迁移标识。
  Set<String> migrationIds(Set<String> selectedIds) {
    return <String>{...selectedIds, ...autoIncludedIds(selectedIds)};
  }

  /// 汇总给定物品标识对应的实际件数。
  int quantityOf(Set<String> ids) {
    return records
        .where((InventoryRecord record) => ids.contains(record.id))
        .fold<int>(
          0,
          (int total, InventoryRecord record) => total + record.quantity,
        );
  }
}
