#!/usr/bin/env bash
# toolkit/install.sh —— 可移植治理套件安装器（E2-S1：归属清单 + --dry-run / --check / --apply）
#
# 用法：
#   toolkit/install.sh --dry-run        # 默认模式。零写入，完整预告每个对象将被创建/更新/跳过
#   toolkit/install.sh --check          # 只读。比对「线上实况 vs manifest 期望」，漂移只报告
#   toolkit/install.sh --apply          # 实际安装（幂等；重复执行是 no-op）
#
# 参数（全部可参数化；对应 toolkit/manifest.json 的 parameters 段）：
#   --repo OWNER/NAME        目标仓库（默认：gh repo view）
#   --default-branch NAME    默认分支（默认：gh repo view 的 defaultBranchRef）
#   --owner ACCOUNT          仓库 owner / 主身份账号（默认：REPO 的 owner 部分）
#   --author-account ACCOUNT 作者身份账号（默认：读凭据文件 .secrets/developer.pat 的身份）
#   --reviewer-account ACCT  评审身份账号（默认：读凭据文件 .secrets/reviewer.pat 的身份）
#   --root DIR               目标仓库根目录（默认：本脚本所在目录的上一级）
#   --kit-dir DIR            套件目录（默认：本脚本所在目录）
#   --manifest FILE          归属清单（默认：<kit-dir>/manifest.json）
# 等价环境变量：REPO / DEFAULT_BRANCH / OWNER / AUTHOR_ACCOUNT / REVIEWER_ACCOUNT
#               DEVELOPER_PAT_FILE / REVIEWER_PAT_FILE
#
# 设计要点（对应 Issue #46 的验收标准）：
#   ① 归属清单唯一：manifest.json 登记每一类受管对象（文件 / 标签 / 规则集 / workflow /
#      CODEOWNERS 行 / 协作者），并记录「装机前是否已存在」。
#   ② 三态幂等 planned → observed → owned：
#        planned  = manifest 里声明的期望（本脚本的输入）
#        observed = **本次运行现读的线上实况**（绝不用上一次运行的记账代替观测）
#        owned    = 本套件创建或明确接管（--apply 时**写前落账** intent=create，成功后回读确认）
#      重试语义：上一次命令报错、但对象其实已经创建 → 记账里留有 create 意图且实况存在
#      → 仍判 owned=true，不会被误当成「用户既有对象」而漏记（失败案例库 D6 的直接教训）。
#   ③ 不覆盖、不接管：对象已存在但非本套件创建时只报告，绝不修改。
#   ④ 零新增运行时依赖：只用 bash 3.2 / git / gh / jq 与 POSIX 自带命令（awk/sed/cmp/mktemp）。
#      兼容性铁律：不用 mapfile/readarray/declare -A/${var,,}；变量后紧跟中文必须写 ${VAR}。
#
# 退出码：0 无漂移（--dry-run/--check）或安装成功（--apply）；1 存在漂移/冲突；2 参数或环境错误
set -eu

KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${KIT_DIR}/.." && pwd)"
MANIFEST=""            # 未显式指定时，参数解析完再按 KIT_DIR 推导
MODE="dry-run"          # dry-run | check | apply

log()  { printf '%s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
ok()   { printf '[ OK ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { local m="${1:-}"; local c="${2:-2}"; printf '[FAIL] %s\n' "$m" >&2; exit "$c"; }

usage() { sed -n '2,37p' "$0"; }

REPO_OPT=""; BRANCH_OPT=""; OWNER_OPT=""; AUTHOR_OPT=""; REVIEWER_OPT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) MODE="dry-run" ;;
    --check)   MODE="check" ;;
    --apply)   MODE="apply" ;;
    --repo)            REPO_OPT="${2:?--repo 需要取值}"; shift ;;
    --default-branch)  BRANCH_OPT="${2:?--default-branch 需要取值}"; shift ;;
    --owner)           OWNER_OPT="${2:?--owner 需要取值}"; shift ;;
    --author-account)  AUTHOR_OPT="${2:?--author-account 需要取值}"; shift ;;
    --reviewer-account) REVIEWER_OPT="${2:?--reviewer-account 需要取值}"; shift ;;
    --root)            ROOT="${2:?--root 需要取值}"; shift ;;
    --kit-dir)         KIT_DIR="${2:?--kit-dir 需要取值}"; shift ;;
    --manifest)        MANIFEST="${2:?--manifest 需要取值}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：${1}（见 --help）" ;;
  esac
  shift
done

for c in gh jq awk sed cmp mktemp comm cut sort tr diff date; do
  command -v "$c" >/dev/null 2>&1 || die "缺少命令 ${c}（本套件只依赖 bash/git/gh/jq 与 POSIX 自带命令）"
done
[ -n "$MANIFEST" ] || MANIFEST="${KIT_DIR}/manifest.json"
[ -f "$MANIFEST" ] || die "找不到归属清单 ${MANIFEST}（用 --manifest 指定）"
jq -e '.objects' "$MANIFEST" >/dev/null 2>&1 || die "归属清单不是合法 JSON 或缺少 objects 段：${MANIFEST}"

# ── 临时区 ────────────────────────────────────────────────────
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/toolkit-install.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM
DRIFT_FILE="${TMP_DIR}/drift.txt"
CREATED_FILE="${TMP_DIR}/created.txt"
: > "$DRIFT_FILE"; : > "$CREATED_FILE"

