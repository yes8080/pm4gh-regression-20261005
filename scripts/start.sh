#!/usr/bin/env bash
# scripts/start.sh <issue#> [--type slice|fix|hotfix|spike|chore] [--slug SLUG] [--dry-run]
#
# W3「领取与开工」：一条命令完成
#   ① 校验 Issue 可开工（OPEN、无未关闭阻塞、未被他人占用）
#   ② 用 **gh issue develop** 创建并绑定分支（官方路径：这样 Issue 的 Development 区块才显示分支；
#      手工 git checkout -b 不会建立绑定 —— 首切片已踩过这个坑）
#   ③ 指派给自己 + 留"开工声明"评论（可审计时间线）
#
# 注意：`gh issue develop` 是官方一等公民能力，但 UI 文档仍标注为 public preview。

set -eu
. "$(dirname "$0")/lib.sh"

ISSUE=""
TYPE="slice"
SLUG=""
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --type)  TYPE="${2:?--type 需要取值}"; shift 2 ;;
    --slug)  SLUG="${2:?--slug 需要取值}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) ISSUE="$1"; shift ;;
  esac
done

[ -n "$ISSUE" ] || die "用法：scripts/start.sh <issue#> [--type ...] [--slug ...] [--dry-run]"
case "$ISSUE" in *[!0-9]*) die "Issue 编号必须是数字：${ISSUE}" ;; esac
case "$TYPE" in slice|fix|hotfix|spike|chore) : ;; *) die "type 只能是 slice|fix|hotfix|spike|chore" ;; esac

require_repo_root
use_main_identity

info "校验 Issue #${ISSUE}"
state="$(issue_state "$ISSUE")"
[ "$state" = "OPEN" ] || die "Issue #${ISSUE} 状态为 ${state}，不能开工（返修请重开原 Issue 或新建 Bug Issue）"

blockers="$(open_blockers "$ISSUE")"
if [ -n "$blockers" ]; then
  die "Issue #${ISSUE} 仍被未关闭的 Issue 阻塞：${blockers}（注意：blockedBy 不会因对方关闭而自动清除，这里只按 state=OPEN 判定）"
fi
ok "无未关闭阻塞"

title="$(issue_json "$ISSUE" 'title' '.title')"
[ -n "$SLUG" ] || SLUG="$(slug_from_title "$title")"
[ -n "$SLUG" ] || die "无法从标题推导 slug，请用 --slug 指定（只允许小写字母、数字、连字符）"
printf '%s' "$SLUG" | grep -qE '^[a-z0-9-]+$' || die "slug 只允许小写字母、数字、连字符：${SLUG}"

BRANCH="${TYPE}/${ISSUE}-${SLUG}"
assert_branch_name "$BRANCH"
info "分支名：${BRANCH}"

if git show-ref --verify --quiet "refs/heads/${BRANCH}" || git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
  die "分支 ${BRANCH} 已存在（本地或远端）。若为返修，请直接切回该分支继续提交，不要新建分支。"
fi

if [ "$DRY" -eq 1 ]; then
  log "[dry-run] gh issue develop ${ISSUE} --base ${BASE_BRANCH} --name ${BRANCH} --checkout"
  log "[dry-run] gh issue edit ${ISSUE} --add-assignee @me"
  log "[dry-run] 追加开工声明评论"
  exit 0
fi

info "创建并绑定分支（gh issue develop）"
gh issue develop "$ISSUE" -R "$REPO" --base "$BASE_BRANCH" --name "$BRANCH" --checkout >/dev/null
ok "分支已创建并绑定到 Issue #${ISSUE}"

gh issue edit "$ISSUE" -R "$REPO" --add-assignee @me >/dev/null
ok "已指派给自己"

gh issue comment "$ISSUE" -R "$REPO" --body "$(cat <<EOF
<!-- HANDOFF:v1 -->
**开工声明**

- 分支：\`${BRANCH}\`（由 \`gh issue develop\` 创建并绑定）
- 执行者：@$(gh api user --jq .login)
- 预计交付：
- 依赖状态：无未关闭阻塞

> 本评论由 \`scripts/start.sh\` 自动生成，构成可审计的开工时间线。
EOF
)" >/dev/null
ok "开工声明已提交"

info "状态迁移：backlog/ready → in-progress"
"$(dirname "$0")/status.sh" "$ISSUE" in-progress

echo
log "下一步："
log "  1) 实现并用 scripts/selfcheck 或本地测试自检"
log "  2) scripts/deliver.sh ${ISSUE} 交付 PR"
