#!/usr/bin/env bash
# toolkit/eject.sh —— 可移植治理套件卸载器（S-A：命名空间归属 + ledger 出库 + 分阶段干净卸载）
#
# 用法：
#   toolkit/eject.sh                                   # 默认 = --dry-run：零写入，完整预告将删除/将保留的对象
#   toolkit/eject.sh --check                           # 只读：核验"是否已回到装机前状态"
#   toolkit/eject.sh --apply                           # 实际卸载（**分阶段**，见下方顺序；可中断可续跑）
#   toolkit/eject.sh --apply --after-content-landed     # 终局阶段：内容已由 PR 落地后，删标签/规则集/协作者
#   toolkit/eject.sh --apply --allow-ungated            # 无可用门禁通道时，显式承认"将在无门禁状态下推送"
#   toolkit/eject.sh --apply --force                    # 允许删除**已漂移**的 owned 对象（默认保留并报告）
#   toolkit/eject.sh --apply --revoke-collaborators     # 显式撤销协作者（默认保留 + 提示手动命令）
#
# 参数（与 install.sh 完全一致，全部可参数化；脚本内不出现任何具体仓库名/账号）：
#   --repo OWNER/NAME  --default-branch NAME  --owner ACCOUNT
#   --author-account ACCOUNT  --reviewer-account ACCOUNT
#   --root DIR  --kit-dir DIR  --kit-yaml FILE
#   --ledger FILE            运行时记账（默认 <root>/.git/governance-ledger.json，**不在版本库内**）
#   --tombstone FILE         tombstone 路径（默认 <root>/.git/governance-eject-tombstone.json）
#   --record-file FILE       卸载记录（默认 <tombstone 基名>-record.md）
#   --record-issue N         卸载前把同一记录也写入该 Issue（沿用 scripts/closeout.sh 的 A3 做法）
# 等价环境变量：REPO / DEFAULT_BRANCH / OWNER / AUTHOR_ACCOUNT / REVIEWER_ACCOUNT
#               DEVELOPER_PAT_FILE / REVIEWER_PAT_FILE / TOOLKIT_LEDGER
#
# 语义（S-A + Bug #60）：
#   ① 只移除 ledger 里 owned=true **且未漂移** 的对象；--dry-run/--check 零写入。
#      **ledger 丢失不丢卸载能力**：归属由命名空间 + 出厂内容指纹自证（设计 #68 §2.2），
#      可用 `toolkit/governance ledger rebuild` 从线上实况重建账本（见 toolkit/README.md）。
#   ② 漂移对象**默认保留并报告**，需显式 --force 才删
#   ③ 协作者属**持久权限**：询问式处理（默认保留 + 报告 + 提示手动撤销命令），**绝不静默撤销**
#   ④ tombstone：任何不可逆动作之前先落 tombstone（计划 + baseline + 门禁勘测 + 可恢复锚点），
#      并把同一份记录写成文件（可选写 Issue）。中断后重跑即续跑 ——
#      续跑依据是**每次重新读线上实况**，不是上次运行的记账（失败案例库 D6 的教训）；
#      tombstone 的作用是让"锚点与装机前 baseline"在中断后仍然存在（D7「最后一步不可恢复」的教训）。
#   ⑤ **顺序（Bug #60 追加要求，P0）：先内容、后门禁。**
#        阶段 A（内容）：受管文件 / workflow / 套件目录 → **通过 PR 落地**
#                        （此时规则集仍生效，门禁照常保护）
#        阶段 B（平台对象）：受管标签（PR 合并后再删：policy/branch-name 依赖 status/* 标签）
#        阶段 C（门禁本体）：规则集（**最后**删）
#        阶段 D（持久权限）：协作者（默认保留）
#      · 若默认分支的必需检查正是由本次要删除的 workflow 产生，则该检查在删除 PR 上**无法上报**
#        （实测形态：PR 的 statusCheckRollup 为空、mergeStateStatus=BLOCKED）→ 删除 PR 没有
#        可用的状态检查门禁。此时 eject **收窄**规则集（只去掉 required_status_checks —— 它的输入
#        正是被删除的对象），保留"必须非作者批准 / code-owner 评审 / 解决评论 / 仅 squash"等审查类规则，
#        使内容删除仍**在规则集生效下经 PR + 独立批准**落地。
#      · 若默认分支没有任何启用的规则集保护（或规则集里没有审查类规则）→ **显式报告**
#        「本次卸载将在无门禁状态下推送」，并且只有显式 --allow-ungated 才继续（绝不静默直推）。
#
# 自检接缝（仅供 toolkit/tests/self-test.sh 使用；生产不使用）：
#   TOOLKIT_EJECT_ABORT_AFTER=<class>:<id>  完成该对象后立即 exit 3，用于验证"中断可续跑"
#
# 关于 CODEOWNERS（NFR-17）：本套件**不写入**用户 CODEOWNERS（只给建议行），因此卸载也不删它；
# --check 会断言它逐字节未变（整文件指纹），这比"只保护我们没写的行"更强。
#
# 兼容性铁律：bash 3.2（禁用 mapfile/readarray/declare -A/${var,,}）；变量后紧跟中文写 ${VAR}
# 退出码：0 完成 / 与装机前一致；1 有失败项或存在需人工决定的漂移对象；2 参数或环境错误
set -eu

KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${KIT_DIR}/.." && pwd)"
KIT_YAML=""              # 出厂声明（kit.yaml）；未显式指定时按 KIT_DIR 推导
KIT_JSON=""              # 运行时由 kit.yaml 派生（lib.sh kit_load；不进版本库）
MODE="dry-run"           # dry-run | check | apply
FORCE=0
REVOKE_COLLAB=0
TOMBSTONE=""
RECORD_FILE=""
RECORD_ISSUE=""
LEDGER=""
STAGE="all"               # all | final（--after-content-landed = final）
ALLOW_UNGATED=0
TAB="$(printf '\t')"

die()  { local m="${1:-}"; local c="${2:-2}"; printf '[FAIL] %s\n' "$m" >&2; exit "$c"; }

# 公共 helper（log/info/ok/warn、占位符渲染、线上实况探测、规则集语义比对、归属判定…）：
# 必须与 install.sh 同源，否则会出现"install 认为 owned、eject 认为不是"的静默不一致。
. "${KIT_DIR}/lib.sh"

usage() { sed -n '/^# 用法：/,/^# 退出码/p' "$0" | sed -E 's/^# ?//'; }

REPO_OPT=""; BRANCH_OPT=""; OWNER_OPT=""; AUTHOR_OPT=""; REVIEWER_OPT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) MODE="dry-run" ;;
    --check)   MODE="check" ;;
    --apply)   MODE="apply" ;;
    --force)   FORCE=1 ;;
    --revoke-collaborators) REVOKE_COLLAB=1 ;;
    --after-content-landed) STAGE="final" ;;
    --allow-ungated)        ALLOW_UNGATED=1 ;;
    --repo)            REPO_OPT="${2:?--repo 需要取值}"; shift ;;
    --default-branch)  BRANCH_OPT="${2:?--default-branch 需要取值}"; shift ;;
    --owner)           OWNER_OPT="${2:?--owner 需要取值}"; shift ;;
    --author-account)  AUTHOR_OPT="${2:?--author-account 需要取值}"; shift ;;
    --reviewer-account) REVIEWER_OPT="${2:?--reviewer-account 需要取值}"; shift ;;
    --root)            ROOT="${2:?--root 需要取值}"; shift ;;
    --kit-dir)         KIT_DIR="${2:?--kit-dir 需要取值}"; shift ;;
    --kit-yaml)        KIT_YAML="${2:?--kit-yaml 需要取值}"; shift ;;
    --ledger)          LEDGER="${2:?--ledger 需要取值}"; shift ;;
    --tombstone)       TOMBSTONE="${2:?--tombstone 需要取值}"; shift ;;
    --record-file)     RECORD_FILE="${2:?--record-file 需要取值}"; shift ;;
    --record-issue)    RECORD_ISSUE="${2:?--record-issue 需要取值}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：${1}（见 --help）" ;;
  esac
  shift
done

for c in gh jq awk sed cmp mktemp comm cut sort diff date find; do
  command -v "$c" >/dev/null 2>&1 || die "缺少命令 ${c}（本套件只依赖 bash/git/gh/jq 与 POSIX 自带命令）"
done
[ -n "$KIT_YAML" ] || KIT_YAML="${KIT_DIR}/kit.yaml"
[ -f "$KIT_YAML" ] || die "找不到出厂声明 ${KIT_YAML}（用 --kit-yaml 指定）"

# ── 归属记账（版本库之外；Bug #60）────────────────────────────
[ -n "$LEDGER" ] || LEDGER="${TOOLKIT_LEDGER:-}"
[ -n "$LEDGER" ] || LEDGER="$(ledger_default "$ROOT")"
ledger_reject_if_tracked "$LEDGER"

# 卸载**必须**有归属记账：没有它就无法判定 owned，任何"删除/保留"结论都是猜的。
ledger_require

if [ -z "$TOMBSTONE" ]; then
  if [ -d "${ROOT}/.git" ]; then TOMBSTONE="${ROOT}/.git/governance-eject-tombstone.json"
  else TOMBSTONE="${ROOT}/.governance-eject/tombstone.json"; fi
fi
TB_BASE="${TOMBSTONE%.json}"
OPLOG="${TB_BASE}.oplog"
BACKUP_DIR="${TB_BASE}.backup"
[ -n "$RECORD_FILE" ] || RECORD_FILE="${TB_BASE}-record.md"

case "$RECORD_ISSUE" in
  "") : ;;
  *[!0-9]*) die "--record-issue 必须是 Issue 编号（数字）：${RECORD_ISSUE}" ;;
