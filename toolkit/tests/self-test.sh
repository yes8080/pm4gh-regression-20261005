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
SRC_ROOT="$(cd "${KIT_DIR}/.." && pwd)"   # 套件源码仓库根（用于 payload ↔ 自身文件的同步断言）
TMPJ="$(mktemp -d "${TMPDIR:-/tmp}/toolkit-selftest-tmp.XXXXXX")"

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
LG=""      # 归属记账（Bug #60：**在版本库之外**，默认 <root>/.git/toolkit-ledger.json）
cleanup() {  # 只清理本脚本自己创建的沙箱目录
  case "${SB:-}" in
    *toolkit-selftest.*) rm -rf "${SB}" ;;
  esac
  case "${TMPJ:-}" in
    *toolkit-selftest-tmp.*) rm -rf "${TMPJ}" ;;
  esac
}
trap cleanup EXIT INT TERM
setup_sandbox() {
  cleanup
  SB="$(mktemp -d "${TMPDIR:-/tmp}/toolkit-selftest.XXXXXX")"
  mkdir -p "${SB}/root/.secrets" "${SB}/bin" "${SB}/root/.git" "${SB}/kit"
  # 套件副本放在**仓库之外**（SB/kit），目标仓库根是 SB/root —— 这是套件的推荐用法：
  #   · objects.kit 走"创建"路径（目标仓库里出现受管 toolkit/，与真装一致）；
  #   · 卸载时不会把正在运行的脚本自己删掉，卸载后仍能跑 --check。
  cp -R "${KIT_DIR}/." "${SB}/kit/"
  printf 'fake-token-author'   > "${SB}/root/.secrets/developer.pat"
  printf 'fake-token-reviewer' > "${SB}/root/.secrets/reviewer.pat"
  cp "${TEST_DIR}/stub-gh.sh" "${SB}/bin/gh"; chmod +x "${SB}/bin/gh"
  printf '{"labels":[],"collaborators":[],"rulesets":[]}\n' > "${SB}/state.json"
  export STUB_STATE="${SB}/state.json" STUB_LOG="${SB}/gh.log" STUB_WRITES="${SB}/gh.writes"
  export STUB_REPO="acme/widgets" STUB_BRANCH="trunk"
  export STUB_AUTHOR="author-bot" STUB_REVIEWER="reviewer-bot"
  # `gh api .../contents/<path>?ref=<branch>` 的模拟基准（= 默认分支的工作区镜像）
  export STUB_ROOT="${SB}/root"
  unset STUB_FAIL_LABEL_NAME || true
  unset STUB_FAIL_DELETE || true
  : > "${STUB_LOG}"; : > "${STUB_WRITES}"
  PATH="${SB}/bin:${PATH}"; export PATH
  unset GH_TOKEN || true
  unset TOOLKIT_LEDGER || true
  KITYAML="${SB}/kit/kit.yaml"
  INS="${SB}/kit/install.sh"
  EJS="${SB}/kit/eject.sh"
  INV="${SB}/kit/scripts/check-invariants.sh"
  GOV="${SB}/kit/governance"
  TB="${SB}/root/.git/governance-eject-tombstone.json"
  REC="${SB}/root/.git/governance-eject-tombstone-record.md"
  LG="${SB}/root/.git/governance-ledger.json"
}
ins() { bash "${INS}" --root "${SB}/root" "$@" 2>&1; }
gov() {  # 沙箱里套件在仓库之外，必须显式 --root（真实采用者仓库里 ledger.sh 会自己向上找 .git）
  local sub="$1" s2="$2"
  shift 2 || true
  bash "${SB}/kit/governance" "$sub" "$s2" --root "${SB}/root" "$@" 2>&1
}
inv() { bash "${KIT_DIR}/scripts/check-invariants.sh" "$@" 2>&1; }
ej()  { bash "${EJS}" --root "${SB}/root" "$@" 2>&1; }
# 注意：set -e 下不能写 out="$(ins ...)"; rc=$? —— 命令替换失败会直接终止脚本
run_ins() { out=""; rc=0; out="$(ins "$@")" || rc=$?; }
run_ej()  { out=""; rc=0; out="$(ej "$@")"  || rc=$?; }
run_gov() { out=""; rc=0; out="$(gov "$@")" || rc=$?; }
run_inv() { out=""; rc=0; out="$(inv "$@")" || rc=$?; }
# 两阶段卸载（Bug #60 追加要求：先内容经 PR 落地、后门禁）：
#   阶段 A = --apply（只做内容，停在等待 PR 落地）
#   阶段 B = --apply --after-content-landed（标签 → 规则集 → 协作者）
# 沙箱里"默认分支"就是工作区镜像（stub 的 contents 接口），阶段 A 删完即视为已落地。
run_ej_all() { run_ej --apply "$@" || true; run_ej --apply --after-content-landed "$@"; }
writes() { cat "${STUB_WRITES}"; }
ledger() { jq -r ".entries[\"$1\"].$2" "${LG}"; }
apresent() { if [ -e "$2" ]; then apass "$1"; else afail "$1" "存在 $2" "不存在"; fi; }
aabsent()  { if [ -e "$2" ]; then afail "$1" "不存在 $2" "存在"; else apass "$1"; fi; }

echo "═══ 0. 出厂声明（kit.yaml）的静态不变量 ═══"
hard="$(grep -rn 'yes8080' "${KIT_DIR}" 2>/dev/null | grep -v "^${TEST_DIR}/self-test.sh:" || true)"
aeq "T0.1 toolkit/ 内无 yes8080（可移植性护栏）" "" "${hard}"
hard="$(grep -rln 'pm4gh' "${KIT_DIR}" 2>/dev/null | grep -v "^${TEST_DIR}/self-test.sh$" || true)"
aeq "T0.2 toolkit/ 内无 pm4gh（可移植性护栏）" "" "${hard}"

KITJ="${TMPJ}/kit.json"
if ! python3 "${KIT_DIR}/scripts/yaml2json.py" "${KIT_DIR}/kit.yaml" > "${KITJ}" 2>"${TMPJ}/y.err"; then
  afail "T0.3 kit.yaml 可被严格子集解析器解析" "退出码 0" "$(cat "${TMPJ}/y.err")"
else
  apass "T0.3 kit.yaml 可被严格子集解析器解析（不猜测：不支持的构造一律报错）"
fi
aeq "T0.4 出厂声明**不含**运行时账（配置/状态分离）" "0" \
  "$(jq -r '[(.ledger.entries // {}) | to_entries[]] | length' "${KITJ}" 2>/dev/null || printf X)"
aeq "T0.5 出厂声明声明了记账落点，且在版本库之外（.git/）" "true" \
  "$(jq -r '(.ledger.path // "") | test("\\.git/")' "${KITJ}")"
aeq "T0.6 记账落点 = <root>/.git/governance-ledger.json（决策 P-4）" "true" \
  "$(jq -r '(.ledger.path // "") | endswith("/.git/governance-ledger.json")' "${KITJ}")"
aeq "T0.7 记账必须活过 git clean -fdx（选 .git/ 的硬理由）" "true" \
  "$(jq -r '(.ledger.must_survive // "") | test("git clean -fdx")' "${KITJ}")"
aeq "T0.8 CODEOWNERS 不再是受管对象（NFR-17：只报告不写入）" "0" \
  "$(jq -r '[.objects | to_entries[] | select(.key=="codeowners")] | length' "${KITJ}")"
