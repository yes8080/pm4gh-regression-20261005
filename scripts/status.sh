#!/usr/bin/env bash
# scripts/status.sh —— 状态机迁移的**唯一合法入口**（决策 D9）
#
# 背景：Projects（v2）已整体移除，因为其"视图分组 / 自动化开关"无官方 API，无法纳入
#       可重建的代码资产。状态改由**全部可 API 化**的三件套承载：
#
#         Issue 开关状态  +  status/* 标签  +  Milestone
#
# 状态模型（唯一状态源）
#   backlog      无 status/* 标签，且 Issue OPEN
#   ready        status/ready
#   in-progress  status/in-progress
#   in-review    status/in-review
#   acceptance   status/acceptance
#   rework       status/rework
#   done         Issue CLOSED 且 state_reason = completed（由 Closes #N 自动达成）
#   canceled     Issue CLOSED 且 state_reason = not planned
#
# 不变量：**开放 Issue 至多一个 status/* 标签**（`--check` 与 CI 都会强制）
#
# 用法：
#   scripts/status.sh <issue#> <state>      # 迁移到指定状态
#   scripts/status.sh <issue#> --show       # 查看当前状态
#   scripts/status.sh --check               # 扫描全部开放 Issue 的互斥性与取值合法性
#
# 退出码：0 成功；1 迁移失败；2 参数或环境错误

set -eu
. "$(dirname "$0")/lib.sh"

usage() { sed -n '2,30p' "$0"; }

MODE="transition"
ISSUE=""
STATE=""

case "${1:-}" in
  --check)
    MODE="check" ;;
  -h|--help|"")
    usage; exit 0 ;;
  *)
    ISSUE="$1"; shift || true
    case "${1:-}" in
      --show) MODE="show" ;;
      *)      STATE="${1:-}" ;;
    esac ;;
esac

require_repo_root
use_main_identity

VALID_STATES="backlog ready in-progress in-review acceptance rework done canceled"

label_of_state() {
  case "$1" in
    backlog)     printf '' ;;
    ready)       printf 'status/ready' ;;
    in-progress) printf 'status/in-progress' ;;
    in-review)   printf 'status/in-review' ;;
    acceptance)  printf 'status/acceptance' ;;
    rework)      printf 'status/rework' ;;
    *)           printf '' ;;
  esac
}

# ── --check：扫描全部开放 Issue ──────────────────────────────
if [ "$MODE" = "check" ]; then
  info "扫描开放 Issue 的状态标签（互斥性与取值合法性）"
  bad=0
  rows="$(gh issue list -R "$REPO" --state open --limit 200 --json number,labels \
    --jq '.[] | "\(.number)\t\([.labels[].name | select(startswith("status/"))] | join(","))"' 2>/dev/null || true)"
  while IFS="$(printf '\t')" read -r n labels; do
    [ -n "$n" ] || continue
    cnt=0
    [ -n "$labels" ] && cnt="$(printf '%s' "$labels" | tr ',' '\n' | grep -c . )"
    if [ "$cnt" -gt 1 ]; then
      warn "Issue #${n} 有多个状态标签：${labels}"
      bad=$((bad + 1))
      continue
    fi
    if [ "$cnt" -eq 1 ]; then
      case " ${STATUS_LABELS} " in
        *" ${labels} "*) : ;;
        *) warn "Issue #${n} 使用了未定义的状态标签：${labels}"; bad=$((bad + 1)) ;;
      esac
    fi
  done <<EOF
${rows}
EOF
  if [ "$bad" -eq 0 ]; then
    ok "全部开放 Issue 状态标签合法且互斥"
    exit 0
  fi
  warn "发现 ${bad} 个问题 —— 用 scripts/status.sh <issue#> <state> 修正"
  exit 1
fi

[ -n "$ISSUE" ] || { usage; exit 2; }
case "$ISSUE" in *[!0-9]*) die "Issue 编号必须是数字：${ISSUE}" ;; esac

# ── --show ──────────────────────────────────────────────────
if [ "$MODE" = "show" ]; then
  info "Issue #${ISSUE} 当前状态：$(status_of_issue "$ISSUE")"
  exit 0
fi

# ── 迁移 ────────────────────────────────────────────────────
[ -n "$STATE" ] || { usage; exit 2; }
case " ${VALID_STATES} " in
  *" ${STATE} "*) : ;;
  *) die "未知状态 ${STATE}（合法值：${VALID_STATES}）" ;;
esac

cur="$(status_of_issue "$ISSUE")"
info "Issue #${ISSUE}：${cur} → ${STATE}"

# 先清理已有的 status/* 标签（互斥保证）
rem_args=()
cur_labels="$(gh issue view "$ISSUE" -R "$REPO" --json labels \
  --jq '[.labels[].name | select(startswith("status/"))] | .[]' 2>/dev/null || true)"
for l in $cur_labels; do
  rem_args[${#rem_args[@]}]="--remove-label"
  rem_args[${#rem_args[@]}]="$l"
done

case "$STATE" in
  backlog)
    if [ "${#rem_args[@]}" -gt 0 ]; then
      gh issue edit "$ISSUE" -R "$REPO" "${rem_args[@]}" >/dev/null
    fi
    ok "已置为 backlog（无状态标签）"
    ;;
  done)
    if [ "${#rem_args[@]}" -gt 0 ]; then
      gh issue edit "$ISSUE" -R "$REPO" "${rem_args[@]}" >/dev/null
    fi
    gh issue close "$ISSUE" -R "$REPO" --reason completed >/dev/null
    ok "已关闭 Issue（state_reason=completed）→ done"
    ;;
  canceled)
    if [ "${#rem_args[@]}" -gt 0 ]; then
      gh issue edit "$ISSUE" -R "$REPO" "${rem_args[@]}" >/dev/null
    fi
    gh issue close "$ISSUE" -R "$REPO" --reason "not planned" >/dev/null
    ok "已关闭 Issue（state_reason=not_planned）→ canceled"
    ;;
  *)
    target="$(label_of_state "$STATE")"
    # 若当前就是该状态且已 OPEN，则无需改动（幂等）
    if [ "$cur" = "$STATE" ]; then
      ok "已是 ${STATE}（幂等，无需改动）"
      exit 0
    fi
    if [ "${#rem_args[@]}" -gt 0 ]; then
      gh issue edit "$ISSUE" -R "$REPO" "${rem_args[@]}" --add-label "$target" >/dev/null
    else
      gh issue edit "$ISSUE" -R "$REPO" --add-label "$target" >/dev/null
    fi
    ok "已置为 ${STATE}（标签 ${target}）"
    ;;
esac

now="$(status_of_issue "$ISSUE")"
[ "$now" = "$STATE" ] || die "迁移后校验失败：期望 ${STATE}，实际 ${now}"
assert_single_status "$ISSUE"
ok "迁移校验通过：${cur} → ${now}"
