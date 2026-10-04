#!/usr/bin/env bash
# scripts/status.sh —— 状态机的**唯一迁移入口**（唯一源 = status/* 标签 + Issue 开关状态）
#
# 用法：
#   scripts/status.sh <issue#> <state> [--force]   # 迁移到指定状态
#   scripts/status.sh <issue#> --show              # 查看当前状态
#   scripts/status.sh --check                      # 扫**全部开放 Issue**：每个恰好 0 或 1 个合法 status/*
#   scripts/status.sh --check-transition <from> <to>  # **只读**判定迁移是否合法（零副作用；不读网络）
#   scripts/status.sh --check-cross                # **只读**交叉状态检查（Issue ↔ PR 四条规则；零副作用）
#
# --check-transition 专供「副作用不可逆」的脚本（start.sh / deliver.sh）在动手前调用：
# 非法时退出码 1 并打印 from 的合法出边与正确命令；合法时退出码 0，且绝不改动任何东西。
#
# 状态集（7）：backlog | ready | in-progress | in-review | rework | done | canceled
#   - backlog = 无任何 status/* 标签且 Issue OPEN
#   - ready / in-progress / in-review / rework = 对应 status/* 标签，**互斥**
#   - done / canceled = Issue CLOSED（state_reason=completed / not planned）**且**无任何 status/* 标签
#   - in-review 的含义 = 「评审中 / 已批准待合并」（没有单独的「验收」状态）
#
# 转换表（合法迁移的**唯一**定义；docs/WORKFLOW.md 里的表由 ci/test 断言与本表**逐字一致**）：
#   backlog     -> ready | in-progress | canceled
#   ready       -> in-progress | backlog | canceled
#   in-progress -> in-review | ready | backlog | canceled
#   in-review   -> rework | done | backlog | canceled
#   rework      -> in-review | ready | backlog | canceled
#   done        -> （终态；无出边）
#   canceled    -> （终态；无出边）
# 表外的 from -> to 一律**失败**（含 done/canceled 出边、跨级跳跃）。
# 唯一兜底：显式 `--force` 跳过表校验（日志打印 [WARN] 说明被绕过的边；互斥与迁移后校验仍执行）。
# 幂等：from == to 且载体齐备时不迁移（终态还要求无残留标签，否则继续清理）。
#
# 不变量：开放 Issue 至多一个 status/* 标签；迁移只允许走本脚本。
# done / canceled 有两个载体：Issue CLOSED **且**无任何 status/* 标签。幂等判断两者都核 ——
# 「已关闭但仍带残留标签」会继续清理，不短路返回。
# 退出码：0 成功；1 校验/迁移失败；2 参数错误

set -eu

die()  { printf '[FAIL] %s\n' "${1:-}" >&2; exit "${2:-1}"; }
ok()   { printf '[ OK ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
info() { printf '\n== %s ==\n' "$*"; }

STATUS_LABELS="status/ready status/in-progress status/in-review status/rework"
VALID_STATES="backlog ready in-progress in-review rework done canceled"
TRANSITIONS="backlog->ready backlog->in-progress backlog->canceled ready->in-progress ready->backlog ready->canceled in-progress->in-review in-progress->ready in-progress->backlog in-progress->canceled in-review->rework in-review->done in-review->backlog in-review->canceled rework->in-review rework->ready rework->backlog rework->canceled"

BASE_LABEL_OF_STATE() {
  case "$1" in
    ready)       printf 'status/ready' ;;
    in-progress) printf 'status/in-progress' ;;
    in-review)   printf 'status/in-review' ;;
    rework)      printf 'status/rework' ;;
    *)           printf '' ;;
  esac
}

# ── 转换表判定：合法 0 / 非法非 0 ────────────────────────────
# 用「空格 + 整边 + 空格」做整词匹配，避免 backlog->read 之类的子串误判。
# 为什么不用多行 case pattern：macOS 自带 bash 3.2 里「引号包裹的多行 case pattern」不可靠
# （实测 `case "$v" in *"\n$1->$2\n"*)` 恒不匹配），用 grep -F 更稳且可读。
# from == to 视为合法：幂等短路会先返回；只有「终态已 CLOSED 但仍有残留标签」会走到这里，
# 那时需要继续执行清理（done -> done 必须放行，否则 closeout 的自动清理永远失败）。
is_legal_transition() {
  [ "$1" = "$2" ] && return 0
  printf '%s' " ${TRANSITIONS} " | grep -qF " $1->$2 "
}

