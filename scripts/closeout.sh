#!/usr/bin/env bash
# scripts/closeout.sh <pr#> [--dry-run]
#
# W7「合并与收尾」的五项核验（合并由 dispatcher 完成后运行）：
#   ① PR 已 MERGED（squash）
#   ② 关联 Issue 已自动关闭
#   ③ 远程不存在头分支
#   ④ 本地头分支已清理（**先**把可恢复锚点写进 Issue，**再** git branch -D）
#   ⑤ 关联 Issue 无残留 status/* 标签 —— 本脚本**自己清理**（内部调用 status.sh <n> done），
#      不再要求人先手动跑一遍 status.sh；判定的是「清理之后」的结果。
#      Issue 本身必须已由平台合并关单：closeout 绝不允许把 OPEN 的 Issue 关掉（那是掩盖错误）。
#
# 第 ④ 项**必须**按此顺序：squash 合并后分支上的原始提交不在 main 上，`git branch -d` 基于祖先关系
# 必然拒绝；**禁止**无条件 `-D`（会掩盖"PR 尚未合并就删本地分支"这类真实错误）。顺序 =
# 「先确认 MERGED → 把分支 tip SHA + PR head SHA 写进 Issue → 再 -D」。

set -eu

die()  { printf '[FAIL] %s\n' "${1:-}" >&2; exit "${2:-1}"; }
ok()   { printf '[ OK ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
info() { printf '\n== %s ==\n' "$*"; }

PR=""
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) PR="$1"; shift ;;
  esac
done
[ -n "$PR" ] || die "用法：scripts/closeout.sh <pr#> [--dry-run]"
case "$PR" in *[!0-9]*) die "PR 编号必须是数字：${PR}" ;; esac
[ -f .github/rulesets/main-protection.json ] || die "请在仓库根目录运行"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
[ -n "$REPO" ] || die "无法确定仓库 slug（gh repo view 失败）"

# 收尾是 dispatcher 的动作：用 gh 登录身份
unset GH_TOKEN || true
unset GITHUB_TOKEN || true
ACTOR="$(gh api user --jq .login 2>/dev/null || true)"
[ -n "$ACTOR" ] || die "gh 未登录或读不到身份（收尾用 gh 登录身份，见 references/workflow.md §0）"
ok "收尾身份（dispatcher）：${ACTOR}"

problems=0
check_ok()   { ok "$1"; }
check_fail() { warn "$1"; problems=$((problems + 1)); }

state="$(gh pr view "$PR" -R "$REPO" --json state --jq .state 2>/dev/null || true)"
[ -n "$state" ] || die "PR #${PR} 不存在或无法访问"
branch="$(gh pr view "$PR" -R "$REPO" --json headRefName --jq .headRefName 2>/dev/null || true)"
head_sha="$(gh pr view "$PR" -R "$REPO" --json headRefOid --jq .headRefOid 2>/dev/null || true)"
merge_sha="$(gh pr view "$PR" -R "$REPO" --json mergeCommit --jq '.mergeCommit.oid // ""' 2>/dev/null || true)"
issues="$(gh pr view "$PR" -R "$REPO" --json closingIssuesReferences \
  --jq '[.closingIssuesReferences[].number] | join(" ")' 2>/dev/null || true)"

# ── 残留状态标签：**先清理，再判定** ─────────────────────────
# 顺序很重要：第 ④ 项只在「其余项全过」时才删本地分支，所以第 ⑤ 项（无残留标签）必须在
# 进入第 ④ 项之前就有结论。清理是幂等的：无残留时不产生任何写操作。
# 只在 Issue **已由平台关闭**时才清；OPEN 的 Issue 绝不代关（那会掩盖「合并没关单」的真实错误）。
info "①-前置 自动清理残留状态标签（status.sh <n> done；仅对已关闭的 Issue）"
for n in $issues; do
  st="$(gh issue view "$n" -R "$REPO" --json state --jq .state 2>/dev/null || echo UNKNOWN)"
  leftover="$(gh issue view "$n" -R "$REPO" --json labels \
    --jq '[.labels[].name | select(startswith("status/"))] | join(",")' 2>/dev/null || true)"
  if [ -z "$leftover" ]; then
    ok "Issue #${n} 无残留状态标签（done 由 Issue 开关状态承载）"
    continue
  fi
  if [ "$st" != "CLOSED" ]; then
    check_fail "Issue #${n} 仍为 ${st} 却带着状态标签 ${leftover} —— 本脚本**不**替平台关单（那会掩盖真实错误），请人工核查"
    continue
  fi
  if [ "$DRY" -eq 1 ]; then
    check_fail "[dry-run] Issue #${n} 有残留状态标签 ${leftover} —— 真实运行会调用 scripts/status.sh ${n} done 清理"
    continue
  fi
  info "  清理 Issue #${n} 的残留状态标签：${leftover}"
  if "$(dirname "$0")/status.sh" "$n" done; then
    after="$(gh issue view "$n" -R "$REPO" --json labels \
      --jq '[.labels[].name | select(startswith("status/"))] | join(",")' 2>/dev/null || true)"
    if [ -z "$after" ]; then
      check_ok "Issue #${n} 残留状态标签已自动清理（${leftover} → 无）"
    else
      check_fail "Issue #${n} 清理后仍有状态标签 ${after}"
    fi
  else
    check_fail "Issue #${n} 自动清理失败 —— 手动跑 scripts/status.sh ${n} done 后重试"
  fi
done

