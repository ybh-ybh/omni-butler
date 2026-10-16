"""从固定、校验过的上游发行包重建笔记标签的离线 emoji 目录。"""

import argparse
import ast
import hashlib
import io
import json
from pathlib import Path
import re
import tarfile
import urllib.request
import xml.etree.ElementTree as ElementTree


# 固定数据版本，不使用浮动分支或运行时网络请求。
ARCHIVE_URL = "https://pub.dev/api/archives/emoji_picker_flutter-4.4.0.tar.gz"
# pub.dev 该版本元数据公布的完整发行包摘要。
ARCHIVE_SHA256 = "984d3e9b9cf3175df9a868ce4a2d9611491e80e5d3b8e2b1e8991a4998972885"
# CLDR 48 与原始发行包时间接近，补齐翻译回退及上游脚本截断的关键词。
CLDR_URL_PREFIX = "https://raw.githubusercontent.com/unicode-org/cldr/release-48/common"
# 基础与派生注解分别校验，远程同名引用变化时停止生成。
CLDR_SHA256 = {
    "annotations/zh.xml": "92389f71659998736530c72d4dcc86e453fe0be170cde5c5ad27094cab2a2de8",
    "annotations/en.xml": "8511aadd046fdba2f0ffe590266ced8bbf48175ad139b2675d85d7141057b235",
    "annotationsDerived/zh.xml": "777acebb7c4ed103c34f5605881a2537656e0a17d9d1127518da7cd54f612bcc",
    "annotationsDerived/en.xml": "d76bd041c8c9e7b00b716aff8b7d9dbf509877010e191d5efd068be2553e066e",
}
# 仓库内附带 CLDR 48 的原始许可，不追随上游当前年份。
UNICODE_LICENSE_SHA256 = "b4c0ae8ef04f7059f96ce5bbe0467f9fe6f6d81bbe13517701dfeb961fb4d0b6"
# 保持上游类别顺序；首个归属用于去重后的展示位置。
CATEGORY_IDS = (
    "smileys", "animals", "foods", "travel",
    "activities", "objects", "symbols", "flags",
)
# 仅解析固定版本的常量声明，不执行上游 Dart 或脚本。
CATEGORY_PATTERN = re.compile(r"CategoryEmoji\(Category\.([A-Z_]+), \[")
# 捕获完整 Dart 单引号字符串，支持其中的转义引号。
EMOJI_PATTERN = re.compile(
    r"\bEmoji\(\s*'((?:\\.|[^'\\])*)'\s*,\s*'((?:\\.|[^'\\])*)'"
    r"\s*,?\s*(?:hasSkinTone:\s*(?:true|false),?\s*)?\)"
)
# 从脚本自身定位客户端目录，不依赖调用者的当前工作目录。
CLIENT_ROOT = Path(__file__).resolve().parents[1]
# 产物与完整许可放在同一个受控资产目录。
ASSET_DIRECTORY = CLIENT_ROOT / "assets" / "emoji"


# 读取发行包中的一个 UTF-8 文件，不展开归档到文件系统。
def read_member(archive: tarfile.TarFile, path: str) -> str:
    # 所需成员必须是文件，缺失时立即停止生成。
    member = archive.extractfile(path)
    if member is None:
        raise ValueError(f"发行包缺少文件：{path}")
    return member.read().decode("utf-8")


# 解析固定版本的类别与条目，并检查没有静默遗漏任何构造器。
def parse_locale(source: str) -> list[dict]:
    # 类别起点用来保留源文件的稳定顺序。
    categories = list(CATEGORY_PATTERN.finditer(source))
    if tuple(match.group(1).lower() for match in categories) != CATEGORY_IDS:
        raise ValueError("上游类别与固定版本预期不一致")
    # 输出保留重复 glyph，稍后统一合并两种语言的关键词。
    entries = []
    # 每一块只解析当前类别，避免跨类别误归属。
    for index, category in enumerate(categories):
        # 最后一个类别读取到文件末尾。
        end = categories[index + 1].start() if index + 1 < len(categories) else len(source)
        # 当前类别里的所有常量声明。
        block = source[category.end():end]
        # 对完整构造器计数，防止解析规则漏掉未知语法。
        matches = list(EMOJI_PATTERN.finditer(block))
        if len(matches) != len(re.findall(r"\bEmoji\(", block)):
            raise ValueError(f"未完整解析类别：{category.group(1)}")
        # 字符串只经过字面量解码，不执行表达式。
        for match in matches:
            # 完整 Unicode 序列保留变体选择符和零宽连接符。
            emoji = ast.literal_eval("'" + match.group(1) + "'")
            # 上游 name 是关键词串，并非单独的正式名称。
            description = ast.literal_eval("'" + match.group(2) + "'")
            entries.append({
                "emoji": emoji,
                "category": category.group(1).lower(),
                "keywords": list(dict.fromkeys(
                    word.strip() for word in description.split(" | ") if word.strip()
                )),
            })
    if len(entries) != 1625:
        raise ValueError(f"固定版本应有 1625 条，实际为 {len(entries)}")
    return entries


