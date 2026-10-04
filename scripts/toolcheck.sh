#!/usr/bin/env bash
# scripts/toolcheck.sh —— 环境与凭据自检
#
# 定位：任何工具/人/AI 接手项目后的**第一步**（见 TOOLING.md）。
# 动机（三次真实事故）：
#   ① 误用 `gh issue create --json`（该命令没有这个旗标）→ 用静态检查兜住"工具能力假设"
#   ② 首切片漏用 `gh issue develop` → 分支未绑定 Issue
#   ③ 凭据单点无自检 → `require_code_owner_review` 生效后，reviewer 凭据失效会让
#      `.github/`、`scripts/`、`docs/` 的改动**永久无法合并**（Bug #13 教训）
#
# 用法：scripts/toolcheck.sh
# 退出码：0 全部通过；1 存在未通过项（每项都会给出可行动的修复提示）

set -eu
. "$(dirname "$0")/lib.sh"

fail=0
note_fail() { warn "$1"; fail=$((fail + 1)); }

info "1/8 基础命令"
for c in git gh jq awk grep sed; do
  if command -v "$c" >/dev/null 2>&1; then ok "${c} 可用"; else note_fail "缺少命令 ${c}，请先安装"; fi
done

info "2/8 bash 版本与兼容性"
bash_ver="$(bash --version | head -1 | sed 's/.*version //; s/ .*//')"
log "  当前 bash：${bash_ver}"
case "$bash_ver" in
  3.2*) log '  → bash 3.2（macOS 自带）：脚本必须继续遵守两条铁律：禁用 bash4 特性；变量后紧跟中文要写 ${VAR}' ;;
  *)    log '  → bash 4+：本地不会暴露 bash 3.2 的兼容问题，但 CI 仍会检查' ;;
esac

info "3/8 gh 登录状态"
if gh auth status >/dev/null 2>&1; then
  who="$(gh api user --jq .login 2>/dev/null || true)"
  ok "gh 已登录：${who}"
else
  note_fail "gh 未登录：运行 gh auth login"
fi

info "4/8 仓库与规则集文件"
require_repo_root
ok "仓库根目录正确，仓库为 ${REPO}"
[ -f "$RULESET_FILE" ] || note_fail "缺少规则集定义 ${RULESET_FILE}"

info "5/8 规则集：线上与仓库内定义是否一致"
rid="$(live_ruleset_id)"
if [ -z "$rid" ]; then
  note_fail "线上没有名为 main-protection 的规则集 —— 门禁未生效（应用方式见 .github/rulesets/README.md）"
else
  ok "线上规则集 id=${rid}"
  live_ctx="$(gh api "repos/${REPO}/rulesets/${rid}" \
    --jq '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context' | sort)"
  file_ctx="$(required_contexts | sort)"
  if [ "$live_ctx" = "$file_ctx" ]; then
    ok "必需检查清单与仓库定义一致"
  else
    warn "  --- 线上必需检查 ---"; printf '%s\n' "$live_ctx" >&2
    warn "  --- 仓库内定义 ---"; printf '%s\n' "$file_ctx" >&2
    note_fail "必需检查清单不一致（改名或降级会导致 PR 永久 pending 或门禁失效）"
  fi
  code_owner="$(gh api "repos/${REPO}/rulesets/${rid}" \
    --jq '.rules[] | select(.type=="pull_request") | .parameters.require_code_owner_review')"
  log "  require_code_owner_review = ${code_owner}（true 时，评审身份凭据是硬依赖）"
fi

info "6/8 必需检查是否都有对应工作流 job"
missing=""
while IFS= read -r ctx; do
  [ -n "$ctx" ] || continue
  if ! workflow_check_names | grep -qx "$ctx"; then missing="${missing} ${ctx}"; fi
done <<EOF
$(required_contexts)
EOF
if [ -n "$missing" ]; then
  note_fail "以下必需检查没有任何工作流会产生它（会导致 PR 永久 pending）：${missing}"
