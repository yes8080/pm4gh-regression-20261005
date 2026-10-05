#!/usr/bin/env bash
# scripts/start.sh <issue#> [--type slice|fix|hotfix|spike|chore] [--as author] [--dry-run]
#
# W2「开工」一条命令：
#   ⓪ 读当前状态 + `status.sh --check-transition <cur> in-progress` **只读**判定 —— 在任何
#      副作用之前；非法立即失败（不建分支、不指派、不评论），并给出正确命令
#   ① 校验 Issue 可开工（OPEN、无未关闭阻塞、状态标签 0 或 1 个）
#   ② 用 `gh issue develop` 创建并**绑定**分支（手工 git checkout -b 不会建立 Issue 绑定）
#   ③ 指派给执行身份 + 留开工声明评论
#   ④ 迁到 status/in-progress（唯一状态入口 scripts/status.sh）
#
# 身份：只有 `--as author`（作者身份 $HOME/.config/pm4gh/developer.pat）—— **没有 dispatcher 开关**，作者身份不可被绕过。

set -eu

SCRIPT_DIR="$(dirname "$0")"

# 作者凭据默认在**工作区之外**；**禁止**指回工作区内路径。
# 写法与 scripts/review.sh 的评审凭据一致（同样支持 env 覆盖）。
DEVELOPER_PAT_FILE="${DEVELOPER_PAT_FILE:-${HOME}/.config/pm4gh/developer.pat}"
BASE_BRANCH="${BASE_BRANCH:-main}"

die()  { printf '[FAIL] %s\n' "${1:-}" >&2; exit "${2:-1}"; }
ok()   { printf '[ OK ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
info() { printf '\n== %s ==\n' "$*"; }

ACTOR=""
# --as 的取值域（**参数级**校验：不读凭据 / 不读网络）。判据只有这一处定义 ——
# 「参数级校验段（--parse-only 走它）」与 `use_identity` 都调用它。
assert_author_as() {
  case "${1:-}" in
    author) : ;;
    main) die "--as 只接受 author：本脚本**没有** dispatcher 身份开关（作者身份不可被绕过）。当前：${1:-}" 2 ;;
    *)    die "--as 只接受 author（当前：${1:-}）" 2 ;;
  esac
}

use_identity() {
  assert_author_as "${1:-}"
  [ -s "$DEVELOPER_PAT_FILE" ] || die "缺少作者凭据 ${DEVELOPER_PAT_FILE}（见 references/identity.md）"
  GH_TOKEN="$(cat "$DEVELOPER_PAT_FILE")"
  export GH_TOKEN
  unset GITHUB_TOKEN || true
  ACTOR="$(gh api user --jq .login 2>/dev/null || true)"
  [ -n "$ACTOR" ] || die "作者凭据无效（无法认证）"
  main="$(env -u GH_TOKEN -u GITHUB_TOKEN gh api user --jq .login 2>/dev/null || true)"
  [ -z "$main" ] || [ "$main" != "$ACTOR" ] || die "身份分离失败：作者身份 = gh 登录身份（${ACTOR}）—— 检查 ${DEVELOPER_PAT_FILE}"
  # 评审凭据**不在这里读**（SKILL.md §5：作者不得读取其他身份的凭据）。
  # 「评审 ≠ 作者」由 W6 `scripts/review.sh` 用**评审凭据自身**判定（平台另禁止自我批准）。
  ok "本次执行身份（作者）：${ACTOR}"
}

ISSUE=""
TYPE=""
SLUG=""
AS="author"
PARSE_ONLY=""
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --type) TYPE="${2:?--type 需要取值}"; shift 2 ;;
    --as)   AS="${2:?--as 需要取值}"; shift 2 ;;
    --parse-only) PARSE_ONLY=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    -*) die "未知参数 ${1:-}（本脚本不提供该开关；用法见 scripts/start.sh -h）" 2 ;;
    *) ISSUE="$1"; shift ;;
  esac
done