# 把相同完整 emoji 的中英关键词并入第一次出现的类别。
def merge_locales(chinese: list[dict], english: list[dict]) -> list[dict]:
    # 字典保留插入顺序，确保分类和随机池在重建时稳定。
    merged = {}
    # 固定版本两种语言应当具有完全相同的 glyph 和类别顺序。
    for chinese_entry, english_entry in zip(chinese, english, strict=True):
        if (chinese_entry["emoji"], chinese_entry["category"]) != (
            english_entry["emoji"], english_entry["category"]
        ):
            raise ValueError("中英文目录的 emoji 顺序不一致")
        # 首次出现的类别决定最终展示位置。
        entry = merged.setdefault(chinese_entry["emoji"], {
            "emoji": chinese_entry["emoji"],
            "category": chinese_entry["category"],
            "keywordsZh": [],
            "keywordsEn": [],
        })
        # 重复条目的词汇全部保留，避免去重损失搜索结果。
        for key, source in (("keywordsZh", chinese_entry), ("keywordsEn", english_entry)):
            entry[key] = list(dict.fromkeys(entry[key] + source["keywords"]))
    if len(merged) != 1611:
        raise ValueError(f"固定版本应有 1611 个唯一 emoji，实际为 {len(merged)}")
    return list(merged.values())


# 只给已有条目补足关键词，不导入肤色变体或扩大候选目录。
def supplement_annotations(entries: list[dict], source_path: str, payload: bytes) -> None:
    if hashlib.sha256(payload).hexdigest() != CLDR_SHA256[source_path]:
        raise ValueError(f"CLDR {source_path} SHA-256 不匹配，停止生成")
    # 语言从受控来源表的文件名读取，不接受任意值。
    locale = Path(source_path).stem
    # 标准库 XML 解析不会读取上游声明的外部 DTD。
    document = ElementTree.fromstring(payload)
    # CLDR 部分 cp 省略 U+FE0F，匹配索引可省略它，输出 glyph 始终不变。
    keywords_by_emoji = {}
    # tts 友好短名排到该语言关键词首位，普通关键词继续保留。
    for annotation in document.findall(".//annotation"):
        # 只处理有效注解，忽略任何上游继承占位标记。
        description = (annotation.text or "").strip()
        if not description or description == "↑↑↑":
            continue
        # 标准化仅用于关联两份 Unicode 数据。
        emoji = annotation.attrib["cp"].replace("\ufe0f", "")
        # 名称或关键词都进入本地搜索索引。
        keywords = [word.strip() for word in description.split(" | ") if word.strip()]
        # 同一字符同时有 tts 与关键词注解。
        existing = keywords_by_emoji.setdefault(emoji, [])
        keywords_by_emoji[emoji] = list(dict.fromkeys(
            keywords + existing if annotation.get("type") == "tts" else existing + keywords
        ))
    # 仅遍历原目录，补全不会增加条目或改动类别归属。
    for entry in entries:
        # 匹配用键和持久化的完整序列分别保留。
        emoji = entry["emoji"].replace("\ufe0f", "")
        # 两种语言写入各自的字段。
        key = "keywordsZh" if locale == "zh" else "keywordsEn"
        entry[key] = list(dict.fromkeys(keywords_by_emoji.get(emoji, []) + entry[key]))


