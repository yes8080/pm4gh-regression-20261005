#!/usr/bin/env bash
# scripts/preflight.sh —— 开工前预检（任何接手者的第一步）
#
# 判定：全部 [ OK ] 才继续；任何 [FAIL] → 把原文报告 dispatcher，不要"先干着看"。
# 检查项：命令齐备 / gh 登录 / cwd 与仓库形态 / 工作区 / 远端唯一 / 三身份互不相同 /
#         凭据 scope 与最小权限 / 线上规则集 == 仓库内定义 / 每个必需 context 都有工作流 job。
#
# 退出码：0 全部通过；1 存在未通过项（每项都给出可行动的修复提示）

set -eu

SECRETS_DIR="${SECRETS_DIR:-.secrets}"
DEVELOPER_PAT_FILE="${DEVELOPER_PAT_FILE:-${SECRETS_DIR}/developer.pat}"
REVIEWER_PAT_FILE="${REVIEWER_PAT_FILE:-${SECRETS_DIR}/reviewer.pat}"
RULESET_FILE="${RULESET_FILE:-.github/rulesets/main-protection.json}"
BASE_BRANCH="${BASE_BRANCH:-main}"
# 这 5 个字符串是**必需检查的 context**（= 工作流里 job 的 name），一个字都不能差。
REQUIRED_EXPECTED="ci/lint ci/test policy/linked-issue policy/branch-name policy/template"

fail=0
ok()   { printf '[ OK ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
bad()  { printf '[FAIL] %s\n' "$*" >&2; fail=$((fail + 1)); }
info() { printf '\n== %s ==\n' "$*"; }

# 取某凭据文件对应的登录名（不打印凭据本身）
login_via_pat() {
  [ -s "${1:-}" ] || return 0
  GH_TOKEN="$(cat "$1")" gh api user --jq .login 2>/dev/null || true
}

# classic PAT 的 OAuth scope 列表（官方响应头 x-oauth-scopes，逗号 + 空格分隔）
scopes_via_pat() {
  [ -s "${1:-}" ] || return 0
  curl -sS -I -H "Authorization: token $(cat "$1")" https://api.github.com/user 2>/dev/null \
    | grep -i '^x-oauth-scopes:' \
    | sed -E 's/^[Xx]-[Oo][Aa]uth-[Ss]copes:[[:space:]]*//' \
    | tr -d '\r' | tr ',' '\n' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | grep -v '^$' || true
}

file_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null || printf '?'
}

info "1/9 基础命令"
for c in git gh jq awk grep sed curl; do
  if command -v "$c" >/dev/null 2>&1; then ok "${c} 可用"; else bad "缺少命令 ${c}，请先安装"; fi
done
printf '  bash：%s\n' "$(bash --version | head -1)"

info "2/9 gh 登录（合并身份 / dispatcher）"
main_login=""
if gh auth status >/dev/null 2>&1; then
  main_login="$(env -u GH_TOKEN -u GITHUB_TOKEN gh api user --jq .login 2>/dev/null || true)"
  if [ -n "$main_login" ]; then ok "gh 已登录：${main_login}"; else bad "gh 已登录但读不到账号（gh api user 失败）"; fi
else
  bad "gh 未登录：运行 gh auth login（合并身份靠它，见 docs/WORKFLOW.md §0）"
fi

info "3/9 仓库形态与 cwd"
toplevel="$(git rev-parse --show-toplevel 2>/dev/null || true)"
REPO=""
if [ -z "$toplevel" ]; then
  bad "当前不在 git 仓库内"