esac

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/toolkit-eject.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM
# 出厂声明（运行时只读）：kit.yaml → KIT_JSON
kit_load
KIT_ROOT="${KIT_ROOT:-$(jq -r '.objects.kit.entries[0].path // ".github/governance/kit"' "$KIT_JSON")}"
KIT_GOVERNANCE_DIR="${KIT_GOVERNANCE_DIR:-$(ns_files)}"; KIT_GOVERNANCE_DIR="${KIT_GOVERNANCE_DIR%/}"
# payload 占位符的具体值（一处定义在 kit.yaml 的 placeholders 段；不变量 B 用同一张表解析）
RULESET_DECL_PATH="${RULESET_DECL_PATH:-$(jq -r '.placeholders.RULESET_DECL_PATH // ""' "$KIT_JSON")}"
CODEOWNERS_PATH="${CODEOWNERS_PATH:-$(jq -r '.placeholders.CODEOWNERS_PATH // ""' "$KIT_JSON")}"
WORKFLOWS_GLOB="${WORKFLOWS_GLOB:-$(jq -r '.placeholders.WORKFLOWS_GLOB // ""' "$KIT_JSON")}"
CODE_OWNER_IDS="${CODE_OWNER_IDS:-}"
PLAN_TSV="${TMP_DIR}/plan.tsv"
ANCHOR_TSV="${TMP_DIR}/anchors.tsv"
: > "$PLAN_TSV"; : > "$ANCHOR_TSV"

P_DELETE=0; P_KEEP_DRIFT=0; P_KEEP_PRE=0; P_KEEP_ABSENT=0; P_KEEP_DEFER=0
P_KEEP_COLLAB=0; P_REVOKE_COLLAB=0; P_FORCED=0; P_FAIL=0

# ── 参数解析：全部可参数化（与 install.sh 同一套语义）──────────────
REPO="${REPO_OPT:-${REPO:-}}"
if [ -z "$REPO" ]; then
  REPO="$(cd "$ROOT" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
fi
[ -n "$REPO" ] || die "无法确定目标仓库：请在仓库内运行，或用 --repo OWNER/NAME / REPO=... 指定"

DEFAULT_BRANCH="${BRANCH_OPT:-${DEFAULT_BRANCH:-}}"
if [ -z "$DEFAULT_BRANCH" ]; then
  DEFAULT_BRANCH="$(gh repo view "$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name // ""' 2>/dev/null || true)"
fi
[ -n "$DEFAULT_BRANCH" ] || die "无法确定默认分支：请用 --default-branch NAME 指定"

OWNER="${OWNER_OPT:-${OWNER:-}}"
[ -n "$OWNER" ] || OWNER="${REPO%%/*}"

AUTHOR_PAT="${DEVELOPER_PAT_FILE:-${ROOT}/.secrets/developer.pat}"
REVIEWER_PAT="${REVIEWER_PAT_FILE:-${ROOT}/.secrets/reviewer.pat}"
AUTHOR_ACCOUNT="${AUTHOR_OPT:-${AUTHOR_ACCOUNT:-}}"
if [ -z "$AUTHOR_ACCOUNT" ]; then AUTHOR_ACCOUNT="$(identity_from_pat "$AUTHOR_PAT" || true)"; fi
[ -n "$AUTHOR_ACCOUNT" ] || die "无法确定作者账号：用 --author-account 指定，或提供凭据 ${AUTHOR_PAT}"
REVIEWER_ACCOUNT="${REVIEWER_OPT:-${REVIEWER_ACCOUNT:-}}"
if [ -z "$REVIEWER_ACCOUNT" ]; then REVIEWER_ACCOUNT="$(identity_from_pat "$REVIEWER_PAT" || true)"; fi
[ -n "$REVIEWER_ACCOUNT" ] || die "无法确定评审账号：用 --reviewer-account 指定，或提供凭据 ${REVIEWER_PAT}"

# ── 小工具 ────────────────────────────────────────────────────
padd() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$PLAN_TSV"; }
aadd() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$ANCHOR_TSV"; }

# file_hash / dir_hash / dir_rel_files 已移入 toolkit/lib.sh（与 install.sh 同源）

# 线上实况 → 当前状态快照
probe_all() {
  probe_labels; probe_collaborators; probe_ruleset_ids
  snapshot_github_files "${TMP_DIR}/cur_github_files.tsv"
}
# <root>/.github 下**所有**文件的 路径+指纹（用于"用户原有文件一个不少"的强证明：
# 未登记的 .github 文件绝不应被本套件碰到）
snapshot_github_files() {
  local out="$1" f rel
  : > "$out"
  [ -d "${ROOT}/.github" ] || return 0
  find "${ROOT}/.github" -type f 2>/dev/null | LC_ALL=C sort > "${TMP_DIR}/gh_files.list" || true
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#${ROOT}/}"
    printf '%s\t%s\n' "$rel" "$(file_hash "$f")" >> "$out"
  done < "${TMP_DIR}/gh_files.list"
}
# CODEOWNERS 是**用户既有文件**：本套件只报告、绝不写入（NFR-17 / 命名空间归属），
# 因此 baseline 记的是**整文件指纹**，核验时断言它逐字节未变 —— 比"只保护我们没改的行"更强。
# （历史教训 F4 / Bug #62：向用户 CODEOWNERS 末尾追加 `*` 会按"最后匹配"语义静默接管其窄规则。）
snapshot_codeowners_file() {  # $1 = 输出文件；内容为 sha256 或 ABSENT
  local out="$1" f="${ROOT}/.github/CODEOWNERS"
  if [ -f "$f" ]; then printf '%s\n' "$(file_hash "$f")" > "$out"; else printf 'ABSENT\n' > "$out"; fi
}

live_label_row() { awk -F '\t' -v n="$1" '$1 == n { print $2 "\t" $3; exit }' "${TMP_DIR}/live_labels.tsv"; }
live_collab_push() { awk -F '\t' -v a="$1" '$1 == a { print $2; exit }' "${TMP_DIR}/live_collab.tsv"; }

# 标签 payload（判定标签漂移的期望值）
parse_want_labels() {
  local src
  src="$(jq -r '.objects.labels.source // ""' "$KIT_JSON")"
  if [ -n "$src" ] && [ -f "${KIT_DIR}/${src}" ]; then
    parse_label_source "${KIT_DIR}/${src}" > "${TMP_DIR}/want_labels.tsv"
  else
    : > "${TMP_DIR}/want_labels.tsv"
  fi
}

# ══ 规划：逐个受管对象判定 delete / keep ═════════════════════════
plan_file_like() {  # $1 = class(files|workflows)，$2 = entry JSON
  local class="$1" entry="$2" id path src tpl target want act detail=""
  id="$(render_str "$(jget "$entry" '.id')")"
  path="$(jget "$entry" '.path')"
  src="$(jget "$entry" '.source')"
  tpl="$(jget "$entry" '.template // false')"
  target="${ROOT}/${path}"
  if [ ! -f "${KIT_DIR}/${src}" ]; then
    P_FAIL=$((P_FAIL + 1)); padd "fail" "$class" "$id" "$path" "-" "payload 缺失 ${src}（清单损坏）"; return 0
  fi
  if ! ledger_owned "$id"; then
    P_KEEP_PRE=$((P_KEEP_PRE + 1))
    padd "keep-pre" "$class" "$id" "$path" "-" "非本套件创建 / 装机前已存在 → 不删"
    return 0
  fi
  if [ ! -f "$target" ]; then
    P_KEEP_ABSENT=$((P_KEEP_ABSENT + 1)); padd "keep-absent" "$class" "$id" "$path" "-" "已不存在（无需删除）"; return 0
  fi
  want="${TMP_DIR}/want.out"
  render_to "${KIT_DIR}/${src}" "$want" "$tpl"
  if cmp -s "$want" "$target"; then
    P_DELETE=$((P_DELETE + 1)); padd "delete" "$class" "$id" "$path" "-" "owned 且未漂移 → 删除"
  elif [ "$FORCE" -eq 1 ]; then
    P_DELETE=$((P_DELETE + 1)); P_FORCED=$((P_FORCED + 1))
    padd "delete" "$class" "$id" "$path" "-" "owned 但已漂移 → --force 强制删除"
  else
    P_KEEP_DRIFT=$((P_KEEP_DRIFT + 1))
    padd "keep-drift" "$class" "$id" "$path" "-" "owned 但内容与期望不一致（漂移）→ 默认保留，需 --force 才删"
  fi
}

plan_label() {
  local entry="$1" id name lv wcolor wdesc rcolor rdesc
  id="$(render_str "$(jget "$entry" '.id')")"
  name="$(jget "$entry" '.name')"
  if ! ledger_owned "$id"; then
    P_KEEP_PRE=$((P_KEEP_PRE + 1)); padd "keep-pre" "labels" "$id" "$name" "-" "非本套件创建 / 装机前已存在 → 不删"; return 0
  fi
  lv="$(live_label_row "$name")"
  if [ -z "$lv" ]; then
    P_KEEP_ABSENT=$((P_KEEP_ABSENT + 1)); padd "keep-absent" "labels" "$id" "$name" "-" "已不存在（无需删除）"; return 0
  fi
  wcolor="$(label_want "$name" | cut -f1)"; wdesc="$(label_want "$name" | cut -f2)"
  rcolor="$(printf '%s' "$lv" | cut -f1)"; rdesc="$(printf '%s' "$lv" | cut -f2)"
  if [ "$rcolor" = "$wcolor" ] && [ "$rdesc" = "$wdesc" ]; then
    P_DELETE=$((P_DELETE + 1)); padd "delete" "labels" "$id" "$name" "-" "owned 且未漂移 → 删除"
  elif [ "$FORCE" -eq 1 ]; then
    P_DELETE=$((P_DELETE + 1)); P_FORCED=$((P_FORCED + 1))
    padd "delete" "labels" "$id" "$name" "-" "owned 但颜色/描述已被改（漂移）→ --force 强制删除"
  else
    P_KEEP_DRIFT=$((P_KEEP_DRIFT + 1))
    padd "keep-drift" "labels" "$id" "$name" "-" "owned 但颜色/描述与期望不一致（漂移）→ 默认保留，需 --force 才删"
  fi
}

