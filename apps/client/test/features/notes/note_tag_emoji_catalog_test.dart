import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/features/notes/data/note_tag_emoji_catalog.dart';

/// 固定抽取最后一个候选，覆盖排除末端和中间位置的索引映射。
class _LastCandidateRandom implements Random {
  /// 本测试仅调用 nextInt，其他随机接口不应参与目录抽样。
  const _LastCandidateRandom();

  /// 总是选择给定候选范围的最后一个合法索引。
  @override
  int nextInt(int max) => max - 1;

  /// 非目录使用的接口意外被调用时明确失败。
  @override
  bool nextBool() => throw UnsupportedError('测试只支持整数抽样');

  /// 非目录使用的接口意外被调用时明确失败。
  @override
  double nextDouble() => throw UnsupportedError('测试只支持整数抽样');
}

/// 检查真实打包资产、搜索和随机语义，不访问数据库或用户偏好。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 所有用例共用真实离线目录，验证与正式界面相同的数据入口。
  late NoteTagEmojiCatalog catalog;

  setUp(() async {
    NoteTagEmojiCatalog.resetCacheForTesting();
    catalog = await NoteTagEmojiCatalog.load();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
    NoteTagEmojiCatalog.resetCacheForTesting();
  });

  test('一次资源加载失败后可重新读取，恢复后的 Future 继续缓存', () async {
    NoteTagEmojiCatalog.resetCacheForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (_) async => null);
    // 模拟系统首次未能提供资源，验证失败不会被任一缓存层保留。
    final Future<NoteTagEmojiCatalog> failedLoad = NoteTagEmojiCatalog.load();
    expect(NoteTagEmojiCatalog.load(), same(failedLoad));
    await expectLater(failedLoad, throwsA(isA<FlutterError>()));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
    // 移除故障后应创建新的 Future，成功解码真实目录。
    final Future<NoteTagEmojiCatalog> retriedLoad = NoteTagEmojiCatalog.load();
    expect(retriedLoad, isNot(same(failedLoad)));
    expect((await retriedLoad).entries, hasLength(1611));
    expect(NoteTagEmojiCatalog.load(), same(retriedLoad));
  });

  test('固定来源、许可及全部八类随资产分发，1611 个完整序列没有重复', () async {
    // 读取实际 Flutter 资源，检查来源和许可没有只留在开发目录。
    final Map<String, dynamic> document = jsonDecode(
      await rootBundle.loadString(NoteTagEmojiCatalog.assetPath),
    ) as Map<String, dynamic>;
    expect(document['source']['version'], '4.4.0');
    expect(document['source']['supplemental']['version'], '48');
    expect(
      document['source']['archiveSha256'],
      '984d3e9b9cf3175df9a868ce4a2d9611491e80e5d3b8e2b1e8991a4998972885',
    );
    expect(document['licenses'][0]['text'], contains('Stefan Humm'));
    expect(document['licenses'][1]['text'], contains('UNICODE LICENSE V3'));
    expect(catalog.entries, hasLength(1611));
    expect(
      catalog.entries.map((entry) => entry.emoji).toSet(),
      hasLength(1611),
    );
    expect(
      catalog.entries.map((entry) => entry.category).toSet().toList(),
      NoteTagEmojiCatalog.categoryLabels.keys.toList(),
    );
    expect(NoteTagEmojiCatalog.categoryLabels, hasLength(8));
    // 每个条目均应有可用中文词，防止上游英文或数字回退再次漏入。
    final RegExp chineseCharacter = RegExp(r'[\u4e00-\u9fff]');
    // 每个类别都必须有可选条目，两种语言和友好标签不能缺失。
    for (final NoteTagEmoji entry in catalog.entries) {
      expect(entry.keywordsZh, isNotEmpty);
      expect(entry.keywordsEn, isNotEmpty);
      expect(
        entry.keywordsZh.any(chineseCharacter.hasMatch),
        isTrue,
        reason: '${entry.emoji} 缺少中文关键词',
      );
      expect(entry.label, entry.keywordsZh.first);
      expect(NoteTagEmojiCatalog.categoryLabels, contains(entry.category));
    }
  });

  test('加载 Future 和目录复用，条目及查询结果不可修改', () async {
    expect(NoteTagEmojiCatalog.load(), same(NoteTagEmojiCatalog.load()));
    expect(await NoteTagEmojiCatalog.load(), same(catalog));
    expect(catalog.search(''), same(catalog.entries));
    expect(catalog.search('  \t\n '), same(catalog.entries));
    expect(() => catalog.entries.clear(), throwsUnsupportedError);
    expect(
      () => catalog.entries.first.keywordsZh.add('改变共享数据'),
      throwsUnsupportedError,
    );
    expect(() => catalog.search('face').clear(), throwsUnsupportedError);
  });

  test('中英文、大小写、部分词及混合多词搜索跨全部类别', () {
    expect(catalog.search('高兴').map((entry) => entry.emoji), contains('😀'));
    expect(catalog.search('GRIN').map((entry) => entry.emoji), contains('😀'));
    expect(
      catalog.search(' 高兴\t FACE ').map((entry) => entry.emoji),
      contains('😀'),
    );
    expect(catalog.search('高兴 face 不存在关键词'), isEmpty);
    expect(catalog.search('face 不存在关键词'), isEmpty);
    expect(
      catalog.search('中国').map((entry) => entry.category),
      contains('flags'),
    );
    expect(catalog.search('zzzz-not-an-emoji-keyword'), isEmpty);
  });

  test('直接粘贴 emoji 保留变体选择符、旗帜和组合序列', () {
    // 多码点序列不能按单个 UTF-16 码元拆分后保存或查询。
    for (final String emoji in ['😀', '☺️', '🇨🇳', '👨‍👩‍👧‍👦']) {
      expect(
        catalog.search(' $emoji ').map((entry) => entry.emoji),
        contains(emoji),
      );
    }
  });

  test('CLDR 补全国家旗帜与派生家庭序列的中英文搜索和中文标签', () {
    expect(catalog.search('中国').map((entry) => entry.emoji), contains('🇨🇳'));
    expect(
      catalog.search('CHINA').map((entry) => entry.emoji),
      contains('🇨🇳'),
    );
    expect(catalog.search('🇨🇳').single.label, '旗: 中国');
    expect(
      catalog.search('家庭 男人女人女孩男孩').map((entry) => entry.emoji),
      contains('👨‍👩‍👧‍👦'),
    );
    expect(
      catalog.search('family man woman girl boy').map((entry) => entry.emoji),
      contains('👨‍👩‍👧‍👦'),
    );
  });

  test('CLDR 基础注解恢复时钟和数字键帽被上游截断的关键词', () {
    expect(catalog.search('十二点').map((entry) => entry.emoji), contains('🕛'));
    expect(
      catalog.search('clock twelve').map((entry) => entry.emoji),
      contains('🕛'),
    );
    expect(catalog.search('按键 0').map((entry) => entry.emoji), contains('0️⃣'));
    expect(
      catalog.search('keycap zero').map((entry) => entry.emoji),
      contains('0️⃣'),
    );
    expect(catalog.search('0️⃣').single.label, '按键: 0');
  });

  test('随机从完整目录选择，排除首项、末项和中间项', () {
    // 固定最后一个候选，精确覆盖排除值两侧的索引边界。
    const Random random = _LastCandidateRandom();
    expect(catalog.random(random: random), same(catalog.entries.last));
    expect(
      catalog.random(excluding: '不在目录内', random: random),
      same(catalog.entries.last),
    );
    expect(
      catalog.random(excluding: catalog.entries.last.emoji, random: random),
      same(catalog.entries[catalog.entries.length - 2]),
    );
    expect(
      catalog.random(excluding: catalog.entries.first.emoji, random: random),
      same(catalog.entries.last),
    );
    expect(
      catalog.random(excluding: catalog.entries[800].emoji, random: random),
      same(catalog.entries.last),
    );
    // 搜索是纯查询，不应缩小后续随机按钮的候选范围。
    catalog.search('😀');
    expect(catalog.random(random: random), same(catalog.entries.last));
  });

  test('注入同种子随机源得到相同序列，每次都排除当前图标', () {
    // 两个独立随机源使用相同种子，避免依赖具体 SDK 的随机序列常量。
    final Random first = Random(2026);
    // 第二个源与首个保持同样的抽样状态。
    final Random second = Random(2026);
    // 连续切换模拟用户多次点击，任意一次都不能重新选中当前值。
    String current = catalog.entries.first.emoji;
    // 多次抽样同时覆盖 Unicode 单字符与多字符的排除键。
    for (int index = 0; index < 100; index++) {
      // 第一份结果作为本轮预览值。
      final NoteTagEmoji selected = catalog.random(
        excluding: current,
        random: first,
      );
      expect(
        selected,
        same(catalog.random(excluding: current, random: second)),
      );
      expect(selected.emoji, isNot(current));
      expect(catalog.entries, contains(selected));
      current = selected.emoji;
    }
  });
}