aeq "T0.9 仍给出 CODEOWNERS 建议行（只报告）" "true" \
  "$(jq -r '(.report_only.codeowners.suggested_lines // []) | length > 0' "${KITJ}")"
aeq "T0.10 套件目录登记在命名空间内" "true" \
  "$(jq -r --arg p "$(jq -r '.namespace.managed_files' "${KITJ}")" '(.objects.kit.entries[0].path // "") | startswith($p)' "${KITJ}")"
aeq "T0.11 占位符表与声明一致（KIT_ROOT = objects.kit.path）" "true" \
  "$(jq -r '(.placeholders.KIT_ROOT == .objects.kit.entries[0].path)' "${KITJ}")"
aeq "T0.12 占位符表与声明一致（KIT_GOVERNANCE_DIR = managed_files 去斜杠）" "true" \
  "$(jq -r '(.placeholders.KIT_GOVERNANCE_DIR == (.namespace.managed_files | rtrimstr("/")))' "${KITJ}")"
aeq "T0.13 占位符表与安装集一致（RULESET_DECL_PATH ∈ objects.files[].path）" "true" \
  "$(jq -r '(.placeholders.RULESET_DECL_PATH as $p | [.objects.files.entries[].path] | index($p) != null)' "${KITJ}")"
aeq "T0.14 payload 规则集的 name = kit.yaml 声明的规则集名" "true" \
  "$(jq -r --slurpfile rs "${KIT_DIR}/payload/main-protection.json" \
        '(.objects.rulesets.entries[0].name == $rs[0].name)' "${KITJ}")"
# payload 与 pm4gh 自身：**差异只能来自占位符**（PLAYBOOK §4 的同步铁律，机器化）
sync_bad=""
for wf in governance-checks governance-acceptance governance-state; do
  o="${SRC_ROOT}/.github/workflows/${wf}.yml"; q="${KIT_DIR}/payload/workflows/${wf}.yml"
  d="$(diff "$o" "$q" 2>/dev/null | grep -E '^[<>]' || true)"
  n_own="$(printf '%s\n' "${d}" | grep -cE '^<' || true)"
  n_pay="$(printf '%s\n' "${d}" | grep -cE '^>' || true)"
  bad="$(printf '%s\n' "${d}" | grep -E '^>' | grep -vE '@@[A-Z_]+@@' || true)"
  # 判据：① payload 侧每一条差异行都必须含占位符；② 两侧行数配对（不是单边新增/删除）
  if [ -n "${bad}" ] || [ "${n_own}" != "${n_pay}" ]; then sync_bad="${sync_bad} ${wf}"; fi
done
aeq "T0.15 payload workflow 与源码仓库自身的差异只来自占位符（逐行 + 配对）" "" "${sync_bad}"
# payload 规则集与 pm4gh 自身规则集：差异只能是 name 与 require_code_owner_review（后者是设计 §2.10 的要求）
rs_diff="$(jq -S 'del(.name) | (.rules[] | select(.type=="pull_request") | .parameters.require_code_owner_review) |= null' "${KIT_DIR}/payload/main-protection.json" | shasum -a 256 | awk '{print $1}')"
rs_own="$(jq -S 'del(.name) | (.rules[] | select(.type=="pull_request") | .parameters.require_code_owner_review) |= null' "${SRC_ROOT}/.github/rulesets/main-protection.json" | shasum -a 256 | awk '{print $1}')"
aeq "T0.16 payload 规则集与 pm4gh 自身规则集只差 name 与 code-owner 开关" "${rs_own}" "${rs_diff}"
aeq "T0.17 采用者侧规则集**不开** require_code_owner_review（配套 NFR-17）" "false" \
  "$(jq -r '[.rules[] | select(.type=="pull_request") | .parameters.require_code_owner_review] | .[0]' "${KIT_DIR}/payload/main-protection.json")"
# YAML 解析器反向样本：不支持的构造必须**报错**（不得静默误读 —— F12 的教训）
yaml_reject() {  # $1 = 片段；期望退出码 2
  printf '%s\n' "$1" > "${TMPJ}/bad.yaml"
  rc2=0; python3 "${KIT_DIR}/scripts/yaml2json.py" "${TMPJ}/bad.yaml" >/dev/null 2>&1 || rc2=$?
  printf '%s' "$rc2"
}
aeq "T0.18 反向样本：流式集合必须报错" "2" "$(yaml_reject 'a: {x: 1}')"
aeq "T0.19 反向样本：制表符缩进必须报错" "2" "$(yaml_reject 'a: 1
	b: 2')"
aeq "T0.20 反向样本：重复键必须报错" "2" "$(yaml_reject 'a: 1
a: 2')"
aeq "T0.21 反向样本：锚点必须报错" "2" "$(yaml_reject 'a: &x 1')"
aeq "T0.22 CLI 门面带 bash shebang（因此被 ci/lint 的 shebang 覆盖面补强纳入检查）" "yes" \
  "$(head -n 1 "${KIT_DIR}/governance" | grep -qE '^#!.*(bash|/sh)' && printf yes || printf no)"

echo "═══ 1. 空仓库 + 无记账：--check 必须**明确报错**（Bug #60 追加要求）═══"
setup_sandbox
run_ins --check
aeq "T1.1 --check 无记账时退出码 2（环境错误，不是静默通过）" "2" "${rc}"
acontains "T1.2 明确报出『归属记账不存在』" "归属记账不存在" "${out}"
acontains "T1.3 明确说明拒绝『猜测归属』" "拒绝在缺少归属记账时猜测归属" "${out}"
aeq "T1.4 --check 零写入" "" "$(writes)"
aeq "T1.5 未创建记账文件（--check 零写入）" "absent" "$([ -f "${LG}" ] && printf present || printf absent)"
: > "${STUB_WRITES}"
run_ins --dry-run
aeq "T1.6 无记账时 --dry-run 仍可零写入预告（退出码 0）" "0" "${rc}"
acontains "T1.7 且在头部显式报告记账不存在（不是静默）" "（不存在）" "${out}"
aeq "T1.8 --dry-run 零写入" "" "$(writes)"
aeq "T1.9 --dry-run 未创建记账（零写入语义成立）" "absent" "$([ -f "${LG}" ] && printf present || printf absent)"

