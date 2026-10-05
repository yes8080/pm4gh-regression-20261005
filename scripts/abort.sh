#!/usr/bin/env bash
# scripts/abort.sh <issue#> [--branch NAME] [--reason TEXT] [--evidence TEXT] [--as author] [--dry-run]
#
# W0..W7 只覆盖「一路顺风」；本脚本是三条**异常路径**的唯一出口（没有它就会留下
# Issue 已 canceled、远端分支却留着，无 PR、无任何门禁能看到的孤儿分支）：
#   ① PR 被**关闭但不合并**
#   ② 作者**中途放弃**（有分支，可能从未有 PR）
#   ③ **Issue 已被取消**（不做）但分支已建
#
# 一条命令做完三件事（**幂等**）：
#   a) 清理**本地 + 远端**分支 —— 但**先证明「内容不会丢」**，证明不了就**拒绝删除**（fail-closed）
#      可见性（#141 D8）：**凡 ref 名可归属到 #<issue#> 的分支都要被考虑**（含不合规形态 `<n>-<slug>`、
#      `<any>/<n>-<slug>`）；`--branch` 是显式指定，**允许任意 ref 名**。放宽的只有可见性，安全判据不动。
#      触发路径文案（#141 D7）：「③ Issue 已取消但分支已建」**只在分支确实存在时**打印。
#   b) 状态迁移 → canceled —— **只走 scripts/status.sh**（绝不直接改标签）
#   c) 在 Issue 留**可恢复锚点**（分支 tip SHA / 原因 / 时间 / 判据 / 关联 PR）—— 锚点写不进去就不删
#
# 「内容不会丢」的判据（任一成立才允许删除）：
#   1. 分支 tip（本地与远端都算）是 origin/main 的**祖先** → 内容已在 main 里
#   2. 该分支有**已合并**的 PR（squash 合并后 tip 不在 main 上，但内容已被合入）
#   3. 显式 `--evidence <说明>`：人工声明内容已另有归宿；脚本把该声明**原文**写进锚点。
#      **不提供**「无记录强删」的开关。
# 三条都不成立（存在独有未合并提交）→ **一个分支都不删、状态也不迁移**，打印处置选项后退出 1。
#
# 用法：
#   scripts/abort.sh 60                                       # 判据不成立则拒绝，不写任何东西
#   scripts/abort.sh 60 --evidence "内容已由 af2e9f4 并入 main"
#   scripts/abort.sh 60 --reason "需求取消" --dry-run
# 退出码：0 已清理 / 幂等无操作；1 拒绝删除或迁移失败；2 用法错

set -eu

# 作者凭据默认在**工作区之外**；**禁止**指回工作区内路径。写法与 review.sh 一致。
DEVELOPER_PAT_FILE="${DEVELOPER_PAT_FILE:-${HOME}/.config/pm4gh/developer.pat}"
BASE_BRANCH="${BASE_BRANCH:-main}"

