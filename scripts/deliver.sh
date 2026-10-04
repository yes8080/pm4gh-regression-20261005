#!/usr/bin/env bash
# scripts/deliver.sh <issue#> [--prepare] [--title TITLE] [--body-file FILE] [--as author|main] [--dry-run]
#
# W4「交付 PR」一条命令：
#   ① 校验分支名合规且对应本 Issue（policy/branch-name 的本地预演）
#   ② 校验正文六段齐备且含 Closes 关键字（policy/linked-issue / policy/template 的本地预演）
#   ③ 用当前身份推送分支（清掉本地 credential helper，否则会静默变成主身份推送）
#   ④ 建 PR；若该分支已有 PR（返修）则用 **REST PATCH** 更新正文 —— `gh pr edit` 走 GraphQL，
#      作者凭据没有 read:org，会报错且**静默不更新**（见 docs/WORKFLOW.md §已知陷阱 7）
#   ⑤ 迁到 status/in-review
#
# 用法：
#   scripts/deliver.sh <issue#> --prepare --as author    # 生成六段骨架
#   （填写骨架）
#   scripts/deliver.sh <issue#> --as author              # 校验 + 推送 + 建/更新 PR

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
      [ -z "$main" ] || [ "$main" != "$ACTOR" ] || die "身份分离失败：作者身份 = gh 登录身份（${ACTOR}）"
      rev="$(login_via_pat "$REVIEWER_PAT_FILE")"
      [ -z "$rev" ] || [ "$rev" != "$ACTOR" ] || die "身份分离失败：作者身份 = 评审身份（${ACTOR}）"
      ok "本次执行身份（作者）：${ACTOR}"
      ;;
    main)
      unset GH_TOKEN || true
      unset GITHUB_TOKEN || true
      ACTOR="$(gh api user --jq .login 2>/dev/null || true)"
      [ -n "$ACTOR" ] || die "gh 未登录或读不到身份"
      ok "本次执行身份（dispatcher）：${ACTOR}"
      ;;
    *) die "--as 只能是 author|main（当前：${1:-}）" ;;
  esac
}

ISSUE=""
TITLE=""
BODY_FILE=""
PREPARE=0
AS="author"
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prepare)   PREPARE=1; shift ;;
    --title)     TITLE="${2:?--title 需要取值}"; shift 2 ;;
    --body-file) BODY_FILE="${2:?--body-file 需要取值}"; shift 2 ;;
    --as)        AS="${2:?--as 需要取值}"; shift 2 ;;
    --dry-run)   DRY=1; shift ;;
    -h|--help)   sed -n '2,17p' "$0"; exit 0 ;;
    *) ISSUE="$1"; shift ;;
  esac
done

[ -n "$ISSUE" ] || die "用法：scripts/deliver.sh <issue#> [--prepare] [--title ...] [--body-file ...] [--as author|main]"
case "$ISSUE" in *[!0-9]*) die "Issue 编号必须是数字：${ISSUE}" ;; esac
[ -f .github/rulesets/main-protection.json ] || die "请在仓库根目录运行"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
[ -n "$REPO" ] || die "无法确定仓库 slug（gh repo view 失败）"

use_identity "$AS"
[ -z "$BODY_FILE" ] && BODY_FILE=".git/PR_BODY_${ISSUE}.md"

if [ "$PREPARE" -eq 1 ]; then
  mkdir -p "$(dirname "$BODY_FILE")"
  cat > "$BODY_FILE" <<EOF
Closes #${ISSUE}

## 1. 变更摘要

<!-- 做了什么、为什么这么做。评审人只看这里就该知道改动意图。 -->

## 2. 影响面

- 受影响范围：
- 是否破坏性变更：否 / 是
- 是否需要数据迁移：否 / 是

## 3. 回滚方式

<!-- 必须可执行：revert 本 PR / 恢复配置 / 反向迁移。不允许写"出问题再说"。 -->

## 4. 验收证据

<!-- 与 Issue 的验收标准逐条对应；给确切命令与输出，禁止"已测试通过"这类无证据断言。 -->

