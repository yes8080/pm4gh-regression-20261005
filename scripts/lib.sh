#!/usr/bin/env bash
# scripts/lib.sh —— 共用函数与常量（被其他脚本 source，不单独执行）
#
# 兼容性铁律（本项目已实测踩坑，见 附录 C.1）：
#   1. 只用 bash 3.2 可用语法：禁止 mapfile / readarray / declare -A / ${var,,}
#      —— macOS 自带 bash 就是 3.2，用了这些就"换台机器跑不动"
#   2. 变量后紧跟中文等多字节字符时必须写 ${VAR}，否则 bash 3.2 会把字节序列并入变量名，
#      报 "unbound variable"（同一坑已踩到三次）
#
# 身份约定（方案 §6.2 D2）：
#   · 主身份 = gh 已登录账号（作者/实现者）→ 用 use_main_identity
#   · 评审/验收身份 = .secrets/reviewer.pat（授权清单里的账号）→ 用 use_reviewer_identity
#
# 用法：. "$(dirname "$0")/lib.sh"

set -eu

log()  { printf '%s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
ok()   { printf '[ OK ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[FAIL] %s\n' "$*" >&2; exit "${2:-1}"; }

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

REPO="$(resolve_repo)"
SECRETS_DIR="${SECRETS_DIR:-.secrets}"
REVIEWER_PAT_FILE="${REVIEWER_PAT_FILE:-${SECRETS_DIR}/reviewer.pat}"
AUTH_IDENTITIES_FILE="${AUTH_IDENTITIES_FILE:-.github/authorized-identities.txt}"
RULESET_FILE="${RULESET_FILE:-.github/rulesets/main-protection.json}"
BASE_BRANCH="${BASE_BRANCH:-main}"

# ── 身份切换 ────────────────────────────────────────────────
use_main_identity() {
  unset GH_TOKEN || true
}

use_reviewer_identity() {
  [ -s "$REVIEWER_PAT_FILE" ] || die "找不到评审身份凭据 ${REVIEWER_PAT_FILE}（见 docs/PLAYBOOK.md 凭据章节）"
  GH_TOKEN="$(cat "$REVIEWER_PAT_FILE")"
  export GH_TOKEN
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
