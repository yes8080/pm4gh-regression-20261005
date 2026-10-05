#!/usr/bin/env bash
# scripts/closeout.sh <pr#> [--dry-run]
#
# W7「合并与收尾」的五项核验（合并由 dispatcher 完成后运行）：
#   ① PR 已 MERGED（squash）
#   ② 关联 Issue 已自动关闭
#   ③ 远程不存在头分支
#   ④ 本地头分支已清理且每个关联 Issue 有恢复锚点（存在时先留锚点再删除）
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
PARSE_ONLY=""
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --parse-only) PARSE_ONLY=1; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    -*) die "未知参数 ${1:-}（本脚本不提供该开关；用法见 scripts/closeout.sh -h）" ;;
    *) PR="$1"; shift ;;
  esac
done
# ── 参数级校验（取值域；**不依赖**仓库 / 凭据 / 网络）────────────────────
# ci/test 的「文档命令可执行性」判据（--parse-only）走这里（#147 C3②）。
[ -n "$PR" ] || die "用法：scripts/closeout.sh <pr#> [--dry-run]" 2
case "$PR" in *[!0-9]*) die "PR 编号必须是数字：${PR}" 2 ;; esac
if [ -n "$PARSE_ONLY" ]; then
  printf '[ OK ] 参数解析通过（--parse-only；未读网络、未写任何文件）：%s\n' "$0"
  exit 0
fi
[ -f .github/rulesets/main-protection.json ] || die "请在仓库根目录运行"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
[ -n "$REPO" ] || die "无法确定仓库 slug（gh repo view 失败）"

# 收尾是 dispatcher 的动作：用 gh 登录身份
unset GH_TOKEN || true
unset GITHUB_TOKEN || true
ACTOR="$(gh api user --jq .login 2>/dev/null || true)"
[ -n "$ACTOR" ] || die "gh 未登录或读不到身份（收尾用 gh 登录身份，见 references/identity.md）"
ok "收尾身份（dispatcher）：${ACTOR}"

problems=0
check_ok()   { ok "$1"; }
check_fail() { warn "$1"; problems=$((problems + 1)); }

