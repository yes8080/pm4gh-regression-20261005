#!/usr/bin/env bash
# scripts/deliver.sh <issue#> [--prepare] [--body-file FILE] [--as author] [--dry-run]
#
# W4「交付 PR」一条命令：
#   ⓪ 读当前 Issue 状态 + `status.sh --check-transition <cur> in-review` **只读**判定 —— 在任何
#      副作用之前；非法立即失败（不写骨架、不推送、不建 PR），并给出正确命令
#   ① 校验分支名合规且对应本 Issue（policy/branch-name 的本地预演）
#   ② 校验正文六段齐备且含 Closes 关键字（policy/linked-issue / policy/template 的本地预演）
#   ③ 用当前身份推送分支（清掉本地 credential helper，否则会静默变成主身份推送）
#   ④ 建 PR；若该分支已有 PR（返修）则用 **REST PATCH** 更新正文 —— `gh pr edit` 走 GraphQL，
#      作者凭据没有 read:org，会报错且**静默不更新**（见 references/traps.md 陷阱 5）
#   ⑤ 证据块 SHA 注入（C7，#161；边界见 references/exceptions.md §6）：把正文**围栏外**每个标记
#      改写为**推送后**的 origin/<branch> head 并回读校验；正文零标记 → 直接失败（门禁会判 FAIL）
#   ⑥ 迁到 status/in-review
#
# 用法：
#   scripts/deliver.sh <issue#> --prepare --as author    # 生成六段骨架
#   （填写骨架）
#   scripts/deliver.sh <issue#> --as author              # 校验 + 推送 + 建/更新 PR

set -eu

SCRIPT_DIR="$(dirname "$0")"

# 作者凭据默认在**工作区之外**；**禁止**指回工作区内路径。写法与 review.sh 一致。
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
  [ -z "$main" ] || [ "$main" != "$ACTOR" ] || die "身份分离失败：作者身份 = gh 登录身份（${ACTOR}）"
  # 评审凭据**不在这里读**（SKILL.md §5：作者不得读取其他身份的凭据）。
  # 「评审 ≠ 作者」由 W6 `scripts/review.sh` 用**评审凭据自身**判定（平台另禁止自我批准）。
  ok "本次执行身份（作者）：${ACTOR}"
}

ISSUE=""
BODY_FILE=""
PREPARE=0
AS="author"
PARSE_ONLY=""
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prepare)   PREPARE=1; shift ;;
    --body-file) BODY_FILE="${2:?--body-file 需要取值}"; shift 2 ;;
    --as)        AS="${2:?--as 需要取值}"; shift 2 ;;
    --parse-only) PARSE_ONLY=1; shift ;;
    --dry-run)   DRY=1; shift ;;
    -h|--help)   sed -n '2,19p' "$0"; exit 0 ;;
    -*)          die "未知参数 ${1:-}（本脚本不提供该开关；用法见 scripts/deliver.sh -h）" 2 ;;
    *) ISSUE="$1"; shift ;;
  esac
done

# ── 参数级校验（取值域；**不依赖**仓库 / 凭据 / 网络）────────────────────
# 全部判据都属于「参数」，必须在读到仓库/凭据之前完成 —— 否则 ci/test 的
# 「文档命令可执行性」判据（--parse-only）会漏掉它们（#147 C3②）。
[ -n "$ISSUE" ] || die "用法：scripts/deliver.sh <issue#> [--prepare] [--body-file ...] [--as author]" 2
case "$ISSUE" in *[!0-9]*) die "Issue 编号必须是数字：${ISSUE}" 2 ;; esac
assert_author_as "$AS"
if [ -n "$PARSE_ONLY" ]; then
  printf '[ OK ] 参数解析通过（--parse-only；未读网络、未写任何文件）：%s\n' "$0"
  exit 0
fi

[ -f .github/rulesets/main-protection.json ] || die "请在仓库根目录运行"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
[ -n "$REPO" ] || die "无法确定仓库 slug（gh repo view 失败）"

use_identity "$AS"
[ -z "$BODY_FILE" ] && BODY_FILE=".git/PR_BODY_${ISSUE}.md"