N_CREATE=0; N_UPDATE=0; N_OK=0; N_SKIP=0; N_DRIFT=0; N_CONFLICT=0; N_FAIL=0
drift() { N_DRIFT=$((N_DRIFT + 1)); printf '%s\n' "$*" >> "$DRIFT_FILE"; }
pline() { printf '  %s %s %s\n' "$1" "$2" "$3"; }

# ── 参数解析：全部可参数化，脚本内不出现任何具体仓库名/账号 ──────────
REPO="${REPO_OPT:-${REPO:-}}"
if [ -z "$REPO" ]; then
  REPO="$(cd "$ROOT" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
fi
[ -n "$REPO" ] || die "无法确定目标仓库：请在仓库内运行，或用 --repo OWNER/NAME / REPO=... 指定"

DEFAULT_BRANCH="${BRANCH_OPT:-${DEFAULT_BRANCH:-}}"
if [ -z "$DEFAULT_BRANCH" ]; then
  # 陷阱：gh repo view 没有 -R 旗标（仓库名是位置参数），写 -R 会报 unknown shorthand flag
  DEFAULT_BRANCH="$(gh repo view "$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name // ""' 2>/dev/null || true)"
fi
[ -n "$DEFAULT_BRANCH" ] || die "无法确定默认分支：请用 --default-branch NAME 指定"

OWNER="${OWNER_OPT:-${OWNER:-}}"
[ -n "$OWNER" ] || OWNER="${REPO%%/*}"

# 身份账号：优先显式参数 → 环境变量 → 读凭据文件对应身份（绝不打印凭据内容）
identity_from_pat() {
  local f="$1"
  [ -s "$f" ] || return 1
  ( GH_TOKEN="$(cat "$f")"; export GH_TOKEN; gh api user --jq .login 2>/dev/null ) || return 1
}
AUTHOR_PAT="${DEVELOPER_PAT_FILE:-${ROOT}/.secrets/developer.pat}"
REVIEWER_PAT="${REVIEWER_PAT_FILE:-${ROOT}/.secrets/reviewer.pat}"
AUTHOR_ACCOUNT="${AUTHOR_OPT:-${AUTHOR_ACCOUNT:-}}"
if [ -z "$AUTHOR_ACCOUNT" ]; then AUTHOR_ACCOUNT="$(identity_from_pat "$AUTHOR_PAT" || true)"; fi
[ -n "$AUTHOR_ACCOUNT" ] || die "无法确定作者账号：用 --author-account 指定，或提供凭据 ${AUTHOR_PAT}"
REVIEWER_ACCOUNT="${REVIEWER_OPT:-${REVIEWER_ACCOUNT:-}}"
if [ -z "$REVIEWER_ACCOUNT" ]; then REVIEWER_ACCOUNT="$(identity_from_pat "$REVIEWER_PAT" || true)"; fi
[ -n "$REVIEWER_ACCOUNT" ] || die "无法确定评审账号：用 --reviewer-account 指定，或提供凭据 ${REVIEWER_PAT}"

# ── 占位符替换（@@NAME@@）─────────────────────────────────────
# 注意：渲染必须走 sed 流，不能用 "$(cat ...)" —— 命令替换会吃掉文件末尾换行，
# 会让"渲染结果"与仓库内文件永久差一个换行（本地实测踩到）。
# 两类账号占位符：@@OWNER@@/@@REVIEWER_ACCOUNT@@ = 裸登录名；@@OWNER_MENTION@@/@@REVIEWER_MENTION@@ = @登录名
render_stream() {
  sed -E \
    -e "s|@@OWNER_MENTION@@|@${OWNER}|g" \
    -e "s|@@REVIEWER_MENTION@@|@${REVIEWER_ACCOUNT}|g" \
    -e "s|@@REPO@@|${REPO}|g" \
    -e "s|@@DEFAULT_BRANCH@@|${DEFAULT_BRANCH}|g" \
    -e "s|@@OWNER@@|${OWNER}|g" \
    -e "s|@@AUTHOR_ACCOUNT@@|${AUTHOR_ACCOUNT}|g" \
    -e "s|@@REVIEWER_ACCOUNT@@|${REVIEWER_ACCOUNT}|g" "$1"
}
render_str() { printf '%s' "$1" | render_stream /dev/stdin; }
render_to() {
  if [ "$3" = "true" ]; then render_stream "$1" > "$2"; else cp "$1" "$2"; fi
}
jget() { printf '%s' "$1" | jq -r "$2"; }

# ── 归属记账（manifest.json 的 ledger 段）───────────────────────
ledger_owned() {
  [ "$(jq -r --arg id "$1" '((.ledger[$id] // {}).owned // false) or (((.ledger[$id] // {}).intent // "") == "create")' "$MANIFEST")" = "true" ]
}
# 写前落账：先登记 create 意图，再执行；即使命令报错/进程中断，下次运行仍能正确归属（D6）
ledger_mark_intent() {
  local tmp
  tmp="$(mktemp "${TMP_DIR}/mf.XXXXXX")"
  jq --arg id "$1" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     '.ledger[$id] = {phase:"planned", intent:"create", observed:"unknown", owned:false, pre_existing:false, recorded_at:$ts}' \
     "$MANIFEST" > "$tmp" && mv "$tmp" "$MANIFEST"
}

