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
# 含 [ ] 等正则元字符的期望串必须用固定串匹配（grep -F），否则 [删除] 会被当成字符类
acontainsF() { if printf '%s' "$3" | grep -qF -- "$2"; then apass "$1"; else afail "$1" "包含「$2」" "$3"; fi; }
anotcontains() { if printf '%s' "$3" | grep -q -- "$2"; then afail "$1" "不含「$2」" "$3"; else apass "$1"; fi; }
anotcontainsF() { if printf '%s' "$3" | grep -qF -- "$2"; then afail "$1" "不含「$2」" "$3"; else apass "$1"; fi; }
grepc() { grep -c -- "$1" "$2" 2>/dev/null || true; }

SB=""
TB=""      # eject 的 tombstone（默认落在 <root>/.git/ 下，见 eject.sh）
REC=""     # eject 的人类可读记录
cleanup() {  # 只清理本脚本自己创建的沙箱目录
  case "${SB:-}" in
    *toolkit-selftest.*) rm -rf "${SB}" ;;
  esac
}
trap cleanup EXIT INT TERM
setup_sandbox() {
  cleanup
  SB="$(mktemp -d "${TMPDIR:-/tmp}/toolkit-selftest.XXXXXX")"
  mkdir -p "${SB}/root/.secrets" "${SB}/bin" "${SB}/root/.git"
  cp -R "${KIT_DIR}" "${SB}/root/toolkit"
  printf 'fake-token-author'   > "${SB}/root/.secrets/developer.pat"
  printf 'fake-token-reviewer' > "${SB}/root/.secrets/reviewer.pat"
  cp "${TEST_DIR}/stub-gh.sh" "${SB}/bin/gh"; chmod +x "${SB}/bin/gh"
  printf '{"labels":[],"collaborators":[],"rulesets":[]}\n' > "${SB}/state.json"
  export STUB_STATE="${SB}/state.json" STUB_LOG="${SB}/gh.log" STUB_WRITES="${SB}/gh.writes"
  export STUB_REPO="acme/widgets" STUB_BRANCH="trunk"
  export STUB_AUTHOR="author-bot" STUB_REVIEWER="reviewer-bot"
  unset STUB_FAIL_LABEL_NAME || true
  unset STUB_FAIL_DELETE || true
  : > "${STUB_LOG}"; : > "${STUB_WRITES}"
  PATH="${SB}/bin:${PATH}"; export PATH
  unset GH_TOKEN || true
  MF="${SB}/root/toolkit/manifest.json"
  INS="${SB}/root/toolkit/install.sh"
  EJS="${SB}/root/toolkit/eject.sh"
  TB="${SB}/root/.git/toolkit-eject-tombstone.json"
  REC="${SB}/root/.git/toolkit-eject-tombstone-record.md"
}
ins() { bash "${INS}" "$@" 2>&1; }
ej()  { bash "${EJS}" "$@" 2>&1; }
# 注意：set -e 下不能写 out="$(ins ...)"; rc=$? —— 命令替换失败会直接终止脚本
run_ins() { out=""; rc=0; out="$(ins "$@")" || rc=$?; }
run_ej()  { out=""; rc=0; out="$(ej "$@")"  || rc=$?; }
writes() { cat "${STUB_WRITES}"; }
ledger() { jq -r ".ledger[\"$1\"].$2" "${MF}"; }
apresent() { if [ -e "$2" ]; then apass "$1"; else afail "$1" "存在 $2" "不存在"; fi; }
aabsent()  { if [ -e "$2" ]; then afail "$1" "不存在 $2" "存在"; else apass "$1"; fi; }

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
echo "═══ 10. eject 语义①：只删 owned 且未漂移；卸载后 --check 报告'与装机前一致' ═══"
setup_sandbox
run_ins --apply
aeq "T10.1 先决条件：install --apply 成功" "0" "${rc}"
run_ej --check
aeq "T10.2 装机后 eject --check 退出码 1（还没卸载）" "1" "${rc}"
: > "${STUB_WRITES}"
run_ej --dry-run
aeq "T10.3 eject --dry-run 退出码 0" "0" "${rc}"
acontainsF "T10.4 预告删除受管文件" "[删除] .github/labels.yml" "${out}"
acontainsF "T10.5 预告删除标签" "[删除] type/feature" "${out}"
acontainsF "T10.6 预告删除规则集" "[删除] main-protection" "${out}"
acontains "T10.7 协作者询问式保留并给出手动撤销命令" "手动撤销：gh api -X DELETE" "${out}"
aeq "T10.8 dry-run 零写入" "" "$(writes)"
aabsent "T10.9 dry-run 未创建 tombstone" "${TB}"

