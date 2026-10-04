#!/usr/bin/env bash
# toolkit/install.sh —— 可移植治理套件安装器（E2-S-A：出厂声明 + 运行时账 + --dry-run / --check / --apply）
#
# 用法：
#   toolkit/install.sh --dry-run        # 默认模式。零写入，完整预告每个对象将被创建/更新/跳过
#   toolkit/install.sh --check          # 只读。比对「线上实况 vs kit.yaml 期望」，漂移只报告
#   toolkit/install.sh --apply          # 实际安装（幂等；重复执行是 no-op）
#
# 参数（全部可参数化；对应 toolkit/kit.yaml 的 parameters 段）：
#   --repo OWNER/NAME        目标仓库（默认：gh repo view）
#   --default-branch NAME    默认分支（默认：gh repo view 的 defaultBranchRef）
#   --owner ACCOUNT          仓库 owner / 主身份账号（默认：REPO 的 owner 部分）
#   --author-account ACCOUNT 作者身份账号（默认：读凭据文件 .secrets/developer.pat 的身份）
#   --reviewer-account ACCT  评审身份账号（默认：读凭据文件 .secrets/reviewer.pat 的身份）
#   --root DIR               目标仓库根目录（默认：本脚本所在目录的上一级）
#   --kit-dir DIR            套件目录（默认：本脚本所在目录）
#   --kit-yaml FILE          出厂声明（默认：<kit-dir>/kit.yaml）
#   --ledger FILE            运行时记账（默认：<root>/.git/governance-ledger.json，**不在版本库内**）
# 等价环境变量：REPO / DEFAULT_BRANCH / OWNER / AUTHOR_ACCOUNT / REVIEWER_ACCOUNT
#               DEVELOPER_PAT_FILE / REVIEWER_PAT_FILE / TOOLKIT_LEDGER
#
# 设计要点（Issue #69 / S-A；设计 #68 §2.1–§2.3）：
#   ① **声明与状态彻底分离**：
#        kit.yaml（出厂声明，进版本库、运行时只读、可审计可 diff）= 定义「管什么」
#        <root>/.git/governance-ledger.json（安装器事务账，**不进版本库**）= 记录「实际创建了什么」
#      收尾时断言 kit.yaml 逐字节未变（Bug #60 的护栏：状态混进分发物会弄红套件自带的 ci/test）。
#   ② 命名空间归属（P-5）：受管文件 .github/governance/**、workflow .github/workflows/governance-*.yml、
#      标签前缀 gov/、规则集前缀 governance-。豁免允许但必须逐条写理由，且由本脚本硬校验。
#   ③ 三态幂等 planned → observed → owned：
#        planned  = kit.yaml 里声明的期望（本脚本的输入）
#        observed = **本次运行现读的线上实况**（绝不用上一次运行的记账代替观测）
#        owned    = 本套件创建或明确接管（--apply 时**写前落账** intent=create，成功后回读确认）
#      重试语义：上一次命令报错、但对象其实已经创建 → 记账里留有 create 意图且实况存在
#      → 仍判 owned=true，不会被误当成「用户既有对象」而漏记（失败案例库 D6 的直接教训）。
#   ④ 冲突不接管：对象已存在但非本套件创建时只报告，绝不修改、绝不静默合并。
#   ⑤ NFR-17：绝不就地改写用户既有文件（CODEOWNERS 只给建议行，见 report_codeowners）。
#   ⑥ 零新增运行时依赖：只用 bash 3.2 / git / gh / jq / python3 与 POSIX 自带命令。
#      兼容性铁律：不用 mapfile/readarray/declare -A/${var,,}；变量后紧跟中文必须写 ${VAR}。
#
# 退出码：0 无漂移（--dry-run/--check）或安装成功（--apply）；1 存在漂移/冲突；2 参数或环境错误
set -eu

KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${KIT_DIR}/.." && pwd)"
KIT_YAML=""            # 出厂声明（kit.yaml）；未显式指定时按 KIT_DIR 推导
KIT_JSON=""            # 运行时由 kit.yaml 派生（lib.sh kit_load；不进版本库）
LEDGER=""              # 未显式指定时，参数解析完再按 ROOT 推导（见 toolkit/lib.sh ledger_default）
MODE="dry-run"          # dry-run | check | apply