echo
echo "═══ 2. 空仓库：--dry-run 应完整预告且零写入 ═══"
: > "${STUB_WRITES}"
run_ins --dry-run
aeq "T2.1 --dry-run 退出码 0" "0" "${rc}"
acontains "T2.2 预告创建文件" "创建" "${out}"
acontains "T2.3 预告创建规则集（命名空间 governance-）" "ruleset governance-main-protection" "${out}"
acontains "T2.3b 预告创建文件落在 .github/governance/**" ".github/governance/labels.yml" "${out}"
acontains "T2.3c 预告创建 workflow 落在 governance-*.yml" ".github/workflows/governance-checks.yml" "${out}"
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
aeq "T3.5 落盘 10 个受管文件（平台强制路径见豁免清单）" "10" "$(cd "${SB}/root" && ls .github/governance/labels.yml .github/governance/rulesets/governance-main-protection.json .github/governance/authorized-identities.txt .github/PULL_REQUEST_TEMPLATE.md .github/ISSUE_TEMPLATE/*.yml | wc -l | tr -d ' ')"
aeq "T3.5b 受管文件都落在 .github/governance/**（平台强制路径除外）" "3" "$(cd "${SB}/root" && ls .github/governance/labels.yml .github/governance/rulesets/governance-main-protection.json .github/governance/authorized-identities.txt | wc -l | tr -d ' ')"
aeq "T3.6 落盘 3 个工作流（含非必需的状态一致性工作流）" "3" "$(ls "${SB}/root/.github/workflows" | wc -l | tr -d ' ')"
aeq "T3.6b 工作流全部落在 governance-*.yml 命名空间" "3" "$(ls "${SB}/root/.github/workflows" | grep -cE '^governance-.*\.yml$' || true)"
aeq "T3.7 未创建/未改写用户 CODEOWNERS（NFR-17）" "absent" "$([ -e "${SB}/root/.github/CODEOWNERS" ] && printf present || printf absent)"
acontains "T3.7b 改为在报告里给出建议行（只报告）" "建议追加 CODEOWNERS:" "${out}"
acontains "T3.8 规则集写入前剥掉 _comment 字段" "true" "$(jq -r '.rulesets[0].body | has("_comment") | not' "${STUB_STATE}")"
aeq "T3.9 ledger 记 owned=true" "true" "$(ledger 'label:type/feature' owned)"
aeq "T3.10 ledger 记 pre_existing=false" "false" "$(ledger 'label:type/feature' pre_existing)"
aeq "T3.11 ledger 记文件 owned=true（命名空间路径）" "true" "$(ledger 'file:.github/governance/labels.yml' owned)"
aeq "T3.11b ledger 的三态字段齐备（phase/observed/owned/recorded_at）" "true" \
  "$(jq -r '(.entries["file:.github/governance/labels.yml"] | has("phase") and has("observed") and has("owned") and has("recorded_at"))' "${LG}")"
aeq "T3.11c 新建对象的 phase=owned / observed=present" "owned|present" \
  "$(jq -r '.entries["file:.github/governance/labels.yml"] | "\(.phase)|\(.observed)"' "${LG}")"
aeq "T3.12 ledger 记规则集 owned=true（命名空间名）" "true" "$(ledger 'ruleset:governance-main-protection' owned)"
resid="$(grep -rl '@@' "${SB}/root/.github/governance" "${SB}/root/.github/workflows" "${SB}/root/.github/PULL_REQUEST_TEMPLATE.md" "${SB}/root/.github/ISSUE_TEMPLATE" 2>/dev/null | grep -v '/governance/kit/' || true)"
aeq "T3.13 安装结果无残留占位符（受管面；vendored 套件里的模板除外）" "" "${resid}"
aeq "T3.14 安装结果无残留占位符（authorized-identities）" "0" "$(grepc '@@' "${SB}/root/.github/governance/authorized-identities.txt")"
# Bug #60 的核心断言：运行时状态落在**版本库之外**，分发物保持出厂状态
apresent "T3.15 归属记账写在 <root>/.git/ 下（版本库之外）" "${LG}"
aeq "T3.16 记账非空" "true" \
  "$(jq -r '(.entries | length) > 0' "${LG}")"
aeq "T3.17 记账含套件目录条目且 owned=true" "true" "$(ledger 'kit:toolkit' owned)"
aeq "T3.18 记账记录了套件整树指纹（供 eject 判漂移）" "true" \
  "$(jq -r '(.entries["kit:toolkit"].sha256 // "") | length > 0' "${LG}")"
aeq "T3.19 安装后出厂声明 kit.yaml 仍**不含**运行时账（配置/状态分离）" "0" \
  "$(python3 "${KIT_DIR}/scripts/yaml2json.py" "${KITYAML}" | jq -r '[(.ledger.entries // {}) | to_entries[]] | length')"
aeq "T3.20 安装后 kit.yaml 与套件源逐字节一致（运行时零写入）" "0" \
  "$(cmp -s "${KITYAML}" "${KIT_DIR}/kit.yaml" && printf 0 || printf 1)"
aeq "T3.21 套件目录已装配进目标仓库的命名空间目录（kit 类）" "present" \
  "$([ -f "${SB}/root/.github/governance/kit/tests/self-test.sh" ] && printf present || printf absent)"
aeq "T3.22 ci/lint 的覆盖面非空（目标仓库有 vendored 的套件 *.sh 依赖资产）" "present" \
  "$([ -f "${SB}/root/.github/governance/kit/scripts/labels.sh" ] && printf present || printf absent)"
aeq "T3.23 安装后不变量检查在目标仓库内通过（门禁自包含 / 命名空间 / 无 PR 状态）" "0" \
  "$(cd "${SB}/root" && bash .github/governance/kit/scripts/check-invariants.sh >/dev/null 2>&1; printf '%s' "$?")"

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
mkdir -p "${SB}/root/.github/governance"; printf 'user-owned\n' > "${SB}/root/.github/governance/labels.yml"
run_ins --apply
aeq "T6.1 存在冲突时 --apply 退出码 1（需要人工决定）" "1" "${rc}"
acontains "T6.2 报告冲突且不覆盖标签" "非本套件创建" "${out}"
aeq "T6.3 未对既有标签发起写入" "0" "$(grepc 'label edit' "${STUB_WRITES}")"
aeq "T6.4 既有文件内容未被改写" "user-owned" "$(cat "${SB}/root/.github/governance/labels.yml")"
aeq "T6.5 ledger 记 pre_existing=true" "true" "$(ledger 'label:type/feature' pre_existing)"
aeq "T6.6 ledger 记 owned=false" "false" "$(ledger 'label:type/feature' owned)"
run_ins --check
aeq "T6.7 冲突在 --check 中同样报漂移（退出码 1）" "1" "${rc}"
aeq "T6.8 --check 后既有文件仍未改写" "user-owned" "$(cat "${SB}/root/.github/governance/labels.yml")"

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
aeq "T8.2 CODEOWNERS 仍未创建（NFR-17：不接管用户既有文件）" "absent" \
  "$([ -e "${SB}/root/.github/CODEOWNERS" ] && printf present || printf absent)"
acontains "T8.2b 报告里的建议行使用目标 owner/reviewer" "@someone @rev-y" "${out}"
anotcontains "T8.3 报告里的建议行不含 acme" "@acme" "${out}"
cfg="$(cat "${SB}/root/.github/ISSUE_TEMPLATE/config.yml")"
acontains "T8.4 模板 URL 使用目标仓库与默认分支" "https://github.com/other/project/blob/trunk2/docs/PLAYBOOK.md" "${cfg}"
acontains "T8.5 协作者使用目标账号" "rev-y" "$(jq -r '[.collaborators[].login] | join(",")' "${STUB_STATE}")"
ai="$(cat "${SB}/root/.github/governance/authorized-identities.txt")"
acontains "T8.6 授权身份清单使用目标评审账号" "rev-y" "${ai}"
aeq "T8.7 安装结果无残留占位符（受管面；套件自身的 payload 模板不算）" "0" \
  "$(grep -rl '@@' "${SB}/root/.github/governance" "${SB}/root/.github/workflows" "${SB}/root/.github/ISSUE_TEMPLATE" "${SB}/root/.github/PULL_REQUEST_TEMPLATE.md" 2>/dev/null | grep -v '/governance/kit/' | wc -l | tr -d ' ')"

