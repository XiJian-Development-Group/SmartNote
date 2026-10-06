#!/bin/bash
# check-docs.py 的自测：故意制造"文档变假话"的情形，确认检查器真的会拦。
#
#   bash scripts/self-test-check-docs.sh
#
# 每个用例都是「改坏 → 跑检查 → 还原」。为了不误伤你正在写的代码，
# 只要被触碰的文件有未提交改动，脚本会直接拒绝运行。
#
# 为什么要有这个：一个"永远打印 ✓"的检查器和没有检查器是一样的。
# 每次改动 check-docs.py 的检查逻辑后，跑一遍这里确认它仍然抓得住。

set -u
cd "$(git rev-parse --show-toplevel)" || exit 1

FEATURE="docs/功能清单.md"
NOTES="docs/notes.md"
CONTENT_VIEW="Platforms/macOS/Views/ContentView_macOS.swift"
THEME="Shared/Models/AppTheme.swift"
STORAGE="Shared/Services/StorageService.swift"
TOUCHED=("$FEATURE" "$NOTES" "$CONTENT_VIEW" "$THEME" "$STORAGE")

for file in "${TOUCHED[@]}"; do
    if ! git diff --quiet -- "$file"; then
        echo "拒绝运行：$file 有未提交改动。先提交或 stash，避免自测把你的改动还原掉。"
        exit 2
    fi
done

pass=0
fail=0

mutate() {  # 文件 原串 新串
    python3 - "$1" "$2" "$3" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old, new = sys.argv[2], sys.argv[3]
if old not in text:
    print(f"!! 变异失败：{path} 里找不到 {old!r}", file=sys.stderr)
    sys.exit(1)
path.write_text(text.replace(old, new, 1), encoding="utf-8")
PY
}

mutate_all() {  # 文件 原串 新串（替换全部出现）
    python3 - "$1" "$2" "$3" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old, new = sys.argv[2], sys.argv[3]
if old not in text:
    print(f"!! 变异失败：{path} 里找不到 {old!r}", file=sys.stderr)
    sys.exit(1)
path.write_text(text.replace(old, new), encoding="utf-8")
PY
}

append_line() {  # 文件 追加内容
    python3 - "$1" "$2" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_text(path.read_text(encoding="utf-8") + sys.argv[2] + "\n", encoding="utf-8")
PY
}

run_case() {  # 说明 期望命中的检查项
    # 注意：$code 后面紧跟全角括号时，bash 会把多字节字符的首字节当变量名的一部分，
    # 必须写 ${code} 这种带花括号的形式，否则报 unbound variable。
    local label="$1" keyword="$2" output code hits
    output=$(python3 scripts/check-docs.py 2>&1)
    code=$?
    hits=$(echo "$output" | grep '✗' | grep -c "$keyword")
    if [ "$code" -ne 0 ] && [ "$hits" -gt 0 ]; then
        echo "  ✅ ${label} → 拦住了（退出码 ${code}）"
        echo "$output" | grep '✗' | grep "$keyword" | head -1 | sed 's/^/       /'
        pass=$((pass + 1))
    else
        echo "  ❌ ${label} → 没拦住（退出码 ${code}）"
        fail=$((fail + 1))
    fi
}

echo "=== check-docs.py 自测 ==="
echo

mutate "$FEATURE" "共 28 项" "共 27 项"
run_case "文档写的侧栏项数被改错（28→27）" "A1"
git checkout -- "$FEATURE"

append_line "$CONTENT_VIEW" "// 探针：模拟新增一行代码"
run_case "改了代码没重跑 gen（生成物过期）" "代码地图"
git checkout -- "$CONTENT_VIEW"

mutate "$THEME" 'name: "经典"' 'name: "经典版"'
run_case "主题改名但 README 名单没跟着改" "A9"
git checkout -- "$THEME"

mutate "$CONTENT_VIEW" "case 24:" "case 44:"
run_case "侧栏有入口但 DetailView 没有对应 case" "B1"
git checkout -- "$CONTENT_VIEW"

mutate "$STORAGE" "@Published var p2pBackgroundEnabled: Bool = false" "@Published var p2pBackgroundEnabled: Bool = false
    @Published var probeFlag: Bool = false"
run_case "新增设置项但没同步 == / CodingKeys / 编解码" "B3"
git checkout -- "$STORAGE"

append_line "$NOTES" "参考 \`SmartNote/Sources/Views/DoesNotExist.swift\`。"
run_case "文档留下指向已删除文件的死链接" "A12"
git checkout -- "$NOTES"

mutate "$NOTES" "## 24. 构建与验证" "## 23. 构建与验证"
run_case "notes 章节号重复" "D1"
git checkout -- "$NOTES"

mutate_all "$FEATURE" "答案之书" "答案本"
run_case "侧栏有入口但功能清单里没有验收项" "E1"
git checkout -- "$FEATURE"

echo
if git diff --quiet -- "${TOUCHED[@]}"; then
    echo "还原完成：被触碰的文件已回到提交状态。"
else
    echo "⚠ 有文件没还原干净，请检查 git status。"
    fail=$((fail + 1))
fi

echo "结果：$pass 个用例被拦住，$fail 个漏网"
if [ "$fail" -eq 0 ]; then
    echo "自测通过：检查器确实会拦。"
    exit 0
fi
echo "自测失败：存在漏网用例，检查器需要修。"
exit 1
