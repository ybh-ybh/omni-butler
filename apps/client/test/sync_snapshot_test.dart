import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/sync/sync_snapshot.dart';

/// 验证迁移引用闭包与原始备份之间的数据边界。
void main() {
  test('只排除本模块业务记录已缺失的关联，保留软删除与异常输入供校验', () {
    // 四个模块的独立业务表，其他模块存在同 ID 不能补齐缺失物品。
    const Map<String, String> recordTables = <String, String>{
      'inventory': 'inventory_items',
      'timeline': 'time_entries',
      'membership': 'memberships',
      'notes': 'note_entries',
    };
    // 完整备份仍保存全部历史关联与未同步操作计数。
    final SyncSnapshot snapshot = SyncSnapshot(
      pendingOperations: 7,
      tables: <String, List<Map<String, Object?>>>{
        for (final String table in SyncSnapshot.tableNames)
          table: <Map<String, Object?>>[],
      },
    );
    for (final MapEntry<String, String> entry in recordTables.entries) {
      snapshot.tables[entry.value]!.add(<String, Object?>{
        'id': '${entry.key}-ABC',
        'deleted_at': '2026-10-19T00:00:00Z',
      });
      for (final String kind in <String>[
        'valid',
        'missing',
        'deleted-missing',
      ]) {
        snapshot.tables['record_taxonomy_links']!.add(<String, Object?>{
          'id': '${entry.key}-$kind',
          'module': entry.key,
          'record_id': kind == 'valid' ? '${entry.key}-abc' : 'missing',
          'taxonomy_id': 'tag',
          'deleted_at': kind == 'deleted-missing' ? '2026-10-19' : null,
        });
      }
    }
    snapshot.tables['note_entries']!.add(<String, Object?>{'id': 'missing'});
    snapshot.tables['record_taxonomy_links']!.addAll(<Map<String, Object?>>[
      <String, Object?>{
        'id': 'unknown-module',
        'module': 'unknown',
        'record_id': 'missing',
      },
      <String, Object?>{
        'id': 'invalid-record-id',
        'module': 'inventory',
        'record_id': null,
      },
    ]);
    // 持久化内容、原计数和原关联不能被内存迁移修复改写。
    final String original = jsonEncode(snapshot.toJson());
    expect(
      snapshot.migrationTables['record_taxonomy_links']!.map(
        (Map<String, Object?> row) => row['id'],
      ),
      <String>[
        'inventory-valid',
        'timeline-valid',
        'membership-valid',
        'notes-valid',
        'notes-missing',
        'notes-deleted-missing',
        'unknown-module',
        'invalid-record-id',
      ],
    );
    expect(
      snapshot.operations
          .where(
            (Map<String, Object?> row) =>
                row['table'] == 'record_taxonomy_links',
          )
          .map((Map<String, Object?> row) => row['id']),
      snapshot.migrationTables['record_taxonomy_links']!.map(
        (Map<String, Object?> row) => row['id'],
      ),
    );
    expect(jsonEncode(snapshot.toJson()), original);
    expect(snapshot.pendingOperations, 7);
  });
}