die()  { printf '[FAIL] %s\n' "${1:-}" >&2; exit "${2:-1}"; }
ok()   { printf '[ OK ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
info() { printf '\n== %s ==\n' "$*"; }

# ── R4 释放本 clone 的单写者锁（#159；创建规则见 scripts/preflight.sh 的 WRITER_LOCK_ASSERT 标记区）──
# 锁在**工作区之外**（`$PM4GH_LOCK_DIR`、默认 `$HOME/.config/pm4gh/locks`；preflight 在默认目录不可写
#   时会回退到 `/tmp/pm4gh-locks-<uid>`，两个候选都查）。键 = clone 的物理根路径。
# 只释放**本 clone**的锁；pid 仍存活 = 可能另有写者 → **只提示、不删**（不代他人释放）。
# WRITER_LOCK_RELEASE:BEGIN
release_writer_lock() {
  rw_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$rw_root" ] || return 0
  rw_root="$(cd "$rw_root" && pwd -P)"
  rw_id="$(printf '%s' "$rw_root" | sed -E 's#^/##; s#[^A-Za-z0-9]+#-#g')"
  rw_found=0
  for rw_dir in "${PM4GH_LOCK_DIR:-${HOME}/.config/pm4gh/locks}" "/tmp/pm4gh-locks-$(id -u)"; do
    rw_file="${rw_dir}/${rw_id}.lock"
    [ -e "$rw_file" ] || continue
    rw_found=1
    rw_owner="$(grep -m1 '^clone=' "$rw_file" 2>/dev/null | sed -E 's/^clone=//' || true)"
    if [ -n "$rw_owner" ] && [ "$rw_owner" != "$rw_root" ]; then
      printf '  [WARN] 锁 %s 属于另一个 clone（clone=%s）—— 不释放\n' "$rw_file" "$rw_owner"
      continue
    fi
    rw_pid="$(grep -m1 '^pid=' "$rw_file" 2>/dev/null | sed -E 's/^pid=//' || true)"
    case "$rw_pid" in
      ''|*[!0-9]*) : ;;
      *) if kill -0 "$rw_pid" 2>/dev/null; then
           printf '  [WARN] 锁 %s 的 pid=%s **仍存活** —— 不代他人释放（确认该写者已退出后手工 rm）\n' "$rw_file" "$rw_pid"
           continue
         fi ;;
    esac
    if rm -f "$rw_file"; then
      printf '[ OK ] 已释放本 clone 的单写者锁：%s\n' "$rw_file"
    else
      printf '  [WARN] 锁 %s 释放失败（权限？）—— 下次 preflight 会按陈旧锁自动接管\n' "$rw_file"
    fi
  done
  [ "$rw_found" = "1" ] || printf '  本 clone 无单写者锁可释放（%s/%s.lock 不存在）\n' "${PM4GH_LOCK_DIR:-${HOME}/.config/pm4gh/locks}" "$rw_id"
}
# WRITER_LOCK_RELEASE:END

ACTOR=""
# --as 的取值域（**参数级**校验：不读凭据 / 不读网络）。判据只有这一处定义 ——
# 「参数级校验段（--parse-only 走它）」与 `use_identity` 都调用它。
assert_author_as() {
  case "${1:-}" in
    author) : ;;
    main) die "--as 只接受 author：本脚本**没有** dispatcher 身份开关（分支清理按 W8 由作者身份执行）。当前：${1:-}" 2 ;;
    *)    die "--as 只接受 author（当前：${1:-}）" 2 ;;
  esac
}

use_identity() {
  assert_author_as "${1:-}"
  [ -s "$DEVELOPER_PAT_FILE" ] || die "缺少作者凭据 ${DEVELOPER_PAT_FILE}（见 references/identity.md）"
  GH_TOKEN="$(cat "$DEVELOPER_PAT_FILE")"
  export GH_TOKEN
  unset GITHUB_TOKEN || true
  ACTOR="$(gh api user --jq .login 2>/dev/null || true)"
  [ -n "$ACTOR" ] || die "作者凭据无效（无法认证）"
  main="$(env -u GH_TOKEN -u GITHUB_TOKEN gh api user --jq .login 2>/dev/null || true)"
  [ -z "$main" ] || [ "$main" != "$ACTOR" ] || die "身份分离失败：作者身份 = gh 登录身份（${ACTOR}）"
  # 评审凭据**不在这里读**（SKILL.md §5：作者不得读取其他身份的凭据）。
  # 「评审 ≠ 作者」由 W6 `scripts/review.sh` 用**评审凭据自身**判定（平台另禁止自我批准）。
  ok "本次执行身份（作者）：${ACTOR}"
}

ISSUE=""
BRANCH_ARG=""
REASON="异常路径终止（abort.sh）"
EVIDENCE=""
AS="author"
PARSE_ONLY=""
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --branch)   BRANCH_ARG="${2:?--branch 需要取值}"; shift 2 ;;
    --reason)   REASON="${2:?--reason 需要取值}"; shift 2 ;;
    --evidence) EVIDENCE="${2:?--evidence 需要取值}"; shift 2 ;;
    --as)       AS="${2:?--as 需要取值}"; shift 2 ;;
    --parse-only) PARSE_ONLY=1; shift ;;
    --dry-run)  DRY=1; shift ;;
    -h|--help)  sed -n '2,29p' "$0"; exit 0 ;;
    -*)         die "未知参数 ${1:-}（本脚本不提供该开关；用法见 scripts/abort.sh -h）" 2 ;;
    *) ISSUE="$1"; shift ;;
  esac