# ── 线上实况探测（每次运行都重新读，绝不信任上一次的记账）──────────
probe_labels() {
  gh label list -R "$REPO" -L 200 --json name,color,description \
    --jq '.[] | "\(.name)\t\(.color|ascii_downcase)\t\(.description)"' > "${TMP_DIR}/live_labels.tsv" 2>/dev/null || : > "${TMP_DIR}/live_labels.tsv"
}
probe_collaborators() {
  gh api "repos/${REPO}/collaborators?per_page=100" \
    --jq '.[] | "\(.login)\t\(.permissions.push)"' > "${TMP_DIR}/live_collab.tsv" 2>/dev/null || : > "${TMP_DIR}/live_collab.tsv"
}
probe_ruleset_ids() {
  gh api "repos/${REPO}/rulesets" --jq '.[] | "\(.name)\t\(.id)"' > "${TMP_DIR}/live_rulesets.tsv" 2>/dev/null || : > "${TMP_DIR}/live_rulesets.tsv"
}
ruleset_id_by_name() { awk -F '\t' -v n="$1" '$1 == n { print $2; exit }' "${TMP_DIR}/live_rulesets.tsv"; }
ruleset_fetch() { gh api "repos/${REPO}/rulesets/$1" 2>/dev/null; }
# 写入线上前先剥掉仅供本地阅读的 _comment* 字段（GitHub API 不接受未知字段）
ruleset_body() {  # $1 = payload 文件 → 输出可提交的 JSON
  jq 'with_entries(select(.key | startswith("_") | not))' "$1"
}