# ── 参数级校验（取值域；**不依赖**仓库 / 凭据 / 网络）────────────────────
# 全部判据都属于「参数」，必须在读到仓库/凭据之前完成 —— 否则 ci/test 的
# 「文档命令可执行性」判据（--parse-only）会漏掉它们（#147 C3②）。
[ -n "$ISSUE" ] || die "用法：scripts/start.sh <issue#> [--type ...] [--as author] [--dry-run]" 2
case "$ISSUE" in *[!0-9]*) die "Issue 编号必须是数字：${ISSUE}" 2 ;; esac
assert_author_as "$AS"
# 空值 = 稍后按标签推导（下方仍会在推导后再校验一次，纵深防御）
case "${TYPE:-}" in
  ""|slice|fix|hotfix|spike|chore) : ;;
  *) die "--type 只能是 slice|fix|hotfix|spike|chore（当前：${TYPE}）" 2 ;;
esac
if [ -n "$PARSE_ONLY" ]; then
  printf '[ OK ] 参数解析通过（--parse-only；未读网络、未写任何文件）：%s\n' "$0"
  exit 0
fi

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
# **必须**先读平台状态、先做只读判定：本脚本的副作用（gh issue develop 建分支 / 指派 / 评论）**不可逆**。
# **禁止**假定 Issue 在 backlog，**禁止**把状态迁移放到副作用之后 —— 非法迁移会把仓库留在半成品。
status_labels="$(gh issue view "$ISSUE" -R "$REPO" --json labels \
  --jq '[.labels[].name | select(startswith("status/"))] | join(" ")' 2>/dev/null || true)"
case "$status_labels" in
  "")                   cur_state="backlog" ;;
  "status/ready")       cur_state="ready" ;;
  "status/in-progress") cur_state="in-progress" ;;
  "status/in-review")   cur_state="in-review" ;;
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
  # `type/hotfix` 必须**先**判：线上故障的 Issue 会同时带 type/bug（模板预置）与 type/hotfix（手动加），
  # 先匹配 type/bug 会把热修静默判成 fix/。
  case ",${labels}," in
    *",type/hotfix,"*) TYPE="hotfix" ;;
    *",type/bug,"*)    TYPE="fix" ;;
    *",type/spike,"*)  TYPE="spike" ;;
    *",type/chore,"*)  TYPE="chore" ;;
    *)                 TYPE="slice" ;;
  esac
  info "未指定 --type，按标签推导：${TYPE}"
  if [ "$TYPE" = "fix" ]; then
    warn "推导结果为 fix —— 若这是**线上故障**（hotfix 轨道），请改用 --type hotfix，或先给 Issue 加 type/hotfix 标签再重跑；本次未创建分支、未指派、未评论"
  fi
fi
# 显式 --type 的取值域已在「参数级校验」段校验；这里覆盖**按标签推导**出来的值（纵深防御）
case "$TYPE" in slice|fix|hotfix|spike|chore) : ;; *) die "--type 只能是 slice|fix|hotfix|spike|chore（当前：${TYPE}）" ;; esac
if [ -z "$SLUG" ]; then
  # 只取 ASCII 再小写化（用 tr 而不是 bash4 的 ${var,,}）；必须 sed -E，BSD sed 不支持 BRE 的 \+
  SLUG="$(printf '%s' "$title" | LC_ALL=C sed -E 's/[^A-Za-z0-9]+/-/g' | tr 'A-Z' 'a-z' \
    | sed -E -e 's/^-+//' -e 's/-+$//' | cut -c1-40)"
fi
[ -n "$SLUG" ] || die "无法从标题推导出合法 slug —— 请把 Issue 标题改成含 ASCII 字母/数字（slug 从标题推导，没有覆盖开关）"
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
  printf '  scripts/status.sh %s in-progress --as %s\n' "$ISSUE" "$AS"
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
"$(dirname "$0")/status.sh" "$ISSUE" in-progress --as "$AS"

echo
printf '下一步：\n'
printf '  1) 实现；自检：bash -n %q/*.sh && %q/status.sh --check\n' "$SCRIPT_DIR" "$SCRIPT_DIR"
printf '  2) 用作者身份提交（提交信息用 -F 传文件）：\n'
printf '     git -c user.name="yes8080-dev-bot" -c user.email="317173623+yes8080-dev-bot@users.noreply.github.com" commit -F <msg-file>\n'
printf '  3) %q/deliver.sh %s --prepare --as author   然后   %q/deliver.sh %s --as author\n' "$SCRIPT_DIR" "$ISSUE" "$SCRIPT_DIR" "$ISSUE"