# ── R4 释放本 clone 的单写者锁（#159；#169 加写者身份核对）──────────────────────────
# 锁在**工作区之外**（`$PM4GH_LOCK_DIR`、默认 `$HOME/.config/pm4gh/locks`；preflight 在默认目录不可写
#   时会回退到 `/tmp/pm4gh-locks-<uid>`，两个候选都查）。键 = clone 的物理根路径。
# 只释放**本 clone**的锁。**pid 存活不足以证明写者还在**（pid 会被无关联进程复用，见 #169）：
#   只有**写者标识匹配**（锁里的 `cmd` 与进程起始时间 `start` 同活进程**逐字一致**）才拒绝释放；
#   标识不匹配 / 不可核（`ps` 取不到，例如受限环境直接拒绝 `/bin/ps`）→ 那是**复用** → **允许释放**
#   （否则留下陈旧锁，只能等下次 preflight 接管）。与 preflight 的 WRITER_LOCK_ASSERT 同一口径，
#   但脚本各自**自包含**（不引共享库），故在此就地实现。
# 这是「正常结束」的释放动作，**不计入收尾五项**（五项的含义不变）。
# WRITER_LOCK_RELEASE:BEGIN
release_writer_lock() {
  # 写者标识（实际命令行）与第二判据（进程起始时间）；取不到 → 空 = **不可核**。
  rw_cmd_of() {
    [ -n "${1:-}" ] || return 0
    ps -p "$1" -o command= 2>/dev/null | tr -d '\n' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' | cut -c1-160 || true
  }
  rw_start_of() {
    [ -n "${1:-}" ] || return 0
    ps -p "$1" -o lstart= 2>/dev/null | tr -d '\n' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' || true
  }
  # 0 = 标识匹配（确实另有本流程的写者 → 不代他人释放）；1 = 不匹配 / 不可核（复用 → 可释放）。
  rw_writer_match() { # $1 = 锁文件；$2 = pid
    rw_m_cmd="$(grep -m1 '^cmd=' "${1:-}" 2>/dev/null | sed -E 's/^cmd=//' || true)"
    rw_m_start="$(grep -m1 '^start=' "${1:-}" 2>/dev/null | sed -E 's/^start=//' || true)"
    [ -n "$rw_m_cmd" ] || return 1
    [ "$(rw_cmd_of "${2:-}")" = "$rw_m_cmd" ] || return 1
    [ -n "$rw_m_start" ] || return 1
    [ "$(rw_start_of "${2:-}")" = "$rw_m_start" ] || return 1
    return 0
  }
  rw_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$rw_root" ] || return 0
  rw_root="$(cd "$rw_root" && pwd -P)"
  rw_id="$(printf '%s' "$rw_root" | sed -E 's#^/##; s#[^A-Za-z0-9]+#-#g')"
  rw_found=0
  for rw_dir in "${PM4GH_LOCK_DIR:-${HOME}/.config/pm4gh/locks}" "/tmp/pm4gh-locks-$(id -u)"; do
    rw_file="${rw_dir}/${rw_id}.lock"
    [ -e "$rw_file" ] || continue
    rw_found=1
    rw_owner="$(grep -m1 '^clone=' "$rw_file" 2>/dev/null | sed -E 's/^clone=//' || true)"
    if [ -n "$rw_owner" ] && [ "$rw_owner" != "$rw_root" ]; then
      printf '  [WARN] 锁 %s 属于另一个 clone（clone=%s）—— 不释放\n' "$rw_file" "$rw_owner"
      continue
    fi
    rw_pid="$(grep -m1 '^pid=' "$rw_file" 2>/dev/null | sed -E 's/^pid=//' || true)"
    case "$rw_pid" in
      ''|*[!0-9]*) : ;;
      *) if kill -0 "$rw_pid" 2>/dev/null; then
           if rw_writer_match "$rw_file" "$rw_pid"; then
             printf '  [WARN] 锁 %s 的 pid=%s **仍存活且写者标识匹配** —— 不代他人释放（确认该写者已退出后手工 rm）\n' "$rw_file" "$rw_pid"
             continue
           fi
           printf '  [WARN] 锁 %s 的 pid=%s 存活但写者标识**不匹配 / 不可核**（锁 cmd/start 与活进程对不上，疑 pid 复用）→ **允许释放**（#169：那不是本流程写者，留下 = 陈旧锁）\n' "$rw_file" "$rw_pid"
         fi ;;
    esac
    if rm -f "$rw_file"; then
      printf '[ OK ] 已释放本 clone 的单写者锁：%s\n' "$rw_file"
    else
      printf '  [WARN] 锁 %s 释放失败（权限？）—— 下次 preflight 会按陈旧锁自动接管\n' "$rw_file"
    fi
  done
  [ "$rw_found" = "1" ] || printf '  本 clone 无单写者锁可释放（%s/%s.lock 不存在）\n' "${PM4GH_LOCK_DIR:-${HOME}/.config/pm4gh/locks}" "$rw_id"
}
# WRITER_LOCK_RELEASE:END

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
    check_fail "[dry-run] Issue #${n} 有残留状态标签 ${leftover} —— 真实运行会调用 scripts/status.sh ${n} done --as dispatcher 清理"
    continue
  fi
  info "  清理 Issue #${n} 的残留状态标签：${leftover}"
  if "$(dirname "$0")/status.sh" "$n" done --as dispatcher; then
    after="$(gh issue view "$n" -R "$REPO" --json labels \
      --jq '[.labels[].name | select(startswith("status/"))] | join(",")' 2>/dev/null || true)"
    if [ -z "$after" ]; then
      check_ok "Issue #${n} 残留状态标签已自动清理（${leftover} → 无）"
    else
      check_fail "Issue #${n} 清理后仍有状态标签 ${after}"
    fi
  else
    check_fail "Issue #${n} 自动清理失败 —— 手动跑 scripts/status.sh ${n} done --as dispatcher 后重试"
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

# CLOSEOUT_ANCHOR:BEGIN
# 即使 gh pr merge --delete-branch 已删掉本地分支，也必须逐个核对关联 Issue 的锚点。
# PR head 是可从 GitHub 取回的权威 SHA；本地 tip 已不可得时明确写明，不伪造为 head。
valid_sha() {
  [ "${#1}" -eq 40 ] || return 1
  case "$1" in *[!0-9a-f]*) return 1 ;; esac
  return 0
}

info "④ 本地头分支清理与恢复锚点（分支已不存在也必须核验）"
local_present=0
tip_sha=""
if [ -z "$branch" ]; then
  check_fail "无法确定要清理的分支名"
elif git show-ref --verify --quiet "refs/heads/${branch}"; then
  local_present=1
  tip_sha="$(git rev-parse "refs/heads/${branch}" 2>/dev/null || true)"
  valid_sha "$tip_sha" || check_fail "无法读取本地分支 ${branch} 的完整 tip SHA"
fi
valid_sha "$head_sha" || check_fail "无法读取完整 PR head SHA —— 不能证明恢复锚点有效"
valid_sha "$merge_sha" || check_fail "无法读取完整合并 SHA —— 不能证明恢复锚点有效"

if [ "$problems" -ne 0 ]; then
  check_fail "收尾前置项未通过，**未执行**恢复锚点写入和本地分支删除"
