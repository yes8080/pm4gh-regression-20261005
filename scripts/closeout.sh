#!/usr/bin/env bash
# scripts/closeout.sh <pr#> [--dry-run]
#
# W8「合并与收尾」的四项核验，一条命令跑完：
#   ① PR 已合并（squash）
#   ② 关联 Issue 已自动关闭
#   ③ 远程头分支已删除
#   ④ 本地头分支已清理
#
# ★ 本脚本承担 Bug #10 的修复要求（squash 合并的固有副作用）：
#   squash 合并后，原始提交在 main 上不存在，git 基于祖先关系的"已合并"判定必然失败，
#   因此 `git branch -d` 会**拒绝**删除本地分支。
#   正确做法：**先验证 PR 状态为 MERGED，再使用 -D**。
#   **禁止无条件 -D** —— 那会掩盖"PR 尚未合并就删掉本地分支"这类真实错误。

set -eu
. "$(dirname "$0")/lib.sh"

PR=""
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) PR="$1"; shift ;;
  esac
done
[ -n "$PR" ] || die "用法：scripts/closeout.sh <pr#> [--dry-run]"
case "$PR" in *[!0-9]*) die "PR 编号必须是数字：${PR}" ;; esac

require_repo_root
use_main_identity

problems=0
check_ok()   { ok "$1"; }
check_fail() { warn "$1"; problems=$((problems + 1)); }

info "① PR #${PR} 是否已合并"
state="$(pr_state "$PR" 2>/dev/null || true)"
[ -n "$state" ] || die "PR #${PR} 不存在或无法访问（检查编号与仓库权限）"
branch="$(pr_head_ref "$PR" 2>/dev/null || true)"
merge_sha="$(pr_json "$PR" 'mergeCommit' '.mergeCommit.oid' 2>/dev/null || true)"
head_sha="$(pr_json "$PR" 'headRefOid' '.headRefOid' 2>/dev/null || true)"
if [ "$state" = "MERGED" ]; then
  check_ok "已合并（squash 提交 ${merge_sha}）"
else
  check_fail "PR 状态为 ${state} —— 未合并不能收尾。若被门禁阻塞：gh pr view ${PR} --json reviewDecision,mergeStateStatus"
fi

info "② 关联 Issue 是否已自动关闭"
issues="$(gh pr view "$PR" -R "$REPO" --json closingIssuesReferences --jq '[.closingIssuesReferences[].number] | join(" ")' 2>/dev/null || true)"
if [ -z "$issues" ]; then
  check_fail "PR 未关联任何 Issue —— 请检查是否因目标不是默认分支导致关闭关键字被忽略（官方限制）"
else
  for n in $issues; do
    st="$(gh issue view "$n" -R "$REPO" --json state --jq .state 2>/dev/null || echo UNKNOWN)"
    if [ "$st" = "CLOSED" ]; then
      check_ok "Issue #${n} 已关闭"
    else
      check_fail "Issue #${n} 仍为 ${st} —— 若 PR 目标不是默认分支，关闭关键字不生效，需手动关单"
    fi
  done
fi

info "③ 远程头分支是否已删除"
if [ -z "$branch" ] || [ "$branch" = "null" ]; then
  check_fail "无法确定 PR 的头分支名"
elif git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
  check_fail "远程分支 ${branch} 仍存在：git push origin --delete ${branch}"
else
  check_ok "远程分支 ${branch} 已删除"
fi

info "④ 本地头分支清理"
if [ -z "$branch" ] || [ "$branch" = "null" ]; then
  check_fail "无法确定要清理的分支名"
elif ! git show-ref --verify --quiet "refs/heads/${branch}"; then
  check_ok "本地分支 ${branch} 已不存在（无需清理）"