die()  { local m="${1:-}"; local c="${2:-2}"; printf '[FAIL] %s\n' "$m" >&2; exit "$c"; }

# 公共 helper（log/info/ok/warn、占位符渲染、线上实况探测、规则集语义比对、
# 归属判定 ledger_owned 等）。**必须与 eject.sh 同源**：归属与漂移的判据若有第二份实现，
# 就会出现"install 认为 owned、eject 认为不是"的静默不一致（见 toolkit/lib.sh 头注释）。
# die 留在本脚本：install 的参数/环境错误用退出码 2，eject 用 1。
. "${KIT_DIR}/lib.sh"

usage() { sed -n '2,39p' "$0"; }

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
    --kit-yaml)        KIT_YAML="${2:?--kit-yaml 需要取值}"; shift ;;
    --ledger)          LEDGER="${2:?--ledger 需要取值}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：${1}（见 --help）" ;;
  esac
  shift
done

for c in gh jq awk sed cmp mktemp comm cut sort tr diff date find; do
  command -v "$c" >/dev/null 2>&1 || die "缺少命令 ${c}（本套件只依赖 bash/git/gh/jq 与 POSIX 自带命令）"
done
[ -n "$KIT_YAML" ] || KIT_YAML="${KIT_DIR}/kit.yaml"
[ -f "$KIT_YAML" ] || die "找不到出厂声明 ${KIT_YAML}（用 --kit-yaml 指定）"

# ── 临时区 ────────────────────────────────────────────────────
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/toolkit-install.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM
DRIFT_FILE="${TMP_DIR}/drift.txt"
CREATED_FILE="${TMP_DIR}/created.txt"
: > "$DRIFT_FILE"; : > "$CREATED_FILE"

# ── 声明 / 状态分离（Bug #60 / Issue #69 S-A）────────────────────
# ① 出厂声明：kit.yaml → KIT_JSON（运行时**只读**；收尾时逐字节断言未变）
kit_load
KIT_ROOT="${KIT_ROOT:-$(jq -r '.objects.kit.entries[0].path // ".github/governance/kit"' "$KIT_JSON")}"
KIT_GOVERNANCE_DIR="${KIT_GOVERNANCE_DIR:-$(ns_files)}"; KIT_GOVERNANCE_DIR="${KIT_GOVERNANCE_DIR%/}"
# payload 占位符的具体值（一处定义在 kit.yaml 的 placeholders 段；不变量 B 用同一张表解析）
RULESET_DECL_PATH="${RULESET_DECL_PATH:-$(jq -r '.placeholders.RULESET_DECL_PATH // ""' "$KIT_JSON")}"
CODEOWNERS_PATH="${CODEOWNERS_PATH:-$(jq -r '.placeholders.CODEOWNERS_PATH // ""' "$KIT_JSON")}"
WORKFLOWS_GLOB="${WORKFLOWS_GLOB:-$(jq -r '.placeholders.WORKFLOWS_GLOB // ""' "$KIT_JSON")}"
CODE_OWNER_IDS="${CODE_OWNER_IDS:-}"
# ② 运行时记账：默认 <root>/.git/governance-ledger.json（**版本库之外**，
#    硬理由：它必须活过 `git clean -fdx`，而 gitignore 方案下它会被直接清掉）
[ -n "$LEDGER" ] || LEDGER="${TOOLKIT_LEDGER:-}"
[ -n "$LEDGER" ] || LEDGER="$(ledger_default "$ROOT")"
# ③ 护栏：记账绝不能被 git 跟踪（一旦入库，真实账号与归属就进了分发物 —— Bug #60）
ledger_reject_if_tracked "$LEDGER"


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
# identity_from_pat 在 toolkit/lib.sh
AUTHOR_PAT="${DEVELOPER_PAT_FILE:-${ROOT}/.secrets/developer.pat}"
REVIEWER_PAT="${REVIEWER_PAT_FILE:-${ROOT}/.secrets/reviewer.pat}"
AUTHOR_ACCOUNT="${AUTHOR_OPT:-${AUTHOR_ACCOUNT:-}}"
if [ -z "$AUTHOR_ACCOUNT" ]; then AUTHOR_ACCOUNT="$(identity_from_pat "$AUTHOR_PAT" || true)"; fi
[ -n "$AUTHOR_ACCOUNT" ] || die "无法确定作者账号：用 --author-account 指定，或提供凭据 ${AUTHOR_PAT}"
REVIEWER_ACCOUNT="${REVIEWER_OPT:-${REVIEWER_ACCOUNT:-}}"
if [ -z "$REVIEWER_ACCOUNT" ]; then REVIEWER_ACCOUNT="$(identity_from_pat "$REVIEWER_PAT" || true)"; fi
[ -n "$REVIEWER_ACCOUNT" ] || die "无法确定评审账号：用 --reviewer-account 指定，或提供凭据 ${REVIEWER_PAT}"