done

# ── 参数级校验（取值域；**不依赖**仓库 / 凭据 / 网络）────────────────────
# 全部判据都属于「参数」，必须在读到仓库/凭据之前完成 —— 否则 ci/test 的
# 「文档命令可执行性」判据（--parse-only）会漏掉它们（#147 C3②）。
[ -n "$ISSUE" ] || die "用法：scripts/abort.sh <issue#> [--branch NAME] [--reason TEXT] [--evidence TEXT] [--as author] [--dry-run]" 2
case "$ISSUE" in *[!0-9]*) die "Issue 编号必须是数字：${ISSUE}" 2 ;; esac
assert_author_as "$AS"
if [ -n "$PARSE_ONLY" ]; then
  printf '[ OK ] 参数解析通过（--parse-only；未读网络、未写任何文件）：%s\n' "$0"
  exit 0
fi

[ -f .github/rulesets/main-protection.json ] || die "请在仓库根目录运行"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
[ -n "$REPO" ] || die "无法确定仓库 slug（gh repo view 失败）"
# 锚点里的自由文本：禁止 tab/换行，避免破坏 TSV 与注释结构
REASON="$(printf '%s' "$REASON" | tr '\t\n|' '   ')"
EVIDENCE="$(printf '%s' "$EVIDENCE" | tr '\t\n|' '   ')"

use_identity "$AS"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pm4gh-abort.XXXXXX")" || die "无法创建临时目录"
cleanup_tmp() { rm -rf "$TMP"; }
trap cleanup_tmp EXIT INT TERM

# ── 0. 读当前状态（只读）+ 迁移合法性预检（任何副作用之前）──────────────
info "读取 Issue #${ISSUE} 当前状态（只读预检，早于任何副作用）"
pstate="$(gh issue view "$ISSUE" -R "$REPO" --json state --jq .state 2>/dev/null || true)"
[ -n "$pstate" ] || die "Issue #${ISSUE} 不存在或无法访问"
if [ "$pstate" = "CLOSED" ]; then
  preason="$(gh issue view "$ISSUE" -R "$REPO" --json stateReason --jq '.stateReason // "COMPLETED"' 2>/dev/null || echo COMPLETED)"
  case "$preason" in
    NOT_PLANNED|not_planned) cur_state="canceled" ;;
    *) cur_state="done" ;;
  esac
else
  status_labels="$(gh issue view "$ISSUE" -R "$REPO" --json labels \
    --jq '[.labels[].name | select(startswith("status/"))] | join(" ")' 2>/dev/null || true)"
  case "$status_labels" in
    "")                   cur_state="backlog" ;;
    "status/ready")       cur_state="ready" ;;
    "status/in-progress") cur_state="in-progress" ;;
    "status/in-review")   cur_state="in-review" ;;
    *" "*) die "Issue #${ISSUE} 有多个状态标签：${status_labels} —— 状态必须唯一，先 scripts/status.sh ${ISSUE} <state> --as author 修正" ;;
    *)     die "Issue #${ISSUE} 使用了未定义的状态标签：${status_labels} —— 用 scripts/status.sh <n> <state> --as author 修正" ;;
  esac
fi
ok "当前状态：${cur_state}（读自平台）"

if [ "$cur_state" = "done" ]; then
  die "Issue #${ISSUE} 已是 done（终态）：残留分支属于**合并收尾**，请用 scripts/closeout.sh <pr#>；确需取消请先 gh issue reopen ${ISSUE} 再重跑本脚本"
fi
if [ "$cur_state" != "canceled" ]; then
  if ! "$(dirname "$0")/status.sh" --check-transition "$cur_state" canceled; then
    die "Issue #${ISSUE} 当前 ${cur_state}，不能迁移到 canceled（见上方合法出边）；本次**未删除任何分支、未留锚点**"
  fi
  ok "迁移合法：${cur_state} → canceled"
