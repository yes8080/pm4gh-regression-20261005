#!/usr/bin/env bash
# toolkit/scripts/check-invariants.sh —— 治理套件的**机器不变量检查**（离线，不联网、零写入）
#
# 为什么需要它（Issue #69 S-A 的两条验收标准）：
#   ① **不变量 B「门禁自包含」**（NFR-07 / AC-06）：装到目标仓库的门禁**不得引用未安装的资产**。
#      S3 演练的 F2 就是这个形态：装出来的 `ci/test` 引用宿主私有的 `scripts/sync-labels.sh`，
#      目标仓库里根本没有它 → 步骤"看起来在跑"其实什么都没验（F3 假绿）。
#      判据：`payload 引用集 ⊆ 安装集`。
#   ② **补「无 PR 时门禁停摆」缺口**：5 项必需检查只在 pull_request/merge_group 触发，仓库里
#      没有开放 PR 时**从不运行**；此时若受管资产被删、命名空间被破坏、门禁引用了不存在的资产，
#      没有任何检查会报。`--check state` 就是给"没有 PR"这个场景准备的状态一致性断言：
#      **它只读仓库内容**（不需要 PR、不需要网络、不需要 gh），因此可以在 push / workflow_dispatch
#      上跑 —— 这正是 `.github/workflows/governance-state.yml` 做的事。
#
# 用法（可在套件源码仓库运行，也可在采用者仓库运行：套件在 .github/governance/kit/ 下）：
#   scripts/check-invariants.sh                      # = --check all
#   scripts/check-invariants.sh --check invariant-b  # 只跑门禁自包含
#   scripts/check-invariants.sh --check namespace    # 只跑命名空间归属
#   scripts/check-invariants.sh --check codeowners   # 只跑"不装不可满足的门禁"
#   scripts/check-invariants.sh --check gates        # 只跑"必需检查都有 job"
#   scripts/check-invariants.sh --check state        # 无 PR 场景的状态一致性（含以上全部 + 触发器自守）
# 参数：--kit-dir DIR（默认：本脚本的上一级）｜--root DIR（默认：向上找 .git）｜--ledger FILE
# 退出码：0 全部通过；1 有违规；2 参数/环境错误
set -eu

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
KIT_DIR="$(cd "${SELF_DIR}/.." && pwd)"
ROOT=""
LEDGER=""
CHECKS=""
WANT_ALL=1

die() { printf '[FAIL] %s\n' "$1" >&2; exit 2; }
usage() { sed -n '2,30p' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --kit-dir) KIT_DIR="${2:?--kit-dir 需要取值}"; shift ;;
    --root)    ROOT="${2:?--root 需要取值}"; shift ;;
    --ledger)  LEDGER="${2:?--ledger 需要取值}"; shift ;;
    --check)   CHECKS="${CHECKS} ${2:?--check 需要取值}"; WANT_ALL=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：${1}（见 --help）" ;;
  esac
  shift
done
[ -d "$KIT_DIR" ] || die "套件目录不存在：${KIT_DIR}"
[ -f "${KIT_DIR}/kit.yaml" ] || die "找不到出厂声明：${KIT_DIR}/kit.yaml"
if [ "$WANT_ALL" -eq 1 ]; then CHECKS=" invariant-b namespace codeowners gates state"; fi
# `--check state` 是"无 PR 场景"的完整断言 → 隐含其余不变量（否则它只会检查触发器，价值有限）
case " ${CHECKS} " in *" state "*) CHECKS="${CHECKS} invariant-b namespace codeowners gates" ;; esac
CHECKS="$(printf '%s\n' ${CHECKS} | awk 'NF' | sort -u | tr '\n' ' ')"

# 仓库根：显式指定 → 否则从套件目录向上找 .git
if [ -z "$ROOT" ]; then
  d="$KIT_DIR"
  while [ "$d" != "/" ] && [ ! -d "${d}/.git" ]; do d="$(dirname "$d")"; done
  if [ -d "${d}/.git" ]; then ROOT="$d"; else ROOT="$(cd "${KIT_DIR}/../../.." 2>/dev/null && pwd || printf '/')"; fi
fi