echo
echo "═══ 9. 出厂声明与 payload 一致性（声明是唯一归属依据） ═══"
setup_sandbox
# 反向样本：把 payload 里的最后一个标签定义删掉 → 声明（35）与 payload（34）不一致
awk 'BEGIN{last=0} {L[NR]=$0} /^[ \t]*-[ \t]*name:/{last=NR} END{for(i=1;i<last;i++) print L[i]}' \
    "${SB}/kit/payload/labels.yml" > "${SB}/kit/payload/labels.yml.tmp" \
  && mv "${SB}/kit/payload/labels.yml.tmp" "${SB}/kit/payload/labels.yml"
run_ins --apply
aeq "T9.1 声明与 payload 不一致时 --apply 退出码 1" "1" "${rc}"
acontains "T9.2 报出声明不一致" "登记的标签与 payload 不一致" "${out}"

echo
echo
echo "═══ 10. eject 语义①（两阶段）：阶段 A 只做内容并停在'需 PR 落地'；门禁最后才拆 ═══"
setup_sandbox
run_ins --apply
aeq "T10.1 先决条件：install --apply 成功" "0" "${rc}"
run_ej --check
aeq "T10.2 装机后 eject --check 退出码 1（还没卸载）" "1" "${rc}"
: > "${STUB_WRITES}"
run_ej --dry-run
aeq "T10.3 eject --dry-run 退出码 0" "0" "${rc}"
acontainsF "T10.4 预告删除受管文件" "[删除] .github/governance/labels.yml" "${out}"
acontainsF "T10.5 预告删除标签" "[删除] type/feature" "${out}"
acontainsF "T10.6 预告删除规则集" "[删除] governance-main-protection" "${out}"
acontains "T10.7 协作者询问式保留并给出手动撤销命令" "手动撤销：gh api -X DELETE" "${out}"
acontains "T10.8 dry-run 报出门禁勘测结果" "门禁勘测" "${out}"
acontains "T10.9 dry-run 指出必需检查的输入正是被删除对象（删除 PR 上无法上报）" "无法上报" "${out}"
aeq "T10.10 dry-run 零写入" "" "$(writes)"
aabsent "T10.11 dry-run 未创建 tombstone" "${TB}"

: > "${STUB_WRITES}"
run_ej --apply --record-issue 47
aeq "T10.12 阶段 A 退出码 1（停在'需通过 PR 落地'，未拆门禁）" "1" "${rc}"
acontains "T10.13 明确报告停在阶段 A" "已停在阶段 A" "${out}"
acontains "T10.14 明确要求通过 PR 落地（不直推）" "请通过 PR 落地" "${out}"
acontains "T10.15 明确说明规则集与协作者未被移除" "未被移除" "${out}"
acontains "T10.16 规则集被收窄（只去掉 required_status_checks）" "去掉 required_status_checks" "${out}"
aabsent "T10.17 受管文件已删除：.github/labels.yml" "${SB}/root/.github/governance/labels.yml"
aabsent "T10.18 受管文件已删除：.github/PULL_REQUEST_TEMPLATE.md" "${SB}/root/.github/PULL_REQUEST_TEMPLATE.md"
aabsent "T10.19 受管目录已删除：.github/ISSUE_TEMPLATE" "${SB}/root/.github/ISSUE_TEMPLATE"
aabsent "T10.20 受管目录已删除：.github/workflows" "${SB}/root/.github/workflows"
aabsent "T10.21 CODEOWNERS 从未被创建（NFR-17：只报告不写入）" "${SB}/root/.github/CODEOWNERS"
aabsent "T10.22 套件目录（依赖资产）已删除（命名空间路径）" "${SB}/root/.github/governance/kit"
aeq "T10.23 阶段 A **不动**标签（平台对象留到 PR 合并后）" "35" "$(jq '.labels | length' "${STUB_STATE}")"
aeq "T10.24 阶段 A **不拆**规则集（门禁本体最后才移除）" "1" "$(jq '.rulesets | length' "${STUB_STATE}")"
aeq "T10.25 规则集已被收窄：required_status_checks 规则已从其正文移除" "0" \
  "$(jq '[.rulesets[0].body.rules[] | select(.type == "required_status_checks")] | length' "${STUB_STATE}")"
aeq "T10.26 规则集仍含审查类规则（pull_request 未被收窄掉）" "1" \
  "$(jq '[.rulesets[0].body.rules[] | select(.type == "pull_request")] | length' "${STUB_STATE}")"
aeq "T10.27 协作者（持久权限）默认保留" "2" "$(jq '.collaborators | length' "${STUB_STATE}")"
aeq "T10.28 tombstone 状态=awaiting_content_pr" "awaiting_content_pr" "$(jq -r .status "${TB}")"
apresent "T10.29 卸载记录已写入文件" "${REC}"
acontains "T10.30 记录含'将删除的对象'" '### ① 将删除' "$(cat "${REC}")"
acontains "T10.31 记录含'可恢复锚点'" '### ③ 可恢复锚点' "$(cat "${REC}")"
acontains "T10.32 记录含协作者手动撤销命令" 'gh api -X DELETE' "$(cat "${REC}")"

# 阶段 B：内容已（在沙箱里）落地 → 才允许删标签 / 规则集 / 协作者
run_ej --apply --after-content-landed
aeq "T10.34 阶段 B（--after-content-landed）退出码 0" "0" "${rc}"
acontains "T10.35 阶段 B 先核实内容已落地" "内容删除已在 trunk 上落地" "${out}"
rec_line="$(grep -n '^issue comment 47 ' "${STUB_LOG}" | head -1 | cut -d: -f1)"
del_line="$(grep -n '^label delete ' "${STUB_LOG}" | head -1 | cut -d: -f1)"
order="no"
if [ -n "${rec_line}" ] && [ -n "${del_line}" ] && [ "${rec_line}" -lt "${del_line}" ]; then order="yes"; fi
aeq "T10.35b D7：锚点记录（Issue 评论）先于第一个不可逆删除" "yes" "${order}"
aeq "T10.36 本套件创建的标签全部消失" "0" "$(jq '.labels | length' "${STUB_STATE}")"
aeq "T10.37 本套件创建的规则集全部消失（门禁最后被移除）" "0" "$(jq '.rulesets | length' "${STUB_STATE}")"
aeq "T10.38 tombstone 状态=completed" "completed" "$(jq -r .status "${TB}")"
: > "${STUB_WRITES}"
run_ej --check
aeq "T10.39 卸载后 eject --check 退出码 0" "0" "${rc}"
acontains "T10.40 --check 报告'与装机前一致'" "与装机前一致" "${out}"
acontains "T10.41 --check 明确协作者属持久权限例外（未静默撤销）" "按询问式语义保留" "${out}"
aeq "T10.42 --check 零写入" "" "$(writes)"
run_ins --check
aeq "T10.43 卸载后 toolkit/install.sh --check 报漂移（受管对象全缺失）" "1" "${rc}"
acontains "T10.44 install --check 逐条报告受管文件缺失" "文件缺失" "${out}"
acontains "T10.45 install --check 逐条报告标签缺失" "标签缺失" "${out}"
run_ej --apply --after-content-landed
aeq "T10.46 已卸干净后重复终局阶段是 no-op（退出码 0）" "0" "${rc}"
acontains "T10.47 重复 --apply 报告'无待删除的 owned 对象'" "无待删除的 owned 对象" "${out}"
aeq "T10.48 no-op 收口后 tombstone 仍为 completed" "completed" "$(jq -r .status "${TB}")"

