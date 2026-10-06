#!/usr/bin/env python3
"""SmartNote 文档与代码一致性检查 / 维护文档生成器。

只依赖标准库。用法：

    python3 scripts/check-docs.py          # 检查（默认），有硬错误退出码 1
    python3 scripts/check-docs.py gen      # 重新生成三份自动维护文档
    python3 scripts/check-docs.py --list   # 列出所有检查项

检查分五组：

  A 数字一致性   文档里写死的数字/名单 vs 代码与资源文件里的真值
  B 结构一致性   侧栏 tab ↔ DetailView case；AppSettings 六个落点的字段覆盖
  C 生成物新鲜度 docs/代码地图.md、docs/文案清单.md、docs/设置项清单.md 是否与代码同步
  D 章节编号     docs/notes.md 的章节号不重复、不倒序
  E 覆盖检查     每个侧栏入口都要在 docs/功能清单.md 里有对应验收项

生成的三份文档都由本脚本产出，因此不存在"手写文档忘了改"的问题：
代码变了而没重新生成，`check` 会直接报错。

新增侧栏项、设置项、数据文件、答案条目后，先跑 `gen` 再跑 `check`。
"""

from __future__ import annotations

import json
import pathlib
import re
import sys
from collections import Counter, defaultdict

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
# iOS/macOS 工程化迁移后，跨平台代码在 Shared/，macOS 专有代码在 Platforms/macOS/。
# iOS 专有代码在 Platforms/iOS/，本检查器只关心 Shared/ + Platforms/macOS/（macOS 是文档基线）。
SHARED = ROOT / "Shared"
MACOS = ROOT / "Platforms" / "macOS"
SHARED_RES = SHARED / "Resources"

README = ROOT / "README.md"
FEATURE_LIST = DOCS / "功能清单.md"
NOTES = DOCS / "notes.md"
CODEX_MAP = DOCS / "代码地图.md"
STRINGS_DOC = DOCS / "文案清单.md"
SETTINGS_DOC = DOCS / "设置项清单.md"

STORAGE = SHARED / "Services" / "StorageService.swift"
INTENTS = MACOS / "Services" / "SmartNoteIntents.swift"
CONTENT_VIEW = MACOS / "Views" / "ContentView_macOS.swift"
THEME = SHARED / "Models" / "AppTheme.swift"
ANSWER_BOOK = SHARED_RES / "answer_book.json"

GENERATED_HEADER = (
    "<!-- 本文件由 scripts/check-docs.py 生成，请勿手动编辑；"
    "代码改动后请重跑 `python3 scripts/check-docs.py gen`。 -->\n\n"
)

CJK = re.compile(r"[\u3400-\u9fff\u3000-\u303f\uff00-\uffef]")

# 侧栏标签与文档用语不一致时的显式别名（键为侧栏 Label，值为文档里可接受的说法）。
# 只在确有历史上不同的叫法时才登记，不要拿它掩盖真正漏写的文档。
SIDEBAR_LABEL_ALIASES = {
    "重复清理": ["重复文件清理"],
    "社交": ["P2P", "社交"],
    "中国近代史": ["中国近代史", "历史科普"],
    "习惯养成打卡": ["习惯打卡", "习惯养成"],
    "全部资料": ["全部资料", "资料库"],
    "文件加密": ["文件加密"],
}

# 有意保留、不属于待清理的字段。
SETTINGS_NO_UI_ALLOWLIST = {
    "defaultStudyMinutes": "旧版本遗留字段，保留仅为兼容老 settings.json",
    "schemaVersion": "由 runStartupMigration 管理，UI 不应直接修改",
    "lastMigrationDate": "迁移记录",
    "lastMigrationCheckedAt": "迁移记录",
    "lastUpdateCheckDate": "更新检查记录",
    "lastFoundReleaseName": "更新检查记录",
    "updateRepoOwner": "更新源配置，设置页可改",
    "updateRepoName": "更新源配置，设置页可改",
    "updateCheckIntervalHours": "更新间隔，设置页可改",
}

# 有意不参与某个落点的字段。**必须写明理由**：
# 这里的每一条都对应代码里的一段显式注释，理由不清楚就不该登记进来。
SETTINGS_INTENTIONAL_EXCLUSIONS: dict[str, dict[str, str]] = {
    "examCountdowns": {
        "encode": "唯一真相源是 AppState.examCountdowns（持久化在 examCountdowns.json）；"
        "settings 里的该键只为一次性迁移保留，写回会造成「设置旧快照覆盖新列表」"
    },
}

