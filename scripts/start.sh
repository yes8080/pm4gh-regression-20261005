#!/usr/bin/env bash
# scripts/start.sh <issue#> [--type slice|fix|hotfix|spike|chore] [--slug SLUG] [--as author|main] [--dry-run]
#
# W2「开工」一条命令：
#   ⓪ 读当前状态 + `status.sh --check-transition <cur> in-progress` **只读**判定 —— 在任何
#      副作用之前；非法立即失败（不建分支、不指派、不评论），并给出正确命令
#   ① 校验 Issue 可开工（OPEN、无未关闭阻塞、状态标签 0 或 1 个）
#   ② 用 `gh issue develop` 创建并**绑定**分支（手工 git checkout -b 不会建立 Issue 绑定）
#   ③ 指派给执行身份 + 留开工声明评论
#   ④ 迁到 status/in-progress（唯一状态入口 scripts/status.sh）
#
# 身份：--as author（默认）= 作者身份 .secrets/developer.pat；--as main = gh 登录身份（dispatcher）。

set -eu

DEVELOPER_PAT_FILE="${DEVELOPER_PAT_FILE:-.secrets/developer.pat}"
REVIEWER_PAT_FILE="${REVIEWER_PAT_FILE:-.secrets/reviewer.pat}"
BASE_BRANCH="${BASE_BRANCH:-main}"

die()  { printf '[FAIL] %s\n' "${1:-}" >&2; exit "${2:-1}"; }
ok()   { printf '[ OK ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
info() { printf '\n== %s ==\n' "$*"; }

login_via_pat() {
  [ -s "${1:-}" ] || return 0
  GH_TOKEN="$(cat "$1")" gh api user --jq .login 2>/dev/null || true
}

ACTOR=""
use_identity() {
  case "${1:-}" in
    author)
      [ -s "$DEVELOPER_PAT_FILE" ] || die "缺少作者凭据 ${DEVELOPER_PAT_FILE}（见 docs/WORKFLOW.md §0）"
      GH_TOKEN="$(cat "$DEVELOPER_PAT_FILE")"
      export GH_TOKEN
      unset GITHUB_TOKEN || true
      ACTOR="$(gh api user --jq .login 2>/dev/null || true)"
      [ -n "$ACTOR" ] || die "作者凭据无效（无法认证）"
      main="$(env -u GH_TOKEN -u GITHUB_TOKEN gh api user --jq .login 2>/dev/null || true)"
      [ -z "$main" ] || [ "$main" != "$ACTOR" ] || die "身份分离失败：作者身份 = gh 登录身份（${ACTOR}）—— 检查 ${DEVELOPER_PAT_FILE}"
      rev="$(login_via_pat "$REVIEWER_PAT_FILE")"
      [ -z "$rev" ] || [ "$rev" != "$ACTOR" ] || die "身份分离失败：作者身份 = 评审身份（${ACTOR}）—— 两个凭据拿错了"
      ok "本次执行身份（作者）：${ACTOR}"
      ;;
    main)
      unset GH_TOKEN || true
      unset GITHUB_TOKEN || true
      ACTOR="$(gh api user --jq .login 2>/dev/null || true)"
      [ -n "$ACTOR" ] || die "gh 未登录或读不到身份（见 docs/WORKFLOW.md §0）"
      ok "本次执行身份（dispatcher）：${ACTOR}"
      ;;
    *) die "--as 只能是 author|main（当前：${1:-}）" ;;
  esac
}

ISSUE=""
TYPE=""
SLUG=""
AS="author"
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --type) TYPE="${2:?--type 需要取值}"; shift 2 ;;
    --slug) SLUG="${2:?--slug 需要取值}"; shift 2 ;;
    --as)   AS="${2:?--as 需要取值}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) ISSUE="$1"; shift ;;
  esac
done

[ -n "$ISSUE" ] || die "用法：scripts/start.sh <issue#> [--type ...] [--slug ...] [--as author|main] [--dry-run]"
case "$ISSUE" in *[!0-9]*) die "Issue 编号必须是数字：${ISSUE}" ;; esac
[ -f .github/rulesets/main-protection.json ] || die "请在仓库根目录运行（未找到 .github/rulesets/main-protection.json）"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
[ -n "$REPO" ] || die "无法确定仓库 slug（gh repo view 失败）"

use_identity "$AS"

info "校验 Issue #${ISSUE}"
state="$(gh issue view "$ISSUE" -R "$REPO" --json state --jq .state 2>/dev/null || true)"
[ "$state" = "OPEN" ] || die "Issue #${ISSUE} 状态为 ${state:-未知}，不能开工（返修请在原 Issue 的原分支继续）"
blockers="$(gh issue view "$ISSUE" -R "$REPO" --json blockedBy \
  --jq '[.blockedBy.nodes[] | select(.state == "OPEN") | "#\(.number)"] | join(" ")' 2>/dev/null || true)"
[ -z "$blockers" ] || die "Issue #${ISSUE} 仍被未关闭的 Issue 阻塞：${blockers}（blockedBy 不会因对方关闭自动清除，这里按 state=OPEN 判定）"
ok "Issue OPEN 且无未关闭阻塞"

info "状态预检（只读：先读平台上的当前状态，再判断能否开工）"
# 为什么必须先读、先判：本脚本的副作用（gh issue develop 建分支 / 指派 / 评论）**不可逆**。
# 旧实现无条件假定 backlog、把迁移放到最后 —— Issue 停在 in-review 时迁移非法，
# 副作用却已完成，仓库被留在半成品（见 Issue #90 的 F）。所以状态从平台读，不假定。
status_labels="$(gh issue view "$ISSUE" -R "$REPO" --json labels \
  --jq '[.labels[].name | select(startswith("status/"))] | join(" ")' 2>/dev/null || true)"