echo
echo "═══ 11. eject 语义②：漂移对象默认保留，--force 才删 ═══"
setup_sandbox
run_ins --apply
aeq "T11.1 先决条件：install --apply 成功" "0" "${rc}"
printf 'user-modified\n' >> "${SB}/root/.github/governance/labels.yml"
jq '(.labels[] | select(.name == "type/feature")) .color = "000000"' "${STUB_STATE}" > "${SB}/s" && mv "${SB}/s" "${STUB_STATE}"
run_ej --apply
aeq "T11.2 存在漂移时阶段 A 退出码 1（需人工决定/需落地 PR）" "1" "${rc}"
acontains "T11.3 报告漂移对象已保留" "因漂移保留" "${out}"
apresent "T11.4 漂移的受管文件仍在（未被静默删除）" "${SB}/root/.github/governance/labels.yml"
aeq "T11.5 漂移的标签仍在（未被静默删除）" "1" "$(jq '[.labels[] | select(.name == "type/feature")] | length' "${STUB_STATE}")"
aabsent "T11.6 未漂移的对象已正常删除" "${SB}/root/.github/PULL_REQUEST_TEMPLATE.md"
aeq "T11.7 tombstone 状态=awaiting_content_pr" "awaiting_content_pr" "$(jq -r .status "${TB}")"
# 反向样本：内容尚未落地时，终局阶段必须**拒绝**先拆门禁
run_ej --apply --after-content-landed
aeq "T11.8 反向样本：内容未落地 → 终局阶段拒绝继续（退出码 1）" "1" "${rc}"
acontains "T11.9 反向样本：明确指出内容尚未在默认分支落地" "尚未在默认分支" "${out}"
acontains "T11.10 反向样本：明确引用 Bug #60 的顺序要求" "必须在内容已落地之后才移除" "${out}"
aeq "T11.11 反向样本：规则集未被提前删除" "1" "$(jq '.rulesets | length' "${STUB_STATE}")"
run_ej --apply --force
aeq "T11.12 显式 --force 后阶段 A 删除漂移文件（仍停在 PR 阶段）" "1" "${rc}"
aabsent "T11.13 --force 后才删除漂移文件" "${SB}/root/.github/governance/labels.yml"
run_ej --apply --force --after-content-landed
aeq "T11.14 --force 的终局阶段退出码 0" "0" "${rc}"
aeq "T11.15 --force 后才删除漂移标签" "0" "$(jq '[.labels[] | select(.name == "type/feature")] | length' "${STUB_STATE}")"
run_ej --check
aeq "T11.16 --force 后 --check 退出码 0" "0" "${rc}"

echo
echo "═══ 12. eject 语义③：中断可续跑（tombstone + 每次重读线上实况） ═══"
setup_sandbox
run_ins --apply
aeq "T12.1 先决条件：install --apply 成功" "0" "${rc}"
export TOOLKIT_EJECT_ABORT_AFTER="files:file:.github/governance/labels.yml"
run_ej --apply --record-issue 47
unset TOOLKIT_EJECT_ABORT_AFTER
aeq "T12.2 模拟中断退出码 3" "3" "${rc}"
apresent "T12.3 中断后 tombstone 已落盘（可续跑）" "${TB}"
aeq "T12.4 tombstone 状态=planned" "planned" "$(jq -r .status "${TB}")"
apresent "T12.5 中断后记录文件已落盘" "${REC}"
acontains "T12.6 记录在删除**之前**已含全部将删除对象（含尚未删除者）" ".github/PULL_REQUEST_TEMPLATE.md" "$(cat "${REC}")"
aabsent "T12.7 已完成的删除：.github/labels.yml" "${SB}/root/.github/governance/labels.yml"
apresent "T12.8 尚未删除的：.github/PULL_REQUEST_TEMPLATE.md" "${SB}/root/.github/PULL_REQUEST_TEMPLATE.md"
base_before="$(jq -r '.baseline.labels | length' "${TB}")"
acontains "T12.9 baseline 保留了装机时的 owned 标签（未因半途状态重新打底）" "type/feature" "$(jq -r '.baseline.labels | join("\n")' "${TB}")"
run_ej --apply
aeq "T12.10 续跑完成阶段 A（退出码 1 = 停在 PR 阶段）" "1" "${rc}"
aeq "T12.11 续跑后 tombstone 状态=awaiting_content_pr" "awaiting_content_pr" "$(jq -r .status "${TB}")"
aeq "T12.12 续跑沿用首次 baseline（未重新打底）" "${base_before}" "$(jq -r '.baseline.labels | length' "${TB}")"
aabsent "T12.13 续跑后受管文件全部消失" "${SB}/root/.github/governance/labels.yml"
run_ej --apply --after-content-landed
aeq "T12.14 终局阶段续跑退出码 0（收敛）" "0" "${rc}"
aeq "T12.15 tombstone 状态=completed" "completed" "$(jq -r .status "${TB}")"
run_ej --check
aeq "T12.16 续跑后 --check 退出码 0" "0" "${rc}"
run_ins --check
aeq "T12.17 续跑后 install --check 报'受管对象全缺失'" "1" "${rc}"

echo
echo "═══ 13. eject 续跑：删除中途失败（stub 注入）后重跑收敛 ═══"
setup_sandbox
run_ins --apply
aeq "T13.1 先决条件：install --apply 成功" "0" "${rc}"
run_ej --apply
aeq "T13.2 阶段 A 完成（退出码 1 = 停在 PR 阶段）" "1" "${rc}"
export STUB_FAIL_DELETE="label delete status/ready"
run_ej --apply --after-content-landed
aeq "T13.3 有删除失败时终局阶段退出码 1" "1" "${rc}"
aeq "T13.4 注入失败的标签未被删除" "1" "$(jq '[.labels[] | select(.name == "status/ready")] | length' "${STUB_STATE}")"
aeq "T13.5 tombstone 状态=completed_with_failures" "completed_with_failures" "$(jq -r .status "${TB}")"
unset STUB_FAIL_DELETE
run_ej --apply --after-content-landed
aeq "T13.6 去掉故障后重跑退出码 0" "0" "${rc}"
aeq "T13.7 残留标签已被续跑删掉" "0" "$(jq '[.labels[] | select(.name == "status/ready")] | length' "${STUB_STATE}")"
run_ej --check
aeq "T13.8 续跑后 --check 退出码 0" "0" "${rc}"

echo
echo "═══ 14. eject 只删 owned：装机前已存在（pre_existing）的对象绝不删 ═══"
setup_sandbox
jq '.labels += [{name:"type/feature",color:"ffffff",description:"用户既有标签"}]' "${STUB_STATE}" > "${SB}/s" && mv "${SB}/s" "${STUB_STATE}"
run_ins --apply
aeq "T14.1 存在冲突时 install --apply 退出码 1（需人工决定）" "1" "${rc}"
aeq "T14.2 ledger 记 pre_existing=true" "true" "$(ledger 'label:type/feature' pre_existing)"
aeq "T14.3 ledger 记 owned=false" "false" "$(ledger 'label:type/feature' owned)"
run_ej --apply
aeq "T14.4 阶段 A 退出码 1（停在 PR 阶段）" "1" "${rc}"
run_ej --apply --after-content-landed
aeq "T14.5 终局阶段退出码 0（无漂移对象需人工决定）" "0" "${rc}"
aeq "T14.6 非本套件创建的标签未被删除（仅报告）" "1" "$(jq '[.labels[] | select(.name == "type/feature")] | length' "${STUB_STATE}")"
aeq "T14.7 其颜色也未被改动" "ffffff" "$(jq -r '.labels[] | select(.name == "type/feature") | .color' "${STUB_STATE}")"
aeq "T14.8 本套件创建的其它标签已删除" "0" "$(jq '[.labels[] | select(.name == "type/task")] | length' "${STUB_STATE}")"
run_ej --check
aeq "T14.9 --check 退出码 0" "0" "${rc}"