plan_ruleset() {
  local entry="$1" id name src rid want live dline act
  id="$(render_str "$(jget "$entry" '.id')")"
  name="$(jget "$entry" '.name')"
  src="$(jget "$entry" '.source')"
  if ! ledger_owned "$id"; then
    P_KEEP_PRE=$((P_KEEP_PRE + 1)); padd "keep-pre" "rulesets" "$id" "$name" "-" "非本套件创建 / 装机前已存在 → 不删"; return 0
  fi
  rid="$(ruleset_id_by_name "$name")"
  if [ -z "$rid" ]; then
    P_KEEP_ABSENT=$((P_KEEP_ABSENT + 1)); padd "keep-absent" "rulesets" "$id" "$name" "-" "已不存在（无需删除）"; return 0
  fi
  if [ ! -f "${KIT_DIR}/${src}" ]; then
    P_FAIL=$((P_FAIL + 1)); padd "fail" "rulesets" "$id" "$name" "-" "payload 缺失 ${src}（清单损坏）"; return 0
  fi
  want="${TMP_DIR}/want.ruleset.json"; live="${TMP_DIR}/live.ruleset.json"
  cp "${KIT_DIR}/${src}" "$want"; ruleset_fetch "$rid" > "$live"
  if [ ! -s "$live" ]; then
    P_FAIL=$((P_FAIL + 1)); padd "fail" "rulesets" "$id" "$name" "-" "无法读取线上规则集（id=${rid}）"; return 0
  fi
  act="ok"
  # 阶段 A 可能**由本套件自己**收窄过该规则集（去掉 required_status_checks，见 Bug #60 的顺序要求）：
  # 那种情况下"线上少了必需检查"是预期结果，不是漂移；痕迹记在 ledger 的 narrowed 上。
  narrowed_ruleset="$(ledger_get "$id" narrowed)"
  while IFS='|' read -r dline dv1 dv2; do
    [ -n "$dline" ] || continue
    case "$dline" in
      extra_rule|extra_param) : ;;
      contexts)
        if [ "$narrowed_ruleset" != "true" ]; then act="drift"; fi ;;
      rule_missing)
        if [ "$narrowed_ruleset" = "true" ] && [ "$dv1" = "required_status_checks" ]; then : ; else act="drift"; fi ;;
      *) act="drift" ;;
    esac
  done <<EOF
$(ruleset_diff "$want" "$live")
EOF
  if [ "$act" = "ok" ]; then
    P_DELETE=$((P_DELETE + 1)); padd "delete" "rulesets" "$id" "$name" "-" "owned 且未漂移 → 删除"
  elif [ "$FORCE" -eq 1 ]; then
    P_DELETE=$((P_DELETE + 1)); P_FORCED=$((P_FORCED + 1))
    padd "delete" "rulesets" "$id" "$name" "-" "owned 但参数与期望不一致（漂移）→ --force 强制删除"
  else
    P_KEEP_DRIFT=$((P_KEEP_DRIFT + 1))
    padd "keep-drift" "rulesets" "$id" "$name" "-" "owned 但参数与期望不一致（漂移）→ 默认保留，需 --force 才删"
  fi
}

plan_kit() {  # 套件自身整树（objects.kit）
  local entry id path dst want_hash cur_hash
  entry="$1"; id="$(render_str "$(jget "$entry" '.id')")"
  path="$(jget "$entry" '.path')"
  dst="${ROOT}/${path}"
  if ! ledger_owned "$id"; then
    P_KEEP_PRE=$((P_KEEP_PRE + 1)); padd "keep-pre" "kit" "$id" "$path" "-" "非本套件创建 / 装机前已存在 → 不删"; return 0
  fi
  if [ ! -d "$dst" ]; then
    P_KEEP_ABSENT=$((P_KEEP_ABSENT + 1)); padd "keep-absent" "kit" "$id" "$path" "-" "已不存在（无需删除）"; return 0
  fi
  # 就地运行（KIT_DIR 就是被删目录）且本次会停在"需 PR 落地" → **延后**到终局阶段再删：
  # 否则第二次调用 eject.sh 时脚本已被自己删掉（实测：No such file or directory，退出码 127）。
  if same_dir "$dst" "$KIT_DIR" && [ "$STAGE" != "final" ] && [ "$WILL_STOP_FOR_PR" -eq 1 ]; then
    P_KEEP_DEFER=$((P_KEEP_DEFER + 1))
    padd "keep-defer" "kit" "$id" "$path" "-" "就地在目标仓库内运行：延后到终局阶段（--after-content-landed）再删，否则脚本会把自己删掉；若要让它的删除也走 PR，请用 --kit-dir <仓库外的套件副本> 运行"
    return 0
  fi
  # 漂移判据：整树指纹 vs ledger 里安装时记下的 sha256。**不能用 KIT_DIR 当基准** ——
  # 目标仓库里 KIT_DIR 就是被检查的目录本身（自装配语义），那样永远"无漂移"。
  want_hash="$(ledger_get "$id" sha256)"
  cur_hash="$(dir_hash "$dst")"
  if [ -z "$want_hash" ] || [ "$want_hash" = "$cur_hash" ]; then
    P_DELETE=$((P_DELETE + 1)); padd "delete" "kit" "$id" "$path" "-" "owned 且整树指纹一致（未漂移）→ 删除整树"
  elif [ "$FORCE" -eq 1 ]; then
    P_DELETE=$((P_DELETE + 1)); P_FORCED=$((P_FORCED + 1))
    padd "delete" "kit" "$id" "$path" "-" "owned 但整树指纹不一致（已被改成漂移）→ --force 强制删除"
  else
    P_KEEP_DRIFT=$((P_KEEP_DRIFT + 1))
    padd "keep-drift" "kit" "$id" "$path" "-" "owned 但整树指纹不一致（漂移）→ 默认保留，需 --force 才删"
  fi
}

plan_collaborator() {
  local entry="$1" id account perm role role_suffix lv
  id="$(render_str "$(jget "$entry" '.id')")"
  account="$(render_str "$(jget "$entry" '.account')")"
  perm="$(jget "$entry" '.permission')"
  role="$(jget "$entry" '.role // ""')"
  role_suffix=""; if [ -n "$role" ]; then role_suffix="，${role}"; fi
  if ! ledger_owned "$id"; then
    P_KEEP_PRE=$((P_KEEP_PRE + 1))
    padd "keep-pre" "collaborators" "$id" "$account" "$perm" "非本套件添加 / 装机前已存在 → 绝不撤销（持久权限）"
    return 0
  fi
  lv="$(live_collab_push "$account")"
  if [ -z "$lv" ]; then
    P_KEEP_ABSENT=$((P_KEEP_ABSENT + 1)); padd "keep-absent" "collaborators" "$id" "$account" "$perm" "已不存在（无需撤销）"; return 0
  fi
  if [ "$REVOKE_COLLAB" -eq 1 ]; then
    P_REVOKE_COLLAB=$((P_REVOKE_COLLAB + 1))
    padd "revoke-collab" "collaborators" "$id" "$account" "$perm" "owned 且显式 --revoke-collaborators → 撤销协作权限${role_suffix}"
  else
    P_KEEP_COLLAB=$((P_KEEP_COLLAB + 1))
    padd "keep-collab" "collaborators" "$id" "$account" "$perm" "持久权限：询问式处理 → 默认保留（撤销需显式 --revoke-collaborators）${role_suffix}"
  fi
}

build_plan() {
  local class entry
  parse_want_labels
  for class in files kit labels rulesets workflows collaborators; do
    jq -c ".objects.${class}.entries[]" "$KIT_JSON" > "${TMP_DIR}/plan_${class}.txt"
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      case "$class" in
        files|workflows) plan_file_like "$class" "$entry" ;;
        kit)             plan_kit "$entry" ;;
        labels)          plan_label "$entry" ;;
        rulesets)        plan_ruleset "$entry" ;;
        collaborators)   plan_collaborator "$entry" ;;
      esac
    done < "${TMP_DIR}/plan_${class}.txt"
  done
}

# ══ 门禁勘测（Bug #60 追加要求）═════════════════════════════════
# 目标：在动手之前回答三个问题 ——
#   ① 默认分支有没有启用的规则集？
#   ② 规则集里有没有**审查类规则**（pull_request：非作者批准 / CODEOWNERS / 解决评论 / 仅 squash）？
#   ③ 必需状态检查的 workflow 是否正是本次要删除的对象？（是 → 该检查在删除 PR 上无法上报）
# 实测依据（E2-S3b，临时仓库 PR #6）：PR 删除了产出必需检查的 workflow 后
#   statusCheckRollup = []、mergeStateStatus = BLOCKED —— 检查**永远不会上报**，PR 永久卡死。
GATE_ANY=0; GATE_REVIEW=0; GATE_STATUS=0; WILL_STOP_FOR_PR=0
GATE_NAMES=""; GATE_CHECKS=""; GATE_UNUSABLE_CHECKS=""; GATE_REVIEW_RULESET=""

in_removal_set() {  # $1 = 仓库内相对路径 → 是否在本次删除计划里
  awk -F '\t' -v p="$1" '$1 == "delete" && ($2 == "files" || $2 == "workflows" || $2 == "kit") && $4 == p { found = 1 } END { exit !found }' "$PLAN_TSV"
}

gate_ctx_of() {  # $1 = 规则集 body → 是否作用于默认分支
  printf '%s' "$1" | jq -r '[(.conditions.ref_name.include // [])[], "x"] | join(",")' 2>/dev/null \
    | grep -qE "(~DEFAULT_BRANCH|refs/heads/${DEFAULT_BRANCH})(,|$)"
}

