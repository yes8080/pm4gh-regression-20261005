#!/usr/bin/env bash
# toolkit/ledger.sh —— 运行时记账（ledger）的**读取**与**重建**（Issue #69 S-A 的第 3 项交付）
#
# 为什么需要这两个子命令（设计 #68 §2.1.1 明文要求）：
#   ledger 放在 `<root>/.git/governance-ledger.json`，它的**代价**是"对人不可发现"：
#   既不出现在 `git status`，也不出现在任何 diff / 评审里。因此设计同时要求两条硬设施：
#     ① `ledger show`    —— 把账本的当前内容、来源、套件版本打出来（只读）
#     ② `ledger rebuild` —— **账本丢失可恢复**：以「命名空间归属 + 出厂内容指纹」重新
#        snapshot 线上对象来重建账本。这正是设计 #68 §2.2 承诺的能力：
#        ledger 丢了只丢"历史细节"，**不丢卸载能力**。
#
# 用法：
#   toolkit/ledger.sh show [--json]            # 读取（只读；账本不存在时给出重建指引，退出码 1）
#   toolkit/ledger.sh rebuild [--dry-run|--apply]   # 重建（默认 dry-run，零写入）
#
# 参数：--root DIR  --kit-dir DIR  --ledger FILE  --repo OWNER/NAME  --default-branch NAME
# 退出码：0 成功；1 账本不存在（show）/ 有需要人工决定的项（rebuild dry-run 有未知归属）；2 参数或环境错误
set -eu

KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT=""
LEDGER=""; SUB=""; JSON=0; MODE="dry-run"
REPO_OPT=""; BRANCH_OPT=""

die() { local m="${1:-}"; local c="${2:-2}"; printf '[FAIL] %s\n' "$m" >&2; exit "$c"; }
usage() { sed -n '2,18p' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    show|rebuild) SUB="$1" ;;
    --json)   JSON=1 ;;
    --apply)  MODE="apply" ;;
    --dry-run) MODE="dry-run" ;;
    --root)   ROOT="${2:?--root 需要取值}"; shift ;;
    --kit-dir) KIT_DIR="${2:?--kit-dir 需要取值}"; shift ;;
    --ledger) LEDGER="${2:?--ledger 需要取值}"; shift ;;
    --repo)   REPO_OPT="${2:?--repo 需要取值}"; shift ;;
    --default-branch) BRANCH_OPT="${2:?--default-branch 需要取值}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：${1}（见 --help）" ;;
  esac
  shift
done
[ -n "$SUB" ] || die "缺少子命令：show | rebuild（见 --help）"
# 仓库根：显式 --root → 否则从套件目录向上找 .git（采用者仓库里套件在 .github/governance/kit 下）
if [ -z "$ROOT" ]; then
  d="$KIT_DIR"
  while [ "$d" != "/" ] && [ ! -d "${d}/.git" ]; do d="$(dirname "$d")"; done
  if [ -d "${d}/.git" ]; then ROOT="$d"; else ROOT="$(cd "${KIT_DIR}/.." && pwd)"; fi
fi
for c in jq awk sed cmp mktemp sort tr date find; do
  command -v "$c" >/dev/null 2>&1 || die "缺少命令 ${c}"
done