else
  marker="<!-- pm4gh-closeout pr=${PR} head=${head_sha} merge=${merge_sha} -->"
  comments_file="$(mktemp "${TMPDIR:-/tmp}/pm4gh-closeout-comments.XXXXXX")"
  rec_file="$(mktemp "${TMPDIR:-/tmp}/pm4gh-closeout-record.XXXXXX")"
  cat > "$rec_file" <<REC
**收尾记录（可恢复锚点）**

${marker}

- 分支：\`${branch}\`
- 本地 tip SHA：\`${tip_sha:-不可得（合并工具已删除本地分支，恢复以 PR head 为准）}\`
- PR head SHA：\`${head_sha}\`（GitHub 侧保留的权威恢复锚点）
- 合并提交（squash）：\`${merge_sha}\`
- 恢复命令：\`git fetch origin refs/pull/${PR}/head && git branch recovery-pr-${PR} FETCH_HEAD\`

> 本地分支已被合并工具删除也要保留记录；若还存在，先核验每个 Issue 的记录，再删除。
REC
  for n in $issues; do
    if ! gh api "repos/${REPO}/issues/${n}/comments" --paginate --jq '.[].body' > "$comments_file"; then
      check_fail "无法读取 Issue #${n} 的恢复锚点 —— 未执行写入，不把读取失败当作记录不存在"
    elif grep -qxF "$marker" "$comments_file"; then
      check_ok "Issue #${n} 已有本 PR 的恢复锚点（已核验 head / merge SHA；幂等不重复写）"
    elif [ "$DRY" -eq 1 ]; then
      check_fail "[dry-run] Issue #${n} 尚无本 PR 的恢复锚点 —— 真实运行会补写；本次未写入"
    elif ! gh issue comment "$n" -R "$REPO" --body-file "$rec_file" >/dev/null; then
      check_fail "无法写入 Issue #${n} 的恢复锚点 —— **拒绝**删除本地分支"
    elif ! gh api "repos/${REPO}/issues/${n}/comments" --paginate --jq '.[].body' > "$comments_file"; then
      check_fail "无法回读 Issue #${n} 的恢复锚点 —— **拒绝**删除本地分支"
    elif grep -qxF "$marker" "$comments_file"; then
      check_ok "已把可恢复锚点写入 Issue #${n} 并回读核验（pr_head ${head_sha:0:12}）"
    else
      check_fail "Issue #${n} 锚点写入后回读不一致 —— **拒绝**删除本地分支"
    fi
  done
  rm -f "$comments_file" "$rec_file"
fi

if [ "$local_present" -eq 1 ]; then
  if [ "$DRY" -eq 1 ]; then
    check_fail "[dry-run] 本地分支 ${branch} 仍存在 —— 本次未删除，真实运行在锚点核验后清理"
  elif [ "$problems" -ne 0 ]; then
    check_fail "存在未通过项，**拒绝**删除本地分支 ${branch}（先保全）"
  else
    current="$(git branch --show-current)"
    if [ "$current" = "$branch" ]; then
      info "先切回 main"
      git checkout main >/dev/null 2>&1 || check_fail "无法切回 main，请手动处理"
      git pull --ff-only >/dev/null 2>&1 || warn "  git pull --ff-only 未成功（稍后手动执行）"
    fi
    if [ "$problems" -eq 0 ] && git branch -D "$branch" >/dev/null 2>&1; then
      check_ok "本地分支 ${branch} 已清理（确认 MERGED 且每个 Issue 留锚点后才执行）"
    else
      check_fail "本地分支 ${branch} 未清理，请手动检查"
    fi
  fi
elif [ "$problems" -eq 0 ]; then
  check_ok "本地分支 ${branch} 已不存在；每个关联 Issue 的恢复锚点均已核验"
fi
# CLOSEOUT_ANCHOR:END

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
      check_fail "Issue #${n} 仍有残留状态标签 ${after} —— 跑 scripts/status.sh ${n} done --as dispatcher 清理后重跑本脚本"
    fi
  done
fi

echo
if [ "$problems" -eq 0 ]; then
  ok "收尾五项全过：① 已合并 ② Issue 已关 ③ 远端无头分支 ④ 本地无头分支+已留锚点 ⑤ 无残留状态标签"
  if [ "$DRY" -eq 0 ]; then
    # R4：正常结束 → 释放本 clone 的单写者锁（--dry-run 零写入，不释放）
    release_writer_lock
  else
    printf '  [dry-run] 不释放单写者锁（本脚本零写入）\n'
  fi
  exit 0
fi
warn "收尾存在 ${problems} 项未通过 —— 逐条修复后重跑本脚本"
exit 1
