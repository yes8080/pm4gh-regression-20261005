#!/usr/bin/env bash
# sync-labels.sh — 把 .github/labels.yml 幂等同步到仓库
#
# 设计依据（docs/项目管理方案.md §11）：
#   · 官方**没有** labels.yml 读取机制，GitHub 不会自动应用本文件
#   · 官方最接近"标签即代码"的机制是 gh label create --force（upsert）与 gh label clone
#   · 本脚本只做 upsert，**永不删除**仓库里的存量标签（删除会让历史 Issue 丢失语义）
#
# 兼容性：刻意只用 bash 3.2 可用的语法（macOS 自带 bash 就是 3.2），
#         不使用 mapfile / readarray / declare -A / ${var,,}，保证"换台机器也能跑"。
#
# 用法：
#   scripts/sync-labels.sh                 # 同步到默认仓库
#   scripts/sync-labels.sh --dry-run       # 只打印将要执行的操作
#   scripts/sync-labels.sh --check         # 校验本地定义与远端是否一致（不一致退出码 1）
#   REPO=owner/repo scripts/sync-labels.sh # 指定仓库
#   LABELS_FILE=path scripts/sync-labels.sh
#
# 退出码：0 成功/一致；1 校验不一致或同步失败；2 本地文件解析失败或环境缺依赖

set -eu

REPO="${REPO:-yes8080/pm4gh}"
LABELS_FILE="${LABELS_FILE:-.github/labels.yml}"
MODE="sync"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) MODE="dry-run" ;;
    --check)   MODE="check" ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "未知参数：${1}（见 --help）" >&2; exit 2 ;;
  esac
  shift
done

command -v gh  >/dev/null 2>&1 || { echo "缺少 gh CLI" >&2; exit 2; }
command -v awk >/dev/null 2>&1 || { echo "缺少 awk" >&2; exit 2; }
command -v jq  >/dev/null 2>&1 || { echo "缺少 jq（gh --json 解析需要）" >&2; exit 2; }
[ -f "$LABELS_FILE" ] || { echo "找不到标签定义文件：$LABELS_FILE" >&2; exit 2; }

TMP_ROWS="$(mktemp)"
TMP_REMOTE="$(mktemp)"
trap 'rm -f "$TMP_ROWS" "$TMP_REMOTE"' EXIT

# ── 解析严格格式的 labels.yml → TSV(name color description) ──
awk '
  function val(line,   p, s) {
    p = index(line, ":")
    if (p == 0) return ""
    s = substr(line, p + 1)
    gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s)
    gsub(/^"/, "", s); gsub(/"$/, "", s)
    return s
  }
  /^[ \t]*-[ \t]*name:/ { if (n != "") print n "\t" c "\t" d; n = val($0); c = ""; d = ""; next }
  /^[ \t]*color:/       { c = val($0); next }
  /^[ \t]*description:/ { d = val($0); next }
  END                   { if (n != "") print n "\t" c "\t" d }
' "$LABELS_FILE" > "$TMP_ROWS"

COUNT="$(wc -l < "$TMP_ROWS" | tr -d ' ')"
[ "$COUNT" -gt 0 ] || { echo "解析失败：$LABELS_FILE 里没有解析出任何标签" >&2; exit 2; }

# ── 逐条校验本地定义 ────────────────────────────────────────
while IFS="$(printf '\t')" read -r name color desc; do
  [ -n "$name" ] || continue
  if [ -z "$color" ] || [ -z "$desc" ]; then
    echo "解析失败：记录不完整 -> name='$name' color='$color' desc='$desc'" >&2
    echo "请检查 $LABELS_FILE 是否严格遵循 name/color/description 三行格式。" >&2
    exit 2
  fi
  case "$color" in
    [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) : ;;
    *) echo "解析失败：'$name' 的颜色 '$color' 不是 6 位十六进制（不要带 #）" >&2; exit 2 ;;
  esac
done < "$TMP_ROWS"

# 注意（已在 macOS bash 3.2 实际踩到）：变量后紧跟中文等多字节字符时必须写成 ${VAR}，
# 否则 bash 3.2 会把多字节字节序列并入变量名，导致 "unbound variable"。
echo "本地定义标签数：${COUNT}（来源 ${LABELS_FILE}）"
echo "目标仓库：${REPO}    模式：${MODE}"
echo

# ── check 模式：与远端比对 ──────────────────────────────────
if [ "$MODE" = "check" ]; then
  gh label list -R "$REPO" -L 200 --json name,color,description > "$TMP_REMOTE"
  drift=0
  while IFS="$(printf '\t')" read -r name color desc; do
    [ -n "$name" ] || continue
    got="$(jq -r --arg n "$name" '.[] | select(.name == $n) | "\(.color)|\(.description)"' "$TMP_REMOTE")"
    if [ -z "$got" ]; then
      printf '  缺失       %s\n' "$name"; drift=1; continue
    fi
    rcolor="${got%%|*}"
    rdesc="${got#*|}"
    rcolor_lc="$(printf '%s' "$rcolor" | tr 'A-Z' 'a-z')"
    want_lc="$(printf '%s' "$color" | tr 'A-Z' 'a-z')"
    if [ "$rcolor_lc" != "$want_lc" ]; then
      printf '  颜色不一致 %s：远端 %s ≠ 本地 %s\n' "$name" "$rcolor" "$color"; drift=1
    fi
    if [ "$rdesc" != "$desc" ]; then
      printf '  描述不一致 %s：远端 "%s" ≠ 本地 "%s"\n' "$name" "$rdesc" "$desc"; drift=1
    fi
  done < "$TMP_ROWS"
  if [ "$drift" -eq 0 ]; then
    echo "✅ 标签与远端一致"
    exit 0
  fi
  echo
  echo "❌ 存在漂移：执行 scripts/sync-labels.sh 使远端与本地定义一致"
  exit 1
fi

# ── sync / dry-run 模式 ────────────────────────────────────
ok=0; failed=0
while IFS="$(printf '\t')" read -r name color desc; do
  [ -n "$name" ] || continue
  if [ "$MODE" = "dry-run" ]; then
    printf '  [dry-run] gh label create "%s" --color %s --description "%s" --force\n' "$name" "$color" "$desc"
    continue
  fi
  if gh label create "$name" --color "$color" --description "$desc" --force -R "$REPO" >/dev/null 2>&1; then
    ok=$((ok + 1))
    printf '  ✓ %s\n' "$name"
  else
    failed=$((failed + 1))
    printf '  ✗ %s（同步失败）\n' "$name" >&2
  fi
done < "$TMP_ROWS"

if [ "$MODE" = "dry-run" ]; then
  echo
  echo "dry-run 结束：将 upsert $COUNT 个标签，不删除任何存量标签。"
  exit 0
fi

echo
echo "完成：成功 upsert $ok 个，失败 $failed 个。（脚本不删除存量标签）"
[ "$failed" -eq 0 ] || exit 1
