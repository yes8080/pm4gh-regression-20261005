#!/usr/bin/env bash
# scripts/deliver.sh <issue#> [--prepare] [--title TITLE] [--body-file FILE] [--as author|main] [--dry-run]
#
# --as <author|main>：执行身份。**默认 main**（gh 登录的主体 = dispatcher，向后兼容）。
#   author = 作者身份 yes8080-dev-bot（凭据 .secrets/developer.pat，决策 D1：推送分支/开 PR）
#   author 模式先做身份自检（当前生效身份必须等于凭据里的身份），再用该身份推送与建 PR
#
# W5「交付 PR」：一条命令完成
#   ① 校验分支名合规且对应当前 Issue（policy/branch-name 的本地预演）
#   ② 校验 PR 正文六段齐备且含 Closes 关键字（policy/linked-issue 与 policy/template 的本地预演）
#   ③ 推送分支并用 gh pr create 建 PR
#
# 为什么要本地预演：官方限制下，关闭关键字**只在 PR 正文或提交信息中**生效，**PR 标题无效**；
# 且 `--fill` 在多提交时只带提交标题、会丢掉正文里的 Closes。所以本脚本强制使用正文文件。
#
# 流程：
#   scripts/deliver.sh 6 --prepare        # 生成正文骨架到 .git/PR_BODY_6.md
#   （填写骨架）
#   scripts/deliver.sh 6                  # 校验并创建 PR

set -eu
. "$(dirname "$0")/lib.sh"

ISSUE=""
TITLE=""
BODY_FILE=""
PREPARE=0
AS="main"
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --prepare)   PREPARE=1; shift ;;
    --title)     TITLE="${2:?--title 需要取值}"; shift 2 ;;
    --body-file) BODY_FILE="${2:?--body-file 需要取值}"; shift 2 ;;
    --as)        AS="${2:?--as 需要取值 author|main}"; shift 2 ;;
    --dry-run)   DRY=1; shift ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    *) ISSUE="$1"; shift ;;
  esac
done

[ -n "$ISSUE" ] || die "用法：scripts/deliver.sh <issue#> [--prepare] [--title ...] [--body-file ...] [--as author|main]"
case "$ISSUE" in *[!0-9]*) die "Issue 编号必须是数字：${ISSUE}" ;; esac
case "$AS" in author|main) : ;; *) die "--as 只能是 author|main（当前：${AS}）" ;; esac

require_repo_root
case "$AS" in
  author)
    # 作者身份链路（决策 D1 / Bug #53）：推送分支与开 PR 都由作者身份完成
    use_developer_identity
    assert_developer_identity
    ;;
  main)
    use_main_identity
    who="$(current_gh_login)"
    [ -n "$who" ] || die "无法读取当前 gh 身份（gh 未登录？见 docs/PLAYBOOK.md §3）"
    ok "本次执行身份（--as main）：${who}"
    ;;
esac

[ -z "$BODY_FILE" ] && BODY_FILE=".git/PR_BODY_${ISSUE}.md"

if [ "$PREPARE" -eq 1 ]; then
  issue_title="$(issue_json "$ISSUE" 'title' '.title')"
  mkdir -p "$(dirname "$BODY_FILE")"
  cat > "$BODY_FILE" <<EOF
Closes #${ISSUE}

## 1. 变更摘要

<!-- 做了什么、为什么这么做 -->

## 2. 影响面

- 受影响范围：
- 是否破坏性变更：否 / 是
- 是否需要数据迁移：否 / 是

## 3. 回滚方式

<!-- 必须可执行 -->

## 4. 验收证据

| 验收条目 | 证据（命令 / 测试名 / 输出） | 结果 |
|---|---|---|
|  |  |  |

## 5. DoD 自查

- [ ] 验收标准逐条有证据（第 4 节）
- [ ] 本地自检通过
- [ ] 文档/ADR 已更新（涉及接口、数据、运维变更时）
- [ ] 未越界：没有改切片 Issue「边界」之外的内容
- [ ] 已确认回滚方式可执行（第 3 节）
- [ ] 提交信息遵循 Conventional Commits 并带 Issue 号