echo
echo "═══ 15. eject 不碰未登记对象 + 无可用门禁通道时**显式报告**（Bug #60 追加要求）═══"
setup_sandbox
printf '%s\n' '{"labels":[{"name":"user/custom","color":"ffffff","description":"用户既有标签"}],"collaborators":[{"login":"human-user","push":true}],"rulesets":[{"id":9,"name":"user-ruleset","body":{"name":"user-ruleset","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[]}}]}' > "${STUB_STATE}"
mkdir -p "${SB}/root/.github"
printf 'user content\n' > "${SB}/root/.github/USERFILE.md"
printf '%s\n' '# 用户自己的 CODEOWNERS' '/legacy/ @human-user' > "${SB}/root/.github/CODEOWNERS"
run_ins --apply
aeq "T15.1 用户既有对象不影响 install（退出码 0）" "0" "${rc}"
run_ej --apply
aeq "T15.2 阶段 A 退出码 1（停在 PR 阶段）" "1" "${rc}"
acontains "T15.3 阶段 A 明确要求通过 PR 落地" "请通过 PR 落地" "${out}"
aeq "T15.4 阶段 A 不动平台对象（标签仍在）" "1" "$(jq '[.labels[] | select(.name == "type/feature")] | length' "${STUB_STATE}")"
aeq "T15.5 阶段 A 不拆门禁（规则集仍在）" "2" "$(jq '.rulesets | length' "${STUB_STATE}")"
run_ej --apply --after-content-landed
aeq "T15.6 终局阶段退出码 0" "0" "${rc}"
aeq "T15.7 用户既有标签仍在且颜色未改" "1" "$(jq '[.labels[] | select(.name == "user/custom" and .color == "ffffff")] | length' "${STUB_STATE}")"
aeq "T15.8 用户既有规则集仍在" "1" "$(jq '[.rulesets[] | select(.name == "user-ruleset")] | length' "${STUB_STATE}")"
aeq "T15.9 用户既有协作者仍在" "1" "$(jq '[.collaborators[] | select(.login == "human-user")] | length' "${STUB_STATE}")"
apresent "T15.10 用户既有 .github 文件仍在" "${SB}/root/.github/USERFILE.md"
acontains "T15.11 CODEOWNERS 保留用户自己的行（NFR-17）" "@human-user" "$(cat "${SB}/root/.github/CODEOWNERS")"
aeq "T15.12 CODEOWNERS 仍只有用户自己的 2 行（套件从未追加 `*`）" "2" "$(grep -c . "${SB}/root/.github/CODEOWNERS" || true)"
aeq "T15.13 本套件创建的标签已删除" "0" "$(jq '[.labels[] | select(.name == "type/feature")] | length' "${STUB_STATE}")"
run_ej --check
aeq "T15.14 --check 退出码 0（与装机前一致）" "0" "${rc}"
acontains "T15.15 用户原有标签全部保持原样" "用户原有的标签全部保持原样" "${out}"
acontains "T15.16 用户原有规则集全部保持原样" "用户原有的规则集全部保持原样" "${out}"
acontains "T15.17 用户原有协作者全部保持原样" "用户原有的协作者全部保持原样" "${out}"
acontains "T15.18 CODEOWNERS 逐字节未被本套件触碰（NFR-17）" "CODEOWNERS 逐字节未被本套件触碰" "${out}"
# 反向样本（与 B9 同型）：故意损坏一个用户对象，--check 必须失败 —— 证明上面的"全绿"不是空断言
rm -f "${SB}/root/.github/USERFILE.md"
run_ej --check
aeq "T15.19 反向样本：删掉用户文件后 --check 退出码 1" "1" "${rc}"
acontains "T15.20 反向样本：--check 明确指出用户文件被动" "用户原有的 .github 文件被动了" "${out}"

echo
echo "═══ 16. eject 协作者：只有显式 --revoke-collaborators 才撤销 ═══"
setup_sandbox
run_ins --apply
aeq "T16.1 先决条件：install --apply 成功" "0" "${rc}"
run_ej --apply
aeq "T16.2 阶段 A 退出码 1（停在 PR 阶段）" "1" "${rc}"
run_ej --apply --after-content-landed
aeq "T16.3 默认终局阶段保留协作者（退出码 0）" "0" "${rc}"
aeq "T16.4 协作者仍在" "2" "$(jq '.collaborators | length' "${STUB_STATE}")"
acontains "T16.5 报告了保留与手动撤销命令" "手动撤销：gh api -X DELETE" "${out}"
anotcontainsF "T16.6 未执行任何撤销动作" "[撤销]" "${out}"
run_ej --apply --after-content-landed --revoke-collaborators
aeq "T16.7 显式 --revoke-collaborators 后退出码 0" "0" "${rc}"
aeq "T16.8 协作者已被撤销" "0" "$(jq '.collaborators | length' "${STUB_STATE}")"
run_ej --check
aeq "T16.9 --check 退出码 0" "0" "${rc}"
acontains "T16.10 --check 报告'完全一致'（无持久权限例外）" "与装机前完全一致" "${out}"

if [ "${TOOLKIT_SELFTEST_NESTED:-0}" != "1" ]; then
echo
echo "═══ 17. 反向样本：把运行时账注入出厂声明 → 必须失败（Bug #60 护栏） ═══"
setup_sandbox
# 重现 Bug #60 的真实形态：把"本次安装实际创建了什么"（含目标特有账号）写回出厂声明。
# 判据有两条，互为保险：① 声明里出现 ledger.entries 即为污染；② 安装后 kit.yaml 逐字节未变。
python3 - "${SB}/kit/kit.yaml" <<'PY'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
s = s.replace("ledger:\n", "ledger:\n  entries:\n    \"collaborator:author-bot\":\n      phase: \"owned\"\n      owned: true\n", 1)
io.open(p, "w", encoding="utf-8").write(s)
PY
aeq "T17.1 被注入运行时账的 kit.yaml 能被解析器读出（污染检测有覆盖面）" "1" \
  "$(python3 "${KIT_DIR}/scripts/yaml2json.py" "${SB}/kit/kit.yaml" | jq -r '[(.ledger.entries // {}) | to_entries[]] | length')"