# 规则集语义比对：期望的参数必须与线上一致；线上多出的字段/规则只报告（平台默认值会多出字段）
ruleset_diff() {
  jq -r -n --slurpfile W "$1" --slurpfile L "$2" '
    ($W[0]) as $w | ($L[0]) as $l |
    ( if $w.name != $l.name then "name|\($w.name)|\($l.name)" else empty end ),
    ( if $w.target != $l.target then "target|\($w.target)|\($l.target)" else empty end ),
    ( if $w.enforcement != $l.enforcement then "enforcement|\($w.enforcement)|\($l.enforcement)" else empty end ),
    ( if (($w.conditions.ref_name.include // [])|sort|join(",")) != (($l.conditions.ref_name.include // [])|sort|join(","))
      then "ref_include|\(($w.conditions.ref_name.include // [])|sort|join(","))|\(($l.conditions.ref_name.include // [])|sort|join(","))" else empty end ),
    ( if (($w.bypass_actors // [])|length) != (($l.bypass_actors // [])|length)
      then "bypass|\(($w.bypass_actors // [])|length)|\(($l.bypass_actors // [])|length)" else empty end ),
    ( $w.rules[] | .type as $t |
        ( if ([ $l.rules[] | select(.type == $t) ] | length) == 0 then "rule_missing|\($t)|" else empty end ) ),
    ( $w.rules[] | select(.type != "required_status_checks") | .type as $t | (.parameters // {}) | to_entries[] |
        .key as $k | .value as $v |
        ( [ $l.rules[] | select(.type == $t) ] | .[0].parameters[$k] ) as $lv |
        ( if ($lv != $v) then "param|\($t).\($k)|期望 \($v|tojson) / 实际 \($lv|tojson)" else empty end ) ),
    ( $l.rules[] | select(.type != "required_status_checks") | .type as $t | (.parameters // {}) | to_entries[] |
        .key as $k |
        ( if ((([ $w.rules[] | select(.type == $t) ] | .[0].parameters) // {}) | has($k)) then empty
          else "extra_param|\($t).\($k)|线上多出（平台默认值，仅报告）" end ) ),
    ( $w.rules[] | select(.type == "required_status_checks") |
        ( [.parameters.required_status_checks[].context] | sort | join(",") ) as $wc |
        ( [ $l.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context ] | sort | join(",") ) as $lc |
        ( if $wc != $lc then "contexts|\($wc)|\($lc)" else empty end ) ),
    ( $l.rules[] | .type as $t |
        ( if ([ $w.rules[] | select(.type == $t) ] | length) == 0 then "extra_rule|\($t)|线上多出（非本套件声明，仅报告）" else empty end ) )
  '
}

# ── ① 文件 ────────────────────────────────────────────────────
decide_files() {
  local entry="$1" id path src tpl target want act
  id="$(jget "$entry" '.id')"; path="$(jget "$entry" '.path')"
  src="$(jget "$entry" '.source')"; tpl="$(jget "$entry" '.template // false')"
  target="${ROOT}/${path}"; want="${TMP_DIR}/want.file"
  if [ ! -f "${KIT_DIR}/${src}" ]; then
    N_FAIL=$((N_FAIL + 1)); drift "清单损坏 ${id}：payload 缺失 ${src}"; pline "[失败]" "payload缺失" "$id"; return 0
  fi
  render_to "${KIT_DIR}/${src}" "$want" "$tpl"
  if [ ! -f "$target" ]; then
    act="create"
  elif cmp -s "$want" "$target"; then
    act="ok"
  elif ledger_owned "$id"; then
    act="update"
  else
    act="conflict"
  fi
  case "$act" in
    create)
      if [ "$MODE" = "check" ]; then
        drift "文件缺失 ${path}（manifest 期望存在）"; pline "[漂移]" "缺失" "$path"
      else
        N_CREATE=$((N_CREATE + 1)); pline "[${MODE}]" "创建" "${path}  ← ${src}"
        if [ "$MODE" = "apply" ]; then
          ledger_mark_intent "$id"
          mkdir -p "$(dirname "$target")"
          if cp "$want" "$target" && cmp -s "$want" "$target"; then
            printf '%s\n' "$id" >> "$CREATED_FILE"
          else
            N_FAIL=$((N_FAIL + 1)); drift "写入失败 ${path}"
          fi
        fi
      fi ;;
    update)
      if [ "$MODE" = "check" ]; then
        drift "文件漂移 ${path}（本套件所有，内容与期望不一致）"; pline "[漂移]" "内容不一致" "$path"
      else
        N_UPDATE=$((N_UPDATE + 1)); pline "[${MODE}]" "更新" "${path}（本套件所有）"
        if [ "$MODE" = "apply" ]; then
          if cp "$want" "$target"; then :; else N_FAIL=$((N_FAIL + 1)); drift "写入失败 ${path}"; fi
        fi
      fi ;;
    ok) N_OK=$((N_OK + 1)); pline "[ OK ]" "已存在且一致" "$path" ;;
    conflict)
      N_CONFLICT=$((N_CONFLICT + 1))
      drift "文件冲突 ${path}：已存在、非本套件创建、内容与期望不一致 → 不覆盖、不接管"
      pline "[冲突]" "不覆盖" "${path}（非本套件创建，仅报告）" ;;
  esac
}

# ── ② 标签 ────────────────────────────────────────────────────
parse_label_source() {  # $1 = labels.yml → TSV(name color description)
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
  ' "$1"
}
label_want() { awk -F '\t' -v n="$1" '$1 == n { print tolower($2) "\t" $3; exit }' "${TMP_DIR}/want_labels.tsv"; }

decide_labels() {
  local entry id name lv rcolor rdesc wcolor wdesc act
  entry="$1"; id="$(jget "$entry" '.id')"; name="$(jget "$entry" '.name')"
  lv="$(awk -F '\t' -v n="$name" '$1 == n { print $2 "\t" $3; exit }' "${TMP_DIR}/live_labels.tsv")"
  if [ -z "$lv" ]; then
    act="create"
  else
    wcolor="$(label_want "$name" | cut -f1)"; wdesc="$(label_want "$name" | cut -f2)"
    rcolor="$(printf '%s' "$lv" | cut -f1)"; rdesc="$(printf '%s' "$lv" | cut -f2)"
    if [ "$rcolor" = "$wcolor" ] && [ "$rdesc" = "$wdesc" ]; then act="ok"
    elif ledger_owned "$id"; then act="update"
    else act="conflict"; fi
  fi
  case "$act" in
    create)
      if [ -z "$(label_want "$name")" ]; then
        N_FAIL=$((N_FAIL + 1)); drift "清单损坏 ${id}：payload 里没有该标签定义"; pline "[失败]" "payload缺失" "$id"; return 0
      fi
      wcolor="$(label_want "$name" | cut -f1)"; wdesc="$(label_want "$name" | cut -f2)"
      if [ "$MODE" = "check" ]; then
        drift "标签缺失 ${name}（manifest 期望存在）"; pline "[漂移]" "缺失" "label ${name}"
      else
        N_CREATE=$((N_CREATE + 1)); pline "[${MODE}]" "创建" "label ${name}（${wcolor}）"
        if [ "$MODE" = "apply" ]; then
          ledger_mark_intent "$id"
          if gh label create "$name" --color "$wcolor" --description "$wdesc" -R "$REPO" >/dev/null 2>&1; then
            printf '%s\n' "$id" >> "$CREATED_FILE"
          else
            N_FAIL=$((N_FAIL + 1)); drift "标签创建失败 ${name}（可能是并发创建；下次运行会先读线上实况再决定）"
          fi
        fi
      fi ;;
    update)
      wcolor="$(label_want "$name" | cut -f1)"; wdesc="$(label_want "$name" | cut -f2)"
      if [ "$MODE" = "check" ]; then
        drift "标签漂移 ${name}（本套件所有，颜色/描述与期望不一致）"; pline "[漂移]" "内容不一致" "label ${name}"
      else
        N_UPDATE=$((N_UPDATE + 1)); pline "[${MODE}]" "更新" "label ${name}"
        if [ "$MODE" = "apply" ]; then
          gh label edit "$name" --color "$wcolor" --description "$wdesc" -R "$REPO" >/dev/null 2>&1 \
            || { N_FAIL=$((N_FAIL + 1)); drift "标签更新失败 ${name}"; }
        fi
      fi ;;
    ok) N_OK=$((N_OK + 1)); pline "[ OK ]" "已存在且一致" "label ${name}" ;;
    conflict)
      N_CONFLICT=$((N_CONFLICT + 1))
      drift "标签冲突 ${name}：已存在、非本套件创建、颜色/描述与期望不一致 → 不覆盖、不接管"
      pline "[冲突]" "不覆盖" "label ${name}（非本套件创建，仅报告）" ;;
  esac
}