## 6. 风险与破坏性变更
EOF
  ok "正文骨架已生成：${BODY_FILE}（切片标题：${issue_title}）"
  log "填写后运行：scripts/deliver.sh ${ISSUE}"
  exit 0
fi

info "校验当前分支"
BRANCH="$(git branch --show-current)"
[ -n "$BRANCH" ] || die "当前处于游离 HEAD，请先切到切片分支"
assert_branch_name "$BRANCH"
branch_issue="${BRANCH#*/}"; branch_issue="${branch_issue%%-*}"
[ "$branch_issue" = "$ISSUE" ] || die "当前分支 ${BRANCH} 指向 Issue #${branch_issue}，与传入的 #${ISSUE} 不一致"
ok "分支 ${BRANCH} 合规且对应 #${ISSUE}"

state="$(issue_state "$ISSUE")"
[ "$state" = "OPEN" ] || die "Issue #${ISSUE} 已 ${state}，不应对它开新 PR（返修请重开或新建 Bug Issue）"

if [ -n "$(git status --porcelain)" ]; then
  warn "工作区有未提交改动："
  git status --short >&2
  die "请先提交（门禁要求 PR 内含完整改动）"
fi
ok "工作区干净"

info "校验 PR 正文"
[ -f "$BODY_FILE" ] || die "找不到正文文件 ${BODY_FILE}（先运行 scripts/deliver.sh ${ISSUE} --prepare）"
grep -qiE "(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]*:?[[:space:]]*#${ISSUE}([^0-9]|$)" "$BODY_FILE" \
  || die "正文缺少指向本 Issue 的关闭关键字，例如 Closes #${ISSUE}（注意：PR 标题里的关键字无效）"
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

[ -n "$TITLE" ] || TITLE="$(issue_json "$ISSUE" 'title' '.title')"
git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 || \
  log "  （分支尚无上游，将自动推送）"

if [ "$DRY" -eq 1 ]; then
  log "[dry-run] git -c credential.helper= -c credential.helper='!gh auth git-credential' push -u origin ${BRANCH}"
  log "[dry-run] gh pr create --base ${BASE_BRANCH} --title \"${TITLE} (#${ISSUE})\" --body-file ${BODY_FILE}"
  exit 0
fi

info "推送分支（身份：$(current_gh_login)）"
# 必须捕获退出码：`git push … | tail -2` 的管道退出码取自 tail（本脚本未开 pipefail），
# 会把"推送被服务端拒绝"吞掉，然后继续用**远端的旧分支**建出一个 PR（Bug #51 的旁支隐患）。
push_out=""
if ! push_out="$(push_branch_as_current_identity "$BRANCH" 2>&1)"; then
  printf '%s\n' "$push_out" >&2
  die "推送失败（上方为服务端原文）。若含 'without workflow scope'，按 docs/PLAYBOOK.md W0.4 重新签发带 workflow scope 的作者凭据；**不要**改用主身份推送、不要 --admin"
fi
printf '%s\n' "$push_out" | tail -2

info "创建 PR"
url="$(gh pr create -R "$REPO" --base "$BASE_BRANCH" --title "${TITLE} (#${ISSUE})" --body-file "$BODY_FILE")"
ok "PR 已创建：${url}"

num="${url##*/}"
ok "PR 作者：@$(pr_author "$num")（本次执行身份：$(current_gh_login)，--as ${AS}）"

info "状态迁移：→ in-review"
"$(dirname "$0")/status.sh" "$ISSUE" in-review
echo
log "下一步："
log "  1) 等待必需检查：gh pr checks ${num} --required"
log "  2) 由授权身份评审：scripts/review.sh ${num} approve"
log "  3) 通过后合并：gh pr merge ${num} --squash --delete-branch"
log "  4) 收尾核验：scripts/closeout.sh ${num}"