else
  ok "Issue 已是 canceled（终态）—— 本次只做分支清理与留锚点"
fi

# ── 1. 发现该 Issue 的分支（显式 / develop 绑定 / 本地 ref / 远端 ref）────
# 可见性（#141 D8）：发现范围 = **凡 ref 名可归属到 #<issue#> 的分支**（末段形如 `<n>-<slug>`）——
#   合规形态 `<type>/<n>-<slug>` 与**不合规但可归属**的形态（`<n>-<slug>`、`<any>/<n>-<slug>`）一视同仁。
#   旧的「只认合规正则」会让不合规分支对 abort **完全不可见**（却打印「未发现分支」+「已闭环」）。
#   放宽的**只是可见性**：第 2 节的内容不丢判据与 fail-closed 语义一字不动。
info "发现分支（显式 → gh issue develop 绑定 → 本地 ref → 远端 ref）"
BRANCHES=""
# ref 名 → 可归属的 Issue 号（取**最后一段**的 `<n>-` 前缀，不要求 type/ 前缀）；不可归属 → 空串
branch_issue_of() {
  seg="${1##*/}"
  case "$seg" in
    *-*) num="${seg%%-*}" ;;
    *)   printf ''; return 0 ;;
  esac
  case "$num" in ''|*[!0-9]*) printf ''; return 0 ;; esac
  printf '%s' "$num"
}
add_branch_raw() {
  b="${1:-}"
  [ -n "$b" ] || return 0
  case "$b" in main|master) return 0 ;; esac
  case " ${BRANCHES} " in *" ${b} "*) return 0 ;; esac
  BRANCHES="${BRANCHES} ${b}"
}
add_branch() {                     # 发现路径：只纳入**可归属到本 Issue**的 ref
  b="${1:-}"
  [ "$(branch_issue_of "$b")" = "$ISSUE" ] || return 0
  add_branch_raw "$b"
}

if [ -n "$BRANCH_ARG" ]; then
  # --branch 是**显式指定**：允许任意 ref 名（旧的合规正则拦截已删）——安全门禁照旧（第 2 节），不放宽。
  # 名字里若带可归属的编号，仍校验它与传入的 #ISSUE 一致（防指错 Issue）。
  bnum="$(branch_issue_of "$BRANCH_ARG")"
  if [ -n "$bnum" ] && [ "$bnum" != "$ISSUE" ]; then
    die "--branch ${BRANCH_ARG} 指向 Issue #${bnum}，与传入的 #${ISSUE} 不一致" 2
  fi
  [ -n "$bnum" ] || warn "--branch ${BRANCH_ARG} 的名字里没有可归属到 #${ISSUE} 的编号 —— 按**显式指定**纳入（内容不丢判据照旧，不放宽）"
  add_branch_raw "$BRANCH_ARG"
else
  while IFS= read -r b; do add_branch "$b"; done <<EOF
$(gh issue develop --list "$ISSUE" -R "$REPO" 2>/dev/null | awk 'NF { print $1 }' || true)
EOF
  while IFS= read -r b; do add_branch "$b"; done <<EOF
$(git for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null || true)
EOF
  while IFS= read -r b; do add_branch "$b"; done <<EOF
$(git ls-remote --heads origin 2>/dev/null | awk '{ print $2 }' | sed 's#^refs/heads/##' || true)
EOF
fi
if [ -z "$BRANCHES" ]; then
  ok "未发现 #${ISSUE} 的本地/远端分支"
else
  ok "发现分支：${BRANCHES}"
fi

# ── 2. 「内容不会丢」判据（任一成立才允许删除）──────────────────────────
info "安全判据（祖先 / 已合并 PR / --evidence）"
git fetch -q origin "$BASE_BRANCH" >/dev/null 2>&1 || warn "无法 fetch origin ${BASE_BRANCH} —— 祖先判据可能不准（会按不安全处理）"
origin_main="$(git rev-parse --verify --quiet "refs/remotes/origin/${BASE_BRANCH}" || true)"