: > "${STUB_WRITES}"
run_ej --apply --record-issue 47
aeq "T10.10 eject --apply 退出码 0" "0" "${rc}"
aabsent "T10.11 受管文件消失：.github/labels.yml" "${SB}/root/.github/labels.yml"
aabsent "T10.12 受管文件消失：.github/PULL_REQUEST_TEMPLATE.md" "${SB}/root/.github/PULL_REQUEST_TEMPLATE.md"
aabsent "T10.13 受管目录消失：.github/ISSUE_TEMPLATE" "${SB}/root/.github/ISSUE_TEMPLATE"
aabsent "T10.14 受管目录消失：.github/workflows" "${SB}/root/.github/workflows"
aabsent "T10.15 仅剩本套件表头的 CODEOWNERS 也被撤掉" "${SB}/root/.github/CODEOWNERS"
aeq "T10.16 本套件创建的标签全部消失" "0" "$(jq '.labels | length' "${STUB_STATE}")"
aeq "T10.17 本套件创建的规则集全部消失" "0" "$(jq '.rulesets | length' "${STUB_STATE}")"
aeq "T10.18 协作者（持久权限）默认保留" "2" "$(jq '.collaborators | length' "${STUB_STATE}")"
aeq "T10.19 tombstone 状态=completed" "completed" "$(jq -r .status "${TB}")"
apresent "T10.20 卸载记录已写入文件" "${REC}"
acontains "T10.21 记录含'将删除的对象'" '### ① 将删除' "$(cat "${REC}")"
acontains "T10.22 记录含'可恢复锚点'" '### ③ 可恢复锚点' "$(cat "${REC}")"
acontains "T10.23 记录含协作者手动撤销命令" 'gh api -X DELETE' "$(cat "${REC}")"
rec_line="$(grep -n '^issue comment 47 ' "${STUB_LOG}" | head -1 | cut -d: -f1)"
del_line="$(grep -n '^label delete ' "${STUB_LOG}" | head -1 | cut -d: -f1)"
order="no"
if [ -n "${rec_line}" ] && [ -n "${del_line}" ] && [ "${rec_line}" -lt "${del_line}" ]; then order="yes"; fi
aeq "T10.24 D7：锚点记录（Issue 评论）先于第一个不可逆删除" "yes" "${order}"
: > "${STUB_WRITES}"
run_ej --check
aeq "T10.25 卸载后 eject --check 退出码 0" "0" "${rc}"
acontains "T10.26 --check 报告'与装机前一致'" "与装机前一致" "${out}"
acontains "T10.27 --check 明确协作者属持久权限例外（未静默撤销）" "按询问式语义保留" "${out}"
aeq "T10.28 --check 零写入" "" "$(writes)"
run_ins --check
aeq "T10.29 卸载后 toolkit/install.sh --check 报漂移（受管对象全缺失）" "1" "${rc}"
acontains "T10.30 install --check 逐条报告受管文件缺失" "文件缺失" "${out}"
acontains "T10.31 install --check 逐条报告标签缺失" "标签缺失" "${out}"
run_ej --apply
aeq "T10.32 已卸干净后重复 --apply 是 no-op（退出码 0）" "0" "${rc}"
acontains "T10.33 重复 --apply 报告'无待删除的 owned 对象'" "无待删除的 owned 对象" "${out}"
aeq "T10.34 no-op 收口后 tombstone 仍为 completed" "completed" "$(jq -r .status "${TB}")"

echo
echo "═══ 11. eject 语义②：漂移对象默认保留，--force 才删 ═══"
setup_sandbox
run_ins --apply
aeq "T11.1 先决条件：install --apply 成功" "0" "${rc}"
printf 'user-modified\n' >> "${SB}/root/.github/labels.yml"
jq '(.labels[] | select(.name == "type/feature")) .color = "000000"' "${STUB_STATE}" > "${SB}/s" && mv "${SB}/s" "${STUB_STATE}"
run_ej --apply
aeq "T11.2 存在漂移时 --apply 退出码 1（需人工决定）" "1" "${rc}"
acontains "T11.3 报告漂移对象已保留" "因漂移保留" "${out}"
apresent "T11.4 漂移的受管文件仍在（未被静默删除）" "${SB}/root/.github/labels.yml"
aeq "T11.5 漂移的标签仍在（未被静默删除）" "1" "$(jq '[.labels[] | select(.name == "type/feature")] | length' "${STUB_STATE}")"
aabsent "T11.6 未漂移的对象已正常删除" "${SB}/root/.github/PULL_REQUEST_TEMPLATE.md"
aeq "T11.7 tombstone 状态=completed_with_drift_kept" "completed_with_drift_kept" "$(jq -r .status "${TB}")"
run_ej --apply --force
aeq "T11.8 显式 --force 后退出码 0" "0" "${rc}"
aabsent "T11.9 --force 后才删除漂移文件" "${SB}/root/.github/labels.yml"
aeq "T11.10 --force 后才删除漂移标签" "0" "$(jq '[.labels[] | select(.name == "type/feature")] | length' "${STUB_STATE}")"
run_ej --check
aeq "T11.11 --force 后 --check 退出码 0" "0" "${rc}"