# ── 记账存在性策略（Bug #60 追加要求）──────────────────────────
#  · --check   ：记账缺失 = **明确报错**（退出码 2）。绝不能静默按「全部装机前已存在」处理，
#                否则既不报漂移、也无法卸载。
#  · --dry-run ：零写入，因此**不创建**记账；缺失时保守按「非本套件创建」处理并显式告警。
#  · --apply   ：记账缺失 = 首次安装，此时创建（唯一允许创建记账的路径）。
if [ "$MODE" = "check" ]; then
  ledger_require
elif [ "$MODE" = "dry-run" ]; then
  LEDGER_LENIENT=1
else
  if [ ! -f "$LEDGER" ]; then
    ledger_init_if_missing
    info "首次安装：已创建归属记账 ${LEDGER}（**位于版本库之外**，不属于分发物 —— Bug #60）"
  fi
fi

# ── 公共 helper（渲染 / 线上实况探测 / 规则集语义比对 / 归属判定 / 标签解析 / CODEOWNERS 归一化）
#     全部在 toolkit/lib.sh —— 与 eject.sh 共用同一份判据，避免归属逻辑出现第二实现。

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
        drift "文件缺失 ${path}（kit.yaml 期望存在）"; pline "[漂移]" "缺失" "$path"
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
# parse_label_source / label_want 在 toolkit/lib.sh（与 eject.sh 同源）

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
        drift "标签缺失 ${name}（kit.yaml 期望存在）"; pline "[漂移]" "缺失" "label ${name}"
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
      drift "规则集缺失 ${name}（kit.yaml 期望存在，缺它则门禁未生效）"; pline "[漂移]" "缺失" "ruleset ${name}"
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
    ledger_clear_narrowed "$id"
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
  # 检查名核验：kit.yaml 声明的每个检查名都必须能在文件里找到同名 job，否则该必需检查永久 pending
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

# ── ⑤ CODEOWNERS：**只报告，不写入**（NFR-17 / 命名空间归属）──────────
# S3 演练 F4（Bug #62）实证：CODEOWNERS 以"最后匹配"为准，向用户文件末尾追加 `*`
# 会静默覆盖其更早的窄规则（例：`/legacy/ @owner`）—— 那正是 NFR-17「不得就地改写用户
# 既有文件」要防的事故。因此本套件把建议行打印在**报告**里，由采用者自行决定；
# 相应地，卸载时也没有"我们追加的行"要撤（归属问题在源头消失）。
# 另一半（采用者侧不使用 require_code_owner_review）由不变量检查断言，见
# scripts/check-invariants.sh 的 codeowners 检查：否则会装出一个"套件自己无法满足"的门禁。
report_codeowners() {
  local l
  jq -r '.report_only.codeowners.suggested_lines[]?' "$KIT_JSON" | while IFS= read -r l; do
    [ -n "$l" ] || continue
    pline "[报告]" "建议追加" "CODEOWNERS: $(render_str "$l")"
  done
  pline "[报告]" "不写入" "CODEOWNERS（NFR-17：绝不就地改写用户既有文件）"
}