# 某个状态的合法出边（人类可读）；终态返回空
out_edges_of() {
  printf '%s' "$TRANSITIONS" | tr ' ' '\n' | grep -E "^$1->" | sed 's/->/ → /g' | tr '\n' ' ' | sed -E 's/[[:space:]]+$//'
}

# ── --check-transition <from> <to>：**只读**判定（零副作用）─────────────
# 为什么要有它：start.sh / deliver.sh 的副作用（建分支、推送、建 PR）**不可逆**；
# 若先动手再迁移状态，非法的迁移会把仓库留在半成品状态（见 Issue #90 的 F）。
# 本分支在任何文件、网络、标签操作**之前**返回 —— 只读本脚本内的 TRANSITIONS。
# 退出码：0 = 合法（含 from == to 的幂等）；1 = 非法（并打印该 from 的合法出边与对应命令）；2 = 用法/状态名错误
if [ "${1:-}" = "--check-transition" ]; then
  from="${2:-}"
  to="${3:-}"
  [ -n "$from" ] && [ -n "$to" ] \
    || die "用法：scripts/status.sh --check-transition <from> <to>（合法状态：${VALID_STATES}）" 2
  case " ${VALID_STATES} " in
    *" ${from} "*) : ;;
    *) die "未知状态 ${from}（合法值：${VALID_STATES}）" 2 ;;
  esac
  case " ${VALID_STATES} " in
    *" ${to} "*) : ;;
    *) die "未知状态 ${to}（合法值：${VALID_STATES}）" 2 ;;
  esac
  if [ "$from" = "$to" ]; then
    ok "转换表允许：${from} → ${to}（同状态，幂等）"
    exit 0
  fi
  if is_legal_transition "$from" "$to"; then
    ok "转换表允许：${from} → ${to}"
    exit 0
  fi
  printf '[FAIL] 非法迁移：%s → %s\n' "$from" "$to" >&2
  targets="$(printf '%s' "$TRANSITIONS" | tr ' ' '\n' | grep -E "^${from}->" | sed 's/^.*->//')"
  if [ -n "$targets" ]; then
    printf '       %s 的合法出边与正确命令：\n' "$from" >&2
    for t in $targets; do
      printf '         scripts/status.sh <issue#> %s\n' "$t" >&2
    done
  else
    printf '       %s 是终态，无出边；确需复活：gh issue reopen <issue#> 再迁移\n' "$from" >&2
  fi
  printf '       转换表见脚本头部 / docs/WORKFLOW.md §1；本命令只读，未改动任何东西\n' >&2
  exit 1
fi

# ── 以下才需要仓库 / 凭据（--check-transition 已在上方返回，不读网络）──────
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

platform_state() { gh issue view "$1" -R "$REPO" --json state --jq .state 2>/dev/null || true; }
status_labels() {
  gh issue view "$1" -R "$REPO" --json labels \
    --jq '[.labels[].name | select(startswith("status/"))] | join(" ")' 2>/dev/null || true
}

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

