#!/usr/bin/env bash
# toolkit/tests/self-test.sh —— 治理套件安装器自检（离线；不联网、不改任何真实仓库）
#
# 为什么需要它（对应 Issue #46 的验收标准）：
#   --dry-run / --check 可以在 pm4gh 上真跑，但「install 的三态幂等 / 不覆盖非本套件对象 /
#   重复执行为 no-op / 命令报错后仍能正确归属（D6）」这些语义**不能拿真实仓库做实验**。
#   因此用 toolkit/tests/stub-gh 在沙箱里模拟 GitHub 侧对象，逐条断言。
#
# 用法：bash toolkit/tests/self-test.sh
# 退出码：0 全部通过；1 存在失败项
set -eu

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
KIT_DIR="$(cd "${TEST_DIR}/.." && pwd)"

PASS=0; FAIL=0
apass() { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
afail() { FAIL=$((FAIL + 1)); printf '  [FAIL] %s（期望 %s；实际 %s）\n' "$1" "$2" "$3"; }
aeq() { if [ "$2" = "$3" ]; then apass "$1"; else afail "$1" "$2" "$3"; fi; }
acontains() { if printf '%s' "$3" | grep -q -- "$2"; then apass "$1"; else afail "$1" "包含「$2」" "$3"; fi; }
anotcontains() { if printf '%s' "$3" | grep -q -- "$2"; then afail "$1" "不含「$2」" "$3"; else apass "$1"; fi; }
grepc() { grep -c -- "$1" "$2" 2>/dev/null || true; }

SB=""
cleanup() {  # 只清理本脚本自己创建的沙箱目录
  case "${SB:-}" in
    *toolkit-selftest.*) rm -rf "${SB}" ;;
  esac
}
trap cleanup EXIT INT TERM
setup_sandbox() {
  cleanup
  SB="$(mktemp -d "${TMPDIR:-/tmp}/toolkit-selftest.XXXXXX")"
  mkdir -p "${SB}/root/.secrets" "${SB}/bin"
  cp -R "${KIT_DIR}" "${SB}/root/toolkit"
  printf 'fake-token-author'   > "${SB}/root/.secrets/developer.pat"
  printf 'fake-token-reviewer' > "${SB}/root/.secrets/reviewer.pat"
  cp "${TEST_DIR}/stub-gh.sh" "${SB}/bin/gh"; chmod +x "${SB}/bin/gh"
  printf '{"labels":[],"collaborators":[],"rulesets":[]}\n' > "${SB}/state.json"
  export STUB_STATE="${SB}/state.json" STUB_LOG="${SB}/gh.log" STUB_WRITES="${SB}/gh.writes"
  export STUB_REPO="acme/widgets" STUB_BRANCH="trunk"
  export STUB_AUTHOR="author-bot" STUB_REVIEWER="reviewer-bot"
  unset STUB_FAIL_LABEL_NAME || true
  : > "${STUB_LOG}"; : > "${STUB_WRITES}"
  PATH="${SB}/bin:${PATH}"; export PATH
  unset GH_TOKEN || true
  MF="${SB}/root/toolkit/manifest.json"
  INS="${SB}/root/toolkit/install.sh"
}
ins() { bash "${INS}" "$@" 2>&1; }
# 注意：set -e 下不能写 out="$(ins ...)"; rc=$? —— 命令替换失败会直接终止脚本
run_ins() { out=""; rc=0; out="$(ins "$@")" || rc=$?; }
writes() { cat "${STUB_WRITES}"; }
ledger() { jq -r ".ledger[\"$1\"].$2" "${MF}"; }

echo "═══ 0. 静态检查：toolkit/ 内不得硬编码仓库名与账号 ═══"
hard="$(grep -rn 'yes8080' "${KIT_DIR}" 2>/dev/null | grep -v "^${TEST_DIR}/self-test.sh:" || true)"
aeq "T0.1 toolkit/ 内无 yes8080" "" "${hard}"
hard="$(grep -rln 'pm4gh' "${KIT_DIR}" 2>/dev/null | grep -v "^${TEST_DIR}/self-test.sh$" || true)"
aeq "T0.2 toolkit/ 内无 pm4gh" "" "${hard}"

