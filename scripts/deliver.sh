#!/usr/bin/env bash
# scripts/deliver.sh <issue#> [--prepare] [--title TITLE] [--body-file FILE] [--dry-run]
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
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --prepare)   PREPARE=1; shift ;;
    --title)     TITLE="${2:?--title 需要取值}"; shift 2 ;;
    --body-file) BODY_FILE="${2:?--body-file 需要取值}"; shift 2 ;;
    --dry-run)   DRY=1; shift ;;
    -h|--help)   sed -n '2,18p' "$0"; exit 0 ;;
    *) ISSUE="$1"; shift ;;
  esac
done

[ -n "$ISSUE" ] || die "用法：scripts/deliver.sh <issue#> [--prepare] [--title ...] [--body-file ...]"
case "$ISSUE" in *[!0-9]*) die "Issue 编号必须是数字：${ISSUE}" ;; esac

require_repo_root
use_main_identity

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
  log "[dry-run] git push -u origin ${BRANCH}"
  log "[dry-run] gh pr create --base ${BASE_BRANCH} --title \"${TITLE} (#${ISSUE})\" --body-file ${BODY_FILE}"
  exit 0
fi

info "推送分支"
git push -u origin "$BRANCH" 2>&1 | tail -2

info "创建 PR"
url="$(gh pr create -R "$REPO" --base "$BASE_BRANCH" --title "${TITLE} (#${ISSUE})" --body-file "$BODY_FILE")"
ok "PR 已创建：${url}"

num="${url##*/}"
echo
log "下一步："
log "  1) 等待必需检查：gh pr checks ${num} --required"
log "  2) 由授权身份评审：scripts/review.sh ${num} approve"
log "  3) 通过后合并：gh pr merge ${num} --squash --delete-branch"
log "  4) 收尾核验：scripts/closeout.sh ${num}"
