#!/usr/bin/env bash
# scripts/review.sh <pr#> <approve|request-changes|comment|accept|reject> [-m 文本 | --body-file 文件]
#
# W6/W7「独立评审与验收」：以**授权评审身份**执行，不切换你本机 gh 的登录账号。
#
# 身份机制（方案 §6.2 D2 / 附录 C.3）：
#   · 作者身份 = gh 已登录账号（不能自我批准，平台会拒绝）
#   · 评审/验收身份 = .secrets/reviewer.pat（classic token，只勾 repo）
#     注意：fine-grained PAT **无法**用于"用户作为 collaborator 的仓库"，故必须 classic
#
# 验收的机器门禁说明（Bug #13 教训）：
#   · `/accept` 评论是**人工审计证据**，不是合并阻塞条件 —— 官方限制：`issue_comment` 触发的
#     检查不满足必需检查；且必需检查不能"先失败后通过"
#   · 真正的合并门禁是规则集的原生规则：required_approving_review_count + require_last_push_approval
#   · 因此 approve 才是让 PR 可合并的动作，accept 只是留下验收记录

set -eu
. "$(dirname "$0")/lib.sh"

PR=""
ACTION=""
MSG=""
BODY_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    -m|--message) MSG="${2:?需要取值}"; shift 2 ;;
    --body-file)  BODY_FILE="${2:?需要取值}"; shift 2 ;;
    -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
    *) if [ -z "$PR" ]; then PR="$1"; else ACTION="$1"; fi; shift ;;
  esac
done

[ -n "$PR" ] && [ -n "$ACTION" ] || die "用法：scripts/review.sh <pr#> <approve|request-changes|comment|accept|reject>"
case "$PR" in *[!0-9]*) die "PR 编号必须是数字：${PR}" ;; esac
case "$ACTION" in approve|request-changes|comment|accept|reject) : ;; *) die "不支持的动作：${ACTION}" ;; esac

require_repo_root
use_reviewer_identity

reviewer="$(gh api user --jq .login)"
author="$(pr_author "$PR")"
state="$(pr_state "$PR")"

info "PR #${PR}（状态 ${state}）"
info "作者身份：${author}"
info "评审身份：${reviewer}"

[ "$reviewer" != "$author" ] || die "评审身份与作者相同 —— 独立评审失去意义（平台也会拒绝自我批准）"
[ "$state" = "OPEN" ] || die "PR 状态为 ${state}，无法再评审"

if ! authorized_identities | grep -qx "$reviewer"; then
  die "身份 ${reviewer} 不在 ${AUTH_IDENTITIES_FILE} 中，其评审不计入验收"
fi
ok "身份在授权清单内"

if [ -z "$MSG" ] && [ -n "$BODY_FILE" ]; then
  [ -f "$BODY_FILE" ] || die "找不到正文文件 ${BODY_FILE}"
  MSG="$(cat "$BODY_FILE")"
fi

case "$ACTION" in
  approve)
    [ -n "$MSG" ] || die "approve 必须给出评审意见（-m 或 --body-file）：门禁要求可审计的评审理由"
    gh pr review "$PR" -R "$REPO" --approve --body "$MSG"
    ok "已批准 —— PR 现在满足审批与 code-owner 要求"
    ;;
  request-changes)
    [ -n "$MSG" ] || die "request-changes 必须给出**可核对的返修清单**（-m 或 --body-file）"
    gh pr review "$PR" -R "$REPO" --request-changes --body "$MSG"
    ok "已请求修改 —— 返修后在**同一分支**继续提交（不要新建分支/PR）"
    ;;
  comment)
    [ -n "$MSG" ] || die "comment 需要正文"
    gh pr review "$PR" -R "$REPO" --comment --body "$MSG"
    ok "已提交评论（不改变门禁状态）"
    ;;
  accept)
    gh pr comment "$PR" -R "$REPO" --body "/accept

${MSG}"
    ok "已留下验收记录 /accept（审计证据；合并门禁由 approve 满足）"
    ;;
  reject)
    [ -n "$MSG" ] || die "reject 必须列出差距"
    gh pr comment "$PR" -R "$REPO" --body "/reject

${MSG}"
    ok "已记录验收不通过 —— 按 W9 返修（同一分支继续提交）"
    ;;
esac

# ── 状态迁移（决策 D9：状态由 status/* 标签承载）────────────
# ★ 目标选择规则（Bug #32 修复）：优先取**分支名中的 issue 号**，与 policy/branch-name 同源。
#   原因："一个切片 = 一个 Issue = 一个分支 = 一个 PR"；而 PR 正文可能同时写 Fixes #N 关闭别的 Issue，
#   直接取 closingIssuesReferences[0] 会把状态打到错误的 Issue 上（静默错误，且 closeout 第五项才会暴露）。
#   放在脚本最后执行：status.sh 会切回主身份（unset GH_TOKEN），不影响上面的评审动作。
target=""
head_ref="$(gh pr view "$PR" -R "$REPO" --json headRefName --jq .headRefName 2>/dev/null || true)"
case "$head_ref" in
  */*)
    cand="${head_ref#*/}"; cand="${cand%%-*}"
    case "$cand" in
      ''|*[!0-9]*) : ;;
      *) target="$cand" ;;
    esac
    ;;
esac
if [ -z "$target" ]; then
  target="$(gh pr view "$PR" -R "$REPO" --json closingIssuesReferences \
    --jq '.closingIssuesReferences[0].number // ""' 2>/dev/null || true)"
  [ -n "$target" ] && warn "无法从分支名解析 issue 号，回退到 closingIssuesReferences[0] = #${target}"
fi

if [ -n "$target" ]; then
  # 校验：目标必须确实在本 PR 的关联 Issue 中，避免误标
  is_linked="$(gh pr view "$PR" -R "$REPO" --json closingIssuesReferences \
    | jq -r --argjson n "$target" 'any(.closingIssuesReferences[]; .number == $n)' 2>/dev/null || echo false)"
  if [ "$is_linked" = "true" ]; then
    case "$ACTION" in
      approve)                "$(dirname "$0")/status.sh" "$target" acceptance ;;
      request-changes|reject) "$(dirname "$0")/status.sh" "$target" rework ;;
      *) : ;;
    esac
  else
    warn "分支对应的 Issue #${target} 不在本 PR 的关联 Issue 中，跳过状态迁移（避免误标）"
  fi
else
  warn "无法确定状态迁移目标（分支名与关联 Issue 都取不到），跳过"
fi

echo
log "当前门禁状态："
gh pr view "$PR" -R "$REPO" --json reviewDecision,mergeStateStatus \
  --jq '"  reviewDecision=\(.reviewDecision)  mergeStateStatus=\(.mergeStateStatus)"'
