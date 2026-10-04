#!/usr/bin/env bash
# scripts/lib.sh —— 共用函数与常量（被其他脚本 source，不单独执行）
#
# 兼容性铁律（本项目已实测踩坑，见 附录 C.1）：
#   1. 只用 bash 3.2 可用语法：禁止 mapfile / readarray / declare -A / ${var,,}
#      —— macOS 自带 bash 就是 3.2，用了这些就"换台机器跑不动"
#   2. 变量后紧跟中文等多字节字符时必须写 ${VAR}，否则 bash 3.2 会把字节序列并入变量名，
#      报 "unbound variable"（同一坑已踩到三次）
#
# 身份约定（决策 D1/D2，W0.4）：
#   · 主/dispatcher 身份 = gh 已登录账号（yes8080：治理、合并）→ 用 use_main_identity
#   · 作者身份 = .secrets/developer.pat（yes8080-dev-bot：建分支/提交/开 PR/返修）→ 用 use_developer_identity
#   · 评审/验收身份 = .secrets/reviewer.pat（授权清单里的账号）→ 用 use_reviewer_identity
#   脚本级入口：scripts/start.sh|deliver.sh 的 `--as author|main`（Bug #53）。
#   gh 的凭据回退链是 GH_TOKEN → GITHUB_TOKEN → 登录态，所以两个 use_* 都必须把两个环境变量都定死，
#   否则环境里残留的变量会让"作者身份"或"主身份"静默变成另一个身份（Bug #53 / #54）。
#
# 用法：. "$(dirname "$0")/lib.sh"

set -eu