# 用户文案里不该出现的模式。
SUSPICIOUS_STRING_PATTERNS = [
    (re.compile(r"\([A-Za-z]\d+(\.\d+)?\)"), "疑似开发编号（如 (A5.2)）"),
    (re.compile(r"按(您|你)说"), "疑似对话残留"),
    (re.compile(r"\bTODO\b|\bFIXME\b|\bXXX\b"), "占位标记"),
    (re.compile(r"待填|占位|示例文本|lorem", re.I), "占位文案"),
    (re.compile(r"[\u4e00-\u9fff][,;][\u4e00-\u9fff]"), "中文里混用半角逗号/分号"),
]

LOG_CALL = re.compile(r"\b(print|NSLog|os_log|debugPrint)\s*\(")
UI_HINT = re.compile(
    r"(Text\(|Label\(|Button\(|\.help\(|navigationTitle|alert\(|TextField\(|SecureField\(|"
    r"Toggle\(|Picker\(|Section\(|confirmationDialog|accessibilityLabel|IntentDescription|"
    r"LocalizedStringResource|title:|placeholder|NSLocalizedDescriptionKey|errorDescription)"
)


# ----------------------------------------------------------------------------
# 通用
# ----------------------------------------------------------------------------


class Report:
    def __init__(self) -> None:
        self.fatal: list[str] = []
        self.warn: list[str] = []
        self.passed: list[str] = []

    def check(self, ok: bool, title: str, detail: str = "", evidence: str = "") -> bool:
        line = title + (f" —— {detail}" if detail else "")
        if evidence:
            line += f"（{evidence}）"
        if ok:
            self.passed.append(line)
        else:
            self.fatal.append(line)
        return ok

    def warn_if(self, condition: bool, message: str) -> None:
        if condition:
            self.warn.append(message)

    def render(self) -> str:
        out = []
        for line in self.passed:
            out.append(f"  ✓ {line}")
        for line in self.warn:
            out.append(f"  ⚠ {line}")
        for line in self.fatal:
            out.append(f"  ✗ {line}")
        return "\n".join(out)