echo
echo "═══ 12. eject 语义③：中断可续跑（tombstone + 每次重读线上实况） ═══"
setup_sandbox
run_ins --apply
aeq "T12.1 先决条件：install --apply 成功" "0" "${rc}"
export TOOLKIT_EJECT_ABORT_AFTER="files:file:.github/labels.yml"
run_ej --apply --record-issue 47
unset TOOLKIT_EJECT_ABORT_AFTER
aeq "T12.2 模拟中断退出码 3" "3" "${rc}"
apresent "T12.3 中断后 tombstone 已落盘（可续跑）" "${TB}"
aeq "T12.4 tombstone 状态=planned" "planned" "$(jq -r .status "${TB}")"
apresent "T12.5 中断后记录文件已落盘" "${REC}"
acontains "T12.6 记录在删除**之前**已含全部将删除对象（含尚未删除者）" ".github/PULL_REQUEST_TEMPLATE.md" "$(cat "${REC}")"
aabsent "T12.7 已完成的删除：.github/labels.yml" "${SB}/root/.github/labels.yml"
apresent "T12.8 尚未删除的：.github/PULL_REQUEST_TEMPLATE.md" "${SB}/root/.github/PULL_REQUEST_TEMPLATE.md"
base_before="$(jq -r '.baseline.labels | length' "${TB}")"
acontains "T12.9 baseline 保留了装机时的 owned 标签（未因半途状态重新打底）" "type/feature" "$(jq -r '.baseline.labels | join("\n")' "${TB}")"
run_ej --apply
aeq "T12.10 重跑续跑退出码 0（收敛）" "0" "${rc}"
aeq "T12.11 tombstone 状态=completed" "completed" "$(jq -r .status "${TB}")"
aeq "T12.12 续跑沿用首次 baseline（未重新打底）" "${base_before}" "$(jq -r '.baseline.labels | length' "${TB}")"
aabsent "T12.13 续跑后受管文件全部消失" "${SB}/root/.github/labels.yml"
run_ej --check
aeq "T12.14 续跑后 --check 退出码 0" "0" "${rc}"
run_ins --check
aeq "T12.15 续跑后 install --check 报'受管对象全缺失'" "1" "${rc}"

echo
echo "═══ 13. eject 续跑：删除中途失败（stub 注入）后重跑收敛 ═══"
setup_sandbox
run_ins --apply
aeq "T13.1 先决条件：install --apply 成功" "0" "${rc}"
export STUB_FAIL_DELETE="label delete status/ready"
run_ej --apply
aeq "T13.2 有删除失败时退出码 1" "1" "${rc}"
aeq "T13.3 注入失败的标签未被删除" "1" "$(jq '[.labels[] | select(.name == "status/ready")] | length' "${STUB_STATE}")"
aeq "T13.4 tombstone 状态=completed_with_failures" "completed_with_failures" "$(jq -r .status "${TB}")"
unset STUB_FAIL_DELETE
run_ej --apply
aeq "T13.5 去掉故障后重跑退出码 0" "0" "${rc}"
aeq "T13.6 残留标签已被续跑删掉" "0" "$(jq '[.labels[] | select(.name == "status/ready")] | length' "${STUB_STATE}")"
run_ej --check
aeq "T13.7 续跑后 --check 退出码 0" "0" "${rc}"

echo
echo "═══ 14. eject 只删 owned：装机前已存在（pre_existing）的对象绝不删 ═══"
setup_sandbox
jq '.labels += [{name:"type/feature",color:"ffffff",description:"用户既有标签"}]' "${STUB_STATE}" > "${SB}/s" && mv "${SB}/s" "${STUB_STATE}"
run_ins --apply
aeq "T14.1 存在冲突时 install --apply 退出码 1（需人工决定）" "1" "${rc}"
aeq "T14.2 ledger 记 pre_existing=true" "true" "$(ledger 'label:type/feature' pre_existing)"
aeq "T14.3 ledger 记 owned=false" "false" "$(ledger 'label:type/feature' owned)"
run_ej --apply
aeq "T14.4 eject --apply 退出码 0（无漂移对象需人工决定）" "0" "${rc}"
aeq "T14.5 非本套件创建的标签未被删除（仅报告）" "1" "$(jq '[.labels[] | select(.name == "type/feature")] | length' "${STUB_STATE}")"
aeq "T14.6 其颜色也未被改动" "ffffff" "$(jq -r '.labels[] | select(.name == "type/feature") | .color' "${STUB_STATE}")"
aeq "T14.7 本套件创建的其它标签已删除" "0" "$(jq '[.labels[] | select(.name == "type/task")] | length' "${STUB_STATE}")"
run_ej --check
aeq "T14.8 --check 退出码 0" "0" "${rc}"

