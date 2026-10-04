#!/usr/bin/env bash
# toolkit/scripts/labels.sh —— 标签定义解析器（**套件自己的资产**，不依赖宿主仓库的 scripts/）
#
# 为什么它在 toolkit 里（Bug #61 F2，P0）：
#   装到目标仓库的必需检查 ci/test 原来写的是
#       bash scripts/sync-labels.sh --dry-run | tail -1
#   这引用了 **宿主仓库自己的、既不在 manifest 登记也不被安装** 的脚本：
#     · 目标仓库里根本没有 scripts/sync-labels.sh → 步骤"看起来在跑"其实什么都没验；
#     · 加上 Actions 的 run shell 是 `bash -e {0}`（**无 pipefail**），管道退出码取 tail →
#       退出码 0 = **假绿**（Bug #61 F3）。
#   修法（二选一中的第①种，理由见 README §8）：
#     "把依赖资产纳入套件并登记" —— 解析器移入 toolkit/scripts/，在 manifest 的 objects.kit 登记，
#     随套件一起装配进目标仓库；工作流侧再补显式存在性守卫（F3），缺失时**非零退出**。
#
# 语义（只解析与校验，不联网、不需要 gh）：
#   labels.sh --check FILE   校验 FILE 是严格 name/color/description 三行格式；失败非零退出
#   labels.sh --tsv   FILE   输出 TSV(name color description)（供 install/eject 复用）
#   labels.sh --names FILE   输出标签名（每行一个）
#
# 兼容性铁律（与 scripts/lib.sh 相同，本项目实测踩坑）：
#   只用 bash 3.2 语法（禁用 mapfile/readarray/declare -A/${var,,}）；变量后紧跟中文写 ${VAR}
# 退出码：0 通过；1 校验不通过；2 用法/环境/文件缺失
set -euo pipefail

MODE="check"
FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE="check" ;;
    --tsv)   MODE="tsv" ;;
    --names) MODE="names" ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*) printf '未知参数：%s（见 --help）\n' "$1" >&2; exit 2 ;;
    *) FILE="$1" ;;
  esac
  shift
done

usage_error() { printf '[FAIL] %s\n' "$1" >&2; exit 2; }

# 文件缺失必须**明确失败**：绝不允许"找不到就当没事"（#61 F3 的教训）
[ -n "$FILE" ] || usage_error "缺少标签定义文件参数（用法：labels.sh --check .github/labels.yml）"
[ -f "$FILE" ] || usage_error "标签定义文件不存在：${FILE}"

parse() {
  awk '
    function val(line,   p, s) {
      p = index(line, ":"); if (p == 0) return ""
      s = substr(line, p + 1); gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s)
      gsub(/^"/, "", s); gsub(/"$/, "", s); return s
    }
    /^[ \t]*-[ \t]*name:/ { if (n != "") print n "\t" c "\t" d; n = val($0); c = ""; d = ""; next }
    /^[ \t]*color:/       { c = val($0); next }
    /^[ \t]*description:/ { d = val($0); next }
    END                   { if (n != "") print n "\t" c "\t" d }
  ' "$FILE"
}

ROWS="$(parse)"
if [ "$MODE" = "tsv" ]; then printf '%s\n' "$ROWS"; exit 0; fi
if [ "$MODE" = "names" ]; then printf '%s\n' "$ROWS" | cut -f1; exit 0; fi

count=0
while IFS="$(printf '\t')" read -r name color desc; do
  [ -n "$name" ] || continue
  count=$((count + 1))
  if [ -z "$color" ] || [ -z "$desc" ]; then
    printf '[FAIL] %s:%s 记录不完整（name=%s color=%s description=%s）—— 必须严格 name/color/description 三行\n' \
      "$FILE" "$count" "$name" "$color" "$desc" >&2
    exit 1
  fi
  case "$color" in
    [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) : ;;
    *) printf '[FAIL] %s：标签 %s 的颜色 %s 不是 6 位十六进制（不要带 #）\n' "$FILE" "$name" "$color" >&2; exit 1 ;;
  esac
done <<EOF
${ROWS}
EOF

# 空集不是"通过"：解析出 0 条 = 覆盖面为空 = 检查形同虚设（与 ci/lint 的空覆盖面审查同一原则）
if [ "$count" -eq 0 ]; then
  printf '[FAIL] %s 里没有解析出任何标签 —— 覆盖面为空，拒绝按通过处理\n' "$FILE" >&2
  exit 1
fi

printf '✅ 标签定义可解析：%s（%s 条，格式：name/color/description）\n' "$FILE" "$count"