KIT_YAML="${KIT_DIR}/kit.yaml"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/toolkit-ledger.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM
: "${OWNER:=}"; : "${REVIEWER_ACCOUNT:=}"; : "${REPO:=}"; : "${DEFAULT_BRANCH:=}"; : "${AUTHOR_ACCOUNT:=}"
. "${KIT_DIR}/lib.sh"
kit_load
KIT_ROOT="${KIT_ROOT:-$(jq -r '.objects.kit.entries[0].path // ".github/governance/kit"' "$KIT_JSON")}"
REPO="${REPO_OPT:-${REPO:-}}"
DEFAULT_BRANCH="${BRANCH_OPT:-${DEFAULT_BRANCH:-}}"
# 身份账号：只用于渲染 id/account 占位符（绝不打印凭据内容）
if [ -z "$AUTHOR_ACCOUNT" ]; then AUTHOR_ACCOUNT="$(identity_from_pat "${ROOT}/.secrets/developer.pat" || true)"; fi
if [ -z "$REVIEWER_ACCOUNT" ]; then REVIEWER_ACCOUNT="$(identity_from_pat "${ROOT}/.secrets/reviewer.pat" || true)"; fi
KIT_NAMESPACE_FILES="$(jq -r '.namespace.managed_files' "$KIT_JSON")"
KIT_NAMESPACE_WF="$(jq -r '.namespace.managed_workflows' "$KIT_JSON")"
KIT_NAMESPACE_LABELS="$(jq -r '.namespace.ownership_labels' "$KIT_JSON")"
KIT_NAMESPACE_RULESETS="$(jq -r '.namespace.managed_rulesets' "$KIT_JSON")"
RULESET_DECL_PATH="$(jq -r '.placeholders.RULESET_DECL_PATH // ""' "$KIT_JSON")"
CODEOWNERS_PATH="$(jq -r '.placeholders.CODEOWNERS_PATH // ""' "$KIT_JSON")"
WORKFLOWS_GLOB="$(jq -r '.placeholders.WORKFLOWS_GLOB // ""' "$KIT_JSON")"
[ -n "$LEDGER" ] || LEDGER="${TOOLKIT_LEDGER:-}"
[ -n "$LEDGER" ] || LEDGER="$(ledger_default "$ROOT")"
KIT_VERSION="$(jq -r '.kit.version' "$KIT_JSON")"
DECL_PATH="$(jq -r '.ledger.path' "$KIT_JSON")"

# 线上实况小工具（与 eject.sh 同源语义；lib.sh 只放两脚本共用的判据）
live_label_row()   { awk -F '\t' -v n="$1" '$1 == n { print $2 "\t" $3; exit }' "${TMP_DIR}/live_labels.tsv"; }
live_collab_push() { awk -F '\t' -v a="$1" '$1 == a { print $2; exit }' "${TMP_DIR}/live_collab.tsv"; }
pline_rb() { printf '  %s %s %s\n' "$1" "$2" "$3"; }

# ── 文档化说明：它是什么 / 放哪 / 丢了怎么办（设计要求逐字可读）──────────
explain() {
  local tracked="否" rel=""
  if command -v git >/dev/null 2>&1 && [ -d "${ROOT}/.git" ]; then
    rel="${LEDGER}"; case "$rel" in "${ROOT}/"*) rel="${rel#${ROOT}/}" ;; esac
    if git -C "$ROOT" ls-files --error-unmatch "$rel" >/dev/null 2>&1; then tracked="**是（异常！）**"; fi
  fi
  cat <<EOF
这是什么：安装器的**事务账**（记录本套件对远端对象实际做了什么），不是任务/状态账本。
          「管什么」在出厂声明 kit.yaml（进版本库、可 diff）；「实际创建了什么」在 ledger。