# ── ③ 规则集 ──────────────────────────────────────────────────
decide_rulesets() {
  local entry id name src want rid live dline key wantv livev act
  entry="$1"; id="$(jget "$entry" '.id')"; name="$(jget "$entry" '.name')"; src="$(jget "$entry" '.source')"
  if [ ! -f "${KIT_DIR}/${src}" ]; then
    N_FAIL=$((N_FAIL + 1)); drift "清单损坏 ${id}：payload 缺失 ${src}"; pline "[失败]" "payload缺失" "$id"; return 0
  fi
  rid="$(ruleset_id_by_name "$name")"
  if [ -z "$rid" ]; then
    if [ "$MODE" = "check" ]; then
      drift "规则集缺失 ${name}（manifest 期望存在，缺它则门禁未生效）"; pline "[漂移]" "缺失" "ruleset ${name}"
    else
      N_CREATE=$((N_CREATE + 1)); pline "[${MODE}]" "创建" "ruleset ${name} ← ${src}"
      if [ "$MODE" = "apply" ]; then
        ledger_mark_intent "$id"
        ruleset_body "${KIT_DIR}/${src}" > "${TMP_DIR}/ruleset_new.json"
        if gh api -X POST "repos/${REPO}/rulesets" --input "${TMP_DIR}/ruleset_new.json" >/dev/null 2>&1; then
          printf '%s\n' "$id" >> "$CREATED_FILE"
        else
          N_FAIL=$((N_FAIL + 1)); drift "规则集创建失败 ${name}（需要 admin 权限；创建规则集属高风险操作，见 docs/PLAYBOOK.md §9）"
        fi
      fi
    fi
    return 0
  fi
  want="${TMP_DIR}/want.ruleset.json"; live="${TMP_DIR}/live.ruleset.json"
  cp "${KIT_DIR}/${src}" "$want"; ruleset_fetch "$rid" > "$live"
  if [ ! -s "$live" ]; then
    N_FAIL=$((N_FAIL + 1)); drift "无法读取线上规则集 ${name}（id=${rid}）"; pline "[失败]" "读取失败" "ruleset ${name}"; return 0
  fi
  act="ok"
  while IFS='|' read -r key wantv livev; do
    [ -n "$key" ] || continue
    case "$key" in
      extra_rule|extra_param) pline "[INFO]" "线上多出" "ruleset ${name}: ${wantv}（${livev}）" ;;
      name|target|enforcement|ref_include|bypass|contexts|param|rule_missing) act="drift" ;;
    esac
  done <<EOF
$(ruleset_diff "$want" "$live")
EOF
  if [ "$act" = "ok" ]; then
    N_OK=$((N_OK + 1)); pline "[ OK ]" "已存在且一致" "ruleset ${name}（id=${rid}）"
    return 0
  fi
  if ledger_owned "$id"; then
    if [ "$MODE" = "check" ]; then
      drift "规则集漂移 ${name}（本套件所有）"; pline "[漂移]" "参数不一致" "ruleset ${name}"
    else
      N_UPDATE=$((N_UPDATE + 1)); pline "[${MODE}]" "更新" "ruleset ${name}"
      if [ "$MODE" = "apply" ]; then
        ruleset_body "$want" > "${TMP_DIR}/ruleset_upd.json"
        gh api -X PUT "repos/${REPO}/rulesets/${rid}" --input "${TMP_DIR}/ruleset_upd.json" >/dev/null 2>&1 \
          || { N_FAIL=$((N_FAIL + 1)); drift "规则集更新失败 ${name}"; }
      fi
    fi
  else
    N_CONFLICT=$((N_CONFLICT + 1))
    drift "规则集冲突 ${name}：已存在、非本套件创建、参数与期望不一致 → 不覆盖、不接管"
    pline "[冲突]" "不覆盖" "ruleset ${name}（非本套件创建，仅报告）"
    while IFS='|' read -r key wantv livev; do
      [ -n "$key" ] || continue
      case "$key" in extra_rule|extra_param) continue ;; esac
      pline "[冲突]" "$key" "期望 ${wantv} / 实际 ${livev}"
    done <<EOF
$(ruleset_diff "$want" "$live")
EOF
  fi
}

# ── ④ workflow ────────────────────────────────────────────────
decide_workflows() {
  local entry id path src tpl target want wf_file act missing c
  entry="$1"; id="$(jget "$entry" '.id')"; path="$(jget "$entry" '.path')"
  src="$(jget "$entry" '.source')"; tpl="$(jget "$entry" '.template // false')"
  target="${ROOT}/${path}"; want="${TMP_DIR}/want.wf"
  if [ ! -f "${KIT_DIR}/${src}" ]; then
    N_FAIL=$((N_FAIL + 1)); drift "清单损坏 ${id}：payload 缺失 ${src}"; pline "[失败]" "payload缺失" "$id"; return 0
  fi
  render_to "${KIT_DIR}/${src}" "$want" "$tpl"
  if [ ! -f "$target" ]; then act="create"
  elif cmp -s "$want" "$target"; then act="ok"
  elif ledger_owned "$id"; then act="update"
  else act="conflict"; fi
  case "$act" in
    create)
      if [ "$MODE" = "check" ]; then
        drift "工作流缺失 ${path}"; pline "[漂移]" "缺失" "$path"
      else
        N_CREATE=$((N_CREATE + 1)); pline "[${MODE}]" "创建" "${path}  ← ${src}"
        if [ "$MODE" = "apply" ]; then
          ledger_mark_intent "$id"
          mkdir -p "$(dirname "$target")"
          if cp "$want" "$target" && cmp -s "$want" "$target"; then printf '%s\n' "$id" >> "$CREATED_FILE"
          else N_FAIL=$((N_FAIL + 1)); drift "写入失败 ${path}"; fi
        fi
      fi ;;
    update)
      if [ "$MODE" = "check" ]; then
        drift "工作流漂移 ${path}（本套件所有）"; pline "[漂移]" "内容不一致" "$path"
      else
        N_UPDATE=$((N_UPDATE + 1)); pline "[${MODE}]" "更新" "${path}（本套件所有）"
        if [ "$MODE" = "apply" ]; then
          cp "$want" "$target" || { N_FAIL=$((N_FAIL + 1)); drift "写入失败 ${path}"; }
        fi
      fi ;;
    ok) N_OK=$((N_OK + 1)); pline "[ OK ]" "已存在且一致" "$path" ;;
    conflict)
      N_CONFLICT=$((N_CONFLICT + 1))
      drift "工作流冲突 ${path}：已存在、非本套件创建、内容与期望不一致 → 不覆盖、不接管"
      pline "[冲突]" "不覆盖" "${path}（非本套件创建，仅报告）" ;;
  esac
  # 检查名核验：manifest 声明的每个检查名都必须能在文件里找到同名 job，否则该必需检查永久 pending
  if [ -f "$target" ]; then wf_file="$target"; else wf_file="$want"; fi
  missing=""
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    grep -qE "^[[:space:]]+name:[[:space:]]+${c}[[:space:]]*$" "$wf_file" || missing="${missing} ${c}"
  done <<EOF