# 生成或只读校验确定性产物；--archive 支持使用本地发行包离线重建。
def main() -> None:
    # 只提供输入包与只读检查两个参数，输出位置固定在受控目录。
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, help="可选的本地 4.4.0 发行包")
    parser.add_argument("--cldr-directory", type=Path, help="可选的本地 CLDR 48 common 目录")
    parser.add_argument("--check", action="store_true", help="只检查产物，不写文件")
    # 命令行参数不参与网络地址或输出目录拼接。
    arguments = parser.parse_args()
    # 无本地包时只请求固定 HTTPS 发行地址。
    payload = arguments.archive.read_bytes() if arguments.archive else urllib.request.urlopen(
        ARCHIVE_URL, timeout=30
    ).read()
    if hashlib.sha256(payload).hexdigest() != ARCHIVE_SHA256:
        raise ValueError("发行包 SHA-256 不匹配，停止生成")
    # 内存解包只读取已知成员，不执行第三方代码。
    with tarfile.open(fileobj=io.BytesIO(payload), mode="r:gz") as archive:
        # 中文与英文目录来自同一个已验证版本。
        chinese = parse_locale(read_member(archive, "lib/locales/emoji_set_zh.dart"))
        # 英文保留完整关键词以支持跨语言联合查询。
        english = parse_locale(read_member(archive, "lib/locales/emoji_set_en.dart"))
        # 原样保留上游 MIT 通知，确保生成资产携带版权说明。
        mit_license = read_member(archive, "LICENSE")
    # Unicode 通知已随仓库固定，重建时不请求可变的远程许可证。
    unicode_license_bytes = (ASSET_DIRECTORY / "LICENSE-Unicode.txt").read_bytes()
    if hashlib.sha256(unicode_license_bytes).hexdigest() != UNICODE_LICENSE_SHA256:
        raise ValueError("本地 CLDR 48 许可摘要不匹配")
    # 原样正文随应用资产分发。
    unicode_license = unicode_license_bytes.decode("utf-8")
    # 先建立稳定的 1611 项目录，再补全该目录中的基础和派生翻译。
    entries = merge_locales(chinese, english)
    # 补充数据也只在开发时获取，正式客户端完全离线。
    for source_path in CLDR_SHA256:
        # 支持本地文件输入，便于无网络环境重建或检查。
        annotation_payload = (arguments.cldr_directory / source_path).read_bytes() if (
            arguments.cldr_directory
        ) else urllib.request.urlopen(f"{CLDR_URL_PREFIX}/{source_path}", timeout=30).read()
        supplement_annotations(entries, source_path, annotation_payload)
    # 元数据记录确切版本和校验值，许可正文同时随唯一 JSON 资产分发。
    catalog = {
        "source": {
            "package": "emoji_picker_flutter",
            "version": "4.4.0",
            "archiveUrl": ARCHIVE_URL,
            "archiveSha256": ARCHIVE_SHA256,
            "files": ["lib/locales/emoji_set_zh.dart", "lib/locales/emoji_set_en.dart"],
            "supplemental": {
                "project": "Unicode CLDR",
                "version": "48",
                "urlPrefix": CLDR_URL_PREFIX,
                "sha256": CLDR_SHA256,
                "copyright": "Copyright © 1991-2025 Unicode, Inc.",
            },
        },
        "licenses": [
            {"name": "MIT", "text": mit_license},
            {"name": "Unicode-3.0", "text": unicode_license},
        ],
        "entries": entries,
    }
    # 一条 emoji 占一行，保留可审查性并控制资产体积。
    lines = [
        "{",
        '  "source": ' + json.dumps(catalog["source"], ensure_ascii=False) + ",",
        '  "licenses": ' + json.dumps(catalog["licenses"], ensure_ascii=False) + ",",
        '  "entries": [',
        ",\n".join("    " + json.dumps(entry, ensure_ascii=False) for entry in catalog["entries"]),
        "  ]",
        "}",
        "",
    ]
    # 两个生成产物都使用固定 UTF-8 和 LF，跨平台字节一致。
    outputs = {
        ASSET_DIRECTORY / "note_tag_emoji_catalog.json": "\n".join(lines),
        ASSET_DIRECTORY / "LICENSE-emoji_picker_flutter.txt": mit_license,
    }
    # 检查模式不创建目录或修改文件。
    for path, content in outputs.items():
        if arguments.check:
            if not path.exists() or path.read_bytes() != content.encode("utf-8"):
                raise ValueError(f"生成产物需要更新：{path}")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content.encode("utf-8"))
    print(f"emoji catalog {'verified' if arguments.check else 'generated'}: 8 categories, 1611 entries")


if __name__ == "__main__":
    main()