else
  ok "规则集引用的必需检查全部有对应 job"
fi

info "7/8 评审/验收身份凭据"
if [ ! -e "$REVIEWER_PAT_FILE" ]; then
  note_fail "找不到 ${REVIEWER_PAT_FILE} —— 没有它就无法提交独立评审/验收（见 docs/PLAYBOOK.md）"
else
  mode="$(file_mode "$REVIEWER_PAT_FILE")"
  [ "$mode" = "600" ] && ok "凭据文件权限 ${mode}" || note_fail "凭据文件权限为 ${mode}，应为 600（运行 chmod 600 ${REVIEWER_PAT_FILE}）"

  if git ls-files --error-unmatch "$REVIEWER_PAT_FILE" >/dev/null 2>&1; then
    note_fail "凭据文件**已被 git 跟踪**，存在泄露风险 —— 立即 git rm --cached 并轮换该 token"
  else
    ok "凭据未进入版本库"
  fi

  rv_login="$(GH_TOKEN="$(cat "$REVIEWER_PAT_FILE")" gh api user --jq .login 2>/dev/null || true)"
  if [ -z "$rv_login" ]; then
    note_fail "凭据无法通过 API 认证（可能已过期/被撤销）—— 需重新签发并写入 ${REVIEWER_PAT_FILE}"
  else
    ok "凭据身份：${rv_login}"
    if authorized_identities | grep -qx "$rv_login"; then
      ok "身份在授权清单内"
    else
      note_fail "身份 ${rv_login} 不在 ${AUTH_IDENTITIES_FILE} 中，其评审不计入验收"
    fi
    can_push="$(GH_TOKEN="$(cat "$REVIEWER_PAT_FILE")" gh api "repos/${REPO}" --jq '.permissions.push' 2>/dev/null || echo false)"
    [ "$can_push" = "true" ] && ok "凭据对本仓库有写权限（可提交评审）" || note_fail "凭据对本仓库无写权限，无法提交评审"
  fi
fi

info "8/10 git 与远端可用性"
if git ls-remote --heads origin >/dev/null 2>&1; then
  ok "可访问远端 origin"
else
  note_fail "无法访问远端 origin（检查网络与凭据）"
fi
current="$(git branch --show-current 2>/dev/null || true)"
log "  当前分支：${current:-（游离或空）}"

info "9/10 git 工作区预检（工作区规则：/Users/ws/code/AGENTS.md 第 2 条）"
toplevel="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$toplevel" ]; then
  note_fail "当前不在 git 仓库内"