# ── --check-cross：**只读**交叉状态检查（Issue ↔ PR）────────────────────
# 为什么要有它：--check / ci/test / policy/* **都只读 Issue**，因此
# 「Issue in-review 而关联 PR 已 CLOSED」「Issue done 而 PR 未合并」这类不一致
# 没有任何门禁能看到（#60 的孤儿分支正是这条盲区的后果）。
# 规则（只读：只发 GET，不写任何东西）：
#   R1 Issue 为 in-review，但关联 PR 已 CLOSED（未合并）
#   R2 Issue 为 done，但关联 PR 未合并（仍开放 / 已关闭未合并）
#   R3 Issue 为 in-review，但没有任何开放 PR
#   R4 有开放 PR，但 Issue 无任何 status/*（Backlog）
# 关联判据（**只检查能确定关联的 PR**）：PR 的 closingIssuesReferences（GitHub 解析出的
# 关闭关系）或分支名 <type>/<issue#>-<slug>。两者都没有 → 如实标注「无法判定」，**不猜测**。
# 退出码：0 = 四条规则全未命中；1 = 存在冲突；2 = 查询失败/用法错
if [ "${1:-}" = "--check-cross" ]; then
  [ "$#" -eq 1 ] || die "用法：scripts/status.sh --check-cross（不接受额外参数）" 2
  CROSS_TMP="$(mktemp -d "${TMPDIR:-/tmp}/pm4gh-cross.XXXXXX")" || die "无法创建临时目录"
  cleanup_cross() { rm -rf "$CROSS_TMP"; }
  trap cleanup_cross EXIT INT TERM

  info "交叉状态只读检查（仓库 ${REPO}，身份 ${ACTOR}）"
  issues_file="${CROSS_TMP}/issues.tsv"
  if ! gh issue list -R "$REPO" --state open --limit 300 --json number,state,stateReason,labels \
    --jq '.[] | "\(.number)|\(.state)|\(.stateReason // "")|\([.labels[].name | select(startswith("status/"))] | join(","))"' \
    > "$issues_file" 2>/dev/null; then
    die "读取开放 Issue 失败（权限/网络）—— 交叉检查未完成" 2
  fi
  prs_open="${CROSS_TMP}/prs-open.tsv"
  if ! gh pr list -R "$REPO" --state open --limit 300 --json number,headRefName,closingIssuesReferences \
    --jq '.[] | "\(.number)|\(.headRefName)|OPEN|\([.closingIssuesReferences[].number] | join(","))"' \
    > "$prs_open" 2>/dev/null; then
    die "读取开放 PR 失败（权限/网络）—— 交叉检查未完成" 2
  fi
  prs_closed="${CROSS_TMP}/prs-closed.tsv"
  if ! gh pr list -R "$REPO" --state closed --limit 300 --json number,headRefName,mergedAt,closingIssuesReferences \
    --jq '.[] | "\(.number)|\(.headRefName)|\(if .mergedAt then "MERGED" else "CLOSED_UNMERGED" end)|\([.closingIssuesReferences[].number] | join(","))"' \
    > "$prs_closed" 2>/dev/null; then
    die "读取已关闭 PR 失败（权限/网络）—— 交叉检查未完成" 2
  fi

  # PR → Issue 关联（每行：issue | pr | pr_kind | link_kind；用 | 分隔，tab 是 IFS 空白会吞掉空字段）
  assoc="${CROSS_TMP}/assoc.tsv"; : > "$assoc"
  undet="${CROSS_TMP}/undetermined.tsv"; : > "$undet"
  add_assoc() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >> "$assoc"; }
  branch_issue_of() {
    printf '%s' "${1:-}" | sed -nE 's#^(slice|fix|hotfix|spike|chore)/([0-9]+)-[a-z0-9-]+$#\2#p'
  }
  scan_prs() {
    while IFS='|' read -r pr head kind refs; do
      [ -n "$pr" ] || continue
      seen=""
      if [ -n "$refs" ]; then
        for n in $(printf '%s' "$refs" | tr ',' ' '); do
          add_assoc "$n" "$pr" "$kind" "closingIssuesReferences"
          seen="${seen} ${n}"
        done
      fi
      bnum="$(branch_issue_of "$head")"
      if [ -n "$bnum" ]; then
        case " ${seen} " in
          *" ${bnum} "*) : ;;
          *) add_assoc "$bnum" "$pr" "$kind" "branch-name" ;;
        esac
      fi
      if [ -z "$refs" ] && [ -z "$bnum" ]; then
        printf '%s|%s\n' "$pr" "$head" >> "$undet"
      fi
    done < "$1"
  }
  scan_prs "$prs_open"
  scan_prs "$prs_closed"

  n_open_issues="$(grep -c . "$issues_file" 2>/dev/null || true)"
  n_open_prs="$(grep -c . "$prs_open" 2>/dev/null || true)"
  n_closed_prs="$(grep -c . "$prs_closed" 2>/dev/null || true)"
  n_by_body="$(grep -c 'closingIssuesReferences' "$assoc" 2>/dev/null || true)"
  n_by_branch="$(grep -c 'branch-name' "$assoc" 2>/dev/null || true)"
  n_undet="$(grep -c . "$undet" 2>/dev/null || true)"

  # 关联到的已关闭 Issue：补读状态（仍然只读）
  unknown_issue=0
  for n in $(cut -d'|' -f1 "$assoc" 2>/dev/null | sort -u); do
    [ -n "$n" ] || continue
    case "$n" in *[!0-9]*) continue ;; esac
    if grep -q "^${n}|" "$issues_file" 2>/dev/null; then
      continue
    fi
    meta="$(gh issue view "$n" -R "$REPO" --json state,stateReason,labels \
      --jq '"\(.state)|\(.stateReason // "")|\([.labels[].name | select(startswith("status/"))] | join(","))"' 2>/dev/null || true)"
    if [ -n "$meta" ]; then
      printf '%s|%s\n' "$n" "$meta" >> "$issues_file"
    else
      unknown_issue=$((unknown_issue + 1))
      warn "PR 关联到不存在的 Issue #${n} —— 无法判定，不计入规则"
    fi
  done

  class_of() {
    if [ "$1" = "OPEN" ]; then
      case "$3" in
        "")               printf 'backlog' ;;
        status/in-review) printf 'in-review' ;;
        *)                printf 'open-other' ;;
      esac
    else
      case "$2" in
        NOT_PLANNED|not_planned) printf 'canceled' ;;
        *) if [ -z "$3" ]; then printf 'done'; else printf 'closed-other'; fi ;;
      esac
    fi
  }
  row_of() { grep -m1 "^${1}|" "$issues_file" 2>/dev/null || true; }

  printf '  数据源：开放 Issue %s 条；开放 PR %s 条；已关闭 PR %s 条（各取最近 300 条）\n' \
    "$n_open_issues" "$n_open_prs" "$n_closed_prs"
  printf '  关联方式：closingIssuesReferences %s 条；分支名解析 %s 条；无法判定 PR %s 个\n' \
    "$n_by_body" "$n_by_branch" "$n_undet"

  r1=0
  r2=0
  r3=0
  r4=0

  info "R1：Issue 为 in-review，但关联 PR 已 CLOSED（未合并）"
  while IFS='|' read -r n pr kind link; do
    [ -n "$n" ] || continue
    [ "$kind" = "CLOSED_UNMERGED" ] || continue
    row="$(row_of "$n")"
    [ -n "$row" ] || continue
    if [ "$(class_of "$(printf '%s' "$row" | cut -d'|' -f2)" "$(printf '%s' "$row" | cut -d'|' -f3)" "$(printf '%s' "$row" | cut -d'|' -f4)")" = "in-review" ]; then
      printf '[FAIL] R1：Issue #%s 为 in-review，但关联 PR #%s 已 CLOSED（未合并；关联方式：%s）\n' "$n" "$pr" "$link"
      r1=$((r1 + 1))
    fi
  done < "$assoc"
  if [ "$r1" -eq 0 ]; then ok "R1 未命中"; fi

  info "R2：Issue 为 done，但关联 PR 未合并"
  while IFS='|' read -r n pr kind link; do
    [ -n "$n" ] || continue
    case "$kind" in OPEN|CLOSED_UNMERGED) : ;; *) continue ;; esac
    row="$(row_of "$n")"
    [ -n "$row" ] || continue
    if [ "$(class_of "$(printf '%s' "$row" | cut -d'|' -f2)" "$(printf '%s' "$row" | cut -d'|' -f3)" "$(printf '%s' "$row" | cut -d'|' -f4)")" = "done" ]; then
      if [ "$kind" = "OPEN" ]; then pstate_txt="仍开放（未合并）"; else pstate_txt="已关闭且未合并"; fi
      printf '[FAIL] R2：Issue #%s 已 done（CLOSED+无 status/*），但关联 PR #%s %s（关联方式：%s）\n' "$n" "$pr" "$pstate_txt" "$link"
      r2=$((r2 + 1))
    fi
  done < "$assoc"
  if [ "$r2" -eq 0 ]; then ok "R2 未命中"; fi

  info "R3：Issue 为 in-review，但没有任何开放 PR"
  while IFS='|' read -r n st rs lb; do
    [ -n "$n" ] || continue
    [ "$st" = "OPEN" ] || continue
    [ "$lb" = "status/in-review" ] || continue
    open_prs="$(awk -F'|' -v num="$n" '$1 == num && $3 == "OPEN" { print "#" $2 }' "$assoc" | tr '\n' ' ' | sed -E 's/[[:space:]]+$//')"
    if [ -n "$open_prs" ]; then continue; fi
    other_prs="$(awk -F'|' -v num="$n" '$1 == num && $3 != "OPEN" { print "#" $2 "(" $3 ")" }' "$assoc" | tr '\n' ' ' | sed -E 's/[[:space:]]+$//')"
    if [ -n "$other_prs" ]; then detail="关联 PR 均非开放：${other_prs}"; else detail="无任何关联 PR"; fi
    printf '[FAIL] R3：Issue #%s 为 in-review，但无开放 PR（%s）\n' "$n" "$detail"
    r3=$((r3 + 1))
  done < "$issues_file"
  if [ "$r3" -eq 0 ]; then ok "R3 未命中"; fi

  info "R4：有开放 PR，但 Issue 无任何 status/*（Backlog）"
  while IFS='|' read -r n pr kind link; do
    [ -n "$n" ] || continue
    [ "$kind" = "OPEN" ] || continue
    row="$(row_of "$n")"
    [ -n "$row" ] || continue
    if [ "$(class_of "$(printf '%s' "$row" | cut -d'|' -f2)" "$(printf '%s' "$row" | cut -d'|' -f3)" "$(printf '%s' "$row" | cut -d'|' -f4)")" = "backlog" ]; then
      printf '[FAIL] R4：Issue #%s 无任何 status/*（Backlog），但有开放 PR #%s（关联方式：%s）\n' "$n" "$pr" "$link"
      r4=$((r4 + 1))
    fi
  done < "$assoc"
  if [ "$r4" -eq 0 ]; then ok "R4 未命中"; fi

  info "无法判定关联的 PR（只标注，不猜测）"
  if [ -s "$undet" ]; then
    while IFS='|' read -r pr head; do
      [ -n "$pr" ] || continue
      printf '  [N/A ] PR #%s（head=%s）：正文无 closingIssuesReferences，分支名也不符合 <type>/<issue#>-<slug>\n' "$pr" "$head"
    done < "$undet"
  else
    ok "所有 PR 都能确定关联"
  fi
  if [ "$unknown_issue" -gt 0 ]; then
    warn "另有 ${unknown_issue} 个关联指向不存在的 Issue（无法判定）"
  fi

  hits=$((r1 + r2 + r3 + r4))
  printf '\n'
  if [ "$hits" -eq 0 ]; then
    ok "交叉状态无冲突：R1/R2/R3/R4 全未命中（只读，零副作用）"
    exit 0
  fi
  warn "交叉状态发现 ${hits} 处冲突：R1=${r1} R2=${r2} R3=${r3} R4=${r4}"
  warn "修法：Issue 侧走 scripts/status.sh <issue#> <state>；异常路径（PR 关闭不合并 / 作者放弃 / Issue 已取消）走 scripts/abort.sh <issue#>"
  exit 1
