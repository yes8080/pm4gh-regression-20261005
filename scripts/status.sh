#!/usr/bin/env bash
# scripts/status.sh —— 状态机的**唯一迁移入口**（唯一源 = status/* 标签 + Issue 开关状态）
#
# 用法：
#   scripts/status.sh <issue#> <state>     # 迁移到指定状态
#   scripts/status.sh <issue#> --show      # 查看当前状态
#   scripts/status.sh --check              # 扫**全部开放 Issue**：每个恰好 0 或 1 个合法 status/*
#
# 状态：backlog（无标签）| ready | in-progress | in-review | acceptance | rework | done | canceled
# 不变量：开放 Issue 至多一个 status/* 标签；Migration 只允许走本脚本。
# 退出码：0 成功；1 校验/迁移失败；2 参数错误

set -eu

die()  { printf '[FAIL] %s\n' "${1:-}" >&2; exit "${2:-1}"; }
ok()   { printf '[ OK ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
info() { printf '\n== %s ==\n' "$*"; }

STATUS_LABELS="status/ready status/in-progress status/in-review status/acceptance status/rework"
VALID_STATES="backlog ready in-progress in-review acceptance rework done canceled"
BASE_LABEL_OF_STATE() {
  case "$1" in
    ready)       printf 'status/ready' ;;
    in-progress) printf 'status/in-progress' ;;
    in-review)   printf 'status/in-review' ;;
    acceptance)  printf 'status/acceptance' ;;
    rework)      printf 'status/rework' ;;
    *)           printf '' ;;
  esac
}

[ -f .github/rulesets/main-protection.json ] || die "请在仓库根目录运行"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
[ -n "$REPO" ] || die "无法确定仓库 slug（gh repo view 失败）"

# 身份：优先用当前生效身份；认证失败再回退到 gh 登录态（label 操作不产生身份归属）
ACTOR="$(gh api user --jq .login 2>/dev/null || true)"
if [ -z "$ACTOR" ]; then
  unset GH_TOKEN || true
  unset GITHUB_TOKEN || true
  ACTOR="$(gh api user --jq .login 2>/dev/null || true)"
fi
[ -n "$ACTOR" ] || die "无法认证：检查环境里的 GH_TOKEN 与 gh auth login（见 docs/WORKFLOW.md §0）"

# ── --check：扫描全部开放 Issue ──────────────────────────────
if [ "${1:-}" = "--check" ]; then
  info "扫描开放 Issue 的状态标签（仓库 ${REPO}，身份 ${ACTOR}）"
  rows="$(gh issue list -R "$REPO" --state open --limit 200 --json number,labels \
    --jq '.[] | "\(.number)\t\([.labels[].name | select(startswith("status/"))] | join(","))"' 2>/dev/null || true)"
  bad=0
  total=0
  backlog=0
  inprog=0
  while IFS="$(printf '\t')" read -r n labels; do
    [ -n "$n" ] || continue
    total=$((total + 1))
    if [ -z "$labels" ]; then
      backlog=$((backlog + 1))
      printf '  #%-5s backlog（无 status/* 标签）\n' "$n"
      continue
    fi
    cnt="$(printf '%s' "$labels" | tr ',' '\n' | grep -c . || true)"
    if [ "$cnt" -gt 1 ]; then
      warn "  #${n} 有 ${cnt} 个状态标签：${labels} —— 状态必须唯一"
      bad=$((bad + 1))
      continue
    fi
    case " ${STATUS_LABELS} " in
      *" ${labels} "*) : ;;
      *) warn "  #${n} 使用了未定义的状态标签：${labels}"; bad=$((bad + 1)); continue ;;
    esac
    printf '  #%-5s %s\n' "$n" "$labels"
    [ "$labels" = "status/in-progress" ] && inprog=$((inprog + 1))
  done <<EOF
${rows}
EOF
  info "小结：开放 Issue ${total} 个；backlog ${backlog} 个；in-progress ${inprog} 个"
  if [ "$inprog" -gt 1 ]; then
    warn "有 ${inprog} 个 in-progress —— 规则是「一次只做一个切片」（见 AGENTS.md §2）"
  fi
  if [ "$bad" -eq 0 ]; then
    ok "全部开放 Issue 恰好 0 或 1 个合法 status/* 标签"
    exit 0
  fi
  warn "发现 ${bad} 个问题 —— 用 scripts/status.sh <issue#> <state> 修正"
  exit 1