$(jget "$entry" '.checks[]?')
EOF
  if [ -n "$missing" ]; then
    N_FAIL=$((N_FAIL + 1))
    drift "工作流 ${path} 缺少 job 名（会导致对应必需检查永久 pending）：${missing}"
    pline "[漂移]" "检查名缺失" "${path}:${missing}"
  fi
}

# ── ⑤ CODEOWNERS 行 ───────────────────────────────────────────
normalize_co() { sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' "$1" | grep -vE '^[[:space:]]*(#|$)' || true; }

decide_codeowners() {
  local entry id path pattern owners owned_line found act f
  entry="$1"; id="$(jget "$entry" '.id')"; path="$(jget "$entry" '.path')"
  pattern="$(jget "$entry" '.pattern')"
  owners="$(jget "$entry" '.owners | join(" ")')"
  owned_line="$(render_str "${pattern} ${owners}" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
  f="${ROOT}/${path}"
  found="no"
  if [ -f "$f" ]; then
    if normalize_co "$f" | grep -Fxq -- "$owned_line"; then found="yes"; fi
  fi
  if [ "$found" = "yes" ]; then
    N_OK=$((N_OK + 1)); pline "[ OK ]" "已存在" "CODEOWNERS ${owned_line}"
    return 0
  fi
  if [ "$MODE" = "check" ]; then
    drift "CODEOWNERS 行缺失：${owned_line}（缺它则 ${pattern} 的改动没有独立 owner，require_code_owner_review 会死锁）"
    pline "[漂移]" "缺失" "CODEOWNERS ${owned_line}"
    return 0
  fi
  N_CREATE=$((N_CREATE + 1)); pline "[${MODE}]" "追加" "CODEOWNERS ${owned_line}"
  if [ "$MODE" = "apply" ]; then
    ledger_mark_intent "$id"
    if [ ! -f "$f" ]; then printf '# CODEOWNERS —— 由治理套件写入（归属见 toolkit/manifest.json）\n\n' > "$f"; fi
    if printf '%s\n' "$owned_line" >> "$f"; then printf '%s\n' "$id" >> "$CREATED_FILE"
    else N_FAIL=$((N_FAIL + 1)); drift "CODEOWNERS 写入失败：${owned_line}"; fi
  fi
}

# ── ⑥ 协作者 ──────────────────────────────────────────────────
decide_collaborators() {
  local entry id account perm role role_suffix lv act
  entry="$1"; id="$(render_str "$(jget "$entry" '.id')")"
  account="$(render_str "$(jget "$entry" '.account')")"
  perm="$(jget "$entry" '.permission')"; role="$(jget "$entry" '.role // ""')"
  role_suffix=""; if [ -n "$role" ]; then role_suffix="，${role}"; fi
  lv="$(awk -F '\t' -v a="$account" '$1 == a { print $2; exit }' "${TMP_DIR}/live_collab.tsv")"
  if [ -z "$lv" ]; then act="create"
  elif [ "$lv" = "true" ]; then act="ok"
  elif ledger_owned "$id"; then act="update"
  else act="conflict"; fi
  case "$act" in
    create)
      if [ "$MODE" = "check" ]; then
        drift "协作者缺失 ${account}（manifest 期望有 ${perm} 权限；缺它则独立评审链路不可用）"
        pline "[漂移]" "缺失" "collaborator ${account}"
      else
        N_CREATE=$((N_CREATE + 1)); pline "[${MODE}]" "邀请" "collaborator ${account}（permission=${perm}${role_suffix}）"
        if [ "$MODE" = "apply" ]; then
          ledger_mark_intent "$id"
          if gh api -X PUT "repos/${REPO}/collaborators/${account}" -f permission="$perm" >/dev/null 2>&1; then
            printf '%s\n' "$id" >> "$CREATED_FILE"
            pline "[INFO]" "需接受邀请" "${account} 需以该账号接受协作邀请（见 docs/PLAYBOOK.md W0.4 第 5 步）"
          else
            N_FAIL=$((N_FAIL + 1)); drift "协作者邀请失败 ${account}（需要 admin 权限）"
          fi
        fi
      fi ;;
    update)
      if [ "$MODE" = "check" ]; then
        drift "协作者权限漂移 ${account}（本套件添加，期望 push=true）"; pline "[漂移]" "权限不一致" "collaborator ${account}"
      else
        N_UPDATE=$((N_UPDATE + 1)); pline "[${MODE}]" "更新权限" "collaborator ${account}"
        gh api -X PUT "repos/${REPO}/collaborators/${account}" -f permission="$perm" >/dev/null 2>&1 \
          || { N_FAIL=$((N_FAIL + 1)); drift "协作者权限更新失败 ${account}"; }
      fi ;;
    ok) N_OK=$((N_OK + 1)); pline "[ OK ]" "已存在且一致" "collaborator ${account}（push=${lv}）" ;;
    conflict)
      N_CONFLICT=$((N_CONFLICT + 1))
      drift "协作者冲突 ${account}：已存在但权限不满足期望，且非本套件创建 → 不改动、仅报告"
      pline "[冲突]" "不接管" "collaborator ${account}（非本套件创建，仅报告）" ;;
  esac
}