# ── ⑥ 套件自身（整树装配进目标仓库）─────────────────────────────
# 为什么需要它（Bug #61 F2，P0）：
#   装到目标仓库的必需检查**不得引用未安装的资产**。ci/lint 需要至少一个被跟踪的 *.sh，
#   ci/test 需要 toolkit/tests/self-test.sh 与 toolkit/scripts/labels.sh —— 它们全都是
#   **套件自己**的文件。修法（二选一中的第①种，理由见 toolkit/README.md §8）：
#   「把依赖资产纳入套件并登记」→ 在 kit.yaml 的 objects.kit 登记，并由本函数整树装配。
# 判定：逐文件比对（缺失/内容不同 = 需要处理）；目标目录里**套件之外**的文件只报告、不删。
decide_kit() {
  local entry id path src dst list rel missing differ extra act h want_dir
  entry="$1"; id="$(jget "$entry" '.id')"; path="$(jget "$entry" '.path')"
  src="$(jget "$entry" '.source')"
  if [ "$src" = "." ]; then src="$KIT_DIR"; else src="${KIT_DIR}/${src}"; fi
  dst="${ROOT}/${path}"
  if [ ! -d "$src" ]; then
    N_FAIL=$((N_FAIL + 1)); drift "清单损坏 ${id}：套件目录不存在 ${src}"; pline "[失败]" "套件目录缺失" "$id"; return 0
  fi
  # 自装配（在目标仓库内就地运行，KIT_DIR 就是目标路径）→ no-op
  if [ -d "$dst" ] && same_dir "$src" "$dst"; then
    N_OK=$((N_OK + 1)); pline "[ OK ]" "已存在且一致" "kit ${path}（就地运行：自装配 no-op）"
    # 「就地运行且内容与套件逐字节一致」= 套件已装配在目标路径上（创建或明确接管）→ 记 owned，
    # 否则 eject 会把它当成"用户既有对象"而永不回收。
    if [ "$MODE" = "apply" ] && ! ledger_owned "$id"; then
      printf '%s\n' "$id" >> "$CREATED_FILE"
    fi
    check_kit_required "$entry" "$dst"
    return 0
  fi
  list="${TMP_DIR}/kit_list.txt"; dir_rel_files "$src" > "$list"
  missing=0; differ=0
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if [ ! -f "${dst}/${rel}" ]; then missing=$((missing + 1))
    elif ! cmp -s "${src}/${rel}" "${dst}/${rel}"; then differ=$((differ + 1)); fi
  done < "$list"
  extra=0
  if [ -d "$dst" ]; then
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      if ! grep -Fxq -- "$rel" "$list"; then extra=$((extra + 1)); fi
    done <<EOF
$(dir_rel_files "$dst")
EOF
  fi

  if [ "$missing" -eq 0 ] && [ "$differ" -eq 0 ]; then
    act="ok"
  elif [ -e "$dst" ]; then
    if ledger_owned "$id"; then act="update"; else act="conflict"; fi
  else
    act="create"
  fi

  case "$act" in
    create)
      if [ "$MODE" = "check" ]; then
        drift "套件目录缺失 ${path}（kit.yaml 期望存在；缺它则 ci/lint 的 *.sh 覆盖面为空、ci/test 的 toolkit 自检必然变红）"
        pline "[漂移]" "缺失" "kit ${path}"
      else
        N_CREATE=$((N_CREATE + 1)); pline "[${MODE}]" "装配" "kit ${path}（${missing} 个文件）"
        if [ "$MODE" = "apply" ]; then
          ledger_mark_intent "$id"
          if apply_kit_files "$src" "$dst" "$list"; then
            printf '%s\n' "$id" >> "$CREATED_FILE"
          else
            N_FAIL=$((N_FAIL + 1)); drift "套件装配失败 ${path}"
          fi
        fi
      fi ;;
    update)
      if [ "$MODE" = "check" ]; then
        drift "套件目录漂移 ${path}（本套件所有，内容与期望不一致：缺失 ${missing} / 不同 ${differ}）"; pline "[漂移]" "内容不一致" "kit ${path}"
      else
        N_UPDATE=$((N_UPDATE + 1)); pline "[${MODE}]" "更新" "kit ${path}（缺失 ${missing} / 不同 ${differ}）"
        if [ "$MODE" = "apply" ]; then apply_kit_files "$src" "$dst" "$list" || { N_FAIL=$((N_FAIL + 1)); drift "套件更新失败 ${path}"; }; fi
      fi ;;
    ok) N_OK=$((N_OK + 1)); pline "[ OK ]" "已存在且一致" "kit ${path}" ;;
    conflict)
      N_CONFLICT=$((N_CONFLICT + 1))
      drift "套件目录冲突 ${path}：已存在、非本套件创建、且与期望不一致（缺失 ${missing} / 不同 ${differ}）→ 不覆盖、不接管"
      pline "[冲突]" "不覆盖" "kit ${path}（非本套件创建，仅报告）" ;;
  esac
  if [ "$extra" -gt 0 ]; then
    pline "[INFO]" "目标多出" "kit ${path}：${extra} 个套件之外的文件 → 不接管、不删除"
  fi
  if [ "$act" != "conflict" ]; then
    if [ -d "$dst" ]; then check_kit_required "$entry" "$dst"; else check_kit_required "$entry" "$src"; fi
  fi
}

