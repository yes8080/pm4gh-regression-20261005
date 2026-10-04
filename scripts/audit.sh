#!/usr/bin/env bash
# scripts/audit.sh [--stale-days N]
#
# 漂移审计：把"靠人记得检查"的事情变成一条命令。检查 5 类漂移：
#   ① 标签漂移（本地 labels.yml vs 远端）
#   ② 规则集漂移（线上 ruleset vs .github/rulesets/main-protection.json）
#   ③ 已合并 PR 但关联 Issue 仍为 open（会漏关单，尤其目标非默认分支时）
#   ④ 长期未活动的远程分支（默认 7 天）
#   ⑤ 阻塞关系已解除但未跟进（实测：blockedBy 不会因对方关闭而自动清除）
#
# 退出码：0 无硬性问题；1 存在需要处理的硬性问题（①②③）

set -eu
. "$(dirname "$0")/lib.sh"

STALE_DAYS=7
while [ $# -gt 0 ]; do
  case "$1" in
    --stale-days) STALE_DAYS="${2:?需要取值}"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) die "未知参数：${1}" ;;
  esac
done

require_repo_root
use_main_identity
case "$STALE_DAYS" in *[!0-9]*) die "--stale-days 必须是数字" ;; esac

hard=0
soft=0

epoch_of_iso() {
  if date -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s >/dev/null 2>&1; then
    date -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s
  else
    date -d "$1" +%s 2>/dev/null || echo 0
  fi
}

info "① 标签漂移"
if scripts/sync-labels.sh --check >/dev/null 2>&1; then
  ok "标签与远端一致"
else
  warn "标签存在漂移 —— 修复：scripts/sync-labels.sh"
  hard=$((hard + 1))
fi

info "② 规则集漂移"
rid="$(live_ruleset_id)"
if [ -z "$rid" ]; then
  warn "线上没有 main-protection 规则集 —— 门禁未生效"
  hard=$((hard + 1))
else
  live_ctx="$(gh api "repos/${REPO}/rulesets/${rid}" \
    --jq '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context' | sort)"
  file_ctx="$(required_contexts | sort)"
  if [ "$live_ctx" = "$file_ctx" ]; then
    ok "必需检查清单一致（id=${rid}）"
  else
    warn "规则集必需检查与仓库定义不一致："
    printf '  线上： %s\n' "$(printf '%s' "$live_ctx" | tr '\n' ' ')" >&2
    printf '  定义： %s\n' "$(printf '%s' "$file_ctx" | tr '\n' ' ')" >&2
    hard=$((hard + 1))
  fi
fi

info "③ 已合并 PR 但关联 Issue 仍 open（最近 30 个已合并 PR）"
leak=0
merged="$(gh pr list -R "$REPO" --state merged --limit 30 --json number --jq '.[].number' 2>/dev/null || true)"
for p in $merged; do
  for n in $(gh pr view "$p" -R "$REPO" --json closingIssuesReferences \
              --jq '[.closingIssuesReferences[].number] | join(" ")' 2>/dev/null || true); do
    st="$(gh issue view "$n" -R "$REPO" --json state --jq .state 2>/dev/null || echo UNKNOWN)"
    if [ "$st" = "OPEN" ]; then
      warn "PR #${p} 已合并，但 Issue #${n} 仍为 OPEN"
      leak=$((leak + 1))
    fi
  done
done
if [ "$leak" -eq 0 ]; then ok "无漏关单"; else hard=$((hard + 1)); fi

info "④ 超过 ${STALE_DAYS} 天未活动的远程分支"
now="$(date +%s)"
stale=0
for b in $(git ls-remote --heads origin 2>/dev/null | sed 's#.*refs/heads/##'); do
  [ "$b" = "$BASE_BRANCH" ] && continue
  iso="$(gh api "repos/${REPO}/commits/${b}" --jq .commit.committer.date 2>/dev/null || true)"
  [ -n "$iso" ] || continue
  ts="$(epoch_of_iso "$iso")"
  [ "$ts" -gt 0 ] || continue
  age_days=$(( (now - ts) / 86400 ))
  if [ "$age_days" -ge "$STALE_DAYS" ]; then
    warn "分支 ${b} 已 ${age_days} 天无提交 —— 要么推进，要么关闭对应 Issue 并删除分支"
    stale=$((stale + 1))
  fi
done
if [ "$stale" -eq 0 ]; then ok "无过期分支"; else soft=$((soft + 1)); fi

info "⑤ 阻塞已解除但未跟进"
ready=0
open_issues="$(gh issue list -R "$REPO" --state open --limit 100 --json number --jq '.[].number' 2>/dev/null || true)"
for n in $open_issues; do
  rel="$(gh issue view "$n" -R "$REPO" --json blockedBy \
          --jq '[.blockedBy.nodes[] | select(.state == "OPEN") | .number] | length' 2>/dev/null || echo 0)"
  total="$(gh issue view "$n" -R "$REPO" --json blockedBy --jq '.blockedBy.nodes | length' 2>/dev/null || echo 0)"
  if [ "$rel" = "0" ] && [ "$total" != "0" ]; then
    log "  #${n} 的阻塞项已全部关闭，但 blockedBy 关系仍挂着（官方不会自动清除）→ 可以开工"
    ready=$((ready + 1))
  fi
done
if [ "$ready" -eq 0 ]; then ok "无待解锁项"; fi

echo
log "审计汇总：硬性问题 ${hard} 个，提示性 ${soft} 个，可解锁切片 ${ready} 个"
if [ "$hard" -gt 0 ]; then
  warn "存在硬性问题，请按上述提示逐条处理"
  exit 1
fi
ok "无硬性问题"