# ── 收尾：回读线上实况并把归属写进 ledger（仅 --apply）────────────
finalize_ledger() {
  probe_labels; probe_collaborators; probe_ruleset_ids
  local ops="${TMP_DIR}/ledger_ops.jsonl" created_box="${TMP_DIR}/created_box.txt"
  : > "$ops"; sort -u "$CREATED_FILE" > "$created_box" 2>/dev/null || : > "$created_box"
  local class entry id path name account pattern owners own_line
  for class in files labels rulesets workflows codeowners collaborators; do
    jq -c ".objects.${class}.entries[]" "$MANIFEST" > "${TMP_DIR}/fin_${class}.txt"
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      id="$(render_str "$(jget "$entry" '.id')")"
      case "$class" in
        files|workflows)
          path="$(jget "$entry" '.path')"
          if [ -f "${ROOT}/${path}" ]; then present="present"; else present="absent"; fi ;;
        labels)
          name="$(jget "$entry" '.name')"
          if awk -F '\t' -v n="$name" '$1 == n { found=1 } END { exit !found }' "${TMP_DIR}/live_labels.tsv"; then present="present"; else present="absent"; fi ;;
        rulesets)
          name="$(jget "$entry" '.name')"
          if [ -n "$(ruleset_id_by_name "$name")" ]; then present="present"; else present="absent"; fi ;;
        codeowners)
          pattern="$(jget "$entry" '.pattern')"; owners="$(jget "$entry" '.owners | join(" ")')"
          own_line="$(render_str "${pattern} ${owners}" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
          if [ -f "${ROOT}/$(jget "$entry" '.path')" ] && normalize_co "${ROOT}/$(jget "$entry" '.path')" | grep -Fxq -- "$own_line"; then present="present"; else present="absent"; fi ;;
        collaborators)
          account="$(render_str "$(jget "$entry" '.account')")"
          if awk -F '\t' -v a="$account" '$1 == a { found=1 } END { exit !found }' "${TMP_DIR}/live_collab.tsv"; then present="present"; else present="absent"; fi ;;
      esac
      owned="false"; pre="false"
      if [ "$present" = "present" ]; then
        if grep -Fxq -- "$id" "$created_box" || ledger_owned "$id"; then owned="true"; else pre="true"; fi
      fi
      if [ "$present" = "present" ]; then phase="owned"; [ "$owned" = "true" ] || phase="pre-existing"; else phase="absent"; fi
      jq -c -n --arg id "$id" --arg phase "$phase" --arg observed "$present" \
         --argjson owned "$owned" --argjson pre "$pre" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
         '{id:$id, v:{phase:$phase, observed:$observed, owned:$owned, pre_existing:$pre, recorded_at:$ts}}' >> "$ops"
    done < "${TMP_DIR}/fin_${class}.txt"
  done
  # 已登记 create 意图但本次回读仍不存在 → 保留 intent=create，供下次运行正确归属（D6）
  local tmp
  tmp="$(mktemp "${TMP_DIR}/mf.XXXXXX")"
  jq --slurpfile ops "$ops" '
    reduce $ops[] as $o (.;
      .ledger[$o.id] =
        ( if ($o.v.observed == "absent") and (((.ledger[$o.id] // {}).intent // "") == "create")
          then ($o.v + {phase:"failed", intent:"create"})
          else $o.v end ))
  ' "$MANIFEST" > "$tmp" && mv "$tmp" "$MANIFEST"
}

# ── 主流程 ────────────────────────────────────────────────────
log "治理套件 install —— 模式：${MODE}"
log "  套件目录：${KIT_DIR}"
log "  目标仓库：${REPO}（默认分支 ${DEFAULT_BRANCH}，owner ${OWNER}）"
log "  目标根目录：${ROOT}"
log "  身份：作者 ${AUTHOR_ACCOUNT} / 评审 ${REVIEWER_ACCOUNT}"
log ""

info "读取线上实况（每次运行都重新读，不用记账代替观测）"
probe_labels; probe_collaborators; probe_ruleset_ids
ok "标签 ${TMP_DIR}/live_labels.tsv：$(wc -l < "${TMP_DIR}/live_labels.tsv" | tr -d ' ') 条线上标签（仅比对 manifest 登记项）"
ok "协作者：$(wc -l < "${TMP_DIR}/live_collab.tsv" | tr -d ' ') 个；规则集：$(wc -l < "${TMP_DIR}/live_rulesets.tsv" | tr -d ' ') 个"

# 标签：payload 与 manifest 登记项必须一致（不一致 = 清单损坏）
if [ -f "${KIT_DIR}/$(jq -r '.objects.labels.source' "$MANIFEST")" ]; then
  parse_label_source "${KIT_DIR}/$(jq -r '.objects.labels.source' "$MANIFEST")" > "${TMP_DIR}/want_labels.tsv"
  jq -r '.objects.labels.entries[].name' "$MANIFEST" | sort > "${TMP_DIR}/mf_labels.txt"
  cut -f1 "${TMP_DIR}/want_labels.tsv" | sort > "${TMP_DIR}/src_labels.txt"
  if ! cmp -s "${TMP_DIR}/mf_labels.txt" "${TMP_DIR}/src_labels.txt"; then
    N_FAIL=$((N_FAIL + 1))
    drift "manifest 登记的标签与 payload 不一致（差异见下）—— 清单是唯一归属依据，必须保持同步"
    diff "${TMP_DIR}/mf_labels.txt" "${TMP_DIR}/src_labels.txt" >&2 || true
  fi
fi

for class in files labels rulesets workflows codeowners collaborators; do
  count="$(jq ".objects.${class}.entries | length" "$MANIFEST")"
  log ""
  info "受管对象：${class}（${count} 个）"
  jq -c ".objects.${class}.entries[]" "$MANIFEST" > "${TMP_DIR}/entries.txt"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$class" in
      files)         decide_files "$entry" ;;
      labels)        decide_labels "$entry" ;;
      rulesets)      decide_rulesets "$entry" ;;
      workflows)     decide_workflows "$entry" ;;
      codeowners)    decide_codeowners "$entry" ;;
      collaborators) decide_collaborators "$entry" ;;
    esac
  done < "${TMP_DIR}/entries.txt"
