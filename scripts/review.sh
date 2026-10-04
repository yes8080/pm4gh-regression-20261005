#!/usr/bin/env bash
# scripts/review.sh <pr#> <approve|request-changes|comment> [-m 文本 | --body-file 文件]
#
# W6「独立评审」：以**评审身份**执行（默认 $HOME/.config/pm4gh/reviewer.pat），不切换本机 gh 登录账号，**不得合并**。
#
# 凭据隔离（#94）：评审凭据**必须在工作区之外** —— 作者 agent 与你在同一工作区里运行，
# 工作区内的评审凭据 = 作者可读，「独立评审」就只剩名义。本脚本因此**拒绝**落在仓库内的路径，
# 缺凭据时打印**可执行**的搬移命令（这是机器判据，不是文档口号）。
#
# 为什么 approve 就是验收门禁：规则集用原生规则承担验收（required_approving_review_count=1 +
# require_code_owner_review + require_last_push_approval）。官方限制：必需检查不能"先失败后通过"，
# 所以不把验收做成自定义检查，也不用 /accept 评论（issue_comment 触发的检查不算必需检查）。
#
# 副作用：approve **不迁移状态** —— 批准后 Issue 停在 status/in-review（含义即「评审中 / 已批准待合并」）；
# request-changes → status/in-progress（同分支返修）。「被打回」**不设独立状态** —— 平台已免费提供
# reviewDecision=CHANGES_REQUESTED；状态迁移只走 status.sh 的合法边：
# in-review --(request-changes)--> in-progress --(deliver.sh)--> in-review --(合并关单 + closeout)--> done。

set -eu

# 评审凭据默认在**工作区之外**（#94）。不要改回仓库内路径 —— 那是作者可读范围。
REVIEWER_PAT_FILE="${REVIEWER_PAT_FILE:-${HOME}/.config/pm4gh/reviewer.pat}"

die()  { printf '[FAIL] %s\n' "${1:-}" >&2; exit "${2:-1}"; }
ok()   { printf '[ OK ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
info() { printf '\n== %s ==\n' "$*"; }

# ── 工作区判据（#94）────────────────────────────────────────
# WORKSPACE_ASSERT:BEGIN
# 凭据路径是否落在**工作区之内**（#94 的机器判据）：工作区内的凭据 = 作者可读，「独立评审」只剩名义。
# 把路径解析成**绝对路径**：父目录存在时用 `cd … && pwd -P`（解析符号链接，如 /tmp → /private/tmp），
# 否则退回词法归一化 —— 路径不存在也要能判定（凭据缺失正是要报的场景）。**不读文件内容**。
# 同一段文本也出现在另一个脚本里（每个脚本自包含，不引共享库），由 ci/test 断言两处**逐字一致**。
physical() {
  d="$(dirname "${1:-}")"; b="$(basename "${1:-}")"
  if [ -d "$d" ]; then
    d="$(cd "$d" && pwd -P)"
    case "$d" in /) printf '/%s\n' "$b" ;; *) printf '%s/%s\n' "$d" "$b" ;; esac
  else
    abspath "${1:-}"
  fi
}

abspath() {
  p="${1:-}"
  case "$p" in /*) : ;; *) p="$(pwd -P)/${p}" ;; esac
  out=""; rest="$p"
  while [ -n "$rest" ]; do
    case "$rest" in
      */*) seg="${rest%%/*}"; rest="${rest#*/}" ;;
      *)   seg="$rest"; rest="" ;;
    esac
    case "$seg" in
      ''|.) : ;;
      ..)   out="${out%/*}" ;;
      *)    out="${out}/${seg}" ;;
    esac
  done
  printf '%s\n' "${out:-/}"
}