fi

ISSUE="${1:-}"
[ -n "$ISSUE" ] || die "用法：scripts/status.sh <issue#> <state> | <issue#> --show | --check" 2
case "$ISSUE" in *[!0-9]*) die "Issue 编号必须是数字：${ISSUE}" 2 ;; esac

state_of() {
  st="$(gh issue view "$1" -R "$REPO" --json state --jq .state 2>/dev/null || true)"
  if [ "$st" = "CLOSED" ]; then
    reason="$(gh issue view "$1" -R "$REPO" --json stateReason --jq '.stateReason // "COMPLETED"' 2>/dev/null || echo COMPLETED)"
    case "$reason" in NOT_PLANNED|not_planned) printf 'canceled' ;; *) printf 'done' ;; esac
    return 0
  fi
  label="$(gh issue view "$1" -R "$REPO" --json labels \
    --jq '[.labels[].name | select(startswith("status/"))] | .[0] // ""' 2>/dev/null || true)"
  case "$label" in
    "")                    printf 'backlog' ;;
    status/ready)          printf 'ready' ;;
    status/in-progress)    printf 'in-progress' ;;
    status/in-review)      printf 'in-review' ;;
    status/acceptance)     printf 'acceptance' ;;
    status/rework)         printf 'rework' ;;
    *)                     printf 'unknown(%s)' "$label" ;;
  esac
}

if [ "${2:-}" = "--show" ]; then
  info "Issue #${ISSUE} 当前状态：$(state_of "$ISSUE")"
  exit 0
fi

STATE="${2:-}"
[ -n "$STATE" ] || die "用法：scripts/status.sh <issue#> <state> | <issue#> --show | --check" 2
case " ${VALID_STATES} " in
  *" ${STATE} "*) : ;;
  *) die "未知状态 ${STATE}（合法值：${VALID_STATES}）" 2 ;;
esac

cur="$(state_of "$ISSUE")"
info "Issue #${ISSUE}：${cur} → ${STATE}"

if [ "$cur" = "$STATE" ]; then
  ok "已是 ${STATE}（幂等，无需改动）"
  exit 0
fi

# 先移除已有的全部 status/* 标签，保证互斥
rm_args=""
for l in $(gh issue view "$ISSUE" -R "$REPO" --json labels \
  --jq '[.labels[].name | select(startswith("status/"))] | .[]' 2>/dev/null || true); do
  rm_args="${rm_args} ${l}"
done

case "$STATE" in
  backlog|done|canceled)
    for l in $rm_args; do gh issue edit "$ISSUE" -R "$REPO" --remove-label "$l" >/dev/null; done
    case "$STATE" in
      backlog) ok "已置为 backlog（无状态标签）" ;;
      done)    gh issue close "$ISSUE" -R "$REPO" --reason completed >/dev/null; ok "已关闭（state_reason=completed）→ done" ;;
      canceled) gh issue close "$ISSUE" -R "$REPO" --reason "not planned" >/dev/null; ok "已关闭（state_reason=not_planned）→ canceled" ;;
    esac
    ;;
  *)
    target="$(BASE_LABEL_OF_STATE "$STATE")"
    [ -n "$target" ] || die "内部错误：${STATE} 没有对应标签"
    for l in $rm_args; do gh issue edit "$ISSUE" -R "$REPO" --remove-label "$l" >/dev/null; done
    gh issue edit "$ISSUE" -R "$REPO" --add-label "$target" >/dev/null
    ok "已置为 ${STATE}（标签 ${target}）"
    ;;
esac

now="$(state_of "$ISSUE")"
[ "$now" = "$STATE" ] || die "迁移后校验失败：期望 ${STATE}，实际 ${now}"
cnt="$(gh issue view "$ISSUE" -R "$REPO" --json labels \
  --jq '[.labels[].name | select(startswith("status/"))] | length' 2>/dev/null || echo 0)"
[ "$cnt" -le 1 ] || die "迁移后 Issue #${ISSUE} 有 ${cnt} 个状态标签 —— 状态必须唯一"
ok "迁移校验通过：${cur} → ${now}"