echo
echo "═══ 15. eject 不碰未登记对象：用户原有对象一个不少（含反向样本） ═══"
setup_sandbox
printf '%s\n' '{"labels":[{"name":"user/custom","color":"ffffff","description":"用户既有标签"}],"collaborators":[{"login":"human-user","push":true}],"rulesets":[{"id":9,"name":"user-ruleset","body":{"name":"user-ruleset","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[]}}]}' > "${STUB_STATE}"
mkdir -p "${SB}/root/.github"
printf 'user content\n' > "${SB}/root/.github/USERFILE.md"
printf '%s\n' '# 用户自己的 CODEOWNERS' '/docs/ @human-user' > "${SB}/root/.github/CODEOWNERS"
run_ins --apply
aeq "T15.1 用户既有对象不影响 install（退出码 0）" "0" "${rc}"
run_ej --apply
aeq "T15.2 eject --apply 退出码 0" "0" "${rc}"
aeq "T15.3 用户既有标签仍在且颜色未改" "1" "$(jq '[.labels[] | select(.name == "user/custom" and .color == "ffffff")] | length' "${STUB_STATE}")"
aeq "T15.4 用户既有规则集仍在" "1" "$(jq '[.rulesets[] | select(.name == "user-ruleset")] | length' "${STUB_STATE}")"
aeq "T15.5 用户既有协作者仍在" "1" "$(jq '[.collaborators[] | select(.login == "human-user")] | length' "${STUB_STATE}")"
apresent "T15.6 用户既有 .github 文件仍在" "${SB}/root/.github/USERFILE.md"
acontains "T15.7 CODEOWNERS 保留用户自己的行" "@human-user" "$(cat "${SB}/root/.github/CODEOWNERS")"
aeq "T15.8 本套件写入的 CODEOWNERS 行已撤除" "0" "$(grep -c 'acme' "${SB}/root/.github/CODEOWNERS" || true)"
aeq "T15.9 本套件创建的标签已删除" "0" "$(jq '[.labels[] | select(.name == "type/feature")] | length' "${STUB_STATE}")"
run_ej --check
aeq "T15.10 --check 退出码 0（与装机前一致）" "0" "${rc}"
acontains "T15.11 用户原有标签全部保持原样" "用户原有的标签全部保持原样" "${out}"
acontains "T15.12 用户原有规则集全部保持原样" "用户原有的规则集全部保持原样" "${out}"
acontains "T15.13 用户原有协作者全部保持原样" "用户原有的协作者全部保持原样" "${out}"
acontains "T15.14 CODEOWNERS 中原有行保持原样" "CODEOWNERS 中原有的" "${out}"
# 反向样本（与 B9 同型）：故意损坏一个用户对象，--check 必须失败 —— 证明上面的"全绿"不是空断言
rm -f "${SB}/root/.github/USERFILE.md"
run_ej --check
aeq "T15.15 反向样本：删掉用户文件后 --check 退出码 1" "1" "${rc}"
acontains "T15.16 反向样本：--check 明确指出用户文件被动" "用户原有的 .github 文件被动了" "${out}"

echo
echo "═══ 16. eject 协作者：只有显式 --revoke-collaborators 才撤销 ═══"
setup_sandbox
run_ins --apply
aeq "T16.1 先决条件：install --apply 成功" "0" "${rc}"
run_ej --apply
aeq "T16.2 默认 --apply 保留协作者" "2" "$(jq '.collaborators | length' "${STUB_STATE}")"
acontains "T16.3 默认 --apply 报告了保留与手动撤销命令" "手动撤销：gh api -X DELETE" "${out}"
anotcontainsF "T16.4 默认 --apply 未执行任何撤销动作" "[撤销]" "${out}"
run_ej --apply --revoke-collaborators
aeq "T16.5 显式 --revoke-collaborators 后退出码 0" "0" "${rc}"
aeq "T16.6 协作者已被撤销" "0" "$(jq '.collaborators | length' "${STUB_STATE}")"
run_ej --check
aeq "T16.7 --check 退出码 0" "0" "${rc}"
acontains "T16.8 --check 报告'完全一致'（无持久权限例外）" "与装机前完全一致" "${out}"

echo
echo "───────────────────────────────────────────────"
printf '自检结果：PASS=%s FAIL=%s\n' "${PASS}" "${FAIL}"
if [ "${FAIL}" -eq 0 ]; then
  echo "全部通过 ✅"
  exit 0
fi
echo "存在失败项 ❌"
exit 1