echo
echo "═══ 1. 空仓库：--check 应报漂移且零写入 ═══"
setup_sandbox
run_ins --check
aeq "T1.1 --check 退出码 1（对象缺失 = 漂移）" "1" "${rc}"
acontains "T1.2 报告文件缺失" "文件缺失" "${out}"
acontains "T1.3 报告标签缺失" "标签缺失" "${out}"
acontains "T1.4 报告规则集缺失" "规则集缺失" "${out}"
aeq "T1.5 --check 零写入" "" "$(writes)"

echo
echo "═══ 2. 空仓库：--dry-run 应完整预告且零写入 ═══"
: > "${STUB_WRITES}"
run_ins --dry-run
aeq "T2.1 --dry-run 退出码 0" "0" "${rc}"
acontains "T2.2 预告创建文件" "创建" "${out}"
acontains "T2.3 预告创建规则集" "ruleset main-protection" "${out}"
aeq "T2.4 --dry-run 零写入" "" "$(writes)"
aeq "T2.5 --dry-run 未落任何本地文件" "absent" "$([ -e "${SB}/root/.github" ] && printf present || printf absent)"

echo
echo "═══ 3. --apply：创建全部对象并登记归属 ═══"
: > "${STUB_WRITES}"
run_ins --apply
aeq "T3.1 --apply 退出码 0" "0" "${rc}"
aeq "T3.2 创建 35 个标签" "35" "$(jq '.labels | length' "${STUB_STATE}")"
aeq "T3.3 创建 1 个规则集" "1" "$(jq '.rulesets | length' "${STUB_STATE}")"
aeq "T3.4 邀请 2 个协作者" "2" "$(jq '[.collaborators[] | select(.push)] | length' "${STUB_STATE}")"
aeq "T3.5 落盘 10 个受管文件" "10" "$(cd "${SB}/root" && ls .github/labels.yml .github/rulesets/main-protection.json .github/authorized-identities.txt .github/PULL_REQUEST_TEMPLATE.md .github/ISSUE_TEMPLATE/*.yml | wc -l | tr -d ' ')"
aeq "T3.6 落盘 2 个工作流" "2" "$(ls "${SB}/root/.github/workflows" | wc -l | tr -d ' ')"
aeq "T3.7 CODEOWNERS 追加 6 行" "6" "$(grep -cE '^[^#[:space:]]' "${SB}/root/.github/CODEOWNERS")"
acontains "T3.8 规则集写入前剥掉 _comment 字段" "true" "$(jq -r '.rulesets[0].body | has("_comment") | not' "${STUB_STATE}")"
aeq "T3.9 ledger 记 owned=true" "true" "$(ledger 'label:type/feature' owned)"
aeq "T3.10 ledger 记 pre_existing=false" "false" "$(ledger 'label:type/feature' pre_existing)"
aeq "T3.11 ledger 记文件 owned=true" "true" "$(ledger 'file:.github/labels.yml' owned)"
aeq "T3.12 ledger 记规则集 owned=true" "true" "$(ledger 'ruleset:main-protection' owned)"
aeq "T3.13 安装结果无残留占位符（.github/CODEOWNERS）" "0" "$(grepc '@@' "${SB}/root/.github/CODEOWNERS")"
aeq "T3.14 安装结果无残留占位符（authorized-identities）" "0" "$(grepc '@@' "${SB}/root/.github/authorized-identities.txt")"

echo
echo "═══ 4. 重复 --apply 必须是 no-op ═══"
: > "${STUB_WRITES}"
run_ins --apply
aeq "T4.1 重复 --apply 退出码 0" "0" "${rc}"
aeq "T4.2 重复 --apply 零写入（no-op）" "" "$(writes)"
acontains "T4.3 报告全部已存在且一致" "已存在且一致" "${out}"
aeq "T4.4 重复 --apply 创建数为 0" "0" "$(printf '%s\n' "${out}" | sed -n 's/^  将创建\/已创建：//p')"

echo
echo "═══ 5. --apply 之后 --check 必须无漂移且零写入 ═══"
run_ins --check
aeq "T5.1 --check 退出码 0" "0" "${rc}"
acontains "T5.2 报告 check 通过" "check 通过" "${out}"
aeq "T5.3 --check 零写入" "" "$(writes)"