done

# 规则集必需检查 ⊆ 工作流产生的检查名（否则必需检查永久 pending）
log ""
info "交叉校验：规则集必需检查 ⇄ 工作流 job 名"
jq -r '.objects.rulesets.entries[]?.source' "$MANIFEST" > "${TMP_DIR}/rs_sources.txt"
: > "${TMP_DIR}/req_ctx.txt"
while IFS= read -r s; do
  [ -n "$s" ] || continue
  [ -f "${KIT_DIR}/${s}" ] || continue
  jq -r '.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context' "${KIT_DIR}/${s}" >> "${TMP_DIR}/req_ctx.txt"
done < "${TMP_DIR}/rs_sources.txt"
jq -r '.objects.workflows.entries[]?.checks[]?' "$MANIFEST" | sort -u > "${TMP_DIR}/wf_checks.txt"
sort -u "${TMP_DIR}/req_ctx.txt" > "${TMP_DIR}/req_ctx_sorted.txt"
missing_ctx="$(comm -23 "${TMP_DIR}/req_ctx_sorted.txt" "${TMP_DIR}/wf_checks.txt" | tr '\n' ' ')"
if [ -n "$(printf '%s' "$missing_ctx" | tr -d ' ')" ]; then
  N_FAIL=$((N_FAIL + 1))
  drift "以下必需检查没有任何受管工作流会产生它（会让所有 PR 永久 pending）：${missing_ctx}"
  pline "[漂移]" "无对应 job" "${missing_ctx}"
else
  ok "规则集引用的必需检查全部有对应 job"
fi

# 归属记账
if [ "$MODE" = "apply" ]; then
  log ""
  info "回读线上实况并写入归属记账（ledger）"
  finalize_ledger
  ok "归属记账已更新：${MANIFEST}"
fi
ledger_total="$(jq -r '.ledger | to_entries | map(select(.key | startswith("_") | not)) | length' "$MANIFEST")"
ledger_owned_n="$(jq -r '.ledger | to_entries | map(select(.key | startswith("_") | not)) | map(select(.value.owned == true)) | length' "$MANIFEST")"
info "归属记账：已登记 ${ledger_total} 个对象（其中 owned=true 共 ${ledger_owned_n} 个）"

# ── 小结 ──────────────────────────────────────────────────────
log ""
info "小结（模式：${MODE}）"
log "  将创建/已创建：${N_CREATE}"
log "  将更新/已更新：${N_UPDATE}"
log "  已存在且一致：${N_OK}"
log "  冲突（非本套件创建，不覆盖不接管）：${N_CONFLICT}"
log "  失败：${N_FAIL}"
if [ "$N_DRIFT" -gt 0 ]; then
  log "  漂移：${N_DRIFT} 处"
  log ""
  log "  漂移明细："
  while IFS= read -r l; do printf '    - %s\n' "$l"; done < "$DRIFT_FILE"
fi
log ""
if [ "$MODE" = "dry-run" ]; then
  ok "dry-run 结束：零写入。若要真正安装请运行：$(basename "$0") --apply"
  exit 0
fi
if [ "$MODE" = "check" ]; then
  if [ "$N_DRIFT" -eq 0 ] && [ "$N_FAIL" -eq 0 ]; then
    ok "check 通过：线上实况与 manifest 期望一致（0 处漂移）"
    exit 0
  fi
  warn "check 未通过：${N_DRIFT} 处漂移 / ${N_FAIL} 处失败 —— 只报告，不自动修改"
  exit 1
fi
if [ "$N_CONFLICT" -gt 0 ]; then
  warn "存在 ${N_CONFLICT} 个非本套件创建的对象与期望不一致：已按「不覆盖、不接管」跳过，需要人工决定"
  exit 1
fi
if [ "$N_FAIL" -gt 0 ] || [ "$N_DRIFT" -gt 0 ]; then
  warn "安装未完全收敛：失败 ${N_FAIL} 处 / 漂移 ${N_DRIFT} 处（重跑会先读线上实况再决定，可安全重试）"
  exit 1
fi
ok "安装完成：本套件对象已就位，重复执行 install.sh 为 no-op"