run_ins --apply
aeq "T17.2 污染声明下 install 仍能跑（但 T3.19 那条护栏会红）" "0" "${rc}"
# 反向样本：套件自检本身必须因为 T0.4 而失败
trc=0
TOOLKIT_SELFTEST_NESTED=1 bash "${SB}/kit/tests/self-test.sh" > "${SB}/tainted.out" 2>&1 || trc=$?
aeq "T17.3 被污染的出厂声明让套件自检非零退出" "yes" "$([ "$trc" -ne 0 ] && printf yes || printf no)"
acontainsF "T17.4 失败原因点名 T0.4（声明含运行时账）" "[FAIL] T0.4" "$(cat "${SB}/tainted.out")"
# 正向对照：未污染的出厂声明在同一条护栏上通过
aeq "T17.5 对照：未污染的出厂声明 ledger.entries 为 0" "0" \
  "$(python3 "${KIT_DIR}/scripts/yaml2json.py" "${KIT_DIR}/kit.yaml" | jq -r '[(.ledger.entries // {}) | to_entries[]] | length')"
fi

echo "═══ 18. 反向样本：必需检查步骤在缺资产时必须**非零退出**（Bug #61 F3 的假绿） ═══"
setup_sandbox
STEP_NAME="标签定义可解析且格式正确（缺失资产必须显式失败）"
step_body="$(awk -v want="${STEP_NAME}" -f "${TEST_DIR}/extract-step.awk" "${KIT_DIR}/payload/workflows/governance-checks.yml" \
  | sed -E 's|@@KIT_GOVERNANCE_DIR@@|.github|g; s|@@KIT_ROOT@@|toolkit|g; s|@@RULESET_DECL_PATH@@|.github/rulesets/main-protection.json|g')"
aeq "T18.1 步骤正文抽取成功（非空；抽取失败会让本节的'通过'变成空跑）" "yes" \
  "$(if [ -n "${step_body}" ]; then printf yes; else printf no; fi)"
acontains "T18.2 该步骤含 set -euo pipefail" "set -euo pipefail" "${step_body}"
anotcontains "T18.3 该步骤不再使用管道（无管道即无假绿空间）" "| tail" "$(printf '%s\n' "${step_body}" | grep -vE '^[[:space:]]*#')"
ST="${SB}/steptest"; mkdir -p "${ST}"
printf '%s\n' "${step_body}" > "${ST}/step.sh"
src=0; ( cd "${ST}" && bash -e step.sh ) >/dev/null 2>&1 || src=$?
aeq "T18.4 缺 .github/labels.yml：非零退出" "yes" "$([ "$src" -ne 0 ] && printf yes || printf no)"
mkdir -p "${ST}/.github"; cp "${KIT_DIR}/payload/labels.yml" "${ST}/.github/labels.yml"
src=0; ( cd "${ST}" && bash -e step.sh ) >/dev/null 2>&1 || src=$?
aeq "T18.5 labels.yml 在、但解析器资产缺失：仍非零退出" "yes" "$([ "$src" -ne 0 ] && printf yes || printf no)"
mkdir -p "${ST}/toolkit/scripts"; cp "${KIT_DIR}/scripts/labels.sh" "${ST}/toolkit/scripts/labels.sh"
src=0; ( cd "${ST}" && bash -e step.sh ) >/dev/null 2>&1 || src=$?
aeq "T18.6 资产齐备时该步骤通过（正向对照，证明上面的非零不是无脑失败）" "0" "${src}"
# 旧写法的对照：同样"缺资产"，旧步骤退出码 0 = 假绿（Bug #61 F3 的实测形态）
printf '%s\n' 'bash scripts/sync-labels.sh --dry-run | tail -1' > "${ST}/old-step.sh"
oldrc=0; ( cd "${ST}" && bash -e old-step.sh ) >/dev/null 2>&1 || oldrc=$?
aeq "T18.7 旧写法在同样场景下退出码 0（复现 F3 的假绿）" "0" "${oldrc}"

echo
echo "═══ 20. 无可用门禁通道：没有任何规则集保护默认分支 → 必须显式报告，不静默直推 ═══"
setup_sandbox
run_ins --apply
aeq "T20.1 先决条件：install --apply 成功" "0" "${rc}"
jq '.rulesets = []' "${STUB_STATE}" > "${SB}/s" && mv "${SB}/s" "${STUB_STATE}"
: > "${STUB_WRITES}"
run_ej --dry-run
aeq "T20.2 dry-run 退出码 0" "0" "${rc}"
acontains "T20.3 勘测报告'没有被任何启用的规则集保护'" "没有被任何启用的规则集保护" "${out}"
aeq "T20.4 dry-run 零写入" "" "$(writes)"
run_ej --apply
aeq "T20.5 无门禁通道时阶段 A 后退出码 1（拒绝静默直推）" "1" "${rc}"
acontains "T20.6 显式报告『本次卸载将在无门禁状态下推送』" "本次卸载将在无门禁状态下推送" "${out}"
acontains "T20.7 要求显式确认（--allow-ungated）" "拒绝继续" "${out}"
aeq "T20.8 未确认前标签未被删除" "35" "$(jq '.labels | length' "${STUB_STATE}")"
run_ej --apply --allow-ungated
aeq "T20.9 显式 --allow-ungated 后退出码 0" "0" "${rc}"
acontains "T20.10 打印了无门禁下的推送命令" "git push origin trunk" "${out}"
aeq "T20.11 标签已删除" "0" "$(jq '.labels | length' "${STUB_STATE}")"
aeq "T20.12 规则集本就为空" "0" "$(jq '.rulesets | length' "${STUB_STATE}")"
run_ej --check
aeq "T20.13 --check 退出码 0" "0" "${rc}"

echo
echo "═══ 21. ledger show / ledger rebuild：账本可读、丢失可恢复（Issue #69 第 3 项） ═══"
setup_sandbox
run_ins --apply
aeq "T21.1 先决条件：install --apply 成功" "0" "${rc}"
run_gov ledger show
aeq "T21.2 ledger show 退出码 0" "0" "${rc}"
acontains "T21.3 说明它是什么（安装器**事务账**，不是任务账本）" "事务账" "${out}"
acontains "T21.4 说明它放在哪（完整路径）" "${LG}" "${out}"
acontains "T21.5 说明丢了怎么办（给出 rebuild）" "rebuild" "${out}"
acontains "T21.6 说明为什么放 .git/（活过 git clean -fdx）" "git clean -fdx" "${out}"
acontains "T21.7 打印条目明细（命名空间路径）" ".github/governance/labels.yml" "${out}"
run_gov ledger show --json
aeq "T21.8 ledger show --json 输出可被 jq 解析" "true" \
  "$(printf '%s' "${out}" | jq -e '(.entries | length) > 0' >/dev/null 2>&1 && printf true || printf false)"
# 账本丢失：--check / eject 必须**明确报错**，绝不猜归属
rm -f "${LG}"
run_ins --check
aeq "T21.9 账本丢失后 install --check 退出码 2（明确报错）" "2" "${rc}"
acontains "T21.10 报错里给出重建命令（不用猜）" "ledger rebuild" "${out}"
run_ej --check
aeq "T21.11 账本丢失后 eject --check 退出码 2（拒绝猜归属）" "2" "${rc}"
run_gov ledger rebuild --dry-run
# 期望退出码 1：受管文件都能自证归属，但**协作者属持久权限、命名空间无法自证** → 保守标记并报告，
# 需人工决定（与 eject 的"有需人工决定项 → 退出码 1"同一语义）。这不是失败，是刻意的保守。
aeq "T21.12 rebuild --dry-run 退出码 1（有无法自证归属的协作者 → 需人工决定）" "1" "${rc}"
acontains "T21.12b 明确说明为什么退出码非 0（保守保留，不据此撤销）" "归属无法自证" "${out}"
aeq "T21.13 rebuild --dry-run 零写入（账本仍未创建）" "absent" "$([ -f "${LG}" ] && printf present || printf absent)"
run_gov ledger rebuild --apply
aeq "T21.14 rebuild --apply 退出码 1（仍有需人工决定项），但账本已落盘" "1" "${rc}"
apresent "T21.15 账本已重建" "${LG}"
aeq "T21.16 重建后可自证归属的文件记 owned=true（内容与出厂一致）" "true" "$(ledger 'file:.github/governance/labels.yml' owned)"
aeq "T21.17 重建留痕（rebuilt=true 且写明依据）" "true" \
  "$(jq -r '(.rebuilt == true) and ((.rebuilt_from // "") | length > 0)' "${LG}")"