apply_kit_files() {  # $1 = src, $2 = dst, $3 = 相对路径清单
  local rel rc=0
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    mkdir -p "$(dirname "${2}/${rel}")"
    if ! cp "${1}/${rel}" "${2}/${rel}" || ! cmp -s "${1}/${rel}" "${2}/${rel}"; then
      warn "套件文件写入失败：${2}/${rel}"; rc=1
    fi
  done < "$3"
  return $rc
}

# 清单声明的 required 文件必须存在于装配结果里（缺失 = 清单损坏：必需检查会失去依赖资产）
check_kit_required() {  # $1 = entry JSON, $2 = 被检查的目录
  local d="$2" miss="" r
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    if [ ! -f "${d}/${r}" ]; then miss="${miss} ${r}"; fi
  done <<EOF
$(jget "$1" '.required[]?')
EOF
  if [ -n "$miss" ]; then
    N_FAIL=$((N_FAIL + 1))
    drift "套件目录缺少必需文件（必需检查的依赖资产）：${miss}"
    pline "[失败]" "必需文件缺失" "kit:${miss}"
  fi
}

# ── ⑦ 协作者 ──────────────────────────────────────────────────
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
        drift "协作者缺失 ${account}（kit.yaml 期望有 ${perm} 权限；缺它则独立评审链路不可用）"
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
  local class entry id path path2 name account extra_hash
  for class in files kit labels rulesets workflows collaborators; do
    jq -c ".objects.${class}.entries[]" "$KIT_JSON" > "${TMP_DIR}/fin_${class}.txt"
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      id="$(render_str "$(jget "$entry" '.id')")"
      case "$class" in
        files|workflows)
          path="$(jget "$entry" '.path')"
          if [ -f "${ROOT}/${path}" ]; then present="present"; else present="absent"; fi ;;
        kit)
          path="$(jget "$entry" '.path')"
          if [ -d "${ROOT}/${path}" ]; then present="present"; else present="absent"; fi ;;
        labels)
          name="$(jget "$entry" '.name')"
          if awk -F '\t' -v n="$name" '$1 == n { found=1 } END { exit !found }' "${TMP_DIR}/live_labels.tsv"; then present="present"; else present="absent"; fi ;;
        rulesets)
          name="$(jget "$entry" '.name')"
          if [ -n "$(ruleset_id_by_name "$name")" ]; then present="present"; else present="absent"; fi ;;
        collaborators)
          account="$(render_str "$(jget "$entry" '.account')")"
          if awk -F '\t' -v a="$account" '$1 == a { found=1 } END { exit !found }' "${TMP_DIR}/live_collab.tsv"; then present="present"; else present="absent"; fi ;;
      esac
      owned="false"; pre="false"
      if [ "$present" = "present" ]; then
        if grep -Fxq -- "$id" "$created_box" || ledger_owned "$id"; then owned="true"; else pre="true"; fi
      fi
      if [ "$present" = "present" ]; then phase="owned"; [ "$owned" = "true" ] || phase="pre-existing"; else phase="absent"; fi
      extra_hash=""
      if [ "$class" = "kit" ] && [ "$present" = "present" ]; then
        # 整树指纹写进 ledger：eject 用它判定"套件目录是否被改过（漂移）"。
        # 注意目标仓库里 KIT_DIR 就是被检查的目录本身，因此**不能**用 KIT_DIR 当基准。
        path2="$(jget "$entry" '.path')"
        extra_hash="$(dir_hash "${ROOT}/${path2}")"
      fi
      jq -c -n --arg id "$id" --arg phase "$phase" --arg observed "$present" \
         --argjson owned "$owned" --argjson pre "$pre" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sha "$extra_hash" \
         '{id:$id, v:({phase:$phase, observed:$observed, owned:$owned, pre_existing:$pre, recorded_at:$ts} + (if $sha == "" then {} else {sha256:$sha} end))}' >> "$ops"
    done < "${TMP_DIR}/fin_${class}.txt"
  done
  # Bug #60 / S-A：**只写 ledger，绝不写 kit.yaml**。kit.yaml 是出厂声明（可版本控制、可分发），
  # 运行时状态（含目标特有数据）一律落在 <root>/.git/governance-ledger.json（版本库之外，
  # 且必须在 `git clean -fdx` 下存活 —— 这是选 .git/ 的硬理由）。
  ledger_init_if_missing
  local tmp
  tmp="$(mktemp "${TMP_DIR}/ledger.XXXXXX")"
  jq --slurpfile ops "$ops" --arg repo "$REPO" --arg br "$DEFAULT_BRANCH" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    .repo = $repo | .default_branch = $br | .updated_at = $ts
    | .entries = (reduce $ops[] as $o (.entries;
        .[$o.id] =
          ( if ($o.v.observed == "absent") and ((.[$o.id] // {}).intent // "") == "create"
            then ($o.v + {phase:"failed", intent:"create"})
            else $o.v end )))
  ' "$LEDGER" > "$tmp" && mv "$tmp" "$LEDGER"
}

# ── 主流程 ────────────────────────────────────────────────────
log "治理套件 install —— 模式：${MODE}"
log "  套件目录：${KIT_DIR}"
log "  目标仓库：${REPO}（默认分支 ${DEFAULT_BRANCH}，owner ${OWNER}）"
log "  目标根目录：${ROOT}"
log "  归属记账：${LEDGER}$(if [ -f "$LEDGER" ]; then printf '%s' '（已存在）'; else printf '%s' '（不存在）'; fi)"
log "  身份：作者 ${AUTHOR_ACCOUNT} / 评审 ${REVIEWER_ACCOUNT}"
log ""

info "读取线上实况（每次运行都重新读，不用记账代替观测）"
probe_labels; probe_collaborators; probe_ruleset_ids
ok "标签 ${TMP_DIR}/live_labels.tsv：$(wc -l < "${TMP_DIR}/live_labels.tsv" | tr -d ' ') 条线上标签（仅比对 kit.yaml 登记项）"
ok "协作者：$(wc -l < "${TMP_DIR}/live_collab.tsv" | tr -d ' ') 个；规则集：$(wc -l < "${TMP_DIR}/live_rulesets.tsv" | tr -d ' ') 个"

# 命名空间归属不变量（设计 #68 §2.2 / PM 决策 P-5）：受管对象必须能**自证归属**，
# 否则 ledger 一丢就无法安全卸载。豁免允许，但必须逐条写理由（不许把命名空间掏空）。
log ""
info "命名空间归属自检（P-5）"
ns_bad="$(namespace_violations)"; ns_gap="$(namespace_exemption_gaps)"
if [ -n "$ns_bad" ]; then
  N_FAIL=$((N_FAIL + 1))
  drift "受管对象越出命名空间 —— 要么改到命名空间内，要么在 kit.yaml 的 namespace.*_exemptions 里显式豁免并写明理由"
  while IFS="$(printf '\t')" read -r cls oid why; do
    [ -n "${cls}" ] || continue
    pline "[漂移]" "${cls}" "${oid}：${why}"
  done <<EOF
${ns_bad}
EOF
else
  ok "全部受管对象都在命名空间内（或已显式豁免）"
fi
if [ -n "$ns_gap" ]; then
  N_FAIL=$((N_FAIL + 1)); drift "命名空间豁免清单缺项或缺理由：$(printf '%s' "$ns_gap" | tr '\n' ' ')"
fi
ok "命名空间：文件 $(ns_files)** ｜ workflow $(ns_workflows)*.yml ｜ 标签 $(ns_labels) ｜ 规则集 $(ns_rulesets)*"
ok "命名空间豁免：$(printf '%s\n' "$(namespace_exemption_report)" | grep -c . || true) 条（逐条带理由，见 kit.yaml 的 namespace 段）"

# 标签：payload 与 kit.yaml 登记项必须一致（不一致 = 声明损坏）
if [ -f "${KIT_DIR}/$(jq -r '.objects.labels.source' "$KIT_JSON")" ]; then
  parse_label_source "${KIT_DIR}/$(jq -r '.objects.labels.source' "$KIT_JSON")" > "${TMP_DIR}/want_labels.tsv"
  jq -r '.objects.labels.entries[].name' "$KIT_JSON" | sort > "${TMP_DIR}/mf_labels.txt"
  cut -f1 "${TMP_DIR}/want_labels.tsv" | sort > "${TMP_DIR}/src_labels.txt"
  if ! cmp -s "${TMP_DIR}/mf_labels.txt" "${TMP_DIR}/src_labels.txt"; then
    N_FAIL=$((N_FAIL + 1))
    drift "kit.yaml 登记的标签与 payload 不一致（差异见下）—— 出厂声明是唯一归属依据，必须保持同步"
    diff "${TMP_DIR}/mf_labels.txt" "${TMP_DIR}/src_labels.txt" >&2 || true
  fi
fi

for class in files kit labels rulesets workflows collaborators; do
  count="$(jq ".objects.${class}.entries | length" "$KIT_JSON")"
  log ""
  info "受管对象：${class}（${count} 个）"
  jq -c ".objects.${class}.entries[]" "$KIT_JSON" > "${TMP_DIR}/entries.txt"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$class" in
      files)         decide_files "$entry" ;;
      kit)           decide_kit "$entry" ;;
      labels)        decide_labels "$entry" ;;
      rulesets)      decide_rulesets "$entry" ;;
      workflows)     decide_workflows "$entry" ;;
      collaborators) decide_collaborators "$entry" ;;
    esac
  done < "${TMP_DIR}/entries.txt"