fi

ISSUE="${1:-}"
[ -n "$ISSUE" ] || die "用法：scripts/status.sh <issue#> <state> [--force] | <issue#> --show | --check | --check-cross | --check-transition <from> <to>" 2
case "$ISSUE" in *[!0-9]*) die "Issue 编号必须是数字：${ISSUE}" 2 ;; esac

state_of() {
  st="$(platform_state "$1")"
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
    status/rework)         printf 'rework' ;;
    *)                     printf 'unknown(%s)' "$label" ;;
  esac
}

if [ "${2:-}" = "--show" ]; then
  info "Issue #${ISSUE} 当前状态：$(state_of "$ISSUE")"
  exit 0
fi

STATE="${2:-}"
[ -n "$STATE" ] || die "用法：scripts/status.sh <issue#> <state> [--force] | <issue#> --show | --check | --check-cross | --check-transition <from> <to>" 2
FORCE=0
case "${3:-}" in
  "") : ;;
  --force) FORCE=1 ;;
  *) die "未知参数 ${3}（只支持 --force）" 2 ;;
esac
case " ${VALID_STATES} " in
  *" ${STATE} "*) : ;;
  *) die "未知状态 ${STATE}（合法值：${VALID_STATES}）" 2 ;;
esac

terminal=0
case "$STATE" in done|canceled) terminal=1 ;; esac

