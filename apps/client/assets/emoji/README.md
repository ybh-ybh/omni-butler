# 笔记标签 emoji 离线目录

数据固定取自 `emoji_picker_flutter 4.4.0` 的官方发行包，仅复制分类与中英文关键词，不引入 Flutter 插件或其最近使用偏好逻辑。

- 发行元数据：https://pub.dev/api/packages/emoji_picker_flutter/versions/4.4.0
- 发行包：https://pub.dev/api/archives/emoji_picker_flutter-4.4.0.tar.gz
- SHA-256：`984d3e9b9cf3175df9a868ce4a2d9611491e80e5d3b8e2b1e8991a4998972885`
- 源文件：`lib/locales/emoji_set_zh.dart`、`lib/locales/emoji_set_en.dart`
- 两种语言各 1625 条，按完整 emoji 字符串合并为 1611 项，保留八类顺序和首次类别归属；重复项的关键词合并保留。
- `name` 在上游是以 ` | ` 分隔的关键词串，界面使用首个中文关键词作友好标签，不表示 Unicode 正式名称。

上游中文集合对国家旗帜等派生序列仍含英文回退，且原生成脚本的冒号分割会截断时钟等条目的词汇。使用固定的 Unicode CLDR 48 `common/annotations/{zh,en}.xml` 和 `common/annotationsDerived/{zh,en}.xml` 补齐既有条目的中英文关键词及友好短名，保留原词汇，不增加图标、肤色变体或类别。CLDR 注解省略的 U+FE0F 仅在关联索引中忽略，JSON 内的 emoji 原序列不变。

- 补充源前缀：https://raw.githubusercontent.com/unicode-org/cldr/release-48/common
- `annotations/zh.xml` SHA-256：`92389f71659998736530c72d4dcc86e453fe0be170cde5c5ad27094cab2a2de8`
- `annotations/en.xml` SHA-256：`8511aadd046fdba2f0ffe590266ced8bbf48175ad139b2675d85d7141057b235`
- `annotationsDerived/zh.xml` SHA-256：`777acebb7c4ed103c34f5605881a2537656e0a17d9d1127518da7cd54f612bcc`
- `annotationsDerived/en.xml` SHA-256：`d76bd041c8c9e7b00b716aff8b7d9dbf509877010e191d5efd068be2553e066e`
- CLDR 48 原始许可：https://raw.githubusercontent.com/unicode-org/cldr/release-48/LICENSE
- 许可 SHA-256：`b4c0ae8ef04f7059f96ce5bbe0467f9fe6f6d81bbe13517701dfeb961fb4d0b6`

从仓库根目录重建：

```powershell
python apps/client/tool/generate_note_tag_emoji_catalog.py
python apps/client/tool/generate_note_tag_emoji_catalog.py --check
```

同时使用 `--archive <本地发行包路径> --cldr-directory <本地 CLDR common 目录>` 可以离线重建或检查。脚本校验全部输入摘要，只读取固定数据，不运行上游代码，也不向文件系统展开归档。

`LICENSE-emoji_picker_flutter.txt` 原样保留发行包 MIT 通知。上游生成脚本 `automation/create_emoji_set.sh` 从 Unicode CLDR 获取关键词；本地补充数据同样来自 CLDR，因此同时原样保留 CLDR 48 的 `LICENSE-Unicode.txt`。两份通知和补充数据版权声明也包含在 JSON 内，随应用资产一同分发。

这里只固定可选择的数据集合，不附带 emoji 字体。Windows 最终字形由系统字体决定；不能以目录完整推断所有系统版本都能显示全部旗帜、组合序列或较新的字符。