def read(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8")


def line_of(text: str, needle: str) -> int:
    for index, line in enumerate(text.splitlines(), 1):
        if needle in line:
            return index
    return 0


def swift_files() -> list[pathlib.Path]:
    return sorted(set(SHARED.rglob("*.swift")) | set(MACOS.rglob("*.swift")))


def string_literals(path: pathlib.Path) -> list[tuple[int, str]]:
    """返回 (行号, 字面量内容)。跳过插值里的表达式文本，只保留字面量本体。"""
    literals: list[tuple[int, str]] = []
    pattern = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
    for index, line in enumerate(read(path).splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith("//") or stripped.startswith("///"):
            continue
        for match in pattern.finditer(line):
            literals.append((index, match.group(1)))
    return literals


# ----------------------------------------------------------------------------
# 真值提取（都从代码/资源里算，不信任文档）
# ----------------------------------------------------------------------------


def truth_sidebar() -> tuple[int, set[int], list[str]]:
    """(侧栏入口数, NavigationLink 的 value 集合, 侧栏标签列表)

    入口数按 Label 数算：许愿是 `Button`（独立窗口，没有 tab 编号），
    所以「入口数」与「tab 编号数」本来就差 1，不能拿它们互相比较。
    """
    text = read(CONTENT_VIEW)
    start = text.index("struct SidebarView")
    end = text.index("\nstruct ", start + 10)
    body = text[start:end]
    values = {int(v) for v in re.findall(r"NavigationLink\(value:\s*(\d+)\)", body)}
    labels = re.findall(r'Label\("([^"]+)"', body)
    navigation_links = len(re.findall(r"NavigationLink\(value:", body))
    return navigation_links + (len(labels) - navigation_links), values, labels


def truth_sidebar_links() -> int:
    text = read(CONTENT_VIEW)
    start = text.index("struct SidebarView")
    end = text.index("\nstruct ", start + 10)
    return len(re.findall(r"NavigationLink\(value:", text[start:end]))


def truth_detail_cases() -> list[int]:
    text = read(CONTENT_VIEW)
    start = text.index("struct DetailView")
    body = text[start:]
    return [int(v) for v in re.findall(r"^\s*case (\d+):", body, re.M)]


def truth_shortcuts() -> int:
    return len(re.findall(r"AppShortcut\(", read(INTENTS)))


def truth_themes() -> list[str]:
    text = read(THEME)
    start = text.index("static let classic")
    end = text.index("static func theme(for id:")
    return re.findall(r'name:\s*"([^"]+)"', text[start:end])


def truth_answer_book() -> dict:
    data = json.loads(read(ANSWER_BOOK))
    answers = data["answers"]
    kinds = Counter(entry.get("kind", "normal") for entry in answers)
    special = {entry["kind"]: entry for entry in answers if entry.get("kind", "normal") != "normal"}
    return {
        "total": len(answers),
        "normal": kinds.get("normal", 0),
        "lost": kinds.get("lost", 0),
        "glitch": kinds.get("glitch", 0),
        "lost_id": special.get("lost", {}).get("id"),
        "glitch_id": special.get("glitch", {}).get("id"),
        "unique_ids": len({entry["id"] for entry in answers}) == len(answers),
        "unique_text": len({entry["content"] for entry in answers}) == len(answers),
    }


def truth_managed_data_files() -> set[str]:
    text = read(STORAGE)
    start = text.index("private enum ManagedDataPath: CaseIterable {")
    end = text.index("var isDirectory: Bool {", start)
    return set(re.findall(r'return "([^"]+\.json)"', text[start:end]))


BUNDLE_RESOURCES = {"history_catalog.json", "answer_book.json"}


def truth_app_settings() -> dict:
    text = read(STORAGE)
    start = text.index("class AppSettings: ObservableObject, Codable, Equatable {")
    block = text[start:]
    equal_start = block.index("static func == (lhs: AppSettings")
    equal_end = block.index("enum DarkModePreference:")
    equality = block[equal_start:equal_end]
    keys_start = block.index("enum CodingKeys: String, CodingKey {")
    keys_end = block.index("init() {", keys_start)
    coding_keys = block[keys_start:keys_end]

    fields: list[dict] = []
    for match in re.finditer(
        r"@Published var (\w+):\s*([^=\n]+?)\s*=\s*(.+)$", block, re.M
    ):
        name, type_name, default = match.group(1), match.group(2).strip(), match.group(3).strip()
        if name == "schemaVersion":  # 第一处 @Published 之前是类头，仍需检查
            pass
        fields.append(
            {
                "name": name,
                "type": type_name,
                "default": default,
                "in_equality": re.search(rf"\.{name}\b", equality) is not None,
                "in_keys": re.search(rf"\bcase {name}\b", coding_keys) is not None,
                "in_decode": re.search(rf"(decodeIfPresent|decode)\([^)\n]*forKey: \.{name}\b", block) is not None,
                "in_encode": re.search(rf"(encode|encodeIfPresent)\([^)\n]*forKey: \.{name}\b", block) is not None,
                "ui_refs": 0,
            }
        )

    views_text = "\n".join(read(p) for p in sorted(set((SHARED / "Views").rglob("*.swift")) | set((MACOS / "Views").rglob("*.swift"))))
    for field in fields:
        field["ui_refs"] = len(re.findall(rf"\.{field['name']}\b", views_text))
    return {"fields": fields}


# ----------------------------------------------------------------------------
# 生成物
# ----------------------------------------------------------------------------


def first_doc_comment(text: str) -> str:
    """取文件顶部的第一段文档注释（/// 或 //），作为一句话说明。"""
    lines = text.splitlines()
    collected: list[str] = []
    for line in lines[:40]:
        stripped = line.strip()
        if stripped.startswith("///"):
            collected.append(stripped.lstrip("/ ").strip())
        elif stripped.startswith("//"):
            collected.append(stripped.lstrip("/ ").strip())
        elif stripped.startswith("import") or stripped.startswith("@"):
            continue
        elif not stripped:
            if collected:
                break
            continue
        else:
            break
    if not collected:
        return "—"
    text_joined = collected[0]
    return text_joined if len(text_joined) <= 70 else text_joined[:69] + "…"


def declared_types(text: str) -> str:
    found: list[str] = []
    for match in re.finditer(
        r"^(?:public |internal |private |fileprivate )?(?:final )?(?:class|struct|enum|protocol|actor) (\w+)",
        text,
        re.M,
    ):
        name = match.group(1)
        if name not in found:
            found.append(name)
    if not found:
        return "—"
    if len(found) <= 3:
        return "、".join(found)
    return "、".join(found[:3]) + f" 等 {len(found)} 个"


def gen_codemap() -> str:
    groups: dict[str, list[pathlib.Path]] = defaultdict(list)
    for path in swift_files():
        groups[str(path.parent.relative_to(ROOT))].append(path)

    total_files = 0
    total_lines = 0
    sections: list[str] = []
    for group in sorted(groups):
        section = [f"## {group}/", "", "| 文件 | 行数 | 主要类型 | 说明 |", "|---|---|---|---|"]
        for path in sorted(groups[group]):
            text = read(path)
            lines = len(text.splitlines())
            total_files += 1
            total_lines += lines
            section.append(
                f"| `{path.name}` | {lines} | {declared_types(text)} | {first_doc_comment(text)} |"
            )
        section.append("")
        sections.append("\n".join(section))

    header = [
        "# SmartNote 代码地图",
        "",
        GENERATED_HEADER.rstrip("\n"),
        "",
        f"`Shared/` 与 `Platforms/macOS/` 下共 **{total_files}** 个 Swift 文件、**{total_lines}** 行；"
        "按目录分组，每个文件给出主要类型与首段文档注释。iOS 端独有文件见 `Platforms/iOS/`，"
        "未纳入本表（基线是 macOS）。",
        "",
        "改代码时先看本表定位文件；新增文件后本表会由 `check-docs.py` 重新生成并在检查时报出未同步。",
        "",
        "---",
        "",
    ]
    return "\n".join(header) + "\n".join(sections)


def classify_literal(path: pathlib.Path, line: str) -> str:
    if LOG_CALL.search(line):
        return "log"
    if UI_HINT.search(line):
        return "ui"
    return "other"


def collect_strings() -> tuple[list[dict], list[dict]]:
    ui: list[dict] = []
    others: list[dict] = []
    for path in swift_files():
        rel = str(path.relative_to(ROOT))
        for line_no, line in enumerate(read(path).splitlines(), 1):
            if line.strip().startswith("//"):
                continue
            for match in re.finditer(r'"((?:[^"\\\n]|\\.)*)"', line):
                value = match.group(1)
                if not CJK.search(value):
                    continue
                item = {"file": rel, "line": line_no, "text": value}
                (ui if classify_literal(path, line) == "ui" else others).append(item)
    return ui, others


def gen_strings() -> str:
    ui, others = collect_strings()
    by_file: dict[str, list[dict]] = defaultdict(list)
    for item in ui:
        by_file[item["file"]].append(item)

    text_counter = Counter(item["text"] for item in ui)
    cross_file: dict[str, set[str]] = defaultdict(set)
    for item in ui:
        cross_file[item["text"]].add(item["file"])
    repeated = [
        (text, count, len(cross_file[text]))
        for text, count in text_counter.items()
        if len(cross_file[text]) >= 2
    ]
    repeated.sort(key=lambda row: (-row[2], -row[1], row[0]))

    suspicious: list[tuple[str, str, int, str]] = []
    for item in ui:
        for pattern, reason in SUSPICIOUS_STRING_PATTERNS:
            if pattern.search(item["text"]):
                suspicious.append((item["file"], item["line"], item["text"], reason))

    out: list[str] = []
    out.append("# SmartNote 用户文案清单")
    out.append("")
    out.append(GENERATED_HEADER.rstrip("\n"))
    out.append("")
    out.append(
        "本表列出源码里全部**含中文的字符串字面量**，分成「用户可见」与「内部/日志」两类，"
        "便于统一检查措辞与择机抽取常量。行号即 `file:line`，改文案直接跳过去。"
    )
    out.append("")
    out.append("## 概况")
    out.append("")
    out.append("| 项 | 数量 |")
    out.append("|---|---|")
    out.append(f"| 用户可见文案 | {len(ui)} |")
    out.append(f"| 内部 / 日志字符串 | {len(others)} |")
    out.append(f"| 出现在 ≥2 个文件里的同一句话 | {len(repeated)} |")
    out.append(f"| 命中可疑模式的用户文案 | {len(suspicious)} |")
    out.append("")
    out.append("## 跨文件重复最多的文案（可作为抽公共常量的候选）")
    out.append("")
    out.append("| 文案 | 出现次数 | 涉及文件数 |")
    out.append("|---|---|---|")
    for text, count, files in repeated[:40]:
        out.append(f"| `{text}` | {count} | {files} |")
    if not repeated:
        out.append("| — | — | — |")
    out.append("")
    out.append("## 可疑文案（占位符 / 开发编号 / 对话残留 / 标点混用）")
    out.append("")
    out.append("| 位置 | 文案 | 原因 |")
    out.append("|---|---|---|")
    for file, line, text, reason in suspicious[:60]:
        out.append(f"| `{file}:{line}` | `{text}` | {reason} |")
    if not suspicious:
        out.append("| — | — | — |")
    out.append("")
    out.append("---")
    out.append("")
    out.append("## 用户可见文案（按文件）")
    out.append("")
    for file in sorted(by_file):
        items = by_file[file]
        out.append(f"### `{file}`（{len(items)} 条）")
        out.append("")
        out.append("| 行 | 文案 |")
        out.append("|---|---|")
        for item in items:
            out.append(f"| {item['line']} | `{item['text']}` |")
        out.append("")
    out.append("---")
    out.append("")
    out.append("## 内部 / 日志字符串（按文件，仅供参考，不必逐条审）")
    out.append("")
    other_by_file: dict[str, int] = Counter(item["file"] for item in others)
    out.append("| 文件 | 条数 |")
    out.append("|---|---|")
    for file, count in sorted(other_by_file.items(), key=lambda kv: (-kv[1], kv[0])):
        out.append(f"| `{file}` | {count} |")
    out.append("")
    return "\n".join(out)


def gen_settings() -> str:
    data = truth_app_settings()
    fields = data["fields"]
    out: list[str] = []
    out.append("# SmartNote 设置项清单")
    out.append("")
    out.append(GENERATED_HEADER.rstrip("\n"))
    out.append("")
    out.append(
        "`AppSettings` 的字段散落在 `Services/StorageService.swift` 里，新增一个设置项要同时改 **6 处**："
        "属性声明、`==`、`CodingKeys`、`init()`、`init(from:)`、`encode(to:)`。"
        "漏掉 `==` 会让「改了设置不生效」，漏掉 `encode` / `init(from:)` 会让「重启后归零」。"
        "本表由脚本核对这 6 处，`check` 会把缺失项当成硬错误。"
    )
    out.append("")
    out.append("| 字段 | 类型 | 默认值 | == | CodingKeys | 解码 | 编码 | 视图引用 |")
    out.append("|---|---|---|---|---|---|---|---|")

    def mark(field: dict, key: str, flag: str) -> str:
        if field[flag]:
            return "✓"
        if key in SETTINGS_INTENTIONAL_EXCLUSIONS.get(field["name"], {}):
            return "—（有意）"
        return "✗"

    for field in fields:
        out.append(
            "| `{name}` | `{type}` | `{default}` | {eq} | {keys} | {dec} | {enc} | {ui} |".format(
                name=field["name"],
                type=field["type"],
                default=field["default"].replace("|", "\\|"),
                eq=mark(field, "equality", "in_equality"),
                keys=mark(field, "keys", "in_keys"),
                dec=mark(field, "decode", "in_decode"),
                enc=mark(field, "encode", "in_encode"),
                ui=field["ui_refs"],
            )
        )
    out.append("")
    out.append("## 有意豁免（代码里有显式注释的设计决定，不算缺陷）")
    out.append("")
    out.append("| 字段 | 落点 | 理由 |")
    out.append("|---|---|---|")
    for name, places in SETTINGS_INTENTIONAL_EXCLUSIONS.items():
        for place, reason in places.items():
            out.append(f"| `{name}` | {place} | {reason} |")
    out.append("")
    out.append("## 没有任何视图引用的字段")
    out.append("")
    out.append("| 字段 | 说明 |")
    out.append("|---|---|")
    no_ui = [f for f in fields if f["ui_refs"] == 0]
    for field in no_ui:
        reason = SETTINGS_NO_UI_ALLOWLIST.get(field["name"], "⚠ 未登记，确认是否为遗留字段")
        out.append(f"| `{field['name']}` | {reason} |")
    if not no_ui:
        out.append("| — | — |")
    out.append("")
    return "\n".join(out)


GENERATED = {
    CODEX_MAP: gen_codemap,
    STRINGS_DOC: gen_strings,
    SETTINGS_DOC: gen_settings,
}


# ----------------------------------------------------------------------------
# 检查
# ----------------------------------------------------------------------------


def check_numbers(report: Report) -> None:
    readme = read(README)
    feature = read(FEATURE_LIST)
    notes = read(NOTES)

    sidebar_count, sidebar_values, sidebar_labels = truth_sidebar()
    match = re.search(r"共 (\d+) 项", feature)
    report.check(
        match is not None and int(match.group(1)) == sidebar_count,
        "A1 侧栏项数：功能清单 vs SidebarView 实际入口数",
        f"文档写 {match.group(1) if match else '未找到'}，实际 {sidebar_count}",
        f"docs/功能清单.md:{line_of(feature, '共 ')}",
    )

    shortcuts = truth_shortcuts()
    match = re.search(r"注册了(\d+)个 Siri", readme)
    report.check(
        match is not None and int(match.group(1)) == shortcuts,
        "A2 Siri 短语数：README vs AppShortcut 实际数量",
        f"文档写 {match.group(1) if match else '未找到'}，实际 {shortcuts}",
        f"README.md:{line_of(readme, '个 Siri')}",
    )
    match = re.search(r"(\d+) 个 `AppShortcut`", notes)
    report.check(
        match is not None and int(match.group(1)) == shortcuts,
        "A3 Siri 短语数：notes vs AppShortcut 实际数量",
        f"文档写 {match.group(1) if match else '未找到'}，实际 {shortcuts}",
        f"docs/notes.md:{line_of(notes, '个 `AppShortcut`')}",
    )

    book = truth_answer_book()
    match = re.search(r"答案库 (\d+) 条", readme)
    report.check(
        match is not None and int(match.group(1)) == book["total"],
        "A4 答案条数：README vs answer_book.json",
        f"文档写 {match.group(1) if match else '未找到'}，实际 {book['total']}",
        f"README.md:{line_of(readme, '答案库')}",
    )
    match = re.search(r"共 (\d+) 条答案", feature)
    report.check(
        match is not None and int(match.group(1)) == book["total"],
        "A5 答案条数：功能清单 vs answer_book.json",
        f"文档写 {match.group(1) if match else '未找到'}，实际 {book['total']}",
        f"docs/功能清单.md:{line_of(feature, '条答案')}",
    )

    final_row = next((l for l in notes.splitlines() if l.startswith("| 最终条数 |")), "")
    pairs = [
        (r"\*\*(\d+) 条\*\*", "total", "总数"),
        (r"(\d+) 常规", "normal", "常规"),
        (r"(\d+) 迷失页", "lost", "迷失页"),
        (r"(\d+) 书页故障", "glitch", "书页故障"),
    ]
    for pattern, key, label in pairs:
        found = re.search(pattern, final_row)
        report.check(
            found is not None and int(found.group(1)) == book[key],
            f"A6 答案构成（{label}）：notes 搬迁表 vs answer_book.json",
            f"文档写 {found.group(1) if found else '未找到'}，实际 {book[key]}",
            f"docs/notes.md:{line_of(notes, '| 最终条数 |')}",
        )
    for pattern, key, label in [
        (r"`lost`，编号 (\d+)", "lost_id", "迷失页"),
        (r"`glitch`，编号 (\d+)", "glitch_id", "书页故障"),
    ]:
        found = re.search(pattern, final_row)
        report.check(
            found is not None and int(found.group(1)) == book[key],
            f"A7 彩蛋编号（{label}）：notes 写的编号 vs 资源里的 id",
            f"文档写 {found.group(1) if found else '未找到'}，实际 {book[key]}",
        )
    report.check(
        book["unique_ids"] and book["unique_text"],
        "A8 answer_book.json 编号与文案唯一",
        f"编号唯一={book['unique_ids']} 文案唯一={book['unique_text']}",
    )

    themes = truth_themes()
    bracket = re.search(r"^\[\s*(.+?)\s*\]", readme, re.M)
    documented = bracket.group(1).split() if bracket else []
    report.check(
        documented == themes,
        "A9 主题名单：README 方括号列表 vs AppTheme 里的 name",
        f"文档 {documented}，代码 {themes}",
        f"README.md:{line_of(readme, '经典')}",
    )
    match = re.search(r"依次选 (\d+) 个主题", feature)
    report.check(
        match is not None and int(match.group(1)) == len(themes),
        "A10 主题数量：功能清单 vs AppTheme.all",
        f"文档写 {match.group(1) if match else '未找到'}，实际 {len(themes)}",
    )

    managed = truth_managed_data_files()
    allowed = managed | BUNDLE_RESOURCES
    offending: list[str] = []
    for doc in (README, FEATURE_LIST, NOTES):
        text = read(doc)
        for match in re.finditer(r"`([A-Za-z][A-Za-z0-9_.*-]*\.json)`", text):
            name = match.group(1)
            if ".corrupted-" in name:
                base = name.split(".corrupted-")[0] + ".json"
                if base in allowed:
                    continue
            if name not in allowed:
                offending.append(f"{doc.name}:{line_of(text, name)} 提到 {name}")
    report.check(
        not offending,
        "A11 文档里提到的数据文件名都已登记在 ManagedDataPath（或确为包内资源）",
        "未登记：" + "；".join(offending) if offending else f"共核对 {len(managed)} 个受管文件",
    )

    # 文档里的仓库内路径必须真实存在：重构改了文件名/目录之后，
    # 文档最容易留下指向已删除文件的指针，这类指针看起来像真的，实际是死的。
    reference = re.compile(
        r"(SmartNote/[A-Za-z0-9_/.-]+\.(?:swift|json|plist|entitlements))"
        r"|(scripts/[A-Za-z0-9_.-]+\.py)"
        r"|(docs/[^\s`|)]+\.md)"
        r"|(project\.yml)"
    )
    dangling: list[str] = []
    for doc in (README, FEATURE_LIST, NOTES, CODEX_MAP, STRINGS_DOC, SETTINGS_DOC):
        if not doc.exists():
            continue
        text = read(doc)
        for match in reference.finditer(text):
            relative = next(group for group in match.groups() if group)
            # 形如 `~/Library/Application Support/SmartNote/xxx.json` 的是用户数据目录，
            # 不是仓库路径，不在这里校验。
            prefix = text[max(0, match.start() - 24) : match.start()]
            if "Support/" in prefix or "Library/" in prefix:
                continue
            if not (ROOT / relative).exists():
                dangling.append(f"{doc.name} → {relative}")
    report.check(
        not dangling,
        "A12 文档里引用的仓库内路径都存在（没有指向已删除/改名文件的死链接）",
        "死链接：" + "；".join(sorted(set(dangling))) if dangling else "全部可解析",
    )


def check_structure(report: Report) -> None:
    sidebar_count, sidebar_values, _ = truth_sidebar()
    cases = truth_detail_cases()
    missing = sorted(sidebar_values - set(cases))
    extra = sorted(set(cases) - sidebar_values)
    report.check(
        not missing and not extra and len(cases) == len(set(cases)),
        "B1 侧栏 value ↔ DetailView case 一一对应",
        f"侧栏缺 case：{missing or '无'}；多余 case：{extra or '无'}；case 重复={len(cases) != len(set(cases))}",
        f"Platforms/macOS/Views/ContentView_macOS.swift",
    )
    report.check(
        len(sidebar_values) == truth_sidebar_links(),
        "B2 侧栏每个 NavigationLink 都有独立 tab 编号（无重复编号）",
        f"{truth_sidebar_links()} 个 NavigationLink，{len(sidebar_values)} 个唯一编号",
    )

    fields = truth_app_settings()["fields"]
    for key, label in [
        ("in_equality", "== 比较"),
        ("in_keys", "CodingKeys"),
        ("in_decode", "init(from:) 解码"),
        ("in_encode", "encode(to:) 编码"),
    ]:
        missing_fields = [
            field["name"]
            for field in fields
            if not field[key]
            and key.replace("in_", "") not in SETTINGS_INTENTIONAL_EXCLUSIONS.get(field["name"], {})
        ]
        report.check(
            not missing_fields,
            f"B3 AppSettings 每个字段都出现在{label}里（共 {len(fields)} 个字段）",
            "缺失：" + "、".join(missing_fields) if missing_fields else "全部覆盖（含已登记的有意豁免）",
            "Shared/Services/StorageService.swift",
        )

    known = {field["name"] for field in fields}
    stale = sorted(name for name in SETTINGS_INTENTIONAL_EXCLUSIONS if name not in known)
    report.warn_if(
        bool(stale),
        f"B4 有意豁免表里有 {len(stale)} 条已不存在的字段（表过期，应删）：{stale}",
    )


def check_generated(report: Report) -> None:
    for path, generator in GENERATED.items():
        rel = path.relative_to(ROOT)
        if not path.exists():
            report.check(False, f"C {rel} 存在", "文件缺失，先跑 `python3 scripts/check-docs.py gen`")
            continue
        expected = generator()
        actual = read(path)
        report.check(
            expected == actual,
            f"C {rel} 与代码同步",
            "内容一致" if expected == actual else "已过期，跑 `python3 scripts/check-docs.py gen` 重新生成",
        )


def check_chapters(report: Report) -> None:
    numbers = [int(m) for m in re.findall(r"^## (\d+)\. ", read(NOTES), re.M)]
    duplicates = [n for n, count in Counter(numbers).items() if count > 1]
    report.check(not duplicates, "D1 notes.md 章节号不重复", f"重复：{duplicates or '无'}")
    report.check(
        numbers == sorted(numbers),
        "D2 notes.md 章节号按顺序排列",
        f"实际顺序：{numbers}",
    )
    gaps = [n for n in range(min(numbers), max(numbers) + 1) if n not in numbers] if numbers else []
    report.warn_if(bool(gaps), f"D3 notes.md 章节号存在空缺：{gaps}（不阻断，但确认是否为漏写的章节）")


def check_coverage(report: Report) -> None:
    _, _, labels = truth_sidebar()
    feature = read(FEATURE_LIST)
    missing: list[str] = []
    for label in labels:
        candidates = SIDEBAR_LABEL_ALIASES.get(label, [label])
        if not any(candidate in feature for candidate in candidates):
            missing.append(label)
    report.check(
        not missing,
        f"E1 每个侧栏入口（{len(labels)} 个）都在功能清单里有验收项",
        "缺：" + "、".join(missing) if missing else "全部覆盖",
        "docs/功能清单.md",
    )


def check_string_audit(report: Report) -> None:
    ui, _ = collect_strings()
    suspicious = []
    for item in ui:
        for pattern, reason in SUSPICIOUS_STRING_PATTERNS:
            if pattern.search(item["text"]):
                suspicious.append((f"{item['file']}:{item['line']}", item["text"], reason))
                break
    for location, text, reason in suspicious[:10]:
        report.warn_if(True, f"E2 可疑文案 {location}：`{text}`（{reason}）")
    report.warn_if(
        len(suspicious) > 10,
        f"E2 可疑文案共 {len(suspicious)} 条，仅列出前 10 条，完整清单见 docs/文案清单.md",
    )
    report.warn_if(
        True,
        f"E3 用户可见中文文案共 {len(ui)} 条；跨文件重复与抽取建议见 docs/文案清单.md",
    )


CHECKS = [
    ("A 数字一致性", check_numbers),
    ("B 结构一致性", check_structure),
    ("C 生成物新鲜度", check_generated),
    ("D 章节编号", check_chapters),
    ("E 覆盖与文案", check_coverage),
    ("E 文案审计", check_string_audit),
]


def run_check() -> int:
    report = Report()
    for title, func in CHECKS:
        print(f"\n[{title}]")
        before_fatal = len(report.fatal)
        before_warn = len(report.warn)
        before_pass = len(report.passed)
        func(report)
        chunk = Report()
        chunk.passed = report.passed[before_pass:]
        chunk.warn = report.warn[before_warn:]
        chunk.fatal = report.fatal[before_fatal:]
        print(chunk.render() or "  （无输出）")

    print("\n" + "=" * 60)
    print(f"通过 {len(report.passed)} 项，警告 {len(report.warn)} 项，硬错误 {len(report.fatal)} 项")
    if report.fatal:
        print("\n硬错误（会让文档变成假话，必须修）：")
        for line in report.fatal:
            print(f"  ✗ {line}")
        return 1
    print("文档与代码一致。")
    return 0


def run_gen() -> int:
    for path, generator in GENERATED.items():
        path.write_text(generator(), encoding="utf-8")
        print(f"已生成 {path.relative_to(ROOT)}（{len(read(path).splitlines())} 行）")
    return 0


def main(argv: list[str]) -> int:
    if "--list" in argv:
        for title, _ in CHECKS:
            print(title)
        return 0
    if "gen" in argv or "--gen" in argv:
        return run_gen()
    return run_check()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