放在哪： ${LEDGER}（出厂声明里的登记值：${DECL_PATH}）
          选择 <root>/.git/ 的硬理由：它必须**活过 \`git clean -fdx\`**（gitignore 方案下会被直接清掉）。
是否被 git 跟踪：${tracked}（必须为「否」—— 一旦入库，真实账号与归属就进了分发物，见 Bug #60）
命名空间：文件 ${KIT_NAMESPACE_FILES}** ｜ workflow ${KIT_NAMESPACE_WF}*.yml ｜ 标签 ${KIT_NAMESPACE_LABELS} ｜ 规则集 ${KIT_NAMESPACE_RULESETS}*
          受管对象：文件 $(jq -r '.objects.files.entries | length' "$KIT_JSON") / workflow $(jq -r '.objects.workflows.entries | length' "$KIT_JSON") / 标签 $(jq -r '.objects.labels.entries | length' "$KIT_JSON") / 规则集 $(jq -r '.objects.rulesets.entries | length' "$KIT_JSON") / 协作者 $(jq -r '.objects.collaborators.entries | length' "$KIT_JSON")
丢了怎么办：① 不需要重建也能卸载 —— 归属由**命名空间**自证，只是丢掉"历史细节"；
          ② 完整恢复：\`toolkit/governance ledger rebuild\`（默认 dry-run，--apply 落盘）——
          以命名空间 + 出厂内容指纹重新 snapshot 线上对象；
          ③ 也可以从备份恢复，或 --ledger FILE / TOOLKIT_LEDGER=... 指定路径。
EOF
}

case "$SUB" in
  show)
    if [ ! -f "$LEDGER" ]; then
      printf '[WARN] 归属记账不存在：%s\n' "$LEDGER" >&2
      explain >&2
      exit 1
    fi
    if [ "$JSON" -eq 1 ]; then
      jq . "$LEDGER"
      exit 0
    fi
    info "归属记账（只读）"
    log "  路径：${LEDGER}"
    log "  套件：$(jq -r '.kit // "?"' "$LEDGER") $(jq -r '.kit_version // "?"' "$LEDGER")（出厂声明版本 ${KIT_VERSION}）"
    log "  仓库：$(jq -r '.repo // ""' "$LEDGER")（默认分支 $(jq -r '.default_branch // ""' "$LEDGER")）"
    log "  生成：$(jq -r '.generated_at // "?"' "$LEDGER")   最后更新：$(jq -r '.updated_at // "?"' "$LEDGER")"
    log "  条目：$(jq -r '.entries | length' "$LEDGER") 个（owned=$(jq -r '[.entries[] | select(.owned==true)] | length' "$LEDGER")，pre_existing=$(jq -r '[.entries[] | select(.pre_existing==true)] | length' "$LEDGER")，其余=待定/缺失）"
    log ""
    log "  ── 条目明细（phase / observed / owned / pre_existing / sha256 前 12 位 / 记录时间）"
    jq -r '.entries | to_entries[] | "  \(.key)\t\(.value.phase // "?")\t\(.value.observed // "?")\t\(.value.owned // false)\t\(.value.pre_existing // false)\t\((.value.sha256 // "-")[0:12])\t\(.value.recorded_at // "?")"' "$LEDGER" \
      | awk -F '\t' '{ printf "    %-52s %-12s %-9s %-6s %-6s %-12s %s\n", $1, $2, $3, $4, $5, $6, $7 }'
    log ""
    explain
    ;;

  rebuild)
    [ -n "$REPO" ] || REPO="$(cd "$ROOT" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
    [ -n "$REPO" ] || die "无法确定目标仓库：用 --repo OWNER/NAME 指定（重建需要读线上实况）"
    [ -n "$DEFAULT_BRANCH" ] || DEFAULT_BRANCH="$(gh repo view "$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name // ""' 2>/dev/null || true)"
    info "以「命名空间归属 + 出厂内容指纹」重建归属记账（模式：${MODE}）"
    log "  目标仓库：${REPO}（默认分支 ${DEFAULT_BRANCH:-?}）"
    log "  记账文件：${LEDGER}"
    probe_labels; probe_collaborators; probe_ruleset_ids
    ok "线上实况：标签 $(wc -l < "${TMP_DIR}/live_labels.tsv" | tr -d ' ') 条 / 协作请求 $(wc -l < "${TMP_DIR}/live_collab.tsv" | tr -d ' ') 条 / 规则集 $(wc -l < "${TMP_DIR}/live_rulesets.tsv" | tr -d ' ') 个"
    if [ -f "${KIT_DIR}/$(jq -r '.objects.labels.source' "$KIT_JSON")" ]; then
      parse_label_source "${KIT_DIR}/$(jq -r '.objects.labels.source' "$KIT_JSON")" > "${TMP_DIR}/want_labels.tsv"
    else
      : > "${TMP_DIR}/want_labels.tsv"
    fi

    OPS="${TMP_DIR}/ops.jsonl"; : > "$OPS"
    N_OWNED=0; N_UNKNOWN=0; N_ABSENT=0
    add() {  # $1 id, $2 owned(true/false), $3 observed(present/absent), $4 origin, $5 sha
      jq -c -n --arg id "$1" --argjson owned "$2" --arg obs "$3" --arg origin "$4" --arg sha "$5" \
         --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
         '{id:$id, v:({phase:(if $owned then "owned" else (if $obs=="absent" then "absent" else "observed" end) end),
              observed:$obs, owned:$owned, pre_existing:(if ($owned|not) and $obs=="present" then true else false end),
              origin:$origin, rebuilt:true, recorded_at:$ts} + (if $sha == "" then {} else {sha256:$sha} end))}' >> "$OPS"
    }

    # ① 文件 / workflow / 套件树：自证判据 = 目标内容（或整树指纹）与**出厂渲染内容**逐字节一致
    for class in files workflows kit; do
      jq -c ".objects.${class}.entries[]?" "$KIT_JSON" > "${TMP_DIR}/rb_${class}.txt"
      while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        id="$(render_str "$(jget "$entry" '.id')")"; path="$(jget "$entry" '.path')"
        if [ "$class" = "kit" ]; then
          if [ -d "${ROOT}/${path}" ] && same_dir "${KIT_DIR}" "${ROOT}/${path}"; then
            add "$id" true present "namespace+content-hash(就地运行)" "$(dir_hash "${ROOT}/${path}")"; N_OWNED=$((N_OWNED + 1))
          elif [ -d "${ROOT}/${path}" ]; then
            if [ "$(dir_hash "${ROOT}/${path}")" = "$(dir_hash "$KIT_DIR")" ]; then
              add "$id" true present "namespace+content-hash(整树一致)" "$(dir_hash "${ROOT}/${path}")"; N_OWNED=$((N_OWNED + 1))
            else
              pline_rb "[未知]" "$path" "套件树内容与出厂不一致 → 归属无法自证，保留不接管"
              add "$id" false present "unknown" ""; N_UNKNOWN=$((N_UNKNOWN + 1))
            fi
          else
            add "$id" false absent "namespace" ""; N_ABSENT=$((N_ABSENT + 1))
          fi
          continue
        fi
        tpl="$(jget "$entry" '.template // false')"; src="$(jget "$entry" '.source')"
        want="${TMP_DIR}/rb.want"; render_to "${KIT_DIR}/${src}" "$want" "$tpl"
        if [ ! -f "${ROOT}/${path}" ]; then
          add "$id" false absent "namespace" ""; N_ABSENT=$((N_ABSENT + 1))
        elif cmp -s "$want" "${ROOT}/${path}"; then
          add "$id" true present "namespace+content-hash" "$(file_hash "${ROOT}/${path}")"; N_OWNED=$((N_OWNED + 1))
        else
          pline_rb "[未知]" "$path" "已存在但与出厂内容不一致 → 归属无法自证，保留不接管"
          add "$id" false present "unknown" ""; N_UNKNOWN=$((N_UNKNOWN + 1))
        fi
      done < "${TMP_DIR}/rb_${class}.txt"
    done

    # ② 标签：声明里有 + 线上颜色/描述与出厂一致 → 自证；否则未知
    jq -c '.objects.labels.entries[]?' "$KIT_JSON" > "${TMP_DIR}/rb_labels.txt"
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      name="$(jget "$entry" '.name')"; id="$(render_str "$(jget "$entry" '.id')")"
      lv="$(live_label_row "$name")"
      if [ -z "$lv" ]; then add "$id" false absent "namespace" ""; N_ABSENT=$((N_ABSENT + 1)); continue; fi
      w="$(label_want "$name")"
      if [ -n "$w" ] && [ "$lv" = "$w" ]; then add "$id" true present "namespace+content-hash" ""; N_OWNED=$((N_OWNED + 1))
      else
        pline_rb "[未知]" "label ${name}" "与出厂颜色/描述不一致 → 归属无法自证，保留不接管"
        add "$id" false present "unknown" ""; N_UNKNOWN=$((N_UNKNOWN + 1))
      fi
    done < "${TMP_DIR}/rb_labels.txt"

    # ③ 规则集：名字带命名空间前缀 + 与出厂声明语义一致 → 自证
    jq -c '.objects.rulesets.entries[]?' "$KIT_JSON" > "${TMP_DIR}/rb_rulesets.txt"
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      name="$(jget "$entry" '.name')"; src="$(jget "$entry" '.source')"; id="$(render_str "$(jget "$entry" '.id')")"
      rid="$(ruleset_id_by_name "$name")"
      if [ -z "$rid" ]; then add "$id" false absent "namespace" ""; N_ABSENT=$((N_ABSENT + 1)); continue; fi
      ruleset_fetch "$rid" > "${TMP_DIR}/rb_live.json"
      if [ -s "${TMP_DIR}/rb_live.json" ] && [ -z "$(ruleset_diff "${KIT_DIR}/${src}" "${TMP_DIR}/rb_live.json")" ]; then
        add "$id" true present "namespace+content-hash" ""; N_OWNED=$((N_OWNED + 1))
      else
        pline_rb "[未知]" "ruleset ${name}" "已存在但参数与出厂声明不一致 → 归属无法自证，保留不接管"
        add "$id" false present "unknown" ""; N_UNKNOWN=$((N_UNKNOWN + 1))
      fi
    done < "${TMP_DIR}/rb_rulesets.txt"

    # ④ 协作者：属**持久权限**，命名空间帮不上忙（账号名不表达归属）→ 一律保守标记，绝不据此撤销
    jq -c '.objects.collaborators.entries[]?' "$KIT_JSON" > "${TMP_DIR}/rb_collabs.txt"
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      account="$(render_str "$(jget "$entry" '.account')")"; id="$(render_str "$(jget "$entry" '.id')")"
      push="$(live_collab_push "$account")"
      if [ -z "$push" ]; then add "$id" false absent "namespace" ""; N_ABSENT=$((N_ABSENT + 1))
      else
        pline_rb "[未知]" "collaborator ${account}" "持久权限无法由命名空间自证 → 保留（撤销需显式 --revoke-collaborators）"
        add "$id" false present "cannot-prove" ""; N_UNKNOWN=$((N_UNKNOWN + 1))
      fi
    done < "${TMP_DIR}/rb_collabs.txt"

    log ""
    info "重建小结：可自证归属（owned=true）${N_OWNED} 个 / 无法自证（保留不接管）${N_UNKNOWN} 个 / 实况不存在 ${N_ABSENT} 个"
    if [ "$MODE" != "apply" ]; then
      ok "dry-run 结束：零写入。要落盘请加 --apply（会覆盖 ${LEDGER}）"
      if [ "$N_UNKNOWN" -gt 0 ]; then
        warn "有 ${N_UNKNOWN} 个对象的归属无法自证：它们会被记为 owned=false（卸载时默认保留）—— 这是刻意的保守选择"
        exit 1
      fi
      exit 0
    fi
    ledger_init_if_missing
    tmp="$(mktemp "${TMP_DIR}/ledger.XXXXXX")"
    jq --slurpfile ops "$OPS" --arg repo "$REPO" --arg br "$DEFAULT_BRANCH" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --arg kv "$KIT_VERSION" '
      .repo = $repo | .default_branch = $br | .updated_at = $ts | .kit_version = $kv
      | .rebuilt = true | .rebuilt_at = $ts
      | .rebuilt_from = "namespace+factory-content-hash（设计 #68 §2.2；ledger 丢失可恢复）"
      | .entries = (reduce $ops[] as $o (.entries; .[$o.id] = $o.v))
    ' "$LEDGER" > "$tmp" && mv "$tmp" "$LEDGER"
    ok "归属记账已重建：${LEDGER}（$(jq -r '.entries | length' "$LEDGER") 个条目）"
    printf '%s\n' '  提示：重建只恢复"归属"，不恢复"历史细节"（谁在何时改过）—— 那部分确实随账本丢失。'
    printf '%s\n' '  卸载能力不再依赖它：命名空间归属 + 出厂内容指纹始终可用（设计 #68 §2.2）。'
    [ "$N_UNKNOWN" -eq 0 ] || exit 1
    ;;
esac