rows="$TMP/branches.tsv"
: > "$rows"
unsafe_count=0
for b in $BRANCHES; do
  ltip="$(git rev-parse --verify --quiet "refs/heads/${b}" 2>/dev/null || true)"
  rtip="$(git ls-remote --heads origin "$b" 2>/dev/null | awk 'NR == 1 { print $1 }' || true)"
  if [ -z "$ltip" ] && [ -z "$rtip" ]; then
    continue
  fi
  # 把远端 tip 取到本地，祖先判据才算得出来（不改变工作区内容）
  if [ -n "$rtip" ]; then
    git fetch -q origin "$b" >/dev/null 2>&1 || true
  fi
  prs="$(gh pr list -R "$REPO" --head "$b" --state all --limit 10 --json number,state,mergedAt \
    --jq '[.[] | "#\(.number):\(.state)\(if .mergedAt then "(merged)" else "" end)"] | join(" ")' 2>/dev/null || true)"
  merged_pr="$(gh pr list -R "$REPO" --head "$b" --state merged --limit 1 --json number \
    --jq '.[0].number // ""' 2>/dev/null || true)"

  ancestor=1
  tip_list=""
  for tip in $ltip $rtip; do
    [ -n "$tip" ] || continue
    case " ${tip_list} " in *" ${tip} "*) continue ;; esac
    tip_list="${tip_list} ${tip}"
    if [ -z "$origin_main" ] || ! git merge-base --is-ancestor "$tip" "$origin_main" 2>/dev/null; then
      ancestor=0
    fi
  done
  unique=""
  for tip in $tip_list; do
    c="$(git rev-list --count "${tip}" ^"${origin_main}" 2>/dev/null || true)"
    unique="${unique} ${tip}~${c:-?}"
  done

  if [ "$ancestor" = "1" ]; then
    verdict="safe"
    proof="tip 是 origin/${BASE_BRANCH} 的祖先（内容已在 ${BASE_BRANCH} 内；独有提交 0）"
  elif [ -n "$merged_pr" ]; then
    verdict="safe"
    proof="PR #${merged_pr} 已合并（squash 后 tip 不在 ${BASE_BRANCH} 上，但内容已被合入）"
  elif [ -n "$EVIDENCE" ]; then
    verdict="safe"
    proof="人工证据（已原文写入锚点）：${EVIDENCE}"
  else
    verdict="unsafe"
    proof="不是 origin/${BASE_BRANCH} 的祖先，且无已合并 PR、无 --evidence"
  fi
  if [ "$verdict" = "unsafe" ]; then
    unsafe_count=$((unsafe_count + 1))
  fi
  printf '%s|%s|%s|%s|%s|%s|%s\n' "$b" "${ltip:--}" "${rtip:--}" "$verdict" "$proof" "${unique:-无}" "${prs:-无}" >> "$rows"
done

if [ "$unsafe_count" -gt 0 ]; then
  printf '\n' >&2
  while IFS='|' read -r b ltip rtip verdict proof unique prs; do
    [ "$verdict" = "unsafe" ] || continue
    printf '[FAIL] 拒绝删除分支 %s：无法证明「内容不会丢」\n' "$b" >&2
    if [ "$ltip" = "-" ]; then ltip_txt="无"; else ltip_txt="$ltip"; fi
    if [ "$rtip" = "-" ]; then rtip_txt="无"; else rtip_txt="$rtip"; fi
    printf '       本地 tip：%s\n' "$ltip_txt" >&2
    printf '       远端 tip：%s\n' "$rtip_txt" >&2
    printf '       与 origin/%s 的差异：%s\n' "$BASE_BRANCH" "$proof" >&2
    printf '       独有提交（tip~计数）：%s\n' "$unique" >&2
    printf '       关联 PR：%s\n' "$prs" >&2
  done < "$rows"
  cat >&2 <<'OPTION'
处置选项（先决策，再重跑）：
  1) 保留分支（默认，什么都不做）——把它转成正常切片：建 Issue / scripts/start.sh 开工 / scripts/deliver.sh 走评审合并
  2) 内容已由别的提交并入 main：重跑并加 --evidence "<证据，例如：内容已由 af2e9f4 并入 main>"（声明原文写入 Issue 锚点）
  3) 先本地备份再处置：git branch backup/<分支> <tip>（或 git tag backup/<分支> <tip>）后重跑
  4) 分支名记错 / PR 未记录：用 --branch <正确分支名> 指定后重跑