info "状态预检（只读：任何副作用之前）"
# **必须**最先做：本脚本的副作用（写正文骨架 / 推送分支 / 建或更新 PR）**不可逆**。
# 先把状态读出来、只读判定合法性，再决定要不要动手；**禁止**先推送 / 建 PR 再迁移状态 ——
# 迁移非法会把仓库卡在半成品。
pstate="$(gh issue view "$ISSUE" -R "$REPO" --json state --jq .state 2>/dev/null || true)"
[ "$pstate" = "OPEN" ] || die "Issue #${ISSUE} 已 ${pstate:-未知}，不应对它开新 PR（policy/branch-name 会拒绝）"
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
case "$cur_state" in
  backlog|ready)
    die "Issue #${ISSUE} 当前 ${cur_state}，尚未开工：先 scripts/start.sh ${ISSUE} --as author（或 scripts/status.sh ${ISSUE} in-progress）再交付；本次**未写正文骨架、未推送、未建 PR**" ;;
esac
if ! "$(dirname "$0")/status.sh" --check-transition "$cur_state" in-review; then
  die "Issue #${ISSUE} 当前 ${cur_state}，不能交付（deliver.sh 只做 → in-review）。先按上方合法出边迁移再重跑；本次**未写正文骨架、未推送、未建 PR**"
fi
ok "当前状态：${cur_state}；迁移合法：${cur_state} → in-review（发生在任何副作用之前）"

if [ "$PREPARE" -eq 1 ]; then
  mkdir -p "$(dirname "$BODY_FILE")"
  cat > "$BODY_FILE" <<EOF
Closes #${ISSUE}

## 1. 变更摘要

<!-- 必须写：改了什么、解决了什么问题。评审人只看这里就该知道改动意图。 -->

## 2. 影响面

- 受影响范围：
- 是否破坏性变更：否 / 是
- 是否需要数据迁移：否 / 是

## 3. 回滚方式

<!-- 必须可执行：revert 本 PR / 恢复配置 / 反向迁移。不允许写"出问题再说"。 -->

## 4. 验收证据

<!-- 与 Issue 的验收标准逐条对应；给确切命令与输出，禁止"已测试通过"这类无证据断言。 -->

<!-- C7：每个证据块必须带产生它的 SHA。保留下面这行标记（一块一行，**放在围栏外**），scripts/deliver.sh 会把 sha 自动改写为推送后的 head SHA。 -->
<!-- evidence sha=<head> -->

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
  printf '填写后运行：%q/deliver.sh %s --as author\n' "$SCRIPT_DIR" "$ISSUE"
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

ok "Issue OPEN 且已进入状态机（状态预检已在任何副作用之前完成）"

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
# 标题判据 = ATX 标题形态 `^#{1,6}[[:space:]]`（井号**后面必须跟空白**）：
# 正文里以 `#` 开头但**不是**标题的行（Issue/PR 引用，如 `#152 引入了…`）必须计入长度 ——
# 用 `/^#/` 会把这类正文当标题跳过 → 该节 chars=0 → 误判"内容过少"（Issue #163 的真实病灶）。
# 小节边界 `## 1.`–`## 6.` 仍由第一条规则处理，不受本行影响。
empty_sec="$(awk '
  /^## [1-6]\./ { if (name != "" && chars < 20) printf "%s ", name; name=$0; chars=0; next }
  /^#{1,6}[[:space:]]/ { next }
  { gsub(/[[:space:]]/, ""); if (name != "") chars += length($0) }
  END { if (name != "" && chars < 20) printf "%s", name }
' "$BODY_FILE")"
[ -z "$empty_sec" ] || die "以下章节内容过少（需要真实填写）：${empty_sec}"
ok "各章节均有实质内容"