# 第一段：只看规则集本身（不依赖删除计划）→ 必须在 build_plan **之前**跑，
# 因为 plan_kit 需要知道"本次是否会停在 PR 阶段"来决定是否延后删除自己。
survey_gate_base() {
  local name rid body checks c
  GATE_ANY=0; GATE_REVIEW=0; GATE_STATUS=0; WILL_STOP_FOR_PR=0
  GATE_NAMES=""; GATE_CHECKS=""; GATE_UNUSABLE_CHECKS=""; GATE_REVIEW_RULESET=""
  while IFS="$TAB" read -r name rid; do
    [ -n "$name" ] || continue
    body="$(ruleset_fetch "$rid")"
    [ -n "$body" ] || continue
    [ "$(printf '%s' "$body" | jq -r '.enforcement // "active"')" = "active" ] || continue
    gate_ctx_of "$body" || continue
    GATE_ANY=1; GATE_NAMES="${GATE_NAMES} ${name}"
    if printf '%s' "$body" | jq -e '.rules[]? | select(.type == "pull_request")' >/dev/null 2>&1; then
      GATE_REVIEW=1
      [ -n "$GATE_REVIEW_RULESET" ] || GATE_REVIEW_RULESET="$name"
    fi
    checks="$(printf '%s' "$body" | jq -r '.rules[]? | select(.type == "required_status_checks") | .parameters.required_status_checks[]?.context' 2>/dev/null || true)"
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      GATE_STATUS=1; GATE_CHECKS="${GATE_CHECKS} ${c}"
    done <<EOF
${checks}
EOF
  done < "${TMP_DIR}/live_rulesets.tsv"
  if [ "$GATE_ANY" -eq 1 ] && [ "$GATE_REVIEW" -eq 1 ]; then WILL_STOP_FOR_PR=1; fi
}