info "① PR #${PR} 是否已合并"
if [ "$state" = "MERGED" ]; then
  check_ok "已合并（squash 提交 ${merge_sha:-未知}）"
else
  check_fail "PR 状态为 ${state} —— 未合并不能收尾。若被门禁阻塞：gh pr view ${PR} --json reviewDecision,mergeStateStatus"
fi

info "② 关联 Issue 是否已自动关闭"
if [ -z "$issues" ]; then
  check_fail "PR 未关联任何 Issue —— 检查关闭关键字是否因目标不是默认分支被忽略（官方限制）"
else
  for n in $issues; do
    st="$(gh issue view "$n" -R "$REPO" --json state --jq .state 2>/dev/null || echo UNKNOWN)"
    if [ "$st" = "CLOSED" ]; then check_ok "Issue #${n} 已关闭"; else check_fail "Issue #${n} 仍为 ${st}"; fi
  done
fi

info "③ 远端是否存在头分支"
if [ -z "$branch" ]; then
  check_fail "无法确定 PR 的头分支名"
elif git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
  check_fail "远端分支 ${branch} 仍存在：git push origin --delete ${branch}"
else
  check_ok "远端无分支 ${branch}"
fi

info "④ 本地头分支清理（先留锚点，再删除）"
if [ -z "$branch" ]; then
  check_fail "无法确定要清理的分支名"
elif ! git show-ref --verify --quiet "refs/heads/${branch}"; then
  check_ok "本地分支 ${branch} 已不存在（无需清理）"
else
  current="$(git branch --show-current)"
  if [ "$current" = "$branch" ]; then
    if [ "$DRY" -eq 1 ]; then
      printf '[dry-run] git checkout main && git pull --ff-only\n'
    else
      info "先切回 main"
      git checkout main >/dev/null 2>&1 || check_fail "无法切回 main，请手动处理"
      git pull --ff-only >/dev/null 2>&1 || warn "  git pull --ff-only 未成功（稍后手动执行）"
    fi
  fi
  if [ "$state" != "MERGED" ]; then
    check_fail "PR 未合并，**拒绝**删除本地分支 ${branch}（避免掩盖真实错误）"
  else
    tip_sha="$(git rev-parse "refs/heads/${branch}" 2>/dev/null || true)"
    if [ "$DRY" -eq 1 ]; then
      printf '[dry-run] 写锚点到 Issue：branch=%s tip=%s pr_head=%s\n' "$branch" "${tip_sha:0:12}" "${head_sha:0:12}"
      printf '[dry-run] git branch -D %s\n' "$branch"
    else
      rec_ok=0
      if [ -n "$issues" ]; then
        rec_file="${TMPDIR:-/tmp}/pm4gh-closeout-${PR}-$$.md"
        cat > "$rec_file" <<REC
**收尾记录（可恢复锚点）**

- 分支：\`${branch}\`
- 本地 tip SHA：\`${tip_sha:-未知}\`
- PR head SHA：\`${head_sha:-未知}\`（**权威锚点**：GitHub 侧保留该提交，PR 页可 "Restore branch"）
- 合并提交（squash）：\`${merge_sha:-未知}\`

> 原因：squash 合并后分支上的原始提交不在 \`main\` 上，直接删除分支会让它只能靠本地 reflog 找回。
> 先留锚点再删除（工作区规则：未验收/未合的独有成果必须可恢复）。
REC
        for n in $issues; do
          if gh issue comment "$n" -R "$REPO" --body-file "$rec_file" >/dev/null 2>&1; then rec_ok=1; break; fi
        done
        rm -f "$rec_file"
      fi
      if [ "$rec_ok" = "1" ]; then
        check_ok "已把可恢复锚点写入 Issue（tip ${tip_sha:0:12} / pr_head ${head_sha:0:12}）"
      else
        check_fail "无法写入可恢复锚点 —— 按规则**不得**再删除本地分支（先修复写入权限）"
      fi
      if [ "$problems" -eq 0 ] && git branch -D "$branch" >/dev/null 2>&1; then
        check_ok "本地分支 ${branch} 已清理（确认 MERGED 且留锚点后才执行）"
      elif [ "$problems" -ne 0 ]; then
        check_fail "存在未通过项，**拒绝**删除本地分支 ${branch}（先保全）"
      else
        check_fail "本地分支 ${branch} 删除失败，请手动检查"
      fi
    fi
  fi
fi

info "⑤ 关联 Issue 无残留状态标签（结论来自上面的①-前置清理）"
if [ -z "$issues" ]; then
  check_ok "无关联 Issue 需要核验（见 ② 的失败项）"
else
  for n in $issues; do
    after="$(gh issue view "$n" -R "$REPO" --json labels \
      --jq '[.labels[].name | select(startswith("status/"))] | join(",")' 2>/dev/null || true)"
    if [ -z "$after" ]; then
      check_ok "Issue #${n} 无残留状态标签（已确认清理后为空）"
    else
      check_fail "Issue #${n} 仍有残留状态标签 ${after} —— 跑 scripts/status.sh ${n} done 清理后重跑本脚本"
    fi
  done
fi

echo
if [ "$problems" -eq 0 ]; then
  ok "收尾五项全过：① 已合并 ② Issue 已关 ③ 远端无头分支 ④ 本地无头分支+已留锚点 ⑤ 无残留状态标签"
  exit 0
fi
warn "收尾存在 ${problems} 项未通过 —— 逐条修复后重跑本脚本"
exit 1