本脚本不提供「无证据强删」开关：任一分支不安全 → 全部不删、状态不迁移（fail-closed）
OPTION
  exit 1
fi

while IFS='|' read -r b ltip rtip verdict proof unique prs; do
  [ -n "$b" ] || continue
  ok "分支 ${b} 可安全删除：${proof}"
done < "$rows"

# ── 3. 触发路径识别（写进锚点）────────────────────────────────────────
# #141 D7：「③ Issue 已取消但分支已建」**只在分支确实存在时**成立 ——
#   无分支时打印它（尤其幂等短路路径）与实际不符，会误导。
scenario="② 作者中途放弃 / 异常终止（未检测到已关闭的 PR）"
if [ -s "$rows" ]; then
  if [ "$cur_state" = "canceled" ]; then
    scenario="③ Issue 已取消但分支已建"
  elif grep -q "CLOSED" "$rows" 2>/dev/null; then
    scenario="① PR 被关闭但不合并"
  fi
  ok "触发路径：${scenario}"
else
  scenario="无（该 Issue 没有实际存在的关联分支；分支清理路径不适用）"
  ok "触发路径：${scenario}"
fi

if [ "$DRY" -eq 1 ]; then
  info "[dry-run] 将要执行（未做任何写操作）"
  printf '  在 Issue #%s 留可恢复锚点（分支 tip / 原因 / 时间 / 判据）\n' "$ISSUE"
  while IFS='|' read -r b ltip rtip verdict proof unique prs; do
    if [ "$rtip" != "-" ]; then
      printf "  git -c credential.helper= -c credential.helper='!gh auth git-credential' push origin --delete %s\n" "$b"
    fi
    if [ "$ltip" != "-" ]; then
      printf '  git branch -D %s\n' "$b"
    fi
  done < "$rows"
  printf '  scripts/status.sh %s canceled --as %s   # 当前 %s\n' "$ISSUE" "$AS" "$cur_state"
  exit 0
fi

# ── 4. 幂等：已 canceled 且无分支 → 不写任何东西 ──────────────────────
if [ -z "$BRANCHES" ] && [ "$cur_state" = "canceled" ]; then
  ok "Issue #${ISSUE} 已是 canceled 且无任何关联分支 —— 无需操作（幂等，零写入）"
  # R4：异常路径已闭环（幂等无操作）→ 释放本 clone 的单写者锁
  release_writer_lock
  exit 0
fi

# ── 5. 先留可恢复锚点；写不进去就不删（fail-closed）──────────────────
info "写可恢复锚点（先留锚点，再删除）"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
anchor="$TMP/anchor.md"
{
  printf '**终止/取消记录（可恢复锚点）**\n\n'
  printf -- '- 触发路径：%s\n' "$scenario"
  printf -- '- 原因：%s\n' "$REASON"
  printf -- '- 时间（UTC）：%s\n' "$NOW"
  printf -- '- 执行者：@%s（`scripts/abort.sh --as %s`）\n' "$ACTOR" "$AS"
  printf -- '- 状态迁移：`%s` → `canceled`（只走 `scripts/status.sh`）\n' "$cur_state"
  if [ -z "$BRANCHES" ]; then
    printf -- '- 分支：无（本 Issue 无任何本地/远端关联分支）\n'
  else
    while IFS='|' read -r b ltip rtip verdict proof unique prs; do
      if [ "$ltip" = "-" ]; then ltip_txt="无"; else ltip_txt="$ltip"; fi
      if [ "$rtip" = "-" ]; then rtip_txt="无"; else rtip_txt="$rtip"; fi
      printf -- '- 分支 `%s`：本地 tip `%s`；远端 tip `%s`\n' "$b" "$ltip_txt" "$rtip_txt"
      printf -- '  - 删除判据：%s\n' "$proof"
      printf -- '  - 关联 PR：%s\n' "$prs"
    done < "$rows"
  fi
  printf -- '- 恢复方式：远端分支删除后，GitHub 仍保留 PR 中的提交（PR 页可 "Restore branch"）；本地可用 `git branch <名字> <tip>` 从对象库恢复（reflog 未过期前）。\n'
  printf -- '\n> 由 `scripts/abort.sh` 自动生成；判据与执行者见 `references/flow.md`（W8 终止/取消）。\n'
} > "$anchor"

