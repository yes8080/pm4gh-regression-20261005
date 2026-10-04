#!/usr/bin/env bash
# scripts/start.sh <issue#> [--type slice|fix|hotfix|spike|chore] [--slug SLUG] [--as author|main] [--dry-run]
#
# --as <author|main>：执行身份。**默认 main**（gh 登录的主体 = dispatcher，向后兼容）。
#   author = 作者身份 yes8080-dev-bot（凭据 .secrets/developer.pat，决策 D1：建分支/指派/开工评论/提交/开 PR）
#   author 模式先做身份自检（当前生效身份必须等于凭据里的身份），再执行；结尾会打印作者身份的提交命令
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
AS="main"
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --type)  TYPE="${2:?--type 需要取值}"; shift 2 ;;
    --slug)  SLUG="${2:?--slug 需要取值}"; shift 2 ;;
    --as)    AS="${2:?--as 需要取值 author|main}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) ISSUE="$1"; shift ;;
  esac
done

[ -n "$ISSUE" ] || die "用法：scripts/start.sh <issue#> [--type ...] [--slug ...] [--as author|main] [--dry-run]"
case "$ISSUE" in *[!0-9]*) die "Issue 编号必须是数字：${ISSUE}" ;; esac
case "$TYPE" in slice|fix|hotfix|spike|chore) : ;; *) die "type 只能是 slice|fix|hotfix|spike|chore" ;; esac
case "$AS" in author|main) : ;; *) die "--as 只能是 author|main（当前：${AS}）" ;; esac

require_repo_root
case "$AS" in
  author)
    # 作者身份链路（决策 D1 / Bug #53）：建分支、指派、开工评论、开 PR 全部由作者身份完成
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
- 执行者：@$(current_gh_login)（\`--as ${AS}\`；作者身份 = 决策 D1）
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
if [ "$AS" = "author" ]; then
  gi="$(developer_git_identity || true)"
  log "  2) 以作者身份提交（提交者身份必须显式指定；提交信息用 -F 传文件，不要把带反引号的信息内联到命令行）："
  if [ -n "$gi" ]; then
    log "     git -c user.name=\"${gi%% *}\" -c user.email=\"${gi#* }\" commit -F <msg-file>"
  else
    log "     git -c user.name=<作者账号> -c user.email=<账号ID>+<作者账号>@users.noreply.github.com commit -F <msg-file>"
  fi
  log "  3) scripts/deliver.sh ${ISSUE} --prepare --as author   然后   scripts/deliver.sh ${ISSUE} --as author"
else
  log "  2) scripts/deliver.sh ${ISSUE} 交付 PR"
fi