# 第二段：必需检查的 workflow 是否正在被删除（需要 PLAN_TSV）→ build_plan 之后跑
survey_gate_unusable() {
  local name rid body checks c wf f
  GATE_UNUSABLE_CHECKS=""
  while IFS="$TAB" read -r name rid; do
    [ -n "$name" ] || continue
    body="$(ruleset_fetch "$rid")"
    [ -n "$body" ] || continue
    [ "$(printf '%s' "$body" | jq -r '.enforcement // "active"')" = "active" ] || continue
    gate_ctx_of "$body" || continue
    checks="$(printf '%s' "$body" | jq -r '.rules[]? | select(.type == "required_status_checks") | .parameters.required_status_checks[]?.context' 2>/dev/null || true)"
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      f=""
      for wf in "${ROOT}"/.github/workflows/*.yml; do
        [ -f "$wf" ] || continue
        if grep -qE "^[[:space:]]+name:[[:space:]]+${c}[[:space:]]*$" "$wf"; then f="${wf#${ROOT}/}"; break; fi
      done
      if [ -z "$f" ]; then
        GATE_UNUSABLE_CHECKS="${GATE_UNUSABLE_CHECKS} ${c}（找不到产出它的 workflow 文件）"
      elif in_removal_set "$f"; then
        GATE_UNUSABLE_CHECKS="${GATE_UNUSABLE_CHECKS} ${c}（由 ${f} 产出，而该文件在删除计划里）"
      fi
    done <<EOF
${checks}
EOF
  done < "${TMP_DIR}/live_rulesets.tsv"
}

survey_gate() {
  survey_gate_base
  survey_gate_unusable
  aadd gate survey "门禁勘测" "默认分支受规则集保护：$(if [ -n "$GATE_NAMES" ]; then printf '%s' "${GATE_NAMES}"; else printf '无'; fi)；审查类规则=$(if [ "$GATE_REVIEW" -eq 1 ]; then printf '有'; else printf '无'; fi)；必需检查=$(if [ -n "$GATE_CHECKS" ]; then printf '%s' "${GATE_CHECKS}"; else printf '无'; fi)；无法在删除 PR 上报的必需检查=$(if [ -n "$GATE_UNUSABLE_CHECKS" ]; then printf '%s' "${GATE_UNUSABLE_CHECKS}"; else printf '无'; fi)"
}

gate_report() {
  if [ "$GATE_ANY" -eq 0 ]; then
    warn "门禁勘测：默认分支（${DEFAULT_BRANCH}）**没有被任何启用的规则集保护**"
    return 0
  fi
  info "门禁勘测：默认分支受启用的规则集保护 ——${GATE_NAMES}"
  if [ "$GATE_REVIEW" -eq 1 ]; then
    ok "  · 含审查类规则（pull_request：非作者批准 / CODEOWNERS / 解决评论 / 仅 squash）→ 内容删除可经 PR 落地"
  else
    warn "  · **不含**审查类规则（只有 deletion / non_fast_forward 之类）→ PR 无法提供独立批准"
  fi
  if [ "$GATE_STATUS" -eq 1 ]; then
    warn "  · 含必需状态检查：${GATE_CHECKS}"
  fi
  if [ -n "$GATE_UNUSABLE_CHECKS" ]; then
    warn "  · 其中这些必需检查的输入正是本次要删除的对象，删除 PR 上它们无法上报：${GATE_UNUSABLE_CHECKS}"
  fi
}

# 收窄规则集：只去掉 required_status_checks（它的输入正是被删除的对象），保留其余（审查类）规则。
# 这样内容删除仍然**在规则集生效下**经 PR + 独立批准落地 —— 而不是先拆门禁再直推。
narrow_ruleset() {
  local name="$1" rid body tmp nid
  rid="$(ruleset_id_by_name "$name")"
  [ -n "$rid" ] || { warn "收窄规则集失败：找不到 ${name}"; return 1; }
  body="$(ruleset_fetch "$rid")"
  [ -n "$body" ] || { warn "收窄规则集失败：读不到 ${name} 正文"; return 1; }
  tmp="${TMP_DIR}/ruleset_narrow.json"
  printf '%s' "$body" | jq '{name, target, enforcement, conditions, rules: [.rules[] | select(.type != "required_status_checks")], bypass_actors: (.bypass_actors // [])}' > "$tmp"
  if gh api -X PUT "repos/${REPO}/rulesets/${rid}" --input "$tmp" >/dev/null 2>&1; then
    # 留痕：否则 eject 会把自己的收窄误判成"漂移"而拒绝继续（实测踩到）
    nid="$(jq -r --arg n "$name" '.objects.rulesets.entries[]? | select(.name == $n) | .id' "$KIT_JSON" 2>/dev/null | head -1)"
    [ -n "$nid" ] || nid="ruleset:${name}"
    ledger_mark_narrowed "$(render_str "$nid")"
    oplog gate "$name" narrow "ok:required_status_checks-removed"
    ok "已收窄规则集 ${name}：去掉 required_status_checks（其输入正是被删除的资产），保留审查类规则"
    ok "  → 内容删除仍须经 PR + 独立批准（规则集仍 active，不是"先拆门禁再直推"）"
    return 0
  fi
  oplog gate "$name" narrow "fail"
  warn "收窄规则集失败 ${name}（需要 admin 权限）"
  return 1
}

remote_path_exists() {  # $1 = 仓库内路径；默认分支上是否存在（存在=0，不存在=1）
  gh api "repos/${REPO}/contents/$1?ref=${DEFAULT_BRANCH}" >/dev/null 2>&1
}

# 终局阶段的前置条件：**内容删除必须已经在默认分支落地**（否则不许先拆门禁）。
require_content_landed() {
  local miss="" p e id kp
  owned_paths > "${TMP_DIR}/rl_paths.txt"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if remote_path_exists "$p"; then miss="${miss} ${p}"; fi
  done < "${TMP_DIR}/rl_paths.txt"
  if jq -e '.objects.kit' "$KIT_JSON" >/dev/null 2>&1; then
    jq -c '.objects.kit.entries[]' "$KIT_JSON" > "${TMP_DIR}/rl_kit.txt"
    while IFS= read -r e; do
      [ -n "$e" ] || continue
      id="$(render_str "$(jget "$e" '.id')")"
      kp="$(jget "$e" '.path')"
      if same_dir "${ROOT}/${kp}" "$KIT_DIR"; then
        info "套件目录 ${kp} 与正在运行的套件是同一份（就地运行）→ 它的删除发生在本阶段内，不做默认分支远端检查"
      elif ledger_owned "$id" && remote_path_exists "$kp"; then
        miss="${miss} ${kp}"; fi
    done < "${TMP_DIR}/rl_kit.txt"
  fi
  if [ -n "$miss" ]; then
    warn "内容删除尚未在默认分支（${DEFAULT_BRANCH}）落地，这些受管路径仍存在：${miss}"
    die "拒绝继续：**规则集（门禁本体）必须在内容已落地之后才移除**（Bug #60 追加要求）。请先把阶段 A 的删除通过 PR 合并，再重跑 --after-content-landed。" 1
  fi
  ok "前置校验通过：内容删除已在 ${DEFAULT_BRANCH} 上落地（受管文件/套件目录均不存在）"
}

# ── 可恢复锚点：把"删掉就找不回来"的东西先存下来 ────────────────────
collect_anchors() {
  local action class id ref extra detail f
  # 文件类：内容整份备份（删除前）
  while IFS="$TAB" read -r action class id ref extra detail; do
    [ "$action" = "delete" ] || continue
    case "$class" in
      files|workflows)
        f="${ROOT}/${ref}"
        [ -f "$f" ] || continue
        mkdir -p "${BACKUP_DIR}/$(dirname "$ref")"
        cp "$f" "${BACKUP_DIR}/${ref}"
        aadd "$class" "$id" "file-backup" "${BACKUP_DIR}/${ref}（sha256 $(file_hash "$f")）" ;;
    esac
  done < "$PLAN_TSV"
  # 标签 / 规则集 / 协作者：记录重建所需的全部数据
  while IFS="$TAB" read -r action class id ref extra detail; do
    [ "$action" = "delete" ] || [ "$action" = "revoke-collab" ] || continue
    case "$class" in
      labels)
        local lv c d
        lv="$(live_label_row "$ref")"; c="$(printf '%s' "$lv" | cut -f1)"; d="$(printf '%s' "$lv" | cut -f2)"
        aadd "$class" "$id" "label-def" "name=${ref} color=${c} description=${d}" ;;
      rulesets)
        local rid
        rid="$(ruleset_id_by_name "$ref")"
        if [ -n "$rid" ]; then
          ruleset_fetch "$rid" > "${BACKUP_DIR}/ruleset-${ref}.json" 2>/dev/null || true
          if [ -s "${BACKUP_DIR}/ruleset-${ref}.json" ]; then
            aadd "$class" "$id" "ruleset-body" "${BACKUP_DIR}/ruleset-${ref}.json（gh api -X POST repos/${REPO}/rulesets --input 该文件 可重建）"
          else
            aadd "$class" "$id" "ruleset-body" "（未能读取线上规则集正文，id=${rid}）"
          fi
        fi ;;
      collaborators)
        aadd "$class" "$id" "collaborator" "account=${ref} permission=${extra}（重建：gh api -X PUT repos/${REPO}/collaborators/${ref} -f permission=${extra}）" ;;
    esac
  done < "$PLAN_TSV"
}

# ── baseline（用于 --check 的"与装机前一致"证明）────────────────────
# 首次 apply 时把**当前实况**存为 baseline；续跑时**沿用** tombstone 里的 baseline
# （绝不用已经删掉一半的现状重新打底，否则"用户原有对象"的对照基准就丢了）。
write_baseline_files() {
  cp "${TMP_DIR}/live_labels.tsv"        "${TMP_DIR}/baseline_labels.tsv"
  cp "${TMP_DIR}/live_collab.tsv"        "${TMP_DIR}/baseline_collab.tsv"
  cp "${TMP_DIR}/live_rulesets.tsv"      "${TMP_DIR}/baseline_rulesets.tsv"
  cp "${TMP_DIR}/cur_github_files.tsv"   "${TMP_DIR}/baseline_github_files.tsv"
  snapshot_codeowners_file "${TMP_DIR}/baseline_co_hash.txt"
}
load_baseline_from_tombstone() {
  jq -r '.baseline.labels[]?        | select(length>0)' "$TOMBSTONE" > "${TMP_DIR}/baseline_labels.tsv" 2>/dev/null || : > "${TMP_DIR}/baseline_labels.tsv"
  jq -r '.baseline.collaborators[]? | select(length>0)' "$TOMBSTONE" > "${TMP_DIR}/baseline_collab.tsv" 2>/dev/null || : > "${TMP_DIR}/baseline_collab.tsv"
  jq -r '.baseline.rulesets[]?      | select(length>0)' "$TOMBSTONE" > "${TMP_DIR}/baseline_rulesets.tsv" 2>/dev/null || : > "${TMP_DIR}/baseline_rulesets.tsv"
  jq -r '.baseline.github_files[]?  | select(length>0)' "$TOMBSTONE" > "${TMP_DIR}/baseline_github_files.tsv" 2>/dev/null || : > "${TMP_DIR}/baseline_github_files.tsv"
  jq -r '.baseline.codeowners_hash // "ABSENT"' "$TOMBSTONE" > "${TMP_DIR}/baseline_co_hash.txt" 2>/dev/null || printf 'ABSENT\n' > "${TMP_DIR}/baseline_co_hash.txt"
}

plan_items_jsonl() {
  local action class id ref extra detail
  while IFS="$TAB" read -r action class id ref extra detail; do
    [ -n "$action" ] || continue
    jq -c -n --arg a "$action" --arg c "$class" --arg i "$id" --arg r "$ref" --arg e "$extra" --arg d "$detail" \
      '{action:$a, class:$c, id:$i, ref:$r, extra:$e, detail:$d}'
  done < "$PLAN_TSV"
}
anchors_jsonl() {
  local class id kind value
  while IFS="$TAB" read -r class id kind value; do
    [ -n "$class" ] || continue
    jq -c -n --arg c "$class" --arg i "$id" --arg k "$kind" --arg v "$value" \
      '{class:$c, id:$i, kind:$k, value:$v}'
  done < "$ANCHOR_TSV"
}

write_tombstone() {  # $1 = status
  local status="$1" tmp
  tmp="$(mktemp "${TMP_DIR}/tb.XXXXXX")"
  {
    plan_items_jsonl
  } > "${TMP_DIR}/items.jsonl"
  {
    anchors_jsonl
  } > "${TMP_DIR}/anchors.jsonl"
  jq -n \
    --slurpfile items "${TMP_DIR}/items.jsonl" \
    --slurpfile anchors "${TMP_DIR}/anchors.jsonl" \
    --arg status "$status" \
    --arg repo "$REPO" --arg branch "$DEFAULT_BRANCH" --arg root "$ROOT" \
    --arg declaration "$KIT_YAML" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson labels "$(jq -R -s 'split("\n")|map(select(length>0))' "${TMP_DIR}/baseline_labels.tsv")" \
    --argjson collabs "$(jq -R -s 'split("\n")|map(select(length>0))' "${TMP_DIR}/baseline_collab.tsv")" \
    --argjson rulesets "$(jq -R -s 'split("\n")|map(select(length>0))' "${TMP_DIR}/baseline_rulesets.tsv")" \
    --argjson ghfiles "$(jq -R -s 'split("\n")|map(select(length>0))' "${TMP_DIR}/baseline_github_files.tsv")" \
    --arg cohash "$(cat "${TMP_DIR}/baseline_co_hash.txt")" \
    '{tombstone_version:1, status:$status, repo:$repo, default_branch:$branch, root:$root,
      declaration:$declaration, updated_at:$ts,
      semantics:{only_owned_and_undrifted:"只删 ledger 里 owned=true 且未漂移的对象",
                 drift_default_keep:"漂移对象默认保留，需 --force 才删",
                 collaborators_ask:"协作者属持久权限：默认保留，需 --revoke-collaborators 才撤销",
                 resume:"中断后重跑即续跑（依据是每次重新读线上实况，不是上次的记账）"},
      baseline:{labels:$labels, collaborators:$collabs, rulesets:$rulesets, github_files:$ghfiles, codeowners_hash:$cohash},
      items:$items, anchors:$anchors}' > "$tmp"
  mv "$tmp" "$TOMBSTONE"
}

# ── 卸载记录（文件 + 可选 Issue）：**必须在任何不可逆动作之前落盘** ────
write_record() {
  local tmp="$TMP_DIR/record.md" action class id ref extra detail
  {
    printf '%s\n' '<!-- TOOLKIT-EJECT-RECORD -->'
    printf '%s\n' '**治理套件卸载记录（将删除的对象 + 可恢复锚点）**'
    printf '\n'
    printf -- '- 目标仓库：`%s`（默认分支 `%s`）\n' "$REPO" "$DEFAULT_BRANCH"
    printf -- '- 目标根目录：`%s`\n' "$ROOT"
    printf -- '- 模式：`%s`%s\n' "$MODE" "$(if [ "$FORCE" -eq 1 ]; then printf '（--force）'; else printf ''; fi)"
    printf -- '- 生成时间：`%s`\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf -- '- tombstone：`%s`（**可续跑**：中断后重跑 `toolkit/eject.sh --apply` 即可）\n' "$TOMBSTONE"
    printf -- '- 内容备份：`%s`\n' "$BACKUP_DIR"
    printf -- '- 记录文件：`%s`\n' "$RECORD_FILE"
    printf '\n%s\n' '### ① 将删除（owned 且未漂移）'
    while IFS="$TAB" read -r action class id ref extra detail; do
      if [ "$action" = "delete" ]; then printf -- '- `%s` `%s` → `%s`（%s）\n' "$class" "$id" "$ref" "$detail"; fi
    done < "$PLAN_TSV"
    while IFS="$TAB" read -r action class id ref extra detail; do
      if [ "$action" = "revoke-collab" ]; then printf -- '- `%s` `%s` → `%s`（%s）\n' "$class" "$id" "$ref" "$detail"; fi
    done < "$PLAN_TSV"
    printf '\n%s\n' '### ② 按设计保留（不删）'
    while IFS="$TAB" read -r action class id ref extra detail; do
      case "$action" in
        keep-drift|keep-pre|keep-collab|keep-absent|fail)
          printf -- '- `[%s]` `%s` `%s` → `%s`（%s）\n' "$action" "$class" "$id" "$ref" "$detail" ;;
      esac
    done < "$PLAN_TSV"
    printf '\n%s\n' '### ③ 可恢复锚点（重建/还原依据）'
    while IFS="$TAB" read -r class id kind value; do
      [ -n "$class" ] || continue
      printf -- '- `%s` `%s`：%s — %s\n' "$class" "$id" "$kind" "$value"
    done < "$ANCHOR_TSV"
    printf '\n%s\n' '### ④ 手动撤销协作者（如需彻底移除持久权限）'
    while IFS="$TAB" read -r action class id ref extra detail; do
      [ "$class" = "collaborators" ] || continue
      case "$action" in
        keep-collab)
          printf -- '- `gh api -X DELETE repos/%s/collaborators/%s`   # %s\n' "$REPO" "$ref" "$detail" ;;
      esac
    done < "$PLAN_TSV"
    printf '\n%s\n' '> 记录原因（失败案例库 D7「最后一步不可恢复」的教训）：不可逆动作之前先落锚点与 baseline。'
    printf '%s\n' '> 续跑语义：重跑 `toolkit/eject.sh --apply`，它会**重新读线上实况**再决定，不使用上次运行的记账。'
  } > "$tmp"
  mkdir -p "$(dirname "$RECORD_FILE")"
  cp "$tmp" "$RECORD_FILE"
  ok "卸载记录已写入文件：${RECORD_FILE}（在任何删除动作之前）"
  if [ -n "$RECORD_ISSUE" ]; then
    if out="$(gh issue comment "$RECORD_ISSUE" -R "$REPO" --body-file "$tmp" 2>&1)"; then
      ok "卸载记录已写入 Issue #${RECORD_ISSUE}（可恢复锚点随评论留档）"
    else
      printf '%s\n' "$out" >&2
      die "无法把卸载记录写入 Issue #${RECORD_ISSUE} —— 按 D7 教训，**拒绝**在锚点未留档时开始删除"
    fi
  fi
}

# ── 执行 ──────────────────────────────────────────────────────
O_OK=0; O_FAIL=0
oplog() { printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "$4" >> "$OPLOG"; }

maybe_abort() {  # 自检接缝：模拟进程中途退出（tombstone 已落盘）
  if [ -n "${TOOLKIT_EJECT_ABORT_AFTER:-}" ] && [ "${TOOLKIT_EJECT_ABORT_AFTER}" = "$1:$2" ]; then
    oplog "$1" "$2" abort "自检接缝：模拟中断（exit 3）"
    warn "自检接缝触发：在 ${1} ${2} 之后模拟中断（tombstone 与锚点已落盘，重跑即续跑）"
    exit 3
  fi
}

delete_file() {  # $1 class, $2 id, $3 path
  local class="$1" id="$2" path="$3" target="${ROOT}/${3}" d
  if rm -f "$target"; then
    oplog "$class" "$id" delete "ok"
    ok "已删除 [${class}] ${path}"
    d="$(dirname "$target")"
    # 清掉被本套件删空的目录（不含仓库根与 .github 本身；非空则 rmdir 失败，不会误删）
    if [ "$d" != "${ROOT}" ] && [ "$d" != "${ROOT}/.github" ] && [ -d "$d" ]; then
      rmdir "$d" 2>/dev/null && log "  （已清理空目录 ${d#${ROOT}/}）" || true
    fi
    return 0
  fi
  oplog "$class" "$id" delete "fail"
  warn "删除失败 [${class}] ${path}"
  return 1
}

delete_kit() {  # $1 id, $2 = path
  local id="$1" path="$2" dst="${ROOT}/${2}" src="$KIT_DIR" rel n=0 left=0
  if [ ! -d "$dst" ]; then oplog kit "$id" delete "skip:absent"; return 0; fi
  # 只删"套件自己的文件"（按套件清单枚举）；目标目录里多出来的文件保留并报告。
  # 注意：清单在**删除之前**一次性取好（命令替换先求值），因此源目录与被删目录同一也无妨。
  if [ -d "$src" ]; then
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      if [ -f "${dst}/${rel}" ]; then
        if rm -f "${dst}/${rel}"; then n=$((n + 1)); fi
      fi
    done <<EOF
$(dir_rel_files "$src")
EOF
  fi
  find "$dst" -depth -type d -empty -exec rmdir {} \; 2>/dev/null || true
  if [ -d "$dst" ]; then
    left="$(dir_rel_files "$dst" | wc -l | tr -d ' ')"
    rmdir "$dst" 2>/dev/null || true
  fi
  oplog kit "$id" delete "ok:$n-files"
  ok "已删除 [kit] ${path}（${n} 个套件文件）"
  if [ -d "$dst" ] && [ "$left" != "0" ]; then
    warn "  （${path} 里仍有 ${left} 个**套件之外**的文件 → 已保留，不接管不删除）"
  fi
  return 0
}

run_plan() {  # $1 = 可选：content | platform | gate | collab | all
  local stage="${1:-all}" class classes action cl id ref extra detail rid
  case "$stage" in
    content)  classes="files workflows kit" ;;
    platform) classes="labels" ;;
    gate)     classes="rulesets" ;;
    collab)   classes="collaborators" ;;
    kit)      classes="kit" ;;
    *)        classes="files workflows kit labels rulesets collaborators" ;;
  esac
  for class in $classes; do
    while IFS="$TAB" read -r action cl id ref extra detail; do
      [ -n "$action" ] || continue
      [ "$cl" = "$class" ] || continue
      case "$action" in
        keep-defer) : ;;
        delete)
          case "$class" in
            files|workflows) delete_file "$class" "$id" "$ref" && O_OK=$((O_OK + 1)) || O_FAIL=$((O_FAIL + 1)) ;;
            kit)             delete_kit "$id" "$ref" && O_OK=$((O_OK + 1)) || O_FAIL=$((O_FAIL + 1)) ;;
            labels)
              # 注意：gh label delete 不加 --yes 会停在交互确认上（脚本里表现为"挂住"）
              if gh label delete "$ref" -R "$REPO" --yes >/dev/null 2>&1; then
                oplog labels "$id" delete "ok"; ok "已删除 [labels] ${ref}"; O_OK=$((O_OK + 1))
              else
                oplog labels "$id" delete "fail"; warn "标签删除失败 [labels] ${ref}"; O_FAIL=$((O_FAIL + 1))
              fi ;;
            rulesets)
              rid="$(ruleset_id_by_name "$ref")"
              if [ -n "$rid" ] && gh api -X DELETE "repos/${REPO}/rulesets/${rid}" >/dev/null 2>&1; then
                oplog rulesets "$id" delete "ok"; ok "已删除 [rulesets] ${ref}（id=${rid}）"; O_OK=$((O_OK + 1))
              else
                oplog rulesets "$id" delete "fail"; warn "规则集删除失败 [rulesets] ${ref}（需要 admin 权限）"; O_FAIL=$((O_FAIL + 1))
              fi ;;
          esac
          maybe_abort "$class" "$id" ;;
        revoke-collab)
          if gh api -X DELETE "repos/${REPO}/collaborators/${ref}" >/dev/null 2>&1; then
            oplog collaborators "$id" revoke "ok"; ok "已撤销协作者 ${ref}（显式 --revoke-collaborators）"; O_OK=$((O_OK + 1))
          else
            oplog collaborators "$id" revoke "fail"; warn "协作者撤销失败 ${ref}（需要 admin 权限）"; O_FAIL=$((O_FAIL + 1))
          fi
          maybe_abort "$class" "$id" ;;
        *) : ;;
      esac
    done < "$PLAN_TSV"
  done
}

# ══ --check：核验"是否已回到装机前状态" ═════════════════════════
V_OK=0; V_BAD=0; V_KEPT_COLLAB=0
vok()  { V_OK=$((V_OK + 1)); }
vbad() { V_BAD=$((V_BAD + 1)); warn "$1"; }

# 受管路径集合（owned：files/workflows 的 path）
# 套件目录是**目录级**归属：命名空间落地后它位于 .github/governance/kit 之下，
# baseline 差异比对必须按前缀排除，否则会把自己的套件文件误报成"用户原有的 .github 文件被动了"。
owned_prefixes() {
  jq -r '.objects.kit.entries[]?.path' "$KIT_JSON"
}
prefix_owned() {  # $1 = 仓库内相对路径
  local pre
  while IFS= read -r pre; do
    [ -n "$pre" ] || continue
    case "$1" in "${pre}"|"${pre}"/*) return 0 ;; esac
  done <<EOF
$(owned_prefixes)
EOF
  return 1
}
owned_paths() {
  local entry id path
  for class in files workflows; do
    jq -c ".objects.${class}.entries[]" "$KIT_JSON" > "${TMP_DIR}/op_${class}.txt"
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      id="$(render_str "$(jget "$entry" '.id')")"
      ledger_owned "$id" || continue
      path="$(jget "$entry" '.path')"
      printf '%s\n' "$path"
    done < "${TMP_DIR}/op_${class}.txt"
  done
}

verify_state() {
  local entry id name path owned_line f cur e
  HAVE_BASELINE=0
  if [ -f "$TOMBSTONE" ]; then HAVE_BASELINE=1; load_baseline_from_tombstone; fi

  # ① owned 的受管文件 / 工作流 / 套件目录必须消失
  info "① 本套件创建的受管文件/工作流/套件目录是否全部消失"
  for class in files workflows kit; do
    jq -c ".objects.${class}.entries[]" "$KIT_JSON" > "${TMP_DIR}/v_${class}.txt"
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      id="$(render_str "$(jget "$entry" '.id')")"
      if ! ledger_owned "$id"; then continue; fi
      path="$(jget "$entry" '.path')"
      if [ "$class" = "kit" ]; then
        if [ -d "${ROOT}/${path}" ]; then vbad "[${class}] ${path} 仍存在（应已被卸载删除）"; else vok; fi
      else
        if [ -f "${ROOT}/${path}" ]; then vbad "[${class}] ${path} 仍存在（应已被卸载删除）"; else vok; fi
      fi
    done < "${TMP_DIR}/v_${class}.txt"
  done
  # ② 本套件创建的标签 / 规则集必须消失
  info "③ 本套件创建的标签/规则集是否全部消失"
  for class in labels rulesets; do
    jq -c ".objects.${class}.entries[]" "$KIT_JSON" > "${TMP_DIR}/v2_${class}.txt"
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      id="$(render_str "$(jget "$entry" '.id')")"
      if ! ledger_owned "$id"; then continue; fi
      name="$(jget "$entry" '.name')"
      if [ "$class" = "labels" ]; then
        if [ -n "$(live_label_row "$name")" ]; then vbad "[labels] ${name} 仍存在（应已被卸载删除）"; else vok; fi
      else
        if [ -n "$(ruleset_id_by_name "$name")" ]; then vbad "[rulesets] ${name} 仍存在（应已被卸载删除）"; else vok; fi
      fi
    done < "${TMP_DIR}/v2_${class}.txt"
  done

  # ④ 协作者：持久权限 —— 保留属"询问式语义"的正常结果，但必须被报告（不静默）
  info "④ 协作者（持久权限：默认保留，需显式撤销）"
  jq -c '.objects.collaborators.entries[]' "$KIT_JSON" > "${TMP_DIR}/v_collab.txt"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    id="$(render_str "$(jget "$entry" '.id')")"
    name="$(render_str "$(jget "$entry" '.account')")"
    if ! ledger_owned "$id"; then
      if [ -z "$(live_collab_push "$name")" ]; then vbad "[collaborators] ${name} 不见了 —— 非本套件添加的协作者不得被改动"; else vok; fi
      continue
    fi
    if [ -n "$(live_collab_push "$name")" ]; then
      V_KEPT_COLLAB=$((V_KEPT_COLLAB + 1))
      log "  [保留] ${name}（持久权限：未被静默撤销；手动撤销：gh api -X DELETE repos/${REPO}/collaborators/${name}）"
    else vok; fi
  done < "${TMP_DIR}/v_collab.txt"

  # ④ 用户原有对象一个不少（本套件可触达的对象范围：.github 文件 + 标签 + 规则集 + 协作者）
  info "⑤ 用户原有对象是否一个不少（与前次 tombstone 的 baseline 逐项比对）"
  if [ "$HAVE_BASELINE" -eq 0 ]; then
    warn "无 tombstone：缺少装机/卸载前 baseline —— 跳过 baseline 差异比对（只剩 kit.yaml 归属判定那一半证据）"
    return 0
  fi
  # (a) 非受管 .github 文件必须原样（CODEOWNERS 不在受管集内，见 (a2)：它是用户既有文件）
  owned_paths > "${TMP_DIR}/owned_paths.txt"
  : > "${TMP_DIR}/user_ghfiles.txt"; : > "${TMP_DIR}/missing_ghfiles.txt"
  while IFS="$TAB" read -r path hash; do
    [ -n "$path" ] || continue
    if grep -Fxq -- "$path" "${TMP_DIR}/owned_paths.txt"; then continue; fi
    if prefix_owned "$path"; then continue; fi
    printf '%s\n' "$path" >> "${TMP_DIR}/user_ghfiles.txt"
    if [ ! -f "${ROOT}/${path}" ]; then printf '%s（已消失）\n' "$path" >> "${TMP_DIR}/missing_ghfiles.txt"
    elif [ "$(file_hash "${ROOT}/${path}")" != "$hash" ]; then printf '%s（内容被改）\n' "$path" >> "${TMP_DIR}/missing_ghfiles.txt"; fi
  done < "${TMP_DIR}/baseline_github_files.tsv"
  if [ -s "${TMP_DIR}/missing_ghfiles.txt" ]; then
    vbad "用户原有的 .github 文件被动了：$(tr '\n' ' ' < "${TMP_DIR}/missing_ghfiles.txt")"
  else
    ok "非受管 .github 文件全部保持原样（$(wc -l < "${TMP_DIR}/user_ghfiles.txt" | tr -d ' ') 个）"; V_OK=$((V_OK + 1))
  fi
  # (a2) CODEOWNERS 是**用户既有文件**：本套件只报告、绝不写入（NFR-17）。
  #      核验判据 = **整文件指纹**，必须与装机/卸载前逐字节一致。
  want_co="$(cat "${TMP_DIR}/baseline_co_hash.txt")"
  cur_co="ABSENT"; [ -f "${ROOT}/.github/CODEOWNERS" ] && cur_co="$(file_hash "${ROOT}/.github/CODEOWNERS")"
  if [ "$want_co" = "$cur_co" ]; then
    ok "CODEOWNERS 逐字节未被本套件触碰（NFR-17；基线=${want_co}）"; V_OK=$((V_OK + 1))
  else
    vbad "用户的 CODEOWNERS 被动了（NFR-17 违反）：基线=${want_co} / 现在=${cur_co}"
  fi
  # (b) 标签：baseline 里"非本套件 owned"的标签必须仍在，且颜色/描述未变
  owned_label_names > "${TMP_DIR}/owned_labels.txt"
  : > "${TMP_DIR}/missing_labels.txt"
  while IFS="$TAB" read -r name cur_color cur_desc; do
    [ -n "$name" ] || continue
    if grep -Fxq -- "$name" "${TMP_DIR}/owned_labels.txt"; then continue; fi
    cur="$(live_label_row "$name")"
    if [ -z "$cur" ]; then printf '%s（已消失）\n' "$name" >> "${TMP_DIR}/missing_labels.txt"
    elif [ "$(printf '%s' "$cur" | cut -f1)" != "$cur_color" ] || [ "$(printf '%s' "$cur" | cut -f2)" != "$cur_desc" ]; then
      printf '%s（颜色/描述被改）\n' "$name" >> "${TMP_DIR}/missing_labels.txt"; fi
  done < "${TMP_DIR}/baseline_labels.tsv"
  if [ -s "${TMP_DIR}/missing_labels.txt" ]; then
    vbad "用户原有的标签被动过：$(tr '\n' ' ' < "${TMP_DIR}/missing_labels.txt")"
  else ok "用户原有的标签全部保持原样"; V_OK=$((V_OK + 1)); fi
  # (c) 规则集与协作者：baseline 里非 owned 的必须仍在
  owned_ruleset_names > "${TMP_DIR}/owned_rulesets.txt"
  miss_rs=""
  while IFS="$TAB" read -r name rid; do
    [ -n "$name" ] || continue
    if grep -Fxq -- "$name" "${TMP_DIR}/owned_rulesets.txt"; then continue; fi
    if [ -z "$(ruleset_id_by_name "$name")" ]; then miss_rs="${miss_rs} ${name}"; fi
  done < "${TMP_DIR}/baseline_rulesets.tsv"
  if [ -n "$miss_rs" ]; then vbad "用户原有的规则集不见了：${miss_rs}"; else ok "用户原有的规则集全部保持原样"; V_OK=$((V_OK + 1)); fi
  owned_collab_accts > "${TMP_DIR}/owned_collabs.txt"
  miss_cb=""
  while IFS="$TAB" read -r name push; do
    [ -n "$name" ] || continue
    if grep -Fxq -- "$name" "${TMP_DIR}/owned_collabs.txt"; then continue; fi
    if [ -z "$(live_collab_push "$name")" ]; then miss_cb="${miss_cb} ${name}"; fi
  done < "${TMP_DIR}/baseline_collab.tsv"
  if [ -n "$miss_cb" ]; then vbad "用户原有的协作者不见了：${miss_cb}"; else ok "用户原有的协作者全部保持原样"; V_OK=$((V_OK + 1)); fi
}

# 归属集合（供 verify_state 的 baseline 差异比对使用）
owned_label_names() {
  jq -c '.objects.labels.entries[]' "$KIT_JSON" > "${TMP_DIR}/on_labels.txt"
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    id="$(render_str "$(jget "$e" '.id')")"
    if ledger_owned "$id"; then jget "$e" '.name'; fi
  done < "${TMP_DIR}/on_labels.txt"
}
owned_ruleset_names() {
  jq -c '.objects.rulesets.entries[]' "$KIT_JSON" > "${TMP_DIR}/on_rulesets.txt"
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    id="$(render_str "$(jget "$e" '.id')")"
    if ledger_owned "$id"; then jget "$e" '.name'; fi
  done < "${TMP_DIR}/on_rulesets.txt"
}
owned_collab_accts() {
  jq -c '.objects.collaborators.entries[]' "$KIT_JSON" > "${TMP_DIR}/on_collabs.txt"
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    id="$(render_str "$(jget "$e" '.id')")"
    # 注意：render_str 用 printf '%s'（不带换行），逐行输出必须自己补 '\n'，否则多行会被拼成一行
    if ledger_owned "$id"; then printf '%s\n' "$(render_str "$(jget "$e" '.account')")"; fi
  done < "${TMP_DIR}/on_collabs.txt"
}

# ══ 主流程 ════════════════════════════════════════════════════
log "治理套件 eject —— 模式：${MODE}$(if [ "$FORCE" -eq 1 ]; then printf '（--force）'; else printf ''; fi)$(if [ "$REVOKE_COLLAB" -eq 1 ]; then printf '（--revoke-collaborators）'; else printf ''; fi)"
log "  套件目录：${KIT_DIR}"
log "  目标仓库：${REPO}（默认分支 ${DEFAULT_BRANCH}，owner ${OWNER}）"
log "  目标根目录：${ROOT}"
log "  归属记账：${LEDGER}"
log "  tombstone：${TOMBSTONE}"
log "  阶段：${STAGE}（--after-content-landed = final）"
log ""

info "读取线上实况（每次运行都重新读，不用记账代替观测）"
probe_all
# 门禁勘测第一段必须在 build_plan 之前（plan_kit 需要 WILL_STOP_FOR_PR）
survey_gate_base
ok "标签 $(wc -l < "${TMP_DIR}/live_labels.tsv" | tr -d ' ') 条；协作者 $(wc -l < "${TMP_DIR}/live_collab.tsv" | tr -d ' ') 个；规则集 $(wc -l < "${TMP_DIR}/live_rulesets.tsv" | tr -d ' ') 个"
ok "受管 .github 文件指纹已采集：$(wc -l < "${TMP_DIR}/cur_github_files.tsv" | tr -d ' ') 个"

LEDGER_TOTAL="$(ledger_total)"
# owned 的判定与 lib.sh 的 ledger_owned 保持一致：owned=true **或** 留有 create 意图（D6）
OWNED_TOTAL="$(jq -r '[.entries[] | select((.owned == true) or ((.intent // "") == "create"))] | length' "$LEDGER" 2>/dev/null || printf '0')"
info "归属记账：${LEDGER_TOTAL} 个对象，其中 owned=true ${OWNED_TOTAL} 个"
info "记账文件：${LEDGER}（在版本库之外）"

if [ "$MODE" = "check" ]; then
  echo
  verify_state
  echo
  info "小结（模式：check）"
  log "  通过检查项：${V_OK}"
  log "  未通过检查项：${V_BAD}"
  log "  按询问式语义保留的协作者：${V_KEPT_COLLAB}"
  if [ "$V_BAD" -eq 0 ] && [ "${OWNED_TOTAL:-0}" -eq 0 ]; then
    ok "check 通过：本套件在本仓库没有 owned 对象（全部为装机前已存在/非本套件对象）→ 无需卸载，状态与装机前一致"
    exit 0
  fi
  if [ "$V_BAD" -eq 0 ]; then
    if [ "$V_KEPT_COLLAB" -gt 0 ]; then
      ok "check 通过：与装机前一致（例外：${V_KEPT_COLLAB} 个协作者属持久权限，按询问式语义保留并已报告，未静默撤销）"
    else
      ok "check 通过：与装机前完全一致（受管文件全消失、本套件创建的对象全消失、用户原有对象一个不少）"
    fi
    exit 0
  fi
  warn "check 未通过：${V_BAD} 项与装机前不一致 —— 上表逐条列出，按提示处理"
  exit 1
fi

# 收尾（三个入口共用：终局阶段 / 无门禁通道 / 单阶段）
finish_apply() {
  echo
  info "③ 收尾"
  if [ "$O_FAIL" -gt 0 ]; then
    write_tombstone "completed_with_failures"
  elif [ "$P_KEEP_DRIFT" -gt 0 ]; then
    write_tombstone "completed_with_drift_kept"
  else
    write_tombstone "completed"
  fi
  ok "tombstone 已更新：${TOMBSTONE}（status=$(jq -r .status "$TOMBSTONE")）"
  ok "操作流水：${OPLOG}"
  echo
  info "小结（模式：apply）"
  log "  已删除对象：${O_OK}"
  log "  删除失败：${O_FAIL}"
  log "  因漂移保留（--force 才删）：${P_KEEP_DRIFT}"
  log "  非本套件对象保留：${P_KEEP_PRE}"
  log "  协作者保留（持久权限）：${P_KEEP_COLLAB}"
  log "  可恢复锚点：${BACKUP_DIR}"
  log "  卸载记录：${RECORD_FILE}"
  echo
  if [ "$O_FAIL" -gt 0 ]; then
    warn "卸载未完全成功：${O_FAIL} 项失败 —— 修复后重跑本命令（会先读线上实况再决定，可安全续跑）"
    exit 1
  fi
  if [ "$P_KEEP_DRIFT" -gt 0 ]; then
    warn "有 ${P_KEEP_DRIFT} 个 owned 对象已漂移，按保护语义**已保留**：需要人工决定 —— 确认后加 --force 重跑，或手工处理"
    exit 1
  fi
  if [ "$P_KEEP_COLLAB" -gt 0 ]; then
    warn "协作者属持久权限，已**按询问式语义保留** ${P_KEEP_COLLAB} 个（未静默撤销）。要一并撤销请显式加 --revoke-collaborators"
  fi
  ok "卸载完成：受管且未漂移的对象已全部移除。核验请运行：$(basename "$0") --check"
  exit 0
}

build_plan
survey_gate_unusable

echo
info "卸载计划（依据：ledger 的归属 + 本次现读的线上实况）"
for class in files workflows kit labels rulesets collaborators; do
  cnt="$(awk -F '\t' -v c="$class" '$2 == c' "$PLAN_TSV" | wc -l | tr -d ' ')"
  log ""
  info "受管对象：${class}（${cnt} 个）"
  while IFS="$TAB" read -r action cl id ref extra detail; do
    [ "$cl" = "$class" ] || continue
    case "$action" in
      delete)          printf '  [删除] %s（%s）\n' "$ref" "$detail" ;;
      revoke-collab)   printf '  [撤销] %s（%s）\n' "$ref" "$detail" ;;
      keep-drift)      printf '  [保留] %s（%s）\n' "$ref" "$detail" ;;
      keep-pre)        printf '  [保留] %s（%s）\n' "$ref" "$detail" ;;
      keep-collab)     printf '  [保留] %s（%s）→ 手动撤销：gh api -X DELETE repos/%s/collaborators/%s\n' "$ref" "$detail" "$REPO" "$ref" ;;
      keep-absent)     printf '  [跳过] %s（%s）\n' "$ref" "$detail" ;;
      keep-defer)      printf '  [延后] %s（%s）\n' "$ref" "$detail" ;;
      fail)            printf '  [失败] %s（%s）\n' "$ref" "$detail" ;;
    esac
  done < "$PLAN_TSV"
done

echo
info "小结（模式：${MODE}）"
log "  将删除/已删除：${P_DELETE}$(if [ "$P_FORCED" -gt 0 ]; then printf '（其中 --force 强制删除漂移对象 %s 个）' "$P_FORCED"; else printf ''; fi)"
log "  因漂移保留（需显式 --force）：${P_KEEP_DRIFT}"
log "  非本套件对象保留（不覆盖不接管）：${P_KEEP_PRE}"
log "  已不存在（无需处理）：${P_KEEP_ABSENT}"
log "  延后处理（就地运行，留到终局阶段）：${P_KEEP_DEFER}"
log "  协作者保留（持久权限，询问式）：${P_KEEP_COLLAB}"
log "  协作者显式撤销：${P_REVOKE_COLLAB}"
log "  失败：${P_FAIL}"

if [ "$MODE" = "dry-run" ]; then
  echo
  info "门禁勘测（Bug #60 追加要求：先内容、后门禁）"
  gate_report
  echo
  ok "dry-run 结束：零写入（未创建 tombstone / 备份 / 记录，未调用任何写接口）。真正卸载请运行：$(basename "$0") --apply"
  log "  说明：--apply 会先把「将删除的对象 + 可恢复锚点 + 装机前 baseline」写入 ${TOMBSTONE} 与 ${RECORD_FILE}，然后才删除。"
  exit 0
fi

# ── --apply ──────────────────────────────────────────────────
if [ "$P_FAIL" -gt 0 ]; then
  warn "计划中有 ${P_FAIL} 处失败（清单损坏/线上不可读）—— 先修复再卸载"
  exit 1
fi

# 纯 no-op：没有要删的、也没有要撤销的、更没有需人工决定的漂移对象
# （宿主仓库自举的场景即如此：所有对象都是 pre_existing）→ 不写任何 tombstone/记录/备份，不调用写接口
if [ "$P_DELETE" -eq 0 ] && [ "$P_REVOKE_COLLAB" -eq 0 ] && [ "$P_KEEP_DRIFT" -eq 0 ]; then
  echo
  if [ -f "$TOMBSTONE" ]; then
    load_baseline_from_tombstone
    write_tombstone "completed"
    ok "续跑收口：无待删除的 owned 对象，tombstone 状态已更新为 $(jq -r .status "$TOMBSTONE")"
  else
    ok "无待删除的 owned 对象（全部为装机前已存在/非本套件对象/已不存在）→ 卸载为 no-op：未写入 tombstone/记录/备份，未调用任何写接口"
  fi
  exit 0
fi

if [ -f "$TOMBSTONE" ]; then
  info "发现已有 tombstone（续跑）：沿用其 baseline，不重新打底"
  load_baseline_from_tombstone
else
  write_baseline_files
fi
mkdir -p "$BACKUP_DIR"
: > "$OPLOG"

echo
info "① 门禁勘测 + 落 tombstone 与可恢复锚点（在任何不可逆动作之前）"
gate_report
collect_anchors
write_tombstone "planned"
ok "tombstone 已写入：${TOMBSTONE}（status=planned，包含 baseline、门禁勘测与锚点）"
write_record

# ── 终局阶段（--after-content-landed）────────────────────────
if [ "$STAGE" = "final" ]; then
  echo
  info "② 终局阶段（--after-content-landed）：先核实内容已落地，再删标签 → 规则集 → 协作者"
  require_content_landed
  echo
  info "阶段 B（平台对象）：受管标签"
  run_plan platform
  echo
  info "阶段 C（门禁本体）：规则集 —— 最后才移除"
  run_plan gate
  echo
  info "阶段 D（持久权限）：协作者（默认保留）"
  run_plan collab
  echo
  info "阶段 E（套件目录）：仅当套件是「就地运行」（脚本就在目标仓库的 toolkit/ 里）而被延后时才有动作"
  run_plan kit
  finish_apply
fi

# ── 阶段 A（内容）：工作区删除，需通过 PR 落地 ────────────────
echo
info "② 阶段 A（内容）：受管文件 / workflow / 套件目录"
info "   （这些改动**必须在规则集仍生效时通过 PR 落地**，不允许直推默认分支）"
run_plan content

if [ "$GATE_ANY" -eq 1 ] && [ "$GATE_REVIEW" -eq 1 ]; then
  # 有审查类规则 → 内容删除可以在规则集生效下经 PR + 独立批准落地
  if [ -n "$GATE_UNUSABLE_CHECKS" ]; then
    echo
    warn "必需状态检查在删除 PR 上无法上报（它们的 workflow 正是被删除对象）：${GATE_UNUSABLE_CHECKS}"
    info "→ 收窄规则集（只去掉 required_status_checks，保留审查类规则），使 PR 依然被门禁约束"
    narrow_ruleset "$GATE_REVIEW_RULESET" || true
  fi
  write_tombstone "awaiting_content_pr"
  echo
  warn "已停在阶段 A：内容删除只在**工作区**完成，规则集（${GATE_REVIEW_RULESET}）与协作者**未被移除**。"
  info "请通过 PR 落地（不要直推）："
  log "    git checkout -b chore/<issue#>-eject-content"
  log "    git add -A && git commit -m \"chore(toolkit): 卸载受管对象（内容）\""
  log "    git push -u origin chore/<issue#>-eject-content"
  log "    gh pr create --base ${DEFAULT_BRANCH} --fill"
  info "合并后重跑：$(basename "$0") --apply --after-content-landed"
  info "（卸了哪些、可恢复锚点在哪，见记录：${RECORD_FILE}）"
  exit 1
fi

# ── 无可用门禁通道：显式报告，绝不静默直推 ─────────────────────
echo
if [ "$GATE_ANY" -eq 0 ]; then
  warn "⚠ 本次卸载将在无门禁状态下推送：默认分支（${DEFAULT_BRANCH}）**没有被任何启用的规则集保护**。"
else
  warn "⚠ 本次卸载将在无门禁状态下推送：规则集存在（${GATE_NAMES}）但**没有审查类规则**，"
  warn "  且受管 workflow 的删除会让必需检查无法上报 —— 这条内容删除路径**没有可用门禁通道**。"
fi
if [ "$ALLOW_UNGATED" -ne 1 ]; then
  echo
  warn "拒绝继续：按 Bug #60 追加要求，无可用门禁通道时必须**显式确认**，绝不静默直推。"
  info "确认后重跑：$(basename "$0") --apply --allow-ungated"
  info "（本次只是预演到最后一步：工作区删除已完成，标签/规则集/协作者**均未动**）"
  exit 1
fi
warn "已显式 --allow-ungated：继续删除标签 → 规则集 → 协作者"
echo
info "阶段 B（平台对象）：受管标签"
run_plan platform
echo
info "阶段 C（门禁本体）：规则集"
run_plan gate
echo
info "阶段 D（持久权限）：协作者（默认保留）"
run_plan collab
echo
info "内容删除已在工作区完成、规则集已移除 → 现在才可能推送（无门禁）："
log "    git add -A && git commit -m \"chore(toolkit): 卸载受管对象（无门禁通道，已显式报告）\""
log "    git push origin ${DEFAULT_BRANCH}"
finish_apply