| 验收条目 | 证据（命令 / 检查名 / 输出 / 链接） | 结果 |
|---|---|---|
|  |  |  |

## 5. DoD 自查

- [ ] 验收标准逐条有证据（第 4 节）
- [ ] 5 个必需检查在最新 SHA 上通过
- [ ] 文档/ADR 已更新（涉及接口、数据、运维变更时）
- [ ] 未越界：没有改 Issue「边界」之外的内容
- [ ] 已确认回滚方式可执行（第 3 节）
- [ ] 提交信息遵循 Conventional Commits 并带 Issue 号

## 6. 风险与破坏性变更
EOF
  ok "正文骨架已生成：${BODY_FILE}"
  printf '填写后运行：scripts/deliver.sh %s --as %s\n' "$ISSUE" "$AS"
  exit 0
fi

info "校验当前分支"
BRANCH="$(git branch --show-current)"
[ -n "$BRANCH" ] || die "当前处于游离 HEAD，请先切到切片分支"
printf '%s' "$BRANCH" | grep -qE '^(slice|fix|hotfix|spike|chore)/[0-9]+-[a-z0-9-]+$' \
  || die "分支名 ${BRANCH} 不符合 <type>/<issue#>-<slug>（policy/branch-name 会拒绝）"
branch_issue="${BRANCH#*/}"; branch_issue="${branch_issue%%-*}"
[ "$branch_issue" = "$ISSUE" ] || die "当前分支 ${BRANCH} 指向 Issue #${branch_issue}，与传入的 #${ISSUE} 不一致"
ok "分支 ${BRANCH} 合规且对应 #${ISSUE}"

state="$(gh issue view "$ISSUE" -R "$REPO" --json state --jq .state 2>/dev/null || true)"
[ "$state" = "OPEN" ] || die "Issue #${ISSUE} 已 ${state:-未知}，不应对它开新 PR"
slabel="$(gh issue view "$ISSUE" -R "$REPO" --json labels \
  --jq '[.labels[].name | select(startswith("status/"))] | length' 2>/dev/null || echo 0)"
[ "$slabel" -ge 1 ] || die "Issue #${ISSUE} 处于 Backlog（无 status/* 标签）—— 先 scripts/status.sh ${ISSUE} in-progress（policy/branch-name 会拒绝）"
ok "Issue OPEN 且已进入状态机"

if [ -n "$(git status --porcelain)" ]; then
  git status --short >&2
  die "工作区有未提交改动 —— 先提交（门禁要求 PR 内含完整改动）"
fi
ok "工作区干净"

info "校验 PR 正文（${BODY_FILE}）"
[ -f "$BODY_FILE" ] || die "找不到正文文件 ${BODY_FILE}（先运行 scripts/deliver.sh ${ISSUE} --prepare）"
grep -qiE "(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]*:?[[:space:]]*#${ISSUE}([^0-9]|$)" "$BODY_FILE" \
  || die "正文缺少关闭关键字，例如 Closes #${ISSUE}（PR 标题里的关键字无效）"
ok "含关闭关键字 Closes #${ISSUE}"
missing=""
for i in 1 2 3 4 5 6; do
  grep -qE "^## ${i}\." "$BODY_FILE" || missing="${missing} ${i}"
done
[ -z "$missing" ] || die "正文缺少章节：${missing}（需要 1.变更摘要 2.影响面 3.回滚方式 4.验收证据 5.DoD自查 6.风险）"
ok "六段齐备"
empty_sec="$(awk '
  /^## [1-6]\./ { if (name != "" && chars < 20) printf "%s ", name; name=$0; chars=0; next }
  /^#/ { next }
  { gsub(/[[:space:]]/, ""); if (name != "") chars += length($0) }
  END { if (name != "" && chars < 20) printf "%s", name }
' "$BODY_FILE")"
[ -z "$empty_sec" ] || die "以下章节内容过少（需要真实填写）：${empty_sec}"
ok "各章节均有实质内容"