cur="$(state_of "$ISSUE")"
raw_state="$(platform_state "$ISSUE")"
leftover="$(status_labels "$ISSUE")"
info "Issue #${ISSUE}：${cur} → ${STATE}"

# 幂等短路只在目标状态的**全部载体**都已满足时成立：
#   - 非终态：状态标签已是目标值
#   - done/canceled：Issue CLOSED 且无任何 status/* 标签 —— 有残留标签就必须继续清理
short_circuit=0
if [ "$cur" = "$STATE" ]; then
  short_circuit=1
  if [ "$terminal" -eq 1 ] && [ -n "$leftover" ]; then
    short_circuit=0
    warn "Issue #${ISSUE} 已关闭为 ${STATE}，但仍有残留状态标签：${leftover} —— 继续清理（不短路）"
  fi
fi
if [ "$short_circuit" -eq 1 ]; then
  ok "已是 ${STATE}（幂等，无需改动）"
  exit 0
fi

# ── 终态出边保护：CLOSED 的 done/canceled 不能迁到非终态 ────────
# 为什么要有这一步：终态的载体是「Issue CLOSED + 无标签」，而本脚本不重开 Issue。
# 若放行，--force 会先删掉残留标签、再在迁移后校验失败 —— 把 Issue 留在「已关闭且无标签」
# 这种「看着是 done/canceled 但目标是 backlog」的分裂状态。宁可在动手前就拒绝。
if [ "$cur" != "$STATE" ] && [ "$terminal" -eq 0 ] && [ "$raw_state" = "CLOSED" ]; then
  die "终态 ${cur} 不能迁出到 ${STATE}：终态的载体是 Issue CLOSED，而本脚本**不重开** Issue。先 gh issue reopen ${ISSUE} 再迁移（--force 也不绕过这一步）"