else
  cwd_real="$(pwd -P)"
  case "$cwd_real" in
    "$toplevel"|"$toplevel"/*) ok "cwd 在仓库内：${cwd_real}" ;;
    *) bad "cwd 不在本仓库内（cwd=${cwd_real}，仓库=${toplevel}）" ;;
  esac
  common="$(git rev-parse --git-common-dir 2>/dev/null || true)"
  case "$common" in
    .git|"$toplevel/.git") ok "git common dir = ${common}（非 worktree）" ;;
    *) bad "git common dir=${common} —— 疑似 worktree/隔离副本" ;;
  esac
  wt_count="$(git worktree list 2>/dev/null | wc -l | tr -d ' ')"
  [ "$wt_count" = "1" ] && ok "worktree 数量 1" || bad "检测到 ${wt_count} 个 worktree（同一时间只允许一个执行者）"
  gd="$(git rev-parse --git-dir 2>/dev/null || true)"
  if [ -n "$gd" ] && [ -e "${gd}/index.lock" ]; then
    bad "存在 ${gd}/index.lock —— 可能有另一个 git 进程在跑"
  else
    ok "无 index.lock"
  fi
  [ -f "$RULESET_FILE" ] || bad "缺少规则集定义 ${RULESET_FILE}（是否在仓库根目录？）"
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  [ -n "$REPO" ] && ok "仓库 slug：${REPO}" || bad "无法确定仓库 slug（gh repo view 失败）"
fi

info "4/9 工作区与远端"
dirty="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
[ "$dirty" = "0" ] && ok "工作区干净" || warn "工作区有 ${dirty} 处未提交改动 —— 开工前确认归属（不要抹掉他人成果）"
current="$(git branch --show-current 2>/dev/null || true)"
printf '  当前分支：%s\n' "${current:-（游离 HEAD）}"
remotes="$(git remote 2>/dev/null | tr '\n' ' ' | sed -E 's/[[:space:]]+$//')"
if [ "$remotes" = "origin" ]; then
  ok "远端唯一：origin（$(git remote get-url origin 2>/dev/null || true)）"
  if git fetch -q origin 2>/dev/null; then
    lm="$(git rev-parse --short "$BASE_BRANCH" 2>/dev/null || true)"
    rm="$(git rev-parse --short "origin/${BASE_BRANCH}" 2>/dev/null || true)"
    [ -n "$lm" ] && [ "$lm" = "$rm" ] && ok "本地 ${BASE_BRANCH} 与 origin/${BASE_BRANCH} 一致（${lm}）" \
      || warn "本地 ${BASE_BRANCH}=${lm:-无} 与 origin/${BASE_BRANCH}=${rm:-无} 不一致 —— 推送前先同步"
  else
    warn "无法 fetch origin（网络或凭据问题）"
  fi
else
  bad "远端不是唯一的 origin（当前：${remotes:-无}）"
fi

info "5/9 三身份凭据（作者 / 评审 / 合并）"
dev_login="$(login_via_pat "$DEVELOPER_PAT_FILE")"
rev_login="$(login_via_pat "$REVIEWER_PAT_FILE")"
for pair in "${DEVELOPER_PAT_FILE}:作者" "${REVIEWER_PAT_FILE}:评审"; do
  f="${pair%%:*}"; label="${pair#*:}"
  if [ ! -s "$f" ]; then
    bad "${label}凭据缺失或为空：${f}（见 docs/WORKFLOW.md §0）"
    continue
  fi
  mode="$(file_mode "$f")"
  [ "$mode" = "600" ] && ok "${label}凭据权限 600" || bad "${label}凭据权限为 ${mode}，应为 600：chmod 600 ${f}"
  if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
    bad "${label}凭据**已被 git 跟踪** —— 立即 git rm --cached 并轮换该 token"
  else
    ok "${label}凭据未进入版本库"
  fi
done
[ -n "$dev_login" ] && ok "作者身份：${dev_login}" || bad "作者凭据无法认证（已过期/被撤销/不是 classic PAT）"
[ -n "$rev_login" ] && ok "评审身份：${rev_login}" || bad "评审凭据无法认证（凭据失效会让 .github/**、scripts/** 永久无法合并）"
if [ -n "$main_login" ] && [ -n "$dev_login" ] && [ "$main_login" != "$dev_login" ]; then
  ok "身份分离：合并 ${main_login} ≠ 作者 ${dev_login}"
elif [ -n "$main_login" ] && [ "$main_login" = "$dev_login" ]; then
  bad "身份分离失败：作者身份 = gh 登录身份（${main_login}）—— 检查 ${DEVELOPER_PAT_FILE} 是否放错"
fi
if [ -n "$dev_login" ] && [ -n "$rev_login" ] && [ "$dev_login" != "$rev_login" ]; then
  ok "身份分离：作者 ${dev_login} ≠ 评审 ${rev_login}"
elif [ -n "$dev_login" ] && [ "$dev_login" = "$rev_login" ]; then
  bad "身份分离失败：作者身份 = 评审身份（${dev_login}）—— 两个凭据拿错了"
fi

info "6/9 凭据 scope 与最小权限"
dev_scopes="$(scopes_via_pat "$DEVELOPER_PAT_FILE" | tr '\n' ' ' | sed -E 's/[[:space:]]+$//')"
rev_scopes="$(scopes_via_pat "$REVIEWER_PAT_FILE" | tr '\n' ' ' | sed -E 's/[[:space:]]+$//')"
if [ -z "$dev_scopes" ]; then
  bad "作者凭据读不到 OAuth scope 头 —— 无法证明 scope 合规（需要 repo + workflow）"
else
  case " ${dev_scopes} " in *" repo "*) ok "作者 scope 含 repo（实测：${dev_scopes}）" ;; *) bad "作者 scope 不含 repo（实测：${dev_scopes}）" ;; esac
  case " ${dev_scopes} " in
    *" workflow "*) ok "作者 scope 含 workflow（可推送 .github/workflows/**）" ;;
    *) bad "作者 scope 缺 workflow —— 推送 .github/workflows/** 会被服务端整体拒绝（实测：${dev_scopes}）" ;;
  esac
fi
if [ -z "$rev_scopes" ]; then
  bad "评审凭据读不到 OAuth scope 头 —— 无法证明 scope 合规（需要 repo）"
else
  case " ${rev_scopes} " in *" repo "*) ok "评审 scope 含 repo（实测：${rev_scopes}）" ;; *) bad "评审 scope 不含 repo（实测：${rev_scopes}）" ;; esac
fi
if [ -n "$REPO" ] && [ -n "$dev_login" ]; then
  perms="$(GH_TOKEN="$(cat "$DEVELOPER_PAT_FILE")" gh api "repos/${REPO}" --jq '"\(.permissions.push)/\(.permissions.admin)"' 2>/dev/null || true)"
  case "$perms" in
    true/false) ok "作者身份 ${dev_login}：push 有、admin 无（符合最小权限）" ;;
    "")        bad "读不到作者身份对本仓库的权限（404？邀请未接受？）" ;;
    *)         warn "作者身份权限异常：push/admin=${perms}" ;;
  esac
fi

info "7/9 工作流 job 名 == 必需检查 context（逐字）"
wf_actual="$(grep -hE '^[[:space:]]+name: (ci|policy)/' .github/workflows/*.yml 2>/dev/null \
  | sed -E 's/^[[:space:]]*name:[[:space:]]*//' | sort -u || true)"