[ -n "$TITLE" ] || TITLE="$(gh issue view "$ISSUE" -R "$REPO" --json title --jq .title)"
existing_pr="$(gh pr list -R "$REPO" --head "$BRANCH" --state open --json number --jq '.[0].number // ""' 2>/dev/null || true)"

if [ "$DRY" -eq 1 ]; then
  info "[dry-run] 将要执行"
  printf "  git -c credential.helper= -c credential.helper='!gh auth git-credential' push -u origin %s\n" "$BRANCH"
  if [ -n "$existing_pr" ]; then
    printf '  REST PATCH repos/%s/pulls/%s  （更新正文，返修场景）\n' "$REPO" "$existing_pr"
  else
    printf '  gh pr create --base %s --title "%s (#%s)" --body-file %s\n' "$BASE_BRANCH" "$TITLE" "$ISSUE" "$BODY_FILE"
  fi
  printf '  scripts/status.sh %s in-review\n' "$ISSUE"
  exit 0
fi

info "推送分支（身份 ${ACTOR}）"
# 必须清掉本地 credential helper：否则 macOS 钥匙串里缓存的主身份凭据会优先命中，
# "作者身份推送"会静默变成主身份推送（身份分离失效）。
push_out=""
if ! push_out="$(git -c credential.helper= -c credential.helper='!gh auth git-credential' push -u origin "$BRANCH" 2>&1)"; then
  printf '%s\n' "$push_out" >&2
  die "推送失败（上方为服务端原文）。若含 without 'workflow' scope → 重新签发作者凭据；不要改用主身份推送、不要 --admin"
fi
printf '%s\n' "$push_out" | tail -2

if [ -n "$existing_pr" ]; then
  info "该分支已有 PR #${existing_pr}（返修）—— 用 REST PATCH 更新正文"
  want="$(cat "$BODY_FILE")"
  if ! jq -Rs '{body:.}' "$BODY_FILE" | gh api -X PATCH "repos/${REPO}/pulls/${existing_pr}" --input - >/dev/null; then
    die "更新 PR #${existing_pr} 正文失败（作者凭据缺 read:org，**不要**改用 gh pr edit）"
  fi
  got="$(gh api "repos/${REPO}/pulls/${existing_pr}" --jq .body 2>/dev/null || true)"
  [ "$got" = "$want" ] || die "更新 PR #${existing_pr} 正文后回读不一致（疑似静默未更新）"
  ok "已更新 PR #${existing_pr} 正文（REST PATCH，回读一致）"
  PR_NUM="$existing_pr"
else
  info "创建 PR"
  url="$(gh pr create -R "$REPO" --base "$BASE_BRANCH" --title "${TITLE} (#${ISSUE})" --body-file "$BODY_FILE")"
  PR_NUM="${url##*/}"
  ok "PR 已创建：${url}"
fi
ok "PR 作者：@$(gh pr view "$PR_NUM" -R "$REPO" --json author --jq .author.login)"

linked="$(gh pr view "$PR_NUM" -R "$REPO" --json closingIssuesReferences \
  --jq '[.closingIssuesReferences[].number] | join(",")' 2>/dev/null || true)"
if [ -n "$linked" ]; then
  ok "GitHub 已解析关闭关系：#${linked}"
else
  warn "GitHub 尚未解析出关闭关系 —— 若目标分支不是默认分支，关闭关键字会被完全忽略（policy/linked-issue 会拦）"
fi

info "状态迁移 → in-review"
"$(dirname "$0")/status.sh" "$ISSUE" in-review

echo
printf '下一步：\n'
printf '  1) 等必需检查：gh pr checks %s --required\n' "$PR_NUM"
printf '  2) 独立评审（**不加** --as，走评审身份）：scripts/review.sh %s approve --body-file review.md\n' "$PR_NUM"
printf '  3) 合并（只有 dispatcher）：gh pr merge %s --squash --delete-branch\n' "$PR_NUM"
printf '  4) 收尾核验：scripts/closeout.sh %s\n' "$PR_NUM"