aeq "T21.18 协作者无法由命名空间自证 → 保守记 owned=false（不据此撤销）" "false" "$(ledger 'collaborator:author-bot' owned)"
run_ins --check
aeq "T21.19 重建后 install --check 通过（0 漂移）" "0" "${rc}"
run_ej_all
run_ej --check
aeq "T21.20 账本重建后仍能完成卸载与核验：**ledger 丢失不丢卸载能力**" "0" "${rc}"

echo
echo "═══ 22. ledger 必须活过 git clean -fdx（这就是不放仓库内 + gitignore 的硬理由） ═══"
setup_sandbox
run_ins --apply
aeq "T22.1 先决条件：install --apply 成功" "0" "${rc}"
git -C "${SB}/root" init -q 2>/dev/null || true
apresent "T22.2 clean 之前账本存在" "${LG}"
git -C "${SB}/root" clean -fdxq >/dev/null 2>&1 || true
apresent "T22.3 git clean -fdx 之后账本**仍然存在**（未跟踪文件会被清掉，.git/ 内不会）" "${LG}"
aabsent "T22.4 对照：同一条命令确实清掉了未跟踪的受管文件" "${SB}/root/.github/governance/labels.yml"
run_gov ledger show
aeq "T22.5 clean 之后 ledger show 仍可用（账本没丢）" "0" "${rc}"
acontains "T22.6 且仍能读出条目明细" ".github/governance/labels.yml" "${out}"

echo
echo "═══ 23. 不变量检查（不变量 B / 命名空间 / 无 PR 状态一致性）+ 反向样本 ═══"
run_inv
aeq "T23.1 套件源码仓库：全部不变量通过（退出码 0）" "0" "${rc}"
acontains "T23.2 报告不变量 B 成立" "不变量 B 成立" "${out}"
acontains "T23.3 报告命名空间归属成立" "全部受管对象都在命名空间内" "${out}"
acontains "T23.4 报告无 PR 场景状态一致（缺口已补）" "无 PR 场景状态一致" "${out}"
acontains "T23.5 汇总行给出 PASS/FAIL（反空跑）" "不变量检查结果：PASS=5 FAIL=0" "${out}"
INV_COPY="${SB}/kit2"
inv_copy() { out=""; rc=0; out="$(bash "${INV_COPY}/scripts/check-invariants.sh" --kit-dir "${INV_COPY}" --root "${INV_COPY}" "$@" 2>&1)" || rc=$?; }

# 反向样本 A：门禁引用了**未安装的宿主私有资产** → 不变量 B 必须失败（F2 的形态）
rm -rf "${INV_COPY}"; mkdir -p "${INV_COPY}"; cp -R "${KIT_DIR}/." "${INV_COPY}/"
printf '%s\n' '      - name: 伪造的宿主私有依赖' '        run: bash scripts/host-private.sh' >> "${INV_COPY}/payload/workflows/governance-checks.yml"
inv_copy --check invariant-b
aeq "T23.6 反向样本 A：引用未安装资产 → 不变量 B 失败（退出码 1）" "1" "${rc}"
acontains "T23.7 反向样本 A：点出越界的引用" "scripts/host-private.sh" "${out}"

# 反向样本 B：把受管文件移出命名空间（且不写豁免理由）→ 命名空间检查必须失败
rm -rf "${INV_COPY}"; mkdir -p "${INV_COPY}"; cp -R "${KIT_DIR}/." "${INV_COPY}/"
sed -i.bak 's|\.github/governance/labels\.yml|.github/labels.yml|g' "${INV_COPY}/kit.yaml"; rm -f "${INV_COPY}/kit.yaml.bak"
inv_copy --check namespace
aeq "T23.8 反向样本 B：受管文件越出命名空间 → 检查失败（退出码 1）" "1" "${rc}"
acontainsF "T23.9 反向样本 B：说明它越界且未豁免" "不在 .github/governance/** 之内" "${out}"

# 反向样本 C：规则集开了套件无法满足的 code-owner 评审（而套件不改写用户 CODEOWNERS）→ 必须失败
rm -rf "${INV_COPY}"; mkdir -p "${INV_COPY}"; cp -R "${KIT_DIR}/." "${INV_COPY}/"
python3 - "${INV_COPY}/payload/main-protection.json" <<'PYX'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
for r in d["rules"]:
    if r["type"] == "pull_request":
        r["parameters"]["require_code_owner_review"] = True
json.dump(d, open(p, "w"), ensure_ascii=False, indent=2)
PYX
inv_copy --check codeowners
aeq "T23.10 反向样本 C：装了套件无法满足的门禁 → 检查失败" "1" "${rc}"
acontains "T23.11 反向样本 C：点名 require_code_owner_review" "require_code_owner_review" "${out}"

# 反向样本 D：**删掉非 PR 触发器**（缺口回归）→ 状态一致性检查必须失败
rm -rf "${INV_COPY}"; mkdir -p "${INV_COPY}"; cp -R "${KIT_DIR}/." "${INV_COPY}/"
sed -i.bak '/^  workflow_dispatch:/d' "${INV_COPY}/payload/workflows/governance-state.yml"; rm -f "${INV_COPY}/payload/workflows/governance-state.yml.bak"
inv_copy --check state
aeq "T23.12 反向样本 D：去掉 workflow_dispatch → 状态一致性检查失败" "1" "${rc}"
acontains "T23.13 反向样本 D：明确点出缺非 PR 触发器（否则「无 PR 就停摆」会静默回归）" "缺少 workflow_dispatch 触发器" "${out}"

# 反向样本 E：把受管工作流改名脱离 governance-* 命名空间 → 命名空间检查必须失败
rm -rf "${INV_COPY}"; mkdir -p "${INV_COPY}"; cp -R "${KIT_DIR}/." "${INV_COPY}/"
sed -i.bak 's|\.github/workflows/governance-checks\.yml|.github/workflows/checks.yml|g' "${INV_COPY}/kit.yaml"; rm -f "${INV_COPY}/kit.yaml.bak"
inv_copy --check namespace
aeq "T23.14 反向样本 E：工作流脱离 governance-*.yml → 检查失败" "1" "${rc}"
acontainsF "T23.15 反向样本 E：说明它不是 governance-*.yml" "不是 .github/workflows/governance-*.yml" "${out}"

echo
echo
echo "═══ 19. 收尾 ═══"
printf '自检结果：PASS=%s FAIL=%s\n' "${PASS}" "${FAIL}"
if [ "${FAIL}" -eq 0 ]; then
  echo "全部通过 ✅"
  exit 0
fi
echo "存在失败项 ❌"
exit 1