if ! gh issue comment "$ISSUE" -R "$REPO" --body-file "$anchor" >/dev/null 2>&1; then
  die "无法写入可恢复锚点 —— 按规则**不得**删除分支、不得迁移状态（先修复评论权限后重跑）"
fi
ok "锚点已写入 Issue #${ISSUE}（含分支 tip SHA / 原因 / 时间）"

# ── 6. 删除远端与本地分支 ─────────────────────────────────────────────
if [ -n "$BRANCHES" ]; then
  info "删除远端分支"
  while IFS='|' read -r b ltip rtip verdict proof unique prs; do
    [ "$rtip" != "-" ] || continue
    if git -c credential.helper= -c credential.helper='!gh auth git-credential' push origin --delete "$b" >/dev/null 2>&1; then
      ok "远端分支 ${b} 已删除"
    else
      die "远端分支 ${b} 删除失败 —— 锚点已留，请人工核查后重跑（幂等）"
    fi
  done < "$rows"

  info "删除本地分支"
  cur_branch="$(git branch --show-current)"
  if [ -n "$cur_branch" ]; then
    case " ${BRANCHES} " in
      *" ${cur_branch} "*)
        [ -z "$(git status --porcelain)" ] || die "当前分支 ${cur_branch} 待删除，但工作区有未提交改动 —— 先提交/清理（锚点已留）"
        git checkout "$BASE_BRANCH" >/dev/null 2>&1 || die "无法切回 ${BASE_BRANCH}，请人工处理（锚点已留）"
        ;;
    esac
  fi
  while IFS='|' read -r b ltip rtip verdict proof unique prs; do
    [ "$ltip" != "-" ] || continue
    if git show-ref --verify --quiet "refs/heads/${b}"; then
      # 判据已成立且锚点已留，才允许 -D（squash 合并后 tip 不在 main 上，-d 必然拒绝）
      if git branch -D "$b" >/dev/null 2>&1; then
        ok "本地分支 ${b} 已删除"
      else
        die "本地分支 ${b} 删除失败 —— 锚点已留，请人工核查后重跑（幂等）"
      fi
    else
      ok "本地分支 ${b} 已不存在"
    fi
  done < "$rows"
fi

# ── 7. 状态迁移（只走 status.sh）+ 收尾校验 ────────────────────────────
info "状态迁移 → canceled（唯一入口 scripts/status.sh）"
if [ "$cur_state" = "canceled" ]; then
  ok "已是 canceled（幂等，无需迁移）"
else
  "$(dirname "$0")/status.sh" "$ISSUE" canceled --as "$AS"
fi

info "收尾校验"
leftovers="$(gh issue view "$ISSUE" -R "$REPO" --json labels \
  --jq '[.labels[].name | select(startswith("status/"))] | join(",")' 2>/dev/null || true)"
if [ -z "$leftovers" ]; then
  ok "Issue #${ISSUE} 无残留 status/* 标签"
else
  die "Issue #${ISSUE} 仍有残留状态标签：${leftovers} —— 跑 scripts/status.sh ${ISSUE} canceled --as author 清理后重跑" 
fi
while IFS='|' read -r b ltip rtip verdict proof unique prs; do
  [ -n "$b" ] || continue
  if git show-ref --verify --quiet "refs/heads/${b}"; then
    die "本地分支 ${b} 仍存在"
  fi
  if git ls-remote --exit-code --heads origin "$b" >/dev/null 2>&1; then
    die "远端分支 ${b} 仍存在"
  fi
  ok "分支 ${b}：本地与远端均已清理"
done < "$rows"

echo
ok "异常路径已闭环：分支（本地+远端）已清理、状态 canceled、锚点已留"
# R4：异常结束（已闭环）→ 释放本 clone 的单写者锁
release_writer_lock