# ── C7（#161）证据块 SHA：前置条件 + 注入 + 自校验 ──────────────────────────────
# 判据本体在 ci/test（**唯一一处**）：PR 正文**围栏外**所有 <!-- evidence sha=… --> 的值
# 必须 == 本 PR 的 head SHA。本脚本**不**复写那份判据，只做三件事：
#   ① 前置条件：正文里至少 1 个标记 —— 零标记在 ci/test 是 FAIL（fail-closed，见
#      references/exceptions.md §6「零标记的语义」）；本地先失败 = 不把明知会红的状态推上去。
#   ② 自动注入：把每个标记的 sha 改写成**推送后**的远端 head（减少手工错误）。
#   ③ 自校验：注入后每个标记都必须是规范形，否则不建 / 不更新 PR。
# 标记形态规则与 ci/test 的判据同形，**必须**在围栏（``` / ~~~）之外 —— 围栏内是证据正文
# （粘进来的输出可能**包含标记样例**），既不参与判定、也不被注入改写（改了就不是证据原文了）。
# 候选判据 = 「以 evidence 开头的单行 HTML 注释」：**不排除** `>`，这样 `sha=<head>` 这类占位符
# 也会被认出来（占位符是**可见**的：未替换 → ci/test 判形态不合规；看不见 = 静默通过的口子）。
# 围栏判定按 CommonMark 口径：只有**同字符且不短于**开围栏的那一行才关闭（嵌套围栏不漏内容）。
evidence_markers() { # $1 = 文件 → 逐行列出围栏外的标记（行号:原文）
  awk '
    BEGIN { fence = 0; fchar = ""; flen = 0 }
    {
      line = $0
      if (line ~ /^[ \t]*(```|~~~)/) {
        tmp = line; sub(/^[ \t]*/, "", tmp); ch = substr(tmp, 1, 1); ln = 0
        while (substr(tmp, ln + 1, 1) == ch) ln++
        if (fence == 0) { fence = 1; fchar = ch; flen = ln; next }
        if (ch == fchar && ln >= flen) { fence = 0; fchar = ""; flen = 0 }
        next
      }
      if (fence) next
      s = line
      while (match(s, /<!--[ \t]*evidence.*-->/)) { printf "%d:%s\n", FNR, substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH) }
    }
  ' "$1" 2>/dev/null || true
}
evidence_count() { evidence_markers "$1" | grep -c . || true; }
markers="$(evidence_count "$BODY_FILE")"
if [ "${markers:-0}" -eq 0 ]; then
  die "正文的围栏之外没有任何证据块 SHA 标记 —— ci/test 的 C7 判据会判 FAIL（零标记 = 未声明证据块，fail-closed）。在 ${BODY_FILE} 的每个证据块处加一行 <!-- evidence sha=<head> -->（sha 值随写，本脚本会改写为推送后的 head）；本次未推送、未建/更新 PR"
fi
ok "证据块标记 ${markers} 个（C7：每个证据块都必须带产生它的 SHA）；推送后本脚本会把它们改写为远端 head SHA"

TITLE="$(gh issue view "$ISSUE" -R "$REPO" --json title --jq .title)"
existing_pr="$(gh pr list -R "$REPO" --head "$BRANCH" --state open --json number --jq '.[0].number // ""' 2>/dev/null || true)"

if [ "$DRY" -eq 1 ]; then
  info "[dry-run] 将要执行"
  printf "  git -c credential.helper= -c credential.helper='!gh auth git-credential' push -u origin %s\n" "$BRANCH"
  if [ -n "$existing_pr" ]; then
    printf '  REST PATCH repos/%s/pulls/%s  （更新正文，返修场景）\n' "$REPO" "$existing_pr"
  else
    printf '  gh pr create --base %s --title "%s (#%s)" --body-file %s\n' "$BASE_BRANCH" "$TITLE" "$ISSUE" "$BODY_FILE"
  fi
  printf '  %q/status.sh %s in-review --as %s\n' "$SCRIPT_DIR" "$ISSUE" "$AS"
  printf '  证据块 SHA 注入：%s 个标记 → sha=<推送后的 head>（本地 HEAD=%s）\n' "$markers" "$(git rev-parse HEAD)"
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

info "证据块 SHA 注入（C7）—— 标注的必须是**推送后**的远端 head"
# 为什么用 origin/<branch> 而不是本地 HEAD：PR 的 head SHA 由**远端**决定；
# 两者不等时标注本地 SHA 会得到一个「格式对、语义错」的标记（比没有标记更糟）。
head_sha="$(git rev-parse HEAD)"
remote_sha="$(git rev-parse "origin/${BRANCH}" 2>/dev/null || true)"
[ -n "$remote_sha" ] || die "读不到 origin/${BRANCH} 的 SHA —— 无法证明将要标注的 SHA 就是本 PR 的 head（fail-closed）；本次未建/更新 PR"
[ "$head_sha" = "$remote_sha" ] || die "本地 HEAD=${head_sha} 与 origin/${BRANCH}=${remote_sha} 不一致 —— 标记的 SHA 必须**就是**本 PR 的 head；先让两者一致再重跑；本次未建/更新 PR"
STAMPED_BODY="${BODY_FILE%.md}.stamped.md"
# 注入 = 把围栏外的每个标记**规范化并改写**为 <!-- evidence sha=<head> -->（同一形态，ci/test 的判据可逐字解析）；
# 围栏内（证据正文）**一字不改** —— 否则注入会改掉「证据原文」，正好违反 C7 的可追溯初衷。
awk -v sha="$head_sha" '
  BEGIN { fence = 0; fchar = ""; flen = 0 }
  {
    line = $0
    if (line ~ /^[ \t]*(```|~~~)/) {
      tmp = line; sub(/^[ \t]*/, "", tmp); ch = substr(tmp, 1, 1); ln = 0
      while (substr(tmp, ln + 1, 1) == ch) ln++
      if (fence == 0) { fence = 1; fchar = ch; flen = ln; print; next }
      if (ch == fchar && ln >= flen) { fence = 0; fchar = ""; flen = 0; print; next }
      print; next
    }
    if (fence) { print; next }
    while (match($0, /<!--[ \t]*evidence.*-->/)) { printf "%s<!-- evidence sha=%s -->", substr($0, 1, RSTART - 1), sha; $0 = substr($0, RSTART + RLENGTH) }
    print
  }
' "$BODY_FILE" > "$STAMPED_BODY"
leftover="$(evidence_markers "$STAMPED_BODY" | sed -E 's/^[0-9]+://' | grep -vxF "<!-- evidence sha=${head_sha} -->" || true)"
[ -z "$leftover" ] || die "注入后仍有不合规的证据块标记：${leftover}（本次未建/更新 PR）"
evidence_markers "$STAMPED_BODY" | sed 's/^/   /'
ok "已注入 $(evidence_count "$STAMPED_BODY") 个证据块标记 → sha=${head_sha}（= origin/${BRANCH}）；注入稿：${STAMPED_BODY}（原正文文件未改）"
want="$(cat "$STAMPED_BODY")"

if [ -n "$existing_pr" ]; then
  info "该分支已有 PR #${existing_pr}（返修）—— 用 REST PATCH 更新正文"
  if ! jq -Rs '{body:.}' "$STAMPED_BODY" | gh api -X PATCH "repos/${REPO}/pulls/${existing_pr}" --input - >/dev/null; then
    die "更新 PR #${existing_pr} 正文失败（作者凭据缺 read:org，**不要**改用 gh pr edit）"
  fi
  got="$(gh api "repos/${REPO}/pulls/${existing_pr}" --jq .body 2>/dev/null || true)"
  [ "$got" = "$want" ] || die "更新 PR #${existing_pr} 正文后回读不一致（疑似静默未更新）"
  ok "已更新 PR #${existing_pr} 正文（REST PATCH，回读一致；标记 sha=${head_sha}）"
  PR_NUM="$existing_pr"
else
  info "创建 PR"
  url="$(gh pr create -R "$REPO" --base "$BASE_BRANCH" --title "${TITLE} (#${ISSUE})" --body-file "$STAMPED_BODY")"
  PR_NUM="${url##*/}"
  ok "PR 已创建：${url}"
  # 注入要**到达产物**才算成立：建 PR 也回读一次（与 PATCH 路径同一口径）——
  # 否则「本地注入成功、PR 正文里没有标记」是静默的，而 ci/test 会因此 FAIL。
  got_create="$(gh api "repos/${REPO}/pulls/${PR_NUM}" --jq .body 2>/dev/null || true)"
  [ "$got_create" = "$want" ] || die "PR #${PR_NUM} 正文回读与注入后的正文不一致（证据块标记可能没写进产物）；**不要**改用 gh pr edit —— 它走 GraphQL，作者凭据会静默失败"
  ok "PR #${PR_NUM} 正文含注入后的证据块标记（回读一致；sha=${head_sha}）"
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
"$(dirname "$0")/status.sh" "$ISSUE" in-review --as "$AS"

echo
printf '下一步：\n'
printf '  1) 等必需检查：gh pr checks %s --required\n' "$PR_NUM"
printf '  2) 独立评审（**不加** --as，走评审身份）：%q/review.sh %s approve --body-file review.md\n' "$SCRIPT_DIR" "$PR_NUM"
printf '  3) 合并（只有 dispatcher）：gh pr merge %s --squash --delete-branch\n' "$PR_NUM"
printf '  4) 收尾核验：%q/closeout.sh %s\n' "$SCRIPT_DIR" "$PR_NUM"