fi

# ── 转换表强校验（迁移前；--force 显式兜底）──────────────────
if is_legal_transition "$cur" "$STATE"; then
  ok "转换表允许：${cur} → ${STATE}"
else
  edges="$(out_edges_of "$cur")"
  if [ -n "$edges" ]; then
    edges_hint="出边参考：${edges}"
  else
    edges_hint="出边参考：（${cur} 是终态，无出边；确需复活请 gh issue reopen ${ISSUE} 后用 --force）"
  fi
  if [ "$FORCE" -eq 1 ]; then
    warn "转换表外的迁移 ${cur} → ${STATE} —— 因显式 --force 而继续"
    warn "  ${edges_hint}"
  else
    printf '[FAIL] 非法迁移：%s → %s\n' "$cur" "$STATE" >&2
    printf '       %s\n' "$edges_hint" >&2
    printf '       转换表见 scripts/status.sh 头部 / docs/WORKFLOW.md §1；确有例外才用 --force（会留 [WARN] 记录）\n' >&2
    exit 1
  fi
fi

# 先移除已有的全部 status/* 标签，保证互斥（含 done/canceled 的残留标签）
for l in $leftover; do
  gh issue edit "$ISSUE" -R "$REPO" --remove-label "$l" >/dev/null
done

case "$STATE" in
  backlog)
    ok "已置为 backlog（无状态标签）" ;;
  done|canceled)
    if [ "$raw_state" = "CLOSED" ]; then
      ok "Issue 已由平台关闭（保留平台置位的开关状态，只清理残留标签）"
    elif [ "$STATE" = "done" ]; then
      gh issue close "$ISSUE" -R "$REPO" --reason completed >/dev/null
      ok "已关闭（state_reason=completed）→ done"
    else
      gh issue close "$ISSUE" -R "$REPO" --reason "not planned" >/dev/null
      ok "已关闭（state_reason=not_planned）→ canceled"
    fi
    ;;
  *)
    target="$(BASE_LABEL_OF_STATE "$STATE")"
    [ -n "$target" ] || die "内部错误：${STATE} 没有对应标签"
    gh issue edit "$ISSUE" -R "$REPO" --add-label "$target" >/dev/null
    ok "已置为 ${STATE}（标签 ${target}）"
    ;;
esac

# 迁移后校验：done/canceled 核两个载体（CLOSED + 无标签），其余核标签唯一
if [ "$terminal" -eq 1 ]; then
  now_state="$(platform_state "$ISSUE")"
  now_labels="$(status_labels "$ISSUE")"
  [ "$now_state" = "CLOSED" ] || die "迁移后校验失败：${STATE} 要求 Issue CLOSED，实际 ${now_state:-未知}"
  [ -z "$now_labels" ] || die "迁移后 Issue #${ISSUE} 仍有状态标签：${now_labels} —— ${STATE} 要求清空"
  now_derived="$(state_of "$ISSUE")"
  [ "$now_derived" = "$STATE" ] \
    || warn "平台 state_reason 解析为 ${now_derived}（与 ${STATE} 不同）—— 本脚本保证的是 CLOSED + 无标签"
  ok "迁移校验通过：${cur} → ${STATE}（Issue CLOSED + 无状态标签）"
  exit 0
fi

now="$(state_of "$ISSUE")"
[ "$now" = "$STATE" ] || die "迁移后校验失败：期望 ${STATE}，实际 ${now}"
cnt="$(gh issue view "$ISSUE" -R "$REPO" --json labels \
  --jq '[.labels[].name | select(startswith("status/"))] | length' 2>/dev/null || echo 0)"
[ "$cnt" -le 1 ] || die "迁移后 Issue #${ISSUE} 有 ${cnt} 个状态标签 —— 状态必须唯一"
ok "迁移校验通过：${cur} → ${now}"