else
  cwd_real="$(pwd -P)"
  case "$cwd_real" in
    "$toplevel"|"$toplevel"/*) ok "cwd 在仓库内：${cwd_real}" ;;
    *) note_fail "cwd 不在本仓库内（cwd=${cwd_real}，仓库=${toplevel}）—— 可能开在了错误目录" ;;
  esac

  common="$(git rev-parse --git-common-dir 2>/dev/null || true)"
  if [ "$common" = ".git" ]; then
    ok "git common dir = .git（非 worktree）"
  else
    note_fail "git common dir=${common} —— 疑似 worktree/隔离副本，工作区规则明令禁止"
  fi

  wt_count="$(git worktree list 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$wt_count" = "1" ]; then
    ok "worktree 数量 1（符合规则）"
  else
    note_fail "检测到 ${wt_count} 个 worktree —— 工作区规则禁止 clone/worktree/隔离实现副本"
  fi

  head_sha="$(git rev-parse --short HEAD 2>/dev/null || true)"
  log "  HEAD=${head_sha:-未知}"

  dirty="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$dirty" = "0" ]; then
    ok "工作区干净"
  else
    warn "工作区有 ${dirty} 处未提交改动 —— 开工前确认归属（切勿用 reset/checkout 抹掉他人成果）"
  fi

  gd="$(git rev-parse --git-dir 2>/dev/null || true)"
  if [ -n "$gd" ] && [ -e "${gd}/index.lock" ]; then
    note_fail "存在 ${gd}/index.lock —— 可能有另一个 git 进程在运行（同一时间只允许一个执行者）"
  else
    ok "无 index.lock（无并发 git 操作迹象）"
  fi
  log "  ⚠️ 活动写者无法自动探测：开始工作前请人工确认无其他执行者（同一 workspace 只允许一个执行者）"

  remotes="$(git remote 2>/dev/null | tr '\n' ' ')"
  if [ "$(printf '%s' "$remotes" | tr -d ' ')" = "origin" ]; then
    ok "远程唯一：origin"
    url="$(git remote get-url origin 2>/dev/null || true)"
    case "$url" in
      *yes8080/pm4gh*) ok "origin 指向本仓库：${url}" ;;
      *) note_fail "origin 指向意外仓库：${url}" ;;
    esac
    if git fetch -q origin 2>/dev/null; then
      lm="$(git rev-parse --short main 2>/dev/null || true)"
      rm="$(git rev-parse --short origin/main 2>/dev/null || true)"
      if [ -n "$lm" ] && [ "$lm" = "$rm" ]; then
        ok "本地 main 与 origin/main 一致（${lm}）"
      else
        warn "本地 main=${lm:-无} 与 origin/main=${rm:-无} 不一致 —— 推送前请先同步"
      fi
    else
      warn "无法 fetch origin（网络或凭据问题）"
    fi
  else
    note_fail "远程不是唯一的 origin（当前：${remotes:-无}）—— 工作区规则只允许向已授权的唯一 GitHub 远程推送"
  fi
fi

echo
if [ "$fail" -eq 0 ]; then
  info "10/10 两个 bot 凭据（作者 / 评审）"
for pair in "developer:${DEVELOPER_PAT_FILE:-.secrets/developer.pat}:作者" "reviewer:${REVIEWER_PAT_FILE:-.secrets/reviewer.pat}:评审"; do
  role="${pair%%:*}"; rest="${pair#*:}"; file="${rest%%:*}"; label="${rest#*:}"
  if [ ! -s "$file" ]; then
    note_fail "${label}身份凭据缺失：${file}（开通流程见 docs/PLAYBOOK.md W0.4）"
    continue
  fi
  mode="$(stat -f '%Lp' "$file" 2>/dev/null || stat -c '%a' "$file" 2>/dev/null || echo '?')"
  [ "$mode" = "600" ] && ok "${label}凭据权限 600" || warn "${label}凭据权限为 ${mode}（建议 600）"
  git ls-files --error-unmatch "$file" >/dev/null 2>&1 && note_fail "${label}凭据已进入版本库：${file}" || ok "${label}凭据未进入版本库"
  tok="$(cat "$file")"
  login="$(curl -sS -H "Authorization: token ${tok}" https://api.github.com/user 2>/dev/null | jq -r '.login // ""' 2>/dev/null || true)"
  [ -n "$login" ] || { note_fail "${label}凭据无效（无法读取身份）"; continue; }
  perms="$(curl -sS -H "Authorization: token ${tok}" "https://api.github.com/repos/${REPO}" 2>/dev/null | jq -r 'if .permissions then "\(.permissions.push)/\(.permissions.admin)" else "none" end' 2>/dev/null || echo none)"
  case "$perms" in
    true/false) ok "${label}身份 ${login}：push 有、admin 无（符合最小权限）" ;;
    none)       note_fail "${label}身份 ${login} 对本仓库无访问权（404）—— 是否漏做 W0.4 第 4/5 步（邀请+同意）？" ;;
    *)          warn "${label}身份 ${login} 权限异常：push/admin=${perms}" ;;
  esac
done

ok "全部通过，可以开始工作"
  exit 0
fi
warn "共有 ${fail} 项未通过 —— 修好再开始（不要跳过：门禁失效或凭据失效都会让 PR 卡死）"
exit 1