# 命中工作区（含仓库根自身）→ 0；否则 1。仓库根取 `git rev-parse --show-toplevel` 的物理路径。
pat_in_workspace() {
  ws_root="$(cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)" && pwd -P)"
  case "$(physical "${1:-}")" in
    "$ws_root"|"$ws_root"/*) return 0 ;;
    *) return 1 ;;
  esac
}
# WORKSPACE_ASSERT:END

PR=""
ACTION=""
MSG=""
BODY_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    -m|--message) MSG="${2:?需要取值}"; shift 2 ;;
    --body-file)  BODY_FILE="${2:?需要取值}"; shift 2 ;;
    -h|--help)    sed -n '2,17p' "$0"; exit 0 ;;
    *) if [ -z "$PR" ]; then PR="$1"; else ACTION="$1"; fi; shift ;;
  esac
done

[ -n "$PR" ] && [ -n "$ACTION" ] || die "用法：scripts/review.sh <pr#> <approve|request-changes|comment> [-m 文本 | --body-file 文件]"
case "$PR" in *[!0-9]*) die "PR 编号必须是数字：${PR}" ;; esac
case "$ACTION" in approve|request-changes|comment) : ;; *) die "不支持的动作：${ACTION}（只允许 approve|request-changes|comment；合并不在这里）" ;; esac
[ -f .github/rulesets/main-protection.json ] || die "请在仓库根目录运行"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
[ -n "$REPO" ] || die "无法确定仓库 slug（gh repo view 失败）"

# ── 评审身份（凭据必须在工作区之外 —— #94 的机器判据）──────────
REPO_ROOT="$(cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)" && pwd -P)"
REVIEWER_PAT_ABS="$(physical "$REVIEWER_PAT_FILE")"
if pat_in_workspace "$REVIEWER_PAT_FILE"; then
  die "评审凭据必须在**工作区之外**（#94），但给定路径落在仓库内
       给定：${REVIEWER_PAT_FILE}
       解析：${REVIEWER_PAT_ABS}
       仓库根：${REPO_ROOT}
       原因：作者 agent 与你在同一工作区里运行 —— 工作区内的评审凭据 = 作者可读，独立评审只剩名义
       搬移（由 PM / dispatcher 在**工作区外**执行；本脚本不搬移、不复制、不打印凭据）：
         mkdir -p \"\${HOME}/.config/pm4gh\" && chmod 700 \"\${HOME}/.config/pm4gh\"
         mv \"${REVIEWER_PAT_ABS}\" \"\${HOME}/.config/pm4gh/reviewer.pat\"
         chmod 600 \"\${HOME}/.config/pm4gh/reviewer.pat\"
       之后按默认路径调用：scripts/review.sh <pr#> approve --body-file <文件>"
fi
ok "评审凭据在工作区之外：${REVIEWER_PAT_ABS}"

if [ ! -s "$REVIEWER_PAT_FILE" ]; then
  die "缺少评审凭据（或不可读）：${REVIEWER_PAT_ABS}
       评审凭据必须在工作区之外（#94）—— 不要放回 .secrets/：那是作者可读范围
       开通 / 搬移（由 PM / dispatcher 执行）：
         mkdir -p \"\${HOME}/.config/pm4gh\" && chmod 700 \"\${HOME}/.config/pm4gh\"
         mv .secrets/reviewer.pat \"\${HOME}/.config/pm4gh/reviewer.pat\"    # 若凭据仍在工作区内
         chmod 600 \"\${HOME}/.config/pm4gh/reviewer.pat\"
         # 该账号尚无 PAT 时：在 GitHub 生成 classic PAT（scope: repo）后写入上面这个路径
       临时指定其它工作区外路径：REVIEWER_PAT_FILE=/绝对路径/reviewer.pat scripts/review.sh <pr#> approve --body-file <文件>"
fi
GH_TOKEN="$(cat "$REVIEWER_PAT_FILE")"
export GH_TOKEN
unset GITHUB_TOKEN || true
REVIEWER="$(gh api user --jq .login 2>/dev/null || true)"
# 失败时 gh 会把错误正文（JSON）留在 stdout —— 登录名只可能是 [A-Za-z0-9-]，据此把它判成"无效"
case "$REVIEWER" in
  ''|*[!A-Za-z0-9-]*) die "评审凭据无效（无法认证）：读不到登录名（过期 / 被撤销 / 不是 classic PAT）—— 见 docs/WORKFLOW.md §0" ;;
esac
ok "评审身份：${REVIEWER}"

can_push="$(gh api "repos/${REPO}" --jq '.permissions.push' 2>/dev/null || true)"
[ "$can_push" = "true" ] || die "评审身份 ${REVIEWER} 对本仓库没有写权限 —— 其评审不计入门禁（邀请未接受？）"

author="$(gh pr view "$PR" -R "$REPO" --json author --jq .author.login 2>/dev/null || true)"
state="$(gh pr view "$PR" -R "$REPO" --json state --jq .state 2>/dev/null || true)"
[ -n "$author" ] || die "PR #${PR} 不存在或无法访问"
info "PR #${PR}（状态 ${state}）作者：${author}；评审：${REVIEWER}"
[ "$REVIEWER" != "$author" ] || die "评审身份与作者相同 —— 独立评审失去意义（平台也会拒绝自我批准）"
[ "$state" = "OPEN" ] || die "PR 状态为 ${state}，无法再评审"
ok "身份独立（评审 ≠ 作者）"

if [ -z "$MSG" ] && [ -n "$BODY_FILE" ]; then
  [ -f "$BODY_FILE" ] || die "找不到正文文件 ${BODY_FILE}"
  MSG="$(cat "$BODY_FILE")"
fi

case "$ACTION" in
  approve)
    [ -n "$MSG" ] || die "approve 必须给出可审计的评审意见（-m 或 --body-file）"
    gh pr review "$PR" -R "$REPO" --approve --body "$MSG"
    ok "已批准 —— 满足「1 名非作者 code owner 批准」"
    ;;
  request-changes)
    [ -n "$MSG" ] || die "request-changes 必须给出**可核对的返修清单**（-m 或 --body-file）"
    gh pr review "$PR" -R "$REPO" --request-changes --body "$MSG"
    ok "已请求修改 —— 作者在**同一分支**继续提交（不要新建分支/PR）"
    ;;
  comment)
    [ -n "$MSG" ] || die "comment 需要正文"
    gh pr review "$PR" -R "$REPO" --comment --body "$MSG"
    ok "已提交评论（不改变门禁状态）"
    ;;
esac

# ── 状态迁移（目标 = 分支名里的 issue 号，与 policy/branch-name 同源）──
target=""
head_ref="$(gh pr view "$PR" -R "$REPO" --json headRefName --jq .headRefName 2>/dev/null || true)"
case "$head_ref" in
  */*) cand="${head_ref#*/}"; cand="${cand%%-*}"
       case "$cand" in ''|*[!0-9]*) : ;; *) target="$cand" ;; esac ;;
