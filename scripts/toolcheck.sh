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

info "8/8 git 与远端可用性"
if git ls-remote --heads origin >/dev/null 2>&1; then
  ok "可访问远端 origin"
else
  note_fail "无法访问远端 origin（检查网络与凭据）"
fi
current="$(git branch --show-current 2>/dev/null || true)"
log "  当前分支：${current:-（游离或空）}"

echo
if [ "$fail" -eq 0 ]; then
  ok "全部通过，可以开始工作"
  exit 0
fi
warn "共有 ${fail} 项未通过 —— 修好再开始（不要跳过：门禁失效或凭据失效都会让 PR 卡死）"
exit 1