echo
echo "═══ 6. 已存在但非本套件创建：不覆盖、不接管、仅报告 ═══"
setup_sandbox
jq '.labels += [{name:"type/feature",color:"ffffff",description:"用户既有标签"}]' "${SB}/state.json" > "${SB}/s2" && mv "${SB}/s2" "${SB}/state.json"
mkdir -p "${SB}/root/.github"; printf 'user-owned\n' > "${SB}/root/.github/labels.yml"
run_ins --apply
aeq "T6.1 存在冲突时 --apply 退出码 1（需要人工决定）" "1" "${rc}"
acontains "T6.2 报告冲突且不覆盖标签" "非本套件创建" "${out}"
aeq "T6.3 未对既有标签发起写入" "0" "$(grepc 'label edit' "${STUB_WRITES}")"
aeq "T6.4 既有文件内容未被改写" "user-owned" "$(cat "${SB}/root/.github/labels.yml")"
aeq "T6.5 ledger 记 pre_existing=true" "true" "$(ledger 'label:type/feature' pre_existing)"
aeq "T6.6 ledger 记 owned=false" "false" "$(ledger 'label:type/feature' owned)"
run_ins --check
aeq "T6.7 冲突在 --check 中同样报漂移（退出码 1）" "1" "${rc}"
aeq "T6.8 --check 后既有文件仍未改写" "user-owned" "$(cat "${SB}/root/.github/labels.yml")"

echo
echo "═══ 7. D6 重试归属：命令报错但对象已创建，不得漏记 ═══"
setup_sandbox
export STUB_FAIL_LABEL_NAME="type/chore"
run_ins --apply
aeq "T7.1 有失败项时 --apply 退出码 1" "1" "${rc}"
aeq "T7.2 报错但已创建的对象仍被归属为 owned" "true" "$(ledger 'label:type/chore' owned)"
aeq "T7.3 且不被误判为 pre_existing" "false" "$(ledger 'label:type/chore' pre_existing)"
unset STUB_FAIL_LABEL_NAME || true
: > "${STUB_WRITES}"
run_ins --apply
aeq "T7.4 第二次 --apply 收敛（退出码 0，无冲突）" "0" "${rc}"
aeq "T7.5 第二次 --apply 零写入" "" "$(writes)"

echo
echo "═══ 8. 可移植性：仓库 / 默认分支 / 身份账号全部参数化 ═══"
setup_sandbox
run_ins --apply --repo other/project --default-branch trunk2 --owner someone \
        --author-account dev-x --reviewer-account rev-y
aeq "T8.1 换仓库后 --apply 退出码 0" "0" "${rc}"
co="$(cat "${SB}/root/.github/CODEOWNERS")"
acontains "T8.2 CODEOWNERS 使用目标 owner/reviewer" "@someone @rev-y" "${co}"
anotcontains "T8.3 CODEOWNERS 不含 acme" "@acme" "${co}"
cfg="$(cat "${SB}/root/.github/ISSUE_TEMPLATE/config.yml")"
acontains "T8.4 模板 URL 使用目标仓库与默认分支" "https://github.com/other/project/blob/trunk2/docs/PLAYBOOK.md" "${cfg}"
acontains "T8.5 协作者使用目标账号" "rev-y" "$(jq -r '[.collaborators[].login] | join(",")' "${STUB_STATE}")"
ai="$(cat "${SB}/root/.github/authorized-identities.txt")"
acontains "T8.6 授权身份清单使用目标评审账号" "rev-y" "${ai}"
aeq "T8.7 安装结果无残留占位符（全树）" "0" "$(grep -rl '@@' "${SB}/root/.github" | wc -l | tr -d ' ')"

echo
echo "═══ 9. manifest 与 payload 一致性（清单是唯一归属依据） ═══"
setup_sandbox
jq 'del(.objects.labels.entries[0])' "${MF}" > "${SB}/mf2" && mv "${SB}/mf2" "${MF}"
run_ins --check
aeq "T9.1 清单与 payload 不一致时 --check 退出码 1" "1" "${rc}"
acontains "T9.2 报出清单不一致" "manifest 登记的标签与 payload 不一致" "${out}"

echo
echo "───────────────────────────────────────────────"
printf '自检结果：PASS=%s FAIL=%s\n' "${PASS}" "${FAIL}"
if [ "${FAIL}" -eq 0 ]; then
  echo "全部通过 ✅"
  exit 0
fi
echo "存在失败项 ❌"
exit 1