esac
if [ -z "$target" ]; then
  target="$(gh pr view "$PR" -R "$REPO" --json closingIssuesReferences \
    --jq '.closingIssuesReferences[0].number // ""' 2>/dev/null || true)"
  [ -n "$target" ] && warn "无法从分支名解析 issue 号，回退到 closingIssuesReferences[0] = #${target}"
fi
if [ -n "$target" ]; then
  is_linked="$(gh pr view "$PR" -R "$REPO" --json closingIssuesReferences \
    --jq "[.closingIssuesReferences[].number] | index(${target}) != null" 2>/dev/null || echo false)"
  if [ "$is_linked" = "true" ]; then
    case "$ACTION" in
      approve)
        ok "approve 不迁移状态：Issue #${target} 停在 in-review（= 已批准待合并；done 由合并关单 + closeout 清理）" ;;
      request-changes)
        "$(dirname "$0")/status.sh" "$target" in-progress ;;
      *) : ;;
    esac
  else
    warn "分支对应的 Issue #${target} 不在本 PR 的关联 Issue 中，跳过状态迁移（避免误标）"
  fi
else
  warn "无法确定状态迁移目标，跳过（Issue 状态请手工用 scripts/status.sh 修正）"
fi

echo
info "当前门禁状态"
gh pr view "$PR" -R "$REPO" --json reviewDecision,mergeStateStatus \
  --jq '"  reviewDecision=\(.reviewDecision)  mergeStateStatus=\(.mergeStateStatus)"'
printf '  合并只能由 dispatcher 执行：gh pr merge %s --squash --delete-branch\n' "$PR"
