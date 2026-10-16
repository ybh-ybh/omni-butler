import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/features/notes/data/note_repository.dart';
import 'package:omni_butler/features/notes/data/note_tag_actions.dart';

/// 在标签解除之后注入失败，验证最外层事务恢复此前全部回收操作。
class _FailingTaxonomy extends TaxonomyRepository {
  /// 与正式笔记仓储共用数据库。
  _FailingTaxonomy(super.database);

  /// 测试模拟标签写入后的失败。
  @override
  Future<void> delete(String id, {bool retainUndoLinks = true}) async {
    await super.delete(id, retainUndoLinks: retainUndoLinks);
    throw StateError('模拟标签事务失败');
  }
}

/// 真实 SQLite 验证回收、标签解除及草稿保护边界。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 每例独立数据库。
  late AppDatabase database;
  // 正式笔记生命周期仓储。
  late NoteRepository notes;
  // 标签生命周期仓储。
  late TaxonomyRepository taxonomy;
  // 领域协调入口。
  late NoteTagActions actions;

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    notes = NoteRepository(database);
    taxonomy = TaxonomyRepository(database);
    actions = NoteTagActions(database, notes, taxonomy);
    // 标签时间固定，避免与业务笔记时间产生隐含关联。
    final DateTime now = DateTime(2026, 10, 15);
    for (final String id in ['tag', 'other-tag']) {
      await database
          .into(database.taxonomyEntries)
          .insert(
            TaxonomyEntriesCompanion.insert(
              id: id,
              module: 'notes',
              kind: 'tag',
              name: id,
              colorValue: const Value(null),
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
  });
  tearDown(() => database.close());

  /// 创建已发布正文与首个不可变版本。
  Future<void> addNote(String id, Set<String> tags) async {
    await notes.save(
      NoteDraft(
        id: id,
        body: id,
        dayKey: '2026-10-15',
        baseRevision: '',
        tags: tags,
      ),
    );
  }

  test('回收单标签和多标签笔记，已有回收时间不变且恢复不带回被删标签', () async {
    await addNote('one', {'tag'});
    await addNote('multi', {'tag', 'other-tag'});
    await addNote('recycled', {'tag'});
    await addNote('untouched', {'other-tag'});
    await notes.softDelete('recycled');
    // 原回收时间不可因删除标签延长。
    final DateTime recycledAt = (await notes.find('recycled'))!.deletedAt!;
    // 正式图片关联与正文一起回收。
    final DateTime now = DateTime.now();
    await database
        .into(database.noteImages)
        .insert(
          NoteImagesCompanion.insert(
            id: 'image',
            noteId: 'multi',
            sortOrder: 0,
            createdAt: now,
            updatedAt: now,
          ),
        );
    await database
        .into(database.noteAudioSegments)
        .insert(
          NoteAudioSegmentsCompanion.insert(
            id: 'audio',
            noteId: 'multi',
            sortOrder: 0,
            durationMs: 1000,
            mime: 'audio/wav',
            sha256: 'hash',
            byteSize: 100,
            createdAt: now,
            updatedAt: now,
          ),
        );
    expect(await actions.activeNoteIds('tag'), {'one', 'multi'});
    expect(
      await actions.deleteTagAndNotes('tag', expectedNoteIds: {'one', 'multi'}),
      {'one', 'multi'},
    );
    expect((await notes.find('one'))!.deletedAt, isNotNull);
    expect((await notes.find('multi'))!.deletedAt, isNotNull);
    expect((await notes.find('recycled'))!.deletedAt, recycledAt);
    expect((await notes.find('untouched'))!.deletedAt, isNull);
    expect(noteTagIds((await notes.find('recycled'))!.tags), isEmpty);
    expect(
      (await database.select(database.noteImages).getSingle()).deletedAt,
      isNotNull,
    );
    expect(
      (await database.select(database.noteAudioSegments).getSingle()).deletedAt,
      isNotNull,
    );
    expect(
      (await database.select(database.noteVersions).get())
          .where((version) => version.noteId == 'multi')
          .single
          .deletedAt,
      isNotNull,
    );
    await notes.restore('multi');
    expect(noteTagIds((await notes.find('multi'))!.tags), {'other-tag'});
    expect(
      (await database.select(database.noteImages).getSingle()).deletedAt,
      isNull,
    );
  });

  test('空标签可以删除，失效身份和其他模块拒绝操作', () async {
    expect(
      await actions.deleteTagAndNotes('tag', expectedNoteIds: {}),
      isEmpty,
    );
    await expectLater(actions.activeNoteIds('tag'), throwsStateError);
    await expectLater(actions.activeNoteIds('missing'), throwsStateError);
    await (database.update(database.taxonomyEntries)
          ..where((row) => row.id.equals('other-tag')))
        .write(const TaxonomyEntriesCompanion(module: Value('inventory')));
    await expectLater(
      actions.deleteTagAndNotes('other-tag', expectedNoteIds: {}),
      throwsStateError,
    );
  });

  test('确认后对象增减均重新确认且不产生部分删除', () async {
    await addNote('first', {'tag'});
    await expectLater(
      actions.deleteTagAndNotes('tag', expectedNoteIds: {}),
      throwsA(
        isA<NoteTagNotesChanged>().having(
          (failure) => failure.actualNoteIds,
          'actual',
          {'first'},
        ),
      ),
    );
    await expectLater(
      actions.deleteTagAndNotes('tag', expectedNoteIds: {'first', 'late'}),
      throwsA(isA<NoteTagNotesChanged>()),
    );
    expect((await notes.find('first'))!.deletedAt, isNull);
    expect(noteTagIds((await notes.find('first'))!.tags), {'tag'});
  });

  test('标签阶段失败时正文、版本、图片和标签全部回滚', () async {
    await addNote('first', {'tag'});
    // 图片已经正式发布，外层失败不能留下部分回收状态。
    final DateTime now = DateTime.now();
    await database
        .into(database.noteImages)
        .insert(
          NoteImagesCompanion.insert(
            id: 'rollback-image',
            noteId: 'first',
            sortOrder: 0,
            createdAt: now,
            updatedAt: now,
          ),
        );
    // 最后一步才失败，覆盖先前已软删除和已移除标签的回滚。
    final NoteTagActions failing = NoteTagActions(
      database,
      notes,
      _FailingTaxonomy(database),
    );
    await expectLater(
      failing.deleteTagAndNotes('tag', expectedNoteIds: {'first'}),
      throwsStateError,
    );
    expect((await notes.find('first'))!.deletedAt, isNull);
    expect(noteTagIds((await notes.find('first'))!.tags), {'tag'});
    expect(
      (await database.select(database.noteVersions).getSingle()).deletedAt,
      isNull,
    );
    expect(
      (await database.select(database.noteImages).getSingle()).deletedAt,
      isNull,
    );
    expect(await actions.activeNoteIds('tag'), {'first'});
  });
}