else
  current="$(git branch --show-current)"
  if [ "$current" = "$branch" ]; then
    if [ "$DRY" -eq 1 ]; then
      log "[dry-run] git checkout ${BASE_BRANCH}"
    else
      info "先切回 ${BASE_BRANCH}"
      git checkout "$BASE_BRANCH" >/dev/null 2>&1 || check_fail "无法切回 ${BASE_BRANCH}，请手动处理"
      git pull --ff-only >/dev/null 2>&1 || warn "  git pull --ff-only 未成功（可稍后手动执行）"
    fi
  fi
  if [ "$state" = "MERGED" ]; then
    tip_sha="$(git rev-parse "refs/heads/${branch}" 2>/dev/null || true)"
    if [ "$DRY" -eq 1 ]; then
      log "[dry-run] 记录可恢复锚点到 Issue：branch=${branch} tip=${tip_sha:0:12} pr_head=${head_sha:0:12}"
      log "[dry-run] git branch -D ${branch}   # 已确认 PR 为 MERGED，故用 -D（squash 合并下 -d 必然拒绝）"
    else
      # 可恢复保全（工作区规则：不永久不可恢复删除）：
      # squash 合并后原始提交不在 main 上，-D 会让本地对象只能靠 reflog 捞；
      # 因此删除前把「分支名 + 本地 tip SHA + PR head SHA + 合并提交」写进关联 Issue 作为可查锚点。
      if [ -n "$issues" ]; then
        rec_body="$(cat <<REC
<!-- CLOSEOUT-RECORD -->
**收尾记录（可恢复锚点）**

- 分支：\`${branch}\`（已删除）
- 本地 tip SHA：\`${tip_sha:-未知}\`
- PR head SHA：\`${head_sha:-未知}\`（**权威锚点**：GitHub 侧保留该提交，PR 页可 "Restore branch"）
- 合并提交（squash）：\`${merge_sha:-未知}\`

> 记录原因：squash 合并后分支上的原始提交不在 \`main\` 上，直接删除分支会使其只能靠本地 reflog 找回。
> 按工作区规则"未验收/未合或独有成果先可恢复保全、不永久不可恢复删除"，此处先留锚点再删除。
REC
)"
        rec_ok=0
        for n in $issues; do
          if gh issue comment "$n" -R "$REPO" --body "$rec_body" >/dev/null 2>&1; then rec_ok=1; break; fi
        done
        if [ "$rec_ok" = "1" ]; then
          check_ok "已把可恢复锚点写入 Issue（tip ${tip_sha:0:12} / pr_head ${head_sha:0:12}）"
        else
          check_fail "无法写入可恢复锚点 —— 按规则**不应**再删除分支（请先修复写入权限）"
        fi
      else
        check_fail "无关联 Issue，无法留可恢复锚点"
      fi
      if [ "$problems" -eq 0 ] && git branch -D "$branch" >/dev/null 2>&1; then
        check_ok "本地分支 ${branch} 已删除（先验证 PR=MERGED 并留锚点，再用 -D）"
      elif [ "$problems" -ne 0 ]; then
        check_fail "因存在未通过项，**拒绝**删除本地分支 ${branch}（先保全）"
      else
        check_fail "本地分支 ${branch} 删除失败，请手动检查"
      fi
    fi
  else
    check_fail "PR 未合并，**拒绝**删除本地分支 ${branch}（避免掩盖真实错误）"
  fi
fi

info "⑤ 关联 Issue 是否已清理状态标签（Done 的载体必须干净）"
if [ -z "$issues" ]; then
  check_fail "无关联 Issue，无法核验状态标签"
else
  for n in $issues; do
    leftover="$(gh issue view "$n" -R "$REPO" --json labels \
      --jq '[.labels[].name | select(startswith("status/"))] | join(",")' 2>/dev/null || true)"
    if [ -z "$leftover" ]; then
      check_ok "Issue #${n} 无遗留状态标签（状态为 Done/Canceled，由 Issue 开关状态承载）"
    else
      check_fail "Issue #${n} 关闭后仍带状态标签 ${leftover} —— 用 scripts/status.sh ${n} done 修正"
    fi
  done
fi

echo
if [ "$problems" -eq 0 ]; then
  ok "收尾全部通过：① 已合并 ② Issue 已关 ③ 远程分支已删 ④ 本地已清理 ⑤ 状态标签已清理"
  exit 0
fi
warn "收尾存在 ${problems} 项未通过 —— 逐条修复后重跑本脚本"
exit 1