expected_sorted="$(printf '%s\n' $REQUIRED_EXPECTED | sort -u)"
if [ "$wf_actual" = "$expected_sorted" ]; then
  ok "工作流产出的检查名与 5 个必需 context 精确一致"
else
  bad "工作流 job 名与必需的 5 个 context 不一致（改名 = 所有 PR 永久 pending）。不要自行修改，报告 dispatcher。"
  warn "  期望：$(printf '%s' "$expected_sorted" | tr '\n' ' ')"
  warn "  实际：$(printf '%s' "$wf_actual" | tr '\n' ' ')"
fi

info "8/9 线上规则集 vs 仓库内定义"
if [ -z "$REPO" ]; then
  bad "仓库 slug 未知，跳过线上规则集比对"
else
  rid="$(gh api "repos/${REPO}/rulesets" --jq '.[]|select(.name=="main-protection")|.id' 2>/dev/null | head -1 || true)"
  if [ -z "$rid" ]; then
    bad "线上没有名为 main-protection 的规则集 —— 门禁未生效（属 dispatcher 权限，请报告）"
  else
    ok "线上规则集 id=${rid}"
    live_ctx="$(gh api "repos/${REPO}/rulesets/${rid}" \
      --jq '.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[].context' 2>/dev/null | sort -u || true)"
    file_ctx="$(jq -r '.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[].context' "$RULESET_FILE" | sort -u)"
    if [ "$live_ctx" = "$file_ctx" ]; then
      ok "必需检查清单：线上 == 仓库内定义（5 项）"
    else
      bad "必需检查清单不一致（改名或降级会让 PR 永久 pending 或门禁失效）"
      warn "  线上：$(printf '%s' "$live_ctx" | tr '\n' ' ')"
      warn "  仓库：$(printf '%s' "$file_ctx" | tr '\n' ' ')"
    fi
    live_shape="$(gh api "repos/${REPO}/rulesets/${rid}" --jq '[
      (.enforcement),
      (.conditions.ref_name.include|join(",")),
      (.bypass_actors|length),
      ([.rules[]|select(.type=="pull_request")|.parameters.required_approving_review_count]|join("")),
      ([.rules[]|select(.type=="pull_request")|.parameters.require_code_owner_review]|join("")),
      ([.rules[]|select(.type=="pull_request")|.parameters.require_last_push_approval]|join(""))
    ]|join(" | ")' 2>/dev/null || true)"
    printf '  线上形态（enforcement | 目标 | bypass 数 | approvals | code-owner | last-push）：%s\n' "$live_shape"
    case "$live_shape" in
      "active | ~DEFAULT_BRANCH | 0 | 1 | true | true") ok "线上规则集形态符合预期" ;;
      "") warn "读不到线上规则集形态（权限？）" ;;
      *) bad "线上规则集形态与预期不符（应为 active | ~DEFAULT_BRANCH | 0 | 1 | true | true）—— 不要自行修改，报告 dispatcher" ;;
    esac
  fi
fi

info "9/9 未提交任何凭据"
if git grep -nE 'ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|gho_[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----' -- . >/dev/null 2>&1; then
  bad "检测到疑似凭据被提交进仓库（git grep 命中）"
else
  ok "未发现凭据"
fi

echo
if [ "$fail" -eq 0 ]; then
  ok "预检全部通过，可以开始工作"
  exit 0
fi
warn "共有 ${fail} 项未通过 —— 修好再开始（不要跳过）"
exit 1