log()  { printf '%s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
ok()   { printf '[ OK ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
# 注意：退出码必须与消息分离 —— 早期实现写成 exit "${2:-1}" 但消息用 "$*"，
# 导致 `die "消息" 2` 输出 `[FAIL] 消息 2`（退出码被拼进消息）。第二次工具切换演练实测发现（Bug #29）。
die()  { local m="${1:-}"; local c="${2:-1}"; printf '[FAIL] %s\n' "$m" >&2; exit "$c"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令 ${1}，请先安装"
}

require_repo_root() {
  [ -f .github/rulesets/main-protection.json ] || \
    die "请在仓库根目录运行（未找到 .github/rulesets/main-protection.json）"
}

resolve_repo() {
  if [ -n "${REPO:-}" ]; then printf '%s' "$REPO"; return 0; fi
  local r
  r="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
  [ -n "$r" ] || die "无法确定仓库：请在仓库内运行，或设置 REPO=owner/repo"
  printf '%s' "$r"
}

# 解析仓库时临时清空 GH_TOKEN：source 阶段早于任何 use_*_identity 调用，
# 若环境里残留一个失效的 GH_TOKEN（例如 GH_TOKEN=bogus 或过期的 PAT），
# resolve_repo 会直接失败并让**所有**脚本卡在 source 阶段。
# 第二次工具切换演练实测：`GH_TOKEN=bogus bash scripts/audit.sh` → `[FAIL] 无法确定仓库`（Bug #29）。
_resolve_saved_token="${GH_TOKEN:-}"
unset GH_TOKEN || true
REPO="$(resolve_repo)"
if [ -n "${_resolve_saved_token}" ]; then export GH_TOKEN="${_resolve_saved_token}"; fi
unset _resolve_saved_token || true
SECRETS_DIR="${SECRETS_DIR:-.secrets}"
REVIEWER_PAT_FILE="${REVIEWER_PAT_FILE:-${SECRETS_DIR}/reviewer.pat}"
DEVELOPER_PAT_FILE="${DEVELOPER_PAT_FILE:-${SECRETS_DIR}/developer.pat}"
AUTH_IDENTITIES_FILE="${AUTH_IDENTITIES_FILE:-.github/authorized-identities.txt}"
RULESET_FILE="${RULESET_FILE:-.github/rulesets/main-protection.json}"
BASE_BRANCH="${BASE_BRANCH:-main}"

# ── 身份切换 ────────────────────────────────────────────────
# 主身份 = gh 登录态。必须**同时**清掉 GH_TOKEN 与 GITHUB_TOKEN：
# gh 的优先级是 GH_TOKEN > GITHUB_TOKEN > 登录态，早期只清 GH_TOKEN 时，
# `GITHUB_TOKEN=<作者 PAT> scripts/xxx.sh`（Bug #53 的临时绕过）会让主身份脚本静默变成作者身份。
use_main_identity() {
  unset GH_TOKEN || true
  unset GITHUB_TOKEN || true
}

# 当前生效身份（GH_TOKEN / GITHUB_TOKEN 或 gh 登录态）—— 用于把"身份到底是谁"做成可核对输出
current_gh_login() { gh api user --jq .login 2>/dev/null || true; }

# 读取 classic PAT 的 OAuth scope 列表（只读响应头，不打印凭据本身）。
# 官方格式：`x-oauth-scopes: repo, workflow`（逗号 + 空格分隔）。
# 返回空 = 拿不到 scope 头（凭据失效，或不是 classic PAT）→ 调用方必须按"未知/失败"处理，
# 不得当成"没有 scope 要求"而跳过（Bug #51 的教训：缺 scope 会在服务端整体拒绝推送）。
pat_scopes() {
  local file="${1:-}"
  [ -s "$file" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  curl -sS -I -H "Authorization: token $(cat "$file")" https://api.github.com/user 2>/dev/null \
    | grep -i '^x-oauth-scopes:' \
    | sed -E 's/^[Xx]-[Oo][Aa]uth-[Ss]copes:[[:space:]]*//' \
    | tr -d '\r' | tr ',' '\n' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | grep -v '^$' || true
}

# 作者身份（决策 D1）：建分支、提交、开 PR、返修用 dev-bot；合并权不在此身份
use_developer_identity() {
  [ -s "$DEVELOPER_PAT_FILE" ] || die "找不到作者身份凭据 ${DEVELOPER_PAT_FILE}（开通流程见 docs/PLAYBOOK.md W0.4）"
  GH_TOKEN="$(cat "$DEVELOPER_PAT_FILE")"
  export GH_TOKEN
  # GH_TOKEN 优先于 GITHUB_TOKEN，这里只是为了不留歧义（见 use_main_identity 注释）
  unset GITHUB_TOKEN || true
  local who
  who="$(current_gh_login)"
  [ -n "$who" ] || die "作者身份凭据无效（无法读取身份）"
  ok "已切换作者身份：${who}"

  # scope 自检（Bug #51 / W0.4）：缺 workflow 时服务端会整体拒绝推送 .github/workflows/**。
  # 这里只**告警不阻断**（不碰 workflows 的切片仍可用作者身份干活）；
  # 硬门禁在 scripts/toolcheck.sh 第 10 项 —— 那里缺 workflow 直接失败。
  local scopes
  scopes="$(pat_scopes "$DEVELOPER_PAT_FILE" | tr '\n' ' ' | sed -E 's/[[:space:]]+$//')"
  case " ${scopes} " in
    *" workflow "*) ok "作者凭据 scope 含 workflow（可推送 .github/workflows/**）" ;;
    *) warn "作者凭据 scope 不含 workflow（实测 scope：${scopes:-读取不到}）—— 触碰 .github/workflows/** 的推送会被服务端整体拒绝（原文见 docs/PLAYBOOK.md W0.4）；scripts/toolcheck.sh 第 10 项会直接失败" ;;
  esac
}

use_reviewer_identity() {
  [ -s "$REVIEWER_PAT_FILE" ] || die "找不到评审身份凭据 ${REVIEWER_PAT_FILE}（见 docs/PLAYBOOK.md 凭据章节）"
  GH_TOKEN="$(cat "$REVIEWER_PAT_FILE")"
  export GH_TOKEN
  unset GITHUB_TOKEN || true
}

# 身份自检：① 当前生效身份必须与作者凭据文件里的身份一致（防止 GH_TOKEN 没真正生效而静默退回主身份）；
#          ② 身份分离（D1）：作者身份不得等于评审身份，也不得等于 gh 登录的主身份。
# 为什么需要 ②：W0.4 实测教训 —— 登错浏览器账号 / 把 token 复制进错误文件，都会让"作者身份"静默变成
# 主身份或评审身份，D1 就名存实亡，而工具链完全看不出来。
assert_developer_identity() {
  local want me reviewer main_login
  want="$(GH_TOKEN="$(cat "$DEVELOPER_PAT_FILE")" gh api user --jq .login 2>/dev/null || true)"
  me="$(current_gh_login)"
  [ -n "$want" ] || die "无法从 ${DEVELOPER_PAT_FILE} 读取作者身份（凭据失效？见 docs/PLAYBOOK.md W0.4）"
  [ "$me" = "$want" ] || die "身份自检失败：当前生效身份是 ${me}，期望作者身份 ${want}（不要用未文档化的 GITHUB_TOKEN 迂回，见 Bug #53）"
  ok "身份自检通过：当前生效身份 = 作者身份 ${me}"

  if [ -s "$REVIEWER_PAT_FILE" ]; then
    reviewer="$(GH_TOKEN="$(cat "$REVIEWER_PAT_FILE")" gh api user --jq .login 2>/dev/null || true)"
    if [ -n "$reviewer" ]; then
      [ "$me" != "$reviewer" ] || die "身份分离自检失败：当前生效身份 ${me} 与评审身份相同 —— 检查 ${DEVELOPER_PAT_FILE} 与 ${REVIEWER_PAT_FILE} 是否拿错（作者不得等于评审）"
      ok "身份分离自检：作者 ${me} ≠ 评审 ${reviewer}"
    fi
  fi

  main_login="$(env -u GH_TOKEN -u GITHUB_TOKEN gh api user --jq .login 2>/dev/null || true)"
  if [ -n "$main_login" ]; then
    [ "$me" != "$main_login" ] || die "身份分离自检失败：当前生效身份 ${me} 与 gh 登录的主身份相同 —— ${DEVELOPER_PAT_FILE} 很可能误放了主身份的 token（W0.4 实测踩过：登错浏览器账号）"
    ok "身份分离自检：作者 ${me} ≠ 主身份 ${main_login}"
  else
    warn "读不到 gh 登录的主身份，跳过「作者 ≠ 主身份」这一条自检（gh 未登录？见 docs/PLAYBOOK.md §3）"
  fi
}

# 作者身份的 git 提交者信息（运行时从凭据推导；不硬编码账号与数字 ID）
# 输出一行：<login> <id>+<login>@users.noreply.github.com
developer_git_identity() {
  local login id
  login="$(current_gh_login)"
  id="$(gh api user --jq .id 2>/dev/null || true)"
  [ -n "$login" ] && [ -n "$id" ] || return 1
  printf '%s %s+%s@users.noreply.github.com' "$login" "$id" "$login"
}

# 以**当前生效身份**推送分支。
# 为什么必须清空本地 credential.helper：macOS 钥匙串等 helper 里缓存的主身份凭据会优先命中，
# 让"作者身份推送"静默变成主身份推送（身份分离失效）；换成 gh 的凭据助手则跟随 GH_TOKEN。
# 这条命令就是 Bug #51 复现时用的等价命令，现在收进脚本，不再需要手工拼。
push_branch_as_current_identity() {
  local branch="$1"
  git -c credential.helper= -c credential.helper='!gh auth git-credential' push -u origin "$branch"
}

# ── 查询helper ──────────────────────────────────────────────
issue_json()  { gh issue view "$1" -R "$REPO" --json "$2" --jq "$3"; }
issue_state() { gh issue view "$1" -R "$REPO" --json state --jq .state; }
pr_json()     { gh pr view "$1" -R "$REPO" --json "$2" --jq "$3"; }
pr_state()    { gh pr view "$1" -R "$REPO" --json state --jq .state; }
pr_head_ref() { gh pr view "$1" -R "$REPO" --json headRefName --jq .headRefName; }
pr_author()   { gh pr view "$1" -R "$REPO" --json author --jq .author.login; }

# 实测：blockedBy 不会因对方关闭而自动清除 → 判定"是否真被阻塞"必须看 blocker 的 state
open_blockers() {
  gh issue view "$1" -R "$REPO" --json blockedBy \
    --jq '[.blockedBy.nodes[] | select(.state == "OPEN") | "#\(.number)"] | join(" ")' 2>/dev/null || true
}

required_contexts() {
  jq -r '.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context' "$RULESET_FILE"
}

authorized_identities() {
  grep -vE '^[[:space:]]*(#|$)' "$AUTH_IDENTITIES_FILE" 2>/dev/null || true
}

# 工作流里实际会产生的检查名（job 的 name）
workflow_check_names() {
  grep -hE '^[[:space:]]+name: (ci|policy|qa)/' .github/workflows/*.yml 2>/dev/null \
    | sed 's/.*name: //' | sort -u
}

live_ruleset_id() {
  gh api "repos/${REPO}/rulesets" --jq '.[] | select(.name == "main-protection") | .id' 2>/dev/null | head -1
}

file_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null || printf '?'
}

# 确认 PR 的 head 分支名符合命名规范；不合规直接失败
assert_branch_name() {
  case "$1" in
    slice/*|fix/*|hotfix/*|spike/*|chore/*) : ;;
    *) die "分支名 ${1} 不符合 <type>/<issue#>-<slug> 规范" ;;
  esac
  printf '%s' "$1" | grep -qE '^(slice|fix|hotfix|spike|chore)/[0-9]+-[a-z0-9-]+$' \
    || die "分支名 ${1} 不符合规范：slug 只允许小写字母、数字、连字符"
}

# 从 Issue 标题推导 slug（仅取 ASCII，小写化用 tr，避免 bash4 的 ${var,,}）
# ★ 必须用 `sed -E`：macOS 自带 BSD sed 不支持 BRE 里的 `\+`，会被当成字面量 `+`，
#   导致替换整体失效（首次实测就是这样失败：中文与括号原样保留）。
slug_from_title() {
  printf '%s' "$1" \
    | LC_ALL=C sed -E 's/[^A-Za-z0-9]+/-/g' \
    | tr 'A-Z' 'a-z' \
    | sed -E -e 's/^-+//' -e 's/-+$//' \
    | cut -c1-40
}


# ── 状态机（决策 D9：Projects 已移除，状态由 status/* 标签 + Issue 开关承载）──
# 唯一状态载体。Backlog = 无 status/* 标签；Done/Canceled = Issue 已关闭。
STATUS_LABELS="status/ready status/in-progress status/in-review status/acceptance status/rework"

# 读取 Issue 的当前状态（字符串）
status_of_issue() {
  local n="$1" st reason labels
  st="$(gh issue view "$n" -R "$REPO" --json state --jq .state 2>/dev/null || true)"
  if [ "$st" = "CLOSED" ]; then
    reason="$(gh issue view "$n" -R "$REPO" --json stateReason --jq '.stateReason // "COMPLETED"' 2>/dev/null || echo COMPLETED)"
    case "$reason" in
      NOT_PLANNED|not_planned) printf 'canceled' ;;
      *) printf 'done' ;;
    esac
    return 0
  fi
  labels="$(gh issue view "$n" -R "$REPO" --json labels \
    --jq '[.labels[].name | select(startswith("status/"))] | .[0] // ""' 2>/dev/null || true)"
  case "$labels" in
    "") printf 'backlog' ;;
    "status/ready")        printf 'ready' ;;
    "status/in-progress")  printf 'in-progress' ;;
    "status/in-review")    printf 'in-review' ;;
    "status/acceptance")   printf 'acceptance' ;;
    "status/rework")       printf 'rework' ;;
    *) printf 'unknown(%s)' "$labels" ;;
  esac
}

# 校验开放 Issue 至多一个 status/* 标签；不合规则非零退出
assert_single_status() {
  local n="$1" cnt
  cnt="$(gh issue view "$n" -R "$REPO" --json labels \
    --jq '[.labels[].name | select(startswith("status/"))] | length' 2>/dev/null || echo 0)"
  [ "$cnt" -le 1 ] || die "Issue #${n} 有 ${cnt} 个 status/* 标签（状态必须唯一）—— 用 scripts/status.sh 修正"
}