case "$status_labels" in
  "")                   cur_state="backlog" ;;
  "status/ready")       cur_state="ready" ;;
  "status/in-progress") cur_state="in-progress" ;;
  "status/in-review")   cur_state="in-review" ;;
  "status/rework")      cur_state="rework" ;;
  *" "*) die "Issue #${ISSUE} 有多个状态标签：${status_labels} —— 状态必须唯一，先 scripts/status.sh ${ISSUE} <state> 修正" ;;
  *)     die "Issue #${ISSUE} 使用了未定义的状态标签：${status_labels} —— 用 scripts/status.sh 修正" ;;
esac
ok "当前状态：${cur_state}（读自平台，不是假定值）"
if ! "$(dirname "$0")/status.sh" --check-transition "$cur_state" in-progress; then
  die "Issue #${ISSUE} 当前 ${cur_state}，不能开工（start.sh 只做 → in-progress）。先按上方合法出边迁移再重跑；本次**未创建分支、未指派、未评论**"
fi
ok "迁移合法：${cur_state} → in-progress（发生在任何副作用之前）"

info "推导分支名"
title="$(gh issue view "$ISSUE" -R "$REPO" --json title --jq .title)"
labels="$(gh issue view "$ISSUE" -R "$REPO" --json labels --jq '[.labels[].name] | join(",")')"
if [ -z "$TYPE" ]; then
  case ",${labels}," in
    *",type/bug,"*)    TYPE="fix" ;;
    *",type/hotfix,"*) TYPE="hotfix" ;;
    *",type/spike,"*)  TYPE="spike" ;;
    *",type/chore,"*)  TYPE="chore" ;;
    *)                 TYPE="slice" ;;
  esac
  info "未指定 --type，按标签推导：${TYPE}"
fi
case "$TYPE" in slice|fix|hotfix|spike|chore) : ;; *) die "--type 只能是 slice|fix|hotfix|spike|chore（当前：${TYPE}）" ;; esac
if [ -z "$SLUG" ]; then
  # 只取 ASCII 再小写化（用 tr 而不是 bash4 的 ${var,,}）；必须 sed -E，BSD sed 不支持 BRE 的 \+
  SLUG="$(printf '%s' "$title" | LC_ALL=C sed -E 's/[^A-Za-z0-9]+/-/g' | tr 'A-Z' 'a-z' \
    | sed -E -e 's/^-+//' -e 's/-+$//' | cut -c1-40)"
fi
[ -n "$SLUG" ] || die "无法从标题推导 slug，请用 --slug 指定"
printf '%s' "$SLUG" | grep -qE '^[a-z0-9-]+$' || die "slug 只允许小写字母、数字、连字符：${SLUG}"
BRANCH="${TYPE}/${ISSUE}-${SLUG}"
printf '%s' "$BRANCH" | grep -qE '^(slice|fix|hotfix|spike|chore)/[0-9]+-[a-z0-9-]+$' \
  || die "分支名 ${BRANCH} 不符合 <type>/<issue#>-<slug> 规范"
info "分支名：${BRANCH}"
if git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
  die "本地已存在分支 ${BRANCH} —— 返修请直接切回该分支继续提交，不要新建分支"
fi
if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
  die "远端已存在分支 ${BRANCH} —— 返修请直接切回该分支继续提交，不要新建分支"
fi

if [ "$DRY" -eq 1 ]; then
  info "[dry-run] 将要执行"
  printf '  （已完成的只读预检：%s → in-progress 合法）\n' "$cur_state"
  printf '  gh issue develop %s -R %s --base %s --name %s --checkout\n' "$ISSUE" "$REPO" "$BASE_BRANCH" "$BRANCH"
  printf '  gh issue edit %s --add-assignee @me\n' "$ISSUE"
  printf '  gh issue comment %s --body-file <开工声明>\n' "$ISSUE"
  printf '  scripts/status.sh %s in-progress\n' "$ISSUE"
  exit 0
fi

info "创建并绑定分支（gh issue develop）"
gh issue develop "$ISSUE" -R "$REPO" --base "$BASE_BRANCH" --name "$BRANCH" --checkout >/dev/null
ok "分支已创建并绑定到 Issue #${ISSUE}"

gh issue edit "$ISSUE" -R "$REPO" --add-assignee @me >/dev/null
ok "已指派给 ${ACTOR}"

info "留开工声明"
note_file="${TMPDIR:-/tmp}/pm4gh-start-${ISSUE}-$$.md"
cat > "$note_file" <<EOF
**开工声明**

- 分支：\`${BRANCH}\`（由 \`gh issue develop\` 创建并绑定）
- 执行者：@${ACTOR}（\`--as ${AS}\`）
- 预计交付：
- 依赖状态：无未关闭阻塞

> 由 \`scripts/start.sh\` 自动生成，构成可审计的开工时间线。
EOF
gh issue comment "$ISSUE" -R "$REPO" --body-file "$note_file" >/dev/null
rm -f "$note_file"
ok "开工声明已提交"

info "状态迁移 → in-progress"
"$(dirname "$0")/status.sh" "$ISSUE" in-progress

echo
printf '下一步：\n'
printf '  1) 实现；自检：bash -n scripts/*.sh && scripts/status.sh --check\n'
printf '  2) 用作者身份提交（提交信息用 -F 传文件）：\n'
printf '     git -c user.name="yes8080-dev-bot" -c user.email="317173623+yes8080-dev-bot@users.noreply.github.com" commit -F <msg-file>\n'
printf '  3) scripts/deliver.sh %s --prepare --as author   然后   scripts/deliver.sh %s --as author\n' "$ISSUE" "$ISSUE"