done

# 只报告、不写入的对象（NFR-17）：CODEOWNERS 只给建议行，绝不就地改写用户文件
log ""
info "只报告、不写入的对象（NFR-17）"
report_codeowners

# 规则集必需检查 ⊆ 工作流产生的检查名（否则必需检查永久 pending）
log ""
info "交叉校验：规则集必需检查 ⇄ 工作流 job 名"
jq -r '.objects.rulesets.entries[]?.source' "$KIT_JSON" > "${TMP_DIR}/rs_sources.txt"
: > "${TMP_DIR}/req_ctx.txt"
while IFS= read -r s; do
  [ -n "$s" ] || continue
  [ -f "${KIT_DIR}/${s}" ] || continue
  jq -r '.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context' "${KIT_DIR}/${s}" >> "${TMP_DIR}/req_ctx.txt"
done < "${TMP_DIR}/rs_sources.txt"
jq -r '.objects.workflows.entries[]?.checks[]?' "$KIT_JSON" | sort -u > "${TMP_DIR}/wf_checks.txt"
sort -u "${TMP_DIR}/req_ctx.txt" > "${TMP_DIR}/req_ctx_sorted.txt"
missing_ctx="$(comm -23 "${TMP_DIR}/req_ctx_sorted.txt" "${TMP_DIR}/wf_checks.txt" | tr '\n' ' ')"
if [ -n "$(printf '%s' "$missing_ctx" | tr -d ' ')" ]; then
  N_FAIL=$((N_FAIL + 1))
  drift "以下必需检查没有任何受管工作流会产生它（会让所有 PR 永久 pending）：${missing_ctx}"
  pline "[漂移]" "无对应 job" "${missing_ctx}"
else
  ok "规则集引用的必需检查全部有对应 job"
fi

# 归属记账（**只写 ledger**；kit.yaml 只读 —— Bug #60 / S-A）
if [ "$MODE" = "apply" ]; then
  log ""
  info "回读线上实况并写入归属记账（ledger）"
  finalize_ledger
  ok "归属记账已更新：${LEDGER}（在版本库之外，不是分发物）"
fi
# 护栏（Bug #60 / S-A）：出厂声明 kit.yaml 只定义「管什么」，运行时绝不写入。
# kit_purity_check 与运行前的哈希逐字节比对，被污染时**立即响亮失败**（退出码 2）。
kit_purity_check
ledger_n="$(ledger_total)"
ledger_owned_n="$(ledger_owned_total)"
info "归属记账：已登记 ${ledger_n} 个对象（其中 owned=true 共 ${ledger_owned_n} 个）"
info "记账文件：${LEDGER}"

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
    ok "check 通过：线上实况与 kit.yaml 期望一致（0 处漂移）"
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