# 复用 toolkit/lib.sh 的**同一份**判据（命名空间/指纹/声明加载）—— 不允许出现第二份实现。
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/toolkit-invariants.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM
KIT_YAML="${KIT_DIR}/kit.yaml"
: "${OWNER:=}"; : "${REVIEWER_ACCOUNT:=}"; : "${REPO:=}"; : "${DEFAULT_BRANCH:=}"; : "${AUTHOR_ACCOUNT:=}"
KIT_ROOT="$(python3 "${KIT_DIR}/scripts/yaml2json.py" "$KIT_YAML" 2>/dev/null | jq -r '.objects.kit.entries[0].path // ".github/governance/kit"')"
KIT_GOVERNANCE_DIR="$(python3 "${KIT_DIR}/scripts/yaml2json.py" "$KIT_YAML" 2>/dev/null | jq -r '.namespace.managed_files // ".github/governance/"')"
KIT_GOVERNANCE_DIR="${KIT_GOVERNANCE_DIR%/}"
. "${KIT_DIR}/lib.sh"
kit_load
[ -n "$LEDGER" ] || LEDGER="$(ledger_default "$ROOT")"

V_OK=0; V_BAD=0
vok()  { V_OK=$((V_OK + 1)); printf '  [PASS] %s\n' "$1"; }
vbad() { V_BAD=$((V_BAD + 1)); printf '  [FAIL] %s\n' "$1"; }
have() { case " ${CHECKS} " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# ── ① 不变量 B：payload 引用集 ⊆ 安装集 ─────────────────────────────
# 扫描**会被安装的门禁资产**（kit.yaml 声明的 workflow 源文件）里的路径引用：
#   (a) `@@KIT_ROOT@@/<相对路径>`      → 必须存在于套件树内（否则装上去就是死链）
#   (b) 裸的 `*.sh` / `*.py` 路径      → 必须是 `@@KIT_ROOT@@/...`（套件自带），否则就是引用宿主私有资产（F2）
#   (c) `.github/...` 引用             → 必须是已声明的受管文件/工作流路径，或平台强制路径
# 边界（如实写明）：只检查**门禁的执行依赖**，不检查文档 URL / 注释里的举例 ——
# 后者不是门禁输入（例如 Issue 模板里的 docs/PLAYBOOK.md 链接）。
check_invariant_b() {
  printf '[检查] 不变量 B：门禁自包含（payload 引用集 ⊆ 安装集）\n'
  local wf_sources inst_paths kit_root bad=0 n=0 src ref rel cls
  inst_paths="${TMP_DIR}/inst_paths.txt"
  jq -r '.objects.files.entries[]?.path, .objects.workflows.entries[]?.path' "$KIT_JSON" | LC_ALL=C sort -u > "$inst_paths"
  kit_root="$KIT_ROOT"
  wf_sources="$(jq -r '.objects.workflows.entries[]?.source' "$KIT_JSON")"
  if [ -z "$wf_sources" ]; then vbad "kit.yaml 没有声明任何 workflow（门禁为空？）"; return 0; fi
  refs="${TMP_DIR}/refs.txt"; : > "$refs"
  # 提取口径（必须写清，否则会变成"看起来在跑其实什么都没验"）：
  #   · 只取**命令位置**的路径引用 —— `echo` / `printf` 的消息文本不是执行依赖
  #     （早期版本把消息里的 scripts/status.sh、install.sh 误报成依赖，全是假阳性）；
  #   · 单引号串（多为 grep/jq 的表达式）先剥掉，双引号串保留（命令替换里的路径才是真依赖）；
  #   · 从 `@@PLACEHOLDER@@` 开始匹配，随后用 kit.yaml 的 placeholders 表解析回真实路径。
  while IFS= read -r src; do
    [ -n "$src" ] || continue
    [ -f "${KIT_DIR}/${src}" ] || { vbad "声明的 workflow 源文件不存在：${src}"; bad=1; continue; }
    grep -vE '^[[:space:]]*#' "${KIT_DIR}/${src}" \
      | grep -vE '^[[:space:]]*(echo|printf)\b' \
      | sed -E "s/'[^']*'//g" \
      | grep -oE '@@[A-Z_]+@@/[A-Za-z0-9_][A-Za-z0-9_./*-]*|(@@[A-Z_]+@@)?\.github/[A-Za-z0-9_][A-Za-z0-9_./*-]*|(@@KIT_ROOT@@/)?[A-Za-z0-9_][A-Za-z0-9_./-]*\.(sh|py)' \
      | sort -u >> "$refs" || true
  done <<EOF
${wf_sources}
EOF
  # 占位符 → 真实安装路径（唯一来源：kit.yaml 的 placeholders 段 + namespace/objects）
  jq -r '.placeholders | to_entries[] | select(.key != "why") | "@@\(.key)@@\t\(.value)"' "$KIT_JSON" > "${TMP_DIR}/ph.tsv"
  resolve() {  # $1 = 引用 → 解析后的路径（解析不了就原样返回）
    local r="$1" k v
    while IFS="$(printf '\t')" read -r k v; do
      [ -n "${k}" ] || continue
      case "$r" in "${k}"*) r="${v}${r#${k}}"; break ;; esac
    done < "${TMP_DIR}/ph.tsv"
    printf '%s' "$r"
  }
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    n=$((n + 1))
    rel="$(resolve "$ref")"
    case "$rel" in
      .github/workflows/*)
        # workflow 的 glob 引用：允许（采用者自己也可能有 workflow 产生同一检查名）
        : ;;
      "${kit_root}"/*|.github/governance/*)
        if [ ! -e "${KIT_DIR}/${rel#${kit_root}/}" ] && [ ! -e "${ROOT}/${rel}" ] && ! grep -Fxq -- "$rel" "$inst_paths"; then
          printf '         - %s → 解析为 %s：套件树与安装集里都不存在\n' "$ref" "$rel"; bad=1
        fi ;;
      .github/CODEOWNERS)
        # 用户既有文件：允许**引用**，前提是规则集没开 code-owner 评审
        # （否则就是装了一个"套件自己无法满足"的门禁；那条由 --check codeowners 断言）
        if jq -e '[.objects.rulesets.entries[].source] | length > 0' "$KIT_JSON" >/dev/null 2>&1; then
          if jq -e 'any(.rules[]? | select(.type=="pull_request") | .parameters.require_code_owner_review; . == true)' \
               "${KIT_DIR}/$(jq -r '.objects.rulesets.entries[0].source' "$KIT_JSON")" >/dev/null 2>&1; then
            printf '         - %s → 引用了用户 CODEOWNERS，但规则集开了 require_code_owner_review（套件不改写它 → 可能永久不可合并）\n' "$ref"; bad=1
          fi
        fi ;;
      .github/*)
        if ! grep -Fxq -- "$rel" "$inst_paths"; then
          if ! jq -e --arg p "$rel" 'any(.namespace.file_exemptions[]?; .path as $x | $p | startswith($x))' "$KIT_JSON" >/dev/null 2>&1; then
            printf '         - %s → 解析为 %s：不在安装集（objects.files/workflows 的 path）里\n' "$ref" "$rel"; bad=1
          fi
        fi ;;
      *)
        printf '         - %s → 不是套件自带资产（门禁资产必须写成 @@KIT_ROOT@@/<路径>，见 kit.yaml 的 placeholders）\n' "$ref"; bad=1 ;;
    esac
  done < "$refs"
  if [ "$n" -eq 0 ]; then
    vbad "没有从 workflow 里提取到任何资产引用 —— 覆盖面为空，本检查形同虚设"
  elif [ "$bad" -eq 0 ]; then
    vok "不变量 B 成立：${n} 条资产引用全部落在安装集内（引用集 ⊆ 安装集；占位符已按 kit.yaml.placeholders 解析）"
  else
    vbad "不变量 B 被破坏：上面的引用指向未安装/不存在的资产（装上去的必需检查必然假绿或直接失败 —— Bug #61 F2/F3）"
  fi
}

# ── ② 命名空间归属 ─────────────────────────────────────────────────
check_namespace() {
  printf '[检查] 命名空间归属（文件 %s** / workflow %s*.yml / 标签 %s / 规则集 %s*）\n' \
    "$(ns_files)" "$(ns_workflows)" "$(ns_labels)" "$(ns_rulesets)"
  local bad gap
  bad="$(namespace_violations)"; gap="$(namespace_exemption_gaps)"
  if [ -z "$bad" ] && [ -z "$gap" ]; then
    vok "全部受管对象都在命名空间内（或已显式豁免），且每条豁免都写了理由"
  else
    if [ -n "$bad" ]; then
      printf '%s\n' "$bad" | while IFS="$(printf '\t')" read -r c i w; do
        [ -n "${c}" ] || continue; printf '         - [%s] %s：%s\n' "${c}" "${i}" "${w}"; done
    fi
    if [ -n "$gap" ]; then printf '         - 豁免缺理由：%s\n' "$(printf '%s' "$gap" | tr '\n' ' ')"; fi
    vbad "命名空间归属被破坏（受管对象越界或豁免未写理由）"
  fi
}

# ── ③ 不装"套件自己无法满足"的门禁（NFR-17 + Bug #13/F4）─────────────
check_codeowners() {
  printf '[检查] 不装不可满足的门禁：CODEOWNERS 只报告 + 规则集不得开 code-owner 评审\n'
  local managed n bad=0
  managed="$(jq -r '[.objects | to_entries[] | select(.key=="codeowners")] | length' "$KIT_JSON")"
  [ "$managed" = "0" ] || { vbad "kit.yaml 仍把 codeowners 当受管对象（NFR-17：绝不就地改写用户既有文件）"; bad=1; }
  jq -e '.report_only.codeowners.suggested_lines | length > 0' "$KIT_JSON" >/dev/null 2>&1 \
    || { vbad "kit.yaml 未给出 CODEOWNERS 建议行（report_only.codeowners.suggested_lines）"; bad=1; }
  n="$(jq -r '.objects.rulesets.entries[].source' "$KIT_JSON" | wc -l | tr -d ' ')"
  while IFS= read -r src; do
    [ -n "$src" ] || continue
    [ -f "${KIT_DIR}/${src}" ] || { vbad "规则集源文件不存在：${src}"; bad=1; continue; }
    if jq -e '[.rules[] | select(.type=="pull_request") | .parameters.require_code_owner_review] | any(. == true)' "${KIT_DIR}/${src}" >/dev/null 2>&1; then
      vbad "payload 规则集 ${src} 开了 require_code_owner_review，但套件不改写采用者的 CODEOWNERS → 该门禁在采用者侧可能永久无法满足（Bug #13 同型）"
      bad=1
    fi
  done <<EOF
$(jq -r '.objects.rulesets.entries[].source' "$KIT_JSON")
EOF
  if [ "$bad" -eq 0 ]; then vok "CODEOWNERS 只报告不写入（${n} 个规则集均未开 require_code_owner_review）"; fi
}

# ── ④ 门禁覆盖：规则集里的必需检查必须都有 workflow job ───────────────
check_gates() {
  printf '[检查] 门禁覆盖：规则集必需检查 ⊆ 声明的 workflow job 名\n'
  local req wf missing
  : > "${TMP_DIR}/req.txt"; : > "${TMP_DIR}/wfjobs.txt"
  while IFS= read -r src; do
    [ -n "$src" ] || continue
    [ -f "${KIT_DIR}/${src}" ] || continue
    jq -r '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context' "${KIT_DIR}/${src}" >> "${TMP_DIR}/req.txt"
  done <<EOF
$(jq -r '.objects.rulesets.entries[].source' "$KIT_JSON")
EOF
  jq -r '.objects.workflows.entries[]?.checks[]?' "$KIT_JSON" | sort -u > "${TMP_DIR}/wfjobs.txt"
  sort -u "${TMP_DIR}/req.txt" > "${TMP_DIR}/req_sorted.txt"
  missing="$(comm -23 "${TMP_DIR}/req_sorted.txt" "${TMP_DIR}/wfjobs.txt" | tr '\n' ' ')"
  if [ -n "$(printf '%s' "$missing" | tr -d ' ')" ]; then
    vbad "以下必需检查没有任何受管 workflow 会产生它（会让所有 PR 永久 pending）：${missing}"
  elif [ ! -s "${TMP_DIR}/req_sorted.txt" ]; then
    vbad "规则集没有声明任何必需检查 —— 覆盖面为空，本检查形同虚设"
  else
    vok "规则集必需检查全部有对应 job：$(tr '\n' ' ' < "${TMP_DIR}/req_sorted.txt")"
  fi
}

# ── ⑤ 无 PR 场景的状态一致性（补「门禁停摆」缺口）──────────────────────
check_state() {
  printf '[检查] 无 PR 场景的状态一致性（不需要 PR / 不需要网络）\n'
  local state_src bad=0
  state_src="$(jq -r '.objects.workflows.entries[]? | select((.checks // []) | index("ci/state")) | .source' "$KIT_JSON" | head -1)"
  if [ -z "$state_src" ]; then
    vbad "kit.yaml 没有声明带 ci/state 的 workflow —— 「无 PR 时门禁停摆」缺口没有补救措施"
    return 0
  fi
  [ -f "${KIT_DIR}/${state_src}" ] || { vbad "状态一致性工作流源文件不存在：${state_src}"; return 0; }
  # 触发器自守：本工作流必须声明**非 PR** 触发器，否则缺口回归（删掉 push/workflow_dispatch 即失败）
  if ! grep -qE '^[[:space:]]*push:' "${KIT_DIR}/${state_src}"; then
    printf '         - %s 缺少 push 触发器\n' "$state_src"; bad=1
  fi
  if ! grep -qE '^[[:space:]]*workflow_dispatch:' "${KIT_DIR}/${state_src}"; then
    printf '         - %s 缺少 workflow_dispatch 触发器\n' "$state_src"; bad=1
  fi
  # 状态一致性：命名空间 + 不变量 B 在此场景下也必须成立（它们才是"漂移"的判据）
  # 记账存在时：owned=true 的文件类对象必须真的在
  local missing=""
  if [ -f "$LEDGER" ]; then
    while IFS="$(printf '\t')" read -r id present; do
      [ -n "${id}" ] || continue
      case "${id}" in
        file:*|workflow:*)
          rel="${id#file:}"; rel="${rel#workflow:}"
          [ -e "${ROOT}/${rel}" ] || missing="${missing} ${rel}" ;;
      esac
    done <<EOF
$(jq -r '.entries | to_entries[] | select(.value.owned == true) | "\(.key)\t1"' "$LEDGER")
EOF
    if [ -n "$missing" ]; then
      printf '         - ledger 记 owned=true 但已不存在：%s\n' "${missing}"
      bad=1
    fi
  else
    printf '         · 记账不存在（%s）—— 这是 CI 里的正常状态（ledger 在 .git/ 下、不进版本库）；\n' "$LEDGER"
    printf '           归属改由**命名空间**自证：本次仍按命名空间 + 不变量断言判定状态一致性。\n'
  fi
  if [ "$bad" -eq 0 ]; then
    vok "无 PR 场景状态一致：非 PR 触发器就位（${state_src}）+ 命名空间/不变量成立 + 记账与实况一致（或记账缺失时以命名空间兜底）"
  else
    vbad "无 PR 场景状态不一致（上面的缺口正是"没有 PR 时无人发现"的那一类漂移）"
  fi
}

# ── 主流程 ────────────────────────────────────────────────────────────
printf '治理套件不变量检查 —— 套件目录：%s\n' "${KIT_DIR}"
printf '  仓库根：%s\n' "${ROOT}"
printf '  检查项：%s\n' "$(printf '%s' "$CHECKS" | sed -E 's/^ +//')"
if have invariant-b; then check_invariant_b; fi
if have namespace;   then check_namespace;   fi
if have codeowners;  then check_codeowners;  fi
if have gates;       then check_gates;       fi
if have state;       then check_state;       fi
printf '不变量检查结果：PASS=%s FAIL=%s\n' "${V_OK}" "${V_BAD}"
if [ "${V_BAD}" -eq 0 ]; then
  printf '全部通过 ✅\n'
  exit 0
fi
printf '存在失败项 ❌\n'
exit 1
